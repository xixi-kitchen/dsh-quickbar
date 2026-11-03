/**
 * dsh-quickbar — Host half.
 *
 * Owns the `quickbar` Typert Remote service: it supervises the native global
 * hotkey helper (`native/quickbar-hotkey`), relays the native popup's submit /
 * cancel / trigger protocol to Web clients, raises the Harness window through
 * the `dsh://open` scheme, and answers `getState` / `testTrigger` / `watch` for
 * the overlay and settings page.
 *
 * Protocol (v3, see CONTRACT.md): the helper owns the hotkey and a lightweight
 * native input panel. stdout lines `READY <pid>`, `TRIGGER <ms>`,
 * `SUBMIT <base64(utf8)>`, `CANCEL`, `ERROR <code> <msg>`; a `trigger` line
 * written to its stdin opens the panel (used by the settings test button).
 *
 * Design constraints (see CONTRACT.md):
 * - `apply` may run again on every config change and must never throw: any
 *   failure degrades to `hotkeyState: 'disabled' | 'error'` with a message.
 * - Every process and timer is owned by an `ctx.effect` disposer.
 * - Remote method wire names equal their parameter names, so handlers are not
 *   destructured. The `@Remote` decorators are not available in this plain-ESM
 *   bundle, so the descriptor artifact is hand-rolled exactly like the notes
 *   plugin does it.
 */

import { chmodSync, existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import Schema from '@deepseek-ai/schemastery'
import { TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const HELPER_PATH = join(PLUGIN_DIR, 'native', 'quickbar-hotkey')
const RAISE_BINARY = '/usr/bin/open'
const RAISE_URL = 'dsh://open'

const DEFAULT_HOTKEY = 'cmd+shift+space'
/** Restart backoff after an unexpected helper exit: 1s / 2s / 4s, then give up. */
const RESTART_DELAYS_MS = [1000, 2000, 4000]
/** A helper that ran this long is considered healthy; a later crash starts a fresh budget. */
const STABLE_HELPER_MS = 30_000
const SPAWN_GRACE_MS = 2000
/** Upper bound for waiting on helper exit during teardown (helper exits well inside it). */
const TERMINATE_WAIT_MS = 3000
const MAX_PROTOCOL_LINE = 64 * 1024
const MAX_STDERR_TAIL = 8192
/** Backpressure cap for one slow `watch` consumer; oldest events are dropped. */
const MAX_SUBSCRIBER_QUEUE = 256
const DISABLED_SPECS = new Set(['off', 'none', 'disabled'])

const HOTKEY_DISABLED = 'disabled'
const HOTKEY_STARTING = 'starting'
const HOTKEY_READY = 'ready'
const HOTKEY_ERROR = 'error'

/**
 * Schema consumed by the Loader (defaults + validation) and by the Settings
 * form (every field is volatile, so it is hot-editable). `inAppShortcut` is
 * read by the client half only.
 */
export const Config = Schema.object({
  enabled: Schema.boolean().default(true).volatile(),
  hotkey: Schema.string().default(DEFAULT_HOTKEY).volatile(),
  raiseWindow: Schema.boolean().default(true).volatile(),
  inAppShortcut: Schema.string().default('cmd+shift+k').volatile(),
})

/** `subprocess` is a hard dependency; `settings` is optional (configured when present). */
export const inject = ['subprocess']

export const name = 'dsh-quickbar'

/** Log through the Host logger; console fallback keeps callbacks from throwing. */
function logWarn(ctx, message, error) {
  try {
    const logger = ctx === undefined || ctx === null ? undefined : ctx.logger
    if (logger !== undefined && logger !== null && typeof logger.warn === 'function') {
      if (error === undefined) logger.warn(message)
      else logger.warn(message, error)
      return
    }
  } catch {
    /* fall through to console */
  }
  try {
    if (error === undefined) console.warn(message)
    else console.warn(message, error)
  } catch {
    /* nothing left to do */
  }
}

/** Debug-level breadcrumb; silently dropped when the Host logger has no debug sink. */
function logDebug(ctx, message) {
  try {
    const logger = ctx === undefined || ctx === null ? undefined : ctx.logger
    if (logger !== undefined && logger !== null && typeof logger.debug === 'function') logger.debug(message)
  } catch {
    /* diagnostics are optional */
  }
}

/** Await a promise no longer than `ms`, swallowing its settlement; never rejects. */
async function settleWithin(promise, ms) {
  let timer
  try {
    await Promise.race([
      Promise.resolve(promise).then(
        () => undefined,
        () => undefined,
      ),
      new Promise((resolve) => {
        timer = setTimeout(resolve, ms)
        if (typeof timer.unref === 'function') timer.unref()
      }),
    ])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

function errorText(error) {
  if (error instanceof Error) return error.message === '' ? error.name : error.message
  if (typeof error === 'string') return error
  try {
    return String(error)
  } catch {
    return 'unknown error'
  }
}

/**
 * Read one resolved Config field. A `Config` field marked `.volatile()` arrives
 * as a frozen `Volatile` reference (`{ get() }`), not as a plain value; a plain
 * object still resolves the same way when the plugin is mounted programmatically.
 */
function readConfigField(field, fallback) {
  try {
    if (field === undefined || field === null) return fallback
    if (typeof field === 'object' && typeof field.get === 'function') {
      const value = field.get()
      return value === undefined || value === null ? fallback : value
    }
    return field
  } catch {
    return fallback
  }
}

/**
 * Lowercase, whitespace-free hotkey spec. An explicitly empty string stays
 * empty ("no hotkey"), while an absent field gets the schema default upstream;
 * the helper itself would reject both empty and `off` with `ERROR invalid-spec`,
 * so the host turns them into `disabled` without spawning.
 */
function normalizeHotkeySpec(raw) {
  if (typeof raw !== 'string') return DEFAULT_HOTKEY
  return raw.trim().toLowerCase().replace(/\s+/g, '')
}

/** `''` / `off` / `none` / `disabled` means "no global hotkey" — do not spawn the helper. */
function isDisabledSpec(spec) {
  return spec === '' || DISABLED_SPECS.has(spec)
}

function describeExit(outcome) {
  if (outcome === null || typeof outcome !== 'object') return 'exited'
  const signal = typeof outcome.signal === 'string' ? outcome.signal : null
  const exitCode = typeof outcome.exitCode === 'number' ? outcome.exitCode : null
  if (signal !== null) return `terminated by ${signal}`
  if (exitCode !== null) return `exit code ${exitCode}`
  return 'exited'
}

/** Last non-empty stderr line, bounded; used only for a debug breadcrumb, never as protocol. */
function lastStderrLine(text) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim() !== '')
  if (lines.length === 0) return ''
  return lines[lines.length - 1].trim().slice(0, 400)
}

/**
 * `ctx.quickbar`: the Remote service plus the helper supervisor.
 *
 * Wire types (must match the client descriptors exactly):
 * - `getState()` -> `QuickbarState` (adds `pendingSubmit` for v3)
 * - `testTrigger()` -> `{ ok: true }` (writes `trigger` to the helper stdin)
 * - `watch(signal)` -> stream of `QuickbarEvent`
 */
class QuickbarService extends TypertRemoteService {
  constructor(ctx, config) {
    super(ctx, 'quickbar')

    this.enabled = readConfigField(config?.enabled, true) === true
    this.hotkey = normalizeHotkeySpec(readConfigField(config?.hotkey, DEFAULT_HOTKEY))
    this.raiseWindowEnabled = readConfigField(config?.raiseWindow, true) === true
    // Read by the client half; kept for diagnostics only.
    this.inAppShortcut = readConfigField(config?.inAppShortcut, 'cmd+shift+k')

    this.platform = process.platform
    this.hotkeyState = HOTKEY_DISABLED
    this.hotkeyError = null
    this.helperPid = null
    this.lastTriggerAt = null
    this.pendingToggle = null
    /** Last native-popup submission, replayed by a client that mounts late. */
    this.pendingSubmit = null
    /** Optional host services that feed the native popup's `CFG`. */
    this.sources = {}
    this.refreshSeq = 0
    /** Workspace rows and model groups projected for the native popup. */
    this.workspaces = []
    this.modelCatalog = []
    /** Single source of truth for the native popup's three pickers. */
    this.lastSelection = { workspaceId: null, provider: null, model: null, reasoningEffort: null, at: 0 }

    this.nonce = 0
    this.handle = null
    /** The helper's stdin (stdio `pipe`) for the `trigger` control line. */
    this.stdin = null
    this.stdoutInterface = null
    this.stderrTail = ''
    /** The helper reported a terminal ERROR line; do not restart it. */
    this.helperReportedError = false
    this.spawnedAt = 0
    this.restartAttempt = 0
    this.restartTimer = null
    this.disposed = false
    /** Set by dispose(); repeated teardown calls share the same bounded wait. */
    this.disposal = null
    /** Watchdog for one native-popup submit waiting on the client's ack. */
    this.submitAckTimer = null
    /** One entry per open `watch` consumer: `{ events, wake }`. */
    this.subscribers = new Set()
  }

  /** Public wire state. Plain JSON only; every field is the contracted shape. */
  getState() {
    return {
      enabled: this.enabled,
      hotkey: this.hotkey,
      hotkeyState: this.hotkeyState,
      hotkeyError: this.hotkeyError,
      helperPid: this.helperPid,
      platform: this.platform,
      lastTriggerAt: this.lastTriggerAt,
      pendingToggle:
        this.pendingToggle === null ? null : { nonce: this.pendingToggle.nonce, at: this.pendingToggle.at },
      pendingSubmit:
        this.pendingSubmit === null
          ? null
          : {
              text: this.pendingSubmit.text,
              selection: this.pendingSubmit.selection === undefined ? null : this.pendingSubmit.selection,
              images: Array.isArray(this.pendingSubmit.images) ? this.pendingSubmit.images : [],
              at: this.pendingSubmit.at,
            },
    }
  }

  /**
   * Settings-page "test": ask the native helper to open its popup by writing a
   * `trigger` control line to its stdin. Best effort only — a missing helper or
   * stdin never throws to the caller and still answers `{ ok: true }`.
   */
  testTrigger() {
    try {
      const stdin = this.stdin
      if (stdin === undefined || stdin === null || typeof stdin.write !== 'function' || stdin.writable === false) {
        logDebug(this.ctx, '[quickbar] testTrigger: helper stdin is unavailable; the native popup cannot be shown')
        return { ok: true }
      }
      stdin.write('trigger\n')
    } catch (error) {
      logWarn(this.ctx, '[quickbar] testTrigger could not write to the helper stdin:', error)
    }
    return { ok: true }
  }

  /**
   * Open a stream endpoint. First item is the current state, then every status
   * change plus the event objects fanned out by `publish()` (`toggle`, `submit`).
   * Waiting races the abort signal so the stream settles promptly when the
   * consumer disconnects.
   * @param signal - cancellation signal injected by the Gateway
   */
  async *watch(signal) {
    const lifetime = signal ?? new AbortController().signal
    if (lifetime.aborted) return

    const subscriber = { events: [], wake: null, closed: false }
    let resolveWait = null
    const wake = () => {
      const resolve = resolveWait
      resolveWait = undefined
      if (resolve !== undefined) resolve('event')
    }
    const onAbort = () => {
      const resolve = resolveWait
      resolveWait = undefined
      if (resolve !== undefined) resolve('abort')
    }
    subscriber.wake = wake
    this.subscribers.add(subscriber)
    lifetime.addEventListener('abort', onAbort, { once: true })
    try {
      yield this.getState()
      while (!lifetime.aborted && !subscriber.closed) {
        if (subscriber.events.length === 0) {
          const reason = await new Promise((resolve) => {
            resolveWait = resolve
          })
          if (reason === 'abort' || subscriber.closed || lifetime.aborted) return
          continue
        }
        yield subscriber.events.shift()
      }
    } finally {
      subscriber.wake = null
      this.subscribers.delete(subscriber)
      lifetime.removeEventListener('abort', onAbort)
    }
  }

  /** Start helper supervision according to the current config/platform. */
  start() {
    if (this.disposed) return
    if (!this.enabled) {
      this.setState({ hotkeyState: HOTKEY_DISABLED, hotkeyError: null, helperPid: null })
      return
    }
    if (this.platform !== 'darwin') {
      this.setState({
        hotkeyState: HOTKEY_DISABLED,
        hotkeyError: 'global hotkeys are supported on macOS only',
        helperPid: null,
      })
      return
    }
    if (isDisabledSpec(this.hotkey)) {
      this.setState({ hotkeyState: HOTKEY_DISABLED, hotkeyError: null, helperPid: null })
      return
    }
    this.spawnHelper()
  }

  /**
   * Best-effort executable-bit repair before spawning the helper.
   *
   * A published package is installed by pnpm/npm, which does not reliably
   * preserve the mode of files outside `bin` (and a DSH plugin install may skip
   * lifecycle scripts), so the checked-in helper can arrive without `+x` and
   * fail to spawn. Repairing it here keeps the published package self-healing.
   * chmod failures never throw: the spawn path below already degrades to
   * `hotkeyState: 'error'` with a readable message.
   */
  ensureHelperExecutable() {
    try {
      const mode = statSync(HELPER_PATH).mode
      if ((mode & 0o111) === 0) {
        chmodSync(HELPER_PATH, 0o755)
        logDebug(this.ctx, `[quickbar] restored the executable bit on ${HELPER_PATH}`)
      }
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not verify the helper executable bit:', error)
    }
  }

  /** Spawn one helper process and wire its protocol streams. Never throws. */
  spawnHelper() {
    this.clearRestartTimer()
    if (this.disposed) return
    if (!existsSync(HELPER_PATH)) {
      this.setState({
        hotkeyState: HOTKEY_ERROR,
        hotkeyError: `hotkey helper binary is missing: ${HELPER_PATH} (run native/build.sh)`,
        helperPid: null,
      })
      return
    }
    this.ensureHelperExecutable()
    const subprocess = this.getSubprocess()
    if (subprocess === undefined) {
      this.setState({
        hotkeyState: HOTKEY_ERROR,
        hotkeyError: 'subprocess service is unavailable; cannot start the hotkey helper',
        helperPid: null,
      })
      return
    }

    this.helperReportedError = false
    this.stderrTail = ''
    this.spawnedAt = Date.now()
    this.setState({ hotkeyState: HOTKEY_STARTING, hotkeyError: null, helperPid: null })

    let handle
    try {
      handle = subprocess.spawn({
        argv: [HELPER_PATH, this.hotkey],
        cwd: homedir(),
        // stdin pipes the `trigger` control line used by the settings test
        // button; stdout/stderr carry the protocol / diagnostics.
        stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' },
        graceMs: SPAWN_GRACE_MS,
      })
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not start the hotkey helper:', error)
      this.finishAttempt(`spawn failed: ${errorText(error)}`)
      return
    }

    this.handle = handle
    try {
      this.attachStdin(handle)
      this.attachStreams(handle)
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not attach helper streams:', error)
      this.finishAttempt(`stream setup failed: ${errorText(error)}`)
      return
    }

    Promise.resolve(handle.done).then(
      (outcome) => this.finishAttempt(describeExit(outcome)),
      (error) => this.finishAttempt(`helper start failed: ${errorText(error)}`),
    )
  }

  getSubprocess() {
    try {
      const subprocess = this.ctx.subprocess
      if (subprocess === undefined || subprocess === null || typeof subprocess.spawn !== 'function') return undefined
      return subprocess
    } catch {
      return undefined
    }
  }

  /** Keep the helper's stdin for the `trigger` control line; never let it throw. */
  attachStdin(handle) {
    const stdin = handle.stdin
    if (stdin === undefined || stdin === null) {
      logDebug(this.ctx, '[quickbar] helper has no stdin pipe; the settings test control is unavailable')
      return
    }
    // A helper that died leaves a broken pipe; an unhandled 'error' event here
    // would crash the Host, so park it.
    stdin.on('error', () => {})
    this.stdin = stdin
  }

  attachStreams(handle) {
    const stdout = handle.stdout
    if (stdout === undefined || stdout === null) {
      throw new Error('helper produced no stdout stream; the protocol needs stdio.stdout = "pipe"')
    }
    stdout.on('error', () => {})
    const interface_ = createInterface({ input: stdout, crlfDelay: Infinity })
    this.stdoutInterface = interface_
    interface_.on('line', (line) => this.onHelperLine(line))
    interface_.on('error', () => {})
    interface_.on('close', () => {
      if (this.stdoutInterface === interface_) this.stdoutInterface = null
    })

    const stderr = handle.stderr
    if (stderr !== undefined && stderr !== null) {
      stderr.on('error', () => {})
      stderr.on('data', (chunk) => {
        this.stderrTail = (this.stderrTail + String(chunk)).slice(-MAX_STDERR_TAIL)
      })
    }
  }

  onHelperLine(line) {
    if (this.disposed) return
    if (typeof line !== 'string') return
    // Split by the first whitespace token, never by whole-line equality: the
    // ERROR payload is `<code> <free text…>` and may contain spaces.
    const text = line.trim()
    if (text === '') return
    if (text.length > MAX_PROTOCOL_LINE) {
      logWarn(this.ctx, '[quickbar] ignoring an oversized helper protocol line')
      return
    }
    const space = text.indexOf(' ')
    const head = space === -1 ? text : text.slice(0, space)
    const rest = space === -1 ? '' : text.slice(space + 1).trim()

    if (head === 'READY') {
      const pid = Number.parseInt(rest, 10)
      this.setState({
        hotkeyState: HOTKEY_READY,
        hotkeyError: null,
        helperPid: Number.isFinite(pid) && pid > 0 ? pid : null,
      })
      // The helper owns the pickers; a fresh process needs the current CFG.
      this.pushCfg()
      return
    }

    if (head === 'TRIGGER') {
      // v3: the helper itself shows the native popup. Record the press and tell
      // clients about the state change only — no window raise, no toggle.
      const at = Number.parseInt(rest, 10)
      this.lastTriggerAt = Number.isFinite(at) && at > 0 ? at : Date.now()
      this.publish({ type: 'status', state: this.getState() })
      return
    }

    if (head === 'SUBMIT') {
      // v4: `SUBMIT <standard-base64(json)>` carrying the text plus the three
      // picker values. A payload that is not a JSON object is the legacy v3
      // plain-text form and keeps the current selection.
      let payload
      try {
        const decoded = Buffer.from(rest, 'base64').toString('utf8')
        let parsed
        try {
          parsed = JSON.parse(decoded)
        } catch {
          parsed = null
        }
        if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          payload = {
            text: typeof parsed.text === 'string' ? parsed.text : '',
            selection: {
              workspaceId: wireSelectionField(parsed.workspaceId),
              provider: wireSelectionField(parsed.provider),
              model: wireSelectionField(parsed.model),
              reasoningEffort: wireSelectionField(parsed.reasoningEffort),
            },
            images: wireImages(parsed.images),
          }
        } else {
          payload = { text: decoded, selection: undefined, images: [] }
        }
      } catch (error) {
        logWarn(this.ctx, '[quickbar] ignoring a SUBMIT line with an undecodable payload:', error)
        return
      }
      if (typeof payload.text !== 'string' || payload.text.trim() === '') {
        logDebug(this.ctx, '[quickbar] ignoring an empty native-popup submission')
        return
      }
      this.submitFromHelper(payload)
      return
    }

    if (head === 'CANCEL') {
      // Esc in the native popup: nothing to send, just refresh client state.
      this.publish({ type: 'status', state: this.getState() })
      return
    }

    if (head === 'ERROR') {
      this.helperReportedError = true
      this.setState({
        hotkeyState: HOTKEY_ERROR,
        hotkeyError: rest === '' ? 'hotkey helper reported an error' : rest,
        helperPid: null,
      })
      return
    }

    // Unknown line: protocol noise from another process on the pipe would land
    // here. Keep it out of the state, but leave a breadcrumb in the log.
    logWarn(this.ctx, `[quickbar] ignoring unknown helper output: ${text.slice(0, 200)}`)
  }

  /**
   * One helper attempt ended (clean exit, crash, or failed spawn). Restart with
   * backoff unless the helper explained itself with ERROR or the budget is spent.
   */
  finishAttempt(reason) {
    this.clearSubmitAck()
    this.detachStreams()
    this.stdin = null
    this.handle = null
    if (this.disposed) return

    this.setState({ helperPid: null })

    if (this.helperReportedError) return

    // macOS writes TSM / keyboard-layout diagnostics to stderr. They are never
    // protocol data and never a user-facing error; keep one debug breadcrumb.
    const stderrLine = lastStderrLine(this.stderrTail)
    if (stderrLine !== '') logDebug(this.ctx, `[quickbar] helper stderr (ignored): ${stderrLine}`)

    const ranFor = this.spawnedAt > 0 ? Date.now() - this.spawnedAt : 0
    if (ranFor >= STABLE_HELPER_MS) this.restartAttempt = 0

    if (this.restartAttempt >= RESTART_DELAYS_MS.length) {
      this.setState({
        hotkeyState: HOTKEY_ERROR,
        hotkeyError: `hotkey helper stopped (${reason}) and was not restarted after ${RESTART_DELAYS_MS.length} attempts`,
      })
      return
    }

    const delay = RESTART_DELAYS_MS[this.restartAttempt] ?? RESTART_DELAYS_MS[RESTART_DELAYS_MS.length - 1]
    this.restartAttempt += 1
    this.setState({ hotkeyState: HOTKEY_STARTING, hotkeyError: null })
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null
      try {
        this.spawnHelper()
      } catch (error) {
        logWarn(this.ctx, '[quickbar] helper restart failed:', error)
      }
    }, delay)
    if (typeof this.restartTimer.unref === 'function') this.restartTimer.unref()
  }

  detachStreams() {
    const interface_ = this.stdoutInterface
    this.stdoutInterface = null
    if (interface_ !== null) {
      try {
        interface_.close()
      } catch {
        /* already closed */
      }
    }
  }

  clearRestartTimer() {
    if (this.restartTimer === null) return
    clearTimeout(this.restartTimer)
    this.restartTimer = null
  }

  /** Register one optional host service that feeds `CFG`; rebuild when it lands. */
  setSource(name, service) {
    if (this.disposed) return
    this.sources[name] = service === null ? undefined : service
    this.refreshCatalog()
  }

  /** Rebuild the workspace list + model catalog from whatever is available. */
  refreshCatalog() {
    if (this.disposed) return
    const sequence = ++this.refreshSeq
    Promise.resolve()
      .then(() => this.buildCatalog(sequence))
      .catch((error) => {
        logWarn(this.ctx, '[quickbar] could not rebuild the quickbar catalog:', error)
      })
  }

  async buildCatalog(sequence) {
    const onError = (message, error) => logWarn(this.ctx, message, error)
    const workspaces =
      this.sources.workspaceRegistry === undefined ? [] : buildWorkspaceList(this.sources.workspaceRegistry, onError)
    const models = this.sources.llm === undefined ? [] : await buildModelCatalog(this.sources.llm, onError)
    if (this.disposed || sequence !== this.refreshSeq) return
    this.workspaces = workspaces
    this.modelCatalog = models
    try {
      this.resolveDefaults()
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not resolve the default selection:', error)
    }
    this.pushCfg()
  }

  /** First-run defaults: default workspace + agentDefaultModel + model default effort. */
  resolveDefaults() {
    if (this.disposed || this.lastSelection.at > 0) return
    const workspace = defaultWorkspaceOf(this.workspaces)
    let provider = null
    let model = null
    let reasoningEffort = null
    const defaultModel = this.sources.agentDefaultModel
    if (defaultModel !== undefined && typeof defaultModel.currentSelection === 'function') {
      try {
        const current = defaultModel.currentSelection()
        if (current !== null && typeof current === 'object') {
          provider = typeof current.provider === 'string' && current.provider !== '' ? current.provider : null
          model = typeof current.model === 'string' && current.model !== '' ? current.model : null
          reasoningEffort =
            typeof current.reasoningEffort === 'string' && current.reasoningEffort !== '' ? current.reasoningEffort : null
        }
      } catch (error) {
        logWarn(this.ctx, '[quickbar] could not read agentDefaultModel.currentSelection():', error)
      }
    }
    this.lastSelection = {
      workspaceId: workspace === undefined ? null : workspace.id,
      provider,
      model,
      reasoningEffort: this.effortForSelection(provider, model, reasoningEffort),
      at: Date.now(),
    }
  }

  /** Keep an effort inside the selected model's menu (its default when unset/unknown). */
  effortForSelection(provider, model, reasoningEffort) {
    if (provider === null || model === null) return reasoningEffort
    const group = this.modelCatalog.find((candidate) => candidate.provider.id === provider)
    const entry = group === undefined ? undefined : group.models.find((candidate) => candidate.id === model)
    if (entry === undefined) return reasoningEffort
    if (entry.efforts.length === 0) return null
    if (reasoningEffort !== null && entry.efforts.some((effort) => effort.id === reasoningEffort)) return reasoningEffort
    if (entry.defaultEffort !== null && entry.efforts.some((effort) => effort.id === entry.defaultEffort)) {
      return entry.defaultEffort
    }
    return entry.efforts[0].id
  }

  /** Merge a normalized selection patch into lastSelection and stamp `at`. */
  mergeSelection(patch) {
    const previous = this.lastSelection
    const provider = patch.provider !== undefined ? patch.provider : previous.provider
    const model = patch.model !== undefined ? patch.model : previous.model
    const reasoningEffort = patch.reasoningEffort !== undefined ? patch.reasoningEffort : previous.reasoningEffort
    this.lastSelection = {
      workspaceId: patch.workspaceId !== undefined ? patch.workspaceId : previous.workspaceId,
      provider,
      model,
      reasoningEffort: this.effortForSelection(provider, model, reasoningEffort),
      at: Date.now(),
    }
    return this.lastSelection
  }

  /** The four wire-visible selection fields (no `at`). */
  selectionSnapshot() {
    return {
      workspaceId: this.lastSelection.workspaceId,
      provider: this.lastSelection.provider,
      model: this.lastSelection.model,
      reasoningEffort: this.lastSelection.reasoningEffort,
    }
  }

  /** The `CFG` JSON the helper consumes to populate its three pickers. */
  buildCfg() {
    return {
      workspaces: this.workspaces.map((workspace) => ({
        id: workspace.id,
        label: workspace.label,
        path: workspace.path,
      })),
      models: this.modelCatalog.map((group) => ({
        provider: { id: group.provider.id, name: group.provider.name },
        models: group.models.map((model) => ({
          id: model.id,
          name: model.name,
          efforts: model.efforts.map((effort) => ({ id: effort.id, name: effort.name })),
          defaultEffort: model.defaultEffort,
        })),
      })),
      selection: this.selectionSnapshot(),
    }
  }

  /** Push one `CFG <base64(json)>` line; a silent no-op before the helper is ready. */
  pushCfg() {
    try {
      const stdin = this.stdin
      if (stdin === undefined || stdin === null || typeof stdin.write !== 'function' || stdin.writable === false) {
        return false
      }
      const encoded = Buffer.from(JSON.stringify(this.buildCfg()), 'utf8').toString('base64')
      stdin.write(`CFG ${encoded}\n`)
      return true
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not push CFG to the helper:', error)
      return false
    }
  }

  /**
   * In-page overlay trigger path (v1/v2 behavior, kept intact): bump the nonce,
   * remember the toggle for late/absent clients, fan out `toggle`, raise the
   * window. v3 does not wire this to the helper's TRIGGER line or `testTrigger()`
   * — the native popup is the hotkey surface — so it stays available for the
   * in-page ⌘⇧K path and future callers.
   * @param at - trigger timestamp (epoch ms or Date.now())
   */
  fireTrigger(at) {
    try {
      const stamp = typeof at === 'number' && Number.isFinite(at) && at > 0 ? at : Date.now()
      this.nonce += 1
      this.lastTriggerAt = stamp
      this.pendingToggle = { nonce: this.nonce, at: stamp }
      this.publish({ type: 'toggle', nonce: this.nonce, at: stamp })
      if (this.raiseWindowEnabled) this.raiseWindowBestEffort()
    } catch (error) {
      logWarn(this.ctx, '[quickbar] trigger failed:', error)
    }
    return { ok: true }
  }

  /**
   * Apply one native-popup submission: merge its picker values into the shared
   * selection, push the refreshed CFG, then fan the submit event out.
   * @param payload - `{ text, selection }` decoded from the helper's SUBMIT line
   */
  submitFromHelper(payload) {
    try {
      if (payload.selection !== undefined) this.mergeSelection(payload.selection)
      this.pushCfg()
      this.fireSubmit({
        text: payload.text,
        selection: this.selectionSnapshot(),
        images: Array.isArray(payload.images) ? payload.images : [],
      })
    } catch (error) {
      logWarn(this.ctx, '[quickbar] native submit failed:', error)
    }
  }

  /**
   * One native-popup submission: remember it for late clients and fan it out as
   * a `submit` event. v5 sends first and raises afterwards: the client calls
   * `raiseWindow()` once the prompt is accepted, so the window never appears
   * before the message is on its way.
   * @param submission - `{ text, selection, images }`; the selection overrides
   *   the client's remembered defaults for this one prompt.
   */
  fireSubmit(submission) {
    try {
      const at = Date.now()
      const text = submission !== null && typeof submission === 'object' && typeof submission.text === 'string'
        ? submission.text
        : ''
      const selection =
        submission !== null && typeof submission === 'object' && submission.selection !== undefined
          ? submission.selection
          : this.selectionSnapshot()
      const images = submission !== null && typeof submission === 'object' && Array.isArray(submission.images)
        ? submission.images
        : []
      this.nonce += 1
      this.lastTriggerAt = at
      this.pendingSubmit = { text, selection, images, at }
      this.publish({ type: 'submit', text, selection, images, nonce: this.nonce, at })
      /* The popup waits for the client's acknowledgement. Fail fast when no
       * window is connected, and bound the wait otherwise, so the panel always
       * ends in a readable state instead of a bare timeout. */
      this.clearSubmitAck()
      if (this.subscribers.size === 0) {
        this.writeHelperLine('SUBMIT_FAIL 没有已连接的窗口，请先打开主窗口再试')
      } else {
        this.submitAckTimer = setTimeout(() => {
          this.submitAckTimer = null
          this.writeHelperLine('SUBMIT_FAIL 窗口未响应：请刷新窗口后重试')
        }, 12000)
        if (typeof this.submitAckTimer.unref === 'function') this.submitAckTimer.unref()
      }
    } catch (error) {
      logWarn(this.ctx, '[quickbar] native submit failed:', error)
    }
  }

  /**
   * Raise the Harness window on the client's request (send-then-raise).
   * Respects the same `raiseWindow` config; never throws.
   */
  raiseWindow() {
    if (this.raiseWindowEnabled) this.raiseWindowBestEffort()
    return { ok: true }
  }

  /**
   * The client reports the outcome of one native-popup submission so the panel
   * can close (`SUBMIT_OK`) or show its inline error (`SUBMIT_FAIL <text>`).
   * Best effort: a missing helper/stdin is only a debug breadcrumb.
   * @param ok - whether the prompt was accepted
   * @param message - failure reason shown inline in the panel
   */
  clearSubmitAck() {
    if (this.submitAckTimer !== null) {
      clearTimeout(this.submitAckTimer)
      this.submitAckTimer = null
    }
  }

  /** Write one control line to the helper's stdin; best effort, never throws. */
  writeHelperLine(line) {
    try {
      const stdin = this.stdin
      if (stdin === undefined || stdin === null || typeof stdin.write !== 'function' || stdin.writable === false) {
        logDebug(this.ctx, '[quickbar] helper stdin is unavailable for a control line')
        return
      }
      stdin.write(line.endsWith('\n') ? line : `${line}\n`)
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not write a control line to the helper:', error)
    }
  }

  reportSubmitResult(ok, message) {
    this.clearSubmitAck()
    if (ok === true) {
      this.writeHelperLine('SUBMIT_OK')
      return { ok: true }
    }
    const reason = typeof message === 'string' && message.trim() !== '' ? message.replace(/\s+/g, ' ').slice(0, 500) : 'unknown error'
    this.writeHelperLine(`SUBMIT_FAIL ${reason}`)
    return { ok: true }
  }

  /**
   * The in-app overlay reports its workspace / model / effort changes so the
   * native popup's pickers stay in sync. Partial patches merge with the current
   * selection; an explicit null clears that field. Never throws.
   * @param selection - `{ workspaceId, provider, model, reasoningEffort }`
   */
  setSelection(selection) {
    try {
      const patch = selection !== null && typeof selection === 'object' && !Array.isArray(selection) ? selection : {}
      this.mergeSelection({
        workspaceId: wireSelectionField(patch.workspaceId),
        provider: wireSelectionField(patch.provider),
        model: wireSelectionField(patch.model),
        reasoningEffort: wireSelectionField(patch.reasoningEffort),
      })
      this.pushCfg()
    } catch (error) {
      logWarn(this.ctx, '[quickbar] setSelection failed:', error)
    }
    return { ok: true }
  }

  /** Best-effort `open dsh://open`; never awaited and never throws into the trigger. */
  raiseWindowBestEffort() {
    try {
      if (this.platform !== 'darwin') return
      if (!existsSync(RAISE_BINARY)) return
      const subprocess = this.getSubprocess()
      if (subprocess === undefined) return
      const handle = subprocess.spawn({
        argv: [RAISE_BINARY, RAISE_URL],
        cwd: homedir(),
        stdio: { stdin: 'ignore', stdout: { maxBytes: 4096 }, stderr: { maxBytes: 4096 } },
        graceMs: SPAWN_GRACE_MS,
      })
      if (handle !== undefined && handle !== null && handle.done !== undefined && typeof handle.done.catch === 'function') {
        handle.done.catch((error) => {
          logWarn(this.ctx, '[quickbar] could not raise the Harness window:', error)
        })
      }
    } catch (error) {
      logWarn(this.ctx, '[quickbar] could not raise the Harness window:', error)
    }
  }

  /** Apply a state patch and notify `watch` consumers only when something changed. */
  setState(patch) {
    let changed = false
    for (const key of Object.keys(patch)) {
      if (Object.is(this[key], patch[key])) continue
      this[key] = patch[key]
      changed = true
    }
    if (changed) this.publish({ type: 'status', state: this.getState() })
  }

  publish(event) {
    for (const subscriber of this.subscribers) {
      try {
        if (subscriber.events.length >= MAX_SUBSCRIBER_QUEUE) subscriber.events.shift()
        subscriber.events.push(event)
        if (subscriber.wake !== null) subscriber.wake()
      } catch (error) {
        logWarn(this.ctx, '[quickbar] watch subscriber failed:', error)
      }
    }
  }

  /** Owner-called teardown: stop timers, mute callbacks, terminate the helper. */
  dispose() {
    if (this.disposal !== null) return this.disposal
    this.disposed = true
    this.clearRestartTimer()
    this.detachStreams()
    // Settle every open watch stream promptly: a service teardown is a stream end.
    for (const subscriber of this.subscribers) {
      try {
        subscriber.closed = true
        if (subscriber.wake !== null) subscriber.wake()
      } catch {
        /* the subscriber is already gone */
      }
    }
    this.subscribers.clear()

    this.stdin = null
    const handle = this.handle
    this.handle = null
    if (handle === null) {
      this.disposal = Promise.resolve()
      return this.disposal
    }

    // Registration of a global hotkey is process-global. Wait (bounded) for the
    // helper to exit so a config reload that re-mounts this row cannot spawn the
    // replacement before the old one released the hotkey.
    let exited
    try {
      exited = handle.done
      if (exited === undefined) exited = typeof handle.waitForExit === 'function' ? handle.waitForExit() : undefined
    } catch {
      exited = undefined
    }
    try {
      const result = handle.terminate()
      if (result !== undefined && result !== null && typeof result.then === 'function') {
        this.disposal = settleWithin(result, TERMINATE_WAIT_MS)
        return this.disposal
      }
    } catch (error) {
      logWarn(this.ctx, '[quickbar] helper termination failed:', error)
    }
    this.disposal = exited === undefined ? Promise.resolve() : settleWithin(exited, TERMINATE_WAIT_MS)
    return this.disposal
  }
}

/** Sentinel title of the initialized default workspace (see the workspace controller). */
const DEFAULT_WORKSPACE_TITLE = 'default-workspace'
/** Localized label the pickers show for that workspace. */
const DEFAULT_WORKSPACE_LABEL = '默认工作区'

/** Normalize one wire-selection field: absent stays undefined, null stays null. */
function wireSelectionField(value) {
  if (value === undefined) return undefined
  if (value === null) return null
  return String(value)
}

/**
 * Validate the native popup's pasted-image list for one submit. Each entry is
 * `{ mediaType, base64, name?, width?, height? }`; invalid entries are dropped.
 * @param value - decoded SUBMIT payload field
 */
function wireImages(value) {
  if (!Array.isArray(value)) return []
  const images = []
  for (const entry of value) {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue
    const mediaType = typeof entry.mediaType === 'string' ? entry.mediaType : ''
    const base64 = typeof entry.base64 === 'string' ? entry.base64 : ''
    if (mediaType === '' || base64 === '') continue
    if (images.length >= 4) break
    images.push({
      mediaType,
      base64,
      ...(typeof entry.name === 'string' && entry.name !== '' ? { name: entry.name } : {}),
      ...(typeof entry.width === 'number' && Number.isFinite(entry.width) ? { width: entry.width } : {}),
      ...(typeof entry.height === 'number' && Number.isFinite(entry.height) ? { height: entry.height } : {}),
    })
  }
  return images
}

/**
 * Project the host workspace registry into the picker rows the native popup
 * consumes. Errors are reported but never thrown.
 * @param registry - the `workspaceRegistry` service
 * @param onError - reporter for a failed list
 */
function buildWorkspaceList(registry, onError) {
  let list
  try {
    list = registry.list()
  } catch (error) {
    onError('[quickbar] workspaceRegistry.list() failed:', error)
    return []
  }
  if (!Array.isArray(list)) return []
  const rows = []
  for (const workspace of list) {
    if (workspace === null || typeof workspace !== 'object') continue
    const rawTitle = typeof workspace.title === 'string' ? workspace.title.trim() : ''
    const isDefault = rawTitle === '' || rawTitle === DEFAULT_WORKSPACE_TITLE
    const id = workspace.id !== undefined && workspace.id !== null ? String(workspace.id) : workspace.workspaceId !== undefined && workspace.workspaceId !== null ? String(workspace.workspaceId) : ''
    if (id === '') continue
    rows.push({
      id,
      label: isDefault ? DEFAULT_WORKSPACE_LABEL : rawTitle,
      path: typeof workspace.path === 'string' ? workspace.path : '',
      isDefault,
    })
  }
  return rows
}

/** The default workspace row (sentinel title) or the first registered one. */
function defaultWorkspaceOf(workspaces) {
  if (!Array.isArray(workspaces) || workspaces.length === 0) return undefined
  return workspaces.find((workspace) => workspace.isDefault === true) ?? workspaces[0]
}

/**
 * Project the host LLM registry into provider/model groups with their reasoning
 * efforts. One provider or model failing is logged and skipped, never fatal.
 * @param llm - the `llm` service
 * @param onError - reporter for a failed provider/model read
 */
async function buildModelCatalog(llm, onError) {
  let providers
  try {
    providers = llm.listProviders()
  } catch (error) {
    onError('[quickbar] llm.listProviders() failed:', error)
    return []
  }
  if (!Array.isArray(providers)) return []
  const groups = []
  for (const provider of providers) {
    if (provider === null || typeof provider !== 'object' || provider.id === undefined) continue
    const providerId = String(provider.id)
    try {
      const models = await llm.listModels(provider.id)
      const entries = []
      for (const model of Array.isArray(models) ? models : []) {
        if (model === null || typeof model !== 'object' || model.id === undefined) continue
        let reasoning
        try {
          reasoning = await llm.resolveModelInfo(provider.id, model.id)
        } catch (error) {
          onError(`[quickbar] llm.resolveModelInfo("${providerId}", "${String(model.id)}") failed:`, error)
          reasoning = undefined
        }
        const declared = reasoning !== null && reasoning !== undefined ? reasoning.reasoning : undefined
        const efforts = Array.isArray(declared === undefined ? undefined : declared.efforts)
          ? declared.efforts
            .filter((effort) => effort !== null && typeof effort === 'object' && effort.id !== undefined)
            .map((effort) => ({
              id: String(effort.id),
              name: typeof effort.name === 'string' && effort.name !== '' ? effort.name : String(effort.id),
            }))
          : []
        const declaredDefault = declared !== undefined && typeof declared.defaultEffort === 'string' ? declared.defaultEffort : null
        const defaultEffort = declaredDefault !== null && efforts.some((effort) => effort.id === declaredDefault)
          ? declaredDefault
          : efforts.length > 0
            ? efforts[0].id
            : null
        entries.push({
          id: String(model.id),
          name: typeof model.name === 'string' && model.name !== '' ? model.name : String(model.id),
          efforts,
          defaultEffort,
        })
      }
      if (entries.length > 0) {
        groups.push({
          provider: {
            id: providerId,
            name: typeof provider.name === 'string' && provider.name !== '' ? provider.name : providerId,
          },
          models: entries,
        })
      }
    } catch (error) {
      onError(`[quickbar] llm.listModels("${providerId}") failed:`, error)
    }
  }
  return groups
}

/**
 * Hand-rolled replica of the `@Remote` decorator artifact (same trick as the
 * notes plugin): a versioned descriptor on the Service prototype, read by the
 * Gateway's source-mode discovery. `watch` is the only stream endpoint.
 */
const REMOTE_METHODS = '@deepseek-ai/dsh-typert-protocol/remote-methods'
function markRemoteMethods(prototype, methods) {
  Object.defineProperty(prototype, REMOTE_METHODS, {
    configurable: true,
    value: Object.freeze({
      version: 1,
      methods: Object.freeze(
        methods.map((entry) =>
          Object.freeze({
            method: entry.method,
            ...(entry.mode !== undefined ? { mode: entry.mode } : {}),
            invocation: Object.freeze({ kind: 'direct' }),
          }),
        ),
      ),
    }),
  })
}

markRemoteMethods(QuickbarService.prototype, [
  { method: 'getState' },
  { method: 'testTrigger' },
  { method: 'setSelection' },
  { method: 'raiseWindow' },
  { method: 'reportSubmitResult' },
  { method: 'watch', mode: 'stream' },
])

/**
 * Attach the optional host services that feed the helper's `CFG`. Each is
 * injected separately: a Host that lacks one still builds `CFG` from the
 * others, and one with none still pushes an empty catalog with null defaults.
 */
function installCatalogSources(ctx, service) {
  const attach = (sourceName) => {
    try {
      ctx.inject([sourceName], (sourceCtx) => {
        try {
          service.setSource(sourceName, sourceCtx[sourceName])
        } catch (error) {
          logWarn(ctx, `[quickbar] could not attach the ${sourceName} service:`, error)
        }
      })
    } catch (error) {
      logWarn(ctx, `[quickbar] ${sourceName} service is unavailable; CFG stays empty for it:`, error)
    }
  }
  attach('workspaceRegistry')
  attach('llm')
  attach('agentDefaultModel')
}

/**
 * The plugin ships its own Settings section, so suppress the schema-generated
 * page. `settings` is optional: a Host without it keeps the automatic page and
 * the hotkey still works.
 */
function installSettingsPolicy(ctx) {
  try {
    ctx.inject(['settings'], (settingsCtx) => {
      try {
        settingsCtx.effect(() => settingsCtx.settings.configure({ auto: false }, ctx.fiber))
      } catch (error) {
        logWarn(ctx, '[quickbar] could not configure the Settings page policy:', error)
      }
    })
  } catch (error) {
    logWarn(ctx, '[quickbar] settings service unavailable; automatic settings page left enabled:', error)
  }
}

/**
 * Plugin entry. Never throws: a broken helper, a missing binary, or an
 * unavailable service degrades to a visible `hotkeyState` instead of crashing
 * the Host. Re-entrant: every process/timer is owned by this fiber's effects.
 */
export async function apply(ctx, config) {
  let service
  try {
    service = new QuickbarService(ctx, config)
  } catch (error) {
    logWarn(ctx, '[quickbar] host service initialization failed; the hotkey is unavailable:', error)
    return
  }

  try {
    ctx.effect(() => () => {
      try {
        const disposal = service.dispose()
        if (disposal !== undefined && disposal !== null && typeof disposal.catch === 'function') {
          return disposal.catch((error) => {
            logWarn(ctx, '[quickbar] dispose failed:', error)
          })
        }
      } catch (error) {
        logWarn(ctx, '[quickbar] dispose failed:', error)
      }
    })
  } catch (error) {
    logWarn(ctx, '[quickbar] could not register the dispose effect:', error)
    try {
      service.dispose()
    } catch {
      /* nothing else to release */
    }
    return
  }

  try {
    installSettingsPolicy(ctx)
  } catch (error) {
    logWarn(ctx, '[quickbar] settings page policy setup failed:', error)
  }

  try {
    installCatalogSources(ctx, service)
  } catch (error) {
    logWarn(ctx, '[quickbar] catalog sources unavailable; CFG will stay empty:', error)
  }

  try {
    service.start()
  } catch (error) {
    logWarn(ctx, '[quickbar] hotkey supervision failed:', error)
    try {
      service.setState({
        hotkeyState: HOTKEY_ERROR,
        hotkeyError: `hotkey supervision failed: ${errorText(error)}`,
        helperPid: null,
      })
    } catch {
      /* the state may already be gone with the fiber */
    }
  }
}
