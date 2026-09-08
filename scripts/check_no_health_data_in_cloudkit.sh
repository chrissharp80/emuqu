#!/usr/bin/env bash
#
# No personal health information may be written to iCloud in the clear.
#
# ## Why
#
# App Review Guideline 5.1.3(ii): apps "may not store personal health
# information in iCloud." The text carries no HealthKit-origin qualification.
#
# A sync path that assumes one uploads `recoveryScore` and `meanRMSSD` as
# plaintext CKRecord fields plus a compressed — not encrypted — session payload
# containing RR intervals, with nothing reading those two fields back: health
# data published to iCloud for no functional gain. Compression is not
# confidentiality.
#
# This gate holds two properties that are cheap to state and easy to lose:
#
#   1. No CKRecord field carries a health scalar.
#   2. Every payload handed to a CKAsset passes through EncryptionManager.
#
# A static check, deliberately. The alternative is a live CloudKit test against
# a real account, which cannot run in CI and would not catch this anyway: the
# upload succeeds, it just uploads the wrong thing.

set -uo pipefail
cd "$(dirname "$0")/.."

HEALTH_FIELDS='recoveryScore|meanRMSSD|rmssd|sdnn|hrv|sleepScore|readinessScore|heartRate|restingHR|spo2|respiratoryRate'
bad=0

# Fail closed: the gate is meaningless if the files it inspects are not
# there, and it must not depend on process substitution (/dev/fd), which
# some sandboxes lack; a failed substitution reads as "no hits".
if ! ls Emuqu/Sources/Storage/CloudKit*.swift >/dev/null 2>&1; then
    echo "check_no_health_data_in_cloudkit: no CloudKit sources found under Emuqu/Sources/Storage." >&2
    exit 2
fi
hits="$(grep -rnE "record\[\"($HEALTH_FIELDS)\"\][[:space:]]*=" Emuqu/Sources/Storage/CloudKit*.swift 2>/dev/null \
    | sed 's|^Emuqu/Sources/Storage/||' \
    | sed 's|$| — plaintext health field written to a CKRecord|' || true)"
if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
        echo "ERROR: $hit" >&2
        bad=$((bad + 1))
    done <<< "$hits"
fi

# Every function that builds bytes for a CKAsset must encrypt them.
for fn in compressedPayload compressedPoints; do
    file="$(grep -rln "func $fn" Emuqu/Sources/Storage/CloudKit*.swift 2>/dev/null | head -1)"
    [[ -z "$file" ]] && continue
    body="$(awk "/func $fn/,/^    \}/" "$file")"
    # The encryption may be inline or one call away in a helper, so accept
    # either — but the function must name something that encrypts, and the file
    # must fail closed. Following a single level of indirection keeps the check
    # honest without pretending to be a call-graph analysis.
    # Matched on the PROPERTY, not a spelling. The manager may be named
    # directly or bound to a local first, and a gate that only recognises
    # `EncryptionManager.shared.encrypt` goes red when someone dedups the
    # singleton reference — which is a correct change failing a check that
    # claimed to be about encryption. Asking "does it encrypt" and "does it
    # consult availability" survives that.
    # Both paths must go through `CloudPayloadCodec` — the shared envelope with
    # a SYNCHRONIZABLE key. Checking only "does it encrypt" passes a writer
    # that seals backups with the device-only archive key, which no
    # replacement device can read, and a live-backup writer whose reader never
    # decrypts at all. Naming the codec is what makes the two directions
    # agree.
    if ! grep -qE "CloudPayloadCodec\.encode|[a-z]ncryptedFor[A-Za-z]*\(" <<<"$body"; then
        echo "ERROR: ${file#Emuqu/Sources/Storage/}: $fn does not encode through CloudPayloadCodec" >&2
        bad=$((bad + 1))
    fi
    if ! grep -qE "CloudPayloadCodec\.hasUsableKey" "$file"; then
        echo "ERROR: ${file#Emuqu/Sources/Storage/}: no fail-closed guard on cloud-key availability" >&2
        bad=$((bad + 1))
    fi
done


# Every writer has a reader. An encrypted writer paired with a reader that
# decompresses without decrypting makes the backup unreadable the
# same day, on the same device, and it surfaces as "no backup" rather than an
# error.
for reader in liveBackupSummary decodeSessionPayload; do
    file="$(grep -rln "func $reader" Emuqu/Sources/Storage/CloudKit*.swift 2>/dev/null | head -1)"
    [[ -z "$file" ]] && continue
    body="$(awk "/func $reader/,/^    \}/" "$file")"
    if grep -q "DataCompression.decompress" <<<"$body" && ! grep -q "CloudPayloadCodec.decode" <<<"$body"; then
        echo "ERROR: ${file#Emuqu/Sources/Storage/}: $reader decompresses without decoding the envelope" >&2
        bad=$((bad + 1))
    fi
done

if (( bad > 0 )); then
    echo >&2
    echo "Guideline 5.1.3(ii) forbids storing personal health information in iCloud." >&2
    echo "Compression is not confidentiality; a compressed payload is readable." >&2
    exit 1
fi

echo "check_no_health_data_in_cloudkit: clean. No plaintext health fields; every CloudKit payload is encrypted and fails closed."
