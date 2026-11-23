"""Mechanical checks for the rules in docs/STYLE.md that a script can decide.

Usage, from the repo root:
    python tools/checks/style_check.py [--advisory] [path ...]

Errors are rule violations and make the exit code 1. Advisories (--advisory) are
heuristics a reviewer has to judge. A deliberate exception goes in
tools/checks/allow/style_check.txt as `<rule> <path under src/ or *> <text on the line>  # reason`.
Each check names the STYLE.md section it enforces.

Left to the reviewer, since a script can't decide them: whether a comment restates the code, stale or
misplaced docs, ownership docs on fields that aren't obviously owned, cross-thread docs, exhaustive
switches on project enums (needs types), errdefer placement, numbers or strings two files must agree on,
a float formatted into a fixed buffer, whether pure logic has been split out, and whether related
declarations (a colour among the palette, a global beside the one it works with) sit together.
"""
import argparse
import os
import re
import sys

from shared import SRC, Finding, allowlist, code_only, read_text, report, src_path

# §8: modules allowed their own externs, for a library only they use.
EXTERN_FILES = {"platform/win32.zig", "notifications/sound.zig", "notifications/tts.zig", "util/http_client.zig"}
# §2: abbreviations STYLE.md spells out, as a whole name or a name part.
BANNED_NAMES = {"ts", "cnt", "ctx", "idx", "tmp", "exe", "cfg", "mgr", "num", "val", "btn", "wnd", "str", "pos", "ptr_", "len", "dx", "dy", "pt", "bmi", "nid", "fmt"}
BANNED_PARTS = {"ts", "cnt", "ctx", "idx", "tmp", "exe", "cfg", "mgr", "btn", "wnd", "dims", "props", "procs", "bufs"}
# §2: abbreviations that only read as one at a name's end: `z` alone is an axis, `w` alone a width.
BANNED_SUFFIXES = ("_len", "_z", "_w")
# §2: Win32 message parameters keep their Win32 spelling.
WIN32_PARAM_MISSPELLINGS = {"lparam": "lParam", "wparam": "wParam", "ncode": "nCode", "l_param": "lParam", "w_param": "wParam"}
WIN32_PARAM_NAMES = {"wParam", "lParam", "nCode"}
# §2: files whose fields or parameters mirror an external schema: the profile JSON, Win32 and COM structs.
SCHEMA_FILES = ("config/", "config.zig", "platform/win32.zig", "notifications/sound.zig", "notifications/tts.zig", "platform/wic.zig", "util/http_client.zig")
SINGLE_LETTERS_ALLOWED = set("ixyrgbalms") | {"it"}
BOOL_PREFIXES = ("is_", "has_", "should_", "was_", "were_", "can_", "needs_", "uses_", "wants_", "shows_", "allows_", "keeps_", "any_", "did_")
UNIT_SUFFIX = re.compile(r"(_ms|_ns|_us|_seconds|_minutes|_hours|_bytes|_mb|_kb|_percent|_px|_count|_index|_length|_width|_height|_id|_size)$")
TIME_WORDS = re.compile(r"^(?:.*_)?(delay|interval|timeout|duration|elapsed|age|period|now|until|since|deadline|expiry|ttl|throttle|cooldown|retention|volume)$")
# §3: a doc line giving a parameter's or member's contract, `name`: ... or `Window` methods: ...
DOC_ITEM = re.compile(r"^///\s*`[^`]+`[^:`]{0,20}:\s")
# §3: where a one-sentence comment has started doing a paragraph's work.
MAX_COMMENT_LENGTH = 150
MAX_TAG_LIST_LENGTH = 120
# A tag list's parts are a few words each; a longer one is a clause.
MAX_TAG_WORDS = 4
# §6: field calls that don't change the field, so a method making only these reads self.
READ_ONLY_CALLS = {"get", "contains", "count", "items", "slice", "len", "hash", "eql", "dupe", "dupeZ", "dupeSentinel", "alloc", "create", "free", "destroy", "print", "allocPrint", "keyIterator", "valueIterator"}
# §6: anytype parameters whose shape their name already says.
SELF_EXPLAINING_ANYTYPE = {"args", "writer", "value", "self", "json_writer", "jw", "source", "options"}


class Source:
    """One file under check: its lines, what the checks share about them, and what they found."""

    def __init__(self, path, text, allowed):
        self.path = path
        self.text = text
        self.lines = text.split("\n")
        self.codes = [code_only(line) for line in self.lines]
        self.functions = function_spans(self.lines)
        self.first_test = next((i for i, line in enumerate(self.lines) if line.startswith("test \"")), len(self.lines))
        self.has_tests = self.first_test < len(self.lines)
        self.imports = set(re.findall(r"^(?:pub\s+)?const\s+(\w+)\s*=\s*@import\(", text, re.M))
        self.findings = []
        self._allowed = allowed

    def add(self, i, rule, message, is_advisory=False):
        line_text = self.lines[i] if i < len(self.lines) else ""
        for allowed_rule, allowed_path, text in self._allowed:
            if allowed_rule == rule and allowed_path in (self.path, "*") and text in line_text:
                return
        self.findings.append((i + 1, Finding(f"src/{self.path}:{i + 1}", rule, message, is_advisory)))


def function_spans(lines):
    """(name, first line index, last line index, signature text) for every fn with a body."""
    spans = []
    i = 0
    while i < len(lines):
        m = re.match(r"^\s*(?:pub\s+)?(?:inline\s+)?fn\s+(\w+)\(", lines[i])
        if not m:
            i += 1
            continue
        signature = lines[i]
        j = i
        while "{" not in code_only(lines[j]) and not code_only(lines[j]).rstrip().endswith(";") and j + 1 < len(lines):
            j += 1
            signature += lines[j]
        if code_only(lines[j]).rstrip().endswith(";"):
            i = j + 1
            continue
        depth = 0
        k = j
        while k < len(lines):
            code = code_only(lines[k])
            depth += code.count("{") - code.count("}")
            if depth <= 0 and ("{" in code_only(signature) or k > j):
                break
            k += 1
        spans.append((m.group(1), i, k, signature))
        i += 1
    return spans


def block_spans(lines, start_pattern):
    """(first line index, last line index) of every block whose first line matches start_pattern."""
    spans = []
    for i, line in enumerate(lines):
        if not re.match(start_pattern, line):
            continue
        depth = 0
        for j in range(i, len(lines)):
            code = code_only(lines[j])
            depth += code.count("{") - code.count("}")
            if depth <= 0 and "{" in "".join(code_only(l) for l in lines[i:j + 1]):
                spans.append((i, j))
                break
    return spans


def statement_text(codes, start):
    """The statement starting on line `start`, up to the `;` that closes it outside any brackets."""
    depth = 0
    parts = []
    for code in codes[start:start + 40]:
        parts.append(code)
        for char in code:
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
        if depth <= 0 and code.rstrip().endswith(";"):
            break
    return "\n".join(parts)


def reads_as_statement(name):
    """Whether a boolean's name says what's true, as §2 asks."""
    bare = name[2:] if name.startswith("g_") else name
    words = bare.split("_")
    return (
        bare.startswith(BOOL_PREFIXES + ("are_", "had_"))
        or words[0].endswith(("s", "ed"))
        or words[-1].endswith("ed")
        or any(w in ("is", "has", "are", "was", "needs", "uses") for w in words[1:])
    )


def import_category(file_path, import_path):
    if not import_path.endswith(".zig"):
        return 0
    if import_path.split("/")[-1] == "log.zig":
        return 3
    if "platform/" in import_path or (file_path.startswith("platform/") and "/" not in import_path):
        return 1
    return 2


def top_level_kind(line, import_names):
    """The §1 ordering class of a column-0 declaration, or None when the line starts no declaration."""
    if line.startswith("test "):
        return "test"
    m = re.match(r"^(pub\s+)?(inline\s+)?fn\s", line)
    if m:
        return "pub_fn" if m.group(1) else "fn"
    if re.match(r"^(pub\s+)?extern\b", line):
        return "constant"
    if re.match(r"^(pub\s+)?var\s", line):
        return "global"
    m = re.match(r"^(pub\s+)?const\s+(\w+)(?:\s*:\s*[^=]+)?\s*=\s*(.*)$", line)
    if not m:
        return None
    name, value = m.group(2), m.group(3)
    if "@import(" in value:
        return "import"
    if name == "testing":
        return "test_alias"
    if name == "slog":
        return "alias"
    # A type read off an import's own by reflection (@typeInfo(@FieldType(ui.Style, "grid")).optional.child) is an alias too.
    reflected = re.match(r"^(?:@(?:typeInfo|FieldType)\()+(\w+)\b", value)
    if reflected and reflected.group(1) in import_names and name[0].isupper() and not name.isupper():
        return "import_type"
    source = re.match(r"^(\w+)\.", value)
    if source and source.group(1) in import_names and not re.search(r"\b(struct|enum|union)\s*\{", value):
        # A plain path is a re-export or alias; a call or expression builds a type or a constant.
        if re.match(r"^[\w.]+;$", value):
            return "import_type" if name.isupper() else "alias"
        return "import_type" if name[0].isupper() and not name.isupper() else "constant"
    if re.match(r"^(packed\s+|extern\s+)?(struct|enum|union|opaque)\b", value) or (name[0].isupper() and not name.isupper()):
        return "type"
    return "constant"


def check_layout(s):
    """§1: the header, imports, slog, and the order of what follows them."""
    lines, codes = s.lines, s.codes
    if not lines or not lines[0].startswith("//!"):
        s.add(0, "header", "file must start with a one-line //! header")
    elif len(lines) > 1 and lines[1].startswith("//!"):
        s.add(1, "header", "the //! header must be one line")
    elif len(lines) > 1 and lines[1].strip() == "":
        s.add(1, "header", "no blank line between the //! header and the imports")

    last_category = -1
    in_import_block = True
    for i, code in enumerate(codes):
        if re.match(r"^\s*(?:pub\s+)?const\s+\w+\s*=\s*@import\(\"[^\"]*\"\)\.\w+", lines[i]):
            s.add(i, "import-type", "import the module, then alias the type on its own line")
        m = re.match(r"^(?:pub\s+)?const\s+\w+\s*=\s*@import\(\"([^\"]+)\"\);", lines[i])
        if m and in_import_block and s.path != "log.zig":
            category = import_category(s.path, m.group(1))
            if category < last_category:
                s.add(i, "import-order", "imports go std, then platform/, then project modules, then log")
            last_category = max(last_category, category)
        elif i > 0 and code.strip() and not m:
            in_import_block = False

    for i, line in enumerate(lines):
        m = re.match(r"^const (\w+) = (?:@import\(|[a-z_]+(?:\.[a-z_]+)*\.[A-Z]\w*;)", line)
        if m and not any(re.search(r"\b" + m.group(1) + r"\b", code) for j, code in enumerate(codes) if j != i):
            s.add(i, "unused-import", f"'{m.group(1)}' is never used")

    uses_slog = any(re.search(r"\bslog\.(debug|info|warn|err)\(", c) for c in codes)
    top_slog = any(re.match(r"^const slog = log\.Scoped\(", l) for l in lines)
    for i, line in enumerate(lines):
        if re.match(r"^\s+const slog = ", line):
            s.add(i, "slog", "declare slog at file level, after the imports")
    if uses_slog and not top_slog and s.path != "log.zig":
        s.add(0, "slog", "the file logs but declares no file-level `const slog = log.Scoped(...)`")

    for i in range(s.first_test, len(lines)):
        if re.match(r"^pub (fn|const|var) ", lines[i]):
            s.add(i, "tests-last", "test blocks go at the bottom of the file")
            break
    for i in range(s.first_test, len(lines)):
        if re.match(r"^(const|var|fn)\s", lines[i]):
            s.add(i, "test-scaffold", "what the tests share goes above the first test, after const testing")

    # Imports, aliases, constants, types, globals, public functions, private functions, tests; win32.zig groups by API area (§8).
    if s.path == "platform/win32.zig":
        return
    rank = {"import": 0, "alias": 1, "constant": 2, "type": 3, "global": 4, "pub_fn": 5, "fn": 6, "test": 7}
    seen_highest = None
    alias_sources = {"std", "builtin"} | s.imports
    type_names = set()
    for i, line in enumerate(lines):
        kind = top_level_kind(line, alias_sources)
        if kind is None:
            continue
        if kind == "type":
            type_names.add(re.match(r"^(?:pub\s+)?const\s+(\w+)", line).group(1))
        # From the tests' own alias down is the test section, which test-scaffold checks.
        if kind == "test_alias":
            break
        if kind in ("alias", "import_type"):
            alias_sources.add(re.match(r"^(?:pub\s+)?const\s+(\w+)", line).group(1))
        # A type built from an import (session.Ref(Config)) reads as an alias in the alias block, and as a type after it.
        if kind == "import_type":
            is_constant = re.match(r"^(?:pub\s+)?const\s+([A-Z0-9_]+)\b", line) is not None
            kind = "alias" if seen_highest in (None, "import", "alias") else ("constant" if is_constant else "type")
        # After a test, tests-last and test-scaffold have already said where it goes.
        if seen_highest is not None and seen_highest != "test" and rank[kind] < rank[seen_highest]:
            if kind == "constant" and seen_highest == "type":
                # A constant built from a type above it (`[_]Move{`, `[n]Replayed`) sits with that type.
                if not any(re.search(rf"\b{name}\b", statement_text(codes, i)) for name in type_names):
                    s.add(i, "decl-order", "constants go before types, unless this one is built from a type above it", True)
            else:
                s.add(i, "decl-order", f"a {kind.replace('_', ' ')} after a {seen_highest.replace('_', ' ')}: the order is imports, aliases, constants, types, globals, public functions, private functions, tests")
        if seen_highest is None or rank[kind] > rank[seen_highest]:
            seen_highest = kind


def check_names(s):
    """§2: case, abbreviations, units, booleans, counts, and names that clash."""
    lines, codes, path = s.lines, s.codes, s.path
    is_schema_file = path.startswith(SCHEMA_FILES)

    for i, line in enumerate(lines):
        m = re.match(r"^(?:pub\s+)?const\s+(\w+)(?:\s*:\s*[^=]+)?\s*=\s*(-?\d|\")", line)
        if m and re.search(r"[a-z]", m.group(1)) and path != "platform/win32.zig":
            s.add(i, "constant-case", f"module-level constant '{m.group(1)}' should be SCREAMING_SNAKE")
        m = re.match(r"^(?:pub\s+)?var\s+(\w+)", line)
        if m and not m.group(1).startswith("g_"):
            s.add(i, "global-prefix", f"mutable global '{m.group(1)}' needs the g_ prefix")

    declared = set()
    for i, code in enumerate(codes):
        names = re.findall(r"\b(?:const|var)\s+(\w+)", code)
        names += re.findall(r"[(,]\s*(?:comptime\s+|noalias\s+)?(\w+)\s*:", code)
        for capture in re.findall(r"\|([^|]+)\|", code):
            names += [n.strip().lstrip("*") for n in capture.split(",")]
        field = re.match(r"^\s+(\w+)\s*:\s*[^=]", code)
        if field and not code.strip().startswith("."):
            names.append(field.group(1))
        for name in names:
            if not name or not re.match(r"^[a-z_]\w*$", name):
                continue
            declared.add(name)
            parts = name.split("_")
            if name in BANNED_NAMES or any(p in BANNED_PARTS for p in parts) or name.endswith(BANNED_SUFFIXES):
                s.add(i, "abbreviation", f"'{name}': spell the word out (§2)")
            if name.lower() in WIN32_PARAM_MISSPELLINGS and name != WIN32_PARAM_MISSPELLINGS[name.lower()]:
                s.add(i, "win32-param", f"'{name}' keeps its Win32 spelling, {WIN32_PARAM_MISSPELLINGS[name.lower()]}")
            if name in ("alloc", "gpa"):
                s.add(i, "allocator-name", f"'{name}': call it allocator, or arena if it's one")
        if re.search(r"fn \w+\(code:\s*c_int,\s*wParam", code):
            s.add(i, "win32-param", "a hook's first parameter is nCode")

    for i, code in enumerate(codes):
        m = re.search(r"\bfn ([a-z]{1,2})\(", code)
        if m:
            s.add(i, "short-fn-name", f"function '{m.group(1)}': spell the word out (§2)")

    # _mod only when the bare stem would clash; config_mod is STYLE.md's own example, since `config` is a common field name.
    for i, line in enumerate(lines):
        m = re.match(r"^const (\w+)_mod = @import\(\"(?:[^\"]*/)?(\w+)\.zig\"\);", line)
        if m and m.group(1) == m.group(2) and m.group(1) != "config" and m.group(1) not in declared and not re.search(r"\bfn " + m.group(1) + r"\b", s.text):
            s.add(i, "mod-alias", f"'{m.group(1)}_mod': nothing named '{m.group(1)}' clashes, so drop _mod")

    # An import named like a field compiles but reads as the field, so the import takes _mod.
    imported = set(re.findall(r"^const (\w+) = @import\(\"[^\"]+\.zig\"\);", s.text, re.M))
    for i, code in enumerate(codes):
        m = re.match(r"^\s+(\w+)\s*:\s*[^=:]", code)
        if m and m.group(1) in imported and not code.strip().startswith("."):
            s.add(i, "import-clash", f"field '{m.group(1)}' clashes with the import, so name the import {m.group(1)}_mod")

    # A block label named like an import reads as the module inside the block it labels.
    import_aliases = {m.group(1) for line in lines for m in [re.match(r"^const (\w+) = @import\(", line)] if m}
    for i, code in enumerate(codes):
        for m in re.finditer(r"(?<![.\w])(\w+):\s*(?:\{|while\b|for\b|switch\b|inline\b)|\b(?:break|continue) :(\w+)", code):
            label = m.group(1) or m.group(2)
            if label in import_aliases:
                s.add(i, "label-clash", f"label '{label}' shares its name with an import: name it for what the block does")

    # A comparator's pair is first and second; a and b stay colour channels, beside a g.
    for i, code in enumerate(codes):
        if "extern" in code or re.search(r"\bfn \w+\(", code) is None:
            continue
        params = re.findall(r"[(,]\s*(\w+)\s*:", code)
        if ("a" in params or "b" in params) and "g" not in params:
            s.add(i, "comparator-pair", "a comparator's pair is first and second, not a and b")
    for i, code in enumerate(codes):
        m = re.match(r"^\s+(?:const|var)\s+([ab])\s*[:=]", code)
        if m and not any(re.search(r"\b(?:const|var)\s+g\s*[:=]", c) for c in codes[max(0, i - 3):i + 4]):
            s.add(i, "comparator-pair", f"'{m.group(1)}': a comparator's pair is first and second, not a and b")

    for name, start, end, signature in s.functions:
        body = codes[start:end + 1]
        declared_here = {}
        for i in range(start, end + 1):
            m = re.match(r"^\s+var (\w+)\s*:\s*(?:usize|u\d+|i\d+|c_int)\s*=\s*0;", codes[i])
            if m and not re.search(r"(count|index|total|sum|depth|offset|position|length|width|height|size)$", m.group(1)) and m.group(1) not in ("i", "j", "k", "x", "y"):
                uses = [c for c in body if re.search(r"\b" + m.group(1) + r"\s*(\+=|-=|=)(?!=)", c)]
                # A cursor into something goes up by one too, but it's an index.
                is_cursor = any(re.search(r"\[[^\]]*\b" + m.group(1) + r"\b[^\]]*\]", c) for c in body)
                if uses and not is_cursor and all(re.search(r"\b" + m.group(1) + r"\s*\+= 1\b", c) for c in uses):
                    s.add(i, "count-name", f"'{m.group(1)}' counts something, so it's {m.group(1)}_count", True)
            m = re.match(r"^\s+(?:const|var)\s+(\w+)\s*=", codes[i])
            if m:
                declared_here.setdefault(m.group(1), i)
        # A local with no bool annotation, told apart only by its use as a condition.
        conditions = set()
        for code in body:
            conditions.update(re.findall(r"\bif \(!?(\w+)\)(?!\s*\|)", code))
        for local in conditions & set(declared_here):
            if not reads_as_statement(local):
                s.add(declared_here[local], "bool-name", f"'{local}': name a boolean as a statement (is_, has_, should_, a past tense or a third-person verb)", True)

    for i, code in enumerate(codes):
        if "extern" in code:
            continue
        for m in re.finditer(r"\b(?:const|var)\s+(\w+)\s*:\s*([iuf]\d+|usize|isize|c_int)\b|[(,]\s*(\w+)\s*:\s*([iuf]\d+|usize|isize|c_int)\s*[,)]", code):
            name = m.group(1) or m.group(3)
            if name and TIME_WORDS.search(name) and not UNIT_SUFFIX.search(name):
                s.add(i, "unit", f"'{name}': include its unit in the name", True)
        for m in re.finditer(r"\b(?:const|var)\s+(\w+)\s*:\s*bool\b|[(,]\s*(\w+)\s*:\s*bool\s*[,)]|^\s+(\w+)\s*:\s*bool\s*[,=]", code):
            name = m.group(1) or m.group(2) or m.group(3)
            if not name or not name.islower() and "_" not in name and any(c.isupper() for c in name):
                continue
            # Config fields are the profile JSON's names, which keep their spelling.
            if m.group(3) and path.startswith("config/"):
                continue
            if not reads_as_statement(name):
                s.add(i, "bool-name", f"'{name}': name a boolean as a statement (is_, has_, should_, a past tense or a third-person verb)", True)

    for i, code in enumerate(codes):
        if re.search(r"\bextern\b", code):
            continue
        m = re.search(r"\bfn ([a-z]\w*)\([^)]*\)\s*\??type\s*\{", code)
        if m:
            s.add(i, "type-fn-case", f"'{m.group(1)}' returns a type, so it's TitleCase")
        m = re.search(r"\bfn (\w+)\(", code)
        if m and not re.search(r"\)\s*\??type\s*\{", code):
            name = m.group(1)
            if "_" in name.strip("_"):
                s.add(i, "fn-case", f"function '{name}' is camelCase")
            elif name[0].isupper():
                s.add(i, "fn-case", f"function '{name}' is camelCase; TitleCase is for types and functions returning one")
        m = re.match(r"^\s+(?:const|var)\s+([a-z][a-z0-9]*[A-Z]\w*)\b", code)
        if m and not is_schema_file and m.group(1) not in WIN32_PARAM_NAMES:
            s.add(i, "local-case", f"'{m.group(1)}' is snake_case")
        m = re.match(r"^\s*(?:pub\s+)?const\s+([a-z]\w*)\s*=\s*(?:packed\s+|extern\s+)?(struct|enum|union|opaque)\b", code)
        if m and path != "dialog/knots/style.zig":
            s.add(i, "type-case", f"type '{m.group(1)}' is TitleCase")
        for name in re.findall(r"\berror\.([a-z]\w*)", code):
            s.add(i, "error-case", f"error.{name} is TitleCase")
        m = re.match(r"^\s+([a-z][a-z0-9]*[A-Z]\w*)\s*:\s*[^=]", code)
        if m and not is_schema_file and m.group(1) not in WIN32_PARAM_NAMES and not code.strip().startswith("."):
            s.add(i, "field-case", f"field '{m.group(1)}' is snake_case, unless it mirrors the profile JSON or a Win32 struct")
        if re.search(r"\bfn \w+\(", code) and not is_schema_file:
            for name in re.findall(r"[(,]\s*(?:comptime\s+)?([a-z][a-z0-9]*[A-Z]\w*)\s*:", code):
                if name not in WIN32_PARAM_NAMES:
                    s.add(i, "param-case", f"parameter '{name}' is snake_case")
        if re.search(r"\b(?:const|var)\s+[a-z]\s*[:=]", code) or re.search(r"\bfn \w+\(.*[(,]\s*[a-z]\s*:", code):
            for name in re.findall(r"\b(?:const|var)\s+([a-z])\s*[:=]", code) + re.findall(r"[(,]\s*([a-z])\s*:", code if "fn " in code else ""):
                if name not in SINGLE_LETTERS_ALLOWED:
                    s.add(i, "single-letter", f"'{name}': single letters are for loop captures, colour channels, formula terms and short if-captures", True)

    for i, line in enumerate(lines):
        m = re.match(r"^const (\w+) = @import\(\"[^\"]*virtual_keys\.zig\"\);", line)
        if m and m.group(1) != "vk":
            s.add(i, "vk-alias", "platform/virtual_keys.zig is imported as vk")
        m = re.match(r"^const slog = log\.Scoped\(\"(\w+)\"\);", line)
        if m:
            stem = path.split("/")[-1][:-4]
            scope = m.group(1)
            folders = path.split("/")[:-1]
            if scope != stem and stem not in scope and not any(f in scope or scope in f for f in folders):
                s.add(i, "log-scope", f"scope '{scope}': use the file stem, prefixed by its folder when ambiguous, or the feature's shared scope", True)

    # A fraction or a format string written out twice has to be kept in step by hand; log and status messages may repeat.
    floats = {}
    for i, code in enumerate(codes[:s.first_test]):
        for literal in re.findall(r"(?<![\w.])(\d+\.\d+)(?![\w.])", code):
            if float(literal) < 1 and literal not in ("0.5", "0.0"):
                floats.setdefault(literal, []).append(i)
    for literal, at in floats.items():
        if len(at) > 1:
            s.add(at[1], "repeated-number", f"{literal} also on line {at[0] + 1}: give it a named constant", True)
    formats = {}
    for i, line in enumerate(lines[:s.first_test]):
        if line.strip().startswith("//") or re.search(r"\b(slog\.\w+|status\.show|std\.debug\.print)\(", line):
            continue
        for literal in re.findall(r'"((?:\\.|[^"\\])*)"', line):
            if re.search(r"\{[^}]*\}", literal) and len(literal) >= 8 and re.search(r"[A-Za-z]{3}", re.sub(r"\\u\{\w+\}", "", literal)):
                formats.setdefault(literal, []).append(i)
    for literal, at in formats.items():
        if len(at) > 1:
            s.add(at[1], "repeated-format", f"\"{literal}\" also on line {at[0] + 1}: give it a named constant", True)


def check_comments(s):
    """§3: TODOs, section headers, and comments doing more than one short sentence's work."""
    for i, line in enumerate(s.lines):
        stripped = line.strip()
        if re.search(r"\b(TODO|FIXME|XXX)\b", line):
            s.add(i, "todo", "no TODO/FIXME in committed code")
        if re.match(r"//\s*(=|-|\*){3,}", stripped):
            s.add(i, "section-header", "no section-header comments")
        if stripped.startswith("///") and i > 0 and s.lines[i - 1].strip().startswith("///") and not DOC_ITEM.match(stripped):
            s.add(i, "doc-length", "a doc comment is one short sentence, on one line, or one `name`: line per parameter or member")
        if re.match(r"///\s*(Initializes|Initialises|Deinitializes|Creates a new)\b", stripped):
            s.add(i, "doc-restates", "a doc comment states a contract the signature can't, not what the function does", True)

        if stripped.startswith("///"):
            comment = stripped[3:]
        elif stripped.startswith("//") and not stripped.startswith("//!"):
            comment = stripped[2:]
        else:
            continue
        # Abbreviations aren't sentence breaks, and a comment quoting game text is data.
        comment = re.sub(r"\b(e\.g|i\.e|etc|vs)\.", "", comment)
        if comment.strip().startswith('"'):
            continue
        # STYLE.md's own contract tags may follow a description: "Owned; freed in deinit", "Borrows from X", "Caller holds mutex".
        comment = re.sub(r"\.\s+(Owned|Borrows|Caller|Logs every|Main thread|Worker thread|Copied into)\b.*$", ".", comment)
        if re.search(r"[a-z)`'\"]\.\s+[A-Z]", comment):
            s.add(i, "comment-sentences", "a comment is one short sentence", True)
        if len(comment.strip()) > MAX_COMMENT_LENGTH:
            s.add(i, "comment-length", f"over {MAX_COMMENT_LENGTH} characters: say less, or shrink what it documents", True)
        # Short tag lists like "Owned; freed in deinit; static." are contracts, not chained thoughts.
        if comment.count(";") >= 2:
            is_tag_list = len(comment.strip()) <= MAX_TAG_LIST_LENGTH and all(len(part.split()) <= MAX_TAG_WORDS for part in comment.split(";"))
            if not is_tag_list:
                s.add(i, "comment-clauses", "three clauses in one comment: shrink the signature or move facts onto fields", True)


def check_errors(s):
    """§4: giving up without logging, log message shape, and unchecked resource creation."""
    lines, codes = s.lines, s.codes
    for i, code in enumerate(codes):
        if "std.debug.print" in code and s.path != "log.zig":
            s.add(i, "debug-print", "log with slog; std.debug.print belongs in log.zig")
        if "@panic(" in code:
            s.add(i, "panic", "no @panic")
        if re.search(r"\borelse unreachable\b", code):
            s.add(i, "orelse-unreachable", "no orelse unreachable on a value from the OS, a file or a user")
        if re.search(r"\bcatch\s*\{\s*\}", code) or re.search(r"\bcatch\s+return\s*;", code):
            s.add(i, "bare-catch", "log before giving up, unless this is a teardown, logger or high-frequency formatting path")
        fallback = re.search(r"\bcatch\s+(null|false|true|-?\d+|\"\"|\.\w+|\w+)\s*[;,)]", code)
        if fallback and fallback.group(1) not in ("return", "continue", "break", "unreachable"):
            s.add(i, "catch-fallback", "a fallback after a failure is logged: catch |err| blk: { ... break :blk fallback; }", True)
        if re.search(r"_\s*=\s*win32\.(CreateWindowEx\w*|SetTimer|SetWindowsHookEx\w*|RegisterHotKey|CreateEvent\w*|CreateMutex\w*|CreateFile\w*|SetWinEventHook|setWinEventHook\w*)\(", code):
            s.add(i, "unchecked-create", "check and log a first-time resource creation")
        # A session Ref's append logs a failure and returns null, so the list may still be empty after it.
        if re.search(r"\b\w+\.append(?:String)?\(\"\"", code):
            for j in range(i + 1, min(i + 4, len(codes))):
                if re.search(r"\.items\.len - 1\b", codes[j]):
                    s.add(j, "append-last", "append can fail and leave the list empty: use the item it returns")
                    break

    for i, line in enumerate(lines):
        m = re.search(r"slog\.err\(\"([^\"]*)", line)
        if m and not m.group(1).startswith("Failed to"):
            s.add(i, "message", "an err message starts 'Failed to <verb>'", True)
        m = re.search(r"\bslog\.(debug|info|warn|err)\(\"((?:\\.|[^\"\\])*)\"", line)
        if not m:
            continue
        level, message = m.group(1), m.group(2)
        if message.endswith("."):
            s.add(i, "message-period", "log messages have no trailing period")
        if re.match(r"^[a-z]", message):
            s.add(i, "message-case", "log messages are sentence case")
        args = re.search(r"\.\{\s*([^{}]*?)\s*\}\s*\)\s*;", line)
        if not args:
            continue
        parts = [p.strip() for p in args.group(1).split(",") if p.strip()]
        if "err" in parts and not parts[-1].endswith("err"):
            s.add(i, "message-error-last", "put the error last")
        if level in ("warn", "err"):
            placeholders = re.findall(r"'?\{[^{}]*\}'?", message)
            for placeholder, arg in zip(placeholders, parts):
                if placeholder == "{s}" and re.search(r"(name|path|dir|url|title|file)\b", arg, re.I) and not re.search(r"@\w+Name|\w\(", arg):
                    s.add(i, "message-quote", f"quote '{arg}' in a warn/err message: '{{s}}'", True)


def check_idioms(s):
    """§5, §6 and §7: Self, receivers, unwrapping, bool parameters, unreachable, decl literals, anytype and pointer globals."""
    lines, codes = s.lines, s.codes
    type_fn_depth = []
    depth = 0
    for i, code in enumerate(codes):
        if re.search(r"\)\s*\??type\s*\{", code):
            type_fn_depth.append(depth)
        if re.search(r"\bconst Self = @This\(\);", code) and not type_fn_depth:
            s.add(i, "self-alias", "name the type instead of Self outside a type-returning function")
        depth += code.count("{") - code.count("}")
        while type_fn_depth and depth <= type_fn_depth[-1]:
            type_fn_depth.pop()
        if re.search(r"&\(\s*[\w.]+\s+orelse\b", code):
            s.add(i, "orelse-pointer", "unwrap with if (x) |*v| ... else, not &(x orelse ...)")
        split = re.search(r"\bvar (\w+) = std\.mem\.(?:split|tokenize)\w*\(", code)
        if split:
            # Only the iterator's first next(), before anything else has advanced it.
            for j in range(i, min(i + 4, len(codes))):
                later = codes[j] if j > i else code[split.end():]
                if re.search(r"\b" + split.group(1) + r"\.next\(\)\.\?", later):
                    s.add(j, "first-split", "a fresh split iterator's first part is .first(), which can't be null")
                    break
                if re.search(r"\b" + split.group(1) + r"\.next\(", later):
                    break
        if "HWND_TOP" in code and "HWND_TOPMOST" not in code:
            s.add(i, "hwnd-top", "HWND_TOP doesn't compile against HWND; use HWND_NOTOPMOST with SWP_NOZORDER")
        m = re.search(r"^\s*(?:var|const) (\w+) = ((?:std\.)?(?:\w+\.)*[A-Z]\w*)\.(init|empty)\b", code)
        if m and not re.search(r"\bcatch\b", statement_text(codes, i)):
            s.add(i, "decl-literal", f"'{m.group(1)}': write `{m.group(1)}: {m.group(2)} = .{m.group(3)}...` (§6)")
        if re.search(r"\bstd\.ArrayList\([^)]*\)\.init\(", code):
            s.add(i, "managed-list", "std.ArrayList is unmanaged: start from .empty and pass the allocator to each call")

    for name, start, end, signature in s.functions:
        sig = code_only(signature)
        if "callconv" not in sig and "extern" not in sig:
            params = re.findall(r"(\w+)\s*:\s*(\??bool)\b", sig.split("{", 1)[0])
            if len(params) >= 2:
                s.add(start, "bool-params", f"{name} takes {len(params)} bool parameters; use an options struct or enum")
        # unreachable states what rules the case out, on its function or the line above.
        has_doc = start > 0 and lines[start - 1].strip().startswith("///")
        for i in range(start, end + 1):
            is_formatting = re.search(r"\b(print|bufPrint|printSentinel|allocPrint)\w*\(", codes[i])
            if not re.search(r"(^|\s)unreachable;|=>\s*unreachable\b|\bcatch unreachable\b", codes[i]) or is_formatting:
                continue
            if not has_doc and not (i > 0 and lines[i - 1].strip().startswith("//")):
                s.add(i, "unreachable-doc", "say what rules this case out, in a /// on the function or a // above it", True)

    check_receivers(s)

    for i, line in enumerate(lines):
        if re.search(r"\bfn \w+\(", line) and "anytype" in line:
            names = [n for n in re.findall(r"(\w+):\s*anytype", line) if n not in SELF_EXPLAINING_ANYTYPE]
            doc = lines[i - 1] if i > 0 else ""
            if names and not doc.strip().startswith("///"):
                s.add(i, "anytype-doc", f"document the shape '{names[0]}: anytype' expects with a ///", True)
        if re.match(r"^(pub\s+)?var\s+g_\w+\s*:\s*\*[^=]*=\s*undefined", line) or re.match(r"^(pub\s+)?var\s+g_\w+\s*:\s*\?\*[\w.]+\s*=\s*undefined", line):
            s.add(i, "pointer-global", "a pointer global set at startup is ?*T = null")


def check_receivers(s):
    """§6: a *T method that never writes through self takes *const T, and one type's read-only methods agree (advisories)."""
    by_type = {}
    for name, start, end, signature in s.functions:
        m = re.search(r"\(self:\s*(\*const |\*)?([A-Z]\w*)", signature)
        if m:
            by_type.setdefault(m.group(2), []).append((name, start, end, m.group(1) == "*"))
    writes = [
        re.compile(r"self\.[\w.\[\]]+\s*(=|\+=|-=|\|=|&=|\*=|\+%=|-\|=)(?!=)"),
        re.compile(r"&self\.\w+"),
        re.compile(r"=\s*self\s*[,}]"),
        re.compile(r"[(,]\s*self\s*[,)]"),
        re.compile(r"\bself\.\*"),
    ]
    for type_name, methods in by_type.items():
        method_names = [m[0] for m in methods]
        mutating = set()
        changed = True
        while changed:
            changed = False
            for name, start, end, is_mutable in methods:
                if name in mutating:
                    continue
                body = "\n".join(s.codes[start + 1:end + 1])
                field_calls = re.findall(r"self\.\w+(?:\.\w+)*\.(\w+)\(", body)
                direct = any(p.search(body) for p in writes) or any(c not in READ_ONLY_CALLS for c in field_calls)
                calls_mutating = any(c in mutating or c not in method_names for c in re.findall(r"\bself\.(\w+)\(", body))
                if direct or calls_mutating:
                    mutating.add(name)
                    changed = True
        for name, start, end, is_mutable in methods:
            if is_mutable and name not in mutating and name not in ("deinit", "init", "run", "setGlobalInstance"):
                s.add(start, "receiver", f"{type_name}.{name} only reads self; take *const {type_name}", True)

    receivers = {}
    for i, line in enumerate(s.lines):
        m = re.search(r"\bfn \w+\(self:\s*(\*const |\*)?([A-Z]\w*)\b", line)
        if m and m.group(1) != "*":
            receivers.setdefault(m.group(2), {}).setdefault("*const" if m.group(1) else "value", i)
    for type_name, kinds in receivers.items():
        if len(kinds) > 1:
            s.add(max(kinds.values()), "receiver-mix", f"{type_name}'s read-only methods mix self: {type_name} and self: *const {type_name}", True)


def check_win32(s):
    """§8: where Win32 declarations live, win32.zig not logging, and window procedures' calling convention."""
    if s.path not in EXTERN_FILES:
        for i, code in enumerate(s.codes):
            if re.search(r"\bextern\s+(\"\w*\"\s+)?fn\b", code):
                s.add(i, "extern", "Win32 declarations live in platform/win32.zig")
    if s.path == "platform/win32.zig":
        for i, code in enumerate(s.codes):
            if re.search(r"\bslog\.", code):
                s.add(i, "win32-logging", "win32.zig doesn't log; its helpers report failure through their return value")
    for i, line in enumerate(s.lines):
        if re.search(r"\bfn \w+\(\s*hwnd:\s*(win32\.)?HWND,\s*msg:\s*(win32\.)?UINT,\s*wParam", line) and "callconv(.c)" not in line:
            s.add(i, "callconv", "a window procedure uses callconv(.c)")


def check_tests(s, tests_imports):
    """§10: tests run under zig build test, pure modules have them, and each is a named claim on the testing allocator without I/O."""
    if s.has_tests and s.path not in tests_imports and s.path != "tests.zig":
        s.add(0, "tests-listed", "this file has tests but tests.zig doesn't import it, so they never run")
    if s.lines and "no I/O" in s.lines[0] and not s.has_tests:
        s.add(0, "pure-untested", "a module whose header says 'no I/O' carries test blocks")
    for start, end in block_spans(s.lines, r"^test \""):
        name = re.match(r"^test \"([^\"]*)\"", s.lines[start]).group(1)
        if " " not in name.strip():
            s.add(start, "test-name", "name a test as a claim", True)
        body = "\n".join(s.codes[start + 1:end])
        if re.search(r"\b(page_allocator|GeneralPurposeAllocator|DebugAllocator|c_allocator)\b", body):
            s.add(start, "test-allocator", "tests use std.testing.allocator, so leaks fail them")
        if re.search(r"\bwin32\.[A-Z]\w*\(|\bstd\.fs\.|\bIo\.Dir\.|\bcwd\(\)", body):
            s.add(start, "test-io", "test code doesn't touch Win32, the filesystem or globals")


def check_file(path, text, tests_imports, allowed):
    """The findings for one file, in line order."""
    s = Source(path, text, allowed)
    check_layout(s)
    check_names(s)
    check_comments(s)
    check_errors(s)
    check_idioms(s)
    check_win32(s)
    check_tests(s, tests_imports)
    return [finding for _, finding in sorted(s.findings, key=lambda entry: entry[0])]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--advisory", action="store_true", help="also report heuristics a reviewer has to judge")
    parser.add_argument("paths", nargs="*", help="files or folders under src/ (default: all of src/)")
    args = parser.parse_args()

    targets = []
    for root in [os.path.abspath(p) for p in args.paths] or [SRC]:
        if os.path.isfile(root):
            targets.append(root)
        else:
            for directory, _, names in os.walk(root):
                targets += [os.path.join(directory, n) for n in names if n.endswith(".zig")]

    tests_imports = set(re.findall(r"@import\(\"([^\"]+)\"\)", read_text(os.path.join(SRC, "tests.zig"))))
    allowed = [tuple(entry.split(" ", 2)) for entry in allowlist("style_check")]
    allowed = [entry for entry in allowed if len(entry) == 3]

    findings = []
    for target in sorted(targets):
        findings += check_file(src_path(target), read_text(target), tests_imports, allowed)
    return report(findings, args.advisory)


if __name__ == "__main__":
    sys.exit(main())
