#!/usr/bin/env bash
#
# The app must never phone home.
#
# Emuqu has no server, no account and no login. The privacy policy states
# outright that the developer receives nothing, and that claim is only as good
# as the next dependency somebody adds. This gate is what keeps it true:
#
#   1. No analytics, tracking, or crash-reporting SDK in the project or the
#      resolved package graph.
#   2. Every network host the code can reach is on the reviewed list below.
#
# Rule 2 is the one that matters. A first-party telemetry endpoint would not
# announce itself as an SDK — it would be one `URL(string:)` in a service class,
# and nothing else in CI would notice. Adding a host here is a deliberate act
# that shows up in a diff next to the reason.
#
# Written 2026-08-27, after a reader assumed the app collected data and
# nothing in the repository could prove otherwise in one command.

set -uo pipefail

cd "$(dirname "$0")/.."

SOURCES=("Emuqu/Sources" "EmuquWatch Watch App")

python3 - "${SOURCES[@]}" <<'PY'
import pathlib
import re
import sys

# Hosts the app is allowed to contact. Each is either a service the user opts
# into with their own credentials, an open public API, or a documentation link
# rendered as a tappable URL. NONE of them is controlled by the developer.
ALLOWED = {
    # Hosted AI providers. Opt-in, user-supplied API key, user's own account.
    "api.anthropic.com", "api.openai.com", "api.deepseek.com", "api.x.ai",
    "generativelanguage.googleapis.com", "ai.google.dev", "cdn.deepseek.com",
    # Optional web search. Opt-in, user-supplied key.
    "api.tavily.com", "app.tavily.com", "tavily.com",
    "x.ai",   # xAI docs link, alongside api.x.ai above
    # Open geodata / weather. No account, no key, coordinates coarsened first.
    "nominatim.openstreetmap.org", "overpass-api.de",
    "api.met.no",
    "api.opentopodata.org", "www.opentopodata.org",
    "overpass.private.coffee", "private.coffee",
    # Attribution and licence links shown on the open-source licences screen.
    "www.openstreetmap.org", "creativecommons.org", "www.met.no", "huggingface.co", "www.apache.org",
    # Documentation, policy and reference links shown to the user.
    "developer.apple.com", "www.apple.com", "maps.apple.com",
    "docs.claude.com", "platform.claude.com", "www.anthropic.com",
    "openai.com", "platform.openai.com", "policies.google.com", "www.google.com",
    "github.com", "forums.swift.org", "www.hackingwithswift.com", "easings.net",
    "en.wikipedia.org", "pubmed.ncbi.nlm.nih.gov", "pmc.ncbi.nlm.nih.gov",
    "www.frontiersin.org", "www.trainingimpulse.com", "www.trainingpeaks.com",
    "fellrnr.com", "polar.com", "www.garmin.com", "www.concept2.cn",
    "www.bluetooth.com", "www.topografix.com", "www.w3.org",
    # Official sources cited beside the emergency-number table (comments only).
    "jp.usembassy.gov", "english.seoul.go.kr", "english.gov.taipei", "en.nhc.gov.cn", "www.gov.pl",
}

URL = re.compile(r"https?://([A-Za-z0-9.-]+)")

found = {}
for root in sys.argv[1:]:
    base = pathlib.Path(root)
    if not base.exists():
        continue
    for path in sorted(base.rglob("*.swift")):
        for lineno, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
            for match in URL.finditer(line):
                found.setdefault(match.group(1), []).append(f"{path}:{lineno}")

unknown = {h: locs for h, locs in found.items() if h not in ALLOWED}

if unknown:
    print(f"check_no_developer_endpoint: {len(unknown)} unreviewed host(s).\n")
    for host, locs in sorted(unknown.items()):
        print(f"  {host}")
        for loc in locs[:3]:
            print(f"      {loc}")
    print()
    print("  The privacy policy tells users the developer receives nothing and")
    print("  that the app has no analytics or tracking. A new host is either a")
    print("  contradiction of that, or an omission from the reviewed list in")
    print("  this script. Add it here with the reason, or remove it.")
    raise SystemExit(1)

print(f"check_no_developer_endpoint: clean. {len(found)} hosts, all reviewed, none developer-controlled.")
PY
status=$?
[[ $status -ne 0 ]] && exit $status

# Analytics / tracking / crash-reporting SDKs, in the project and in the
# resolved package graph. Presence alone contradicts the policy.
BANNED='firebase|mixpanel|amplitude|segment\.com|sentry|bugsnag|crashlytics|appsflyer|posthog|datadog|adjust\.com|braze|onesignal|flurry|newrelic'
hits=$(grep -riE "$BANNED" \
    Emuqu.xcodeproj/project.pbxproj \
    Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    2>/dev/null | wc -l | tr -d ' ')

if [[ "$hits" != "0" ]]; then
    echo "check_no_developer_endpoint: analytics/telemetry SDK detected in the dependency graph." >&2
    grep -riE "$BANNED" Emuqu.xcodeproj/project.pbxproj \
        Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null | head -5 >&2
    exit 1
fi

echo "check_no_developer_endpoint: no analytics, tracking, or crash-reporting SDK in the graph."

# ---------------------------------------------------------------------------
# CVE-2023-39135 / GHSA-g454-wj9r-jpg4 — path traversal in Zip through 2.1.2.
#
# Zip 2.1.2 is in the resolved graph, pulled in transitively by polar-ble-sdk
# for its firmware-update utility. There is no patched release: the advisory
# still matches the latest version, so "upgrade" is not a remedy.
#
# A reachability determination is worth more than an
# inventory entry. The determination is that the vulnerable extraction path is
# unreachable from this app: Emuqu never imports Zip, never calls `unzipFile`,
# and never invokes Polar's firmware-update API — the only firmware references
# are a version string surfaced as an assistant fact and an error message
# telling the user to update through Polar's own app.
#
# A determination is only worth the check that keeps it true. If someone adds a
# firmware-update feature or a direct Zip call, this goes red and the CVE has
# to be reassessed against real usage rather than assumed away.
zip_hits="$(grep -rnE '^import Zip$|\bZip\.(unzipFile|quickUnzipFile|zipFiles|quickZipFiles)' \
    Emuqu "EmuquWatch Watch App" 2>/dev/null || true)"
if [[ -n "$zip_hits" ]]; then
    echo "ERROR: app code now reaches the Zip package, which has an unpatched" >&2
    echo "path-traversal advisory (CVE-2023-39135) with no fixed release:" >&2
    echo "$zip_hits" >&2
    echo >&2
    echo "The non-exploitability decision recorded here assumed no such call." >&2
    echo "Re-assess before shipping: malicious-archive tests for traversal," >&2
    echo "absolute paths and symlink escape are required wherever extraction runs." >&2
    exit 1
fi

firmware_hits="$(grep -rnE '\.(updateFirmware|firmwareUpdate)\(|PolarFirmwareUpdate' \
    Emuqu "EmuquWatch Watch App" 2>/dev/null || true)"
if [[ -n "$firmware_hits" ]]; then
    echo "ERROR: app code now calls Polar's firmware-update API, which is the" >&2
    echo "route to the vulnerable Zip extraction:" >&2
    echo "$firmware_hits" >&2
    exit 1
fi

echo "check_no_developer_endpoint: Zip advisory unreachable — no Zip import, no unzip call, no firmware-update API."
