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

`config.exe` renders that UI via WebView2, which needs `WebView2Loader.dll` next to the exe at runtime (the target machine's WebView2 Runtime itself is preinstalled on Windows 10/11). `build.zig` installs `src/WebView2Loader.dll` into `zig-out\bin` alongside `config.exe`, the same way it installs `icon.ico`. It's redistributed under the terms in `WebView2Loader-LICENSE.txt` (BSD-style, from the `Microsoft.Web.WebView2` NuGet package), which ships alongside `config.exe` in release packages.

## Installer

`installer\eve-maj-preview.iss` is an [Inno Setup](https://jrsoftware.org/isinfo.php) script that packages `zig-out\bin` into a Windows installer with Start Menu shortcuts, an optional desktop icon, and toggles on the finish page to launch the app and/or the configuration dialog. It always installs per-user under `%LocalAppData%\Programs` (no admin, never Program Files) since the app reads/writes its profiles, settings, and log file next to the exe.

`build-release.ps1` builds it automatically if `ISCC.exe` (the Inno Setup compiler) is on `PATH` or in its default install location, and attaches the resulting setup exe to the GitHub release alongside the zip. To build it manually:

```powershell
iscc /DMyAppVersion=0.95.0 installer\eve-maj-preview.iss
```
