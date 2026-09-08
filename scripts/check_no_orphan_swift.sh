#!/usr/bin/env bash
set -euo pipefail

# Every Swift file on disk must be a member of a build target.
#
# 2026-08-20 — a file-split wrote a new extension to a path that ALREADY
# existed (`HelpContent+Articles.swift`), silently destroying the five help
# categories it defined. The build caught it, but only because those symbols
# were referenced; a file of purely additive code would have vanished with no
# error at all. This is the cheap check that would have caught it directly:
# every `.swift` under the app target is referenced by project.pbxproj.

PROJECT="${1:-Emuqu.xcodeproj/project.pbxproj}"

# This scanned `Emuqu` only, so nothing under `EmuquTests`,
# `EmuquUITests` or the watch app was ever checked for target membership. That
# mattered because `scripts/add_swift_file.py` advertised `EmuquTests` support
# while hardcoding the APP target's Sources phase: a test file added with the
# mandated tool joined the wrong target, and the guard whose entire job is
# "every Swift file is in a build target" was pointed away from the one
# directory where the tool was broken. Both are fixed; the roots are now every
# directory that carries first-party Swift.
SOURCE_ROOTS=("${@:2}")
if (( ${#SOURCE_ROOTS[@]} == 0 )); then
    SOURCE_ROOTS=("Emuqu" "EmuquTests" "EmuquUITests" "EmuquWatch Watch App")
fi

# A folder registered as a PBXFileSystemSynchronizedRootGroup (Xcode 16+
# "synchronised" group) includes its contents BY BEING ON DISK — individual
# files are deliberately not listed, and `membershipExceptions` is the only way
# to remove one. Name-matching a file in such a folder against project.pbxproj
# is therefore the wrong test: it reports every file as orphaned. The watch app
# is one of these. Collect the synchronised roots and skip them, but say how
# many files were covered that way so the exemption is visible rather than
# silent.
# `mapfile` is bash 4+; macOS ships bash 3.2 and this script runs there.
SYNCED_ROOTS=()
while IFS= read -r synced_root; do
    [[ -n "$synced_root" ]] && SYNCED_ROOTS+=("$synced_root")
done < <(
    grep 'isa = PBXFileSystemSynchronizedRootGroup;' "$PROJECT" \
        | sed -E 's/.*[[:space:]]path = "?([^";]+)"?;.*/\1/' | sort -u
)

is_synced() {
    local file="$1" root
    (( ${#SYNCED_ROOTS[@]} == 0 )) && return 1
    for root in "${SYNCED_ROOTS[@]}"; do
        [[ "$file" == "$root"/* ]] && return 0
    done
    return 1
}

missing=()
scanned=0
synced=0
for root in "${SOURCE_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
        scanned=$((scanned + 1))
        if is_synced "$file"; then
            synced=$((synced + 1))
            continue
        fi
        base="$(basename "$file")"
        grep -q "/\* ${base} \*/" "$PROJECT" || missing+=("$file")
    done < <(find "$root" -name '*.swift' | sort)
done

if (( ${#missing[@]} > 0 )); then
    echo "ERROR: Swift files on disk but not in any build target:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Add them with scripts/add_swift_file.py, or delete them." >&2
    exit 1
fi

# 2026-08-25 — and no file may be in a target TWICE.
#
# The check above is one-directional: it proves every file reaches the build. It
# says nothing about a file reaching it twice, and a duplicate row in the
# Sources build phase does not fail loudly — it fails as
# "Multiple commands produce .../Foo.stringsdata", which reads like a build-system
# problem rather than a project-file problem.
#
# This happened while splitting `RecordView.swift`: the new extension was written
# to a path that already existed AND was already registered, so registering it
# again produced exactly that error. The same sitting also proved the destructive
# half of the original bug is still live — writing to an existing path silently
# replaced 201 lines of working view code, and only a "cannot find X in scope"
# from an unrelated file surfaced it. Check the path before you write it.
duplicates="$(grep -oE '[A-Za-z0-9_+.-]+\.swift in Sources \*/,' "$PROJECT" \
    | sort | uniq -d || true)"

if [[ -n "$duplicates" ]]; then
    echo "ERROR: Swift files listed more than once in a Sources build phase:" >&2
    printf '  - %s\n' $duplicates >&2
    echo >&2
    echo "Xcode reports this as 'Multiple commands produce ... .stringsdata'." >&2
    echo "Remove the duplicate PBXBuildFile row and its PBXFileReference." >&2
    exit 1
fi

echo "check_no_orphan_swift: clean. ${scanned} Swift files under ${SOURCE_ROOTS[*]} are in a target, none twice."
if (( synced > 0 )); then
    echo "check_no_orphan_swift: ${synced} of those are covered by a synchronised root group (${SYNCED_ROOTS[*]}) rather than an explicit reference."
fi
