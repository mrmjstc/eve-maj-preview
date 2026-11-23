"""Finds declarations in src/ that nothing references. Zig only analyzes what is referenced, so the compiler never warns.

Usage, from the repo root:
    python tools/checks/dead_code.py [--advisory] [path ...]

Paths only limit what is reported; references are always counted across all of src/.
Errors are declarations with no reference anywhere and make the exit code 1. Advisories (--advisory)
are heuristics a reviewer has to judge. A deliberate exception goes in tools/checks/allow/dead_code.txt
as `<rule> <path> <text on the line>  # reason`, where a text of `*` matches any line in that file.

Rules:
    unused-import   an @import or alias line nothing in its file names
    dead-private    a non-pub fn/const/var nothing in its file names
    dead-pub        a pub fn/const/var nothing in src/ names
    test-only       (advisory) referenced only from test blocks or tests.zig
    pub-unneeded    (advisory) pub, but only its own file uses it, and not in a pub signature or a field
    maybe-dead      (advisory) a file-level pub decl named elsewhere only by files that don't import its file
    dead-field      a struct or union field nothing names as .field or "field"
    dead-variant    an enum tag nothing names as .tag or "tag"
    write-only-field (advisory) a field only ever set with `.field = value`

Checks repeat with references from dead code dropped, so "except dead code" marks code only dead code uses.
Matching is by name, without types, except that `alias.name` with alias importing another file never counts.
A dead method sharing its name with a live one elsewhere (init, deinit) reads as used, so a clean run is not proof of none. Fields and tags match the same way, so a dead `.width` is
hidden by any other; extern and packed structs, and types walked by @typeInfo, std.meta, std.enums or Wire, are skipped.
"""
import argparse
import os
import re
import sys
from dataclasses import dataclass

from shared import Finding, allowlist, code_only, report, selected, zig_files

# Names the compiler or std reaches without a reference in our code.
STD_HOOKS = {"main", "panic", "std_options", "format", "jsonStringify", "jsonParse", "jsonParseFromValue", "hash", "eql", "_"}
DECL = re.compile(r"^\s*(pub\s+)?((?:export|extern(?:\s+\"\w*\")?|inline|noinline|threadlocal)\s+)*(fn|const|var)\s+(\w+)\b")
IDENT = re.compile(r"(\.?)\b([A-Za-z_]\w*)\b")
CONTAINER_OPEN = re.compile(r"\b(struct|opaque|enum|union)\s*(\([^)]*\))?\s*$")


@dataclass
class Candidate:
    """A finding, with what the allowlist and the dead-code passes need to know about it."""
    path: str
    line_no: int
    rule: str
    message: str
    line_text: str
    span: tuple  # (path, first line index, last line index) of the declaration
    is_advisory: bool = False

    def is_allowed(self, entries):
        return any(rule == self.rule and path in (self.path, "*") and (text == "*" or text in self.line_text) for rule, path, text in entries)

    def finding(self):
        return Finding(f"src/{self.path}:{self.line_no}", self.rule, self.message, self.is_advisory)


def statement_end(codes, start):
    """Index of the line that ends the declaration starting at `start`."""
    depth = 0
    for k in range(start, len(codes)):
        code = codes[k]
        depth += code.count("{") - code.count("}")
        if depth <= 0 and (";" in code or "}" in code):
            return k
    return len(codes) - 1


class Source:
    def __init__(self, path, text):
        self.path = path
        self.lines = text.split("\n")
        self.codes = [code_only(line) for line in self.lines]
        self.decls = []  # (name, line index, end index, is_pub, is_file_level, kind)
        self.in_test = [False] * len(self.lines)
        self.has_file_fields = False
        self.imports = set()
        self.import_aliases = {}  # alias -> imported file, for `const alias = @import("file.zig");`
        self.api_lines = set()  # pub fn signatures, container fields and pub var types, where a type is part of the file's API
        self.api_columns = {}  # line index -> the column span of a pub var or const's type annotation
        self.first_test = next((i for i, code in enumerate(self.codes) if re.match(r"^test\b", code)), len(self.lines))
        self.members = []  # (name, line index, column, container kind, container name or None)
        self.scan()
        self.scan_members()

    def scan(self):
        stack = []  # one of "container", "test", "block" per open brace
        for i, code in enumerate(self.codes):
            all_containers = all(kind == "container" for kind in stack)
            self.in_test[i] = "test" in stack
            m = DECL.match(code)
            if m and all_containers:
                kind = "export" if "export" in (m.group(2) or "") else m.group(3)
                self.decls.append((m.group(4), i, statement_end(self.codes, i), bool(m.group(1)), not stack, kind))
                if m.group(1) and m.group(3) == "fn":
                    k = i
                    while k < len(self.codes) - 1 and "{" not in self.codes[k] and ";" not in self.codes[k]:
                        k += 1
                    self.api_lines |= set(range(i, k + 1))
                elif m.group(1):
                    annotation = re.match(r"^\s*pub\s+(?:var|const)\s+\w+\s*:([^=]*)", code)
                    if annotation:
                        self.api_lines.add(i)
                        self.api_columns[i] = annotation.span(1)
            elif (not stack or stack[-1] == "container") and not m and re.match(r"^\s*[a-z_]\w*\s*:\s*[^=]+[,=]", code) and not re.match(r"^\s*test\b", code):
                self.api_lines.add(i)
                if not stack:
                    self.has_file_fields = True
            for imp in re.findall(r"@import\(\"([^\"]+\.zig)\"\)", self.lines[i]):
                target = os.path.normpath(os.path.join(os.path.dirname(self.path), imp)).replace(os.sep, "/")
                self.imports.add(target)
                alias = re.match(r"^\s*(?:pub\s+)?const\s+(\w+)\s*=\s*@import\(\"[^\"]+\"\);", self.lines[i])
                if alias:
                    self.import_aliases[alias.group(1)] = target
            for pos, ch in enumerate(code):
                if ch == "{":
                    before = code[:pos]
                    if CONTAINER_OPEN.search(before):
                        stack.append("container")
                    elif re.match(r"^\s*test\b", code):
                        stack.append("test")
                    else:
                        stack.append("block")
                elif ch == "}" and stack:
                    stack.pop()

    def scan_members(self):
        """Fields of structs and unions and tags of enums, from each container's own level; extern and packed structs keep a layout, so they're skipped."""
        stack = []  # per open brace: container kind ("struct", "enum", "union", "opaque", "skip") or "block"
        outer_parens = []  # the enclosing level's open-paren count, restored when its brace closes
        names = []  # per open brace, the container's declared name, or None
        text, start, parens = "", None, 0

        def flush():
            nonlocal text, start
            kind = stack[-1] if stack else "file"
            if start is not None and kind in ("struct", "enum", "union", "file"):
                pattern = r"^\s*(\w+)\s*(?:=[^=>]|,|$)" if kind == "enum" else r"^\s*(\w+)\s*(?::|,|$)"
                m = re.match(pattern, text)
                bare_name = not re.match(r"^\s*\w+\s*:", text)
                if m and m.group(1) not in KEYWORDS and not (bare_name and kind in ("struct", "file")):
                    self.members.append((m.group(1), start[0], start[1] + m.start(1), kind, names[-1] if names else None))
            text, start = "", None

        for i, code in enumerate(self.codes):
            for pos, ch in enumerate(code):
                at_member_level = not stack or stack[-1] != "block"
                if ch == "(":
                    parens += 1
                elif ch == ")":
                    parens -= 1
                if ch == "{":
                    if at_member_level:
                        flush()
                    container = CONTAINER_OPEN.search(code[:pos])
                    if container:
                        is_layout = re.search(r"\b(extern|packed)\s+(struct|union)\s*(\([^)]*\))?\s*$", code[:pos])
                        stack.append("skip" if is_layout else container.group(1))
                        declared = re.search(r"\b(\w+)\s*=\s*(?:extern\s+|packed\s+)?(?:struct|enum|union)\b", code[:pos])
                        names.append(declared.group(1) if declared else None)
                    else:
                        stack.append("block")
                        names.append(None)
                    outer_parens.append(parens)
                    parens = 0
                    continue
                if ch == "}":
                    if at_member_level:
                        flush()
                    if stack:
                        stack.pop()
                        names.pop()
                        parens = outer_parens.pop()
                    continue
                if not at_member_level:
                    continue
                if (ch == "," and parens <= 0) or ch == ";":
                    flush()
                    parens = 0
                    continue
                if start is None and not ch.isspace():
                    start = (i, pos)
                if start is not None:
                    text += ch
            if start is not None:
                text += " "


KEYWORDS = {"pub", "fn", "const", "var", "comptime", "test", "usingnamespace", "extern", "export", "inline", "noinline", "threadlocal", "return", "if", "else", "switch", "for", "while", "defer", "errdefer", "try", "align", "callconv"}


REFLECTION = re.compile(r"(?:@typeInfo|std\.meta\.\w+|std\.enums\.\w+|enumLabels|\bWire|wire\.\w+)\(\s*(?:[\w.]+\.)?(\w+)\s*[,)]")


def reflected_types(sources):
    """Type names whose fields or tags are walked by reflection, so each one is read without being named."""
    return {name for source in sources.values() for code in source.codes for name in REFLECTION.findall(code)}


def string_references(sources):
    """name -> list of (path, line index), for identifiers spelled out in string literals: bind-by-name and @field reach fields this way."""
    refs = {}
    for source in sources.values():
        for i, line in enumerate(source.lines):
            for m in re.finditer(r'"(\w+)"', line):
                refs.setdefault(m.group(1), []).append((source.path, i))
    return refs


def references(sources):
    """name -> list of (path, line index, is_member_access, is_in_test, column)."""
    refs = {}
    for source in sources.values():
        for i, code in enumerate(source.codes):
            in_test = source.in_test[i] or source.path == "tests.zig"
            for m in IDENT.finditer(code):
                refs.setdefault(m.group(2), []).append((source.path, i, m.group(1) == ".", in_test, m.start(2)))
        # @hasDecl(T, "name") and @field(x, "name") reach a decl through a string, from any type's file.
        for line in source.lines:
            for name in re.findall(r"@(?:hasDecl|field)\([^,]+,\s*\"(\w+)\"", line):
                refs.setdefault(name, []).append(("<reflection>", -1, True, False, 0))
    return refs


def through_other_module(sources, ref, path):
    """Whether ref is `alias.name` with alias importing a file other than path, so it can't name path's decl."""
    referrer = sources.get(ref[0])
    if referrer is None or not ref[2]:
        return False
    owner = re.search(r"(?<![\w.])(\w+)\s*\.\s*$", referrer.codes[ref[1]][:ref[4]])
    target = referrer.import_aliases.get(owner.group(1)) if owner else None
    return target is not None and target != path


def in_api(source, ref):
    """Whether a reference sits in a pub signature, a field or a pub var's type."""
    if ref[1] not in source.api_lines:
        return False
    start, end = source.api_columns.get(ref[1], (0, len(source.codes[ref[1]])))
    return start <= ref[4] < end


def check(sources, refs, string_refs, reflected):
    findings = []
    for source in sources.values():
        if source.path == "tests.zig":
            continue
        test_only_spans = []
        for name, start, end, is_pub, is_file_level, kind in source.decls:
            if name in STD_HOOKS or kind == "export":
                continue
            line_text = source.lines[start]

            def add(rule, message, is_advisory=False):
                findings.append(Candidate(source.path, start + 1, rule, message, line_text, (source.path, start, end), is_advisory))

            outside = [r for r in refs.get(name, []) if not (r[0] == source.path and start <= r[1] <= end) and not through_other_module(sources, r, source.path)]
            local = [r for r in outside if r[0] == source.path]
            # Another file can only reach a pub decl through member access: mod.name, Type.name, .name.
            external = [r for r in outside if r[0] != source.path and r[2]]
            used = local + external if is_pub else local
            is_import = bool(re.search(r"=\s*@import\(", line_text)) or bool(re.match(r"^\s*const\s+\w+\s*=\s*(?!(?:true|false|null|undefined)\s*;)[A-Za-z_][\w.]*;\s*$", source.codes[start]))

            if not used:
                if is_pub:
                    add("dead-pub", f"pub {kind} '{name}' is referenced nowhere in src/")
                elif is_import and is_file_level:
                    add("unused-import", f"'{name}' is never used in this file")
                else:
                    add("dead-private", f"{kind} '{name}' is never used in this file")
                continue
            if all(r[3] for r in used):
                # Private fixtures, helpers below the first test and members of a test-only type are expected.
                is_helper = start > source.first_test or "std.testing" in source.codes[start]
                if is_pub and not is_helper and not any(s < start <= e for s, e in test_only_spans):
                    add("test-only", f"'{name}' is only referenced from tests", True)
                test_only_spans.append((start, end))
                continue
            if is_pub and not external and not any(in_api(source, r) for r in local):
                add("pub-unneeded", f"'{name}' is pub but only this file uses it", True)
                continue
            if is_pub and is_file_level and not local and not source.has_file_fields:
                importers = {r[0] for r in external if r[0] not in sources or source.path in sources[r[0]].imports}
                if not importers:
                    add("maybe-dead", f"'{name}' is only named by files that don't import {source.path}", True)
        for name, line, column, kind, container in source.members:
            if source.in_test[line] or container in reflected:
                continue
            # Fields and tags are only ever reached as .name, or by name in a string (bind by name, @field, JSON).
            used = [r for r in refs.get(name, []) if r[2] and not (r[0] == source.path and r[1] == line and r[4] == column)]
            if name in string_refs:
                continue
            if used:
                # `.name = value`, in an initializer or an assignment, sets a field without reading it.
                if kind != "enum" and all(re.match(r"\s*=(?![=>])", sources[r[0]].codes[r[1]][r[4] + len(name):]) for r in used if r[0] in sources):
                    findings.append(Candidate(source.path, line + 1, "write-only-field", f"field '{name}' is set but never read", source.lines[line], (source.path, line, line), True))
                continue
            rule, noun = ("dead-variant", "enum tag") if kind == "enum" else ("dead-field", "field")
            findings.append(Candidate(source.path, line + 1, rule, f"{noun} '{name}' is never used in src/", source.lines[line], (source.path, line, line)))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--advisory", action="store_true", help="also report heuristics a reviewer has to judge")
    parser.add_argument("paths", nargs="*", help="files or folders under src/ to report on (default: all of src/)")
    args = parser.parse_args()

    sources = {path: Source(path, text) for path, text in zig_files().items()}
    report_paths = selected(args.paths, sources)
    entries = [tuple(entry.split(" ", 2)) for entry in allowlist("dead_code")]
    entries = [entry for entry in entries if len(entry) == 3]

    all_refs = references(sources)
    string_refs = string_references(sources)
    reflected = reflected_types(sources)
    # Repeat with references from dead code dropped, until nothing new dies; allowlisted code stays live.
    dead, first_dead = set(), None
    while True:
        refs = {name: [r for r in at if not any(p == r[0] and s <= r[1] <= e for p, s, e in dead)] for name, at in all_refs.items()}
        candidates = [c for c in check(sources, refs, string_refs, reflected) if not c.is_allowed(entries)]
        now_dead = {c.span for c in candidates if not c.is_advisory}
        if first_dead is None:
            first_dead = now_dead
        if now_dead == dead:
            break
        dead = now_dead

    findings = []
    for candidate in sorted(candidates, key=lambda c: (c.path, c.line_no)):
        if candidate.path not in report_paths:
            continue
        if not candidate.is_advisory and candidate.span not in first_dead:
            candidate.message += " except dead code"
        findings.append(candidate.finding())
    return report(findings, args.advisory)


if __name__ == "__main__":
    sys.exit(main())
