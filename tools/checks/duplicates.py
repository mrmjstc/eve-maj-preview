"""Finds runs of duplicated code across src/ by comparing token sequences, so formatting and comments don't hide a copy.

Usage, from the repo root:
    python tools/checks/duplicates.py [--renamed] [--min-tokens N] [--top N] [--tests] [path ...]

Exact mode (the default) finds copy-paste. --renamed treats every identifier as ID and every literal as LIT,
so it also finds the same code with different names, at the cost of more noise. Paths only limit which
matches are reported: a match is shown if either side is in one of them.

Test blocks, `extern` function declarations, top-level imports and list-like runs are skipped (--tests keeps the tests). A deliberate repeat
goes in tools/checks/allow/duplicates.txt as `<path glob> <text in the match, or *>  # reason`; a match is
dropped once both of its sides are covered by entries. Findings make the exit code 1.

Same shape isn't proof of duplication: two functions that do one job differently aren't found, and a long
run of similar declarations (a switch mapping enums to strings) can match without being worth merging.
"""
import argparse
import fnmatch
import os
import re
import sys
from collections import defaultdict

from shared import allowlist, src_path, zig_files

# Renamed matching erases names, so it needs a longer run before a match means anything.
EXACT_MIN_TOKENS = 60
RENAMED_MIN_TOKENS = 100
# A run repeating a pattern this many tokens long or shorter is a list, not copied logic.
MAX_LIST_PERIOD = 40

TOKEN = re.compile(
    r"""(?P<skip>[ \t\r\n]+|//[^\n]*)
      | (?P<string>\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])+')
      | (?P<number>0[xX][0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?\d+)?|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)
      | (?P<name>@"(?:\\.|[^"\\])*"|@?[A-Za-z_][A-Za-z0-9_]*)
      | (?P<symbol>\.\.\.|\.\.|<<=|>>=|\+%=|-%=|\*%=|\+\|=|-\|=|\*\|=|<<\||\+\+|\*\*|=>|==|!=|<=|>=|<<|>>|\+=|-=|\*=|/=|%=|&=|\|=|\^=|\+%|-%|\*%|\+\||-\||\*\||\|\||\.\*|\.\?|[-+*/%=<>!&|^~?:;,.(){}\[\]])
      | (?P<other>.)""",
    re.VERBOSE,
)
KEYWORDS = {
    "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch", "comptime",
    "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline",
    "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "linksection",
    "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "var", "volatile", "while",
    "true", "false", "null", "undefined", "void", "bool", "type", "anyerror", "noreturn",
}


class Token:
    __slots__ = ("text", "line", "kind")

    def __init__(self, text, line, kind):
        self.text, self.line, self.kind = text, line, kind


def tokenize(text):
    tokens = []
    line = 1
    for match in TOKEN.finditer(text):
        kind = match.lastgroup
        value = match.group()
        if kind != "skip":
            tokens.append(Token(value, line, kind))
        line += value.count("\n")
    return tokens


def skip_matching(tokens, index, opener, closer):
    """The index just past the `closer` matching the `opener` at or after `index`."""
    while index < len(tokens) and tokens[index].text != opener:
        index += 1
    depth = 0
    while index < len(tokens):
        if tokens[index].text == opener:
            depth += 1
        elif tokens[index].text == closer:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return index


def strip_noise(tokens, keep_tests):
    """Drops test blocks, `extern` fn declarations and top-level imports, which repeat by nature."""
    kept = []
    index = 0
    depth = 0
    while index < len(tokens):
        token = tokens[index]
        following = tokens[index + 1].text if index + 1 < len(tokens) else ""
        if depth == 0 and token.text == "test" and not keep_tests:
            index = skip_matching(tokens, index, "{", "}")
            continue
        if depth == 0 and token.text == "const" and index + 3 < len(tokens) and tokens[index + 3].text == "@import":
            while index < len(tokens) and tokens[index].text != ";":
                index += 1
            index += 1
            continue
        if token.text == "extern" and (following == "fn" or following.startswith('"')):
            while index < len(tokens) and tokens[index].text != ";":
                index += 1
            index += 1
            # A `pub` already kept belongs to the declaration just dropped.
            if kept and kept[-1].text == "pub":
                kept.pop()
            continue
        if token.text == "{":
            depth += 1
        elif token.text == "}":
            depth -= 1
        kept.append(token)
        index += 1
    return kept


def normalized(token, is_renamed):
    if not is_renamed:
        return token.text
    if token.kind == "name" and token.text not in KEYWORDS and not token.text.startswith("@"):
        return "ID"
    if token.kind in ("string", "number"):
        return "LIT"
    return token.text


def load_files(texts, keep_tests, is_renamed):
    """path -> (tokens, the keys matching compares), for each file's text."""
    files = {}
    for path, text in texts.items():
        tokens = strip_noise(tokenize(text), keep_tests)
        files[path] = (tokens, [normalized(token, is_renamed) for token in tokens])
    return files


def is_list_like(keys, start, length):
    """Whether the run repeats a short pattern (a field list, a key table), which matches itself shifted along."""
    run = keys[start:start + length]
    for period in range(1, min(MAX_LIST_PERIOD, length // 3) + 1):
        if run[period:] == run[:-period]:
            return True
    return False


def find_matches(files, min_tokens):
    """Maximal matching runs of at least `min_tokens`, as (length, (path, start), (path, start)), longest first."""
    windows = defaultdict(list)
    for path, (_, keys) in files.items():
        for start in range(len(keys) - min_tokens + 1):
            windows[hash(tuple(keys[start:start + min_tokens]))].append((path, start))

    matches = []
    for places in windows.values():
        if len(places) < 2:
            continue
        for first_index, first in enumerate(places):
            for second in places[first_index + 1:]:
                first_keys, second_keys = files[first[0]][1], files[second[0]][1]
                first_start, second_start = first[1], second[1]
                # Only report a run from its first token, not from every token inside it.
                if first_start > 0 and second_start > 0 and first_keys[first_start - 1] == second_keys[second_start - 1]:
                    continue
                length = 0
                while (first_start + length < len(first_keys) and second_start + length < len(second_keys)
                       and first_keys[first_start + length] == second_keys[second_start + length]):
                    if first[0] == second[0] and first_start + length >= second_start:
                        break
                    length += 1
                if length >= min_tokens and not is_list_like(first_keys, first_start, length):
                    matches.append((length, first, second))
    matches.sort(key=lambda match: (-match[0], match[1], match[2]))
    return matches


def line_span(files, place, length):
    tokens = files[place[0]][0]
    return tokens[place[1]].line, tokens[place[1] + length - 1].line


def is_covered(entries, path, lines, first_line, last_line):
    for glob, text in entries:
        if not fnmatch.fnmatch(path, glob):
            continue
        if text == "*" or any(text in line for line in lines[first_line - 1:last_line]):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--renamed", action="store_true", help="match code that differs only in names and literals")
    parser.add_argument("--min-tokens", type=int, help="shortest run reported (default 60, or 100 with --renamed)")
    parser.add_argument("--top", type=int, default=40, help="most matches printed (default 40, 0 for all)")
    parser.add_argument("--tests", action="store_true", help="include test blocks")
    parser.add_argument("paths", nargs="*", help="only report matches with a side in these files")
    args = parser.parse_args()
    min_tokens = args.min_tokens or (RENAMED_MIN_TOKENS if args.renamed else EXACT_MIN_TOKENS)

    texts = zig_files()
    files = load_files(texts, args.tests, args.renamed)
    wanted = {src_path(os.path.abspath(path)) for path in args.paths}
    entries = [(path, text.strip() or "*") for path, _, text in (entry.partition(" ") for entry in allowlist("duplicates"))]

    def lines_of(path):
        return texts[path].split("\n")

    findings = []
    reported = defaultdict(list)

    def is_mostly_reported(place, length):
        covered = set()
        for start, end in reported[place[0]]:
            covered.update(range(max(start, place[1]), min(end, place[1] + length)))
        return len(covered) * 10 >= length * 8

    for length, first, second in find_matches(files, min_tokens):
        if wanted and first[0] not in wanted and second[0] not in wanted:
            continue
        # A repetitive run (a field list, a third copy) matches itself shifted many times; keep only its longest match.
        if is_mostly_reported(first, length) and is_mostly_reported(second, length):
            continue
        reported[first[0]].append((first[1], first[1] + length))
        reported[second[0]].append((second[1], second[1] + length))
        first_span = line_span(files, first, length)
        second_span = line_span(files, second, length)
        if (is_covered(entries, first[0], lines_of(first[0]), *first_span)
                and is_covered(entries, second[0], lines_of(second[0]), *second_span)):
            continue
        findings.append(f"src/{first[0]}:{first_span[0]}-{first_span[1]} ~ src/{second[0]}:{second_span[0]}-{second_span[1]} ({length} tokens)")

    shown = findings if args.top == 0 else findings[:args.top]
    for finding in shown:
        print(finding)
    if len(shown) < len(findings):
        print(f"... {len(findings) - len(shown)} more (--top 0 for all)")
    sys.stdout.flush()
    print(f"{len(findings)} match(es)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
