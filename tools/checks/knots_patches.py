"""Checks that deps/knots's patches, its EVE-Maj patch markers and PATCHES.md agree, without fetching upstream.

Usage, from the repo root:
    python tools/checks/knots_patches.py

Errors make the exit code 1:
    unexported      a file marked `EVE-Maj patch` has no patch in deps/knots/patches/, or a patch
                    no longer reverses cleanly out of deps/knots: run `python tools/update_knots.py export`
    unmarked        a patched file has no `EVE-Maj patch` marker
    undocumented    a patched file isn't under any of PATCHES.md's `## ` headings
    stale-heading   a PATCHES.md heading names a file no patch touches
"""
import fnmatch
import os
import re
import subprocess
import sys

from shared import REPO, Finding, read_text, report

KNOTS = os.path.join(REPO, "deps", "knots")
PATCHES = os.path.join(KNOTS, "patches")
MARKER = "EVE-Maj patch"
SKIPPED_DIRS = {"patches", "zig-pkg", ".zig-cache", "zig-out"}


def patched_paths():
    """{path inside deps/knots: patch file name}, read from each patch's `diff --git` line."""
    paths = {}
    for name in sorted(os.listdir(PATCHES)):
        if name.endswith(".patch"):
            m = re.search(r"^diff --git a/(\S+) b/", read_text(os.path.join(PATCHES, name)), re.M)
            if m:
                paths[m.group(1)] = name
    return paths


def marked_paths():
    found = set()
    for directory, folders, names in os.walk(KNOTS):
        folders[:] = [f for f in folders if f not in SKIPPED_DIRS]
        for name in names:
            full = os.path.join(directory, name)
            path = os.path.relpath(full, KNOTS).replace(os.sep, "/")
            if path == "PATCHES.md" or not name.endswith((".zig", ".zon")):
                continue
            if MARKER in read_text(full):
                found.add(path)
    return found


def documented_patterns():
    """(line number, pattern) for each backticked path in PATCHES.md's `## ` headings."""
    patterns = []
    for number, line in enumerate(read_text(os.path.join(KNOTS, "PATCHES.md")).split("\n"), 1):
        if line.startswith("## "):
            patterns += [(number, p) for p in re.findall(r"`([^`]+)`", line)]
    return patterns


def reverses_cleanly(name):
    """Whether undoing the patch from deps/knots would succeed, i.e. the tree still holds what it adds."""
    result = subprocess.run(["git", "apply", "-R", "--check", "--directory=deps/knots", os.path.join(PATCHES, name)], cwd=REPO, capture_output=True)
    return result.returncode == 0


def main():
    patched = patched_paths()
    marked = marked_paths()
    patterns = documented_patterns()
    findings = []
    for path in sorted(marked - set(patched)):
        findings.append(Finding(f"deps/knots/{path}", "unexported", "marked as patched, but has no patch; run tools/update_knots.py export"))
    for path, name in patched.items():
        location = f"deps/knots/patches/{name}"
        if not reverses_cleanly(name):
            findings.append(Finding(location, "unexported", f"doesn't match deps/knots/{path} any more; run tools/update_knots.py export"))
        if os.path.exists(os.path.join(KNOTS, path)) and path not in marked:
            findings.append(Finding(f"deps/knots/{path}", "unmarked", f"patched, but has no '{MARKER}' comment"))
        if not any(fnmatch.fnmatch(path, pattern) for _, pattern in patterns):
            findings.append(Finding(f"deps/knots/{path}", "undocumented", "patched, but under no PATCHES.md heading"))
    for number, pattern in patterns:
        if not any(fnmatch.fnmatch(path, pattern) for path in patched):
            findings.append(Finding(f"deps/knots/PATCHES.md:{number}", "stale-heading", f"'{pattern}' matches no patched file"))
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
