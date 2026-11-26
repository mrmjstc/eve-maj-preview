"""Client Speed: each client's CPU priority and efficiency mode, by whether it has focus."""

import ctypes
import time
from ctypes import wintypes

from harness import ALPHA, BRAVO, covers, fresh, stays, wait_for

ALL_ON = {"raiseFocusedClient": True, "lowerBackgroundClients": True, "backgroundEfficiencyMode": True}
GLOBAL_SETTINGS = {"clientSpeed": ALL_ON}

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PROCESS_POWER_THROTTLING = 4
EXECUTION_SPEED = 0x1
PRIORITY_NAMES = {0x20: "normal", 0x4000: "below_normal", 0x8000: "above_normal"}

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.GetPriorityClass.argtypes = [wintypes.HANDLE]
kernel32.GetPriorityClass.restype = wintypes.DWORD
kernel32.GetProcessInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
kernel32.GetProcessInformation.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


class PowerThrottlingState(ctypes.Structure):
    _fields_ = [("Version", wintypes.ULONG), ("ControlMask", wintypes.ULONG), ("StateMask", wintypes.ULONG)]


def speed(session, name: str) -> tuple[str, str]:
    """The client's priority, and its throttling: "default", "efficient", "never", or "unreadable" before Windows 11."""
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, session.clients[name].process.pid)
    if not handle:
        return ("unreadable", "unreadable")
    try:
        priority = PRIORITY_NAMES.get(kernel32.GetPriorityClass(handle), "other")
        state = PowerThrottlingState(Version=1)
        if not kernel32.GetProcessInformation(handle, PROCESS_POWER_THROTTLING, ctypes.byref(state), ctypes.sizeof(state)):
            return (priority, "unreadable")
        if not state.ControlMask & EXECUTION_SPEED:
            return (priority, "default")
        return (priority, "efficient" if state.StateMask & EXECUTION_SPEED else "never")
    finally:
        kernel32.CloseHandle(handle)


def is_at(session, name: str, priority: str, throttle: str) -> bool:
    """Windows 10 can't read throttling back, so there only the priority is checked."""
    actual_priority, actual_throttle = speed(session, name)
    return actual_priority == priority and actual_throttle in (throttle, "unreadable")


def focus_alpha(session, profile: dict | None = None):
    session.use(profile)
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.switch_to(ALPHA)


@covers("ClientSpeedConfig.raiseFocusedClient", "ClientSpeedConfig.lowerBackgroundClients", "ClientSpeedConfig.backgroundEfficiencyMode")
def test_client_speed_raises_the_focused_client_and_slows_the_others(session):
    focus_alpha(session)
    wait_for("Alpha to be raised", lambda: is_at(session, ALPHA, "above_normal", "default"),
             details=lambda: speed(session, ALPHA))
    wait_for("Bravo to be slowed", lambda: is_at(session, BRAVO, "below_normal", "efficient"),
             details=lambda: speed(session, BRAVO))


def test_switching_gives_a_slowed_client_its_speed_back(session):
    focus_alpha(session)
    wait_for("Bravo to be slowed", lambda: is_at(session, BRAVO, "below_normal", "efficient"),
             details=lambda: speed(session, BRAVO))
    session.switch_to(BRAVO)
    wait_for("Bravo to be raised", lambda: is_at(session, BRAVO, "above_normal", "default"),
             details=lambda: speed(session, BRAVO))
    wait_for("Alpha to be slowed once switching settles", lambda: is_at(session, ALPHA, "below_normal", "efficient"),
             details=lambda: speed(session, ALPHA))


@covers("CharacterConfig.keepFullSpeed")
def test_a_character_kept_at_full_speed_is_never_slowed(session):
    focus_alpha(session, {"characters": [{"name": BRAVO, "keepFullSpeed": True}]})
    wait_for("Bravo to be kept out of efficiency mode", lambda: is_at(session, BRAVO, "normal", "never"),
             details=lambda: speed(session, BRAVO))
    stays("Bravo to stay at full speed", lambda: is_at(session, BRAVO, "normal", "never"), 2.0,
          details=lambda: speed(session, BRAVO))


@fresh({"clientSpeed": {}})
def test_client_speed_leaves_clients_alone_by_default(session):
    focus_alpha(session)
    # Windows itself resets a below-normal client to Normal as it takes focus, and clients inherit the runner's priority.
    time.sleep(1.5)
    started = (speed(session, ALPHA), speed(session, BRAVO))
    stays("both clients to stay as they started", lambda: (speed(session, ALPHA), speed(session, BRAVO)) == started, 2.5,
          details=lambda: (speed(session, ALPHA), speed(session, BRAVO)))


@fresh({"clientSpeed": ALL_ON, "protocolLinks": {"allowExitApp": True}})
def test_quitting_the_app_puts_every_client_back(session):
    focus_alpha(session)
    wait_for("Bravo to be slowed", lambda: is_at(session, BRAVO, "below_normal", "efficient"),
             details=lambda: speed(session, BRAVO))
    session.protocol("evemajpreview://hotkey/exit_app")
    wait_for("the app to exit", lambda: session.app.poll() is not None)
    wait_for("both clients to be put back", lambda: is_at(session, ALPHA, "normal", "default") and is_at(session, BRAVO, "normal", "default"),
             details=lambda: (speed(session, ALPHA), speed(session, BRAVO)))
