# Building from Source

Requires [Zig 0.17.1](https://ziglang.org/download/); [UPGRADING_ZIG.md](UPGRADING_ZIG.md) lists what to change for a new release. The project targets `x86_64-windows-gnu` and is Windows-only; Zig bundles its own mingw headers/libs, so no separate Windows SDK or MSVC install is needed.

## Build

```powershell
zig build
```

This produces `eve-maj-preview.exe` in `zig-out\bin\`, which also hosts the configuration window and is the only file it needs. The exe embeds its icon (`src/assets/icon.ico`, via `app.rc`), which the tray uses too. The configuration window's favicon is `src/assets/icon.svg`.

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

The end-to-end tests, which run the app against simulated EVE clients, have their own setup: see [TESTING.md](TESTING.md).

To run the source checks (style, dead code, import cycles, stale comments, translations and the configuration doc), with Python 3.9 or later:

```powershell
python tools/checks/run_all.py
```

`cp tools/checks/pre-push .git/hooks/pre-push` runs them before every push.

GitHub Actions (`.github/workflows/ci.yml`) runs `zig fmt --check`, the source checks, `zig build check` and `zig build test` on every push and pull request.

## Version

The build reads the app version from the `VERSION` file at the repo root and embeds it via `build_options`. Bump `VERSION` (not `build.zig.zon`) to change the version reported by the built executables.

## Dependencies

The configuration window is drawn with [knots](https://github.com/knots-ui/knots), vendored in `deps/knots` with local patches listed in `deps/knots/PATCHES.md`. It renders with Vulkan, so the window needs a graphics driver with Vulkan 1.3 support; without one it shows an error instead of opening. knots is MIT-licensed (`licenses/knots-LICENSE.txt`), which ships in release packages and the installer.

The fonts are bundled from `src/assets/fonts/`, since Windows doesn't ship them: [Geist](https://github.com/vercel/geist-font) Regular and SemiBold, which the configuration window, panels and thumbnail text use by default, and [Cascadia Code](https://github.com/microsoft/cascadia-code) (v2407.24) Regular, SemiBold and Mono. `eve-maj-preview.exe` embeds the TTFs and registers them process-privately at startup (`platform/fonts.zig`). Both are licensed under the SIL OFL 1.1 (`licenses/Geist-LICENSE.txt`, `licenses/CascadiaCode-LICENSE.txt`), which ship in release packages and the installer; unmodified files keep any Reserved Font Name.

The alert sounds in `sounds/` were made for this app by its author and are covered by its GPL-3.0 licence (`licenses/eve-maj-preview-LICENSE.txt`).

## Installer

`installer\eve-maj-preview.iss` is an [Inno Setup](https://jrsoftware.org/isinfo.php) script that packages `zig-out\bin` into a Windows installer with Start Menu shortcuts, an optional desktop icon, and toggles on the finish page to launch the app and/or open its configuration window. Upgrades delete the separate `config.exe` and the `WebView2Loader.dll` older versions shipped. It always installs per-user under `%LocalAppData%\Programs` (no admin, never Program Files) since the app reads/writes its profiles, settings, and log file next to the exe.

A release builds it automatically if `ISCC.exe` (the Inno Setup compiler) is on `PATH` or in its default install location, and attaches the resulting setup exe to the GitHub release alongside the zip. To build it manually:

```powershell
iscc /DMyAppVersion=0.95.0 installer\eve-maj-preview.iss
```

## Releasing

Releases are built in CI. `build-release.ps1` runs the unit tests, bumps the version, promotes the changelog's `[Unreleased]` section, commits, tags `vX.Y.Z` and pushes. `build-release-dev.ps1` tags the `dev` branch's head `vX.Y.Z-dev.N` and pushes. The tag starts the Release workflow (`.github/workflows/release.yml`), which runs the CI checks, then `tools/release/publish.ps1`: it builds, packages the zip and installer with a `SHA256SUMS.txt`, creates the GitHub release (a draft for `vX.Y.Z`, a prerelease for a dev tag) and announces it on Discord. Publish the draft on GitHub, then run `update-winget.ps1` to submit the winget manifest.

Both scripts take `-DryRun`, which builds and packages the next version locally and prints the release and announcement without changing or pushing anything. If the workflow fails, re-run it from the Actions tab, run it by hand there with the tag, or run `.\tools\release\publish.ps1 -Tag <tag>` locally; a tag that already has a release is skipped.

The Discord webhook URLs aren't in the repo. The workflow reads them from the repository secrets `DISCORD_WEBHOOK_RELEASE` and `DISCORD_WEBHOOK_DEV`; a release without one skips the announcement. For local runs, save each once per machine (stored encrypted to your Windows account under `%LOCALAPPDATA%`), and copy a saved one into its secret with `-UploadToGitHub`:

```powershell
.\tools\discord-webhook.ps1 -Channel release
.\tools\discord-webhook.ps1 -Channel dev
.\tools\discord-webhook.ps1 -Channel release -UploadToGitHub
.\tools\discord-webhook.ps1 -Channel dev -UploadToGitHub
```
