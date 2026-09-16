#!/usr/bin/env bash
#
# CI guard for `@unchecked Sendable` and `nonisolated(unsafe)`.
#
# These annotations bypass Swift 6 strict-concurrency safety. Each is a
# deliberate, locally-justified decision (every allowlisted file has either
# an NSLock, a serial DispatchQueue, or an OSAllocatedUnfairLock guarding
# the unchecked state).
#
# The guard fails the build if a NEW
# file uses either annotation outside the allowlist below, OR if the total
# count of non-comment annotations grows beyond BASELINE_COUNT.

set -uo pipefail

cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

ALLOWLIST=(
    # Every file below carries one of the two annotations; each names the
    # queue, lock, or SDK contract that owns the state. A file whose escapes
    # are gone (OSAllocatedUnfairLock-backed state, say) must leave this
    # list: an allowlist entry with no escape in it is slack a future edit
    # can hide inside.
    "Emuqu/Sources/Analysis/BaselineTracker.swift"
    "Emuqu/Sources/Assistant/Chat/ConversationStore.swift"
    "Emuqu/Sources/Assistant/Chat/WhisperKitSTTBridge.swift"
    # StrapRadio: the Polar SDK handle. The SDK marshals every call onto its
    # own queues but does not declare itself Sendable; `StrapAPI` is the one
    # place that contract is asserted.
    "Emuqu/Sources/Collection/StrapRadio.swift"
    # WorkoutStartCue: the start announcement synthesizer is driven from one
    # detached task so it never queues behind the recording view's first mount.
    "Emuqu/Sources/Collection/WorkoutStartCue.swift"
    "Emuqu/Sources/Services/ActiveRouteSession.swift"
    "Emuqu/Sources/Services/AmbientLocationService.swift"
    "Emuqu/Sources/Services/BreadcrumbStore.swift"
    # WatchConnectivityBridge+Session: WCSession's reply handler is not
    # declared Sendable; the box carries it to the main actor and back.
    "Emuqu/Sources/Services/WatchConnectivityBridge+Session.swift"
    "Emuqu/Sources/Storage/Archive.swift"
    "Emuqu/Sources/Storage/RawRRBackup.swift"
    "Emuqu/Sources/Storage/WorkoutTrackBackup.swift"
    "Emuqu/Sources/Utilities/KeyboardPerfSignpost.swift"
    "Emuqu/Sources/Utilities/SystemDiagnosticsManager.swift"
)

# Find every `.swift` file under the iOS app + Watch app and grep for the
# annotations. Use BSD-grep-portable flags only.
RG_TMP=$(gate_mktemp unchecked-sendable) || exit $?
trap 'rm -f "$RG_TMP"' EXIT

find Emuqu "EmuquWatch Watch App" -name '*.swift' -type f -print0 \
    | xargs -0 grep -nHE '@unchecked Sendable|nonisolated\(unsafe\)' \
    > "$RG_TMP" 2>/dev/null || true

# Filter out comment-line matches: format is `path:lineno:content`.
REAL_HITS=$(awk -F: '
    {
        content = ""
        for (i = 3; i <= NF; i++) content = content (i > 3 ? ":" : "") $i
        sub(/^[ \t]+/, "", content)
        if (content ~ /^\/\//) next
        if (content ~ /^\*/) next
        print $0
    }
' "$RG_TMP")

FILES=$(printf '%s\n' "$REAL_HITS" | awk -F: 'NF>0 {print $1}' | sort -u)

VIOLATIONS=()
while IFS= read -r file; do
    [ -z "$file" ] && continue
    allowed=false
    for entry in "${ALLOWLIST[@]}"; do
        if [ "$file" = "$entry" ]; then
            allowed=true
            break
        fi
    done
    if [ "$allowed" = false ]; then
        VIOLATIONS+=("$file")
    fi
done <<< "$FILES"

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
    echo "ERROR: @unchecked Sendable or nonisolated(unsafe) found in non-allowlisted files:"
    for v in "${VIOLATIONS[@]}"; do
        echo "  - $v"
        grep -nHE '@unchecked Sendable|nonisolated\(unsafe\)' "$v" | sed 's/^/      /'
    done
    echo
    echo "Either:"
    echo "  (a) Refactor to remove the unchecked/unsafe annotation (use actor, @MainActor, or OSAllocatedUnfairLock)."
    echo "  (b) Add the file to ALLOWLIST in scripts/check_unchecked_sendable.sh AFTER confirming the synchronization is correct."
    exit 1
fi

ACTUAL_COUNT=$(printf '%s\n' "$REAL_HITS" | grep -c . || true)
# The count is checked as well as the file because an allowlisted file can
# gain annotations without any new file appearing — and that drift is easy
# to miss, since the FILE check above exits first and the count check never
# gets to report it. If this number needs bumping, re-verify each new
# annotation rather than raising it to make CI green. What makes the
# individually admitted escapes safe:
#   • SettingsManager.swift:16  — `nonisolated(unsafe) static let shared`;
#     Swift guarantees run-once, thread-safe `static let` init.
#   • LanguageManager.swift:35  — `locale`; written only in the run-once
#     `init` and in `@MainActor setLanguage` (single call site).
#   • LanguageManager.swift:47  — `bundle`; same writers, and a class
#     reference (pointer-atomic) for its ~3,547 nonisolated readers.
#   • RRCollector.swift:303 — `_liveHRVSnapshotMirror`; NSLock-guarded,
#     documented in-place at lines 291-302.
#   • WorkoutStartCue.swift (start-cue synthesizer spoken off main) and
#     WatchConnectivityBridge+Session.swift (asynchronous Watch reply) —
#     removing these by moving the work onto the main actor is a behaviour
#     regression, not a cleanup.
BUDGET_FILE=".ci/unchecked_sendable_budget.txt"
if [[ ! -f "$BUDGET_FILE" ]]; then
    echo "check_unchecked_sendable: missing $BUDGET_FILE" >&2
    exit 2
fi
BASELINE_COUNT="$(tr -d '[:space:]' < "$BUDGET_FILE")"

if [ "$ACTUAL_COUNT" -gt "$BASELINE_COUNT" ]; then
    echo "WARN: total @unchecked Sendable / nonisolated(unsafe) count is $ACTUAL_COUNT (baseline $BASELINE_COUNT)."
    echo "An allowlisted file added new annotations. Review and either justify or remove."
    printf '%s\n' "$REAL_HITS"
    exit 1
fi

echo "OK: @unchecked Sendable / nonisolated(unsafe) count = $ACTUAL_COUNT (baseline $BASELINE_COUNT). All confined to allowlisted files."
