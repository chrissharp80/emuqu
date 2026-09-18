#!/usr/bin/env bash
#
# The strap's heart-rate feed opens when the link is established and never
# waits for the SDK to report heart rate ready.
#
# ## Why this exists
#
# Polar BLE SDK 8.x checks feature readiness on a main-run-loop timer with a
# ten-second deadline, and a feature that becomes ready after that deadline is
# never reported — although its documentation says it will be. An H10 on a busy
# phone routinely enables HR notifications later than that. Code that waits for
# the heart-rate report before subscribing therefore waits forever on exactly
# the phones that are slowest to begin with.
#
# That is not hypothetical. The subscribe was once deferred until readiness
# fired; two field logs from the same phone and strap, before and after:
#
#     before   HR monitor started  8     HR streaming ready  3
#     after    HR monitor queued  60     HR streaming ready  0
#
# Sixty reconnects, zero beats, a night of sleep lost.
#
# Heart rate now comes from the strap's standard Heart Rate Service
# (`StandardHeartRateLink`), which does not wait on the SDK's setup at all, so
# the subscription belongs at the moment the link exists; a subscription that
# ends is re-opened on a short schedule and on every link change.
#
# The rule: `StrapLinkCoordinator.linkEstablished` starts the feed, and nothing
# in `StrapHeartRateFeed` waits on heart-rate readiness or sleeps.
#
# Exit 0 clean, 1 on violation, 2 on config error.
set -uo pipefail
cd "$(dirname "$0")/.."

COORDINATOR="${1:-Emuqu/Sources/Collection/StrapLinkCoordinator.swift}"
FEED="${2:-Emuqu/Sources/Collection/StrapHeartRateFeed.swift}"
for f in "$COORDINATOR" "$FEED"; do
    if [[ ! -f "$f" ]]; then
        echo "check_hr_feed_subscribes_on_link: missing $f" >&2
        exit 2
    fi
done

python3 - "$COORDINATOR" "$FEED" <<'PY'
import pathlib
import re
import sys

def code_only(text):
    return "\n".join(line.split("//")[0] for line in text.split("\n"))

def body(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    depth, i = 0, text.find("{", start)
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return None

coordinator = code_only(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
feed = code_only(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))

established = body(coordinator, "func linkEstablished(")
if established is None:
    print("check_hr_feed_subscribes_on_link: linkEstablished not found — "
          "it was renamed or removed; re-point this gate at it.", file=sys.stderr)
    raise SystemExit(2)
if "struct StrapHeartRateFeed" not in feed:
    print("check_hr_feed_subscribes_on_link: StrapHeartRateFeed not found — "
          "re-point this gate at the heart-rate subscription.", file=sys.stderr)
    raise SystemExit(2)

problems = []
if not re.search(r"\bfeed\.start\(", established):
    problems.append("linkEstablished no longer starts the heart-rate feed")

WAITS = re.compile(
    r"(awaitFeature|whenFeatureUsable|requireUsable|isUsable|isReady|waitOutcome|state)"
    r"\(\s*(of:\s*)?\.heartRate\b|isHrStreamingReady|Task\.sleep|sleepQuietly|sleepIgnoringCancellation"
)
hit = WAITS.search(feed)
if hit:
    problems.append(f"StrapHeartRateFeed waits before subscribing (`{hit.group(0)}`)")

if not problems:
    print("check_hr_feed_subscribes_on_link: clean. "
          "The heart-rate feed opens on link and does not wait for readiness.")
    raise SystemExit(0)

for problem in problems:
    print(f"check_hr_feed_subscribes_on_link: {problem}.", file=sys.stderr)
print("\n  SDK 8.x never reports a feature that becomes ready after its ten-second\n"
      "  check, so a wait for heart rate can last the whole session. A field log\n"
      "  shows 60 reconnects and 0 beats across a night. The SDK refuses an early\n"
      "  subscribe locally and the feed re-opens it; let that do the waiting.",
      file=sys.stderr)
raise SystemExit(1)
PY
