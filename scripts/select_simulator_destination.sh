#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/xcodebuild.sh"

SCHEME="${1:-Emuqu}"
PROJECT="${2:-Emuqu.xcodeproj}"

# On a freshly started runner the simulator service can still be coming up,
# and `-showdestinations` then lists only placeholders. Ask again a few times
# before calling the machine unusable.
find_destination() {
    {
        xcodebuild "$XCODEBUILD_PINNED" -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null || true
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
    '
}

DESTINATION_ID=""
for attempt in 1 2 3 4 5; do
    DESTINATION_ID="$(find_destination)"
    [[ -n "$DESTINATION_ID" || $attempt -eq 5 ]] && break
    echo "No simulator listed yet (attempt $attempt of 5); retrying in 20 s." >&2
    sleep 20
done

if [[ -z "$DESTINATION_ID" ]]; then
    echo "No usable iOS Simulator destination found for scheme '$SCHEME'." >&2
    exit 1
fi

echo "id=${DESTINATION_ID}"
