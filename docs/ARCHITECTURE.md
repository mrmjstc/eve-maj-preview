# Architecture

How `src/` fits together. For related docs, see [CONFIGURATION.md](CONFIGURATION.md) (settings), [BUILDING.md](BUILDING.md) (build steps), and `.claude/STYLE.md` (code style).

## Overview

- One executable, `eve-maj-preview.exe` (`src/main.zig`), built for the Windows subsystem. A console opens only when the log level is `debug`.
- The configuration window runs in-process on the main thread using `knots` and Vulkan. `zig build config` launches the app with `--config`.
- `zig build test` runs `src/tests.zig` (Debug build), which imports every tested module. `zig build check` type-checks without emitting a binary; ZLS runs it on save. End-to-end tests live in `tools/ui_tests/`.
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
| `data/logo_colors.json` | Colour picked from each sov-holding alliance's logo; at most 200 before it starts again | `map/stats_feed.zig` |
| `logs/eve-maj.log`, `.old` | Log, rotated at 20 MB | `log.zig` |
| `logs/eve-maj-crash.dmp` | Minidump of the latest crash | `crash.zig` |

### File safety and migration

- `config/files.zig`'s `migrateLegacyLayout` moves files older versions kept beside the exe into `data/` and `logs/`.
- Every save writes `<file>.<hex>.tmp` and renames it over the file (`util/atomic_file.zig`).
- `sweepTempFiles` deletes the `.tmp` files a killed process left in `profiles/`, `data/` and `data/portraits/`.

## Startup and teardown (`main.zig`)

### Startup sequence

1. **Process setup:** Set per-monitor DPI awareness and install crash and panic handlers (`crash.zig`).
2. **Arguments:** Parse `--profile` / `-p`, `--config` and `--protocol <url>` (`arguments.zig`).
3. **Protocol forwarding:** With `--protocol`, forward the URL to the running instance over `WM_COPYDATA` and exit. Runs before the single-instance check.
4. **Single instance:** Claim the `Global\EVE-Maj-Preview-SingleInstance` mutex. If it's taken, send `evemajpreview://config` to the running instance and exit.
5. **Environment and stores:**
   - Sweep leftover `.tmp` files, skipped if the working directory couldn't be set to the exe's folder.
   - Load bundled fonts (`platform/fonts.zig`) and start the hotkey hook thread (`hotkeys/hook_thread.zig`).
   - Load `GlobalConfig` and apply it at once through `app.applyGlobalSettings` (log level, debug console, Run key, protocol handler), as again after each Save.
   - Load `CharacterIds` and the profile into a `ProfileStore`, which `App.init` takes as `App.Loaded`.
   - Set `app.g_app`, start the dialog host (`dialog/knots/host.zig`) and load the UI language (`lang/`).
6. **Subsystems:**
   - Create the hidden timer window and hand it to `App.start`.
   - Start `NotificationCenter`, `MapPanel`, `Scout`'s event hooks, the focus hook and the tray icon.
   - Run `restartSubsystems` from nothing running: scan windows, build the `ThumbnailSet`, create and wire `ChatlogMonitor` and `Trackers`, start the chatlog worker, create the `HotkeyManager` and start the tick timer.
   - Queue the character-ID backfill, and move clients if `moveOnStartup` is on.
7. **Background services:** Install the focus grant (`platform/focus_grant.zig`) and start the update check thread (`update.zig`).
8. **Message loop:** Run the `GetMessageA` loop.

### Teardown sequence

`main.zig`'s `defer`s run in reverse order of registration:

1. **Process-wide services:** Uninstall the focus grant, shut down the sound and TTS workers, then wait for one-shot threads (see [Worker lifecycles and limits](#worker-lifecycles-and-limits)).
2. **Dialog host:** `knots_host.deinit` runs before `App.deinit`, while the store it edits still lives.
3. **`App.deinit`:** Tears down everything `App` owns in one sequence, each part before what it borrows, including the `ProfileStore`. Copes with a startup that failed partway.
4. **`app.g_app`:** Cleared only after `App.deinit`, so callbacks lose the app once it's torn down.
5. **Hook thread:** Stopped last, since `App.deinit` unregisters the hotkey manager's hooks through it.

## `App` and lifecycle (`app.zig`)

`App` owns every long-lived subsystem. Main thread only.

| Field(s) | Lifetime |
|---|---|
| `store` (`ProfileStore`), `global_settings`, `character_ids`, `scout`, `roster`, `auto_colors` (`AutoColorStore`), `exclusions`, `auto_move` (`AutoMoveVerifier`), `notifications` (`NotificationCenter`), `intel` (`Intel`), `focus`, `trackers`, `tray_icon` | Whole run, across profile switches and Saves. |
| `auto_minimizer` | Whole run; reset when a different profile loads, restarting each client's idle delay. |
| `thumbnail_set`, `hotkey_manager`, `chatlog_monitor` | Rebuilt on reload; heap pointers replaced by `restartSubsystems`. |
| `list_window` | Built and torn down with `thumbnail_set`; `ClientList` and `ThumbnailsAndList` modes only. |

### Invariants

- Rebuilt subsystems are read from `App` each time, never cached elsewhere.
- State that must survive a rebuild lives on `App`: cycle exclusions, notification history, the auto-minimize toggle.
- Every user command, from a hotkey, the tray or a protocol link, runs through `App.commands()` (`hotkeys/commands.zig`), which holds pointers into `App`, so none waits on the `HotkeyManager` that `App` rebuilds on each Save and profile switch. Each command gets the current `ThumbnailSet` and hands back an `Outcome` (activate a client, switch profile, toggle a panel, return to the last app), which `App.runHotkeyOutcome` runs.
- `ThumbnailSet` borrows only the store, exclusions and `NotificationCenter`'s records (`dispatch.Records`). `App` passes in its window procs and destroy hook, so `thumbnail/` imports no input or panel code.

### Reload entry points

| Call | Trigger | Effect |
|---|---|---|
| `requestProfileSwitch` → `WM_SWITCH_PROFILE` → `switchProfile` | Tray, hotkey | Deferred to the next message-loop turn. |
| `switchProfile` | Protocol link, dialog | Loads the profile into a new store, then runs `restartSubsystems`. |
| `saveSettings` (`DIALOG_HOST.save`) | Dialog Save | Commits `live` → `saved` on the same store, runs `restartSubsystems` adopting a copy of the global draft, then writes and applies `GlobalConfig`. |
| `onLiveProfileEdited` (`DIALOG_HOST.run`) | Every dialog edit | Restyles and reflows; rebuilds the `ThumbnailSet` only on a view-mode change. |

`restartSubsystems` runs the steps from `control/restart_plan.zig` (pure, tested), at startup as on a reload: which subsystems are kept, paused or rebuilt, in what order, and what to bring back up if a step fails.

- A kept chatlog worker is paused until the new trackers are wired in and it has the profile's chat-alert rules (`apply_monitor_profile`).
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
| `WM_HOTKEYS_STATE_CHANGED` | Suspend/resume notification. |
| `WM_WIN_KEY_CAPTURED` | `keyboard_hook.onWinKeyCaptured`: a bare Win press the dialog is recording. |
| `WM_KNOTS_COMMAND` | `dialog/knots/host.onCommand`: dialog work that replaces documents or touches the app, run between frames. |
| `WM_ENDSESSION` | `App.saveBeforeAbruptExit`: writes pending auto colours and log lines, since Windows may end the process once it returns. |

## The tick (`App.tick`)

Driven by `WM_TIMER` at `timer.scanIntervalMs`, or every 1 s while no EVE window is tracked and the dialog is closed. Throttled work uses `util/schedule.zig`: intervals measure from the tick's start and run on the nearest tick, so timer jitter never skips a whole interval.

```text
1. Scout.update(force_scan)         hook events + full EnumWindows at most every 1 s
2. Roster.sync / refreshConfig / setActive
                                    mirror Scout's windows, read new names' settings, record the foreground window
3. followNewClients                 auto-move clients that joined or logged in, start new ones minimized, verify pending moves
4. clearLoggedOutExclusions         drop cycle exclusions of clients that logged out
5. focus.afterActiveRefresh         record focus, resync cycle cursors
6. Roster.expireAlerts              drop expired alerts; flashing ones redraw
7. Roster.refreshMinimized          each client's minimized state, skipping the dragged one
8. ThumbnailSet.update              create, destroy or rename thumbnails to match the roster
9. ThumbnailSet.checkHoverZoom      enlarged preview under the cursor
10. AutoMinimizer.check             minimize idle clients on the roster
11. ChatlogMonitor.update + drain   findings to Roster (systems), Intel (pins), Notifier (alerts) and Scout
12. NotificationCenter.update       History Panel
13. MapPanel.update                 take new feed snapshots, render the map
14. Trackers.tick                   throttled push of rates and resources onto the roster; alerts via Notifier
15. travel_left_behind.check        every ~2 s
16. adjust tick interval            active scan rate or 1 s idle rate
17. publishState                    rewrite the state file when it changed; only when EVE_MAJ_STATE_FILE is set
```

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
| Eve Stars calls | `map/evestars_feed.zig` (one-shot per character list, send, route plan, Ansiblex list, and avoid list read or change; one at a time for each) | Atomic reply swap, taken on the tick or the panel's 100 ms timer. |
| Eve Stars activity | `map/activity_feed.zig` (one-shot every 10 min for the span's kill and jump sums; every 2 min for the last two hours' NPC kills while NPC delta waits for its hour before) | Atomic pointer swaps, taken on the tick or the panel's 100 ms timer. |
| Live sov campaigns | `map/campaigns_feed.zig` (one-shot every 10 s while a running sov timer is listed for the shown regions) | Atomic campaigns swap, laid over the stats snapshot on the tick. |
| zKillboard feed | `map/zkill_feed.zig` (one-shot runs while the Map Panel shows kills: each reads up to 50 R2Z2 files from where the last stopped, then names new ships and victims through ESI; the next starts at once while behind, else after 6 s) | Atomic batch swap, taken on the tick. The read position and asked-for IDs belong to the running run, or main between runs. |

### Worker lifecycles and limits

- **Audio workers:** TTS and sound share `notifications/worker.zig`'s `Worker`, started by the first alert that needs it and blocked on an event while idle. Once a second, `alert_effects.releaseUnused` stops either one that has no work, along with its engine, if no alert `rules.hasAudibleAlert` can let through still uses it.
  - `pushAlert` drops the oldest waiting alerts past a limit (`tts_max_waiting` for speech, 3 for sound).
  - `push` (voice settings) is never dropped.
- **One-shot threads:** Started through `util/detached.zig`, which counts them. At exit `main.zig` waits up to 2 s for them; if any are still running, it saves with `App.saveBeforeAbruptExit` and ends the process rather than freeing state they still hold.

### Cross-thread data

- Chatlog: `commands` (main → worker); `system_updates`, `notifications`, `session_starts`, `intel_sightings` (worker → main). Every other `ChatlogMonitor` field, its `Interpreter` included, is owned by one thread.
- `activity/tracker.zig` trackers: written by the worker, read by main, each under its own mutex.
- `CharacterIds` locks its own map.
- Hook bindings, held presses and the `requireEveFocus` filter: hook thread only. Main changes them through `hook_thread.call`, which runs the change there and waits for it.
  - The hook thread never logs while a hook is installed: waiting on the log lock could stall it past `LowLevelHooksTimeout`, and Windows would silently drop the hook. Changes report their outcome for main to log, and failed `WM_HOTKEY` posts are counted for `App.tick` to log.
- The worker reads `GlobalConfig` ore prices, so new global settings are adopted only while it's stopped.

## Window discovery, thumbnails and overlays

### Discovery and roster

- **`clients/scout.zig` (`Scout`):** `EnumWindows` matched against `windowFilters` (class name, then exe path for new windows only). `trinityWindow` titles give the character name.
  - Per-process `EVENT_OBJECT_NAMECHANGE` and `EVENT_OBJECT_DESTROY` hooks catch logins, logouts and closes between scans.
  - The destroy hook only records the hwnd; `Scout.update()` drops it before handing out the window list, so the slice a tick borrows never changes under it.
  - No creation hook: it would fire for every window on the desktop.
- **`clients/roster.zig` (`Roster`, tested):** One `Client` record per tracked window, kept for the whole run. `Roster.sync` mirrors `Scout` once per tick and is the only place clients are added or removed.
  - **Holds:** an owned copy of the name, the login time, the system (only `updateSystem` writes it, dropping stale log events; cleared at logout and when log monitoring goes off), Travel Mode's jumps, minimized state and idle start, the combat, mining and bounty readings, the alerts on screen and their throttle, when a click last brought it forward, the display name, character colour and minimize exclusion, what the last sync did to it (`last_sync`: joined or logged in), the active window (`active_hwnd`, written only by `setActive`), and a `revision` bumped on every change a view shows.
  - **Read by:** `Notifier`, Travel Mode, `AutoMinimizer`, `FocusTracker`, the membership hotkeys, the client list, the Map Panel's marks (`panel_host.Host.roster`), the Intel Panel's nearest client, and each thumbnail at render (`readingsOf`).
  - **Survives rebuilds:** A `ThumbnailSet` rebuild or profile switch keeps the roster, so nothing is carried across. `ThumbnailSet` copies each client's system onto its thumbnail when the `revision` moves and the text differs.
  - **Exclusions:** Cycle exclusions aren't copied onto it; the overlay and list ask `App.exclusions` by name, and a toggle bumps the matching clients' revisions (`Roster.bumpByName`).

### Thumbnails and rendering

- **`thumbnail/set.zig` (`ThumbnailSet`):** Owns the `ThumbnailWindow` list (linear search; a few dozen at most), keeps it in step with `Scout`, schedules layout, owns the `Renderer` and `DragOverlays`, and borrows App's `AutoColorStore`. Callers outside `thumbnail/` reach the hover zoom and drag overlays through its methods.
- **`thumbnail/window.zig` (`ThumbnailWindow`):** One per client in `Thumbnails` and `ThumbnailsAndList` modes, keyed by `source_hwnd` to its roster client. Each pairs two windows:
  1. A layered popup with the client's DWM thumbnail (`DwmRegisterThumbnail`), or a plain fill on `WM_ERASEBKGND` when live preview is off for that character. `applyLivePreview()` registers or drops it when settings change.
  2. A layered window on top with the GDI overlay (border, texts, connection map, alerts).
  - In `ClientList` and `Nothing` modes the set holds no thumbnails.
  - Shown or hidden (visibility hotkey, focus auto-hide) is set-wide, `ThumbnailSet.visibility`; only the region tool hides thumbnails one by one. Render state (active, inactive, alert, minimized, dragging) isn't stored: `effectiveRenderState()` derives it each render.
- Per-thumbnail state owned elsewhere: `render_cache` by `thumbnail/overlay.zig`, `is_dragged` by `drag/thumbnail.zig`.
- **Rendering:**
  - `thumbnail/renderer.zig`: owns `FontCache` and `HoverZoom`; skips a redraw when `RenderSettings` are unchanged.
  - `thumbnail/look.zig` (pure, tested): decides `RenderSettings` (compared field by field at comptime) from the profile and a `Subject`, the thumbnail's state as plain values.
  - `thumbnail/overlay.zig`: reads what only Win32 can tell (DPI, client size, minimized, the clock) into that `Subject`, then paints. The cache borrows thumbnail strings, so they're swapped only through `ThumbnailWindow.replaceText`, which nulls `render_cache.settings` first.
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
- `panels/panel_host.zig`: panels build their window from its `Context` (allocator, store, instance), handed out by `App.panelContext`, and reach `App` only through `Host`, App's `PANEL_HOST`: the current `ThumbnailSet`, and a `Request` (activate a client, show a system) that `App` runs.
- `panels/list_view.zig` + `list_look.zig` (pure, tested): the client list in `ClientList` and `ThumbnailsAndList` modes, drawn from the roster. `list_look` holds the row order (Tracked, Alphabetical, Configured, grouped by system) and is shared with the dialog preview.
- Shared by the panels in `panels/`:
  - `panel_look.zig` + `panel_chrome.zig`: fonts, header, footer buttons and frame for the History, Intel and Map panels, so they match.
  - `panel_lifecycle.zig`: creates and destroys those panels' windows from their `show` setting.
  - `panel_header.zig` (pure, tested) + `header_panel.zig`: the header (chevron, title, buttons) and window procedure the Client List, History and Intel panels share: header drag, snapping, saving where they landed.
  - `panel_menu.zig` + `panel_menu_look.zig` (pure, tested): the `⋯` menu, a borderless topmost window of its own, shared by those three panels.
  - `panel_section.zig`: their shared settings (keep on top, lock, opacity, folding, position), changed through `ProfileStore.updateSection`.
  - `history_rows.zig` + `history_look.zig` (pure, tested): category filter, merging repeats, and row drawing for `HistoryPanel`, `IntelPanel` (`panels/intel_panel.zig`) and the Map Panel's Intel card.
  - `popup_menu.zig` + `popup_look.zig`: a menu with two levels of submenu drawn inside a panel, plus tooltip placement; used by the Map Panel.
  - `segmented.zig` (pure, tested): the segmented control shared by the Map Panel's metric bar, the Intel Panel's range filter and the `⋯` menu.
  - `glyphs.zig` (pure, tested): the one icon set, built at compile time from strokes on a 16-unit grid with a 1.5 px line, so no image files ship. `dialog/knots/glyphs.zig` lays them out for the dialog.

## Map Panel

`panels/map_panel.zig` (`MapPanel`) is owned by `App`, so it survives `ThumbnailSet` rebuilds. It holds the feeds, pins, zKillboard kills, Eve Stars state, the window's lifecycle, its window procedure, and when it redraws.

### Panel UI and state (`panels/map/`)

| File | Role |
|---|---|
| `window.zig` | `MapPanelWindow`: the window, the regions it shows and saves, client marks, render signature, and layout, label and overview caches. |
| `input.zig` | Mouse and keyboard to `MapState` changes, menu actions and search. Hands back a redraw `Response`; doesn't import `map_panel.zig`. |
| `state.zig` | *(pure, tested)* `MapState`: what the map shows and what's under the cursor, hit testing included. |
| `paint.zig` | Draws a frame from `MapState` without changing it, handing back the row and popup boxes the next hit test needs. |
| `menu.zig` | *(pure, tested)* The right-click menus on a system and a region, and the Layers checklist. |
| `search.zig` | *(pure, tested)* The search's query, cursor, selection and results. |
| `marks.zig` | *(pure, tested)* The clients on the map. |
| `look.zig` | Sizes, colours, the panel's own markers (heat, kills, timers, portals, bridges) and its `Areas`. |
| `metric_segments.zig` | *(pure, tested)* Which metrics each metric bar segment shows, and the value a metric reads from a system. |
| `ownership.zig` | *(pure, tested)* Who holds the shown systems and regions, ranked, and each holder's colour. |
| `text.zig` | Tooltips, legends and titles. |
| `wormhole_list.zig` | *(pure, tested)* The Thera and Turnur card's list, one hub a tab, sorted by region, and its scrolling. |
| `timer_list.zig` | *(pure, tested)* The sov timer card's list, soonest first. |
| `destinations.zig` | Who can be sent an Eve Stars destination, the account's Ansiblex gates and saved avoid list (the only one; profiles keep none), a planned route, and how each call turned out. |
| `traffic.zig` | Eve Stars' kill and jump sums for the picked span, and the NPC kills' hour before, handed to the snapshot once its last hour matches. |

### Map data and feeds (`map/`)

| File(s) | Role |
|---|---|
| `universe.zig` | The embedded map, built by `.claude/tools/build_universe.py`. |
| `layout.zig` | Positions on CCP's flattened map, up to four regions side by side with the gates between them bent around systems; exits and portals (stubs to Thera, Turnur or an Ansiblex gate's far end); zoom and pan; label placement. |
| `overview.zig` | New Eden as bubbles, for picking a region. |
| `markers.zig` | *(tested)* Marks the Map Panel and the thumbnails' connection map draw alike: system markers, rings, gate colours, exits and intel halos. |
| `security.zig` | *(pure, tested)* A system's security as the game shows it, colour and text, for the map, client list, dialog preview and thumbnails. |
| `search.zig` | Names in the embedded map. |
| `jump_range.zig` | Ship jump ranges and the systems in reach, by the embedded map's true 3D positions. |
| `stats.zig` + `stats_feed.zig` | ESI figures, with each hour's change in NPC kills; incursions, sov campaigns and faction warfare through `incursions.zig`, `campaigns.zig` and `faction_warfare.zig`; EVE-Scout's storms and wormholes through `storms.zig` and `wormholes.zig`. |
| `campaigns_feed.zig` | A running sov timer's scores, refreshed every 10 s between snapshots. |
| `zkill.zig` + `zkill_feed.zig` | zKillboard's live kills, and the names of their ships and victims. |
| `holder_colors.zig` | Sovereignty colours: fixed for NPC factions, picked from logos for alliances. |
| `nearest.zig` | *(pure, tested)* Which positions are nearest a system by gate jumps, ties kept. Used by the chatlog worker's intel routing and the Intel Panel's "N jumps from X", each with its own range and filter. |
| `intel.zig` | *(pure, tested)* `Intel` on `App`: intel's one owner, holding the pins (`intel_pins.zig`) and the report history. Read by the Map Panel, Intel Panel, `Notifier` and the thumbnails' connection map. |
| `evestars.zig` + `evestars_feed.zig` | The Eve Stars route API: sends, route plans, the Ansiblex list and the saved avoid list. |
| `activity.zig` + `activity_feed.zig` | Eve Stars' kills and jumps summed over a span, and its NPC kills an hour at a time. |
| `system_links.zig` | A system's Dotlan, zKillboard and Eve Stars pages. |

### Drawing and input

- Hover, panning and the wheel redraw from their own messages, no more often than the screen refreshes, since the idle tick is a second apart; a short timer draws where a skipped move ended. `PanelWindow.present` paints at once, as `WM_PAINT` would otherwise wait out a moving mouse.
- A pan or zoom only re-places the layout; systems and gates are gathered again only when the regions change. Names are placed after each render measures the cards and legends over the map, and again only when the systems with sov timers change.
- A new intel pin or kill, or a system picked from the search, plays a ripple on its own fast timer, which stops once no ripple is playing. While sov timers or kills show, the render signature takes the minute too, so countdowns, ages and fading kill marks move on.
- A system with a sov timer gets a two-line name with the countdown under it, sized for the widest countdown so it never moves.
- The right-click menu and search results are drawn inside the panel. A click anywhere on the map activates the window, as other windows do.
- The search takes the keyboard, unbinding the hotkeys while it's open.

## Input and control

### Hotkeys and focus

- **Low-level hooks** (`hotkeys/keyboard_hook.zig`, `mouse_hook.zig`, shared `hook_bindings.zig`; `hooks.zig` routes each binding to its hook): `WH_KEYBOARD_LL` and `WH_MOUSE_LL` on their own thread instead of `RegisterHotKey`, so bare modifiers and mouse buttons bind, and a busy main thread never delays input or gets the hooks removed by Windows. Matches are posted as `WM_HOTKEY`.
  - Each press is decided at its first down: a swallowed press has its repeats and release swallowed too, so a client never sees a key-up without its down, which holding Ctrl through a cycle depends on.
  - With `requireEveFocus`, a bound key pressed outside a tracked EVE window passes through untouched.
  - With NumLock on, Windows sends Shift+Numpad as a fake Shift release then a navigation key; the hook and the dialog's recorder read it back as Shift+Numpad.
- **ID bands** (`hotkeys/bindings.zig`): 1000 per kind (cycle group 0, global action 1000, per-character 2000, profile switch 3000, assign group 4000, app 5000, URL 6000, close group 7000, minimize group 8000). `GLOBAL_BINDINGS` maps global actions to config fields and protocol actions.
- `hotkeys/manager.zig` (`HotkeyManager`): registration, the press gate (repeat, suspend, EVE focus), suspend and the dialog-recording pause, and the per-character hotkeys' cursors. Bindings come from `store.saved`, other settings from `store.live`.
- `hotkeys/plan.zig` (pure, tested): which hotkeys a profile binds, in registration order (globals first); `pressVerdict`, whether a press runs; and `conflicts`, combos bound twice outside a sharing chain, which the dialog refuses to save and registration warns about. The registered `Plan` owns the actions' index slices until `unregisterAll`.
- `hotkeys/commands.zig` (`Commands`): `run`, the one switch on `HotkeyAction`, and `runGlobal` / `runGroup` / `runGroupAt` for the tray and protocol links. `cycling.zig` picks the client each cycle hotkey activates, with decisions in `cycle_order.zig` (pure, tested); the cursors are `App.cycle`, reset whenever the hotkey manager is recreated.
- `control/focus.zig` (`FocusTracker`): the `EVENT_SYSTEM_FOREGROUND` hook; sets `Roster.active_hwnd`, feeds the thumbnail set, auto-minimize and cycling, and auto-hides thumbnails after focus leaves EVE.

### Activation and window actions

- `control/activation.zig` (`activate`): where every click, cycle and protocol switch ends. Restores, brings to the foreground, reconciles thumbnail states, dismisses click-suppressed notifications and syncs cycle cursors.
- `platform/focus_grant.zig`: `SetForegroundWindow` needs recent user input, so a real `RegisterHotKey` on an unreachable combo is triggered with `keybd_event`; its `WM_HOTKEY` carries the foreground right.
- `control/auto_minimize.zig`: minimizes idle clients from each roster client's minimized state, idle time and minimize exclusion; decisions in `minimize_rules.zig` (pure, tested).
- `clients/`: actions on EVE windows only (minimize, close, move, `animation.zig`'s `showClient`). Imports nothing from `thumbnail/`, `hotkeys/`, `drag/` or `control/`.

```text
Hotkey press → character switch:

WM_HOTKEY ─> timerWindowProc ─> HotkeyManager.handleHotkeyPress ─> Commands.run
  ─> cycling.* ─> Scout.getHwndByName ─> Outcome.activate
  ─> App.runHotkeyOutcome ─> activation.activate ─> focus_grant.forceSetForegroundWindow
```

### Drag and protocol links

- `control/thumbnail_input.zig`: thumbnail window procs, passed into `thumbnail/` by `App`, and the client list's row input (`list_view.RowInput`). Left click activates; Shift+click toggles the cycle exclusion; right drag moves the thumbnail (`drag/thumbnail.zig`; Ctrl moves all).
- `drag/`: snapping (`snap_math.zig`, pure) and `DragOverlays` (ghost outlines and the drag hint). Panel header drags are `panels/drag.zig`; `PanelWindow` tags its window so drags can find panels to snap to.
- `protocol/`:
  - `url.zig` (pure, tested): parses `evemajpreview://` URLs into a `Command`.
  - `ipc.zig`: sends the URL to the running instance over `WM_COPYDATA`, giving up after 5 s on a hung one. The timer window lets the message through UIPI, so an elevated instance still receives it.
  - `run.zig`: runs the command through the same code as its hotkey or tray item (group actions via `HotkeyManager.runGroupAction`), refusing one that closes clients or the app (`Command.closeAction`) unless `protocolLinks` is on.
  - `registry.zig`: registers the handler, again whenever the exe path changes.

## Log monitoring and trackers

`chatlog.zig` (`ChatlogMonitor`) finds and follows the logs and owns the queues; what their lines mean is `chatlog/interpret.zig`'s. Worker loop: `processCommands` → `pollLogFiles` → `rescanForNewLogs` → wait `poll_interval_ms`.

- **Main side:** `update()` queues add, remove and resolve-ID commands; `drain()` returns `Findings`, which `App.deliverChatlogFindings` routes to `Roster`, `Intel`, `Notifier` and `Scout`. The monitor never touches them.
- **Finding and reading logs:**
  - `chatlog/discovery.zig` (`LogFinder`): a character's newest log by cached ID (`*_<id>.txt`), else by reading the `Listener:` headers of the newest 64 files.
  - `chatlog/tail.zig` (`LogFile`): keeps the handle open, reads appended bytes, backs off when idle.
  - `chatlog/utf16.zig`, `lines.zig` (pure): decoding and parsing of system changes, jumps, undocks, file names and headers.
- **Interpreting (worker thread):**
  - `chatlog/interpret.zig` (`Interpreter`, worker only): each line to system changes, chat alerts, intel sightings, game events and tracker entries. It holds the alert rules, weapon filter, trackers and where each client is; the monitor sets them while the worker is stopped.
  - `chatlog/alert_rules.zig` + `routing.zig` (pure, tested): which chat lines alert and who gets them (nearest clients, else the listener or an unmuted stand-in), duplicates and cooldowns, and which system reports count (a repeated undock or Local is dropped, a jump never is, only gate jumps notify).
  - `notifications/gamelog_events.zig` (`classify`, pure): line → `Notification`.
  - `activity/lines.zig` (pure): combat, mining (priced from the ore table) and bounty parsers, feeding `activity/tracker.zig`'s ring-buffer windows.
  - `session_starts` backdates a character's login (Session Timer) via `Scout.backdateLogin`; the roster mirrors it on its next sync.
- **Main-thread samplers (`activity/`):**
  - `runtime.zig` (`Trackers`): matches trackers to the config while the worker is stopped, keeping history for those that stay enabled.
  - `resources.zig` samples CPU, RAM and VRAM (PDH) per client process; `ping.zig` pings each client's game server with asynchronous ICMP echoes polled each tick. Both follow `store.live`, so they preview before Save, and write onto the roster client's `stats` (`activity/stats.zig`) through `Roster.updateStats`.

## Notifications

- `notifications/notification.zig`: types, categories, placeholders, default text. `template.zig` (pure) fills `{name}` placeholders in custom text.
- `notifications/notifier.zig` (`Notifier`): what `App.notifier()` hands every caller that raises an alert (trackers, Travel Mode, hotkeys, the dialog's Test button, `App` itself). A copy is only pointers into `App`, so alerts land with or without a thumbnail set.
- `notifications/dispatch.zig`: shows a notification on a roster client if `rules.zig` (pure) allows it, and adds sound, speech, history and notified-queue entries. `stack.zig` holds a client's on-screen alerts and throttle timestamps, kept on the roster.
- `notifications/alert_effects.zig`: speech and sound, plus the session-only audio mute.
- The chatlog worker queues `Notification` payloads; text is rendered on the main thread.
- `notifications/center.zig` (`NotificationCenter` on `App`): the `history.zig` ring buffer, `notified_queue.zig`, `panels/history_panel.zig` and `panels/intel_panel.zig`. Survives `ThumbnailSet` rebuilds.
- `travel/`: left-behind detection; `stragglers.zig` is pure.

## Configuration model (`config.zig`, `config/`)

`config.zig` defines `Config` and re-exports every settings type; other modules import only it.

- One file per section (`thumbnail.zig`, `display.zig`, `panels.zig`, `intel.zig`, `behavior.zig`, `activity.zig`, `notifications.zig`, `chatlog.zig`, `characters.zig`, `hotkeys.zig`, `spaces.zig`, ...). Types holding saved settings are named `XxxConfig`, and a thumbnail text's look `XxxTextStyle`.
- A feature's behaviour has a section of its own that every view reads (`notifications`, `intel`, `combat`, `mining`, ...); a view keeps only how it draws it (`thumbnail.alertText`, `thumbnail.combatText`, ...).
- **Serialization and validation:**
  - `wire.zig`: generates each section's JSON shape and encode, decode, free and clone from its fields (`pub const Wire = wire.Wire(Self)`). Field-name conventions pick the encoding: `*Color` `u32` → hex string, `KeyList` → key code(s). `runtime_fields` aren't saved; `wire_defaults` supplies a missing key's default where the field's own default can't hold it (e.g. a non-empty list).
  - `readable.zig`: lenient load. Drops each field, item or entry that doesn't fit its type, so it falls back to its default alone. Only non-JSON fails: the file is copied to `profiles/backup/` and defaults are used.
  - `migrate.zig` (pure, tested): upgrades older profile JSON before parsing. `legacy_dpi.zig` scales positions a DPI-unaware process saved, for old profiles and the EVE-O, EVE-X and EVE-APM importers.
  - `ranges.zig`: per-type `ranges` tables and `zero_means_default`; every `validate()` is `ranges_mod.clamp(Self, self)`, which recurses into nested sections.
- **`store.zig` (`ProfileStore`):** the only writer of the running profile.
  - `live`: what the app shows, including unsaved dialog edits. Read by `ThumbnailSet` and panels.
  - `saved`: what's on disk. Read by setup-once consumers: `Scout` filters, hotkey bindings, chatlog, trackers, the tick timer.
  - Runtime changes (drags, tray toggles, group membership) apply to both and save immediately: `update` takes a patch from the root, `updateSection` one for a single named section.
  - `commit` (Save) clones `live` → `saved`; `discard` clones `saved` → `live`.
- **Other modules:**
  - `patch.zig`: path-addressed `set` / `insert` / `remove` / `move` ops; keyed lists (`characters`, `hotkeyGroups`, `thumbnailSpaces`) are addressed by runtime `id`. Used for imports.
  - `profiles.zig`: load with fallbacks, save, create (exclusive), copy, rename, backup and restore. Every name passes `validateName`.
  - `import/`: EVE-X / EVE-MultiPreview, EVE-APM (INI), EVE-O and own profiles → `Draft` → patch ops. Untested by design.
  - `global.zig`: `GlobalConfig` (last profile, cross-profile hotkeys, ore prices, log level, language).

## Configuration window (`dialog/`)

Immediate-mode (`knots` on Vulkan), main thread, with a nested message loop so the tick and tray keep running. Each frame reads settings and writes them straight back to `store.live`; there's no form state.

- `knots/host.zig`: window lifecycle, nested loop, close prompt, saved position. Every save goes through `saveChanges`, which refuses while `plan.conflicts` finds hotkey conflicts. Anything that replaces documents or touches the app is posted as `WM_KNOTS_COMMAND` and runs between frames.
- `knots/session.zig`: edits `store.live` and a `GlobalConfig` draft. Every change goes through `Ref.set` (or list `append` / `remove` / `move`), which copies strings, clamps, and asks `App` to restyle through `session.run`. Replaced strings are freed a frame later. Dirty means the profile differs from saved, or a Save with global changes failed. `save()` hands `App` the dirty flag and the global draft, which `App` adopts a copy of, so a failed save leaves the draft as typed.
- `knots/form.zig`: header, sidebar (tabs grouped under Clients, Display, Input, Alerts and App), open tab, footer, prompts. `knots/tabs/` has one file per tab, plus sections kept in their own files (`panel_settings.zig`, `window_filters.zig`, `chatlog.zig`, and `client_list.zig`, drawn on the Appearance tab). `widgets.openSharedSection` tags a section whose settings every profile shares.
- `knots/widgets.zig`, `bind.zig`, `style.zig`: layout pieces, setting-bound controls, and styles built on `palette.zig`.
- `knots/roster.zig`, `selection.zig` (pure, tested): a list tab's rows and which item its details show. `tabs/panel_preview.zig`: the panel previews' stage, frame, header and clickable parts.
- `knots/hotkey.zig`: the recording field; pauses live hotkeys while recording, draws its key caps compact when full size would overrun `widgets.controlsRoom`, and marks conflicting combos with their holders' names from `labels.zig`.
- `tools/`: `region_select.zig` (full-screen overlay for drawing a thumbnail space; math in `region_math.zig`), `esi_prices.zig` (Jita ore prices), `ultra_potato.zig` (patches EVE's graphics YAML).

## Module dependencies

- Direct calls, no event bus. Code is handed `*App` or just what it needs.
- Win32 callbacks have no context pointer: window procs and hooks read `app.g_app` (or `app.currentThumbnailSet()`) and pass it down; modules below them never read the global. `Scout` keeps a private pointer for its own hooks so it stays testable.
- A panel finds its own struct from the `hwnd`: its owner attaches it with `PanelWindow.attachOwner`, and the window proc reads it back with `panel_window.ownerOf`. Panels reach `App` only through `PANEL_HOST` (the Map Panel through `MapPanel.host`, set by `App.init`).
- The dialog reaches `App` only through `dialog/dialog_host.zig`: `host.init` takes App's `Context` (allocator, io, store, global settings, Scout, character IDs) and `DIALOG_HOST` (thumbnail set, timer window, save, requests), and hands back `DialogHooks`. `import_cycles.py` fails if `dialog/` imports `app.zig`.
- `platform/` depends on nothing app-specific. Win32 declarations live in `platform/win32.zig`, which never logs.
- Pure logic is split into its own file (marked "no I/O" in its header) and tested.

## Client simulator (`sim.zig`, `sim/`)

A second exe, `eve-maj-sim` (`zig build sim`), that stands in for EVE clients so the app can be tested without the game. It shares `dialog/knots/style.zig` and `widgets.zig` but nothing else of the app.

- `sim.zig`: entry point; runs in `%TEMP%\EveMajSimulator`. With `--client <name>` it becomes one client instead.
- `client_window.zig`: a client. One `trinityWindow` per process, titled `EVE - <name>`; the controller posts `WM_SIM_LOGIN` / `WM_SIM_LOGOUT` to change the title.
- `fleet.zig`: the controller. Copies itself to `exefile.exe` (Scout's filter needs that name), starts and ends client processes, and writes their chatlogs, gamelogs and channel logs.
- `lines.zig` *(pure, tested against `chatlog/lines.zig` and `gamelog_events.zig`)*: every log name, header and line it writes.
- `schedule.zig` (pure, tested): timed steps for bursts, routes and guided tests, run from a 100 ms timer so the window never blocks. `scenarios.zig`: the guided tests.
- `journal.zig`: the activity feed. `view.zig`, `window.zig`: the knots window. `win32_sim.zig`: Win32 declarations only the simulator uses, an allowed exception to keeping them in `platform/win32.zig`.

## End-to-end tests (`tools/ui_tests/`)

Python (stdlib and ctypes only) that drives the built app against simulated clients. Run `python tools/ui_tests/run.py [name-substring ...]` with the app closed, since it's single-instance.

- `harness.py`: copies the app into a temp folder with its own profile and global settings (protocol registration and update checks off), starts `eve-maj-sim --client` copies named `exefile.exe`, sends protocol links through a second launch, and presses keys only while a test client has focus.
- `diagnostics/state_file.zig`: with `EVE_MAJ_STATE_FILE` set, the app writes each thumbnail's current name, window handles, visibility and group badge, plus the active client, cycle exclusions, suspended hotkeys and each group's live members, as JSON, because a thumbnail window's title keeps the name it was created with. The harness joins it with what Win32 reports for positions and visibility.
- `run.py`: runs `tests/test_<area>.py`. Each module shares one sandboxed app, and each test switches it to a profile of its own; a failed test, or exclusions or suspended hotkeys left behind, restart it. `@fresh` tests get an app of their own, for global settings.
- `coverage.py`: lists every setting as `Struct.field`, read from `src/config/`, and the tests that claim it with `@covers`.

## Other modules

| Module | Role |
|---|---|
| `log.zig` | Buffered rotating file log, `Scoped(name)`, debug console. |
| `crash.zig` | Vectored and unhandled exception handlers, panic handler, minidump. |
| `palette.zig` | The app's colours, sizes and fonts; the GDI panels, the map's markers and the dialog (through `dialog/knots/style.zig`) build on it, so they match. |
| `tray.zig` | Tray icon and menu; its toggles run as hotkey actions through `App.commands().runGlobal`. |
| `update.zig` | GitHub release check. |
| `lang/` | UI strings by English key, one JSON file per language. |
| `platform/fonts.zig` | Bundled Cascadia and Geist, registered process-private; `create` makes every GDI font. |
| `platform/run_on_startup.zig` | The Run registry key, set or removed by `app.applyGlobalSettings`. |
| `platform/virtual_keys.zig` | VK codes, `KEY_NAMES`, mouse-chord encoding. |
| `platform/wic.zig` | Image decoding (portraits, alliance logos). |
| `util/` | Colour (OKLab picks), number format, HTTP (WinHTTP, with timeouts), schedule, strings, UTC time to Unix seconds, wildcard matching (`glob.zig`), crash-safe writes (`atomic_file.zig`). |
