#!/usr/bin/env bash
#
# Dependency advisories the app is not affected by stay that way.
#
# Why this exists. `security.yml`'s dependency review fails on a high or
# critical advisory, and allows one (`allow-ghsas`) only where the vulnerable
# code is unreachable from the app. "Unreachable" is a claim about our code,
# and a claim needs a gate: the day the app starts calling into the vulnerable
# path, the allowance becomes a hole. This fails that day.
#
# GHSA-g454-wj9r-jpg4 (CVE-2023-39138), Zip <= 2.1.2, no patched release:
# `Zip.unzipFile` can write outside its destination for a crafted archive.
# Zip reaches the app only through polar-ble-sdk, which calls it in one place,
# `PolarFirmwareUpdateUtils.unzipFirmwarePackage`, reached only from the
# firmware-update API (`updateFirmware`, `PolarFirmwareUpdateApi`). The app
# updates no strap firmware (Polar Flow and Polar Beat do) and imports no Zip.
#
# Exit 0 clean, 1 when the app reaches a path an allowance says it does not.
set -uo pipefail
cd "$(dirname "$0")/.."

ROOTS=("Emuqu/Sources" "EmuquWatch Watch App")
for root in "${ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
        echo "check_unreached_advisories: source root not found: $root" >&2
        exit 2
    fi
done

# Any of these in the app's own Swift reaches Zip's unzip.
# Any import form (attributes, `import struct Zip.X`), and the firmware entry
# point however it is reached: called with a space, or taken as a reference.
PATTERN='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?Zip\b|\bZip\.(unzipFile|unzip|quickUnzipFile)\b|\bupdateFirmware\b|\bPolarFirmwareUpdateApi\b|\bunzipFirmwarePackage\b'

# Each allowance in security.yml needs its reachability proof here. This gate
# proves GHSA-g454-wj9r-jpg4 only; a second allowance has none.
PROVEN_GHSAS="GHSA-g454-wj9r-jpg4"
allowed="$(grep -hoE 'allow-ghsas:.*' .github/workflows/*.yml | sed 's/allow-ghsas://' | tr ', ' '\n\n' | grep -E '^GHSA-' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [[ "$allowed" != "$PROVEN_GHSAS" ]]; then
    echo "check_unreached_advisories: workflows allow [$allowed]; this gate proves only [$PROVEN_GHSAS] unreachable." >&2
    echo "Add the reachability check for the new advisory here, or drop the allowance." >&2
    exit 1
fi

hits="$(grep -rnE --include='*.swift' "$PATTERN" "${ROOTS[@]}" || true)"
if [[ -n "$hits" ]]; then
    echo "check_unreached_advisories: the app now reaches code a dependency advisory is allowed for:" >&2
    echo "$hits" >&2
    echo "" >&2
    echo "GHSA-g454-wj9r-jpg4 (Zip path traversal, no fix) is allowed in security.yml only" >&2
    echo "because the app never unzips. Validate every entry's path before calling this," >&2
    echo "or drop the call; then remove the allowance from security.yml." >&2
    exit 1
fi
echo "check_unreached_advisories: clean. The app reaches no code an allowed advisory names."
