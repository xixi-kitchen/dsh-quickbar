/*
 * quickbar-hotkey.m — dsh-quickbar native macOS helper (v4).
 *
 * Pure C/Objective-C (no Swift, no Accessibility permission, no CGEventTap).
 * Registers exactly one system-wide hotkey with the Carbon HotKey API, keeps the
 * process alive with Cocoa's NSApplication run loop, and shows a lightweight
 * always-on-top popup with workspace / model / reasoning-effort pickers and a
 * single-line input field.
 *
 * The long-lived host plugin spawns this binary and talks to it over
 * stdout/stderr (protocol) and stdin (control):
 *
 *   stdout (protocol only, every line flushed):
 *     READY <pid>             hotkey registered and handler installed
 *     TRIGGER <epoch-ms>      hotkey pressed (physical, synthesized, or stdin)
 *     SUBMIT <base64-json>    popup submitted:
 *                             {text, workspaceId, provider, model, reasoningEffort}
 *     CANCEL                  popup cancelled (Escape)
 *     ERROR <code> [message]  failure; exit 3 (2 for invalid-spec)
 *
 *   stdin (control, one command per line):
 *     trigger                 show the popup, exactly like pressing the hotkey
 *     CFG <base64-json>       update the pickers:
 *                             {workspaces:[{id,label,path}],
 *                              models:[{provider:{id,name},
 *                                       models:[{id,name,efforts:[{id,name}],
 *                                                defaultEffort}]}],
 *                              selection:{workspaceId, provider, model,
 *                                         reasoningEffort}}
 *     (blank / unknown lines are ignored; EOF leaves the helper running)
 *
 * CLI:
 *     quickbar-hotkey <hotkey-spec>
 *         run (hotkey + popup)
 *     quickbar-hotkey <hotkey-spec> --selftest
 *         register + synthesize one hotkey event, no UI, exit 0
 *     quickbar-hotkey <hotkey-spec> --ui-test [CFG_JSON] TEXT
 *         build the popup, optionally apply CFG_JSON, set TEXT, submit, print one
 *         structured SUBMIT line, exit 0.  CFG_JSON may be raw JSON or base64 JSON;
 *         it can also be passed with `--cfg CFG_JSON`.
 *
 * Build:  native/build.sh  (clang -O2 -o quickbar-hotkey quickbar-hotkey.m
 *                           -framework Carbon -framework AppKit)
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

/* Popup geometry (points). */
static const CGFloat kQBPanelWidth = 640.0;
static const CGFloat kQBPanelHeight = 96.0;
static const CGFloat kQBPanelCornerRadius = 14.0;
static const CGFloat kQBPanelInset = 16.0;
static const CGFloat kQBPanelToolbarHeight = 24.0;
static const CGFloat kQBPanelToolbarTopInset = 12.0;
static const CGFloat kQBPanelFieldHeight = 24.0;
static const CGFloat kQBPanelFieldBottomInset = 18.0;
static const CGFloat kQBPanelWidgetGap = 10.0;

/* Runtime state (all Carbon/Foundation calls happen on the main thread). */
static EventHotKeyRef gHotKeyRef = NULL;
static EventHandlerRef gHandlerRef = NULL;
static CFRunLoopTimerRef gQuitTimer = NULL;
static volatile sig_atomic_t gQuitRequested = 0;
static volatile sig_atomic_t gTimerInstalled = 0;
static volatile sig_atomic_t gTriggerCount = 0;

/* --selftest: synthesize the event but never build/show UI. */
static int gSelftest = 0;

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
 * Structured protocol payloads (SUBMIT, and future ones) carry compact JSON as
 * standard base64 of its UTF-8 bytes: one line, no spaces (padding '=' is fine).
 */
static void qb_emit_payload(const char *tag, NSDictionary *payload) {
    NSError *error = nil;
    NSData *json;
    NSString *encoded;

    json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil) {
        qb_error("submit-failed", "could not encode JSON payload");
        return;
    }
    encoded = [json base64EncodedStringWithOptions:0];
    qb_emit("%s %s", tag, encoded != nil ? [encoded UTF8String] : "");
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
/* Popup controller                                                           */
/* ------------------------------------------------------------------------- */

/* Borderless panels cannot become key by default; the text field needs key. */
@interface QBPanel : NSPanel
@end

@interface QBController : NSObject <NSTextFieldDelegate> {
    QBPanel *_panel;
    NSTextField *_field;
    NSView *_background;
    NSPopUpButton *_workspacePopup;
    NSPopUpButton *_modelPopup;
    NSPopUpButton *_effortPopup;
    NSDictionary *_config;      /* last CFG object (retained) */
    NSArray *_modelEntries;     /* flattened provider/model entries (retained) */
    BOOL _built;
}
- (void)buildUI;
- (void)showPanel;
- (void)hidePanel;
- (void)submitCurrentText;
- (void)cancel;
- (void)setFieldText:(NSString *)text;
- (void)invokeSubmitLikeEnter;
- (void)applyConfig:(NSDictionary *)config;
@end

@interface QBController ()
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
@end

/* ------------------------------------------------------------------------- */
/* Hotkey event handling                                                      */
/* ------------------------------------------------------------------------- */

static void qb_handle_trigger(void);

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
    qb_handle_trigger();
    return noErr;
}

static void qb_handle_trigger(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            qb_handle_trigger();
        });
        return;
    }

    qb_emit("TRIGGER %lld", qb_epoch_ms());

    /* --selftest proves the handler path only; it must never show UI. */
    if (!gSelftest && gController != nil) {
        [gController showPanel];
    }
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
/* Popup menu helpers                                                         */
/* ------------------------------------------------------------------------- */

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
    item.representedObject = represented;
    [[popup menu] addItem:item];
    [item release];
}

static void qb_popup_show_placeholder(NSPopUpButton *popup, NSString *title) {
    qb_popup_menu(popup);
    [popup removeAllItems];
    [popup addItemWithTitle:title];
    [popup selectItemAtIndex:0];
}

/* ------------------------------------------------------------------------- */
/* Popup implementation                                                       */
/* ------------------------------------------------------------------------- */

@implementation QBPanel
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return NO;
}
@end

@implementation QBController

- (void)dealloc {
    [_workspacePopup release];
    [_modelPopup release];
    [_effortPopup release];
    [_config release];
    [_modelEntries release];
    [_panel release];
    [_field release];
    [_background release];
    [super dealloc];
}

- (void)configurePopup:(NSPopUpButton *)popup placeholder:(NSString *)placeholder {
    popup.font = [NSFont systemFontOfSize:12.0];
    popup.autoresizingMask = NSViewNotSizable;
    qb_popup_menu(popup);
    [popup removeAllItems];
    [popup addItemWithTitle:placeholder];
    [popup selectItemAtIndex:0];
}

- (void)buildUI {
    NSArray<NSScreen *> *screens;
    NSScreen *screen;
    NSRect visibleFrame;
    CGFloat width;
    CGFloat innerWidth;
    CGFloat toolbarY;
    CGFloat fieldY;
    CGFloat x;
    CGFloat y;
    CGFloat workspaceWidth;
    CGFloat modelWidth;
    CGFloat effortWidth;
    CGFloat modelX;
    CGFloat effortX;
    QBPanel *panel;
    NSView *background;
    NSTextField *field;
    NSPopUpButton *workspacePopup;
    NSPopUpButton *modelPopup;
    NSPopUpButton *effortPopup;
    NSAttributedString *placeholder;
    NSColor *backgroundColor;
    NSColor *borderColor;

    if (_built) {
        return;
    }
    _built = YES;

    screens = [NSScreen screens];
    screen = screens.count > 0 ? screens.firstObject : [NSScreen mainScreen];
    visibleFrame = screen.visibleFrame;

    width = kQBPanelWidth;
    if (width > visibleFrame.size.width - 80.0) {
        width = visibleFrame.size.width - 80.0;
    }
    if (width < 320.0) {
        width = 320.0;
    }
    /* Centered horizontally, in the middle of the top third of the screen. */
    x = visibleFrame.origin.x + (visibleFrame.size.width - width) / 2.0;
    y = visibleFrame.origin.y + visibleFrame.size.height * (5.0 / 6.0) - kQBPanelHeight / 2.0;
    if (y < visibleFrame.origin.y + 8.0) {
        y = visibleFrame.origin.y + 8.0;
    }

    panel = [[QBPanel alloc] initWithContentRect:NSMakeRect(x, y, width, kQBPanelHeight)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.movableByWindowBackground = YES;
    panel.ignoresMouseEvents = NO;
    _panel = panel;

    /* Rounded, translucent-looking content surface drawn by a layer-backed view. */
    background = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, kQBPanelHeight)];
    background.wantsLayer = YES;
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    backgroundColor = [[NSColor windowBackgroundColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (backgroundColor == nil) {
        backgroundColor = [NSColor windowBackgroundColor];
    }
    background.layer.backgroundColor = [[backgroundColor colorWithAlphaComponent:0.97] CGColor];
    background.layer.cornerRadius = kQBPanelCornerRadius;
    background.layer.masksToBounds = YES;
    background.layer.borderWidth = 0.5;
    borderColor = [[NSColor separatorColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (borderColor == nil) {
        borderColor = [NSColor separatorColor];
    }
    background.layer.borderColor = [[borderColor colorWithAlphaComponent:0.8] CGColor];
    _background = background;
    panel.contentView = background;

    /* Toolbar row: workspace | model (Provider · Model) | reasoning effort. */
    innerWidth = width - 2.0 * kQBPanelInset;
    toolbarY = kQBPanelHeight - kQBPanelToolbarTopInset - kQBPanelToolbarHeight;
    fieldY = kQBPanelFieldBottomInset;
    workspaceWidth = floor((innerWidth - 2.0 * kQBPanelWidgetGap) * 0.30);
    modelWidth = floor((innerWidth - 2.0 * kQBPanelWidgetGap) * 0.42);
    effortWidth = innerWidth - 2.0 * kQBPanelWidgetGap - workspaceWidth - modelWidth;
    modelX = kQBPanelInset + workspaceWidth + kQBPanelWidgetGap;
    effortX = modelX + modelWidth + kQBPanelWidgetGap;

    workspacePopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(kQBPanelInset, toolbarY, workspaceWidth, kQBPanelToolbarHeight)
             pullsDown:NO];
    [self configurePopup:workspacePopup placeholder:@"工作区"];
    [background addSubview:workspacePopup];
    _workspacePopup = workspacePopup;

    modelPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(modelX, toolbarY, modelWidth, kQBPanelToolbarHeight)
             pullsDown:NO];
    [self configurePopup:modelPopup placeholder:@"模型"];
    modelPopup.target = self;
    modelPopup.action = @selector(modelSelectionChanged:);
    [background addSubview:modelPopup];
    _modelPopup = modelPopup;

    effortPopup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(effortX, toolbarY, effortWidth, kQBPanelToolbarHeight)
             pullsDown:NO];
    [self configurePopup:effortPopup placeholder:@"推理强度"];
    [background addSubview:effortPopup];
    _effortPopup = effortPopup;

    field = [[NSTextField alloc]
        initWithFrame:NSMakeRect(kQBPanelInset, fieldY, innerWidth, kQBPanelFieldHeight)];
    field.font = [NSFont systemFontOfSize:15.0];
    field.textColor = [NSColor labelColor];
    field.bordered = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.usesSingleLineMode = YES;
    field.maximumNumberOfLines = 1;
    field.cell.wraps = NO;
    field.cell.scrollable = YES;
    field.autoresizingMask = NSViewWidthSizable;
    field.refusesFirstResponder = NO;
    field.delegate = self;
    placeholder = [[NSAttributedString alloc]
        initWithString:@"输入问题，回车发送…"
            attributes:@{NSForegroundColorAttributeName : [NSColor secondaryLabelColor],
                         NSFontAttributeName : field.font}];
    field.placeholderAttributedString = placeholder;
    [placeholder release];
    [background addSubview:field];
    _field = field;
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
    [self rebuildEffortMenuWithDesiredEffort:qb_nonempty_string([self configSelection][@"reasoningEffort"])];
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
    NSString *defaultEffort = entry != nil ? qb_nonempty_string([entry objectForKey:@"defaultEffort"]) : nil;
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

/* ---- window behaviour --------------------------------------------------- */

- (void)showPanel {
    [self buildUI];

    /*
     * A global-hotkey press is user intent, so ask to activate regardless of
     * which app is currently frontmost. (activateIgnoringOtherApps: is still the
     * only call that reliably steals focus from an arbitrary app.)
     */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop

    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_field];
    /* Select any leftover text: pressing the hotkey again offers a fresh query. */
    [_field selectText:nil];
}

- (void)hidePanel {
    if (_panel != nil && [_panel isVisible]) {
        [_panel orderOut:nil];
        /* Best effort: hand activation back instead of holding an empty app. */
        [NSApp deactivate];
    }
}

- (void)submitCurrentText {
    NSString *text = _field != nil ? [_field stringValue] : @"";
    NSString *workspaceId;
    NSString *providerId;
    NSString *modelId;
    NSString *effortId;
    NSMutableDictionary *payload;

    if (text == nil) {
        text = @"";
    }
    [self hidePanel];
    if (_field != nil) {
        [_field setStringValue:@""];
    }

    workspaceId = [self selectedWorkspaceId];
    providerId = [self selectedProviderId];
    modelId = [self selectedModelId];
    effortId = [self selectedEffortId];

    payload = [NSMutableDictionary dictionary];
    [payload setObject:text forKey:@"text"];
    [payload setObject:(workspaceId != nil ? (id)workspaceId : (id)[NSNull null])
                forKey:@"workspaceId"];
    [payload setObject:(providerId != nil ? (id)providerId : (id)[NSNull null])
                forKey:@"provider"];
    [payload setObject:(modelId != nil ? (id)modelId : (id)[NSNull null])
                forKey:@"model"];
    [payload setObject:(effortId != nil ? (id)effortId : (id)[NSNull null])
                forKey:@"reasoningEffort"];
    qb_emit_payload("SUBMIT", payload);
}

- (void)cancel {
    [self hidePanel];
    if (_field != nil) {
        [_field setStringValue:@""];
    }
    qb_emit("CANCEL");
}

- (void)setFieldText:(NSString *)text {
    [self buildUI];
    [_field setStringValue:(text != nil ? text : @"")];
}

/*
 * --ui-test entry point: route through the exact same delegate callback an Enter
 * key press produces, so the panel → field editor → submit wiring is exercised.
 * Falls back to the submit action directly if no field editor can be created.
 */
- (void)invokeSubmitLikeEnter {
    NSText *editor;
    [self buildUI];
    editor = [_panel fieldEditor:YES forObject:_field];
    if (editor != nil && [editor isKindOfClass:[NSTextView class]]) {
        (void)[self control:_field
                   textView:(NSTextView *)editor
        doCommandBySelector:@selector(insertNewline:)];
    } else {
        [self submitCurrentText];
    }
}

#pragma mark - NSTextFieldDelegate

- (BOOL)control:(NSControl *)control
             textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    (void)control;

    if (commandSelector == @selector(insertNewline:)) {
        /*
         * IME-aware: while a composition (marked text) is active, Enter belongs
         * to the input method — return NO so the default insertion commits the
         * composition instead of submitting half-typed text.
         */
        if ([textView hasMarkedText]) {
            return NO;
        }
        [self submitCurrentText];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self cancel];
        return YES;
    }
    return NO;
}

@end

/* ------------------------------------------------------------------------- */
/* stdin control: `trigger` shows the popup, `CFG <base64-json>` fills menus. */
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
                                qb_handle_trigger();
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
    int result = QB_EXIT_OK;
    @autoreleasepool {
        NSString *string;
        QBController *controller;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        controller = [[QBController alloc] init];
        [controller buildUI];

        if (configText != NULL) {
            NSDictionary *config = qb_parse_config_argument(configText);
            if (config == nil) {
                [controller release];
                fflush(stdout);
                qb_error("invalid-spec", "--ui-test CFG is not a valid JSON object");
                return QB_EXIT_INVALID_SPEC;
            }
            [controller applyConfig:config];
        }

        string = text != NULL ? [NSString stringWithUTF8String:text] : @"";
        if (string == nil) {
            string = @"";
        }
        [controller setFieldText:string];
        [controller invokeSubmitLikeEnter];
        [controller release];
    }
    fflush(stdout);
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
            "  e.g. quickbar-hotkey cmd+shift+space\n"
            "\n"
            "modes (default: register the hotkey and show the workspace/model/effort popup):\n"
            "  --selftest           register, synthesize one hotkey event, print TRIGGER,\n"
            "                       exit 0 (no UI is created)\n"
            "  --ui-test TEXT       build the popup, set TEXT and submit it, print one\n"
            "                       structured SUBMIT line, exit 0 (no human needed)\n"
            "  --ui-test JSON TEXT  same, after applying the CFG JSON (menus populated and\n"
            "                       the CFG selection preselected)\n"
            "  --cfg JSON           CFG JSON for --ui-test (alternative to the positional\n"
            "                       form); raw JSON or base64-encoded JSON\n"
            "\n"
            "stdin: \"trigger\" shows the popup (like the hotkey);\n"
            "       \"CFG <base64-json>\" updates workspace/model/effort pickers\n"
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

    if (selftest && uiTest) {
        qb_error("invalid-spec", "cannot combine --selftest and --ui-test");
        return QB_EXIT_INVALID_SPEC;
    }
    if (!uiTest && cfgOption != NULL) {
        qb_error("invalid-spec", "--cfg is only valid together with --ui-test");
        return QB_EXIT_INVALID_SPEC;
    }
    if (!uiTest && positionalCount > 1) {
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

    if (uiTest) {
        const char *uiConfig = cfgOption;
        const char *uiText = NULL;
        int extra = positionalCount - 1;

        if (extra == 0) {
            qb_error("invalid-spec", "--ui-test requires a text argument");
            return QB_EXIT_INVALID_SPEC;
        }
        if (extra == 1) {
            uiText = positional[1];
        } else if (extra == 2) {
            if (uiConfig != NULL) {
                qb_error("invalid-spec",
                         "--ui-test got both a positional CFG argument and --cfg");
                return QB_EXIT_INVALID_SPEC;
            }
            uiConfig = positional[1];
            uiText = positional[2];
        } else {
            qb_error("invalid-spec", "too many --ui-test arguments");
            return QB_EXIT_INVALID_SPEC;
        }
        return qb_run_ui_test(uiConfig, uiText);
    }

    return qb_run_interactive(&parsed);
}
