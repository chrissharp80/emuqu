#!/usr/bin/env bash
#
# Code handed its dependencies does not reach for the container, and only
# tests put a container in force.
#
# Why this exists. `AppDependencies.current` is a process-wide container any
# code can read, and a read inside a function is an edge that its signature
# does not show. The files listed below are handed exactly the services they
# use by the composition root (`AppDependencies.launchServices`,
# `AppDependencies.purgeStores`, and `AppDependencies.makeSessionReanalysis`
# for the reanalysis service, its coordinator and the scoring context; fact
# namespaces get a `FactServices` from `AppFactResolverFactory.build`, and the
# workout recorder and its parts a `WorkoutServices` from `RecorderBox`, and
# the chat view model, its router and tool runner a `ChatServices`, and the
# assistant's context source and builder a `ContextServices`, and the voice
# conversation and its audio pipeline a `VoiceServices`, and the AI providers
# an `AIProviderServices` from the registry, and the recording collector's
# parts the `CollectorServices` the collector holds), and
# their tests construct them with substitutes. One new
# `AppDependencies.current` read in them hides an edge again and puts the
# tests back on the live services.
#
# `AppDependencies.current` has no setter; `AppDependencies.install(_:)` is
# the only way to put another container in force, and it is for tests. The
# app runs on the live container `current` starts with, so a call in either
# app target is a container swapped under running code.
#
# Rules, comment lines excepted:
#   1. no `AppDependencies.current`, and no service list built from it
#      (`XServices(.current)`), in an EXPLICIT file;
#   2. no `AppDependencies.install(` in `Emuqu/` or the Watch target.
# See docs/adr/007-single-target-composition-root.md.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

# Each pattern must match at least one file: a renamed file would otherwise
# leave the rule checking nothing and reporting clean.
EXPLICIT_PATTERNS=(
    "Emuqu/Sources/Services/AppLaunchTasks*.swift"
    "Emuqu/Sources/Services/DataPurgeService*.swift"
    "Emuqu/Sources/Services/ReanalysisService*.swift"
    "Emuqu/Sources/Collection/SessionReanalysisCoordinator*.swift"
    "Emuqu/Sources/Collection/SessionScoringContext.swift"
    "Emuqu/Sources/Models/*.swift"
    "Emuqu/Sources/Storage/*.swift"
    "Emuqu/Sources/Analysis/*.swift"
    "Emuqu/Sources/Analysis/*/*.swift"
    "Emuqu/Sources/Assistant/Facts/AppFactResolver.swift"
    "Emuqu/Sources/Assistant/Facts/*Facts.swift"
    "Emuqu/Sources/Assistant/Facts/FactNumericArguments.swift"
    "Emuqu/Sources/Assistant/Facts/FactServices.swift"
    "Emuqu/Sources/Collection/WorkoutRecorder*.swift"
    "Emuqu/Sources/Collection/WorkoutTicker.swift"
    "Emuqu/Sources/Collection/WorkoutSessionLifecycle.swift"
    "Emuqu/Sources/Collection/WorkoutFinalizer.swift"
    "Emuqu/Sources/Collection/WorkoutAIContextBuilder.swift"
    "Emuqu/Sources/Collection/WorkoutServices.swift"
    "Emuqu/Sources/Assistant/ViewModel/*.swift"
    "Emuqu/Sources/Assistant/Context/ContextBuilder*.swift"
    "Emuqu/Sources/Assistant/Context/ContextServices.swift"
    "Emuqu/Sources/Assistant/Chat/AssistantContextSource.swift"
    "Emuqu/Sources/Assistant/VoiceConversationController*.swift"
    "Emuqu/Sources/Assistant/VoiceAudioPipeline*.swift"
    "Emuqu/Sources/Assistant/VoiceServices.swift"
    "Emuqu/Sources/Services/BreadcrumbRecorder.swift"
    "Emuqu/Sources/Assistant/Providers/*.swift"
    "Emuqu/Sources/Collection/RRCollector+*.swift"
)
APP_DIRS=("Emuqu" "EmuquWatch Watch App")

status=0
explicit=()
for pattern in "${EXPLICIT_PATTERNS[@]}"; do
    matched=0
    for file in $pattern; do
        [[ -f "$file" ]] || continue
        explicit+=("$file")
        matched=1
    done
    if (( ! matched )); then
        echo "check_explicit_dependencies: no file matches $pattern." >&2
        exit 2
    fi
done

# Prints the non-comment lines of the named files that match $1.
code_hits() {
    local pattern="$1"
    shift
    grep -nHE "$pattern" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:\s*(///|//|\*)' || true
}

# `XServices(.current)` builds a service list from the container in force, so
# it is the same lookup spelled shorter.
# Also the shorter spellings of the same read: a parameter or property
# defaulted from it (`deps: AppDependencies = .current`), `AppDependencies.self`,
# and an alias of the container type (`typealias D = AppDependencies`), which
# every spelling above would otherwise miss.
lookups="$(code_hits 'AppDependencies([[:space:]]*\.[[:space:]]*self)?[[:space:]]*\.[[:space:]]*current\b|Services\([[:space:]]*\.current[[:space:]]*\)|:[[:space:]]*AppDependencies[[:space:]]*[!?]?[[:space:]]*=[[:space:]]*\.current\b|typealias[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*AppDependencies\b' "${explicit[@]}")"
if [[ -n "$lookups" ]]; then
    echo "$lookups"
    echo "check_explicit_dependencies: \`AppDependencies.current\` is read in a file handed its dependencies (above)." >&2
    echo "Add the service to the set the composition root hands it instead." >&2
    status=1
fi

for dir in "${APP_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        echo "check_explicit_dependencies: $dir not found." >&2
        exit 2
    fi
done
installs="$(grep -rnE 'AppDependencies([[:space:]]*\.[[:space:]]*self)?[[:space:]]*\.[[:space:]]*install[[:space:]]*\(|typealias[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*AppDependencies\b' "${APP_DIRS[@]}" --include='*.swift' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:\s*(///|//|\*)' || true)"
if [[ -n "$installs" ]]; then
    echo "$installs"
    echo "check_explicit_dependencies: \`AppDependencies.install\` is called in app code (above); it is for tests." >&2
    status=1
fi

if (( status )); then
    exit 1
fi
echo "check_explicit_dependencies: clean. ${#explicit[@]} file(s) take their dependencies explicitly; no container is installed in app code."
