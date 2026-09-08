#!/usr/bin/env bash
#
# CI guard: user-facing decimal formatting must name a locale.
#
# Why this exists (2026-08-23). `String(format: "%.1f", x)` takes NO locale, and
# with no locale Foundation formats POSIX-style — the decimal separator is always
# ".". The app ships 16 non-English localizations, and in de/fr/es/it/pt and the
# rest the separator is ",". So every metric on every screen, and every number in
# the PDF report, rendered as "3.5" to users whose language writes "3,5". There
# were 905 such call sites and not one of them passed a locale.
#
# The fix is `String(format: "%.1f", locale: .current, x)`. This guard keeps it
# that way.
#
# SCOPE — deliberately narrow, and the narrowness is the point:
#
#   * Only float conversions (%f/%e/%g). A locale changes those in exactly the
#     way we want.
#
#   * NEVER integer conversions. A locale also adds GROUPING separators, so
#     `String(format: "%d:%02d", 1234, 7)` becomes "1.234:07" in German — a
#     corrupted duration, not a localized one. Measured, not assumed. Any format
#     string mixing %d with %f is left alone for a human to split.
#
#   * Only directories whose output a person reads: Views/ and Export/ (all of
#     whose format sites are PDF report text — CSVExporter has none, and must
#     keep none, since a comma decimal separator would break the columns).
#     Analysis/, Services/, Storage/ and friends mostly compute and log; POSIX
#     is right there.
#
#     "mostly" was doing a lot of work in that sentence.
#     Four of them do not compute, they WRITE PROSE THE USER READS:
#     `AnalysisSummaryGenerator` ("Your HRV is low at 45ms"),
#     `CoachReportGenerator`, `ScoreDetailBuilder` (the score
#     breakdown shown on the dashboard) and `MorningResultsViewModel`. Between
#     them they held 102 unlocalized decimal sites that this gate reported
#     nothing about while printing "clean. User-facing decimals name a locale."
#     All 102 now pass `locale: .current`, and the four are in scope below so
#     they stay that way. The rest of Analysis/ genuinely does compute, and
#     stays out. Assistant/ is excluded as a directory because it is genuinely mixed
#     — WorkoutAIContext and AIProvider+SystemPrompt build LLM prompts, where
#     unambiguous POSIX numbers are what we want the model to see — so only the
#     view file in it is guarded.
#
#   * Logging calls are skipped wherever they appear. A log line is machine
#     output that happens to live in a UI file.
#
# Exit 0 clean, 1 on violations, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

SCAN_DIRS=("Emuqu/Sources/Views" "Emuqu/Sources/Export")
# Narrative generators: they live under Analysis/ and ViewModels/ but their
# output is sentences, not numbers for a machine.
SCAN_GLOBS=(
    "Emuqu/Sources/Analysis/AnalysisSummaryGenerator"*.swift
    "Emuqu/Sources/Analysis/CoachReportGenerator"*.swift
    "Emuqu/Sources/Analysis/ScoreDetailBuilder.swift"
    "Emuqu/Sources/ViewModels/MorningResultsViewModel.swift"
)
# `SessionStorageDiagnostic` builds its strings in Storage/ but they are
# rendered by `SettingsDiagnosticsViews`. A gate that scans where a string is
# WRITTEN rather than where it is SHOWN misses exactly this shape — the RMSSD
# and SDNN figures on the diagnostics screen printed a hardcoded "." decimal
# separator to every comma-locale user.
SCAN_FILES=(
    "Emuqu/Sources/Assistant/Views/CitationQuickView.swift"
    "Emuqu/Sources/Storage/SessionStorageDiagnostic.swift"
    "${SCAN_GLOBS[@]}"
)

for d in "${SCAN_DIRS[@]}"; do
    if [[ ! -d "$d" ]]; then
        echo "check_locale_formatting: scan directory missing: $d" >&2
        echo "check_locale_formatting: fix the path in this script, or remove the entry." >&2
        exit 2
    fi
done
for f in "${SCAN_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "check_locale_formatting: scan file missing: $f" >&2
        echo "check_locale_formatting: fix the path in this script, or remove the entry." >&2
        exit 2
    fi
done

VIOLATIONS="$(
    python3 - "${SCAN_DIRS[@]}" "${SCAN_FILES[@]}" <<'PY'
import re, sys, pathlib

FMT   = re.compile(r'String\(format:\s*"((?:[^"\\]|\\.)*)"\s*,')
FLOAT = re.compile(r"%[-+ #0-9.']*[efgEFG]")
INT   = re.compile(r"%[-+ #0-9.']*(?:l{0,2}[diu])")
LOG   = re.compile(r'\b(debugLog|NSLog|os_log)\s*\(')

paths = []
for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    paths.extend(sorted(p.rglob('*.swift')) if p.is_dir() else [p])

for f in paths:
    for n, line in enumerate(f.read_text(encoding='utf-8', errors='ignore').splitlines(), 1):
        if LOG.search(line) or 'locale:' in line:
            continue
        for m in FMT.finditer(line):
            fmt = m.group(1)
            if FLOAT.search(fmt) and not INT.search(fmt):
                print(f"{f}:{n}: String(format: \"{fmt}\", …) has no locale")
PY
)"

if [[ -n "$VIOLATIONS" ]]; then
    COUNT="$(printf '%s\n' "$VIOLATIONS" | grep -c .)"
    echo "check_locale_formatting: $COUNT user-facing site(s) format a decimal without a locale." >&2
    printf '%s\n' "$VIOLATIONS" >&2
    echo >&2
    echo "Pass the locale explicitly:" >&2
    echo '    String(format: "%.1f", locale: .current, value)' >&2
    echo >&2
    echo "Without it the separator is always \".\", so users reading de/fr/es/it/pt" >&2
    echo "and the other localizations see \"3.5\" where their language writes \"3,5\"." >&2
    exit 1
fi

echo "check_locale_formatting: clean. User-facing decimals name a locale."
exit 0
