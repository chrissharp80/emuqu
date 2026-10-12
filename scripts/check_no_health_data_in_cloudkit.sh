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

# Field writes. Every Swift file in the app and watch targets that names
# `CKRecord` is read, not only `Storage/CloudKit*.swift`: the health scrub, the
# trash restore and the settings sync all touch records from elsewhere. A key
# is recognised as a string literal (`record["rmssd"] = ...`), through a
# string constant declared in the scanned files (`record[payloadField] = ...`
# where `payloadField = "settingsJSON"`), or through `setValue(_:forKey:)` /
# `setObject(_:forKey:)`.
#
#   * A health scalar may never be written.
#   * The settings record's plaintext fields — `settingsJSON` held birthday,
#     sex, weight, heart-rate thresholds and baselines, and `deviceName` often
#     the owner's name — may only ever be cleared (`= nil`). Records from older
#     builds still carry them, which is why the names cannot simply disappear
#     from the source.
hits="$(python3 - "$HEALTH_FIELDS" Emuqu "EmuquWatch Watch App" <<'PY'
import pathlib
import re
import sys

health = re.compile(rf"^(?:{sys.argv[1]})$")
legacy = re.compile(r"^(?:settingsJSON|deviceName)$")
files = [p for root in sys.argv[2:] for p in sorted(pathlib.Path(root).rglob("*.swift"))
         if "CKRecord" in p.read_text(encoding="utf-8", errors="ignore")]
if not files:
    sys.stderr.write("check_no_health_data_in_cloudkit: no Swift file names CKRecord.\n")
    sys.exit(2)

CONSTANT = re.compile(r"\blet\s+(\w+)\s*(?::\s*String\s*)?=\s*\"([^\"]+)\"")
SUBSCRIPT = re.compile(r"\b\w*[rR]ecord\s*\[\s*(?:\"([^\"]+)\"|([A-Za-z_][\w.]*))\s*\]\s*=(?!=)\s*(.*)$")
SETTER = re.compile(r"\.set(?:Value|Object)\s*\((.*),\s*forKey:\s*(?:\"([^\"]+)\"|([A-Za-z_][\w.]*))\s*\)")

texts = {p: p.read_text(encoding="utf-8", errors="ignore") for p in files}
# A constant name may be declared in more than one file with different
# values, so a name resolves to every value it is given anywhere.
constants = {}
for text in texts.values():
    for name, value in CONSTANT.findall(text):
        constants.setdefault(name, set()).add(value)


def keys_of(literal, name):
    if literal:
        return {literal}
    return constants.get((name or "").split(".")[-1], set())


for path, text in texts.items():
    for n, line in enumerate(text.split("\n"), 1):
        code = line.split("//")[0]
        writes = [(k, m.group(3)) for m in SUBSCRIPT.finditer(code) for k in keys_of(m.group(1), m.group(2))]
        writes += [(k, m.group(1)) for m in SETTER.finditer(code) for k in keys_of(m.group(2), m.group(3))]
        for key, value in writes:
            if health.match(key):
                print(f"{path}:{n}: {line.strip()} — plaintext health field written to a CKRecord")
            elif legacy.match(key) and value.strip() != "nil":
                print(f"{path}:{n}: {line.strip()} — legacy plaintext settings field written with a value")
PY
)" || exit 2
if [[ -n "$hits" ]]; then
    while IFS= read -r hit; do
        echo "ERROR: $hit" >&2
        bad=$((bad + 1))
    done <<< "$hits"
fi

# Every function that builds bytes for a CKAsset or the settings record must
# encrypt them.
for fn in compressedPayload compressedPoints encryptedSettingsPayload; do
    file="$(grep -rlnE "func $fn\b" Emuqu/Sources/Storage 2>/dev/null | head -1)"
    # A writer that was renamed or moved is not a writer that passed: say so.
    if [[ -z "$file" ]]; then
        echo "check_no_health_data_in_cloudkit: writer $fn not found under Emuqu/Sources/Storage — re-point this gate at it." >&2
        exit 2
    fi
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
# The readers are the functions that actually decompress: `decodePoints`
# (live backups, called by `liveBackupSummary`) and `decodeSessionAsset`
# (CloudPullCoordinator; every session payload, for the pull and for the
# health scrub). A reader that is not found, or no longer decompresses in its
# own body, is a config error rather than a pass.
for reader in decodePoints decodeSessionAsset; do
    file="$(grep -rlnE "func $reader\b" Emuqu/Sources/Storage 2>/dev/null | head -1)"
    if [[ -z "$file" ]]; then
        echo "check_no_health_data_in_cloudkit: reader $reader not found under Emuqu/Sources/Storage — re-point this gate at it." >&2
        exit 2
    fi
    body="$(awk "/func $reader/,/^    \}/" "$file")"
    if ! grep -q "DataCompression.decompress" <<<"$body"; then
        echo "check_no_health_data_in_cloudkit: $reader no longer decompresses in its own body — re-point this gate at the function that does." >&2
        exit 2
    fi
    if ! grep -q "CloudPayloadCodec.decode" <<<"$body"; then
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
