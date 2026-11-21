# Architecture

How `src/` fits together. Settings are in [CONFIGURATION.md](CONFIGURATION.md), the build in [BUILDING.md](BUILDING.md), code style in `.claude/STYLE.md`.

## Overview

- One executable, `eve-maj-preview.exe`, root `src/main.zig`. Windows subsystem; a console opens only at log level `debug`.
- The configuration window runs in-process on the main thread (knots, Vulkan). `zig build config` runs the app with `--config`.
- `zig build test` runs `src/tests.zig`, which lists every module with tests. Tests build in Debug.
- `zig build check` type-checks the app without emitting a binary; ZLS runs it on save.
- knots is vendored in `deps/knots/`; local changes are marked `EVE-Maj patch` and listed in its `PATCHES.md`.

## Files on disk

All relative to the exe folder (`main.zig` sets the cwd there).

| Path | Contents | Owner |
|---|---|---|
| `profiles/<name>.json` | Per-profile `Config` | `config/profiles.zig` |
| `profiles/global.settings.json` | `GlobalConfig` | `config/global.zig` |
| `profiles/backup/` | Profiles deleted, reset, imported over, unreadable or backed up from the Backups tab, `<unix time>_<name>` | `config/profiles.zig` |
| `data/colors.json` | Generated system/character colours | `clients/auto_colors.zig` |
| `data/character_ids.json` | Character name → EVE ID | `chatlog/character_ids.zig` |
| `data/portraits/{id}.jpg` | Character portraits | `dialog/knots/portraits.zig` |
| `data/logo_colors.json` | Colour picked from each sov-holding alliance's logo, at most 200 before it starts again | `map/stats_feed.zig` |
| `logs/eve-maj.log`, `.old` | Log, rotated at 20 MB | `log.zig` |
| `logs/eve-maj-crash.dmp` | Minidump of the latest crash | `crash.zig` |

`config/files.zig`'s `migrateLegacyLayout` moves files older versions kept beside the exe into `data/` and `logs/`. Every save writes `<file>.<hex>.tmp` and renames it over the file; `sweepTempFiles` deletes the ones a killed process left in `profiles/`, `data/` and `data/portraits/`.

## Startup (`main.zig`)

1. Set per-monitor DPI awareness, install crash handlers.
2. Parse arguments (`arguments.zig`: `--profile`/`-p`, `--config`, `--protocol <url>`).
3. `--protocol`: forward to the running instance over `WM_COPYDATA` and exit. Done before the single-instance check.
4. Claim the `Global\EVE-Maj-Preview-SingleInstance` mutex. If taken, send `evemajpreview://config` to the running instance and exit.
5. Sweep leftover temp files, skipped if the working directory couldn't be set to the exe's folder. Load bundled fonts and start the hotkey hook thread, then `GlobalConfig`, `CharacterIds` and the profile into a `ProfileStore`, which `App.init` takes as `App.Loaded`; then set `app.g_app`, start the dialog host and load the language.
6. Build subsystems in dependency order: notification center → `Scout`'s event hooks → `ThumbnailSet` → `ChatlogMonitor` (worker stopped) → activity `Trackers` → start the chatlog worker.
7. Create the hidden timer window, focus hook, tray icon, update check thread.
8. Scan windows, populate thumbnails, add characters to the chatlog monitor.
9. Create the `HotkeyManager`, install the focus grant, start the tick timer.
10. Run the `GetMessageA` loop.

`App.deinit` tears down everything `App` owns in one sequence, each part before what it borrows, and copes with a startup that failed partway. `main.zig`'s own `defer`s cover only process-wide modules: the hook thread outlives `App.deinit`, which unregisters hooks through it, and the dialog host goes before it, while the store lives. `app.g_app` is cleared after `App.deinit`.

## `App` (`app.zig`)

Owns every long-lived subsystem. Main thread only.

| Field | Lifetime |
|---|---|
| `store` (`ProfileStore`), `global_settings`, `character_ids`, `scout`, `roster`, `auto_colors` (`AutoColorStore`), `exclusions`, `auto_move` (`AutoMoveVerifier`), `notifications` (`NotificationCenter`), `intel` (`Intel`), `focus`, `trackers`, tray | Whole run |
| `auto_minimizer` | Whole run; reset when a different profile loads |
| `thumbnail_set`, `hotkey_manager`, `chatlog_monitor` | Rebuilt on reload; heap pointers |
| `list_window` | Built and torn down with `thumbnail_set`; `ClientList` and `ThumbnailsAndList` modes only |

Rules:

- Rebuilt subsystems are read from `App` each time, never cached elsewhere.
- State that must survive a rebuild lives on `App` (exclusions, notification history, auto-minimize toggle).
- Every user command, from a hotkey, the tray or a protocol link, runs through `App.commands()`, a `hotkeys/commands.zig` `Commands` of pointers into App, so none waits on the `HotkeyManager` App rebuilds on each Save and profile switch. Each is handed App's current thumbnail set, and hands back an `Outcome` for what only App can do (activate a client, switch profile, toggle a panel, return to the last app), which `App.runHotkeyOutcome` runs. `ThumbnailSet` borrows only the store, exclusions and the notification center's history and notified queue (`dispatch.Records`). App passes in its window procs and destroy hook, so `thumbnail/` imports no input or panel code.

Reload entry points:

| Call | Trigger | Effect |
|---|---|---|
| `requestProfileSwitch` → `WM_SWITCH_PROFILE` → `switchProfile` | Tray, hotkey | Deferred to the next message-loop turn |
| `switchProfile` | Protocol, dialog | Loads the profile, then `restartSubsystems` |
| `saveSettings` (`DIALOG_HOST.save`) | Dialog Save | Commits the profile, `restartSubsystems` with the same store adopting a copy of the global draft, then writes and applies the global settings |
| `onLiveProfileEdited` (`DIALOG_HOST.run`) | Every dialog edit | Restyle/reflow; rebuilds the thumbnail set only on a view-mode change |

`restartSubsystems` runs the steps from `control/restart_plan.zig` (pure, tested): which subsystems are kept, paused or rebuilt, in what order, and what to bring back up if a step fails. A kept chatlog worker is paused until the new trackers are wired in and it has the profile's chat-alert rules (`apply_monitor_profile`). A new store is built before anything is torn down, so a load failure leaves the running profile intact.

## Main thread messages

`timerWindowProc` (`main.zig`) is the central dispatcher:

| Message | Handler |
|---|---|
| `WM_TIMER` `TICK_TIMER_ID` | `App.tick` |
| `WM_TIMER` `HIDE_DEBOUNCE_TIMER_ID` | `focus.onHideTimer` |
| `WM_HOTKEY` | `focus_grant.handleWmHotkey`, else `HotkeyManager.handleHotkeyPress`, which gates it and runs it through `Commands`; the outcome goes to `App.runHotkeyOutcome` |
| `WM_TRAYICON`, `WM_COMMAND` | `TrayIcon` |
| `TaskbarCreated` (registered) | `TrayIcon.handleTaskbarCreated`: re-adds the icon after Explorer restarts; the tick also retries a missing one every 5 s |
| `WM_COPYDATA` | `protocol/run.handleCopyData`: protocol URLs from a second process |
| `WM_SWITCH_PROFILE` | `App.runPendingProfileSwitch` |
| `WM_HOTKEYS_STATE_CHANGED` | Suspend/resume notification |
| `WM_WIN_KEY_CAPTURED` | `keyboard_hook.onWinKeyCaptured`: a bare Win press the config dialog is recording |
| `WM_KNOTS_COMMAND` | `dialog/knots/host.onCommand` |
| `WM_ENDSESSION` | `App.saveBeforeAbruptExit`: Windows may end the process once it returns, so pending auto colours and log lines are written first |

## The tick (`App.tick`)

Driven by `WM_TIMER` at `timer.scanIntervalMs`, or 1 s while no window is tracked and the dialog is closed.

```
Scout.update(force_scan)              hook events + full EnumWindows at most every 1 s
Roster.sync, refreshConfig, setActive mirror Scout's windows, read new names' settings; the foreground window is the active one
followNewClients                      auto-move clients that joined or logged in, start new ones minimized, verify pending moves
clearLoggedOutExclusions
focus.afterActiveRefresh              record focus, resync cycle cursors
Roster.expireAlerts                   drop expired alerts; flashing ones redraw
Roster.refreshMinimized               each client's minimized state, skipping the dragged one
ThumbnailSet.update                   create/destroy/rename thumbnails
ThumbnailSet.checkHoverZoom
AutoMinimizer.check                   over the roster's clients
ChatlogMonitor.update + drain         -> deliverChatlogFindings -> Roster (systems), Intel (pins), Notifier (alerts, intel list), Scout
NotificationCenter.update             History Panel
MapPanel.update                       takes new stats, renders the map
Trackers.tick                         throttled push of rates/resources onto the Roster; alerts via Notifier
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
| Dialog helpers | `pickers.zig`, `prices.zig`, `portraits.zig`, one-shot | A `util/handoff.zig` `Stack`, then a `WM_KNOTS_COMMAND` carrying no pointer |
| Map stats | `map/stats_feed.zig`, one-shot every 15 minutes while the Map Panel shows; after the figures, it fetches logos of alliances it hasn't seen | Atomic snapshot and logo colour swaps, taken on the tick |
| Eve Stars calls | `map/evestars_feed.zig`, one-shot per character list, send, route plan, Ansiblex list, and avoid list read or change, one at a time for each | Atomic reply swap, taken on the tick or the panel's 100ms timer |
| Eve Stars activity | `map/activity_feed.zig`, one-shot for the span's kill and jump sums every 10 minutes while a span past the hour shows, and for the last two hours' NPC kills every 2 minutes while NPC delta waits for its hour before | Atomic pointer swaps, taken on the tick or the panel's 100ms timer |
| Live sov campaigns | `map/campaigns_feed.zig`, one-shot every 10 s while a running sov timer is listed for the regions shown | Atomic campaigns swap, taken on the tick and laid over the snapshot's |
| zKillboard feed | `map/zkill_feed.zig`, one-shot runs while the Map Panel shows kills: each reads zKillboard's R2Z2 files from where the last stopped, up to 50, then names new ships and victims through ESI; the next starts once its batch is taken, at once while behind, 6 s at the newest file | Atomic batch swap, taken on the tick; the read position and asked-for ids belong to whichever run is going, or main between runs |

TTS and sound share `notifications/worker.zig`'s `Worker`, started by the first alert that needs it and blocked on an event while idle. Once a second, `alert_effects.releaseUnused` stops either one that has no work, along with its engine, if no alert `rules.hasAudibleAlert` can let through still uses it. Alerts go through `pushAlert`, which drops the oldest waiting alerts past a limit (speech: the profile's `tts_max_waiting`; sound: 3); voice settings go through `push` and are never dropped.

The one-shot threads (update check, clipboard uploads, dialog helpers, map stats, Eve Stars calls, zKillboard runs) are started through `util/detached.zig`, which counts them; `main.zig` waits up to 2 s at exit for them to finish before tearing down what they use; if any are still running, it saves with `App.saveBeforeAbruptExit` and ends the process rather than freeing state they still hold.

Cross-thread data:

- Chatlog: `commands` (main → worker); `system_updates`, `notifications`, `session_starts`, `intel_sightings` (worker → main). Every other `ChatlogMonitor` field is owned by one thread.
- `activity/tracker.zig` trackers: written by the worker, read by main, each under its own mutex.
- `CharacterIds`: locks its own map.
- Hook bindings, held presses and the require-EVE-focus filter: hook thread only. Main changes them through `hook_thread.call`, which runs the change there and waits for it. The hook thread never logs while a hook is installed, since waiting on the log lock could stall it past `LowLevelHooksTimeout` and Windows would silently drop the hook: changes report their outcome for main to log, and failed `WM_HOTKEY` posts are counted for `App.tick` to log.
- The worker reads `GlobalConfig` ore prices, so new global settings are adopted only while it's stopped.

## Window discovery and thumbnails

**`clients/scout.zig`** (`Scout`): `EnumWindows` matched against `windowFilters` (class name, then exe path for new windows only). `trinityWindow` titles give the character name. Per-process `EVENT_OBJECT_NAMECHANGE`/`DESTROY` hooks catch renames and closes between scans; the destroy hook only records the hwnd, and `update()` drops it before handing out the window list, so the slice a tick borrows never changes under it. No creation hook: it would fire for every window on the desktop.

**`clients/roster.zig`** (`Roster`, tested): one `Client` record per tracked window, kept by App for the whole run. `sync` mirrors Scout's window list once per tick, right after `Scout.update`, and is the only place clients are added or removed. It holds an owned copy of the name, the login time mirrored from Scout, the system (only `updateSystem` writes it, dropping stale log events; cleared at logout and when log monitoring goes off), Travel Mode's jumps, whether it was minimized and since when it's been idle (auto-minimize; the delay restarts on a profile switch), the activity readings (combat, mining and bounty rates cleared once monitoring is off), the alerts on screen and their throttle (expired each tick, cleared at logout, on a profile switch, and of log alerts once monitoring is off), when a click last brought it forward, the display name, character colour and minimize exclusion (`refreshConfig` reads them for new names each tick, and for everyone after a profile switch, Save or dialog edit), what the last sync did to it (`last_sync`: joined or logged in, which App's `followNewClients` acts on), the active window (`active_hwnd`, the foreground window whether a client's or not; only `setActive` writes it), and a `revision` bumped on every change a view shows. A thumbnail set rebuild or profile switch keeps it, so nothing is carried across. Read by the `Notifier`, Travel Mode, auto-minimize, focus, the membership hotkeys, the client list and the Map Panel's marks (through `panel_host.Host.roster`), the Intel Panel's nearest client, and each thumbnail at render (`readingsOf`); `ThumbnailSet` copies each system onto its thumbnail when the revision moves and the text differs. Cycle exclusions aren't copied onto it: the overlay and the list ask App's `Exclusions` by name, and a toggle bumps the matching clients' revisions (`bumpByName`).

**`thumbnail/set.zig`** (`ThumbnailSet`): the central mutable state. Owns the `ThumbnailWindow` list (linear search, a few dozen at most), keeps it in step with Scout, schedules layout and redraws. Holds the `Renderer` and a drag's ghost overlay and hint (`DragOverlays`), and borrows App's `AutoColorStore`; callers outside `thumbnail/` reach the hover zoom and drag overlays through its methods, not `renderer`.

**`thumbnail/window.zig`** (`ThumbnailWindow`): one per client in Thumbnails mode, keyed by `source_hwnd` to its roster client. It holds only what drawing needs: two HWNDs, the render cache, the text it last drew and the profile settings it draws with, while the game state it draws is read from the roster at each render:

1. A layered popup with the client's DWM thumbnail (`DwmRegisterThumbnail`), or, with the live preview off for that character, no registration and a plain fill painted on `WM_ERASEBKGND`. `applyLivePreview()` registers or drops it when settings change.
2. A layered window on top with the GDI overlay (border, texts, notifications).

In `ClientList`/`Nothing` view modes the set holds no thumbnails: the list draws from the roster. Shown or hidden (visibility hotkey, focus auto-hide) is set-wide, `ThumbnailSet.visibility`, which each thumbnail follows; only the region tool hides thumbnails one by one. Render state (active, inactive, alert, minimized, dragging) isn't stored; `effectiveRenderState()` derives it each render, from the client's alerts on the roster among other things.

Per-thumbnail state owned by other modules:

| Field | Owner |
|---|---|
| `render_cache` | `thumbnail/overlay.zig` |
| `is_dragged` | `drag/thumbnail.zig` |

Rendering:

- `thumbnail/renderer.zig`: skips a redraw when `RenderSettings` are unchanged. Owns `FontCache` and `HoverZoom`.
- `thumbnail/look.zig` (pure, tested): decides `RenderSettings` (compared field by field at comptime) from the profile and a `Subject`, the thumbnail's state as plain values.
- `thumbnail/overlay.zig`: reads what only Win32 can tell (DPI, client size, minimized, the clock) into that `Subject`, then paints the settings. The cache borrows thumbnail strings, so they're swapped only through `ThumbnailWindow.replaceText`, which nulls `render_cache.settings` first.
- `thumbnail/draw.zig`: text, border and exclusion primitives.
- `platform/gdi_overlay.zig`: DIB-backed layered windows, text helpers, `HintBox`, class registration.
- `util/pixel_buffer.zig`: pure ARGB drawing (rects, anti-aliased lines and circles, rounded frames, alpha fix-up).
- `platform/panel_window.zig`: `PanelWindow`, shared by the client list and the History, Intel and Map panels. The first three are borderless layered overlays presented through `UpdateLayeredWindow`; `initNative` makes the Map Panel a normal window with a title bar, painted on `WM_PAINT`.
- `panels/header_panel.zig`: the window class and procedure the client list and the History and Intel panels share: header drag, snapping, saving where they landed, then the panel's own click or message handler. These panels reach App only through `panels/panel_host.zig`'s `Host`, App's `PANEL_HOST`: the current thumbnail set, and a `Request` (activate a client, show a system) that App runs. Every panel builds its window from the same file's `Context` (allocator, store, instance), which `App.panelContext` hands out.
- `panels/list_view.zig` + `list_look.zig`: `ClientList` and `ThumbnailsAndList` view modes; App owns the window, built and torn down with the thumbnail set. Its rows are the roster's clients; it works out their name, system and active colours and hide-from-list from the profile and `AutoColorStore` each render, and follows the thumbnails' visibility and drag through a `View` (as if shown with no set). `list_look` is pure, tested and shared with the dialog preview; it holds the row order (Tracked, Alphabetical, Configured, grouped by system) and the lines and headings the rows lay out in.
- `panels/panel_look.zig` + `panel_chrome.zig`: what the History, Map and Intel panels share, so they match: fonts, header, footer buttons, frame, and when they show.
- `panels/panel_lifecycle.zig`: when those three have a window. Their `show` setting makes one; the tray, a hotkey or the Map Panel's close button turns `show` off.
- `panels/history_rows.zig`: draws the rows the History and Intel panels list; `history_look.zig` (pure, tested) works them out: the category filter, merging repeats within the merge window, and a merged row's names. The Map Panel draws them, two lines each, in its Intel card; `panels/intel_panel.zig` is the Intel Panel's own window for when it's detached.
- `panels/map_panel.zig` + `panels/map/`: the Map Panel's window and input; see [Map Panel](#map-panel).
- `panels/popup_menu.zig` + `popup_look.zig`: a menu with two levels of submenu, drawn inside a panel, plus tooltip placement. The Map Panel's right-click menu and search results use it; a panel supplies its own rows and actions.
- `panels/glyphs.zig` (pure, tested): the one icon set the dialog, map and panels draw, built at compile time from strokes on a 16-unit grid at whatever size a caller needs, with the same 1.5px line, so no image files ship. `dialog/knots/glyphs.zig` lays them out as canvas pixels.
- `panels/panel_header.zig` (pure, tested) + `header_panel.zig`: the header the Client List, History and Intel panels share (chevron, title, buttons) and its window procedure; `panel_chrome.zig` draws it.
- `panels/panel_menu.zig` + `panel_menu_look.zig` (pure, tested): the ⋯ menu, a borderless topmost window of its own under the button, shared by those three panels; each supplies what it shows and what its rows do.
- `panels/panel_section.zig`: what those three panels' settings sections share (keep on top, lock, opacity, folding, position), changed through `ProfileStore.updateSection` by the section's name.
- `panels/segmented.zig` (pure, tested): the segmented control the Map Panel's metric bar, the Intel Panel's range filter and the ⋯ menu's Order row share.
- `panels/palette.zig`: the configuration window's colours, sizes and fonts, so the GDI panels match it.
- `thumbnail/hover_zoom.zig` + `layout/zoom.zig`: click-through enlarged copy under the cursor.

Layout (`layout/`, mostly pure):

- `spaces.zig`: which thumbnail space a character goes to, and its cell.
- `region_grid.zig`: grid math inside a space.
- `placement.zig`: per-space cells and hand-placed positions.
- `monitors.zig`: monitor bounds and DPI.
- `thumbnail/arrange.zig`: applies the layout to windows.

## Map Panel

`panels/map_panel.zig` holds `MapPanel`: the feeds, stats, pins, zKillboard's kills and their names, and Eve Stars destinations, routes, avoid list, Ansiblex gates and activity, the window's lifecycle, its window procedure and when it redraws. App owns the panel, so it survives thumbnail set rebuilds.

The panel's own files in `panels/map/`:

- `window.zig`: `MapPanelWindow`, the window, the regions it shows and saves, and each frame's preparation: client marks, the render signature, and the layout, label and overview caches.
- `input.zig`: mouse and keyboard to `MapState` changes, the right-click menu's actions and the search. It reaches past the window only through a `Context` (destinations, host) and hands back a `Response` saying how to redraw, so it doesn't import `map_panel.zig`.
- `state.zig` (pure, tested): `MapState`, what the map shows and what's under the cursor, hit testing included.
- `paint.zig`: draws a frame from `MapState` without changing it, handing back only the rows and popup boxes the next hit test needs.
- `menu.zig` (pure, tested): the right-click menus on a system and on a region, and the Layers checklist; their rows and what each press asks for.
- `search.zig` (pure, tested): the search's query, its cursor and selection, and its results.
- `marks.zig` (pure, tested): the clients on the map.
- `look.zig`: sizes, colours, markers and the panel's `Areas`.
- `metric_segments.zig` (pure, tested): which metrics each metric bar segment shows, and the value a metric reads from a system.
- `ownership.zig` (pure, tested): who holds the shown systems and regions, ranked, and each holder's colour.
- `text.zig`: tooltips, legends and titles.
- `wormhole_list.zig` (pure, tested): the Thera and Turnur card's list, one hub a tab, sorted by region, and its scrolling.
- `timer_list.zig` (pure, tested): the sov timer card's list, the shown regions' campaigns, soonest first.
- `destinations.zig`: who can be sent an Eve Stars destination, the account's Ansiblex gates and saved avoid list (the only one; profiles keep none), a planned route, and how each call turned out.
- `traffic.zig`: Eve Stars' kill and jump sums for the picked span, and the NPC kills' hour before, which it hands the snapshot once its last hour matches.

What it draws from, in `map/`:

- `universe.zig`: the embedded map, built by `.claude/tools/build_universe.py`.
- `layout.zig`: positions on CCP's flattened map, with up to four regions packed side by side and the gates between them bent around systems; exits, and portals (stubs to Thera, Turnur or an Ansiblex gate's far end, set each time those change); zoom and pan; label placement.
- `overview.zig`: New Eden as bubbles, for picking a region.
- `search.zig`: names in the embedded map.
- `jump_range.zig`: ship ranges and the systems in reach, by the embedded map's true 3D positions.
- `stats.zig` + `stats_feed.zig`: ESI figures, with each hour's change in NPC kills carried from the snapshot before; ESI's incursions, sov campaigns and faction warfare through `incursions.zig`, `campaigns.zig` and `faction_warfare.zig`, a running timer's scores refreshed between snapshots by `campaigns_feed.zig`; and EVE-Scout's storms and Thera's and Turnur's connections through `storms.zig` and `wormholes.zig`.
- `zkill.zig` + `zkill_feed.zig`: zKillboard's live kills, and the names of their ships and victims.
- `holder_colors.zig`: sovereignty colours; NPC factions' are fixed, alliances' picked from their logos.
- `nearest.zig` (pure, tested): which positions are nearest a system by gate jumps, ties kept. The chatlog worker's intel routing (within a rule's range, unmuted clients) and the Intel Panel's "N jumps from X" (any range, falling back to the first EVE client) both use it, each with its own range and filter.
- `intel.zig` (`Intel` on `App`, pure, tested): intel's one owner, holding the pins (`intel_pins.zig`, systems named in intel channels) and the report history the Intel Panel and the map's Intel card list. App hands it each sighting; the Map Panel, the Intel Panel and the thumbnails' connection map read it, and the `Notifier` lists each report there, measured from the nearest client.
- `evestars.zig` + `evestars_feed.zig`: the Eve Stars route API: sends, route plans, the Ansiblex list and the saved avoid list.
- `activity.zig` + `activity_feed.zig`: Eve Stars' kills and jumps summed over a span, and its NPC kills an hour at a time.
- `system_links.zig`: a system's pages on the web.

Drawing and input:

- Hover, panning and the wheel redraw from their own messages, since the idle tick is a second apart, but no more often than the screen refreshes; a short timer draws where a skipped move ended.
- `PanelWindow.present` paints at once, as `WM_PAINT` would otherwise wait out a moving mouse.
- A pan or zoom only re-places the layout; the systems and gates are gathered again only when the regions change.
- The menu and search results are drawn in the panel.
- A click anywhere on the map activates the window, as other windows do.
- Names keep clear of the cards over the map: they're placed after each render measures the chrome, the Intel, Thera and Turnur and sov timer cards, and the legends.
- A new intel pin or kill, or a system picked from the search, plays a ripple on its own fast timer, which stops once no ripple is playing.
- While sov timers or kills show, the render signature takes the minute too, so countdowns, ages and fading kill marks move on.
- A system with a sov timer gets a two-line name, the countdown under it, kept clear of the timer's square and sized for the widest countdown so it never moves; names are placed again only when the systems with timers change.
- The search takes the keyboard, unbinding the hotkeys while it's open.

## Input and control

- **Hotkeys** go through `WH_KEYBOARD_LL`/`WH_MOUSE_LL` (`hotkeys/keyboard_hook.zig`, `mouse_hook.zig`, shared `hook_bindings.zig`; `hooks.zig` routes each binding to its hook), not `RegisterHotKey`, so bare modifiers and mouse buttons bind. Matches are posted as `WM_HOTKEY`. The hooks run on their own thread, so a busy main thread never delays input or gets them removed by Windows. Each key or button press is decided at its first down: a swallowed press has its repeats and release swallowed too, so a client never sees a key-up without its down, which holding Ctrl through a cycle depends on. With `requireEveFocus`, a bound key pressed outside a tracked window passes through untouched. With NumLock on, Windows sends Shift+Numpad as a fake Shift release then a navigation key; the hook and the config dialog's recorder read it back as Shift+Numpad.
- **IDs** (`hotkeys/bindings.zig`): bands of 1000 per kind (cycle group 0, global action 1000, per-character 2000, profile switch 3000, assign group 4000, app 5000, URL 6000, close group 7000, minimize group 8000). `GLOBAL_BINDINGS` maps global actions to config fields and protocol actions.
- **`hotkeys/manager.zig`** (`HotkeyManager`): registration, the press gate (repeat, suspend, EVE focus), suspend and the dialog-recording pause, and the per-character hotkeys' cursors in its key map. Bindings come from `store.saved`; other settings from `store.live`.
- **`hotkeys/commands.zig`** (`Commands`): `run`, the one switch on `HotkeyAction`, and `runGlobal`/`runGroup`/`runGroupAt` for the tray and protocol links. The cycle cursors it moves are App's `cycle`, reset whenever the hotkey manager is recreated.
- **`hotkeys/plan.zig`** (pure, tested): which hotkeys a profile binds, with their IDs, actions and descriptions in registration order (globals first), and `pressVerdict`, whether a press runs. The registered `Plan` owns the actions' index slices until `unregisterAll`.
- **`hotkeys/cycling.zig`**: every cycle hotkey, each returning the client to activate. Decisions are in `cycle_order.zig` (pure, tested).
- **`control/activation.zig`** (`activate`): where every click, cycle and protocol switch ends. Restore, foreground, reconcile thumbnail states, dismiss click-suppressed notifications, sync cycle cursors.
- **`platform/focus_grant.zig`**: `SetForegroundWindow` needs recent user input. A real `RegisterHotKey` on an unreachable combo is triggered with `keybd_event`; its `WM_HOTKEY` carries the foreground right.
- **`control/focus.zig`** (`FocusTracker`): the `EVENT_SYSTEM_FOREGROUND` hook; sets the roster's active window and feeds the thumbnail set, auto-minimize and cycling, with or without a thumbnail set; auto-hides thumbnails after focus leaves EVE.
- **`control/auto_minimize.zig`**: minimizes idle clients, reading each roster client's minimized state, idle time and minimize exclusion; decisions in `minimize_rules.zig` (pure, tested).
- **`clients/`**: actions on EVE windows only (minimize, close, move, `animation.zig`'s `showClient`). Imports nothing from thumbnail, hotkey, drag or control.
- **`control/thumbnail_input.zig`**: thumbnail window procs, passed into `thumbnail/` by App, and the client list's row input (`list_view.RowInput`). Left click → `activate`; shift-click → exclusion toggle; right drag → `drag/thumbnail.zig` (Ctrl moves all).
- **`drag/`**: snapping (`snap_math.zig` pure), and `DragOverlays` (ghost outlines and the drag hint). Panel header drags are `panels/drag.zig`; `PanelWindow` tags its window so drags can find panels to snap to.
- **`protocol/`**: `url.zig` parses `evemajpreview://` URLs into a `Command` (pure, tested); `ipc.zig` sends the URL text itself to the running instance over `WM_COPYDATA`, giving up after 5 s on a hung one (the timer window lets the message through UIPI, so an elevated instance still receives it); `run.zig` parses it there and runs it through the same code as its hotkey or tray item (group actions via `HotkeyManager.runGroupAction`), refusing a command that closes clients or the app (`Command.closeAction`) unless its `protocolLinks` setting is on; `registry.zig` registers the handler, again whenever the exe path changes.

Hotkey press → character switch:

```
WM_HOTKEY -> timerWindowProc -> HotkeyManager.handleHotkeyPress -> Commands.run
  -> cycling.* -> Scout.getHwndByName, returned as Outcome.activate
  -> App.runHotkeyOutcome -> activation.activate -> focus_grant.forceSetForegroundWindow
```

## Log monitoring

`chatlog.zig` (`ChatlogMonitor`). Worker loop: `processCommands` → `pollLogFiles` → `rescanForNewLogs` → wait `poll_interval_ms`.

- Main side: `update()` queues add/remove/resolve-ID commands; `drain()` returns `Findings`, which `App.deliverChatlogFindings` routes to Scout and `ThumbnailSet`. The monitor never touches either.
- `chatlog/discovery.zig` (`LogFinder`): finds a character's newest log by cached ID (`*_<id>.txt`), else by reading `Listener:` headers of the newest 64 files.
- `chatlog/tail.zig` (`LogFile`): keeps the handle open, reads appended bytes, backs off when idle.
- `chatlog/utf16.zig`, `chatlog/lines.zig`: decoding and line parsing (pure). System changes, jumps, undocks, file names, headers.
- `chatlog/alert_rules.zig` + `chatlog/routing.zig` (pure, tested): which chat lines alert and who gets them (nearest clients, else the listener or an unmuted stand-in), duplicates and cooldowns, where each client is, and which system reports count (a repeated undock or Local is dropped, a jump never is, only gate jumps notify).
- `notifications/gamelog_events.zig` (`classify`): line → `Notification` (pure).
- `activity/lines.zig`: combat/mining/bounty line parsers (pure), feeding `activity/tracker.zig`'s ring-buffer windows.
- `session_starts` backdates a character's login (Session Timer) via `Scout.backdateLogin`; the roster mirrors it on its next sync, and the thumbnail's timer reads it from there.

`activity/runtime.zig` (`Trackers`) matches trackers to the config while the worker is stopped, keeping history for those that stay enabled. `activity/resources.zig` samples CPU/RAM/VRAM (PDH) per client process on the main thread, and `activity/ping.zig` pings each client's game server with asynchronous ICMP echoes it polls each tick; both follow the live config, so they preview before Save. Every reading lands on the roster client's `stats` (`activity/stats.zig`) through `Roster.updateStats`, so it survives a thumbnail set rebuild.

## Notifications

- `notifications/notification.zig`: types, categories, placeholders, default text.
- `notifications/notifier.zig` (`Notifier`): what `App.notifier()` hands out to every caller that raises an alert (trackers, Travel Mode, hotkeys, the dialog's Test button, App itself); a copy is only pointers into App, so alerts land with or without a thumbnail set.
- `notifications/dispatch.zig`: shows a notification on a roster `Client` if `rules.zig` (pure) allows it; adds sound, speech, history and notified-queue entries.
- `notifications/template.zig`: fills `{name}` placeholders in custom text (pure).
- `notifications/stack.zig`: a client's on-screen alerts, with throttle timestamps; kept on the roster.
- `notifications/center.zig` (`NotificationCenter` on `App`): the `history.zig` ring buffer the History Panel lists, `notified_queue.zig`, `panels/history_panel.zig`, `panels/intel_panel.zig`. Survives thumbnail set rebuilds.
- `notifications/alert_effects.zig`: speech and sound, plus the session-only audio mute.
- The chatlog worker queues `Notification` payloads; text is rendered on the main thread.
- `travel/`: left-behind detection; `stragglers.zig` is pure.

## Configuration model (`config.zig`, `config/`)

`config.zig` defines `Config` and re-exports every settings type; other modules import only it.

- One file per section (`thumbnail.zig`, `display.zig`, `panels.zig` (the Client List and the History, Map and Intel panels, one section each), `intel.zig` (how intel marks systems, for every view), `behavior.zig`, `activity.zig`, `notifications.zig`, `chatlog.zig`, `characters.zig`, `hotkeys.zig`, `spaces.zig`, ...). Types holding saved settings are named `XxxConfig`.
- **`wire.zig`**: generates each section's JSON shape and encode/decode/free/clone from its fields (`pub const Wire = wire.Wire(Self)`). Field-name conventions pick the encoding: `*Color` u32 → hex string, `KeyList` → key code(s). `runtime_fields` aren't saved; `wire_defaults` supplies defaults a runtime field can't hold.
- **`readable.zig`**: lenient load. Drops each field, item or entry that doesn't fit its type, so it falls back to its default alone. Only non-JSON fails (file copied to `profiles/backup/`, defaults used).
- **`migrate.zig`**: upgrades older profile JSON before parsing (pure, tested).
- **`ranges.zig`**: per-type `ranges` tables and `zero_means_default`; every `validate()` is `ranges_mod.clamp(Self, self)`, which recurses into nested sections.
- **`store.zig`** (`ProfileStore`): the only writer of the running profile.
  - `live`: what the app shows, including unsaved dialog edits. Read by `ThumbnailSet` and panels (as `*const Config`).
  - `saved`: what's on disk. Read by setup-once consumers: Scout filters, hotkey bindings, chatlog, trackers, timer.
  - Runtime changes (drags, tray toggles, group membership) apply to both and save immediately: `update` takes a patch from the root, `updateSection` one for a single named section.
  - `commit` (Save) clones `live` → `saved`; `discard` clones `saved` → `live`.
- **`patch.zig`**: path-addressed `set`/`insert`/`remove`/`move` ops; keyed lists (`characters`, `hotkeyGroups`, `thumbnailSpaces`) are addressed by runtime `id`. Used for imports.
- **`profiles.zig`**: load with fallbacks, save, create (exclusive), copy, rename, backup, restore. Every name passes `validateName`.
- **`import/`**: EVE-X / EVE-MultiPreview, EVE-APM (INI), EVE-O and own profiles → `Draft` → patch ops. Untested by design.
- **`global.zig`**: `GlobalConfig` (last profile, cross-profile hotkeys, ore prices, log level, language).

## Configuration window (`dialog/`)

Immediate-mode (knots on Vulkan), main thread, nested message loop so the tick and tray keep running. Each frame reads settings and writes them straight back; there's no form state.

- `knots/host.zig`: window lifecycle, nested loop, close prompt, saved position. Every save goes through `saveChanges`, which refuses while hotkeys conflict. Anything that replaces documents or touches the app is posted as `WM_KNOTS_COMMAND` and runs between frames.
- `knots/session.zig`: edits `store.live` and a `GlobalConfig` draft. Every change goes through `Ref.set` (or list `append`/`remove`/`move`): copies strings, clamps, asks App to restyle through `session.run`. Replaced strings are freed a frame later. Dirty = differs from saved, or a Save with global changes failed. `save()` hands App the profile's dirty flag and the global draft, which App adopts a copy of, so a failed save leaves the draft as typed.
- `knots/form.zig`: header, sidebar, open tab, footer, prompts. The sidebar groups tabs under Clients, Display, Input, Alerts and App. `knots/tabs/`: one file per tab, plus sections kept in their own files (`panel_settings.zig`, `window_filters.zig`, `chatlog.zig`, and `client_list.zig`, drawn on the Appearance tab). `widgets.openSharedSection` tags a section whose settings every profile shares.
- `knots/widgets.zig`, `bind.zig`, `style.zig`: layout pieces, setting-bound controls, styles.
- `knots/roster.zig`, `selection.zig`: a list tab's rows and which item its details show (pure, tested). `tabs/panel_preview.zig`: the panel previews' stage, frame, header and clickable parts.
- `knots/hotkey.zig`: recording field; pauses live hotkeys while recording. Draws its key caps compact when full size would overrun the room `widgets.controlsRoom` reports beside the row's label. Finds conflicting combos and names their holders, using `labels.zig`'s hotkey labels.
- `tools/region_select.zig`: full-screen overlay for drawing a thumbnail space, with its own hint box; math in `region_math.zig`.
- `tools/esi_prices.zig`: Jita ore prices. `tools/ultra_potato.zig`: patches EVE's graphics YAML.
- `run_on_startup.zig`: the Run registry key.

## Module dependencies

- Direct calls, no event bus. Code is handed `*App` or just what it needs.
- Win32 callbacks have no context pointer: window procs and hooks read `app.g_app` (or `app.currentThumbnailSet()`) and pass it down, except the panels', which get App's `PANEL_HOST` (the Map Panel through `MapPanel.host`, set by `App.init`) and find what they belong to through their window's owner. Modules below them never read the global. Scout keeps a private pointer for its own hooks so it stays testable.
- A panel finds its own window struct from the `hwnd`: its owner attaches it with `PanelWindow.attachOwner` once it's stored, and the window proc reads it back with `panel_window.ownerOf`.
- The dialog reaches App only through `dialog/dialog_host.zig`, as the panels do through `PANEL_HOST`: `host.init` takes App's `Context` (allocator, io, store, global settings, Scout, character IDs) and `DIALOG_HOST` (thumbnail set, timer window, save, requests), and hands back `DialogHooks` (redraw, is open, close for exit, the live global settings, open at a panel's settings page). `import_cycles.py` fails if `dialog/` imports `app.zig` again.
- `platform/` depends on nothing app-specific. Win32 declarations live in `platform/win32.zig`, which never logs.
- Pure logic is split into its own file (marked "no I/O" in its header) and tested.

## Client simulator (`sim.zig`, `sim/`)

A second exe, `eve-maj-sim` (`zig build sim`), that stands in for EVE clients so the app can be tested without the game. It shares the dialog's `style.zig` and `widgets.zig` but nothing else of the app.

- `sim.zig`: entry point. Runs in `%TEMP%\EveMajSimulator`. With `--client <name>` it becomes one client instead.
- `client_window.zig`: a client. One `trinityWindow` per process, titled `EVE - <name>`; the controller posts `WM_SIM_LOGIN`/`WM_SIM_LOGOUT` to change the title.
- `fleet.zig`: the controller. Copies itself to `exefile.exe` (scout's filter needs that name), starts and ends client processes, and writes their chatlogs, gamelogs and channel logs.
- `lines.zig`: every log name, header and line it writes (pure, tested against `chatlog/lines.zig` and `gamelog_events.zig`).
- `schedule.zig`: timed steps for bursts, routes and guided tests, run from a 100 ms timer so the window never blocks (pure, tested).
- `scenarios.zig`: the guided tests. `journal.zig`: the activity feed. `view.zig`, `window.zig`: the knots window.
- `win32_sim.zig`: Win32 declarations only the simulator uses, an allowed exception to keeping them in `platform/win32.zig`.

## Other modules

| Module | Role |
|---|---|
| `log.zig` | Buffered rotating file log, `Scoped(name)`, debug console |
| `crash.zig` | Exception handlers, panic handler, minidump |
| `tray.zig` | Tray icon and menu; its toggles run as hotkey actions through `App.commands().runGlobal` |
| `update.zig` | GitHub release check |
| `lang/` | UI strings by English key, per-language JSON |
| `platform/fonts.zig` | Bundled Cascadia and Geist, registered process-private; `create` makes every GDI font |
| `platform/virtual_keys.zig` | VK codes, `KEY_NAMES`, mouse-chord encoding |
| `platform/wic.zig` | Image decoding (portraits, alliance logos) |
| `util/` | Colour (OKLab picks), number format, HTTP (WinHTTP, with timeouts), schedule, strings |
