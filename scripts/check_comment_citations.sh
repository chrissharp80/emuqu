#!/usr/bin/env bash
#
# CI guard: a `File.swift:NNN` citation in a comment must point at a line that
# exists.
#
# Why this exists. Line-numbered cross-file citations rot in two ways — past
# the end of the file they name, or in range but at unrelated code — and a
# single file-splitting pass leaves a crop like this behind:
#
#   BackgroundLocationManager.swift:44  "WorkoutRecorder.swift ~1291"   file is 365 lines
#   HolisticDailyReport.swift:76,:213   "WorkoutRecorder+Lifecycle.swift:1030"  file is 854
#   MedicalQueryGuard.swift:10          "AIProvider.swift:580+"         file is 445
#   AssistantContext.swift:90           "AIProvider.swift:1372"         file is 445
#   RecordView+Sections.swift:260       "RecordView.swift:915"          file is 379
#   VitalsScoring.swift:244 "Constants.swift:317" -> enum MinimumBeats
#   MorningProcessingService+Sleep.swift:77  "HealthKitManager+Sleep.swift:110-115" -> warmSleepCache
#
# A split moves the cited code into `+Extension` files and shortens the
# originals. This repo splits files to meet budgets as a matter of routine, so
# a line-numbered cross-file citation is on a timer from the day it is written.
#
# Stale rationale is a defect: a reader who
# follows one of these lands on unrelated code and concludes the comment is
# lying about more than the line number.
#
# The out-of-range case is decidable and is what this checks. An in-range
# citation that points at the wrong code is not mechanically decidable, which is
# why the guidance in the failure message is to cite the SYMBOL instead — a
# symbol survives a split, a line number does not.
#
# Exit 0 clean, 1 on a broken citation.

set -uo pipefail
cd "$(dirname "$0")/.."

SOURCE_ROOTS=("$@")
if (( ${#SOURCE_ROOTS[@]} == 0 )); then
    SOURCE_ROOTS=("Emuqu" "EmuquTests" "EmuquUITests")
fi

python3 - "${SOURCE_ROOTS[@]}" <<'PY'
import pathlib
import re
import sys

roots = sys.argv[1:] or ["Emuqu", "EmuquTests", "EmuquUITests"]

# Longest line count for each basename anywhere in the tree — a citation is
# only broken if it exceeds EVERY file that could plausibly be the target.
lengths: dict[str, int] = {}
for root in roots:
    for path in pathlib.Path(root).rglob("*.swift"):
        name = path.name
        count = len(path.read_text(encoding="utf-8", errors="ignore").splitlines())
        lengths[name] = max(lengths.get(name, 0), count)

# `Foo.swift:123`, `Foo.swift: 123`, `Foo.swift ~1291`, `Foo.swift line 42`,
# `Foo.swift, line 42`, and the GitHub permalink form `Foo.swift#L42`.
# A four-digit run that looks like a year is skipped — comments here are dense
# with dates like "CoachReportGenerator.swift 2026-08-23".
#
# Block comments are scanned too. A gate that matches `^\s*//` only leaves a
# citation inside a `/* … */` block invisible to a check whose entire premise is
# that these citations rot. A guard that covers one comment syntax out of two
# reports a clean tree it has not read.
CITATION = re.compile(
    r"([A-Za-z][\w+]*\.swift)\s*(?::\s*|:?\s+~\s*|\s*,?\s+line\s+|#L)(\d{1,5})(?!\d)"
)
LINE_COMMENT = re.compile(r"^\s*//")
BLOCK_OPEN = re.compile(r"/\*")
BLOCK_CLOSE = re.compile(r"\*/")


def comment_lines(text):
    """Yield (line_number, text) for every line that is inside a comment.

    Line comments are matched whole. For block comments the whole line is
    yielded while the block is open, which over-includes the code sharing a
    line with `*/` — harmless here, because a citation is only ever reported
    when it names a real .swift file and a real line number.
    """
    depth = 0
    for index, line in enumerate(text.splitlines()):
        opens, closes = len(BLOCK_OPEN.findall(line)), len(BLOCK_CLOSE.findall(line))
        if depth or opens:
            yield index + 1, line
            depth = max(0, depth + opens - closes)
            continue
        if LINE_COMMENT.match(line):
            yield index + 1, line


def check_citations(path, numbered_lines, out):
    """Record every `File.swift:NNN` that names an unknown file or a line past
    its end. Four-digit years are not citations."""
    found = 0
    for lineno, line in numbered_lines:
        for match in CITATION.finditer(line):
            name, number = match.group(1), int(match.group(2))
            if re.match(r"^(19|20)\d\d$", match.group(2)):
                continue
            found += 1
            known = lengths.get(name)
            if known is None:
                out.append((str(path), lineno, match.group(0), "no such file in the tree"))
            elif number > known:
                out.append((str(path), lineno, match.group(0), f"{name} is {known} lines"))
    return found


broken = []
total = 0
for root in roots:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        total += check_citations(path, comment_lines(text), broken)

# The same citations live in Markdown, and nothing else checks THEM.
# `check_doc_links.sh` verifies that a documented path exists but says nothing
# about the line number after the colon, so `docs/ARCHITECTURE.md` can point at
# a line in `HealthKitManager+Sleep.swift` that has moved to another file
# entirely. A guard that covers one half of the tree reports a clean tree it has
# not read.
DOC_ROOTS = [pathlib.Path("docs"), pathlib.Path("README.md")]
for root in DOC_ROOTS:
    docs = [root] if root.is_file() else (sorted(root.rglob("*.md")) if root.is_dir() else [])
    for path in docs:
        lines = path.read_text(encoding="utf-8", errors="ignore").split("\n")
        total += check_citations(path, enumerate(lines, 1), broken)

print(f"check_comment_citations: {total} file:line citation(s) in comments and docs.")

if not broken:
    print("check_comment_citations: clean. Every citation in Swift comments and Markdown resolves to a real line.")
    sys.exit(0)

print(f"check_comment_citations: {len(broken)} broken citation(s).\n", file=sys.stderr)
for path, line, citation, why in broken:
    print(f"  {path}:{line}", file=sys.stderr)
    print(f"    cites: {citation}  ({why})\n", file=sys.stderr)
print(
    "Cite the SYMBOL, not the line: `WorkoutRecorder+Start.startKeepAlives` survives a\n"
    "file split, `WorkoutRecorder.swift:1291` does not. This repo splits files to meet\n"
    "length budgets as a matter of routine.",
    file=sys.stderr,
)
sys.exit(1)
PY
