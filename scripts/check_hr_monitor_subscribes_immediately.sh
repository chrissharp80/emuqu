#!/usr/bin/env bash
#
# The connect-time HR monitor must subscribe IMMEDIATELY, never after a wait.
#
# ## Why this exists
#
# `PolarManager.startHRMonitoring` opens the strap's HR stream as soon as
# `deviceConnected` fires. Doing so answers `notificationNotEnabled`, and
# sometimes `gattDisconnected`, because the H10 has not finished publishing its
# services — which reads exactly like a bug worth deferring around, and is not.
#
# That subscription is what PROMPTS the H10 to enable HR notifications, and
# therefore what makes `bleSdkFeatureReady(.feature_hr)` fire. Deferring it
# until the feature reports ready waits for an event only the deferred action
# can cause.
#
# It was deferred on exactly that reasoning. Two field logs from the same phone
# and the same strap, before and after:
#
#     before   Started live HR monitoring  8     HR streaming ready  3
#     after    Live HR monitoring queued  60     HR streaming ready  0
#
# Sixty reconnect attempts, zero beats, a whole night of sleep lost — and the
# streaming path failed with it, because it waits on the same flag.
#
# The rule: nothing between `startHRMonitoring` and the stream subscription may
# wait on readiness. Fix the log noise by classifying the early error (see
# `logHRMonitorError`), never by delaying the subscribe.
#
# Exit 0 clean, 1 on violation, 2 on config error.
set -uo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-Emuqu/Sources/Collection/PolarManager+Observers.swift}"
if [[ ! -f "$FILE" ]]; then
    echo "check_hr_monitor_subscribes_immediately: missing $FILE" >&2
    exit 2
fi

python3 - "$FILE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

start = text.find("func startHRMonitoring(")
if start < 0:
    print("check_hr_monitor_subscribes_immediately: startHRMonitoring not found — "
          "it was renamed or removed; re-point this gate at it.", file=sys.stderr)
    raise SystemExit(2)

# The function body, brace-matched.
depth, i = 0, start
while i < len(text):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
body = text[start:i + 1]

# Anything that waits for readiness, or hands the subscription to something
# that might, before the stream is opened.
WAITS = re.compile(
    r"isHrStreamingReady|waitForHrStreamingFeature|awaitHrFeatureReady|featureReady|"
    r"sleepQuietly|sleepIgnoringCancellation|Task\.sleep"
)
hit = WAITS.search(body)
if hit is None:
    print("check_hr_monitor_subscribes_immediately: clean. "
          "The connect-time HR monitor subscribes without waiting.")
    raise SystemExit(0)

print("check_hr_monitor_subscribes_immediately: startHRMonitoring waits before subscribing "
      f"(`{hit.group(0)}`).\n", file=sys.stderr)
print("  That subscription is what makes the strap enable HR notifications, so a\n"
      "  wait for `feature_hr` waits for something only the subscribe can cause.\n"
      "  It deadlocks the whole session: a field log shows 60 reconnects and 0\n"
      "  beats across an entire night.\n\n"
      "  If the early `notificationNotEnabled` / `gattDisconnected` noise is the\n"
      "  problem, classify it in `logHRMonitorError` — do not delay the subscribe.",
      file=sys.stderr)
raise SystemExit(1)
PY
