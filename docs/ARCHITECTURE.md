# Architecture

How `src/` fits together. Settings are in [CONFIGURATION.md](CONFIGURATION.md), the build in [BUILDING.md](BUILDING.md), code style in `.claude/STYLE.md`.

## Overview

- One executable, `eve-maj-preview.exe`, root `src/main.zig`. Windows subsystem; a console opens only at log level `debug`.
- The configuration window runs in-process on the main thread (knots, Vulkan). `zig build config` runs the app with `--config`.
- `zig build test` runs `src/tests.zig`, which lists every module with tests. Tests build in Debug.
- knots is vendored in `deps/knots/`; local changes are marked `EVE-Maj patch` and listed in its `PATCHES.md`.

## Files on disk

All relative to the exe folder (`main.zig` sets the cwd there).

| Path | Contents | Owner |
|---|---|---|
| `profiles/<name>.json` | Per-profile `Config` | `config/profiles.zig` |
| `profiles/global.settings.json` | `GlobalConfig` | `config/global.zig` |
| `profiles/backup/` | Profiles deleted, reset, imported over, unreadable or backed up from the Backups tab, `<unix time>_<name>` | `config/profiles.zig` |
| `data/colors.json` | Generated system/character colours | `config/auto_colors.zig` |
| `data/character_ids.json` | Character name → EVE ID | `chatlog/character_ids.zig` |
| `data/portraits/{id}.jpg` | Character portraits | `dialog/knots/portraits.zig` |
| `logs/eve-maj.log`, `.old` | Log, rotated at 20 MB | `log.zig` |
| `logs/eve-maj-crash.dmp` | Minidump of the latest crash | `crash.zig` |

`config/files.zig`'s `migrateLegacyLayout` moves files older versions kept beside the exe into `data/` and `logs/`.

## Startup (`main.zig`)

1. Set per-monitor DPI awareness, install crash handlers.
2. Parse arguments (`arguments.zig`: `--profile`/`-p`, `--config`, `--protocol <url>`).
3. `--protocol`: forward to the running instance over `WM_COPYDATA` and exit. Done before the single-instance check.
4. Claim the `Global\EVE-Maj-Preview-SingleInstance` mutex. If taken, send `evemajpreview://config` to the running instance and exit.
5. Load bundled fonts, `GlobalConfig`, `CharacterIds`, language, then the profile into a `ProfileStore`.
6. Build subsystems in dependency order: notification center → `Scout` → `ThumbnailSet` → `ChatlogMonitor` (worker stopped) → activity `Trackers` → start the chatlog worker.
7. Create the hidden timer window, focus hook, tray icon, update check thread.
8. Scan windows, populate thumbnails, add characters to the chatlog monitor.
9. Start the hotkey hook thread, create the `HotkeyManager`, install the focus grant, start the tick timer.
10. Run the `GetMessageA` loop.

Each step's `defer` sits right after it, so teardown is the reverse order. `app.g_app` is set first and cleared last.

## `App` (`app.zig`)

Owns every long-lived subsystem. Main thread only.

| Field | Lifetime |
|---|---|
| `store` (`ProfileStore`), `global_settings`, `character_ids`, `scout`, `exclusions`, `notifications` (`NotificationCenter`), `focus`, `trackers`, tray | Whole run |
| `auto_minimizer` | Whole run; reset when a different profile loads |
| `thumbnail_set`, `hotkey_manager`, `chatlog_monitor` | Rebuilt on reload; heap pointers |
| `list_window` | Built and torn down with `thumbnail_set`; `ClientList` and `ThumbnailsAndList` modes only |

Rules:

- Rebuilt subsystems are read from `App` each time, never cached elsewhere.
- State that must survive a rebuild lives on `App` (exclusions, notification history, auto-minimize toggle).
- `HotkeyManager` holds `*App`. `ThumbnailSet` borrows only the store, exclusions and the notification center's history and notified queue (`dispatch.Records`). App passes in its window procs and destroy hook, so `thumbnail/` imports no input or panel code.

Reload entry points:

| Call | Trigger | Effect |
|---|---|---|
| `requestProfileSwitch` → `WM_SWITCH_PROFILE` → `switchProfile` | Tray, hotkey | Deferred to the next message-loop turn |
| `switchProfile` | Protocol, dialog | Loads the profile, then `restartSubsystems` |
| `applySavedSettings` | Dialog Save | `restartSubsystems` with the same store |
| `onLiveProfileEdited` | Every dialog edit | Restyle/reflow; rebuilds the thumbnail set only on a view-mode change |

`restartSubsystems` runs the steps from `control/restart_plan.zig` (pure, tested): which subsystems are kept, paused or rebuilt, in what order, and what to bring back up if a step fails. A kept chatlog worker is paused until the new trackers are wired in. A new store is built before anything is torn down, so a load failure leaves the running profile intact.

## Main thread messages

`timerWindowProc` (`main.zig`) is the central dispatcher:

| Message | Handler |
|---|---|
| `WM_TIMER` `TICK_TIMER_ID` | `App.tick` |
| `WM_TIMER` `HIDE_DEBOUNCE_TIMER_ID` | `focus.onHideTimer` |
| `WM_HOTKEY` | `focus_grant.handleWmHotkey`, else `HotkeyManager.handleHotkeyPress` |
| `WM_TRAYICON`, `WM_COMMAND` | `TrayIcon` |
| `TaskbarCreated` (registered) | `TrayIcon.handleTaskbarCreated`: re-adds the icon after Explorer restarts; the tick also retries a missing one every 5 s |
| `WM_COPYDATA` | `protocol/run.handleCopyData`: protocol URLs from a second process |
| `WM_SWITCH_PROFILE` | `App.runPendingProfileSwitch` |
| `WM_HOTKEYS_STATE_CHANGED` | Suspend/resume notification |
| `WM_WIN_KEY_CAPTURED` | `keyboard_hook.onWinKeyCaptured`: a bare Win press the config dialog is recording |
| `WM_KNOTS_COMMAND` | `dialog/knots/host.onCommand` |
| `WM_ENDSESSION` | `App.saveForSessionEnd`: Windows may end the process once it returns, so pending auto colours and log lines are written first |

## The tick (`App.tick`)

Driven by `WM_TIMER` at `timer.scanIntervalMs`, or 1 s while no window is tracked and the dialog is closed.

```
Scout.update(force_scan)              hook events + full EnumWindows at most every 1 s
clearLoggedOutExclusions
ThumbnailSet.update                   create/destroy/rename thumbnails
focus.afterThumbnailSetUpdate         record focus, resync cycle cursors
AutoMinimizer.check
ThumbnailSet.updateNotifications
ThumbnailSet.checkHoverZoom
ChatlogMonitor.update + drain         -> deliverChatlogFindings -> Scout, ThumbnailSet
NotificationCenter.update             History Panel
MapPanel.update                       takes new stats, renders the map
Trackers.tick                         throttled push of rates/resources into ThumbnailSet
travel_left_behind.check              every ~2 s
adjust tick interval
```

Throttled work uses `util/schedule.zig`: intervals measure from the tick's start and run on the nearest tick, so timer jitter never skips a whole interval.

## Threads

| Thread | Module | Talks to main via |
|---|---|---|
| Main | message loop, all window procs, WinEvent hooks, tick, config window | — |
| Hotkey hooks | `hotkeys/hook_thread.zig`: the low-level keyboard and mouse hooks, at time-critical priority | Posts `WM_HOTKEY` and `WM_WIN_KEY_CAPTURED`; main changes bindings through `hook_thread.call` |
| Chatlog worker | `chatlog.zig` | `chatlog/queue.zig` queues |
| TTS worker | `notifications/tts.zig` (STA COM, SAPI) | Fire-and-forget command queue |
| Sound worker | `notifications/sound.zig` (Media Foundation + waveOut) | Fire-and-forget command queue |
| Update check | `update.zig`, one-shot at startup and each time the config dialog opens | Mutex-guarded `UpdateStatus` |
| Clipboard upload | `hotkeys/paste_upload.zig`, one per press, at most 4 at once | None; slots claimed through atomics |
| Dialog helpers | `pickers.zig`, `prices.zig`, `portraits.zig`, one-shot | `WM_KNOTS_COMMAND` |
| Map stats | `map/stats_feed.zig`, one-shot every 15 minutes while the Map Panel shows | Atomic snapshot swap, taken on the tick |

TTS and sound share `notifications/worker.zig`'s lazily started `Worker`. Alerts go through `pushAlert`, which drops the oldest waiting alerts past a limit (speech: the profile's `tts_max_waiting`; sound: 3); voice settings go through `push` and are never dropped.

The one-shot threads (update check, clipboard uploads, dialog helpers, map stats) are started through `util/detached.zig`, which counts them; `main.zig` waits up to 2 s at exit for them to finish before tearing down what they use, and ends the process instead of returning if any are still running, since returning frees the allocator and `Io` they use.

Cross-thread data:

- Chatlog: `commands` (main → worker); `system_updates`, `notifications`, `session_starts`, `intel_sightings` (worker → main). Every other `ChatlogMonitor` field is owned by one thread.
- `activity/tracker.zig` trackers: written by the worker, read by main, each under its own mutex.
- `CharacterIds`: locks its own map.
- Hook bindings, held presses and the require-EVE-focus filter: hook thread only. Main changes them through `hook_thread.call`, which runs the change there and waits for it. The hook thread never logs while a hook is installed, since waiting on the log lock could stall it past `LowLevelHooksTimeout` and Windows would silently drop the hook: changes report their outcome for main to log, and failed `WM_HOTKEY` posts are counted for `App.tick` to log.
- The worker reads `GlobalConfig` ore prices, so new global settings are adopted only while it's stopped.

## Window discovery and thumbnails

**`clients/scout.zig`** (`Scout`): `EnumWindows` matched against `windowFilters` (class name, then exe path for new windows only). `trinityWindow` titles give the character name. Per-process `EVENT_OBJECT_NAMECHANGE`/`DESTROY` hooks catch renames and closes between scans; the destroy hook only records the hwnd, and `update()` drops it before handing out the window list, so the slice a tick borrows never changes under it. No creation hook: it would fire for every window on the desktop.

**`thumbnail/set.zig`** (`ThumbnailSet`): the central mutable state. Owns the `ThumbnailWindow` list (linear search, a few dozen at most), keeps it in step with Scout, dispatches notifications, schedules layout and redraws. Holds the `Renderer`, auto-move verifier, ghost overlay, hint box and `AutoColorStore`.

**`thumbnail/window.zig`** (`ThumbnailWindow`): one per client, two HWNDs:

1. A layered popup with the client's DWM thumbnail (`DwmRegisterThumbnail`).
2. A layered window on top with the GDI overlay (border, texts, notifications).

In `ClientList`/`Nothing` view modes both HWNDs are sentinels. Render state (active, inactive, alert, minimized, dragging) isn't stored; `effectiveRenderState()` derives it each render.

Per-thumbnail state owned by other modules:

| Field | Owner |
|---|---|
| `render_cache` | `thumbnail/overlay.zig` |
| `notifications` | `notifications/stack.zig` |
| `auto_minimize` | `control/auto_minimize.zig` |
| `is_dragged` | `drag/thumbnail.zig` |
| `travel` | `travel/left_behind.zig` |
| `stats` | Activity trackers, via `ThumbnailSet.updateStats` |

Rendering:

- `thumbnail/renderer.zig`: skips a redraw when `RenderSettings` are unchanged. Owns `FontCache` and `HoverZoom`.
- `thumbnail/overlay.zig`: builds `RenderSettings` (compared field by field at comptime) and paints them. The cache borrows thumbnail strings, so they're swapped only through `ThumbnailWindow.replaceText`, which nulls `render_cache.settings` first.
- `thumbnail/draw.zig`: text, border and exclusion primitives.
- `platform/gdi_overlay.zig`: DIB-backed layered windows, text helpers, `HintBox`, class registration.
- `util/pixel_buffer.zig`: pure ARGB drawing (rects, anti-aliased lines and circles, rounded frames, alpha fix-up).
- `platform/panel_window.zig`: `PanelWindow`, shared by the client list, History Panel and Map Panel.
- `panels/list_view.zig` + `list_look.zig`: `ClientList` and `ThumbnailsAndList` view modes; App owns the window, built and torn down with the thumbnail set. `list_look` is pure and shared with the dialog preview.
- `panels/panel_look.zig` + `panel_chrome.zig`: what the History, Map and Intel panels share, so they match: fonts, header, footer buttons, frame, and when they show.
- `panels/history_rows.zig`: the rows the History and Intel panels list. The Map Panel draws them in a sidebar; `panels/intel_panel.zig` is the Intel Panel's own window for when it's detached.
- `panels/map_panel.zig` + `map_look.zig`: the Map Panel; App owns it, so it survives thumbnail set rebuilds. Draws from `map/`: `universe.zig` (embedded map, built by `.claude/tools/build_universe.py`), `layout.zig` (positions and label placement on CCP's flattened map), `stats.zig` + `stats_feed.zig` (ESI figures), `intel_pins.zig` (systems named in intel channels). Hover redraws from `WM_MOUSEMOVE`, since the idle tick is a second apart.
- `thumbnail/hover_zoom.zig` + `layout/zoom.zig`: click-through enlarged copy under the cursor.

Layout (`layout/`, mostly pure):

- `spaces.zig`: which thumbnail space a character goes to, and its cell.
- `region_grid.zig`: grid math inside a space.
- `placement.zig`: per-space cells and hand-placed positions.
- `monitors.zig`: monitor bounds and DPI.
- `thumbnail/arrange.zig`: applies the layout to windows.

## Input and control

- **Hotkeys** go through `WH_KEYBOARD_LL`/`WH_MOUSE_LL` (`hotkeys/keyboard_hook.zig`, `mouse_hook.zig`, shared `hook_bindings.zig`), not `RegisterHotKey`, so bare modifiers and mouse buttons bind. Matches are posted as `WM_HOTKEY`. The hooks run on their own thread, so a busy main thread never delays input or gets them removed by Windows. Each key or button press is decided at its first down: a swallowed press has its repeats and release swallowed too, so a client never sees a key-up without its down, which holding Ctrl through a cycle depends on. With `requireEveFocus`, a bound key pressed outside a tracked window passes through untouched. With NumLock on, Windows sends Shift+Numpad as a fake Shift release then a navigation key; the hook and the config dialog's recorder read it back as Shift+Numpad.
- **IDs** (`hotkeys/bindings.zig`): bands of 1000 per kind (cycle group 0, global action 1000, per-character 2000, profile switch 3000, assign group 4000, app 5000, URL 6000, close group 7000, minimize group 8000). `GLOBAL_BINDINGS` maps global actions to config fields and protocol actions.
- **`hotkeys/manager.zig`** (`HotkeyManager`): registration, suspend and dialog-recording pause, and `runAction`, the one switch on `HotkeyAction`. Bindings come from `store.saved`; other settings from `store.live`.
- **`hotkeys/cycling.zig`**: every cycle hotkey. Decisions are in `cycle_order.zig` (pure, tested).
- **`control/activation.zig`** (`activate`): where every click, cycle and protocol switch ends. Restore, foreground, reconcile thumbnail states, dismiss click-suppressed notifications, sync cycle cursors.
- **`platform/focus_grant.zig`**: `SetForegroundWindow` needs recent user input. A real `RegisterHotKey` on an unreachable combo is triggered with `keybd_event`; its `WM_HOTKEY` carries the foreground right.
- **`control/focus.zig`** (`FocusTracker`): the `EVENT_SYSTEM_FOREGROUND` hook; feeds the thumbnail set, auto-minimize and cycling; auto-hides thumbnails after focus leaves EVE.
- **`control/auto_minimize.zig`**: minimizes idle clients; decisions in `minimize_rules.zig` (pure, tested).
- **`clients/`**: actions on EVE windows only (minimize, close, move, `animation.zig`'s `showClient`). Imports nothing from thumbnail, hotkey, drag or control.
- **`control/thumbnail_input.zig`**: thumbnail window procs, passed into `thumbnail/` by App. Left click → `activate`; shift-click → exclusion toggle; right drag → `drag/thumbnail.zig` (Ctrl moves all).
- **`drag/`**: snapping (`snap_math.zig` pure), ghost overlays. Panel header drags are `panels/drag.zig`.
- **`protocol/`**: `url.zig` parses `evemajpreview://` URLs into a `Command` (pure, tested); `ipc.zig` sends the URL text itself to the running instance over `WM_COPYDATA`, giving up after 5 s on a hung one (the timer window lets the message through UIPI, so an elevated instance still receives it); `run.zig` parses it there and runs it through the same code as its hotkey or tray item (group actions via `HotkeyManager.runGroupAction`); `registry.zig` registers the handler, again whenever the exe path changes.

Hotkey press → character switch:

```
WM_HOTKEY -> timerWindowProc -> HotkeyManager.handleHotkeyPress -> runAction
  -> cycling.* -> Scout.getHwndByName -> activation.activate -> focus_grant.forceSetForegroundWindow
```

## Log monitoring

`chatlog.zig` (`ChatlogMonitor`). Worker loop: `processCommands` → `pollLogFiles` → `rescanForNewLogs` → wait `poll_interval_ms`.

- Main side: `update()` queues add/remove/resolve-ID commands; `drain()` returns `Findings`, which `App.deliverChatlogFindings` routes to Scout and `ThumbnailSet`. The monitor never touches either.
- `chatlog/discovery.zig` (`LogFinder`): finds a character's newest log by cached ID (`*_<id>.txt`), else by reading `Listener:` headers of the newest 64 files.
- `chatlog/tail.zig` (`LogFile`): keeps the handle open, reads appended bytes, backs off when idle.
- `chatlog/utf16.zig`, `chatlog/lines.zig`: decoding and line parsing (pure). System changes, jumps, undocks, file names, headers.
- `notifications/gamelog_events.zig` (`classify`): line → `Notification` (pure).
- `activity/lines.zig`: combat/mining/bounty line parsers (pure), feeding `activity/tracker.zig`'s ring-buffer windows.
- `session_starts` backdates a character's login (Session Timer) via `Scout.backdateLogin`.

`activity/runtime.zig` (`Trackers`) matches trackers to the config while the worker is stopped, keeping history for those that stay enabled. `activity/resources.zig` samples CPU/RAM/VRAM (PDH) per client process on the main thread, and `activity/ping.zig` pings each client's game server with asynchronous ICMP echoes it polls each tick; both follow the live config, so they preview before Save.

## Notifications

- `notifications/notification.zig`: types, categories, placeholders, default text.
- `notifications/dispatch.zig`: shows a notification if `rules.zig` (pure) allows it; adds sound, speech, history and notified-queue entries.
- `notifications/template.zig`: fills `{name}` placeholders in custom text (pure).
- `notifications/stack.zig`: per-thumbnail on-screen stack, with throttle timestamps.
- `notifications/center.zig` (`NotificationCenter` on `App`): `history.zig` ring buffers (one more for the Intel Panel, fed by every chatlog intel sighting), `notified_queue.zig`, `panels/history_panel.zig`, `panels/intel_panel.zig`. Survives thumbnail set rebuilds.
- `notifications/alert_effects.zig`: speech and sound, plus the session-only audio mute.
- The chatlog worker queues `Notification` payloads; text is rendered on the main thread.
- `travel/`: left-behind detection; `stragglers.zig` is pure.

## Configuration model (`config.zig`, `config/`)

`config.zig` defines `Config` and re-exports every settings type; other modules import only it.

- One file per section (`thumbnail.zig`, `display.zig`, `behavior.zig`, `activity.zig`, `notifications.zig`, `chatlog.zig`, `characters.zig`, `hotkeys.zig`, `spaces.zig`, ...). Types holding saved settings are named `XxxConfig`.
- **`wire.zig`**: generates each section's JSON shape and encode/decode/free/clone from its fields (`pub const Wire = wire.Wire(Self)`). Field-name conventions pick the encoding: `*Color` u32 → hex string, `KeyList` → key code(s). `runtime_fields` aren't saved; `wire_defaults` supplies defaults a runtime field can't hold.
- **`readable.zig`**: lenient load. Drops each field, item or entry that doesn't fit its type, so it falls back to its default alone. Only non-JSON fails (file copied to `profiles/backup/`, defaults used).
- **`migrate.zig`**: upgrades older profile JSON before parsing (pure, tested).
- **`ranges.zig`**: per-type `ranges` tables and `zero_means_default`; every `validate()` is `ranges_mod.clamp(Self, self)`, which recurses into nested sections.
- **`store.zig`** (`ProfileStore`): the only writer of the running profile.
  - `live`: what the app shows, including unsaved dialog edits. Read by `ThumbnailSet` and panels (as `*const Config`).
  - `saved`: what's on disk. Read by setup-once consumers: Scout filters, hotkey bindings, chatlog, trackers, timer.
  - Runtime changes (drags, tray toggles, group membership) apply to both and save immediately.
  - `commit` (Save) clones `live` → `saved`; `discard` clones `saved` → `live`.
- **`patch.zig`**: path-addressed `set`/`insert`/`remove`/`move` ops; keyed lists (`characters`, `hotkeyGroups`, `thumbnailSpaces`) are addressed by runtime `id`. Used for imports.
- **`profiles.zig`**: load with fallbacks, save, create (exclusive), copy, rename, backup, restore. Every name passes `validateName`.
- **`import/`**: EVE-X / EVE-MultiPreview, EVE-APM (INI), EVE-O and own profiles → `Draft` → patch ops. Untested by design.
- **`global.zig`**: `GlobalConfig` (last profile, cross-profile hotkeys, ore prices, log level, language).

## Configuration window (`dialog/`)

Immediate-mode (knots on Vulkan), main thread, nested message loop so the tick and tray keep running. Each frame reads settings and writes them straight back; there's no form state.

- `knots/host.zig`: window lifecycle, nested loop, close prompt, saved position. Every save goes through `saveChanges`, which refuses while hotkeys conflict. Anything that replaces documents or touches the app is posted as `WM_KNOTS_COMMAND` and runs between frames.
- `knots/session.zig`: edits `store.live` and a `GlobalConfig` draft. Every change goes through `Ref.set` (or list `append`/`remove`/`move`): copies strings, clamps, calls `App.onLiveProfileEdited`. Replaced strings are freed a frame later. Dirty = differs from saved. `save()` commits, restarts subsystems and adopts the global draft.
- `knots/form.zig`: header, sidebar, open tab, footer, prompts. `knots/tabs/`: one file per tab.
- `knots/widgets.zig`, `bind.zig`, `style.zig`: layout pieces, setting-bound controls, styles.
- `knots/hotkey.zig`: recording field; pauses live hotkeys while recording. Draws its key caps compact when full size would overrun the room `widgets.controlsRoom` reports beside the row's label. Finds conflicting combos and names their holders, using `labels.zig`'s hotkey labels.
- `tools/region_select.zig`: full-screen overlay for drawing a thumbnail space; math in `region_math.zig`.
- `tools/esi_prices.zig`: Jita ore prices. `tools/ultra_potato.zig`: patches EVE's graphics YAML.
- `run_on_startup.zig`: the Run registry key.

## Module dependencies

- Direct calls, no event bus. Code is handed `*App` or just what it needs.
- Win32 callbacks have no context pointer: window procs and hooks read `app.g_app` (or `app.currentThumbnailSet()`) and pass it down. Modules below them never read the global. Scout keeps a private pointer for its own hooks so it stays testable.
- The dialog reaches the app through `session.runningApp()`.
- `platform/` depends on nothing app-specific. Win32 declarations live in `platform/win32.zig`, which never logs.
- Pure logic is split into its own file (marked "no I/O" in its header) and tested.

## Other modules

| Module | Role |
|---|---|
| `log.zig` | Buffered rotating file log, `Scoped(name)`, debug console |
| `crash.zig` | Exception handlers, panic handler, minidump |
| `tray.zig` | Tray icon and menu |
| `update.zig` | GitHub release check |
| `lang/` | UI strings by English key, per-language JSON |
| `barrage/` | Barrage, the artillery game behind About's wordmark: rules, terrain and AI (`game.zig`), players' messages (`messages.zig`); drawn by `dialog/knots/barrage.zig` and `barrage_tanks.zig` |
| `multiplayer/` | Anonymous games by join code, up to six players: relay notices and codes (`wire.zig`), relay connection thread (`link.zig`); relay Worker in `tools/game-relay/` |
| `platform/fonts.zig` | Bundled Cascadia and Geist, registered process-private |
| `platform/virtual_keys.zig` | VK codes, `KEY_NAMES`, mouse-chord encoding |
| `platform/wic.zig` | Image decoding (portraits) |
| `util/` | Colour (OKLab picks), number format, HTTP and WebSocket (WinHTTP, with timeouts), schedule, strings |
