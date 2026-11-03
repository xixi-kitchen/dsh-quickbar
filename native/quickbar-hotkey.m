/*
 * quickbar-hotkey.m — dsh-quickbar native macOS helper (v5).
 *
 * Pure C/Objective-C (no Swift, no Accessibility permission, no CGEventTap).
 * Registers exactly one system-wide hotkey with the Carbon HotKey API, keeps the
 * process alive with Cocoa's NSApplication run loop, and shows a lightweight
 * always-on-top command palette (native/DESIGN.md is the authoritative visual
 * spec): a material card with three pill selectors, a multi-line input, an
 * image-thumbnail strip, and a footer with key hints plus an accent Send pill.
 *
 * The long-lived host plugin spawns this binary and talks to it over
 * stdout/stderr (protocol) and stdin (control):
 *
 *   stdout (protocol only, every line flushed):
 *     READY <pid>             hotkey registered and handler installed
 *     TRIGGER <epoch-ms>      hotkey pressed (physical, synthesized, or stdin)
 *     SUBMIT <base64-json>    popup submitted:
 *                             {text, workspaceId, provider, model,
 *                              reasoningEffort,
 *                              images:[{mediaType, base64, name?, width?, height?}]}
 *     CANCEL                  popup cancelled (Escape)
 *     ERROR <code> [message]  failure; exit 3 (2 for invalid-spec)
 *
 *   stdin (control, one command per line):
 *     trigger                 show the popup, exactly like pressing the hotkey
 *     CFG <base64-json>       update the pickers (workspaces/models/selection)
 *     SUBMIT_OK               the host accepted the submission: show the
 *                             checkmark for 150 ms, then close the panel
 *     SUBMIT_FAIL <text>      the host rejected it: show the inline error row,
 *                             keep the text and re-enable the input
 *     (blank / unknown lines are ignored; EOF leaves the helper running)
 *
 * CLI:
 *     quickbar-hotkey <hotkey-spec>
 *         run (hotkey + popup)
 *     quickbar-hotkey <hotkey-spec> --selftest
 *         register + synthesize one hotkey event, no UI, exit 0
 *     quickbar-hotkey <hotkey-spec> --ui-test [CFG_JSON] TEXT
 *         build the popup, optionally apply CFG_JSON, set TEXT, submit, print one
 *         structured SUBMIT line, exit 0 (no human needed)
 *     quickbar-hotkey <hotkey-spec> --ui-test-ack [CFG_JSON] TEXT
 *         like --ui-test (one SUBMIT line), then wait on stdin for
 *         SUBMIT_OK / SUBMIT_FAIL and report the resulting state on stderr: the
 *         automated proof for the sending/sent/error lifecycle.
 *     quickbar-hotkey <hotkey-spec> --interaction-test
 *         headless(ish) proof for toggle, draft preservation, Esc-cancel, the
 *         image-chip limit/removal and the visual constants: prints
 *         `INTERACTION ok: …` lines on stderr, exits 0 (3 on failure).
 *
 * Build:  native/build.sh  (clang -O2 -Wall -Wextra, two arch slices + lipo)
 *
 * Signal behaviour: SIGTERM/SIGINT unregister the hotkey, flush and exit 0.
 * SIGPIPE is ignored so a dead host pipe cannot kill the helper unexpectedly.
 */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include <Carbon/Carbon.h>
#include <CoreGraphics/CoreGraphics.h>

#include <ctype.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Four-char-code signature for our EventHotKeyID: 'QbHK'. */
#define QB_SIGNATURE ((OSType)0x5162484B)
#define QB_HOTKEY_ID ((UInt32)1)

/* Exit codes from the shared contract. */
enum {
    QB_EXIT_OK = 0,
    QB_EXIT_INVALID_SPEC = 2,
    QB_EXIT_ERROR = 3,
};

/* ------------------------------------------------------------------------- */
/* Visual constants — keep in sync with native/DESIGN.md (authoritative).     */
/* ------------------------------------------------------------------------- */

/* Card geometry (points). */
static const CGFloat kQBCardWidth = 640.0;
static const CGFloat kQBCardCornerRadius = 16.0;
static const CGFloat kQBHorizontalInset = 20.0;
static const CGFloat kQBVerticalInset = 16.0;
static const CGFloat kQBSectionGap = 12.0;
static const CGFloat kQBToolbarHeight = 26.0;
static const CGFloat kQBInputMinHeight = 44.0;
static const NSUInteger kQBInputMaxLines = 5;
static const CGFloat kQBFooterHeight = 26.0;
static const CGFloat kQBImageChipSize = 72.0;
static const CGFloat kQBImageChipCornerRadius = 8.0;
static const CGFloat kQBImageChipGap = 8.0;
static const CGFloat kQBImageStripGap = 8.0;
static const CGFloat kQBErrorGap = 8.0;
static const CGFloat kQBErrorHeight = 17.0;
static const CGFloat kQBSendButtonWidth = 62.0;
static const CGFloat kQBSendButtonHeight = 26.0;
static const CGFloat kQBMinCardWidth = 400.0;
static const CGFloat kQBToolbarWidgetGap = 10.0;
static const CGFloat kQBInputContainerInsetX = 4.0;
static const CGFloat kQBInputContainerInsetY = 2.0;

/* Fixed type scale (no fluid sizes; DESIGN.md §4). */
static const CGFloat kQBInputFontSize = 13.0;
/* Grace period before a lost key window closes the palette: transient focus
 * grabs (IME candidates, clipboard pickers) hand focus back within it. */
static const NSTimeInterval kBQResignHideDelay = 0.35;
static const CGFloat kQBControlFontSize = 13.0;
static const CGFloat kQBHintFontSize = 11.5;
static const CGFloat kQBSmallLabelFontSize = 11.0;
static const CGFloat kQBSendFontSize = 13.0;
static const CGFloat kQBErrorFontSize = 13.0;
static const CGFloat kQBInputLineSpacing = 2.0;

/* Motion budget (milliseconds) — motion only expresses state, never > 250 ms. */
enum {
    kQBOpenDurationMs = 180,
    kQBCloseDurationMs = 120,
    kQBSentHoldMs = 150,
};
_Static_assert(kQBOpenDurationMs <= 250 && kQBCloseDurationMs <= 250 &&
                   kQBSentHoldMs <= 250,
               "all motion must stay at or below 250 ms");

/* Behaviour. */
static const NSUInteger kQBMaxImages = 4;
static const NSTimeInterval kQBAckTimeoutDefault = 15.0;
static NSString *const kQBOriginDefaultsKey = @"quickbar.popup.origin";
static const char *const kQBAckTimeoutEnv = "QUICKBAR_ACK_TIMEOUT_MS";

/* Runtime state (all Carbon/Foundation calls happen on the main thread). */
static EventHotKeyRef gHotKeyRef = NULL;
static EventHandlerRef gHandlerRef = NULL;
static CFRunLoopTimerRef gQuitTimer = NULL;
static volatile sig_atomic_t gQuitRequested = 0;
static volatile sig_atomic_t gTimerInstalled = 0;
static volatile sig_atomic_t gTriggerCount = 0;
static volatile sig_atomic_t gSubmitEmitCount = 0;

/* --selftest: synthesize the event but never build/show UI. */
static int gSelftest = 0;

/* Automated modes: share the "finished" flag with the controller. */
enum {
    QBAutomatedNone = 0,
    QBAutomatedUiTest = 1 << 0,
    QBAutomatedUiTestAck = 1 << 1,
    QBAutomatedInteraction = 1 << 2,
};
static volatile sig_atomic_t gTestFinished = 0;
static char gTestDiag[1024];

@class QBController;
static QBController *gController = nil;

/* ------------------------------------------------------------------------- */
/* Generic helpers                                                            */
/* ------------------------------------------------------------------------- */

static NSString *qb_nonempty_string(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        return string.length > 0 ? string : nil;
    }
    return nil;
}

static NSString *qb_trimmed_string(NSString *value) {
    if (value == nil) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* Single-line diagnostic helpers must never leak a newline into the protocol. */
static NSString *qb_single_line(NSString *value, NSUInteger limit) {
    NSString *line;
    if (value == nil) {
        return @"";
    }
    line = [[value componentsSeparatedByCharactersInSet:
                        [NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (line.length > limit) {
        line = [[line substringToIndex:limit] stringByAppendingString:@"…"];
    }
    return line;
}

static void qb_test_finish(const char *diag) {
    snprintf(gTestDiag, sizeof gTestDiag, "%s", diag != NULL ? diag : "");
    gTestFinished = 1;
}

/* Spin the main run loop so animations / dispatch_after / NSTimer can run. */
static void qb_spin_runloop(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
    }
}

/* ------------------------------------------------------------------------- */
/* Output helpers — stdout is the protocol channel and must always be flushed. */
/* ------------------------------------------------------------------------- */

static void qb_emit(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

static void qb_error(const char *code, const char *fmt, ...) {
    va_list ap;
    fprintf(stdout, "ERROR %s", code);
    if (fmt != NULL && *fmt != '\0') {
        fputc(' ', stdout);
        va_start(ap, fmt);
        vfprintf(stdout, fmt, ap);
        va_end(ap);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

/*
 * Structured protocol payloads (SUBMIT) carry compact JSON as standard base64
 * of its UTF-8 bytes: one line, no spaces (padding '=' is fine).
 */
static void qb_emit_payload(const char *tag, NSDictionary *payload) {
    NSError *error = nil;
    NSData *json;
    NSString *encoded;

    if (![NSJSONSerialization isValidJSONObject:payload]) {
        qb_error("submit-failed", "payload is not valid JSON");
        return;
    }
    json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil) {
        qb_error("submit-failed", "could not encode JSON payload");
        return;
    }
    encoded = [json base64EncodedStringWithOptions:0];
    qb_emit("%s %s", tag, encoded != nil ? [encoded UTF8String] : "");
    if (strcmp(tag, "SUBMIT") == 0) {
        gSubmitEmitCount++;
    }
}

/* ------------------------------------------------------------------------- */
/* Time / cleanup / signal plumbing                                           */
/* ------------------------------------------------------------------------- */

static long long qb_epoch_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return (long long)time(NULL) * 1000LL;
    }
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000L);
}

static void qb_cleanup(void) {
    if (gQuitTimer != NULL) {
        CFRunLoopTimerInvalidate(gQuitTimer);
        CFRelease(gQuitTimer);
        gQuitTimer = NULL;
        gTimerInstalled = 0;
    }
    if (gHotKeyRef != NULL) {
        UnregisterEventHotKey(gHotKeyRef);
        gHotKeyRef = NULL;
    }
    if (gHandlerRef != NULL) {
        RemoveEventHandler(gHandlerRef);
        gHandlerRef = NULL;
    }
}

/* ------------------------------------------------------------------------- */
/* CFG / JSON parsing                                                         */
/* ------------------------------------------------------------------------- */

static NSDictionary *qb_json_object_from_data(NSData *data) {
    id object;
    if (data == nil) {
        return nil;
    }
    object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:[NSDictionary class]] ? (NSDictionary *)object : nil;
}

static NSDictionary *qb_parse_config_base64(NSString *base64) {
    NSData *data;
    NSDictionary *config;
    if (![base64 isKindOfClass:[NSString class]]) {
        return nil;
    }
    data = [[NSData alloc] initWithBase64EncodedString:base64
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data == nil) {
        return nil;
    }
    config = qb_json_object_from_data(data);
    [data release];
    return config;
}

/*
 * Accepts either raw JSON (starts with '{') or base64-encoded JSON; used by
 * --ui-test so the picker population can be proved without the host.
 */
static NSDictionary *qb_parse_config_argument(const char *utf8) {
    NSString *string;
    NSString *trimmed;

    if (utf8 == NULL) {
        return nil;
    }
    string = [NSString stringWithUTF8String:utf8];
    if (string == nil) {
        return nil;
    }
    trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }
    if ([trimmed hasPrefix:@"{"]) {
        return qb_json_object_from_data([trimmed dataUsingEncoding:NSUTF8StringEncoding]);
    }
    return qb_parse_config_base64(trimmed);
}

/* ------------------------------------------------------------------------- */
/* Screen / appearance helpers                                                */
/* ------------------------------------------------------------------------- */

static unsigned int qb_display_id_for_screen(NSScreen *screen) {
    NSDictionary *description;
    NSNumber *number;
    if (screen == nil) {
        return 0;
    }
    description = [screen deviceDescription];
    number = description != nil ? [description objectForKey:@"NSScreenNumber"] : nil;
    return [number isKindOfClass:[NSNumber class]] ? [number unsignedIntValue] : 0;
}

static NSScreen *qb_screen_for_display_id(unsigned int displayId) {
    for (NSScreen *screen in [NSScreen screens]) {
        if (qb_display_id_for_screen(screen) == displayId) {
            return screen;
        }
    }
    return nil;
}

static NSScreen *qb_screen_under_mouse(void) {
    NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(mouse, [screen frame])) {
            return screen;
        }
    }
    {
        NSScreen *mainScreen = [NSScreen mainScreen];
        if (mainScreen != nil) {
            return mainScreen;
        }
    }
    return [[NSScreen screens] firstObject];
}

/* ------------------------------------------------------------------------- */
/* Pasteboard / image helpers                                                 */
/* ------------------------------------------------------------------------- */

static BOOL qb_pasteboard_has_image(NSPasteboard *pasteboard) {
    NSArray *types;
    if (pasteboard == nil) {
        return NO;
    }
    types = [pasteboard types];
    if ([types containsObject:NSPasteboardTypePNG] ||
        [types containsObject:NSPasteboardTypeTIFF] ||
        [types containsObject:@"public.jpeg"]) {
        return YES;
    }
    return NO;
}

static BOOL qb_pasteboard_has_file_urls(NSPasteboard *pasteboard) {
    NSArray *types = pasteboard != nil ? [pasteboard types] : nil;
    return [types containsObject:NSPasteboardTypeFileURL] ||
           [types containsObject:@"NSFilenamesPboardType"];
}

/* The single image on the pasteboard, if there is one (never a file). */
static NSImage *qb_pasteboard_image(NSPasteboard *pasteboard) {
    NSImage *image;
    if (!qb_pasteboard_has_image(pasteboard)) {
        return nil;
    }
    image = [[NSImage alloc] initWithPasteboard:pasteboard];
    return [image autorelease];
}

/*
 * Encode one pasted image for the SUBMIT payload:
 * {mediaType, base64, name, width, height}. PNG when reasonable, JPEG when the
 * PNG would be huge (screenshots), so one clipboard image stays a few hundred
 * kilobytes in the protocol line.
 */
static NSDictionary *qb_image_payload(NSImage *image, NSUInteger ordinal) {
    NSBitmapImageRep *rep = nil;
    NSData *tiff;
    NSData *data;
    NSString *mediaType = @"image/png";
    NSString *extension = @"png";
    NSDictionary *payload;

    if (image == nil) {
        return nil;
    }
    tiff = [image TIFFRepresentation];
    if (tiff != nil) {
        rep = [NSBitmapImageRep imageRepWithData:tiff];
    }
    if (rep == nil) {
        NSArray *representations = [image representations];
        rep = [representations count] > 0 ? [representations objectAtIndex:0] : nil;
        if (![rep isKindOfClass:[NSBitmapImageRep class]]) {
            rep = nil;
        }
    }
    if (rep == nil) {
        return nil;
    }

    data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:[NSDictionary dictionary]];
    if (data == nil || data.length > 3 * 1024 * 1024) {
        NSData *jpeg = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                         properties:[NSDictionary dictionaryWithObject:@0.85
                                                                               forKey:NSImageCompressionFactor]];
        if (jpeg != nil && (data == nil || jpeg.length < data.length)) {
            data = jpeg;
            mediaType = @"image/jpeg";
            extension = @"jpg";
        }
    }
    if (data == nil || data.length == 0) {
        return nil;
    }

    payload = [NSDictionary dictionaryWithObjectsAndKeys:
                mediaType, @"mediaType",
                [data base64EncodedStringWithOptions:0], @"base64",
                [NSString stringWithFormat:@"pasted-image-%lu.%@", (unsigned long)ordinal, extension], @"name",
                [NSNumber numberWithInteger:rep.pixelsWide], @"width",
                [NSNumber numberWithInteger:rep.pixelsHigh], @"height",
                nil];
    return payload;
}

/* ------------------------------------------------------------------------- */
/* Custom UI classes                                                          */
/* ------------------------------------------------------------------------- */

/* Borderless panels cannot become key by default; the text view needs key. */
@interface QBPanel : NSPanel
@end

/* A pill selector container: rounded fill + hover, children laid out by hand. */
@interface QBPillView : NSView {
    BOOL _hovered;
}
@end

/* One 56x56 rounded image thumbnail with a hover-only remove button. */
@interface QBChipView : NSView {
    NSImage *_image;
    NSButton *_removeButton;
    BOOL _hovered;
}
- (instancetype)initWithImage:(NSImage *)image;
- (void)setRemoveTarget:(id)target action:(SEL)action;
@end

typedef NS_ENUM(NSInteger, QBSendState) {
    QBSendStateDisabled = 0,
    QBSendStateNormal,
    QBSendStateSending,
    QBSendStateSent,
};

/* Accent pill: disabled / normal / sending spinner / sent checkmark. */
@interface QBSendButton : NSButton {
    QBSendState _sendState;
    NSTimer *_spinnerTimer;
    CGFloat _spinnerAngle;
    BOOL _hovered;
}
- (void)setSendState:(QBSendState)state;
- (QBSendState)sendState;
@end

/* Input row container: the darker field fill + placeholder live here (behind the
 * transparent text view). */
@interface QBInputContainer : NSView {
    BOOL _focused;
    BOOL _showsPlaceholder;
}
- (void)setFocused:(BOOL)focused;
- (void)setShowsPlaceholder:(BOOL)shows;
@end

/* NSTextView that owns Enter/Shift+Enter/Escape and Cmd+V image paste. */
@interface QBPasteTextView : NSTextView {
    QBController *_owningController; /* not retained: the controller owns us */
}
- (void)setOwningController:(QBController *)controller;
@end

/* ------------------------------------------------------------------------- */
/* Controller                                                                 */
/* ------------------------------------------------------------------------- */

@interface QBController : NSObject <NSTextViewDelegate, NSMenuDelegate, NSWindowDelegate> {
    QBPanel *_panel;
    NSVisualEffectView *_cardView;
    QBInputContainer *_inputContainer;
    NSScrollView *_inputScroll;
    QBPasteTextView *_textView;
    NSPopUpButton *_workspacePopup;
    NSPopUpButton *_modelPopup;
    NSPopUpButton *_effortPopup;
    QBPillView *_workspacePill;
    QBPillView *_modelPill;
    QBPillView *_effortPill;
    NSTextField *_workspaceTag;
    NSTextField *_modelTag;
    NSTextField *_effortTag;
    NSImageView *_workspaceChevron;
    NSImageView *_modelChevron;
    NSImageView *_effortChevron;
    NSControl *_footerLeft;   /* label or borderless paste button */
    NSTextField *_footerRight;
    NSTextField *_errorLabel;
    NSView *_separator;
    QBSendButton *_sendButton;
    NSMutableArray *_imageChips;   /* QBChipView */
    NSMutableArray *_images;       /* NSMutableDictionary: payload + NSImage */
    NSDictionary *_config;         /* last CFG object (retained) */
    NSArray *_modelEntries;        /* flattened provider/model entries (retained) */
    NSTimer *_ackTimer;
    NSTimer *_resignHideTimer;
    NSTimer *_transientErrorTimer;
    NSString *_errorText;
    CGFloat _cardWidth;
    CGFloat _panelTop;
    CGFloat _inputHeight;
    NSUInteger _showGeneration;
    QBSendState _sendState;
    BOOL _built;
    BOOL _panelVisible;
    BOOL _panelBecameKeyThisShow;
    BOOL _menuTracking;
    BOOL _suppressMoveSave;
    BOOL _skipActivation;
    BOOL _uiTestMode;
    BOOL _uiTestAckMode;
    BOOL _interactionTestMode;
    NSInteger _interactionFailures;
}
- (void)buildUI;
- (void)showPanel;
- (void)hidePanelClearing:(BOOL)clearDraft notifyCancel:(BOOL)notifyCancel;
- (void)togglePanel;
- (void)submitCurrentText;
- (void)cancel;
- (void)setFieldText:(NSString *)text;
- (void)applyConfig:(NSDictionary *)config;
- (void)handleSubmitOk;
- (void)handleSubmitFail:(NSString *)message;
- (BOOL)pasteFromPasteboard:(NSPasteboard *)pasteboard;
- (void)setAutomatedMode:(NSUInteger)mode;
- (int)runInteractionChecks;
- (void)cancelResignHide;
- (void)resignHideTimerFired:(NSTimer *)timer;
@end

@interface QBController ()
- (void)buildCardContent;
- (void)buildPillInto:(QBPillView **)pillOut
                  tag:(NSTextField **)tagOut
                popup:(NSPopUpButton **)popupOut
              chevron:(NSImageView **)chevronOut
             tagTitle:(NSString *)tagTitle
            placeholder:(NSString *)placeholder;
- (void)configurePopup:(NSPopUpButton *)popup placeholder:(NSString *)placeholder;
- (void)rebuildWorkspaceMenu;
- (void)rebuildModelMenu;
- (void)rebuildEffortMenuWithDesiredEffort:(NSString *)desiredEffort;
- (void)modelSelectionChanged:(id)sender;
- (NSDictionary *)configSelection;
- (NSDictionary *)selectedModelEntry;
- (NSString *)selectedWorkspaceId;
- (NSString *)selectedProviderId;
- (NSString *)selectedModelId;
- (NSString *)selectedEffortId;
- (CGFloat)cardWidthForScreen:(NSScreen *)screen;
- (NSRect)cardFrameForScreen:(NSScreen *)screen cardSize:(NSSize)size;
- (NSScreen *)targetScreenForShow;
- (void)saveOriginToDefaults;
- (BOOL)loadSavedOrigin:(NSPoint *)originOut displayId:(unsigned int *)displayOut;
- (CGFloat)maxInputHeight;
- (CGFloat)rawTextHeight;
- (CGFloat)desiredCardHeight;
- (void)layoutContent;
- (void)layoutToolbarRowAtY:(CGFloat)y width:(CGFloat)innerWidth;
- (void)layoutPill:(QBPillView *)pill
               tag:(NSTextField *)tag
             popup:(NSPopUpButton *)popup
           chevron:(NSImageView *)chevron;
- (void)updateSendButtonState;
- (void)setInputFocused:(BOOL)focused;
- (void)invalidateTransientErrorTimer;
- (void)clearContent;
- (NSString *)currentText;
- (BOOL)hasTextContent;
- (NSDictionary *)currentSubmitPayload;
- (void)startAckTimer;
- (void)stopAckTimer;
- (void)ackTimerFired:(NSTimer *)timer;
- (void)beginSending;
- (void)failSendingWithMessage:(NSString *)message diag:(NSString *)diag;
- (void)failAfterTimeout;
- (void)showError:(NSString *)message persistent:(BOOL)persistent;
- (void)showHint:(NSString *)message;
- (void)pasteButtonClicked:(id)sender;
- (NSString *)footerLeftText;
- (void)clearError;
- (void)transientErrorTimerFired:(NSTimer *)timer;
- (void)addChipView:(QBChipView *)chip;
- (void)removeChipClicked:(NSButton *)sender;
- (void)removeImageAtIndex:(NSUInteger)index;
- (void)relayoutImageChipsWithTop:(CGFloat)top;
- (void)sendButtonClicked:(id)sender;
- (void)simulateKeyDown:(unsigned short)keyCode modifiers:(NSEventModifierFlags)flags;
- (void)logInteraction:(BOOL)ok format:(NSString *)format, ...;
- (void)appendInteractionFailure:(NSString *)message;
@end

/* ------------------------------------------------------------------------- */
/* QBPanel                                                                    */
/* ------------------------------------------------------------------------- */

@implementation QBPanel
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end

/* ------------------------------------------------------------------------- */
/* QBPillView                                                                 */
/* ------------------------------------------------------------------------- */

@implementation QBPillView
- (BOOL)isOpaque {
    return NO;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self trackingAreas]) {
        [self removeTrackingArea:area];
    }
    {
        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                         NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];
        [area release];
    }
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    [self setNeedsDisplay:YES];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path;
    NSColor *fill;
    (void)dirtyRect;
    path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                            xRadius:NSHeight(self.bounds) / 2.0
                                            yRadius:NSHeight(self.bounds) / 2.0];
    /* Subtle neutral pill fill: 8% at rest, 12% on hover (DESIGN §5.1). */
    fill = [[NSColor labelColor] colorWithAlphaComponent:_hovered ? 0.12 : 0.08];
    [fill setFill];
    [path fill];
}
@end

/* ------------------------------------------------------------------------- */
/* QBChipView                                                                 */
/* ------------------------------------------------------------------------- */

@implementation QBChipView

- (instancetype)initWithImage:(NSImage *)image {
    self = [super initWithFrame:NSMakeRect(0, 0, kQBImageChipSize, kQBImageChipSize)];
    if (self != nil) {
        _image = [image retain];
        _removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(kQBImageChipSize - 20.0, 4.0, 16.0, 16.0)];
        [_removeButton setBordered:NO];
        [_removeButton setButtonType:NSButtonTypeMomentaryChange];
        [_removeButton setFocusRingType:NSFocusRingTypeNone];
        [_removeButton setImagePosition:NSImageOnly];
        [_removeButton setTitle:@""];
        {
            NSImage *symbol = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                                        accessibilityDescription:@"移除图片"];
            if (symbol != nil) {
                [_removeButton setImage:symbol];
                [_removeButton setContentTintColor:[NSColor labelColor]];
            } else {
                [_removeButton setTitle:@"×"];
                [_removeButton setFont:[NSFont systemFontOfSize:12.0]];
            }
        }
        [_removeButton setHidden:YES];
        [self addSubview:_removeButton];
    }
    return self;
}

- (void)dealloc {
    [_image release];
    [_removeButton release];
    [super dealloc];
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setRemoveTarget:(id)target action:(SEL)action {
    [_removeButton setTarget:target];
    [_removeButton setAction:action];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self trackingAreas]) {
        [self removeTrackingArea:area];
    }
    {
        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                         NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];
        [area release];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [_removeButton setHidden:NO];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    [_removeButton setHidden:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *clip;
    NSRect bounds = self.bounds;
    (void)dirtyRect;
    clip = [NSBezierPath bezierPathWithRoundedRect:bounds
                                           xRadius:kQBImageChipCornerRadius
                                           yRadius:kQBImageChipCornerRadius];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [[[NSColor blackColor] colorWithAlphaComponent:0.18] setFill];
    NSRectFill(bounds);
    if (_image != nil) {
        NSSize imageSize = [_image size];
        if (imageSize.width > 0.0 && imageSize.height > 0.0) {
            CGFloat scale = MIN(NSWidth(bounds) / imageSize.width,
                                NSHeight(bounds) / imageSize.height);
            NSSize drawSize = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
            NSRect destination = NSMakeRect((NSWidth(bounds) - drawSize.width) / 2.0,
                                            (NSHeight(bounds) - drawSize.height) / 2.0,
                                            drawSize.width, drawSize.height);
            [_image drawInRect:destination
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:[NSDictionary dictionaryWithObject:@(NSImageInterpolationHigh)
                                                            forKey:NSImageHintInterpolation]];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    {
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                               xRadius:kQBImageChipCornerRadius
                                                               yRadius:kQBImageChipCornerRadius];
        [border setLineWidth:1.0];
        [[[NSColor separatorColor] colorWithAlphaComponent:0.45] setStroke];
        [border stroke];
    }
}
@end

/* ------------------------------------------------------------------------- */
/* QBSendButton                                                               */
/* ------------------------------------------------------------------------- */

@implementation QBSendButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        _sendState = QBSendStateDisabled;
        [self setBordered:NO];
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self setFocusRingType:NSFocusRingTypeNone];
        [self setTitle:@""];
        [self setImagePosition:NSNoImage];
        [self setEnabled:NO];
    }
    return self;
}

- (void)dealloc {
    [_spinnerTimer invalidate];
    [_spinnerTimer release];
    [super dealloc];
}

- (BOOL)isOpaque {
    return NO;
}

- (QBSendState)sendState {
    return _sendState;
}

- (void)advanceSpinner:(NSTimer *)timer {
    (void)timer;
    _spinnerAngle += 0.42;
    if (_spinnerAngle > 6.283185307179586) {
        _spinnerAngle -= 6.283185307179586;
    }
    [self setNeedsDisplay:YES];
}

- (void)startSpinner {
    if (_spinnerTimer != nil) {
        return;
    }
    _spinnerAngle = 0.0;
    _spinnerTimer = [[NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                     target:self
                                                   selector:@selector(advanceSpinner:)
                                                   userInfo:nil
                                                    repeats:YES] retain];
}

- (void)stopSpinner {
    if (_spinnerTimer != nil) {
        [_spinnerTimer invalidate];
        [_spinnerTimer release];
        _spinnerTimer = nil;
    }
}

- (void)drawSpinnerInRect:(NSRect)rect {
    NSColor *tint = [NSColor alternateSelectedControlTextColor];
    CGFloat centerX = NSMidX(rect);
    CGFloat centerY = NSMidY(rect);
    CGFloat radius = MIN(NSWidth(rect), NSHeight(rect)) / 2.0;
    NSUInteger index;
    NSUInteger segments = 8;
    [NSGraphicsContext saveGraphicsState];
    for (index = 0; index < segments; index++) {
        CGFloat fraction = (CGFloat)index / (CGFloat)segments;
        CGFloat angle = _spinnerAngle + fraction * 6.283185307179586;
        CGFloat alpha = 0.18 + 0.82 * fraction;
        NSBezierPath *dot;
        CGFloat dotRadius = MAX(1.0, radius * 0.18);
        CGFloat dotX = centerX + cos(angle) * (radius - dotRadius);
        CGFloat dotY = centerY + sin(angle) * (radius - dotRadius);
        [[tint colorWithAlphaComponent:alpha] setFill];
        dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotX - dotRadius,
                                                                 dotY - dotRadius,
                                                                 dotRadius * 2.0,
                                                                 dotRadius * 2.0)];
        [dot fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)setSendState:(QBSendState)state {
    if (_sendState == state) {
        return;
    }
    _sendState = state;
    if (state == QBSendStateSending) {
        [self startSpinner];
    } else {
        [self stopSpinner];
    }
    [self setEnabled:(state == QBSendStateNormal || state == QBSendStateSent)];
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self trackingAreas]) {
        [self removeTrackingArea:area];
    }
    {
        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                         NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
        [self addTrackingArea:area];
        [area release];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *pill;
    NSColor *fill = nil;
    (void)dirtyRect;

    if (NSWidth(bounds) <= 0.0 || NSHeight(bounds) <= 0.0) {
        return;
    }
    pill = [NSBezierPath bezierPathWithRoundedRect:bounds
                                           xRadius:NSHeight(bounds) / 2.0
                                           yRadius:NSHeight(bounds) / 2.0];

    switch (_sendState) {
        case QBSendStateDisabled:
            fill = [NSColor quaternaryLabelColor];
            break;
        case QBSendStateSent:
            fill = [NSColor systemGreenColor];
            break;
        case QBSendStateNormal:
        case QBSendStateSending:
        default:
            fill = [NSColor controlAccentColor];
            break;
    }
    [fill setFill];
    [pill fill];

    if (_hovered && _sendState == QBSendStateNormal) {
        [[[NSColor whiteColor] colorWithAlphaComponent:0.08] setFill];
        [pill fill];
    }
    if ([self isHighlighted] && _sendState != QBSendStateDisabled) {
        [[[NSColor blackColor] colorWithAlphaComponent:0.08] setFill];
        [pill fill];
    }

    if (_sendState == QBSendStateSent) {
        CGFloat centerX = NSMidX(bounds);
        CGFloat centerY = NSMidY(bounds);
        NSBezierPath *check = [NSBezierPath bezierPath];
        [check setLineWidth:2.0];
        [check setLineCapStyle:NSLineCapStyleRound];
        [check setLineJoinStyle:NSLineJoinStyleRound];
        [check moveToPoint:NSMakePoint(centerX - 5.0, centerY + 0.0)];
        [check lineToPoint:NSMakePoint(centerX - 1.5, centerY - 3.5)];
        [check lineToPoint:NSMakePoint(centerX + 5.0, centerY + 3.5)];
        [[NSColor alternateSelectedControlTextColor] setStroke];
        [check stroke];
        return;
    }
    if (_sendState == QBSendStateSending) {
        [self drawSpinnerInRect:NSMakeRect(floor(NSMidX(bounds) - 7.0),
                                           floor(NSMidY(bounds) - 7.0), 14.0, 14.0)];
        return;
    }

    {
        NSString *title = @"发送";
        NSColor *textColor = (_sendState == QBSendStateDisabled)
                                 ? [NSColor tertiaryLabelColor]
                                 : [NSColor alternateSelectedControlTextColor];
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        NSDictionary *attributes;
        NSSize textSize;

        [paragraph setAlignment:NSTextAlignmentCenter];
        attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                        [NSFont systemFontOfSize:kQBSendFontSize weight:NSFontWeightMedium],
                        NSFontAttributeName,
                        textColor, NSForegroundColorAttributeName,
                        paragraph, NSParagraphStyleAttributeName,
                        nil];
        [paragraph release];
        textSize = [title sizeWithAttributes:attributes];
        [title drawInRect:NSMakeRect(0.0, floor((NSHeight(bounds) - textSize.height) / 2.0),
                                     NSWidth(bounds), ceil(textSize.height))
           withAttributes:attributes];
    }
}
@end

/* ------------------------------------------------------------------------- */
/* QBInputContainer                                                           */
/* ------------------------------------------------------------------------- */

@implementation QBInputContainer

- (BOOL)isOpaque {
    return NO;
}

- (void)setFocused:(BOOL)focused {
    if (_focused == focused) {
        return;
    }
    _focused = focused;
    [self setNeedsDisplay:YES];
}

- (void)setShowsPlaceholder:(BOOL)shows {
    if (_showsPlaceholder == shows) {
        return;
    }
    _showsPlaceholder = shows;
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    (void)dirtyRect;

    /*
     * No stroke: the field is identified by a fill slightly darker than the
     * card; focus deepens it instead of adding a ring (DESIGN.md: one
     * elevation, no decorative borders).
     */
    {
        BOOL dark = [[self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
            isEqualToString:NSAppearanceNameDarkAqua];
        CGFloat alpha = dark ? 0.22 : 0.06;
        if (_focused) {
            alpha += dark ? 0.07 : 0.04;
        }
        {
            NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                                 xRadius:10.0
                                                                 yRadius:10.0];
            [[[NSColor blackColor] colorWithAlphaComponent:alpha] setFill];
            [fill fill];
        }
    }
    if (_showsPlaceholder) {
        NSFont *font = [NSFont systemFontOfSize:kQBInputFontSize];
        NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                        font, NSFontAttributeName,
                                        [NSColor placeholderTextColor],
                                        NSForegroundColorAttributeName,
                                        nil];
        CGFloat lineHeight = ceil([font ascender] - [font descender] + [font leading]);
        [@"输入问题，回车发送…" drawAtPoint:NSMakePoint(kQBInputContainerInsetX,
                                                     NSHeight(bounds) -
                                                         kQBInputContainerInsetY - lineHeight)
                          withAttributes:attributes];
    }
}
@end

/* ------------------------------------------------------------------------- */
/* QBPasteTextView                                                            */
/* ------------------------------------------------------------------------- */

@implementation QBPasteTextView

- (void)setOwningController:(QBController *)controller {
    _owningController = controller;
}

- (void)paste:(id)sender {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (_owningController != nil && [_owningController pasteFromPasteboard:pasteboard]) {
        return;
    }
    [super paste:sender];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars;

    if (flags == NSEventModifierFlagCommand) {
        chars = [[event charactersIgnoringModifiers] lowercaseString];
        if ([chars isEqualToString:@"v"]) {
            if (_owningController != nil &&
                [_owningController pasteFromPasteboard:[NSPasteboard generalPasteboard]]) {
                return YES;
            }
            [super paste:nil];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    unsigned short keyCode = [event keyCode];

    /* Enter / keypad Enter: send. Shift+Enter: newline. IME composition wins. */
    if ((keyCode == 36 || keyCode == 76) && ![self hasMarkedText]) {
        if (([event modifierFlags] & NSEventModifierFlagShift) != 0) {
            [self insertNewlineIgnoringFieldEditor:nil];
            return;
        }
        if (_owningController != nil) {
            [_owningController submitCurrentText];
        }
        return;
    }
    /* Escape: close and clear (no submit) — unless an IME composition is
       active, where Escape must cancel the composition instead. */
    if (keyCode == 53) {
        if ([self hasMarkedText]) {
            [super keyDown:event];
            return;
        }
        if (_owningController != nil) {
            [_owningController cancel];
        }
        return;
    }
    [super keyDown:event];
}
@end

/* ------------------------------------------------------------------------- */
/* Small helpers used by the controller                                       */
/* ------------------------------------------------------------------------- */

/*
 * The helper is a menu-bar-less accessory app, so standard editing shortcuts
 * (Cmd+V in particular) have no menu item to route them to the focused text
 * view. Install a minimal Edit menu: its key equivalents are still dispatched
 * to the key window's first responder even though an accessory app shows no
 * menu bar. Without this, Cmd+V did nothing in the palette.
 */
static void qb_install_edit_menu(void) {
    NSMenu *mainMenu;
    NSMenuItem *editItem;
    NSMenu *editMenu;
    NSArray *items;
    NSArray *specs;
    NSUInteger index;

    mainMenu = [[NSMenu alloc] initWithTitle:@""];
    editItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editItem setSubmenu:editMenu];
    [editMenu release];

    items = [NSArray arrayWithObjects:
                 [NSArray arrayWithObjects:@"Undo", @"undo:", @"z", @(NSEventModifierFlagCommand), nil],
                 [NSArray arrayWithObjects:@"Redo", @"redo:", @"Z", @(NSEventModifierFlagCommand | NSEventModifierFlagShift), nil],
                 [NSArray arrayWithObjects:@"Cut", @"cut:", @"x", @(NSEventModifierFlagCommand), nil],
                 [NSArray arrayWithObjects:@"Copy", @"copy:", @"c", @(NSEventModifierFlagCommand), nil],
                 [NSArray arrayWithObjects:@"Paste", @"paste:", @"v", @(NSEventModifierFlagCommand), nil],
                 [NSArray arrayWithObjects:@"Select All", @"selectAll:", @"a", @(NSEventModifierFlagCommand), nil],
                 nil];
    specs = items;
    for (index = 0; index < [specs count]; index++) {
        NSArray *spec = [specs objectAtIndex:index];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[spec objectAtIndex:0]
                                                      action:NSSelectorFromString([spec objectAtIndex:1])
                                               keyEquivalent:[spec objectAtIndex:2]];
        [item setKeyEquivalentModifierMask:[[spec objectAtIndex:3] unsignedIntegerValue]];
        [editMenu addItem:item];
        [item release];
    }
    [NSApp setMainMenu:mainMenu];
    [mainMenu release];
}

static NSMenu *qb_popup_menu(NSPopUpButton *popup) {
    NSMenu *menu = [popup menu];
    if (menu == nil) {
        menu = [[NSMenu alloc] initWithTitle:@""];
        [popup setMenu:menu];
        [menu release];
        menu = [popup menu];
    }
    [menu setAutoenablesItems:NO];
    return menu;
}

static void qb_popup_add_item(NSPopUpButton *popup, NSString *title, id represented) {
    NSMenuItem *item;
    if (title == nil) {
        title = @"";
    }
    qb_popup_menu(popup);
    item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    [item setRepresentedObject:represented];
    [[popup menu] addItem:item];
    [item release];
}

static void qb_popup_show_placeholder(NSPopUpButton *popup, NSString *title) {
    qb_popup_menu(popup);
    [popup removeAllItems];
    [popup addItemWithTitle:title];
    [popup selectItemAtIndex:0];
}

static NSTextField *qb_make_label(NSString *text, CGFloat fontSize, NSColor *color,
                                 NSTextAlignment alignment) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setStringValue:(text != nil ? text : @"")];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setFocusRingType:NSFocusRingTypeNone];
    [label setRefusesFirstResponder:YES];
    [label setFont:[NSFont systemFontOfSize:fontSize]];
    [label setTextColor:color];
    [label setAlignment:alignment];
    [label setLineBreakMode:NSLineBreakByClipping];
    [label setMaximumNumberOfLines:1];
    return label;
}

/* A single 1px separator line (semantic color, adapts to light/dark). */
@interface QBLineView : NSView
@end

@implementation QBLineView
- (BOOL)isOpaque {
    return NO;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[[NSColor separatorColor] colorWithAlphaComponent:0.12] setFill];
    NSRectFill(self.bounds);
}
@end

static NSImage *qb_make_test_image(void) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(40.0, 30.0)];
    [image lockFocus];
    [[NSColor systemBlueColor] setFill];
    NSRectFill(NSMakeRect(0.0, 0.0, 40.0, 30.0));
    [image unlockFocus];
    return [image autorelease];
}

/* ------------------------------------------------------------------------- */
/* QBController implementation                                                */
/* ------------------------------------------------------------------------- */

@implementation QBController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _imageChips = [[NSMutableArray alloc] init];
        _images = [[NSMutableArray alloc] init];
        _cardWidth = kQBCardWidth;
        _sendState = QBSendStateDisabled;
    }
    return self;
}

- (void)dealloc {
    [self stopAckTimer];
    [self invalidateTransientErrorTimer];
    [_panel release];
    [_cardView release];
    [_errorText release];
    [_errorLabel release];
    [_footerLeft release];
    [_footerRight release];
    [_separator release];
    [_imageChips release];
    [_images release];
    [_config release];
    [_modelEntries release];
    [_inputContainer release];
    [_inputScroll release];
    [_textView release];
    [_workspacePill release];
    [_modelPill release];
    [_effortPill release];
    [super dealloc];
}

/* ---- build -------------------------------------------------------------- */

- (CGFloat)cardWidthForScreen:(NSScreen *)screen {
    NSRect visible = screen != nil ? [screen visibleFrame] : NSZeroRect;
    CGFloat available = NSWidth(visible) - 96.0;
    CGFloat width = kQBCardWidth;
    if (available > 0.0 && width > available) {
        width = available;
    }
    if (width < kQBMinCardWidth) {
        width = kQBMinCardWidth;
    }
    if (available > 0.0 && width > NSWidth(visible)) {
        width = NSWidth(visible);
    }
    if (width < 320.0) {
        width = 320.0;
    }
    return floor(width);
}

- (BOOL)loadSavedOrigin:(NSPoint *)originOut displayId:(unsigned int *)displayOut {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kQBOriginDefaultsKey];
    const char *utf8;
    double x = 0.0;
    double y = 0.0;
    unsigned int display = 0;

    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    utf8 = [value UTF8String];
    if (utf8 == NULL) {
        return NO;
    }
    if (sscanf(utf8, "%lf,%lf,%u", &x, &y, &display) != 3) {
        return NO;
    }
    if (originOut != NULL) {
        *originOut = NSMakePoint((CGFloat)x, (CGFloat)y);
    }
    if (displayOut != NULL) {
        *displayOut = display;
    }
    return YES;
}

- (void)saveOriginToDefaults {
    NSRect frame;
    NSScreen *screen;
    NSString *value;
    unsigned int displayId;

    if (_panel == nil) {
        return;
    }
    frame = [_panel frame];
    screen = [_panel screen];
    displayId = qb_display_id_for_screen(screen);
    value = [NSString stringWithFormat:@"%.2f,%.2f,%u", NSMinX(frame), NSMinY(frame), displayId];
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kQBOriginDefaultsKey];
}

- (NSScreen *)targetScreenForShow {
    NSPoint saved = NSZeroPoint;
    unsigned int display = 0;
    if ([self loadSavedOrigin:&saved displayId:&display]) {
        NSScreen *screen = qb_screen_for_display_id(display);
        if (screen != nil) {
            return screen;
        }
    }
    return qb_screen_under_mouse();
}

- (NSRect)cardFrameForScreen:(NSScreen *)screen cardSize:(NSSize)size {
    NSRect visible = screen != nil ? [screen visibleFrame] : NSMakeRect(0, 0, 1280, 800);
    NSPoint saved = NSZeroPoint;
    unsigned int savedDisplay = 0;
    BOOL hasSaved = [self loadSavedOrigin:&saved displayId:&savedDisplay];
    CGFloat width = size.width;
    CGFloat height = size.height;
    CGFloat x;
    CGFloat y;

    if (hasSaved && savedDisplay == qb_display_id_for_screen(screen)) {
        CGFloat minX = NSMinX(visible);
        CGFloat maxX = NSMaxX(visible) - width;
        CGFloat minY = NSMinY(visible);
        CGFloat maxY = NSMaxY(visible) - height;
        x = saved.x;
        y = saved.y;
        if (x < minX) {
            x = minX;
        }
        if (x > maxX) {
            x = maxX;
        }
        if (y < minY) {
            y = minY;
        }
        if (y > maxY) {
            y = maxY;
        }
        return NSMakeRect(floor(x), floor(y), width, height);
    }

    /* No saved position (or that display is gone): centered in the top third. */
    x = NSMinX(visible) + (NSWidth(visible) - width) / 2.0;
    y = NSMinY(visible) + NSHeight(visible) * (5.0 / 6.0) - height / 2.0;
    if (y > NSMaxY(visible) - height) {
        y = NSMaxY(visible) - height;
    }
    if (y < NSMinY(visible)) {
        y = NSMinY(visible);
    }
    return NSMakeRect(floor(x), floor(y), width, height);
}

- (void)configurePopup:(NSPopUpButton *)popup placeholder:(NSString *)placeholder {
    NSPopUpButtonCell *cell;
    NSMenu *menu;

    [popup setFont:[NSFont systemFontOfSize:kQBControlFontSize weight:NSFontWeightMedium]];
    [popup setBordered:NO];
    [popup setFocusRingType:NSFocusRingTypeNone];
    [popup setAutoresizingMask:NSViewNotSizable];
    cell = (NSPopUpButtonCell *)[popup cell];
    if ([cell isKindOfClass:[NSPopUpButtonCell class]]) {
        [cell setArrowPosition:NSPopUpNoArrow];
        [cell setAlignment:NSTextAlignmentLeft];
        [cell setLineBreakMode:NSLineBreakByTruncatingTail];
    }
    menu = qb_popup_menu(popup);
    [menu setDelegate:self];
    [popup removeAllItems];
    [popup addItemWithTitle:placeholder];
    [popup selectItemAtIndex:0];
}

- (void)buildPillInto:(QBPillView **)pillOut
                  tag:(NSTextField **)tagOut
                popup:(NSPopUpButton **)popupOut
              chevron:(NSImageView **)chevronOut
             tagTitle:(NSString *)tagTitle
          placeholder:(NSString *)placeholder {
    QBPillView *pill = [[QBPillView alloc] initWithFrame:NSZeroRect];
    NSTextField *tag = qb_make_label(tagTitle, kQBSmallLabelFontSize, [NSColor secondaryLabelColor],
                                     NSTextAlignmentLeft);
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSImageView *chevron = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"chevron.down"
                                accessibilityDescription:@"展开菜单"];

    [self configurePopup:popup placeholder:placeholder];
    if (symbol != nil) {
        NSImageSymbolConfiguration *configuration =
            [NSImageSymbolConfiguration configurationWithPointSize:8.0 weight:NSFontWeightSemibold];
        NSImage *sized = [symbol imageWithSymbolConfiguration:configuration];
        [chevron setImage:(sized != nil ? sized : symbol)];
    }
    [chevron setContentTintColor:[NSColor secondaryLabelColor]];
    [chevron setImageScaling:NSImageScaleProportionallyDown];
    [pill addSubview:tag];
    [pill addSubview:popup];
    [pill addSubview:chevron];
    [tag release];
    [popup release];
    [chevron release];
    *pillOut = pill;
    *tagOut = tag;
    *popupOut = popup;
    *chevronOut = chevron;
}

- (void)buildCardContent {
    QBInputContainer *container;
    NSScrollView *scroll;
    QBPasteTextView *textView;
    NSTextField *errorLabel;
    QBLineView *separator;
    NSTextField *footerRight;
    QBSendButton *sendButton;
    NSMutableParagraphStyle *paragraph;
    NSFont *inputFont;

    _cardView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, _cardWidth, 160.0)];
    [_cardView setMaterial:NSVisualEffectMaterialPopover];
    [_cardView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
    [_cardView setState:NSVisualEffectStateActive];
    [_cardView setWantsLayer:YES];
    [[_cardView layer] setCornerRadius:kQBCardCornerRadius];
    [[_cardView layer] setMasksToBounds:YES];
    [_cardView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_panel setContentView:_cardView];

    [self buildPillInto:&_workspacePill
                    tag:&_workspaceTag
                  popup:&_workspacePopup
                chevron:&_workspaceChevron
               tagTitle:@"工作区"
            placeholder:@"工作区"];
    [_cardView addSubview:_workspacePill];

    [self buildPillInto:&_modelPill
                    tag:&_modelTag
                  popup:&_modelPopup
                chevron:&_modelChevron
               tagTitle:@"模型"
            placeholder:@"模型"];
    [_modelPopup setTarget:self];
    [_modelPopup setAction:@selector(modelSelectionChanged:)];
    [_cardView addSubview:_modelPill];

    [self buildPillInto:&_effortPill
                    tag:&_effortTag
                  popup:&_effortPopup
                chevron:&_effortChevron
               tagTitle:@"思考"
            placeholder:@"推理强度"];
    [_cardView addSubview:_effortPill];

    /* Multi-line input: scroll view + transparent, plain-text NSTextView. */
    container = [[QBInputContainer alloc] initWithFrame:NSZeroRect];
    [container setShowsPlaceholder:YES];
    _inputContainer = container;
    [_cardView addSubview:container];

    scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [scroll setDrawsBackground:NO];
    [scroll setBorderType:NSNoBorder];
    [scroll setHasVerticalScroller:NO];
    [scroll setAutohidesScrollers:YES];
    [scroll setScrollerStyle:NSScrollerStyleOverlay];
    [scroll setVerticalScrollElasticity:NSScrollElasticityNone];
    [scroll setHorizontalScrollElasticity:NSScrollElasticityNone];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [[scroll contentView] setDrawsBackground:NO];
    _inputScroll = scroll;

    textView = [[QBPasteTextView alloc] initWithFrame:NSMakeRect(0, 0, 100.0, 40.0)];
    [textView setOwningController:self];
    [textView setDelegate:self];
    [textView setRichText:NO];
    [textView setImportsGraphics:NO];
    [textView setDrawsBackground:NO];
    [textView setEditable:YES];
    [textView setSelectable:YES];
    [textView setAllowsUndo:YES];
    [textView setUsesFindBar:NO];
    [textView setVerticallyResizable:YES];
    [textView setHorizontallyResizable:NO];
    [textView setMinSize:NSMakeSize(0.0, 0.0)];
    [textView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    [textView setAutoresizingMask:NSViewWidthSizable];
    [textView setTextContainerInset:NSMakeSize(0.0, kQBInputContainerInsetY)];
    [[textView textContainer] setWidthTracksTextView:YES];
    [[textView textContainer] setLineFragmentPadding:0.0];
    [textView setContinuousSpellCheckingEnabled:NO];
    [textView setGrammarCheckingEnabled:NO];
    [textView setAutomaticSpellingCorrectionEnabled:NO];
    [textView setAutomaticQuoteSubstitutionEnabled:NO];
    [textView setAutomaticDashSubstitutionEnabled:NO];
    [textView setAutomaticTextReplacementEnabled:NO];
    [textView setSmartInsertDeleteEnabled:NO];
    inputFont = [NSFont systemFontOfSize:kQBInputFontSize];
    [textView setFont:inputFont];
    [textView setTextColor:[NSColor labelColor]];
    paragraph = [[NSMutableParagraphStyle alloc] init];
    [paragraph setLineSpacing:kQBInputLineSpacing];
    [textView setDefaultParagraphStyle:paragraph];
    {
        NSDictionary *typingAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                              inputFont, NSFontAttributeName,
                                              [NSColor labelColor], NSForegroundColorAttributeName,
                                              paragraph, NSParagraphStyleAttributeName,
                                              nil];
        [textView setTypingAttributes:typingAttributes];
    }
    [paragraph release];
    _textView = textView;
    [scroll setDocumentView:textView];
    /* The scroll view must join the container hierarchy: a text view outside a
       window cannot become first responder, which made the palette untypable. */
    [container addSubview:scroll];

    errorLabel = qb_make_label(@"", kQBErrorFontSize, [NSColor systemRedColor], NSTextAlignmentLeft);
    [errorLabel setHidden:YES];
    _errorLabel = errorLabel;
    [_cardView addSubview:errorLabel];

    separator = [[QBLineView alloc] initWithFrame:NSZeroRect];
    _separator = separator;
    [_cardView addSubview:separator];

    {
        NSButton *paste = [[NSButton alloc] initWithFrame:NSZeroRect];
        [paste setBordered:NO];
        [paste setButtonType:NSButtonTypeMomentaryChange];
        [paste setFocusRingType:NSFocusRingTypeNone];
        [paste setTitle:@"⌘V 粘图"];
        [paste setFont:[NSFont systemFontOfSize:kQBHintFontSize]];
        [paste setContentTintColor:[NSColor secondaryLabelColor]];
        [paste setTarget:self];
        [paste setAction:@selector(pasteButtonClicked:)];
        _footerLeft = paste;
    }
    [_cardView addSubview:_footerLeft];

    footerRight = qb_make_label(@"Enter 发送 · Shift+Enter 换行 · Esc 关闭", kQBHintFontSize,
                                [NSColor secondaryLabelColor], NSTextAlignmentRight);
    _footerRight = footerRight;
    [_cardView addSubview:footerRight];

    sendButton = [[QBSendButton alloc]
        initWithFrame:NSMakeRect(0, 0, kQBSendButtonWidth, kQBSendButtonHeight)];
    [sendButton setTarget:self];
    [sendButton setAction:@selector(sendButtonClicked:)];
    _sendButton = sendButton;
    [_cardView addSubview:sendButton];
}

- (void)buildUI {
    NSScreen *screen;
    CGFloat width;
    CGFloat minHeight;
    NSRect frame;
    QBPanel *panel;

    if (_built) {
        return;
    }
    _built = YES;

    screen = [self targetScreenForShow];
    width = [self cardWidthForScreen:screen];
    _cardWidth = width;
    minHeight = kQBVerticalInset * 2.0 + kQBToolbarHeight + kQBSectionGap + kQBInputMinHeight +
                kQBSectionGap + kQBFooterHeight;
    frame = NSMakeRect(0, 0, width, minHeight);

    panel = [[QBPanel alloc] initWithContentRect:frame
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
    [panel setLevel:NSFloatingWindowLevel];
    [panel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary];
    [panel setOpaque:NO];
    [panel setBackgroundColor:[NSColor clearColor]];
    [panel setHasShadow:YES];
    [panel setReleasedWhenClosed:NO];
    [panel setHidesOnDeactivate:NO];
    [panel setMovableByWindowBackground:YES];
    [panel setIgnoresMouseEvents:NO];
    [panel setAcceptsMouseMovedEvents:YES];
    [panel setAnimationBehavior:NSWindowAnimationBehaviorNone];
    [panel setDelegate:self];
    _panel = panel;
    _panelTop = NSMaxY(frame);

    [self buildCardContent];
    [self layoutContent];
}

/* ---- layout ------------------------------------------------------------- */

- (CGFloat)maxInputHeight {
    NSFont *font;
    NSLayoutManager *layoutManager;
    CGFloat lineHeight;

    font = _textView != nil ? [_textView font] : nil;
    if (font == nil) {
        font = [NSFont systemFontOfSize:kQBInputFontSize];
    }
    layoutManager = [_textView layoutManager];
    if (layoutManager != nil) {
        lineHeight = [layoutManager defaultLineHeightForFont:font];
    } else {
        lineHeight = [font ascender] - [font descender];
    }
    lineHeight = ceil(lineHeight + kQBInputLineSpacing);
    return ceil(lineHeight * (CGFloat)kQBInputMaxLines + 2.0 * kQBInputContainerInsetY + 2.0);
}

- (CGFloat)rawTextHeight {
    CGFloat textWidth;
    NSTextContainer *textContainer;
    NSTextView *textView = _textView;

    if (textView == nil) {
        return kQBInputMinHeight;
    }
    textWidth = _cardWidth - 2.0 * kQBHorizontalInset - 2.0 * kQBInputContainerInsetX;
    if (textWidth < 80.0) {
        textWidth = 80.0;
    }
    [textView setFrameSize:NSMakeSize(textWidth, MAX(60.0, NSHeight([textView frame])))];
    textContainer = [textView textContainer];
    if (textContainer != nil) {
        [[textView layoutManager] ensureLayoutForTextContainer:textContainer];
    }
    {
        NSRect used = [[textView layoutManager] usedRectForTextContainer:textContainer];
        return ceil(NSMaxY(used)) + 2.0 * kQBInputContainerInsetY + 2.0;
    }
}

- (CGFloat)desiredCardHeight {
    CGFloat raw = [self rawTextHeight];
    CGFloat maximum = [self maxInputHeight];
    CGFloat inputHeight = raw;

    if (inputHeight < kQBInputMinHeight) {
        inputHeight = kQBInputMinHeight;
    }
    if (inputHeight > maximum) {
        inputHeight = maximum;
    }
    _inputHeight = inputHeight;
    {
        CGFloat imagesHeight = [_images count] > 0 ? (kQBImageStripGap + kQBImageChipSize) : 0.0;
        CGFloat errorHeight = _errorText.length > 0 ? (kQBErrorGap + kQBErrorHeight) : 0.0;
        return kQBVerticalInset * 2.0 + kQBToolbarHeight + kQBSectionGap + inputHeight +
               imagesHeight + errorHeight + kQBSectionGap + kQBFooterHeight;
    }
}

- (void)layoutPill:(QBPillView *)pill
               tag:(NSTextField *)tag
             popup:(NSPopUpButton *)popup
           chevron:(NSImageView *)chevron {
    CGFloat width = NSWidth([pill bounds]);
    CGFloat height = NSHeight([pill bounds]);
    NSFont *tagFont = tag != nil ? [tag font] : [NSFont systemFontOfSize:kQBSmallLabelFontSize];
    NSDictionary *tagAttributes = [NSDictionary dictionaryWithObject:tagFont
                                                              forKey:NSFontAttributeName];
    CGFloat tagWidth = ceil([[tag stringValue] sizeWithAttributes:tagAttributes].width) + 8.0;
    CGFloat tagX = 10.0;
    CGFloat chevronSize = 8.0;
    CGFloat chevronX = width - 10.0 - chevronSize;
    CGFloat popupX;
    CGFloat popupWidth;

    if (tag != nil) {
        [tag setFrame:NSMakeRect(tagX, floor((height - 14.0) / 2.0), tagWidth, 14.0)];
    }
    if (chevron != nil) {
        [chevron setFrame:NSMakeRect(chevronX, floor((height - chevronSize) / 2.0),
                                     chevronSize, chevronSize)];
    }
    popupX = tagX + tagWidth + 6.0;
    popupWidth = chevronX - 4.0 - popupX;
    if (popupWidth < 20.0) {
        popupWidth = 20.0;
    }
    if (popup != nil) {
        [popup setFrame:NSMakeRect(popupX, floor((height - 20.0) / 2.0), popupWidth, 20.0)];
    }
}

- (void)layoutToolbarRowAtY:(CGFloat)y width:(CGFloat)innerWidth {
    CGFloat workspaceWidth = floor((innerWidth - 2.0 * kQBToolbarWidgetGap) * 0.26);
    CGFloat modelWidth = floor((innerWidth - 2.0 * kQBToolbarWidgetGap) * 0.50);
    CGFloat effortWidth = innerWidth - 2.0 * kQBToolbarWidgetGap - workspaceWidth - modelWidth;
    CGFloat x = kQBHorizontalInset;

    [_workspacePill setFrame:NSMakeRect(x, y, workspaceWidth, kQBToolbarHeight)];
    x += workspaceWidth + kQBToolbarWidgetGap;
    [_modelPill setFrame:NSMakeRect(x, y, modelWidth, kQBToolbarHeight)];
    x += modelWidth + kQBToolbarWidgetGap;
    [_effortPill setFrame:NSMakeRect(x, y, effortWidth, kQBToolbarHeight)];

    [self layoutPill:_workspacePill tag:_workspaceTag popup:_workspacePopup chevron:_workspaceChevron];
    [self layoutPill:_modelPill tag:_modelTag popup:_modelPopup chevron:_modelChevron];
    [self layoutPill:_effortPill tag:_effortTag popup:_effortPopup chevron:_effortChevron];
}

- (void)relayoutImageChipsWithTop:(CGFloat)top {
    CGFloat x = kQBHorizontalInset;
    for (QBChipView *chip in _imageChips) {
        [chip setFrame:NSMakeRect(x, top - kQBImageChipSize, kQBImageChipSize, kQBImageChipSize)];
        x += kQBImageChipSize + kQBImageChipGap;
    }
}

- (void)layoutContent {
    CGFloat width;
    CGFloat innerWidth;
    CGFloat height;
    CGFloat raw;
    CGFloat maximum;
    CGFloat imagesHeight;
    CGFloat errorHeight;
    NSRect frame;
    CGFloat toolbarY;
    CGFloat cursor;
    CGFloat inputY;
    CGFloat textHeight;
    NSDictionary *hintAttributes;
    CGFloat hintWidth;
    CGFloat footerY;

    if (!_built || _panel == nil) {
        return;
    }
    width = _cardWidth;
    innerWidth = width - 2.0 * kQBHorizontalInset;
    if (innerWidth < 100.0) {
        innerWidth = 100.0;
    }

    raw = [self rawTextHeight];
    maximum = [self maxInputHeight];
    if (raw < kQBInputMinHeight) {
        raw = kQBInputMinHeight;
    }
    if (raw > maximum) {
        raw = maximum;
    }
    _inputHeight = raw;
    imagesHeight = [_images count] > 0 ? (kQBImageStripGap + kQBImageChipSize) : 0.0;
    errorHeight = _errorText.length > 0 ? (kQBErrorGap + kQBErrorHeight) : 0.0;
    height = kQBVerticalInset * 2.0 + kQBToolbarHeight + kQBSectionGap + _inputHeight +
             imagesHeight + errorHeight + kQBSectionGap + kQBFooterHeight;

    frame = [_panel frame];
    if (fabs(NSWidth(frame) - width) > 0.01 || fabs(NSHeight(frame) - height) > 0.01) {
        _suppressMoveSave = YES;
        [_panel setFrame:NSMakeRect(NSMinX(frame), _panelTop - height, width, height)
                 display:YES
                 animate:NO];
        _suppressMoveSave = NO;
        [_panel invalidateShadow];
    }
    [_cardView setFrame:NSMakeRect(0, 0, width, height)];

    toolbarY = height - kQBVerticalInset - kQBToolbarHeight;
    [self layoutToolbarRowAtY:toolbarY width:innerWidth];
    cursor = toolbarY - kQBSectionGap;

    inputY = cursor - _inputHeight;
    [_inputContainer setFrame:NSMakeRect(kQBHorizontalInset, inputY, innerWidth, _inputHeight)];
    [_inputScroll setFrame:NSInsetRect([_inputContainer bounds], kQBInputContainerInsetX,
                                       kQBInputContainerInsetY)];
    textHeight = MAX([self rawTextHeight], NSHeight([_inputScroll bounds]));
    [_textView setFrameSize:NSMakeSize(NSWidth([_inputScroll bounds]), textHeight)];
    [_inputScroll setHasVerticalScroller:([self rawTextHeight] > _inputHeight + 0.5)];
    cursor = inputY;

    if (imagesHeight > 0.0) {
        CGFloat chipTop = cursor - kQBImageStripGap;
        [self relayoutImageChipsWithTop:chipTop];
        cursor = chipTop - kQBImageChipSize;
    }
    if (errorHeight > 0.0) {
        cursor -= kQBErrorGap;
        [_errorLabel setFrame:NSMakeRect(kQBHorizontalInset, cursor - kQBErrorHeight, innerWidth,
                                         kQBErrorHeight)];
        cursor -= kQBErrorHeight;
    }
    [_errorLabel setHidden:(_errorText.length == 0)];

    footerY = kQBVerticalInset;
    [_sendButton setFrame:NSMakeRect(width - kQBHorizontalInset - kQBSendButtonWidth, footerY,
                                     kQBSendButtonWidth, kQBSendButtonHeight)];
    hintAttributes = [NSDictionary dictionaryWithObject:[NSFont systemFontOfSize:kQBHintFontSize]
                                                  forKey:NSFontAttributeName];
    hintWidth = ceil([[_footerRight stringValue] sizeWithAttributes:hintAttributes].width) + 8.0;
    [_footerRight setFrame:NSMakeRect(NSMinX([_sendButton frame]) - 12.0 - hintWidth,
                                      footerY + floor((kQBFooterHeight - 16.0) / 2.0), hintWidth,
                                      16.0)];
    hintWidth = ceil([[self footerLeftText] sizeWithAttributes:hintAttributes].width) + 8.0;
    [_footerLeft setFrame:NSMakeRect(kQBHorizontalInset,
                                     footerY + floor((kQBFooterHeight - 16.0) / 2.0), hintWidth,
                                     16.0)];
    [_separator setFrame:NSMakeRect(kQBHorizontalInset, footerY + kQBFooterHeight + 5.0,
                                    innerWidth, 1.0)];

    [_inputContainer setShowsPlaceholder:(_textView.string.length == 0)];
}

/* ---- config → menus ----------------------------------------------------- */

- (NSDictionary *)configSelection {
    id selection;
    if (_config == nil) {
        return [NSDictionary dictionary];
    }
    selection = [_config objectForKey:@"selection"];
    if ([selection isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)selection;
    }
    return [NSDictionary dictionary];
}

- (void)applyConfig:(NSDictionary *)config {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyConfig:config];
        });
        return;
    }
    [self buildUI];

    if (_config != config) {
        [_config release];
        _config = [config retain];
    }

    [self rebuildWorkspaceMenu];
    [self rebuildModelMenu];
    [self rebuildEffortMenuWithDesiredEffort:
              qb_nonempty_string([[self configSelection] objectForKey:@"reasoningEffort"])];
    [self layoutContent];
}

- (void)rebuildWorkspaceMenu {
    NSDictionary *selection = [self configSelection];
    NSString *wantedId = qb_nonempty_string([selection objectForKey:@"workspaceId"]);
    id workspaces = _config != nil ? [_config objectForKey:@"workspaces"] : nil;
    NSInteger selected = -1;

    qb_popup_menu(_workspacePopup);
    [_workspacePopup removeAllItems];
    if ([workspaces isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)workspaces) {
            NSDictionary *workspace;
            NSString *workspaceId;
            NSString *label;

            if (![element isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            workspace = (NSDictionary *)element;
            workspaceId = qb_nonempty_string([workspace objectForKey:@"id"]);
            if (workspaceId == nil) {
                continue;
            }
            label = qb_nonempty_string([workspace objectForKey:@"label"]);
            if (label == nil) {
                label = workspaceId;
            }
            qb_popup_add_item(_workspacePopup, label, workspace);
            if (wantedId != nil && [workspaceId isEqualToString:wantedId]) {
                selected = [_workspacePopup numberOfItems] - 1;
            }
        }
    }
    if ([_workspacePopup numberOfItems] == 0) {
        qb_popup_show_placeholder(_workspacePopup, @"工作区");
    } else {
        if (selected < 0) {
            selected = 0;
        }
        [_workspacePopup selectItemAtIndex:selected];
    }
}

- (void)rebuildModelMenu {
    NSDictionary *selection = [self configSelection];
    NSString *wantedProvider = qb_nonempty_string([selection objectForKey:@"provider"]);
    NSString *wantedModel = qb_nonempty_string([selection objectForKey:@"model"]);
    id providers = _config != nil ? [_config objectForKey:@"models"] : nil;
    NSMutableArray *entries = [NSMutableArray array];
    NSInteger selected = -1;

    qb_popup_menu(_modelPopup);
    [_modelPopup removeAllItems];
    if ([providers isKindOfClass:[NSArray class]]) {
        for (id providerElement in (NSArray *)providers) {
            NSDictionary *providerWrapper;
            NSDictionary *provider;
            NSString *providerId;
            NSString *providerName;
            id models;

            if (![providerElement isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            providerWrapper = (NSDictionary *)providerElement;
            provider = [providerWrapper objectForKey:@"provider"];
            if (![provider isKindOfClass:[NSDictionary class]]) {
                provider = nil;
            }
            providerId = provider != nil ? qb_nonempty_string([provider objectForKey:@"id"]) : nil;
            providerName = provider != nil ? qb_nonempty_string([provider objectForKey:@"name"]) : nil;
            if (providerName == nil) {
                providerName = providerId;
            }
            models = [providerWrapper objectForKey:@"models"];
            if (![models isKindOfClass:[NSArray class]]) {
                continue;
            }
            for (id modelElement in (NSArray *)models) {
                NSDictionary *model;
                NSString *modelId;
                NSString *modelName;
                NSArray *efforts;
                NSString *defaultEffort;
                NSMutableDictionary *entry;
                NSString *title;

                if (![modelElement isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                model = (NSDictionary *)modelElement;
                modelId = qb_nonempty_string([model objectForKey:@"id"]);
                if (modelId == nil) {
                    continue;
                }
                modelName = qb_nonempty_string([model objectForKey:@"name"]);
                if (modelName == nil) {
                    modelName = modelId;
                }
                efforts = [model objectForKey:@"efforts"];
                if (![efforts isKindOfClass:[NSArray class]]) {
                    efforts = [NSArray array];
                }
                defaultEffort = qb_nonempty_string([model objectForKey:@"defaultEffort"]);

                entry = [NSMutableDictionary dictionary];
                [entry setObject:(providerId != nil ? providerId : @"") forKey:@"providerId"];
                [entry setObject:(providerName != nil ? providerName : @"") forKey:@"providerName"];
                [entry setObject:modelId forKey:@"modelId"];
                [entry setObject:modelName forKey:@"modelName"];
                [entry setObject:efforts forKey:@"efforts"];
                [entry setObject:(defaultEffort != nil ? defaultEffort : @"") forKey:@"defaultEffort"];
                [entries addObject:entry];

                title = providerName != nil
                            ? [NSString stringWithFormat:@"%@ · %@", providerName, modelName]
                            : modelName;
                qb_popup_add_item(_modelPopup, title, entry);

                if (wantedProvider != nil && wantedModel != nil && providerId != nil &&
                    [providerId isEqualToString:wantedProvider] &&
                    [modelId isEqualToString:wantedModel]) {
                    selected = [_modelPopup numberOfItems] - 1;
                }
            }
        }
    }

    [_modelEntries release];
    _modelEntries = [entries copy];

    if ([_modelPopup numberOfItems] == 0) {
        qb_popup_show_placeholder(_modelPopup, @"模型");
    } else {
        if (selected < 0) {
            selected = 0;
        }
        [_modelPopup selectItemAtIndex:selected];
    }
}

- (void)rebuildEffortMenuWithDesiredEffort:(NSString *)desiredEffort {
    NSDictionary *entry = [self selectedModelEntry];
    NSArray *efforts = entry != nil ? [entry objectForKey:@"efforts"] : nil;
    NSString *defaultEffort =
        entry != nil ? qb_nonempty_string([entry objectForKey:@"defaultEffort"]) : nil;
    NSString *wanted = qb_nonempty_string(desiredEffort);
    NSInteger selected = -1;

    if (wanted == nil) {
        wanted = defaultEffort;
    }

    qb_popup_menu(_effortPopup);
    [_effortPopup removeAllItems];
    if ([efforts isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)efforts) {
            NSDictionary *effort;
            NSString *effortId;
            NSString *effortName;

            if (![element isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            effort = (NSDictionary *)element;
            effortId = qb_nonempty_string([effort objectForKey:@"id"]);
            if (effortId == nil) {
                continue;
            }
            effortName = qb_nonempty_string([effort objectForKey:@"name"]);
            if (effortName == nil) {
                effortName = effortId;
            }
            qb_popup_add_item(_effortPopup, effortName, effort);
            if (wanted != nil && [effortId isEqualToString:wanted]) {
                selected = [_effortPopup numberOfItems] - 1;
            }
        }
    }
    if ([_effortPopup numberOfItems] == 0) {
        qb_popup_show_placeholder(_effortPopup, @"推理强度");
    } else {
        if (selected < 0) {
            selected = 0;
        }
        [_effortPopup selectItemAtIndex:selected];
    }
}

- (void)modelSelectionChanged:(id)sender {
    (void)sender;
    /* New model → its own effort list, defaulting to that model's defaultEffort. */
    [self rebuildEffortMenuWithDesiredEffort:nil];
}

/* ---- current selection -------------------------------------------------- */

- (NSDictionary *)selectedModelEntry {
    id object;
    if (_modelPopup == nil) {
        return nil;
    }
    object = [[_modelPopup selectedItem] representedObject];
    if ([object isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)object;
    }
    return nil;
}

- (NSString *)selectedWorkspaceId {
    id object;
    if (_workspacePopup == nil) {
        return nil;
    }
    object = [[_workspacePopup selectedItem] representedObject];
    if ([object isKindOfClass:[NSDictionary class]]) {
        return qb_nonempty_string([(NSDictionary *)object objectForKey:@"id"]);
    }
    return nil;
}

- (NSString *)selectedProviderId {
    NSDictionary *entry = [self selectedModelEntry];
    return entry != nil ? qb_nonempty_string([entry objectForKey:@"providerId"]) : nil;
}

- (NSString *)selectedModelId {
    NSDictionary *entry = [self selectedModelEntry];
    return entry != nil ? qb_nonempty_string([entry objectForKey:@"modelId"]) : nil;
}

- (NSString *)selectedEffortId {
    id object;
    if (_effortPopup == nil) {
        return nil;
    }
    object = [[_effortPopup selectedItem] representedObject];
    if ([object isKindOfClass:[NSDictionary class]]) {
        return qb_nonempty_string([(NSDictionary *)object objectForKey:@"id"]);
    }
    return nil;
}

/* ---- content / state ---------------------------------------------------- */

- (NSString *)currentText {
    NSString *text = _textView != nil ? [_textView string] : nil;
    return text != nil ? text : @"";
}

- (BOOL)hasTextContent {
    return [qb_trimmed_string([self currentText]) length] > 0;
}

- (void)setFieldText:(NSString *)text {
    [self buildUI];
    [_textView setString:(text != nil ? text : @"")];
    [self updateSendButtonState];
    [self layoutContent];
}

- (void)setInputFocused:(BOOL)focused {
    [_inputContainer setFocused:focused];
}

- (void)updateSendButtonState {
    QBSendState desired;

    if (_sendState == QBSendStateSending || _sendState == QBSendStateSent) {
        return;
    }
    desired = [self hasTextContent] ? QBSendStateNormal : QBSendStateDisabled;
    if (desired != _sendState) {
        _sendState = desired;
        [_sendButton setSendState:desired];
    }
    [_inputContainer setShowsPlaceholder:([_textView.string length] == 0)];
}

- (NSDictionary *)currentSubmitPayload {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    NSMutableArray *images = [NSMutableArray array];
    NSString *workspaceId = [self selectedWorkspaceId];
    NSString *providerId = [self selectedProviderId];
    NSString *modelId = [self selectedModelId];
    NSString *effortId = [self selectedEffortId];

    for (NSDictionary *entry in _images) {
        NSMutableDictionary *image = [NSMutableDictionary dictionary];
        id mediaType = [entry objectForKey:@"mediaType"];
        id base64 = [entry objectForKey:@"base64"];
        id name = [entry objectForKey:@"name"];
        id width = [entry objectForKey:@"width"];
        id height = [entry objectForKey:@"height"];
        if (mediaType != nil) {
            [image setObject:mediaType forKey:@"mediaType"];
        }
        if (base64 != nil) {
            [image setObject:base64 forKey:@"base64"];
        }
        if (name != nil) {
            [image setObject:name forKey:@"name"];
        }
        if (width != nil) {
            [image setObject:width forKey:@"width"];
        }
        if (height != nil) {
            [image setObject:height forKey:@"height"];
        }
        [images addObject:image];
    }

    [payload setObject:[self currentText] forKey:@"text"];
    [payload setObject:(workspaceId != nil ? (id)workspaceId : (id)[NSNull null])
                forKey:@"workspaceId"];
    [payload setObject:(providerId != nil ? (id)providerId : (id)[NSNull null]) forKey:@"provider"];
    [payload setObject:(modelId != nil ? (id)modelId : (id)[NSNull null]) forKey:@"model"];
    [payload setObject:(effortId != nil ? (id)effortId : (id)[NSNull null])
                forKey:@"reasoningEffort"];
    [payload setObject:images forKey:@"images"];
    return payload;
}

- (void)clearContent {
    [_textView setString:@""];
    [_textView setEditable:YES];
    for (QBChipView *chip in _imageChips) {
        [chip removeFromSuperview];
    }
    [_imageChips removeAllObjects];
    [_images removeAllObjects];
    [self clearError];
    _sendState = QBSendStateDisabled;
    [_sendButton setSendState:QBSendStateDisabled];
    [self updateSendButtonState];
    [self layoutContent];
}

/* ---- error row ---------------------------------------------------------- */

- (void)invalidateTransientErrorTimer {
    if (_transientErrorTimer != nil) {
        [_transientErrorTimer invalidate];
        [_transientErrorTimer release];
        _transientErrorTimer = nil;
    }
}

- (void)transientErrorTimerFired:(NSTimer *)timer {
    (void)timer;
    _transientErrorTimer = nil;
    [self clearError];
}

- (void)showHint:(NSString *)message {
    [self showError:message persistent:NO];
    [_errorLabel setTextColor:[NSColor secondaryLabelColor]];
}

- (void)showError:(NSString *)message persistent:(BOOL)persistent {
    NSString *line = qb_single_line(message, 200);
    [_errorLabel setTextColor:[NSColor systemRedColor]];

    [self invalidateTransientErrorTimer];
    [_errorText release];
    _errorText = [line copy];
    [_errorLabel setStringValue:line];
    [_errorLabel setHidden:NO];
    if (!persistent) {
        _transientErrorTimer = [[NSTimer scheduledTimerWithTimeInterval:2.5
                                                                target:self
                                                              selector:@selector(transientErrorTimerFired:)
                                                              userInfo:nil
                                                               repeats:NO] retain];
    }
    [self layoutContent];
}

- (void)clearError {
    [self invalidateTransientErrorTimer];
    [_errorText release];
    _errorText = nil;
    [_errorLabel setStringValue:@""];
    [_errorLabel setHidden:YES];
}

/* ---- images ------------------------------------------------------------- */

- (void)addChipView:(QBChipView *)chip {
    if (chip == nil) {
        return;
    }
    [_imageChips addObject:chip];
    [_cardView addSubview:chip];
}

- (void)removeChipClicked:(NSButton *)sender {
    QBChipView *chip = (QBChipView *)[sender superview];
    NSUInteger index;
    if (![chip isKindOfClass:[QBChipView class]]) {
        return;
    }
    index = [_imageChips indexOfObjectIdenticalTo:chip];
    if (index == NSNotFound) {
        return;
    }
    [self removeImageAtIndex:index];
}

- (void)removeImageAtIndex:(NSUInteger)index {
    if (index >= [_images count]) {
        return;
    }
    [_images removeObjectAtIndex:index];
    if (index < [_imageChips count]) {
        QBChipView *chip = [_imageChips objectAtIndex:index];
        [chip removeFromSuperview];
        [_imageChips removeObjectAtIndex:index];
    }
    [self updateSendButtonState];
    [self layoutContent];
}

- (NSString *)footerLeftText {
    if ([_footerLeft isKindOfClass:[NSButton class]]) {
        return [(NSButton *)_footerLeft title];
    }
    return [_footerLeft stringValue];
}

- (void)pasteButtonClicked:(id)sender {
    (void)sender;
    if (![self pasteFromPasteboard:[NSPasteboard generalPasteboard]]) {
        [self showHint:@"剪贴板里没有图片，先复制一张图片再粘贴"];
    }
}

- (BOOL)pasteFromPasteboard:(NSPasteboard *)pasteboard {
    NSImage *image = qb_pasteboard_image(pasteboard);

    if (image == nil) {
        if (qb_pasteboard_has_file_urls(pasteboard)) {
            [self showError:@"暂不支持文件附件，只能粘贴图片" persistent:NO];
            return YES;
        }
        return NO;
    }
    if ([_images count] >= kQBMaxImages) {
        [self showError:@"最多只能附加 4 张图片" persistent:NO];
        return YES;
    }
    {
        NSDictionary *encoded = qb_image_payload(image, [_images count] + 1);
        if (encoded == nil) {
            [self showError:@"图片读取失败，请重试" persistent:NO];
            return YES;
        }
        {
            NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:encoded];
            [entry setObject:image forKey:@"image"];
            [_images addObject:entry];
        }
        {
            QBChipView *chip = [[QBChipView alloc] initWithImage:image];
            [chip setRemoveTarget:self action:@selector(removeChipClicked:)];
            [self addChipView:chip];
            [chip release];
        }
        [self updateSendButtonState];
        [self layoutContent];
        [self showHint:[NSString stringWithFormat:@"已添加图片 %lu/%d",
                                                  (unsigned long)[_images count], (int)kQBMaxImages]];
    }
    return YES;
}

/* ---- sending lifecycle -------------------------------------------------- */

- (void)startAckTimer {
    NSTimeInterval timeout = kQBAckTimeoutDefault;
    const char *configured = getenv(kQBAckTimeoutEnv);

    if (configured != NULL) {
        long milliseconds = atol(configured);
        if (milliseconds > 0) {
            timeout = (NSTimeInterval)milliseconds / 1000.0;
        }
    }
    [self stopAckTimer];
    _ackTimer = [[NSTimer scheduledTimerWithTimeInterval:timeout
                                                  target:self
                                                selector:@selector(ackTimerFired:)
                                                userInfo:nil
                                                 repeats:NO] retain];
}

- (void)stopAckTimer {
    if (_ackTimer != nil) {
        [_ackTimer invalidate];
        [_ackTimer release];
        _ackTimer = nil;
    }
}

- (void)ackTimerFired:(NSTimer *)timer {
    (void)timer;
    _ackTimer = nil;
    [self failAfterTimeout];
}

- (void)beginSending {
    _sendState = QBSendStateSending;
    [_sendButton setSendState:QBSendStateSending];
    [_textView setEditable:NO];
    [self setInputFocused:NO];
    [self clearError];
    [self layoutContent];
}

- (void)submitCurrentText {
    NSDictionary *payload;

    if (_sendState == QBSendStateSending || _sendState == QBSendStateSent) {
        return;
    }
    if (!_uiTestMode && ![self hasTextContent]) {
        return;
    }
    payload = [self currentSubmitPayload];
    if (payload == nil) {
        return;
    }
    if (_uiTestMode) {
        qb_emit_payload("SUBMIT", payload);
        return;
    }
    [self beginSending];
    qb_emit_payload("SUBMIT", payload);
    [self startAckTimer];
}

- (void)handleSubmitOk {
    if (_sendState != QBSendStateSending) {
        return;
    }
    [self stopAckTimer];
    _sendState = QBSendStateSent;
    [_sendButton setSendState:QBSendStateSent];
    [_textView setEditable:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kQBSentHoldMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                       if (_sendState != QBSendStateSent) {
                           return;
                       }
                       _sendState = QBSendStateDisabled;
                       [self hidePanelClearing:YES notifyCancel:NO];
                   });
}

- (void)failSendingWithMessage:(NSString *)message diag:(NSString *)diag {
    NSString *line = qb_single_line(message, 160);

    [self stopAckTimer];
    _sendState = [self hasTextContent] ? QBSendStateNormal : QBSendStateDisabled;
    [_sendButton setSendState:_sendState];
    [_textView setEditable:YES];
    [self showError:line persistent:YES];
    [self setInputFocused:YES];
    if (_panelVisible) {
        [_panel makeFirstResponder:_textView];
    }
    if (_uiTestAckMode) {
        NSString *text = [self currentText];
        NSString *summary = [NSString stringWithFormat:
                                  @"%@ state=error text-kept=%d text-len=%lu error-row=%@",
                                  diag, [text length] > 0 ? 1 : 0, (unsigned long)[text length], line];
        qb_test_finish([summary UTF8String]);
    }
}

- (void)handleSubmitFail:(NSString *)message {
    if (_sendState != QBSendStateSending) {
        return;
    }
    [self failSendingWithMessage:(message.length > 0 ? message : @"发送失败，请重试")
                            diag:@"ack=fail"];
}

- (void)failAfterTimeout {
    if (_sendState != QBSendStateSending) {
        return;
    }
    [self failSendingWithMessage:@"发送超时，请检查连接后重试" diag:@"ack=timeout"];
}

- (void)sendButtonClicked:(id)sender {
    (void)sender;
    [self submitCurrentText];
}

/* ---- window behaviour --------------------------------------------------- */

- (void)showPanel {
    NSScreen *screen;
    NSRect target;
    NSRect start;
    NSUInteger length;

    if (_panelVisible) {
        return;
    }
    [self buildUI];

    screen = [self targetScreenForShow];
    _cardWidth = [self cardWidthForScreen:screen];
    target = [self cardFrameForScreen:screen
                             cardSize:NSMakeSize(_cardWidth, [self desiredCardHeight])];
    _panelTop = NSMaxY(target);
    _suppressMoveSave = YES;
    [_panel setFrame:target display:NO];
    _suppressMoveSave = NO;
    [self layoutContent];

    _showGeneration++;
    _panelVisible = YES;
    _panelBecameKeyThisShow = NO;
    [self clearError];
    _sendState = [self hasTextContent] ? QBSendStateNormal : QBSendStateDisabled;
    [_sendButton setSendState:_sendState];
    [_textView setEditable:YES];

    start = target;
    start.origin.y -= 6.0;
    _suppressMoveSave = YES;
    [_panel setFrame:start display:NO];
    [_panel setAlphaValue:0.0];

    if (!_skipActivation) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    }
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_textView];
    length = [_textView.string length];
    [_textView setSelectedRange:NSMakeRange(length, 0)];
    [self setInputFocused:YES];
    [self updateSendButtonState];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:(NSTimeInterval)kQBOpenDurationMs / 1000.0];
        [context setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        [[_panel animator] setAlphaValue:1.0];
        [[_panel animator] setFrame:target display:YES];
    }
                      completionHandler:^{
                          _suppressMoveSave = NO;
                          [self saveOriginToDefaults];
                      }];
    if ([_cardView layer] != nil) {
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        [scale setFromValue:[NSNumber numberWithDouble:0.98]];
        [scale setToValue:[NSNumber numberWithDouble:1.0]];
        [scale setDuration:(NSTimeInterval)kQBOpenDurationMs / 1000.0];
        [scale setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        [[_cardView layer] addAnimation:scale forKey:@"qbOpenScale"];
    }
}

- (void)hidePanelClearing:(BOOL)clearDraft notifyCancel:(BOOL)notifyCancel {
    NSUInteger generation;

    if (!_panelVisible) {
        if (clearDraft) {
            [self clearContent];
        }
        return;
    }
    _panelVisible = NO;
    [self cancelResignHide];
    [self stopAckTimer];
    [self invalidateTransientErrorTimer];
    [self setInputFocused:NO];
    [self saveOriginToDefaults];
    if (notifyCancel) {
        qb_emit("CANCEL");
    }
    generation = ++_showGeneration;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:(NSTimeInterval)kQBCloseDurationMs / 1000.0];
        [context setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
        [[_panel animator] setAlphaValue:0.0];
    }
                      completionHandler:^{
                          if (generation != _showGeneration || _panelVisible) {
                              return;
                          }
                          [_panel orderOut:nil];
                          [_panel setAlphaValue:1.0];
                          if (clearDraft) {
                              [self clearContent];
                          }
                          if (!_skipActivation) {
                              [NSApp deactivate];
                          }
                          if (_uiTestAckMode) {
                              qb_test_finish("ack=ok state=sent-then-closed text-cleared=1 "
                                             "images-cleared=1");
                          }
                      }];
}

- (void)togglePanel {
    if (_sendState == QBSendStateSending) {
        return;
    }
    if (_panelVisible) {
        [self hidePanelClearing:NO notifyCancel:NO];
    } else {
        [self showPanel];
    }
}

- (void)cancel {
    if (!_panelVisible) {
        return;
    }
    [self hidePanelClearing:YES notifyCancel:YES];
}

- (void)setAutomatedMode:(NSUInteger)mode {
    _uiTestMode = (mode & QBAutomatedUiTest) != 0;
    _uiTestAckMode = (mode & QBAutomatedUiTestAck) != 0;
    _interactionTestMode = (mode & QBAutomatedInteraction) != 0;
    _skipActivation = (mode & (QBAutomatedUiTest | QBAutomatedUiTestAck | QBAutomatedInteraction)) != 0;
}

/* ---- delegates ---------------------------------------------------------- */

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateSendButtonState];
    [self layoutContent];
    [_textView scrollRangeToVisible:[_textView selectedRange]];
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        /* Plain Enter is handled in QBPasteTextView keyDown:; anything that
         * still arrives here (e.g. Shift+Enter) keeps the text view's default
         * newline insertion so it stays a line break, never a submit. */
        return NO;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if ([textView hasMarkedText]) {
            return NO;
        }
        [self cancel];
        return YES;
    }
    return NO;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    _menuTracking = YES;
    [self setInputFocused:NO];
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    _menuTracking = NO;
    if (_panelVisible && _sendState != QBSendStateSending) {
        [self setInputFocused:YES];
        [_panel makeFirstResponder:_textView];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    _panelBecameKeyThisShow = YES;
    [self cancelResignHide];
    if (_panelVisible && _sendState != QBSendStateSending) {
        [self setInputFocused:YES];
        [_panel makeFirstResponder:_textView];
    }
}

- (void)cancelResignHide {
    if (_resignHideTimer != nil) {
        [_resignHideTimer invalidate];
        _resignHideTimer = nil;
    }
}

- (void)resignHideTimerFired:(NSTimer *)timer {
    (void)timer;
    _resignHideTimer = nil;
    if (!_panelVisible || _sendState == QBSendStateSending) {
        return;
    }
    /* Our app still owns the activation: the key window went to a transient
     * panel (IME / clipboard picker) and will come back. Keep the palette. */
    if ([NSApp isActive]) {
        return;
    }
    /* A real outside click / app switch: close, but keep the draft so an
     * accidental click never discards what the user typed (only Esc clears). */
    [self hidePanelClearing:NO notifyCancel:NO];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    if (!_panelVisible) {
        return;
    }
    if (_menuTracking) {
        return;
    }
    /* If the window never became key (activation raced with show), do not make
     * the palette vanish before the user has seen it; the next outside click
     * after it becomes key closes it as usual. */
    if (!_panelBecameKeyThisShow) {
        return;
    }
    if (_sendState == QBSendStateSending) {
        return;
    }
    /*
     * Transient key-window changes inside our own active app (an IME candidate
     * window, a clipboard-history picker implemented as a non-activating panel,
     * a system panel) must NOT close the palette: the user is composing or
     * picking something that will be pasted back here. Only losing application
     * activation (a real click on another app) closes it, and even then we wait
     * a moment in case that other app hands focus straight back.
     */
    [self setInputFocused:NO];
    [self cancelResignHide];
    _resignHideTimer = [NSTimer scheduledTimerWithTimeInterval:kBQResignHideDelay
                                                        target:self
                                                      selector:@selector(resignHideTimerFired:)
                                                      userInfo:nil
                                                       repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_resignHideTimer forMode:NSRunLoopCommonModes];
}

- (void)windowDidMove:(NSNotification *)notification {
    (void)notification;
    if (!_panelVisible || _suppressMoveSave) {
        return;
    }
    _panelTop = NSMaxY([_panel frame]);
    [self saveOriginToDefaults];
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    if (!_panelVisible || _suppressMoveSave) {
        return;
    }
    _panelTop = NSMaxY([_panel frame]);
}

/* ---- interaction self-check (--interaction-test) ------------------------ */

- (void)logInteraction:(BOOL)ok format:(NSString *)format, ... {
    va_list ap;
    char message[768];

    va_start(ap, format);
    vsnprintf(message, sizeof message, [format UTF8String], ap);
    va_end(ap);
    fprintf(stderr, "INTERACTION %s: %s\n", ok ? "ok" : "fail", message);
    if (!ok) {
        _interactionFailures++;
    }
}

- (void)appendInteractionFailure:(NSString *)message {
    [self logInteraction:NO format:@"%@", message];
}

- (void)simulateKeyDown:(unsigned short)keyCode modifiers:(NSEventModifierFlags)flags {
    NSString *characters = @"";
    if (keyCode == 36 || keyCode == 76) {
        characters = @"\r";
    }
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:flags
                                     timestamp:[[NSProcessInfo processInfo] systemUptime]
                                  windowNumber:_panel != nil ? [_panel windowNumber] : 0
                                       context:nil
                                    characters:characters
                   charactersIgnoringModifiers:characters
                                     isARepeat:NO
                                       keyCode:keyCode];
    if (event != nil && _textView != nil) {
        [_textView keyDown:event];
    }
}

- (int)runInteractionChecks {
    _interactionFailures = 0;

    /* 1. Visual constants (DESIGN.md is authoritative). */
    [self logInteraction:(kQBOpenDurationMs == 180 && kQBCloseDurationMs == 120 &&
                             kQBSentHoldMs == 150)
                  format:@"motion open=%dms close=%dms sent=%dms (all <= 250ms)",
                         kQBOpenDurationMs, kQBCloseDurationMs, kQBSentHoldMs];
    [self logInteraction:(kQBCardCornerRadius == 16.0 && kQBToolbarHeight == 26.0 &&
                             kQBInputMinHeight == 44.0 && kQBInputMaxLines == 5 &&
                             kQBImageChipSize == 72.0 && kQBSendButtonHeight == 26.0)
                  format:@"geometry card-radius=16 toolbar=26 input-min=44 max-lines=5 "
                         @"chip=72 send=26"];
    [self logInteraction:(kQBInputFontSize == 13.0 && kQBControlFontSize == 13.0 &&
                             kQBHintFontSize == 11.5 && kQBSmallLabelFontSize == 11.0)
                  format:@"type-scale input=13 controls=13 hints=11.5 pills=11"];
    {
        BOOL cardOk = [_cardView isKindOfClass:[NSVisualEffectView class]] &&
                      [[_cardView layer] cornerRadius] == kQBCardCornerRadius &&
                      [[_cardView layer] masksToBounds] &&
                      [[_cardView layer] borderWidth] == 0.0 &&
                      [_panel hasShadow] && [_panel level] == NSFloatingWindowLevel &&
                      ([_panel collectionBehavior] &
                       NSWindowCollectionBehaviorCanJoinAllSpaces) != 0 &&
                      ([_panel collectionBehavior] &
                       NSWindowCollectionBehaviorFullScreenAuxiliary) != 0;
        [self logInteraction:cardOk
                      format:@"card material=popover radius=16 masks=YES outer-border=none "
                             @"single-system-shadow floating/all-spaces/fullscreen-aux"];
    }
    {
        BOOL toolbarOk = _workspacePopup != nil && _modelPopup != nil && _effortPopup != nil &&
                         _workspacePill != nil && _modelPill != nil && _effortPill != nil &&
                         ((NSPopUpButtonCell *)[_workspacePopup cell]).arrowPosition == NSPopUpNoArrow;
        [self logInteraction:toolbarOk
                      format:@"3 pill selectors (workspace/model/effort) borderless, no native arrow"];
    }
    {
        NSFont *inputFont = [_textView font];
        BOOL inputOk = _inputScroll != nil && _textView != nil &&
                       [[_textView string] length] == 0 && ![_textView isRichText] &&
                       ![_textView drawsBackground] &&
                       inputFont != nil &&
                       fabs([inputFont pointSize] - 13.0) < 0.01 &&
                       ![_textView isAutomaticQuoteSubstitutionEnabled] &&
                       [_sendButton sendState] == QBSendStateDisabled &&
                       [[_footerRight stringValue] rangeOfString:@"Enter 发送"].location != NSNotFound &&
                       [[_footerRight stringValue] rangeOfString:@"Shift+Enter"].location != NSNotFound &&
                       [[_footerRight stringValue] rangeOfString:@"Esc 关闭"].location != NSNotFound &&
                       [[self footerLeftText] rangeOfString:@"⌘V 粘图"].location != NSNotFound;
        [self logInteraction:inputOk
                      format:@"multi-line transparent plain-text input 13pt, smart quotes off, "
                             @"footer hints + accent send pill, send disabled when empty"];
    }

    /* 2. Position persistence key contract. */
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kQBOriginDefaultsKey];
    [self logInteraction:([self loadSavedOrigin:NULL displayId:NULL] == NO)
                  format:@"no saved origin -> centered top-third fallback"];
    [self showPanel];
    qb_spin_runloop(0.30);
    {
        NSPoint origin = NSZeroPoint;
        unsigned int displayId = 0;
        BOOL saved = [self loadSavedOrigin:&origin displayId:&displayId];
        NSScreen *screen = [_panel screen];
        BOOL positioned = saved && displayId == qb_display_id_for_screen(screen) &&
                          fabs(origin.x - NSMinX([_panel frame])) < 1.5 &&
                          fabs(origin.y - NSMinY([_panel frame])) < 1.5;
        [self logInteraction:(_panelVisible && positioned)
                      format:@"open -> visible, origin remembered in NSUserDefaults key "
                             @"quickbar.popup.origin"];
    }

    /* 3. Hotkey toggle: hide (no submit) → reopen keeps the draft. */
    [self setFieldText:@"草稿"];
    [self logInteraction:[_textView.string isEqualToString:@"草稿"] format:@"typing sets input text"];
    [self togglePanel];
    qb_spin_runloop(0.25);
    [self logInteraction:(!_panelVisible && [_textView.string isEqualToString:@"草稿"])
                  format:@"toggle while visible -> hidden, draft preserved, no submit"];
    [self togglePanel];
    qb_spin_runloop(0.30);
    [self logInteraction:(_panelVisible && [_textView.string isEqualToString:@"草稿"])
                  format:@"toggle while hidden -> visible, draft still there"];

    /* 4. Esc: close + clear + CANCEL protocol line (stdout). */
    [self simulateKeyDown:53 modifiers:0];
    qb_spin_runloop(0.25);
    [self logInteraction:(!_panelVisible && [[self currentText] length] == 0)
                  format:@"Esc -> hidden + content cleared (CANCEL emitted on stdout)"];

    /* 4b. Cmd+V routing: the Edit menu must exist and a command-V event must
     *     reach the paste path (this is what made the palette look "dead"). */
    {
        NSMenuItem *editItem = [[NSApp mainMenu] itemAtIndex:0];
        NSMenu *editMenu = [editItem submenu];
        BOOL hasPaste = NO;
        for (NSMenuItem *item in [editMenu itemArray]) {
            if ([[item keyEquivalent] isEqualToString:@"v"] &&
                ([item keyEquivalentModifierMask] & NSEventModifierFlagCommand) != 0) {
                hasPaste = YES;
            }
        }
        [self logInteraction:(editMenu != nil && hasPaste)
                      format:@"Edit menu routes Cmd+V to paste: to the focused field"];
    }

    /* 5. Paste image: decode from a private pasteboard, chips, 4-image cap,
     *    remove button, SUBMIT payload shape. */
    {
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
        NSImage *image = qb_make_test_image();
        [pasteboard clearContents];
        [pasteboard writeObjects:[NSArray arrayWithObject:image]];
        [self logInteraction:qb_pasteboard_has_image(pasteboard)
                      format:@"pasteboard image detection (public.png/tiff) works"];
        [self logInteraction:(qb_pasteboard_image(pasteboard) != nil)
                      format:@"pasteboard -> NSImage decoding works"];
        {
            NSUInteger index;
            for (index = 0; index < kQBMaxImages + 1; index++) {
                (void)[self pasteFromPasteboard:pasteboard];
            }
        }
        [self logInteraction:([_images count] == kQBMaxImages && [_imageChips count] == kQBMaxImages)
                      format:@"Cmd+V image chips: 4 attached, 5th rejected (max 4) with inline error"];
        [self logInteraction:(_errorText.length > 0 && ![_errorLabel isHidden])
                      format:@"inline error row visible for the image limit"];
        {
            /* The chips are the only visual proof a paste worked: they must be
             * laid out inside the card, non-empty, and parented to it. */
            BOOL chipsOk = [_imageChips count] == kQBMaxImages;
            NSRect cardBounds = [_cardView bounds];
            for (QBChipView *chip in _imageChips) {
                NSRect frame = [chip frame];
                if ([chip superview] != _cardView || NSWidth(frame) < 20.0 ||
                    NSHeight(frame) < 20.0 || !NSContainsRect(cardBounds, frame)) {
                    chipsOk = NO;
                }
            }
            [self logInteraction:chipsOk
                          format:@"image chips visible inside the card (%lu chips, %0.fx%0.f)",
                                 (unsigned long)[_imageChips count], kQBImageChipSize,
                                 kQBImageChipSize];
        }
        {
            NSDictionary *payload = [self currentSubmitPayload];
            NSArray *images = [payload objectForKey:@"images"];
            BOOL payloadOk = [images count] == kQBMaxImages;
            if (payloadOk) {
                NSDictionary *first = [images objectAtIndex:0];
                NSString *mediaType = [first objectForKey:@"mediaType"];
                NSString *base64 = [first objectForKey:@"base64"];
                NSNumber *width = [first objectForKey:@"width"];
                NSNumber *height = [first objectForKey:@"height"];
                NSData *decoded = [[[NSData alloc] initWithBase64EncodedString:base64
                                                                       options:0] autorelease];
                BOOL pngMagic = decoded.length > 4 &&
                                ((const unsigned char *)[decoded bytes])[0] == 0x89;
                payloadOk = [mediaType isEqualToString:@"image/png"] && decoded.length > 0 &&
                            [width intValue] > 0 && [height intValue] > 0 && pngMagic;
            }
            [self logInteraction:payloadOk
                          format:@"SUBMIT payload images[]: mediaType/base64/width/height valid PNG"];
        }
        [self removeImageAtIndex:0];
        [self logInteraction:([_images count] == 3 && [_imageChips count] == 3)
                      format:@"chip remove button drops the image (4 -> 3)"];
        [self clearContent];
    }

    /* 6. Multi-line auto-grow (to 5 lines, then internal scroll). */
    {
        NSString *multi = @"1\n2\n3\n4\n5\n6\n7\n8";
        CGFloat minCardHeight = kQBVerticalInset * 2.0 + kQBToolbarHeight + kQBSectionGap +
                                kQBInputMinHeight + kQBSectionGap + kQBFooterHeight;
        [self setFieldText:multi];
        [self layoutContent];
        CGFloat grownHeight = NSHeight([_panel frame]);
        [self logInteraction:(_inputHeight > kQBInputMinHeight + 1.0 &&
                                 grownHeight > minCardHeight + 1.0 &&
                                 [_inputScroll hasVerticalScroller])
                      format:@"multi-line input auto-grows to 5 lines then scrolls "
                             @"(input=%.0fpt card=%.0fpt scroller=YES)",
                             _inputHeight, grownHeight];
        [self setFieldText:@"hello"];
        [self layoutContent];
        [self logInteraction:(fabs(NSHeight([_panel frame]) - minCardHeight) < 1.5)
                      format:@"single-line input returns the card to its 152pt minimum "
                             @"(card=%.0fpt)",
                             NSHeight([_panel frame])];
    }

    /* 7. Shift+Enter inserts a newline and never submits; plain Enter sends. */
    {
        NSInteger submitsBefore = gSubmitEmitCount;
        [self setFieldText:@"a"];
        [self simulateKeyDown:36 modifiers:NSEventModifierFlagShift];
        qb_spin_runloop(0.10);
        BOOL newlineInserted = [_textView.string isEqualToString:@"a\n"];
        [self logInteraction:(newlineInserted && gSubmitEmitCount == submitsBefore)
                      format:@"Shift+Enter inserts a newline, no SUBMIT"];
        [self showPanel];
        qb_spin_runloop(0.30);
        [self setFieldText:@"hello"];
        [self simulateKeyDown:36 modifiers:0];
        qb_spin_runloop(0.10);
        [self logInteraction:(gSubmitEmitCount == submitsBefore + 1 &&
                                 _sendState == QBSendStateSending && _panelVisible &&
                                 ![_textView isEditable] &&
                                 [_sendButton sendState] == QBSendStateSending)
                      format:@"Enter -> one SUBMIT + sending: input disabled, spinner, panel open"];
    }
    if (_sendState == QBSendStateSending) {
        [self stopAckTimer];
        _sendState = QBSendStateNormal;
        [_sendButton setSendState:QBSendStateNormal];
        [_textView setEditable:YES];
    }
    [self hidePanelClearing:YES notifyCancel:NO];
    qb_spin_runloop(0.25);

    return _interactionFailures > 0 ? QB_EXIT_ERROR : QB_EXIT_OK;
}

@end

/* ------------------------------------------------------------------------- */
/* Hotkey event handling                                                      */
/* ------------------------------------------------------------------------- */

static void qb_handle_hotkey_trigger(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            qb_handle_hotkey_trigger();
        });
        return;
    }

    qb_emit("TRIGGER %lld", qb_epoch_ms());

    /* --selftest proves the handler path only; it must never show UI. */
    if (gSelftest || gController == nil) {
        return;
    }
    /* v5: the global hotkey toggles — visible panel hides, hidden panel opens.
     * Hiding through the hotkey never submits. */
    [gController togglePanel];
}

static void qb_handle_stdin_trigger(void) {
    qb_emit("TRIGGER %lld", qb_epoch_ms());
    if (gSelftest || gController == nil) {
        return;
    }
    /* stdin `trigger` keeps its v4 meaning: show the popup (do not toggle). */
    [gController showPanel];
}

static OSStatus qb_hotkey_handler(EventHandlerCallRef inCallRef, EventRef inEvent,
                                  void *inUserData) {
    EventHotKeyID hotKeyID;
    OSStatus status;

    (void)inCallRef;
    (void)inUserData;

    memset(&hotKeyID, 0, sizeof hotKeyID);
    status = GetEventParameter(inEvent, kEventParamDirectObject, typeEventHotKeyID, NULL,
                               sizeof hotKeyID, NULL, &hotKeyID);
    if (status != noErr) {
        return eventNotHandledErr;
    }
    if (hotKeyID.signature != QB_SIGNATURE || hotKeyID.id != QB_HOTKEY_ID) {
        return eventNotHandledErr;
    }

    gTriggerCount++;
    qb_handle_hotkey_trigger();
    return noErr;
}

/* ------------------------------------------------------------------------- */
/* Signals: handlers only set a flag; a CFRunLoop timer does the clean exit.  */
/* ------------------------------------------------------------------------- */

static void qb_signal_handler(int signo) {
    (void)signo;
    gQuitRequested = 1;
    if (!gTimerInstalled) {
        /*
         * Degraded fallback (very early signal, or timer install failed): no
         * timer can notice the flag, so do the cleanup and exit right here.
         */
        qb_cleanup();
        fflush(stdout);
        _exit(QB_EXIT_OK);
    }
}

static void qb_quit_timer_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    if (!gQuitRequested) {
        return;
    }
    qb_cleanup();
    fflush(stdout);
    exit(QB_EXIT_OK);
}

/* ------------------------------------------------------------------------- */
/* stdin control: trigger / CFG / SUBMIT_OK / SUBMIT_FAIL                     */
/* Read on a background queue so the UI loop is never blocked.                */
/* ------------------------------------------------------------------------- */

static void qb_start_stdin_reader(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char *line = NULL;
        size_t capacity = 0;
        ssize_t count;

        while ((count = getline(&line, &capacity, stdin)) > 0) {
            @autoreleasepool {
                size_t length = (size_t)count;
                size_t start = 0;

                while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r' ||
                                      line[length - 1] == ' ' || line[length - 1] == '\t')) {
                    line[--length] = '\0';
                }
                while (start < length && (line[start] == ' ' || line[start] == '\t')) {
                    start++;
                }
                if (length > start) {
                    NSString *command = [[NSString alloc] initWithBytes:line + start
                                                                 length:length - start
                                                               encoding:NSUTF8StringEncoding];
                    if (command != nil) {
                        if ([command isEqualToString:@"trigger"]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                qb_handle_stdin_trigger();
                            });
                        } else if ([command isEqualToString:@"SUBMIT_OK"]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (gController != nil) {
                                    [gController handleSubmitOk];
                                }
                            });
                        } else if ([command hasPrefix:@"SUBMIT_FAIL"]) {
                            NSString *reason =
                                [[command substringFromIndex:11]
                                    stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (gController != nil) {
                                    [gController handleSubmitFail:reason];
                                }
                            });
                        } else {
                            NSRange whitespace = [command rangeOfCharacterFromSet:
                                                              [NSCharacterSet whitespaceCharacterSet]];
                            if (whitespace.location != NSNotFound && whitespace.location <= 4) {
                                NSString *tag = [command substringToIndex:whitespace.location];
                                if ([tag isEqualToString:@"CFG"]) {
                                    NSString *payload = [[command substringFromIndex:NSMaxRange(whitespace)]
                                        stringByTrimmingCharactersInSet:
                                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                    NSDictionary *config = qb_parse_config_base64(payload);
                                    if (config != nil) {
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            if (gController != nil) {
                                                [gController applyConfig:config];
                                            }
                                        });
                                    } else {
                                        fprintf(stderr,
                                                "quickbar-hotkey: ignoring malformed CFG payload\n");
                                    }
                                }
                            }
                        }
                        [command release];
                    }
                }
            }
        }
        free(line);
    });
}

/* ------------------------------------------------------------------------- */
/* Hotkey spec parsing                                                        */
/* ------------------------------------------------------------------------- */

typedef struct {
    UInt32 modifiers;
    UInt32 keyCode;
    int hasKey;
} QbSpec;

typedef struct {
    const char *name;
    UInt32 code;
} QbKeyEntry;

static const QbKeyEntry kQbKeys[] = {
    {"a", kVK_ANSI_A},
    {"b", kVK_ANSI_B},
    {"c", kVK_ANSI_C},
    {"d", kVK_ANSI_D},
    {"e", kVK_ANSI_E},
    {"f", kVK_ANSI_F},
    {"g", kVK_ANSI_G},
    {"h", kVK_ANSI_H},
    {"i", kVK_ANSI_I},
    {"j", kVK_ANSI_J},
    {"k", kVK_ANSI_K},
    {"l", kVK_ANSI_L},
    {"m", kVK_ANSI_M},
    {"n", kVK_ANSI_N},
    {"o", kVK_ANSI_O},
    {"p", kVK_ANSI_P},
    {"q", kVK_ANSI_Q},
    {"r", kVK_ANSI_R},
    {"s", kVK_ANSI_S},
    {"t", kVK_ANSI_T},
    {"u", kVK_ANSI_U},
    {"v", kVK_ANSI_V},
    {"w", kVK_ANSI_W},
    {"x", kVK_ANSI_X},
    {"y", kVK_ANSI_Y},
    {"z", kVK_ANSI_Z},
    {"0", kVK_ANSI_0},
    {"1", kVK_ANSI_1},
    {"2", kVK_ANSI_2},
    {"3", kVK_ANSI_3},
    {"4", kVK_ANSI_4},
    {"5", kVK_ANSI_5},
    {"6", kVK_ANSI_6},
    {"7", kVK_ANSI_7},
    {"8", kVK_ANSI_8},
    {"9", kVK_ANSI_9},
    {"space", kVK_Space},
    {"tab", kVK_Tab},
    {"return", kVK_Return},
    {"enter", kVK_Return},
    {"escape", kVK_Escape},
    {"esc", kVK_Escape},
    {"f1", kVK_F1},
    {"f2", kVK_F2},
    {"f3", kVK_F3},
    {"f4", kVK_F4},
    {"f5", kVK_F5},
    {"f6", kVK_F6},
    {"f7", kVK_F7},
    {"f8", kVK_F8},
    {"f9", kVK_F9},
    {"f10", kVK_F10},
    {"f11", kVK_F11},
    {"f12", kVK_F12},
    {"comma", kVK_ANSI_Comma},
    {"period", kVK_ANSI_Period},
    {"slash", kVK_ANSI_Slash},
    {"minus", kVK_ANSI_Minus},
    {"backtick", kVK_ANSI_Grave},
    {"left", kVK_LeftArrow},
    {"right", kVK_RightArrow},
    {"up", kVK_UpArrow},
    {"down", kVK_DownArrow},
};

static UInt32 qb_modifier_for(const char *token) {
    if (strcmp(token, "cmd") == 0 || strcmp(token, "command") == 0) {
        return cmdKey;
    }
    if (strcmp(token, "shift") == 0) {
        return shiftKey;
    }
    if (strcmp(token, "opt") == 0 || strcmp(token, "alt") == 0 ||
        strcmp(token, "option") == 0) {
        return optionKey;
    }
    if (strcmp(token, "ctrl") == 0 || strcmp(token, "control") == 0) {
        return controlKey;
    }
    return 0;
}

static UInt32 qb_key_code_for(const char *token, int *found) {
    size_t i;
    for (i = 0; i < sizeof kQbKeys / sizeof kQbKeys[0]; i++) {
        if (strcmp(token, kQbKeys[i].name) == 0) {
            *found = 1;
            return kQbKeys[i].code;
        }
    }
    *found = 0;
    return 0;
}

static char *qb_trim(char *s) {
    char *end;
    while (*s != '\0' && isspace((unsigned char)*s)) {
        s++;
    }
    if (*s == '\0') {
        return s;
    }
    end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) {
        *end = '\0';
        end--;
    }
    return s;
}

/*
 * Parse "<mod>+...+<key>". Tokens are matched case-insensitively after trimming
 * surrounding whitespace (a friendly superset of the contract's lowercase
 * spelling). Anything unknown, duplicated, empty, or with the wrong number of
 * keys/modifiers is rejected — never silently mapped to a different hotkey.
 */
static int qb_parse_spec(const char *raw, QbSpec *out, char *err, size_t errSize) {
    char buffer[512];
    char *cursor;
    UInt32 modifiers = 0;
    int sawToken = 0;

    memset(out, 0, sizeof *out);

    if (raw == NULL) {
        snprintf(err, errSize, "missing hotkey spec");
        return 0;
    }
    if (raw[0] == '\0') {
        snprintf(err, errSize, "empty hotkey spec");
        return 0;
    }
    if (strlen(raw) >= sizeof buffer) {
        snprintf(err, errSize, "hotkey spec is too long");
        return 0;
    }
    memcpy(buffer, raw, strlen(raw) + 1);
    {
        size_t i;
        for (i = 0; buffer[i] != '\0'; i++) {
            buffer[i] = (char)tolower((unsigned char)buffer[i]);
        }
    }

    /* Contract: `off`/`none`/`disabled` means "do not register anything". */
    {
        char *trimmed = qb_trim(buffer);
        if (strcmp(trimmed, "off") == 0 || strcmp(trimmed, "none") == 0 ||
            strcmp(trimmed, "disabled") == 0) {
            snprintf(err, errSize, "hotkey spec '%s' means disabled", trimmed);
            return 0;
        }
        if (trimmed != buffer) {
            memmove(buffer, trimmed, strlen(trimmed) + 1);
        }
    }

    cursor = buffer;
    for (;;) {
        char *token = cursor;
        char *plus = strchr(cursor, '+');
        if (plus != NULL) {
            *plus = '\0';
        }
        sawToken = 1;
        token = qb_trim(token);
        if (*token == '\0') {
            snprintf(err, errSize, "empty token in hotkey spec");
            return 0;
        }
        {
            UInt32 modifier = qb_modifier_for(token);
            if (modifier != 0) {
                if ((modifiers & modifier) != 0) {
                    snprintf(err, errSize, "duplicate modifier '%s'", token);
                    return 0;
                }
                modifiers |= modifier;
            } else {
                int isKey = 0;
                UInt32 keyCode = qb_key_code_for(token, &isKey);
                if (!isKey) {
                    snprintf(err, errSize, "unsupported token '%s'", token);
                    return 0;
                }
                if (out->hasKey) {
                    snprintf(err, errSize, "more than one key ('%s')", token);
                    return 0;
                }
                out->hasKey = 1;
                out->keyCode = keyCode;
            }
        }
        if (plus == NULL) {
            break;
        }
        cursor = plus + 1;
    }

    if (!sawToken) {
        snprintf(err, errSize, "empty hotkey spec");
        return 0;
    }
    if (modifiers == 0) {
        snprintf(err, errSize, "hotkey spec needs at least one modifier");
        return 0;
    }
    if (!out->hasKey) {
        snprintf(err, errSize, "hotkey spec needs exactly one key");
        return 0;
    }

    out->modifiers = modifiers;
    return 1;
}

/* ------------------------------------------------------------------------- */
/* Registration helpers                                                       */
/* ------------------------------------------------------------------------- */

static int qb_gui_session_available(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (session == NULL) {
        return 0;
    }
    CFRelease(session);
    return 1;
}

static int qb_install_hotkey_handler(void) {
    EventTypeSpec eventType;
    OSStatus status;

    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;

    status = InstallEventHandler(GetApplicationEventTarget(), qb_hotkey_handler, 1,
                                 &eventType, NULL, &gHandlerRef);
    if (status != noErr) {
        qb_error("handler-failed", "%d", (int)status);
        qb_cleanup();
        return 0;
    }
    return 1;
}

static int qb_register_hotkey(const QbSpec *spec) {
    EventHotKeyID hotKeyID;
    OSStatus status;

    hotKeyID.signature = QB_SIGNATURE;
    hotKeyID.id = QB_HOTKEY_ID;

    status = RegisterEventHotKey(spec->keyCode, spec->modifiers, hotKeyID,
                                 GetApplicationEventTarget(), 0, &gHotKeyRef);
    if (status != noErr) {
        qb_error("register-failed", "%d", (int)status);
        qb_cleanup();
        return 0;
    }
    return 1;
}

/*
 * Synthesize one kEventHotKeyPressed for our id and dispatch it to the same
 * application event target a real press hits. Used only by --selftest.
 */
static int qb_synthesize_hotkey_event(void) {
    EventHotKeyID hotKeyID;
    EventRef event = NULL;
    OSStatus status;

    hotKeyID.signature = QB_SIGNATURE;
    hotKeyID.id = QB_HOTKEY_ID;

    status = CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed,
                         GetCurrentEventTime(), 0, &event);
    if (status == noErr) {
        status = SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                   sizeof hotKeyID, &hotKeyID);
    }
    if (status == noErr) {
        status = SendEventToEventTarget(event, GetApplicationEventTarget());
    }
    if (event != NULL) {
        ReleaseEvent(event);
    }
    if (status != noErr) {
        qb_error("handler-failed", "%d", (int)status);
        return 0;
    }
    if (gTriggerCount < 1) {
        qb_error("selftest-failed",
                 "synthetic kEventHotKeyPressed reached no handler without error");
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------------- */
/* Modes                                                                     */
/* ------------------------------------------------------------------------- */

static int qb_apply_ui_test_config(QBController *controller, const char *configText) {
    NSDictionary *config;
    if (configText == NULL) {
        return 1;
    }
    config = qb_parse_config_argument(configText);
    if (config == nil) {
        qb_error("invalid-spec", "--ui-test CFG is not a valid JSON object");
        return 0;
    }
    [controller applyConfig:config];
    return 1;
}

static int qb_run_selftest(const QbSpec *spec) {
    gSelftest = 1;

    if (!qb_gui_session_available()) {
        qb_error("no-display", "no active GUI session; cannot register a global hotkey");
        return QB_EXIT_ERROR;
    }
    if (!qb_install_hotkey_handler()) {
        return QB_EXIT_ERROR;
    }
    if (!qb_register_hotkey(spec)) {
        return QB_EXIT_ERROR;
    }

    qb_emit("READY %ld", (long)getpid());

    if (!qb_synthesize_hotkey_event()) {
        qb_cleanup();
        return QB_EXIT_ERROR;
    }
    qb_cleanup();
    return QB_EXIT_OK;
}

static int qb_run_ui_test(const char *configText, const char *text) {
    @autoreleasepool {
        QBController *controller;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        controller = [[QBController alloc] init];
        [controller setAutomatedMode:QBAutomatedUiTest];
        [controller buildUI];
        if (!qb_apply_ui_test_config(controller, configText)) {
            [controller release];
            fflush(stdout);
            return QB_EXIT_INVALID_SPEC;
        }
        {
            NSString *string = text != NULL ? [NSString stringWithUTF8String:text] : @"";
            [controller setFieldText:(string != nil ? string : @"")];
        }
        [controller submitCurrentText];
        [controller release];
    }
    fflush(stdout);
    return QB_EXIT_OK;
}

/*
 * --ui-test-ack: prove the host-ack lifecycle end to end without a human.
 * Emits exactly one SUBMIT, then waits on stdin for SUBMIT_OK / SUBMIT_FAIL
 * (or the timeout, shortened by QUICKBAR_ACK_TIMEOUT_MS), and reports the
 * resulting panel state on stderr (diagnostics only; stdout stays protocol).
 */
static int qb_run_ui_test_ack(const char *configText, const char *text) {
    int result = QB_EXIT_OK;
    @autoreleasepool {
        QBController *controller;
        NSDate *deadline;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        controller = [[QBController alloc] init];
        [controller setAutomatedMode:QBAutomatedUiTestAck];
        [controller buildUI];
        if (!qb_apply_ui_test_config(controller, configText)) {
            [controller release];
            fflush(stdout);
            return QB_EXIT_INVALID_SPEC;
        }
        {
            NSString *string = text != NULL ? [NSString stringWithUTF8String:text] : @"";
            [controller setFieldText:(string != nil ? string : @"")];
        }
        gController = controller;
        [controller showPanel];
        qb_start_stdin_reader();
        [controller submitCurrentText];

        deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
        while (!gTestFinished && [deadline timeIntervalSinceNow] > 0.0) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            }
        }
        if (!gTestFinished) {
            snprintf(gTestDiag, sizeof gTestDiag, "ack=timeout-in-test-harness");
        }
        fprintf(stderr, "quickbar-hotkey: ui-test-ack %s\n", gTestDiag);
        gController = nil;
        [controller release];
    }
    fflush(stdout);
    fflush(stderr);
    return result;
}

/*
 * --interaction-test: headless-ish proof for toggle / draft / Esc / paste-image
 * chips / visual constants. Prints `INTERACTION ok|fail: …` on stderr; stdout
 * must contain only the one CANCEL produced by the simulated Escape.
 */
static int qb_run_interaction_test(void) {
    int result;
    @autoreleasepool {
        QBController *controller;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        qb_install_edit_menu();

        controller = [[QBController alloc] init];
        [controller setAutomatedMode:QBAutomatedInteraction];
        [controller buildUI];
        result = [controller runInteractionChecks];
        [controller release];
    }
    fflush(stdout);
    fflush(stderr);
    return result;
}

static int qb_run_interactive(const QbSpec *spec) {
    int result;
    CFRunLoopTimerContext timerContext;

    @autoreleasepool {
        if (!qb_gui_session_available()) {
            qb_error("no-display", "no active GUI session; cannot register a global hotkey");
            return QB_EXIT_ERROR;
        }

        /*
         * Cocoa main loop: NSApplication provides the run loop (and pumps the
         * Carbon events the hotkey handler is installed for). Accessory policy
         * keeps the helper out of the Dock and the app switcher.
         */
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        qb_install_edit_menu();

        if (!qb_install_hotkey_handler()) {
            return QB_EXIT_ERROR;
        }
        if (!qb_register_hotkey(spec)) {
            return QB_EXIT_ERROR;
        }

        gController = [[QBController alloc] init];
        /* Warm the popup before READY so the first hotkey press is instant. */
        [gController buildUI];

        qb_emit("READY %ld", (long)getpid());

        timerContext.version = 0;
        timerContext.info = NULL;
        timerContext.retain = NULL;
        timerContext.release = NULL;
        timerContext.copyDescription = NULL;
        gQuitTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.05, 0.1, 0, 0,
                                          qb_quit_timer_cb, &timerContext);
        if (gQuitTimer != NULL) {
            CFRunLoopAddTimer(CFRunLoopGetMain(), gQuitTimer, kCFRunLoopCommonModes);
            gTimerInstalled = 1;
        } else {
            fprintf(stderr,
                    "quickbar-hotkey: warning: run-loop timer unavailable; "
                    "signals exit the process synchronously\n");
        }

        qb_start_stdin_reader();

        [NSApp run];

        /* Reached only if something terminated the application. */
        qb_cleanup();
        fflush(stdout);
        [gController release];
        gController = nil;
        result = QB_EXIT_OK;
    }
    return result;
}

/* ------------------------------------------------------------------------- */
/* main                                                                       */
/* ------------------------------------------------------------------------- */

static void qb_usage(void) {
    fprintf(stderr,
            "usage: quickbar-hotkey <hotkey-spec> [--selftest | --ui-test [CFG_JSON] TEXT]\n"
            "       [--cfg CFG_JSON]\n"
            "       quickbar-hotkey <hotkey-spec> --ui-test-ack [CFG_JSON] TEXT\n"
            "       quickbar-hotkey <hotkey-spec> --interaction-test\n"
            "  e.g. quickbar-hotkey cmd+shift+space\n"
            "\n"
            "modes (default: register the hotkey and show the command palette):\n"
            "  --selftest           register, synthesize one hotkey event, print TRIGGER,\n"
            "                       exit 0 (no UI is created)\n"
            "  --ui-test TEXT       build the popup, set TEXT and submit it, print one\n"
            "                       structured SUBMIT line, exit 0 (no human needed)\n"
            "  --ui-test JSON TEXT  same, after applying the CFG JSON (menus populated and\n"
            "                       the CFG selection preselected)\n"
            "  --ui-test-ack ...    like --ui-test, then wait on stdin for SUBMIT_OK or\n"
            "                       SUBMIT_FAIL and report the panel state on stderr\n"
            "  --interaction-test   toggle / draft / Esc / image-chip / design self-check\n"
            "  --cfg JSON           CFG JSON for --ui-test / --ui-test-ack (raw JSON or\n"
            "                       base64-encoded JSON)\n"
            "\n"
            "stdin: \"trigger\" shows the popup (like the hotkey);\n"
            "       \"CFG <base64-json>\" updates workspace/model/effort pickers;\n"
            "       \"SUBMIT_OK\" / \"SUBMIT_FAIL <text>\" acknowledge a submission\n"
            "stdout protocol: READY <pid> | TRIGGER <epoch-ms> | SUBMIT <base64-json> |\n"
            "                 CANCEL | ERROR <code> <message>\n"
            "\n"
            "spec: one or more of cmd|command, shift, opt|alt|option, ctrl|control,\n"
            "      then exactly one of a-z, 0-9, space, tab, return|enter,\n"
            "      escape|esc, f1..f12, comma, period, slash, minus, backtick,\n"
            "      left, right, up, down\n");
}

int main(int argc, char **argv) {
    const char *positional[4];
    int positionalCount = 0;
    const char *cfgOption = NULL;
    const char *spec = NULL;
    int selftest = 0;
    int uiTest = 0;
    int uiTestAck = 0;
    int interactionTest = 0;
    int i;
    QbSpec parsed;
    char err[256];

    signal(SIGPIPE, SIG_IGN);

    /*
     * Install signal handlers before doing anything else so a host that
     * terminates the helper immediately after spawn still gets a clean exit 0.
     * Until the run-loop timer exists, the handler does the cleanup and exits
     * synchronously (see qb_signal_handler).
     */
    {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_handler = qb_signal_handler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGINT, &action, NULL);
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) {
            if (selftest) {
                qb_error("invalid-spec", "duplicate --selftest");
                return QB_EXIT_INVALID_SPEC;
            }
            selftest = 1;
        } else if (strcmp(argv[i], "--ui-test") == 0) {
            if (uiTest) {
                qb_error("invalid-spec", "duplicate --ui-test");
                return QB_EXIT_INVALID_SPEC;
            }
            uiTest = 1;
        } else if (strcmp(argv[i], "--ui-test-ack") == 0) {
            if (uiTestAck) {
                qb_error("invalid-spec", "duplicate --ui-test-ack");
                return QB_EXIT_INVALID_SPEC;
            }
            uiTestAck = 1;
        } else if (strcmp(argv[i], "--interaction-test") == 0) {
            if (interactionTest) {
                qb_error("invalid-spec", "duplicate --interaction-test");
                return QB_EXIT_INVALID_SPEC;
            }
            interactionTest = 1;
        } else if (strcmp(argv[i], "--cfg") == 0) {
            if (cfgOption != NULL) {
                qb_error("invalid-spec", "duplicate --cfg");
                return QB_EXIT_INVALID_SPEC;
            }
            if (i + 1 >= argc) {
                qb_error("invalid-spec", "--cfg requires a JSON argument");
                return QB_EXIT_INVALID_SPEC;
            }
            cfgOption = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            qb_usage();
            return QB_EXIT_OK;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            qb_error("invalid-spec", "unknown option '%s'", argv[i]);
            return QB_EXIT_INVALID_SPEC;
        } else if (positionalCount < (int)(sizeof positional / sizeof positional[0])) {
            positional[positionalCount++] = argv[i];
        } else {
            qb_error("invalid-spec", "unexpected extra argument '%s'", argv[i]);
            return QB_EXIT_INVALID_SPEC;
        }
    }

    if (positionalCount < 1) {
        qb_error("invalid-spec", "missing hotkey spec");
        return QB_EXIT_INVALID_SPEC;
    }
    spec = positional[0];

    {
        int modeCount = selftest + uiTest + uiTestAck + interactionTest;
        if (modeCount > 1) {
            qb_error("invalid-spec", "mutually exclusive modes were combined");
            return QB_EXIT_INVALID_SPEC;
        }
    }
    if (cfgOption != NULL && !uiTest && !uiTestAck) {
        qb_error("invalid-spec", "--cfg is only valid together with --ui-test/--ui-test-ack");
        return QB_EXIT_INVALID_SPEC;
    }
    if (interactionTest && positionalCount > 1) {
        qb_error("invalid-spec", "--interaction-test takes no text/CFG arguments");
        return QB_EXIT_INVALID_SPEC;
    }
    if (!uiTest && !uiTestAck && !interactionTest && positionalCount > 1) {
        qb_error("invalid-spec", "unexpected extra argument '%s'", positional[1]);
        return QB_EXIT_INVALID_SPEC;
    }

    if (!qb_parse_spec(spec, &parsed, err, sizeof err)) {
        qb_error("invalid-spec", "%s", err);
        return QB_EXIT_INVALID_SPEC;
    }

    if (selftest) {
        return qb_run_selftest(&parsed);
    }
    if (interactionTest) {
        return qb_run_interaction_test();
    }
    if (uiTest || uiTestAck) {
        const char *uiConfig = cfgOption;
        const char *uiText = NULL;
        int extra = positionalCount - 1;

        if (extra == 0) {
            qb_error("invalid-spec", "%s requires a text argument",
                     uiTest ? "--ui-test" : "--ui-test-ack");
            return QB_EXIT_INVALID_SPEC;
        }
        if (extra == 1) {
            uiText = positional[1];
        } else if (extra == 2) {
            if (uiConfig != NULL) {
                qb_error("invalid-spec", "%s got both a positional CFG argument and --cfg",
                         uiTest ? "--ui-test" : "--ui-test-ack");
                return QB_EXIT_INVALID_SPEC;
            }
            uiConfig = positional[1];
            uiText = positional[2];
        } else {
            qb_error("invalid-spec", "too many %s arguments",
                     uiTest ? "--ui-test" : "--ui-test-ack");
            return QB_EXIT_INVALID_SPEC;
        }
        if (uiTest) {
            return qb_run_ui_test(uiConfig, uiText);
        }
        return qb_run_ui_test_ack(uiConfig, uiText);
    }

    return qb_run_interactive(&parsed);
}
