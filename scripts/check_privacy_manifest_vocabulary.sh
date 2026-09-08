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
# Source manifests only. Build output contains copies from previous builds,
# which would report a value that is already fixed in the tree. Read through
# a here-string rather than process substitution so a sandbox without
# /dev/fd cannot turn an unread list into a clean result.
found="$(find . -name 'PrivacyInfo.xcprivacy' \
    -not -path './.claude/*' -not -path './DerivedData/*' \
    -not -path './build/*' -not -path './.build/*' | sort)"
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
