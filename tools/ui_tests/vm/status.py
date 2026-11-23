"""Shows a UI test run's progress as a strip over the middle of the VM's taskbar, outside the work area the tests use.

Usage (in the guest, started by runner.py): pythonw status.py <out dir>
Reads <out dir>/output.txt as run.py writes it; click-through and never takes focus.
"""

import ctypes
import sys
import time
import tkinter
from ctypes import wintypes
from pathlib import Path

REFRESH_MS = 1000
GWL_EXSTYLE = -20
WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW, WS_EX_LAYERED, WS_EX_NOACTIVATE = 0x8, 0x20, 0x80, 0x80000, 0x8000000
HWND_TOPMOST = -1
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE = 0x1, 0x2, 0x10
SPI_GETWORKAREA = 0x30
BACKGROUND, NORMAL, GOOD, BAD = "#1f2430", "#d8dee9", "#a3be8c", "#e06c75"

user32 = ctypes.windll.user32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
user32.GetParent.restype = wintypes.HWND
user32.GetParent.argtypes = [wintypes.HWND]
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_long]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.FindWindowW.restype = wintypes.HWND


def strip_rect() -> tuple[int, int, int, int]:
    """(left, top, width, height): the taskbar's middle when it's along the bottom, else a strip below the work area."""
    screen_width, screen_height = user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)
    taskbar = user32.FindWindowW("Shell_TrayWnd", None)
    rect = wintypes.RECT()
    if taskbar and user32.GetWindowRect(taskbar, ctypes.byref(rect)) and rect.top > screen_height // 2:
        width = rect.right - rect.left
        return rect.left + width * 30 // 100, rect.top, width * 45 // 100, rect.bottom - rect.top
    work = wintypes.RECT()
    user32.SystemParametersInfoW(SPI_GETWORKAREA, 0, ctypes.byref(work), 0)
    height = max(28, screen_height - work.bottom)
    return screen_width * 30 // 100, screen_height - height, screen_width * 45 // 100, height


def summary(lines: list[str]) -> tuple[str, str]:
    """(text, colour) for the strip, from run.py's output so far."""
    module = ""
    passed = failed = 0
    last = ""
    for line in lines:
        if line and not line.startswith(" ") and line.startswith("test_"):
            module = line.strip()
        elif line.startswith("  PASS"):
            passed += 1
            last = "PASS " + line[6:].split("  (")[0].strip()
        elif line.startswith("  FAIL") or line.startswith("  ERROR"):
            failed += 1
            last = " ".join(line.split(":")[0].split())
    for line in reversed(lines):
        if " passed in " in line:
            return f"UI tests done: {line.strip()}", GOOD if failed == 0 else BAD
        if line.startswith("Missing ") or line.startswith("EVE-Maj Preview is running"):
            return f"UI tests stopped: {line.strip()}", BAD
    counts = f"{passed} passed, {failed} failed"
    parts = [p for p in (module, counts, last) if p]
    return "  |  ".join(parts) or "UI tests starting", BAD if failed else NORMAL


def main() -> None:
    output_path = Path(sys.argv[1]) / "output.txt"
    started = time.monotonic()
    root = tkinter.Tk()
    root.withdraw()
    root.overrideredirect(True)
    root.configure(bg=BACKGROUND)
    left, top, width, height = strip_rect()
    root.geometry(f"{width}x{height}+{left}+{top}")
    label = tkinter.Label(root, bg=BACKGROUND, fg=NORMAL, font=("Segoe UI", 10), anchor="w", padx=12)
    label.pack(fill="both", expand=True)
    root.update_idletasks()
    hwnd = user32.GetParent(root.winfo_id())
    style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE)
    # A layered window stays invisible until it's given attributes; -alpha does that.
    root.attributes("-alpha", 0.95)
    root.deiconify()
    is_done = False

    def refresh():
        nonlocal is_done
        if not is_done:
            try:
                lines = output_path.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            text, colour = summary(lines)
            is_done = text.startswith("UI tests done") or text.startswith("UI tests stopped")
            elapsed = int(time.monotonic() - started)
            label.configure(text=f"{text}  |  {elapsed // 60}:{elapsed % 60:02d}" if not is_done else text, fg=colour)
        # The taskbar raises itself over other topmost windows when it repaints.
        user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE)
        root.after(REFRESH_MS, refresh)

    refresh()
    root.mainloop()


if __name__ == "__main__":
    main()
