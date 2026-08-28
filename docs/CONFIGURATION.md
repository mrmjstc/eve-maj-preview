# Configuration Reference

Configuration files use **JSON format**. The application generates a default profile at `profiles\default.json` on first run. 

## Logging

```json
{
  "logLevel": "info"
}
```

Log levels (from most to least verbose):
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
    "borderColor": "0xFFE4E4E4",
    "borderStyle": "Solid",
    "showBorderWhenInactive": false,
    "inactiveBorderWidth": 1,
    "inactiveBorderColor": "0xFF606060",
    "inactiveBorderStyle": "Solid",
    "textBgColorInheritBorderColor": false
  }
}
```

Set `textBgColorInheritBorderColor` to `true` to reuse the current border color for the text background while preserving the alpha from `textBgColor`.

**Border Styles**: `Solid`, `Dashed`, `Dotted`, `Double`, `DiagonalHatch`, `DashDot`, `CornerBrackets`

### Text Overlay Settings
```json
{
  "thumbnail": {
    "showText": true,
    "showCharacterName": true,
    "showSystemName": false,
    "textColor": "0x00FFFFFF",
    "textBgColor": "0x80000000",
    "textFontName": "Segoe UI",
    "textFontSize": 14,
    "textFontWeight": "Regular",
    "useUniqueSystemColors": false,
    "systemNameColor": "0x00FFFFFF"
  }
}
```

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

### Quick Group Badge

```json
{
  "thumbnail": {
    "showQuickGroupBadge": true,
    "quickGroupBadgeColor": "0xFF44FF44",
    "quickGroupBadgePosition": "RightCenter",
    "quickGroupBadgeOffsetX": 0,
    "quickGroupBadgeOffsetY": 0
  }
}
```

Drawn on a thumbnail whenever its character is a current member of any [Quick Group](#quick-groups-hover-assigned-temporary-cycling). `quickGroupBadgePosition` uses the same values as [Text Positions](#text-overlay-settings).

### Exclusion Overlay

```json
{
  "thumbnail": {
    "exclusionOverlayStyle": "X",
    "exclusionOverlayColor": "0x33FF0000"
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

> **Note:** These per-state overrides are not currently exposed as editable profile JSON keys - they exist as fixed built-in defaults used at render time. `alert` state visuals (border color/width) are driven separately via the per-notification-type `border_color` override - see [Notification System](#notification-system).

## Timer and Scanning

```json
{
  "timer": {
    "scanIntervalMs": 50
  }
}
```

`scanIntervalMs` defaults to `50` and is clamped between `50` and `10000`.

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
- **name**: User-friendly name for the filter (descriptive only)
- **enabled**: Whether this filter is active (default: `true`)
- **class_names**: Array of window class names to match (empty array = match any)
- **executable_names**: Array of executable names to match (case-insensitive, empty array = match any)

**How It Works:**
1. The application scans all visible windows every `scanIntervalMs`
2. Each window's class name is checked against all enabled filters
3. If a class name matches, the executable path is verified against the filter's executable names
4. Both checks must pass for a window to be tracked


## Display and Positioning

The display configuration supports multiple layout modes for arranging thumbnails automatically, with full multi-monitor support.

**Basic Configuration:**

```json
{
  "display": {
    "startX": 10,
    "startY": 10,
    "spacing": 10,
    "layoutMode": "HorizontalList",
    "gridColumns": 4,
    "honorSavedPositions": true
  }
}
```

**Layout Modes:**

- **`HorizontalList`** (default): Multi-row grid, fills left-to-right, then wraps to next row
- **`Grid`**: Classic grid with configurable rows/columns and directional fill patterns
- **`VerticalList`**: Multi-column grid, fills top-to-bottom, then starts new column
- **`VerticalStack`**: Single column, thumbnails stacked vertically
- **`HorizontalStack`**: Single row, thumbnails stacked horizontally
- **`Overlay`**: All thumbnails at the same position (for minimal space/hotkey switching)
- **`Custom`**: No auto-layout, uses only saved positions

**Multi-Monitor Support:**

Target specific monitors by index (0-based):

```json
{
  "display": {
    "layoutMode": "Grid",
    "gridColumns": 4,
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

**Grid Configuration:**

```json
{
  "display": {
    "layoutMode": "Grid",
    "layoutDirection": "RowFirst_LTR_TTB",
    "gridColumns": 4,
    "gridRows": 3,
    "spacing": 10
  }
}
```

**Layout Directions** (for Grid mode):
- `RowFirst_LTR_TTB`: Left→right, top→bottom (default)
- `RowFirst_RTL_TTB`: Right→left, top→bottom
- `RowFirst_LTR_BTT`: Left→right, bottom→top
- `RowFirst_RTL_BTT`: Right→left, bottom→top
- `ColumnFirst_TTB_LTR`: Top→bottom, left→right
- `ColumnFirst_BTT_LTR`: Bottom→top, left→right
- `ColumnFirst_TTB_RTL`: Top→bottom, right→left
- `ColumnFirst_BTT_RTL`: Bottom→top, right→left

**Stack Alignment:**

Control how stacks align on their secondary axis:

```json
{
  "display": {
    "layoutMode": "VerticalStack",
    "stackAlignment": "Center",
    "stackOffset": 10,
    "startX": 960
  }
}
```

For **VerticalStack** (aligns horizontally):
- `TopLeft`, `LeftCenter`, `BottomLeft`: Left edge at startX
- `TopCenter`, `Center`, `BottomCenter`: Centered on startX
- `TopRight`, `RightCenter`, `BottomRight`: Right edge at startX

For **HorizontalStack** (aligns vertically):
- `TopLeft`, `TopCenter`, `TopRight`: Top edge at startY
- `LeftCenter`, `Center`, `RightCenter`: Centered on startY
- `BottomLeft`, `BottomCenter`, `BottomRight`: Bottom edge at startY

**Advanced Spacing:**

Use different horizontal and vertical spacing:

```json
{
  "display": {
    "spacing": 10,
    "spacingX": 20,
    "spacingY": 5
  }
}
```

- `spacing`: Default spacing if `spacingX`/`spacingY` not specified
- `spacingX`: Horizontal spacing between thumbnails (overrides `spacing`)
- `spacingY`: Vertical spacing between thumbnails (overrides `spacing`)

**Example Configurations:**

**Overlay Mode** (minimal space):
```json
{
  "display": {
    "layoutMode": "Overlay",
    "startX": 100,
    "startY": 100,
    "honorSavedPositions": false
  }
}
```

**Second Monitor Grid**:
```json
{
  "display": {
    "layoutMode": "Grid",
    "gridColumns": 6,
    "monitorIndex": 1,
    "startX": 0,
    "startY": 0
  }
}
```

**Centered Vertical Stack**:
```json
{
  "display": {
    "layoutMode": "VerticalStack",
    "stackAlignment": "Center",
    "startX": 960,
    "startY": 10,
    "stackOffset": 10
  }
}
```

**All Display Options:**

- `startX`, `startY`: Starting position (absolute or monitor-relative)
- `spacing`: Default spacing between thumbnails
- `spacingX`, `spacingY`: Per-direction spacing (optional)
- `layoutMode`: Layout arrangement mode
- `layoutDirection`: Direction for grid growth
- `gridColumns`: Number of columns
- `gridRows`: Maximum rows (null = unlimited)
- `stackOffset`: Spacing for stack modes
- `stackAlignment`: Alignment for stacks on secondary axis
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
- `listViewOpacity`: Panel opacity, 0–255 (default: `255`)
- `listViewColumns`: Number of columns, 1–15 (default: `1`)
- `listViewFontName`, `listViewFontSize`, `listViewFontWeight`: Font used for row text (font weight uses the same values as [Text Overlay Settings](#text-overlay-settings))

## Window Snapping

```json
{
  "snapping": {
    "enabled": true,
    "threshold": 10,
    "screenEdges": true,
    "thumbnailEdges": true
  }
}
```

## User Interaction

```json
{
  "interaction": {
    "enableDragging": true,
    "animationStyle": "NoAnimation",
    "clickTrigger": "MouseDown"
  }
}
```

**Configuration Options:**
- `enableDragging`: Enable or disable thumbnail dragging (default: `true`)
- `animationStyle`: Control Windows animations during window switching
  - `"NoAnimation"` (default): Temporarily disable system animations for faster window switching
  - `"OriginalAnimation"`: Use Windows default minimize/restore animations
- `clickTrigger`: When left-click activates the EVE client
  - `"MouseDown"` (default): Activate immediately on mouse button press
  - `"MouseUp"`: Activate on mouse button release

**Animation Style Details:**

By default (`"NoAnimation"`), the application temporarily disables Windows system-wide minimize and restore animations when switching to a client, then immediately restores them. This provides near-instant window switching. Set to `"OriginalAnimation"` if you prefer to keep Windows default animations.

**Mouse Interactions:**
- **Left-click**: Activate and bring the EVE client to foreground
- **Right-click + Drag**: Move thumbnail position (hold Ctrl to move all thumbnails)
- **Shift + Left-click**: Toggle character exclusion from hotkey cycling
  - Excluded characters show a visual overlay (default: semi-transparent red "X"; see [Exclusion Overlay](#exclusion-overlay) for other styles)
  - "Excluded" or "Included" notification appears for 5 seconds
  - Excluded characters are skipped when using hotkey group cycling (if the character belongs to a group) and when using Cycle All Clients with `cycleAllClientsRespectExclusions` enabled - works even for characters that don't belong to any hotkey group
  - Exclusion state is temporary (resets when application restarts)
  - Can also be toggled via `hotkeyToggleExclusion` for the focused EVE window
  - Use `hotkeyNextExcluded`/`hotkeyPreviousExcluded` to cycle through excluded characters for review

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
- **`profile/<filename>`**: Load the named profile (filename relative to `profiles\`, e.g. `pvp.json`).
- **`hotkey/<action>`**: Trigger one of the hotkey actions below, exactly as if its configured global hotkey had been pressed.

**Hotkey Actions:**

| Action | Effect |
|---|---|
| `minimize_all` | Minimize all EVE client windows |
| `close_all` | Close all EVE client windows |
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

These correspond directly to the actions in [Hotkey Configuration](#hotkey-configuration) - see that section for details on what each one does.

**Example Commands:**

```
evemajpreview://switch/Character%20Name
evemajpreview://profile/pvp.json
evemajpreview://hotkey/toggle_visibility
```

### Registration

Control whether the application automatically registers the protocol handler on startup with `autoRegisterProtocol`, under `"hotkeys"` (see [Hotkey Configuration](#hotkey-configuration)):

```json
{
  "hotkeys": {
    "autoRegisterProtocol": true
  }
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
    "exemptLastActiveOnFocusLoss": false
  }
}
```

`delayMs` is clamped between `0` and `10000`.

`exemptLastActiveOnFocusLoss` (default: `false`) keeps the last-focused client visible when EVE itself loses focus entirely (e.g. switching to another app), instead of minimizing it along with the rest once its delay elapses.

Exclusions are configured per character, not here - set `excludeFromMinimize` on the character entry (see [Per-Character Configuration](#per-character-configuration)).

## Close All

```json
{
  "closeAll": {}
}
```

Exclusions are configured per character, not here - set `excludeFromCloseAll` on the character entry (see [Per-Character Configuration](#per-character-configuration)).

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
      "suppress_click_duration_ms": 5000,
      "tts_enabled": false,
      "tts_volume": 100,
      "tts_rate": 0,
      "tts_speak_character_name": true,
      "tts_use_display_name": false,
      "notified_cycle_retention_seconds": 30,
      "type_configs": {
        "FleetInvite": {
          "enabled": true,
          "duration_ms": 5000,
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
- `enabled`: Master switch for notification system
- `position`: Where notifications appear on thumbnails (see Text Positions above)
- `offset_x`/`offset_y`: Fine-tune notification position (pixels)
- `suppress_click_duration_ms`: How long to suppress after click, applies per-type when that type's `suppress_when_clicked` is `true` (milliseconds, default: `5000`)
- `tts_enabled`: Master switch for text-to-speech - a given alert only speaks when this **and** its own `tts_enabled` are both `true` (default: `false`)
- `tts_volume`: Speech volume, 0–100 (default: `100`)
- `tts_rate`: Speech rate, native SAPI range -10 (slowest) to 10 (fastest) (default: `0`)
- `tts_speak_character_name`: Prefix spoken alerts with `"<character>, "` (default: `true`)
- `tts_use_display_name`: When prefixing, speak the character's Custom Display Name instead of their character name; only consulted when `tts_speak_character_name` is `true`, and falls back to the character name if no display name is set (default: `false`)
- `notified_cycle_retention_seconds`: How long (seconds) a character stays eligible in the "cycle to recently notified character" hotkey's queue after its last notification, before aging out; re-notifying resets the window (clamped to 5–600, default: `30`) - see [Notified-Character Cycling](#notified-character-cycling)

**Per-Type Configuration** (each type has its own independent settings - there is no global default applied across types other than each field's own default shown below):
- `enabled`: Whether this notification type fires at all (default: `true`)
- `duration_ms`: How long the notification stays on screen (default: `5000`)
- `suppress_when_focused`: Suppress this type when the EVE client has focus (default: `false`)
- `suppress_when_clicked`: Suppress this type for `suppress_click_duration_ms` after the user clicks the thumbnail (default: `false`)
- `throttle_ms`: Ignore repeat notifications of this type until this many ms have passed since the last one actually shown (per thumbnail); suppressed attempts don't reset the window - `0` disables throttling (default: `10000`, clamped to 0–300000)
- `tts_enabled`: Speak this type's alert aloud - requires the global `tts_enabled` master switch above to also be `true` (default: `false`)
- `show_border`: Whether to draw a border at all while this notification is active; `false` suppresses the border entirely regardless of the Alert state's border settings or any `border_color` override (default: `true`)
- `flash_border`: Blink the border on/off 4 times (150ms per phase) when the notification starts, then settle into a steady-on border for the rest of the duration; has no effect when `show_border` is `false` (default: `false`)
- `border_color`: Optional ARGB color override for the thumbnail border while this notification is active (default: `null`, falls back to the Alert state's border color)
- `text_color`: Optional ARGB color override for the notification text while this notification is active (default: `null`, falls back to the thumbnail's normal text color)

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
- `Generic`: Other game events

## Chatlog Monitoring

Monitor EVE Online chat and game logs for system changes and events:

```json
{
  "chatlog": {
    "enabled": true,
    "chatlogDir": "C:/Users/YourName/Documents/EVE/logs/Chatlogs",
    "gamelogDir": "C:/Users/YourName/Documents/EVE/logs/Gamelogs",
    "pollIntervalMs": 500,
    "idlePollThreshold": 20,
    "maxPollMultiplier": 8,
    "useThreading": true
  }
}
```

**Environment Variables**: Both `chatlogDir` and `gamelogDir` support Windows environment variable expansion using `%VARIABLE%` syntax. For example:
- `"%USERPROFILE%/Documents/EVE/logs/Chatlogs"`
- `"%APPDATA%/EVE/logs/Gamelogs"`
- `"C:/Users/%USERNAME%/Documents/EVE/logs/Chatlogs"`

Variables are expanded when the configuration is loaded. If a variable doesn't exist, the literal text is preserved in the path.

**Threading Support**: When enabled (default: `true`), chatlog monitoring runs in a dedicated worker thread with async I/O processing:
- Prevents blocking the main thread during file operations
- Improves UI responsiveness and thumbnail rendering performance
- Uses thread-safe event queues for communication between worker and main threads
- Set to `false` to disable threading and run chatlog monitoring synchronously (useful for debugging)

**Polling Optimization**: The chatlog monitor uses exponential backoff to reduce CPU usage for inactive log files:
- Files with no changes accumulate idle poll counts
- After reaching `idlePollThreshold` * current multiplier, the multiplier doubles (1x → 2x → 4x → 8x)
- The multiplier is capped at `maxPollMultiplier` to prevent excessive delays
- Any file change resets the idle count and multiplier to 1x

## Combat DPS Overlay

Display real-time incoming/outgoing damage-per-second labels directly on each character's thumbnail, calculated over a configurable sliding time window from EVE gamelogs:

```json
{
  "combat": {
    "enabled": false,
    "windowSeconds": 60,
    "showIncoming": true,
    "showOutgoing": true,
    "incomingColor": 4294934596,
    "outgoingColor": 4279017540,
    "fontSize": 11,
    "updateIntervalMs": 1000,
    "incomingPosition": "TopCenter",
    "outgoingPosition": "BottomCenter",
    "incomingOffsetX": 0,
    "incomingOffsetY": 0,
    "outgoingOffsetX": 0,
    "outgoingOffsetY": 0,
    "damageAlertEnabled": false,
    "damageAlertRepeatSeconds": 10,
    "iconEnabled": false,
    "iconColor": "0xFFFF4444",
    "iconPosition": "TopRight",
    "iconOffsetX": 0,
    "iconOffsetY": 0,
    "iconFontSize": 20
  }
}
```

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir` to receive combat events.

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the DPS overlay |
| `windowSeconds` | `60` | Sliding window duration for DPS calculation (1–3600 s) |
| `showIncoming` | `true` | Show incoming damage label |
| `showOutgoing` | `true` | Show outgoing damage label |
| `incomingColor` | red | ARGB color for incoming damage text |
| `outgoingColor` | green | ARGB color for outgoing damage text |
| `fontSize` | `11` | Font size for DPS labels (6–72) |
| `updateIntervalMs` | `1000` | How often the display refreshes (100–60000 ms) |
| `incomingPosition` | `TopCenter` | Position of the incoming-damage label on the thumbnail (see [Text Positions](#text-overlay-settings)) |
| `outgoingPosition` | `BottomCenter` | Position of the outgoing-damage label on the thumbnail |
| `incomingOffsetX`/`incomingOffsetY` | `0` | Fine-tune incoming label position (pixels) |
| `outgoingOffsetX`/`outgoingOffsetY` | `0` | Fine-tune outgoing label position (pixels) |
| `damageAlertEnabled` | `false` | Enable the taking-damage alert (see below) |
| `damageAlertRepeatSeconds` | `10` | Minimum seconds between repeat alerts while still taking damage (1–3600 s) |
| `iconEnabled` | `false` | Enable the persistent combat icon (see below) |
| `iconColor` | red | ARGB color for the combat icon |
| `iconPosition` | `TopRight` | Position of the icon on the thumbnail |
| `iconOffsetX`/`iconOffsetY` | `0` | Fine-tune icon position (pixels) |
| `iconFontSize` | `20` | Icon size (6–72) |

Incoming and outgoing damage are rendered as two independently-positioned labels rather than a single combined box.

**Taking-Damage Alert**: When `damageAlertEnabled` is `true`, a `TakingDamage` notification (see [Notification Types](#notification-system)) fires the first time incoming damage is recorded, then re-fires at most once per `damageAlertRepeatSeconds` while more incoming hits keep landing - it stays silent once combat actually stops instead of repeating on a bare timer. Border color, duration, suppression, and TTS for the alert are configured generically like any other notification type, under `TakingDamage` in `type_configs`.

**Combat Icon**: When `iconEnabled` is `true`, a persistent icon is drawn on the thumbnail for as long as incoming DPS is above zero - an ambient "under fire" indicator, independent of the one-shot taking-damage alert above.

**Direction Classification**: EVE gamelog `(combat)` lines are classified by the keyword immediately following the damage number:
- **Incoming**: line contains `" from "` after the amount - e.g. `63 from Gistatis Legatus - Hits` or `26 from Gistatis Legatus - Nova Light Missile - Hits`
- **Outgoing**: line contains `" to "` after the amount - e.g. `166 to Gistatis Legatus - Berserker II - Grazes`
- **Excluded**: remote repairs/cap transfers (keyword scan), misses (no leading damage number), and unrecognised formats

**DPS Formula**: Total damage within the window divided by `windowSeconds`. The display refreshes every `updateIntervalMs`.

## Mining Rate Overlay

Display a real-time mining rate overlay on each character's thumbnail, calculated over a configurable sliding time window from EVE gamelogs. Also supports alerts when a laser goes idle or mining stops entirely.

```json
{
  "mining": {
    "enabled": false,
    "windowSeconds": 60,
    "color": 4282690303,
    "fontSize": 11,
    "updateIntervalMs": 1000,
    "position": "BottomRight",
    "offsetX": 0,
    "offsetY": 0,
    "idleAlertEnabled": false,
    "idleAlertWindowSeconds": 30,
    "idleAlertThreshold": 1,
    "stoppedAlertEnabled": false,
    "stoppedAlertWindowSeconds": 60
  }
}
```

> **Note**: Requires `chatlog.enabled: true` and a valid `gamelogDir` to receive mining events.

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable the mining rate overlay |
| `windowSeconds` | `60` | Sliding window duration for rate calculation (1–3600 s) |
| `color` | light blue | ARGB color for the rate text |
| `fontSize` | `11` | Font size for the rate label (6–72) |
| `updateIntervalMs` | `1000` | How often the display refreshes (100–60000 ms) |
| `position` | `BottomRight` | Position of the text on the thumbnail |
| `offsetX` / `offsetY` | `0` | Fine-tune position (pixels) |
| `idleAlertEnabled` | `false` | Enable the laser-idle alert notification |
| `idleAlertWindowSeconds` | `30` | Window in which events are counted for the idle check |
| `idleAlertThreshold` | `1` | Fire alert when event count in window is ≤ this value |
| `stoppedAlertEnabled` | `false` | Enable the mining-stopped alert notification |
| `stoppedAlertWindowSeconds` | `60` | Seconds of silence before the stopped alert fires |

**Rate Formula**: Total units mined within the window divided by `windowSeconds`, converted to per-minute for display. Displays as `M: XXXX u/min`.

**Parsing**: EVE gamelog `(mining)` lines are parsed for yield quantity:
- **Normal yield**: `You mined 42 units of Bistot II-Grade`
- **Critical yield**: `Critical mining success! You mined an additional 124 units of Bistot II-Grade`
- **Excluded**: residue/waste lines (`depleted from asteroid as residue`) are ignored

**Laser Idle Alert** (`MiningIdle` notification type): Fires when the number of `(mining)` events within `idleAlertWindowSeconds` drops to `≤ idleAlertThreshold`. Useful for detecting when one of two lasers stops. The alert fires once per window-duration cooldown and resets when activity rises above threshold again.

**Mining Stopped Alert** (`MiningStopped` notification type): Fires once when no `(mining)` events have occurred for `stoppedAlertWindowSeconds` seconds, after the character was previously mining. Re-arms automatically when mining resumes.

**Cargo Full** (`CargoFull` notification type): Fires when the gamelog contains `"Ship's cargo hold is full"` - e.g. `Your Modulated Strip Miner II has completed operations. Ship's cargo hold is full.` This is a `(notify)` event and requires no extra configuration beyond enabling the notification type.

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
    "autoRegisterProtocol": true,
    "hotkeyMinimizeAll": null,
    "hotkeyCloseAll": null,
    "hotkeyToggleVisibility": null,
    "hotkeyToggleAutoMinimize": null,
    "hotkeyToggleExclusion": null,
    "hotkeyNextExcluded": null,
    "hotkeyPreviousExcluded": null,
    "hotkeySuspend": null,
    "hotkeyCycleNotified": null,
    "hotkeyPreviousNotified": null
  }
}
```

**requireEveFocus**: Only trigger hotkeys while an EVE client window has focus

**resetGroupIndexOnNonGroupFocus**: Reset a hotkey group's cycle position when focus leaves that group

**Global Hotkeys**: Set to a virtual key code string (e.g., `"F9"`, `"F10"`, `"0x70"`), a modifier combo (e.g., `"Ctrl+F9"`, `"Alt+Shift+F1"`, `"LWin+M"`), or `null` to disable
- **hotkeyMinimizeAll**: Minimize all EVE client windows
- **hotkeyCloseAll**: Close all EVE client windows (respects per-character `excludeFromCloseAll`)
- **hotkeyToggleVisibility**: Toggle visibility of all thumbnails
- **hotkeyToggleAutoMinimize**: Toggle auto-minimize mode on/off
- **hotkeyToggleExclusion**: Toggle exclusion from cycling for the currently focused EVE window
- **hotkeyNextExcluded**: Cycle to the next excluded character (in the order they were excluded)
- **hotkeyPreviousExcluded**: Cycle to the previous excluded character
- **hotkeySuspend**: Suspend/resume all other hotkeys at once
- **hotkeyCycleNotified**: Cycle forward to the character that most recently triggered a notification (see [Notified-Character Cycling](#notified-character-cycling))
- **hotkeyPreviousNotified**: Cycle backward through recently notified characters
**Virtual Key Codes**: See [virtual_keys.zig](src/virtual_keys.zig) for full list

**Modifier Combos**: Any global hotkey field, hotkey group key, per-character hotkey, or profile-switch hotkey can be prefixed with one or more modifiers, combined with `+`: `Ctrl`/`Control`, `Alt`, `Shift`, `Win`/`LWin`/`RWin` (e.g. `"Ctrl+Alt+F9"`).

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
  "hotkeyCycleAllClientsForward": "F22",
  "hotkeyCycleAllClientsBackward": "F23",
  "cycleAllClientsRespectExclusions": false,
  "disableUpdateChecks": false
}
```

**Global Settings:**
- **lastUsedProfile**: Last loaded profile (automatically updated)
- **hotkeyNextProfile**: Hotkey to cycle to next profile (in directory enumeration order - typically alphabetical, but not guaranteed)
- **hotkeyPreviousProfile**: Hotkey to cycle to previous profile
- **profileSwitchHotkeys**: List of hotkeys bound directly to a specific target profile (`targetProfile` is the profile's filename, e.g. `"pvp.json"`). Unlike `hotkeyNextProfile`/`hotkeyPreviousProfile`, each binding jumps straight to its configured profile instead of cycling. These stay active regardless of which profile is currently loaded, and can be edited from the config dialog's Hotkeys tab ("Profile Switch Hotkeys" section).
- **hotkeyCycleAllClientsForward** / **hotkeyCycleAllClientsBackward**: Cycle through every currently logged-in EVE client, in the order they were detected, regardless of which profile is loaded or how hotkey groups are defined. Editable from the config dialog's Hotkeys tab ("Cycle All Clients" section).
- **cycleAllClientsRespectExclusions**: If `true`, characters excluded via Shift+Click (or `hotkeyToggleExclusion`) are skipped when cycling all clients, whether or not they belong to a hotkey group (default: `false`, cycles through every client)
- **disableUpdateChecks**: Set to `true` to disable automatic update checks on startup (default: `false`)
- **characterIdMap**: Internal mapping of character names to session IDs (managed automatically)

**Profile Cycling Features:**
- Cycle forward/backward through profiles with wraparound
- Set either or both hotkeys to `null` to disable
- Profiles are enumerated from the `profiles` directory
- Allows quick switching between different profile configurations (e.g., PvP, Mining, Trading) without using the system tray or command-line arguments

### Hotkey Groups (Character Cycling)

```json
{
  "hotkeyGroups": [
    {
      "name": "Main Fleet",
      "forwardKey": "F22",
      "backwardKey": null,
      "characters": ["Main Character", "Alt 1", "Alt 2"]
    },
    {
      "name": "Mining Fleet",
      "forwardKey": "F15",
      "backwardKey": "F16",
      "characters": ["Mining Hulk 1", "Mining Hulk 2", "Orca"]
    }
  ]
}
```

- **name**: Optional user-facing name for the group (default: empty string)

**Supported Keys:**
- **Function Keys**: F1-F24
- **Arrow Keys**: Left, Right, Up, Down
- **Navigation**: PageUp, PageDown, Home, End, Insert, Delete
- **Letters**: A-Z (case-insensitive)
- **Numbers**: 0-9
- **Numpad**: Numpad0-Numpad9, NumpadAdd, NumpadSubtract, NumpadMultiply, NumpadDivide, NumpadDecimal
- **Special**: Space
- **Modifiers**: Any of the above can be combined with `Ctrl`/`Alt`/`Shift`/`Win` - see [Modifier Combos](#hotkey-configuration)

### Quick Groups (Hover-Assigned Temporary Cycling)

An alternative to hotkey groups for ad-hoc fleets: instead of pre-listing characters in the profile, hover a thumbnail and press the group's assign key to toggle that character in or out.

```json
{
  "quickGroups": [
    {
      "name": "Scouts",
      "assignKey": "Ctrl+1",
      "forwardKey": "F15",
      "backwardKey": "F16"
    }
  ]
}
```

- **name**: Optional user-facing name for the group (default: empty string)
- **assignKey**: Hovering a thumbnail and pressing this key toggles that character's membership in the group - added if not already a member, removed if it is
- **forwardKey**/**backwardKey**: Cycle forward/backward through the group's current members, same as hotkey group cycling but without exclusion-list support
- Uses the same [supported keys](#hotkey-groups-character-cycling) as hotkey groups

Membership is **never persisted** - it lives only in memory and resets every time the application restarts, unlike hotkey groups which are defined statically in the profile. Members currently in a quick group are marked with a badge on their thumbnail, configurable under `thumbnail` in profile JSON: `showQuickGroupBadge`, `quickGroupBadgeColor`, `quickGroupBadgePosition`, `quickGroupBadgeOffsetX`/`quickGroupBadgeOffsetY` (same position values as [Text Positions](#text-overlay-settings)).

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

Bound via `hotkeyCycleNotified` and `hotkeyPreviousNotified` (see [Hotkey Configuration](#hotkey-configuration)), these hotkeys jump to whichever character most recently triggered a notification, without needing to click through thumbnails to find who needs attention.

- Characters are tracked in a FIFO queue: each notification adds (or re-adds) the character at the back of the queue.
- A character stays eligible for `notified_cycle_retention_seconds` (see [Notification System](#notification-system)) after its last notification, then ages out; a new notification resets the window.
- `hotkeyCycleNotified` cycles forward through the queue, oldest-still-eligible first, wrapping back to the start; `hotkeyPreviousNotified` cycles backward through the same order. Both share one cursor, so switching directions continues from wherever the last press left off. Characters that are no longer running are skipped.

## Per-Character Configuration

Customize individual characters with position, size, border colors, display names, a dedicated hotkey, auto-minimize/Close All exclusions, and hiding the thumbnail entirely:

```json
{
  "characters": [
    {
      "name": "Main Character",
      "position": { "x": 100, "y": 200 },
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
      "excludeFromMinimize": true,
      "excludeFromCloseAll": true,
      "hideThumbnail": false
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

- **hotkey**: Optional. Virtual key code string (same format as [hotkey groups](#hotkey-groups-character-cycling)) that directly activates this character's window. `null`/omitted to disable. See [Per-Character Hotkeys](#per-character-hotkeys-direct-activation).
- **excludeFromMinimize**: Skip this character when auto-minimize fires (default: `false`). See [Auto-Minimize](#auto-minimize).
- **excludeFromCloseAll**: Skip this character when the Close All hotkey fires (default: `false`). See [Close All](#close-all).
- **hideThumbnail**: Hide this character's thumbnail (and its row in list view) entirely, regardless of state (default: `false`).

**Note**: Character positions are automatically saved when you drag thumbnails. Manual editing is not recommended.

## System Color Overrides

Define custom colors for specific solar systems:

```json
{
  "systemColors": [
    { "systemName": "Jita", "color": "0xFFD700" },
    { "systemName": "Amarr", "color": "0xFFD700" },
    { "systemName": "Rancer", "color": "0xFF0000" },
    { "systemName": "Amamake", "color": "0xFF0000" }
  ]
}
```

> **Note**: The key is `systemName`, not `name` - an entry using the wrong key will fail to load and abort loading the entire profile.

## Color Format

Colors use hexadecimal string format in JSON:
- **RGB format**: `"0xRRGGBB"` (no transparency, fully opaque)
- **ARGB format**: `"0xAARRGGBB"` (includes alpha/transparency)

`0x`/`0X` prefixes, a `#` prefix, and bare hex digits with no prefix (e.g. `"FF606060"`) are all accepted.

Examples:
```json
"0x00FFFFFF"   // White (opaque)
"0x00FF0000"   // Red (opaque)
"0x0000FF00"   // Green (opaque)
"0x000000FF"   // Blue (opaque)
"0x80000000"   // Black with 50% transparency
"0xFF606060"   // Gray (opaque)
"0xFF00FFFF"   // Cyan (opaque)
```

Alpha channel values:
- `0xFF` = 255 = Fully opaque
- `0x80` = 128 = 50% transparent
- `0x00` = 0 = Fully transparent


