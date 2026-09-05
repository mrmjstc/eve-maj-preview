# Architecture

A map of how the ~20k lines in `src/` fit together. This covers module responsibilities, ownership, threading, and control flow - not configuration (see [CONFIGURATION.md](CONFIGURATION.md)) or the build (see [BUILDING.md](BUILDING.md)).

Line numbers are call-outs to orient you, not guarantees - they will drift as the code changes.

## Two binaries, one `src/`

`build.zig` defines two independent executables that both compile against the same `src/` tree:

- **`eve-maj-preview.exe`** - entry point `main.zig`, the actual thumbnail/hotkey/notification app.
- **`config.exe`** - entry point `config_dialog.zig`, a [zig-webui](https://github.com/webui-dev/zig-webui) window around embedded `config_dialog.html/css/js` for editing profile JSON without hand-editing files.

They are not spawned from a shared root - `config.exe` is launched as a child process via `ShellExecuteA` when the user opens it from the tray menu (`tray.zig` `openConfigDialog`). Once running, the two processes are independent and talk only over Win32 IPC: `config_dialog.zig` locates the running main app with `FindWindowA` against the timer window's class name (`"EVE_TIMER_CLASS"`), then sends commands via `WM_COPYDATA`/`WM_PROTOCOL_HOTKEY` (see [protocol.zig](#protocolzig-and-cross-process-control)). This is how live profile switching and live thumbnail-appearance preview from the config dialog reach the running app.

Both binaries import `config.zig` as a shared model layer for profile JSON - neither owns it.

## Startup (`main.zig`)

`main()` → `mainImpl()` does, in order:

1. Install crash handling: vectored exception handler, unhandled exception filter, a `panic` override that writes to `eve-maj.log`, and minidump support.
2. Check for `--protocol <url>` **before** the single-instance check, so protocol commands work even when another instance is already running - see [protocol.zig](#protocolzig-and-cross-process-control).
3. Acquire a named mutex (`Global\EVE-Maj-Preview-SingleInstance`) to enforce single instance.
4. Load `GlobalSettings`, then the per-profile `Config` (default or `--profile`/`-p`).
5. Auto-register the `evemajpreview://` protocol handler if configured.
6. Construct subsystems in dependency order: `Scout` → `Painter` → `ChatlogMonitor` → `CombatTracker`/`MiningTracker` (wired into the monitor) → **then** start the chatlog worker thread, only once the trackers exist for it to feed.
7. Register the hidden timer window (`WndProc` = `timerWindowProc`), `TrayIcon`, and a detached background thread for `UpdateChecker`.
8. Initial window scan and thumbnail creation, `HotkeyManager` setup, `SetTimer` at `config.timer.scanIntervalMs`.
9. Enter the classic `GetMessageA`/`TranslateMessage`/`DispatchMessageA` loop.

`timerWindowProc` is the app's central message dispatcher: tray clicks, `WM_TIMER` (→ `onTimerTick`, see below), `WM_HOTKEY`, profile switches, and incoming `WM_COPYDATA` from `config.exe` or a second CLI invocation.

## The central state owner: `Painter`, not `state.zig`

Despite the name, `state.zig` is not an app-state struct - it's ~70 lines defining two enums (`VisibilityState`, `ThumbnailState`) plus the legal-transition helpers (`transitionVisibility`/`tryTransitionVisibility`) that enforce them for `VisibilityState`; `ThumbnailState` is a plain style-lookup key with no transition logic of its own (see `ThumbnailWindow.effectiveRenderState` below). Likewise `manager.zig` is just a handful of standalone window actions (`minimizeAllClients`, `closeAllClients`, `moveAllClientsToSavedPositions`, `moveClientToPosition`) - it holds no state and is not a main-loop orchestrator.

The actual central mutable-state owner is **`Painter`** (`painter.zig`, 3700+ lines - the largest file in the project). It owns:

- The thumbnail collection: `thumbnails: ArrayList(ThumbnailWindow)` plus HWND→index hashmaps for O(1) lookup.
- The full thumbnail lifecycle: `createThumbnail`, `destroyThumbnailResources`, `cleanupClosedThumbnails`.
- Per-tick reconciliation of scan results into thumbnail state: `update()`.
- Notifications, including triggering TTS: `showNotification`, `updateNotifications`.
- Travel Mode's left-behind detection: `checkTravelLeftBehind`, called on a throttled ~2s cadence from `onTimerTick`. Compares each `ThumbnailWindow.system_name` (not jump-timestamp order) to find the group's current system, so a straggler who catches up is never mistakenly flagged just because their jump landed last - see [CONFIGURATION.md](CONFIGURATION.md#travel-mode).
- Actual pixel rendering: `renderThumbnail` (diffs cached `RenderSettings` to skip redundant redraws) → `renderThumbnailOverlay` → a family of private GDI-drawing helpers (`drawBorder`, `drawExclusionOverlay`, `drawSparkLine`, `renderText`, ...) that make up roughly the other third of the file.
- DPS/mining chart data feeding into the overlay, and drag-snap "ghost group" preview overlays.

Each tracked character is a `ThumbnailWindow`: `hwnd`/`text_hwnd`/`thumbnail_id`, `source_hwnd`, cached display strings/colors, `visibility_state`, and the `cached_render_settings` used for render skipping. Its render state (Active/Inactive/Alert/Minimized/Dragging) isn't stored - `effectiveRenderState()` derives it live on each render from focus (`Painter.active_source_hwnd`), `isWindowIconic`, active notifications, and drag state. In `ClientList`/`Nothing` view modes, `hwnd`/`text_hwnd` are sentinel values rather than real windows - see [list_view.zig](#other-subsystems).

## Window discovery → rendering pipeline

**`scout.zig`**'s `Scout` owns discovery. `scanForEveWindows()` drives `EnumWindows`, filtering each window by class name against `config.windowFilters` (cheap pre-filter) before checking the process executable path (cached per-PID). `trinityWindow`-class windows get a character name parsed from the title; other filters use their configured `name`. Three `SetWinEventHook`s (`EVENT_OBJECT_NAMECHANGE`/`CREATE`/`DESTROY`) catch window lifecycle events between polls; `Scout.update()` reconciles these with the periodic full rescan.

Rendering is split three ways:

- **`win32.zig`** - Win32 constants, `extern` declarations (including the `DwmRegisterThumbnail`/`DwmUpdateThumbnailProperties` family), struct layouts, plus small helpers built directly on those bindings with no app-specific knowledge (window title/class/exe-path lookups, `shellOpen`, the COM `showFolderPicker`). No EVE- or config-aware logic.
- **`painter.zig`** - the DWM integration and orchestration (above). `createThumbnail()` creates a borderless layered popup window, calls `DwmRegisterThumbnail` to bind the EVE client's live DWM thumbnail into it, then creates a *second* layered window stacked on top for GDI-drawn overlay content (border, text, notifications). Each visible thumbnail is therefore two HWNDs, not one.
- **`gdi_overlay.zig`** - the shared GDI leaf module: `OverlayBitmap` (a top-down DIBSection selected into a memory DC), alpha-fixup helpers for GDI text output, pixel-buffer `fillRect`, buffer-truncating `toBufZ`, and `registerWindowClass` (the common `WNDCLASSEXA` registration boilerplate). Used by `painter.zig`, `list_view.zig`, `notif_info_view.zig`, and `main.zig`.

## Log monitoring and activity tracking

**`chatlog.zig`**'s `ChatlogMonitor` matches the threading model documented in [CONFIGURATION.md](CONFIGURATION.md#chatlog-monitoring): when `useThreading` is enabled (default), a dedicated worker thread owns all file I/O (`workerThreadMain` → `processCommands`/`pollLogFiles`/`checkNewLogFiles`), decoupled from the main thread by three mutex-guarded `EventQueue(T)` instances - `command_queue` (main → worker), `result_queue` and `notification_queue` (worker → main). The main-thread side of `ChatlogMonitor.update()` only pushes add/remove-character commands and drains the two result queues - explicitly the only point where worker-thread output touches `Painter`/`Scout`. With threading disabled, `update()` instead polls synchronously inline on the main thread under a small time budget.

**`activity_tracker.zig`** is the DPS/mining-rate math, fed by log lines parsed on the chatlog worker thread. `CombatWindow`/`MiningWindow` are fixed-capacity ring buffers (no heap allocation after init) computing trailing-window sums and per-bucket spark-chart data. Both trackers are explicitly cross-thread: the chatlog worker calls `addEntry`/`removeCharacter` while the main thread calls `refreshAll`/`getDps`/`getRate`, serialized by each tracker's own mutex.

**`resource_tracker.zig`**'s `ResourceTracker` is unrelated to the chatlog pipeline above - it samples per-process CPU%/RAM/VRAM directly from the OS (`GetProcessTimes`, `GetProcessMemoryInfo`, and a PDH "GPU Process Memory" query for VRAM), keyed by `scout.EveWindow.process_id`. Main-thread only, no locking: `main.zig`'s `onTimerTick` calls `sampleAll` on its own throttled interval (`config.resources.update_interval_ms`) and pushes the result into `Painter.updateResourceStatsForCharacter`, the same push-then-`processDirtyDpsOverlays` shape combat/mining/bounty use, just without their cross-thread queue. See [CONFIGURATION.md](CONFIGURATION.md#resource-usage-overlay).

## Input & control surfaces

- **`hotkeys.zig`** - `HotkeyManager` owns a single `hotkey_map: AutoHashMap(c_int, HotkeyAction)`. Hotkey IDs are banded by range (cycle-groups, global actions, per-character, profile-switch, quick-groups) so a single `WM_HOTKEY` ID reverse-maps to an action. `handleHotkeyPress()` is the one dispatch point, gating on suspend/focus-requirement state before switching on the `HotkeyAction` union. It also owns a `WH_KEYBOARD_LL` hook that swallows a hotkey's key-up after a successful cycle action, mirroring `mouse_hook.zig`'s hook-lifecycle shape.
- **`mouse_hook.zig`** - a `WH_MOUSE_LL` hook mapping mouse-button chords to hotkey IDs and re-posting them as synthetic `WM_HOTKEY` messages, so `hotkeys.zig` doesn't need a separate input path for mouse buttons.
- **`input.zig`** - client activation (`handleThumbnailClick` - restore, foreground, dismiss suppressible notifications, reconcile focus state), shift-click exclusion toggling, and the thumbnail/text-window `WndProc`s (drag, edge/thumbnail/ghost-position snapping).
- **`protocol.zig` and cross-process control** - parses `evemajpreview://action/params` URLs, handles registry registration/unregistration, and implements the actual IPC transport (`sendCommandToInstance`, `findExistingInstance`) used both by external protocol invocations and by `config.exe`.

**Call chain, hotkey press → character switch:**
`WM_HOTKEY` → `timerWindowProc` → `HotkeyManager.handleHotkeyPress` → an action handler (`cycleGroup`, `activatePerCharacterGroup`, `cycleExcluded`, `cycleNotified`, ...) → `Scout.getHwndByName` → `input.handleThumbnailClick` → `SetForegroundWindow`/`BringWindowToTop`.

**Call chain, protocol URL → character switch:**
second process invocation with `--protocol "evemajpreview://switch/Name"` → `protocol.parseUrl` + `findExistingInstance` + `sendCommandToInstance` → running instance's `timerWindowProc` receives `WM_COPYDATA` → `Scout.getHwndByName` → `input.handleThumbnailClick` (same tail as above).

## `config.zig`

Not just JSON schema - it's the shared model layer with both a wire format and runtime logic:

- Most config sub-structs (`ThumbnailConfig`, `ChatlogConfig`, `CharacterConfig`, ...) pair a runtime struct with a `.Wire` struct and `toWire()`/`fromWire()` methods, since the runtime shape isn't always the JSON shape (e.g. hotkeys are raw `?u32` at runtime, a serializable `VkCode` wrapper on disk).
- Two independent settings layers: `GlobalSettings` (`profiles/global.settings.json` - last-used profile, cross-profile hotkeys, log level) and per-profile `Config` (`profiles/<name>.json`).
- Runtime helper methods beyond parsing: per-character overrides (`getCharacterSize`, `isExcludedFromMinimize`, ...), lazily-generated and cached system/character colors (not persisted back to JSON), `validate()` clamping, and the position-save family that read-modify-writes the profile JSON when a thumbnail is dragged.
- Partial-parsing entry points (`parseJsonThumbnailConfig`, `applyCharacterOverridesFromJson`, ...) used by the live-preview path from `config.exe`.

`config_dialog.zig` imports `config.zig` the same way `main.zig` does - there's no dependency in the other direction.

## Threading model

Four threads, total:

1. **Main thread** - the Win32 message loop, all window procs, all `SetWinEventHook`/low-level keyboard/mouse hook callbacks (Win32 delivers these to the installing thread), and `onTimerTick` (see below).
2. **Chatlog worker thread** (`chatlog.zig`, opt-out via `useThreading: false`) - log file I/O and parsing, communicating through the three `EventQueue(T)` queues.
3. **TTS worker thread** (`tts.zig`) - a lazily-started, persistent STA-COM thread draining a mutex-guarded command queue, so `Speak()` never blocks the caller.
4. **Update-check thread** - one-shot, detached, writes into a mutex-guarded global `UpdateStatus` that the tray menu reads.
5. **Clipboard-upload thread** (`paste_upload.zig`) - one-shot, detached, spawned when a URL hotkey with `uploadClipboard` set is pressed; POSTs the clipboard to the target URL and opens the page it redirects to.

Inter-module communication is predominantly **direct calls on shared global pointers**, not an event bus: `main.zig` holds module-level globals (`g_scout`, `g_painter`, `g_hotkey_manager`, `g_chatlog_monitor`, ...), and other modules mirror this with their own optional global pointers set during init (`painter.g_painter_ptr`, `scout.g_scout_ptr`) so OS callbacks - which can't carry a `self` pointer through the Win32 callback ABI - can reach the live instances. A couple of function-pointer fields exist purely to break compile-time circular imports (`list_view.g_activate_fn`, set by `Painter.init` so `list_view.zig` can call into `input.zig` without importing it). The closest thing to real message passing is the chatlog event queues (cross-thread) and Win32 messages themselves, used both for same-process signaling (tray → main loop) and cross-process IPC (`config.exe` → main app).

## The tick

`main.zig`'s `onTimerTick()`, fired by `WM_TIMER` at `config.timer.scanIntervalMs`, is the one driver every subsystem update cascades from, in fixed order:

```
Scout.update()                    window discovery / lifecycle reconciliation
  -> Painter.update()             sync scan results into thumbnail state
  -> Painter.updateNotifications()
  -> ChatlogMonitor.update()      queue commands / drain result+notification queues
  -> CombatTracker/MiningTracker.refreshAll()
       -> throttled push into Painter (own update_interval_ms, independent of scan cadence)
```

The expensive full `EnumWindows` rescan is itself throttled to roughly every 20 ticks rather than running every tick.

## Other subsystems

- **`tray.zig`** - system tray icon, right-click menu (profiles, dragging/auto-minimize/visibility/suspend-hotkeys toggles, Close All, update notice), launches `config.exe`.
- **`tts.zig`** - Windows SAPI via late-bound `IDispatch::Invoke` on its own STA-COM thread; `speakAlert()` is the fire-and-forget public API.
- **`update.zig`** - checks GitHub Releases via `std.http.Client` on a background thread, run independently by both `main.zig` and `config_dialog.zig` since they're separate processes, each with its own `UpdateStatus`; opens the release page in a browser.
- **`paste_upload.zig`** - a URL hotkey's optional clipboard-upload path: POSTs the clipboard as form data to the target URL via `std.http.Client`, relies on the client's default redirect handling to land on the created paste's page (the standard Post/Redirect/Get pattern), then opens that page in a browser.
- **`list_view.zig`** - the compact `ClientList` view mode: a single custom-drawn panel (badge/name/system/notification per row) as an alternative to per-window DWM thumbnails, wired to `input.zig` via function pointers to avoid a circular import.
- **`notif_info_view.zig`** - the History Panel: an always-available, resizable panel (`display.showNotifInfoPanel`/`notifInfoPanelWidth`/`notifInfoPanelHeight`, independent of `viewMode`), structurally a near-twin of `list_view.zig`: notification history (newest-first, click a row to jump to that character), each row colored by the notifying character's name color and that notification type's configured text color. History lives in a fixed-capacity ring buffer on `Painter` (`notification_history`, pushed from `showNotification`).
- **`color.zig`** - color math (`hsvToRgb` and related) behind the auto-generated system/character name colors.
- **`log.zig`** - the app's own file logger: buffered, size-rotated (`eve-maj.log`/`.old`, 5MB cap), a `scoped(name)` factory, mutex-guarded so it's safe to call from the crash handler.
- **`types.zig`** - shared enums with no owning struct (`BorderStyle`, `TextPosition`, `NotificationType`, `LayoutMode`, ...), imported by nearly every module.
- **`virtual_keys.zig`** - VK constants plus the hotkey string parser/formatter, including the convention for encoding mouse-button chords into the same `u32` ID space as keyboard VKs.
