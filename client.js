/**
 * dsh-quickbar — Web client half.
 *
 * A system-wide hotkey (host half) raises the Harness window and pushes a
 * `toggle` event; this half renders a quick-input overlay in `shell.overlay`,
 * sends the typed text to the current Session (or creates one), and contributes
 * a settings page for the hotkey / behavior.
 *
 * Verified against the installed Harness (2026-10-29):
 * - `window.__ModuleLoader__.load({ id, factory(require) })` with `id` equal to
 *   the package name; `require('react')` is available (same shape as
 *   @zzerx/dsh-plugin-notes/lib/client.js).
 * - Remote descriptors: notes' `$mount` call shape
 *   (`{ package, descriptors: [{ id, service, namespace, method, invocation:
 *   {kind:'direct'}, parameters: [], result: {mode:'src-json'},
 *   [mode:'stream', cancellation:{parameter:'signal'}] }] }`).
 *   Direct methods resolve to `{ ok, value }` / `{ ok:false, error }`.
 *   Stream frames are the host generator's yielded values verbatim
 *   (node_modules/@deepseek-ai/dsh-api-gateway/lib/client.browser.js
 *   `invokeStream`/`ClientStreamHandle`; host `pump()` sends `{type:'item', value}`).
 * - Session submit path: `ctx.sessions.retain(id, {source})` ->
 *   `await reference.ready` (resolves to the binding) -> `binding.session`
 *   (SessionReference also exposes `.session` in older builds; both are tried)
 *   -> `beginSubmission({mode:'queue', text, attachments: []})` ->
 *   `prompt([{type:'text',text}], 'queue', undefined, handle.requestId)` ->
 *   `reference.release()`. See dsh-api-session-controller/lib/types/client.
 * - `ctx.sessions.create({})` -> SessionId; `ctx.uiWorkspace.openSession(id)`;
 *   `ctx.uiWorkspace.startSession(undefined, {prompt, whenDraftExists:'replace'})`.
 * - Current session id comes from a probe registration in the session-scoped
 *   `conversation.composer.dock` slot, whose standardProps include `sessionId`
 *   (slot catalog in dsh-cordis-client-runner/lib/client.js).
 * - Config reads/writes: `ctx.configForms.get(entryId)` returns a form with
 *   `getSnapshot()` (`{status, value, writable, ...}`), `subscribe(fn)` and
 *   `set(field, value) -> Promise<boolean>` (dsh-client-ui-settings/lib/client.js
 *   ConfigFormController; dsh-client-ui-settings-shell/lib/client.js usage).
 * - `shell.overlay` is a root list slot; the layer is click-through and its
 *   direct children get `pointer-events:auto` (dsh-client-ui-layout AppFrame).
 * - Theme tokens only (`--dsw-alias-*` colors + `--dsw-shadow-*`, `--dsw-font-*`,
 *   `--dsw-focus-ring-*`).
 *
 * Every registration/listener/observer is created inside `apply()` and owned by
 * `ctx.effect` / `ctx.slots` / `ctx.inject`, so unload disposes it; the factory
 * itself has no side effects.
 */
window.__ModuleLoader__.load({
  id: 'dsh-quickbar',
  factory(require) {
    'use strict';

    const React = require('react');
    const h = React.createElement;

    // ---------------------------------------------------------------------
    // Locale copy (zh is the active profile locale; en is the declared fallback)
    // ---------------------------------------------------------------------
    const NS = 'quickbar';
    const ENTRY_ID = 'quickbar';
    const SERVICE = 'quickbar';
    const PACKAGE_NAME = 'dsh-quickbar';
    const OVERLAY_SLOT = 'shell.overlay';
    const SETTINGS_SLOT = 'settings.section';
    const COMPOSER_SLOT = 'conversation.composer.dock';
    const SESSION_PROBE_ID = 'quickbar-session-probe';
    const PENDING_TOGGLE_TTL_MS = 15000;
    const STREAM_RETRY_MS = 2000;
    /** Client-side only: how long a remembered workspace/model choice stays valid. */
    const DEFAULT_REMEMBER_WINDOW_MS = 600000;
    const LS_WORKSPACE_KEY = 'dsh-quickbar:last-workspace';
    const LS_MODEL_KEY = 'dsh-quickbar:last-model';
    /** Marks a native-popup submit text as consumed (page reload / second window dedupe). */
    const LS_SUBMIT_KEY = 'dsh-quickbar:last-submit';
    const PENDING_SUBMIT_TTL_MS = 15000;
    /** Clock tolerance between a `submit` event's `at` and `pendingSubmit.at` of the same trigger. */
    const SUBMIT_MARKER_TOLERANCE_MS = 300;
    const LS_ONBOARDED_KEY = 'dsh-quickbar:onboarded';
    const LS_CONFLICT_KEY = 'dsh-quickbar:conflict-dismissed';
    /** Media types the prompt image part accepts (mirrors the conversation client). */
    const INCOMING_IMAGE_MEDIA_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
    /** Fixed type scale (DESIGN.md): one family, two weights, four sizes. */
    const TYPE = { title: 17, body: 13, hint: 11.5, caption: 11, control: 13 };
    /** Semantic spacing scale. */
    const SPACE = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20 };
    /** Suggested replacements for a conflicted global hotkey (first valid one wins). */
    const SUGGESTED_HOTKEYS = ['cmd+shift+opt+space', 'cmd+opt+space', 'cmd+shift+ctrl+space', 'ctrl+opt+space', 'shift+opt+space', 'cmd+shift+f9'];
    /** Attachment limits kept for this overlay (images are inline base64 parts). */
    const MAX_IMAGES = 4;
    const MAX_FILES = 4;
    const MAX_IMAGE_SIDE = 2000;
    const PICKER_AVAILABILITY_TIMEOUT_MS = 6000;
    /** Universal reasoning ids used when a model declares no efforts. */
    const UNIVERSAL_EFFORTS = [
      { id: 'off', labelKey: 'overlayEffortOff' },
      { id: 'low', labelKey: 'overlayEffortLow' },
      { id: 'medium', labelKey: 'overlayEffortMedium' },
      { id: 'high', labelKey: 'overlayEffortHigh' },
      { id: 'max', labelKey: 'overlayEffortMax' },
    ];

    const DEFAULT_CONFIG = {
      enabled: true,
      hotkey: 'cmd+shift+space',
      raiseWindow: true,
      inAppShortcut: 'cmd+shift+k',
    };

    const ZH = {
      nav: '快捷唤起',
      title: '快捷唤起',
      description: '用全局快捷键唤起 Harness 窗口，选择工作区和模型后输入问题，回车即可新建会话并发送。',
      sectionShortcuts: '快捷键',
      sectionHotkey: '全局快捷键',
      hotkeyHint: '点击后按下新的组合键；保存后立即生效。',
      hotkeyRecording: '请按下组合键…',
      hotkeyEmpty: '未设置',
      hotkeyNeedsModifier: '请配合 ⌘、⌥ 或 ⌃ 再加一个按键。',
      hotkeyUnsupported: '不支持这个按键。',
      hotkeyCancelHint: '按 Esc 取消',
      sectionStatus: '状态',
      statusReady: '已就绪',
      statusStarting: '启动中…',
      statusDisabled: '已停用',
      statusError: '启动失败',
      statusUnknown: '状态未知',
      statusRemoteUnavailable: '未连接到插件主进程，无法读取快捷键状态。',
      statusHotkeyLine: '系统快捷键：{hotkey}',
      statusHelperPid: '辅助进程 pid {pid}',
      statusAppliedHint: '修改后立即生效。',
      sectionBehavior: '行为',
      enableLabel: '启用全局快捷键',
      enableHint: '关闭后仍可用应用内快捷键打开快捷输入。',
      raiseLabel: '唤起窗口',
      raiseHint: '按快捷键时把 Harness 窗口带到前台。',
      inAppLabel: '应用内快捷键',
      inAppHint: '在本窗口聚焦时打开快捷输入。',
      clear: '清除',
      test: '测试',
      testing: '测试中…',
      testHint: '打开快捷输入；开启「唤起窗口」时还会把窗口带到前台。',
      testFailed: '测试失败：{message}',
      readOnly: '本部署的设置为只读。',
      unavailable: '当前无法读取该插件的配置。',
      configLoading: '正在读取配置…',
      writeRejected: '配置写入被拒绝。',
      overlayTitle: '问 DeepSeek',
      overlayPlaceholder: '输入问题，回车发送…',
      commandOpen: '打开快捷输入',
      overlaySend: '发送',
      overlaySending: '发送中…',
      overlayClose: '关闭',
      overlaySessionCurrent: '发送到当前会话',
      overlaySessionNew: '发送到新会话',
      overlayErrorGeneric: '发送失败，内容已保留。',
      overlayPromptRejected: '发送被拒绝：{message}',
      overlayNoTarget: '当前没有可用会话。',
      overlayHintSend: '发送',
      overlayHintNewline: '换行',
      overlayHintClose: '关闭',
      overlayHintPaste: '粘贴图片',
      overlayEffortOff: 'OFF',
      overlayEffortLow: 'Low',
      overlayEffortMedium: 'Medium',
      overlayEffortHigh: 'High',
      overlayEffortMax: 'Ultracode',
      overlayEffortDefault: '默认',
      overlayWorkspaceDefault: '默认工作区',
      overlayWorkspaceUnavailable: '工作区不可用',
      overlayModelUnavailable: '模型选择不可用',
      overlayModelDefault: '默认模型',
      overlaySendsToWorkspace: '将在「{workspace}」新建会话',
      overlayEffortLabel: '思考强度',
      overlayCatalogLoading: '正在加载模型…',
      overlayCatalogError: '模型列表加载失败：{message}',
      overlayCatalogEmpty: '没有可用模型',
      overlayRetry: '重试',
      overlayAttachFile: '添加文件',
      overlayFilesUnsupported: '文件暂不支持',
      overlayFilesUploadFailed: '文件上传失败：{message}',
      overlayModelSelectFailed: '模型切换失败：{message}',
      overlayImageProcessing: '正在处理图片…',
      overlayImageFailed: '图片处理失败，已跳过。',
      overlayTooManyImages: '最多添加 4 张图片。',
      overlayTooManyFiles: '最多添加 4 个文件。',
      overlayRemoveAttachment: '移除附件',
      overlayWorkspaceCreateFailed: '无法在该工作区创建会话：{message}',
      overlayUnsupportedContent: '当前无法发送附件。',
      noticeOnboardingTitle: '快捷唤起已就绪',
      noticeOnboardingBody: '按 {hotkey} 随时唤起快捷输入；回车发送，Esc 关闭。',
      noticeConflictTitle: '全局快捷键注册失败',
      noticeConflictBody: '{hotkey} 注册失败：{message}',
      noticeConflictSuggestion: '建议改用 {hotkey}',
      noticeGoSettings: '去设置',
      noticeDismiss: '知道了',
      noticeClose: '关闭提示',
      settingsConflictTitle: '快捷键冲突',
      settingsConflictHint: '系统拒绝了当前快捷键，通常是被其他应用占用。换一个组合后会自动重新注册。',
      settingsSuggestion: '建议组合：{hotkey}',
      settingsUseSuggestion: '改用此组合',
      settingsReRegister: '重新注册',
      settingsReRegistering: '注册中…',
      settingsReRegistered: '已请求重新注册快捷键。',
      settingsReRegisterFailed: '重新注册失败：{message}',
      settingsSuggestionApplied: '已改用 {hotkey}。',
    };

    const EN = {
      nav: 'Quickbar',
      title: 'Quickbar',
      description: 'Raise the Harness window with a global shortcut, pick a workspace and model, then press Enter to start a conversation and send.',
      sectionShortcuts: 'Shortcuts',
      sectionHotkey: 'Global shortcut',
      hotkeyHint: 'Click, then press the new combination. Changes take effect immediately.',
      hotkeyRecording: 'Press a combination…',
      hotkeyEmpty: 'Not set',
      hotkeyNeedsModifier: 'Include ⌘, ⌥ or ⌃ with one key.',
      hotkeyUnsupported: 'This key is not supported.',
      hotkeyCancelHint: 'Esc cancels',
      sectionStatus: 'Status',
      statusReady: 'Ready',
      statusStarting: 'Starting…',
      statusDisabled: 'Disabled',
      statusError: 'Failed',
      statusUnknown: 'Unknown',
      statusRemoteUnavailable: 'The plugin host is not connected, so the shortcut status is unavailable.',
      statusHotkeyLine: 'System shortcut: {hotkey}',
      statusHelperPid: 'Helper pid {pid}',
      statusAppliedHint: 'Changes take effect immediately.',
      sectionBehavior: 'Behavior',
      enableLabel: 'Enable global shortcut',
      enableHint: 'When off, the in-app shortcut still opens the quick input.',
      raiseLabel: 'Raise the window',
      raiseHint: 'Bring the Harness window to the front when the shortcut fires.',
      inAppLabel: 'In-app shortcut',
      inAppHint: 'Opens the quick input while this window is focused.',
      clear: 'Clear',
      test: 'Test',
      testing: 'Testing…',
      testHint: 'Opens the quick input. With Raise the window on, it also focuses the window.',
      testFailed: 'Test failed: {message}',
      readOnly: 'This deployment stores settings read-only.',
      unavailable: 'This plugin’s configuration is not available right now.',
      configLoading: 'Loading configuration…',
      writeRejected: 'The settings write was rejected.',
      overlayTitle: 'Ask DeepSeek',
      overlayPlaceholder: 'Ask anything, then press Enter…',
      commandOpen: 'Open quick input',
      overlaySend: 'Send',
      overlaySending: 'Sending…',
      overlayClose: 'Close',
      overlaySessionCurrent: 'Sends to the current conversation',
      overlaySessionNew: 'Sends to a new conversation',
      overlayErrorGeneric: 'Could not send. Your text was kept.',
      overlayPromptRejected: 'Send rejected: {message}',
      overlayNoTarget: 'No conversation is available right now.',
      overlayHintSend: 'send',
      overlayHintNewline: 'new line',
      overlayHintClose: 'close',
      overlayHintPaste: 'paste image',
      overlayEffortOff: 'OFF',
      overlayEffortLow: 'Low',
      overlayEffortMedium: 'Medium',
      overlayEffortHigh: 'High',
      overlayEffortMax: 'Ultracode',
      overlayEffortDefault: 'default',
      overlayWorkspaceDefault: 'Default workspace',
      overlayWorkspaceUnavailable: 'Workspaces unavailable',
      overlayModelUnavailable: 'Model selection unavailable',
      overlayModelDefault: 'Default model',
      overlaySendsToWorkspace: 'Starts a new conversation in “{workspace}”',
      overlayEffortLabel: 'Effort',
      overlayCatalogLoading: 'Loading models…',
      overlayCatalogError: 'Could not load models: {message}',
      overlayCatalogEmpty: 'No models available',
      overlayRetry: 'Retry',
      overlayAttachFile: 'Attach file',
      overlayFilesUnsupported: 'Files are not supported here',
      overlayFilesUploadFailed: 'File upload failed: {message}',
      overlayModelSelectFailed: 'Could not switch the model: {message}',
      overlayImageProcessing: 'Processing image…',
      overlayImageFailed: 'Could not read one image; it was skipped.',
      overlayTooManyImages: 'Up to 4 images.',
      overlayTooManyFiles: 'Up to 4 files.',
      overlayRemoveAttachment: 'Remove attachment',
      overlayWorkspaceCreateFailed: 'Could not create a session in that workspace: {message}',
      overlayUnsupportedContent: 'Attachments cannot be sent right now.',
      noticeOnboardingTitle: 'Quickbar is ready',
      noticeOnboardingBody: 'Press {hotkey} any time to open the quick input; Enter sends, Esc closes.',
      noticeConflictTitle: 'Global shortcut failed',
      noticeConflictBody: '{hotkey} could not be registered: {message}',
      noticeConflictSuggestion: 'Try {hotkey} instead',
      noticeGoSettings: 'Open settings',
      noticeDismiss: 'Got it',
      noticeClose: 'Dismiss notice',
      settingsConflictTitle: 'Shortcut conflict',
      settingsConflictHint: 'The system rejected this shortcut — usually another app owns it. Pick another combination and it re-registers automatically.',
      settingsSuggestion: 'Suggested: {hotkey}',
      settingsUseSuggestion: 'Use this combination',
      settingsReRegister: 'Re-register',
      settingsReRegistering: 'Re-registering…',
      settingsReRegistered: 'Re-registration requested.',
      settingsReRegisterFailed: 'Re-registration failed: {message}',
      settingsSuggestionApplied: 'Now using {hotkey}.',
    };

    // ---------------------------------------------------------------------
    // Theme tokens (no literal chrome colors anywhere)
    // ---------------------------------------------------------------------
    const C = {
      scrim: 'var(--dsw-alias-bg-mask-2)',
      card: 'var(--dsw-alias-bg-layer-3, var(--dsw-alias-bg-layer-2))',
      surface: 'var(--dsw-alias-bg-layer-1)',
      surfaceMuted: 'var(--dsw-alias-bg-module-platform)',
      borderL1: 'var(--dsw-alias-border-l1)',
      borderL2: 'var(--dsw-alias-border-l2)',
      borderL3: 'var(--dsw-alias-border-l3)',
      text: 'var(--dsw-alias-label-primary)',
      textSecondary: 'var(--dsw-alias-label-secondary)',
      textTertiary: 'var(--dsw-alias-label-tertiary)',
      textCaption: 'var(--dsw-alias-label-caption)',
      placeholder: 'var(--dsw-alias-label-caption)',
      hover: 'var(--dsw-alias-interactive-bg-hover)',
      active: 'var(--dsw-alias-interactive-bg-active)',
      dangerBg: 'var(--dsw-alias-interactive-bg-hover-danger)',
      primaryFill: 'var(--dsw-alias-button-primary-fill)',
      primaryHover: 'var(--dsw-alias-button-primary-hover)',
      primaryDimmed: 'var(--dsw-alias-button-primary-dimmed)',
      onPrimary: 'var(--dsw-alias-label-primary-foreground)',
      danger: 'var(--dsw-alias-state-error-primary)',
      success: 'var(--dsw-alias-state-success-primary)',
      warn: 'var(--dsw-alias-state-warn-label)',
      business: 'var(--dsw-alias-state-business-primary)',
      switchTrack: 'var(--dsw-alias-state-business-primary)',
      switchThumb: 'var(--dsw-alias-switch-thumb)',
      link: 'var(--dsw-alias-link)',
      shadow: 'var(--dsw-shadow-lv3)',
      focus: 'var(--dsw-focus-ring-color)',
      font: 'var(--dsw-font-family)',
    };

    const S = {
      // ---- overlay
      overlay: {
        position: 'fixed',
        inset: 0,
        zIndex: 300,
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'center',
        boxSizing: 'border-box',
        paddingTop: '16vh',
        paddingLeft: 20,
        paddingRight: 20,
        pointerEvents: 'auto',
        background: C.scrim,
      },
      card: {
        width: 'min(640px, calc(100vw - 40px))',
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
        padding: '14px 16px 12px',
        background: C.card,
        color: C.text,
        border: '1px solid ' + C.borderL2,
        borderRadius: 14,
        boxShadow: C.shadow,
        fontFamily: C.font,
      },
      cardFocused: {
        border: '1px solid ' + C.focus,
      },
      header: {
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        minWidth: 0,
      },
      headerIcon: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: 22,
        height: 22,
        borderRadius: 7,
        background: C.surfaceMuted,
        color: C.textSecondary,
        flex: 'none',
      },
      headerTitle: {
        fontSize: 13,
        fontWeight: 600,
        color: C.text,
        minWidth: 0,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      headerSpacer: { flex: 1, minWidth: 8 },
      hotkeyBadge: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        padding: '2px 7px',
        borderRadius: 6,
        border: '1px solid ' + C.borderL2,
        background: C.surfaceMuted,
        color: C.textTertiary,
        fontSize: 11,
        lineHeight: '16px',
        fontVariantNumeric: 'tabular-nums',
        whiteSpace: 'nowrap',
        flex: 'none',
      },
      iconButton: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: 24,
        height: 24,
        padding: 0,
        border: 'none',
        borderRadius: 7,
        background: 'transparent',
        color: C.textTertiary,
        cursor: 'pointer',
        flex: 'none',
      },
      textarea: {
        width: '100%',
        minHeight: 26,
        maxHeight: 88,
        resize: 'none',
        overflowY: 'auto',
        padding: 0,
        border: 'none',
        outline: 'none',
        background: 'transparent',
        color: C.text,
        caretColor: C.text,
        fontFamily: C.font,
        fontSize: 13,
        lineHeight: '20px',
        boxSizing: 'border-box',
      },
      errorRow: {
        padding: '6px 10px',
        borderRadius: 8,
        background: C.dangerBg,
        color: C.danger,
        fontSize: 12,
        lineHeight: '18px',
        wordBreak: 'break-word',
      },
      metaRow: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 12,
        flexWrap: 'wrap',
      },
      sessionHint: {
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
        minWidth: 0,
      },
      hintGroup: {
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        flexWrap: 'wrap',
        marginLeft: 'auto',
      },
      hint: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
        whiteSpace: 'nowrap',
      },
      kbd: {
        display: 'inline-flex',
        alignItems: 'center',
        padding: '0 5px',
        minWidth: 16,
        height: 16,
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL2,
        borderRadius: 4,
        background: C.surfaceMuted,
        color: C.textTertiary,
        fontSize: 10,
        lineHeight: '14px',
        fontFamily: C.font,
      },
      footer: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'flex-end',
        gap: 8,
      },
      button: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 6,
        height: 30,
        padding: '0 14px',
        border: 'none',
        borderRadius: 8,
        fontSize: 13,
        fontWeight: 500,
        fontFamily: C.font,
        cursor: 'pointer',
        background: C.primaryFill,
        color: C.onPrimary,
        transition: 'background 120ms ease',
      },
      buttonHover: {
        background: C.primaryHover,
      },
      buttonFocus: {
        boxShadow: '0 0 0 2px ' + C.focus,
      },
      buttonDisabled: {
        background: C.active,
        color: C.textTertiary,
        cursor: 'default',
      },
      inputWrap: {
        position: 'relative',
        display: 'flex',
        flexDirection: 'column',
        minWidth: 0,
        background: C.surfaceMuted,
        borderRadius: 10,
        padding: '8px 10px',
      },
      placeholder: {
        position: 'absolute',
        top: 8,
        left: 10,
        right: 10,
        fontSize: 13,
        lineHeight: '20px',
        color: C.placeholder,
        pointerEvents: 'none',
        userSelect: 'none',
        whiteSpace: 'nowrap',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
      },
      // ---- overlay v2: workspace / model pickers + attachments
      toolbar: {
        position: 'relative',
        display: 'flex',
        alignItems: 'center',
        gap: 6,
        flexWrap: 'wrap',
        minWidth: 0,
      },
      toolbarItem: {
        position: 'relative',
        display: 'inline-flex',
        alignItems: 'center',
        minWidth: 0,
      },
      toolbarSpacer: {
        flex: 1,
        minWidth: 4,
      },
      toolbarHint: {
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
        whiteSpace: 'nowrap',
      },
      selectorButton: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 4,
        maxWidth: 260,
        minWidth: 0,
        height: 26,
        padding: '0 8px',
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL1,
        borderRadius: 7,
        background: C.surfaceMuted,
        color: C.textSecondary,
        fontFamily: C.font,
        fontSize: 12,
        lineHeight: '20px',
        cursor: 'pointer',
      },
      selectorLabel: {
        minWidth: 0,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      selectorChevron: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        color: C.textCaption,
      },
      attachButton: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        width: 26,
        height: 26,
        padding: 0,
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL1,
        borderRadius: 7,
        background: C.surfaceMuted,
        color: C.textSecondary,
        cursor: 'pointer',
      },
      hiddenInput: {
        display: 'none',
      },
      popover: {
        position: 'absolute',
        top: 'calc(100% + 6px)',
        left: 0,
        zIndex: 30,
        display: 'flex',
        flexDirection: 'column',
        gap: 2,
        minWidth: 240,
        maxWidth: 'min(380px, calc(100vw - 80px))',
        maxHeight: 'min(300px, 45vh)',
        overflowY: 'auto',
        padding: 6,
        boxSizing: 'border-box',
        background: C.card,
        border: '1px solid ' + C.borderL2,
        borderRadius: 10,
        boxShadow: C.shadow,
        color: C.text,
      },
      popoverRight: {
        position: 'absolute',
        top: 'calc(100% + 6px)',
        right: 0,
        zIndex: 30,
        display: 'flex',
        flexDirection: 'column',
        gap: 2,
        minWidth: 260,
        maxWidth: 'min(400px, calc(100vw - 80px))',
        maxHeight: 'min(320px, 48vh)',
        overflowY: 'auto',
        padding: 6,
        boxSizing: 'border-box',
        background: C.card,
        border: '1px solid ' + C.borderL2,
        borderRadius: 10,
        boxShadow: C.shadow,
        color: C.text,
      },
      popoverStatus: {
        padding: '8px',
        fontSize: 12,
        lineHeight: '18px',
        color: C.textTertiary,
      },
      popoverError: {
        display: 'flex',
        flexDirection: 'column',
        gap: 6,
        padding: '6px 8px',
        marginBottom: 2,
        borderRadius: 8,
        background: C.dangerBg,
        color: C.danger,
        fontSize: 11,
        lineHeight: '16px',
      },
      popoverRetry: {
        alignSelf: 'flex-start',
        padding: 0,
        border: 'none',
        background: 'transparent',
        color: 'inherit',
        fontFamily: C.font,
        fontSize: 11,
        fontWeight: 600,
        cursor: 'pointer',
      },
      popoverGroup: {
        padding: '6px 8px 2px',
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
        whiteSpace: 'nowrap',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
      },
      popoverOption: {
        display: 'flex',
        alignItems: 'center',
        gap: 6,
        width: '100%',
        padding: '5px 8px',
        boxSizing: 'border-box',
        border: 'none',
        borderRadius: 6,
        background: 'transparent',
        color: C.text,
        fontFamily: C.font,
        fontSize: 13,
        lineHeight: '18px',
        textAlign: 'left',
        cursor: 'pointer',
      },
      popoverOptionSelected: {
        background: C.active,
      },
      popoverOptionLabel: {
        flex: 1,
        minWidth: 0,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      popoverOptionDetail: {
        flex: 'none',
        maxWidth: 140,
        marginLeft: 8,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
        fontSize: 11,
        color: C.textCaption,
      },
      popoverCheck: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        color: C.text,
      },
      effortSection: {
        display: 'flex',
        flexDirection: 'column',
        gap: 6,
        marginTop: 2,
        padding: '6px 8px 2px',
        borderTop: '1px solid ' + C.borderL1,
      },
      effortLabel: {
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
      },
      effortChips: {
        display: 'flex',
        flexWrap: 'wrap',
        gap: 6,
      },
      effortChip: {
        height: 24,
        padding: '0 9px',
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL2,
        borderRadius: 6,
        background: 'transparent',
        color: C.textSecondary,
        fontFamily: C.font,
        fontSize: 12,
        lineHeight: '20px',
        cursor: 'pointer',
        whiteSpace: 'nowrap',
      },
      effortChipSelected: {
        background: C.business,
        border: '1px solid ' + C.business,
        color: C.onPrimary,
      },
      attachmentsRow: {
        display: 'flex',
        alignItems: 'center',
        gap: 6,
        flexWrap: 'wrap',
      },
      attachmentChip: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 6,
        maxWidth: 210,
        minWidth: 0,
        padding: '3px 5px 3px 3px',
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL2,
        borderRadius: 8,
        background: C.surfaceMuted,
        color: C.textSecondary,
        fontSize: 11,
        lineHeight: '16px',
      },
      attachmentThumb: {
        display: 'block',
        flex: 'none',
        width: 26,
        height: 26,
        borderRadius: 5,
        objectFit: 'cover',
      },
      attachmentIcon: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        width: 26,
        height: 26,
        borderRadius: 5,
        background: C.surface,
        color: C.textTertiary,
      },
      attachmentName: {
        minWidth: 0,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      attachmentRemove: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        width: 18,
        height: 18,
        padding: 0,
        border: 'none',
        borderRadius: 4,
        background: 'transparent',
        color: C.textTertiary,
        cursor: 'pointer',
      },
      attachmentHint: {
        fontSize: 11,
        lineHeight: '16px',
        color: C.textCaption,
      },
      // ---- settings
      settingsRoot: {
        display: 'flex',
        flexDirection: 'column',
        gap: 16,
        minHeight: 0,
        padding: '2px 2px 28px',
        color: C.text,
        fontFamily: C.font,
      },
      settingsHeader: {
        display: 'flex',
        flexDirection: 'column',
        gap: 6,
      },
      settingsTitle: {
        margin: 0,
        fontSize: TYPE.title,
        fontWeight: 500,
        lineHeight: '24px',
        color: C.text,
      },
      settingsDesc: {
        margin: 0,
        fontSize: TYPE.body,
        lineHeight: 1.55,
        color: C.textTertiary,
      },
      settingsCard: {
        display: 'flex',
        flexDirection: 'column',
        gap: SPACE.md,
        padding: '12px ' + SPACE.lg + 'px',
        background: C.surfaceMuted,
        border: '1px solid ' + C.borderL1,
        borderRadius: 12,
      },
      cardTitle: {
        fontSize: TYPE.control,
        fontWeight: 500,
        color: C.text,
      },
      row: {
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'space-between',
        gap: 16,
      },
      rowText: {
        display: 'flex',
        flexDirection: 'column',
        gap: 3,
        minWidth: 0,
      },
      rowLabel: {
        fontSize: 13,
        lineHeight: '20px',
        color: C.text,
      },
      rowHint: {
        fontSize: TYPE.hint,
        lineHeight: 1.5,
        color: C.textCaption,
      },
      field: {
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'flex-end',
        gap: 5,
        flex: 'none',
      },
      recorder: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 8,
        minWidth: 190,
        height: 30,
        padding: '0 12px',
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL2,
        borderRadius: 8,
        background: C.surface,
        color: C.text,
        fontFamily: C.font,
        fontSize: TYPE.control,
        textAlign: 'left',
        cursor: 'pointer',
      },
      recorderActive: {
        border: '1px solid ' + C.focus,
      },
      recorderValue: {
        color: C.text,
        fontWeight: 500,
        letterSpacing: '0.02em',
      },
      recorderPlaceholder: {
        color: C.textTertiary,
      },
      recorderHint: {
        marginLeft: 'auto',
        fontSize: TYPE.caption,
        color: C.textCaption,
      },
      fieldError: {
        maxWidth: 240,
        fontSize: 11,
        lineHeight: '15px',
        color: C.danger,
        textAlign: 'right',
      },
      linkButton: {
        padding: 0,
        border: 'none',
        background: 'transparent',
        color: C.link,
        fontFamily: C.font,
        fontSize: TYPE.caption,
        cursor: 'pointer',
      },
      controlDisabled: {
        opacity: 0.45,
        cursor: 'default',
      },
      statusRow: {
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        flexWrap: 'wrap',
      },
      statusDot: {
        width: 8,
        height: 8,
        borderRadius: '50%',
        flex: 'none',
        background: C.textTertiary,
      },
      statusLabel: {
        fontSize: TYPE.control,
        fontWeight: 500,
        color: C.text,
      },
      statusDetail: {
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.textTertiary,
        wordBreak: 'break-word',
      },
      notice: {
        padding: '6px 10px',
        borderRadius: 8,
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.textSecondary,
        background: C.hover,
      },
      noticeError: {
        padding: '6px 10px',
        borderRadius: 8,
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.danger,
        background: C.dangerBg,
      },
      noticeWarn: {
        padding: '6px 10px',
        borderRadius: 8,
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.warn,
        background: C.hover,
      },
      switchTrack: {
        position: 'relative',
        display: 'inline-flex',
        alignItems: 'center',
        width: 36,
        height: 20,
        padding: 2,
        boxSizing: 'border-box',
        border: 'none',
        borderRadius: 999,
        cursor: 'pointer',
        flex: 'none',
        transition: 'background 120ms ease',
      },
      switchTrackOn: {
        background: C.switchTrack,
      },
      switchTrackOff: {
        background: C.active,
      },
      switchThumb: {
        display: 'block',
        width: 16,
        height: 16,
        borderRadius: '50%',
        background: C.switchThumb,
        boxShadow: C.shadow,
        transform: 'translateX(0)',
        transition: 'transform 120ms ease',
      },
      switchThumbOn: {
        transform: 'translateX(16px)',
      },
      testRow: {
        display: 'flex',
        alignItems: 'center',
        gap: SPACE.sm,
        flexWrap: 'wrap',
      },
      secondaryButton: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 6,
        height: 28,
        padding: '0 12px',
        boxSizing: 'border-box',
        border: '1px solid ' + C.borderL2,
        borderRadius: 8,
        background: 'transparent',
        color: C.text,
        fontFamily: C.font,
        fontSize: TYPE.control,
        cursor: 'pointer',
        transition: 'background 120ms ease, border-color 120ms ease',
      },
      secondaryHover: {
        background: C.hover,
        border: '1px solid ' + C.borderL3,
      },
      secondaryFocus: {
        border: '1px solid ' + C.focus,
        boxShadow: '0 0 0 2px ' + C.focus,
      },
      noticeWrap: {
        position: 'fixed',
        top: 'calc(var(--dsh-frame-chrome-top, 0px) + 18px)',
        left: 0,
        right: 0,
        zIndex: 320,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: SPACE.sm,
        pointerEvents: 'none',
        padding: '0 16px',
        boxSizing: 'border-box',
      },
      noticeCard: {
        pointerEvents: 'auto',
        display: 'flex',
        alignItems: 'flex-start',
        gap: SPACE.md,
        width: 'min(460px, calc(100vw - 32px))',
        boxSizing: 'border-box',
        padding: '12px 14px',
        background: C.card,
        color: C.text,
        border: '1px solid ' + C.borderL2,
        borderRadius: 12,
        boxShadow: C.shadow,
        fontFamily: C.font,
        animation: 'none',
      },
      noticeIcon: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        width: 26,
        height: 26,
        borderRadius: 8,
        background: C.surfaceMuted,
        color: C.textSecondary,
      },
      noticeIconWarn: {
        background: C.dangerBg,
        color: C.danger,
      },
      noticeBodyWrap: {
        display: 'flex',
        flexDirection: 'column',
        gap: 3,
        minWidth: 0,
        flex: 1,
      },
      noticeTitle: {
        fontSize: TYPE.control,
        fontWeight: 500,
        lineHeight: '18px',
        color: C.text,
      },
      noticeText: {
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.textSecondary,
        wordBreak: 'break-word',
      },
      noticeActions: {
        display: 'flex',
        alignItems: 'center',
        gap: SPACE.sm,
        marginTop: 6,
        flexWrap: 'wrap',
      },
      noticePrimary: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: 26,
        padding: '0 10px',
        border: 'none',
        borderRadius: 7,
        background: C.primaryFill,
        color: C.onPrimary,
        fontFamily: C.font,
        fontSize: TYPE.hint,
        fontWeight: 500,
        cursor: 'pointer',
      },
      noticeGhost: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: 26,
        padding: '0 8px',
        border: '1px solid transparent',
        borderRadius: 7,
        background: 'transparent',
        color: C.textSecondary,
        fontFamily: C.font,
        fontSize: TYPE.hint,
        cursor: 'pointer',
      },
      noticeClose: {
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        width: 22,
        height: 22,
        padding: 0,
        border: 'none',
        borderRadius: 6,
        background: 'transparent',
        color: C.textTertiary,
        cursor: 'pointer',
      },
      conflictCard: {
        display: 'flex',
        flexDirection: 'column',
        gap: SPACE.sm,
        padding: '12px ' + SPACE.lg + 'px',
        borderRadius: 12,
        background: C.dangerBg,
        border: '1px solid ' + C.borderL1,
      },
      conflictTitle: {
        fontSize: TYPE.control,
        fontWeight: 500,
        color: C.danger,
      },
      conflictText: {
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.textSecondary,
        wordBreak: 'break-word',
      },
      conflictHint: {
        fontSize: TYPE.hint,
        lineHeight: '17px',
        color: C.textTertiary,
      },
      suggestionRow: {
        display: 'flex',
        alignItems: 'center',
        gap: SPACE.sm,
        flexWrap: 'wrap',
      },
      suggestionCode: {
        display: 'inline-flex',
        alignItems: 'center',
        height: 24,
        padding: '0 8px',
        borderRadius: 6,
        border: '1px solid ' + C.borderL2,
        background: C.surface,
        color: C.text,
        fontFamily: C.font,
        fontSize: TYPE.hint,
        fontWeight: 500,
        letterSpacing: '0.02em',
      },
    };

    // ---------------------------------------------------------------------
    // Hotkey spec helpers (grammar mirrors native/quickbar-hotkey)
    // ---------------------------------------------------------------------
    const MOD_ORDER = ['cmd', 'shift', 'opt', 'ctrl'];
    const MOD_SYMBOL = { cmd: '⌘', shift: '⇧', opt: '⌥', ctrl: '⌃' };
    const MOD_ALIAS = {
      cmd: 'cmd',
      command: 'cmd',
      meta: 'cmd',
      super: 'cmd',
      shift: 'shift',
      opt: 'opt',
      alt: 'opt',
      option: 'opt',
      ctrl: 'ctrl',
      control: 'ctrl',
    };
    const NAMED_KEYS = {
      space: 'space',
      tab: 'tab',
      return: 'return',
      enter: 'return',
      escape: 'escape',
      esc: 'escape',
      comma: 'comma',
      period: 'period',
      slash: 'slash',
      minus: 'minus',
      backtick: 'backtick',
      left: 'left',
      right: 'right',
      up: 'up',
      down: 'down',
    };
    const KEY_LABEL = {
      space: 'Space',
      tab: 'Tab',
      return: 'Return',
      escape: 'Esc',
      comma: ',',
      period: '.',
      slash: '/',
      minus: '-',
      backtick: '`',
      left: '←',
      right: '→',
      up: '↑',
      down: '↓',
    };
    const EVENT_KEY_TOKEN = {
      ' ': 'space',
      Spacebar: 'space',
      Enter: 'return',
      Tab: 'tab',
      Escape: 'escape',
      Esc: 'escape',
      ',': 'comma',
      '.': 'period',
      '/': 'slash',
      '-': 'minus',
      '`': 'backtick',
      ArrowLeft: 'left',
      ArrowRight: 'right',
      ArrowUp: 'up',
      ArrowDown: 'down',
    };

    function canonicalKeyToken(token) {
      if (typeof token !== 'string' || token === '') return null;
      const value = token.toLowerCase();
      if (/^[a-z]$/u.test(value)) return value;
      if (/^[0-9]$/u.test(value)) return value;
      if (/^f(?:[1-9]|1[0-2])$/u.test(value)) return value;
      if (Object.prototype.hasOwnProperty.call(NAMED_KEYS, value)) return NAMED_KEYS[value];
      return null;
    }

    /** Parse a host spec such as `cmd+shift+space`; null when unsupported. */
    function parseSpec(spec) {
      if (typeof spec !== 'string') return null;
      const trimmed = spec.trim();
      if (trimmed === '') return null;
      const parts = trimmed.split('+').map(function (part) { return part.trim(); }).filter(function (part) { return part !== ''; });
      if (parts.length === 0) return null;
      const key = canonicalKeyToken(parts[parts.length - 1]);
      if (key === null) return null;
      const mods = { cmd: false, shift: false, opt: false, ctrl: false };
      for (let index = 0; index < parts.length - 1; index += 1) {
        const alias = MOD_ALIAS[parts[index].toLowerCase()];
        if (alias === undefined) return null;
        mods[alias] = true;
      }
      return { key: key, mods: mods };
    }

    function isValidSpec(spec) {
      return parseSpec(spec) !== null;
    }

    /** Human label such as `⌘⇧Space`; unparseable specs are shown verbatim. */
    function formatAccel(spec) {
      const parsed = parseSpec(spec);
      if (parsed === null) return typeof spec === 'string' ? spec.trim() : '';
      let out = '';
      for (let index = 0; index < MOD_ORDER.length; index += 1) {
        if (parsed.mods[MOD_ORDER[index]]) out += MOD_SYMBOL[MOD_ORDER[index]];
      }
      out += capKey(parsed.key);
      return out;
    }

    function capKey(key) {
      if (Object.prototype.hasOwnProperty.call(KEY_LABEL, key)) return KEY_LABEL[key];
      if (/^f[0-9]+$/u.test(key)) return key.toUpperCase();
      return key.toUpperCase();
    }

    /** KeyboardEvent -> canonical spec; null when the key is not in the grammar. */
    function eventToSpec(event) {
      if (event === null || typeof event !== 'object') return null;
      const raw = typeof event.key === 'string' ? event.key : '';
      let key = Object.prototype.hasOwnProperty.call(EVENT_KEY_TOKEN, raw) ? EVENT_KEY_TOKEN[raw] : null;
      if (key === null) key = canonicalKeyToken(raw);
      if (key === null) return null;
      const mods = [];
      if (event.metaKey) mods.push('cmd');
      if (event.shiftKey) mods.push('shift');
      if (event.altKey) mods.push('opt');
      if (event.ctrlKey) mods.push('ctrl');
      if (mods.length === 0) return null;
      return mods.join('+') + '+' + key;
    }

    /**
     * Map a shortcut spec to the shell Shortcut Service's physical binding
     * (`{ code, modifiers }`, modifiers from primary/control/alt/shift).
     * Returns null when the spec or the key has no physical-code equivalent.
     */
    const SHORTCUT_CODE = {
      space: 'Space',
      enter: 'Enter',
      tab: 'Tab',
      escape: 'Escape',
      backspace: 'Backspace',
      delete: 'Delete',
      arrowup: 'ArrowUp',
      arrowdown: 'ArrowDown',
      arrowleft: 'ArrowLeft',
      arrowright: 'ArrowRight',
      ',': 'Comma',
      '.': 'Period',
      '/': 'Slash',
      ';': 'Semicolon',
      "'": 'Quote',
      '[': 'BracketLeft',
      ']': 'BracketRight',
      '\\': 'Backslash',
      '-': 'Minus',
      '=': 'Equal',
      '`': 'Backquote',
    };
    function specToShortcutBinding(spec) {
      const parsed = parseSpec(spec);
      if (parsed === null) return null;
      let code = SHORTCUT_CODE[parsed.key];
      if (code === undefined) {
        if (/^[a-z]$/u.test(parsed.key)) code = 'Key' + parsed.key.toUpperCase();
        else if (/^[0-9]$/u.test(parsed.key)) code = 'Digit' + parsed.key;
        else if (/^f([1-9]|1[0-9]|2[0-4])$/u.test(parsed.key)) code = parsed.key.toUpperCase();
      }
      if (code === undefined) return null;
      const modifiers = [];
      if (parsed.mods.cmd) modifiers.push('primary');
      if (parsed.mods.shift) modifiers.push('shift');
      if (parsed.mods.opt) modifiers.push('alt');
      if (parsed.mods.ctrl) modifiers.push('control');
      return { code: code, modifiers: modifiers };
    }

    function eventMatchesSpec(parsed, event) {
      if (parsed === null || event === null) return false;
      const raw = typeof event.key === 'string' ? event.key : '';
      let key = Object.prototype.hasOwnProperty.call(EVENT_KEY_TOKEN, raw) ? EVENT_KEY_TOKEN[raw] : null;
      if (key === null) key = canonicalKeyToken(raw);
      if (key !== parsed.key) return false;
      return Boolean(event.metaKey) === parsed.mods.cmd
        && Boolean(event.shiftKey) === parsed.mods.shift
        && Boolean(event.altKey) === parsed.mods.opt
        && Boolean(event.ctrlKey) === parsed.mods.ctrl;
    }

    // ---------------------------------------------------------------------
    // Remote descriptors for the host service `quickbar`
    // ---------------------------------------------------------------------
    const RESULT_JSON = { mode: 'src-json' };
    /**
     * Every declared Remote parameter needs a `strict` codec for the Gateway's local
     * validation. Direct invocation passes the wire value through unchanged (the codec is
     * only consumed by the unused typed-input helper), so this passthrough is sufficient.
     */
    /** Passthrough strict codecs for the scalar/boolean Remote parameters (see above). */
    const BOOLEAN_CODEC = {
      mode: 'strict',
      typeSymbol: 'dsh-quickbar#boolean',
      create: function () {
        return { parse: function (value) { return value; } };
      },
      jsonSchema: { type: 'boolean' },
    };
    const TEXT_CODEC = {
      mode: 'strict',
      typeSymbol: 'dsh-quickbar#string',
      create: function () {
        return { parse: function (value) { return value; } };
      },
      jsonSchema: { type: 'string' },
    };
    const SELECTION_CODEC = {
      mode: 'strict',
      typeSymbol: 'dsh-quickbar#QuickbarSelection',
      create: function () {
        return {
          parse: function (value) {
            return value;
          },
        };
      },
      jsonSchema: { type: 'object', additionalProperties: true },
    };

    function descriptor(method, extra) {
      const base = {
        id: SERVICE + '.' + method,
        service: SERVICE,
        namespace: SERVICE,
        method: method,
        invocation: { kind: 'direct' },
        parameters: [],
        result: RESULT_JSON,
      };
      return extra === undefined ? base : Object.assign(base, extra);
    }

    const CONTRIBUTION = {
      package: PACKAGE_NAME,
      descriptors: [
        descriptor('getState'),
        descriptor('testTrigger'),
        descriptor('watch', { mode: 'stream', cancellation: { parameter: 'signal' } }),
        // v4: the in-app overlay mirrors its selection to the Host (native popup parity).
        descriptor('setSelection', {
          parameters: [{ name: 'selection', wire: 'selection', source: 'json', codec: SELECTION_CODEC }],
        }),
        // v5: send-then-raise and the native panel's submit acknowledgement.
        descriptor('raiseWindow'),
        descriptor('reportSubmitResult', {
          parameters: [
            { name: 'ok', wire: 'ok', source: 'json', codec: BOOLEAN_CODEC },
            { name: 'message', wire: 'message', source: 'json', codec: TEXT_CODEC },
          ],
        }),
      ],
    };

    // ---------------------------------------------------------------------
    // Small generic helpers
    // ---------------------------------------------------------------------
    function errorText(error) {
      if (error === null || error === undefined) return '';
      if (typeof error === 'string') return error;
      if (typeof error.message === 'string' && error.message !== '') return error.message;
      try {
        return String(error);
      } catch (unused) {
        return '';
      }
    }

    function remoteFailureText(result) {
      if (result && result.error) return errorText(result.error);
      return '';
    }

    function unwrapRemoteValue(item) {
      if (item !== null && typeof item === 'object' && 'ok' in item && 'value' in item) {
        return item.ok === true ? item.value : undefined;
      }
      return item;
    }

    function sleep(ms, signal) {
      return new Promise(function (resolve) {
        if (signal !== undefined && signal !== null && signal.aborted) {
          resolve();
          return;
        }
        let timer = null;
        let settled = false;
        function finish() {
          if (settled) return;
          settled = true;
          if (timer !== null) clearTimeout(timer);
          if (signal !== undefined && signal !== null) signal.removeEventListener('abort', onAbort);
          resolve();
        }
        function onAbort() {
          finish();
        }
        timer = setTimeout(finish, ms);
        if (signal !== undefined && signal !== null) signal.addEventListener('abort', onAbort, { once: true });
      });
    }

    function isPlainObject(value) {
      return value !== null && typeof value === 'object' && !Array.isArray(value);
    }

    // ---------------------------------------------------------------------
    // v2 helpers: local memory, model metadata, image preparation
    // ---------------------------------------------------------------------
    function readStoredJson(key) {
      try {
        if (typeof window === 'undefined' || window.localStorage === undefined) return null;
        const raw = window.localStorage.getItem(key);
        if (raw === null || raw === '') return null;
        const value = JSON.parse(raw);
        return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : null;
      } catch (error) {
        return null;
      }
    }

    function writeStoredJson(key, value) {
      try {
        if (typeof window === 'undefined' || window.localStorage === undefined) return;
        window.localStorage.setItem(key, JSON.stringify(value));
      } catch (error) {
        // private mode / quota: remembering is optional
      }
    }

    function effectiveRememberWindowMs(cfg) {
      const raw = cfg !== null && cfg !== undefined && typeof cfg.rememberWindowMs === 'number' ? cfg.rememberWindowMs : DEFAULT_REMEMBER_WINDOW_MS;
      return raw >= 0 ? raw : DEFAULT_REMEMBER_WINDOW_MS;
    }

    /** The default workspace is the one whose title is the sentinel "default-workspace" (or empty); otherwise the first listed one. */
    function defaultWorkspaceId(items) {
      if (!Array.isArray(items) || items.length === 0) return null;
      for (const item of items) {
        if (item !== null && typeof item === 'object') {
          const title = typeof item.title === 'string' ? item.title.trim() : '';
          if (title === '' || title === 'default-workspace') return item.id;
        }
      }
      return items[0].id;
    }

    function findModelEntry(groups, provider, model) {
      if (!Array.isArray(groups) || typeof provider !== 'string' || typeof model !== 'string') return null;
      for (const group of groups) {
        if (group === null || typeof group !== 'object' || group.id !== provider) continue;
        const models = Array.isArray(group.models) ? group.models : [];
        for (const candidate of models) {
          if (candidate !== null && typeof candidate === 'object' && candidate.id === model) return { group: group, model: candidate };
        }
      }
      return null;
    }

    function modelDeclaredEfforts(model) {
      const reasoning = model !== null && model !== undefined && typeof model === 'object' ? model.reasoning : null;
      const efforts = reasoning !== null && typeof reasoning === 'object' && Array.isArray(reasoning.efforts) ? reasoning.efforts : [];
      const declared = [];
      for (const effort of efforts) {
        if (effort === null || typeof effort !== 'object' || typeof effort.id !== 'string' || effort.id === '') continue;
        declared.push({ id: effort.id, name: typeof effort.name === 'string' && effort.name !== '' ? effort.name : effort.id });
      }
      return declared;
    }

    function modelDefaultEffort(model) {
      const reasoning = model !== null && model !== undefined && typeof model === 'object' ? model.reasoning : null;
      if (reasoning === null || typeof reasoning !== 'object') return undefined;
      return typeof reasoning.defaultEffort === 'string' && reasoning.defaultEffort !== '' ? reasoning.defaultEffort : undefined;
    }

    function isUniversalEffort(effortId) {
      for (const effort of UNIVERSAL_EFFORTS) if (effort.id === effortId) return true;
      return false;
    }

    function universalEffortName(t, effortId) {
      for (const effort of UNIVERSAL_EFFORTS) if (effort.id === effortId) return t(effort.labelKey);
      return effortId;
    }

    function effortNameFor(t, model, effortId) {
      if (typeof effortId !== 'string' || effortId === '') return t('overlayEffortDefault');
      const declared = modelDeclaredEfforts(model);
      for (const effort of declared) if (effort.id === effortId) return effort.name;
      if (isUniversalEffort(effortId)) return universalEffortName(t, effortId);
      return effortId;
    }

    /** Normalize a selection against the catalog; returns null when the model is gone. */
    function normalizeSelection(selection, groups) {
      if (selection === null || selection === undefined || typeof selection !== 'object') return null;
      const found = findModelEntry(groups, selection.provider, selection.model);
      if (found === null) return null;
      let effort = typeof selection.reasoningEffort === 'string' && selection.reasoningEffort !== '' ? selection.reasoningEffort : undefined;
      if (effort !== undefined) {
        const declared = modelDeclaredEfforts(found.model);
        const valid = declared.length > 0 ? declared.some(function (entry) { return entry.id === effort; }) : isUniversalEffort(effort);
        if (!valid) effort = undefined;
      }
      if (effort === undefined) effort = modelDefaultEffort(found.model);
      return {
        provider: selection.provider,
        model: selection.model,
        reasoningEffort: effort,
      };
    }

    function createLocalizedError(message, cause) {
      const error = new Error(message);
      error.quickbarLocalized = true;
      if (cause !== undefined) error.cause = cause;
      return error;
    }

    function readBlobAsDataUrl(blob) {
      return new Promise(function (resolve, reject) {
        const reader = new FileReader();
        reader.onload = function () { resolve(String(reader.result)); };
        reader.onerror = function () { reject(reader.error !== null && reader.error !== undefined ? reader.error : new Error('file read failed')); };
        reader.readAsDataURL(blob);
      });
    }

    function loadImageElement(source) {
      return new Promise(function (resolve, reject) {
        const image = new Image();
        image.onload = function () { resolve(image); };
        image.onerror = function () { reject(new Error('image decode failed')); };
        image.src = source;
      });
    }

    function canvasHasAlpha(context, width, height) {
      try {
        const data = context.getImageData(0, 0, width, height).data;
        for (let index = 3; index < data.length; index += 16) {
          if (data[index] !== 255) return true;
        }
        return false;
      } catch (error) {
        return true;
      }
    }

    /**
     * Read one pasted/picked image into the prompt image wire form:
     * downscaled to <= 2000px on the longest side; JPEG when fully opaque,
     * PNG when the image really has an alpha channel (webp is not assumed).
     */
    async function prepareImageAttachment(file) {
      const originalUrl = await readBlobAsDataUrl(file);
      const image = await loadImageElement(originalUrl);
      const naturalWidth = image.naturalWidth > 0 ? image.naturalWidth : image.width;
      const naturalHeight = image.naturalHeight > 0 ? image.naturalHeight : image.height;
      const scale = Math.min(1, MAX_IMAGE_SIDE / Math.max(naturalWidth, naturalHeight));
      const width = Math.max(1, Math.round(naturalWidth * scale));
      const height = Math.max(1, Math.round(naturalHeight * scale));
      if (typeof document === 'undefined') throw new Error('image processing needs a document');
      const canvas = document.createElement('canvas');
      canvas.width = width;
      canvas.height = height;
      const context = canvas.getContext('2d');
      if (context === null || context === undefined) throw new Error('canvas 2d context unavailable');
      context.drawImage(image, 0, 0, width, height);
      let dataUrl;
      let mediaType;
      const alpha = file.type === 'image/jpeg' ? false : canvasHasAlpha(context, width, height);
      if (alpha) {
        dataUrl = canvas.toDataURL('image/png');
        mediaType = 'image/png';
      } else {
        dataUrl = canvas.toDataURL('image/jpeg', 0.88);
        mediaType = 'image/jpeg';
      }
      const separator = dataUrl.indexOf(',');
      if (separator < 0) throw new Error('image encoding failed');
      const base64 = dataUrl.slice(separator + 1);
      const extension = mediaType === 'image/png' ? 'png' : 'jpg';
      const name = typeof file.name === 'string' && file.name.trim() !== '' ? file.name : 'quickbar-image.' + extension;
      return {
        dataUrl: dataUrl,
        base64: base64,
        mediaType: mediaType,
        width: width,
        height: height,
        name: name,
        bytes: Math.floor(base64.length * 3 / 4),
      };
    }

    /** Map the native popup's SUBMIT images into the v2 prepared-image shape. */
    function mapIncomingImages(rawImages) {
      const mapped = [];
      if (!Array.isArray(rawImages)) return mapped;
      for (const entry of rawImages) {
        if (mapped.length >= MAX_IMAGES) break;
        if (entry === null || typeof entry !== 'object') continue;
        const mediaType = typeof entry.mediaType === 'string' ? entry.mediaType : '';
        if (INCOMING_IMAGE_MEDIA_TYPES.indexOf(mediaType) < 0) continue;
        const base64 = typeof entry.base64 === 'string' ? entry.base64 : '';
        if (base64 === '') continue;
        const extension = mediaType === 'image/jpeg' ? 'jpg' : mediaType === 'image/png' ? 'png' : mediaType === 'image/webp' ? 'webp' : 'gif';
        const name = typeof entry.name === 'string' && entry.name !== '' ? entry.name : 'quickbar-image.' + extension;
        mapped.push({
          mediaType: mediaType,
          base64: base64,
          dataUrl: 'data:' + mediaType + ';base64,' + base64,
          name: name,
          ...(typeof entry.width === 'number' && isFinite(entry.width) && entry.width > 0 ? { width: Math.round(entry.width) } : {}),
          ...(typeof entry.height === 'number' && isFinite(entry.height) && entry.height > 0 ? { height: Math.round(entry.height) } : {}),
          bytes: Math.floor(base64.length * 3 / 4),
          fromNative: true,
        });
      }
      return mapped;
    }

    /** First valid suggested replacement for a conflicted global hotkey. */
    function suggestAlternativeHotkey(currentSpec) {
      const current = typeof currentSpec === 'string' ? currentSpec.trim().toLowerCase() : '';
      for (const candidate of SUGGESTED_HOTKEYS) {
        if (candidate === current) continue;
        if (isValidSpec(candidate)) return candidate;
      }
      return SUGGESTED_HOTKEYS[0];
    }

    // ---------------------------------------------------------------------
    // Store: one observable snapshot consumed through useSyncExternalStore
    // ---------------------------------------------------------------------
    function createQuickbarStore() {
      const listeners = new Set();
      const sessionCounts = new Map();
      let activeSessionId = null;
      let snapshot = {
        open: false,
        focusSeq: 0,
        reason: null,
        busy: false,
        error: null,
        state: null,
        remoteReady: null,
        stateError: null,
        config: Object.assign({}, DEFAULT_CONFIG),
        configWritable: false,
        configStatus: 'loading',
        activeSessionId: null,
        lastTriggerAt: null,
        workspaces: [],
        workspacesStatus: 'loading',
        workspaceId: null,
        catalog: { status: 'idle', groups: [], default: null, error: null },
        modelStatus: 'loading',
        selection: null,
        popover: null,
        fileStatus: 'loading',
        onboarding: null,
        conflict: null,
      };

      function emit() {
        const current = [...listeners];
        for (let index = 0; index < current.length; index += 1) {
          try {
            current[index]();
          } catch (error) {
            console.warn('[quickbar] store listener failed:', error);
          }
        }
      }

      function set(patch) {
        let next = null;
        for (const key of Object.keys(patch)) {
          if (snapshot[key] !== patch[key]) {
            next = next === null ? Object.assign({}, snapshot) : next;
            next[key] = patch[key];
          }
        }
        if (next === null) return;
        snapshot = next;
        emit();
      }

      return {
        subscribe(listener) {
          listeners.add(listener);
          return function () {
            listeners.delete(listener);
          };
        },
        getSnapshot() {
          return snapshot;
        },
        set: set,
        open(reason) {
          if (snapshot.open) {
            set({ focusSeq: snapshot.focusSeq + 1, reason: reason });
            return;
          }
          set({
            open: true,
            focusSeq: snapshot.focusSeq + 1,
            reason: reason,
            error: null,
            busy: false,
            popover: null,
          });
        },
        close() {
          if (!snapshot.open) return;
          set({ open: false, popover: null });
        },
        trackSession(sessionId) {
          if (typeof sessionId !== 'string' || sessionId === '') return function () {};
          sessionCounts.set(sessionId, (sessionCounts.get(sessionId) || 0) + 1);
          activeSessionId = sessionId;
          set({ activeSessionId: sessionId });
          return function () {
            const next = (sessionCounts.get(sessionId) || 0) - 1;
            if (next <= 0) sessionCounts.delete(sessionId);
            else sessionCounts.set(sessionId, next);
            if (activeSessionId !== sessionId) return;
            const remaining = [...sessionCounts.keys()];
            activeSessionId = remaining.length === 0 ? null : remaining[remaining.length - 1];
            set({ activeSessionId: activeSessionId });
          };
        },
      };
    }

    // ---------------------------------------------------------------------
    // Inline icons / spinner (SMIL, no stylesheet injection)
    // ---------------------------------------------------------------------
    function IconSearch() {
      return h('svg', { width: 14, height: 14, viewBox: '0 0 20 20', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('circle', { cx: 9, cy: 9, r: 5.5, stroke: 'currentColor', strokeWidth: 1.6 }),
        h('path', { d: 'M13.4 13.4 17 17', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round' }));
    }

    function IconClose() {
      return h('svg', { width: 14, height: 14, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'm3.5 3.5 9 9m0-9-9 9', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round' }));
    }

    function IconSend() {
      return h('svg', { width: 13, height: 13, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'M2 8 14 2 9 14 7 9 2 8Z', stroke: 'currentColor', strokeWidth: 1.4, strokeLinejoin: 'round' }));
    }

    function Spinner() {
      return h('svg', { width: 13, height: 13, viewBox: '0 0 16 16', 'aria-hidden': true, style: { display: 'block' } },
        h('circle', {
          cx: 8,
          cy: 8,
          r: 6,
          fill: 'none',
          stroke: 'currentColor',
          strokeWidth: 2,
          strokeLinecap: 'round',
          strokeDasharray: '24 12',
        }, h('animateTransform', {
          attributeName: 'transform',
          type: 'rotate',
          from: '0 8 8',
          to: '360 8 8',
          dur: '0.9s',
          repeatCount: 'indefinite',
        })));
    }

    function IconChevron() {
      return h('svg', { width: 10, height: 10, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'm4 6 4 4 4-4', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' }));
    }

    function IconCheck() {
      return h('svg', { width: 12, height: 12, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'm3.5 8.5 3 3 6-6.5', stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round' }));
    }

    function IconPaperclip() {
      return h('svg', { width: 13, height: 13, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'M6.2 9.1 10 5.3a2.2 2.2 0 0 1 3.1 3.1l-4.6 4.6a3.6 3.6 0 0 1-5.1-5.1l4.4-4.4', stroke: 'currentColor', strokeWidth: 1.4, strokeLinecap: 'round' }));
    }

    function IconFile() {
      return h('svg', { width: 12, height: 12, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'M4 2h5l3 3v9H4V2Zm5 0v3h3', stroke: 'currentColor', strokeWidth: 1.4, strokeLinejoin: 'round' }));
    }

    function IconSpark() {
      return h('svg', { width: 13, height: 13, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'M8 1.6 9.7 6.3 14.4 8 9.7 9.7 8 14.4 6.3 9.7 1.6 8 6.3 6.3 8 1.6Z', stroke: 'currentColor', strokeWidth: 1.3, strokeLinejoin: 'round' }));
    }

    function IconAlert() {
      return h('svg', { width: 13, height: 13, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true, style: { display: 'block' } },
        h('path', { d: 'M8 1.8 15 14H1L8 1.8Z', stroke: 'currentColor', strokeWidth: 1.3, strokeLinejoin: 'round' }),
        h('path', { d: 'M8 6v3.4', stroke: 'currentColor', strokeWidth: 1.5, strokeLinecap: 'round' }),
        h('circle', { cx: 8, cy: 11.6, r: 0.9, fill: 'currentColor' }));
    }

    // ---------------------------------------------------------------------
    // Notices (first-run guidance + hotkey conflict) ride the same shell.overlay
    // registration as the quick-ask dialog; no second overlay surface.
    // ---------------------------------------------------------------------
    function renderNoticeCard(options) {
      return h('div', {
        key: options.key,
        'data-quickbar-notice': options.kind,
        role: 'status',
        style: S.noticeCard,
      },
      h('span', {
        style: options.warn === true ? Object.assign({}, S.noticeIcon, S.noticeIconWarn) : S.noticeIcon,
        'aria-hidden': 'true',
      }, options.warn === true ? h(IconAlert) : h(IconSpark)),
      h('div', { style: S.noticeBodyWrap },
        h('div', { style: S.noticeTitle }, options.title),
        h('div', { style: S.noticeText }, options.text),
        h('div', { style: S.noticeActions },
          h('button', {
            type: 'button',
            'data-quickbar-notice-settings': 'true',
            onClick: options.onSettings,
            style: S.noticePrimary,
          }, options.settingsLabel),
          h('button', {
            type: 'button',
            'data-quickbar-notice-dismiss': 'true',
            onClick: options.onDismiss,
            style: S.noticeGhost,
          }, options.dismissLabel))),
      h('button', {
        type: 'button',
        title: options.closeLabel,
        'aria-label': options.closeLabel,
        onClick: options.onDismiss,
        style: S.noticeClose,
      }, h(IconClose)));
    }

    function renderNotices(snap, actions, t) {
      const cards = [];
      if (snap.onboarding !== null && snap.onboarding !== undefined) {
        cards.push(renderNoticeCard({
          key: 'onboarding',
          kind: 'onboarding',
          warn: false,
          title: t('noticeOnboardingTitle'),
          text: t('noticeOnboardingBody', { hotkey: snap.onboarding.hotkey }),
          settingsLabel: t('noticeGoSettings'),
          dismissLabel: t('noticeDismiss'),
          closeLabel: t('noticeClose'),
          onSettings: function () { actions.openSettings(); },
          onDismiss: function () { actions.dismissOnboarding(); },
        }));
      }
      if (snap.conflict !== null && snap.conflict !== undefined) {
        const suggestion = typeof snap.conflict.suggestion === 'string' && snap.conflict.suggestion !== ''
          ? ' ' + t('noticeConflictSuggestion', { hotkey: formatAccel(snap.conflict.suggestion) })
          : '';
        cards.push(renderNoticeCard({
          key: 'conflict',
          kind: 'conflict',
          warn: true,
          title: t('noticeConflictTitle'),
          text: t('noticeConflictBody', { hotkey: snap.conflict.hotkey, message: snap.conflict.message }) + suggestion,
          settingsLabel: t('noticeGoSettings'),
          dismissLabel: t('noticeDismiss'),
          closeLabel: t('noticeClose'),
          onSettings: function () { actions.openSettings(); },
          onDismiss: function () { actions.dismissConflict(); },
        }));
      }
      if (cards.length === 0) return null;
      return h('div', { style: S.noticeWrap, 'data-quickbar-notices': 'true' }, cards);
    }

    // ---------------------------------------------------------------------
    // Overlay components (registered into shell.overlay, rendered only while open)
    // ---------------------------------------------------------------------

    /** Display text for one workspace: its title, or the localized default label. */
    function workspaceLabel(item, t) {
      if (item === null || item === undefined || typeof item !== 'object') return t('overlayWorkspaceDefault');
      const title = typeof item.title === 'string' ? item.title.trim() : '';
      return (title === '' || title === 'default-workspace') ? t('overlayWorkspaceDefault') : title;
    }

    function PopoverSurface(props) {
      return h('div', {
        'data-quickbar-popover': props.kind,
        style: props.right === true ? S.popoverRight : S.popover,
        onKeyDown: function (event) {
          if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            props.onClose();
          }
        },
        onMouseDown: function (event) {
          event.stopPropagation();
        },
      }, props.children);
    }

    function PopoverRow(props) {
      return h('button', {
        type: 'button',
        'data-quickbar-option': props.kind,
        onClick: props.onClick,
        style: props.selected === true ? Object.assign({}, S.popoverOption, S.popoverOptionSelected) : S.popoverOption,
      },
      h('span', { style: S.popoverOptionLabel }, props.label),
      props.detail !== undefined && props.detail !== null && props.detail !== ''
        ? h('span', { style: S.popoverOptionDetail, title: props.detail }, props.detail)
        : null,
      props.selected === true
        ? h('span', { style: S.popoverCheck, 'aria-hidden': 'true' }, h(IconCheck))
        : null);
    }

    function AttachmentChip(props) {
      const label = props.label !== undefined && props.label !== null && props.label !== '' ? props.label : '…';
      return h('span', { style: S.attachmentChip, 'data-quickbar-attachment': props.kind },
        props.thumb !== undefined && props.thumb !== null
          ? h('img', { src: props.thumb, alt: '', style: S.attachmentThumb })
          : h('span', { style: S.attachmentIcon }, h(IconFile)),
        h('span', { style: S.attachmentName, title: props.title !== undefined ? props.title : label }, label),
        h('button', {
          type: 'button',
          title: props.removeLabel,
          'aria-label': props.removeLabel,
          onClick: props.onRemove,
          style: S.attachmentRemove,
        }, h(IconClose)));
    }

    function OverlayHost(props) {
      const store = props.store;
      const actions = props.actions;
      const t = props.t;
      const snap = React.useSyncExternalStore(store.subscribe, store.getSnapshot);
      const [text, setText] = React.useState('');
      const [images, setImages] = React.useState([]);
      const [files, setFiles] = React.useState([]);
      const [focused, setFocused] = React.useState(false);
      const [processing, setProcessing] = React.useState(0);
      const [attachmentError, setAttachmentError] = React.useState(null);
      const taRef = React.useRef(null);
      const fileInputRef = React.useRef(null);
      const wasOpen = React.useRef(false);
      const openedRef = React.useRef(false);
      const restoreRef = React.useRef(null);
      const nextId = React.useRef(1);

      // Focus save/restore across open transitions.
      React.useEffect(function () {
        const open = snap.open;
        if (open && !wasOpen.current) {
          restoreRef.current = typeof document !== 'undefined' ? document.activeElement : null;
        } else if (!open && wasOpen.current) {
          const previous = restoreRef.current;
          restoreRef.current = null;
          if (previous !== null && typeof previous.focus === 'function' && typeof document !== 'undefined' && document.contains(previous)) {
            try {
              previous.focus({ preventScroll: true });
            } catch (error) {
              // focus restore is best effort
            }
          }
        }
        wasOpen.current = open;
      }, [snap.open]);

      // Focus the input when the overlay opens (or is re-triggered while open).
      React.useEffect(function () {
        if (!snap.open) return undefined;
        const element = taRef.current;
        if (element === null) return undefined;
        if (typeof requestAnimationFrame !== 'function') return undefined;
        const handle = requestAnimationFrame(function () {
          try {
            element.focus({ preventScroll: true });
            const length = element.value.length;
            element.setSelectionRange(length, length);
          } catch (error) {
            // focus is best effort
          }
        });
        return function () {
          if (typeof cancelAnimationFrame === 'function') cancelAnimationFrame(handle);
        };
      }, [snap.open, snap.focusSeq]);

      // Grow the textarea up to three lines.
      React.useLayoutEffect(function () {
        const element = taRef.current;
        if (element === null || !snap.open) return;
        element.style.height = 'auto';
        const next = Math.max(26, Math.min(element.scrollHeight, 88));
        element.style.height = next + 'px';
      }, [text, snap.open]);

      // Resolve the remembered workspace / model defaults once per open.
      React.useEffect(function () {
        if (!snap.open) {
          openedRef.current = false;
          return;
        }
        if (openedRef.current) return;
        openedRef.current = true;
        setAttachmentError(null);
        actions.overlayOpened();
      }, [snap.open, actions]);

      // Click outside a popover closes it (the document listener is component-owned).
      React.useEffect(function () {
        if (!snap.open || snap.popover === null) return undefined;
        if (typeof document === 'undefined') return undefined;
        function onDocumentMouseDown(event) {
          const target = event.target;
          if (target !== null && target !== undefined && typeof target.closest === 'function') {
            if (target.closest('[data-quickbar-popover],[data-quickbar-popover-trigger]') !== null) return;
          }
          actions.setPopover(null);
        }
        document.addEventListener('mousedown', onDocumentMouseDown, true);
        return function () {
          document.removeEventListener('mousedown', onDocumentMouseDown, true);
        };
      }, [snap.open, snap.popover, actions]);

      // Drop transient attachment state when the overlay closes.
      React.useEffect(function () {
        if (snap.open) return;
        setProcessing(0);
        setAttachmentError(null);
      }, [snap.open]);

      const notices = renderNotices(snap, actions, t);
      if (!snap.open) return notices;

      const busy = snap.busy === true;
      const hasContent = text.trim() !== '' || images.length > 0 || files.length > 0;
      const canSend = !busy && processing === 0 && hasContent;
      const state = snap.state;
      const hotkeyState = state !== null && typeof state === 'object' ? state : null;
      const badgeSpec = hotkeyState !== null && typeof hotkeyState.hotkey === 'string' && hotkeyState.hotkey !== ''
        ? hotkeyState.hotkey
        : snap.config.hotkey;
      const badge = actions.formatAccel(badgeSpec);
      const workspaces = Array.isArray(snap.workspaces) ? snap.workspaces : [];
      const currentWorkspace = workspaces.find(function (item) { return item.id === snap.workspaceId; }) || null;
      const workspaceText = workspaceLabel(currentWorkspace, t);
      const catalog = snap.catalog !== null && snap.catalog !== undefined && typeof snap.catalog === 'object'
        ? snap.catalog
        : { status: 'idle', groups: [], error: null };
      const groups = Array.isArray(catalog.groups) ? catalog.groups : [];
      const selection = snap.selection;
      const selectedEntry = selection !== null ? findModelEntry(groups, selection.provider, selection.model) : null;
      const selectedModel = selectedEntry !== null ? selectedEntry.model : null;
      const selectedGroup = selectedEntry !== null ? selectedEntry.group : null;
      const modelLabel = selection === null
        ? t('overlayModelDefault')
        : ((selectedGroup !== null && typeof selectedGroup.name === 'string' && selectedGroup.name !== '' ? selectedGroup.name : selection.provider)
          + ' · '
          + (selectedModel !== null && typeof selectedModel.name === 'string' && selectedModel.name !== '' ? selectedModel.name : selection.model)
          + ' · '
          + effortNameFor(t, selectedModel, selection.reasoningEffort));
      const shownError = snap.error !== null && snap.error !== '' ? snap.error : attachmentError;
      const usesWorkspaceTarget = snap.workspacesStatus === 'ready' && workspaces.length > 0;
      const targetHint = usesWorkspaceTarget
        ? t('overlaySendsToWorkspace', { workspace: workspaceText })
        : (snap.activeSessionId === null ? t('overlaySessionNew') : t('overlaySessionCurrent'));

      function send() {
        if (busy || processing > 0) return;
        if (text.trim() === '' && images.length === 0 && files.length === 0) return;
        const payload = {
          images: images.map(function (image) {
            return {
              mediaType: image.mediaType,
              base64: image.base64,
              dataUrl: image.dataUrl,
              name: image.name,
              width: image.width,
              height: image.height,
            };
          }),
          files: files.map(function (entry) { return entry.file; }),
        };
        Promise.resolve(actions.submit(text, payload)).then(function (ok) {
          if (!ok) return;
          setText('');
          setImages([]);
          setFiles([]);
          setAttachmentError(null);
          actions.close();
        }).catch(function (error) {
          console.warn('[quickbar] submit failed outside the guarded path:', error);
        });
      }

      function onTextKeyDown(event) {
        const native = event.nativeEvent;
        if (native !== undefined && native !== null && native.isComposing) return;
        if (event.key === 'Enter' && !event.shiftKey) {
          event.preventDefault();
          event.stopPropagation();
          send();
        }
      }

      function addImageFiles(list) {
        setAttachmentError(null);
        const room = MAX_IMAGES - images.length;
        if (room <= 0) {
          setAttachmentError(t('overlayTooManyImages'));
          return;
        }
        const batch = list.slice(0, room);
        if (list.length > room) setAttachmentError(t('overlayTooManyImages'));
        batch.forEach(function (file) {
          setProcessing(function (count) { return count + 1; });
          function finish() {
            setProcessing(function (count) { return Math.max(0, count - 1); });
          }
          prepareImageAttachment(file).then(function (prepared) {
            setImages(function (previous) {
              if (previous.length >= MAX_IMAGES) return previous;
              const entry = Object.assign({ id: nextId.current }, prepared);
              nextId.current += 1;
              return previous.concat([entry]);
            });
          }, function (error) {
            console.warn('[quickbar] image preparation failed:', error);
            setAttachmentError(t('overlayImageFailed'));
          }).then(finish);
        });
      }

      function onPaste(event) {
        const clipboard = event.clipboardData;
        if (clipboard === null || clipboard === undefined) return;
        const items = clipboard.items;
        if (items === null || items === undefined || typeof items.length !== 'number') return;
        const pasted = [];
        for (let index = 0; index < items.length; index += 1) {
          const item = items[index];
          if (item === null || item === undefined) continue;
          if (item.kind !== 'file') continue;
          if (typeof item.type !== 'string' || item.type.indexOf('image/') !== 0) continue;
          const file = item.getAsFile();
          if (file !== null && file !== undefined) pasted.push(file);
        }
        if (pasted.length === 0) return;
        event.preventDefault();
        addImageFiles(pasted);
      }

      function onFileInputChange(event) {
        const input = event.target;
        const picked = input !== null && input !== undefined && input.files !== null && input.files !== undefined
          ? Array.prototype.slice.call(input.files)
          : [];
        try {
          if (input !== null && input !== undefined) input.value = '';
        } catch (error) {
          // ignore reset failures
        }
        if (picked.length === 0) return;
        setAttachmentError(null);
        const room = MAX_FILES - files.length;
        if (room <= 0) {
          setAttachmentError(t('overlayTooManyFiles'));
          return;
        }
        const batch = picked.slice(0, room);
        if (picked.length > room) setAttachmentError(t('overlayTooManyFiles'));
        setFiles(function (previous) {
          const additions = batch.map(function (file) {
            const entry = {
              id: nextId.current,
              file: file,
              name: typeof file.name === 'string' && file.name !== '' ? file.name : 'file',
            };
            nextId.current += 1;
            return entry;
          });
          return previous.concat(additions);
        });
      }

      function removeImage(id) {
        setAttachmentError(null);
        setImages(function (previous) { return previous.filter(function (image) { return image.id !== id; }); });
      }

      function removeFile(id) {
        setAttachmentError(null);
        setFiles(function (previous) { return previous.filter(function (entry) { return entry.id !== id; }); });
      }

      function openFilePicker() {
        if (snap.fileStatus !== 'ready') return;
        const input = fileInputRef.current;
        if (input === null || input === undefined) return;
        try {
          input.click();
        } catch (error) {
          console.warn('[quickbar] could not open the file picker:', error);
        }
      }

      function renderModelPopover() {
        const children = [];
        if (catalog.status === 'loading' || catalog.status === 'idle') {
          children.push(h('div', { key: 'status', style: S.popoverStatus }, t('overlayCatalogLoading')));
        } else if (catalog.status === 'error') {
          children.push(h('div', { key: 'error', style: S.popoverError },
            h('span', null, t('overlayCatalogError', {
              message: typeof catalog.error === 'string' && catalog.error !== '' ? catalog.error : '?',
            })),
            h('button', {
              type: 'button',
              style: S.popoverRetry,
              onClick: function () { actions.reloadCatalog(); },
            }, t('overlayRetry'))));
        } else {
          let rows = 0;
          for (const group of groups) {
            if (group === null || typeof group !== 'object') continue;
            children.push(h('div', {
              key: 'group:' + String(group.id),
              style: S.popoverGroup,
              title: String(group.id),
            }, typeof group.name === 'string' && group.name !== '' ? group.name : String(group.id)));
            const models = Array.isArray(group.models) ? group.models : [];
            for (const model of models) {
              if (model === null || typeof model !== 'object') continue;
              rows += 1;
              const isSelected = selection !== null && selection.provider === group.id && selection.model === model.id;
              children.push(h(PopoverRow, {
                key: 'model:' + String(group.id) + ':' + String(model.id),
                kind: 'model',
                label: typeof model.name === 'string' && model.name !== '' ? model.name : String(model.id),
                selected: isSelected,
                onClick: function () {
                  actions.chooseModel({ provider: group.id, model: model.id });
                },
              }));
            }
          }
          if (rows === 0) children.push(h('div', { key: 'empty', style: S.popoverStatus }, t('overlayCatalogEmpty')));
          if (selection !== null) {
            const declared = modelDeclaredEfforts(selectedModel);
            const effortChoices = declared.length > 0
              ? declared
              : UNIVERSAL_EFFORTS.map(function (entry) { return { id: entry.id, name: universalEffortName(t, entry.id) }; });
            children.push(h('div', { key: 'efforts', style: S.effortSection },
              h('div', { style: S.effortLabel }, t('overlayEffortLabel')),
              h('div', { style: S.effortChips }, effortChoices.map(function (effort) {
                const isSelected = selection.reasoningEffort === effort.id;
                return h('button', {
                  key: 'effort:' + effort.id,
                  type: 'button',
                  'data-quickbar-effort': effort.id,
                  onClick: function () {
                    actions.chooseModel({
                      provider: selection.provider,
                      model: selection.model,
                      reasoningEffort: effort.id,
                      closePopover: true,
                    });
                  },
                  style: isSelected ? Object.assign({}, S.effortChip, S.effortChipSelected) : S.effortChip,
                }, effort.name);
              }))));
          }
        }
        return h(PopoverSurface, {
          kind: 'model',
          right: true,
          onClose: function () { actions.setPopover(null); },
        }, children);
      }

      const dialog = h('div', {
        'data-quickbar-overlay': 'true',
        style: S.overlay,
        onMouseDown: function (event) {
          if (event.target === event.currentTarget) {
            event.preventDefault();
            actions.close();
          }
        },
        onKeyDown: function (event) {
          if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            actions.close();
          }
        },
      }, h('div', {
        role: 'dialog',
        'aria-modal': 'true',
        'aria-label': t('overlayTitle'),
        'data-quickbar-card': 'true',
        style: focused ? Object.assign({}, S.card, S.cardFocused) : S.card,
      },
      h('div', { style: S.header },
        h('span', { style: S.headerIcon }, h(IconSearch)),
        h('span', { style: S.headerTitle }, t('overlayTitle')),
        h('span', { style: S.headerSpacer }),
        badge !== '' ? h('span', { style: S.hotkeyBadge, 'data-quickbar-badge': 'true' }, badge) : null,
        h('button', {
          type: 'button',
          'data-quickbar-close': 'true',
          title: t('overlayClose'),
          'aria-label': t('overlayClose'),
          onClick: function () { actions.close(); },
          style: S.iconButton,
        }, h(IconClose))),
      h('div', { style: S.toolbar, 'data-quickbar-toolbar': 'true' },
        snap.workspacesStatus === 'ready' && workspaces.length > 0
          ? h('span', { style: S.toolbarItem },
            h('button', {
              type: 'button',
              'data-quickbar-popover-trigger': 'workspace',
              'aria-haspopup': 'listbox',
              'aria-expanded': snap.popover === 'workspace',
              onClick: function () { actions.togglePopover('workspace'); },
              style: S.selectorButton,
            },
            h('span', { style: S.selectorLabel, 'data-quickbar-workspace': 'true' }, workspaceText),
            h('span', { style: S.selectorChevron }, h(IconChevron))),
            snap.popover === 'workspace'
              ? h(PopoverSurface, {
                kind: 'workspace',
                onClose: function () { actions.setPopover(null); },
              }, workspaces.map(function (item) {
                return h(PopoverRow, {
                  key: 'workspace:' + item.id,
                  kind: 'workspace',
                  label: workspaceLabel(item, t),
                  detail: typeof item.path === 'string' && item.path !== '' ? item.path : undefined,
                  selected: item.id === snap.workspaceId,
                  onClick: function () { actions.chooseWorkspace(item.id); },
                });
              }))
              : null)
          : null,
        snap.workspacesStatus === 'unavailable'
          ? h('span', { style: S.toolbarHint }, t('overlayWorkspaceUnavailable'))
          : null,
        snap.modelStatus === 'ready'
          ? h('span', { style: S.toolbarItem },
            h('button', {
              type: 'button',
              'data-quickbar-popover-trigger': 'model',
              'aria-haspopup': 'listbox',
              'aria-expanded': snap.popover === 'model',
              onClick: function () { actions.togglePopover('model'); },
              style: S.selectorButton,
            },
            h('span', { style: S.selectorLabel, 'data-quickbar-model': 'true' }, modelLabel),
            h('span', { style: S.selectorChevron }, h(IconChevron))),
            snap.popover === 'model' ? renderModelPopover() : null)
          : null,
        snap.modelStatus === 'unavailable'
          ? h('span', { style: S.toolbarHint }, t('overlayModelUnavailable'))
          : null,
        h('span', { style: S.toolbarSpacer }),
        h('button', {
          type: 'button',
          'data-quickbar-attach': 'true',
          title: snap.fileStatus === 'unavailable' ? t('overlayFilesUnsupported') : t('overlayAttachFile'),
          'aria-label': t('overlayAttachFile'),
          disabled: snap.fileStatus !== 'ready',
          onClick: openFilePicker,
          style: snap.fileStatus === 'ready' ? S.attachButton : Object.assign({}, S.attachButton, S.controlDisabled),
        }, h(IconPaperclip)),
        h('input', {
          ref: fileInputRef,
          type: 'file',
          multiple: true,
          tabIndex: -1,
          'aria-hidden': 'true',
          onChange: onFileInputChange,
          style: S.hiddenInput,
        })),
      h('div', { style: S.inputWrap },
        text === '' ? h('span', { 'aria-hidden': 'true', style: S.placeholder }, t('overlayPlaceholder')) : null,
        h('textarea', {
          ref: taRef,
          'data-quickbar-input': 'true',
          value: text,
          rows: 1,
          spellCheck: false,
          'aria-label': t('overlayPlaceholder'),
          disabled: busy,
          onFocus: function () { setFocused(true); },
          onBlur: function () { setFocused(false); },
          onChange: function (event) { setText(event.target.value); },
          onKeyDown: onTextKeyDown,
          onPaste: onPaste,
          style: busy
            ? Object.assign({}, S.textarea, { color: C.textTertiary, WebkitTextFillColor: C.textTertiary })
            : S.textarea,
        })),
      images.length > 0 || files.length > 0 || processing > 0 || snap.fileStatus === 'unavailable'
        ? h('div', { style: S.attachmentsRow, 'data-quickbar-attachments': 'true' },
          images.map(function (image) {
            return h(AttachmentChip, {
              key: 'image:' + String(image.id),
              kind: 'image',
              label: image.name,
              title: image.name,
              thumb: image.dataUrl,
              removeLabel: t('overlayRemoveAttachment'),
              onRemove: function () { removeImage(image.id); },
            });
          }),
          files.map(function (entry) {
            return h(AttachmentChip, {
              key: 'file:' + String(entry.id),
              kind: 'file',
              label: entry.name,
              title: entry.name,
              removeLabel: t('overlayRemoveAttachment'),
              onRemove: function () { removeFile(entry.id); },
            });
          }),
          processing > 0 ? h('span', { style: S.attachmentHint }, t('overlayImageProcessing')) : null,
          snap.fileStatus === 'unavailable' ? h('span', { style: S.attachmentHint }, t('overlayFilesUnsupported')) : null)
        : null,
      shownError !== null && shownError !== '' ? h('div', { role: 'alert', 'data-quickbar-error': 'true', style: S.errorRow }, shownError) : null,
      h('div', { style: S.metaRow },
        h('span', { 'data-quickbar-target': 'true', style: S.sessionHint }, targetHint),
        h('span', { style: S.hintGroup },
          h('span', { style: S.hint }, h('span', { style: S.kbd }, 'Enter'), t('overlayHintSend')),
          h('span', { style: S.hint }, h('span', { style: S.kbd }, 'Shift+Enter'), t('overlayHintNewline')),
          h('span', { style: S.hint }, h('span', { style: S.kbd }, 'Esc'), t('overlayHintClose')),
          h('span', { style: S.hint }, h('span', { style: S.kbd }, '⌘V'), t('overlayHintPaste')))),
      h('div', { style: S.footer },
        h('button', {
          type: 'button',
          'data-quickbar-send': 'true',
          disabled: !canSend,
          onClick: send,
          style: canSend ? S.button : Object.assign({}, S.button, S.buttonDisabled),
        }, busy ? h(Spinner) : h(IconSend), busy ? t('overlaySending') : t('overlaySend')))));
      return h(React.Fragment, null, notices, dialog);
    }

    // ---------------------------------------------------------------------
    // Settings page (registered into settings.section)
    // ---------------------------------------------------------------------
    /** One button primitive with the DESIGN.md state set: default/hover/focus/disabled/loading. */
    function UiButton(props) {
      const [hover, setHover] = React.useState(false);
      const [focus, setFocus] = React.useState(false);
      const disabled = props.disabled === true;
      const variant = props.variant === 'primary' ? 'primary' : 'secondary';
      let style = variant === 'primary' ? Object.assign({}, S.button) : Object.assign({}, S.secondaryButton);
      if (!disabled && hover === true) style = Object.assign({}, style, variant === 'primary' ? S.buttonHover : S.secondaryHover);
      if (!disabled && focus === true) style = Object.assign({}, style, variant === 'primary' ? S.buttonFocus : S.secondaryFocus);
      if (disabled) style = Object.assign({}, style, S.controlDisabled);
      const attrs = Object.assign({}, props.attrs || {}, {
        'data-quickbar-button': variant,
        type: 'button',
        disabled: disabled,
        style: style,
      });
      const children = props.loading === true && typeof props.loadingLabel === 'string' ? props.loadingLabel : props.children;
      return h('button', Object.assign({}, attrs, {
        onClick: disabled ? undefined : props.onClick,
        onMouseEnter: function () { setHover(true); },
        onMouseLeave: function () { setHover(false); },
        onFocus: function () { setFocus(true); },
        onBlur: function () { setFocus(false); },
        title: props.title,
      }), props.loading === true ? h(Spinner) : null, children);
    }

    function Toggle(props) {
      const checked = props.checked === true;
      const disabled = props.disabled === true;
      const [hover, setHover] = React.useState(false);
      const [focus, setFocus] = React.useState(false);
      let style = Object.assign({}, S.switchTrack, checked ? S.switchTrackOn : S.switchTrackOff);
      if (!disabled && hover === true) style = Object.assign({}, style, { opacity: 0.9 });
      if (!disabled && focus === true) style = Object.assign({}, style, { boxShadow: '0 0 0 2px ' + C.focus });
      if (disabled) style = Object.assign({}, style, S.controlDisabled);
      return h('button', {
        type: 'button',
        role: 'switch',
        'aria-checked': checked,
        'aria-label': props.label,
        disabled: disabled,
        onClick: function () {
          if (disabled) return;
          props.onChange(!checked);
        },
        onMouseEnter: function () { setHover(true); },
        onMouseLeave: function () { setHover(false); },
        onFocus: function () { setFocus(true); },
        onBlur: function () { setFocus(false); },
        style: style,
      }, h('span', { style: checked ? Object.assign({}, S.switchThumb, S.switchThumbOn) : S.switchThumb }));
    }

    function AccelRecorder(props) {
      const t = props.t;
      const [recording, setRecording] = React.useState(false);
      const [hint, setHint] = React.useState(null);
      const [hover, setHover] = React.useState(false);
      const [focus, setFocus] = React.useState(false);
      const ref = React.useRef(null);
      const disabled = props.disabled === true;
      const value = typeof props.value === 'string' ? props.value : '';

      React.useEffect(function () {
        if (!recording) return;
        const element = ref.current;
        if (element === null) return;
        try {
          element.focus({ preventScroll: true });
        } catch (error) {
          // focus is best effort
        }
      }, [recording]);

      function stop() {
        setRecording(false);
        setHint(null);
      }

      function onKeyDown(event) {
        if (!recording) return;
        event.preventDefault();
        event.stopPropagation();
        if (event.key === 'Escape') {
          stop();
          return;
        }
        if (event.key === 'Meta' || event.key === 'Shift' || event.key === 'Alt' || event.key === 'Control') return;
        if (!(event.metaKey || event.altKey || event.ctrlKey)) {
          setHint(t('hotkeyNeedsModifier'));
          return;
        }
        const spec = props.eventToSpec(event);
        if (spec === null) {
          setHint(t('hotkeyUnsupported'));
          return;
        }
        stop();
        props.onCapture(spec);
      }

      const display = recording
        ? t('hotkeyRecording')
        : (value !== '' && isValidSpec(value) ? formatAccel(value) : (value !== '' ? value : t('hotkeyEmpty')));

      return h('div', { style: S.field },
        h('button', {
          ref: ref,
          type: 'button',
          'data-quickbar-hotkey-recorder': props.field,
          disabled: disabled,
          onClick: function () {
            if (disabled) return;
            if (recording) stop();
            else {
              setHint(null);
              setRecording(true);
            }
          },
          onKeyDown: onKeyDown,
          onBlur: function () {
            setFocus(false);
            if (recording) stop();
          },
          onFocus: function () { setFocus(true); },
          onMouseEnter: function () { setHover(true); },
          onMouseLeave: function () { setHover(false); },
          style: Object.assign(
            {},
            S.recorder,
            recording ? S.recorderActive : null,
            !disabled && hover === true && !recording ? { border: '1px solid ' + C.borderL3 } : null,
            !disabled && focus === true && !recording ? { boxShadow: '0 0 0 2px ' + C.focus } : null,
            disabled ? S.controlDisabled : null,
          ),
        },
        h('span', { style: recording ? S.recorderPlaceholder : S.recorderValue }, display),
        recording ? h('span', { style: S.recorderHint }, t('hotkeyCancelHint')) : null),
        hint !== null ? h('span', { style: S.fieldError }, hint) : null,
        props.allowClear === true && value !== '' && !recording
          ? h('button', {
            type: 'button',
            disabled: disabled,
            onClick: function () {
              stop();
              props.onCapture('');
            },
            style: Object.assign({}, S.linkButton, disabled ? S.controlDisabled : null),
          }, t('clear'))
          : null);
    }

    function SettingsSection(props) {
      const store = props.store;
      const actions = props.actions;
      const t = props.t;
      const snap = React.useSyncExternalStore(store.subscribe, store.getSnapshot);
      const [notice, setNotice] = React.useState(null);
      const [testing, setTesting] = React.useState(false);
      const [registering, setRegistering] = React.useState(false);
      const closeSettings = typeof props.close === 'function' ? props.close : null;

      const cfg = snap.config;
      const unavailable = snap.configStatus === 'unavailable';
      const readOnly = snap.configWritable !== true;
      const controlsDisabled = unavailable || readOnly;
      const state = snap.state;
      const stateInfo = describeState(snap, t);
      const conflictActive = stateInfo.code === 'error';
      const currentSpec = state !== null && state !== undefined && typeof state.hotkey === 'string' && state.hotkey !== ''
        ? state.hotkey
        : cfg.hotkey;
      const suggestion = conflictActive ? actions.suggestAlternativeHotkey(currentSpec) : null;

      function write(field, value) {
        if (controlsDisabled) return Promise.resolve({ ok: false, message: t('readOnly') });
        setNotice(null);
        return Promise.resolve(actions.write(field, value)).then(function (result) {
          if (result !== null && result !== undefined && result.ok === false) setNotice({ kind: 'error', text: result.message });
          return result;
        }).catch(function (error) {
          console.warn('[quickbar] config write failed outside the guarded path:', error);
          setNotice({ kind: 'error', text: t('writeRejected') });
          return { ok: false };
        });
      }

      function applySuggestion(spec) {
        if (typeof spec !== 'string' || spec === '') return;
        write('hotkey', spec).then(function (result) {
          if (result !== null && result !== undefined && result.ok === true) {
            setNotice({ kind: 'info', text: t('settingsSuggestionApplied', { hotkey: formatAccel(spec) }) });
          }
        });
      }

      function runTest() {
        if (testing) return;
        setNotice(null);
        setTesting(true);
        Promise.resolve(actions.test(closeSettings)).then(function (failure) {
          setTesting(false);
          if (typeof failure === 'string' && failure !== '') setNotice({ kind: 'error', text: t('testFailed', { message: failure }) });
        }).catch(function (error) {
          setTesting(false);
          setNotice({ kind: 'error', text: t('testFailed', { message: errorText(error) }) });
        });
      }

      function runReregister() {
        if (registering) return;
        setNotice(null);
        setRegistering(true);
        write('hotkey', cfg.hotkey).then(function (result) {
          setRegistering(false);
          if (result !== null && result !== undefined && result.ok === false) {
            setNotice({ kind: 'error', text: t('settingsReRegisterFailed', { message: typeof result.message === 'string' ? result.message : '' }) });
            return;
          }
          setNotice({ kind: 'info', text: t('settingsReRegistered') });
        }).catch(function (error) {
          setRegistering(false);
          setNotice({ kind: 'error', text: t('settingsReRegisterFailed', { message: errorText(error) }) });
        });
      }

      const rows = [];

      if (unavailable) rows.push(h('div', { key: 'unavailable', style: S.noticeWarn }, t('unavailable')));
      else if (snap.configStatus === 'loading') rows.push(h('div', { key: 'loading', style: S.notice }, t('configLoading')));
      else if (readOnly) rows.push(h('div', { key: 'readonly', style: S.notice }, t('readOnly')));

      // Conflict is shown clearly, with one suggested alternative and a one-click apply.
      if (conflictActive) {
        rows.push(h('div', { key: 'conflict', style: S.conflictCard, 'data-quickbar-conflict': 'true' },
          h('div', { style: S.conflictTitle }, t('settingsConflictTitle')),
          stateInfo.detail !== null
            ? h('div', { style: S.conflictText, 'data-quickbar-conflict-reason': 'true' }, stateInfo.detail)
            : null,
          h('div', { style: S.conflictHint }, t('settingsConflictHint')),
          suggestion !== null
            ? h('div', { style: S.suggestionRow },
              h('span', { style: S.suggestionCode, 'data-quickbar-suggestion': suggestion }, t('settingsSuggestion', { hotkey: formatAccel(suggestion) })),
              h(UiButton, {
                variant: 'secondary',
                disabled: controlsDisabled,
                attrs: { 'data-quickbar-use-suggestion': 'true' },
                onClick: function () { applySuggestion(suggestion); },
              }, t('settingsUseSuggestion')))
            : null));
      }

      rows.push(h('div', { key: 'behavior', style: S.settingsCard },
        h('div', { style: S.cardTitle }, t('sectionBehavior')),
        h('div', { style: S.row },
          h('div', { style: S.rowText },
            h('span', { style: S.rowLabel }, t('enableLabel')),
            h('span', { style: S.rowHint }, t('enableHint'))),
          h(Toggle, {
            checked: cfg.enabled === true,
            disabled: controlsDisabled,
            label: t('enableLabel'),
            onChange: function (next) { write('enabled', next); },
          })),
        h('div', { style: S.row },
          h('div', { style: S.rowText },
            h('span', { style: S.rowLabel }, t('raiseLabel')),
            h('span', { style: S.rowHint }, t('raiseHint'))),
          h(Toggle, {
            checked: cfg.raiseWindow === true,
            disabled: controlsDisabled,
            label: t('raiseLabel'),
            onChange: function (next) { write('raiseWindow', next); },
          }))));

      rows.push(h('div', { key: 'shortcuts', style: S.settingsCard },
        h('div', { style: S.cardTitle }, t('sectionShortcuts')),
        h('div', { style: S.row },
          h('div', { style: S.rowText },
            h('span', { style: S.rowLabel }, t('sectionHotkey')),
            h('span', { style: S.rowHint }, t('hotkeyHint'))),
          h(AccelRecorder, {
            field: 'hotkey',
            t: t,
            value: cfg.hotkey,
            disabled: controlsDisabled,
            eventToSpec: eventToSpec,
            allowClear: false,
            onCapture: function (spec) { write('hotkey', spec); },
          })),
        h('div', { style: S.row },
          h('div', { style: S.rowText },
            h('span', { style: S.rowLabel }, t('inAppLabel')),
            h('span', { style: S.rowHint }, t('inAppHint'))),
          h(AccelRecorder, {
            field: 'inAppShortcut',
            t: t,
            value: cfg.inAppShortcut,
            disabled: controlsDisabled,
            eventToSpec: eventToSpec,
            allowClear: true,
            onCapture: function (spec) { write('inAppShortcut', spec); },
          }))));

      rows.push(h('div', { key: 'status', style: S.settingsCard },
        h('div', { style: S.cardTitle }, t('sectionStatus')),
        h('div', { style: S.statusRow, 'data-quickbar-status': stateInfo.code },
          h('span', { style: Object.assign({}, S.statusDot, { background: stateInfo.color }) }),
          h('span', { style: S.statusLabel }, stateInfo.label)),
        stateInfo.detail !== null ? h('div', { style: S.statusDetail, 'data-quickbar-status-detail': 'true' }, stateInfo.detail) : null,
        stateInfo.hotkeyLine !== null ? h('div', { style: S.statusDetail }, stateInfo.hotkeyLine) : null,
        h('div', { style: S.statusDetail }, t('statusAppliedHint')),
        // Compact re-register / test affordance, one accent (primary = test).
        h('div', { style: S.testRow },
          h(UiButton, {
            variant: 'primary',
            loading: testing,
            loadingLabel: t('testing'),
            disabled: testing,
            attrs: { 'data-quickbar-test': 'true' },
            onClick: runTest,
          }, t('test')),
          h(UiButton, {
            variant: 'secondary',
            loading: registering,
            loadingLabel: t('settingsReRegistering'),
            disabled: controlsDisabled || registering,
            attrs: { 'data-quickbar-reregister': 'true' },
            onClick: runReregister,
          }, t('settingsReRegister')),
          h('span', { style: S.rowHint }, t('testHint'))),
        notice !== null ? h('div', {
          role: 'status',
          'data-quickbar-notice': notice.kind,
          style: notice.kind === 'error' ? S.noticeError : S.notice,
        }, notice.text) : null));

      return h('div', { 'data-quickbar-settings': 'true', style: S.settingsRoot },
        h('div', { style: S.settingsHeader },
          h('h2', { style: S.settingsTitle }, t('title')),
          h('p', { style: S.settingsDesc }, t('description'))),
        rows);
    }

    function describeState(snap, t) {
      if (snap.remoteReady === false && (snap.state === null || snap.state === undefined)) {
        return {
          code: 'unavailable',
          label: t('statusRemoteUnavailable'),
          color: C.danger,
          detail: snap.stateError !== null && snap.stateError !== undefined ? snap.stateError : null,
          hotkeyLine: null,
        };
      }
      const state = snap.state;
      if (state === null || state === undefined || typeof state !== 'object') {
        return { code: 'unknown', label: t('statusUnknown'), color: C.textTertiary, detail: null, hotkeyLine: null };
      }
      const hotkeyLine = typeof state.hotkey === 'string' && state.hotkey !== ''
        ? t('statusHotkeyLine', { hotkey: formatAccel(state.hotkey) })
        : null;
      if (state.hotkeyState === 'ready') {
        const pid = typeof state.helperPid === 'number' ? state.helperPid : null;
        return {
          code: 'ready',
          label: t('statusReady'),
          color: C.success,
          detail: pid === null ? null : t('statusHelperPid', { pid: pid }),
          hotkeyLine: hotkeyLine,
        };
      }
      if (state.hotkeyState === 'starting') {
        return { code: 'starting', label: t('statusStarting'), color: C.warn, detail: null, hotkeyLine: hotkeyLine };
      }
      if (state.hotkeyState === 'error') {
        return {
          code: 'error',
          label: t('statusError'),
          color: C.danger,
          detail: typeof state.hotkeyError === 'string' && state.hotkeyError !== '' ? state.hotkeyError : null,
          hotkeyLine: hotkeyLine,
        };
      }
      if (state.hotkeyState === 'disabled') {
        return { code: 'disabled', label: t('statusDisabled'), color: C.textTertiary, detail: null, hotkeyLine: hotkeyLine };
      }
      return { code: 'unknown', label: t('statusUnknown'), color: C.textTertiary, detail: null, hotkeyLine: hotkeyLine };
    }

    // ---------------------------------------------------------------------
    // Session probe: records the sessionId of the mounted composer dock
    // (session-scoped slot whose standardProps include `sessionId`).
    // ---------------------------------------------------------------------
    function SessionProbe(props) {
      const store = props.store;
      const sessionId = props.sessionId;
      React.useEffect(function () {
        if (typeof sessionId !== 'string' || sessionId === '') return undefined;
        return store.trackSession(sessionId);
      }, [store, sessionId]);
      return null;
    }

    // ---------------------------------------------------------------------
    // Plugin apply
    // ---------------------------------------------------------------------
    function apply(ctx) {
      const t = ctx.locale.bind(NS);
      const store = createQuickbarStore();
      const env = {
        ctx: ctx,
        t: t,
        cfg: Object.assign({}, DEFAULT_CONFIG),
        form: null,
        sessions: null,
        uiWorkspace: null,
        remoteCtx: null,
        api: null,
        mountPromise: null,
        mountError: null,
        workspacesSvc: null,
        remoteSession: null,
        modelDirectories: null,
        fileUpload: null,
        catalog: { status: 'idle', groups: [], default: null, error: null },
        catalogPromise: null,
        catalogGeneration: 0,
        defaultsGeneration: 0,
        disposed: false,
        lastSubmittedSessionId: null,
        scrollRaf: null,
        scrollToken: 0,
        onboardingShown: false,
        conflictSeen: new Set(),
        settingsOpening: false,
      };
      /** Timers owned by this plugin lifetime (cancelled on teardown). */
      const ownedTimeouts = new Set();
      function ownedTimeout(callback, delayMs) {
        const id = setTimeout(function () {
          ownedTimeouts.delete(id);
          if (!env.disposed) callback();
        }, delayMs);
        ownedTimeouts.add(id);
        return id;
      }
      const seenNonces = new Set();
      /** Nonces of native-popup `submit` events already accepted (separate stream of ids). */
      const seenSubmitNonces = new Set();
      /** In-page guard: one native text is queued at most once even without localStorage. */
      const queuedExternalSubmits = new Set();
      /** Serializes native-popup sends so two triggers can never interleave prompts. */
      let externalSubmitQueue = Promise.resolve();
      /** The watch stream's opening state is the fallback resume point when getState() failed. */
      let submitResumeChecked = false;

      // Locale dictionaries are registered on this plugin's context.
      ctx.effect(function () {
        return ctx.locale.register(NS, { zh: ZH, en: EN });
      }, 'quickbar: locale dictionaries');

      // Native-popup submits and notice/scroll work must stop once the plugin unloads.
      ctx.effect(function () {
        return function () {
          env.disposed = true;
          for (const id of ownedTimeouts) clearTimeout(id);
          ownedTimeouts.clear();
          if (env.scrollRaf !== null && typeof cancelAnimationFrame === 'function') {
            try {
              cancelAnimationFrame(env.scrollRaf);
            } catch (error) {
              // ignore
            }
            env.scrollRaf = null;
          }
        };
      }, 'quickbar: external submit teardown');

      // A profile without the settings service never resolves the form: report that honestly.
      ctx.effect(function () {
        const timer = setTimeout(function () {
          if (store.getSnapshot().configStatus === 'loading') {
            store.set({ configStatus: 'unavailable', configWritable: false });
          }
        }, 4000);
        return function () {
          clearTimeout(timer);
        };
      }, 'quickbar: config availability watchdog');

      ctx.effect(function () {
        const timer = setTimeout(function () {
          if (env.remoteCtx === null) {
            store.set({ remoteReady: false, stateError: t('statusRemoteUnavailable') });
          }
        }, 5000);
        return function () {
          clearTimeout(timer);
        };
      }, 'quickbar: remote availability watchdog');

      // Optional services that never appear keep their pickers hidden/disabled honestly.
      ctx.effect(function () {
        const timer = setTimeout(function () {
          const snapshot = store.getSnapshot();
          const patch = {};
          if (snapshot.workspacesStatus === 'loading') patch.workspacesStatus = 'unavailable';
          if (snapshot.modelStatus === 'loading') patch.modelStatus = 'unavailable';
          if (snapshot.fileStatus === 'loading') patch.fileStatus = 'unavailable';
          if (Object.keys(patch).length > 0) store.set(patch);
        }, PICKER_AVAILABILITY_TIMEOUT_MS);
        return function () {
          clearTimeout(timer);
        };
      }, 'quickbar: picker availability watchdog');

      // ---------------------------------------------------------------- store input
      function applyState(state) {
        if (state === null || typeof state !== 'object') return;
        if (typeof state.hotkeyState !== 'string') return;
        store.set({ state: state, remoteReady: true, stateError: null });
        maybeShowNotices(state);
        // The host echoes its last trigger in every state; a reconnect can deliver a
        // toggle this client never saw (dedupe by nonce keeps the normal path single).
        maybeResumePending(state);
      }

      /**
       * A body-portaled Harness modal (settings, feedback, onboarding) lives above
       * the frame's `shell.overlay` layer; the overlay could never be seen or focused
       * underneath it, so a trigger that lands on a modal is consumed silently instead
       * of opening a hidden dialog. `data-quickbar-card` excludes our own dialog.
       */
      function hasHostModal() {
        if (typeof document === 'undefined') return false;
        try {
          if (document.querySelector('[data-shortcut-modal]') !== null) return true;
          return document.querySelector('[role="dialog"][aria-modal="true"]:not([data-quickbar-card])') !== null;
        } catch (error) {
          return false;
        }
      }

      // ---------------------------------------------------------------- notices / settings bridge
      function maybeShowNotices(state) {
        if (state === null || typeof state !== 'object') return;
        // First run: one dismissible guidance card per install.
        if (!env.onboardingShown) {
          env.onboardingShown = true;
          const onboarded = readStoredJson(LS_ONBOARDED_KEY);
          if (onboarded === null || onboarded === undefined) {
            const spec = typeof state.hotkey === 'string' && state.hotkey !== '' ? state.hotkey : env.cfg.hotkey;
            store.set({ onboarding: { hotkey: formatAccel(spec) } });
          }
        }
        // Hotkey conflict: one visible card per distinct error, never per status event.
        if (state.hotkeyState !== 'error') return;
        const message = typeof state.hotkeyError === 'string' && state.hotkeyError !== '' ? state.hotkeyError : t('statusError');
        if (env.conflictSeen.has(message)) return;
        const stored = readStoredJson(LS_CONFLICT_KEY);
        const dismissed = stored !== null && stored !== undefined && Array.isArray(stored.signatures) ? stored.signatures : [];
        env.conflictSeen.add(message);
        if (dismissed.indexOf(message) >= 0) return;
        const spec = typeof state.hotkey === 'string' && state.hotkey !== '' ? state.hotkey : env.cfg.hotkey;
        store.set({
          conflict: {
            message: message,
            hotkey: formatAccel(spec),
            signature: message,
            suggestion: suggestAlternativeHotkey(spec),
          },
        });
      }

      function dismissOnboarding() {
        writeStoredJson(LS_ONBOARDED_KEY, { at: Date.now() });
        store.set({ onboarding: null });
      }

      function dismissConflict() {
        const conflict = store.getSnapshot().conflict;
        if (conflict !== null && conflict !== undefined && typeof conflict.signature === 'string') {
          const stored = readStoredJson(LS_CONFLICT_KEY);
          const signatures = stored !== null && stored !== undefined && Array.isArray(stored.signatures) ? stored.signatures.slice() : [];
          if (signatures.indexOf(conflict.signature) < 0) signatures.push(conflict.signature);
          writeStoredJson(LS_CONFLICT_KEY, { signatures: signatures.slice(-10), at: Date.now() });
        }
        store.set({ conflict: null });
      }

      /** The shell's own trigger label ("trigger" in the `settings` namespace), when present. */
      function settingsTriggerLabel() {
        try {
          const bind = ctx.locale.bind('settings');
          const label = bind('trigger');
          return typeof label === 'string' && label !== '' && label !== 'trigger' ? label : null;
        } catch (error) {
          return null;
        }
      }

      function findSettingsTrigger() {
        if (typeof document === 'undefined') return null;
        try {
          const label = settingsTriggerLabel();
          const nodes = document.querySelectorAll('button[aria-haspopup="dialog"]');
          for (const node of nodes) {
            const aria = node.getAttribute('aria-label') || '';
            const text = (node.textContent || '').trim();
            if (label !== null && (aria === label || text === label)) return node;
            if (aria === '设置' || aria === 'Settings' || text === '设置' || text === 'Settings') return node;
          }
        } catch (error) {
          return null;
        }
        return null;
      }

      function selectQuickbarSection(attempt) {
        if (env.disposed) return;
        try {
          const label = t('nav');
          const dialogs = document.querySelectorAll('[data-shortcut-modal], [role="dialog"]');
          for (const dialog of dialogs) {
            const buttons = dialog.querySelectorAll('button, [role="tab"], [role="button"]');
            for (const node of buttons) {
              if ((node.textContent || '').trim() === label) {
                node.click();
                return;
              }
            }
          }
        } catch (error) {
          // fall through to retry
        }
        if (attempt < 6) ownedTimeout(function () { selectQuickbarSection(attempt + 1); }, 120);
      }

      /**
       * Best-effort "去设置": open the shell-owned settings dialog (clicking its trigger,
       * or dispatching the product Settings shortcut) and then select 快捷唤起. The shell
       * exposes no programmatic navigation API, so every step is guarded and optional.
       */
      function openSettings() {
        if (env.disposed || env.settingsOpening) return;
        env.settingsOpening = true;
        ownedTimeout(function () { env.settingsOpening = false; }, 800);
        try {
          if (typeof document === 'undefined') return;
          if (document.querySelector('[data-shortcut-modal]') !== null) {
            selectQuickbarSection(0);
            return;
          }
          const trigger = findSettingsTrigger();
          if (trigger !== null) {
            trigger.click();
            selectQuickbarSection(0);
            return;
          }
          const state = store.getSnapshot().state;
          const isMac = (state !== null && state !== undefined && state.platform === 'darwin')
            || (typeof navigator !== 'undefined' && /Mac/iu.test(navigator.platform || ''));
          if (typeof window === 'undefined' || typeof KeyboardEvent !== 'function') return;
          window.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Comma',
            code: 'Comma',
            keyCode: 188,
            which: 188,
            metaKey: isMac,
            ctrlKey: !isMac,
            bubbles: true,
            cancelable: true,
            composed: true,
          }));
          selectQuickbarSection(0);
        } catch (error) {
          console.warn('[quickbar] opening settings failed:', error);
        }
      }

      // ---------------------------------------------------------------- remote: ack / raise
      function callQuickbarRemote(method, args) {
        return Promise.resolve(ensureApi()).then(function (api) {
          if (api === null || api === undefined || typeof api[method] !== 'function') return null;
          return Promise.resolve(api[method].apply(api, args));
        }).catch(function (error) {
          console.warn('[quickbar] remote ' + method + ' failed:', error);
          return null;
        });
      }

      /** Tell the native panel whether the submit was accepted (ok closes it, message shows inline). */
      function reportSubmitResultSafe(ok, message) {
        const accepted = ok === true;
        // Two declared parameters: pass `undefined` for an absent message so the wire keeps one field.
        const args = [accepted, typeof message === 'string' && message !== '' ? message : undefined];
        return callQuickbarRemote('reportSubmitResult', args).then(function (result) {
          if (result !== null && result !== undefined && result.ok === false) {
            console.debug('[quickbar] reportSubmitResult rejected:', remoteFailureText(result));
          }
        });
      }

      /** Send-then-raise: the Host only raises when the client asks (best effort). */
      function raiseWindowSafe() {
        return callQuickbarRemote('raiseWindow', []).then(function (result) {
          if (result !== null && result !== undefined && result.ok === false) {
            console.debug('[quickbar] raiseWindow rejected:', remoteFailureText(result));
          }
        });
      }

      // ---------------------------------------------------------------- auto-scroll
      function scrollConversationToBottom(sessionId) {
        try {
          if (typeof document === 'undefined') return false;
          let container = null;
          if (typeof sessionId === 'string' && sessionId !== '') {
            let scope = null;
            try {
              scope = document.querySelector('[data-conversation-session="' + sessionId.replace(/["\\]/gu, '\\$&') + '"]');
            } catch (error) {
              scope = null;
            }
            if (scope !== null && scope !== undefined) container = scope.querySelector('[data-conversation-scroll]');
          }
          if (container === null || container === undefined) {
            const all = document.querySelectorAll('[data-conversation-scroll]');
            container = all.length === 1 ? all[0] : null;
          }
          if (container === null || container === undefined) container = document.querySelector('[data-conversation-content]');
          if (container === null || container === undefined) return false;
          const height = typeof container.scrollHeight === 'number' ? container.scrollHeight : 0;
          if (height <= 0) return false;
          container.scrollTop = height;
          return true;
        } catch (error) {
          return false;
        }
      }

      /** Scroll after navigation settles: retry a few frames, never throw, never leak. */
      function scheduleConversationScroll(sessionId) {
        try {
          if (env.disposed || typeof document === 'undefined' || typeof requestAnimationFrame !== 'function') return;
          if (env.scrollRaf !== null && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(env.scrollRaf);
          env.scrollToken += 1;
          const token = env.scrollToken;
          const deadline = Date.now() + 3000;
          function step() {
            if (env.disposed || token !== env.scrollToken) {
              env.scrollRaf = null;
              return;
            }
            if (scrollConversationToBottom(sessionId) || Date.now() >= deadline) {
              env.scrollRaf = null;
              return;
            }
            env.scrollRaf = requestAnimationFrame(step);
          }
          env.scrollRaf = requestAnimationFrame(step);
        } catch (error) {
          env.scrollRaf = null;
        }
      }

      function maybeResumePending(state) {
        if (state === null || typeof state !== 'object') return;
        const pending = state.pendingToggle;
        if (pending === null || typeof pending !== 'object') return;
        if (typeof pending.nonce !== 'number' || typeof pending.at !== 'number') return;
        if (Date.now() - pending.at >= PENDING_TOGGLE_TTL_MS) return;
        if (seenNonces.has(pending.nonce)) return;
        seenNonces.add(pending.nonce);
        if (hasHostModal()) {
          console.debug('[quickbar] pending toggle consumed while a Harness modal is open');
          return;
        }
        store.open('pending');
      }

      function handleToggle(event) {
        if (typeof event.nonce !== 'number') return;
        if (seenNonces.has(event.nonce)) return;
        seenNonces.add(event.nonce);
        if (seenNonces.size > 200) seenNonces.clear();
        if (typeof event.at === 'number') store.set({ lastTriggerAt: event.at });
        if (hasHostModal()) {
          console.debug('[quickbar] toggle consumed while a Harness modal is open');
          return;
        }
        store.open('hotkey');
      }

      function handleStreamItem(item) {
        if (item === null || typeof item !== 'object') return;
        if (item.type === 'toggle') {
          handleToggle(item);
          return;
        }
        if (item.type === 'submit') {
          handleSubmitEvent(item);
          return;
        }
        if (item.type === 'status' && item.state !== null && typeof item.state === 'object') {
          applyState(item.state);
          return;
        }
        // The host's watch generator opens with the current QuickbarState. This first
        // raw state is also the fallback pendingSubmit resume point (only once per mount;
        // later generations must not replay a stale pendingSubmit).
        applyState(item);
        if (!submitResumeChecked) {
          submitResumeChecked = true;
          maybeResumePendingSubmit(item);
        }
      }

      // ---------------------------------------------------------------- config
      function readConfig(snap) {
        const value = snap !== null && snap !== undefined && isPlainObject(snap.value) ? snap.value : {};
        const hotkeyRaw = typeof value.hotkey === 'string' ? value.hotkey.trim() : '';
        const hotkey = hotkeyRaw !== '' ? hotkeyRaw : DEFAULT_CONFIG.hotkey;
        let inApp = DEFAULT_CONFIG.inAppShortcut;
        if (typeof value.inAppShortcut === 'string') {
          const trimmed = value.inAppShortcut.trim();
          inApp = trimmed !== '' && isValidSpec(trimmed) ? trimmed : '';
        }
        return {
          enabled: value.enabled !== false,
          hotkey: hotkey,
          raiseWindow: value.raiseWindow !== false,
          inAppShortcut: inApp,
          // Client-side only; the Host Config does not declare it. It is read forward-compatibly
          // in case a future profile supplies the field on the settings namespace.
          rememberWindowMs: typeof value.rememberWindowMs === 'number' && value.rememberWindowMs >= 0
            ? value.rememberWindowMs
            : DEFAULT_REMEMBER_WINDOW_MS,
        };
      }

      function setupConfig(child) {
        let form = null;
        try {
          form = child.configForms.get(ENTRY_ID);
        } catch (error) {
          console.warn('[quickbar] config form lookup failed:', error);
        }
        env.form = form;
        if (form === null) {
          store.set({ configStatus: 'unavailable', configWritable: false });
          return;
        }
        function sync() {
          try {
            const snap = form.getSnapshot();
            const cfg = readConfig(snap);
            env.cfg = cfg;
            store.set({
              config: cfg,
              configWritable: snap !== null && snap !== undefined && snap.writable === true,
              configStatus: snap !== null && snap !== undefined && typeof snap.status === 'string' ? snap.status : 'loading',
            });
          } catch (error) {
            console.warn('[quickbar] reading configuration failed:', error);
          }
        }
        try {
          child.effect(function () {
            return form.subscribe(sync);
          }, 'quickbar: configuration subscription');
        } catch (error) {
          console.warn('[quickbar] subscribing to configuration failed:', error);
        }
        sync();
      }

      function writeConfig(field, value) {
        const form = env.form;
        if (form === null) return Promise.resolve({ ok: false, message: t('unavailable') });
        let snap = null;
        try {
          snap = form.getSnapshot();
        } catch (error) {
          snap = null;
        }
        if (snap === null || snap === undefined || snap.writable !== true) {
          return Promise.resolve({ ok: false, message: t('readOnly') });
        }
        return Promise.resolve()
          .then(function () { return form.set(field, value); })
          .then(function (accepted) {
            return accepted === true ? { ok: true } : { ok: false, message: t('writeRejected') };
          })
          .catch(function (error) {
            console.warn('[quickbar] config write rejected:', error);
            return { ok: false, message: t('writeRejected') };
          });
      }

      // ---------------------------------------------------------------- remote
      function lookupApi(child) {
        try {
          const direct = child.remote !== undefined && child.remote !== null ? child.remote[SERVICE] : undefined;
          if (direct !== undefined && direct !== null && typeof direct.getState === 'function') return direct;
        } catch (error) {
          // fall through to ctx.get
        }
        try {
          const service = child.get('remote.' + SERVICE);
          if (service !== undefined && service !== null && typeof service.getState === 'function') return service;
        } catch (error) {
          // absent
        }
        return null;
      }

      function ensureApi() {
        if (env.mountPromise !== null) return env.mountPromise;
        const child = env.remoteCtx;
        if (child === null) {
          store.set({ remoteReady: false, stateError: t('statusRemoteUnavailable') });
          env.mountPromise = Promise.resolve(null);
          return env.mountPromise;
        }
        env.mountPromise = Promise.resolve()
          .then(function () { return child.remote.$mount(CONTRIBUTION); })
          .catch(function (error) {
            env.mountError = error;
            console.warn('[quickbar] mounting Remote descriptors failed:', error);
          })
          .then(function () {
            env.api = lookupApi(child);
            if (env.api === null) {
              store.set({ remoteReady: false, stateError: t('statusRemoteUnavailable') });
            } else {
              store.set({ remoteReady: true, stateError: null });
            }
            return env.api;
          });
        return env.mountPromise;
      }

      async function watchLoop(child, abortController, isDisposed) {
        const api = await ensureApi();
        if (api === null || isDisposed() || abortController.signal.aborted) return;
        let initial = null;
        try {
          initial = await api.getState();
        } catch (error) {
          console.warn('[quickbar] initial getState failed:', error);
        }
        if (isDisposed() || abortController.signal.aborted) return;
        if (initial !== null && initial !== undefined && initial.ok === true) {
          applyState(initial.value);
          maybeResumePendingSubmit(initial.value);
        }
        while (!isDisposed() && !abortController.signal.aborted) {
          try {
            const stream = api.watch(abortController.signal);
            for await (const item of stream) {
              if (isDisposed() || abortController.signal.aborted) break;
              handleStreamItem(unwrapRemoteValue(item));
            }
          } catch (error) {
            if (isDisposed() || abortController.signal.aborted) break;
            console.warn('[quickbar] host status stream interrupted:', error);
          }
          if (isDisposed() || abortController.signal.aborted) break;
          await sleep(STREAM_RETRY_MS, abortController.signal);
        }
      }

      function startRemote(child) {
        env.remoteCtx = child;
        child.effect(function () {
          let disposed = false;
          const abortController = new AbortController();
          watchLoop(child, abortController, function () { return disposed; }).catch(function (error) {
            if (!disposed) console.warn('[quickbar] status watch loop stopped:', error);
          });
          return function () {
            disposed = true;
            try {
              abortController.abort();
            } catch (error) {
              // AbortController.abort never throws in practice
            }
          };
        }, 'quickbar: host status stream');
      }

      // ---------------------------------------------------------------- v2: workspaces / model catalog / selection
      function currentCatalog() {
        const snapshot = store.getSnapshot();
        if (snapshot.catalog !== null && snapshot.catalog !== undefined && typeof snapshot.catalog === 'object') return snapshot.catalog;
        return env.catalog;
      }

      function setCatalog(catalog) {
        env.catalog = catalog;
        store.set({ catalog: catalog });
      }

      function catalogGroups() {
        const catalog = currentCatalog();
        return catalog !== null && catalog !== undefined && Array.isArray(catalog.groups) ? catalog.groups : [];
      }

      function publishWorkspaces() {
        const service = env.workspacesSvc;
        let items = [];
        try {
          const snapshot = service.list.getSnapshot();
          items = snapshot !== null && snapshot !== undefined && Array.isArray(snapshot.items) ? snapshot.items : [];
        } catch (error) {
          items = [];
        }
        const mapped = [];
        for (const item of items) {
          if (item === null || typeof item !== 'object') continue;
          if (typeof item.workspaceId !== 'string' || item.workspaceId === '') continue;
          mapped.push({
            id: item.workspaceId,
            title: typeof item.title === 'string' ? item.title : '',
            path: typeof item.path === 'string' ? item.path : '',
          });
        }
        store.set({ workspaces: mapped, workspacesStatus: 'ready' });
        if (store.getSnapshot().open) resolveWorkspaceSelection();
      }

      /** Preselect the remembered workspace inside the window, else the default workspace. */
      function resolveWorkspaceSelection() {
        const snapshot = store.getSnapshot();
        const items = Array.isArray(snapshot.workspaces) ? snapshot.workspaces : [];
        if (items.length === 0) {
          if (snapshot.workspaceId !== null) store.set({ workspaceId: null });
          return;
        }
        const windowMs = effectiveRememberWindowMs(env.cfg);
        const stored = readStoredJson(LS_WORKSPACE_KEY);
        let chosen = null;
        if (stored !== null && typeof stored.id === 'string' && typeof stored.at === 'number' && Date.now() - stored.at <= windowMs) {
          for (const item of items) {
            if (item.id === stored.id) {
              chosen = item.id;
              break;
            }
          }
        }
        if (chosen === null) chosen = defaultWorkspaceId(items);
        if (chosen !== null && snapshot.workspaceId !== chosen) store.set({ workspaceId: chosen });
      }

      function chooseWorkspace(workspaceId) {
        if (typeof workspaceId !== 'string' || workspaceId === '') return;
        store.set({ workspaceId: workspaceId, popover: null });
        writeStoredJson(LS_WORKSPACE_KEY, { id: workspaceId, at: Date.now() });
        reportSelectionToHost();
      }

      /** Load the Host-generation model catalog once; retry when the caller asks for it. */
      function ensureModelCatalog(force) {
        if (env.remoteSession === null) {
          store.set({ modelStatus: 'unavailable' });
          return Promise.resolve();
        }
        if (force !== true && currentCatalog().status === 'ready') return Promise.resolve();
        if (force !== true && env.catalogPromise !== null) return env.catalogPromise;
        env.catalogGeneration += 1;
        const generation = env.catalogGeneration;
        const previous = currentCatalog();
        setCatalog({ status: 'loading', groups: Array.isArray(previous.groups) ? previous.groups : [], default: previous.default, error: null });
        const promise = Promise.resolve().then(function () {
          return env.remoteSession.modelCatalog();
        }).then(function (result) {
          if (env.catalogGeneration !== generation) return;
          if (result === null || result === undefined || result.ok !== true) {
            const message = result !== null && result !== undefined && result.error !== undefined ? errorText(result.error) : '';
            throw new Error(message !== '' ? message : 'model catalog unavailable');
          }
          const value = result.value !== null && result.value !== undefined && typeof result.value === 'object' ? result.value : {};
          const groups = Array.isArray(value.groups)
            ? value.groups.filter(function (group) { return group !== null && typeof group === 'object' && typeof group.id === 'string'; })
            : [];
          setCatalog({ status: 'ready', groups: groups, default: value.default !== undefined ? value.default : null, error: null });
          env.catalogPromise = null;
          resolveModelDefaults();
        }).catch(function (error) {
          if (env.catalogGeneration !== generation) return;
          console.warn('[quickbar] model catalog load failed:', error);
          setCatalog({
            status: 'error',
            groups: Array.isArray(previous.groups) ? previous.groups : [],
            default: previous.default,
            error: errorText(error),
          });
          env.catalogPromise = null;
        });
        env.catalogPromise = promise;
        return promise;
      }

      /** Best-effort read of the open conversation's model selection as the picker default. */
      async function readCurrentSessionSelection(sessionId) {
        const directories = env.modelDirectories;
        if (directories === null || directories === undefined || typeof sessionId !== 'string' || sessionId === '') return null;
        try {
          const directory = directories.directoryFor(sessionId);
          if (directory === null || directory === undefined) return null;
          if (typeof directory.load === 'function') {
            try {
              await directory.load();
            } catch (error) {
              // the default still falls back to the catalog
            }
          }
          const snapshot = directory.store !== null && directory.store !== undefined && typeof directory.store.getSnapshot === 'function'
            ? directory.store.getSnapshot()
            : null;
          const current = snapshot !== null && snapshot !== undefined ? snapshot.current : null;
          if (current === null || current === undefined || typeof current !== 'object') return null;
          if (typeof current.provider !== 'string' || typeof current.model !== 'string') return null;
          return {
            provider: current.provider,
            model: current.model,
            reasoningEffort: typeof current.reasoningEffort === 'string' && current.reasoningEffort !== '' ? current.reasoningEffort : undefined,
          };
        } catch (error) {
          return null;
        }
      }

      function applyResolvedSelection(selection, generation, before) {
        if (env.defaultsGeneration !== generation) return;
        if (store.getSnapshot().selection !== before) return;
        store.set({ selection: selection });
      }

      /**
       * Resolve the overlay's model default: remembered choice, then the open
       * conversation's current selection, then the first catalog group's first model.
       */
      async function resolveModelDefaults() {
        const snapshot = store.getSnapshot();
        const catalog = snapshot.catalog;
        if (catalog === null || catalog === undefined || catalog.status !== 'ready') return;
        const groups = Array.isArray(catalog.groups) ? catalog.groups : [];
        if (groups.length === 0) return;
        const generation = env.defaultsGeneration + 1;
        env.defaultsGeneration = generation;
        const before = snapshot.selection;
        if (before !== null && normalizeSelection(before, groups) !== null) return;
        const windowMs = effectiveRememberWindowMs(env.cfg);
        const stored = readStoredJson(LS_MODEL_KEY);
        if (stored !== null && typeof stored.provider === 'string' && typeof stored.model === 'string'
          && typeof stored.at === 'number' && Date.now() - stored.at <= windowMs) {
          const normalized = normalizeSelection({ provider: stored.provider, model: stored.model, reasoningEffort: stored.reasoningEffort }, groups);
          if (normalized !== null) {
            applyResolvedSelection(normalized, generation, before);
            return;
          }
        }
        const activeSessionId = store.getSnapshot().activeSessionId;
        if (activeSessionId !== null) {
          const current = await readCurrentSessionSelection(activeSessionId);
          if (generation !== env.defaultsGeneration) return;
          if (current !== null) {
            const normalized = normalizeSelection(current, groups);
            if (normalized !== null) {
              applyResolvedSelection(normalized, generation, before);
              return;
            }
          }
        }
        for (const group of groups) {
          const models = Array.isArray(group.models) ? group.models : [];
          if (models.length === 0) continue;
          const first = models[0];
          if (first === null || typeof first !== 'object' || typeof first.id !== 'string') continue;
          const normalized = normalizeSelection({ provider: group.id, model: first.id }, groups);
          if (normalized !== null) applyResolvedSelection(normalized, generation, before);
          return;
        }
      }

      function chooseModel(input) {
        if (input === null || input === undefined || typeof input !== 'object') return;
        const normalized = normalizeSelection({ provider: input.provider, model: input.model, reasoningEffort: input.reasoningEffort }, catalogGroups());
        if (normalized === null) return;
        env.defaultsGeneration += 1;
        const patch = { selection: normalized };
        if (input.closePopover === true) patch.popover = null;
        store.set(patch);
        writeStoredJson(LS_MODEL_KEY, {
          provider: normalized.provider,
          model: normalized.model,
          reasoningEffort: normalized.reasoningEffort === undefined ? null : normalized.reasoningEffort,
          at: Date.now(),
        });
        reportSelectionToHost();
      }

      /** The Host-owned selection shape; unknown fields stay `null`, never omitted. */
      function currentSelectionPayload() {
        const snapshot = store.getSnapshot();
        const selection = snapshot.selection;
        return {
          workspaceId: typeof snapshot.workspaceId === 'string' && snapshot.workspaceId !== '' ? snapshot.workspaceId : null,
          provider: selection !== null && typeof selection.provider === 'string' && selection.provider !== '' ? selection.provider : null,
          model: selection !== null && typeof selection.model === 'string' && selection.model !== '' ? selection.model : null,
          reasoningEffort: selection !== null && typeof selection.reasoningEffort === 'string' && selection.reasoningEffort !== ''
            ? selection.reasoningEffort
            : null,
        };
      }

      /**
       * Best-effort mirror of the in-app overlay's workspace/model/effort to the Host.
       * The Host is the native popup's source of truth in v4; an older Host without
       * `setSelection` simply answers a failed Remote result, which is non-fatal here.
       */
      function reportSelectionToHost() {
        const payload = currentSelectionPayload();
        Promise.resolve(ensureApi()).then(function (api) {
          if (api === null || api === undefined || typeof api.setSelection !== 'function') return undefined;
          return Promise.resolve(api.setSelection(payload)).then(function (result) {
            if (result !== null && result !== undefined && result.ok === false) {
              console.debug('[quickbar] Host did not accept setSelection:', remoteFailureText(result));
            }
            return undefined;
          });
        }).catch(function (error) {
          console.warn('[quickbar] setSelection could not be delivered:', error);
        });
      }

      function setPopover(kind) {
        const next = kind === 'workspace' || kind === 'model' ? kind : null;
        store.set({ popover: next });
        if (next === 'model') ensureModelCatalog(false);
      }

      function togglePopover(kind) {
        setPopover(store.getSnapshot().popover === kind ? null : kind);
      }

      function reloadCatalog() {
        return ensureModelCatalog(true);
      }

      /** Called once per overlay open: refresh pickers and resolve remembered defaults. */
      function overlayOpened() {
        store.set({ popover: null });
        resolveWorkspaceSelection();
        if (env.remoteSession !== null) {
          if (currentCatalog().status === 'ready') resolveModelDefaults();
          else ensureModelCatalog(false);
        }
      }

      // ---------------------------------------------------------------- v3: native-popup submit path
      // The native popup prints SUBMIT <base64>; the host raises the main window and
      // broadcasts `{type:'submit', text, nonce, at}`. This path reuses the exact v2
      // hydration helpers, sends through `submitPrompt` (workspace + model + navigation),
      // and never opens the overlay. `dsh-quickbar:last-submit` marks an accepted trigger
      // so a page reload or a second window cannot send the same text twice.
      function submitMarkerMatches(stored, at, text) {
        return stored !== null && stored !== undefined
          && typeof stored.text === 'string' && stored.text === text
          && typeof stored.at === 'number' && Math.abs(stored.at - at) <= SUBMIT_MARKER_TOLERANCE_MS;
      }

      function consumeSubmitMarker(at, text) {
        const stored = readStoredJson(LS_SUBMIT_KEY);
        if (submitMarkerMatches(stored, at, text)) return false;
        writeStoredJson(LS_SUBMIT_KEY, { at: at, text: text });
        return true;
      }

      /** A failed external submit releases the marker so a reload can retry inside the window. */
      function releaseSubmitMarker(at, text) {
        const stored = readStoredJson(LS_SUBMIT_KEY);
        if (!submitMarkerMatches(stored, at, text)) return;
        try {
          if (typeof window !== 'undefined' && window.localStorage !== undefined) window.localStorage.removeItem(LS_SUBMIT_KEY);
        } catch (error) {
          // storage is best effort
        }
      }

      /** Resolve a promise no later than `timeoutMs`; late settlements are ignored. */
      function settleWithin(promise, timeoutMs) {
        return new Promise(function (resolve) {
          let settled = false;
          const timer = setTimeout(function () {
            if (settled) return;
            settled = true;
            resolve(undefined);
          }, timeoutMs);
          function finish(value) {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve(value);
          }
          Promise.resolve(promise).then(finish, function () { finish(undefined); });
        });
      }

      async function waitForCondition(check, timeoutMs) {
        const deadline = Date.now() + timeoutMs;
        while (!env.disposed) {
          let ready = false;
          try {
            ready = check() === true;
          } catch (error) {
            ready = true;
          }
          if (ready) return;
          if (Date.now() >= deadline) return;
          await sleep(120);
        }
      }

      async function waitUntilIdle(timeoutMs) {
        const deadline = Date.now() + timeoutMs;
        while (!env.disposed && store.getSnapshot().busy === true && Date.now() < deadline) {
          await sleep(120);
        }
      }

      /**
       * Hydrate the remembered target without any overlay interaction: the live Workspace
       * list drives `resolveWorkspaceSelection()` (localStorage `last-workspace` inside the
       * remembered window, else the default workspace), and the model catalog drives the
       * stored `last-model` selection, falling back to the regular default resolution.
       */
      async function rehydrateExternalSelection() {
        await waitForCondition(function () {
          return env.workspacesSvc !== null || store.getSnapshot().workspacesStatus !== 'loading';
        }, 2000);
        if (env.disposed) return;
        if (env.workspacesSvc !== null) {
          try {
            publishWorkspaces();
          } catch (error) {
            console.warn('[quickbar] native submit: workspace refresh failed:', error);
          }
          resolveWorkspaceSelection();
        }
        if (env.remoteSession === null) return;
        await settleWithin(ensureModelCatalog(false), 5000);
        if (env.disposed) return;
        const groups = catalogGroups();
        if (groups.length === 0) return;
        const windowMs = effectiveRememberWindowMs(env.cfg);
        const stored = readStoredJson(LS_MODEL_KEY);
        let applied = false;
        if (stored !== null && typeof stored.provider === 'string' && typeof stored.model === 'string'
          && typeof stored.at === 'number' && Date.now() - stored.at <= windowMs) {
          const normalized = normalizeSelection({
            provider: stored.provider,
            model: stored.model,
            reasoningEffort: stored.reasoningEffort,
          }, groups);
          if (normalized !== null) {
            env.defaultsGeneration += 1;
            store.set({ selection: normalized });
            applied = true;
          }
        }
        if (!applied) await settleWithin(resolveModelDefaults(), 4000);
      }

      /** Mirror a Host-provided selection into localStorage so overlay defaults follow it. */
      function rememberExternalSelection() {
        const snapshot = store.getSnapshot();
        if (typeof snapshot.workspaceId === 'string' && snapshot.workspaceId !== '') {
          writeStoredJson(LS_WORKSPACE_KEY, { id: snapshot.workspaceId, at: Date.now() });
        }
        const selection = snapshot.selection;
        if (selection === null || selection === undefined) return;
        if (typeof selection.provider !== 'string' || typeof selection.model !== 'string') return;
        writeStoredJson(LS_MODEL_KEY, {
          provider: selection.provider,
          model: selection.model,
          reasoningEffort: typeof selection.reasoningEffort === 'string' ? selection.reasoningEffort : null,
          at: Date.now(),
        });
      }

      /**
       * v4: override the rehydrated defaults with the Host/native-popup selection.
       * - workspaceId is accepted only while it exists in the live Workspace list
       *   (an empty list means the service is unavailable, so it is accepted as-is);
       * - provider/model is normalized against the loaded catalog (effort validated,
       *   invalid effort falls back to the model's defaultEffort); with no catalog the
       *   incoming triple is accepted as-is because it cannot be validated;
       * - an invalid/absent field leaves the rehydrated (remembered) value in place.
       */
      function applyIncomingSelection(selection) {
        if (selection === null || selection === undefined || typeof selection !== 'object') return false;
        let applied = false;
        const workspaceId = selection.workspaceId;
        if (typeof workspaceId === 'string' && workspaceId !== '') {
          const items = store.getSnapshot().workspaces;
          const known = !Array.isArray(items) || items.length === 0
            || items.some(function (item) { return item.id === workspaceId; });
          if (known) {
            store.set({ workspaceId: workspaceId });
            applied = true;
          } else {
            console.warn('[quickbar] native selection names an unknown workspace; keeping the remembered one:', workspaceId);
          }
        }
        const provider = selection.provider;
        const model = selection.model;
        if (typeof provider === 'string' && provider !== '' && typeof model === 'string' && model !== '') {
          const groups = catalogGroups();
          if (groups.length > 0) {
            const normalized = normalizeSelection({
              provider: provider,
              model: model,
              reasoningEffort: selection.reasoningEffort,
            }, groups);
            if (normalized !== null) {
              env.defaultsGeneration += 1;
              store.set({ selection: normalized });
              applied = true;
            } else {
              console.warn('[quickbar] native selection names an unknown model; keeping the remembered one:', provider + '/' + model);
            }
          } else {
            store.set({
              selection: {
                provider: provider,
                model: model,
                reasoningEffort: typeof selection.reasoningEffort === 'string' && selection.reasoningEffort !== ''
                  ? selection.reasoningEffort
                  : undefined,
              },
            });
            applied = true;
          }
        }
        if (applied) {
          try {
            rememberExternalSelection();
          } catch (error) {
            console.warn('[quickbar] remembering the native selection failed:', error);
          }
        }
        return applied;
      }

      async function submitExternal(text, selection, images, markerAt) {
        const value = typeof text === 'string' ? text : '';
        if (value.trim() === '') return false;
        if (env.disposed) return false;
        let accepted = false;
        let failureMessage = null;
        try {
          await rehydrateExternalSelection();
          if (env.disposed) return false;
          if (selection !== null && selection !== undefined) {
            try {
              applyIncomingSelection(selection);
            } catch (error) {
              console.warn('[quickbar] applying the native selection failed; using the remembered one:', error);
            }
          }
          const mappedImages = mapIncomingImages(images);
          await waitUntilIdle(15000);
          if (env.disposed) return false;
          accepted = (await submitPrompt(value, { images: mappedImages, files: [] })) === true;
          if (accepted !== true) {
            const currentError = store.getSnapshot().error;
            failureMessage = typeof currentError === 'string' && currentError !== '' ? currentError : t('overlayErrorGeneric');
            console.warn('[quickbar] native submit did not complete:', failureMessage);
          }
        } catch (error) {
          console.warn('[quickbar] native submit failed:', error);
          accepted = false;
          failureMessage = t('overlayErrorGeneric');
        } finally {
          if (accepted !== true && typeof markerAt === 'number') releaseSubmitMarker(markerAt, value);
          try {
            store.close();
          } catch (error) {
            // closing the overlay is best effort
          }
        }
        // The native panel owns the visible result: ack first (close or inline error), then raise.
        await reportSubmitResultSafe(accepted === true, accepted === true ? null : failureMessage);
        if (accepted === true) {
          await raiseWindowSafe();
          if (!env.disposed) scheduleConversationScroll(env.lastSubmittedSessionId);
        }
        return accepted === true;
      }

      function queueExternalSubmit(text, selection, images, markerAt) {
        externalSubmitQueue = externalSubmitQueue.then(function () {
          return submitExternal(text, selection, images, markerAt);
        }).catch(function (error) {
          console.warn('[quickbar] external submit queue failed:', error);
        });
        return externalSubmitQueue;
      }

      function handleSubmitEvent(event) {
        if (event.text === undefined || event.text === null || typeof event.text !== 'string' || event.text.trim() === '') return;
        const nonce = typeof event.nonce === 'number' ? event.nonce : null;
        if (nonce !== null) {
          if (seenSubmitNonces.has(nonce)) return;
          seenSubmitNonces.add(nonce);
          if (seenSubmitNonces.size > 200) seenSubmitNonces.clear();
        }
        const at = typeof event.at === 'number' ? event.at : Date.now();
        const signature = String(at) + '|' + event.text;
        if (queuedExternalSubmits.has(signature)) return;
        queuedExternalSubmits.add(signature);
        if (queuedExternalSubmits.size > 100) queuedExternalSubmits.clear();
        if (!consumeSubmitMarker(at, event.text)) return;
        queueExternalSubmit(event.text, event.selection, event.images, at);
      }

      function maybeResumePendingSubmit(state) {
        if (state === null || typeof state !== 'object') return;
        const pending = state.pendingSubmit;
        if (pending === null || typeof pending !== 'object') return;
        if (typeof pending.text !== 'string' || pending.text.trim() === '') return;
        if (typeof pending.at !== 'number') return;
        if (Date.now() - pending.at >= PENDING_SUBMIT_TTL_MS) return;
        const nonce = typeof pending.nonce === 'number' ? pending.nonce : null;
        if (nonce !== null) {
          if (seenSubmitNonces.has(nonce)) return;
          seenSubmitNonces.add(nonce);
        }
        const signature = String(pending.at) + '|' + pending.text;
        if (queuedExternalSubmits.has(signature)) return;
        queuedExternalSubmits.add(signature);
        if (queuedExternalSubmits.size > 100) queuedExternalSubmits.clear();
        if (!consumeSubmitMarker(pending.at, pending.text)) return;
        queueExternalSubmit(pending.text, pending.selection, pending.images, pending.at);
      }

      // ---------------------------------------------------------------- submit
      function resolveSession(reference, binding) {
        try {
          if (binding !== null && binding !== undefined && binding.session !== undefined && binding.session !== null
            && typeof binding.session.prompt === 'function') return binding.session;
        } catch (error) {
          // released reference
        }
        try {
          if (reference !== null && reference !== undefined && reference.session !== undefined && reference.session !== null
            && typeof reference.session.prompt === 'function') return reference.session;
        } catch (error) {
          // older/later shape without .session
        }
        return null;
      }

      function tryDraftFallback(text) {
        const workspace = env.uiWorkspace;
        if (workspace === null || workspace === undefined || typeof workspace.startSession !== 'function') return false;
        try {
          workspace.startSession(undefined, { prompt: text, whenDraftExists: 'replace' });
          return true;
        } catch (error) {
          console.warn('[quickbar] draft fallback failed:', error);
          return false;
        }
      }

      /**
       * Resolve where this prompt goes. Primary path: a new conversation in the
       * selected Workspace (`connectWorkspace` returns an id without opening it,
       * then `openSession` navigates). Degraded paths: the open conversation, a
       * bare `sessions.create({})`, or the composer draft.
       */
      async function resolveSubmitTarget() {
        const snapshot = store.getSnapshot();
        const workspaces = Array.isArray(snapshot.workspaces) ? snapshot.workspaces : [];
        if (snapshot.workspacesStatus === 'ready' && workspaces.length > 0) {
          let workspaceId = snapshot.workspaceId;
          if (workspaceId === null || !workspaces.some(function (item) { return item.id === workspaceId; })) {
            workspaceId = defaultWorkspaceId(workspaces);
          }
          const ui = env.uiWorkspace;
          if (workspaceId !== null && ui !== null && ui !== undefined && typeof ui.connectWorkspace === 'function') {
            let sessionId = null;
            try {
              sessionId = await ui.connectWorkspace(workspaceId);
            } catch (error) {
              throw createLocalizedError(t('overlayWorkspaceCreateFailed', { message: errorText(error) }), error);
            }
            if (typeof sessionId !== 'string' || sessionId === '') {
              throw createLocalizedError(t('overlayWorkspaceCreateFailed', { message: 'empty session id' }), null);
            }
            try {
              if (typeof ui.openSession === 'function') ui.openSession(sessionId);
            } catch (error) {
              console.warn('[quickbar] opening the new session failed:', error);
            }
            return { sessionId: sessionId, viaWorkspace: true };
          }
        }
        const activeSessionId = snapshot.activeSessionId;
        const sessions = env.sessions;
        if (sessions !== null && sessions !== undefined && activeSessionId !== null) {
          return { sessionId: activeSessionId, viaWorkspace: false };
        }
        if (sessions !== null && sessions !== undefined && typeof sessions.create === 'function') {
          let createdId = null;
          try {
            createdId = await sessions.create({});
          } catch (error) {
            console.warn('[quickbar] creating a session failed:', error);
            createdId = null;
          }
          if (typeof createdId === 'string' && createdId !== '') {
            try {
              if (env.uiWorkspace !== null && typeof env.uiWorkspace.openSession === 'function') env.uiWorkspace.openSession(createdId);
            } catch (error) {
              console.warn('[quickbar] opening the created session failed:', error);
            }
            return { sessionId: createdId, viaWorkspace: false };
          }
        }
        return null;
      }

      /** Apply the picker selection to the target session through modelDirectories. */
      async function applyModelSelection(sessionId) {
        const selection = store.getSnapshot().selection;
        if (selection === null) return;
        const normalized = normalizeSelection(selection, catalogGroups());
        if (normalized === null) return;
        const directories = env.modelDirectories;
        if (directories === null || directories === undefined || typeof directories.directoryFor !== 'function') return;
        let result = null;
        try {
          const directory = directories.directoryFor(sessionId);
          if (directory === null || directory === undefined || typeof directory.select !== 'function') return;
          result = await directory.select({
            provider: normalized.provider,
            model: normalized.model,
            ...(normalized.reasoningEffort === undefined ? {} : { reasoningEffort: normalized.reasoningEffort }),
          });
        } catch (error) {
          throw createLocalizedError(t('overlayModelSelectFailed', { message: errorText(error) }), error);
        }
        if (result !== null && result !== undefined && result.ok === false) {
          throw createLocalizedError(t('overlayModelSelectFailed', {
            message: result.error !== undefined ? errorText(result.error) : 'selection refused',
          }), null);
        }
      }

      /** Upload file attachments through the existing client upload service (receipt per file). */
      async function uploadFileAttachments(sessionId, files) {
        const uploader = env.fileUpload;
        if (uploader === null || uploader === undefined || typeof uploader.upload !== 'function') {
          throw createLocalizedError(t('overlayUnsupportedContent'), null);
        }
        const uploaded = [];
        for (const file of files) {
          let result = null;
          try {
            result = await uploader.upload(
              sessionId,
              file,
              typeof file.name === 'string' && file.name !== '' ? file.name : undefined,
              undefined,
              undefined,
            );
          } catch (error) {
            throw createLocalizedError(t('overlayFilesUploadFailed', { message: errorText(error) }), error);
          }
          const failed = result === null || result === undefined || result.ok !== true
            || result.value === null || result.value === undefined
            || typeof result.value.receiptId !== 'string' || result.value.receiptId === ''
            || result.value.file === null || result.value.file === undefined
            || typeof result.value.file.attachmentId !== 'string';
          if (failed) {
            const message = result !== null && result !== undefined && result.error !== undefined ? errorText(result.error) : 'upload failed';
            throw createLocalizedError(t('overlayFilesUploadFailed', { message: message }), null);
          }
          uploaded.push({ receiptId: result.value.receiptId, file: result.value.file });
        }
        return uploaded;
      }

      async function submitPrompt(rawText, attachments) {
        const text = typeof rawText === 'string' ? rawText : '';
        const payload = attachments !== null && attachments !== undefined && typeof attachments === 'object' ? attachments : {};
        const images = Array.isArray(payload.images) ? payload.images : [];
        const files = Array.isArray(payload.files) ? payload.files : [];
        if (text.trim() === '' && images.length === 0 && files.length === 0) return false;
        if (store.getSnapshot().busy) return false;
        store.set({ busy: true, error: null, popover: null });
        const sessions = env.sessions;
        try {
          const target = await resolveSubmitTarget();
          if (target === null) {
            if (images.length === 0 && files.length === 0 && tryDraftFallback(text)) {
              store.set({ busy: false, error: null });
              store.close();
              return true;
            }
            store.set({ busy: false, error: t('overlayNoTarget') });
            return false;
          }
          if (sessions === null || sessions === undefined || typeof sessions.retain !== 'function') {
            store.set({ busy: false, error: t('overlayNoTarget') });
            return false;
          }
          const reference = sessions.retain(target.sessionId, { source: 'controllerOperation' });
          try {
            await reference.ready;
            let binding = null;
            try {
              binding = reference.binding;
            } catch (error) {
              binding = null;
            }
            const session = resolveSession(reference, binding);
            if (session === null) throw new Error('session is not available');
            // Order: retained scope -> model selection -> uploads -> echo -> prompt.
            await applyModelSelection(target.sessionId);
            const uploaded = files.length > 0 ? await uploadFileAttachments(target.sessionId, files) : [];
            const content = [];
            for (const image of images) {
              if (typeof image.mediaType !== 'string' || typeof image.base64 !== 'string' || image.base64 === '') continue;
              content.push({
                type: 'image',
                mediaType: image.mediaType,
                data: image.base64,
                ...(typeof image.name === 'string' && image.name !== '' ? { name: image.name } : {}),
              });
            }
            for (const entry of uploaded) content.push({ type: 'file', receiptId: entry.receiptId });
            if (text.trim() !== '') content.push({ type: 'text', text: text });
            const pending = [];
            for (const image of images) {
              if (typeof image.dataUrl !== 'string' || image.dataUrl === '') continue;
              pending.push({
                type: 'image',
                value: {
                  previewUrl: image.dataUrl,
                  ...(typeof image.name === 'string' && image.name !== '' ? { name: image.name } : {}),
                  ...(typeof image.width === 'number' ? { width: image.width } : {}),
                  ...(typeof image.height === 'number' ? { height: image.height } : {}),
                },
              });
            }
            for (const entry of uploaded) pending.push({ type: 'file', value: entry.file });
            let handle = null;
            try {
              handle = session.beginSubmission({ mode: 'queue', text: text, attachments: pending });
            } catch (error) {
              console.warn('[quickbar] beginSubmission failed; sending without local echo:', error);
              handle = null;
            }
            const requestId = handle !== null && handle !== undefined && typeof handle.requestId === 'string'
              ? handle.requestId
              : undefined;
            const result = await session.prompt(content, 'queue', undefined, requestId);
            if (result !== null && result !== undefined && result.ok === false) {
              const detail = remoteFailureText(result);
              throw createLocalizedError(t('overlayPromptRejected', { message: detail !== '' ? detail : 'unknown rejection' }), null);
            }
            store.set({ busy: false, error: null });
            env.lastSubmittedSessionId = target.sessionId;
            scheduleConversationScroll(target.sessionId);
            return true;
          } finally {
            try {
              reference.release();
            } catch (error) {
              // already released
            }
          }
        } catch (error) {
          console.warn('[quickbar] quickbar send failed:', error);
          const message = error !== null && error !== undefined && error.quickbarLocalized === true
            ? error.message
            : t('overlayErrorGeneric');
          store.set({ busy: false, error: message });
          return false;
        }
      }

      // ---------------------------------------------------------------- actions seat
      const actions = {
        open: function () { store.open('manual'); },
        close: function () { store.close(); },
        submit: function (text, attachments) { return submitPrompt(text, attachments); },
        test: function (closeSettings) { return runTest(closeSettings); },
        write: function (field, value) { return writeConfig(field, value); },
        overlayOpened: overlayOpened,
        togglePopover: togglePopover,
        setPopover: setPopover,
        chooseWorkspace: chooseWorkspace,
        chooseModel: chooseModel,
        reloadCatalog: reloadCatalog,
        dismissOnboarding: dismissOnboarding,
        dismissConflict: dismissConflict,
        openSettings: openSettings,
        suggestAlternativeHotkey: suggestAlternativeHotkey,
        formatAccel: formatAccel,
        eventToSpec: eventToSpec,
      };

      async function runTest(closeSettings) {
        if (typeof closeSettings === 'function') {
          try {
            closeSettings();
          } catch (error) {
            console.warn('[quickbar] closing settings before the test failed:', error);
          }
        }
        store.open('test');
        const api = env.api !== null ? env.api : await ensureApi();
        if (api === null) {
          const message = t('statusRemoteUnavailable');
          store.set({ error: message });
          return message;
        }
        try {
          const result = await api.testTrigger();
          if (result !== null && result !== undefined && result.ok === false) {
            const message = remoteFailureText(result) !== '' ? remoteFailureText(result) : t('overlayErrorGeneric');
            store.set({ error: message });
            return message;
          }
          return null;
        } catch (error) {
          console.warn('[quickbar] testTrigger failed:', error);
          const message = errorText(error) !== '' ? errorText(error) : t('overlayErrorGeneric');
          store.set({ error: message });
          return message;
        }
      }

      // ---------------------------------------------------------------- optional services
      ctx.inject(['configForms'], function (child) {
        setupConfig(child);
      });

      ctx.inject(['sessions'], function (child) {
        env.sessions = child.sessions;
      });

      ctx.inject(['uiWorkspace'], function (child) {
        env.uiWorkspace = child.uiWorkspace;
      });

      // Workspace picker: the live Workspace list plus its default workspace.
      ctx.inject(['workspaces'], function (child) {
        env.workspacesSvc = child.workspaces;
        try {
          child.effect(function () {
            return child.workspaces.list.subscribe(publishWorkspaces);
          }, 'quickbar: workspace list');
        } catch (error) {
          console.warn('[quickbar] workspace list subscription failed:', error);
        }
        publishWorkspaces();
      });

      // Model catalog + per-session model selection.
      ctx.inject(['remote', 'remote.session', 'modelDirectories'], function (child) {
        env.remoteSession = child.remote.session;
        env.modelDirectories = child.modelDirectories;
        store.set({ modelStatus: 'ready' });
        if (store.getSnapshot().open) ensureModelCatalog(false);
      });

      // Existing client upload service (background transport); receipts feed the prompt.
      ctx.inject(['fileUpload'], function (child) {
        env.fileUpload = child.fileUpload;
        store.set({ fileStatus: 'ready' });
      });

      ctx.inject(['remote', 'typert'], function (child) {
        startRemote(child);
      });

      // ---------------------------------------------------------------- keyboard listeners
      ctx.effect(function () {
        if (typeof window === 'undefined') return function () {};
        function isInsideOverlay(target) {
          if (target === null || target === undefined) return false;
          if (typeof target.closest !== 'function') return false;
          try {
            return target.closest('[data-quickbar-overlay]') !== null;
          } catch (error) {
            return false;
          }
        }
        function onInAppKeyDown(event) {
          if (env.shortcutCommand === true) return;
          if (event.defaultPrevented || event.repeat) return;
          if (store.getSnapshot().open) return;
          if (hasHostModal()) return;
          const spec = env.cfg.inAppShortcut;
          if (typeof spec !== 'string' || spec === '') return;
          const parsed = parseSpec(spec);
          if (parsed === null) return;
          if (!eventMatchesSpec(parsed, event)) return;
          if (isInsideOverlay(event.target)) return;
          event.preventDefault();
          event.stopPropagation();
          store.open('shortcut');
        }
        function onEscapeKeyDown(event) {
          if (event.key !== 'Escape') return;
          const snapshot = store.getSnapshot();
          if (!snapshot.open) return;
          event.preventDefault();
          event.stopPropagation();
          if (snapshot.popover !== null) {
            store.set({ popover: null });
            return;
          }
          store.close();
        }
        // Capture phase: the shell and other plugins register their own key
        // handlers on window, and a bubble-phase listener ran too late once
        // another handler stopped propagation (the in-app shortcut looked dead).
        window.addEventListener('keydown', onInAppKeyDown, true);
        window.addEventListener('keydown', onEscapeKeyDown, true);
        return function () {
          window.removeEventListener('keydown', onInAppKeyDown, true);
          window.removeEventListener('keydown', onEscapeKeyDown, true);
        };
      }, 'quickbar: keyboard listeners');

      // ---------------------------------------------------------------- command registration
      // The desktop app routes accepted shortcuts through the native keyboard
      // bridge, so a DOM keydown listener never sees them. Register the real
      // command in the shell Shortcut Service (it also shows up under
      // Settings -> Shortcuts and honours user rebinds); the DOM listener above
      // stays as the fallback for environments without that service.
      ctx.inject(['shortcuts'], function (child) {
        const candidates = [];
        const configured = specToShortcutBinding(env.cfg.inAppShortcut);
        if (configured !== null) candidates.push(configured);
        candidates.push({ code: 'KeyK', modifiers: ['primary', 'shift'] });
        candidates.push({ code: 'KeyK', modifiers: ['primary', 'alt'] });
        const defaults = {};
        for (let index = 0; index < 6; index += 1) {
          const profile = ['desktop:macos', 'desktop:windows', 'desktop:linux', 'web:macos', 'web:windows', 'web:linux'][index];
          defaults[profile] = candidates[0];
        }
        function openFromCommand() {
          const snapshot = store.getSnapshot();
          if (snapshot.open) {
            store.close();
            return;
          }
          if (hasHostModal()) return;
          store.open('shortcut');
        }
        child.effect(function () {
          for (let index = 0; index < candidates.length; index += 1) {
            const binding = candidates[index];
            const profileDefaults = {};
            const profiles = ['desktop:macos', 'desktop:windows', 'desktop:linux', 'web:macos', 'web:windows', 'web:linux'];
            for (let p = 0; p < profiles.length; p += 1) profileDefaults[profiles[p]] = binding;
            try {
              const dispose = child.shortcuts.register({
                id: 'quickbar.open',
                label: function () { return env.t('commandOpen'); },
                aliases: ['quickbar', 'quick input', '快捷唤起'],
                defaults: profileDefaults,
                regions: ['page', 'editable', 'terminal'],
                modals: [],
                resolve: function () {
                  return {
                    status: 'handled',
                    run: function () { openFromCommand(); },
                  };
                },
              });
              env.shortcutCommand = true;
              return dispose;
            } catch (error) {
              console.warn('[quickbar] shortcut binding rejected, trying the next one:', error);
            }
          }
          return function () {};
        }, 'quickbar: shortcut command');
      });

      // ---------------------------------------------------------------- slot registrations
      const injectFace = function () {
        return { store: store, actions: actions, t: t };
      };

      ctx.slots.inject(OVERLAY_SLOT, function () {
        return ctx.slots.register({
          name: OVERLAY_SLOT,
          id: 'quickbar-overlay',
          order: 500,
          inject: injectFace,
        }, OverlayHost);
      });

      ctx.slots.inject(SETTINGS_SLOT, function () {
        return ctx.slots.register({
          name: SETTINGS_SLOT,
          id: ENTRY_ID,
          order: 60,
          label: function () { return t('nav'); },
          inject: injectFace,
        }, SettingsSection);
      });

      ctx.slots.inject(COMPOSER_SLOT, function () {
        return ctx.slots.register({
          name: COMPOSER_SLOT,
          id: SESSION_PROBE_ID,
          order: 1000,
          inject: injectFace,
        }, SessionProbe);
      });
    }

    return {
      inject: ['slots', 'locale'],
      apply: apply,
    };
  },
});
