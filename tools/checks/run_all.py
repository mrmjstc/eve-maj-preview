"""Runs every checker that gates a push, and prints the output of those that fail.

Usage, from anywhere in the repo:
    python tools/checks/run_all.py

duplicates.py is left out: its matches are for review, not a gate. The exit code is 1 if any checker failed.
"""
import os
import subprocess
import sys

from shared import CHECKS

GATES = ("style_check", "config_docs", "dead_code", "import_cycles", "lang_keys", "stale_refs")


def main():
    sys.stdout.reconfigure(errors="replace")
    # Piped, a child would write in the console's code page; findings quote source text, which can be any Unicode.
    environment = {**os.environ, "PYTHONIOENCODING": "utf-8"}
    failed = []
    for name in GATES:
        result = subprocess.run([sys.executable, os.path.join(CHECKS, name + ".py")], capture_output=True, encoding="utf-8", errors="replace", env=environment)
        if result.returncode == 0:
            print(f"{name}: ok")
            continue
        failed.append(name)
        print(f"{name}: failed")
        print(result.stdout + result.stderr, end="")
    sys.stdout.flush()
    if failed:
        print(f"Failed: {', '.join(failed)}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
