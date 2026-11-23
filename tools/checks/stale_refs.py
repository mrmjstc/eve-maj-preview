"""Finds comments that name code no longer in src/: identifiers, and .zig paths.

Usage, from the repo root:
    python tools/checks/stale_refs.py [path ...]

A comment names code when it writes it as code: in backticks, as `name()`, or spelled so no English word
could be (camelCase, snake_case, SCREAMING_SNAKE, a TitleCase name with another capital inside). Each
such name must appear somewhere in src/ code (a declaration, a field, a tag, a local, anything) or be the
stem of a file, and a `x/y.zig` path must exist. Paths only limit what is reported. Findings make the exit
code 1. A deliberate exception goes in tools/checks/allow/stale_refs.txt as
`<name, or a path under src/ ending in .zig>  # reason` for a name that is right but isn't ours (a Win32
or std name, a product).

A name that still exists but now means something else, or moved to where the comment no longer points,
isn't caught.
"""
import argparse
import os
import re
import sys

from shared import REPO, Finding, allowlist, code_only, read_text, report, selected, zig_files

COMMENT = re.compile(r"//[/!]?(.*)$")
BACKTICKED = re.compile(r"`([^`]+)`")
CALLED = re.compile(r"\b([A-Za-z_]\w*)\(\)")
CODE_SHAPED = re.compile(r"\b(?:[a-z]+[A-Z]\w*|[A-Za-z]\w*_\w+|[A-Z][a-z]+[A-Z]\w*)\b")
PATH = re.compile(r"\b([\w./-]+\.zig)\b")
FILE_TYPES = "jpg|png|ico|json|txt|yaml|yml|wav|mp3|dmp|log|old|exe|dll|pdb|md|py|ps1|rc|bak|ttf|otf|html|csv|ini|xml|settings"
IGNORED = {"null", "true", "false", "undefined", "unreachable", "error", "anytype", "comptime", "orelse", "catch", "try", "self"}


def comment_text(line):
    """The text of a line's // comment, ignoring // inside a string."""
    code = re.sub(r'"(?:\\.|[^"\\])*"', lambda m: " " * len(m.group(0)), line)
    if code.lstrip().startswith("\\\\"):
        return None
    m = COMMENT.search(code)
    return line[m.start(1):] if m else None


def named(text):
    """Each identifier the comment text writes as code, once."""
    def blank(pattern, value):
        return re.sub(pattern, lambda m: " " * len(m.group(0)), value)

    text = blank(r"'[^']*'|\"[^\"]*\"", text)  # quoted game text and values
    # URLs, paths, file names, <placeholders>, {placeholders} and *_globs name no identifier.
    text = blank(r"\b\w+://[^\s`]*|[^\s`]*/[^\s`]*|[^\s`]*\.(?:" + FILE_TYPES + r")\b|<[^>]*>|\{[^}]*\}|\*\w*|\w*\*", text)
    found = []
    for m in BACKTICKED.finditer(text):
        for part in re.finditer(r"[A-Za-z_]\w*", m.group(1)):
            found.append(part.group(0))
    plain = BACKTICKED.sub(lambda m: " " * len(m.group(0)), text)
    plain = PATH.sub(lambda m: " " * len(m.group(0)), plain)
    for pattern in (CALLED, CODE_SHAPED):
        for m in pattern.finditer(plain):
            found.append(m.group(1) if pattern is CALLED else m.group(0))
    return [name for name in dict.fromkeys(found) if name not in IGNORED and not name.isdigit()]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="files or folders under src/ to report on (default: all of src/)")
    args = parser.parse_args()

    files = zig_files()
    known = set()
    for path, text in files.items():
        known.add(os.path.splitext(os.path.basename(path))[0])
        for line in text.split("\n"):
            known |= set(re.findall(r"[A-Za-z_]\w*", code_only(line)))
            # Names spelled in strings (bind by name, JSON keys) are code too.
            known |= set(re.findall(r'"(\w+)"', line))
    build = os.path.join(REPO, "build.zig")
    if os.path.exists(build):
        for line in read_text(build).split("\n"):
            known |= set(re.findall(r"[A-Za-z_]\w*", code_only(line)))
    allowed = set(allowlist("stale_refs"))

    findings = []
    for path in sorted(selected(args.paths, files)):
        for number, line in enumerate(files[path].split("\n"), 1):
            text = comment_text(line)
            if not text:
                continue
            for target in PATH.findall(text):
                candidates = {os.path.normpath(os.path.join(os.path.dirname(path), target)).replace(os.sep, "/"), target.lstrip("./")}
                exists = candidates & set(files) or any(p.endswith("/" + target) or p == target for p in files) or os.path.exists(os.path.join(REPO, target))
                if not exists and target not in allowed:
                    findings.append(Finding(f"src/{path}:{number}", "missing-path", f"'{target}' doesn't exist"))
            for name in named(text):
                if name not in known and name not in allowed:
                    findings.append(Finding(f"src/{path}:{number}", "stale-name", f"'{name}' names nothing in src/"))
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
