# quickbar-hotkey — native command palette + global-hotkey helper for `dsh-quickbar` (v5)

One small C/Objective-C binary (no Swift, no Accessibility permission, no
`CGEventTap`, no extra runtime dependencies). It:

1. registers a **single system-wide hotkey** with the macOS Carbon HotKey API,
2. runs a Cocoa (`[NSApp run]`) main loop that keeps Carbon hotkey events flowing,
3. on the hotkey (or a `trigger` line on stdin) shows a lightweight borderless,
   always-on-top **command palette** (`native/DESIGN.md` is the authoritative
   visual/interaction spec): material card, three pill selectors
   (workspace / model / reasoning effort), multi-line input, pasted-image chips
   and a footer with key hints plus an accent Send pill, and
4. reports the typed text, the three picker values and any pasted images on
   stdout as one structured `SUBMIT` line; the host then acknowledges the
   submission over the helper's stdin (`SUBMIT_OK` / `SUBMIT_FAIL`).

Everything visible is native AppKit; the host plugin spawns this binary and talks
to it over stdout/stderr (protocol) and stdin (control).

## Files

| File | Purpose |
|---|---|
| `quickbar-hotkey.m` | the complete implementation (C/Objective-C) |
| `DESIGN.md` | the authoritative visual/interaction spec this pass implements |
| `build.sh` | builds a universal `quickbar-hotkey` with `/usr/bin/clang` + `lipo`; prints its absolute path |
| `quickbar-hotkey` | built **universal** Mach-O binary (arm64 + x86_64) the host spawns (never edit by hand; rebuild) |
| `check.sh` | automated acceptance checks (`bash native/check.sh`) |
| `README.md` | this document |

## Build

```sh
bash native/build.sh
# -> /absolute/path/to/quickbar/native/quickbar-hotkey
```

The script is idempotent, can be run from any directory, prints the absolute
binary path, and exits non-zero on failure. It compiles one slice per
architecture with an explicit deployment target (`-Wall -Wextra` clean) and
combines them with `lipo`:

```sh
/usr/bin/clang -O2 -Wall -Wextra -arch arm64  -mmacosx-version-min=11.0 -o /tmp/qb.arm64  quickbar-hotkey.m -framework Carbon -framework AppKit -framework QuartzCore
/usr/bin/clang -O2 -Wall -Wextra -arch x86_64 -mmacosx-version-min=11.0 -o /tmp/qb.x86_64 quickbar-hotkey.m -framework Carbon -framework AppKit -framework QuartzCore
/usr/bin/lipo -create -output quickbar-hotkey /tmp/qb.arm64 /tmp/qb.x86_64
```

The result is a **universal** Mach-O binary (`arm64` + `x86_64`, minos 11.0), so
the same published npm package works on Apple Silicon and Intel Macs. Override
the deployment floor with `MIN_MACOS=... bash native/build.sh` if needed.

The Swift toolchain on this machine is broken (SDK/toolchain mismatch); do not
convert this helper to Swift. Xcode Command Line Tools are only needed to
**rebuild**; users of the published package run the checked-in universal binary
and need nothing extra. `QuartzCore` is linked for the `CAMediaTimingFunction`
used by the open animation.

## CLI

```
quickbar-hotkey <hotkey-spec> [--selftest | --ui-test [CFG_JSON] TEXT]
                [--cfg CFG_JSON]
quickbar-hotkey <hotkey-spec> --ui-test-ack [CFG_JSON] TEXT
quickbar-hotkey <hotkey-spec> --interaction-test
```

| Mode / flag | Behaviour |
|---|---|
| (default) | register the hotkey, print `READY <pid>`, keep running; hotkey **toggles** the palette (`trigger` on stdin shows it); Enter submits, Esc cancels, clicking outside closes |
| `--selftest` | register, print `READY`, synthesize **one** `kEventHotKeyPressed` and let the handler print `TRIGGER`, then exit 0. **No UI is created**; unchanged automated hotkey acceptance test |
| `--ui-test TEXT` | build the palette, set TEXT and invoke the exact same submit action as Enter, print **one** structured `SUBMIT` line, exit 0 |
| `--ui-test CFG_JSON TEXT` | same, after applying CFG_JSON: the three pill menus are populated and the CFG `selection` is preselected; the SUBMIT line carries that selection |
| `--ui-test-ack [CFG_JSON] TEXT` | like `--ui-test` (still exactly one `SUBMIT` on stdout), then **enters the sending state and waits on stdin** for `SUBMIT_OK` / `SUBMIT_FAIL` (or the ack timeout); prints `quickbar-hotkey: ui-test-ack …` on stderr and exits 0. Automated proof of the sending → sent/error lifecycle |
| `--interaction-test` | no-hotkey self-check: toggle / draft preservation / Esc-clear / ⌘V-image chips + 4-image cap + remove / auto-grow to 5 lines / Shift+Enter / sending state / DESIGN.md constants. Prints `INTERACTION ok: …` lines on stderr, exits 0 (3 if any assertion fails) |
| `--cfg CFG_JSON` | alternative way to pass the CFG to `--ui-test` / `--ui-test-ack` (raw JSON or base64 JSON) |
| `-h` / `--help` | usage on **stderr**, exit 0 (not part of the host protocol) |

The modes are mutually exclusive (exit 2 if combined). Without any flag the
helper stays alive until `SIGTERM`/`SIGINT`.

## Popup behaviour (DESIGN.md)

- Borderless / frameless `NSPanel` subclass that can become key (`QBPanel`),
  `NSFloatingWindowLevel`, `CanJoinAllSpaces | FullScreenAuxiliary`,
  `movableByWindowBackground`, no window animation.
- **Material card**: `NSVisualEffectView` with `material = .popover`
  (follows light/dark system appearance), `blendingMode = .behindWindow`,
  rounded to **16 pt** (`layer.cornerRadius`, `masksToBounds`), **single
  elevation** from AppKit's window shadow (`hasShadow`), **no outer border**.
  The card is **640 pt** wide (`min(640, screenWidth - 96)`) and its height
  follows the content: vertical inset 16 + toolbar 26 + gap 12 + input
  (44 min, auto-grow to 5 lines) + optional image strip 64 + optional error row
  + gap 12 + footer 26 + vertical inset 16 → the empty single-line card is
  **152 pt** tall (the interaction self-check asserts this).
- **Pill selector row** (26 pt tall, radius 13): three borderless
  `NSPopUpButton`s (workspace / model `Provider · Model` / reasoning effort),
  each inside a pill with a 11 pt secondary caption (`工作区` / `模型` / `思考`),
  13 pt medium button text, 8 pt `chevron.down` SF Symbol on the right, and a
  subtle hover fill (8 % → 12 %). When the model changes, the effort menu is
  rebuilt from that model's `efforts` and defaults to its `defaultEffort`.
- **Multi-line input**: `NSScrollView` + transparent plain-text `NSTextView`
  (`drawsBackground = NO`, `isRichText = NO`, smart quotes/dashes/text
  replacement/spelling off), 17 pt with 4 pt line spacing. It auto-grows from
  44 pt to 5 lines (~126 pt) and then scrolls internally; the card grows with it.
  A 2 pt rounded focus ring in 18 % `controlAccentColor` is drawn behind the
  text while the input is focused, and the placeholder
  “输入问题，回车发送…” is drawn in `placeholderTextColor`.
- **Text behaviours**: Enter sends (IME-aware), Shift+Enter inserts a line
  break, Esc closes and clears, ⌘V with an image on the pasteboard attaches a
  **56×56 rounded thumbnail chip** (max 4, hover-only × remove button); ⌘V with
  plain text pastes text. A file-only clipboard gets an inline “no file
  attachments” hint instead of attaching a file.
- **Footer**: left `⌘V 粘图`, right
  `Enter 发送 · Shift+Enter 换行 · Esc 关闭`, separated from the content above by
  a 1 px `separatorColor` line (12 % alpha); the **accent Send pill** (26 pt,
  `controlAccentColor` at rest, 13 pt medium `发送`) sits on the right and has
  four states: disabled (`quaternaryLabelColor` fill, tertiary text), normal,
  sending (14 pt white-tinted spinner), sent (150 ms `systemGreen` checkmark).
- **Motion ≤ 250 ms**: open = 180 ms ease-out (opacity 0→1, 6 pt upward shift,
  card scale 0.98→1); close = 120 ms ease-in fade; success holds the checkmark
  for 150 ms and then closes. Motion only expresses state.
- **Open / close / toggle**: the global hotkey opens the panel when hidden and
  hides it when visible (never submits; the draft is preserved). `trigger` on
  stdin always shows the panel (v4 semantics). Esc hides + clears + emits
  `CANCEL`. Clicking outside hides and clears (`windowDidResignKey`; opening a
  selector menu does not trigger it). While a submission is waiting for the
  host ack the panel stays open and the input is disabled.
- **Position**: the dragged origin is remembered under the `NSUserDefaults` key
  `quickbar.popup.origin` as `x,y,displayId`. Reopening on the same display
  restores (and clamps) that position; when no position is saved or the saved
  display is gone, the panel is centered in the top third of the screen under
  the mouse pointer.
- Empty menus (before the first CFG arrives) show placeholder entries
  `工作区` / `模型` / `推理强度`; submitting then reports `null` for those values.

### IME-aware Enter (important)

`QBPasteTextView` handles Return / keypad Enter before the key binding system:
with `hasMarkedText` true (e.g. mid-way through a Chinese composition) the
event is passed to AppKit/IME instead, so Enter commits the composition and
does **not** submit. Without marked text, Enter sends and Shift+Enter inserts a
newline. The text-view delegate also intercepts `cancelOperation:` (Escape).

## Hotkey spec grammar

One or more modifiers followed by exactly one key, lowercase and `+`-separated
(tokens are matched case-insensitively and surrounding whitespace per token is
trimmed, so `Cmd + Shift + Space` also parses). **At least one modifier is
required** — a bare `space` or `a` would hijack normal typing system-wide and is
rejected.

| Modifiers | Aliases |
|---|---|
| Command | `cmd`, `command` |
| Shift | `shift` |
| Option | `opt`, `alt`, `option` |
| Control | `ctrl`, `control` |

| Key | Tokens |
|---|---|
| Letters | `a` … `z` |
| Digits | `0` … `9` |
| Space / Tab | `space`, `tab` |
| Return | `return`, `enter` |
| Escape | `escape`, `esc` |
| Function keys | `f1` … `f12` |
| Punctuation | `comma`, `period`, `slash`, `minus`, `backtick` |
| Arrows | `left`, `right`, `up`, `down` |

Examples: `cmd+shift+space`, `shift+f9`, `ctrl+alt+minus`, `option+backtick`.

Invalid specs print `ERROR invalid-spec <reason>` and exit **2** — no hotkey is
registered. Rejected examples: empty string, `off`, `none`, `disabled`, `space`
(no modifier), `cmd` (no key), `cmd+shift` (no key), `cmd+shift+space+tab` (two
keys), `cmd++space` (empty token), `cmd+cmd+space` (duplicate modifier),
`hyper+space` (unknown token).

## stdout protocol (line-based, every line flushed)

```
READY <pid>              hotkey registered + event handler installed
TRIGGER <epoch-ms>       hotkey pressed (physical, synthesized, or stdin `trigger`)
SUBMIT <base64-json>     popup submitted; payload = {
                           "text": <utf8 string>,
                           "workspaceId": <id|null>,
                           "provider": <provider id|null>,
                           "model": <model id|null>,
                           "reasoningEffort": <effort id|null>,
                           "images": [
                             {"mediaType": "image/png"|"image/jpeg",
                              "base64": <standard base64 of the image bytes>,
                              "name": "pasted-image-1.png",
                              "width": <pixels>, "height": <pixels>}
                           ]
                         }
CANCEL                   popup cancelled with Escape
ERROR <code> [message]   failure, then exit 3 (2 for invalid-spec)
```

- `READY` is printed only after **both** `InstallEventHandler` and
  `RegisterEventHotKey` return `noErr`; `<pid>` is the helper's process id.
- `TRIGGER` is printed once per hotkey press / stdin trigger, **before** the
  popup is shown or toggled; `<epoch-ms>` is `Date.now()`-compatible Unix
  milliseconds (UTC).
- `SUBMIT` carries compact JSON as **standard base64** of its UTF-8 bytes
  (`NSData base64EncodedStringWithOptions:0`): single line, `+`/`/`/`=` alphabet,
  no spaces or newlines. Decode as UTF-8 JSON. Example:
  `SUBMIT eyJ0ZXh0Ijoi5L2g5aW9Iiwi…` → `{"text":"你好","workspaceId":"ws-2",…,"images":[]}`.
  Missing pickers are `null`; `images` is always present (empty array when no
  image was pasted).
- `CANCEL` has no payload.
- stdout is used for protocol lines **only**; diagnostics go to stderr.
- SIGPIPE is ignored, so a dead host pipe cannot kill the helper through a
  stdout write.

## stdin control

The helper reads stdin line by line on a background queue (the UI loop is never
blocked) and accepts:

```
trigger                 show the popup, exactly like pressing the hotkey
                        (also prints TRIGGER first)
CFG <base64-json>       update the workspace/model/effort pickers
SUBMIT_OK               the host accepted the submission: the send pill shows its
                        checkmark for 150 ms, then the panel closes and clears
SUBMIT_FAIL <text>      the host rejected it: the inline red error row shows
                        <text> (or a generic message), the typed text is kept and
                        the input is re-enabled for a retry
```

`CFG` payload (standard base64 of UTF-8 JSON):

```json
{
  "workspaces": [{"id": "ws-id", "label": "Label", "path": "/abs/path"}],
  "models": [{
    "provider": {"id": "provider-id", "name": "Provider Name"},
    "models": [{
      "id": "model-id",
      "name": "Model Name",
      "efforts": [{"id": "low", "name": "Low"}, {"id": "high", "name": "High"}],
      "defaultEffort": "low"
    }]
  }],
  "selection": {
    "workspaceId": "ws-id",
    "provider": "provider-id",
    "model": "model-id",
    "reasoningEffort": "high"
  }
}
```

On `CFG` the three menus are rebuilt and the `selection` is preselected
(`null`/missing values fall back to the first workspace, the first model and its
`defaultEffort`; an unknown id falls back the same way). A `CFG` line produces
**no stdout output**. Malformed base64/JSON is reported on stderr and ignored.
Blank lines, EOF and unknown commands are ignored (the helper keeps running; the
host usually pushes one `CFG` right after `READY` and again on selection
changes). `SUBMIT_OK`/`SUBMIT_FAIL` lines are ignored when no submission is
waiting for an ack.

The ack timeout is **15 s**; if the host never acknowledges, the panel shows the
inline error “发送超时，请检查连接后重试” and keeps the text. The integration
test shortens it with `QUICKBAR_ACK_TIMEOUT_MS` (milliseconds).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | `--selftest` / `--ui-test` / `--ui-test-ack` / `--interaction-test` succeeded, `--help`, or clean shutdown after SIGTERM/SIGINT |
| `2` | `ERROR invalid-spec …` — spec/CLI/CFG could not be parsed; nothing registered |
| `3` | `ERROR <code> …` — runtime failure (`register-failed`, `handler-failed`, `no-display`, `selftest-failed`), or `--interaction-test` assertion failure |

## ERROR codes

| Code | When |
|---|---|
| `invalid-spec` | malformed/unsupported spec, CLI arguments, or `--ui-test` CFG |
| `register-failed <OSStatus>` | `RegisterEventHotKey` failed; status is the raw `OSStatus` |
| `handler-failed <OSStatus>` | `InstallEventHandler` failed, or the synthetic event could not be created/sent |
| `no-display` | no active GUI login session (`CGSessionCopyCurrentDictionary` is NULL), e.g. a plain ssh shell — a global hotkey/popup cannot work there |
| `selftest-failed <message>` | `--selftest` dispatched the synthetic event without error but no handler ran (should not happen; signals a logic regression) |
| `submit-failed <message>` | the structured SUBMIT payload could not be encoded (should not happen) |

## Runtime behaviour / design notes

- Main loop: `[NSApplication sharedApplication]`, activation policy
  `NSApplicationActivationPolicyAccessory` (no Dock icon), then `[NSApp run]`.
  The Carbon hotkey handler is installed on `GetApplicationEventTarget()`; Cocoa's
  run loop pumps Carbon events, so hotkey presses still reach it (verified by
  posting a queued `kEventHotKeyPressed` through `PostEventToQueue` under
  `[NSApp run]`).
- The panel (and its three menus) is built once, before `READY`, so the first
  hotkey press is instant; `CFG` lines then repopulate the menus on the main
  thread.
- SIGTERM / SIGINT: the signal handler only sets a flag (AppKit/Carbon calls are
  not async-signal-safe); a 100 ms CFRunLoop timer on the main run loop notices
  the flag, unregisters the hotkey, removes the event handler, flushes stdout and
  exits 0. If the timer cannot be installed the handler falls back to a direct
  synchronous cleanup/exit. Signal handlers are installed at process start, so a
  helper killed before `READY` also exits 0.
- Exactly one hotkey per process; the host restarts the helper when the
  configured hotkey changes.
- No Accessibility/Input Monitoring permission is needed: Carbon
  `RegisterEventHotKey` is not a `CGEventTap` and requires no TCC grant.
- Picker changes are local until submit: the helper does **not** push selection
  changes back to the host on its own; the host learns them from `SUBMIT` and
  then pushes a fresh `CFG`.
- A global-hotkey press is user intent, so showing the panel calls
  `-[NSApplication activateIgnoringOtherApps:]` and makes the panel key so the
  input receives typing immediately; hiding hands activation back. (Focus
  stealing is intentional for a command palette; if another app grabs focus the
  panel closes.)
- macOS may print keyboard-layout/TSM diagnostics on stderr when an AppKit/Carbon
  process starts using input sources (e.g. `TISFileInterrogator …`,
  `Keyboard Layouts: duplicate keyboard layout identifier …`). They come from the
  OS, are harmless, and never appear on stdout.
- The binary never writes files (apart from `NSUserDefaults`), never forks, and
  does not daemonise.

## Automated checks

```sh
# all automated acceptance checks (build twice/idempotent, universal binary,
# -Wall -Wextra clean source, selftest, structured ui-test with CFG selections and
# images:[], invalid specs, stdin CFG+trigger+ack line discipline, SUBMIT_OK /
# SUBMIT_FAIL / timeout lifecycle, interaction self-check (toggle/draft/Esc/paste
# chips/auto-grow/Shift+Enter/design constants), SIGTERM/SIGINT, grammar matrix,
# implementation constraints)
bash native/check.sh
```

`check.sh` briefly shows the popup during the stdin-trigger/interaction checks,
then hides it by terminating the helper. JSON assertions use `python3`.

## What only a human can confirm

The checks above are scripted, but a few things need eyes and a real keyboard
(no Accessibility permission, so menus/clicks/IME cannot be scripted):

1. **Visual look** in light and dark appearance: the material card's soft shadow
   and 16 pt corners, the pill row with hover, the accent Send pill (normal /
   sending spinner / sent checkmark / disabled), the focus ring, the inline red
   error row, and the 180 ms open / 120 ms close motion feel right and adapt to
   the system theme.
2. **Chinese IME**: typing `nihao` and pressing Enter mid-composition commits
   the composition (no premature submit); a second Enter sends. Smart quotes are
   off.
3. **Focus stealing**: pressing the global hotkey from another app puts the caret
   into the input immediately; closing gives focus back to the previous app.
4. **Click outside / toggle / Esc**: clicking another app or the desktop closes
   the panel; pressing the hotkey again closes it (draft kept); Esc clears it;
   opening a selector menu does not close the panel.
5. **Drag position persistence**: drag the panel, close and reopen — it should
   come back at the same spot, and after a display change / display unplug it
   should fall back to the top-third center of the screen under the pointer.
6. **Multi-display / fullscreen Spaces**: the panel appears on the display it
   was last used on (or under the pointer the first time), joins all Spaces and
   can overlay a fullscreen app.
7. **Picker menus**: clicking each pill shows the expected items, keyboard
   navigation works, and changing the model rebuilds the effort list.

## Deviations from DESIGN.md (deliberate, AppKit limitations)

- **Shadow**: DESIGN.md specifies a custom soft shadow (offset `(0,-10)`,
  blur `28`, alpha `0.30`/`0.45`). The implementation uses AppKit's single
  window-server shadow (`panel.hasShadow`, invalidated on resize) with the card
  exactly window-sized and borderless. A custom layer shadow would require a
  transparent click-swallowing padding around the card (clicks in that halo would
  not reach the app below), which is worse for a floating palette; the
  single-elevation / no-border intent is preserved.
- **Sending spinner**: `NSProgressIndicator` has no public tint API, so the
  14 pt spinner is drawn in the button (8 fading dots in
  `alternateSelectedControlTextColor`, i.e. white on the accent fill) instead of
  embedding an untintable `NSProgressIndicator`.
- **Inline error reuse**: the inline red row is also used for transient paste
  hints (max 4 images / no file attachments), not only for submit failures.
- **Draft clearing**: hiding by hotkey toggle keeps the draft (useful for a quick
  interruption); Esc and outside-click clear it. DESIGN.md only specifies clearing
  for Esc.
- **Send requires text**: the Send pill enables once the trimmed input is
  non-empty; pasted images ride along with the text (the host ignores empty-text
  submissions, so image-only sends would otherwise time out). The `SUBMIT`
  payload still always carries an `images` array.
