# Changelog

## 0.2.0 — 2026-11-04

Interaction and reliability pass on the native quick-input popup.

### Native popup
- Multi-line input (`NSTextView`): grows to 5 lines then scrolls; Enter sends,
  Shift+Enter adds a newline, IME composition is never submitted mid-word.
- Toggle: the global hotkey opens the popup, pressing it again closes it (draft
  kept); Esc clears and closes; clicking outside closes and keeps the draft.
- Transient focus grabs (IME candidate windows, clipboard-history pickers) no
  longer close the popup; only switching away from the app does.
- `⌘V` image paste actually reaches the field (the helper now installs an Edit
  menu, because a menu-bar-less accessory app never gets the paste key
  equivalent). Up to 4 images, 72×72 previews that show the whole image,
  hover-to-remove, and a transient “已添加图片 N/4” confirmation. The footer
  “⌘V 粘图” hint is also a clickable manual paste path.
- Sending lifecycle: sending / sent / inline error, acknowledged by the host
  over stdin (`SUBMIT_OK` / `SUBMIT_FAIL`), with actionable messages instead of
  a bare timeout.
- Visual pass per `native/DESIGN.md`: material card, 16 pt radius, one soft
  shadow, no borders, pill selectors, accent send pill, 13 pt input on a darker
  fill (no focus ring), semantic AppKit colors, 180/120/150 ms motion, drag
  position remembered per display.

### Host and client
- Images travel from the popup through `submit` events and `pendingSubmit`;
  `fireSubmit` no longer raises the window — the client raises it after the
  prompt is accepted (`raiseWindow()`), and reports the outcome
  (`reportSubmitResult()`).
- A submit is bounded by an explicit ack watchdog, and lines over the protocol
  cap are answered with an error instead of being dropped.
- In-app `⌘⇧K` overlay: registered as a real shortcut command through the
  Harness Shortcut Service, so it works on desktop (native keyboard bridge) and
  appears in Settings → Shortcuts where it can be rebound.
- First-run guidance, hotkey-conflict notices, auto-scroll to the sent message,
  and a settings page polished to the same design language.

### Docs
- New developer docs under `docs/dev/` (architecture, native protocol, popup
  decisions and pitfalls, testing recipes, release checklist) plus
  `DEVELOPMENT.md`; the stale `HOST_NOTES.md` was folded into them.
- Repository moved to the dedicated workspace layout
  `plugins-workspace/plugins/dsh-quickbar`.

## 0.1.0 — 2026-11-03
- First public version: global hotkey (`⌘⇧Space`), native popup with workspace /
  model / reasoning-effort pickers, in-app overlay with image paste and file
  attachments, settings page.
