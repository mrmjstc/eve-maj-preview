
# EVE-Maj Preview

![EVE-Maj Preview screenshot](http://i.mjst.cc/V8tzkjPpU4.png)
![EVE-Maj Preview thumbnails](http://i.mjst.cc/BGIojpNJon.gif)

A *very* lightweight Windows tool for displaying DWM-based thumbnail previews of EVE Online client windows with customizable borders, text overlays, and advanced configuration options.

## What EVE-Maj Preview Isn't

It's **never** going to let you input broadcast, display portions of your eve client, manipulate your eve client in any way or intentionally help you break the EVE Online EULA/TOS. 

> **Not publicly supported.** This is built for my corporation, friends, and anyone brave enough to run it - not a supported public release. Use it as-is, no guarantees, no support whatsoever.

## Features

- **Live Thumbnails**: Real-time DWM thumbnails of EVE client windows
- **Compact List View**: Single-panel alternative to thumbnails, one row per client with state, name, and system/notification text
- **Multi-Application Support**: Configurable window filters to track any Windows app
- **Notification System**: Per-type event alerts with suppression, border color/flash, and TTS
- **Text-to-Speech Alerts**: Speaks notifications via Windows SAPI, with per-type opt-in and adjustable volume/rate
- **Notified-Character Cycling**: Hotkey to jump between recently notified characters
- **Profile System**: Multiple configs with hotkey-based cycling
- **Configuration Editor**: Standalone GUI (`config.exe`) for editing settings without touching JSON
- **Hotkey Groups**: Cycle or switch clients via keyboard shortcuts
- **Quick Groups**: Hover + key toggles a character into a temporary cycling group, no config needed
- **Per-Character Hotkeys**: Dedicated hotkey to jump straight to one character
- **Auto-Minimize**: Minimizes inactive clients after a delay, with per-character exclusions
- **Per-Character Customization**: Override colors, sizes, names, hotkeys, and more
- **Persistent Positions**: Thumbnail positions save and restore automatically
- **Chatlog Monitoring**: Tracks system changes and combat/mining events from EVE logs
- **Combat DPS Overlay**: Real-time incoming/outgoing DPS per character
- **Taking-Damage Alert**: Notifies the moment incoming damage is recorded
- **Mining Rate Overlay**: Real-time units/min with laser-idle and mining-stopped alerts
- **Protocol Handler**: `evemajpreview://` URLs for external control - character switching, profile loading, hotkeys
- **Automatic Update Checks**: Checks GitHub releases on startup
- **No Telemetry**: I don't need to know you're using the app, that's insane

## Installation

1. Download the latest release or build from source using Zig 0.15.2
2. Extract to your desired location
3. Run `config.exe` for configuration
4. Run `eve-maj-preview.exe` for thumbnails

## Usage

### Basic Usage

Just run eve-maj-preview.exe and start some EVE clients.

The application will:
1. Create a `profiles` directory if it doesn't exist
2. Generate a default profile (`profiles\default.json`)
3. Create thumbnail windows for each client found

### Command-Line Flags

```powershell
.\eve-maj-preview.exe --profile pvp.json
.\eve-maj-preview.exe -p pvp.json
```

- `--profile <name>` / `-p <name>`: Load a specific profile by filename (relative to the `profiles` directory - do not include the `profiles\` prefix)
- `--protocol <url>`: Internal flag used when Windows invokes the registered `evemajpreview://` protocol handler; not intended for manual use

### Profile Management

If no `--profile`/`-p` flag is given, the application loads whichever profile was last used (`lastUsedProfile` in `profiles\global.settings.json`), falling back to `profiles\default.json` on first run. Whichever profile is loaded becomes the new `lastUsedProfile` for next time.

### Configuration Editor

Right-click the system tray icon and choose **Open Configuration...** to launch `config.exe`, a standalone editor for the current profile's settings.

### Protocol Handler

EVE-Maj Preview supports the `evemajpreview://` protocol handler for external integration. This allows you to control the application with Steam Decks, etc.

**Example Commands:**

```
evemajpreview://switch/Character%20Name          - Switch to character
evemajpreview://profile/pvp.json                 - Load profile
evemajpreview://hotkey/minimize_all              - Minimize all clients
evemajpreview://hotkey/close_all                 - Close all clients
evemajpreview://hotkey/toggle_visibility         - Toggle thumbnails
evemajpreview://hotkey/toggle_auto_minimize      - Toggle auto-minimize mode
evemajpreview://hotkey/next_profile              - Cycle to next profile
evemajpreview://hotkey/previous_profile          - Cycle to previous profile
evemajpreview://hotkey/toggle_exclusion          - Toggle exclusion of the focused character from cycling
evemajpreview://hotkey/next_excluded             - Cycle to next excluded character
evemajpreview://hotkey/previous_excluded         - Cycle to previous excluded character
evemajpreview://hotkey/suspend_hotkeys           - Suspend/resume all hotkeys
evemajpreview://hotkey/cycle_notified            - Cycle to most recently notified character
evemajpreview://hotkey/previous_notified         - Cycle backward through notified characters
evemajpreview://hotkey/next_all_clients          - Cycle forward through all logged-in clients
evemajpreview://hotkey/previous_all_clients      - Cycle backward through all logged-in clients
evemajpreview://hotkey/next_not_logged_in        - Cycle forward through not-logged-in clients
evemajpreview://hotkey/previous_not_logged_in    - Cycle backward through not-logged-in clients
```


## Configuration Reference

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full configuration reference, covering every profile JSON setting, thumbnail/display/notification options, hotkeys, and the color format.

## Building from Source

Requires Zig 0.15.2:

```powershell
zig build
```

Run directly:

```powershell
zig build run
```

## Architecture

- **Scout** (`src/scout.zig`): Owns and tracks EVE window list (single source of truth)
- **Painter** (`src/painter.zig`): DWM thumbnails with text overlays and visual states
- **List View** (`src/list_view.zig`): Compact text-based client list, an alternative to DWM thumbnails
- **Manager** (`src/manager.zig`): Window operations (minimize, close, auto-minimize)
- **State** (`src/state.zig`): State machine (Inactive, Active, Hover, Alert, Minimized, Dragging, Hidden)
- **Config** (`src/config.zig`): Profile system with per-character overrides
- **Config Dialog** (`src/config_dialog.zig`): Standalone GUI configuration editor (`config.exe`)
- **Protocol** (`src/protocol.zig`): Protocol handler for external automation
- **Win32** (`src/win32.zig`): Windows API wrappers
- **Input** (`src/input.zig`): Interaction handling
- **Hotkeys** (`src/hotkeys.zig`): Global hotkeys and character cycling
- **Virtual Keys** (`src/virtual_keys.zig`): Key/modifier name parsing and encoding
- **Activity Tracker** (`src/activity_tracker.zig`): Combat DPS and mining rate tracking from gamelogs
- **TTS** (`src/tts.zig`): Text-to-speech alerts via Windows SAPI, driven on a dedicated worker thread
- **Chatlog** (`src/chatlog.zig`): EVE log monitoring
- **Tray** (`src/tray.zig`): System tray icon and menu
- **Update** (`src/update.zig`): GitHub release update checks
- **Log** (`src/log.zig`): Structured logging


## License

See [LICENSE](LICENSE) file for details.
