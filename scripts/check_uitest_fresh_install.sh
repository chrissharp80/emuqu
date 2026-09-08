#!/usr/bin/env bash
set -euo pipefail

# Every UI-test suite must launch the app with `-UITests-FreshInstall`.
#
# Without it a suite inherits whatever onboarding, paywall, and scroll state the
# shared simulator clone was left in by the previous test, and its assertions
# start describing the wrong screen. Missing one suite is easy — a pass that
# moves every suite onto the shared `UITestLaunch` harness can skip
# `EmuquUITests.swift`, the file that defines the harness — and one missed
# suite turns a handful of tests red and the whole `tests` job with them.
#
# The check reads CODE, not prose.
#
# A whole-file `grep -q -- '-UITests-FreshInstall' "$file"` is not enough.
# Several launching suites name the flag in a doc comment as well as in
# `launchArguments`, so for those the argument can be deleted from the launch
# itself — `OnboardingFlowUITests.setUpWithError`, the actual launch — and a
# whole-file grep still reports every launching suite as reset.
#
# A guard satisfied by a comment describing the guard is worse than no guard: it
# reports a number for a population it never sampled. So comment lines are
# stripped first, and the flag has to appear on a line that also mentions
# `launchArguments`, which is the only place it can have any effect.

UITEST_DIR="${1:-EmuquUITests}"

if [[ ! -d "$UITEST_DIR" ]]; then
    echo "check_uitest_fresh_install: directory not found: $UITEST_DIR" >&2
    exit 66
fi

missing=()
checked=0

while IFS= read -r file; do
    # Only files that actually launch an app need the argument; pure helper
    # files (identifier registries, find/nav utilities) do not.
    # Strip whole-line comments AND trailing ones. A trailing `// …` is an
    # evasion on its own: the flag deleted from the array and re-added as a
    # comment on the same line passes a check that strips only whole lines.
    code="$(sed -E -e 's|^[[:space:]]*//.*$||' -e 's|[[:space:]]+//.*$||' "$file")"
    printf '%s\n' "$code" | grep -q '\.launch()' || continue
    checked=$((checked + 1))
    # The flag must sit in the launch arguments, not merely somewhere in the
    # file. `launchArguments` is often built over several lines, so accept the
    # flag on any line of a `launchArguments` assignment block: the block is
    # everything from `launchArguments` to the closing bracket.
    printf '%s\n' "$code" \
        | awk '/launchArguments/ { inblock = 1 }
               inblock { print }
               inblock && /\]/ { inblock = 0 }' \
        | grep -q -- '-UITests-FreshInstall' || missing+=("$file")
done < <(find "$UITEST_DIR" -name '*.swift' | sort)

if (( ${#missing[@]} > 0 )); then
    echo "ERROR: UI-test suites launch the app without -UITests-FreshInstall:" >&2
    for file in "${missing[@]}"; do
        echo "  - $file" >&2
    done
    echo >&2
    echo "Add \"-UITests-FreshInstall\" to app.launchArguments in setUpWithError()," >&2
    echo "then call UITestLaunch.toMainUI(app) (or toPaywall, for suites that" >&2
    echo "deliberately assert on a first-run gate)." >&2
    exit 1
fi

echo "check_uitest_fresh_install: clean. ${checked} launching suites, all reset."
