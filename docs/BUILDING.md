# Building from Source

Requires [Zig 0.16.0](https://ziglang.org/download/). The project targets `x86_64-windows-gnu` and is Windows-only; Zig bundles its own mingw headers/libs, so no separate Windows SDK or MSVC install is needed.

## Build

```powershell
zig build
```

This produces `eve-maj-preview.exe` in `zig-out\bin\`, which also hosts the configuration window. `WebView2Loader.dll` is copied in alongside it, and the exe embeds its icon (`src/assets/icon.ico`, via `app.rc`), which the tray and the configuration window's favicon use too.

## Run

```powershell
zig build run
```

Builds and launches `eve-maj-preview.exe`, passing through any extra args after `--`:

```powershell
zig build run -- --profile pvp.json
```

To build and launch it with the configuration window open (the same as `eve-maj-preview.exe --config`, which asks an already-running instance to open it instead):

```powershell
zig build config
```

To run the unit tests (listed in `src/tests.zig`), which cover log parsing, hotkeys, URL commands, activity rates and layout math and don't need EVE or the app running:

```powershell
zig build test
```

## Version

The build reads the app version from the `VERSION` file at the repo root and embeds it via `build_options`. Bump `VERSION` (not `build.zig.zon`) to change the version reported by the built executables.

## Dependencies

[zig-webui](https://github.com/webui-dev/zig-webui) and [webui](https://github.com/webui-dev/webui) are vendored in `deps/` (webui carries a local patch, marked `EVE-Maj patch`, so it appends to `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` instead of overwriting the `--no-proxy-server` that `dialog/host.zig` sets) and statically linked into `eve-maj-preview.exe` for the configuration window. webui, zig-webui and the CivetWeb server inside webui are MIT-licensed; their notices are in `webui-LICENSE.txt`, which ships in release packages and the installer.

The window renders via WebView2, which needs `WebView2Loader.dll` next to the exe at runtime (the target machine's WebView2 Runtime itself is preinstalled on Windows 10/11); it's only loaded when the window first opens. `build.zig` installs `src/WebView2Loader.dll` into `zig-out\bin` alongside the exe. It's redistributed under the terms in `WebView2Loader-LICENSE.txt` (BSD-style, from the `Microsoft.Web.WebView2` NuGet package), which ships alongside it in release packages.

Not every Windows install has [Cascadia Code](https://github.com/microsoft/cascadia-code) (v2407.24), so its fonts are bundled from `src/assets/fonts/`. `eve-maj-preview.exe` embeds the static Regular/SemiBold/Mono TTFs and registers them process-privately at startup (`platform/fonts.zig`); the configuration window serves the variable WOFF2 to its page for an `@font-face`. They're licensed under the SIL OFL 1.1 (`CascadiaCode-LICENSE.txt`), which ships in release packages and the installer; unmodified files keep the Reserved Font Name.

## Installer

`installer\eve-maj-preview.iss` is an [Inno Setup](https://jrsoftware.org/isinfo.php) script that packages `zig-out\bin` into a Windows installer with Start Menu shortcuts, an optional desktop icon, and toggles on the finish page to launch the app and/or open its configuration window. Upgrades delete the separate `config.exe` older versions shipped. It always installs per-user under `%LocalAppData%\Programs` (no admin, never Program Files) since the app reads/writes its profiles, settings, and log file next to the exe.

`build-release.ps1` builds it automatically if `ISCC.exe` (the Inno Setup compiler) is on `PATH` or in its default install location, and attaches the resulting setup exe to the GitHub release alongside the zip. To build it manually:

```powershell
iscc /DMyAppVersion=0.95.0 installer\eve-maj-preview.iss
```
