# Building from Source

Requires [Zig 0.16.0](https://ziglang.org/download/). The project targets `x86_64-windows-gnu` and is Windows-only; Zig bundles its own mingw headers/libs, so no separate Windows SDK or MSVC install is needed.

## Build

```powershell
zig build
```

This produces two executables in `zig-out\bin\`:
- `eve-maj-preview.exe` - the main application
- `config.exe` - the standalone configuration dialog

`icon.ico` is copied into `zig-out\bin\` alongside them; both executables embed `app.rc` for their taskbar/tray icon.

## Run

```powershell
zig build run
```

Builds and launches `eve-maj-preview.exe`, passing through any extra args after `--`:

```powershell
zig build run -- --profile pvp.json
```

To build and launch the configuration dialog instead:

```powershell
zig build config
```

## Version

The build reads the app version from the `VERSION` file at the repo root and embeds it via `build_options`. Bump `VERSION` (not `build.zig.zon`) to change the version reported by the built executables.

## Dependencies

[zig-webui](https://github.com/webui-dev/zig-webui) is fetched automatically by the Zig package manager per `build.zig.zon` and statically linked into `config.exe` for its UI.
