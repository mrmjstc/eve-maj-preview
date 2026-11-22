"""Runs the end-to-end tests in tests/test_*.py against the built app.

Usage: python tools/ui_tests/run.py [name-substring ...]
       python tools/ui_tests/run.py --failed     (only the tests the last run failed)

Each module shares one sandboxed app and each test switches to a profile of its own; a failed test
restarts the app. Windows appear and take focus, and the mouse and keyboard are used while it runs;
don't touch them until it finishes.
"""

import importlib
import sys
import tempfile
import time
import traceback
from pathlib import Path

from harness import Session, TestFailure, ensure_ready

TESTS_DIR = Path(__file__).parent / "tests"
# Outside the repo; each run rewrites it with the `module.test` names it failed.
FAILURES_FILE = Path(tempfile.gettempdir()) / "eve-maj-ui-failures.txt"


def collect(filters: list[str], exact: set[str] | None = None):
    """(module name, module, tests) per module, tests in the order they're written; `exact` names whole `module.test` ids."""
    sys.path.insert(0, str(TESTS_DIR))
    for path in sorted(TESTS_DIR.glob("test_*.py")):
        module = importlib.import_module(path.stem)
        tests = [(name, fn) for name, fn in vars(module).items() if name.startswith("test_") and callable(fn)]
        tests = [(name, fn) for name, fn in tests if not filters or any(f in f"{path.stem}.{name}" for f in filters)]
        if exact is not None:
            tests = [(name, fn) for name, fn in tests if f"{path.stem}.{name}" in exact]
        if tests:
            yield path.stem, module, tests


def run_test(name: str, fn, session: Session) -> bool:
    started = time.monotonic()
    try:
        fn(session)
        print(f"  PASS  {name}  ({time.monotonic() - started:.1f}s)")
        return True
    except TestFailure as failure:
        print(f"  FAIL  {name}: {failure}")
    except Exception:
        print(f"  ERROR {name}")
        traceback.print_exc()
    return False


def run_fresh(name: str, fn, global_settings: dict) -> bool:
    try:
        with Session(global_settings=global_settings) as own:
            return run_test(name, fn, own)
    except TestFailure as failure:
        print(f"  ERROR {name}: couldn't start its app: {failure}")
        return False


def main(arguments: list[str]) -> int:
    ensure_ready()
    exact = None
    if "--failed" in arguments:
        if not FAILURES_FILE.exists():
            print("No failures recorded from a last run")
            return 1
        exact = set(FAILURES_FILE.read_text(encoding="utf-8").split())
    filters = [a for a in arguments if a != "--failed"]
    passed = failed = 0
    failures: list[str] = []
    started = time.monotonic()
    for module_name, module, tests in collect(filters, exact):
        print(module_name)
        shared: Session | None = None
        try:
            for name, fn in tests:
                fresh_settings = getattr(fn, "fresh_global_settings", None)
                if fresh_settings is not None:
                    # The app is single-instance, so the shared one has to go first.
                    if shared:
                        shared.__exit__(None, None, None)
                        shared = None
                    ok = run_fresh(name, fn, {**getattr(module, "GLOBAL_SETTINGS", {}), **fresh_settings})
                else:
                    if shared is None:
                        shared = Session(global_settings=getattr(module, "GLOBAL_SETTINGS", {})).__enter__()
                    ok = run_test(name, fn, shared)
                    if not ok:
                        shared.restart()
                passed += ok
                failed += not ok
                if not ok:
                    failures.append(f"{module_name}.{name}")
        finally:
            if shared:
                shared.__exit__(None, None, None)
    print(f"\n{passed}/{passed + failed} passed in {time.monotonic() - started:.0f}s")
    FAILURES_FILE.write_text("\n".join(failures), encoding="utf-8", newline="")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
