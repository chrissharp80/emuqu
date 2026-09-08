#!/usr/bin/env bash
#
# No `unowned` references in app source.
#
# Why this exists (2026-09-03). Twenty-eight helper types held `unowned let`
# back-pointers to the object that owned them. Every one was documented as
# safe "because the owner outlives it", and every one was safe on the
# synchronous path. The asynchronous path was another matter: a Task or a
# resumed continuation that kept the helper alive after its owner had gone
# read the reference and trapped —
#
#     Fatal error: Attempted to read an unowned reference but object … was
#     already destroyed
#
# — first in four observable-state tests on 2026-09-02, then in the unit suite
# on 2026-09-03 from a launch-time migration. The class of bug was removed, not
# the instances: the helpers are now values that hold their owner strongly and
# are built on demand, so nothing can outlive what it points at and nothing
# forms a cycle. This gate keeps it that way. `weak` remains available where a
# genuinely optional back-reference is needed; `unowned` is not.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

hits="$(grep -rnE '\bunowned(\(unsafe\))?\s+(let|var)\b' Emuqu/Sources "EmuquWatch Watch App" --include='*.swift' 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
    echo "check_no_unowned: unowned references are not allowed in app source:" >&2
    echo "$hits" >&2
    echo >&2
    echo "A helper that needs its owner should hold it strongly and be built on" >&2
    echo "demand by the owner (see CollectorSessionControl); an optional" >&2
    echo "back-reference should be weak." >&2
    exit 1
fi
echo "check_no_unowned: clean."
