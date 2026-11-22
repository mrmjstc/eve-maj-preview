"""Runs the built app against simulated EVE clients in a throwaway folder and reads back what it shows.

Nothing here touches the real install: the app is copied into a sandbox, so its profiles, data
and logs live there, and the sandbox's global settings turn off protocol registration and
update checks. The app writes what it shows to a state file (src/diagnostics/state_file.zig)
because a thumbnail window's title keeps the name it was created with.
"""

import ctypes
import json
import os
import shutil
import subprocess
import tempfile
import time
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BIN = REPO / "zig-out" / "bin"
APP_EXE = BIN / "eve-maj-preview.exe"
SIM_EXE = BIN / "eve-maj-sim.exe"

# Class names the app and simulator register (src/protocol/ipc.zig, src/sim/client_window.zig).
APP_MAIN_CLASS = "EVE_TIMER_CLASS"
CLIENT_CLASS = "trinityWindow"
STATE_FILE_VARIABLE = "EVE_MAJ_STATE_FILE"
GENERIC_CHARACTER_NAME = "EVE"

WM_CLOSE = 0x0010
WM_APP = 0x8000
WM_SIM_LOGIN = WM_APP + 1
WM_SIM_LOGOUT = WM_APP + 2
KEYEVENTF_KEYUP = 0x0002
SW_MINIMIZE = 6
VK_SHIFT = 0x10
VK_F13 = 0x7C
BYSTANDER_NAME = "Bystander"

user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindow.argtypes = [wintypes.HWND]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsIconic.argtypes = [wintypes.HWND]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetDpiForWindow.argtypes = [wintypes.HWND]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
user32.FindWindowW.restype = wintypes.HWND
user32.GetForegroundWindow.restype = wintypes.HWND
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ctypes.c_void_p]
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.GetLayeredWindowAttributes.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.BYTE), ctypes.POINTER(wintypes.DWORD)]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
MONITORENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)
user32.EnumDisplayMonitors.argtypes = [wintypes.HDC, ctypes.c_void_p, MONITORENUMPROC, wintypes.LPARAM]
gdi32 = ctypes.WinDLL("gdi32")
gdi32.GetPixel.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.GetPixel.restype = wintypes.DWORD
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]
SRCCOPY = 0x00CC0020
CAPTUREBLT = 0x40000000
shcore = ctypes.WinDLL("shcore")


class MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT), ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]


user32.GetMonitorInfoW.argtypes = [wintypes.HMONITOR, ctypes.POINTER(MONITORINFO)]
user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]

# Physical pixels, matching the app, which is per-monitor aware too.
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))


class TestFailure(AssertionError):
    pass


@dataclass(frozen=True)
class Window:
    hwnd: int
    class_name: str
    title: str
    pid: int
    is_visible: bool
    is_minimized: bool
    left: int
    top: int
    right: int
    bottom: int
    dpi: int

    @property
    def width(self) -> int:
        return self.right - self.left

    @property
    def height(self) -> int:
        return self.bottom - self.top

    @property
    def scale(self) -> float:
        return self.dpi / 96

    def point(self, x_fraction: float, y_fraction: float) -> tuple[int, int]:
        return self.left + round(self.width * x_fraction), self.top + round(self.height * y_fraction)

    def overlaps(self, other: "Window") -> bool:
        return self.left < other.right and other.left < self.right and self.top < other.bottom and other.top < self.bottom


@dataclass(frozen=True)
class Thumbnail:
    """One thumbnail as the app reports it, with its window as Windows reports it."""
    character_name: str
    source_hwnd: int
    visibility: str
    is_hidden_by_character: bool
    group_badge: str
    window: Window

    @property
    def is_shown(self) -> bool:
        return self.window.is_visible


def describe(hwnd: int) -> Window | None:
    if not user32.IsWindow(hwnd):
        return None
    class_buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, class_buf, 256)
    title_buf = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, title_buf, 256)
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return Window(
        hwnd=hwnd, class_name=class_buf.value, title=title_buf.value, pid=pid.value,
        is_visible=bool(user32.IsWindowVisible(hwnd)), is_minimized=bool(user32.IsIconic(hwnd)),
        left=rect.left, top=rect.top, right=rect.right, bottom=rect.bottom,
        dpi=user32.GetDpiForWindow(hwnd) or 96,
    )


def top_level_windows() -> list[Window]:
    handles: list[int] = []
    user32.EnumWindows(WNDENUMPROC(lambda hwnd, _lparam: handles.append(hwnd) or True), 0)
    return [w for w in map(describe, handles) if w]


@dataclass(frozen=True)
class Monitor:
    bounds: tuple[int, int, int, int]
    work_area: tuple[int, int, int, int]
    dpi: int

    @property
    def scale(self) -> float:
        return self.dpi / 96


def monitors() -> list[Monitor]:
    """In EnumDisplayMonitors order, which is what DisplayConfig.monitorIndex counts."""
    found: list[Monitor] = []

    def visit(hmonitor, _hdc, _rect, _lparam):
        info = MONITORINFO(cbSize=ctypes.sizeof(MONITORINFO))
        user32.GetMonitorInfoW(hmonitor, ctypes.byref(info))
        dpi_x, dpi_y = wintypes.UINT(), wintypes.UINT()
        shcore.GetDpiForMonitor(hmonitor, 0, ctypes.byref(dpi_x), ctypes.byref(dpi_y))
        as_tuple = lambda r: (r.left, r.top, r.right, r.bottom)
        found.append(Monitor(as_tuple(info.rcMonitor), as_tuple(info.rcWork), dpi_x.value or 96))
        return True

    user32.EnumDisplayMonitors(None, None, MONITORENUMPROC(visit), 0)
    return found


def layered_alpha(hwnd: int) -> int | None:
    """The alpha SetLayeredWindowAttributes gave the window, or None when it has none."""
    alpha, flags = wintypes.BYTE(), wintypes.DWORD()
    if not user32.GetLayeredWindowAttributes(hwnd, None, ctypes.byref(alpha), ctypes.byref(flags)):
        return None
    return alpha.value & 0xFF if flags.value & 0x2 else None


def pixel(x: int, y: int) -> tuple[int, int, int]:
    """The composited screen colour at a point, as (r, g, b), layered windows included."""
    screen = user32.GetDC(None)
    memory = gdi32.CreateCompatibleDC(screen)
    bitmap = gdi32.CreateCompatibleBitmap(screen, 1, 1)
    old = gdi32.SelectObject(memory, bitmap)
    try:
        # Without CAPTUREBLT the copy leaves out layered windows, which the overlays are.
        gdi32.BitBlt(memory, 0, 0, 1, 1, screen, x, y, SRCCOPY | CAPTUREBLT)
        color = gdi32.GetPixel(memory, 0, 0)
    finally:
        gdi32.SelectObject(memory, old)
        gdi32.DeleteObject(bitmap)
        gdi32.DeleteDC(memory)
        user32.ReleaseDC(None, screen)
    return color & 0xFF, (color >> 8) & 0xFF, (color >> 16) & 0xFF


def close_to(color: tuple[int, int, int], expected: tuple[int, int, int], tolerance: int = 24) -> bool:
    return all(abs(c - e) <= tolerance for c, e in zip(color, expected))


def foreground_hwnd() -> int:
    return user32.GetForegroundWindow() or 0


def wait_for(description: str, check, timeout_s: float = 5.0, interval_s: float = 0.1, details=None):
    """Polls `check` until it returns something truthy, which is returned; fails after timeout_s.

    `details`, when given, is called on a timeout to say what was seen instead.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(interval_s)
    seen = f"; saw {details()}" if details else ""
    raise TestFailure(f"Timed out after {timeout_s}s waiting for {description}{seen}")


def stays(description: str, check, for_s: float = 2.0, interval_s: float = 0.1, details=None):
    """Fails as soon as `check` turns falsy within for_s; for things that must not happen."""
    deadline = time.monotonic() + for_s
    while time.monotonic() < deadline:
        if not check():
            seen = f"; saw {details()}" if details else ""
            raise TestFailure(f"Expected {description} for {for_s}s, but it stopped{seen}")
        time.sleep(interval_s)


def default_profile() -> dict:
    """A partial profile: anything left out loads with its default."""
    return {
        "app": "eve-maj-preview",
        "formatVersion": 7,
        "thumbnail": {"width": 240, "height": 135, "showLivePreview": True, "activeThumbnailHidden": False},
        "display": {"startX": 100, "startY": 100, "newThumbnailSpacing": 10, "placementMode": "Manual"},
    }


def merged(base: dict, patch: dict) -> dict:
    """`base` with `patch` laid over it, nested dicts merged rather than replaced."""
    result = dict(base)
    for key, value in patch.items():
        result[key] = merged(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else value
    return result


class Client:
    """One simulated EVE client process; its window title is "EVE - <name>", or "EVE" while logged out."""

    def __init__(self, exe: Path, name: str):
        self.name = name
        self.process = subprocess.Popen([str(exe), "--client", name], cwd=exe.parent)
        self.hwnd = 0

    def window(self) -> Window | None:
        return describe(self.hwnd) if self.hwnd else None

    def wait_ready(self):
        def find():
            for window in top_level_windows():
                if window.pid == self.process.pid and window.class_name == CLIENT_CLASS and window.is_visible:
                    return window
            return None

        self.hwnd = wait_for(f"client window '{self.name}'", find).hwnd

    def log_out(self):
        user32.PostMessageW(self.hwnd, WM_SIM_LOGOUT, 0, 0)

    def log_in(self):
        user32.PostMessageW(self.hwnd, WM_SIM_LOGIN, 0, 0)

    def minimize(self):
        user32.ShowWindow(self.hwnd, SW_MINIMIZE)

    def move(self, x: int, y: int):
        # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        user32.SetWindowPos(self.hwnd, None, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010)

    def close(self):
        if self.process.poll() is not None:
            return
        user32.PostMessageW(self.hwnd, WM_CLOSE, 0, 0)
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()


class Session:
    """A sandboxed copy of the app, kept running across a module's tests, plus the current test's clients.

    `profile` is laid over default_profile(); `global_settings` over the sandbox's safe defaults.
    Each test calls use() to get a clean slate on a profile of its own.
    """

    def __init__(self, profile: dict | None = None, global_settings: dict | None = None):
        self.profile = merged(default_profile(), profile or {})
        self.global_settings = global_settings or {}
        self.dir = Path(tempfile.mkdtemp(prefix="eve-maj-ui-"))
        self.exe = self.dir / APP_EXE.name
        self.state_path = self.dir / "state.json"
        self.app: subprocess.Popen | None = None
        self.clients: dict[str, Client] = {}
        self.profile_count = 0

    def __enter__(self) -> "Session":
        self._prepare()
        self.start()
        return self

    def __exit__(self, *_exc):
        self.close_clients()
        self.stop()
        shutil.rmtree(self.dir, ignore_errors=True)

    def start(self):
        self.state_path.unlink(missing_ok=True)
        environment = {**os.environ, STATE_FILE_VARIABLE: str(self.state_path)}
        self.app = subprocess.Popen([str(self.exe)], cwd=self.dir, env=environment)
        wait_for("the app's state file", self.state)

    def stop(self):
        if self.app and self.app.poll() is None:
            self.app.kill()
            self.app.wait(timeout=5)
        self.app = None

    def restart(self):
        self.close_clients()
        self.stop()
        self.start()

    def close_clients(self):
        for client in self.clients.values():
            client.close()
        self.clients.clear()

    def use(self, profile: dict | None = None):
        """Closes the last test's clients and switches to a new profile laid over default_profile()."""
        self.close_clients()
        if self.app is None or self.app.poll() is not None or self._has_leaked_state():
            self.stop()
            self.start()
        wait_for("the last test's thumbnails to go", lambda: not self.thumbnail_list(),
                 details=lambda: [t.character_name for t in self.thumbnail_list()])
        self.profile_count += 1
        name = f"t{self.profile_count:03d}.json"
        write_json(self.dir / "profiles" / name, merged(default_profile(), profile or {}))
        self.protocol(f"evemajpreview://profile/{name}")
        wait_for(f"profile '{name}' to load", lambda: (self.state() or {}).get("profile") == name,
                 details=lambda: (self.state() or {}).get("profile"))

    def write_profile(self, file_name: str, profile: dict | None = None):
        """An extra profile beside the test's own, laid over default_profile()."""
        write_json(self.dir / "profiles" / file_name, merged(default_profile(), profile or {}))

    def read_profile(self) -> dict:
        """The current profile as the app last saved it."""
        name = (self.state() or {}).get("profile", "")
        return json.loads((self.dir / "profiles" / name).read_text(encoding="utf-8"))

    def profile_name(self) -> str:
        return (self.state() or {}).get("profile", "")

    def _has_leaked_state(self) -> bool:
        """What a profile switch keeps, which would carry one test's changes into the next."""
        state = self.state() or {}
        return bool(state.get("excluded_characters")) or bool(state.get("are_hotkeys_suspended"))

    def _prepare(self):
        shutil.copy2(APP_EXE, self.dir)
        clients_dir = self.dir / "clients"
        clients_dir.mkdir()
        # scout.zig only counts windows owned by an exe named exefile.exe, so the bystander's copy isn't a client.
        shutil.copy2(SIM_EXE, clients_dir / "exefile.exe")
        shutil.copy2(SIM_EXE, clients_dir / "bystander.exe")
        profiles = self.dir / "profiles"
        profiles.mkdir()
        settings = {
            "lastUsedProfile": "default.json",
            "logLevel": "info",
            "autoRegisterProtocol": False,
            "disableUpdateChecks": True,
            "evestarsEnabled": False,
            "runOnStartup": False,
            **self.global_settings,
        }
        write_json(profiles / "global.settings.json", settings)
        write_json(profiles / "default.json", self.profile)

    def start_client(self, name: str) -> Client:
        client = Client(self.dir / "clients" / "exefile.exe", name)
        self.clients[name] = client
        client.wait_ready()
        return client

    def start_clients(self, *names: str) -> list[Client]:
        return [self.start_client(name) for name in names]

    def start_bystander(self) -> Client:
        """A window that looks like a client but isn't one to the app; it takes focus when it opens."""
        bystander = Client(self.dir / "clients" / "bystander.exe", BYSTANDER_NAME)
        self.clients[BYSTANDER_NAME] = bystander
        bystander.wait_ready()
        return bystander

    def running_names(self) -> set[str]:
        return {name for name, c in self.clients.items() if c.process.poll() is None and name != BYSTANDER_NAME}

    def state(self) -> dict | None:
        """The app's latest state file, or None while it's missing or mid-replace."""
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def thumbnail_list(self) -> list[Thumbnail]:
        state = self.state() or {"thumbnails": []}
        found = []
        for entry in state["thumbnails"]:
            window = describe(entry["hwnd"])
            if window:
                found.append(Thumbnail(entry["character_name"], entry["source_hwnd"], entry["visibility"],
                                       entry["is_hidden_by_character"], entry["group_badge"], window))
        return found

    def thumbnails(self) -> dict[str, Thumbnail]:
        """Shown thumbnails by character name."""
        return {t.character_name: t for t in self.thumbnail_list() if t.is_shown}

    def shown_names(self) -> list[str]:
        return sorted(self.thumbnails())

    def wait_for_thumbnails(self, names: set[str], timeout_s: float = 5.0) -> dict[str, Thumbnail]:
        # Wrapped in a list so that no thumbnails at all still counts as a match.
        matched = wait_for(f"shown thumbnails to be exactly {sorted(names)}",
                           lambda: (lambda shown: [shown] if set(shown) == names else None)(self.thumbnails()),
                           timeout_s, details=self.shown_names)
        return matched[0]

    def app_windows(self, class_name: str) -> list[Window]:
        """The app's visible top-level windows of one class, e.g. a panel's."""
        return [w for w in top_level_windows()
                if self.app and w.pid == self.app.pid and w.class_name == class_name and w.is_visible]

    def assert_thumbnails_stay(self, names: set[str], for_s: float = 2.0):
        stays(f"shown thumbnails to stay exactly {sorted(names)}", lambda: set(self.thumbnails()) == names,
              for_s, details=self.shown_names)

    def group_members(self, group_name: str) -> list[str]:
        groups = (self.state() or {}).get("groups", [])
        return next((g["members"] for g in groups if g["name"] == group_name), [])

    def excluded(self) -> list[str]:
        return (self.state() or {}).get("excluded_characters", [])

    def active_hwnd(self) -> int | None:
        return (self.state() or {}).get("active_hwnd")

    def protocol(self, url: str):
        """Runs `url` through a second launch, as a clicked link would."""
        subprocess.run([str(self.exe), "--protocol", url], cwd=self.dir, timeout=10, check=False)

    def switch_to(self, name: str):
        self.protocol(f"evemajpreview://switch/{name.replace(' ', '%20')}")
        self.wait_for_foreground(name)

    def foreground_client(self) -> str | None:
        hwnd = foreground_hwnd()
        return next((c.name for c in self.clients.values() if c.hwnd == hwnd), None)

    def wait_for_foreground(self, name: str) -> Client:
        client = self.clients[name]
        wait_for(f"'{name}' in the foreground", lambda: foreground_hwnd() == client.hwnd,
                 details=lambda: self.foreground_client() or describe(foreground_hwnd()))
        return client

    def press(self, virtual_key: int, modifiers: tuple[int, ...] = ()):
        """Presses a key system-wide, only while one of this session's windows has focus."""
        for modifier in modifiers:
            self.key_down(modifier)
        self.key_down(virtual_key)
        self.key_up(virtual_key)
        for modifier in reversed(modifiers):
            self.key_up(modifier)

    def key_down(self, virtual_key: int):
        """A second key_down before key_up is what auto-repeat sends."""
        if self.foreground_client() is None:
            raise TestFailure(f"Refused to press a key outside the test windows; focus is on {describe(foreground_hwnd())}")
        user32.keybd_event(virtual_key, 0, 0, None)

    def key_up(self, virtual_key: int):
        user32.keybd_event(virtual_key, 0, KEYEVENTF_KEYUP, None)

    def hover(self, character_name: str):
        window = self.thumbnails()[character_name].window
        user32.SetCursorPos((window.left + window.right) // 2, (window.top + window.bottom) // 2)
        # The app reads the hovered thumbnail from mouse messages, so give it a moment to see the move.
        time.sleep(0.2)

    def log_text(self) -> str:
        path = self.dir / "logs" / "eve-maj.log"
        return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


ALPHA, BRAVO, CHARLIE = "Alpha Pilot", "Bravo Pilot", "Charlie Pilot"


def check(condition: bool, message: str):
    if not condition:
        raise TestFailure(message)


def scaled(value: int, scale: float) -> int:
    return round(value * scale)


def covers(*keys: str):
    """Marks the settings a test proves, as `Struct.field` from src/config/ (or `NotificationType.X`), for coverage.py."""
    def mark(test):
        test.covers = keys
        return test
    return mark


def fresh(global_settings: dict | None = None):
    """Runs a test in an app of its own, for global settings or startup behaviour a profile switch can't give."""
    def mark(test):
        test.fresh_global_settings = global_settings or {}
        return test
    return mark


def write_json(path: Path, value: dict):
    path.write_text(json.dumps(value, indent=2), encoding="utf-8", newline="")


def ensure_ready():
    """Refuses to run beside a real instance, which would take the sandboxed copy's place."""
    for exe in (APP_EXE, SIM_EXE):
        if not exe.exists():
            raise SystemExit(f"Missing {exe}; run zig build first")
    if user32.FindWindowW(APP_MAIN_CLASS, None):
        raise SystemExit("EVE-Maj Preview is running; close it first (the app is single-instance)")
