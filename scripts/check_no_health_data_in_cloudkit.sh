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

# Words that mark a field as health data. A key is split into its camelCase and
# snake_case words, and it is a health field when any word is on this list, so
# `avgHR`, `hrvScore` and `resting_heart_rate_bpm` are caught as well as the
# exact names, not only a fixed set of spellings.
HEALTH_WORDS='hr|hrv|rmssd|sdnn|pnn50|heart|pulse|bpm|spo2|oxygen|respiratory|respiration|sleep|recovery|readiness|score|vo2|resting|temperature|alpha1|strain|stress|calories|rr|ibi|beat|beats|interval|intervals|dfa|hrr|ecg|weight|mass|bmi|glucose|blood|pressure|cadence|power|energy|steps|workout|route|location|latitude|longitude|altitude|elevation|distance|pace|speed'
bad=0

# function_body <name> <file>: prints `func <name>` through the closing brace at
# the indentation the declaration has, whatever that is. Exits 3 when the
# function is not found or never closes, so a range cannot run on to the end of
# the file and find the call it looks for in some other function.
function_body() {
    awk -v fn="$1" '
        !inside && $0 ~ ("func " fn "[^A-Za-z0-9_]") {
            match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH); inside = 1; print; next
        }
        inside { print; if ($0 ~ ("^" indent "}[ \t]*$")) { closed = 1; exit } }
        END { if (!closed) exit 3 }
    ' "$2"
}

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
# `setObject(_:forKey:)`. The record is any variable named `*record` or
# `*Record`, any name a file binds to one (`let ck = record`, `ck: CKRecord`,
# `= CKRecord(`), and its `encryptedValues`, which are still stored in iCloud.
# `setValuesForKeys` hides its keys from a line scan, so it is refused outright
# on a record: write the fields one by one.
#
# This is the fast first line. CloudUploadRecordTests builds the real session
# and live-backup records and reads their keys and asset bytes, which catches
# what no source pattern can.
#
#   * A health scalar may never be written.
#   * The settings record's plaintext fields — `settingsJSON` held birthday,
#     sex, weight, heart-rate thresholds and baselines, and `deviceName` often
#     the owner's name — may only ever be cleared (`= nil`). Records from older
#     builds still carry them, which is why the names cannot simply disappear
#     from the source.
hits="$(python3 - "$HEALTH_WORDS" Emuqu "EmuquWatch Watch App" <<'PY'
import pathlib
import re
import sys

health_words = set(sys.argv[1].split("|"))
WORD = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z0-9]+")


def is_health(key):
    return any(word.lower() in health_words for word in WORD.findall(key))


legacy = re.compile(r"^(?:settingsJSON|deviceName)$")
files = [p for root in sys.argv[2:] for p in sorted(pathlib.Path(root).rglob("*.swift"))
         if "CKRecord" in p.read_text(encoding="utf-8", errors="ignore")]
if not files:
    sys.stderr.write("check_no_health_data_in_cloudkit: no Swift file names CKRecord.\n")
    sys.exit(2)

CONSTANT = re.compile(r"\blet\s+(\w+)\s*(?::\s*String\s*)?=\s*\"([^\"]+)\"")
SUBSCRIPT = re.compile(r"\b(\w+)(?:\.encryptedValues)?\s*\[\s*(?:\"([^\"]+)\"|([A-Za-z_][\w.]*))\s*\]\s*=(?!=)\s*(.*)$")
ALIAS = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::\s*CKRecord\b[^=]*)?=\s*(?:\w*[rR]ecord\b|CKRecord\s*\()"
                   r"|\b(\w+)\s*:\s*CKRecord\b(?!\s*\.)"
                   r"|\b(?:let|var)\s+(\w+)\s*=\s*\w*[rR]ecords\b|\bfor\s+(\w+)\s+in\s+\w*[rR]ecords\b")
BULK = re.compile(r"\.setValuesForKeys\s*\(")
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


def is_record(name, aliases):
    return name.lower().endswith("record") or name in aliases


for path, text in texts.items():
    aliases = {next(g for g in groups if g) for groups in ALIAS.findall(text)}
    for n, line in enumerate(text.split("\n"), 1):
        code = line.split("//")[0]
        if BULK.search(code):
            print(f"{path}:{n}: {line.strip()}: setValuesForKeys on a record; its keys cannot be checked")
        writes = [(k, m.group(4)) for m in SUBSCRIPT.finditer(code) if is_record(m.group(1), aliases)
                  for k in keys_of(m.group(2), m.group(3))]
        writes += [(k, m.group(1)) for m in SETTER.finditer(code) for k in keys_of(m.group(2), m.group(3))]
        for key, value in writes:
            # Clearing a field writes nothing; the bytes of an asset are held to
            # the sealing checks on its writer below.
            if is_health(key) and value.strip() != "nil" and not value.strip().startswith("CKAsset("):
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
# seal them with `CloudPayloadCodec.sealForUpload`: the shared envelope with a
# SYNCHRONIZABLE key, so a replacement device can read the backup. A writer
# that encrypts with the device-only archive key would pass an "it encrypts"
# check and still produce backups no other device can open.
for fn in compressedPayload compressedPoints sealedLocalSettings scrubStoredRecord; do
    file="$(grep -rlnE "func $fn\b" Emuqu/Sources/Storage 2>/dev/null | head -1)"
    # A writer that was renamed or moved is not a writer that passed: say so.
    if [[ -z "$file" ]]; then
        echo "check_no_health_data_in_cloudkit: writer $fn not found under Emuqu/Sources/Storage — re-point this gate at it." >&2
        exit 2
    fi
    if ! body="$(function_body "$fn" "$file")"; then
        echo "check_no_health_data_in_cloudkit: cannot find the end of $fn in $file — re-point this gate at it." >&2
        exit 2
    fi
    if ! grep -qF "CloudPayloadCodec.sealForUpload(" <<<"$body"; then
        echo "ERROR: ${file#Emuqu/Sources/Storage/}: $fn does not seal through CloudPayloadCodec.sealForUpload" >&2
        bad=$((bad + 1))
    fi
    # Sealing and then returning something else uploads the plaintext: the
    # sealed bytes are what a writer hands back, never a bare variable.
    if grep -qE "^[[:space:]]*return[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$" <<<"$body" \
        || grep -qE "^[[:space:]]*_[[:space:]]*=[[:space:]]*try[[:space:]]+CloudPayloadCodec\.sealForUpload" <<<"$body"; then
        echo "ERROR: ${file#Emuqu/Sources/Storage/}: $fn seals and then hands back something other than the sealed bytes" >&2
        bad=$((bad + 1))
    fi
done

# The seal fails closed: with no cloud key it throws encryptionUnavailable and
# never hands back the payload unsealed.
codec="Emuqu/Sources/Storage/CloudPayloadCodec.swift"
if ! seal_body="$(function_body sealForUpload "$codec")"; then
    echo "check_no_health_data_in_cloudkit: sealForUpload not found in $codec — re-point this gate at it." >&2
    exit 2
fi
if ! grep -qF "throw CloudSyncError.encryptionUnavailable" <<<"$seal_body"; then
    echo "ERROR: CloudPayloadCodec.swift: sealForUpload does not fail closed when the key is unavailable" >&2
    bad=$((bad + 1))
fi
if grep -qE "return[[:space:]]+payload\b" <<<"$seal_body"; then
    echo "ERROR: CloudPayloadCodec.swift: sealForUpload can return the payload unsealed" >&2
    bad=$((bad + 1))
fi


# Every writer has a reader. An encrypted writer paired with a reader that
# decompresses without decrypting makes the backup unreadable the
# same day, on the same device, and it surfaces as "no backup" rather than an
# error.
# The readers are the functions that actually decompress: `decodePayload`
# (live backups, called by `liveBackupSummary`) and `decodeSessionAsset`
# (CloudPullCoordinator; every session payload, for the pull and for the
# health scrub). A reader that is not found, or no longer decompresses in its
# own body, is a config error rather than a pass.
for reader in decodePayload decodeSessionAsset; do
    file="$(grep -rlnE "func $reader\b" Emuqu/Sources/Storage 2>/dev/null | head -1)"
    if [[ -z "$file" ]]; then
        echo "check_no_health_data_in_cloudkit: reader $reader not found under Emuqu/Sources/Storage — re-point this gate at it." >&2
        exit 2
    fi
    if ! body="$(function_body "$reader" "$file")"; then
        echo "check_no_health_data_in_cloudkit: cannot find the end of $reader in $file — re-point this gate at it." >&2
        exit 2
    fi
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
