# dsh-quickbar — Host half notes (`index.js`)

Owner: host-plugin. Read `CONTRACT.md` first; this file only records the host
implementation and what was verified locally.

## Files delivered (host scope)

| File | Role |
|---|---|
| `index.js` | Host plugin: `Config`, `inject`, `QuickbarService` (`ctx.quickbar`), helper supervisor, remotes |
| `package.json` | Bundle manifest: `dsh.bundle.patch`, `dsh.client` (`platform: web`, `immediately: true`), exports, minimal peers |
| `cordis.patch.yml` | One `insert` row `id: quickbar`, `name: dsh-quickbar`, config defaults |
| `locale/en.json`, `locale/zh.json` | Display metadata `meta.title` / `meta.description` for Plugin Manager + Settings |
| `icon.svg` | Original 64×64 keyboard + magnifier mark (no third-party artwork) |
| `HOST_NOTES.md` | This file |

`client.js` (client teammate) already exists; `package.json` exports `./client`
and lists it in `files`, so nothing else is needed from the host side.

## Wire contract implemented

Remote namespace `quickbar`, class `QuickbarService extends TypertRemoteService`
with `super(ctx, 'quickbar')`, and the hand-rolled `REMOTE_METHODS` descriptor
(verbatim copy of the notes plugin's `markRemoteMethods` trick):

| Method | Mode | Params | Result |
|---|---|---|---|
| `getState()` | direct | none | `QuickbarState` |
| `testTrigger()` | direct | none | `{ ok: true }` |
| `watch(signal)` | stream | `signal` (injected cancellation) | first `QuickbarState`, then `QuickbarEvent`s |

`QuickbarState` / `QuickbarEvent` are exactly the shapes in `CONTRACT.md`
(the state object is built fresh on every `getState()` call; `pendingToggle` is
`{nonce, at}` or `null`). `testTrigger()` is `fireTrigger()` — identical effect
to a physical press.

## Config

`Config = Schema.object({ enabled, hotkey, raiseWindow, inAppShortcut })`, all
`.volatile()`. Important: a volatile field arrives as a frozen `Volatile`
reference, **not** a plain value — the host reads them through
`readConfigField(field, fallback)` (calls `.get()`); a plain object still works
for programmatic mounts. Defaults: `enabled: true`, `hotkey: 'cmd+shift+space'`,
`raiseWindow: true`, `inAppShortcut: 'cmd+shift+k'` (client-only).

## Helper supervision (spawn + parse)

- Helper path: `fileURLToPath(new URL('./native/quickbar-hotkey',
  import.meta.url))`; `existsSync` check before spawn.
- One `ctx.subprocess.spawn` request:
  ```js
  argv: [helperPath, normalizedHotkey], cwd: os.homedir(),
  stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, graceMs: 2000
  ```
- `normalizedHotkey` = trimmed/lowercased/no-whitespace spec. `''`, `off`,
  `none`, `disabled` ⇒ `hotkeyState: 'disabled'`, **no spawn** (the helper itself
  would reject them). `!enabled` and non-`darwin` also mean `disabled`.
- stdout is parsed with `node:readline`, **by the first whitespace token**
  (`READY <pid>`, `TRIGGER <epoch-ms>`, `ERROR <code> <free text…>`), lines
  longer than 64 KiB are ignored, blank lines skipped. An `ERROR` payload keeps
  its free-text message in `hotkeyError` and is terminal (no restart).
- stderr is drained (so the pipe cannot fill) but never used as protocol and
  never surfaced as an error; at most one `debug` breadcrumb per attempt
  (macOS prints TSM/keyboard-layout diagnostics there).
- Process exit / failed spawn: `hotkeyState: 'starting'`, restart after
  1 s / 2 s / 4 s (3 restarts), then `hotkeyState: 'error'` with the recorded
  reason. A helper that ran ≥ 30 s gets a fresh restart budget on a later crash.
  Intentional teardown sets `disposed` first, so the exit callback is muted and
  no restart is scheduled.
- Teardown (`ctx.effect` disposer): clear timers, settle open `watch` streams,
  `handle.terminate()`, then wait (bounded to 3 s) for helper exit. Waiting is
  deliberate: hotkey registration is process-global and a config reload can
  re-mount the row immediately (same hotkey) — the replacement must not race the
  old helper's `UnregisterEventHotKey`. Cordis awaits the returned promise before
  the next `apply`, so a same-hotkey reload stays clean.

## Trigger path (`fireTrigger`)

`nonce += 1`, `lastTriggerAt = at` (helper epoch-ms or `Date.now()`),
`pendingToggle = { nonce, at }`, broadcast `{type:'toggle', nonce, at}` to every
open `watch` subscriber (per-subscriber queue, capped at 256, oldest dropped),
then — when `raiseWindow` — a fire-and-forget
`spawn({ argv: ['/usr/bin/open', 'dsh://open'], stdio: ignore/collect, graceMs: 2000 })`
whose `done` rejection is logged at warn; it never blocks or throws into the
trigger. Status changes (starting/ready/error/disabled, pid) broadcast
`{type:'status', state}` only when a field actually changed.

`apply` is total: it never throws. A missing binary, failed spawn, missing
`subprocess`, or missing `settings` degrades to `hotkeyState` with a message.
The `settings` page policy is optional (`ctx.inject(['settings'], …)` →
`ctx.effect(() => settings.configure({auto:false}, ctx.fiber))`), suppressing the
schema-generated page exactly as `CONTRACT.md` requires. All processes/timers are
owned by `ctx.effect`/`ctx.inject` disposers, so a config reload re-runs `apply`
without leaking a helper, timer, or stream.

## Locally verified (commands + results)

1. `node --check index.js` → OK. `node --check client.js` → OK (client teammate's file).
2. `package.json`, `locale/en.json`, `locale/zh.json` parse as JSON; every
   non-glob `exports` target and every non-glob `files[]` entry exists.
3. `cordis.patch.yml` parses with YAML → exactly one `insert` row
   `{id: quickbar, name: dsh-quickbar, config: {enabled, hotkey, raiseWindow, inAppShortcut}}`.
4. `icon.svg` parses as XML, 64×64 viewBox, 1299 bytes (limits: 256 KiB).
5. Native helper smoke test (owner's binary): `native/quickbar-hotkey
   cmd+shift+space --selftest` → `READY <pid>` + `TRIGGER <ms>`, exit 0;
   `'bad+spec'` → `ERROR invalid-spec …`, exit 2.
6. **Behavior harness** (`/tmp/qb-verify/harness.mjs`): a byte-identical copy of
   `index.js` (md5 compared against the deliverable) is mounted inside a real
   `@deepseek-ai/cordis` `Context` via `ctx.plugin({apply, inject, Config}, config)`
   with a stubbed `subprocess` service; config is validated by the real
   schemastery `Config`. 8/8 scenarios passed:
   - real helper: `READY` ⇒ `ready`, correct `helperPid`, `watch` opens with the
     current state, `testTrigger()` ⇒ `{ok:true}` + toggle event + `open dsh://open`
     spawn with the documented request, nonce monotonic, `watch` settles < 500 ms
     on abort, teardown kills the helper and settles streams/effects;
   - immediate re-mount with the same hotkey after dispose reaches `ready`
     (no `register-failed` race);
   - fake helper `ERROR invalid-spec …` ⇒ `error` with the free-text message, no
     restart;
   - fake helper `READY`/`TRIGGER`/garbage lines ⇒ pid 4242, exact epoch-ms
     `lastTriggerAt`, unknown line ignored, state unchanged;
   - fake helper exiting instantly ⇒ exactly 1 initial + 3 backoff restarts,
     then `error` “not restarted after 3 attempts”;
   - `enabled: false` and `hotkey: 'off'` ⇒ `disabled`, zero spawns, manual
     `testTrigger()` still raises/broadcasts;
   - helper binary absent ⇒ `error` with a build hint, `apply` never throws.
7. **Typert contract check** (`/tmp/qb-verify/typert-check.mjs`) against the real
   `@deepseek-ai/dsh-typert-protocol`: `remoteMethods(service)` returns exactly
   `getState`/`testTrigger` direct + `watch` stream direct, `service.typertRemote`
   binds `serviceKey`/`namespace` `quickbar`, `watch` is an async generator that
   settles on abort, and the Config schema is a standard-schema whose four
   leaves are volatile references with the documented defaults.

Not verified locally (needs the installed profile + live page): bundle
installation/activation, the Gateway descriptor handshake for
`ctx.remote.quickbar` (`$mount`), client overlay/settings rendering, config
persistence round-trip through `settings.update` (Loader reload → new `apply`
is exercised only synthetically), the real physical global hotkey press, and
`open dsh://open` actually focusing the window (the spawn is exercised with a
stub, not executed).

## Open risks / what the Lead should watch at install time

1. **`inject` list**: `CONTRACT.md` says `inject = ['subprocess']` with the
   settings page configured through an optional `ctx.inject(['settings'], …)`;
   the task summary said `['subprocess','settings']`. This implementation follows
   `CONTRACT.md` (optional settings keeps the plugin alive on a Host without
   Settings). One-line change if the Lead prefers the hard dependency.
2. **Gateway handshake** is the main unverifiable piece: `getState`/`testTrigger`
   must mount and `watch` must stream. If `$mount` fails, the client console shows
   a descriptor error while the host logs nothing — check the client first.
3. **Global registration is exclusive**: if another process (including a stray
   test helper) holds `cmd+shift+space`, the helper prints
   `ERROR register-failed <OSStatus>` and the host goes to `error` without
   restarting (by design — an OS conflict will not fix itself). Kill stale
   helpers before testing and reload the plugin row afterwards.
4. **Helper `no-display` / transient errors are terminal too**: `ERROR` never
   retries. After a login-session change, reload the row (settings save) or the
   app to re-register. Acceptable per protocol, documented here.
5. **Config reload window**: teardown waits up to 3 s for helper exit; a reload
   therefore takes ~100–300 ms extra. Do not judge `set_plugin` speed by it.
6. **`dsh.client.inject` is empty**: if the client half needs another client
   module activated first (module graph ordering, e.g. a slot provider), add the
   specifiers there — it is a `package.json` line owned by host-plugin; tell me
   and I will change it.
7. Native binary distribution: linked-directory installs use the workspace
   binary in place; a packed install relies on `files[]` including
   `native/quickbar-hotkey`. The Lead's install is a link, so keep
   `native/quickbar-hotkey` built and executable.
