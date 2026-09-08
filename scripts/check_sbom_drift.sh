#!/usr/bin/env bash
#
# CI guard: the in-app open-source acknowledgements screen must mirror
# `Package.resolved` 1:1.
#
# Why this exists: `AcknowledgementsView` in
# Emuqu/Sources/Views/PrivacyPolicyView.swift is a HAND-MAINTAINED list.
# Its own code comment says so. A hand list against a resolver-generated
# file drifts, and transitive pins are the usual casualty (the WhisperKit →
# HuggingFace/Apple chain alone is eight of them); MIT/Apache/BSD notices
# are a distribution requirement and App Review does spot them.
#
# This is the same drift-guard pattern as check_infoplist_key_drift.sh:
# compare the generated source of truth against the hand-written mirror
# and fail loudly rather than hoping someone remembers.
#
# Checks, in order:
#   1. every identity in Package.resolved appears in AcknowledgementsView
#   2. every package in AcknowledgementsView still exists in Package.resolved
#   3. the version string for each matches
#
# Exit 0 clean, 1 on drift, 2 on config/parse error.

set -uo pipefail
cd "$(dirname "$0")/.."

RESOLVED="Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
ACK_VIEW="Emuqu/Sources/Views/PrivacyPolicyView.swift"

if [[ ! -f "$RESOLVED" ]]; then
    echo "check_sbom_drift: Package.resolved not found at $RESOLVED" >&2
    exit 2
fi
if [[ ! -f "$ACK_VIEW" ]]; then
    echo "check_sbom_drift: acknowledgements view not found at $ACK_VIEW" >&2
    exit 2
fi

python3 - "$RESOLVED" "$ACK_VIEW" <<'PY'
import json
import re
import sys

resolved_path, ack_path = sys.argv[1], sys.argv[2]

try:
    with open(resolved_path, encoding="utf-8") as fh:
        pins = json.load(fh).get("pins", [])
except (OSError, json.JSONDecodeError) as exc:
    sys.stderr.write(f"check_sbom_drift: cannot parse Package.resolved: {exc}\n")
    sys.exit(2)

# identity is lowercase in Package.resolved; the view uses the display name.
# Compare case-insensitively on the identity.
resolved = {}
for pin in pins:
    identity = pin.get("identity", "")
    version = (pin.get("state") or {}).get("version", "")
    if identity:
        resolved[identity.lower()] = version

source = open(ack_path, encoding="utf-8").read()

# Pull the `packages` array entries: Pkg(name: "x", version: "y", ...)
entry_re = re.compile(
    r'Pkg\(\s*name:\s*"([^"]+)"\s*,\s*version:\s*"([^"]+)"',
    re.S,
)
declared = {name.lower(): version for name, version in entry_re.findall(source)}

if not declared:
    sys.stderr.write(
        "check_sbom_drift: parsed zero Pkg(...) entries from "
        f"{ack_path}. The view's shape changed — update this guard.\n"
    )
    sys.exit(2)

missing = sorted(set(resolved) - set(declared))
extra = sorted(set(declared) - set(resolved))
mismatched = sorted(
    (name, resolved[name], declared[name])
    for name in set(resolved) & set(declared)
    if resolved[name] and resolved[name] != declared[name]
)

failed = False

if missing:
    failed = True
    print("FAIL: in Package.resolved but NOT attributed in AcknowledgementsView:")
    for name in missing:
        print(f"  - {name} ({resolved[name]})")
    print()

if extra:
    failed = True
    print("FAIL: attributed in AcknowledgementsView but no longer in Package.resolved:")
    for name in extra:
        print(f"  - {name} ({declared[name]})")
    print()

if mismatched:
    failed = True
    print("FAIL: version drift between Package.resolved and AcknowledgementsView:")
    for name, resolved_v, declared_v in mismatched:
        print(f"  - {name}: resolved={resolved_v} attributed={declared_v}")
    print()

if failed:
    print("Fix: edit the `packages` array in Emuqu/Sources/Views/PrivacyPolicyView.swift")
    print("so it mirrors Package.resolved exactly (direct AND transitive pins).")
    sys.exit(1)

print(f"check_sbom_drift: clean. {len(resolved)} SPM pins, all attributed with matching versions.")
PY
