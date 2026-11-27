#!/usr/bin/env bash
# check_strict_concurrency_enabled.sh — proves the compiler is the concurrency
# gate: every build configuration is in Swift 6 language mode with
# `SWIFT_STRICT_CONCURRENCY = complete`, and warnings are errors in every
# configuration that ships: Debug and Release of the app and the watch app,
# read as Xcode resolves them (the target's own setting, else the project's).
#
# The compiler already fails the ordinary build on an isolation hazard. What
# an ordinary build cannot catch is someone REMOVING the setting, which turns
# everything green while nothing is checked. That needs no build, so this runs
# on the Ubuntu lint path in seconds.
#
# To measure against a different level or language version:
#
#     STRICT_CONCURRENCY_LEVEL=complete SWIFT_LANGUAGE_VERSION=6.0 ./scripts/check_strict_concurrency_enabled.sh

set -uo pipefail

cd "$(dirname "$0")/.."

PROJECT_FILE="Emuqu.xcodeproj/project.pbxproj"
EXPECTED_LEVEL="${STRICT_CONCURRENCY_LEVEL:-complete}"
EXPECTED_SWIFT_VERSION="${SWIFT_LANGUAGE_VERSION:-6.0}"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

[[ -f "$PROJECT_FILE" ]] || fail "$PROJECT_FILE not found"

# One `SWIFT_VERSION` per build configuration is the reliable denominator —
# every configuration that compiles Swift has one.
# The counts below read only the plain `KEY = value;` spelling. Xcode also
# applies conditional settings ("KEY[sdk=iphoneos*]" = ...), compiler flags in
# OTHER_SWIFT_FLAGS and xcconfig files, and each can switch off what the
# counts report as on, for the device build alone.
override_report="$(python3 - "$PROJECT_FILE" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
KEYS = r"(?:SWIFT_VERSION|SWIFT_STRICT_CONCURRENCY|SWIFT_TREAT_WARNINGS_AS_ERRORS|OTHER_SWIFT_FLAGS)"
for m in re.finditer(r'^\s*"?' + KEYS + r'\[[^\]]*\]"?\s*=', text, re.M):
    print("conditional setting: " + m.group(0).strip())
FLAGS = re.compile(r"-swift-version|-language-mode|-strict-concurrency|-no-warnings-as-errors|-suppress-warnings|-Wwarning")
for m in re.finditer(r'OTHER_SWIFT_FLAGS"?\s*=\s*(\([^)]*\)|[^;]*);', text):
    if FLAGS.search(m.group(1)):
        print("OTHER_SWIFT_FLAGS overrides the language mode or warnings: " + " ".join(m.group(1).split())[:120])
if "baseConfigurationReference" in text:
    print("a configuration reads an xcconfig file, which this gate does not parse")
PY
)"
if [[ -n "$override_report" ]]; then
    fail "$(printf '%s\n\n%s' "$override_report" "Set these as plain per-configuration settings so the counts below see them.")"
fi

configs=$(grep -c 'SWIFT_VERSION = ' "$PROJECT_FILE" | tr -d ' ')
strict=$(grep -c "SWIFT_STRICT_CONCURRENCY = ${EXPECTED_LEVEL};" "$PROJECT_FILE" | tr -d ' ')
swift6=$(grep -c "SWIFT_VERSION = ${EXPECTED_SWIFT_VERSION};" "$PROJECT_FILE" | tr -d ' ')

echo "Strict concurrency: ${strict}/${configs} configurations at '${EXPECTED_LEVEL}'"
echo "Swift language mode: ${swift6}/${configs} configurations at ${EXPECTED_SWIFT_VERSION}"

if (( strict < configs )); then
    fail "$(cat <<EOF
strict concurrency is not set in every build configuration ($strict of $configs).

A configuration without it compiles without data-race checking, and nothing else
in CI would notice — the build simply goes green. Set
'SWIFT_STRICT_CONCURRENCY = $EXPECTED_LEVEL;' in every configuration, or, if a
target genuinely cannot support it yet, say which and why in this script rather
than leaving the gap silent.
EOF
)"
fi

if (( swift6 < configs )); then
    fail "$(cat <<EOF
Swift ${EXPECTED_SWIFT_VERSION} language mode is not set in every build configuration ($swift6 of $configs).
Swift 6 mode is what turns every data-race diagnostic into a compile error; a
configuration left in Swift 5 mode reports them as warnings and the build goes
green. Set 'SWIFT_VERSION = ${EXPECTED_SWIFT_VERSION};' in every configuration.
EOF
)"
fi

# Warnings as errors, per shipping target and configuration. A count of YES
# lines anywhere passes with the setting gone from Release, or overridden to
# NO in one target, so each one is resolved the way Xcode resolves it.
SHIPPING_TARGETS=("Emuqu" "EmuquWatch Watch App")
SHIPPING_CONFIGS=("Debug" "Release")
werror_report="$(python3 - "$PROJECT_FILE" "${#SHIPPING_TARGETS[@]}" "${SHIPPING_TARGETS[@]}" "${SHIPPING_CONFIGS[@]}" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
count = int(sys.argv[2])
targets, configs = sys.argv[3:3 + count], sys.argv[3 + count:]
OBJECT = re.compile(r"^\t\t(\w+) /\*[^*]*\*/ = \{\n(.*?)^\t\t\};", re.S | re.M)


def section(name):
    m = re.search(r"/\* Begin " + name + r" section \*/(.*?)/\* End " + name + r" section \*/", text, re.S)
    return m.group(1) if m else ""


def field(body, key):
    m = re.search(r"\b" + key + r" = ([^;]+);", body)
    return m.group(1).split(" /*")[0].strip().strip('"') if m else None


build = {ident: (field(body, "name"), field(body, "SWIFT_TREAT_WARNINGS_AS_ERRORS"))
         for ident, body in OBJECT.findall(section("XCBuildConfiguration"))}
lists = {ident: re.findall(r"^\t\t\t\t(\w+) /\*", body, re.M)
         for ident, body in OBJECT.findall(section("XCConfigurationList"))}


def by_name(list_id):
    return {build[c][0]: build[c][1] for c in lists.get(list_id, []) if c in build}


project = by_name(field(section("PBXProject"), "buildConfigurationList") or "")
native = {field(body, "name"): by_name(field(body, "buildConfigurationList") or "")
          for _, body in OBJECT.findall(section("PBXNativeTarget"))}

missing = []
for target in targets:
    for config in configs:
        if config not in native.get(target, {}):
            print(f"{target} has no {config} configuration in the project")
            raise SystemExit(2)
        own = native[target][config]
        effective = own if own is not None else project.get(config)
        print(f"Warnings as errors: {target} {config}: {effective or 'unset'}")
        if effective != "YES":
            missing.append(f"{target} {config}")
raise SystemExit(1 if missing else 0)
PY
)"
werror_status=$?
echo "$werror_report"
if (( werror_status == 2 )) || [[ -z "$werror_report" ]]; then
    echo "check_strict_concurrency_enabled: cannot resolve the shipping build settings." >&2
    exit 2
fi
if (( werror_status != 0 )); then
    fail "$(cat <<EOF
SWIFT_TREAT_WARNINGS_AS_ERRORS is not YES in every shipping configuration.

Strict concurrency without warnings-as-errors is a report, not a gate: the
diagnostics are emitted and the build still succeeds. Both settings together are
what makes a new isolation hazard fail CI, in the Debug build CI tests and in
the Release build that ships.
EOF
)"
fi

echo "check_strict_concurrency_enabled: clean. The compiler enforces isolation; this only proves it is switched on."
