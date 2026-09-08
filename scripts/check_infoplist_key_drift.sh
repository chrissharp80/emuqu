#!/usr/bin/env bash
# CI guard for permission-string drift between pbxproj and Info.plist files.
#
# Background: when an iOS / Watch target carries an INFOPLIST_FILE AND any
# `INFOPLIST_KEY_*` build settings, Xcode merges both into the bundled
# Info.plist with `INFOPLIST_KEY_*` taking precedence. Three permission
# strings were once silently overridden this way — the detailed Info.plist
# text never shipped; users saw shorter generic stubs at the OS prompt.
#
# Invariant enforced: no `INFOPLIST_KEY_*UsageDescription` entries in
# pbxproj. Permission strings live ONLY in Info.plist files, which are
# the canonical source of truth. (`GENERATE_INFOPLIST_FILE = YES` is
# fine — Xcode's auto-injected build-time keys like CFBundleIdentifier
# are required for the bundle to install. The hazard is the
# UsageDescription overrides, which this guard catches directly.)
#
# Exits 0 on clean, 1 on any violation. Intended to run in `make ci`.

set -euo pipefail

PBXPROJ="${1:-Emuqu.xcodeproj/project.pbxproj}"

if [[ ! -f "$PBXPROJ" ]]; then
    echo "check_infoplist_key_drift: cannot find $PBXPROJ" >&2
    exit 2
fi

failed=0

hits=$(grep -nE 'INFOPLIST_KEY_NS[A-Za-z]*UsageDescription' "$PBXPROJ" || true)
if [[ -n "$hits" ]]; then
    echo "FAIL: INFOPLIST_KEY_*UsageDescription entries found in $PBXPROJ:" >&2
    echo "$hits" >&2
    echo "" >&2
    echo "Permission strings live ONLY in Info.plist files. The pbxproj" >&2
    echo "INFOPLIST_KEY_* override silently wins over Info.plist values," >&2
    echo "which is the drift this gate exists for. Move the string to the Info.plist" >&2
    echo "for the appropriate target and delete the INFOPLIST_KEY_*UsageDescription line." >&2
    failed=1
fi

if [[ "$failed" -eq 0 ]]; then
    echo "check_infoplist_key_drift: clean."
fi

exit "$failed"
