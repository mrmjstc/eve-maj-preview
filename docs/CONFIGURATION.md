# Configuration Reference

Configuration files use **JSON format**. The application generates a default profile at `profiles\default.json` on first run.

When editing by hand, a value the app can't read (an unknown option name, a malformed color, text where a number belongs) is skipped with a warning in the log, and that one setting uses its default; the rest of the file loads as written. A file that isn't valid JSON at all loads with default settings, after a copy is kept: a profile in `profiles\backup\` (restorable from the config dialog's Import), the global settings as `profiles\global.settings.json.bak`.

## Logging

```json
{
  "logLevel": "info"
}
```

`logLevel` lives in `profiles\global.settings.json` (default: `err`). Log levels (from most to least verbose):
- **debug**: Detailed troubleshooting info (positions, indices, state changes)
- **info**: Important user-facing events (config loaded, thumbnails created)
- **warn**: Warning conditions that don't prevent operation
- **err**: Error conditions only

## Thumbnail Settings

### Basic Dimensions
```json
{
  "thumbnail": {
    "width": 200,
    "height": 112,
    "thumbnailOpacity": 255,
    "applyOpacityToOverlayTexts": false
  }
}
```

`applyOpacityToOverlayTexts` controls whether `thumbnailOpacity` also affects text overlays (character/system/notification text, text backgrounds, borders, DPS/mining overlay text).

### Border Settings
```json
{
  "thumbnail": {
    "showBorderWhenFocused": true,
    "borderWidth": 2,
    "borderColor": "0xFFD9A441",
    "borderStyle": "Solid",
    "showBorderWhenInactive": false,
    "inactiveBorderWidth": 2,
    "inactiveBorderColor": "0xFF606060",
    "inactiveBorderStyle": "Solid"
  }
}
```

**Border Styles**: `Solid`, `Dashed`, `Dotted`, `Double`, `DiagonalHatch`, `DashDot`, `CornerBrackets`

### Text Overlay Settings
```json
{
  "thumbnail": {
    "showText": true,
    "showCharacterName": true,
    "showSystemName": false,
    "characterNameColor": "0x00FFFFFF",
    "characterNameBgColor": "0xE6000000",
    "characterNameFontName": "Segoe UI",
    "characterNameFontSize": 12,
    "characterNameFontWeight": "Regular",
    "useUniqueCharacterNameColors": false,
    "systemNameColor": "0x00FFFFFF",
    "systemNameBgColor": "0xE6000000",
    "systemNameFontName": "Segoe UI",
    "systemNameFontSize": 12,
    "systemNameFontWeight": "Regular",
    "useUniqueSystemColors": false
  }
}
```

The character name and system name each have their own color, background and font. Per-state `textColor` / `textBgColor` overrides live under `thumbnail.active`, `thumbnail.inactive` and the other state blocks.

**Font Weights**: `Regular`, `Bold`, `Italic`, `BoldItalic`

### Text Positioning
```json
{
  "thumbnail": {
    "characterNamePosition": "TopLeft",
    "characterNameOffsetX": 0,
    "characterNameOffsetY": 0,
    "systemNamePosition": "BottomLeft",
    "systemNameOffsetX": 0,
    "systemNameOffsetY": 0
  }
}
```

**Text Positions**: `TopLeft`, `TopCenter`, `TopRight`, `LeftCenter`, `Center`, `RightCenter`, `BottomLeft`, `BottomCenter`, `BottomRight`

### Visibility Settings
```json
{
  "thumbnail": {
    "thumbnailOpacity": 255,
    "applyOpacityToOverlayTexts": false,
    "activeThumbnailHidden": false,
    "hideWhenNoEveFocus": false,
    "hideDebounceMs": 500
  }
}
```

### Group Badge

```json
{
  "thumbnail": {
    "showQuickGroupBadge": true,
    "quickGroupBadgeColor": "0xFF44FF44",
    "quickGroupBadgeBgColor": "0xE6000000",
    "quickGroupBadgePosition": "RightCenter",
    "quickGroupBadgeOffsetX": 0,
    "quickGroupBadgeOffsetY": 0,
    "quickGroupBadgeFontName": "Segoe UI",
    "quickGroupBadgeFontSize": 12,
    "quickGroupBadgeFontWeight": "Regular"
  }
}
```

Drawn on a thumbnail whenever its character is a member of a [Hotkey Group](#hotkey-groups-character-cycling) with `showBadge` set. `quickGroupBadgePosition` uses the same values as [Text Positions](#text-overlay-settings).

### Exclusion Overlay

```json
{
  "thumbnail": {
    "exclusionOverlayStyle": "X",
    "exclusionOverlayColor": "0x33A62222"
  }
}
```

Drawn on a thumbnail whenever its character is excluded from hotkey cycling (see [Shift + Left-click](#user-interaction)).

**Exclusion Overlay Styles**:
- `"X"` (default): Semi-transparent diagonal cross across the thumbnail
- `"DiagonalSlash"`: A single diagonal band, half of the `X` style
- `"DiagonalHatch"`: Repeating 45° stripes across the whole thumbnail
- `"Checkerboard"`: Alternating tinted squares across the whole thumbnail
- `"SolidTint"`: The whole thumbnail washed in `exclusionOverlayColor`, no shape
- `"CircleSlash"`: A "no entry" circle-and-slash centered on the thumbnail
- `"None"`: No visual indicator drawn

## State-Specific Visual Overrides

Each thumbnail has one of these states at any time: `active`, `inactive`, `alert`, `minimized`, `dragging`. Internally, each state can override `borderWidth`, `borderColor`, `borderStyle`, `textColor`, `textBgColor`, and `showBorder`/`showThumbnail`, falling back to the base thumbnail settings above when unset.

**Current built-in defaults:**

| State | `showThumbnail` |
|---|---|
| `active` | Follows `activeThumbnailHidden` |
| `inactive`, `alert`, `minimized`, `dragging` | `true` |

> **Note:** These per-state overrides are saved in the profile as `thumbnail.active`, `thumbnail.inactive`, `thumbnail.alert`, `thumbnail.minimized` and `thumbnail.dragging`, and can be edited there by hand, but the config dialog doesn't show them. An active notification's border color comes from its type's `border_color` override when set - see [Notification System](#notification-system).

## Timer and Scanning

```json
{
  "timer": {
    "scanIntervalMs": 50
  }
}
```

`scanIntervalMs` defaults to `50` and is clamped between `50` and `1000`. While no client is open and the configuration window is closed, the app ticks once a second instead, since there is nothing to draw.

## Window Filters

Configure which applications to create thumbnails for. By default, only EVE Online windows are tracked.

```json
{
  "windowFilters": [
    {
      "name": "EVE Online",
      "enabled": true,
      "class_names": ["trinityWindow"],
      "executable_names": ["exefile.exe"]
    },
    {
      "name": "Notepad",
      "enabled": true,
      "class_names": ["Notepad"],
      "executable_names": ["notepad.exe"]
    }
  ]
}
```

**Filter Properties:**
- **name**: The thumbnail label for the windows this filter matches, whatever their titles; EVE clients are named after their character instead
- Windows that aren't EVE clients get thumbnails and hotkeys, but no log tracking (system, combat, mining, notifications), and Minimize All, Close All, Auto-Minimize and Auto-Move leave them alone
- **enabled**: Whether this filter is active (default: `true`)
- **class_names**: Array of window class names to match, exactly and case-sensitively (empty array = match any)
- **executable_names**: Array of executable names, matched case-insensitively against the end of the window's executable path (empty array = match any)
- A filter with both arrays empty matches nothing

**How It Works:**
1. The application scans all visible windows at least once a second
2. Each window's class name is checked against all enabled filters
3. If a class name matches, the executable path is verified against the filter's executable names
4. Both checks must pass for a window to be tracked


## Display and Positioning

The display configuration has two layout modes, with full multi-monitor support.

**Basic Configuration:**

```json
{
  "display": {
    "startX": 10,
    "startY": 10,
    "spacing": 0,
    "layoutMode": "Custom",
    "honorSavedPositions": true
  }
}
```

**Layout Modes:**

- **`Custom`** (default): No auto-layout. Each character spawns at its saved position (see `honorSavedPositions`); a character with no saved position yet spawns at `startX`/`startY`.
- **`RegionFit`**: Auto-fits thumbnails into a user-dragged screen rectangle (`regionX`/`regionY`/`regionWidth`/`regionHeight`) - see [Thumbnail Space (Region Fit)](#thumbnail-space-region-fit) below.

## Thumbnail Space (Region Fit)

Rather than a fixed per-thumbnail size and an unbounded grid, `RegionFit` mode fits however many thumbnails are currently tracked into a fixed rectangle, sizing every cell to preserve the configured thumbnail's aspect ratio. The grid grows one column or row at a time as thumbnails spawn, always growing whichever gives the bigger cell, so it expands incrementally instead of being re-optimized from scratch on every count change.

Cells are packed snugly against each other (using `spacing`, not stretched to fill the region) so any slack collects as one block at the region's far edge instead of gaps between thumbnails. It reflows automatically on login, and on logout if `regionFitReorderLoggedOut` is true; while active it fully replaces per-character manual dragging and the global/per-character thumbnail size (`thumbnail.width`/`height`, `characters[].thumbnailSize`) - those are ignored.

The region itself is set via the config dialog's "New Thumbnail Region" button, which asks the running main app to show a full-desktop drag-to-select overlay; the captured rectangle is written into `regionX`/`regionY`/`regionWidth`/`regionHeight` (all `null` until first captured). Once a region exists, "Edit Region" reopens the overlay with the region's edges and body draggable, and the x button clears it. The overlay finishes with Save/Cancel buttons (or Enter/Esc). If `hideThumbnailsDuringRegionSelect` (default `true`) is on, currently-visible thumbnails are hidden for the duration of that overlay so they don't cover it, then restored exactly as they were once it closes (a thumbnail already hidden beforehand, e.g. manually, is left alone).

If `regionFitLimitToThumbnailSize` (default `false`) is on, cell size is additionally capped at the configured thumbnail size (`thumbnail.width`/`height`, DPI-scaled for the region's own monitor) instead of always growing to fill the region; once cells hit that cap, extra thumbnails just wrap into more rows/columns, leaving unused space in the region rather than shrinking further.

Fill order is controlled by two independent settings:
- `regionFitOrder`: `Characters` (the profile's configured character list order) or `HotkeyGroups` (grouped by hotkey group membership, in `hotkeyGroups` order, each group's own member order preserved; a character in more than one group counts toward whichever it appears in first). Characters matching neither sort after ranked ones.
- `regionFitDirection`: which corner the grid fills from and whether it goes row-first or column-first:
  - `RowFirst_LTR_TTB`: Left→right, top→bottom (default)
  - `RowFirst_RTL_TTB`: Right→left, top→bottom
  - `RowFirst_LTR_BTT`: Left→right, bottom→top
  - `RowFirst_RTL_BTT`: Right→left, bottom→top
  - `ColumnFirst_TTB_LTR`: Top→bottom, left→right
  - `ColumnFirst_BTT_LTR`: Bottom→top, left→right
  - `ColumnFirst_TTB_RTL`: Top→bottom, right→left
  - `ColumnFirst_BTT_RTL`: Bottom→top, right→left

`regionFitReorderLoggedOut` (default `true`): whether a character logging out moves its thumbnail to the end of the grid (an unranked "EVE" placeholder always sorts last) or stays in its current slot until some other login/logout triggers a reflow. Ignored when [Not-Logged-In Thumbnail Space](#not-logged-in-thumbnail-space) is enabled - a logout always reflows then, since the placeholder must physically leave the grid for that space rather than just keep or lose its slot within it.

```json
{
  "display": {
    "layoutMode": "RegionFit",
    "regionX": 100,
    "regionY": 100,
    "regionWidth": 800,
    "regionHeight": 600,
    "regionFitOrder": "Characters",
    "regionFitDirection": "RowFirst_LTR_TTB",
    "regionFitReorderLoggedOut": true,
    "hideThumbnailsDuringRegionSelect": true,
    "regionFitLimitToThumbnailSize": false,
    "spacing": 10
  }
}
```

## Not-Logged-In Thumbnail Space

A separate, optional auto-fit area just for not-yet-logged-in "EVE" placeholder windows, independent of `layoutMode`. When `notLoggedInSpaceEnabled` is on and `notLoggedInSpaceX`/`Y`/`Width`/`Height` are captured (same drag-to-select flow as Thumbnail Space, via its own "New Thumbnail Region" button, with the same Edit Region and clear controls), placeholders auto-fit to fill that rectangle - the same column/row/aspect-ratio grid-fit `RegionFit` itself uses (see above), sized for however many placeholders currently exist - instead of joining the regular unpositioned-thumbnail flow at `startX`/`startY`. It has its own `notLoggedInSpaceSpacing`, independent of `RegionFit`'s `spacing`, its own `notLoggedInSpaceHideThumbnailsDuringRegionSelect` (default `true`, same as `hideThumbnailsDuringRegionSelect` for this space's overlay), and its own `notLoggedInSpaceLimitToThumbnailSize` (default `false`), which caps its cell size at the configured thumbnail size the same way `regionFitLimitToThumbnailSize` does for the Thumbnail Space.

It coexists with `RegionFit`: placeholders are carved out of the `RegionFit` grid entirely (they don't take a cell, and don't count toward its cell-count math) and auto-fit into the not-logged-in space instead, reflowing back into the grid the moment they log in. Both grids reflow (resizing every member, not just the one that changed) whenever a placeholder crosses between them.

```json
{
  "display": {
    "notLoggedInSpaceEnabled": true,
    "notLoggedInSpaceX": 100,
    "notLoggedInSpaceY": 100,
    "notLoggedInSpaceWidth": 400,
    "notLoggedInSpaceHeight": 300,
    "notLoggedInSpaceSpacing": 10,
    "notLoggedInSpaceLimitToThumbnailSize": false
  }
}
```

**Multi-Monitor Support:**

Target specific monitors by index (0-based):

```json
{
  "display": {
    "layoutMode": "Custom",
    "monitorIndex": 1,
    "useMonitorWorkArea": true,
    "startX": 10,
    "startY": 10
  }
}
```

- `monitorIndex`: Which monitor to spawn on (0 = primary, 1 = second, etc., null = absolute coordinates)
- `useMonitorWorkArea`: Respect taskbar when true, use full screen when false
- `startX`/`startY`: When `monitorIndex` is set, these are **offsets within that monitor**

All pixel-based values here (thumbnail size, `startX`/`startY`, spacing, font sizes) are logical (96 DPI) units — the app is per-monitor DPI aware and scales them to whichever monitor a thumbnail actually lands on, so the same config looks the same size on monitors with different display scaling.

**All Display Options:**

- `startX`, `startY`: Starting position (absolute or monitor-relative); also the spawn point for characters with no saved position in `Custom` mode
- `newThumbnailSpacing`: Horizontal gap between thumbnails with no saved position yet (new characters, and not-logged-in "EVE" placeholders not covered by `notLoggedInSpaceEnabled`) - they're lined up left-to-right from `startX`/`startY` instead of stacking on top of each other
- `spacing`: Gap between thumbnails in `RegionFit` mode
- `layoutMode`: `Custom` or `RegionFit`
- `regionX`, `regionY`, `regionWidth`, `regionHeight`: Thumbnail Space rectangle for `RegionFit` mode (null until captured) - see [Thumbnail Space (Region Fit)](#thumbnail-space-region-fit)
- `regionFitOrder`, `regionFitDirection`, `regionFitReorderLoggedOut`, `hideThumbnailsDuringRegionSelect`, `regionFitLimitToThumbnailSize`: `RegionFit` fill order, logout behavior, select-overlay hiding, and thumbnail-size cap - see [Thumbnail Space (Region Fit)](#thumbnail-space-region-fit)
- `notLoggedInSpaceEnabled`, `notLoggedInSpaceX`, `notLoggedInSpaceY`, `notLoggedInSpaceWidth`, `notLoggedInSpaceHeight`, `notLoggedInSpaceSpacing`, `notLoggedInSpaceLimitToThumbnailSize`, `notLoggedInSpaceHideThumbnailsDuringRegionSelect`: Separate auto-fit area just for not-logged-in placeholders - see [Not-Logged-In Thumbnail Space](#not-logged-in-thumbnail-space)
- `monitorIndex`: Target monitor (0-based, null = absolute)
- `useMonitorWorkArea`: Respect taskbar
- `honorSavedPositions`: Use saved character positions
- `viewMode`: `Thumbnails` (default), `ClientList`, or `Nothing` - see [List View Mode](#list-view-mode) below

## List View Mode

An alternative to live DWM thumbnails: a single semi-transparent panel with one row per tracked client, showing a state badge dot, character name, and either the current system name or an active notification message. Clicking a row activates that client; Shift+click toggles exclusion from hotkey cycling. The header bar can be dragged to reposition the panel.

Setting `viewMode` to `Nothing` disables all visual output - no thumbnails and no list panel - while still tracking clients internally, so hotkeys (including client cycling) and notifications keep working. This avoids the DWM thumbnail and panel rendering overhead entirely.

```json
{
  "display": {
    "viewMode": "ClientList",
    "listViewOrder": "Tracked",
    "rememberListViewPosition": true,
    "listViewOpacity": 255,
    "listViewColumns": 1,
    "listViewFontName": "Segoe UI",
    "listViewFontSize": 13,
    "listViewFontWeight": "Regular"
  }
}
```

- `viewMode`: `Thumbnails` (default), `ClientList`, or `Nothing` (no visual output; tracking only)
- `listViewOrder`: Row ordering - `Tracked` (default, internal tracking order), `Alphabetical` (by character name), or `ConfiguredCharacters` (order of `characters` array)
- `rememberListViewPosition`: Save/restore the panel's position (default: `true`)
- `listViewOpacity`: Panel opacity, 51–255 (default: `255`)
- `listViewColumns`: Number of columns, 1–15 (default: `1`)
- `listViewFontName`, `listViewFontSize`, `listViewFontWeight`: Font used for row text (font weight uses the same values as [Text Overlay Settings](#text-overlay-settings))

## Window Snapping

```json
{
  "snapping": {
    "enabled": true,
    "threshold": 10,
    "screenEdges": true,
    "thumbnailEdges": true,
    "ghostPositions": true,
    "showGhostPositionBorders": true
  }
}
```

- `ghostPositions`: While dragging, snap to other characters' saved positions
- `showGhostPositionBorders`: While dragging, outline every other saved position (default: `true`; automatically disabled after importing settings, since imported positions belong to a different setup)

## User Interaction

```json
{
  "interaction": {
    "enableDragging": true,
    "animationStyle": "NoAnimation",
    "clickTrigger": "MouseDown",
    "clickThrough": false,
    "hoverCursor": "Default"
  }
}
```

**Configuration Options:**
- `enableDragging`: Enable or disable thumbnail dragging (default: `true`)
- `animationStyle`: Control Windows animations when the app minimizes or restores a client
  - `"NoAnimation"` (default): Temporarily disable system animations so it happens instantly
  - `"OriginalAnimation"`: Use Windows default minimize/restore animations
- `clickTrigger`: When left-click activates the EVE client
  - `"MouseDown"` (default): Activate immediately on mouse button press
  - `"MouseUp"`: Activate on mouse button release
- `clickThrough`: Make thumbnails ignore all mouse input (default: `false`), so clicks and drags pass through to whatever is behind them on screen. Disables click-to-focus, shift-click exclusion toggling, and dragging on every thumbnail while enabled.
- `hoverCursor`: System mouse cursor shown while hovering a thumbnail (thumbnails only, not the Client List or History panels)
  - `"Default"` (default): The standard arrow
  - `"Hand"`: Link-select hand
  - `"Crosshair"`: Precision-select crosshair
  - `"Move"`: Four-way move arrows
  - `"Help"`: Arrow with a question mark

**Animation Style Details:**

By default (`"NoAnimation"`), the application temporarily disables Windows system-wide minimize and restore animations whenever it minimizes or restores a client (switching to it, Auto-Minimize, Minimize All, minimizing an excluded client, and restoring a client to move it to its saved position), then puts your Windows setting back. This makes those near-instant. Set to `"OriginalAnimation"` if you prefer to keep Windows default animations.

**Mouse Interactions:**
- **Left-click**: Activate and bring the EVE client to foreground
- **Right-click + Drag**: Move thumbnail position (hold Ctrl to move all thumbnails)
- **Shift + Left-click**: Toggle character exclusion from hotkey cycling
  - Excluded characters show a visual overlay (default: semi-transparent red "X"; see [Exclusion Overlay](#exclusion-overlay) for other styles)
  - "Excluded" or "Included" notification appears (the `CycleExclusion` notification type, 3s by default)
  - Excluded characters are skipped when using hotkey group cycling (if the character belongs to a group) and when using Cycle All Clients with `cycleAllClientsRespectExclusions` enabled - works even for characters that don't belong to any hotkey group
  - Exclusion state is temporary (resets when application restarts)
  - Can also be toggled via `hotkeyToggleExclusion` for the focused EVE window
  - Use `hotkeyNextExcluded`/`hotkeyPreviousExcluded` to cycle through excluded characters for review

**Exclusion Options:**

```json
{
  "exclusion": {
    "enableShiftClickExclude": true,
    "autoMinimizeExcluded": false
  }
}
```

- `enableShiftClickExclude`: Whether Shift + Left-click toggles exclusion (default: `true`); when `false`, Shift + Left-click activates the client like a plain click
- `autoMinimizeExcluded`: Minimize a client's EVE window as soon as it's excluded, by Shift + Left-click or `hotkeyToggleExclusion` (default: `false`)

## Protocol Handler

EVE-Maj Preview registers a `evemajpreview://` custom URL protocol for external control - character switching, profile loading, and hotkey actions. Useful for Stream Deck buttons, AutoHotkey scripts, browser bookmarks, or any tool that can open a URL.

### How It Works

Windows launches `eve-maj-preview.exe --protocol "<url>"` when a `evemajpreview://` link is opened. That new process does not become the running instance - it looks for an already-running instance by window class, forwards the parsed command to it via `WM_COPYDATA`/`WM_APP` messages, then exits.

> **Note:** The application must already be running for a protocol URL to do anything. If no running instance is found, the command is logged and silently dropped - it does not launch a new instance.

### URL Format

```
evemajpreview://<action>/<param>
```

- **`switch/<character-name>`**: Switch to and foreground the named character's client. The name must be URL-encoded (spaces as `%20` or `+`).
- **`profile/<filename>`**: Load the named profile (a plain file name inside `profiles\`, e.g. `pvp.json`; letter case doesn't matter). A name that isn't a plain `<name>.json`, or a profile that doesn't exist, loads the default profile instead.
- **`hotkey/<action>`**: Trigger one of the hotkey actions below, exactly as if its configured global hotkey had been pressed.

**Hotkey Actions:**

| Action | Effect |
|---|---|
| `minimize_all` | Minimize all EVE client windows |
| `close_all` | Close all EVE client windows |
| `close_active` | Close the focused EVE client window |
| `toggle_visibility` | Toggle visibility of all thumbnails |
| `toggle_auto_minimize` | Toggle auto-minimize mode on/off |
| `next_profile` / `previous_profile` | Cycle to next/previous profile |
| `toggle_exclusion` | Toggle exclusion of the focused EVE window from cycling |
| `next_excluded` / `previous_excluded` | Cycle through excluded characters |
| `suspend_hotkeys` | Suspend/resume all other hotkeys |
| `cycle_notified` / `previous_notified` | Cycle forward/backward through recently notified characters |
| `next_all_clients` / `previous_all_clients` | Cycle forward/backward through all logged-in clients |
| `next_not_logged_in` / `previous_not_logged_in` | Cycle forward/backward through not-logged-in clients |
| `move_to_saved_positions` | Move all clients back to their saved positions |
| `return_to_last_app` | Return focus to the last non-EVE application you used |
| `exit_app` | Exit EVE-Maj Preview |

These correspond directly to the actions in [Hotkey Configuration](#hotkey-configuration) - see that section for details on what each one does.

**Example Commands:**

```
evemajpreview://switch/Character%20Name
evemajpreview://profile/pvp.json
evemajpreview://hotkey/toggle_visibility
```

### Registration

Control whether the application automatically registers the protocol handler on startup with `autoRegisterProtocol`, in [Global Settings](#global-settings-profilesglobalsettingsjson) (it applies regardless of which profile is loaded, so it isn't part of any one profile's JSON):

```json
{
  "autoRegisterProtocol": true
}
```

When enabled (default: `true`), the application checks whether the protocol handler is registered at startup and registers it if needed. Registration writes to `HKEY_CURRENT_USER\Software\Classes\evemajpreview` rather than `HKEY_CLASSES_ROOT`, so it does not require administrator privileges. The registered command points at the currently running executable's path plus `--protocol "%1"`, so re-registration is needed if the executable is moved.

## Auto-Minimize

Automatically minimize inactive EVE clients after a delay:

```json
{
  "autoMinimize": {
    "enabled": false,
    "delayMs": 5000,
    "exemptLastActiveOnFocusLoss": true
  }
}
```

`delayMs` is clamped between `0` and `10000`.

The last-focused client on each monitor (by the monitor its EVE window is on) is treated as that monitor's last-active client. While an EVE client is focused, the last-active client on every other monitor stays visible, so one client per monitor can remain on screen; other clients minimize after the delay.

`exemptLastActiveOnFocusLoss` (default: `true`) keeps each monitor's last-active client visible when EVE itself loses focus entirely (e.g. switching to another app), instead of minimizing it along with the rest once its delay elapses.

Exclusions are configured per character, not here - set `excludeFromMinimize` on the character entry (see [Per-Character Configuration](#per-character-configuration)).

## Auto-Move Position

Move EVE client windows to their saved window positions automatically:

```json
{
  "autoMovePosition": {
    "enabled": false,
    "moveOnStartup": false,
    "verifyIntervalMs": 2000,
    "verifyCount": 6
  }
}
```

Each character's target is its `windowPosition` (see [Per-Character Configuration](#per-character-configuration)). `enabled` moves a client when a character logs in. `moveOnStartup` moves clients that are already running when the application starts; it works independently of `enabled`.

After each move, the client's position is re-checked every `verifyIntervalMs` (clamped `250`-`10000`), up to `verifyCount` times (clamped `0`-`30`; `0` disables re-checking), and re-applied if EVE shifted its own window while loading.

Exclusions are configured per character - set `excludeFromAutoMove` on the character entry (see [Per-Character Configuration](#per-character-configuration)).

## Close All

```json
{
  "closeAll": {
    "excludeLoginScreenClients": false
  }
}
```

`excludeLoginScreenClients` (default: `false`) skips any client still sitting at the character-selection screen.

Per-character exclusions are configured separately - set `excludeFromCloseAll` on the character entry (see [Per-Character Configuration](#per-character-configuration)).

## Notification System

Configure near-real-time event notifications from EVE game logs displayed as text overlays on thumbnails:

```json
{
  "thumbnail": {
    "notifications": {
      "enabled": true,
      "position": "Center",
      "offset_x": 0,
      "offset_y": 0,
      "suppress_click_duration_ms": 2000,
      "tts_volume": 100,
      "tts_rate": 0,
      "tts_speak_character_name": true,
      "tts_use_display_name": false,
      "notified_cycle_retention_seconds": 30,
      "type_configs": {
        "FleetInvite": {
          "enabled": true,
          "duration_ms": 10000,
          "suppress_when_focused": false,
          "suppress_when_clicked": false,
          "throttle_ms": 10000,
          "tts_enabled": false,
          "show_border": true,
          "flash_border": false,
          "border_color": null,
          "text_color": null
        },
        "SystemChange": {
          "enabled": true,
          "duration_ms": 3000,
          "suppress_when_focused": true,
          "suppress_when_clicked": false,
          "throttle_ms": 0,
          "tts_enabled": false,
          "show_border": true,
          "flash_border": false,
          "border_color": "0xFFFF0000",
          "text_color": "0xFFFFFF00"
        }
      }
    }
  }
}
```

**Notification Settings:**
- `enabled`: Master switch for notification system (per-character mute is set via `notificationsMuted` on the character entry - see [Per-Character Configuration](#per-character-configuration)) (default: `true`)
- `position`: Where notifications appear on thumbnails (see Text Positions above)
- `offset_x`/`offset_y`: Fine-tune notification position (pixels)
- `suppress_click_duration_ms`: How long to suppress after click, applies per-type when that type's `suppress_when_clicked` is `true` (milliseconds, default: `2000`)
- `tts_volume`: Speech volume, 0–100 (default: `100`)
- `tts_rate`: Speech rate, native SAPI range -10 (slowest) to 10 (fastest) (default: `0`)
- `tts_speak_character_name`: Prefix spoken alerts with `"<character>, "` (default: `true`)
- `tts_use_display_name`: When prefixing, speak the character's Custom Display Name instead of their character name; only consulted when `tts_speak_character_name` is `true`, and falls back to the character name if no display name is set (default: `false`)
- `notified_cycle_retention_seconds`: How long (seconds) a character stays eligible in the "cycle to recently notified character" hotkey's queue after its last notification, before aging out; re-notifying resets the window (clamped to 5–600, default: `30`) - see [Notified-Character Cycling](#notified-character-cycling)

**Per-Type Configuration** (each type has its own independent settings - there is no global default applied across types other than each field's own default shown below):
- `enabled`: Whether this notification type fires at all (default: `true`)
- `duration_ms`: How long the notification stays on screen (default: `10000`, or `3000` for notifications of your own actions such as hotkey toggles)
- `suppress_when_focused`: Suppress this type when the EVE client has focus (default: `false`)
- `suppress_when_clicked`: Suppress this type for `suppress_click_duration_ms` after the user clicks the thumbnail (default: `false`)
- `throttle_ms`: Ignore repeat notifications of this type until this many ms have passed since the last one actually shown (per thumbnail); suppressed attempts don't reset the window - `0` disables throttling (default: `10000`, or `0` for notifications of your own actions; clamped to 0–300000)
- `tts_enabled`: Speak this type's alert aloud - self-contained, there is no global TTS master switch (default: `false`)
- `sound_enabled`: Play `sound_path` as a custom sound alert - self-contained too, there is no global sound master switch either (default: `false`)
- `sound_path`: Absolute path to a `.wav` or `.mp3` file to play when this type fires; only these two formats are supported (decoded via Windows Media Foundation - no OGG or other formats). May be set while `sound_enabled` is `false` without losing the picked file (default: `null`)
- `sound_volume`: Playback volume for this type's sound alert, 0–100 (default: `100`); each type has its own, there is no shared/global volume
- `show_border`: Whether to draw a border at all while this notification is active; `false` suppresses the border entirely regardless of the Alert state's border settings or any `border_color` override (default: `false`)
- `flash_border`: Blink the border on/off 4 times (150ms per phase) when the notification starts, then settle into a steady-on border for the rest of the duration; has no effect when `show_border` is `false` (default: `false`)
- `border_color`: Optional ARGB color override for the thumbnail border while this notification is active (default: `null`, falls back to the Alert state's border color)
- `text_color`: Optional ARGB color override for the notification text while this notification is active (default: `null`, falls back to the thumbnail's normal text color)
- `custom_text`: Wording shown (and spoken) instead of the built-in text, with `{name}` placeholders filled from the event - see Custom Text Placeholders below. Names are case-insensitive, unknown names are kept as typed, and if a placeholder used has no value for that event the built-in text is shown instead. Type `\n` for a line break, up to 3 lines per notification; the Client List and History Panel show them on one line (default: `null`, the built-in text)
- `custom_text_alt`: `custom_text` for a two-state type's second state: Self-Destruct aborted, hotkeys resumed, auto-minimize off, removed from group, included in cycle (default: `null`)

**Custom Text Placeholders:**

| Type | Placeholders |
|---|---|
| `FleetInvite`, `ConversationInvite` | `{pilot}` |
| `FleetFollow`, `FleetRegroup` | `{leader}` |
| `MiningCompression` | `{ore}`, `{result}` (e.g. "10 Compressed Veldspar") |
| `AsteroidDepleted`, `CargoFull`, `BombLauncherEmpty` | `{module}` |
| `CrystalBroke` | `{module}`, `{crystal}` |
| `WarpScrambled`, `WarpDisrupted` | `{attacker}` |
| `Decloak`, `WarpBubble` | `{object}` |
| `SystemChange`, `ConduitJump` | `{system}` |
| `TravelLeftBehind` | `{system}`, `{group_system}` |
| `GroupMembership` | `{group}` |
| `ProfileSwitch` | `{profile}` |
| `Generic` | `{message}` |

Every type also offers `{character}`, except `HotkeySuspend`, `ProfileSwitch` and `AutoMinimizeToggle`, which show on every client at once.

**Notification Types:**
- `FleetInvite`: Fleet invitation received
- `FleetFollow`: Fleet follow command
- `FleetRegroup`: Fleet regroup command
- `FleetDisband`: Fleet disbanding notification
- `ConversationInvite`: Conversation/chat invitation
- `JumpCloning`: Clone jump started
- `MiningCompression`: Mining compression complete
- `AsteroidDepleted`: Asteroid mined out, mining laser deactivated
- `MiningIdle`: Laser idle - fewer events than threshold in the configured window
- `MiningStopped`: No mining events for the configured silence window
- `CargoFull`: Ship cargo hold is full (miner module completed ops)
- `TakingDamage`: Incoming damage recorded - see [Taking-Damage Alert](#combat-dps-overlay)
- `WarpScrambled`: Warp scramble attempt landed on you
- `WarpDisrupted`: Warp disruption (point) attempt landed on you
- `Decloak`: Ship decloaked due to proximity
- `ObservatoryDecloak`: Ship decloaked by Mobile Observatory pulse
- `CloakFailed`: Cloak activation failed (too close to object)
- `CrystalBroke`: Mining crystal depleted
- `BombLauncherEmpty`: Bomb Launcher has run out of charges
- `SelfDestruct`: Ship/capsule self-destruct initiated or aborted
- `Docking`: Action blocked while docking
- `AutopilotReached`: Autopilot waypoint reached
- `AutopilotApproaching`: Autopilot approaching target
- `JumpRange`: Too far from stargate to jump
- `AggressionCantJump`: Stargate denies jump due to recent acts of aggression
- `WarpBubble`: Caught in a warp disruption zone, unable to warp
- `ConduitJump`: Jumped via Conduit Field to a new system
- `SystemChange`: Jumped to new solar system
- `TravelLeftBehind`: Character hasn't jumped with the group within Travel Mode's configured window - see [Travel Mode](#travel-mode)
- `GroupMembership`: Character added to or removed from a hotkey group via its assign key; defaults to a 3s duration with no throttle
- `CycleExclusion`: Character excluded from or included in hotkey cycling; defaults to a 3s duration with no throttle
- `HotkeySuspend`: Hotkeys suspended or resumed; shown on every client
- `ProfileSwitch`: Switched to another profile; shown on every client once the new profile has loaded
- `AutoMinimizeToggle`: Auto-minimize toggled on or off by its hotkey; shown on every client
- `SavedPositionMove`: Client window moved by the "move to saved positions" hotkey; shown only on the clients that moved
- `Generic`: Other game events

### History Panel

A draggable list of recent notifications across all characters, with filter buttons for each category. Toggle it from the tray's "Show History Panel".

```json
{
  "display": {
    "showNotifInfoPanel": false,
    "notifInfoPanelX": 10,
    "notifInfoPanelY": 250,
    "notifInfoPanelWidth": 300,
    "notifInfoPanelHeight": 400,
    "rememberNotifInfoPanelPosition": true,
    "hideNotifInfoPanelWhenNoCharacters": true,
    "notifInfoPanelOpacity": 255,
    "notifInfoPanelFontName": "Segoe UI",
    "notifInfoPanelFontSize": 13,
    "notifInfoPanelFontWeight": "Regular",
    "notifInfoPanelMaxRows": 15,
    "notifInfoPanelShowTimestamp": false,
    "notifInfoPanelMergeEnabled": false,
    "notifInfoPanelMergeWindowSec": 10,
    "notifInfoPanelShowCategoryFilters": true,
    "notifInfoPanelShowFleet": true,
    "notifInfoPanelShowMining": true,
    "notifInfoPanelShowCombat": true,
    "notifInfoPanelShowNavigation": true,
    "notifInfoPanelShowGeneral": true
  }
}
```

- `showNotifInfoPanel`: Show the panel (default: `false`); the tray toggle sets this too
- `notifInfoPanelX` / `notifInfoPanelY`: Panel position on screen (default: `10`, `250`)
- `notifInfoPanelWidth` / `notifInfoPanelHeight`: Panel size, at least 100 × 60 (default: `300` × `400`)
- `rememberNotifInfoPanelPosition`: Save the position when you drag the panel (default: `true`)
- `hideNotifInfoPanelWhenNoCharacters`: Hide the panel while no character is logged in (default: `true`); turning it on from the tray shows it anyway until the next time everyone logs out
- `notifInfoPanelOpacity`: Panel opacity, 51–255 (default: `255`)
- `notifInfoPanelFontName`, `notifInfoPanelFontSize`, `notifInfoPanelFontWeight`: Font for the rows (default: `Segoe UI`, `13`, `Regular`; size 6–72)
- `notifInfoPanelMaxRows`: How many notifications the panel lists, 1–30 (default: `15`)
- `notifInfoPanelShowTimestamp`: Show each notification's time (default: `false`)
- `notifInfoPanelMergeEnabled`: Merge back-to-back identical notifications from different characters into one row with a `+N` count; clicking a merged row expands it (default: `false`)
- `notifInfoPanelMergeWindowSec`: Max gap in seconds between consecutive notifications for them to merge, 1–300 (default: `10`)
- `notifInfoPanelShowCategoryFilters`: Show the category filter buttons (default: `true`)
- `notifInfoPanelShowFleet`, `notifInfoPanelShowMining`, `notifInfoPanelShowCombat`, `notifInfoPanelShowNavigation`, `notifInfoPanelShowGeneral`: Whether each category is listed (default: `true`); clicking a filter button toggles its category and saves it here

## Chatlog Monitoring

Monitor EVE Online chat and game logs for system changes and events:

```json
{
  "chatlog": {
    "enabled": true,
    "chatlogDir": "C:/Users/YourName/Documents/EVE/logs/Chatlogs",
    "gamelogDir": "C:/Users/YourName/Documents/EVE/logs/Gamelogs",
    "pollIntervalMs": 500,
    "idlePollThreshold": 600,
    "maxPollMultiplier": 2
  }
}
```

**Environment Variables**: Both `chatlogDir` and `gamelogDir` support Windows environment variable expansion using `%VARIABLE%` syntax. For example:
- `"%USERPROFILE%/Documents/EVE/logs/Chatlogs"`
- `"%APPDATA%/EVE/logs/Gamelogs"`
- `"C:/Users/%USERNAME%/Documents/EVE/logs/Chatlogs"`

Variables are expanded when the configuration is loaded. If a variable doesn't exist, the literal text is preserved in the path.

Either folder left empty (the default) uses EVE's own: `EVE\logs\Chatlogs` or `EVE\logs\Gamelogs` under your Windows Documents folder, wherever it has been moved to (e.g. OneDrive).

**Threading**: Chatlog monitoring always runs on its own worker thread, so reading logs never holds up the thumbnails. (The old `useThreading` setting is ignored if a profile still has it.)

**Polling Optimization**: The chatlog monitor uses exponential backoff to reduce CPU usage for inactive log files:
- Files with no changes accumulate idle poll counts
- After reaching `idlePollThreshold` * current multiplier, the multiplier doubles (1x → 2x → 4x → 8x), stopping at `maxPollMultiplier`
- `maxPollMultiplier` (1–8) caps it to prevent excessive delays, e.g. a cap of 3 steps 1x → 2x → 3x
- Any file change resets the idle count and multiplier to 1x

## Combat DPS Overlay

Display real-time incoming/outgoing damage-per-second labels directly on each character's thumbnail, calculated over a configurable sliding time window from EVE gamelogs:

```json
{
  "combat": {
    "enabled": false,
    "window_seconds": 60,
    "show_incoming": true,
    "show_outgoing": true,
    "incoming_color": "0xFFFF4444",
    "outgoing_color": "0xFF44FF44",
    "incoming_bg_color": "0xE6000000",
    "outgoing_bg_color": "0xE6000000",
    "incoming_font_size": 12,
    "incoming_font_name": "Segoe UI",
    "incoming_font_weight": "Regular",
    "outgoing_font_size": 12,
    "outgoing_font_name": "Segoe UI",
    "outgoing_font_weight": "Regular",
    "update_interval_ms": 1000,
    "incoming_position": "TopCenter",
    "outgoing_position": "BottomCenter",
    "incoming_offset_x": 0,
    "incoming_offset_y": 0,
    "outgoing_offset_x": 0,
    "outgoing_offset_y": 0,
    "incoming_show_prefix": true,
    "outgoing_show_prefix": true,
    "damage_alert_excluded_weapons": ""
  }
}
```

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir` to receive combat events.

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the DPS overlay |
| `window_seconds` | `60` | Sliding window duration for DPS calculation (5–600 s) |
| `show_incoming` / `show_outgoing` | `true` | Show the incoming / outgoing damage label |
| `incoming_color` / `outgoing_color` | red / green | ARGB color for each label's text |
| `incoming_bg_color` / `outgoing_bg_color` | `0xE6000000` | ARGB background behind each label |
| `incoming_font_size` / `outgoing_font_size` | `12` | Font size for each label (6–72) |
| `incoming_font_name` / `outgoing_font_name` | `Segoe UI` | Font for each label |
| `incoming_font_weight` / `outgoing_font_weight` | `Regular` | Font weight for each label (see [Text Overlay Settings](#text-overlay-settings)) |
| `update_interval_ms` | `1000` | How often the display refreshes (1000–10000 ms); alerts are checked every second regardless |
| `incoming_position` | `TopCenter` | Position of the incoming-damage label on the thumbnail (see [Text Positioning](#text-positioning)) |
| `outgoing_position` | `BottomCenter` | Position of the outgoing-damage label on the thumbnail |
| `incoming_offset_x` / `incoming_offset_y` | `0` | Fine-tune incoming label position (-500–500 px) |
| `outgoing_offset_x` / `outgoing_offset_y` | `0` | Fine-tune outgoing label position (-500–500 px) |
| `incoming_show_prefix` / `outgoing_show_prefix` | `true` | Show each label's prefix before the number |
| `damage_alert_excluded_weapons` | `""` | Comma-separated, case-insensitive weapon-name parts whose hits count toward DPS but don't trigger the Taking Damage alert |

Incoming and outgoing damage are rendered as two independently-positioned labels rather than a single combined box.

**Taking-Damage Alert** (`TakingDamage` notification type): Fires when incoming damage lands, at most once per the type's `throttle_ms`, and stays silent once combat actually stops instead of repeating on a timer. It's switched on and off with the type's Enabled box in the Notifications tab (`type_configs.TakingDamage.enabled`), where its border color, duration, suppression and TTS are also set.

**Direction Classification**: EVE gamelog `(combat)` lines start with the damage number, and the text after it decides the direction, `" from "` checked before `" to "`:
- **Incoming**: `" from "` anywhere after the amount - e.g. `63 from Gistatis Legatus - Hits` or `26 from Gistatis Legatus - Nova Light Missile - Hits`
- **Outgoing**: otherwise `" to "` anywhere after the amount - e.g. `166 to Gistatis Legatus - Berserker II - Grazes`
- **Incoming misses**: `misses you completely` counts as a zero-damage incoming hit, so it still raises Taking Damage
- **Excluded**: remote repairs, boosts and cap transfers (`repairs your`, `shields your`, `boosts your`, `transfers`), outgoing misses (no leading damage number), and unrecognised formats

**DPS Formula**: Total damage within the window divided by `window_seconds`. During the first `window_seconds` of a fight (after a full window without hits), it's the damage after the first second divided by the time since, shown as `??` for the first 3 seconds. If every hit so far landed in the fight's first second, it's that damage divided by `window_seconds`. The display refreshes every `update_interval_ms`.

## Mining Rate Overlay

Display a real-time mining rate overlay on each character's thumbnail, calculated over a configurable sliding time window from EVE gamelogs. Also supports alerts when a laser goes idle or mining stops entirely.

```json
{
  "mining": {
    "enabled": false,
    "window_seconds": 60,
    "color": "0xFF44AAFF",
    "bg_color": "0xE6000000",
    "font_size": 12,
    "font_name": "Segoe UI",
    "font_weight": "Regular",
    "update_interval_ms": 1000,
    "position": "BottomRight",
    "offset_x": 0,
    "offset_y": 0,
    "idle_alert_window_seconds": 30,
    "idle_alert_threshold": 1,
    "stopped_alert_window_seconds": 60,
    "show_isk_rate": true,
    "isk_rate_unit": "hour",
    "show_prefix": true
  }
}
```

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir` to receive mining events.

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the mining rate overlay |
| `window_seconds` | `60` | Sliding window duration for rate calculation (30–3600 s) |
| `color` | light blue | ARGB color for the rate text |
| `bg_color` | `0xE6000000` | ARGB background behind the label |
| `font_size` | `12` | Font size for the rate label (6–72) |
| `font_name` / `font_weight` | `Segoe UI` / `Regular` | Font for the rate label (see [Text Overlay Settings](#text-overlay-settings)) |
| `update_interval_ms` | `1000` | How often the display refreshes (1000–10000 ms); alerts are checked every second regardless |
| `position` | `BottomRight` | Position of the text on the thumbnail |
| `offset_x` / `offset_y` | `0` | Fine-tune position (-500–500 px) |
| `idle_alert_window_seconds` | `30` | Window in which events are counted for the idle check (30–600 s) |
| `idle_alert_threshold` | `1` | Fire alert when event count in window is ≤ this value (0–60) |
| `stopped_alert_window_seconds` | `60` | Seconds of silence before the stopped alert fires (30–3600 s) |
| `show_isk_rate` | `true` | Show the ISK rate of what's mined alongside the m³ rate |
| `isk_rate_unit` | `hour` | Show the ISK rate per `hour` or per `minute` |
| `show_prefix` | `true` | Show the label's prefix before the numbers |

The Laser Idle and Mining Stopped alerts are switched on and off with their types' Enabled boxes in the Notifications tab (`type_configs.MiningIdle.enabled` and `type_configs.MiningStopped.enabled`).

**Rate Formula**: Total m³ mined within the window (units × the ore's volume) divided by `window_seconds`, converted to per-minute for display. Displays as `M: XXXX m3/min`, with the ISK rate of the same yield beneath it when `show_isk_rate` is on. During the first `window_seconds` of mining, it's the units mined after the first cycle divided by the time from the first yield to the latest, so lasers cycling in step read their true rate from the second cycle on. Bounty ISK/hr works the same way.

**Parsing**: EVE gamelog `(mining)` lines are parsed for yield quantity:
- **Normal yield**: `You mined 42 units of Bistot II-Grade`
- **Critical yield**: `Critical mining success! You mined an additional 124 units of Bistot II-Grade`
- **Excluded**: residue/waste lines (`depleted from asteroid as residue`) are ignored

**Laser Idle Alert** (`MiningIdle` notification type): Fires when the number of `(mining)` events within `idle_alert_window_seconds` drops to `≤ idle_alert_threshold`. Useful for detecting when one of two lasers stops. It isn't checked until mining has run for a whole `idle_alert_window_seconds`, so starting to mine doesn't trigger it. The alert fires once per idle stretch and re-arms only when activity rises above the threshold again.

**Mining Stopped Alert** (`MiningStopped` notification type): Fires once when no `(mining)` events have occurred for `stopped_alert_window_seconds` seconds, after the character was previously mining. Re-arms automatically when mining resumes.

**Cargo Full** (`CargoFull` notification type): Fires when the gamelog contains `"Ship's cargo hold is full"` - e.g. `Your Modulated Strip Miner II has completed operations. Ship's cargo hold is full.` This is a `(notify)` event and requires no extra configuration beyond enabling the notification type.

## Bounty ISK Overlay

Display each character's bounty ISK rate on its thumbnail, from the `(bounty)` lines EVE writes to the gamelog as bounties are added to the next payout (e.g. `120,272 ISK added to next bounty payout`).

```json
{
  "bounty": {
    "enabled": false,
    "window_seconds": 1200,
    "color": "0xFFFFD700",
    "bg_color": "0xE6000000",
    "font_size": 12,
    "font_name": "Segoe UI",
    "font_weight": "Regular",
    "update_interval_ms": 1000,
    "position": "TopRight",
    "offset_x": 0,
    "offset_y": 0,
    "isk_rate_unit": "hour",
    "show_prefix": true
  }
}
```

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir` to receive bounty events.

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the bounty overlay |
| `window_seconds` | `1200` | Sliding window duration for the rate (60–3600 s) |
| `color` | gold | ARGB color for the rate text |
| `bg_color` | `0xE6000000` | ARGB background behind the label |
| `font_size` | `12` | Font size for the label (6–72) |
| `font_name` / `font_weight` | `Segoe UI` / `Regular` | Font for the label (see [Text Overlay Settings](#text-overlay-settings)) |
| `update_interval_ms` | `1000` | How often the display refreshes (1000–10000 ms) |
| `position` | `TopRight` | Position of the text on the thumbnail |
| `offset_x` / `offset_y` | `0` | Fine-tune position (-500–500 px) |
| `isk_rate_unit` | `hour` | Show the rate per `hour` or per `minute` |
| `show_prefix` | `true` | Show the label's prefix before the number |

**Rate Formula**: The same as the mining rate: ISK added within the window divided by `window_seconds`, and during the first `window_seconds` of earning, the ISK after the first payout divided by the time from the first payout to the latest.

## Resource Usage Overlay

Display each client's CPU%, RAM, and dedicated VRAM usage as a single combined text label on its thumbnail, sampled directly from the OS rather than from EVE's logs:

```json
{
  "resources": {
    "enabled": false,
    "show_cpu": true,
    "show_ram": true,
    "show_vram": true,
    "color": "0xFFFFFFFF",
    "bg_color": "0xE6000000",
    "font_size": 12,
    "font_name": "Segoe UI",
    "font_weight": "Regular",
    "update_interval_ms": 10000,
    "position": "LeftCenter",
    "offset_x": 0,
    "offset_y": 0
  }
}
```

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the resource usage overlay |
| `show_cpu` | `true` | Include the CPU% segment |
| `show_ram` | `true` | Include the RAM segment (process working-set memory, in MB) |
| `show_vram` | `true` | Include the VRAM segment (dedicated GPU memory, in MB) - see note below |
| `update_interval_ms` | `10000` | How often CPU/RAM/VRAM are resampled (1000-60000 ms); shared by all three since VRAM sampling is the most expensive of the three |
| `position` | `LeftCenter` | Position of the label on the thumbnail (see [Text Positions](#text-overlay-settings)) |
| `offset_x`/`offset_y` | `0` | Fine-tune label position (pixels) |

**CPU%**: Process CPU time (kernel + user) sampled via `GetProcessTimes`, normalized by elapsed wall time and logical processor count - the same basis Task Manager uses, clamped to 0-100%. The first sample after a character logs in or the overlay is turned on has nothing to diff against, so it reads 0% until the second sample.

**RAM**: The process's current working-set size via `GetProcessMemoryInfo`.

**VRAM**: Dedicated GPU memory via the Windows "GPU Process Memory" performance counter (the same source Task Manager's GPU column uses). This requires the `pdh.dll` perf counter subsystem to be available and the counter category to exist; if either is missing, `show_vram` silently has no effect and the label falls back to just CPU/RAM. VRAM segments are omitted from the label until a value is actually available for that process, even with `show_vram: true`.

## Travel Mode

Detects a tracked character falling behind while the rest of the group jumps together between solar systems, and fires a `TravelLeftBehind` notification. There is no manual on/off toggle beyond `enabled` - detection is entirely automatic, based on which system each character currently occupies.

```json
{
  "travel": {
    "enabled": false,
    "window_seconds": 30,
    "threshold_mode": "percent",
    "threshold_percent": 50.0,
    "threshold_count": 2
  }
}
```

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable Travel Mode detection |
| `window_seconds` | `30` | Grace period (1–3600 s): how long a straggler has to jump into the group's current system before being flagged |
| `threshold_mode` | `percent` | `percent` or `count` - which of the two fields below decides how large the co-located group must be before it counts as "the group is traveling" |
| `threshold_percent` | `50.0` | Used when `threshold_mode` is `percent`: minimum percentage (1–100) of eligible characters that must share the group's current system |
| `threshold_count` | `2` | Used when `threshold_mode` is `count`: minimum fixed number (1–50) of eligible characters that must share the group's current system |

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir`/`chatlogDir` to detect jumps.

**Eligibility**: A character only participates in Travel Mode once it has jumped (stargate or Conduit Field - not undock) at least once in the current session, and only if it isn't excluded via the existing shift-click character exclusion used elsewhere in the app (Hotkeys tab).

**Detection logic** (evaluated roughly every 2 seconds):
1. Among eligible characters, find the "group system" - whichever current solar system the largest number of them share.
2. If fewer than `threshold_percent`/`threshold_count` of eligible characters are in that system, this isn't treated as a real group trip (e.g. one character jumping around alone) and nothing fires.
3. Otherwise, any eligible character in a *different* system is a straggler. Once that character has been away for longer than `window_seconds` (measured from when the last group member arrived), a `TravelLeftBehind` notification fires once for that character.
4. The alert re-arms the moment that character jumps - whether they catch up to the group's system (clearing the alert) or jump elsewhere (re-evaluated against the group next tick). Because "caught up" is based on current system rather than jump order, a straggler who jumps in late never causes the characters who arrived first to be flagged.

## Hotkey Configuration

```json
{
  "hotkeys": {
    "requireEveFocus": false,
    "resetGroupIndexOnNonGroupFocus": false,
    "allowHotkeyAutoRepeat": false,
    "exactHotkeyModifiers": false,
    "hotkeyMinimizeAll": null,
    "hotkeyCloseAll": null,
    "hotkeyCloseActive": null,
    "hotkeyToggleVisibility": null,
    "hotkeyToggleAutoMinimize": null,
    "hotkeyToggleExclusion": null,
    "hotkeyNextExcluded": null,
    "hotkeyPreviousExcluded": null,
    "hotkeySuspend": null,
    "hotkeyExitApp": null,
    "hotkeyCycleNotified": null,
    "hotkeyPreviousNotified": null,
    "hotkeyMoveToSavedPositions": null
  }
}
```

**requireEveFocus**: Only trigger hotkeys while an EVE client window has focus

**resetGroupIndexOnNonGroupFocus**: Reset a hotkey group's cycle position when focus leaves that group

**allowHotkeyAutoRepeat**: When `false` (default), holding a keyboard hotkey down fires its action once; when `true`, Windows' key-repeat re-fires it while held. Mouse-button hotkeys always fire once per click regardless (mouse buttons don't auto-repeat).

**exactHotkeyModifiers**: When `false` (default), a combo with no binding of its own falls back to the bare key's binding, so a hotkey on `1` also fires (and swallows) `Alt+1`. When `true`, a hotkey fires only when exactly its modifiers are held, and unbound combos pass through to the game. Applies to keyboard and mouse hotkeys.

Pressing **hotkeySuspend** fires a `HotkeySuspend` notification on every client (see [Notification System](#notification-system)).

**Global Hotkeys**: Set to a key name (e.g., `"F9"`, `"F10"`), a modifier combo (e.g., `"Ctrl+F9"`, `"Alt+Shift+F1"`, `"LWin+M"`), a hex virtual key code (`"0x70"`), or `null` to disable. Names are accepted when editing by hand, but the app saves every hotkey back as its hex code (`"Ctrl+F9"` becomes `"0x278"`). A key the app can't read is skipped with a warning in the log, and the rest of the binding and profile load as normal.
- **hotkeyMinimizeAll**: Minimize all EVE client windows
- **hotkeyCloseAll**: Close all EVE client windows (respects per-character `excludeFromCloseAll`)
- **hotkeyCloseActive**: Close the focused EVE client window, even if its character is excluded from Close All
- **hotkeyToggleVisibility**: Toggle visibility of all thumbnails
- **hotkeyToggleAutoMinimize**: Toggle auto-minimize mode on/off
- **hotkeyToggleExclusion**: Toggle exclusion from cycling for the currently focused EVE window
- **hotkeyNextExcluded**: Cycle to the next excluded character (in the order they were excluded)
- **hotkeyPreviousExcluded**: Cycle to the previous excluded character
- **hotkeySuspend**: Suspend/resume all other hotkeys at once
- **hotkeyExitApp**: Exit EVE-Maj Preview, same as the tray menu's Exit. EVE clients stay open.
- **hotkeyCycleNotified**: Cycle forward through recently notified characters, oldest first (see [Notified-Character Cycling](#notified-character-cycling))
- **hotkeyPreviousNotified**: Cycle backward through recently notified characters
- **hotkeyMoveToSavedPositions**: Move all EVE client windows to their saved positions (respects per-character `excludeFromAutoMove`)
**Virtual Key Codes**: See [virtual_keys.zig](../src/platform/virtual_keys.zig) for full list

**Modifier Combos**: Any global hotkey field, hotkey group key, per-character hotkey, or profile-switch hotkey can be prefixed with one or more modifiers, combined with `+`: `Ctrl`/`Control`, `Alt`, `Shift`, `Win`/`LWin`/`RWin` (e.g. `"Ctrl+Alt+F9"`).

**Multiple Keys**: Any of those fields (including app and URL hotkeys) also takes an array of up to 4 keys, each with its own modifiers, any of which triggers the action (e.g. `"forwardKey": ["F22", "XButton2", "Ctrl+1"]`). A single key is saved as a plain string; duplicates are dropped, and keys past the fourth are dropped with a warning in the log.

### Global Settings (profiles\global.settings.json)

Some settings persist across all profiles and are configured in `profiles\global.settings.json`:

```json
{
  "lastUsedProfile": "default.json",
  "hotkeyNextProfile": "F20",
  "hotkeyPreviousProfile": "F21",
  "profileSwitchHotkeys": [
    { "hotkey": "F13", "targetProfile": "pvp.json" },
    { "hotkey": "F14", "targetProfile": "mining.json" }
  ],
  "appHotkeys": [
    { "hotkey": "LWin+D", "executableName": "Discord.exe" }
  ],
  "urlHotkeys": [
    { "hotkey": "LWin+M", "url": "https://evemaps.dotlan.net/" },
    { "hotkey": "LWin+I", "url": "https://adashboard.info/intel", "uploadClipboard": true }
  ],
  "hotkeyCycleAllClientsForward": "F22",
  "hotkeyCycleAllClientsBackward": "F23",
  "cycleAllClientsRespectExclusions": false,
  "hotkeyCycleNotLoggedInForward": "F18",
  "hotkeyCycleNotLoggedInBackward": "F19",
  "hotkeyReturnToLastApp": "LWin+Z",
  "disableUpdateChecks": false,
  "autoRegisterProtocol": true,
  "runOnStartup": false,
  "alwaysOnTop": true,
  "language": "en",
  "advancedMode": false,
  "logLevel": "err",
  "oreTable": [
    { "name": "Veldspar", "price": 11.53 }
  ]
}
```

**Global Settings:**
- **lastUsedProfile**: Last loaded profile (automatically updated)
- **hotkeyNextProfile**: Hotkey to cycle to next profile (in directory enumeration order - typically alphabetical, but not guaranteed)
- **hotkeyPreviousProfile**: Hotkey to cycle to previous profile
- **profileSwitchHotkeys**: List of hotkeys bound directly to a specific target profile (`targetProfile` is the profile's filename, e.g. `"pvp.json"`). Unlike `hotkeyNextProfile`/`hotkeyPreviousProfile`, each binding jumps straight to its configured profile instead of cycling. These stay active regardless of which profile is currently loaded, and can be edited from the config dialog's Hotkeys tab ("Profiles" section).
- **appHotkeys**: List of hotkeys bound to an external (non-EVE) application, matched by its executable name (e.g. `"Discord.exe"`) at press time. Picked from a dropdown of currently running windows in the config dialog's Hotkeys tab ("Outside EVE" section, uses the same window picker as Window Filters). If more than one window matches the executable, the frontmost one is activated; if none match, the hotkey is a no-op.
- **urlHotkeys**: List of hotkeys that open a URL in the OS default browser (via `ShellExecute`, same as clicking a link). Editable from the config dialog's Hotkeys tab ("Outside EVE" section), which also offers one-click presets for [Dotlan](https://evemaps.dotlan.net/) and [aDashboard Intel](https://adashboard.info/intel) alongside free-form custom URLs.
  - **uploadClipboard**: If `true`, instead of just opening `url`, the current clipboard text is POSTed to it first as `application/x-www-form-urlencoded` (field `Paste anything`, matching aDashboard's paste-intake form and ShareX's custom uploader for it), the resulting page's URL replaces the clipboard content, and that page is opened instead. Falls back to opening the plain `url` if the clipboard has no text or the upload fails. Runs on a background thread so the app doesn't freeze during the request; a second press while one is still in flight is ignored rather than starting an overlapping upload. The config dialog's checkbox for this only appears when `url`'s host is `adashboard.info`, since the POST body shape is specific to that site's form.
- **hotkeyCycleAllClientsForward** / **hotkeyCycleAllClientsBackward**: Cycle through every currently logged-in EVE client, ordered by the profile's Characters list (any client not yet added there follows after, in detection order), regardless of which profile is loaded or how hotkey groups are defined. Editable from the config dialog's Hotkeys tab ("Clients" section).
- **cycleAllClientsRespectExclusions**: If `true`, characters excluded via Shift+Click (or `hotkeyToggleExclusion`) are skipped when cycling all clients, whether or not they belong to a hotkey group (default: `false`, cycles through every client)
- **hotkeyCycleNotLoggedInForward** / **hotkeyCycleNotLoggedInBackward**: Cycle through the clients sitting at the login screen (title just "EVE"), oldest logout first. Stays active regardless of which profile is loaded.
- **hotkeyReturnToLastApp**: Refocus whichever non-EVE window last held focus (e.g. jump back to your browser or Discord after switching into EVE). Stays active regardless of which profile is loaded; editable from the config dialog's Hotkeys tab ("Outside EVE" section).
- **disableUpdateChecks**: Set to `true` to disable automatic update checks on startup (default: `false`)
- **autoRegisterProtocol**: See [Registration](#registration) under Protocol Handler (default: `true`)
- **runOnStartup**: Start EVE-Maj Preview when you sign in to Windows, through the current user's `Run` registry key (default: `false`)
- **alwaysOnTop**: Keep the configuration window above other windows (default: `true`)
- **language**: Configuration window language: `en`, `de`, `es`, `fr`, `pl`, `pt`, `ru` or `zh` (default: `en`)
- **logLevel**: See [Logging](#logging) (default: `err`)
- **advancedMode**: See [Config Dialog Advanced Mode](#config-dialog-advanced-mode) (default: `false`)
- **dialogX** / **dialogY**: Where the configuration window last was, saved when you move it (default: `null`, near the top-left of the screen; also used when the saved spot is on no monitor)
- **dialogScale**: The configuration window's UI scale in percent, 50–300; `0` picks one from the screen resolution (default: `0`)
- **oreTable**: Your ISK-per-unit price overrides for the mining ISK rate, one `{ "name", "price" }` entry per ore; ores you haven't overridden use the built-in price. A name matches its grade variants too (e.g. `Veldspar` covers `Veldspar II-Grade`). Editable from the config dialog's ore price table (0–1,000,000,000,000).

**Profile Cycling Features:**
- Cycle forward/backward through profiles with wraparound
- Set either or both hotkeys to `null` to disable
- Profiles are enumerated from the `profiles` directory
- Allows quick switching between different profile configurations (e.g., PvP, Mining, Trading) without using the system tray or command-line arguments
- Deleting a profile moves its file to `profiles\backup\` (timestamp-prefixed) instead of removing it; the config dialog's Import modal can restore from these backups

### Hotkey Groups (Character Cycling)

```json
{
  "hotkeyGroups": [
    {
      "name": "Main Fleet",
      "forwardKey": "F22",
      "backwardKey": null,
      "includeNotLoggedIn": false,
      "stopAtEnds": false,
      "characters": ["Main Character", "Alt 1", "Alt 2"]
    },
    {
      "name": "Scouts",
      "forwardKey": "F15",
      "backwardKey": "F16",
      "assignKey": "Ctrl+1",
      "temporaryMembership": true,
      "showBadge": true,
      "characters": []
    }
  ]
}
```

- **name**: Optional user-facing name for the group (default: empty string)
- **forwardKey**/**backwardKey**: Cycle forward/backward through the group's members; both optional, so a group can be assign-only
- **assignKey**: Hovering a thumbnail and pressing this key toggles that character's membership in the group - added if not already a member, removed if it is
- **temporaryMembership**: When `true`, membership is runtime-only: assign-key edits are never written back to the profile and the group starts empty every launch. When `false`, assign-key edits change the profile's own character list (default: `false`)
- **showBadge**: Draws the group's name on its members' thumbnails, styled by the [Group Badge](#group-badge) settings (default: `false`)
- **includeNotLoggedIn**: When `true`, cycling this group appends still-queued not-logged-in clients (the same windows the `next_not_logged_in`/`previous_not_logged_in` hotkeys cycle) after the group's characters, in the order they logged out (default: `false`)
- **stopAtEnds**: When `true`, cycling stops at the group's first/last member instead of looping round; pressing on at the end refocuses that member if focus has moved away (default: `false`)

**Supported Keys:**
- **Function Keys**: F1-F24
- **Arrow Keys**: Left, Right, Up, Down
- **Navigation**: PageUp, PageDown, Home, End, Insert, Delete
- **Letters**: A-Z (case-insensitive)
- **Numbers**: 0-9
- **Numpad**: Numpad0-Numpad9, NumpadAdd, NumpadSubtract, NumpadMultiply, NumpadDivide, NumpadDecimal
- **Special**: Space, Tab, Enter, Backspace, Pause, CapsLock, NumLock, ScrollLock, PrintScreen, Menu
- **Punctuation**: `;` `=` `,` `-` `.` `/` `` ` `` `[` `\` `]` `'`
- **Media**: VolumeMute, VolumeDown, VolumeUp, MediaNext, MediaPrevious, MediaStop, MediaPlayPause
- **Mouse**: MButton, XButton1, XButton2, WheelUp, WheelDown
- **Bare modifiers**: Ctrl, Alt, Shift or Win alone as the trigger key
- **Modifiers**: Any of the above can be combined with `Ctrl`/`Alt`/`Shift`/`Win` - see [Modifier Combos](#hotkey-configuration)

### Per-Character Hotkeys (Direct Activation)

In addition to hotkey groups, each character can have its own dedicated hotkey that jumps straight to that character's window - no group membership required. Configured via the `hotkey` field on a character entry (see [Per-Character Configuration](#per-character-configuration)):

```json
{
  "characters": [
    {
      "name": "Main Character",
      "hotkey": "F1"
    }
  ]
}
```

Uses the same [supported keys](#hotkey-groups-character-cycling) as hotkey groups. Set to `null` to disable.

Assigning the same hotkey to more than one character turns it into an implicit cycling group - each press jumps to the next running character sharing that key, in profile order.

### Notified-Character Cycling

Bound via `hotkeyCycleNotified` and `hotkeyPreviousNotified` (see [Hotkey Configuration](#hotkey-configuration)), these hotkeys step through the characters that recently triggered a notification, without needing to click through thumbnails to find who needs attention.

- Characters are tracked in a FIFO queue: each notification adds (or re-adds) the character at the back of the queue.
- A character stays eligible for `notified_cycle_retention_seconds` (see [Notification System](#notification-system)) after its last notification, then ages out; a new notification resets the window.
- `hotkeyCycleNotified` cycles forward through the queue, oldest-still-eligible first, wrapping back to the start; `hotkeyPreviousNotified` cycles backward through the same order. Both share one cursor, so switching directions continues from wherever the last press left off. Characters that are no longer running are skipped.

## Per-Character Configuration

Customize individual characters with position, size, border colors, display names, a dedicated hotkey, opacity, auto-minimize/Close All/auto-move exclusions, hiding the thumbnail entirely, and muting notifications:

```json
{
  "characters": [
    {
      "name": "Main Character",
      "position": { "x": 100, "y": 200 },
      "windowPosition": { "x": -7, "y": 0 },
      "borderColors": {
        "activeBorderColor": "0xFFFF00FF",
        "inactiveBorderColor": "0xFF808080"
      },
      "thumbnailSize": {
        "width": 400,
        "height": 300
      },
      "displayName": "Main",
      "hotkey": "F1",
      "opacity": 255,
      "excludeFromMinimize": true,
      "excludeFromCloseAll": true,
      "excludeFromAutoMove": false,
      "hideThumbnail": false,
      "notificationsMuted": false
    },
    {
      "name": "Scout Character",
      "position": { "x": 10, "y": 10 },
      "thumbnailSize": {
        "width": 200,
        "height": 150
      }
    }
  ]
}
```

- **position**: Where this character's thumbnail sits (screen pixels).
- **windowPosition**: Where this character's EVE client window goes when moved to its saved position (see [Auto-Move Position](#auto-move-position)). Set it with Save Position on the Characters tab while the client is running. It's the window's top-left corner, including the few pixels of invisible resize border Windows adds, so a client snapped to a screen's left edge saves at about `x: -7`. A position whose title bar would be off every screen (e.g. after a monitor was removed) is pulled onto the nearest monitor.
- **borderColors**: Optional `activeBorderColor` / `inactiveBorderColor` overrides for this character's thumbnail border; either can be left out to use the thumbnail's own.
- **thumbnailSize**: Optional `width` / `height` override for this character's thumbnail (ignored in `RegionFit` mode).
- **nameColor**: Optional color for this character's name text, taking precedence over `useUniqueCharacterNameColors`.
- **displayName**: Optional name shown instead of the character name on the thumbnail and in the Client List (and spoken, with `tts_use_display_name`).
- **hotkey**: Optional. Virtual key code string (same format as [hotkey groups](#hotkey-groups-character-cycling)) that directly activates this character's window. `null`/omitted to disable. See [Per-Character Hotkeys](#per-character-hotkeys-direct-activation).
- **opacity**: Optional per-character override for `thumbnailOpacity` (default: `null`, inherits the global value; clamped to the same 51–255 minimum).
- **excludeFromMinimize**: Skip this character when auto-minimize fires (default: `false`). See [Auto-Minimize](#auto-minimize).
- **excludeFromCloseAll**: Skip this character when the Close All hotkey fires (default: `false`). See [Close All](#close-all).
- **excludeFromAutoMove**: Skip this character when moving EVE client windows to their saved positions, whether via the auto-move-on-login setting or the `hotkeyMoveToSavedPositions` hotkey (default: `false`).
- **hideThumbnail**: Hide this character's thumbnail (and its row in list view) entirely, regardless of state (default: `false`).
- **notificationsMuted**: Suppress all notifications for this character, regardless of the global/per-type notification settings (default: `false`). See [Notification System](#notification-system).

**Note**: Character positions are automatically saved when you drag thumbnails. Manual editing is not recommended.

## System Color Overrides

Define custom colors for specific solar systems:

```json
{
  "systemColors": [
    { "systemName": "Jita, Amarr", "color": "0xFFD700" },
    { "systemName": "Rancer, Amamake", "color": "0xFF0000" },
    { "systemName": "J######", "color": "0x00BFFF" }
  ]
}
```

`systemName` is a comma-separated list of names and patterns. Matching ignores case and leading/trailing spaces around each name. Patterns support `*` (any text), `?` (any one character) and `#` (any one digit), so `J######` matches every wormhole system but not `Jita`.

> **Note**: An exact name always beats a pattern, regardless of row order; otherwise the first matching row wins.

With `useUniqueSystemColors` on, systems without an override get an automatically assigned color: the palette color farthest from your overrides and every other assigned color. `useUniqueCharacterNameColors` does the same for character names, and `useUniqueCharacterBorderColors` for the focused border (a character's own `borderColors.activeBorderColor` wins); a character gets one stored color used for both, avoiding every character's own `nameColor` and active border color. Assignments are kept for the 64 most recently seen systems and 64 most recently seen characters in `data/colors.json` (shared by all profiles), written when the last EVE client closes or the app exits; delete the file to reassign them.

Chatlog monitoring also keeps each character's EVE character ID, read from its log file names, in `data/character_ids.json`, so later lookups skip reading log headers; it's managed automatically, and deleting it only means the IDs are found again from the logs.

> **Note**: The key is `systemName`, not `name`. Unknown keys are ignored, so an entry using `name` loads with no system names and never matches.

## Config Dialog Accent Color

```json
{
  "accentColor": "0xFFD9A441"
}
```

Sets the accent color used by the config dialog's own UI (buttons, focus rings, tabs) for this profile. Purely cosmetic - it has no effect on thumbnail rendering or the running overlay. Chosen when creating, copying, or importing into a profile.

## Config Dialog Advanced Mode

```json
{
  "advancedMode": false
}
```

Whether the config dialog's Advanced Mode (extra, rarely-changed settings sections and tabs) is on. Dialog-only - has no effect on the running overlay. Lives in `global.settings.json`, not the profile JSON, so it applies across every profile instead of resetting when you switch.

## Color Format

Colors are hexadecimal strings in `"0xAARRGGBB"` form: alpha, then red, green and blue. `0x`/`0X` prefixes, a `#` prefix, and bare hex digits with no prefix (e.g. `"FF606060"`) are all accepted. A six-digit `"0xRRGGBB"` is read with an alpha of `00`.

Where alpha applies:
- **Text colors** (character and system names, notification text, overlay labels, badges) ignore alpha and are always drawn opaque, so `"0xFFFFFF"` and `"0xFFFFFFFF"` are the same white.
- **Everything else** (borders, text backgrounds, the exclusion overlay) uses it: `0xFF` is fully opaque, `0x80` about half transparent, and `0x00` fully transparent, so a six-digit color there is invisible.

Examples:
```json
"0xFFFFFFFF"   // White (opaque)
"0xFFFF0000"   // Red (opaque)
"0xFF606060"   // Gray (opaque)
"0x80000000"   // Black, about 50% transparent
"0x00FFFFFF"   // White text; invisible as a border or background
```


