"""Finds import cycles between src/ files, and fails on one that crosses features outside the top layer.

Usage, from the repo root:
    python tools/checks/import_cycles.py [--list]

A cycle within one feature (thumbnail/set.zig and thumbnail/arrange.zig) is fine. One that spans
features is an error for each member not matched by tools/checks/allow/import_cycles.txt, which
lists the top layer: app.zig, and the tray and window procs that reach back up to it.
Each error shows one cycle through the file, so the import to cut is visible. --list prints every
cycle, allowed or not. A root file counts as its folder's feature (config.zig with config/).
An allowlist pattern that matches no file in a cross-feature cycle is an error too.
"""
import argparse
import fnmatch
import os
import re
import sys

from shared import SRC, Finding, allowlist, report, src_path, stale_allowlist, zig_files

IMPORT = re.compile(r'@import\("([^"]+\.zig)"\)')


def build_graph():
    """Each src/ file's path under src/, mapped to the src/ files it imports."""
    graph = {}
    for path, text in zig_files().items():
        directory = os.path.dirname(os.path.join(SRC, path))
        imports = set()
        for match in IMPORT.finditer(text):
            target = os.path.normpath(os.path.join(directory, match.group(1)))
            if os.path.isfile(target) and os.path.commonpath([target, SRC]) == SRC:
                imports.add(src_path(target))
        graph[path] = imports
    return graph


def strongly_connected(graph):
    """Tarjan's algorithm, iterative so a deep import chain can't hit the recursion limit."""
    index_of, low, stack, on_stack, components = {}, {}, [], set(), []
    counter = 0
    for root in sorted(graph):
        if root in index_of:
            continue
        work = [(root, iter(sorted(graph[root])))]
        index_of[root] = low[root] = counter
        counter += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, children = work[-1]
            child = next(children, None)
            if child is not None:
                if child not in index_of:
                    index_of[child] = low[child] = counter
                    counter += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, iter(sorted(graph[child]))))
                elif child in on_stack:
                    low[node] = min(low[node], index_of[child])
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index_of[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1:
                    components.append(sorted(component))
    return components


def feature(path):
    return path.split("/")[0].removesuffix(".zig")


def cycle_through(graph, start, members):
    """The shortest import path from `start` back to itself within `members` that leaves its feature."""
    home = feature(start)
    start_state = (start, False)
    previous = {start_state: None}
    queue = [start_state]
    for state in queue:
        node, has_left = state
        for child in sorted(graph[node] & members):
            child_state = (child, has_left or feature(child) != home)
            if child == start and child_state[1]:
                path = [node]
                step = previous[state]
                while step is not None:
                    path.append(step[0])
                    step = previous[step]
                return list(reversed(path)) + [start]
            if child != start and child_state not in previous:
                previous[child_state] = state
                queue.append(child_state)
    return [start]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="print every cycle, allowed or not")
    args = parser.parse_args()

    graph = build_graph()
    patterns = allowlist("import_cycles")
    findings, used = [], set()
    for component in strongly_connected(graph):
        members = set(component)
        features = sorted({feature(path) for path in component})
        if args.list:
            print(f"cycle of {len(component)} files across {', '.join(features)}:")
            for path in component:
                print(f"  src/{path}")
        if len(features) == 1:
            continue
        for path in component:
            allowing = [pattern for pattern in patterns if fnmatch.fnmatch(path, pattern)]
            if allowing:
                used.update(allowing)
                continue
            findings.append(Finding(f"src/{path}", "cross-feature-cycle", " -> ".join(cycle_through(graph, path, members))))
    findings += stale_allowlist("import_cycles", used)
    return report(findings)


if __name__ == "__main__":
    sys.exit(main())
