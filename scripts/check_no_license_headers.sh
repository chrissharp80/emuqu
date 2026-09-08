#!/usr/bin/env bash
#
# Source files carry no license text of their own.
#
# Why this exists. The repository's license changed, and eleven files kept a
# header written under the old one ("copying or modification strictly
# prohibited"), so the tree told two legal stories. `LICENSE` is the license;
# a per-file header is a copy that drifts. This gate fails on any Swift file
# that states rights, prohibitions or confidentiality in a comment.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

if ! find Emuqu "EmuquWatch Watch App" EmuquTests EmuquUITests -name '*.swift' -print -quit | grep -q .; then
    echo "check_no_license_headers: no Swift sources found." >&2
    exit 2
fi

hits="$(grep -rnEi '^\s*(//|\*)\s*.*(all rights reserved|strictly prohibited|proprietary and confidential|without prior written permission|licensed under)' \
    Emuqu "EmuquWatch Watch App" EmuquTests EmuquUITests --include='*.swift' 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
    echo "check_no_license_headers: license text in source comments; LICENSE is the only license:" >&2
    echo "$hits" >&2
    exit 1
fi
echo "check_no_license_headers: clean. No source file states its own license."
