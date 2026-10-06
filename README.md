
# EVE-Maj Preview

![EVE-Maj Preview screenshot](http://i.mjst.cc/N60T032mJ1.png)
![EVE-Maj Preview thumbnails](http://i.mjst.cc/BGIojpNJon.gif)

A *very* lightweight Windows tool for displaying DWM-based thumbnail previews of EVE Online client windows with customizable borders, text overlays, and advanced configuration options.

## What EVE-Maj Preview Isn't

It's **never** going to let you input broadcast, display cropped portions of your eve client, manipulate your eve client in any way or intentionally help you break the EVE Online EULA/TOS. 

> **Not publicly supported.** This is built for my corporation, friends, and anyone brave enough to run it - not a supported public release. Use it as-is, no guarantees, no support whatsoever.

## Features

- **Live Thumbnails**: Real-time DWM thumbnails of EVE client windows
- **Configuration Editor**: A settings window for editing profiles without touching files directly
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

Download the latest release, either:

- **Installer** (`eve-maj-preview-vX.Y.Z-setup.exe`): installs per-user under `%LocalAppData%\Programs` (no admin) with Start Menu shortcuts for the app and its configuration window
- **Portable** (`eve-maj-preview-vX.Y.Z-portable.zip`): extract anywhere and run `eve-maj-preview.exe`

Everything, including the configuration window, runs from the single `eve-maj-preview.exe`. Double-click the tray icon (or run `eve-maj-preview.exe --config`) to open the configuration window.

To build from source, see [docs/BUILDING.md](docs/BUILDING.md).

## Usage

### Basic Usage

Just run eve-maj-preview.exe and start some EVE clients.

The application will:
1. Create a `profiles` directory if it doesn't exist
2. Generate a default profile (`profiles\default.json`)
3. Create thumbnail windows for each client found

Logs and crash dumps go in `logs\`, and app data in `data\`, next to the exe.

### Command-Line Flags

```powershell
.\eve-maj-preview.exe --profile pvp.json
.\eve-maj-preview.exe -p pvp.json
.\eve-maj-preview.exe --config
```

- `--profile <name>` / `-p <name>`: Load a specific profile by filename (relative to the `profiles` directory - do not include the `profiles\` prefix)
- `--config`: Open the configuration window on the running profile, starting the app first if it isn't already running
- `--protocol <url>`: Internal flag used when Windows invokes the registered `evemajpreview://` protocol handler; not intended for manual use

### Configuration Editor

Right-click the system tray icon and choose **Open Configuration** (or double-click the icon) to open the settings window for the current profile. Changes preview live on your thumbnails and are only kept once you Save.

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

Bundled third-party components: [Cascadia Code](https://github.com/microsoft/cascadia-code) fonts under the SIL Open Font License 1.1 ([CascadiaCode-LICENSE.txt](licenses/CascadiaCode-LICENSE.txt)), and [knots](https://github.com/knots-ui/knots) under the MIT License ([knots-LICENSE.txt](licenses/knots-LICENSE.txt)).

## Fenris Creations Copyright Notice

EVE Online, the EVE logo, EVE and all associated logos and designs are the intellectual property of Fenris Creations. All artwork, screenshots, characters, vehicles, storylines, world facts or other recognizable features of the intellectual property relating to these trademarks are likewise the intellectual property of Fenris Creations. EVE Online and the EVE logo are the registered trademarks of Fenris Creations. All rights are reserved worldwide. All other trademarks are the property of their respective owners. Fenris Creations has granted permission to EVE-Maj Preview to use EVE Online and all associated logos and designs for promotional and information purposes on its website but does not endorse, and is not in any way affiliated with, EVE-Maj Preview. Fenris Creations is in no way responsible for the content on or functioning of this program, nor can it be liable for any damage arising from the use of this program.
