# Changelog

## [Unreleased]

### Added
- Intel Map: region and New Eden map with live intel, characters, Sov, incursions, storms, jump ranges and search
- Intel Map layers: zKillboard kills, sov timers, Thera & Turnur, Faction Warfare and Ansiblex gates
- Eve Stars: set destinations from the map
- Chat alerts: keyword and intel alerts for any chat channel, with bundled sounds
- Cloaked Can't Warp game event
- Panels: Always on Top, Lock Position, and snapping to each other
- Intel panel: range filter, jump counts, mute, and show on map
- Client List: group by system
- Client List: optional totals line adding up every client's rates
- Mining rate per minute or per hour
- Intel Map: kills and jumps over 1h, 24h or 7d from Eve Stars
- Intel Map: Show Route with alternatives
- Intel Map: NPC delta right away with an Eve Stars token
- Per-character Hide from Client List setting
- Simulator has its own icon
- Intel Map: Scroll Out to New Eden setting; a fast scroll-out stops at the whole region
- Blank thumbnails: turn off the live preview per profile or per character, with a fill color or a dimmed border color
- End-to-end test suite against simulated clients
- Config dialog controls named for screen readers and automation
- Style guide and source checks in the repo, run in CI
- Manual placement map shows unsaved thumbnails where they are, and follows them live
- Hide Taskbar Over Clients: taskbar goes behind the active client, even one smaller than the screen

### Changed
- Client List, History and Intel panels redesigned, with collapsible headers and a ⋯ settings menu
- Panels, map and config window share one look, font, icon set and colours
- Config window: settings regrouped into Clients, Display, Panels, Input, Alerts and App
- Notifications are now called alerts
- Log Monitoring is shared by every profile
- Softer default colours for damage, mining and bounty rates
- Taking Damage cooldown defaults to 60 s
- Client List rates show their units, like the thumbnails
- ISK shows billions as `b`
- Eve Stars: avoided systems come from your Eve Stars saved list, no longer stored in profiles
- Eve Stars token stored encrypted with Windows DPAPI
- Config window: preview popovers match the rest of the dialog
- Hide Thumbnail no longer hides the client list row
- Rate overlays stay hidden until measured, instead of showing ??
- Built with Zig 0.17.1
- Client List rates have their own switches, independent of the thumbnail overlays
- Client List rate popovers show the averaging, update interval and unit settings shared with thumbnails
- Mining overlay settings moved from the Mining tab into the Mining Rate popovers
- Thumbnail text popovers no longer hide settings behind Advanced Mode
- Rate units renamed to m3 Per and ISK Per
- Config window: Text Overlays, Client List and Alert History previews edit parts from a list under the preview instead of in popovers
- Config window: font, size and weight share one row
- Systems, Travel Mode jumps and activity readings survive a profile switch
- Intel panel: its own font, timestamp and merge settings, no longer the History panel's
- Import Settings: Alert Options is its own section, apart from Thumbnail Appearance
- Profiles: alert, text overlay and intel settings regrouped by feature; older versions reset them
- Startup carries on without log monitoring, or with no windows found, when either fails
- Client List: stat prefixes spaced as on the thumbnails, e.g. "IN: 412"
- CI checks formatting; map generator moved to `tools/`
- Release scripts tracked in the repo; Discord webhooks stored encrypted outside it
- Update check logs a short excerpt of GitHub's reply
- CI type-checks the simulator
- Changelog moved to docs/; older versions match their release notes
- Unit tests for alert history, the notified queue and log interpretation
- Unit tests for hotkey press handling
- Unit tests for Intel Map marker and gate colours
- Style check catches decl literals after `try` and abbreviated constants
- Moved off std APIs Zig 0.17 deprecates; style check blocks them
- Struct literals typed on the left; style check enforces it
- Speech and sound alerts use the app allocator instead of a memory page per alert
- Region overlay resets all of its state each time it opens
- Source checks fail on allow-list entries that match nothing
- Source checks catch stale names and files in ARCHITECTURE.md
- Receiver style rule sees teardown helpers and writes through captures
- App tick split into named phases; subsystem restart moved to control/restart.zig; fields grouped by lifetime

### Fixed
- Profiles: a queued action drops a leftover restore backup
- Dragged panels stay under the cursor instead of lagging behind
- Alert types set only in part in a profile keep their own defaults
- A newly opened client no longer leaves auto-hidden thumbnails hidden or counts as the last app
- Blank thumbnails showed black until hovered or moved
- Panel fills at a canvas edge are clipped instead of skipped
- Game Events: the Mining Idle and Stopped settings no longer say the mining rate is off while the Client List shows it
- Tray and link commands no longer fail while a Save or profile switch is applied
- Auto-move still corrects a client that was loading during a profile switch
- Sound and speech alerts no longer keep a thread running once no alert uses them
- Client List updates at once when a setting changes
- Region edit hint matches the mode it falls back to
- Config window: a failed Save keeps your edits and stays unsaved, so it can be retried
- Hotkeys: non-US keys like AZERTY `<` can be bound
- Same system showing different unique colours across thumbnails
- Client List: Client 2 sorts before Client 10
- Characters tab: selection no longer jumps after Discard
- A briefly locked settings file or profile no longer resets settings or stops the app starting
- Panels: ⋯ menu no longer falls behind its panel when Keep on Top is turned on
- Leftover `.tmp` files from interrupted saves are cleaned up at startup
- Downloads are capped in size, and logged error replies are truncated
- EVE-O Preview import: RWin hotkeys now fire
- Messages from other programs can no longer crash the app
- Intel Map: kill names no longer pile up in memory over long runs
- Config window: character portraits load a few at a time
- Game Events: custom sounds on Fleet Follow and Fleet Regrouped no longer crash the app
- Config window: settings search no longer crashes on the panels' Layout sections
- Config window: settings search no longer crashes with a preview popover open
- Map Panel no longer shrinks when moved on a screen above 100% scaling
- Map Panel: Always on Top pin lights in the accent colour like the other panels'
- Alert History lists alerts held back by focus, a click or the cooldown
- Game Events hints say held-back alerts still appear in Alert History
- Client List keeps its own position instead of moving the thumbnails' start position
- Placement tab: Thumbnail Spaces card fits all of a space's settings without scrolling
- Tray: Minimize and Close Group act on the saved groups, like their hotkeys
- Update check opens only this app's release pages
- Intel Panel hides on focus loss after a profile detaches it from the map

## [1.0.9] - 2026-10-29

### Changed
- Config & Interface Redesign: Massive rework from Webview2 HTML/CSS to pure Zig.

## [1.0.7] - 2026-09-23

### Added
- Comma lists and wildcard patterns in System Colors (e.g. `Jita, Amarr`, `J######`).
- Setting to turn off the "Hotkeys suspended/resumed" notification.
- Config dialog now remembers its window position between launches.

### Changed
- Unique System and Character Name Colors are now clearly distinct and stay the same across restarts.
- Unique Character Border Colors is now a saved setting instead of a one-time fill.

### Fixed
- System Colors now match regardless of case and spaces.
- System Colors hint no longer says overrides need Unique System Colors.
- Restore Saved Position on Login no longer repeatedly re-grabs focus while a client is still loading; it waits for the window to settle and corrects it once.

## [1.0.6] - 2026-09-21

### Added
- Test notification button.
- "Restore Saved Position on App Startup" setting.
- Advanced re-check interval and count settings for saved window position moves.

### Fixed
- Saved window position sometimes not applied on login.
- All-clients hotkey cycle position now syncs when a client is focused manually.
- Thumbnail DWM rect now updates on login and on not-logged-in-space resize.

## [1.0.5] - 2026-09-20

### Added
- "Hover Cursor" setting for thumbnails.
- "Edit Region" button and clear button for Thumbnail Space regions, with Save/Cancel in the selection overlay.
- "Cap Thumbnail Size" and "Hide Thumbnails During Region Selection" settings for the Not-Logged-In Thumbnail Space.
- Bundled Cascadia Code fonts and third-party license notice.

### Changed
- Thumbnail Space selection overlay redone: draw, then resize or move before confirming.

## [1.0.4] - 2026-09-19

### Added
- "Cap Thumbnail Size at Configured Size" setting for Thumbnail Space, off by default.
- Config dialog is now resizable.

### Changed
- Thumbnail Space grid now grows one column/row at a time as thumbnails spawn, instead of re-optimizing the whole grid per count.
- Auto-minimize now tracks the last-active client per monitor, so one stays visible on each.

### Fixed
- Hotkey and detail-panel label columns no longer stay misaligned after the post-load DPI resize.
- Config dialog no longer saves the position of a minimized client.

## [1.0.3] - 2026-09-18

### Added
- Not-Logged-In Thumbnail Space: separate auto-fit region for pending logins.
- "Hide Thumbnails During Region Selection" setting.
- "Restore Saved Positions" item in the system tray menu.
- "Don't Close Clients On Login Screen" setting for Close All.
- "Click Through Thumbnails" setting.

### Changed
- Thumbnail Space fills one column to capacity before starting another.

### Fixed
- "Move Logged-Out Characters to the End" now reliably sorts them last.
- Chatlog worker's character ID map and pending-character set now mutex-guarded.
- Log rotation drops the stale entry for the old file path.
- Chatlog line parsing and initial scan now log silent give-up paths.

## [1.0.2] - 2026-09-16

### Added
- Separate settings to show/hide the Damage/Bounty/Mining text overlay prefix.
- "Snap to Other Characters' Ghost Positions" setting, independent of the ghost border display toggle.
- "Disable Update Checks" setting in the config dialog.
- Confirm-before-close when the dialog has real unsaved changes.
- Custom sound alerts (.wav/.mp3) per notification type, with a per-event volume and a Test button in the config dialog.
- Notice on the Notifications tab and in the System Name/DPS/Mining/Bounty overlay popovers when Log Monitoring is disabled.

### Changed
- Removed the redundant single-item sub-nav under Combat/Bounty Overlay tabs.
- Removed leftover debug `console.log` statements from the config dialog.
- Combat overlay's "Window" and "Text Color" labels now match the wording used on Mining/Bounty/Resources.
- Removed the global "Enable Text-to-Speech" master switch - each event type's own TTS checkbox is now self-contained.

### Fixed
- Hotkey input shows "Bind..." instead of clipping "Click to bind" when the field is too narrow.
- Advanced Mode now applies globally instead of resetting per profile.

## [1.0.1] - 2026-09-14

### Changed
- Removed the 100px min-size clamp on thumbnail space width/height (was silently overriding a smaller dragged region).

## [1.0.0] - 2026-09-13

- Initial release.
