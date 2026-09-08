#!/usr/bin/env bash
#
# The debug logger must never log through itself.
#
# Why this exists. `DebugLogger.init` relaxes the log file's protection so
# overnight writes succeed while the phone is locked. Route that call through
# `attempt(...)` and a failure calls `debugLog`, which resolves
# `DebugLogger.shared`, whose once-initialiser is the frame already running: a
# recursive `swift_once` on the very first log line of the process, and the
# app hangs on the splash screen in exactly the case the call exists for (a
# log file still carrying `.complete`). The logger's own
# failures go to `NSLog`; nothing in its file may call `attempt(` or
# `debugLog(`.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

file="Emuqu/Sources/Utilities/DebugLog.swift"
if [[ ! -s "$file" ]]; then
    echo "check_logger_self_reference: missing input $file" >&2
    exit 2
fi

# `attempt(` is never legitimate in this file. `debugLog(` is the file's own
# entry point, so only calls made from inside the `DebugLogger` class body
# count: the free functions after it (`debugLog`, `debugLogExternal`) are the
# API, not the logger calling itself.
hits="$(awk '
    /^(final )?class DebugLogger/ { inside = 1 }
    inside && /^}/ { inside = 0 }
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line ~ /^\/\//) next
        if (line ~ /(^|[^A-Za-z0-9_])attempt\(/) { print NR ": " $0; next }
        if (inside && line ~ /(^|[^A-Za-z0-9_])debugLog\(/ && line !~ /func debugLog\(/) print NR ": " $0
    }
' "$file")"
if [[ -n "$hits" ]]; then
    echo "check_logger_self_reference: DebugLog.swift calls the logger from inside the logger:" >&2
    echo "$hits" >&2
    echo >&2
    echo "Report the logger's own failures with NSLog. A call through attempt/debugLog" >&2
    echo "re-enters DebugLogger.shared from its own initialiser and hangs the launch." >&2
    exit 1
fi
echo "check_logger_self_reference: clean."
