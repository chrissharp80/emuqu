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

# Only the public entry points at file scope (`func debugLog(`,
# `func debugLogExternal(`) may reach the logger: they are the API, not the
# logger calling itself. Everything else in the file is the logger, its file
# writer `BoundedLogFile` included, and must not call `attempt(`, `debugLog(`,
# `debugLogExternal(`, or resolve the logger (`DebugLogger.shared`,
# `.debugLogger`), each of which re-enters `DebugLogger.shared`.
hits="$(awk '
    /^func (debugLog|debugLogExternal)\(/ { api = 1 }
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line ~ /^\/\//) next
        sub(/\/\/.*$/, "", line)
        if (!api && line ~ /(^|[^A-Za-z0-9_])(attempt|debugLog|debugLogExternal)\(/ && line !~ /func (debugLog|debugLogExternal)\(/) print NR ": " $0
        else if (!api && line ~ /(DebugLogger|Self)\.shared([^A-Za-z0-9_]|$)|\.debugLogger([^A-Za-z0-9_]|$)/) print NR ": " $0
    }
    api && /^}/ { api = 0 }
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
