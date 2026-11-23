"""Checks src/lang/en.json against the strings the code translates, and each language file against en.json.

Usage, from the repo root:
    python tools/checks/lang_keys.py [--advisory]

English text is the key: lang.text("Save") looks "Save" up in the chosen language's file, and a string
missing there shows in English. Errors make the exit code 1. A deliberate exception goes in
tools/checks/allow/lang_keys.txt as `<rule> <the whole text, part of the src/ path, or *>  # reason`.

Rules:
    missing-key     a literal the code translates that en.json lacks, so no language can translate it
    unused-key      an en.json key no literal, enum tag (as enumLabels spells it) or ++ join produces
    untranslated    an en.json key a language file lacks
    raw-text        (advisory) a literal drawn as `.content = "..."` in dialog/ or drag/, never translated

A literal counts as translated when it reaches lang.text, lang.format or lang.write: directly, or through
any chain of parameters (and for-loop captures over them) that ends there. Calls are resolved by import
alias, then by name and argument count, so a helper sharing its name and arity with a translating one
can be mistaken for it. Text built at runtime or stored in a struct field before translation isn't seen.
"""
import argparse
import json
import os
import re
import sys

import dead_code
from shared import SRC, Finding, allowlist, read_text, report, zig_files

LANG = os.path.join(SRC, "lang")
UI_FOLDERS = ("dialog/", "drag/")
SINKS = {"text": 0, "format": 1, "write": 1}  # lang.<fn> -> the argument holding the English text

TOKEN = re.compile(r"""
    (?P<comment>//[^\n]*)
  | (?P<multiline>(?:[ \t]*\\\\[^\n]*\n?)+)
  | (?P<string>"(?:\\.|[^"\\\n])*")
  | (?P<char>'(?:\\.|[^'\\\n])+')
  | (?P<ident>@?[A-Za-z_]\w*)
  | (?P<number>\d[\w.]*)
  | (?P<op>\+\+|=>|==|!=|<=|>=|\.\.|.)
""", re.VERBOSE | re.DOTALL)


class Token:
    __slots__ = ("kind", "text", "line")

    def __init__(self, kind, text, line):
        self.kind, self.text, self.line = kind, text, line


def unescape(literal):
    """A Zig string literal's value."""
    body = literal[1:-1]
    escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}

    def one(m):
        code = m.group(1)
        if code[0] == "x":
            return chr(int(code[1:], 16))
        if code[0] == "u":
            return chr(int(code[2:-1], 16))
        return escapes.get(code, "\\" + code)

    return re.sub(r"\\(x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)", one, body)


def tokenize(text):
    tokens, line = [], 1
    for m in TOKEN.finditer(text):
        kind = m.lastgroup
        value = m.group(kind)
        if kind == "string":
            tokens.append(Token("string", unescape(value), line))
        elif kind not in ("comment", "multiline") and not value.isspace():
            tokens.append(Token(kind if kind != "op" else value, value, line))
        line += value.count("\n")
    return tokens


def matching(tokens, start):
    """Index of the bracket closing tokens[start]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    depth = 0
    for k in range(start, len(tokens)):
        if tokens[k].kind in pairs:
            depth += 1
        elif tokens[k].kind in pairs.values():
            depth -= 1
            if depth == 0:
                return k
    return len(tokens) - 1


def split_top(tokens, start, end):
    """The comma-separated pieces of tokens[start:end], as (from, to) ranges."""
    pieces, depth, begin = [], 0, start
    for k in range(start, end):
        kind = tokens[k].kind
        if kind in "([{":
            depth += 1
        elif kind in ")]}":
            depth -= 1
        elif kind == "," and depth == 0:
            pieces.append((begin, k))
            begin = k + 1
    if begin < end:
        pieces.append((begin, end))
    return pieces


class Function:
    def __init__(self, path, name, params, body):
        self.path, self.name, self.params, self.body = path, name, params, body
        self.translating = set()  # indices into params


class Call:
    def __init__(self, path, function, receiver, name, args, tokens, line):
        self.path, self.function, self.receiver, self.name, self.args, self.tokens, self.line = path, function, receiver, name, args, tokens, line

    def arg_strings(self, index):
        """The literals an argument is: one string, or every string of a `.{ ... }` list of them."""
        start, end = self.args[index]
        pieces = [t for t in self.tokens[start:end] if t.kind not in ("&", ".", "{", "}", ",")]
        if pieces and all(t.kind == "string" for t in pieces) and (end - start == 1 or self.tokens[start].kind in ("&", ".")):
            return [t.text for t in pieces]
        return []

    def arg_names(self, index):
        start, end = self.args[index]
        return {t.text for t in self.tokens[start:end] if t.kind == "ident"}


class File:
    def __init__(self, path, text):
        self.path = path
        self.tokens = tokenize(text)
        self.functions = []
        self.calls = []
        self.aliases = {}  # import alias -> imported file
        self.scan()

    def scan(self):
        tokens = self.tokens
        for k, token in enumerate(tokens):
            if token.text == "@import" and k >= 3 and tokens[k - 1].kind == "=" and tokens[k + 2].kind == "string":
                target = os.path.normpath(os.path.join(os.path.dirname(self.path), tokens[k + 2].text)).replace(os.sep, "/")
                self.aliases[tokens[k - 2].text] = target
            if token.text == "fn" and k + 2 < len(tokens) and tokens[k + 1].kind == "ident" and tokens[k + 2].kind == "(":
                close = matching(tokens, k + 2)
                params = []
                for begin, end in split_top(tokens, k + 3, close):
                    names = [t.text for t in tokens[begin:end] if t.kind == "ident" and t.text not in ("comptime", "noalias")]
                    params.append(names[0] if names else "")
                body = close + 1
                while body < len(tokens) and tokens[body].kind not in ("{", ";"):
                    body = matching(tokens, body) + 1 if tokens[body].kind in "([" else body + 1
                if body < len(tokens) and tokens[body].kind == "{":
                    self.functions.append(Function(self.path, tokens[k + 1].text, params, (body, matching(tokens, body))))
        for function in self.functions:
            self.scan_calls(function)

    def scan_calls(self, function):
        tokens = self.tokens
        start, end = function.body
        function.aliases = {}  # capture -> the parameter it iterates over
        for k in range(start, end):
            token = tokens[k]
            if token.text == "for" and tokens[k + 1].kind == "(":
                close = matching(tokens, k + 1)
                if close + 1 < end and tokens[close + 1].kind == "|":
                    bar = next(j for j in range(close + 2, end) if tokens[j].kind == "|")
                    captures = [[t.text for t in tokens[b:e] if t.kind == "ident"] for b, e in split_top(tokens, close + 2, bar)]
                    for (b, e), names in zip(split_top(tokens, k + 2, close), captures):
                        if e - b == 1 and tokens[b].text in function.params and names:
                            function.aliases[names[0]] = tokens[b].text
            if token.kind == "ident" and not token.text.startswith("@") and tokens[k + 1].kind == "(" and tokens[k - 1].text != "fn":
                receiver = tokens[k - 2].text if tokens[k - 1].kind == "." and tokens[k - 2].kind == "ident" else None
                close = matching(tokens, k + 1)
                self.calls.append(Call(self.path, function, receiver, token.text, split_top(tokens, k + 2, close), tokens, token.line))


def spell_out(tag):
    """labels.zig's spellOut: "TopLeft" -> "Top Left", "EVEFocus" -> "EVE Focus", "next_profile" -> "Next profile"."""
    out = tag[0].upper()
    for i in range(1, len(tag)):
        c, previous = tag[i], tag[i - 1]
        starts_word = previous.islower() or (previous.isupper() and i + 1 < len(tag) and tag[i + 1].islower())
        if c == "_":
            out += " "
        elif c.isupper() and starts_word:
            out += " " + c
        else:
            out += c
    return out


def resolve(files, call, by_name):
    """The functions a call may reach, with the offset from its argument index to their parameter index."""
    if call.receiver and call.receiver in files[call.path].aliases:
        target = files.get(files[call.path].aliases[call.receiver])
        return [(f, 0) for f in (target.functions if target else []) if f.name == call.name and len(f.params) == len(call.args)]
    if call.receiver is None:
        return [(f, 0) for f in files[call.path].functions if f.name == call.name and len(f.params) == len(call.args)]
    return [(f, 1) for f in by_name.get(call.name, []) if len(f.params) == len(call.args) + 1 and f.params[0] == "self"] + \
           [(f, 0) for f in by_name.get(call.name, []) if len(f.params) == len(call.args) and (not f.params or f.params[0] != "self")]


def translated_literals(files):
    """(text, path, line) for every literal that reaches a lang sink."""
    by_name = {}
    for file in files.values():
        for function in file.functions:
            by_name.setdefault(function.name, []).append(function)

    def param_indices(function, names):
        names = names | {function.aliases[n] for n in names if n in function.aliases}
        return {i for i, p in enumerate(function.params) if p in names}

    changed = True
    while changed:
        changed = False
        for file in files.values():
            for call in file.calls:
                for index in sink_args(files, call, by_name):
                    if index >= len(call.args):
                        continue
                    new = param_indices(call.function, call.arg_names(index)) - call.function.translating
                    if new:
                        call.function.translating |= new
                        changed = True

    found = []
    for file in files.values():
        for call in file.calls:
            for index in sink_args(files, call, by_name):
                if index < len(call.args):
                    found += [(text, call.path, call.line) for text in call.arg_strings(index)]
    return found


def sink_args(files, call, by_name):
    """The argument indices of a call that end up translated."""
    if call.receiver == "lang" and call.name in SINKS:
        return {SINKS[call.name]}
    indices = set()
    for function, offset in resolve(files, call, by_name):
        indices |= {i - offset for i in function.translating if i - offset >= 0}
    return indices


def file_consts(file):
    """name -> value for the file's `const NAME = "...";`, `const NAME: T = 16;` and `const NAME = std.fmt.comptimePrint("...", .{...});`."""
    consts, tokens = {}, file.tokens
    for k, token in enumerate(tokens):
        if token.text != "const" or k + 2 >= len(tokens) or tokens[k + 1].kind != "ident":
            continue
        equals = k + 2
        if tokens[equals].kind == ":":
            equals = next((j for j in range(k + 3, min(k + 8, len(tokens))) if tokens[j].kind in ("=", ";")), k + 2)
        if tokens[equals].kind != "=" or equals + 2 >= len(tokens):
            continue
        value = tokens[equals + 1]
        if value.kind in ("string", "number") and tokens[equals + 2].kind == ";":
            consts[tokens[k + 1].text] = value.text
        elif value.text == "std":
            call = next((j for j in range(equals + 1, min(equals + 7, len(tokens))) if tokens[j].text == "comptimePrint"), None)
            if call is not None and tokens[call + 2].kind == "string":
                close = matching(tokens, call + 1)
                consts[tokens[k + 1].text] = ("print", tokens[call + 2].text, tokens[call + 3:close])
    return consts


def joined_strings(files):
    """Values of `"a" ++ NAME ++ "b"` joins, with NAME (or alias.NAME) a string const or a comptimePrint of number consts."""
    consts = {path: file_consts(file) for path, file in files.items()}

    def lookup(path, qualified):
        """The value of a [alias.]NAME as seen from path, or None."""
        if len(qualified) == 2:
            path = files[path].aliases.get(qualified[0])
            if path not in consts:
                return None
        held = consts[path].get(qualified[-1])
        if isinstance(held, tuple):
            _, template, arguments = held
            names, numbers = [], []
            for t in arguments:
                if t.kind == "ident":
                    names.append(t.text)
                elif t.kind in (",", "}") and names:
                    numbers.append(lookup(path, names[-2:]))
                    names = []
            if any(n is None for n in numbers):
                return None
            numbers = iter(numbers)
            return re.sub(r"\{d\}", lambda _: next(numbers, "{d}"), template)
        return held

    joins = set()
    for file in files.values():
        tokens = file.tokens
        for k, token in enumerate(tokens):
            if token.kind != "++":
                continue
            left = k - 1
            while left >= 2 and tokens[left - 1].kind == "++":
                left -= 2
            if left != k - 1:
                continue
            parts, j = [], left
            while j < len(tokens):
                piece = tokens[j]
                if piece.kind == "string":
                    parts.append(piece.text)
                elif piece.kind == "ident":
                    qualified = [piece.text]
                    while j + 2 < len(tokens) and tokens[j + 1].kind == "." and tokens[j + 2].kind == "ident":
                        j += 2
                        qualified.append(tokens[j].text)
                    resolved = lookup(file.path, qualified[-2:])
                    if resolved is None:
                        break
                    parts.append(resolved)
                else:
                    break
                if j + 1 < len(tokens) and tokens[j + 1].kind == "++":
                    j += 2
                else:
                    joins.add("".join(parts))
                    break
    return joins


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--advisory", action="store_true", help="also report heuristics a reviewer has to judge")
    args = parser.parse_args()

    files, sources = {}, {}
    for path, text in zig_files().items():
        files[path] = File(path, text)
        sources[path] = dead_code.Source(path, text)

    english = json.loads(read_text(os.path.join(LANG, "en.json")))
    entries = [entry.partition(" ")[::2] for entry in allowlist("lang_keys")]
    findings = []  # (rule, location, message, text matched by the allowlist, is_advisory)

    translated = translated_literals(files)
    for text, path, line in sorted(set(translated), key=lambda t: (t[1], t[2])):
        if text not in english and re.search(r"[A-Za-z]", text):
            findings.append(("missing-key", f"src/{path}:{line}", f"'{text}' is translated but missing from en.json", text, False))

    produced = {t.text for f in files.values() if not f.path.startswith("lang/") for t in f.tokens if t.kind == "string"}
    produced |= {spell_out(m[0]) for s in sources.values() for m in s.members if m[3] == "enum"}
    produced |= joined_strings(files)
    for key in english:
        if key not in produced:
            findings.append(("unused-key", "src/lang/en.json", f"'{key}' is produced by nothing in src/", key, False))

    catalogs = {n[:-5]: json.loads(read_text(os.path.join(LANG, n))) for n in sorted(os.listdir(LANG)) if n.endswith(".json") and n != "en.json"}
    for key in english:
        lacking = [language for language, catalog in catalogs.items() if key not in catalog]
        if lacking:
            findings.append(("untranslated", "src/lang/en.json", f"'{key}' has no translation in {', '.join(lacking)}", key, False))

    for file in files.values():
        if not file.path.startswith(UI_FOLDERS):
            continue
        tokens = file.tokens
        for k in range(len(tokens) - 3):
            if tokens[k].kind == "." and tokens[k + 1].text == "content" and tokens[k + 2].kind == "=" and tokens[k + 3].kind == "string":
                text = tokens[k + 3].text
                if re.search(r"[A-Za-z]{2}", text):
                    findings.append(("raw-text", f"src/{file.path}:{tokens[k].line}", f"'{text}' is drawn without lang.text", text, True))

    kept = [Finding(location, rule, message, is_advisory) for rule, location, message, text, is_advisory in findings
            if not any(r == rule and (t == "*" or t == text or t in location) for r, t in entries)]
    return report(kept, args.advisory)


if __name__ == "__main__":
    sys.exit(main())
