#!/usr/bin/env bash
set -euo pipefail

# Localization coverage guard.
#
# The app ships 17 locales, and every non-English one sat at
# exactly 51.8% translated. 1,796 of 3,729 catalogue keys had no entry in ANY
# locale, so roughly half the UI silently fell back to English in all 16
# translations. Nothing measured this, so nothing stopped it drifting.
#
# A German user does not experience that as "untranslated" — they experience an
# app that drops into English mid-screen, which reads as broken. It also makes
# the App Store listing overstate what the binary delivers.
#
# This is the same drift-guard shape as `check_infoplist_key_drift.sh` and
# `check_sbom_drift.sh`: measure the real number, commit it as a floor, fail if
# it regresses, ratchet it up deliberately.
#
# Keys marked `"shouldTranslate": false` in the catalogue are excluded from the
# denominator — those are pure format/punctuation strings ("%@ · %@", "—") where
# a translation is meaningless.
#
# Usage: check_localization_coverage.sh [catalogue] [floor-file]

CATALOGUE="${1:-Emuqu/Localizable.xcstrings}"
FLOOR_FILE="${2:-.ci/min_localization_coverage.txt}"

if [[ ! -f "$CATALOGUE" ]]; then
    echo "String catalogue not found: $CATALOGUE" >&2
    exit 66
fi

if [[ ! -f "$FLOOR_FILE" ]]; then
    echo "Localization floor file not found: $FLOOR_FILE" >&2
    exit 66
fi

FLOOR="$(tr -d '[:space:]' < "$FLOOR_FILE")"
if [[ -z "$FLOOR" ]]; then
    echo "Localization floor file is empty: $FLOOR_FILE" >&2
    exit 65
fi

SUMMARY="$(python3 - "$CATALOGUE" "$FLOOR" <<'PY'
import json
import sys

catalogue_path = sys.argv[1]
floor = float(sys.argv[2])

with open(catalogue_path, encoding="utf-8") as fh:
    catalogue = json.load(fh)

source = catalogue.get("sourceLanguage", "en")
strings = catalogue["strings"]

# Only keys that are actually meant to be translated count.
translatable = {
    key: value
    for key, value in strings.items()
    if value.get("shouldTranslate") is not False
}

# Locales the app ships = every locale that appears anywhere in the catalogue,
# minus the source language.
locales = set()
for value in translatable.values():
    locales.update((value.get("localizations") or {}).keys())
locales.discard(source)

if not locales:
    print("No non-source locales found in the catalogue.")
    raise SystemExit(65)

total = len(translatable)
worst_pct = 100.0
rows = []
for locale in sorted(locales):
    done = 0
    for value in translatable.values():
        unit = ((value.get("localizations") or {}).get(locale) or {}).get("stringUnit") or {}
        # "translated" is the only state that actually ships a translation;
        # "new" / "needs_review" are placeholders Xcode writes.
        if unit.get("state") == "translated" and unit.get("value"):
            done += 1
    pct = 100.0 * done / total if total else 0.0
    worst_pct = min(worst_pct, pct)
    rows.append((locale, done, pct))

print(f"Localization coverage over {total} translatable keys ({len(locales)} locales), floor {floor:.1f}%:")
for locale, done, pct in rows:
    flag = "  <-- BELOW FLOOR" if pct + 1e-9 < floor else ""
    print(f"  {locale:<8} {done:>5}/{total}  {pct:6.2f}%{flag}")
print(f"Worst locale: {worst_pct:.2f}% (floor {floor:.1f}%)")

if worst_pct + 1e-9 < floor:
    print(f"FAIL: at least one locale is below the {floor:.1f}% floor.")
    raise SystemExit(1)
PY
)" && STATUS=0 || STATUS=$?

echo "$SUMMARY"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Localization coverage"
        echo
        echo '```text'
        echo "$SUMMARY"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$STATUS" -ne 0 ]]; then
    echo "check_localization_coverage: FAILED" >&2
    exit 1
fi

echo "check_localization_coverage: clean."
