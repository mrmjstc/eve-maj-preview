# Upgrading Zig

The project pins one Zig release everywhere. Upgrade only to a stable release, in one commit (knots included if it needs changes), and only once the weekly `Zig master` CI job has shown what breaks. Last done for 0.17.1 in `7c2dd53` (the version bump) and `f944c4b` (moving off deprecated std APIs).

## 1. Bump the version

Every place that names the version, as of 0.17.1:

| File | What to change |
|---|---|
| `build.zig.zon` | `minimum_zig_version` |
| `deps/knots/build.zig.zon`, `deps/knots/lib/*/build.zig.zon` | `minimum_zig_version`, a local knots patch listed in `deps/knots/PATCHES.md` |
| `.github/workflows/ci.yml`, `.github/workflows/release.yml` | `mlugg/setup-zig`'s `version` |
| `docs/BUILDING.md` | The "Requires Zig" line |
| `.vscode/settings.json` (untracked) | The Zig path, if your editor points at a versioned folder |

`grep -rn "0\.17\.1"` outside `zig-pkg/`, `.zig-cache/` and `docs/CHANGELOG.md` finds them all.

## 2. Make it build

1. `zig build` and `zig build check` (the app and the simulator), then fix compile errors in `src/` first, then in `deps/knots/`. A knots change is a patch: mark it `EVE-Maj patch` and list it in `PATCHES.md`, or update knots instead if upstream already supports the new release.
2. `zig build test`.
3. `zig fmt --check src build.zig build.zig.zon`: a new `zig fmt` can reformat code that was fine before. Commit any reformatting on its own.

## 3. Move off newly deprecated std APIs

1. Search the new release's std for `/// Deprecated` doc comments, and add each one `src/` might use to `DEPRECATED_STD` in `tools/checks/style_check.py`, with its replacement. Update the "Zig 0.17" wording in that table's comment and message.
2. `python tools/checks/style_check.py` lists every use; replace them as the doc comments say.
3. Drop table entries the new release removed outright: the compiler now catches those.

## 4. Check it runs

1. `python tools/checks/run_all.py`.
2. Run the app: thumbnails, hotkeys, the configuration window (knots and Vulkan), a profile switch and a Save.
3. The UI tests in the VM (`docs/TESTING.md`), since a std change in threading, I/O or formatting can break behaviour without breaking the build.

## 5. Record it

A changelog line under `### Changed` ("Built with Zig X.Y.Z"), and update this file if the list in step 1 changed.
