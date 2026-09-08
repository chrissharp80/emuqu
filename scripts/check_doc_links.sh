#!/usr/bin/env bash
#
# Documentation integrity gate.
#
# Relative Markdown links break, and documentation constants drift from the
# values they describe. The shapes this catches:
#
#   • README.md and docs/runbooks/hotfix.md both claiming a 90% coverage floor
#     while the real floors, read from .ci/ at runtime, are 30 and 41.
#   • hotfix.md naming a .shared budget of 823 against an actual 716.
#   • docs/LOCALIZATION.md pinning a source-string count and a "≈52% coverage"
#     figure, and stating that CI does not gate translation completeness while
#     CI gates it at 100%.
#
# Every one of those is written accurately and goes stale, which is the failure
# mode this script exists to catch. It enforces two rules:
#
#   1. Every relative Markdown link resolves to a file that exists.
#   2. No Markdown file restates a value that lives in .ci/*.txt. Those files
#      all ratchet; a number copied into prose is a number that will be wrong.
#      Documentation must point at the file, not quote it.
#
#   3. Every backtick-quoted path that looks like a repository file resolves.
#      A code span is not a Markdown link, so rule 1 cannot see it: a release
#      runbook can cite `REVIEW.md` with no such file in the tree, and the API
#      reference can document `Sources/ViewModels/DashboardViewModel.swift`
#      for weeks after it is deleted.
#
# Rule 2 is deliberately narrow. It matches a `.ci/` budget filename mentioned
# in the same paragraph as a bare number, not every number in the docs — the
# goal is to stop the specific "tightened to 823" pattern, not to ban arithmetic
# from prose.

set -uo pipefail

cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

SKIP_DIRS = (
    ".build", "build/", "DerivedData", "node_modules",
    ".claude/worktrees", "SourcePackages", ".git/",
)


# Existence means "a fresh checkout would have it". A file that is present
# on the maintainer's disk but gitignored (design notes, build output) is
# invisible to CI, and a link to it passes locally and fails on the runner.
# So the tree is what `git ls-files` says it is, ignored files excluded.
_listing = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
    capture_output=True, text=True,
)
VISIBLE = {line for line in _listing.stdout.split("\n") if line} if _listing.returncode == 0 else None


def visible(path):
    if VISIBLE is None:
        return pathlib.Path(path).exists()
    try:
        rel = pathlib.Path(path).resolve().relative_to(pathlib.Path(".").resolve())
    except ValueError:
        return False
    rel = str(rel)
    return rel in VISIBLE or any(v.startswith(rel + "/") for v in VISIBLE)


def markdown_files():
    for path in sorted(pathlib.Path(".").rglob("*.md")):
        if any(skip in str(path) for skip in SKIP_DIRS):
            continue
        if not visible(path):
            continue
        yield path


# ---------------------------------------------------------------- rule 1

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

broken = []
for path in markdown_files():
    for lineno, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
        for match in LINK.finditer(line):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            # Strip an anchor fragment: docs/FOO.md#section -> docs/FOO.md
            target = target.split("#", 1)[0]
            if not target:
                continue
            if not visible(path.parent / target):
                broken.append((str(path), lineno, target))


# ---------------------------------------------------------------- rule 3

# A backtick span that names a file with a source-ish extension, or a path with
# a directory separator. Prose like `make ci` or `[String: Any]` has neither.
# `.json` is excluded on purpose: the docs correctly cite on-device data files
# (Breadcrumbs/active.json, saved_routes.json) that the app writes at runtime
# and that are not, and should not be, in the tree.
# The optional `:NNN` tail matters. Without it this pattern requires the
# backtick to close right after the extension, so `Models/HRVSession.swift:236`
# matches nothing and its wrong directory goes unnoticed for as long as the line
# number is attached — the suffix hides the claim, it does not make it.
# (Whether the LINE exists is `check_comment_citations.sh`'s job; this gate only
# asks whether the path does.)
CODE_PATH = re.compile(
    r"`([A-Za-z0-9_./+-]+\.(?:swift|md|sh|yml|yaml|plist|xcprivacy|entitlements))(?::\d{1,5})?(?:[-–]\d{1,5})?`"
)

# Illustrative placeholders and third-party filenames, not claims about this tree.
CODE_PATH_ALLOW = (
    "Package.swift",                    # documented as absent; that IS the Dependabot finding
    "Foo.swift", "Foo+Bar.swift", "Foo+Baz.swift",
    "Providers/MyProvider.swift",       # "how to add a provider" template
    "PolarH10.md", "SdkOfflineRecordingExplained.md",   # Polar SDK docs, not ours
)

# Index every file's basename once. Walking the tree per citation makes this
# gate take minutes, because build/ and SourcePackages/ are enormous.
#
# Two traps in this index:
#
#   * It must include untracked files. Built from tracked files only, a newly
#     added file cited in the docs is reported missing until it is committed —
#     the gate failing on correct documentation.
#   * The basename fallback applies only to a bare filename with no directory
#     in it. Applied to any citation, a path naming the WRONG directory passes
#     as long as some file somewhere shares its basename — and citations that
#     say `Sources/...` for files living at `Emuqu/Sources/...` are then never
#     checked at all.
tracked_basenames = {pathlib.PurePath(line).name for line in (VISIBLE or ())}

missing_paths = []
for path in markdown_files():
    for lineno, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
        for match in CODE_PATH.finditer(line):
            target = match.group(1)
            if target in CODE_PATH_ALLOW or target.startswith(("http", "~", "+")):
                continue
            # Accept the path relative to the repo root or to the doc.
            if visible(target) or visible(path.parent / target):
                continue
            # A bare filename with no directory is a legitimate way to cite a
            # file, so fall back to matching it anywhere in the tree. A citation
            # that DOES name a directory is making a claim about where the file
            # lives, and that claim has to hold.
            if "/" not in target and target in tracked_basenames:
                continue
            missing_paths.append((str(path), lineno, target))


# ---------------------------------------------------------------- rule 2

budget_files = sorted(pathlib.Path(".ci").glob("*.txt"))
budget_values = {}
for path in budget_files:
    raw = path.read_text().strip()
    if raw.isdigit():
        budget_values[path.name] = raw

# A paragraph that names a budget file AND contains a bare integer is quoting a
# ratcheting value. Allow the value only when it is inside a code span naming
# the read (`cat .ci/foo.txt`), which cannot go stale.
NUMBER = re.compile(r"(?<![\w.])(\d{2,6})(?![\w.%])")

quoted = []
for path in markdown_files():
    text = path.read_text(errors="ignore")
    lines = text.split("\n")
    for lineno, line in enumerate(lines, 1):
        for name in budget_values:
            if name not in line:
                continue
            # The surrounding sentence: this line plus the next, since the
            # filename and its value are often split across a wrap.
            window = line + " " + (lines[lineno] if lineno < len(lines) else "")
            # Ignore lines that are shell reads or code fences.
            if re.search(r"`[^`]*(cat|head|read_budget)[^`]*`", window):
                continue
            for match in NUMBER.finditer(window):
                quoted.append((str(path), lineno, name, match.group(1)))
                break


# ---------------------------------------------------------------- report

failed = False

if broken:
    failed = True
    print(f"check_doc_links: {len(broken)} broken relative link(s).\n")
    for path, lineno, target in broken:
        print(f"  {path}:{lineno} -> {target}")
    print()

if quoted:
    failed = True
    print(f"check_doc_links: {len(quoted)} documentation constant(s) quoting a ratcheting budget.\n")
    for path, lineno, name, value in quoted:
        current = budget_values.get(name, "?")
        print(f"  {path}:{lineno} mentions {name} near the literal {value} (current value: {current})")
    print()
    print("  Budgets in .ci/ ratchet. Point at the file instead of quoting it:")
    print("    \"the floor lives in .ci/<name>.txt\"  — not  \"the floor is 41\"")
    print()

if missing_paths:
    failed = True
    print(f"check_doc_links: {len(missing_paths)} documented path(s) that do not exist.\n")
    for path, lineno, target in missing_paths:
        print(f"  {path}:{lineno} cites `{target}`")
    print()
    print("  Documentation naming a file that is not in the tree sends the reader")
    print("  somewhere that does not exist, usually under release pressure.")
    print()

if failed:
    sys.exit(1)

count = sum(1 for _ in markdown_files())
print(f"check_doc_links: clean. {count} Markdown files, all relative links resolve, "
      f"no budget constants restated, all cited paths exist.")
PY
