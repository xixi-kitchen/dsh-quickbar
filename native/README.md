# quickbar-hotkey — native popup + global-hotkey helper for `dsh-quickbar` (v4)

One small C/Objective-C binary (no Swift, no Accessibility permission, no
`CGEventTap`, no extra runtime dependencies). It:

1. registers a **single system-wide hotkey** with the macOS Carbon HotKey API,
2. runs a Cocoa (`[NSApp run]`) main loop that keeps Carbon hotkey events flowing,
3. on the hotkey (or a `trigger` line on stdin) shows a lightweight borderless,
   always-on-top **input popup** with **workspace / model / reasoning-effort
   pickers** (floating `NSPanel`, joins all Spaces, fullscreen auxiliary,
   centered in the top third of the primary screen), and
4. reports the typed text plus the three picker values on stdout as one
   structured `SUBMIT` line so the host plugin can submit the query and raise the
   Harness window.

Everything visible is native AppKit; the host plugin spawns this binary and talks
to it over stdout/stderr (protocol) and stdin (control).

## Files

| File | Purpose |
|---|---|
| `quickbar-hotkey.m` | the complete implementation (C/Objective-C) |
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
architecture with an explicit deployment target and combines them with `lipo`:

```sh
/usr/bin/clang -O2 -arch arm64  -mmacosx-version-min=11.0 -o /tmp/qb.arm64  quickbar-hotkey.m -framework Carbon -framework AppKit
/usr/bin/clang -O2 -arch x86_64 -mmacosx-version-min=11.0 -o /tmp/qb.x86_64 quickbar-hotkey.m -framework Carbon -framework AppKit
/usr/bin/lipo -create -output quickbar-hotkey /tmp/qb.arm64 /tmp/qb.x86_64
```

The result is a **universal** Mach-O binary (`arm64` + `x86_64`, minos 11.0), so
the same published npm package works on Apple Silicon and Intel Macs. Override
the deployment floor with `MIN_MACOS=... bash native/build.sh` if needed.

The Swift toolchain on this machine is broken (SDK/toolchain mismatch); do not
convert this helper to Swift. Xcode Command Line Tools are only needed to
**rebuild**; users of the published package run the checked-in universal binary
and need nothing extra. The source stays `-Wall -Wextra` clean.

## CLI

```
quickbar-hotkey <hotkey-spec> [--selftest | --ui-test [CFG_JSON] TEXT]
                [--cfg CFG_JSON]
```

| Mode / flag | Behaviour |
|---|---|
| (default) | register the hotkey, print `READY <pid>`, keep running; hotkey / stdin `trigger` shows the popup; Enter submits, Esc cancels |
| `--selftest` | register, print `READY`, synthesize **one** `kEventHotKeyPressed` and let the handler print `TRIGGER`, then exit 0. **No UI is created**; unchanged automated hotkey acceptance test |
| `--ui-test TEXT` | build the popup, set TEXT and invoke the exact same submit action as Enter, print **one** structured `SUBMIT` line, exit 0 |
| `--ui-test CFG_JSON TEXT` | same, after applying CFG_JSON: the three menus are populated and the CFG `selection` is preselected; the SUBMIT line carries that selection |
| `--cfg CFG_JSON` | alternative way to pass the CFG to `--ui-test` (raw JSON or base64 JSON) |
| `-h` / `--help` | usage on **stderr**, exit 0 (not part of the host protocol) |

`--selftest` and `--ui-test` are mutually exclusive (exit 2 if combined).
Without either flag the helper stays alive until `SIGTERM`/`SIGINT`.

## Popup behaviour

- Borderless / frameless `NSPanel` subclass that can become key (`QBPanel`).
- `NSFloatingWindowLevel`; `NSWindowCollectionBehaviorCanJoinAllSpaces |
  NSWindowCollectionBehaviorFullScreenAuxiliary`; follows the active Space and
  can overlay fullscreen apps.
- Transparent window with a rounded (14 pt), translucent, layer-backed content
  surface and a soft system shadow; ~640×96 pt.
- **Toolbar row of three `NSPopUpButton`s** (compact, 12 pt system font):
  1. **workspace** — uses each workspace's `label`;
  2. **model** — flattened `ProviderName · ModelName` across all providers;
  3. **reasoning effort** — that model's `efforts` (`name`), preselected to the
     model's `defaultEffort` when the model changes or no effort is selected.
  When the model picker changes, the effort menu is rebuilt from the newly
  selected model's `efforts` and defaults to that model's `defaultEffort`.
- Below the toolbar, one single-line `NSTextField` (system font 15 pt) with the
  zh placeholder **“输入问题，回车发送…”** (secondary label colour).
- Centered horizontally in the **top third** of the primary screen
  (`NSScreen.screens[0].visibleFrame`).
- On show: `[NSApp activateIgnoringOtherApps:YES]`, make panel key, focus the
  text field, select any leftover text.
- `Enter` (no IME composition) → hide panel, print one structured `SUBMIT`.
- `Escape` → hide panel, print `CANCEL`.
- After submit/cancel the field is cleared and the app deactivates (best effort)
  so focus can return to the previous app / the Harness window.

Empty menus (before the first CFG arrives) show placeholder entries
`工作区` / `模型` / `推理强度`; submitting then reports `null` for those values.

### IME-aware Enter (important)

The text field's delegate implements
`control:textView:doCommandBySelector:`. For `insertNewline:` it first checks
`[textView hasMarkedText]`:

- **marked text present** (e.g. mid-way through a Chinese composition) → return
  `NO`, i.e. let the input method handle Enter and commit the composition; the
  helper does **not** submit.
- **no marked text** → consume the command and submit the current field text.

`cancelOperation:` (Escape) always cancels.

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
                             "reasoningEffort": <effort id|null>
                         }
CANCEL                   popup cancelled with Escape
ERROR <code> [message]   failure, then exit 3 (2 for invalid-spec)
```

- `READY` is printed only after **both** `InstallEventHandler` and
  `RegisterEventHotKey` return `noErr`; `<pid>` is the helper's process id.
- `TRIGGER` is printed once per hotkey press / stdin trigger, **before** the
  popup is shown; `<epoch-ms>` is `Date.now()`-compatible Unix milliseconds (UTC).
- `SUBMIT` carries compact JSON as **standard base64** of its UTF-8 bytes
  (`NSData base64EncodedStringWithOptions:0`): single line, `+`/`/`/`=` alphabet,
  no spaces or newlines. Decode as UTF-8 JSON. Example:
  `SUBMIT eyJ0ZXh0Ijoi5L2g5aW9Iiwi…` → `{"text":"你好","workspaceId":"ws-2",…}`.
  Missing pickers are `null`. Empty text is still allowed to reach the host
  (the host may ignore it).
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
changes).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | `--selftest` / `--ui-test` succeeded, `--help`, or clean shutdown after SIGTERM/SIGINT |
| `2` | `ERROR invalid-spec …` — spec/CLI/CFG could not be parsed; nothing registered |
| `3` | `ERROR <code> …` — runtime failure (`register-failed`, `handler-failed`, `no-display`, `selftest-failed`) |

## ERROR codes

| Code | When |
|---|---|
| `invalid-spec` | malformed/unsupported spec, CLI arguments, or `--ui-test` CFG |
| `register-failed <OSStatus>` | `RegisterEventHotKey` failed; status is the raw `OSStatus` |
| `handler-failed <OSStatus>` | `InstallEventHandler` failed, or the synthetic event could not be created/sent |
| `no-display` | no active GUI login session (`CGSessionCopyCurrentDictionary` is NULL), e.g. a plain ssh shell — a global hotkey/popup cannot work there |
| `selftest-failed <message>` | `--selftest` dispatched the synthetic event without error but no handler ran (should not happen; signals a logic regression) |

## Runtime behaviour / design notes

- Main loop: `[NSApplication sharedApplication]`, activation policy
  `NSApplicationActivationPolicyAccessory` (no Dock icon), then `[NSApp run]`.
  The Carbon hotkey handler is installed on `GetApplicationEventTarget()`; Cocoa's
  run loop pumps Carbon events, so hotkey presses still reach it (verified by
  posting a queued `kEventHotKeyPressed` through `PostEventToQueue` under
  `[NSApp run]`).
- The popup (and its three menus) is built once, before `READY`, so the first
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
- macOS may print keyboard-layout/TSM diagnostics on stderr when an AppKit/Carbon
  process starts using input sources (e.g. `TISFileInterrogator …`,
  `Keyboard Layouts: duplicate keyboard layout identifier …`). They come from the
  OS, are harmless, and never appear on stdout.
- The binary never writes files, never forks, and does not daemonise.

## Automated checks

```sh
# all automated acceptance checks (build, selftest, structured ui-test with CFG
# selections/base64/JSON escaping, invalid specs, stdin CFG+trigger, SIGTERM/SIGINT,
# grammar matrix, binary/source shape)
bash native/check.sh

# or individually:
native/quickbar-hotkey cmd+shift+space --selftest          # READY + TRIGGER, exit 0
native/quickbar-hotkey cmd+shift+space --ui-test "你好"    # one structured SUBMIT, exit 0
native/quickbar-hotkey cmd+shift+space --ui-test "你好" | sed 's/^SUBMIT //' | base64 -D
#   -> {"text":"你好","workspaceId":null,...}   (no CFG -> null selection)
native/quickbar-hotkey cmd+shift+space --ui-test "$CFG_JSON" "你好" | sed 's/^SUBMIT //' | base64 -D
#   -> {"text":"你好","workspaceId":"ws-2","provider":"anthropic",...}
native/quickbar-hotkey 'bad+spec'; echo "exit=$?"          # ERROR invalid-spec, exit 2

# long-running mode: READY, stays alive, clean SIGTERM exit
native/quickbar-hotkey cmd+shift+space &
pid=$!
sleep 3; kill -0 "$pid" && echo alive; kill -TERM "$pid"; wait "$pid"; echo "exit=$?"
```

`check.sh` briefly shows the popup once (the stdin `trigger` test), then hides it
by terminating the helper. JSON assertions use `python3`.

## What only a human can confirm

The pickers are native `NSPopUpButton`s, but opening a menu, choosing an item and
keyboard navigation cannot be scripted here without Accessibility permission.
Please confirm manually:

1. Press the global hotkey **from another app**: the popup appears with the three
   pickers reflecting the remembered selection (`CFG`) and takes keyboard focus;
   the text field is focused so typing goes straight in.
2. **Pickers behave normally**: clicking each shows its menu with the expected
   items (`Provider · Model` flattened for the model picker), selection changes
   are reflected in the button title, and keyboard/menu navigation looks right.
3. **Changing the model rebuilds the effort picker** from that model's efforts
   and preselects its `defaultEffort` (and changing the effort/workspace sticks
   until submit).
4. **Chinese IME composition** works: Enter mid-composition commits the
   composition instead of submitting; a second Enter submits.
5. Enter submits and the main Harness window opens with the answer in the chosen
   workspace/model/effort (host/client behavior); Esc cancels and focus returns
   hand to the previous app.
6. Popup placement/look (rounded panel, shadow, exact dropdown appearance,
   top-third position, light/dark appearance) is acceptable; it appears on the
   current Space including over fullscreen apps, and on the expected display when
   multiple displays are attached.
