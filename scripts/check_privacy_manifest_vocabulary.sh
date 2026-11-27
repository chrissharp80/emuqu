#!/usr/bin/env bash
#
# Privacy manifests must use Apple's vocabulary, not plausible-looking strings.
#
# ## Why this exists
#
# `NSPrivacyCollectedDataTypeHealthData` and
# `NSPrivacyCollectedDataTypeSleepAnalysis` were in the shipped manifests. Neither is
# an Apple value — the real ones are `...TypeHealth` and `...TypeFitness`.
#
# Nothing caught it because every existing check was a SYNTAX check: `plutil`
# parses the file, the plist is well-formed, the keys are spelled correctly.
# A manifest can be perfectly valid XML and still declare a data type Apple has
# never heard of, and the failure surfaces at submission as a rejected or
# misread privacy report rather than as a build error.
#
# This validates the VALUES against Apple's published vocabulary:
#   https://developer.apple.com/documentation/bundleresources/app-privacy-configuration
#
# Adding a genuinely new Apple value means adding it here, deliberately, which
# is the point — the list is the contract.

set -uo pipefail
cd "$(dirname "$0")/.."

# Apple's NSPrivacyCollectedDataType values.
VALID_TYPES=(
    NSPrivacyCollectedDataTypeEmailAddress NSPrivacyCollectedDataTypePhoneNumber
    NSPrivacyCollectedDataTypePhysicalAddress NSPrivacyCollectedDataTypeName
    NSPrivacyCollectedDataTypeOtherUserContactInfo NSPrivacyCollectedDataTypeHealth
    NSPrivacyCollectedDataTypeFitness NSPrivacyCollectedDataTypePaymentInfo
    NSPrivacyCollectedDataTypeCreditInfo NSPrivacyCollectedDataTypeOtherFinancialInfo
    NSPrivacyCollectedDataTypePreciseLocation NSPrivacyCollectedDataTypeCoarseLocation
    NSPrivacyCollectedDataTypeSensitiveInfo NSPrivacyCollectedDataTypeContacts
    NSPrivacyCollectedDataTypeEmailsOrTextMessages NSPrivacyCollectedDataTypePhotosorVideos
    NSPrivacyCollectedDataTypeAudioData NSPrivacyCollectedDataTypeGameplayContent
    NSPrivacyCollectedDataTypeCustomerSupport NSPrivacyCollectedDataTypeOtherUserContent
    NSPrivacyCollectedDataTypeBrowsingHistory NSPrivacyCollectedDataTypeSearchHistory
    NSPrivacyCollectedDataTypeUserID NSPrivacyCollectedDataTypeDeviceID
    NSPrivacyCollectedDataTypePurchaseHistory NSPrivacyCollectedDataTypeProductInteraction
    NSPrivacyCollectedDataTypeAdvertisingData NSPrivacyCollectedDataTypeOtherUsageData
    NSPrivacyCollectedDataTypeCrashData NSPrivacyCollectedDataTypePerformanceData
    NSPrivacyCollectedDataTypeOtherDiagnosticData NSPrivacyCollectedDataTypeEnvironmentScanning
    NSPrivacyCollectedDataTypeHands NSPrivacyCollectedDataTypeHead
    NSPrivacyCollectedDataTypeOtherDataTypes
)

VALID_PURPOSES=(
    NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising
    NSPrivacyCollectedDataTypePurposeDeveloperAdvertising
    NSPrivacyCollectedDataTypePurposeAnalytics
    NSPrivacyCollectedDataTypePurposeProductPersonalization
    NSPrivacyCollectedDataTypePurposeAppFunctionality
    NSPrivacyCollectedDataTypePurposeOther
)

manifests=()
# Tracked manifests only. Build output and nested checkouts hold copies,
# which would report a value that is already fixed in the tree. Read through
# a here-string rather than process substitution so a sandbox without
# /dev/fd cannot turn an unread list into a clean result.
found="$(git ls-files -- '*PrivacyInfo.xcprivacy' | sed 's#^#./#' | sort)"
if [[ -n "$found" ]]; then
    while IFS= read -r line; do manifests+=("$line"); done <<< "$found"
fi

if (( ${#manifests[@]} == 0 )); then
    echo "check_privacy_manifest_vocabulary: no manifests found." >&2
    exit 2
fi

bad=0
checked=0
for manifest in "${manifests[@]}"; do
    while IFS= read -r value; do
        [[ -z "$value" ]] && continue
        checked=$((checked + 1))
        found=0
        for valid in "${VALID_TYPES[@]}"; do
            [[ "$value" == "$valid" ]] && { found=1; break; }
        done
        if (( found == 0 )); then
            echo "ERROR: ${manifest#./} declares '$value', which is not an Apple data type." >&2
            bad=$((bad + 1))
        fi
    done < <(python3 -c "
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
for entry in d.get('NSPrivacyCollectedDataTypes', []):
    print(entry.get('NSPrivacyCollectedDataType', ''))
" "$manifest")

    while IFS= read -r value; do
        [[ -z "$value" ]] && continue
        checked=$((checked + 1))
        found=0
        for valid in "${VALID_PURPOSES[@]}"; do
            [[ "$value" == "$valid" ]] && { found=1; break; }
        done
        if (( found == 0 )); then
            echo "ERROR: ${manifest#./} declares purpose '$value', which is not an Apple value." >&2
            bad=$((bad + 1))
        fi
    done < <(python3 -c "
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
for entry in d.get('NSPrivacyCollectedDataTypes', []):
    for p in entry.get('NSPrivacyCollectedDataTypePurposes', []):
        print(p)
" "$manifest")
done

# Everything the two loops above do not read: a manifest that does not parse
# (the loops print nothing for it), the top-level keys, tracking, and the
# required-reason API declarations, checked against Apple's categories and
# reason codes and against the APIs each target's own sources call.
#   https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
python3 -I - "${manifests[@]}" <<'PY'
import pathlib, plistlib, re, sys
REASONS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}
USES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp": r"\b(?:creationDate|modificationDate|contentModificationDate\w*|creationDateKey|attributeModificationDate\w*|fileModificationDate)\b|\battributesOfItem\b|\bgetattrlist\b|\b[fl]?stat\(",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|\bmach_absolute_time\b|\bkern\.boottime\b",
    "NSPrivacyAccessedAPICategoryDiskSpace": r"\bvolumeAvailableCapacity\w*|\bvolumeTotalCapacity\w*|\bsystemFreeSize\b|\bsystemSize\b|\bstatv?fs\(",
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"\bactiveInputModes\b",
}
TOP = {"NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}
bad = 0
def err(msg):
    global bad
    bad += 1
    print("ERROR: " + msg, file=sys.stderr)
for manifest in sys.argv[1:]:
    name = manifest[2:] if manifest.startswith("./") else manifest
    try:
        d = plistlib.load(open(manifest, "rb"))
    except Exception as exc:
        err(f"{name} does not parse: {exc}")
        continue
    for key in sorted(set(d) - TOP):
        err(f"{name} has key '{key}', which is not a privacy manifest key.")
    if d.get("NSPrivacyTracking") is not False or d.get("NSPrivacyTrackingDomains", []) != []:
        err(f"{name} declares tracking or tracking domains; the app does not track.")
    declared = {}
    for entry in d.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType", "")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        if category not in REASONS:
            err(f"{name} declares API category '{category}', which is not an Apple value.")
            continue
        if not reasons:
            err(f"{name} declares {category} with no reason.")
        for reason in reasons:
            if reason not in REASONS[category]:
                err(f"{name} gives {category} reason '{reason}', which is not one of Apple's for it.")
        declared[category] = reasons
    root = pathlib.Path(manifest).parent
    text = "\n".join(p.read_text(encoding="utf-8", errors="ignore")
                     for p in sorted(root.rglob("*")) if p.suffix in (".swift", ".m", ".c") and p.is_file())
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)
    for category, pattern in USES.items():
        if re.search(pattern, text) and category not in declared:
            err(f"{name}: sources under {root}/ call a {category} API the manifest does not declare.")
sys.exit(1 if bad else 0)
PY
(( $? == 0 )) || bad=$((bad + 1))

if (( bad > 0 )); then
    echo >&2
    echo "A privacy manifest can be valid XML and still declare a type Apple has never" >&2
    echo "heard of. That is rejected or misread at submission, not at build time." >&2
    echo "Apple's vocabulary: https://developer.apple.com/documentation/bundleresources/app-privacy-configuration" >&2
    exit 1
fi

if (( checked == 0 )); then
    echo "check_privacy_manifest_vocabulary: read ${#manifests[@]} manifest(s) but checked no values; refusing to report clean." >&2
    exit 2
fi
echo "check_privacy_manifest_vocabulary: clean. ${#manifests[@]} manifest(s), $checked value(s), all Apple-defined."
