"""Checks docs/CONFIGURATION.md against the profile and global settings structs in src/config.

Usage, from the repo root:
    python tools/checks/config_docs.py

A profile section is a Config field holding a struct, or a list of them, and is documented under its own
`### name` heading; Config's plain fields go under `### Top level`, and GlobalConfig's under
`## Global settings`. A `### a.b` heading documents a.b's struct, and a `**`a.<Type>`**` line inside a
section starts rows for the struct field a holds (a map's MapValue). Rows name keys in backticks in their
first cell. Errors make the exit code 1. A deliberate exception goes in tools/checks/allow/config_docs.txt
as `<rule> <key path, e.g. thumbnail.width, or *>  # reason`. An entry that no longer matches anything is an error too.

Rules:
    undocumented-section  a Config field holding a struct with no `### field` heading
    undocumented-key      a saved field with no row in its section's table
    stale-key             a row naming a field its struct doesn't have
    stale-section         a heading that names no Config field
    missing-contents      a profile heading the Contents list doesn't link to

Fields named in a struct's runtime_fields aren't saved, so they're skipped. Only sections the doc gives
a heading or subheading are checked field by field: a field holding a small struct (`{x, y}`) is
documented by its own row.
"""
import argparse
import os
import re
import sys

from lang_keys import matching, tokenize
from shared import REPO, SRC, Finding, allowlist, read_text, report, stale_allowlist

DOC = os.path.join(REPO, "docs", "CONFIGURATION.md")


class Struct:
    def __init__(self, name, path):
        self.name, self.path = name, path
        self.fields = {}  # name -> type tokens
        self.runtime_fields = set()
        self.map_value = None  # the struct a custom Wire map holds, from `MapValue = X.Wire`


def parse_structs(path, text):
    """Every `const Name = struct { ... }` in a file, nested ones included."""
    tokens = tokenize(text)
    structs = []
    for k in range(len(tokens) - 4):
        if tokens[k].text == "const" and tokens[k + 1].kind == "ident" and tokens[k + 2].kind == "=" and tokens[k + 3].text == "struct" and tokens[k + 4].kind == "{":
            struct = Struct(tokens[k + 1].text, path)
            open_brace, close = k + 4, matching(tokens, k + 4)
            j, depth, previous = open_brace + 1, 0, "{"
            while j < close:
                token = tokens[j]
                if depth == 0 and token.kind == "ident" and tokens[j + 1].kind == ":" and previous in ("{", ",", ";", "}"):
                    end = j + 2
                    while end < close and not (tokens[end].kind in (",", "=") and depth_between(tokens, j + 2, end) == 0):
                        end = matching(tokens, end) + 1 if tokens[end].kind in "([{" else end + 1
                    struct.fields[token.text] = tokens[j + 2:end]
                if depth == 0 and token.text == "runtime_fields" and tokens[j + 1].kind == "=":
                    struct.runtime_fields = {t.text for t in tokens[j + 2:matching(tokens, j + 3) + 1] if t.kind == "string"}
                if token.text == "MapValue" and tokens[j + 1].kind == "=" and tokens[j + 2].kind == "ident":
                    struct.map_value = tokens[j + 2].text
                if token.kind in "([{":
                    depth += 1
                elif token.kind in ")]}":
                    depth -= 1
                if depth == 0:
                    previous = token.kind
                j += 1
            structs.append(struct)
    return structs


def depth_between(tokens, start, end):
    depth = 0
    for t in tokens[start:end]:
        if t.kind in "([{":
            depth += 1
        elif t.kind in ")]}":
            depth -= 1
    return depth


def held_struct(type_tokens, structs):
    """The struct a field's type holds, through ?, [], pointers and std.ArrayList(...), or None."""
    names = [t.text for t in type_tokens if t.kind == "ident" and t.text not in ("std", "ArrayList", "const")]
    for name in reversed(names):
        if name in structs and name != "Wire":
            return structs[name]
    return None


def parse_doc(text, names_fields):
    """scope -> {key path: line}, where scope is "global", "top" or a heading's path, extended by a `**`sub`**` path.

    names_fields(scope, name) says whether name is a field of the struct a scope documents. The headings
    map also holds the lines of `## Profile`, `### Top level` and `## Global settings`, as <profile>, <top> and <global>.
    """
    scopes, headings, contents = {}, {}, set()
    part, scope, base, is_key_table = None, None, None, False
    for number, line in enumerate(text.split("\n"), 1):
        if line.startswith("## "):
            part = line[3:].strip()
            scope = base = "global" if part == "Global settings" else None
            if base:
                headings["<global>"] = number
            if part == "Profile":
                headings["<profile>"] = number
            continue
        if line.startswith("### ") and part == "Profile":
            title = line[4:].strip()
            scope = base = "top" if title == "Top level" else title
            headings["<top>" if title == "Top level" else title] = number
            continue
        if part == "Contents":
            contents |= set(re.findall(r"\]\(#([\w-]+)\)", line))
        if not base:
            continue
        sub = re.match(r"^\*\*`([\w.]+)(?:\.<\w+>)?`\*\*\s*$", line)
        if sub:
            scope = join(base, sub.group(1))
            continue
        labelled = re.match(r"^\*\*[^*`]+\*\*:?(.*)$", line)
        if labelled:
            # "**Per-state overrides**: `active`, `inactive`" names fields that share the table below it.
            names = re.findall(r"`(\w+)`", re.split(r"\.\s", labelled.group(1), maxsplit=1)[0])
            if names and all(names_fields(base, name) for name in names):
                for name in names:
                    scopes.setdefault(base, {})[name] = number
                scope = join(base, names[0])
            else:
                scope = base
            continue
        header = re.match(r"^\|\s*([^|`]+?)\s*\|", line)
        if header and not line.startswith("|---"):
            is_key_table = header.group(1) == "Key"
            continue
        row = re.match(r"^\|\s*(`[^|]*)\|", line)
        if row and scope and is_key_table:
            previous = None
            for key in re.findall(r"`([^`]+)`", row.group(1)):
                key = key.replace("[]", "")
                # `extraRegionId1` … `3` stands for each numbered field.
                stem = re.match(r"^(\D\w*?)(\d+)$", previous or "")
                if key.isdigit() and stem:
                    for i in range(int(stem.group(2)), int(key) + 1):
                        scopes.setdefault(scope, {})[f"{stem.group(1)}{i}"] = number
                else:
                    scopes.setdefault(scope, {})[key] = number
                previous = key
    return scopes, headings, contents


def join(base, path):
    return path if base in ("top", "global") else f"{base}.{path}"


def main():
    argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter).parse_args()
    structs = {}
    for folder in (os.path.join(SRC, "config"),):
        for n in sorted(os.listdir(folder)):
            if n.endswith(".zig"):
                for struct in parse_structs(n, read_text(os.path.join(folder, n))):
                    structs.setdefault(struct.name, struct)
    for struct in parse_structs("config.zig", read_text(os.path.join(SRC, "config.zig"))):
        structs.setdefault(struct.name, struct)

    allowed = [(entry, *entry.partition(" ")[::2]) for entry in allowlist("config_docs")]
    findings, used = [], set()

    def add(rule, where, key, message):
        allowing = next((entry for entry, r, k in allowed if r == rule and (k == "*" or k == key)), None)
        if allowing is None:
            findings.append(Finding(f"docs/CONFIGURATION.md:{where}", rule, message))
        else:
            used.add(allowing)

    def saved_fields(struct):
        return {name: t for name, t in struct.fields.items() if name not in struct.runtime_fields}

    def compare(struct, scope, prefix, heading_line):
        rows = scopes.get(scope, {})
        fields = saved_fields(struct)
        for name in fields:
            if name not in rows and f"{prefix}{name}" not in headings:
                add("undocumented-key", heading_line, f"{prefix}{name}", f"'{prefix}{name}' has no row")
        for key, line in rows.items():
            first, _, rest = key.partition(".")
            if first not in fields:
                add("stale-key", line, f"{prefix}{key}", f"'{prefix}{key}' isn't a field of {struct.name}")
            elif rest:
                inner = held_struct(fields[first], structs)
                if inner and rest.split(".")[0] not in saved_fields(inner):
                    add("stale-key", line, f"{prefix}{key}", f"'{prefix}{key}' isn't a field of {inner.name}")

    def resolve(path):
        """The struct a dotted path from Config holds, following map values."""
        struct = structs["Config"]
        for part in path.split("."):
            field = saved_fields(struct).get(part)
            struct = held_struct(field, structs) if field is not None else None
            if struct is None:
                return None
            if struct.map_value and struct.map_value in structs:
                struct = structs[struct.map_value]
        return struct

    def names_fields(scope, name):
        struct = {"global": structs.get("GlobalConfig"), "top": structs["Config"]}.get(scope) or resolve(scope)
        return struct is not None and name in saved_fields(struct)

    scopes, headings, contents = parse_doc(read_text(DOC), names_fields)
    profile_line = headings.pop("<profile>", 1)
    top_line = headings.pop("<top>", profile_line)
    global_line = headings.pop("<global>", 1)

    config = structs["Config"]
    top_fields = Struct("Config", config.path)
    top_fields.runtime_fields = config.runtime_fields
    for name, type_tokens in saved_fields(config).items():
        if held_struct(type_tokens, structs):
            if name not in headings:
                add("undocumented-section", profile_line, name, f"'{name}' has no '### {name}' section")
        else:
            top_fields.fields[name] = type_tokens
    compare(top_fields, "top", "", top_line)

    for title, line in headings.items():
        struct = resolve(title)
        if struct is None:
            add("stale-section", line, title, f"'### {title}' names no Config field")
            continue
        if title.lower().replace(".", "") not in contents:
            add("missing-contents", line, title, f"'{title}' isn't linked from Contents")
        compare(struct, title, f"{title}.", line)
        for scope in scopes:
            if scope.startswith(title + ".") and scope[len(title) + 1:] not in headings:
                inner = resolve(scope)
                if inner is None:
                    add("stale-section", line, scope, f"'{scope}' names no field")
                else:
                    compare(inner, scope, f"{scope}.", line)

    if "GlobalConfig" in structs:
        compare(structs["GlobalConfig"], "global", "", global_line)

    findings += stale_allowlist("config_docs", used)
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
