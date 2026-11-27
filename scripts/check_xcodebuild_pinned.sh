#!/usr/bin/env bash
#
# Every xcodebuild run builds against the committed package versions.
#
# `Package.resolved` is committed and testflight.yml records its hash beside
# each archive, but that record is only true if the build used it. Without
# `-onlyUsePackageVersionsFromResolvedFile`, xcodebuild may resolve the packages
# again and build, test or archive against versions the file does not name,
# and nothing in the log says so.
#
# The flag is defined once, as XCODEBUILD_PINNED in `scripts/lib/xcodebuild.sh`.
# This fails when:
#
#   1. that file no longer defines XCODEBUILD_PINNED as the flag;
#   2. an xcodebuild invocation in the Makefile, a workflow, a script or a git
#      hook loads the project without the flag. A script may pass
#      "$XCODEBUILD_PINNED" only if it sources the library, and the Makefile
#      $(XCODEBUILD_PINNED) only if it includes it; a workflow step passes the
#      flag literally, since its shell has not sourced anything;
#   3. it finds no invocation at all, which means it read nothing.
#
# Invocations that never load a project (`-version`, `-showsdks`, `-help`,
# `-exportArchive` of an existing archive, platform downloads) are exempt.

set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

FLAG = "-onlyUsePackageVersionsFromResolvedFile"
LIB = pathlib.Path("scripts/lib/xcodebuild.sh")
MAKEFILE = pathlib.Path("Makefile")

for path in (LIB, MAKEFILE):
    if not path.is_file():
        print(f"check_xcodebuild_pinned: {path} not found", file=sys.stderr)
        raise SystemExit(2)

# 1. The single definition.
if not re.search(rf"^XCODEBUILD_PINNED={re.escape(FLAG)}\s*$", LIB.read_text(), re.M):
    print(f"check_xcodebuild_pinned: {LIB} does not define XCODEBUILD_PINNED={FLAG}.",
          file=sys.stderr)
    raise SystemExit(1)

workflows = sorted(pathlib.Path(".github/workflows").glob("*.y*ml"))
scripts = sorted(pathlib.Path("scripts").glob("*.sh")) + sorted(pathlib.Path("scripts/lib").glob("*.sh"))
hooks = sorted(p for p in pathlib.Path(".githooks").glob("*") if p.is_file())
if not workflows or not scripts:
    print("check_xcodebuild_pinned: no workflows or scripts found; refusing to report clean.",
          file=sys.stderr)
    raise SystemExit(2)

# xcodebuild in command position: at the start of a command, after a shell
# operator or keyword, after make's `@`/`-` prefixes, after `run:` or `xcrun`.
# A mention inside an echo or a sentence is preceded by a word and is not one.
# A command word, then any wrappers that run their argument (timeout N,
# sudo, nice, caffeinate -i, xcrun --sdk X), then xcodebuild, bare, quoted
# or by absolute path.
COMMAND = re.compile(
    r"(?:^|[;&|({!@-]|\$\(|\brun:|\b(?:then|do|else|if|exec|time|command|env))"
    r"(?:\s*(?:(?:g?timeout)\s+\S+|sudo|nice|nohup|caffeinate(?:\s+-\w+)*"
    r"|xcrun(?:\s+-{1,2}[\w-]+(?:\s+[A-Za-z][\w.]*)?)*))*"
    r"""\s*["']?(?:/\S*/)?xcodebuild["']?(?=\s|$|\))"""
)
# xcodebuild bound to a name, or spawned from Python, escapes COMMAND.
ALIAS = re.compile(r"""=\s*["'(]?(?:/\S*/)?xcodebuild\b(?![-.])|\bxcrun\s+(?:-\S+\s+)*-f\s+xcodebuild\b""")
PY_SPAWN = re.compile(r"""["'](?:/\S*/)?xcodebuild["']""")
# A separator ends the invocation; what follows is another command.
SEPARATOR = re.compile(r"&&|\|\||;|\s\|\s|\|$|\)\s*$")
# Actions that never open the project, so never resolve packages.
NO_PROJECT = re.compile(
    r"\s-(?:version|showsdks|help|usage|license|exportArchive|exportNotarizedApp|"
    r"downloadPlatform|downloadAllPlatforms|importPlatform|runFirstLaunch|checkFirstLaunchStatus)\b"
)
VARIABLE = {
    "make": re.compile(r"\$\(XCODEBUILD_PINNED\)"),
    "sh": re.compile(r"\$\{?XCODEBUILD_PINNED\}?"),
    "yml": None,
}


def logical_lines(text):
    """(first line number, text) per command, comments dropped, `\\` continuations joined."""
    out = []
    buffer, start = "", None
    for lineno, line in enumerate(text.split("\n"), 1):
        if line.strip().startswith("#"):
            continue
        line = re.sub(r"(^|\s)#\s.*$", "", line)
        if start is None:
            start = lineno
        if line.rstrip().endswith("\\"):
            buffer += line.rstrip()[:-1] + " "
            continue
        out.append((start, buffer + line))
        buffer, start = "", None
    if buffer:
        out.append((start, buffer))
    return out


def defines_variable(path, kind, text):
    if kind == "make":
        return re.search(r"^include\s+scripts/lib/xcodebuild\.sh\s*$", text, re.M) is not None
    if kind == "sh":
        return path == LIB or re.search(
            r'^\s*(?:source|\.)\s+"\$\(dirname "\$0"\)/(?:\.\./scripts/)?lib/xcodebuild\.sh"', text, re.M
        ) is not None
    return False


# A Python heredoc inside a shell script spawns it the same way, so the shell
# scripts are read for a quoted `"xcodebuild"` argument too.
python_hosts = sorted(pathlib.Path(".").glob("scripts/**/*.py")) + sorted(pathlib.Path(".").glob("Tools/**/*.py"))
python_hosts += [p for p in scripts + hooks if p.name != "check_xcodebuild_pinned.sh"]
for path in python_hosts:
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").split("\n"), 1):
        if PY_SPAWN.search(line) and not line.lstrip().startswith("#"):
            print(f"check_xcodebuild_pinned: {path}:{lineno} spawns xcodebuild from Python; "
                  "call it from a shell script that sources scripts/lib/xcodebuild.sh.", file=sys.stderr)
            raise SystemExit(1)

files = [(MAKEFILE, "make")] + [(p, "yml") for p in workflows] + [(p, "sh") for p in scripts + hooks]
checked = 0
exempt = 0
failures = []
for path, kind in files:
    text = path.read_text(encoding="utf-8", errors="ignore")
    sourced = defines_variable(path, kind, text)
    for lineno, line in logical_lines(text):
        if ALIAS.search(line) and path.name != "check_xcodebuild_pinned.sh":
            failures.append(f"{path}:{lineno} binds xcodebuild to a name; this gate "
                            "can only see it called by name:\n      " + line.strip()[:110])
        for match in COMMAND.finditer(line):
            rest = line[match.end():]
            cut = SEPARATOR.search(rest)
            invocation = "xcodebuild" + (rest[:cut.start()] if cut else rest)
            if NO_PROJECT.search(invocation):
                exempt += 1
                continue
            checked += 1
            if FLAG in invocation:
                continue
            variable = VARIABLE[kind]
            if variable and variable.search(invocation):
                if sourced:
                    continue
                failures.append(f"{path}:{lineno} passes XCODEBUILD_PINNED without "
                                f"{'including' if kind == 'make' else 'sourcing'} {LIB}, "
                                f"so it expands to nothing")
                continue
            failures.append(f"{path}:{lineno} runs xcodebuild without {FLAG}:\n"
                            f"      {invocation.strip()[:110]}")

if checked == 0:
    print("check_xcodebuild_pinned: found no xcodebuild invocation that loads the project; "
          "refusing to report clean.", file=sys.stderr)
    raise SystemExit(2)

if failures:
    print(f"check_xcodebuild_pinned: {len(failures)} xcodebuild invocation(s) can resolve "
          f"packages to versions Package.resolved does not name.\n", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}\n", file=sys.stderr)
    print("  Pass \"$XCODEBUILD_PINNED\" after sourcing scripts/lib/xcodebuild.sh, $(XCODEBUILD_PINNED)"
          "\n  in the Makefile, or the flag itself in a workflow step.", file=sys.stderr)
    raise SystemExit(1)

print(f"check_xcodebuild_pinned: clean. {checked} xcodebuild invocation(s) pinned to "
      f"Package.resolved; {exempt} open no project.")
PY
