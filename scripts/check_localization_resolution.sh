#!/usr/bin/env bash
#
# CI guard: every `String(localized:)` literal in the code resolves to a key
# that actually exists in the string catalogue.
#
# Why this exists. The two other localization gates can both report perfect
# scores while a user-facing string ships in English to all sixteen locales:
#
#   * check_localization_coverage.sh measures catalogue -> locale. It asks
#     "does every key have a translation?" and answers 100.00% across 16
#     locales. It cannot see a key that nothing requests.
#   * check_localization_bundle.sh measures whether each lookup is
#     bundle-qualified. It asks "will this read from the right bundle?" and
#     answers "all bundle-qualified". A lookup can be perfectly
#     bundle-qualified and still name a key that does not exist.
#
# Neither measures the remaining direction: code -> catalogue. That is the
# direction this failure runs in.
#
# Edit the English literal in `DeepDiveReportRenderer+Pages.swift` after the
# catalogue is translated — to add "overtraining" and a monitor-for-symptoms
# instruction, say — and the lookup key changes with it: the catalogue entry
# (translated into all 16 locales, every one of them marked `translated`) is
# orphaned and every non-English user falls back to the raw English claim.
# Both gates above stay green through all of it.
#
# The whole class of bug is: edit a localized literal, forget to re-extract.
# It is silent, it is invisible in review, and it de-localises exactly the
# string someone cared enough to hand-edit.
#
# WHAT THIS DOES NOT DO. It does not re-implement Xcode's extractor. It
# normalises the two transforms that matter — interpolations become format
# specifiers, literal `%` doubles — and accepts either form where the
# developer authored a format template by hand. Unrecognised specifier
# spellings (`%lld`, `%1$@`, `%.1f`) are matched permissively rather than
# reported, because a false positive here costs more than a missed edge case:
# this gate has to stay believable to be worth having.
#
# Exit 0 clean, 1 on any unresolved literal, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

# The Watch target was never scanned. It has 99 localized literals of its own,
# so "every literal resolves to a key" was a statement about the iPhone app
# only — and the catalogue was not even in the Watch target's Resources, which
# meant every one of them fell back to its English key in all sixteen locales
# while three localization gates reported perfect scores.
SCAN_DIRS=("Emuqu/Sources" "EmuquWatch Watch App")
CATALOGUE="Emuqu/Localizable.xcstrings"

for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "$dir" ]] && continue
    echo "check_localization_resolution: scan directory missing: $dir" >&2
    exit 2
done
if [[ ! -f "$CATALOGUE" ]]; then
    echo "check_localization_resolution: catalogue missing: $CATALOGUE" >&2
    exit 2
fi

# A key only resolves in a target that ships the catalogue. The Watch App's copy
# once sat in the Resources phase of the empty `EmuquWatch` container target
# instead of its own, so the watch shipped none while this gate passed. Both
# shipping targets have to carry it.
python3 - Emuqu.xcodeproj/project.pbxproj "Emuqu" "EmuquWatch Watch App" <<'PY' || exit $?
import re
import sys

project_path, targets = sys.argv[1], sys.argv[2:]
try:
    text = open(project_path, encoding="utf-8").read()
except OSError as exc:
    sys.stderr.write(f"check_localization_resolution: cannot read {project_path}: {exc}\n")
    sys.exit(2)

missing = []
for name in targets:
    target = re.search(
        r"/\* " + re.escape(name) + r" \*/ = \{\s*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);",
        text, re.S)
    if not target:
        sys.stderr.write(f"check_localization_resolution: target not found: {name}\n")
        sys.exit(2)
    phase = re.search(r"(\w+) /\* Resources \*/", target.group(1))
    files = phase and re.search(
        re.escape(phase.group(1)) + r" /\* Resources \*/ = \{.*?files = \((.*?)\);", text, re.S)
    if not files or "Localizable.xcstrings in Resources" not in files.group(1):
        missing.append(name)

if missing:
    for name in missing:
        print(f"check_localization_resolution: target '{name}' does not ship "
              f"Localizable.xcstrings in its Resources phase.", file=sys.stderr)
    sys.exit(1)
PY

python3 - "$CATALOGUE" "${SCAN_DIRS[@]}" <<'PY'
import json
import pathlib
import re
import sys

catalogue_path, scan_dirs = sys.argv[1], sys.argv[2:]

try:
    catalogue = json.loads(pathlib.Path(catalogue_path).read_text(encoding="utf-8"))
except Exception as exc:
    sys.stderr.write(f"check_localization_resolution: cannot parse catalogue: {exc}\n")
    sys.exit(2)

keys = set(catalogue.get("strings", {}))
if not keys:
    sys.stderr.write("check_localization_resolution: catalogue has no strings.\n")
    sys.exit(2)

sys.dont_write_bytecode = True
sys.path.insert(0, "scripts/lib")
from localization_extract import INTERP, candidate_keys, key_pattern, localized_literals

# The extractor is shared with check_localization_orphans.sh, so the two
# directions agree on what a localized literal is. It reads multi-line
# `"""` literals and `NSLocalizedString(` as well as `String(localized:)`, and
# every SwiftUI form that takes a `LocalizedStringKey`: `Button("…")`,
# `Section("…")`, `.navigationTitle("…")`, `.alert("…")`,
# `.accessibilityLabel("…")`, `Toggle`, `TextField`, `Picker`, `Label`. A
# `Text(` without `bundle:` is NOT a plain string: it resolves through
# `.environment(\.locale, …)` against `Bundle.main`, and that is the call form
# the codebase most commonly writes UI copy in.
#
# This header claims no catch count on purpose. A gate header that overstates
# what it caught is the same defect the header above it describes, one level
# up — the prose and the code disagreeing, with only the prose being read. The
# script prints the number of call sites scanned on every run, and anyone can
# check that.

literals = []
for path in sorted(p for d in scan_dirs for p in pathlib.Path(d).rglob("*.swift")):
    text = path.read_text(encoding="utf-8", errors="ignore")
    for line, body in localized_literals(text):
        # A literal with no letters in it is punctuation or a format shell
        # ("%@ · %@", "—"), never a translatable phrase.
        if not re.search(r"[A-Za-z]{2,}", body.replace(INTERP, "")):
            continue
        literals.append((str(path), line, body))

unresolved = []
for path, line, raw in literals:
    candidates = candidate_keys(raw)
    if candidates & keys:
        continue
    matched = False
    for candidate in candidates:
        rx = key_pattern(candidate)
        if any(rx.match(k) for k in keys):
            matched = True
            break
    if not matched:
        unresolved.append((path, line, sorted(candidates, key=len)[-1]))

print(f"check_localization_resolution: {len(literals)} localized literals, "
      f"{len(keys)} catalogue keys.")

if not unresolved:
    print("check_localization_resolution: clean. Every literal resolves to a key.")
    sys.exit(0)

print(f"check_localization_resolution: {len(unresolved)} literal(s) resolve to NO "
      f"catalogue key.", file=sys.stderr)
print("These render in English in all locales, whatever the coverage gate says.\n",
      file=sys.stderr)
for path, line, key in unresolved:
    print(f"  {path}:{line}", file=sys.stderr)
    print(f"    key: {key[:200]!r}\n", file=sys.stderr)
print("Fix: re-run string extraction so the catalogue picks up the edited literal,\n"
      "then translate the new key and delete the orphan it replaced.", file=sys.stderr)
sys.exit(1)
PY
