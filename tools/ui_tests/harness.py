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
import sys
import time
from contextlib import contextmanager
from ctypes import wintypes
from dataclasses import dataclass
from pathlib import Path

from eve_logs import CharacterLogs

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
BYSTANDER_EXES = ("bystander.exe", "onlooker.exe")
# src/panels/panel_header.zig's HEIGHT, in physical pixels: the strip a panel drags by, and all a folded one shows.
PANEL_HEADER_HEIGHT = 34

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
user32.GetCursorPos.argtypes = [ctypes.POINTER(wintypes.POINT)]
user32.mouse_event.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
user32.WindowFromPoint.argtypes = [wintypes.POINT]
user32.WindowFromPoint.restype = wintypes.HWND
user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetAncestor.restype = wintypes.HWND
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.GetWindowLongW.restype = wintypes.LONG
user32.LoadCursorW.argtypes = [wintypes.HINSTANCE, ctypes.c_void_p]
user32.LoadCursorW.restype = wintypes.HANDLE


class CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD), ("hCursor", wintypes.HANDLE), ("ptScreenPos", wintypes.POINT)]


user32.GetCursorInfo.argtypes = [ctypes.POINTER(CURSORINFO)]
MOUSE_BUTTONS = {"left": (0x0002, 0x0004), "right": (0x0008, 0x0010)}
VK_CONTROL = 0x11
GWL_EXSTYLE = -20
WS_EX_TRANSPARENT = 0x00000020
SYSTEM_CURSORS = {"Default": 32512, "Hand": 32649, "Crosshair": 32515, "Move": 32646, "Help": 32651}
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
    # What its last render drew (src/diagnostics/state_file.zig's Overlay); None before the first.
    overlay: dict | None = None

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


MOUSEEVENTF_MOVE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL = 0x0001, 0x8000, 0x4000, 0x0800
WHEEL_DELTA = 120
SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 76, 77, 78, 79
# A borderless window of one colour, from a second Python so this one needn't pump messages; per-monitor DPI aware so its pixels are the screen's.
BACKDROP_SCRIPT = """
import ctypes, sys, tkinter
ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
left, top, width, height, color = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
root = tkinter.Tk()
root.overrideredirect(True)
root.configure(bg=color)
root.geometry(f"{width}x{height}+{left}+{top}")
root.mainloop()
"""


def move_mouse(x: int, y: int):
    """As real input, which Windows' own move loop follows; SetCursorPos alone can leave it a step behind."""
    left, top = user32.GetSystemMetrics(SM_XVIRTUALSCREEN), user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    width, height = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN), user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
    normal_x = round((x - left) * 65535 / max(1, width - 1))
    normal_y = round((y - top) * 65535 / max(1, height - 1))
    user32.mouse_event(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, normal_x, normal_y, 0, None)



def wheel(x: int, y: int, notches: int):
    """Turns the wheel over a point: positive away from the user, which zooms in."""
    move_mouse(x, y)
    time.sleep(0.1)
    user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, (notches * WHEEL_DELTA) & 0xFFFFFFFF, None)


@contextmanager
def backdrop(rect: tuple[int, int, int, int], color: str):
    """A plain window of `color` (e.g. "#ff0000") over `rect` (left, top, right, bottom), under any topmost window."""
    left, top, right, bottom = rect
    process = subprocess.Popen([sys.executable, "-c", BACKDROP_SCRIPT, str(left), str(top), str(right - left), str(bottom - top), color])
    try:
        time.sleep(1.0)
        yield
    finally:
        process.kill()
        process.wait(timeout=5)


def client_to_screen(hwnd: int, x: int, y: int) -> tuple[int, int]:
    point = wintypes.POINT(x, y)
    user32.ClientToScreen(hwnd, ctypes.byref(point))
    return point.x, point.y


def client_size(hwnd: int) -> tuple[int, int]:
    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    return rect.right - rect.left, rect.bottom - rect.top


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


def cursor_position() -> tuple[int, int]:
    point = wintypes.POINT()
    user32.GetCursorPos(ctypes.byref(point))
    return point.x, point.y


def current_cursor() -> int:
    info = CURSORINFO(cbSize=ctypes.sizeof(CURSORINFO))
    user32.GetCursorInfo(ctypes.byref(info))
    return info.hCursor or 0


def system_cursor(name: str) -> int:
    """The shared handle of a system cursor, the same in every process."""
    return user32.LoadCursorW(None, ctypes.c_void_p(SYSTEM_CURSORS[name])) or 0


def extended_style(hwnd: int) -> int:
    return user32.GetWindowLongW(hwnd, GWL_EXSTYLE) & 0xFFFFFFFF


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
        "formatVersion": 8,
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
        self.exe = exe
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
        self.logs_dir = self.dir / "EVE" / "logs"
        self.app: subprocess.Popen | None = None
        self.clients: dict[str, Client] = {}
        self.profile_count = 0

    def __enter__(self) -> "Session":
        self.cursor_at_start = cursor_position()
        self._prepare()
        self.start()
        return self

    def __exit__(self, *_exc):
        self.close_clients()
        self.stop()
        user32.SetCursorPos(*self.cursor_at_start)
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
                 details=lambda: f"{(self.state() or {}).get('profile')}; log: {self.log_lines('profile', 'protocol')[-6:]}")
        # The alert history outlasts a profile switch, so the last test's entries would count in this one.
        # Only when there's something to clear: the link can land late, and seen empty first, it would clear this test's alerts.
        if self.history():
            self.protocol("evemajpreview://hotkey/clear_notification_history")
            wait_for("the alert history to clear", lambda: not self.history(), details=self.history)

    def log_lines(self, *words: str) -> list[str]:
        """The app's log lines mentioning any of `words`, case-insensitively."""
        return [line for line in self.log_text().splitlines() if any(w.lower() in line.lower() for w in words)]

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
        for exe in BYSTANDER_EXES:
            shutil.copy2(SIM_EXE, clients_dir / exe)
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
        chatlog = settings.get("chatlog")
        if chatlog and chatlog.get("enabled"):
            settings["chatlog"] = {"chatlogDir": str(self.logs_dir / "Chatlogs"), "gamelogDir": str(self.logs_dir / "Gamelogs"),
                                   "pollIntervalMs": 100, **chatlog}
        write_json(profiles / "global.settings.json", settings)
        write_json(profiles / "default.json", self.profile)

    def start_client(self, name: str) -> Client:
        client = Client(self.dir / "clients" / "exefile.exe", name)
        self.clients[name] = client
        client.wait_ready()
        return client

    def start_clients(self, *names: str) -> list[Client]:
        return [self.start_client(name) for name in names]

    def start_logged_client(self, name: str, system: str = "Jita", channels: tuple[str, ...] = ()) -> CharacterLogs:
        """Writes the character's session logs, then starts its client and waits for the app to follow them.

        Needs log reading on: `GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}` in the module.
        """
        logs = CharacterLogs(self.logs_dir, name, system, channels)
        self.start_client(name)
        wait_for(f"the app to read {name}'s system from its logs", lambda: self.system_of(name) == system,
                 details=lambda: self.system_of(name))
        return logs

    def client_state(self, name: str) -> dict:
        return next((c for c in (self.state() or {}).get("clients", []) if c["character_name"] == name), {})

    def system_of(self, name: str) -> str:
        return self.client_state(name).get("system_name", "")

    def alerts(self, name: str) -> list[str]:
        """The types of the alerts up on the client, newest first."""
        return [a["notification_type"] for a in self.client_state(name).get("alerts", [])]

    def alert(self, name: str, notification_type: str) -> dict | None:
        return next((a for a in self.client_state(name).get("alerts", []) if a["notification_type"] == notification_type), None)

    def wait_for_alert(self, name: str, notification_type: str, timeout_s: float = 5.0) -> dict:
        return wait_for(f"a {notification_type} alert on {name}", lambda: self.alert(name, notification_type),
                        timeout_s, details=lambda: self.alerts(name))

    def overlay(self, name: str) -> dict:
        """The thumbnail's last render, waiting for its first."""
        def drawn():
            thumbnail = next((t for t in self.thumbnail_list() if t.character_name == name), None)
            return thumbnail.overlay if thumbnail else None
        return wait_for(f"{name}'s thumbnail to render", drawn)

    def drawn_texts(self, name: str, element: str) -> list[dict]:
        """The texts of one element (thumbnail/overlay.zig's Element) the thumbnail last drew, top to bottom."""
        return [t for t in self.overlay(name)["texts"] if t["element"] == element]

    def wait_for_text(self, name: str, element: str, timeout_s: float = 6.0) -> dict:
        texts = wait_for(f"{name}'s {element} text", lambda: self.drawn_texts(name, element), timeout_s,
                         details=lambda: [t["element"] for t in self.overlay(name)["texts"]])
        return texts[0]

    def history(self) -> list[dict]:
        return (self.state() or {}).get("history", [])

    def panel_window(self, class_name: str) -> Window | None:
        """The app's visible window of a panel's class, if it shows."""
        windows = self.app_windows(class_name)
        return windows[0] if windows else None

    def wait_for_panel_window(self, class_name: str, timeout_s: float = 5.0) -> Window:
        return wait_for(f"a {class_name} window", lambda: self.panel_window(class_name), timeout_s)

    def panel(self, kind: str) -> dict | None:
        """A panel's entry in the state file (src/diagnostics/state_file.zig's Panel), while it has a window."""
        return next((p for p in (self.state() or {}).get("panels", []) if p["kind"] == kind), None)

    def panel_texts(self, kind: str) -> list[dict]:
        """What the panel's last render drew as text, in drawing order."""
        return (self.panel(kind) or {}).get("texts", [])

    def panel_strings(self, kind: str) -> list[str]:
        return [t["text"] for t in self.panel_texts(kind)]

    def wait_for_panel_text(self, kind: str, matches, timeout_s: float = 6.0) -> dict:
        """The first text the panel drew that equals `matches`, or that `matches` accepts when it's a function."""
        accepts = matches if callable(matches) else (lambda text: text == matches)
        found = lambda: next((t for t in self.panel_texts(kind) if accepts(t["text"])), None)
        return wait_for(f"the {kind} panel to draw {matches if isinstance(matches, str) else 'the text'}", found, timeout_s,
                        details=lambda: self.panel_strings(kind))

    def history_count(self, notification_type: str) -> int:
        return sum(entry["notification_type"] == notification_type for entry in self.history())

    def start_bystander(self, exe: str = BYSTANDER_EXES[0], name: str = BYSTANDER_NAME) -> Client:
        """A window that looks like a client but isn't one to the app; it takes focus when it opens.

        `exe` is one of BYSTANDER_EXES, so two bystanders can be told apart by executable.
        """
        bystander = Client(self.dir / "clients" / exe, name)
        self.clients[name] = bystander
        bystander.wait_ready()
        return bystander

    def running_names(self) -> set[str]:
        return {name for name, c in self.clients.items() if c.process.poll() is None and c.exe.name not in BYSTANDER_EXES}

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
                                       entry["is_hidden_by_character"], entry["group_badge"], window, entry.get("overlay")))
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
        self.move_cursor((window.left + window.right) // 2, (window.top + window.bottom) // 2)

    def move_cursor(self, x: int, y: int):
        user32.SetCursorPos(x, y)
        # The app reads the cursor from mouse messages, so give it a moment to see the move.
        time.sleep(0.15)

    def park_cursor(self):
        """Clear of every thumbnail and client, so a resting cursor can't hover or zoom one."""
        bounds = monitors()[0].work_area
        self.move_cursor(bounds[2] - 5, bounds[1] + 5)

    def _owns_point(self, x: int, y: int) -> bool:
        hwnd = user32.WindowFromPoint(wintypes.POINT(x, y))
        root = user32.GetAncestor(hwnd, 2) if hwnd else 0
        window = describe(root) if root else None
        pids = {c.process.pid for c in self.clients.values()} | ({self.app.pid} if self.app else set())
        return window is not None and window.pid in pids

    def _button(self, button: str, is_down: bool):
        down, up = MOUSE_BUTTONS[button]
        user32.mouse_event(down if is_down else up, 0, 0, 0, None)
        time.sleep(0.1)

    def mouse_down(self, x: int, y: int, button: str = "left"):
        """Refuses unless the window under the point is the app's or a test client's."""
        self.move_cursor(x, y)
        if not self._owns_point(x, y):
            raise TestFailure(f"Refused to press the mouse at ({x}, {y}), which isn't over a test window")
        self._button(button, True)

    def mouse_up(self, button: str = "left"):
        self._button(button, False)

    def click(self, x: int, y: int, button: str = "left", modifiers: tuple[int, ...] = ()):
        for modifier in modifiers:
            self.key_down(modifier)
        try:
            self.mouse_down(x, y, button)
            self.mouse_up(button)
        finally:
            for modifier in reversed(modifiers):
                self.key_up(modifier)

    def click_thumbnail(self, character_name: str, modifiers: tuple[int, ...] = ()):
        self.click(*self.thumbnails()[character_name].window.point(0.5, 0.5), modifiers=modifiers)

    def drag_thumbnail(self, character_name: str, to: tuple[int, int], modifiers: tuple[int, ...] = (), while_held=None):
        """Right-drags the thumbnail so its top-left would land on `to` before any snapping.

        `while_held`, when given, runs with the button still down, for what only shows mid-drag.
        """
        window = self.thumbnails()[character_name].window
        grab_x, grab_y = window.width // 2, window.height // 2
        start = (window.left + grab_x, window.top + grab_y)
        end = (to[0] + grab_x, to[1] + grab_y)
        for modifier in modifiers:
            self.key_down(modifier)
        try:
            self.mouse_down(*start, button="right")
            for step in range(1, 6):
                user32.SetCursorPos(start[0] + (end[0] - start[0]) * step // 5, start[1] + (end[1] - start[1]) * step // 5)
                time.sleep(0.05)
            time.sleep(0.2)
            if while_held:
                while_held()
            self.mouse_up("right")
        finally:
            for modifier in reversed(modifiers):
                self.key_up(modifier)
        self.park_cursor()

    def drag(self, start: tuple[int, int], end: tuple[int, int], button: str = "left"):
        """Presses at `start`, moves to `end` in steps, as Windows' move loop needs, and lets go."""
        self.mouse_down(*start, button=button)
        try:
            for step in range(1, 9):
                move_mouse(start[0] + (end[0] - start[0]) * step // 8, start[1] + (end[1] - start[1]) * step // 8)
                time.sleep(0.04)
            time.sleep(0.2)
        finally:
            self.mouse_up(button)
        self.park_cursor()

    def extra_thumbnail_windows(self) -> list[Window]:
        """The app's visible thumbnail-class windows that aren't a client's thumbnail, i.e. the hover zoom."""
        listed = {t.window.hwnd for t in self.thumbnail_list()}
        return [w for w in self.app_windows("EVE_THUMBNAIL_CLASS") if w.hwnd not in listed]

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
