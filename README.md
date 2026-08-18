
# EVE-Maj Preview

![EVE-Maj Preview screenshot](http://i.mjst.cc/wkMWgprMn5.png)
![EVE-Maj Preview thumbnails](http://i.mjst.cc/BGIojpNJon.gif)

A *very* lightweight Windows tool for displaying DWM-based thumbnail previews of EVE Online client windows with customizable borders, text overlays, and advanced configuration options.

## What EVE-Maj Preview Isn't

It's **never** going to let you input broadcast, display portions of your eve client, manipulate your eve client in any way or intentionally help you break the EVE Online EULA/TOS. 

> **Not publicly supported.** This is built for my corporation, friends, and anyone brave enough to run it - not a supported public release. Use it as-is, no guarantees, no support whatsoever.

## Features

- **Live Thumbnails**: Real-time DWM thumbnails of EVE client windows
- **Configuration Editor**: Standalone interface (`config.exe`) for editing settings without touching files directly
- **Compact List View**: Single-panel alternative to thumbnails, one row per client with state, name, and system/notification text
- **Multi-Application Support**: Configurable window filters to track any Windows app
- **Notification System**: Per-type event alerts with suppression, border color/flash, and text-to-speech options
- **Text-to-Speech Alerts**: Speaks notifications via Windows SAPI, with per-type opt-in and adjustable volume/rate
- **Profile System**: Multiple configs with hotkey-based cycling
- **Hotkey Groups**: Cycle or switch clients via keyboard shortcuts
- **Quick Groups**: Temporary hotkey groups
- **Notified-Character Cycling**: Hotkey to jump between recently notified characters
- **Per-Character Hotkeys**: Dedicated hotkey to jump straight to that character
- **Auto-Minimize**: Minimizes inactive clients if needed, with per-character exclusions
- **Per-Character Customization**: Override colors, sizes, names, hotkeys, and more
- **Log Monitoring**: Tracks system changes and combat/mining events from EVE logs
- **Combat DPS Overlay**: Real-time incoming/outgoing DPS per character
- **Mining Rate Overlay**: Real-time units/min with laser-idle and mining-stopped alerts
- **Protocol Handler**: `evemajpreview://` URLs for external control - character switching, profile loading, hotkeys, etc
- **Automatic Update Checks**: Checks GitHub for new releases on startup, only informs but will never automatically download 
- **No Telemetry**: I don't need to know you're using the app, that's insane

## Installation

1. Download the latest release
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

### Configuration Editor

Right-click the system tray icon and choose **Open Configuration** to launch `config.exe`, a standalone editor for the current profile's settings.

### Protocol Handler

EVE-Maj Preview registers a `evemajpreview://` URL protocol for external control - character switching, profile loading, and hotkey actions - useful for Stream Deck buttons, etc. The application must already be running for a protocol URL to have any effect.

```
evemajpreview://switch/Character%20Name
evemajpreview://profile/pvp.json
evemajpreview://hotkey/toggle_visibility
```

See [Protocol Handler](docs/CONFIGURATION.md#protocol-handler) in the configuration reference for the full URL format, all hotkey actions, and registration details.

## Configuration Reference

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full configuration reference, covering every profile JSON setting, thumbnail/display/notification options, hotkeys, and the color format.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a map of how the source modules fit together - entry points, the threading model, and the per-tick update flow.

## License

See [LICENSE](LICENSE) file for details.
