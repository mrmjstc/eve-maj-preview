"""Keeps deps/knots as upstream knots plus the patches in deps/knots/patches/.

Usage, from anywhere in the repo:
    python tools/update_knots.py export
    python tools/update_knots.py update <upstream commit>

export: rewrites deps/knots/patches/ from how deps/knots differs from upstream at the commit in
deps/knots/patches/BASE, one patch per changed file. Run it after changing anything in deps/knots.

update: replaces deps/knots with upstream at <commit> and applies every patch with a 3-way merge.
A patch that doesn't apply cleanly leaves conflict markers in its file and is listed; resolve
them, build and test, update PATCHES.md, then run export. BASE becomes <commit> either way.

Upstream is cloned once into .zig-cache/knots-upstream (no CRLF conversion, so the patches stay
LF like the repo). Upstream's dotfiles, .github/, examples/, LICENSE.md and README.md aren't
vendored: the license ships as licenses/knots-LICENSE.txt.
"""
import fnmatch
import os
import shutil
import subprocess
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
KNOTS = os.path.join(REPO, "deps", "knots")
PATCHES = os.path.join(KNOTS, "patches")
BASE_FILE = os.path.join(PATCHES, "BASE")
CACHE = os.path.join(REPO, ".zig-cache", "knots-upstream")
WORK = os.path.join(REPO, ".zig-cache", "knots-work")
UPSTREAM_URL = "https://github.com/knots-ui/knots.git"
# Ours, not upstream's: kept when deps/knots is replaced and never diffed.
LOCAL_FILES = ("PATCHES.md",)
LOCAL_DIRS = ("patches",)
NOT_VENDORED = (".*", ".github/*", "examples/*", "LICENSE.md", "README.md")


def git(*args, cwd=REPO, check=True):
    result = subprocess.run(["git", "-c", "core.autocrlf=false", *args], cwd=cwd, capture_output=True, encoding="utf-8", errors="replace")
    if check and result.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
    return result


def is_vendored(path):
    return not any(fnmatch.fnmatch(path, pattern) for pattern in NOT_VENDORED)


def is_local(path):
    return path in LOCAL_FILES or path.split("/", 1)[0] in LOCAL_DIRS


def read_base():
    with open(BASE_FILE, encoding="utf-8") as file:
        return file.read().strip()


def write_base(commit):
    os.makedirs(PATCHES, exist_ok=True)
    with open(BASE_FILE, "w", encoding="utf-8", newline="") as file:
        file.write(commit + "\n")


def ensure_upstream(commit):
    """The cache clone, holding `commit`; returns its full hash."""
    if not os.path.isdir(os.path.join(CACHE, ".git")):
        print(f"Cloning {UPSTREAM_URL} into {os.path.relpath(CACHE, REPO)}...")
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        git("clone", "--quiet", "--no-checkout", UPSTREAM_URL, CACHE)
    if git("cat-file", "-e", f"{commit}^{{commit}}", cwd=CACHE, check=False).returncode != 0:
        git("fetch", "--quiet", "origin", cwd=CACHE)
    return git("rev-parse", f"{commit}^{{commit}}", cwd=CACHE).stdout.strip()


def fresh_worktree(commit):
    """A clean checkout of `commit` at WORK."""
    git("worktree", "prune", cwd=CACHE)
    if os.path.isdir(WORK):
        git("worktree", "remove", "--force", WORK, cwd=CACHE, check=False)
        shutil.rmtree(WORK, ignore_errors=True)
    git("worktree", "add", "--quiet", "--detach", WORK, commit, cwd=CACHE)


def tracked_knots_files():
    """deps/knots's files from upstream, as paths inside it: tracked or new, not ignored, and on disk, so it's right mid-update too."""
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "deps/knots").stdout.split("\0")
    paths = {os.path.relpath(os.path.join(REPO, p), KNOTS).replace(os.sep, "/") for p in listed if p}
    return sorted(p for p in paths if not is_local(p) and os.path.isfile(os.path.join(KNOTS, p)))


def worktree_files():
    return [p for p in git("ls-files", "-z", cwd=WORK).stdout.split("\0") if p and is_vendored(p)]


def patch_name(path):
    return path.replace("/", "-") + ".patch"


def export():
    base = ensure_upstream(read_base())
    fresh_worktree(base)
    ours = set(tracked_knots_files())
    for path in worktree_files():
        if path not in ours:
            os.remove(os.path.join(WORK, path))
    for path in ours:
        target = os.path.join(WORK, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(os.path.join(KNOTS, path), target)
    git("add", "--all", "--intent-to-add", cwd=WORK)

    for name in os.listdir(PATCHES):
        if name.endswith(".patch"):
            os.remove(os.path.join(PATCHES, name))
    changed = [p for p in git("diff", "--name-only", "-z", cwd=WORK).stdout.split("\0") if p]
    for path in changed:
        diff = git("diff", "--binary", "--", path, cwd=WORK).stdout
        with open(os.path.join(PATCHES, patch_name(path)), "w", encoding="utf-8", newline="") as file:
            file.write(diff)
    git("worktree", "remove", "--force", WORK, cwd=CACHE)
    print(f"Wrote {len(changed)} patch(es) against {base[:12]} to {os.path.relpath(PATCHES, REPO)}")


def update(commit):
    target = ensure_upstream(commit)
    fresh_worktree(target)
    conflicted, failed = [], []
    for name in sorted(os.listdir(PATCHES)):
        if not name.endswith(".patch"):
            continue
        result = git("apply", "--3way", "--whitespace=nowarn", os.path.join(PATCHES, name), cwd=WORK, check=False)
        if result.returncode == 0:
            continue
        # --3way leaves markers in the file when it can merge, and refuses outright when it can't.
        if "with conflicts" in result.stderr:
            conflicted.append(name)
        else:
            failed.append((name, result.stderr.strip()))

    fresh = set(worktree_files())
    for path in tracked_knots_files():
        if path not in fresh:
            os.remove(os.path.join(KNOTS, path))
    for path in fresh:
        destination = os.path.join(KNOTS, path)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(os.path.join(WORK, path), destination)
    git("worktree", "remove", "--force", WORK, cwd=CACHE)
    write_base(target)

    print(f"deps/knots is now upstream {target[:12]} with the patches applied.")
    for name in conflicted:
        print(f"  conflicts: {name}")
    for name, reason in failed:
        print(f"  not applied: {name}: {reason}")
    if conflicted or failed:
        print("Resolve those by hand (the vendored file has the markers, or lacks the patch), then build, test and run export.")
    else:
        print("Every patch applied; build and test, then run export so the patches match the new base.")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "export":
        export()
    elif len(sys.argv) == 3 and sys.argv[1] == "update":
        update(sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
