"""The taskbar going behind the active client while Hide Taskbar Over Clients is on."""

import ctypes
from ctypes import wintypes

from harness import ALPHA, BRAVO, covers, fresh, stays, user32, wait_for

GW_HWNDPREV = 3
GWL_EXSTYLE = -20
WS_EX_TOPMOST = 0x8
HIDDEN = {"interaction": {"hideTaskbarOverClients": True}}
SHOWN = {"interaction": {"hideTaskbarOverClients": False}}

user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetWindow.restype = wintypes.HWND


def taskbar_state(client_hwnd: int) -> dict:
    """Whether Explorer keeps the taskbar topmost, and whether it sits above `client_hwnd` in the z-order."""
    taskbar = user32.FindWindowW("Shell_TrayWnd", None)
    is_above = False
    hwnd = user32.GetWindow(client_hwnd, GW_HWNDPREV)
    while hwnd:
        if hwnd == taskbar:
            is_above = True
            break
        hwnd = user32.GetWindow(hwnd, GW_HWNDPREV)
    is_topmost = bool(user32.GetWindowLongW(taskbar, GWL_EXSTYLE) & WS_EX_TOPMOST)
    return {"is_topmost": is_topmost, "is_above_client": is_above}


def is_taskbar_over(client_hwnd: int) -> bool:
    state = taskbar_state(client_hwnd)
    return state["is_topmost"] and state["is_above_client"]


def activate_alpha(session, profile: dict):
    """Alpha in front after Bravo, so Explorer judges it when it becomes active rather than as it opens."""
    session.use(profile)
    alpha, _ = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.switch_to(BRAVO)
    session.switch_to(ALPHA)
    return alpha


@covers("InteractionConfig.hideTaskbarOverClients")
def test_the_taskbar_goes_behind_the_active_client_when_on(session):
    alpha = activate_alpha(session, HIDDEN)
    wait_for("the taskbar to go behind Alpha", lambda: not is_taskbar_over(alpha.hwnd),
             details=lambda: taskbar_state(alpha.hwnd))


def test_the_taskbar_stays_over_the_active_client_when_off(session):
    alpha = activate_alpha(session, SHOWN)
    stays("the taskbar to stay over Alpha", lambda: is_taskbar_over(alpha.hwnd), 1.5,
          details=lambda: taskbar_state(alpha.hwnd))


@fresh({"protocolLinks": {"allowExitApp": True}})
def test_quitting_the_app_puts_the_taskbar_back_over_the_clients(session):
    alpha = activate_alpha(session, HIDDEN)
    wait_for("the taskbar to go behind Alpha", lambda: not is_taskbar_over(alpha.hwnd),
             details=lambda: taskbar_state(alpha.hwnd))
    session.protocol("evemajpreview://hotkey/exit_app")
    wait_for("the app to exit", lambda: session.app.poll() is not None)
    wait_for("the taskbar to come back over Alpha", lambda: is_taskbar_over(alpha.hwnd),
             details=lambda: taskbar_state(alpha.hwnd))
