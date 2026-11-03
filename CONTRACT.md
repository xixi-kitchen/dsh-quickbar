# dsh-quickbar — shared contract (read first)

Goal: a persistent Harness bundle named `dsh-quickbar` that gives the user a **system-wide
global hotkey** (default `cmd+shift+space`). Pressing it:

1. raises/focuses the DeepSeek Harness desktop window (`open dsh://open`),
2. pushes a `toggle` event to every connected Web page,
3. the page shows a **quick input overlay** (centered floating composer),
4. typing a query + Enter sends it as a prompt to the current Session (or creates one),
   Esc / backdrop click closes the overlay.

All work happens in this directory: `<workspace>/quickbar/`. It is a **linked local
bundle**: `plugin_manager install_bundle` links this directory into the profile. So:
no build step, no dependencies to install. Plain ESM JavaScript + one small native C
helper. Do NOT write `~/.dsh/profiles/desktop/*` yourself.

Environment facts (already verified by the Lead):

- macOS arm64, `/usr/bin/clang` works for ObjC/C (Swift toolchain is broken — use C/ObjC
  only, no Swift).
- The Electron shell registers the custom URL scheme `dsh://`; `open dsh://open`
  restores/minimizes-aware focuses the primary window (`focusPrimaryWindow`).
- The Host runs as a child of the Electron main process. It has `ctx.subprocess`
  (`spawn` with piped stdout) and can import `node:*`.
- A bare `@deepseek-ai/*` import from this linked directory resolves against the dsh
  installation **only if the name is listed in this package's `peerDependencies`**
  (verified in dsh-app-boot's profile-resolution-bootstrap). Keep the peer list minimal
  and exact.
- The working precedent for host→client remotes in this very profile is
  `~/.dsh/profiles/desktop/node_modules/@zzerx/dsh-plugin-notes/lib/index.js` (host) and
  `.../lib/client.js` (client). Read them; copy the pattern, not the content.
- Slot `shell.overlay` exists (kind `list`, root scope, click-through layer). Register
  with `{id, order}` there. Theme tokens are `--dsw-alias-*` only; never literal colors
  in the overlay chrome.

## File ownership (do not edit another owner's files)

| Owner | Files |
|---|---|
| hotkey-helper | `native/**` (source, build.sh, built binary) |
| host-plugin | `index.js`, `package.json`, `cordis.patch.yml`, `locale/en.json`, `locale/zh.json`, `icon.svg` |
| client-plugin | `client.js` |
| lead | `CONTRACT.md`, `README.md`, installation, integration fixes |

Write only inside your own files. Report shared-file needs to the Lead.

## Bundle identity

- package name: `dsh-quickbar`
- loader row id: `quickbar` (cordis.patch.yml `insert` row `id: quickbar`)
- client module id in `window.__ModuleLoader__.load({id: 'dsh-quickbar', ...})` must equal
  the package name.
- Remote service name: `quickbar` → host `ctx.quickbar`, client `ctx.remote.quickbar`.

## Host plugin (`index.js`)

Exports: `export const Config`, `export const inject = ['subprocess']`,
`export async function apply(ctx, config)`.

`Config` = schemastery object (import `Schema from '@deepseek-ai/schemastery'`; list it in
peerDependencies):

```js
Config = Schema.object({
  enabled:        Schema.boolean().default(true).volatile(),
  hotkey:         Schema.string().default('cmd+shift+space').volatile(),
  raiseWindow:    Schema.boolean().default(true).volatile(),
  inAppShortcut:  Schema.string().default('cmd+shift+k').volatile(), // read by client only
})
```

Behavior of `apply`:

1. Instantiate the remote service: `class QuickbarService extends TypertRemoteService`
   with `super(ctx, 'quickbar')`, then `markRemoteMethods(QuickbarService.prototype, [...])`
   exactly like the notes plugin does (declare `@deepseek-ai/dsh-typert-protocol` in
   peerDependencies; the `REMOTE_METHODS` symbol trick must be copied verbatim).
2. Spawn the native helper (only when `config.enabled` and `process.platform === 'darwin'`
   and the binary exists). Use `ctx.subprocess.spawn`:
   - `argv: [helperPath, resolvedHotkeySpec]`
   - `cwd: os.homedir()`
   - `stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, graceMs: 2000`
   - Parse `handle.stdout` **line by line** (`node:readline` or manual buffering).
   - `READY <pid>` → state `ready`; `TRIGGER <ms>` → `fireTrigger()`; `ERROR <code> <msg>`
     → state `error` with message; process exit → `error`/`starting` + restart with backoff
     (3 attempts, 1s/2s/4s), then give up and record the message.
   - Kill the helper on disposal (`ctx.effect` disposer → `handle.terminate()`), and do not
     leak timers.
3. `fireTrigger()` (also used by `testTrigger`):
   - increment `nonce`, set `lastTriggerAt = Date.now()`, keep `pendingToggle = {nonce, at}`
     for late/absent clients,
   - broadcast `{type:'toggle', nonce, at}` to every open `watch` subscriber,
   - if `config.raiseWindow`, best-effort spawn `open dsh://open` (argv `['/usr/bin/open',
     'dsh://open']` via ctx.subprocess, stdio ignore/inherit/collect — must never throw or
     block the trigger; catch and log at warn level).
4. Keep everything that can throw inside try/catch: a missing binary, a failed spawn, or a
   missing `subprocess` service must degrade to `hotkeyState: 'error'|'disabled'`, never
   crash the Host. `apply` must be re-entrant: config changes reload the row, so all
   timers/processes must be owned by `ctx.effect`/`ctx.on` disposers.

Remote methods (wire names = parameter names, never destructured):

- `getState()` → `QuickbarState` (direct)
- `testTrigger()` → `{ ok: true }` — same effect as pressing the hotkey
  (`fireTrigger()`), for the settings page button
- `async *watch(signal)` → stream, cancellation parameter `signal`; on connect first yield
  the current `QuickbarState`, then each status change and each toggle event. Must settle
  promptly when `signal` aborts (race the wait against abort, exactly like notes'
  `watch`).

Wire types (client descriptors must match exactly):

```ts
type QuickbarState = {
  enabled: boolean;
  hotkey: string;                     // configured spec, e.g. 'cmd+shift+space'
  hotkeyState: 'disabled' | 'starting' | 'ready' | 'error';
  hotkeyError: string | null;
  helperPid: number | null;
  platform: string;                   // process.platform
  lastTriggerAt: number | null;
  pendingToggle: { nonce: number; at: number } | null;
};
type QuickbarEvent =
  | { type: 'toggle'; nonce: number; at: number }
  | { type: 'status'; state: QuickbarState };
```

Also export a plain (non-remote) method or reuse `getState` for `hotkeyState` status.

## Native helper (`native/quickbar-hotkey`, built binary; source in `native/`)

ObjC/C, compiled with `clang -O2 -o quickbar-hotkey quickbar-hotkey.m -framework Carbon -framework AppKit`.
Build script `native/build.sh` must be idempotent and print the binary path.

CLI: `quickbar-hotkey <hotkey-spec> [--selftest]`

Hotkey spec grammar (lowercase, `+`-separated): modifiers `cmd|command|shift|opt|alt|option|ctrl|control`
followed by one key: `a-z`, `0-9`, `space`, `tab`, `return|enter`, `escape|esc`, `f1..f12`,
`comma|period|slash|minus`, `backtick`, `left|right|up|down`. Empty or `off|none|disabled`
→ print `ERROR invalid-spec` and exit 2 (do not register).

Protocol on **stdout**, one line each, flushed:
- `READY <pid>` after `RegisterEventHotKey` + `InstallEventHandler` succeed (noErr),
- `TRIGGER <epoch-ms>` on every hotkey press,
- `ERROR <code> <message>` on failure (codes: `invalid-spec`, `register-failed <OSStatus>`,
  `handler-failed <OSStatus>`, `no-display`), then exit 3.

`--selftest`: parse the spec, register, print `READY`, synthesize one
`kEventHotKeyPressed` for the registered id via `SendEventToEventTarget`
(so the handler runs), print `TRIGGER <ms>` from the handler, then exit 0. This is the
automated acceptance test (real physical presses cannot be automated on this machine).

Constraints: no Swift; no accessibility permission; `RunApplicationEventLoop()` keeps the
process alive and must be pumped from the main thread; SIGTERM/SIGINT → `UnregisterEventHotKey`,
`fflush`, exit 0. stderr may carry diagnostics only.

## Client plugin (`client.js`)

Plain module in this exact shape:

```js
window.__ModuleLoader__.load({
  id: 'dsh-quickbar',
  factory(require) { /* require('react'), require('react/jsx-runtime') are available */
    return { inject: [...], apply(ctx) { ... } };
  },
});
```

Requirements:

1. Mount the host descriptors once (copy notes' `$mount` call shape):

```js
await ctx.remote.$mount({
  package: 'dsh-quickbar',
  descriptors: [
    // getState / testTrigger: mode 'src-json', invocation {kind:'direct'}, parameters []
    // watch: same + mode 'stream' + cancellation { parameter: 'signal' }
  ],
});
```

Then use `ctx.remote.quickbar.getState()`, `.testTrigger()`, and
`for await (const item of ctx.remote.quickbar.watch(signal))`.

2. Register the overlay in `shell.overlay` via `ctx.slots.inject('shell.overlay', () =>
   ctx.slots.register({name:'shell.overlay', id:'quickbar-overlay', order: 500}, Component))`.
   Component rendered only while open; the layer is click-through, so the open overlay
   itself must set `pointerEvents: 'auto'` on its backdrop.
3. Overlay UX:
   - fixed backdrop, subtle scrim, centered card (max width ~640px) near the top third,
   - one-line text input (`textarea` growing to 3 lines is fine), placeholder via locale,
   - hint row: `Enter` send, `Esc` close, plus hotkey badge from state,
   - auto-focus on open, restore focus on close,
   - `Enter` (without Shift) sends; `Shift+Enter` newline; `Esc` closes
     (stopPropagation so Harness shortcuts do not fire); backdrop click closes,
   - while sending: spinner/disabled; on failure show the error inline and keep the text,
   - completely remove listeners on unmount; no DOM writes outside the component.
4. Submit target — resolve in this order (verify against the live page, then document):
   a. current Session: use the session-bound facilities available to a root slot
      (`props.usePanelInfo` / `props.useSessions` / `props.useSessionStatus`, and/or a tiny
      session-scoped probe registration in `conversation.composer.dock` that records the
      active `sessionId` in a module-level store). Then
      `ctx.sessions.retain(sessionId, {source:'controllerOperation'})`, `await ref.ready`,
      `const h = ref.session.beginSubmission({mode:'queue', text, attachments: []})`,
      `await ref.session.prompt([{type:'text', text}], 'queue', undefined, h.requestId)`,
      `ref.release()`.
   b. no open Session: create one with
      `ctx.sessions.create({})` → `openSession` via `ctx.uiWorkspace.openSession(id)` →
      same prompt path.
   c. if every path is unavailable, fall back to
      `ctx.uiWorkspace.startSession(undefined, {prompt: text, whenDraftExists: 'replace'})`
      and close the overlay (text lands in the composer draft).
   Never throw to the Console; surface a locale string in the overlay error row instead.
5. Trigger sources (all call the same `open()`):
   - host stream `toggle` events (dedupe by `nonce`; ignore a nonce already handled),
   - on mount, `getState()`: if `pendingToggle` is < 15s old and its nonce is unseen, open
     (covers the "window was closed when the hotkey fired" case),
   - in-app fallback: `keydown` listener on `window` for `state.inAppShortcut`
     (default `cmd+shift+k`), ignore when the event target is inside the overlay, ignore
     when another modal likely owns focus only if straightforward, and never fight the
     host's own `Cmd+K` (different combo),
   - a `testTrigger()` call from the settings page.
6. Settings page: register in `settings.section` (id `quickbar`, order ~60, label via
   locale) with:
   - hotkey recorder input: focus it, press a combo, store `cmd+shift+space`-style spec,
     show it as `⌘⇧Space`; only combos the helper supports (modifier + one key),
   - status line from `getState()`: ready / starting / error (+ `hotkeyError`),
     "保存后立即生效" note,
   - `raiseWindow` toggle, `inAppShortcut` recorder (optional but cheap),
   - "测试" button → `ctx.remote.quickbar.testTrigger()`,
   - write config through `configForms`: `ctx.inject(['configForms'], c =>
     c.configForms.get('quickbar'))`, `form.getSnapshot().value`, `form.set('hotkey', spec)`
     (follow notes' settings code for the exact API and read-only/writable handling),
   - host must call `ctx.settings.configure({auto:false}, ctx.fiber)` when the `settings`
     service exists (notes' `configureNotesSettingsPage`) so there is only one settings page.
7. Localization: register through `ctx.locale` (`ctx.inject(['locale'])`,
   `ctx.locale.register('quickbar', locale, dict)` or `ctx.locale.bind('quickbar')` — copy
   the exact call shape from notes/dock plugins). English + Chinese strings; the installed
   profile locale is `zh`. Every visible string goes through it.
8. Styles: only `--dsw-alias-*` theme tokens; use `var(--dsw-alias-...)` with sensible
   fallbacks. No `require('@deepseek-ai/dsh-client-ui-primitives')`, no DOM append, no
   iframe.

## Acceptance / verification (Lead owns the final run)

1. `node --check index.js`, `node --check client.js`.
2. `native/quickbar-hotkey cmd+shift+space --selftest` prints `READY` then `TRIGGER`.
3. `plugin_manager install_bundle` (Lead, needs approval) → `application: applied`.
4. Live page: overlay opens from the settings test button, from an in-app keypress, and
   (manually, user confirms) from the global hotkey; a submitted query appears as a user
   message in the conversation and the answer streams.
5. `Esc` closes, no console errors, no leaked listeners after overlay close.

---

# v3 — lightweight native popup (global hotkey no longer raises the main window)

Goal: the **global hotkey** shows a small native always-on-top text input (not the
main window). After the user types and presses Enter, the main window is raised and
the answer streams there. The in-page overlay (⌘⇧K) stays as the advanced composer
with workspace/model pickers; the native popup reuses the client's **remembered**
workspace/model selection.

## Native helper protocol changes (quickbar-hotkey)

- Keep hotkey registration + `READY <pid>` / `ERROR <code> <msg>`.
- Main loop moves from `RunApplicationEventLoop()` to `[NSApp run]` (Carbon hotkey
  handlers installed on `GetApplicationEventTarget()` continue to fire).
- On hotkey press: print `TRIGGER <epoch-ms>`, then **show** a borderless, frameless,
  always-on-top NSPanel (floating level, joins all spaces + fullscreen auxiliary)
  centered in the top third of the primary screen. Activate the app ignoring others,
  make the panel key and focus a single-line NSTextField.
- Panel text field: placeholder localized to zh ("输入问题，回车发送…"); IME-aware —
  in the Enter handler check `[textView hasMarkedText]` and, when marked, let the
  default insert happen instead of submitting.
- Enter (no marked text) → hide panel, print one stdout line
  `SUBMIT <standard-base64-of-UTF8-text>` (single line, no spaces). Esc → hide panel,
  print `CANCEL`.
- **stdin control**: read lines from stdin; a line `trigger` does exactly what the
  hotkey does (show the panel). Ignore unknown/blank lines. (Host uses this for the
  settings 测试 button.)
- `--selftest`: unchanged semantics — register, synthesize one hotkey event, print
  `TRIGGER <ms>` **without** showing the panel, exit 0. Add `--ui-test <text>`: build
  the panel, programmatically set the field text and invoke the submit action, expect
  one `SUBMIT <b64(text)>` line, exit 0 (proves the submit wiring without a human).
- stderr stays diagnostics-only; stdout stays the protocol.

## Host plugin (index.js)

- Spawn stdio changes: `stdin` from `'ignore'` to `'pipe'`; keep the stdin stream
  reference. On config `enabled:false`/non-darwin/disabled-spec → no helper (as now).
- Parse the new lines (first-token, then payload):
  - `TRIGGER <ms>` → set `lastTriggerAt`, publish a status event, but do **not** raise
    the window and do **not** broadcast a `toggle` (the native popup is the surface).
  - `SUBMIT <b64>` → decode UTF-8 → `fireSubmit(text)`.
  - `CANCEL` → publish a status event only.
- `fireSubmit(text)`:
  - nonce++, `lastTriggerAt = Date.now()`, `pendingSubmit = { text, at: Date.now() }`,
  - broadcast `{ type:'submit', text, nonce, at }` to all `watch` subscribers,
  - if `raiseWindow` → best-effort `open dsh://open` (so the answer is visible).
- `testTrigger()`: write `trigger\n` to the helper stdin (best-effort, catch/log) and
  return `{ ok: true }`. This now opens the native popup, matching "测试快捷键".
- `QuickbarState` adds `pendingSubmit: { text: string; at: number } | null` (reuse the
  same late-client pattern as `pendingToggle`; client consumes by nonce).
- Keep the existing `toggle`/`fireTrigger` machinery intact (⌘⇧K overlay path is
  client-local; nothing regresses).

## Client plugin (client.js)

- `watch` loop additionally handles `{ type:'submit', text, nonce }`: dedupe by nonce,
  then `submitExternal(text)`.
- On mount, after `getState()`: if `pendingSubmit` is non-null and fresh (< 15s) and
  its nonce unseen, `submitExternal(pendingSubmit.text)`.
- `submitExternal(text)`:
  1. ensure model catalog loaded (for selection resolution),
  2. rehydrate the store's `workspaceId` + model selection from localStorage
     (the native popup always uses the remembered selection),
  3. run the existing `submitPrompt(text, { images: [], files: [] })` (all the v2
     workspace/model/effort/connectWorkspace/navigation logic),
  4. close the overlay if it happened to be open.
- The native popup path must NOT require the overlay to have been opened before.
- In-app ⌘⇧K and settings page are unchanged.

## Acceptance (Lead, isolated instance + user)

- `quickbar-hotkey cmd+shift+space --selftest` → `READY` + `TRIGGER`, exit 0.
- `quickbar-hotkey cmd+shift+space --ui-test "你好"` → one `SUBMIT` line whose base64
  decodes to `你好`, exit 0.
- Host parses `SUBMIT`, broadcasts, raises window, `pendingSubmit` present in state.
- Client auto-sends on a `submit` event and on fresh `pendingSubmit` at mount.
- User: press global hotkey from another app → a lightweight input pops up; type +
  Enter → main window opens with the answer streaming. Esc cancels. ⌘⇧K still opens
  the in-app overlay with workspace/model pickers.

---

# v4 — native popup parity: workspace + model + reasoning-effort pickers

Goal: the global-hotkey native popup gets the same adjustable things as the in-app
overlay — a workspace picker, a model picker, and a reasoning-effort picker. The Host
becomes the single source of truth for the remembered selection, so the two surfaces
stay in sync and "延续上次使用" keeps working.

## Selection model

Host owns `lastSelection = { workspaceId, provider, model, reasoningEffort, at }`
(in-memory; best-effort JSON persistence via node:fs is optional). `at` is the last
change time; a consumer falls back to defaults when `Date.now() - at` exceeds a window
(keep the existing 10-minute convention).

Defaults: workspace = default workspace (the `workspaceRegistry` entry whose title is
the sentinel, else first); model = `agentDefaultModel.currentSelection()`; effort = that
model's `defaultEffort`.

## Host → helper stdin push (new)

One JSON line, base64-encoded UTF-8, prefixed `CFG `:

```
CFG <base64( { workspaces:[{id,label,path}], models:[{provider:{id,name}, models:[{id,name,efforts:[{id,name}], defaultEffort}]}], selection:{workspaceId|null, provider|null, model|null, reasoningEffort|null} } )>
```

Push once right after the helper prints `READY`, and again whenever the Host selection
changes. The helper also still accepts the `trigger` stdin line (show the popup).

## Helper → host stdout (changed SUBMIT)

`SUBMIT` is now structured:

```
SUBMIT <base64( { text: <utf8>, workspaceId, provider, model, reasoningEffort|null } )>
```

`TRIGGER`/`CANCEL`/`READY`/`ERROR` unchanged.

## Helper UI

- NSPanel content: a compact toolbar row of three NSPopUpButtons — workspace, model
  (flattened `Provider · Model`), reasoning-effort — above the existing single-line
  NSTextField. Effort menu is rebuilt from the selected model's `efforts` when the model
  changes (default = `defaultEffort`).
- On `CFG`, populate the three menus and preselect the current `selection`.
- On Enter (IME-aware as before): emit `SUBMIT` with the typed text plus the three
  current menu values. Empty text is still allowed to reach the host (host may ignore).
- Keep Esc → `CANCEL`, focus/IME behavior, SIGTERM/SIGINT clean exit.

## Host SUBMIT handling

- Parse the JSON payload; fall back to a plain-text payload as `{ text }` if it is not
  `{`.
- Update `lastSelection` (at = now), push a fresh `CFG` to the helper.
- `fireSubmit({ text, selection })`: nonce++, `pendingSubmit = { text, selection, at }`,
  broadcast `{ type:'submit', text, selection, nonce, at }`, raise window if configured.
- `QuickbarState.pendingSubmit` now also carries `selection`.
- New remote `setSelection(selection)` (direct) — the in-app overlay reports its changes
  to the Host; Host updates `lastSelection`, pushes `CFG`, returns `{ ok:true }`.

## Client changes

- In-app overlay: when the user changes workspace / model / effort, additionally call
  `ctx.remote.quickbar.setSelection(...)` (best-effort, non-fatal) so the native popup
  stays in sync.
- `submitExternal(text, selection)`: before the existing `submitPrompt`, override the
  store's `workspaceId` + model `selection` with the incoming `selection` (validate
  against catalog where available), then submit. The mount `pendingSubmit` path passes
  `pendingSubmit.selection` through the same override.

## Acceptance (Lead, isolated + user)

- Helper `--selftest` unchanged; `--ui-test` now emits a structured `SUBMIT` (with the
  currently configured selection) whose base64 decodes to the right JSON; add a way to
  feed a `CFG` into the ui-test to prove menu population + selection passthrough.
- Host parses structured SUBMIT, updates lastSelection, re-pushes CFG, broadcasts
  submit with selection, raises window.
- Client `submitExternal` honors an incoming selection; in-app overlay reports changes
  via `setSelection`.
- User: global hotkey → native popup shows three pickers reflecting the remembered
  selection; change workspace/model/effort there; Enter → main window shows the answer
  in the chosen workspace with the chosen model; the in-app overlay reflects the same.

---

# v5 — interaction & visual pass (native popup UX)

## Native helper (`native/quickbar-hotkey.m`) — see `native/DESIGN.md`

- **Multi-line input**: NSTextView (auto-grow to 5 lines, then internal scroll). Enter sends,
  Shift+Enter newlines, IME-aware (`hasMarkedText` guard).
- **Toggle**: the global hotkey opens the panel when hidden and closes it when visible
  (no submit). Esc closes and clears. Clicking outside the panel closes it
  (`windowDidResignKey`). The panel remembers its dragged position.
- **Paste image**: ⌘V with an image clipboard attaches it (max 4, 56×56 chips with remove),
  no file attachments in this popup.
- **States**: `sending` (spinner in the send button, input disabled, panel stays open),
  `sent` (150 ms check, then close), `error` (inline red row, text kept). The helper must not
  close the panel on submit if the host reports a failure — the host acknowledges via stdin.
- **Visual**: `native/DESIGN.md` is authoritative (material, radius, shadow, type scale,
  pill selectors, footer hints, motion ≤ 250 ms).
- **SUBMIT payload** gains `images`:
  `SUBMIT <base64({ text, workspaceId, provider, model, reasoningEffort, images:[{mediaType, base64, name?, width?, height?}] })>`
- **stdin** gains two control lines from the host:
  - `SUBMIT_OK` — the host accepted the submission; the panel may close (or show `sent`).
  - `SUBMIT_FAIL <text>` — the host/client rejected it; show the inline error, keep the text.
  (`CFG` and `trigger` unchanged.)

## Host (`index.js`)

- Structured `SUBMIT` parsing keeps `images` in the event: `pendingSubmit = { text, selection,
  images, at }`, broadcast `{ type:'submit', text, selection, images, nonce, at }`.
- **No window raise inside `fireSubmit`**: the client raises the window *after* the prompt is
  accepted (send-then-raise). New direct remote `raiseWindow()` → `open dsh://open` when
  `config.raiseWindow` is true; returns `{ ok: true }`.
- New direct remote `reportSubmitResult(ok, message?)` (client → host): the host writes
  `SUBMIT_OK` or `SUBMIT_FAIL <message>` to the helper stdin so the native panel can close
  or show the error.
- Helper stdout `TRIGGER`/`SUBMIT`/`CANCEL` handling otherwise unchanged.

## Client (`client.js`)

- `submit` events / `pendingSubmit` now carry `images`; `submitExternal(text, selection, images)`
  passes them to the existing `submitPrompt(text, { images, files: [] })` (the v2 image parts +
  beginSubmission attachments already exist).
- On submit success/failure, call `reportSubmitResult(ok, message)` so the native panel closes
  or shows the inline error (fire-and-forget; ignore failures).
- After a successful prompt, call `raiseWindow()` (send-then-raise).
- **Auto-scroll**: after navigation/prompt, scroll the conversation to the newly sent message
  (best effort: scroll the conversation scroll container to the bottom).
- **First-run guidance**: once per install (localStorage flag), show a dismissible notice with
  the hotkey and a "去设置" action.
- **Hotkey conflict notice**: when `getState().hotkeyState === 'error'` (e.g. `register-failed`),
  show a visible dismissible notice with the reason and a "去设置" action (once per state change).
- **Settings polish**: follow `native/DESIGN.md`'s language (type scale, spacing, semantic colors,
  state completeness) for the 快捷唤起 settings page; show conflict clearly and suggest a
  recommended combo.

## Acceptance

- Native: `--selftest` unchanged; `--ui-test` emits a structured SUBMIT that may include images;
  `check.sh` extended for the new protocol lines; universal binary rebuilt.
- Host/client: `node --check`; harness/isolated run proves submit-with-images, report/raise
  ordering, first-run + conflict notices, and auto-scroll.
