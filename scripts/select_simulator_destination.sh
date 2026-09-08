#!/usr/bin/env bash
set -euo pipefail

SCHEME="${1:-Emuqu}"
PROJECT="${2:-Emuqu.xcodeproj}"

DESTINATION_ID="$({
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null || true
} | awk '
    /platform:iOS Simulator/ && $0 !~ /placeholder/ {
        if (match($0, /id:[^,]*/)) {
            id = substr($0, RSTART + 3, RLENGTH - 3)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
            if (fallback == "") {
                fallback = id
            }
            if ($0 ~ /name:iPhone/) {
                print id
                found = 1
                exit
            }
        }
    }
    END {
        if (found != 1 && fallback != "") {
            print fallback
        }
    }
')"

if [[ -z "$DESTINATION_ID" ]]; then
    echo "No usable iOS Simulator destination found for scheme '$SCHEME'." >&2
    exit 1
fi

echo "id=${DESTINATION_ID}"
