# Testing

- **Unit tests** cover pure logic: log parsing, hotkeys, layout math, formatting. They need only Zig and run in CI.
- **End-to-end (UI) tests**, in `tools/ui_tests`, run the real app against simulated EVE clients and check what it shows and does. They drive the real mouse and keyboard, so run them in a VM.

## Unit tests

```powershell
zig build test
```

Tests sit at the bottom of the file they test, and each such file is listed in `src/tests.zig`. Only code with no Win32, file or global access can be tested this way, which is why that logic lives in files of its own ([STYLE.md](STYLE.md) §9, §10).

## UI tests

### Requirements

- Windows 10 or 11, and Python 3.10+ with only the standard library.
- `zig build` output: `eve-maj-preview.exe` and the simulator `eve-maj-sim.exe` in `zig-out\bin`.
- No other EVE-Maj Preview running; the app is single-instance.
- 1920x1080 at 100% scaling. Some tests place windows at fixed positions or count pixels.
- Vulkan 1.3, for the config dialog tests.

Each test module runs a copy of the app in a temporary folder with its own profiles, logs and settings, with protocol registration and update checks off. The simulator opens windows titled like EVE clients and writes the game and chat logs the app reads. The app reports what it shows through a state file, written only while `EVE_MAJ_STATE_FILE` is set (`src/diagnostics/state_file.zig`).

### Running locally

```powershell
python tools/ui_tests/run.py                  # every test
python tools/ui_tests/run.py hotkey overlay   # tests whose module or name contains either word
python tools/ui_tests/run.py --failed         # only what the last run failed
```

A full run takes about 20 minutes, with windows taking focus and synthetic input throughout. Don't use the machine meanwhile.

### Running in a VM

Any hypervisor works. The guest needs the requirements above, plus:

- **The console session.** Run the tests on the guest's own desktop, not over RDP or another remote-desktop protocol: those resize the screen to the client window and lock the session when disconnected. Watch through the hypervisor's console view, scaled on the host side if it's too big.
- **Auto-logon**, so the test account's desktop is there after a reboot without anyone signing in.
- **`ForegroundLockTimeout` 0** for the test account, if you start the run from a background process (a scheduled task, a remote shell). Otherwise Windows won't let it give windows focus:

  ```powershell
  Set-ItemProperty "HKCU:\Control Panel\Desktop" ForegroundLockTimeout 0
  ```

- **A software Vulkan driver** if the guest has no GPU, for the config dialog. Put Mesa's lavapipe (`vulkan_lvp.dll` and `lvp_icd.x86_64.json`, from [mesa-dist-win](https://github.com/pal1000/mesa-dist-win/releases)) in a folder with a `vulkan-1.dll` loader, then before the run:

  ```powershell
  $env:PATH = "C:\vulkan;$env:PATH"
  $env:VK_DRIVER_FILES = "C:\vulkan\lvp_icd.x86_64.json"
  ```

Copy `tools\ui_tests` and the two exes into the guest in the same layout, `<root>\tools\ui_tests` and `<root>\zig-out\bin`, as the harness finds the exes from its own path. Then run `python tools\ui_tests\run.py` there as above.

`tools\ui_tests\vm` automates this for Hyper-V; each script's `Get-Help` lists what it expects.

## Flaky tests

A few tests are timing-sensitive. Rerun failures with `--failed` before investigating: one that passes on the rerun is flaky, one that fails again is broken.

## Writing a UI test

Tests live in `tools/ui_tests/tests/test_*.py`, one module per area. A test is a function named as a claim that takes the `session`:

```python
@covers("ListViewConfig.fontSize")
def test_a_bigger_font_makes_taller_rows(session):
    heights = []
    for size in (12, 20):
        session.use({"display": {"viewMode": "ClientList"}, "listView": {"fontSize": size}})
        session.start_client(ALPHA)
        heights.append(session.wait_for_panel_window("EVE_LIST_CLASS").height)
    check(heights[1] > heights[0], f"the list is {heights[1]} high at font size 20, {heights[0]} at 12")
```

- `session.use(profile)` closes the last test's clients and switches to a new profile of those settings over the defaults.
- `session.start_client` opens a simulated client; `session.start_logged_client` also writes the game and chat logs that alerts, rates and systems come from.
- `wait_for`, `stays` and `session.wait_for_*` poll the state file and Win32. Prefer them to fixed sleeps.
- `check(condition, message)`: the message should say what was seen, not only what was expected.
- A module's `GLOBAL_SETTINGS` apply to its whole app; `@fresh(...)` gives one test an app of its own, for startup behaviour or global settings.

The rest of the helpers are in `tools/ui_tests/harness.py`.

### Coverage

`@covers` names the settings a test proves, as `Struct.field` from `src/config/`, or `NotificationType.X` for an alert type.

```powershell
python tools/ui_tests/coverage.py          # structs with untested settings
python tools/ui_tests/coverage.py --all    # every struct
```

A new setting is untested until a test covers it. One no test can observe (it writes the registry, needs the network, or only affects the config dialog) goes in `NOT_TESTED` in `coverage.py` with the reason.
