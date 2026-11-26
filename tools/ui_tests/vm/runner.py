"""Runs tools/ui_tests/run.py under pythonw inside the test VM, so no console window covers the tests.

Usage (in the guest, from run_tests.ps1's scheduled task): pythonw runner.py <out dir> <vulkan dir> [run.py arguments ...]
Writes run.py's output to <out dir>/output.txt and its exit code to <out dir>/exitcode.txt. The vulkan dir holds
lavapipe and the Vulkan loader from install_lavapipe.ps1, since the guest has no GPU of its own.
"""

import os
import runpy
import subprocess
import sys
import time
import traceback
from pathlib import Path

UI_TESTS_DIR = Path(__file__).resolve().parents[1]
STATUS_SCRIPT = Path(__file__).resolve().parent / "status.py"
STATUS_STARTUP_SECONDS = 1.5


def use_lavapipe(vulkan_dir: Path) -> None:
    """The app loads vulkan-1.dll by name, so PATH finds it; the loader then takes only lavapipe."""
    if not (vulkan_dir / "vulkan-1.dll").exists():
        return
    os.environ["PATH"] = f"{vulkan_dir};{os.environ.get('PATH', '')}"
    os.environ["VK_DRIVER_FILES"] = str(vulkan_dir / "lvp_icd.x86_64.json")


def main() -> None:
    out_dir = Path(sys.argv[1])
    use_lavapipe(Path(sys.argv[2]))
    subprocess.Popen([sys.executable, str(STATUS_SCRIPT), str(out_dir)])
    # Lets the strip show and give focus back before the first test window opens.
    time.sleep(STATUS_STARTUP_SECONDS)
    code = 1
    with open(out_dir / "output.txt", "w", encoding="utf-8", buffering=1, newline="") as output:
        sys.stdout = sys.stderr = output
        sys.path.insert(0, str(UI_TESTS_DIR))
        sys.argv = [str(UI_TESTS_DIR / "run.py"), *sys.argv[3:]]
        try:
            runpy.run_path(sys.argv[0], run_name="__main__")
            code = 0
        except SystemExit as exit_request:
            if isinstance(exit_request.code, str):
                print(exit_request.code)
            code = exit_request.code if isinstance(exit_request.code, int) else (0 if exit_request.code is None else 1)
        except BaseException:
            traceback.print_exc()
    (out_dir / "exitcode.txt").write_text(str(code), encoding="utf-8", newline="")


if __name__ == "__main__":
    main()
