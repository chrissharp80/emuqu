#!/usr/bin/env bash
#
# CoreMotion callback closures must say which actor they run on.
#
# ## Why this exists
#
# `CMPedometerHandler` and its siblings are Objective-C block types that predate
# Sendable, so they are NOT `@Sendable` in the generated Swift interface. Form
# one of these closures inside a `@MainActor` type and Swift gives it INHERITED
# main-actor isolation, then emits an executor precondition at the closure's
# entry. CoreMotion delivers on its own dispatch workloop, so that precondition
# runs `dispatch_assert_queue(main)` — and libdispatch answers a failed queue
# assertion with `__builtin_trap()`.
#
# The result is a SIGTRAP inside the first callback, with nothing in the crash
# log that names the app except the closure itself. It cost a user their entire
# walk: the app died about a second after Start, iOS did not relaunch it, and
# the session recovered at next launch was one second long. Nothing catches this
# earlier — it compiles without a warning, it cannot happen in the simulator
# tests because there is no motion coprocessor there, and it depends on which
# queue CoreMotion happens to pick.
#
# ## The rule
#
# Every CoreMotion callback closure must be one of:
#
#   * delivered to an explicit queue (`to: .main`, `to: someQueue`) — then the
#     isolation is the queue's and the call site says so; or
#   * marked `@Sendable` — then the closure is nonisolated, no executor check is
#     emitted, and whatever it needs on the main actor it hops to explicitly.
#
# What is banned is the third case: a bare closure whose isolation is inherited
# invisibly from its surroundings and asserted at runtime on someone else's
# thread.
#
# Exit 0 clean, 1 on violation, 2 on config error.
set -uo pipefail
cd "$(dirname "$0")/.."

if (( $# == 0 )); then
    SOURCE_ROOTS=("Emuqu" "EmuquWatch Watch App")
else
    SOURCE_ROOTS=("$@")
fi

if ! find "${SOURCE_ROOTS[@]}" -name '*.swift' -print -quit 2>/dev/null | grep -q .; then
    echo "check_coremotion_handler_isolation: no Swift sources found under: ${SOURCE_ROOTS[*]}" >&2
    exit 2
fi

python3 - "${SOURCE_ROOTS[@]}" <<'PY'
import pathlib
import re
import sys

# CoreMotion entry points that take a completion/update block AND let the call
# name the queue it is delivered on. Their Objective-C selectors all end
# `...ToQueue:withHandler:`, which imports into Swift as a `to:` label — so on
# these, and only these, `to:` means "the isolation is stated".
QUEUE_DELIVERED_APIS = (
    "startRelativeAltitudeUpdates",
    "startAbsoluteAltitudeUpdates",
    "startDeviceMotionUpdates",
    "startAccelerometerUpdates",
    "startGyroUpdates",
    "startMagnetometerUpdates",
    "startActivityUpdates",
    "queryActivityStarting",
)

# Entry points with NO queue parameter: CoreMotion picks the thread. These take
# a `to:` that is NOT a queue — `queryPedometerData(from:to:)` bounds a date
# range — so accepting `to:` as proof of isolation here would exempt every call
# to them and report clean while measuring nothing.
SELF_QUEUED_APIS = (
    "startUpdates",
    "queryPedometerData",
)

HANDLER_APIS = QUEUE_DELIVERED_APIS + SELF_QUEUED_APIS
CALL = re.compile(r"\.(" + "|".join(HANDLER_APIS) + r")\s*\(")

def strip_comments(text):
    """Blank out // comments so a mention in prose is not a call site.

    Line-wise and literal-aware: a `//` inside a string literal is not a
    comment, and blanking from there would hide real code on the same line.
    """
    out = []
    for line in text.split("\n"):
        in_string = False
        escaped = False
        cut = None
        for index, char in enumerate(line):
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == '"':
                in_string = not in_string
                continue
            if not in_string and char == "/" and line[index + 1: index + 2] == "/":
                cut = index
                break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)

violations = []
scanned = 0

for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        scanned += 1
        for match in CALL.finditer(text):
            # The argument list up to the trailing closure's `{`. Bounded so a
            # call with no trailing closure cannot scan the rest of the file.
            window = text[match.end(): match.end() + 400]
            brace = window.find("{")
            if brace < 0:
                continue
            arguments = window[:brace]
            if match.group(1) in QUEUE_DELIVERED_APIS and re.search(r"\bto:\s*\S", arguments):
                continue  # Explicit delivery queue — isolation is stated.
            body = window[brace + 1:].lstrip()
            if body.startswith("@Sendable"):
                continue
            line = text[: match.start()].count("\n") + 1
            violations.append(f"{path}:{line}: {match.group(1)} handler is neither @Sendable nor queue-delivered")

if not violations:
    print(f"check_coremotion_handler_isolation: clean. {scanned} Swift file(s) scanned; "
          "every CoreMotion handler states its isolation.")
    raise SystemExit(0)

print("check_coremotion_handler_isolation: CoreMotion handlers with inherited isolation:\n",
      file=sys.stderr)
for violation in violations:
    print(f"  {violation}", file=sys.stderr)
print(
    "\n  A closure formed in a @MainActor type and handed to one of these"
    "\n  non-Sendable block types inherits main-actor isolation, and the"
    "\n  executor precondition Swift emits for it runs dispatch_assert_queue()"
    "\n  on CoreMotion's worker thread. libdispatch answers that with"
    "\n  __builtin_trap(): SIGTRAP, inside the first callback of the workout."
    "\n"
    "\n  Either pass a queue (`to: .main`), or mark the closure `@Sendable` and"
    "\n  hop to the main actor with the values you need.",
    file=sys.stderr,
)
raise SystemExit(1)
PY
