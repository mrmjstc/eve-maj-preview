# Architecture

How `src/` fits together. For related docs, see [CONFIGURATION.md](CONFIGURATION.md) (settings), [BUILDING.md](BUILDING.md) (build steps), and [STYLE.md](STYLE.md) (code style).

## Overview

- One executable, `eve-maj-preview.exe` (`src/main.zig`), built for the Windows subsystem. A console opens only when the log level is `debug`.
- The configuration window runs in-process on the main thread using `knots` and Vulkan. `zig build config` launches the app with `--config`.
- `zig build test` runs `src/tests.zig` (Debug build), which imports every tested module. `zig build check` type-checks the app and the simulator without emitting a binary; ZLS runs it on save. End-to-end tests live in `tools/ui_tests/`.
- `knots` is vendored in `deps/knots/`. Local changes are marked `EVE-Maj patch` and listed in `deps/knots/PATCHES.md`.

## Files on disk

All paths are relative to the exe folder (`main.zig` sets the working directory there at startup).

| Path | Contents | Owner |
|---|---|---|
| `profiles/<name>.json` | Per-profile `Config` | `config/profiles.zig` |
| `profiles/global.settings.json` | Cross-profile `GlobalConfig` | `config/global.zig` |
| `profiles/backup/` | Profiles deleted, reset, imported over, unreadable, or backed up from the Backups tab (`<unix time>_<name>`) | `config/profiles.zig` |
| `data/colors.json` | Generated system and character colours | `clients/auto_colors.zig` |
| `data/character_ids.json` | Character name → EVE ID | `chatlog/character_ids.zig` |
| `data/portraits/{id}.jpg` | Character portraits | `dialog/knots/portraits.zig` |
| `data/logo_colors.json` | Colour picked from each sov-holding alliance's logo. Holds up to 200; once full it's emptied and refilled, since old entries are mostly alliances long gone | `map/stats_feed.zig` |
| `logs/eve-maj.log`, `.old` | Log, rotated at 20 MB | `log.zig` |
| `logs/eve-maj-crash.dmp` | Minidump of the latest crash | `crash.zig` |

### File safety and migration

- At startup, `config/files.zig`'s `migrateLegacyLayout` moves files that older versions kept beside the exe into `data/` and `logs/`. It never replaces a file already there.
- Every save writes `<file>.<hex>.tmp` and renames it over the file (`util/atomic_file.zig`), so a crash mid-save never leaves a half-written file.
- Also at startup, once this is the only instance, `sweepTempFiles` deletes `.tmp` files a killed process left behind in `profiles/`, `data/` and `data/portraits/`.

## Startup and teardown (`main.zig`)

### Startup sequence

1. **Process setup:** Set per-monitor DPI awareness and install crash and panic handlers (`crash.zig`).
2. **Working directory:** Set it to the exe's folder and move files from older layouts (see [File safety and migration](#file-safety-and-migration)).
3. **Arguments:** Parse `--profile` / `-p`, `--config` and `--protocol <url>` (`arguments.zig`).
4. **Protocol forwarding:** With `--protocol`, forward the URL to the running instance over `WM_COPYDATA` and exit. Runs before the single-instance check, so links work while the app is running.
5. **Single instance:** Claim the `Global\EVE-Maj-Preview-SingleInstance` mutex. If it's taken, wait for the running instance's window, send it `evemajpreview://config` so its settings open, and exit. Only after this are unknown arguments rejected, so a second launch with bad arguments still brings up the running instance.
6. **Environment and stores:**
   - Sweep leftover `.tmp` files, skipped if the working directory couldn't be set to the exe's folder.
   - Load bundled fonts (`platform/fonts.zig`) and start the hotkey hook thread (`hotkeys/hook_thread.zig`).
   - Load `GlobalConfig` and apply it through `app.applyGlobalSettings`: log level, debug console, Run key and protocol handler. The same call runs again after each Save.
   - Load `CharacterIds` and the profile into a `ProfileStore`, which `App.init` takes as `App.Loaded`.
   - Set `app.g_app`, start the dialog host (`dialog/knots/host.zig`) and load the UI language (`lang/`).
7. **Subsystems:**
   - Create the hidden timer window and hand it to `App.start`, which does the rest of this step.
   - Start `NotificationCenter`, `MapPanel`, `Scout`'s event hooks, the focus hook and the tray icon.
   - Run `restart.run` from nothing running: scan windows, build the `ThumbnailSet`, create and wire `ChatlogMonitor` and `Trackers`, start the chatlog worker, create the `HotkeyManager` and start the tick timer.
   - Queue the character-ID backfill, and move clients if `moveOnStartup` is on.
8. **Background services:** Install the focus grant (`platform/focus_grant.zig`) and start the update check thread (`update.zig`) unless update checks are disabled.
9. **Message loop:** With `--config`, open the configuration window, then run the `GetMessageA` loop until the app quits.

### Teardown sequence

`main.zig`'s `defer`s run in reverse order of registration:

1. **Process-wide services:** Uninstall the focus grant, shut down the sound and TTS workers, then wait for one-shot threads (see [Worker lifecycles and limits](#worker-lifecycles-and-limits)).
2. **Dialog host:** `knots_host.deinit` runs before `App.deinit`, while the store it edits still lives.
3. **`App.deinit`:** Tears down everything `App` owns, the `ProfileStore` included, freeing each part before anything it borrows from. Also copes with a startup that failed partway.
4. **`app.g_app`:** Set to null after `App.deinit`. Window procs and hooks that fire after this see null and do nothing.
5. **Hook thread:** Stopped last, since `App.deinit` unregisters the hotkey manager's hooks through it.

## `App` and lifecycle (`app.zig`)

`App` owns every long-lived subsystem. Main thread only.

| Field(s) | Lifetime |
|---|---|
| `store` (`ProfileStore`), `global_settings`, `character_ids`, `scout`, `focus`, `trackers`, `tray_icon`, and in `persistent` (`Persistent`): `roster`, `auto_colors` (`AutoColorStore`), `exclusions`, `auto_move` (`AutoMoveVerifier`), `notifications` (`NotificationCenter`), `intel` (`Intel`), `map_panel` (`MapPanel`) | Whole run, across profile switches and Saves. `store` itself is replaced on a profile switch. |
| `persistent.auto_minimizer` | Whole run; reset when a different profile loads, restarting each client's idle delay. |
| `rebuilt.hotkey_manager` | Rebuilt by `restart.run` on every reload. |
| `cycle` | Each cycle hotkey's position; reset whenever the hotkey manager is rebuilt. |
| `rebuilt.thumbnail_set` | Rebuilt on a profile switch or view-mode change. A Save keeps it and only refills it, since the dialog has already previewed the changes and a rebuild would make every thumbnail flash. |
| `rebuilt.chatlog_monitor` | Kept across reloads, paused while they run. Rebuilt only when the log folders change, and destroyed when log monitoring is turned off. |
| `rebuilt.list_window` | Built and torn down with `thumbnail_set`; `ClientList` and `ThumbnailsAndList` modes only. |

### Invariants

- Rebuilt subsystems are read from `App` each time, never cached elsewhere.
- State that must survive a rebuild lives on `App`: cycle exclusions, notification history, the auto-minimize toggle (an override on `auto_minimizer`).
- Every user command, whether from a hotkey, the tray or a protocol link, runs through `App.commands()` (`hotkeys/commands.zig`).
  - `Commands` holds pointers into `App` rather than living on the `HotkeyManager`. The manager is rebuilt on each Save and profile switch, so tray and protocol commands don't depend on it existing.
  - A command is given the current `ThumbnailSet` and returns an `Outcome`: activate a client, switch profile, toggle a panel, or return to the last app. `App.runHotkeyOutcome` then carries it out.
- `ThumbnailSet` borrows only the store, exclusions, auto colours and roster (`ThumbnailSet.Borrowed`). `App` passes in its window procs and destroy hook, so `thumbnail/` imports no input or panel code.

### Reload entry points

| Call | Trigger | Effect |
|---|---|---|
| `requestProfileSwitch` → `WM_SWITCH_PROFILE` → `switchProfile` | Tray, hotkey | Deferred to the next message-loop turn, since the switch tears down subsystems such as the hotkey manager, which may be the caller still running. |
| `switchProfile` | Protocol link, dialog | Loads the profile into a new store, then runs `restart.run`. |
| `saveSettings` (`DIALOG_HOST.save`) | Dialog Save | Commits `live` → `saved` on the same store, runs `restart.run` adopting a copy of the global draft, then writes and applies `GlobalConfig`. Does nothing if neither the profile nor the global settings changed. |
| `onLiveProfileEdited` (`DIALOG_HOST.run`) | Every dialog edit | Restyles and reflows; rebuilds the `ThumbnailSet` only on a view-mode change. |

`restart.run` (`control/restart.zig`) runs both at startup and on every reload. It follows the steps `control/restart_plan.zig` (pure, tested) lays out: which subsystems are kept, paused or rebuilt, in what order, and what to bring back up if a step fails.

- If the chatlog worker is kept, it's paused while the new trackers are wired in and it's given the new profile's chat-alert rules (the `apply_monitor_profile` step), then resumed.
- A new `ProfileStore` is built before anything is torn down, so a load failure leaves the running profile intact.

## Main thread messages (`messages.zig`)

`timerWindowProc` (`main.zig`) is the central dispatcher. `messages.zig` defines the app's own `WM_*` messages and timer IDs and checks they're unique, so `platform/win32.zig` keeps only Windows' own.

| Message / timer | Handler |
|---|---|
| `WM_TIMER` (`TICK_TIMER_ID`) | `App.tick`. |
| `WM_TIMER` (`HIDE_DEBOUNCE_TIMER_ID`) | `focus.onHideTimer`: hides thumbnails after focus leaves EVE. |
| `WM_HOTKEY` | `focus_grant.handleWmHotkey` first; otherwise `HotkeyManager.handleHotkeyPress` → `Commands` → `App.runHotkeyOutcome`. |
| `WM_TRAYICON`, `WM_COMMAND` | `TrayIcon` (`tray.zig`). |
| `TaskbarCreated` (registered) | `TrayIcon.handleTaskbarCreated`: re-adds the icon after Explorer restarts; the tick also retries a missing one every 5 s. |
| `WM_COPYDATA` | `protocol/run.handleCopyData`: `evemajpreview://` URLs from a second process. |
| `WM_SWITCH_PROFILE` | `App.runPendingProfileSwitch`. |
| `WM_HOTKEYS_STATE_CHANGED` | Raises the "hotkeys suspended" or "resumed" notification. |
| `WM_WIN_KEY_CAPTURED` | `keyboard_hook.onWinKeyCaptured`: a bare Win press the dialog is recording. |
| `WM_KNOTS_COMMAND` | `dialog/knots/host.onCommand`: dialog work that replaces documents or touches the app, run between frames. |
| `WM_ENDSESSION` | `App.saveBeforeAbruptExit`: writes pending auto colours and log lines, since Windows may end the process once it returns. |

`messages.zig` also defines `WM_HOOK_REQUEST`, which goes to the hook thread rather than the timer window (see [Cross-thread data](#cross-thread-data)).

## The tick (`App.tick`)

Driven by `WM_TIMER` at `timer.scanIntervalMs`, slowing to every 1 s while no EVE window is tracked and the dialog is closed (never while the state file is on, as the end-to-end tests wait on it).

Work that runs less often than every tick (every 2 s, every 15 min, ...) is timed by `util/schedule.zig`. Each interval is measured from the start of the tick that ran it, and the work runs on whichever tick lands nearest the due time rather than the first one past it. Timer ticks often arrive a few ms early, which would otherwise push the work back a whole tick.

```text
1. TrayIcon.retryIfMissing          re-add a missing tray icon, at most every 5 s
2. alert_effects.releaseUnused      on full-scan ticks only: stop audio threads no alert uses
3. Scout.update(force_scan)         hook events, plus a full EnumWindows at least once a second
4. Roster.sync / refreshConfig / setActive
                                    mirror Scout's windows, read new names' settings, record the foreground window
5. followNewClients                 auto-move clients that joined or logged in, start new ones minimized, verify pending moves
6. syncTaskbarMarks                 mark clients so the taskbar hides over them (hideTaskbarOverClients): all on a setting change or Explorer restart, else new ones
7. auto_colors.flush                save generated colours, once no client is left
8. clearLoggedOutExclusions         drop cycle exclusions of clients that logged out
9. dialog redraw                    after a login, logout or close, so the Characters tab is current
10. HotkeyManager.syncFocusFilter   tell the hook thread which windows are EVE, for requireEveFocus
11. hook_bindings.logFailedPosts    log WM_HOTKEY posts the hook thread couldn't make
12. focus.afterActiveRefresh        record focus, resync cycle cursors
13. Roster.expireAlerts             drop expired alerts; flashing ones redraw
14. Roster.refreshMinimized         each client's minimized state, skipping the dragged one
15. ThumbnailSet.updateConnections  the thumbnails' connection maps, from the intel pins
16. ThumbnailSet.update             create, destroy or rename thumbnails to match the roster
17. ThumbnailSet.checkHoverZoom     enlarged preview under the cursor
18. redrawDialogIfThumbnailsMoved   while the dialog is open, so the Placement tab's map follows the thumbnails
19. ListWindow.render               the client list, when shown
20. AutoMinimizer.check             minimize idle clients on the roster
21. ChatlogMonitor.update + drain   findings to Roster (systems), Intel (pins), Notifier (alerts) and Scout
22. MapPanel.update                 take new feed snapshots, render the map
23. NotificationCenter.update       History and Intel panels, after the chatlog so they list this tick's alerts
24. Trackers.tick                   throttled push of rates and resources onto the roster; alerts via Notifier
25. travel_left_behind.check        every 2 s
26. adjust tick interval            active scan rate, or the 1 s idle rate
27. publishState                    rewrite the state file when it changed; only when EVE_MAJ_STATE_FILE is set
```

`tick` runs steps 4–12 as `discoverWindows`, 13–20 as `updateThumbnails`, 21 as `ingestLogs`, 22–25 as `updatePanels` and 26 as `scheduleNextTick`.

## Threads and concurrency

| Thread | Module | Talks to main via |
|---|---|---|
| Main | `main.zig` (message loop, window procs, WinEvent hooks, tick, config window) | — |
| Hotkey hooks | `hotkeys/hook_thread.zig` (`WH_KEYBOARD_LL` / `WH_MOUSE_LL`, time-critical priority) | Posts `WM_HOTKEY` and `WM_WIN_KEY_CAPTURED`; main changes bindings through `hook_thread.call`. |
| Chatlog worker | `chatlog.zig` | Mutex-guarded queues in `chatlog/queue.zig`. |
| TTS worker | `notifications/tts.zig` (STA COM, SAPI) | Fire-and-forget command queue (`notifications/worker.zig`). |
| Sound worker | `notifications/sound.zig` (Media Foundation + `waveOut`) | Fire-and-forget command queue (`notifications/worker.zig`). |
| Update check | `update.zig` (one-shot at startup and each time the dialog opens) | Mutex-guarded `UpdateStatus`. |
| Clipboard upload | `hotkeys/paste_upload.zig` (one per press, at most 4 at once) | None; slots claimed through atomics. |
| Dialog helpers | `pickers.zig`, `prices.zig`, `portraits.zig` (one-shot) | A `util/handoff.zig` `Stack`, then a `WM_KNOTS_COMMAND` carrying no pointer. |
| Map stats | `map/stats_feed.zig` (one-shot every 15 min while the Map Panel shows; then fetches logos of alliances it hasn't seen) | Atomic snapshot and logo-colour swaps, taken on the tick. |
| Eve Stars calls | `map/evestars_feed.zig` (one-shot per request: character list, send destination, route plan, Ansiblex list, avoid list read or change; at most one of each kind in flight) | Atomic reply swap, taken on the tick or the panel's 100 ms timer. |
| Eve Stars activity | `map/activity_feed.zig` (one-shot every 10 min for the kill and jump totals over the picked span; see [Map data and feeds](#map-data-and-feeds-map) for a second, NPC-kill fetch) | Atomic pointer swaps, taken on the tick or the panel's 100 ms timer. |
| Live sov campaigns | `map/campaigns_feed.zig` (one-shot every 10 s while a running sov timer is listed for the shown regions) | Atomic campaigns swap, laid over the stats snapshot on the tick. |
| zKillboard feed | `map/zkill_feed.zig` (one-shot runs while the Map Panel shows kills; see [Map data and feeds](#map-data-and-feeds-map)) | Atomic batch swap, taken on the tick. The read position and requested IDs belong to the running run, or to main between runs. |

The dialog helpers and map feeds all hand results over through `util/handoff.zig`: a `Job` (one run at a time, newest result kept) or `Slot` for a feed, a `Stack` for the dialog helpers. All are lock-free atomic swaps, so neither thread waits on the other.

### Worker lifecycles and limits

- **Audio workers:** TTS and sound share `notifications/worker.zig`'s `Worker`. Each thread starts with the first alert that needs it and sleeps on an event while idle.
  - Once a second, `alert_effects.releaseUnused` checks the profile with `rules.hasAudibleAlert`. If no alert would still speak (or play a sound), the speech (or sound) thread is stopped along with its engine, provided it has nothing queued.
  - `pushAlert` drops the oldest waiting alerts past a limit (`tts_max_waiting` for speech, 3 for sound), minor alerts first.
  - `push` (voice settings) is never dropped.
- **One-shot threads:** Started through `util/detached.zig`, which counts them. At exit `main.zig` waits up to 2 s for them; if any are still running, it saves with `App.saveBeforeAbruptExit` and ends the process rather than freeing state they still hold.

### Cross-thread data

- Chatlog: `commands` (main → worker); `system_updates`, `notifications`, `session_starts`, `intel_sightings` (worker → main). Every other `ChatlogMonitor` field, its `Interpreter` included, is owned by one thread.
- `activity/tracker.zig` trackers: written by the worker, read by main, each under its own mutex.
- `CharacterIds` locks its own map.
- Hook bindings, held presses and the `requireEveFocus` filter: hook thread only. Main changes them through `hook_thread.call`, which posts the change to the hook thread as `WM_HOOK_REQUEST`, runs it there and waits for it to finish.
  - The hook thread never logs while a hook is installed: waiting on the log lock could stall it past `LowLevelHooksTimeout`, and Windows would silently drop the hook. Changes report their outcome for main to log, and failed `WM_HOTKEY` posts are counted for `App.tick` to log.
- The worker reads `GlobalConfig` ore prices, so new global settings are adopted only while it's stopped.

## Window discovery, thumbnails and overlays

### Discovery and roster

- **`clients/scout.zig` (`Scout`):** finds client windows with `EnumWindows`, keeping visible ones that match a `windowFilters` entry. The class name is checked first, and the exe path only for windows not already tracked, since opening the process is far slower.
  - An EVE window (class `trinityWindow`) takes its character name from the title, `EVE - <name>`. Any other window a filter matches (`is_eve_client` false) is named after the filter, since its title isn't a stable identity.
  - Per-process `EVENT_OBJECT_NAMECHANGE` and `EVENT_OBJECT_DESTROY` hooks catch logins, logouts and closes between scans.
  - The destroy hook only records the hwnd; `Scout.update()` drops it before handing out the window list, so the slice a tick borrows never changes under it.
  - No creation hook: it would fire for every window on the desktop.
- **`clients/roster.zig` (`Roster`, tested):** One `Client` record per tracked window, kept for the whole run. `Roster.sync` mirrors `Scout` once per tick and is the only place clients are added or removed.
  - **Holds, per client:**
    - Identity: an owned copy of the character name, the login time, and the display name, character colour and minimize exclusion read from the profile.
    - Location: the current system and Travel Mode's jumps. Only `updateSystem` writes the system, and it ignores log events older than the one it has. The system is cleared at logout and when log monitoring is turned off.
    - Window state: minimized or not, when it went idle, and when a click last brought it forward.
    - Readings: combat, mining and bounty figures.
    - Alerts: the ones on screen and their throttle.
    - `last_sync`: whether the last sync saw it join or log in.
    - `revision`: bumped on every change a view displays, so views can tell when to redraw.
  - **Roster-wide:** `active_hwnd`, the foreground EVE window, written only by `setActive`.
  - **Read by:** `Notifier`, Travel Mode, `AutoMinimizer`, `FocusTracker`, the membership hotkeys, the client list, the Map Panel's marks (`panel_host.Host.roster`), the Intel Panel's nearest client, and each thumbnail at render (`readingsOf`).
  - **Survives rebuilds:** The roster lives on `App`, so a `ThumbnailSet` rebuild or profile switch loses no client state and needs nothing copied over. Each thumbnail copies its client's system name from the roster when the `revision` changes and the text differs.
  - **Exclusions:** Cycle exclusions aren't copied onto it; the overlay and list ask `App.exclusions` by name, and a toggle bumps the matching clients' revisions (`Roster.bumpByName`).

### Thumbnails and rendering

- **`thumbnail/set.zig` (`ThumbnailSet`):** Owns the `ThumbnailWindow` list (linear search; a few dozen at most), keeps it in step with `Scout`, schedules layout, owns the `Renderer` and `DragOverlays`, and borrows App's `AutoColorStore`. Callers outside `thumbnail/` reach the hover zoom and drag overlays through its methods.
- **`thumbnail/window.zig` (`ThumbnailWindow`):** One per client in `Thumbnails` and `ThumbnailsAndList` modes, keyed by `source_hwnd` to its roster client. Each pairs two windows:
  1. A layered popup with the client's DWM thumbnail (`DwmRegisterThumbnail`), or a plain fill on `WM_ERASEBKGND` when live preview is off for that character. `applyLivePreview()` registers or drops it when settings change.
  2. A layered window on top with the GDI overlay (border, texts, connection map, alerts).
  - In `ClientList` and `Nothing` modes the set holds no thumbnails.
  - Whether thumbnails are shown (the visibility hotkey, auto-hide when focus leaves EVE) applies to the whole set, through `ThumbnailSet.visibility`. Only the region tool hides individual thumbnails.
  - A thumbnail's render state (active, inactive, alert, minimized, dragging) isn't stored; `effectiveRenderState()` works it out on each render.
- Two `ThumbnailWindow` fields belong to other modules, which alone write them: `render_cache` to `thumbnail/overlay.zig`, and `is_dragged` to `drag/thumbnail.zig`.
- **Rendering:**
  - `thumbnail/renderer.zig`: owns `FontCache` and `HoverZoom`; skips a redraw when `RenderSettings` are unchanged.
  - `thumbnail/look.zig` (pure, tested): decides `RenderSettings`, everything the overlay shows, from the profile and a `Subject` (the thumbnail's state as plain values). Settings are compared by walking their fields at comptime, so a newly added field is never left out of the comparison.
  - `thumbnail/overlay.zig`: reads what only Win32 can tell (DPI, client size, minimized, the clock) into that `Subject`, then paints.
    - Its `render_cache` points into the thumbnail's strings rather than copying them. So those strings are only replaced through `ThumbnailWindow.replaceText`, which clears `render_cache.settings` first so the cache never reads a freed string.
  - `thumbnail/draw.zig`: text, border and exclusion primitives.
  - `thumbnail/hover_zoom.zig` + `layout/zoom.zig`: click-through enlarged copy under the cursor.
- **Layout (`layout/`, mostly pure):**
  - `spaces.zig`: which thumbnail space a character goes to, and its cell.
  - `region_grid.zig`: grid math inside a space.
  - `placement.zig`: per-space cells and hand-placed positions.
  - `monitors.zig`: monitor bounds and DPI.
  - `thumbnail/arrange.zig`: applies the layout to windows.

### Panels and shared chrome

- `platform/gdi_overlay.zig`: DIB-backed layered windows, text helpers, `HintBox`. `util/pixel_buffer.zig`: pure ARGB drawing (rects, anti-aliased lines and circles, rounded frames, alpha fix-up).
- `platform/panel_window.zig` (`PanelWindow`): shared by the client list and the History, Intel and Map panels. The first three are borderless layered overlays presented through `UpdateLayeredWindow`; `initNative` makes the Map Panel a normal titled window painted on `WM_PAINT`.
- `panels/panel_host.zig`: the panels' only way to reach `App`.
  - `Context` (allocator, store, auto colours, instance), from `App.panelContext`, is what a panel builds its window from.
  - `Host` (App's `PANEL_HOST`) gives the current `ThumbnailSet`, roster and cycle exclusions, and runs a `Request` such as activating a client, showing a system on the map, suspending hotkeys or opening a settings page.
- `panels/list_view.zig` + `list_look.zig` (pure, tested): the client list in `ClientList` and `ThumbnailsAndList` modes, drawn from the roster. `list_look` holds the sizes, colours, stat text and row order (Tracked, Alphabetical, Configured, grouped by system), and is shared with the dialog preview and the History Panel.
- Shared by the panels in `panels/`:
  - `panel_chrome.zig`: draws the fonts, header, frame and text that the Client List and the History, Intel and Map panels share, so they can't drift apart.
  - `panel_look.zig` (pure): what the History, Intel and Map panels share: how ages read and when the panels show.
  - `panel_lifecycle.zig`: creates and destroys those panels' windows from their `show` setting.
  - `panel_header.zig` (pure, tested) + `header_panel.zig`: the header (chevron, title, buttons) and window procedure the Client List, History and Intel panels share: header drag, snapping, saving where they landed.
  - `panel_menu.zig` + `panel_menu_look.zig` (pure, tested): the `⋯` menu, a borderless topmost window of its own, shared by those three panels.
  - `panel_section.zig`: their shared settings (keep on top, lock, opacity, folding, position), changed through `ProfileStore.updateSection`.
  - `history_look.zig` (pure, tested): the history rows' sizes, category chips, text, and which repeated entries merge into one row. Shared with the dialog's preview.
  - `history_rows.zig`: draws those rows, for `HistoryPanel`, `IntelPanel` (`panels/intel_panel.zig`) and the Map Panel's Intel card.
  - `popup_menu.zig` + `popup_look.zig`: a menu with two levels of submenu, plus tooltip placement; used by the Map Panel. It's drawn inside the panel because `TrackPopupMenu` needs the foreground, which panels never take.
  - `segmented.zig` (pure, tested): the segmented control shared by the Map Panel's metric bar, the Intel Panel's range filter and the `⋯` menu.
  - `glyphs.zig` (pure, tested): the one icon set, built at compile time from strokes on a 16-unit grid with a 1.5 px line, so no image files ship. `dialog/knots/glyphs.zig` lays them out for the dialog.

## Map Panel

`panels/map_panel.zig` (`MapPanel`) is owned by `App`, so it survives `ThumbnailSet` rebuilds. It holds the feeds and their latest results (stats snapshot, logo colours, zKillboard kills, Eve Stars state), the window's lifecycle, its window procedure, and when it redraws. Intel pins it only reads, from `App`'s `Intel`.

### Panel UI and state (`panels/map/`)

| File | Role |
|---|---|
| `window.zig` | `MapPanelWindow`: the window, the regions it shows and saves, client marks, render signature, and layout, label and overview caches. |
| `input.zig` | Mouse and keyboard to `MapState` changes, menu actions and search. Hands back a redraw `Response`; doesn't import `map_panel.zig`. |
| `state.zig` | *(pure, tested)* `MapState`: what the map shows and what's under the cursor, hit testing included. |
| `scene.zig` | `Scene`: what `MapPanel` hands each render besides the settings, and which of its layers (storms, incursions, sov timers, wormholes, Ansiblex) the settings let through. |
| `paint.zig` | Draws a frame from `MapState` without changing it, handing back the row and popup boxes the next hit test needs. |
| `menu.zig` | *(pure, tested)* The right-click menus on a system and a region, and the Layers checklist. |
| `search.zig` | *(pure, tested)* The search's query, cursor, selection and results. |
| `marks.zig` | *(pure, tested)* The clients on the map. |
| `look.zig` | *(pure, tested)* Sizes, colours, footer buttons, the panel's own markers (heat, kills, timers, portals, bridges) and its `Areas`. |
| `coloring.zig` | *(pure, tested)* How markers and gates take their colour from the metric shown. |
| `metric_segments.zig` | *(pure, tested)* Which metrics each metric bar segment shows, and the value a metric reads from a system. |
| `ownership.zig` | *(pure, tested)* Who holds the shown systems and regions, ranked, and each holder's colour. |
| `text.zig` | *(pure, tested)* Tooltips, legends, titles and labels. |
| `wormhole_list.zig` | *(pure, tested)* The Thera and Turnur card's list, one hub a tab, sorted by region, and its scrolling. |
| `timer_list.zig` | *(pure, tested)* The sov timer card's list, soonest first. |
| `destinations.zig` | The panel's Eve Stars route state: which characters can be sent a destination, the account's Ansiblex gates, its saved avoid list (the only avoid list; profiles don't keep one), the planned route, and how each call turned out. |
| `traffic.zig` | Owns the Eve Stars activity feed for the panel: keeps the latest kill and jump totals for each span, and fills in the NPC delta's missing hour (see **NPC delta** under [Map data and feeds](#map-data-and-feeds-map)). |

### Map data and feeds (`map/`)

Every file here except the `*_feed.zig` ones does no I/O and is tested; the feeds make the network calls, on background threads.

| File(s) | Role |
|---|---|
| `universe.zig` | Reads the embedded map, `universe.bin`: every system, gate and region. `tools/build_universe.py` rebuilds it from CCP's static data after a game update changes the map. |
| `layout.zig` | Where everything is drawn. Systems sit at their positions on CCP's flattened map, with up to four regions side by side; gates between regions curve around systems in the way. Also places exits and portals (short stubs leading to Thera, Turnur or an Ansiblex gate's far end), applies zoom and pan, and places labels. |
| `overview.zig` | New Eden as bubbles, for picking a region. |
| `markers.zig` | The marks both the Map Panel and the thumbnails' connection map draw, so they look the same: system markers, rings, gate colours, exits and intel halos. |
| `security.zig` | A system's security as the game shows it, colour and text, for the map, client list, dialog preview and thumbnails. |
| `search.zig` | Names in the embedded map. |
| `jump_range.zig` | Ship jump ranges and the systems in reach, by the embedded map's true 3D positions. |
| `stats.zig` + `stats_feed.zig` | The `Snapshot` of per-system figures: ESI's kills, jumps and sovereignty, and the NPC delta (see below). Also gathers incursions (`incursions.zig`), sov campaigns (`campaigns.zig`), faction warfare (`faction_warfare.zig`), and EVE-Scout's storms (`storms.zig`) and wormholes (`wormholes.zig`). |
| `campaigns_feed.zig` | A running sov timer's scores, refreshed every 10 s between snapshots. |
| `zkill.zig` + `zkill_feed.zig` | zKillboard's live kills, and the names of their ships and victims. |
| `holder_colors.zig` | Sovereignty colours: fixed for NPC factions, picked from logos for alliances. |
| `connections.zig` | The systems a few gates out from a client's system, and the intel pinned on them, for the thumbnails' connection map. |
| `nearest.zig` | Which positions are nearest a system by gate jumps, ties kept. Used by the chatlog worker's intel routing and the Intel Panel's "N jumps from X", each with its own range and filter. |
| `intel.zig` | `Intel` on `App`: intel's one owner, holding the pins (`intel_pins.zig`) and the report history. Read by the Map Panel, Intel Panel, `Notifier` and the thumbnails' connection map. |
| `evestars.zig` + `evestars_feed.zig` | The Eve Stars route API: sends, route plans, the Ansiblex list and the saved avoid list. |
| `activity.zig` + `activity_feed.zig` | Eve Stars' per-system kills and jumps, totalled over the span picked in the panel (ESI only gives the last hour), and its NPC kills for the last two single hours. |
| `system_links.zig` | A system's Dotlan, zKillboard and Eve Stars pages. |

- **NPC delta:** each system's NPC kills in the last hour minus the hour before. ESI only reports the last hour, so the first snapshot after startup has nothing to compare against; the delta normally appears once a later snapshot reaches a new hour. To show it sooner, `activity_feed.zig` asks Eve Stars for the last two hours every 2 min while the delta is missing. `traffic.zig` applies Eve Stars' earlier hour only if its last hour matches the snapshot's NPC kills in every system, which shows both describe the same hour.
- **zKillboard runs:** each run reads up to 50 R2Z2 files from where the last stopped, then looks up the names of new ships and victims through ESI. The next run starts at once while it's still catching up, otherwise after 6 s.

### Drawing and input

- Hover, panning and the mouse wheel redraw straight from their own messages, since waiting for the tick could mean a second's lag when idle. Redraws are capped at the screen's refresh rate; when a mouse move is skipped by that cap, a short timer draws its final position.
- `PanelWindow.present` paints immediately instead of invalidating, because Windows holds back `WM_PAINT` while the mouse keeps moving.
- A pan or zoom only recomputes positions. The systems and gates themselves are gathered again only when the shown regions change.
- Labels are placed after a render has measured the cards and legends drawn over the map, so names avoid them. They're placed again only when the set of systems with sov timers changes.
- A new intel pin or kill, or a system picked from the search, plays a ripple animation on its own fast timer, which stops once no ripple is playing.
- The render signature decides whether a frame needs drawing. While sov timers or kills show, it includes the current minute, so countdowns, kill ages and fading kill marks keep updating.
- A system with a sov timer gets a two-line name with the countdown under it, sized for the widest countdown so it never moves.
- The right-click menu and search results are drawn inside the panel. A click anywhere on the map activates the window, as other windows do.
- The search takes the keyboard, unbinding the hotkeys while it's open.

## Input and control

### Hotkeys and focus

- **Low-level hooks:** hotkeys use `WH_KEYBOARD_LL` and `WH_MOUSE_LL` hooks on their own thread rather than `RegisterHotKey`. That lets bare modifiers and mouse buttons be bound, and means a busy main thread can neither delay input nor get the hooks removed by Windows. A matched press is posted to main as `WM_HOTKEY`.
  - `hotkeys/keyboard_hook.zig` and `mouse_hook.zig` are the hooks; `hook_bindings.zig` holds the bindings they share, and `hooks.zig` routes each binding to the right hook.
  - `press_rules.zig` (pure, tested) decides whether a press matches, passes through or is swallowed.
  - Whether a press is swallowed is decided once, on its first key-down, and its repeats and key-up follow that decision. So a client never sees a key-up whose key-down it didn't see, which is what lets Ctrl stay held in the game while cycling clients.
  - With `requireEveFocus`, a bound key pressed outside a tracked EVE window passes through untouched.
  - With NumLock on, Windows sends Shift+Numpad as a fake Shift release then a navigation key; the hook and the dialog's recorder read it back as Shift+Numpad.
- **ID bands** (`hotkeys/bindings.zig`): 1000 per kind (cycle group 0, global action 1000, per-character 2000, profile switch 3000, assign group 4000, app 5000, URL 6000, close group 7000, minimize group 8000). `GLOBAL_BINDINGS` maps global actions to config fields and protocol actions.
- `hotkeys/manager.zig` (`HotkeyManager`): registration, the press gate (repeats, suspend, the dialog recording a key, EVE focus), suspend and the dialog-recording pause, and the per-character hotkeys' cursors. Bindings come from `store.saved`, other settings from `store.live`.
- `hotkeys/plan.zig` (pure, tested):
  - `Plan`: which hotkeys a profile binds, in registration order (globals first). The registered `Plan` owns its actions' index slices until `unregisterAll`.
  - `pressVerdict`: whether a press runs.
  - `conflicts`: combos bound more than once, where only the first to register would get the key. Several characters, or several groups' forward or backward keys, may share one combo on purpose: the press then cycles through them, so that isn't a conflict. The dialog refuses to save with conflicts, and registration logs a warning.
- `hotkeys/commands.zig` (`Commands`): `run`, the one switch on `HotkeyAction`, and `runGlobal` / `runGroup` / `runGroupAt` for the tray and protocol links.
- `hotkeys/cycling.zig`: picks the client each cycle hotkey activates, with the decisions in `cycle_order.zig` (pure, tested). Each cycle's current position lives in `App.cycle`, reset whenever the hotkey manager is recreated.
- `control/focus.zig` (`FocusTracker`): the `EVENT_SYSTEM_FOREGROUND` hook. Sets `Roster.active_hwnd`; informs the thumbnail set, auto-minimize and cycling; and auto-hides thumbnails after focus leaves EVE.
  - A new client often takes focus before a scan has added it to the roster. If the window matches the client filters (`scout.matchesFilters`), it still counts as EVE, so thumbnails don't hide, and the tick records its focus once the roster has it.

### Activation and window actions

- `control/activation.zig` (`activate`): where every click, cycle and protocol switch ends. It brings the client to the foreground and restores it if minimized. It then handles the focus change at once rather than waiting for the foreground hook, which can be late: the active border, auto-minimize's record and the cycle positions. Finally it dismisses notifications set to clear on a click, and redraws up to 4 changed thumbnails straight away.
- `platform/focus_grant.zig`: Windows only lets `SetForegroundWindow` succeed for a process that just received input. A key caught by the low-level hook doesn't count as input to the app, so it registers a real `RegisterHotKey` on a combo no one can press, and triggers it with `keybd_event`. Receiving that `WM_HOTKEY` gives the app the right to set the foreground window.
- `control/auto_minimize.zig`: minimizes idle clients from each roster client's minimized state, idle time and minimize exclusion; decisions in `minimize_rules.zig` (pure, tested).
- `clients/`: the EVE windows themselves. Besides `Scout`, the roster, cycle exclusions and auto colours, it holds the actions on them: minimize, close and move (`actions.zig`), restoring with or without Windows' animation (`animation.zig`'s `showClient`), correcting a client EVE moves while it loads (`auto_move.zig`), and marking clients fullscreen so Explorer puts the taskbar behind the active one (`taskbar.zig`, which App re-marks every client with after the setting changes or Explorer restarts). Imports nothing from `thumbnail/`, `hotkeys/`, `drag/` or `control/`.

```text
Hotkey press → character switch:

WM_HOTKEY ─> timerWindowProc ─> HotkeyManager.handleHotkeyPress ─> Commands.run
  ─> cycling.* ─> Scout.getHwndByName ─> Outcome.activate
  ─> App.runHotkeyOutcome ─> activation.activate ─> focus_grant.forceSetForegroundWindow
```

### Drag and protocol links

- `control/thumbnail_input.zig`: thumbnail window procs, passed into `thumbnail/` by `App`, and the client list's row input (`list_view.RowInput`). Left click activates; Shift+click toggles the cycle exclusion; right drag moves the thumbnail (`drag/thumbnail.zig`; Ctrl moves all).
- `drag/`: snapping to screen edges, other thumbnails, panels and saved positions (`snapping.zig`, with the math in `snap_math.zig`, pure); the saved positions shown as ghosts, stacked ones merged (`ghost_groups.zig`, pure); and `DragOverlays` (`overlays.zig`: the ghost outlines and the drag hint).
- `panels/drag.zig`: dragging the client list and the History, Intel and Map panels by their header strip (the Map Panel by its title bar). Windows moves the window and the app snaps it. `PanelWindow` tags each panel's window with a property so drags can find panels to snap to.
- `protocol/`:
  - `url.zig` (pure, tested): parses `evemajpreview://` URLs into a `Command`.
  - `ipc.zig`: sends the URL to the running instance over `WM_COPYDATA`, giving up after 5 s on a hung one. The timer window lets the message through UIPI, so an elevated instance still receives it.
  - `run.zig`: runs the command through the same code as its hotkey or tray item (group actions via `Commands.runGroup`), refusing one that closes clients or the app (`Command.closeAction`) unless that action is allowed in `protocolLinks` (`allowCloseAll`, `allowCloseActive`, `allowCloseGroup`, `allowExitApp`), so a web page can't close your clients.
  - `registry.zig`: registers the handler, again whenever the exe path changes.

## Log monitoring and trackers

`chatlog.zig` (`ChatlogMonitor`) finds and follows the logs and owns the queues; `chatlog/interpret.zig` works out what each line means. Worker loop: `processCommands` → `pollLogFiles` → `rescanForNewLogs` → wait `poll_interval_ms`.

- **Main side:** the two threads talk only through the queues in `chatlog/queue.zig`. `update()` queues add, remove and resolve-ID commands; `drain()` returns `Findings`, which `App.deliverChatlogFindings` routes to `Roster`, `Intel`, `Notifier` and `Scout`. The monitor never touches them.
- **Finding and reading logs:**
  - `chatlog/discovery.zig` (`LogFinder`): finds a character's newest chatlog and gamelog, and its other chat channels' logs, among possibly tens of thousands of files. By cached ID it matches file names (`*_<id>.txt`); without one it reads the `Listener:` headers of the newest 64 files.
  - `chatlog/character_ids.zig` (`CharacterIds`): each character's EVE ID, learned from log file names and cached in `data/character_ids.json` so later lookups skip reading headers.
  - `chatlog/tail.zig` (`LogFile`): keeps the handle open, reads appended bytes, backs off when idle.
  - `chatlog/utf16.zig`, `lines.zig` (pure): decoding and parsing of system changes, jumps, undocks, file names and headers.
- **Interpreting (worker thread):**
  - `chatlog/interpret.zig` (`Interpreter`, worker only): each line to system changes, chat alerts, intel sightings, game events and tracker entries. It holds the alert rules, weapon filter, trackers and where each client is; the monitor sets them while the worker is stopped.
  - `chatlog/alert_rules.zig` (pure, tested): which chat lines raise an alert, plus duplicate suppression and cooldowns.
  - `chatlog/routing.zig` (pure, tested): which client an alert goes to (the nearest clients, else the character whose log it came from, else an unmuted stand-in), and which system reports count. A repeated undock or Local report is dropped but a jump never is, and only gate jumps raise a notification.
  - `notifications/gamelog_events.zig` (`classify`, pure): line → `Notification`.
  - `activity/lines.zig` (pure): combat, mining and bounty parsers, feeding `activity/tracker.zig`'s sliding-window rates. Mining is valued from `activity/ores.zig`'s volumes and price snapshot (pure).
  - `session_starts` backdates a character's login (Session Timer) via `Scout.backdateLogin`; the roster mirrors it on its next sync.
- **Main-thread samplers (`activity/`):**
  - `runtime.zig` (`Trackers`): matches trackers to the config while the worker is stopped, keeping history for those that stay enabled.
  - `resources.zig` samples CPU, RAM and VRAM (PDH) per client process; `ping.zig` pings each client's game server with asynchronous ICMP echoes polled each tick. Both follow `store.live`, so they preview before Save, and write onto the roster client's `stats` (`activity/stats.zig`) through `Roster.updateStats`.
  - `stat_text.zig` (pure): how a rate reads wherever it's shown, e.g. `IN: 412` or `M: 1,284 m3/hr`.

## Notifications

- `notifications/notification.zig`: types, categories, placeholders, default text. `template.zig` (pure) fills `{name}` placeholders in custom text.
- `notifications/notifier.zig` (`Notifier`): how anything raises an alert (trackers, Travel Mode, hotkeys, the dialog's Test button, `App` itself), obtained from `App.notifier()`. It holds only pointers into `App`, not into the `ThumbnailSet`, so alerts still work while thumbnails are being rebuilt or are turned off.
- `notifications/dispatch.zig`: shows a notification on a roster client if `rules.zig` (pure) allows it, and adds sound, speech, history and notified-queue entries. `stack.zig` holds a client's on-screen alerts and throttle timestamps, kept on the roster.
- `notifications/alert_effects.zig`: speech and sound, plus the session-only audio mute.
- The chatlog worker queues `Notification` payloads; text is rendered on the main thread.
- `notifications/center.zig` (`NotificationCenter` on `App`): what outlives a notification on its client, and so survives `ThumbnailSet` rebuilds. That's the history (`history.zig`, a ring buffer of the last 30), the queue the cycle-to-notified hotkey walks (`notified_queue.zig`), and the History and Intel panels (`panels/history_panel.zig`, `panels/intel_panel.zig`).
- `travel/`: Travel Mode's left-behind check, which alerts characters still in a system the rest of their group has moved on from. `left_behind.zig` runs it every 2 s from the tick; `stragglers.zig` (pure) works out the group's system and who's behind.

## Configuration model (`config.zig`, `config/`)

`config.zig` defines `Config` and re-exports every settings type; other modules import only it.

- One file per section (`thumbnail.zig`, `display.zig`, `panels.zig`, `intel.zig`, `behavior.zig`, `activity.zig`, `notifications.zig`, `chatlog.zig`, `characters.zig`, `hotkeys.zig`, `spaces.zig`, ...). Types holding saved settings are named `XxxConfig`, and a thumbnail text's look `XxxTextStyle`.
- What a feature does is configured in its own section (`notifications`, `intel`, `combat`, `mining`, ...), which every view reads. A view's section holds only how that view draws it (`thumbnail.alertText`, `thumbnail.combatText`, ...).
- **Serialization and validation:**
  - `wire.zig`: generates each section's JSON shape, and its encode, decode, free and clone functions, from the struct's fields at comptime. A section opts in with `pub const Wire = wire.Wire(Self)`.
    - Field names pick special encodings: a `u32` named `*Color` is written as a hex string, and a `KeyList` as key codes.
    - Fields listed in `runtime_fields` aren't saved.
    - `wire_defaults` gives the default for a missing key when the field's own default can't express it, e.g. a non-empty list.
  - `readable.zig`: lenient loading. Any field, list item or map entry that doesn't fit its type is dropped, so only that one setting falls back to its default and the rest still load. Unknown keys are ignored. Only a file that isn't valid JSON fails to load: it's copied to `profiles/backup/` and defaults are used.
  - `migrate.zig` (pure, tested): upgrades older profile JSON before parsing. `legacy_dpi.zig` scales positions a DPI-unaware process saved, for old profiles and the EVE-O, EVE-X and EVE-APM importers.
  - `ranges.zig`: each settings type declares a `ranges` table of min and max per field, and optionally `zero_means_default`, fields where 0 means "use the default". Every `validate()` is just `ranges_mod.clamp(Self, self)`, which also recurses into nested sections.
- **`store.zig` (`ProfileStore`):** the only writer of the running profile.
  - `live`: what the app shows, including unsaved dialog edits. Read by `ThumbnailSet` and panels.
  - `saved`: what's on disk. Read by setup-once consumers: `Scout` filters, hotkey bindings, chatlog, trackers, the tick timer.
  - Runtime changes (drags, tray toggles, group membership) apply to both and save immediately. `update` takes a struct literal mirroring `Config`'s nesting, e.g. `.{ .display = .{ .startX = 10 } }`; `updateSection` takes one for a single named section. (These aren't `patch.zig` ops.)
  - `commit` (Save) clones `live` → `saved`; `discard` clones `saved` → `live`.
- **Other modules:**
  - `patch.zig`: path-addressed `set` / `insert` / `remove` / `move` ops; keyed lists (`characters`, `hotkeyGroups`, `thumbnailSpaces`) are addressed by a runtime `id`, which `assignIds` gives each item. Imports are applied as these ops.
  - `types.zig`: types and defaults several sections share. Enum tag names are saved in profiles, so renaming a tag breaks existing profiles.
  - `key_list.zig` (`KeyList`): a binding's key combos, alternates that all trigger the same action.
  - `field_strings.zig` (pure): which string fields still hold their default literal and which hold owned copies, so only the copies are freed.
  - `profiles.zig`: load (strict for user switches; startup falls back to the default profile), save, create (exclusive), copy, rename, backup and restore. Every name passes `validateName`.
  - `import/`: EVE-X / EVE-MultiPreview, EVE-APM (INI), EVE-O and own profiles → `Draft` → patch ops. Untested by design.
  - `global.zig`: `GlobalConfig`, the settings every profile shares: last profile, log level, language, the log folders (`chatlog`), cross-profile hotkeys (profile switching, cycling all clients or apps, app and URL hotkeys), run on startup, update checks, the protocol handler and `protocolLinks`, ore prices, and the Eve Stars token.

## Configuration window (`dialog/`)

Immediate-mode (`knots` on Vulkan), main thread, with a nested message loop so the tick and tray keep running. Each frame reads settings and writes them straight back to `store.live`; there's no form state.

- `knots/host.zig`: window lifecycle, nested loop, close prompt, saved position. Every save goes through `saveChanges`, which refuses while `plan.conflicts` finds hotkey conflicts. Anything that replaces documents or touches the app is posted as `WM_KNOTS_COMMAND` and runs between frames.
- `knots/session.zig`: edits `store.live` and a draft copy of `GlobalConfig`.
  - Every change goes through `Ref.set` (or a list's `append` / `remove` / `move`), which copies strings, clamps values to their ranges, and asks `App` to restyle through `session.run`.
  - A replaced string is freed one frame later, since the current frame may still be drawing it.
  - The session is dirty when the profile differs from what's saved, or when a Save that included global changes failed.
  - `save()` hands `App` the dirty flag and the global draft. `App` adopts a copy, so if the save fails, the draft still holds what the user typed.
- `knots/form.zig`: lays out the header, sidebar (tabs grouped under Clients, Display, Input, Alerts and App), open tab, footer and prompts. `knots/tabs/` has one file per tab, plus sections kept in their own files (`panel_settings.zig`, `window_filters.zig`, `chatlog.zig`, and `client_list.zig`, drawn on the Appearance tab). `widgets.openSharedSection` tags a section whose settings every profile shares.
- `knots/widgets.zig`, `bind.zig`, `style.zig`: layout pieces, setting-bound controls, and styles built on `palette.zig`.
- `knots/roster.zig`: a list tab's rows, each clicked to select what the details beside it show. `selection.zig` (pure, tested): which item that is, kept as the list shrinks or reorders.
- `tabs/panel_preview.zig`: the panel previews' stage, frame, header and clickable parts.
- `knots/header.zig`: the header's brand and profile menu, and the prompts it opens. `profiles.zig` runs the profile and backup actions (switch, create, copy, rename, delete, reset, back up, restore) between frames, since each can replace the documents. `import_dialog.zig` is the Import Settings dialog. `status.zig` is the footer's status line.
- `knots/hotkey.zig`: the recording field; pauses live hotkeys while recording, draws its key caps compact when full size would overrun `widgets.controlsRoom`, and marks conflicting combos with their holders' names from `labels.zig`.
- `tools/`: `region_select.zig` (full-screen overlay for drawing a thumbnail space; math in `region_math.zig`), `esi_prices.zig` (Jita ore prices), `ultra_potato.zig` (patches EVE's graphics YAML).

## Module dependencies

- Direct calls, no event bus. Code is handed `*App` or just what it needs.
- Win32 callbacks have no context pointer: window procs and hooks read `app.g_app` (or `app.currentThumbnailSet()`) and pass it down; modules below them never read the global. `Scout` keeps a private pointer for its own hooks so it stays testable.
- A panel finds its own struct from the `hwnd`: its owner attaches it with `PanelWindow.attachOwner`, and the window proc reads it back with `panel_window.ownerOf`. Panels reach `App` only through `PANEL_HOST` (the Map Panel through `MapPanel.host`, set by `App.init`).
- The dialog reaches `App` only through `dialog/dialog_host.zig`: `host.init` takes App's `Context` (allocator, io, store, global settings, Scout, character IDs) and `DIALOG_HOST` (thumbnail set, notifier, timer window, save, requests), and hands back `DialogHooks`. `import_cycles.py` fails if `dialog/` imports `app.zig`.
- `platform/` depends on nothing app-specific: outside itself it imports only `log.zig` and `util/`. Win32 declarations live in `platform/win32.zig`, which never logs.
- Pure logic is split into its own file (marked "no I/O" in its header) and tested.

## Client simulator (`sim.zig`, `sim/`)

A second exe, `eve-maj-sim` (`zig build sim`), that stands in for EVE clients so the app can be tested without the game. It reuses only leaf modules, never `App` or anything that runs the app: the dialog's look (`dialog/knots/style.zig`, `widgets.zig`, `glyphs.zig`, `images.zig`, `color_convert.zig`), `platform/win32.zig` and `gdi_overlay.zig`, `log.zig`, the embedded map (`map/universe.zig`), and the log parsers it writes for (`chatlog/lines.zig`, `notifications/gamelog_events.zig`).

- `sim.zig`: entry point; runs in `%TEMP%\EveMajSimulator`. With `--client <name>` it becomes one client instead.
- `client_window.zig`: a client. One `trinityWindow` per process, titled `EVE - <name>`; the controller posts `WM_SIM_LOGIN` / `WM_SIM_LOGOUT` to change the title.
- `fleet.zig`: the controller. Copies itself to `exefile.exe` (Scout's filter needs that name), starts and ends client processes, and writes their chatlogs, gamelogs and channel logs.
- `lines.zig` *(pure, tested against `chatlog/lines.zig` and `gamelog_events.zig`)*: every log name, header and line it writes.
- `schedule.zig` (pure, tested): timed steps for bursts, routes and guided tests, run from a 100 ms timer so the window never blocks. `scenarios.zig`: the guided tests.
- `journal.zig` (pure, tested): the activity feed: what it wrote, what to expect, and what went wrong. `view.zig`, `window.zig`: the knots window, laid out like the configuration window. `win32_sim.zig`: Win32 declarations only the simulator uses, an allowed exception to keeping them in `platform/win32.zig`.

## End-to-end tests (`tools/ui_tests/`)

Python (stdlib and ctypes only) that drives the built app against simulated clients. Run `python tools/ui_tests/run.py [name-substring ...]` with the app closed, since it's single-instance.

- `harness.py`: copies the app into a temp folder with its own profile and global settings (protocol registration and update checks off), starts `eve-maj-sim --client` copies named `exefile.exe`, sends protocol links through a second launch, and presses keys only while a test client has focus.
- `diagnostics/state_file.zig`: with `EVE_MAJ_STATE_FILE` set, the app writes what it shows as JSON, so tests can check what the user would see. It includes:
  - each thumbnail: name, handles, visibility, badge, and what its overlay last drew;
  - each client: system, alerts, rates;
  - the alert and intel histories, and how many sounds and speech lines played;
  - each open panel's drawn text, with the font GDI actually used for it;
  - the active client, cycle exclusions, suspended hotkeys and groups.

  Tests read names from here rather than from window titles, since a thumbnail window keeps the title it was created with. The harness combines this file with what Win32 reports for positions and visibility.
- `diagnostics/app_state.zig`: builds the snapshot from the parts of `App` it's handed (`Sources`), so it doesn't import `app.zig`. Its `Recorders` exist only while the state file is on.
- `diagnostics/recorder.zig`: keeps a copy of each window's last render. `Recorders` hands them to the code that draws:
  - `thumbnail/overlay.zig` for thumbnails;
  - `panels/panel_chrome.zig` for panels: its draw helpers, and `recordText` for the map's haloed labels, record every panel's text into a `panels/drawn_text.zig` record;
  - `notifications/alert_effects.zig` for sound and speech.

  With the state file off, each recording point costs only a null check.
- `uia.py`: drives the config dialog through UI Automation, reading the controls knots publishes in its AccessKit tree (each named for its row's label by `widgets.nameControl`).
- `eve_logs.py`: writes chatlogs and gamelogs as EVE does, so tests can feed alerts, systems, chat and activity.
- `run.py`: runs `tests/test_<area>.py`; `--failed` reruns only what the last run failed.
  - All tests in a module share one sandboxed app, and each test switches it to a profile of its own.
  - The shared app is restarted after a failed test, or when a test leaves cycle exclusions or suspended hotkeys behind.
  - `@fresh` tests get an app of their own, for tests that need different global settings.
- `coverage.py`: lists every setting as `Struct.field`, read from `src/config/`, and the tests that claim it with `@covers`.
- `vm/`: runs the tests inside a Hyper-V VM, so they don't take over your desktop; setup is in [TESTING.md](TESTING.md).

## Source checks (`tools/checks/`)

Python (stdlib only) checks that a script can decide and the compiler doesn't. `run_all.py` runs the ones that gate a push, as CI and the `pre-push` hook do (install the hook with `cp tools/checks/pre-push .git/hooks/pre-push`). Each takes `--help`, and reads any deliberate exceptions from `allow/<checker>.txt`; a full run fails on an entry that no longer matches anything.

| Checker | Finds |
|---|---|
| `style_check.py` | Breaks of [STYLE.md](STYLE.md)'s mechanical rules; `--advisory` adds the heuristics a reviewer judges. |
| `dead_code.py` | Declarations, fields and enum tags nothing references, which Zig's lazy analysis never warns about. |
| `import_cycles.py` | Import cycles between features, outside the top layer that reaches back up to `App`. |
| `stale_refs.py` | Comments, and this file's backticked code, naming identifiers or files that no longer exist. |
| `lang_keys.py` | Translated strings missing from `src/lang/en.json`, unused keys, and keys a language lacks. |
| `config_docs.py` | Settings missing from [CONFIGURATION.md](CONFIGURATION.md), and rows naming fields that are gone. |
| `knots_patches.py` | `deps/knots/patches/` out of step with the vendored files, their `EVE-Maj patch` markers or `PATCHES.md`; `tools/update_knots.py export` rewrites the patches. |
| `duplicates.py` | Copied runs of code; for review, not a gate. |

## Other modules

| Module | Role |
|---|---|
| `arguments.zig` | *(pure)* The command line, parsed once into what `main.zig` acts on. |
| `log.zig` | Buffered rotating file log, `Scoped(name)`, debug console. |
| `crash.zig` | Vectored and unhandled exception handlers, panic handler, minidump. |
| `palette.zig` | The app's colours, sizes and fonts; the GDI panels, the map's markers and the dialog (through `dialog/knots/style.zig`) build on it, so they match. |
| `tray.zig` | Tray icon and menu; its toggles run as hotkey actions through `App.commands().runGlobal`. |
| `update.zig` | GitHub release check, and the result the tray menu and config dialog show. |
| `lang/` | UI strings by English key, one JSON file per language. `lang.zig` looks up the chosen language, falling back to English; `wording.zig` (pure) loads the files and fills their `{placeholders}`. |
| `platform/fonts.zig` | Bundled Cascadia and Geist, registered process-private; `create` makes every GDI font. |
| `platform/run_on_startup.zig` | The Run registry key, set or removed by `app.applyGlobalSettings`. |
| `platform/virtual_keys.zig` | VK codes, `KEY_NAMES`, mouse-chord encoding. |
| `platform/wic.zig` | Image decoding (portraits, alliance logos). |
| `util/` | Small shared helpers. Threads: one-shot background threads (`detached.zig`) and lock-free hand-off to main (`handoff.zig`). Files and network: crash-safe writes (`atomic_file.zig`) and HTTP over WinHTTP with timeouts (`http_client.zig`). Drawing: pixel buffers (`pixel_buffer.zig`, `rgba.zig`), rectangles (`box.zig`), colour math and OKLab picks (`color.zig`), and the font GDI realized (`selected_font.zig`). Text: strings, number format, UTF-8 cutting (`utf8.zig`), owned text that can cross threads (`fixed_text.zig`) and wildcard matching (`glob.zig`). Time: tick scheduling (`schedule.zig`) and UTC time to Unix seconds (`time.zig`). |
