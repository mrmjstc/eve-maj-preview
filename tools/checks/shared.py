"""What the checkers share: where the repo is, reading src/, allowlists and reporting findings."""
import os
import re
import sys
from dataclasses import dataclass

CHECKS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(CHECKS, "..", ".."))
SRC = os.path.join(REPO, "src")
ALLOW_DIR = os.path.join(CHECKS, "allow")


@dataclass
class Finding:
    location: str  # as printed: "src/app.zig:12", or a file alone
    rule: str
    message: str
    is_advisory: bool = False

    def __str__(self):
        kind = "advisory" if self.is_advisory else "error"
        return f"{self.location}: {kind} [{self.rule}] {self.message}"


def code_only(line):
    """The line with string and char literal contents and any // comment removed."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])'", "''", line)
    if line.lstrip().startswith("\\\\"):
        return ""
    cut = line.find("//")
    return line if cut < 0 else line[:cut]


def src_path(full):
    """A file's path under src/, with forward slashes."""
    return os.path.relpath(full, SRC).replace(os.sep, "/")


def read_text(full):
    with open(full, encoding="utf-8") as file:
        return file.read()


def zig_files():
    """Every .zig file under src/, as {path under src/: text}, in sorted order."""
    files = {}
    for directory, _, names in os.walk(SRC):
        for name in names:
            if name.endswith(".zig"):
                full = os.path.join(directory, name)
                files[src_path(full)] = read_text(full)
    return dict(sorted(files.items()))


def selected(paths, known):
    """The paths in `known` under any of the command line's files or folders; all of them when none were given."""
    chosen = set()
    for root in [os.path.abspath(p) for p in paths] or [SRC]:
        rel = src_path(root)
        chosen |= {p for p in known if rel == "." or p == rel or p.startswith(rel + "/")}
    return chosen


def allowlist(name):
    """The entries of allow/<name>.txt, each with its `  # reason` cut off; comment and blank lines skipped."""
    path = os.path.join(ALLOW_DIR, name + ".txt")
    if not os.path.exists(path):
        return []
    entries = []
    with open(path, encoding="utf-8") as file:
        for raw in file:
            entry = raw.split("  #", 1)[0].strip()
            if entry and not entry.startswith("#"):
                entries.append(entry)
    return entries


def report(findings, show_advisories=False):
    """Prints the findings and a summary on stderr; returns the exit code, 1 if any error was found."""
    # Findings quote source text, which a console's code page may not cover.
    sys.stdout.reconfigure(errors="replace")
    errors = advisories = 0
    for finding in findings:
        if finding.is_advisory:
            if not show_advisories:
                continue
            advisories += 1
        else:
            errors += 1
        print(finding)
    sys.stdout.flush()
    print(f"{errors} error(s)" + (f", {advisories} advisory(ies)" if show_advisories else ""), file=sys.stderr)
    return 1 if errors else 0
