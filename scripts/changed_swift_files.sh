#!/usr/bin/env bash
set -euo pipefail

# Emits changed Swift files (one per line) for the current GitHub event.
event_name="${GITHUB_EVENT_NAME:-}"
base_sha="${PR_BASE_SHA:-}"
before_sha="${PUSH_BEFORE_SHA:-}"

range=""
if [[ "$event_name" == "pull_request" || "$event_name" == "pull_request_target" ]]; then
    if [[ -n "$base_sha" ]]; then
        range="${base_sha}...HEAD"
    fi
elif [[ "$event_name" == "push" ]]; then
    if [[ -n "$before_sha" && "$before_sha" != "0000000000000000000000000000000000000000" ]]; then
        range="${before_sha}...HEAD"
    fi
fi

if [[ -z "$range" ]]; then
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        range="HEAD~1...HEAD"
    else
        range="HEAD"
    fi
fi

git diff --name-only --diff-filter=ACMR "$range" -- '*.swift'
