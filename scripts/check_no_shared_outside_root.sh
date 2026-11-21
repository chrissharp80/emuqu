#!/usr/bin/env bash
#
# `Type.shared` is read in the composition root and nowhere else.
#
# Why this exists. `.shared` reads spread through the app make it untestable
# with a substitute and make "who depends on what" unreadable.
# `AppDependencies` is the one place that names the singletons; everything
# else is injected: `@Environment(\.dependencies)` in
# views, an `init` parameter defaulting to `.current` in classes, and
# `AppDependencies.current` in static helpers.
#
# This gate keeps the reads where they belong. A `static let shared`
# DECLARATION is fine anywhere (that is how a service says it is a singleton);
# a `.shared` READ is allowed only in the files listed below. System types
# (`UIApplication.shared`, `URLSession.shared`, …) are not the app's business
# and are ignored.
#
# Scope is the iOS app AND the watch app. The watch is a separate target with
# singletons of its own and no `AppDependencies`; its composition root is
# `WatchDependencies.swift`, listed below, and every other watch file, its app
# struct included, has them injected, the same rule as the phone. The phone's
# app struct (`EmuquApp.swift`) is not a root either: it takes every service
# it holds from `AppDependencies.current`, so a test substitute reaches it.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

ROOT_FILES=(
    "Emuqu/Sources/Utilities/AppDependencies.swift"
    "EmuquWatch Watch App/WatchDependencies.swift"
)
SYSTEM='UIApplication|URLSession|NotificationCenter|UNUserNotificationCenter|WCSession|HKHealthStore|UIDevice|AVAudioSession|UIScreen|CLLocationManager|UIPasteboard|ProcessInfo|FileManager|UIAccessibility|SKPaymentQueue|MPMusicPlayerController|MXMetricManager|AVAudioApplication|AppTransaction|WidgetCenter|UIAccessibility'

# Fail closed: the scan must not depend on process substitution (/dev/fd),
# which some sandboxes lack; a failed substitution would read as "clean".
if ! find Emuqu "EmuquWatch Watch App" -name '*.swift' -print -quit | grep -q .; then
    echo "check_no_shared_outside_root: no Swift sources found under Emuqu or the Watch target." >&2
    exit 2
fi
hits="$(grep -rnE '(^|[^A-Za-z0-9_.])\.shared\b|\b[A-Z][A-Za-z0-9]+\.shared\b' Emuqu "EmuquWatch Watch App" --include='*.swift' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:\s*(///|//)' \
    | grep -vE "\b(${SYSTEM})\.shared\b" \
    | grep -vE 'static (let|var) shared\b' || true)"
status=0
if [[ -n "$hits" ]]; then
    while IFS= read -r line; do
        file="${line%%:*}"
        skip=0
        for root in "${ROOT_FILES[@]}"; do [[ "$file" == "$root" ]] && skip=1; done
        (( skip )) && continue
        echo "$line"
        status=1
    done <<< "$hits"
fi

if (( status )); then
    echo "check_no_shared_outside_root: \`.shared\` is read outside the composition root (above)." >&2
    echo "Inject it: @Environment(\\.dependencies) in a view, an init parameter in a class," >&2
    echo "or AppDependencies.current in a static helper." >&2
    exit 1
fi
echo "check_no_shared_outside_root: clean. \`.shared\` is read only in the composition root."
