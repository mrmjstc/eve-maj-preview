# Configuration Reference

Every setting EVE-Maj Preview reads, by file and JSON key. The config dialog writes all of these; hand-editing is supported.

## Contents

- [Files](#files)
- [Loading rules](#loading-rules)
- [Value formats](#value-formats)
- [Profile](#profile): [top level](#top-level) · [thumbnail](#thumbnail) · [thumbnail.notifications](#thumbnailnotifications) · [timer](#timer) · [display](#display) · [thumbnailSpaces](#thumbnailspaces) · [snapping](#snapping) · [interaction](#interaction) · [exclusion](#exclusion) · [autoMinimize](#autominimize) · [autoMovePosition](#automoveposition) · [closeAll](#closeall) · [chatlog](#chatlog) · [combat](#combat) · [mining](#mining) · [bounty](#bounty) · [resources](#resources) · [travel](#travel) · [hotkeys](#hotkeys) · [hotkeyGroups](#hotkeygroups) · [characters](#characters) · [systemColors](#systemcolors) · [windowFilters](#windowfilters)
- [Global settings](#global-settings)
- [Command line and protocol](#command-line-and-protocol)

## Files

Paths are relative to the executable's folder.

| Path | Contents |
|---|---|
| `profiles\<name>.json` | A profile. `default.json` is created on first run and can't be deleted. |
| `profiles\global.settings.json` | [Global settings](#global-settings), shared by all profiles. |
| `profiles\backup\<unix time>_<name>.json` | Deleted profiles, and profiles that failed to parse. Listed in the dialog's Backups tab. |
| `profiles\global.settings.json.bak` | Global settings file that failed to parse. |
| `data\colors.json` | Generated unique system/character colours (64 most recent of each). Written when the last client closes or on exit. Delete to reassign. |
| `data\character_ids.json` | Character IDs read from log file names. Rebuilt from logs if deleted. |
| `data\portraits\<id>.jpg` | Character portraits, downloaded once. Delete one to refetch it. |
| `logs\eve-maj.log`, `eve-maj.log.old` | Log, and the previous one. |
| `logs\eve-maj-crash.dmp` | Minidump from the last crash. |

Profile file names: `<name>.json` with no path separators or `:*?"<>|`, not starting with `.`. Names created in the dialog are 1–16 characters of letters, digits, space, `-`, `_`.

## Loading rules

- Unknown keys are ignored.
- A missing key takes its default.
- A value of the wrong type or format (bad colour, unknown enum, text for a number) is dropped with a log warning; that setting takes its default. A bad list item is dropped alone; a bad notification type resets only that type.
- A number outside its range is clamped, with a log warning. Fields marked **0 = default** treat `0` as "use the default".
- A file that isn't valid JSON loads as all defaults; the original is kept (see [Files](#files)).
- Profiles are saved with `null` optionals omitted, colours as 8-digit hex and hotkeys as hex codes.
- `formatVersion` below 3 migrates on load: `display.layoutMode`/`regionX`/`regionY`/`regionWidth`/`regionHeight`/`spacing`/`regionFitOrder`/`regionFitDirection`/`regionFitLimitToThumbnailSize` become an `Everyone` space (enabled only if `layoutMode` was `RegionFit`, with `takesUnassigned` and `takesLoginScreen`); `display.notLoggedInSpace*` becomes a `Login Screen` space ahead of it. Below 2, character `position`s are rescaled from DPI-unaware pixels.
- A profile with `thumbnailSpaces` but no `display.placementMode` gets `ThumbnailSpaces` if any space is enabled.

## Value formats

| Format | Syntax |
|---|---|
| **colour** | `"0xAARRGGBB"`. Also accepted: `0X`, `#`, or no prefix. Six digits read as alpha `00`. Text colours ignore alpha (always opaque); borders, backgrounds and the exclusion overlay use it, so a 6-digit colour there is invisible. |
| **keys** | A key name (`"F9"`), a combo (`"Ctrl+Alt+F9"`), a hex code (`"0x278"`), an array of up to 4 of these (any one triggers), or `null`/omitted for unbound. Saved back as hex: low byte = virtual key, bits 8–11 = modifiers (Alt `0x1`, Ctrl `0x2`, Shift `0x4`, Win `0x8`). Unreadable keys are skipped with a warning; extra keys past 4 and duplicates are dropped. |
| **position** | `TopLeft` `TopCenter` `TopRight` `LeftCenter` `Center` `RightCenter` `BottomLeft` `BottomCenter` `BottomRight` |
| **weight** | `Regular` `Bold` `Italic` `BoldItalic` |
| **font size** | 6–72 |
| **offset** | Pixels from the anchor, −500–500 |
| **opacity** | 51–255 (255 = opaque) |
| **pixels** | Logical (96 DPI) pixels, scaled per monitor. Saved screen positions: x −3840–7680, y −2160–4320. |

**Key names** (case-insensitive): `F1`–`F24`, `A`–`Z`, `0`–`9`, `Numpad0`–`Numpad9`, `NumpadAdd` `NumpadSubtract` `NumpadMultiply` `NumpadDivide` `NumpadDecimal`, `Left` `Right` `Up` `Down`, `PageUp` `PageDown` `Home` `End` `Insert` `Delete`, `Space` `Tab` `Enter` `Backspace` `Pause` `CapsLock` `NumLock` `ScrollLock` `PrintScreen` `Menu`, `;` `=` `,` `-` `.` `/` `` ` `` `[` `\` `]` `'` (shifted forms `:` `<` `_` `>` `?` `~` `{` `|` `}` `"` also accepted), `VolumeMute` `VolumeDown` `VolumeUp` `MediaNext` `MediaPrevious` `MediaStop` `MediaPlayPause`, `MButton` `XButton1` `XButton2` `WheelUp` `WheelDown`, and bare `Ctrl` `Alt` `Shift` `Win` as the trigger key.

**Modifiers**: `Ctrl`/`Control`, `Alt`, `Shift`, `Win`/`LWin`/`RWin`. A modifier can't also be the trigger (`Shift+Shift` is rejected).

## Profile

### Top level

| Key | Type | Default | Notes |
|---|---|---|---|
| `app` | string | `"eve-maj-preview"` | Rewritten on save. |
| `formatVersion` | int | `3` | Read only to migrate; rewritten on save. |
| `accentColor` | colour | `0xFFD9A441` | Config dialog accent for this profile. No effect on overlays. |

Sections: `thumbnail`, `timer`, `display`, `snapping`, `interaction`, `autoMinimize`, `autoMovePosition`, `exclusion`, `closeAll`, `chatlog`, `combat`, `mining`, `bounty`, `resources`, `travel`, `hotkeys` (objects); `windowFilters`, `characters`, `systemColors`, `hotkeyGroups`, `thumbnailSpaces` (arrays).

### thumbnail

**Size and visibility**

| Key | Type | Default | Range / values | Notes |
|---|---|---|---|---|
| `width` | int | `200` | 50–3840 | |
| `height` | int | `112` | 50–2160 | |
| `thumbnailOpacity` | int | `255` | opacity | Overridden per character by `characters[].opacity`. |
| `applyOpacityToOverlayTexts` | bool | `true` | | Opacity also applies to texts, text backgrounds and borders. |
| `activeThumbnailHidden` | bool | `false` | | Hide the focused client's thumbnail. |
| `hideWhenNoEveFocus` | bool | `false` | | Hide all thumbnails while no EVE client has focus. |
| `hideDebounceMs` | int | `500` | 0–5000 | Delay before hiding. |
| `showText` | bool | `true` | | Master switch for every text overlay. |

**Borders**

| Key | Type | Default | Range / values |
|---|---|---|---|
| `showBorderWhenFocused` | bool | `true` | |
| `borderWidth` | int | `2` | 1–50 |
| `borderColor` | colour | `0xFFD9A441` | |
| `borderStyle` | enum | `Solid` | `Solid` `Dashed` `Dotted` `Double` `DiagonalHatch` `DashDot` `CornerBrackets` |
| `showBorderWhenInactive` | bool | `false` | |
| `inactiveBorderWidth` | int | `2` | 1–50 |
| `inactiveBorderColor` | colour | `0xFF606060` | |
| `inactiveBorderStyle` | enum | `Solid` | as `borderStyle` |
| `useUniqueCharacterBorderColors` | bool | `false` | Generated per-character focused border colour. `characters[].borderColors.activeBorderColor` wins. |

**Character name**

| Key | Type | Default | Range / values |
|---|---|---|---|
| `showCharacterName` | bool | `true` | |
| `characterNameColor` | colour | `0x00FFFFFF` | |
| `characterNameBgColor` | colour | `0xE6000000` | |
| `useUniqueCharacterNameColors` | bool | `false` | Generated per-character colour. `characters[].nameColor` wins. |
| `characterNameFontName` | string | `"Segoe UI"` | |
| `characterNameFontSize` | int | `12` | font size |
| `characterNameFontWeight` | enum | `Regular` | weight |
| `characterNamePosition` | enum | `TopLeft` | position |
| `characterNameOffsetX`, `characterNameOffsetY` | int | `0` | offset |

**System name** (needs chatlog monitoring)

| Key | Type | Default | Range / values |
|---|---|---|---|
| `showSystemName` | bool | `false` | |
| `systemNameColor` | colour | `0x00FFFFFF` | |
| `systemNameBgColor` | colour | `0xE6000000` | |
| `useUniqueSystemColors` | bool | `false` | Generated colour for systems without a `systemColors` entry. |
| `systemNameFontName` | string | `"Segoe UI"` | |
| `systemNameFontSize` | int | `12` | font size |
| `systemNameFontWeight` | enum | `Regular` | weight |
| `systemNamePosition` | enum | `BottomLeft` | position |
| `systemNameOffsetX`, `systemNameOffsetY` | int | `0` | offset |

**Group badge**: names of the character's hotkey groups that have `showBadge` (unnamed groups show their 1-based number).

| Key | Type | Default | Range / values |
|---|---|---|---|
| `showQuickGroupBadge` | bool | `true` | |
| `quickGroupBadgeColor` | colour | `0xFF44FF44` | |
| `quickGroupBadgeBgColor` | colour | `0xE6000000` | |
| `quickGroupBadgePosition` | enum | `RightCenter` | position |
| `quickGroupBadgeOffsetX`, `quickGroupBadgeOffsetY` | int | `0` | offset |
| `quickGroupBadgeFontName` | string | `"Segoe UI"` | |
| `quickGroupBadgeFontSize` | int | `12` | font size |
| `quickGroupBadgeFontWeight` | enum | `Regular` | weight |

**Session timer**: time logged in, as `42m` or `3h 07m`; resets on logout. A character already logged in at startup counts from its gamelog's session start (with chatlog monitoring) or from when the app first saw it.

| Key | Type | Default | Range / values |
|---|---|---|---|
| `showSessionTimer` | bool | `false` | |
| `sessionTimerColor` | colour | `0x00FFFFFF` | |
| `sessionTimerBgColor` | colour | `0xE6000000` | |
| `sessionTimerPosition` | enum | `RightCenter` | position |
| `sessionTimerOffsetX` | int | `0` | offset |
| `sessionTimerOffsetY` | int | `-24` | offset |
| `sessionTimerFontName` | string | `"Segoe UI"` | |
| `sessionTimerFontSize` | int | `12` | font size |
| `sessionTimerFontWeight` | enum | `Regular` | weight |

**Exclusion overlay**: drawn on characters excluded from cycling.

| Key | Type | Default | Values |
|---|---|---|---|
| `exclusionOverlayStyle` | enum | `X` | `X` (diagonal cross), `DiagonalSlash` (one band), `DiagonalHatch` (45° stripes), `Checkerboard`, `SolidTint` (whole thumbnail), `CircleSlash` (no-entry sign), `None` |
| `exclusionOverlayColor` | colour | `0x33A62222` | |

**Per-state overrides**: `active`, `inactive`, `alert`, `minimized`, `dragging`. Not shown in the dialog. Each is an object; an omitted or `null` field falls back to the base setting.

| Key | Type | Notes |
|---|---|---|
| `borderWidth` | int | 1–50 |
| `borderColor` | colour | |
| `borderStyle` | enum | as `borderStyle` |
| `textColor` | colour | Character name colour. Generated/per-character colours win. |
| `textBgColor` | colour | Background of every text overlay. |
| `showBorder` | bool | |
| `showThumbnail` | bool | Default `true`; `active` defaults to `null` (follows `activeThumbnailHidden`). |

### thumbnail.notifications

Event popups on thumbnails, from game and chat logs (needs [chatlog](#chatlog)) and from your own actions.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `true` | | Thumbnail popups. Client List uses `display.listViewShowNotifications`. |
| `position` | enum | `Center` | position | |
| `offset_x`, `offset_y` | int | `0` | offset | |
| `font_name` | string | `"Segoe UI"` | | |
| `font_size` | int | `12` | font size | |
| `font_weight` | enum | `Regular` | weight | |
| `color` | colour | `0xFFFFFFFF` | | Text colour for types without `text_color`. |
| `bg_color` | colour | `0xE6000000` | | |
| `suppress_click_duration_ms` | int | `2000` | 0–60000 | Window for `suppress_when_clicked`. |
| `tts_volume` | int | `100` | 0–100 | |
| `tts_rate` | int | `0` | −10–10 | SAPI rate. |
| `tts_speak_character_name` | bool | `true` | | Prefix speech with `"<character>, "`. |
| `tts_use_display_name` | bool | `false` | | Speak `displayName` instead, when set. |
| `notified_cycle_retention_seconds` | int | `30` | 5–600 | How long a notified character stays in the `hotkeyCycleNotified` queue; renotifying resets it. |
| `type_configs` | object | | | One object per type name below. |

**`type_configs.<Type>`**

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `true` | | |
| `duration_ms` | int | `10000`; `3000` for user-action types | 0–60000 | |
| `throttle_ms` | int | `10000`; `0` for user-action types | 0–300000 | Per thumbnail, from the last one shown. `0` = off. |
| `suppress_when_focused` | bool | `false` | | Skip while that client has focus. |
| `suppress_when_clicked` | bool | `false` | | Skip for `suppress_click_duration_ms` after clicking the thumbnail. |
| `show_hidden_thumbnail` | bool | `false` | | Show a thumbnail hidden by focus auto-hide or the visibility toggle while active. `hideThumbnail` still wins. |
| `show_border` | bool | `false` | | Draw the alert border. |
| `flash_border` | bool | `false` | | Blink the border 4× (150 ms phases) first. Needs `show_border`. |
| `border_color` | colour? | `null` | | `null` = `alert` state / `borderColor`. |
| `text_color` | colour? | `null` | | `null` = `color` (thumbnails) / `display.listViewNotificationColor` (Client List). |
| `tts_enabled` | bool | `false` | | Speak it. No global switch. |
| `sound_enabled` | bool | `false` | | Play `sound_path`. No global switch. |
| `sound_path` | string? | `null` | | Absolute path to `.wav` or `.mp3`. |
| `sound_volume` | int | `100` | 0–100 | |
| `custom_text` | string? | `null` | | Replaces built-in text (shown and spoken). Supports placeholders and `\n` (max 3 lines; one line in lists). Falls back to built-in if a used placeholder has no value. |
| `custom_text_alt` | string? | `null` | | `custom_text` for the type's second state (see table). |

**Types**: user-action types are marked **U**; types shown on every client are marked **all**.

| Type | Category | Fires on | Placeholders | Alt state |
|---|---|---|---|---|
| `FleetInvite` | Fleet | Fleet invite | `{pilot}` | |
| `FleetFollow` | Fleet | Fleet follow command | `{leader}` | |
| `FleetRegroup` | Fleet | Fleet regroup command | `{leader}` | |
| `FleetDisband` | Fleet | Fleet disbanded | | |
| `MiningCompression` | Mining | Compression done | `{ore}`, `{result}` | |
| `AsteroidDepleted` | Mining | Asteroid depleted | `{module}` | |
| `MiningIdle` | Mining | See [mining](#mining) | | |
| `MiningStopped` | Mining | See [mining](#mining) | | |
| `CargoFull` | Mining | `Ship's cargo hold is full` | `{module}` | |
| `CrystalBroke` | Mining | Mining crystal depleted | `{module}`, `{crystal}` | |
| `TakingDamage` | Combat | See [combat](#combat) | | |
| `WarpScrambled` | Combat | Scram landed on you | `{attacker}` | |
| `WarpDisrupted` | Combat | Point landed on you | `{attacker}` | |
| `Decloak` | Combat | Decloaked by proximity | `{object}` | |
| `ObservatoryDecloak` | Combat | Decloaked by Mobile Observatory | | |
| `CloakFailed` | Combat | Cloak failed (too close) | | |
| `BombLauncherEmpty` | Combat | Bomb launcher out of charges | `{module}` | |
| `SelfDestruct` | Combat | Self-destruct started | | aborted |
| `WarpBubble` | Combat | Caught in a warp disruption field | `{object}` | |
| `Docking` | Navigation | Action blocked while docking | | |
| `AutopilotReached` | Navigation | Waypoint reached | | |
| `AutopilotApproaching` | Navigation | Autopilot approaching | | |
| `JumpRange` | Navigation | Too far from gate | | |
| `AggressionCantJump` | Navigation | Gate refuses jump (aggression) | | |
| `ConduitJump` | Navigation | Conduit Field jump | `{system}` | |
| `JumpCloning` | Navigation | Clone jump | | |
| `SystemChange` | Navigation | New solar system | `{system}` | |
| `TravelLeftBehind` | Navigation | See [travel](#travel) | `{system}`, `{group_system}` | |
| `ConversationInvite` | General | Conversation invite | `{pilot}` | |
| `GroupMembership` | General | **U** Group assign key | `{group}` | removed |
| `CycleExclusion` | General | **U** Exclusion toggled | | included |
| `HotkeySuspend` | General | **U**, **all** Hotkeys suspended | | resumed |
| `ProfileSwitch` | General | **U**, **all** Profile loaded | `{profile}` | |
| `AutoMinimizeToggle` | General | **U**, **all** Auto-minimize toggled | | off |
| `SavedPositionMove` | General | **U** Moved by `hotkeyMoveToSavedPositions` | | |
| `Generic` | General | Other game events | `{message}` | |

Every type except `HotkeySuspend`, `ProfileSwitch` and `AutoMinimizeToggle` also has `{character}`. Placeholder names are case-insensitive; unknown ones are left as typed. Category drives the History Panel filters.

### timer

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `scanIntervalMs` | int | `50` | 50–1000 | Main tick. Drops to 1 s while no client is open and the dialog is closed. |

### display

**Placement**

| Key | Type | Default | Range / values | Notes |
|---|---|---|---|---|
| `placementMode` | enum | `Manual` | `Manual` `ThumbnailSpaces` | `Manual` ignores `thumbnailSpaces`. |
| `viewMode` | enum | `Thumbnails` | `Thumbnails` `ClientList` `Nothing` | `Nothing`: no visuals; tracking, hotkeys, alerts still run. |
| `startX`, `startY` | int | `10` | screen | Spawn point for thumbnails with no saved position. Monitor-relative when `monitorIndex` is set. |
| `newThumbnailSpacing` | int | `10` | 0–200 | Horizontal gap when lining up new thumbnails from `startX`/`startY`. |
| `monitorIndex` | int? | `null` | 0–9 | `null` = absolute coordinates. |
| `useMonitorWorkArea` | bool | `true` | | Exclude the taskbar. |
| `honorSavedPositions` | bool | `true` | | Use `characters[].position`. |
| `hideThumbnailsDuringRegionSelect` | bool | `true` | | Hide thumbnails while drawing a space's region. |

**Client List** (`viewMode: ClientList`): one row per client; click activates, Shift+click toggles exclusion, drag the header to move. It uses its own colour, system name and auto-hide settings below instead of the `thumbnail` ones; per-character colours, display names, `systemColors` and each overlay's `enabled` are shared.

| Key | Type | Default | Range / values | Notes |
|---|---|---|---|---|
| `listViewOrder` | enum | `ConfiguredCharacters` | `ConfiguredCharacters` `Tracked` `Alphabetical` | |
| `rememberListViewPosition` | bool | `true` | | |
| `listViewOpacity` | int | `255` | opacity | |
| `listViewColumns` | int | `1` | 1–6 | |
| `listViewColumnWidth` | int | `230` | 120–500 | |
| `listViewFontName` | string | `"Segoe UI"` | | Header and right-hand text are 2 px smaller. |
| `listViewFontSize` | int | `13` | font size | |
| `listViewFontWeight` | enum | `Regular` | weight | |
| `listViewIndicatorStyle` | enum | `Dot` | `Dot` `Square` `None` | |
| `listViewShowSystemName` | bool | `true` | | |
| `listViewSystemNameColor` | colour | `0xFF8B8F96` | | |
| `listViewUseUniqueSystemColors` | bool | `false` | | |
| `listViewUseUniqueCharacterNameColors` | bool | `false` | | |
| `listViewActiveColor` | colour | `0xFFD9A441` | | Active row's dot, tint and name. |
| `listViewUseUniqueActiveColors` | bool | `false` | | Character's generated colour as its active colour. |
| `listViewShowNotifications` | bool | `true` | | |
| `listViewNotificationColor` | colour | `0xFFFFFFFF` | | For types without `text_color`. |
| `listViewShowIncomingDps`, `listViewShowOutgoingDps`, `listViewShowMiningRate`, `listViewShowBountyRate` | bool | `true` | | Each also needs its overlay's `enabled`. |
| `listViewShowIncomingPrefix`, `listViewShowOutgoingPrefix`, `listViewShowMiningPrefix`, `listViewShowBountyPrefix` | bool | `true` | | `IN:`, `OUT:`, `M:`, `ISK:`. |
| `listViewIncomingDpsColor` | colour | `0xFFFF4444` | | |
| `listViewOutgoingDpsColor` | colour | `0xFF44FF44` | | |
| `listViewMiningRateColor` | colour | `0xFF44AAFF` | | |
| `listViewBountyRateColor` | colour | `0xFFFFD700` | | |
| `listViewHideWhenNoEveFocus` | bool | `false` | | |
| `listViewHideDebounceMs` | int | `500` | 0–5000 | |

**History Panel**: recent notifications from all characters. Also toggled from the tray.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `showNotifInfoPanel` | bool | `false` | | |
| `notifInfoPanelX`, `notifInfoPanelY` | int | `10`, `250` | screen | |
| `notifInfoPanelWidth` | int | `300` | 100–3840 | |
| `notifInfoPanelHeight` | int | `400` | 60–2160 | |
| `rememberNotifInfoPanelPosition` | bool | `true` | | Save position on drag. |
| `hideNotifInfoPanelWhenNoCharacters` | bool | `true` | | |
| `notifInfoPanelOpacity` | int | `255` | opacity | |
| `notifInfoPanelFontName` | string | `"Segoe UI"` | | |
| `notifInfoPanelFontSize` | int | `13` | font size | |
| `notifInfoPanelFontWeight` | enum | `Regular` | weight | |
| `notifInfoPanelMaxRows` | int | `15` | 1–30 | |
| `notifInfoPanelShowTimestamp` | bool | `false` | | |
| `notifInfoPanelMergeEnabled` | bool | `false` | | Merge identical back-to-back notifications from different characters into one `+N` row. |
| `notifInfoPanelMergeWindowSec` | int | `10` | 1–300 | Max gap to merge. |
| `notifInfoPanelShowCategoryFilters` | bool | `true` | | |
| `notifInfoPanelShowFleet`, `notifInfoPanelShowMining`, `notifInfoPanelShowCombat`, `notifInfoPanelShowNavigation`, `notifInfoPanelShowGeneral` | bool | `true` | | Category filters. |

### thumbnailSpaces

Screen rectangles whose characters' thumbnails are auto-sized into a grid. Used only while `display.placementMode` is `ThumbnailSpaces`. A held thumbnail ignores saved positions, dragging, `thumbnail.width`/`height` and `characters[].thumbnailSize`.

| Key | Type | Default | Range / values | Notes |
|---|---|---|---|---|
| `name` | string | `""` | | |
| `enabled` | bool | `true` | | |
| `groups` | string[] | `[]` | | Hotkey group names held. |
| `holdsLoginScreen` | bool | `false` | | Marks the Login Screen space. |
| `holdsUnassigned` | bool | `false` | | Marks the Unassigned Characters space. |
| `takesUnassigned` | bool | `false` | | Append unassigned characters after its own. |
| `takesLoginScreen` | bool | `false` | | Append login-screen clients last. |
| `x`, `y` | int? | `null` | screen | |
| `width` | int? | `null` | 1–11520 | |
| `height` | int? | `null` | 1–6480 | |
| `order` | enum | `Characters` | `Characters` `HotkeyGroups` | `HotkeyGroups`: by group order in `hotkeyGroups`, then member order. |
| `direction` | enum | `RowFirst_LTR_TTB` | `RowFirst_LTR_TTB` `RowFirst_RTL_TTB` `RowFirst_LTR_BTT` `RowFirst_RTL_BTT` `ColumnFirst_TTB_LTR` `ColumnFirst_TTB_RTL` `ColumnFirst_BTT_LTR` `ColumnFirst_BTT_RTL` | Start corner and fill axis. |
| `spacing` | int | `0` | 0–200 | Gap between cells. |
| `limitToThumbnailSize` | bool | `false` | | Cap cells at `thumbnail.width`/`height` (DPI-scaled). |

Rules:
- Every profile has one Login Screen and one Unassigned Characters space, kept first and second; missing ones are added disabled. Only the first space with each mark keeps it.
- A space places thumbnails only when enabled with `x`, `y`, `width` and `height` all set.
- A character goes to the first enabled space holding any of its groups.
- Characters no space holds go to Unassigned Characters if usable, else the first space with `takesUnassigned`, else are placed by hand.
- Login-screen clients go to Login Screen if usable, else the first space with `takesLoginScreen`, else are placed by hand.
- Cells keep the thumbnail aspect ratio. The grid adds a row or column, whichever gives the bigger cell. Slack collects at the far edge.
- Spaces reflow on login, logout, thumbnail open/close and group membership change.

### snapping

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `true` | | |
| `threshold` | int | `10` | 0–20 | Pixels. |
| `screenEdges` | bool | `true` | | |
| `thumbnailEdges` | bool | `true` | | |
| `ghostPositions` | bool | `true` | | Snap to other characters' saved positions while dragging. |
| `showGhostPositionBorders` | bool | `true` | | Outline those positions while dragging. Turned off by import. |

### interaction

| Key | Type | Default | Range / values | Notes |
|---|---|---|---|---|
| `enableDragging` | bool | `true` | | Right-drag moves a thumbnail; Ctrl+right-drag moves all. |
| `animationStyle` | enum | `NoAnimation` | `NoAnimation` `OriginalAnimation` | `NoAnimation` disables Windows' minimize/restore animation around the app's own minimize/restore calls, then restores the setting. |
| `clickTrigger` | enum | `MouseDown` | `MouseDown` `MouseUp` | When left-click activates. |
| `clickThrough` | bool | `false` | | Thumbnails and Client List ignore the mouse. Disables clicking, exclusion, dragging and hover zoom. |
| `hoverCursor` | enum | `Default` | `Default` `Hand` `Crosshair` `Move` `Help` | Over thumbnails and Client List rows. |
| `hoverZoomEnabled` | bool | `false` | | Enlarged live copy over the hovered thumbnail. |
| `hoverZoomPercent` | int | `200` | 110–1000 | Shrunk to fit the monitor. |
| `hoverZoomAnchor` | enum | `Center` | position | Point that stays fixed as the zoom grows. |

### exclusion

Excluded characters are skipped by group cycling and [travel](#travel), and by all-clients cycling and Close All when `cycleAllClientsRespectExclusions` / `closeAll.excludeCycleExcludedClients` is on. Exclusion is runtime-only. Toggled by Shift+left-click or `hotkeyToggleExclusion`.

| Key | Type | Default | Notes |
|---|---|---|---|
| `enableShiftClickExclude` | bool | `true` | `false`: Shift+click activates like a plain click. |
| `autoMinimizeExcluded` | bool | `false` | Minimize a client when it's excluded. |
| `logoutClearsExclusion` | bool | `true` | Logging out to the login screen re-includes the character. |

### autoMinimize

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | Minimize unfocused clients after `delayMs`. The last-focused client on each monitor stays up. |
| `delayMs` | int | `5000` | 0–10000 | |
| `exemptLastActiveOnFocusLoss` | bool | `true` | | Keep each monitor's last-active client up when focus leaves EVE. |
| `startMinimized` | bool | `false` | | Minimize each newly launched client. Independent of `enabled`. |

Per-character opt-out: `characters[].excludeFromMinimize`.

### autoMovePosition

Moves client windows to `characters[].windowPosition`.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | On login. |
| `moveOnStartup` | bool | `false` | | Clients already running at startup. Independent of `enabled`. |
| `verifyIntervalMs` | int | `2000` | 250–10000 | Recheck interval after a move. |
| `verifyCount` | int | `6` | 0–30 | Rechecks; reapplied if EVE moved the window. `0` = none. |

Per-character opt-out: `characters[].excludeFromAutoMove`.

### closeAll

| Key | Type | Default | Notes |
|---|---|---|---|
| `excludeCycleExcludedClients` | bool | `false` | Skip characters excluded from cycling. |
| `excludeLoginScreenClients` | bool | `false` | Skip clients at character select. |

Per-character opt-out: `characters[].excludeFromCloseAll`.

### chatlog

Reads EVE's chat and game logs on a worker thread. Required by system names, notifications from game events, combat, mining, bounty and travel.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `chatlogDir` | string | `""` | | `""` = `<Documents>\EVE\logs\Chatlogs` (follows OneDrive redirection). `%VAR%` expanded; unknown variables kept literally. |
| `gamelogDir` | string | `""` | | As above, `Gamelogs`. |
| `pollIntervalMs` | int | `500` | 100–5000 | |
| `idlePollThreshold` | int | `600` | 1–1000 | Idle polls before a file's poll interval doubles. |
| `maxPollMultiplier` | int | `2` | 1–8 | Backoff cap. Any change resets to 1×. |

### combat

Incoming/outgoing DPS labels from gamelog `(combat)` lines. Lines with `" from "` after the amount are incoming, else `" to "` outgoing. `misses you completely` counts as a 0-damage incoming hit. Repairs, boosts, transfers and outgoing misses are ignored.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `window_seconds` | int | `60` | 5–600 | **0 = default.** DPS = damage in window ÷ window. Early in a fight, damage after the first second ÷ elapsed; `??` for 3 s. |
| `update_interval_ms` | int | `1000` | 1000–10000 | Display refresh. Alerts check every second. |
| `show_incoming`, `show_outgoing` | bool | `true` | | |
| `incoming_color` | colour | `0xFFFF4444` | | |
| `outgoing_color` | colour | `0xFF44FF44` | | |
| `incoming_bg_color`, `outgoing_bg_color` | colour | `0xE6000000` | | |
| `incoming_font_name`, `outgoing_font_name` | string | `"Segoe UI"` | | |
| `incoming_font_size`, `outgoing_font_size` | int | `12` | font size | |
| `incoming_font_weight`, `outgoing_font_weight` | enum | `Regular` | weight | |
| `incoming_position` | enum | `TopCenter` | position | |
| `outgoing_position` | enum | `BottomCenter` | position | |
| `incoming_offset_x`, `incoming_offset_y`, `outgoing_offset_x`, `outgoing_offset_y` | int | `0` | offset | |
| `incoming_show_prefix`, `outgoing_show_prefix` | bool | `true` | | |
| `damage_alert_excluded_weapons` | string | `""` | | Comma-separated, case-insensitive weapon-name substrings that count toward DPS but don't raise `TakingDamage`. |

`TakingDamage` fires on incoming hits, at most once per its `throttle_ms`, and stops when the hits stop.

### mining

m³/min and ISK rate from gamelog `(mining)` lines (normal and critical yields; residue ignored).

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `window_seconds` | int | `60` | 30–3600 | **0 = default.** Rate = m³ in window ÷ window. Early on, units after the first cycle ÷ time from first to latest yield. |
| `update_interval_ms` | int | `1000` | 1000–10000 | |
| `color` | colour | `0xFF44AAFF` | | |
| `bg_color` | colour | `0xE6000000` | | |
| `font_name` | string | `"Segoe UI"` | | |
| `font_size` | int | `12` | font size | |
| `font_weight` | enum | `Regular` | weight | |
| `position` | enum | `BottomRight` | position | |
| `offset_x`, `offset_y` | int | `0` | offset | |
| `show_prefix` | bool | `true` | | `M:` |
| `show_isk_rate` | bool | `true` | | Second line, priced from the [ore table](#global-settings). |
| `isk_rate_unit` | enum | `hour` | `hour` `minute` | |
| `idle_alert_window_seconds` | int | `30` | 30–600 | **0 = default.** `MiningIdle` fires once when events in this window ≤ `idle_alert_threshold`, after mining for a full window; rearms above it. |
| `idle_alert_threshold` | int | `1` | 0–60 | |
| `stopped_alert_window_seconds` | int | `60` | 30–3600 | **0 = default.** `MiningStopped` fires once after this long with no events; rearms on mining. |

### bounty

ISK rate from gamelog `(bounty)` lines (`… ISK added to next bounty payout`). Same formula as mining.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `window_seconds` | int | `1200` | 60–3600 | **0 = default.** |
| `update_interval_ms` | int | `1000` | 1000–10000 | |
| `color` | colour | `0xFFFFD700` | | |
| `bg_color` | colour | `0xE6000000` | | |
| `font_name` | string | `"Segoe UI"` | | |
| `font_size` | int | `12` | font size | |
| `font_weight` | enum | `Regular` | weight | |
| `position` | enum | `TopRight` | position | |
| `offset_x`, `offset_y` | int | `0` | offset | |
| `show_prefix` | bool | `true` | | `ISK:` |
| `isk_rate_unit` | enum | `hour` | `hour` `minute` | |

### resources

Per-client CPU / RAM / VRAM label, sampled from the OS (no logs needed).

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `show_cpu` | bool | `true` | | `GetProcessTimes`, normalised to all logical cores, 0–100 %. First sample reads 0 %. |
| `show_ram` | bool | `true` | | Working set, MB. |
| `show_vram` | bool | `true` | | Dedicated GPU memory, MB, via the "GPU Process Memory" perf counter. Omitted when unavailable. |
| `update_interval_ms` | int | `10000` | 1000–60000 | |
| `color` | colour | `0xFFFFFFFF` | | |
| `bg_color` | colour | `0xE6000000` | | |
| `font_name` | string | `"Segoe UI"` | | |
| `font_size` | int | `12` | font size | |
| `font_weight` | enum | `Regular` | weight | |
| `position` | enum | `LeftCenter` | position | |
| `offset_x`, `offset_y` | int | `0` | offset | |

### travel

Fires `TravelLeftBehind` when a character isn't in the group's system. Checked about every 2 s.

| Key | Type | Default | Range | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | | |
| `window_seconds` | int | `30` | 1–3600 | **0 = default.** Grace period after the last group member arrives. |
| `threshold_mode` | enum | `percent` | `percent` `count` | |
| `threshold_percent` | float | `50.0` | 1–100 | Share of eligible characters that must share a system for it to count as the group. |
| `threshold_count` | int | `2` | 1–50 | As above, as a count. |

Eligible: jumped (gate or Conduit, not undock) at least once this session and not excluded. The group system is the one most eligible characters share. A straggler is flagged once; its next jump rearms.

### hotkeys

All values are **keys**.

| Key | Type | Default | Notes |
|---|---|---|---|
| `requireEveFocus` | bool | `false` | Hotkeys only fire while an EVE client has focus. |
| `resetGroupIndexOnNonGroupFocus` | bool | `false` | Reset a group's cycle position when focus leaves the group. |
| `allowHotkeyAutoRepeat` | bool | `false` | Holding a keyboard hotkey repeats it. |
| `exactHotkeyModifiers` | bool | `false` | `false`: an unbound combo falls back to its bare key's binding (`Alt+1` fires `1`). `true`: modifiers must match exactly; unbound combos pass to the game. |
| `hotkeyMinimizeAll` | keys | | Minimize all clients. |
| `hotkeyCloseAll` | keys | | Close all clients, per [closeAll](#closeall). |
| `hotkeyCloseActive` | keys | | Close the focused client, ignoring Close All exclusions. |
| `hotkeyToggleVisibility` | keys | | Show/hide all thumbnails. |
| `hotkeyToggleAutoMinimize` | keys | | Toggle `autoMinimize.enabled`. |
| `hotkeyToggleAlertMute` | keys | | Mute TTS and sounds for this session. |
| `hotkeyToggleExclusion` | keys | | Toggle the focused client's exclusion. |
| `hotkeyNextExcluded`, `hotkeyPreviousExcluded` | keys | | Cycle excluded characters, in exclusion order. |
| `hotkeySuspend` | keys | | Suspend/resume all other hotkeys. |
| `hotkeyExitApp` | keys | | Exit the app (clients stay open). |
| `hotkeyCycleNotified`, `hotkeyPreviousNotified` | keys | | Cycle recently notified characters, oldest first, one shared cursor. |
| `hotkeyMoveToSavedPositions` | keys | | Move clients to `windowPosition`, honouring `excludeFromAutoMove`. |

### hotkeyGroups

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `""` | Used by `thumbnailSpaces[].groups` and the badge. |
| `characters` | string[] | `[]` | Cycle order. |
| `forwardKey`, `backwardKey` | keys | | Cycle. Both optional. |
| `assignKey` | keys | | Toggle the hovered thumbnail's character in/out of the group. Can't be shared. |
| `closeKey` | keys | | Close every running member of the group, ignoring Close All exclusions. Can't be shared. |
| `temporaryMembership` | bool | `false` | Members aren't saved; the group starts empty each launch. |
| `showBadge` | bool | `false` | Show the group on members' [group badge](#thumbnail). |
| `includeNotLoggedIn` | bool | `false` | Append login-screen clients, oldest logout first. |
| `stopAtEnds` | bool | `false` | Stop at the first/last member instead of wrapping; pressing again refocuses it. |

Groups sharing a `forwardKey` (or `backwardKey`) cycle as one list in group order. Login-screen clients are appended if any shares `includeNotLoggedIn`; ends stop only if all set `stopAtEnds`. One group's forward key can't be another's backward key.

### characters

Matched by exact `name`. Positions are saved automatically on drag.

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `""` | |
| `position` | `{x, y}`? | `null` | Thumbnail position. |
| `windowPosition` | `{x, y}`? | `null` | Client window top-left, including Windows' invisible border (a left-snapped window is about `x: -7`). Pulled onto a monitor if off-screen. |
| `windowSize` | `{width, height}`? | `null` | Saved with `windowPosition`; dialog preview only. |
| `thumbnailSize` | `{width?, height?}`? | `null` | 50–3840 × 50–2160. Ignored inside a space. |
| `borderColors` | `{activeBorderColor?, inactiveBorderColor?}`? | `null` | Colours. |
| `nameColor` | colour? | `null` | |
| `displayName` | string? | `null` | Shown instead of `name` on thumbnails and the Client List. |
| `opacity` | int? | `null` | opacity; `null` = `thumbnail.thumbnailOpacity`. |
| `hotkey` | keys | | Activate this character. Shared keys cycle the sharers in profile order. |
| `excludeFromMinimize` | bool | `false` | |
| `excludeFromCloseAll` | bool | `false` | |
| `excludeFromAutoMove` | bool | `false` | |
| `hideThumbnail` | bool | `false` | Hide its thumbnail and list row; takes no space cell. |
| `notificationsMuted` | bool | `false` | |

### systemColors

| Key | Type | Default | Notes |
|---|---|---|---|
| `systemName` | string | `""` | Comma-separated names and patterns, case-insensitive. `*` any text, `?` one character, `#` one digit (`J######` = wormholes). |
| `color` | colour | `0` | |

An exact name beats a pattern regardless of order; otherwise the first match wins. The key is `systemName`; an entry using `name` never matches.

### windowFilters

Which windows get thumbnails. A profile without the key gets the EVE filter below; an empty array tracks nothing.

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `""` | Thumbnail label for non-EVE windows. |
| `enabled` | bool | `true` | |
| `class_names` | string[] | `[]` | Exact, case-sensitive. Empty = any. |
| `executable_names` | string[] | `[]` | Case-insensitive suffix of the executable path. Empty = any. |

A window must pass both lists; a filter with both empty matches nothing. Non-EVE windows get thumbnails and hotkeys but no log features, and are ignored by Minimize All, Close All, auto-minimize and auto-move.

```json
"windowFilters": [
  { "name": "EVE Online", "enabled": true, "class_names": ["trinityWindow"], "executable_names": ["exefile.exe"] }
]
```

## Global settings

`profiles\global.settings.json`. Applies to every profile.

| Key | Type | Default | Notes |
|---|---|---|---|
| `lastUsedProfile` | string | `"default.json"` | Set by the app. |
| `logLevel` | enum | `err` | `debug` `info` `warn` `err` |
| `language` | enum | `en` | `en` `de` `es` `fr` `pl` `pt` `ru`. Dialog and on-screen hints. |
| `advancedMode` | bool | `false` | Show the dialog's advanced settings. |
| `alwaysOnTop` | bool | `true` | Keep the config dialog on top. |
| `dialogX`, `dialogY` | int? | `null` | Dialog position. Set by the app. |
| `runOnStartup` | bool | `false` | `HKCU\…\Run` entry, re-applied each launch. |
| `autoRegisterProtocol` | bool | `true` | Register `evemajpreview://` at startup if missing. |
| `disableUpdateChecks` | bool | `false` | |
| `hotkeyNextProfile`, `hotkeyPreviousProfile` | keys | | Cycle profiles in directory order, wrapping. |
| `profileSwitchHotkeys` | `[{hotkey, targetProfile}]` | `[]` | `targetProfile` is a file name, e.g. `"pvp.json"`. |
| `hotkeyCycleAllClientsForward`, `hotkeyCycleAllClientsBackward` | keys | | All logged-in clients, in `characters` order, then the rest. |
| `cycleAllClientsRespectExclusions` | bool | `false` | Skip excluded characters in the above. |
| `hotkeyCycleNotLoggedInForward`, `hotkeyCycleNotLoggedInBackward` | keys | | Login-screen clients, oldest logout first. |
| `hotkeyReturnToLastApp` | keys | | Focus the last non-EVE window. |
| `appHotkeys` | `[{hotkey, executableName}]` | `[]` | Focus the frontmost window of that executable; nothing if not running. |
| `hotkeyCycleAppsForward`, `hotkeyCycleAppsBackward` | keys | | Step through running `appHotkeys` apps in list order. |
| `urlHotkeys` | `[{hotkey, url, uploadClipboard}]` | `[]` | Open `url` in the default browser. |
| `urlHotkeys[].uploadClipboard` | bool | `false` | POST clipboard text to `url` as form field `Paste anything`, put the result URL on the clipboard and open it; falls back to opening `url`. For `adashboard.info`. |
| `oreTable` | `[{name, price}]` | `[]` | ISK/unit overrides, 0–1e12. A name also covers its grade variants (`Veldspar` → `Veldspar II-Grade`). Others use built-in Jita prices. |
| `orePricesFetchedAtSeconds` | int | `0` | Unix time of the last Fetch Prices. |

## Command line and protocol

| Argument | Effect |
|---|---|
| `--profile <file>`, `-p <file>` | Load this profile instead of `lastUsedProfile`. |
| `--config` | Open the config dialog. Any second launch forwards this to the running instance. |
| `--protocol <url>` | Forward a protocol URL to the running instance and exit. |

`evemajpreview://` URLs are forwarded to the running instance and dropped if none is running. Registered under `HKCU\Software\Classes\evemajpreview` (no admin) with the current executable's path; re-register after moving the exe.

| URL | Effect |
|---|---|
| `evemajpreview://switch/<character>` | Activate that character. URL-encoded. |
| `evemajpreview://profile/<file>` | Load `<file>` (e.g. `pvp.json`, case-insensitive). Invalid or missing → `default.json`. |
| `evemajpreview://hotkey/<action>` | Run a global hotkey action. |

| Action | Same as |
|---|---|
| `minimize_all` | `hotkeyMinimizeAll` |
| `close_all` | `hotkeyCloseAll` |
| `close_active` | `hotkeyCloseActive` |
| `toggle_visibility` | `hotkeyToggleVisibility` |
| `toggle_auto_minimize` | `hotkeyToggleAutoMinimize` |
| `toggle_alert_mute` | `hotkeyToggleAlertMute` |
| `toggle_exclusion` | `hotkeyToggleExclusion` |
| `next_excluded`, `previous_excluded` | `hotkeyNextExcluded`, `hotkeyPreviousExcluded` |
| `suspend_hotkeys` | `hotkeySuspend` |
| `cycle_notified`, `previous_notified` | `hotkeyCycleNotified`, `hotkeyPreviousNotified` |
| `move_to_saved_positions` | `hotkeyMoveToSavedPositions` |
| `exit_app` | `hotkeyExitApp` |
| `next_profile`, `previous_profile` | `hotkeyNextProfile`, `hotkeyPreviousProfile` |
| `next_all_clients`, `previous_all_clients` | `hotkeyCycleAllClientsForward`, `…Backward` |
| `next_not_logged_in`, `previous_not_logged_in` | `hotkeyCycleNotLoggedInForward`, `…Backward` |
| `return_to_last_app` | `hotkeyReturnToLastApp` |
| `next_app`, `previous_app` | `hotkeyCycleAppsForward`, `…Backward` |
