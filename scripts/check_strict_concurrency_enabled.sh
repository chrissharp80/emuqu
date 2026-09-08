#!/usr/bin/env bash
# check_strict_concurrency_enabled.sh — proves the compiler is the concurrency
# gate: every build configuration is in Swift 6 language mode with
# `SWIFT_STRICT_CONCURRENCY = complete`, and warnings are errors somewhere.
#
# The compiler already fails the ordinary build on an isolation hazard. What
# an ordinary build cannot catch is someone REMOVING the setting, which turns
# everything green while nothing is checked. That needs no build, so this runs
# on the Ubuntu lint path in seconds.
#
# To measure against a different level or language version:
#
#     STRICT_CONCURRENCY_LEVEL=complete SWIFT_LANGUAGE_VERSION=6.0 ./scripts/check_strict_concurrency_enabled.sh

set -uo pipefail

cd "$(dirname "$0")/.."

PROJECT_FILE="Emuqu.xcodeproj/project.pbxproj"
EXPECTED_LEVEL="${STRICT_CONCURRENCY_LEVEL:-complete}"
EXPECTED_SWIFT_VERSION="${SWIFT_LANGUAGE_VERSION:-6.0}"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

[[ -f "$PROJECT_FILE" ]] || fail "$PROJECT_FILE not found"

# One `SWIFT_VERSION` per build configuration is the reliable denominator —
# every configuration that compiles Swift has one.
configs=$(grep -c 'SWIFT_VERSION = ' "$PROJECT_FILE" | tr -d ' ')
strict=$(grep -c "SWIFT_STRICT_CONCURRENCY = ${EXPECTED_LEVEL};" "$PROJECT_FILE" | tr -d ' ')
werror=$(grep -c 'SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;' "$PROJECT_FILE" | tr -d ' ')
swift6=$(grep -c "SWIFT_VERSION = ${EXPECTED_SWIFT_VERSION};" "$PROJECT_FILE" | tr -d ' ')

echo "Strict concurrency: ${strict}/${configs} configurations at '${EXPECTED_LEVEL}'"
echo "Warnings as errors: ${werror} configuration(s)"
echo "Swift language mode: ${swift6}/${configs} configurations at ${EXPECTED_SWIFT_VERSION}"

if (( strict < configs )); then
    fail "$(cat <<EOF
strict concurrency is not set in every build configuration ($strict of $configs).

A configuration without it compiles without data-race checking, and nothing else
in CI would notice — the build simply goes green. Set
'SWIFT_STRICT_CONCURRENCY = $EXPECTED_LEVEL;' in every configuration, or, if a
target genuinely cannot support it yet, say which and why in this script rather
than leaving the gap silent.
EOF
)"
fi

if (( swift6 < configs )); then
    fail "$(cat <<EOF
Swift ${EXPECTED_SWIFT_VERSION} language mode is not set in every build configuration ($swift6 of $configs).
Swift 6 mode is what turns every data-race diagnostic into a compile error; a
configuration left in Swift 5 mode reports them as warnings and the build goes
green. Set 'SWIFT_VERSION = ${EXPECTED_SWIFT_VERSION};' in every configuration.
EOF
)"
fi

if (( werror < 1 )); then
    fail "$(cat <<EOF
SWIFT_TREAT_WARNINGS_AS_ERRORS is not YES anywhere.

Strict concurrency without warnings-as-errors is a report, not a gate: the
diagnostics are emitted and the build still succeeds. Both settings together are
what makes a new isolation hazard fail CI.
EOF
)"
fi

echo "check_strict_concurrency_enabled: clean. The compiler enforces isolation; this only proves it is switched on."
