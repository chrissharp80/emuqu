#!/usr/bin/env bash
#
# Prove every gate actually fails.
#
# ## Why this exists
#
# A gate is only worth its runtime if it goes red on a real violation, and a
# gate can report clean while missing exactly the thing it is named for. The
# shapes this repository produces:
#
#   • `try? on write/encode/delete paths: 0` not seeing
#     `try? EncryptionManager.shared.encrypt(...)` fall through to a plaintext
#     write of health data — the highest-severity finding to date.
#   • `check_unchecked_sendable.sh` and `check_log_redaction.sh` exiting 0 and
#     printing "clean" after `mktemp` fails and they have measured nothing.
#
# Every one of those passes a "does the gate run without erroring" check. A
# gate nobody has watched fail is the gap this closes: for each gate, plant a
# violation the gate claims to catch, assert a non-zero exit, restore. A gate
# that stays green here is not protecting anything.
#
#     ./scripts/verify_gates_fail.sh          # all gates
#     ./scripts/verify_gates_fail.sh doc_links # one, by substring
#
# Cheap gates only — nothing here builds or runs a simulator, so it belongs in
# `make ci`. The Thread Sanitizer gate runs here against a stand-in xcodebuild
# (see its plants). The coverage gate needs a real build, is verified by its own
# runs, and is listed at the bottom as not covered.

set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
source "$(dirname "$0")/lib/preflight.sh"
gate_acquire_tree_lock "verify_gates_fail.sh"
# The trap goes in before anything else can fail, so a failed temp-dir
# creation does not leave the lock behind.
BACKUP_DIR=""
trap 'restore_all; [[ -n "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"; gate_release_tree_lock' EXIT INT TERM HUP
BACKUP_DIR="$(gate_mktemp_dir verify-gates)" || exit $?

TOUCHED=()

backup() {
    local f="$1" safe
    safe="$(printf '%s' "$f" | tr '/' '_')"
    cp "$f" "$BACKUP_DIR/$safe"
    TOUCHED+=("$f")
}

restore_all() {
    local f safe
    for f in "${TOUCHED[@]:-}"; do
        [[ -z "$f" ]] && continue
        safe="$(printf '%s' "$f" | tr '/' '_')"
        [[ -f "$BACKUP_DIR/$safe" ]] && cp "$BACKUP_DIR/$safe" "$f"
    done
    TOUCHED=()
}

# Whether a red gate fell over rather than reported the violation: an
# interpreter error (a Python traceback, a bash unbound variable, syntax error
# or missing command) or an exit code no gate uses for a finding (126 and 127
# are bash's could-not-run codes, above 128 is a signal). A plant that breaks
# the gate itself proves nothing about whether it catches the violation.
gate_crashed() {
    local code="$1" output="$2"
    (( code == 126 || code == 127 || code > 128 )) && return 0
    grep -qE 'Traceback \(most recent call last\)|: unbound variable|: syntax error|: command not found' <<<"$output"
}

# check <name> <gate command> <file to mutate> <python mutation>
check() {
    local name="$1" gate="$2" file="$3" mutation="$4"

    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        return
    fi

    # The gate must be green before we break anything, or the test proves nothing.
    if ! eval "$gate" >/dev/null 2>&1; then
        printf "  \033[33mSKIP\033[0m  %-34s gate is already red; fix that first\n" "$name"
        SKIP=$((SKIP + 1))
        return
    fi

    backup "$file"
    if ! python3 -c "$mutation" 2>/dev/null; then
        printf "  \033[33mSKIP\033[0m  %-34s could not plant the violation\n" "$name"
        restore_all
        SKIP=$((SKIP + 1))
        return
    fi

    local output code
    output="$(eval "$gate" 2>&1)"
    code=$?
    restore_all

    if (( code != 0 )) && gate_crashed "$code" "$output"; then
        printf "  \033[31mFAIL\033[0m  %-34s CRASHED instead of reporting (exit %d); a crash is not a catch\n" "$name" "$code"
        FAIL=$((FAIL + 1))
    elif (( code != 0 )); then
        printf "  \033[32mPASS\033[0m  %-34s went red on a planted violation\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m  %-34s STAYED GREEN — this gate protects nothing\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

echo "Verifying that each gate fails when it should."
echo

check "copy_perimeter/malformed_catalogue" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Localizable.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');p.write_text('{ not json')"

check "doc_links/ignored_target" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;pathlib.Path('build').mkdir(exist_ok=True);pathlib.Path('build/planted-notes.md').write_text('planted');p=pathlib.Path('README.md');p.write_text(p.read_text()+'\nSee [notes](build/planted-notes.md).\n')"

check "doc_links/broken_link" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;p=pathlib.Path('README.md');p.write_text(p.read_text()+'\n[x](docs/definitely-not-here.md)\n')"

check "doc_links/quoted_budget" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;p=pathlib.Path('README.md');p.write_text(p.read_text()+'\nThe .ci/swiftlint_warning_budget.txt is 4242 today.\n')"

check "doc_links/dead_code_path" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;p=pathlib.Path('README.md');p.write_text(p.read_text()+'\nSee \`Emuqu/Sources/NotAReal/File.swift\` for details.\n')"

# A citation that names the WRONG directory for a file that does exist. A gate
# that falls back to matching the basename anywhere in the tree passes it, and
# citations reading `Sources/...` for files living at `Emuqu/Sources/...` are
# never checked at all. The fallback must apply only to a bare filename, which
# is the case it exists for.
check "doc_links/wrong_directory" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;p=pathlib.Path('README.md');p.write_text(p.read_text()+'\nSee \`WrongDir/EmuquApp.swift\` for details.\n')"

# A privacy manifest can be valid XML and declare a type Apple has never heard
# of; that is rejected at submission, not at build.
# Guideline 5.1.3(ii) forbids storing personal health information in iCloud.
# Compression is not confidentiality.
check "cloudkit/plaintext_health" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');p.write_text(p.read_text().replace('return try CloudPayloadCodec.sealForUpload(compressed)','return compressed',1))"

# A health field under a name no fixed list spells out.
check "cloudkit/unlisted_health_field" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift');s=p.read_text();o='record[\"beatCount\"] = ';assert s.count(o)==1;p.write_text(s.replace(o,'record[\"avgHR\"] = 0; record[\"beatCount\"] = ',1))"

# Field writes the record's own name does not show: through another name
# bound to it, through `encryptedValues` (still stored in iCloud), and
# through `setValuesForKeys`, whose keys no line scan reads.
check "cloudkit/aliased_record_field" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');s=p.read_text();o='        record[\"isDeleted\"] = 0 as CKRecordValue\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'        let ck = record; ck[\"meanRMSSD\"] = 42.0 as CKRecordValue\n'))"

check "cloudkit/encrypted_values_field" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');s=p.read_text();o='        record[\"isDeleted\"] = 0 as CKRecordValue\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'        record.encryptedValues[\"meanRMSSD\"] = 42.0 as CKRecordValue\n'))"

check "cloudkit/set_values_for_keys" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');s=p.read_text();o='        record[\"isDeleted\"] = 0 as CKRecordValue\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'        record.setValuesForKeys([\"recoveryScore\": 7.4])\n'))"

# The seal is called and its result dropped, so the asset is the plaintext.
check "cloudkit/sealed_then_discarded" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');s=p.read_text();o='        return try CloudPayloadCodec.sealForUpload(compressed)\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = try CloudPayloadCodec.sealForUpload(compressed)\n        return compressed\n'))"

check "privacy_manifest/bad_type" \
    "./scripts/check_privacy_manifest_vocabulary.sh" \
    "Emuqu/PrivacyInfo.xcprivacy" \
    "import pathlib;p=pathlib.Path('Emuqu/PrivacyInfo.xcprivacy');p.write_text(p.read_text().replace('NSPrivacyCollectedDataTypeHealth<','NSPrivacyCollectedDataTypeHealthData<',1))"

check "no_developer_endpoint/host" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu/Sources/Services/WeatherService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WeatherService.swift');p.write_text(p.read_text().replace('import Foundation','import Foundation\n// planted\nprivate let t = URL(string: \"https://telemetry.example-analytics.io/e\")',1))"

check "no_developer_endpoint/sdk" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');p.write_text(p.read_text()+'\n/* planted firebase-analytics reference */\n')"

# A lock file that is not there greps as zero hits; that is not "no SDK".
check "no_developer_endpoint/missing_lock_file" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "import pathlib;pathlib.Path('Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').unlink()"

# A host the code builds at runtime cannot be read off the source: an
# interpolated host and a host assigned from a variable must each go red.
check "no_developer_endpoint/interpolated_host" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu/Sources/Services/WeatherService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WeatherService.swift');p.write_text(p.read_text().replace('import Foundation','import Foundation\nprivate let plantedHost = \"telemetry.example-analytics.io\"\nprivate let t = URL(string: \"https://\\(plantedHost)/e\")',1))"

check "no_developer_endpoint/variable_host" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu/Sources/Services/WeatherService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WeatherService.swift');p.write_text(p.read_text().replace('import Foundation','import Foundation\nprivate func plantedURL(host: String) -> URL? { var c = URLComponents(); c.scheme = \"https\"; c.host = host; return c.url }',1))"

check "xcodebuild_pinned/unpinned_build" \
    "./scripts/check_xcodebuild_pinned.sh" \
    ".github/workflows/performance.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/performance.yml');t=p.read_text();assert '-onlyUsePackageVersionsFromResolvedFile \\\\\n' in t;p.write_text(t.replace('-onlyUsePackageVersionsFromResolvedFile \\\\\n','',1))"

check "privacy_manifest/unknown_api_reason" \
    "./scripts/check_privacy_manifest_vocabulary.sh" \
    "Emuqu/PrivacyInfo.xcprivacy" \
    "import pathlib;p=pathlib.Path('Emuqu/PrivacyInfo.xcprivacy');s=p.read_text();o='<string>C617.1</string>';assert s.count(o)==1;p.write_text(s.replace(o,'<string>X999.1</string>'))"

check "privacy_manifest/undeclared_watch_file_timestamp" \
    "./scripts/check_privacy_manifest_vocabulary.sh" \
    "EmuquWatch Watch App/WatchSessionManager.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchSessionManager.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'func plantedAge(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }\n'))"

check "privacy_manifest/unparseable_watch_manifest" \
    "./scripts/check_privacy_manifest_vocabulary.sh" \
    "EmuquWatch Watch App/PrivacyInfo.xcprivacy" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/PrivacyInfo.xcprivacy');s=p.read_text();o='</plist>';assert s.count(o)==1;p.write_text(s.replace(o,''))"

check "copy_perimeter/plural_variation" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Localizable.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');s=p.read_text();o='%lld Sitzung konnte nicht entfernt werden. Versuche es erneut.';assert s.count(o)==1;p.write_text(s.replace(o,'%lld Sitzung zeigt Overtraining.'))"

check "copy_perimeter/permission_prompt" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Info.plist" \
    "import pathlib;p=pathlib.Path('Emuqu/Info.plist');s=p.read_text();o='Emuqu reads from Apple Health';assert s.count(o)==1;p.write_text(s.replace(o,'Emuqu diagnoses overtraining from Apple Health'))"

# Every concept the README says is checked in all 17 languages, planted in a
# French translation with no English word for the English patterns to catch.
check "copy_perimeter/translated_diagnosis" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Localizable.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');s=p.read_text();o='Les segments sont notés indépendamment.';assert s.count(o)==1;p.write_text(s.replace(o,'Emuqu peut diagnostiquer votre état.'))"

check "copy_perimeter/translated_overtraining" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Localizable.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');s=p.read_text();o='Les segments sont notés indépendamment.';assert s.count(o)==1;p.write_text(s.replace(o,'Les segments montrent un surentraînement.'))"

check "copy_perimeter/translated_injury_risk" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Localizable.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');s=p.read_text();o='Les segments sont notés indépendamment.';assert s.count(o)==1;p.write_text(s.replace(o,'Les segments montrent un risque de blessure.'))"

# A concept the every-locale list names but the linter cannot load must stop
# the run, not drop out of the check while it reports clean.
check "copy_perimeter/unloadable_concept" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='        diagnosis, injuryRisk, overtraining'+chr(10)+'    ]';assert s.count(o)==1;p.write_text(s.replace(o,'        diagnosis, injuryRisk, overtraining, plantedMissingConcept'+chr(10)+'    ]'))"

check "perimeter_sync/concept_not_scrubbed" \
    "./scripts/check_perimeter_sync.sh" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='        regulatoryClearance, injuryRisk, overtraining, riskZoneFraming, pathology,';assert s.count(o)==1;p.write_text(s.replace(o,'        regulatoryClearance, injuryRisk, riskZoneFraming, pathology,'))"

check "perimeter_sync/commented_out_alternative" \
    "./scripts/check_perimeter_sync.sh" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='            \"overtrain(?:s|ed|ing)?\", \"overtraining\",';assert s.count(o)==1;p.write_text(s.replace(o,'            // \"overtrain(?:s|ed|ing)?\", \"overtraining\",'))"

check "science_register/digit_in_name" \
    "./scripts/check_science_register.sh" \
    "Emuqu/Sources/Analysis/ScoringVersion.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/ScoringVersion.swift');s=p.read_text();o='enum ScoringVersion {';assert s.count(o)==1;p.write_text(s.replace(o,'func spo2Penalty(_ x: Double) -> Double { x * 0.9 }\n'+o))"

check "science_register/retracted_claim_in_help" \
    "./scripts/check_science_register.sh" \
    "Emuqu/Help.xcstrings" \
    "import pathlib;p=pathlib.Path('Emuqu/Help.xcstrings');s=p.read_text();o='2-5 minute daytime readings for on-the-spot recovery checks';assert s.count(o)==1;p.write_text(s.replace(o,o+' (ICC 0.77-0.84)'))"

check "unreached_advisories/spaced_call" \
    "./scripts/check_unreached_advisories.sh" \
    "Emuqu/Sources/Collection/PolarManager+Observers.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PolarManager+Observers.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'func plantedFw(_ api: PolarBleApi, _ id: String) { _ = api.updateFirmware (id) }\n'))"

check "unreached_advisories/unproven_allowance" \
    "./scripts/check_unreached_advisories.sh" \
    ".github/workflows/security.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/security.yml');s=p.read_text();o='allow-ghsas: GHSA-g454-wj9r-jpg4';assert s.count(o)==1;p.write_text(s.replace(o,o+', GHSA-2c8m-8w5h-9q4f'))"

check "xcodebuild_pinned/wrapped_unpinned_build" \
    "./scripts/check_xcodebuild_pinned.sh" \
    ".github/workflows/performance.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/performance.yml');s=p.read_text();o='          xcodebuild test \\\\\n            -onlyUsePackageVersionsFromResolvedFile \\\\\n';assert s.count(o)==1;p.write_text(s.replace(o,'          timeout 3600 xcodebuild test \\\\\n'))"

check "strict_concurrency_enabled/device_only_swift5" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='\t\t\t\tTARGETED_DEVICE_FAMILY = 1;\n\t\t\t\tVALIDATE_PRODUCT = YES;\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'\t\t\t\t\"SWIFT_VERSION[sdk=iphoneos*]\" = 5.0;\n'))"

check "infoplist_key_drift/usage_key_without_ns" \
    "./scripts/check_infoplist_key_drift.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='\t\t\t\tTARGETED_DEVICE_FAMILY = 1;\n\t\t\t\tVALIDATE_PRODUCT = YES;\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'\t\t\t\tINFOPLIST_KEY_NFCReaderUsageDescription = \"Scan tags.\";\n'))"

check "doc_links/reference_style_link" \
    "./scripts/check_doc_links.sh" \
    "docs/MAINTAINERS.md" \
    "import pathlib;p=pathlib.Path('docs/MAINTAINERS.md');s=p.read_text();o='# Emuqu — Maintainer\'s Guide\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'\nSee the [runbook][rb].\n\n[rb]: RUNBOOK_MISSING.md\n'))"

check "sbom_drift/commented_out_entry" \
    "./scripts/check_sbom_drift.sh" \
    "Emuqu/Sources/Views/PrivacyPolicyView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/PrivacyPolicyView.swift');s=p.read_text();o='            name: \"polar-ble-sdk\",\n';assert s.count(o)==1;i=s.rindex('        Pkg(\n',0,s.index(o));j=s.index('        ),\n',i)+11;p.write_text(s[:i]+'        /*\n'+s[i:j]+'        */\n'+s[j:])"

check "sbom_drift/revision_pin" \
    "./scripts/check_sbom_drift.sh" \
    "Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');s=p.read_text();o='\"revision\" : \"6d7298683b5168601c6141f843701973feedc66e\",\n        \"version\" : \"8.3.0\"';assert s.count(o)==1;p.write_text(s.replace(o,'\"branch\" : \"master\",\n        \"revision\" : \"6d7298683b5168601c6141f843701973feedc66e\"'))"

check "no_developer_endpoint/websocket_host" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu/Sources/Collection/PolarManager+Observers.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PolarManager+Observers.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'let plantedSink = URL(string: \"wss://collector.example.net/ingest\")\n'))"

check "no_developer_endpoint/userinfo_host" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu/Sources/Collection/PolarManager+Observers.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PolarManager+Observers.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'let plantedSink = URL(string: \"https://api.openai.com@collector.example.net/ingest\")\n'))"

check "no_health_data_in_cloudkit/rr_field" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift');s=p.read_text();o='        record[\"sessionId\"] = sessionId.uuidString as CKRecordValue\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'        record[\"beatCount\"] = 31_000 as CKRecordValue\n'))"

check "log_redaction/logger_log_method" \
    "./scripts/check_log_redaction.sh" \
    "EmuquWatch Watch App/WatchStrapConnector.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchStrapConnector.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'func plantedLog(_ log: Logger, _ email: String) { log.log(\"user \\\\(email)\") }\n'))"

check "log_redaction/bare_latitude" \
    "./scripts/check_log_redaction.sh" \
    "EmuquWatch Watch App/WatchStrapConnector.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchStrapConnector.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'func plantedLog(_ log: Logger, _ latitude: Double) { log.info(\"fix \\\\(latitude)\") }\n'))"

check "strict_concurrency_enabled" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();p.write_text(s.replace('\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;\n','',1))"

check "strict_concurrency_enabled/swift5_mode" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();p.write_text(s.replace('SWIFT_VERSION = 6.0;','SWIFT_VERSION = 5.0;',1))"

# A deleted snapshot reference does not fail — the harness records a new one
# and passes against itself forever.
check "snapshot_refs/deleted_reference" \
    "./scripts/check_snapshot_references.sh" \
    "EmuquTests/__Snapshots__/alpha1-report.raw" \
    "import pathlib;pathlib.Path('EmuquTests/__Snapshots__/alpha1-report.raw').unlink()"

# Two references with the same bytes: the renderer drew something other than
# the views, and both tests pass against it whatever their views do.
check "snapshot_refs/identical_references" \
    "./scripts/check_snapshot_references.sh" \
    "EmuquTests/__Snapshots__/badge-morning-feeling.raw" \
    "import pathlib;d=pathlib.Path('EmuquTests/__Snapshots__');(d/'badge-morning-feeling.raw').write_bytes((d/'alpha1-report.raw').read_bytes())"

# `1 ..< xs.count` traps when xs is empty — a shape that recurs, and that
# ships as a latent crash.
check "empty_range/unguarded_loop" \
    "./scripts/check_empty_range_loops.sh" \
    "Emuqu/Sources/Analysis/Verification.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/Verification.swift');s=p.read_text();o='        guard points.count > 1 else { return 0 }\n\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# The second shape of the same trap: `0 ..< (count - N)` is invalid, not empty,
# on a collection shorter than N.
check "empty_range/unguarded_count_arithmetic" \
    "./scripts/check_empty_range_loops.sh" \
    "Emuqu/Sources/Analysis/NonlinearAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/NonlinearAnalysis.swift');p.write_text(p.read_text()+'\nfunc plantedSum(_ xs: [Double]) -> Double {\n    var s = 0.0\n    for i in 0 ..< (xs.count - 1) { s += xs[i] }\n    return s\n}\n')"

check "sbom_drift" \
    "python3 scripts/generate_sbom.py --check" \
    "sbom.spdx.json" \
    "import json,pathlib;p=pathlib.Path('sbom.spdx.json');d=json.loads(p.read_text());d['packages'][1]['versionInfo']='9.9.9';p.write_text(json.dumps(d,indent=2)+'\n')"

check "spec_conformance/long_function" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['    let v%d = %d' % (i,i) for i in range(30)]);p.write_text(p.read_text()+'\nfunc plantedLongFunction() {\n'+body+'\n}\n')"

# The app root is the one file outside `Emuqu/Sources`; a SCAN_DIR that stops
# there leaves a 455-line `body` unmeasured. This plants into that specific
# file, so the scan can never narrow without going red here.
check "spec_conformance/app_root" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/EmuquApp.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/EmuquApp.swift');body='\n'.join(['    let v%d = %d' % (i,i) for i in range(30)]);p.write_text(p.read_text()+'\nfunc plantedLongFunction() {\n'+body+'\n}\n')"

check "copy_perimeter" \
    "python3 Tools/copy_linter/lint.py" \
    "Emuqu/Sources/Views/MetricInfoSheets.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MetricInfoSheets.swift');p.write_text(p.read_text()+'\nlet plantedCopy = String(localized: \"This can diagnose your arrhythmia.\")\n')"

# Two shapes this gate must get right: a correct call split across lines is
# not a violation (a false positive costs a CI run), and the word "bundle:"
# inside translated copy is not the argument (a false negative is the
# dangerous direction). Both are pinned here.
check "localization_bundle/multiline" \
    "./scripts/check_localization_bundle.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nlet plantedMultiline = String(localized:\n    \"planted no bundle\")\n')"

check "localization_bundle/word_in_copy" \
    "./scripts/check_localization_bundle.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nlet plantedWordInCopy = String(localized: \"copy mentioning bundle: here\")\n')"

check "log_redaction" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedLeak(apiKey: String) { debugLog(\"key: \\(apiKey)\") }'+chr(10))"

# What the user asked, and the street they are on, interpolated into a log.
check "log_redaction/user_text" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedQuery(query: String) { debugLog(\"asked: \\(query.prefix(80))\") }'+chr(10))"

check "log_redaction/place_name" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedRoute(savedRoute: SavedRoute) { debugLog(\"route: \\(savedRoute.name)\") }'+chr(10))"

# A call into Polar's firmware update reaches Zip's unzip, which an
# allowance in security.yml says the app never does.
check "unreached_advisories" \
    "./scripts/check_unreached_advisories.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedFirmware(api: PolarBleApi) { _ = api.updateFirmware(\"id\") }'+chr(10))"

# Where the user is, under a name that says so: a road and a grid cell.
check "log_redaction/location_name" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedRoad(currentRoad: String, cellKey: String) { debugLog(\"on \\(currentRoad) in \\(cellKey)\") }'+chr(10))"

# The Watch logs through `os.Logger` values named `log`, and through a
# `Logger(…)` built in place with the level call chained on the next line.
check "log_redaction/watch_logger" \
    "./scripts/check_log_redaction.sh" \
    "EmuquWatch Watch App/WatchStrapConnector.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchStrapConnector.swift');s=p.read_text();o='dropped: \\(error.localizedDescription)';assert s.count(o)==1;p.write_text(s.replace(o,'dropped: \\(token)'))"

# A location value whole prints the user's coordinates.
check "log_redaction/location_value" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedLocation(location: CLLocation) { debugLog(\"at \\(location)\") }'+chr(10))"

check "log_redaction/location_coordinate" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedCoordinate(location: CLLocation) { debugLog(\"at \\(location.coordinate)\") }'+chr(10))"

# What the user typed, lowercased on the way in, is still what they typed.
check "log_redaction/transformed_query" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedLowered(query: String) { debugLog(\"asked: \\(query.lowercased())\") }'+chr(10))"

# Joined on with `+` instead of interpolated.
check "log_redaction/concatenated_query" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedJoined(query: String) { debugLog(\"asked: \" + query) }'+chr(10))"

# The beat series mapped and joined is still the beat series.
check "log_redaction/mapped_series" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedSeries(rr: [Int]) { debugLog(\"rr: \\(rr.map(String.init).joined(separator: \",\"))\") }'+chr(10))"

check "unchecked_sendable" \
    "./scripts/check_unchecked_sendable.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfinal class PlantedUnsafe: @unchecked Sendable { nonisolated(unsafe) static var x = 0 }\n')"

check "unchecked_sendable/decimal_budget" \
    "./scripts/check_unchecked_sendable.sh" \
    ".ci/unchecked_sendable_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/unchecked_sendable_budget.txt');p.write_text(p.read_text().strip()+'.0'+chr(10))"

check "orphan_swift" \
    "./scripts/check_no_orphan_swift.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;pathlib.Path('Emuqu/Sources/Utilities/PlantedOrphan.swift').write_text('// planted\nimport Foundation\n')"
# The plant is a new file, which restore_all does not remove; left in place it
# turns every later Swift-scanning check's baseline red.
rm -f Emuqu/Sources/Utilities/PlantedOrphan.swift

# ---------------------------------------------------------------------------
# Every cheap gate in `scripts/` needs a plant here. A gate with none has
# never been watched fail, which is the standing this file exists to end. The
# gates that need a build or a simulator are named at the bottom.
# ---------------------------------------------------------------------------

# A path with a `:NNN` tail must not slip past the path check; otherwise a
# citation can name the wrong directory indefinitely as long as it carries a
# line number.
check "doc_links/wrong_directory_with_line_number" \
    "./scripts/check_doc_links.sh" \
    "docs/ARCHITECTURE.md" \
    "import pathlib;p=pathlib.Path('docs/ARCHITECTURE.md');p.write_text(p.read_text()+chr(10)+'Planted: \`WrongDir/EmuquApp.swift:42\`'+chr(10))"

# A gate CI never invokes is indistinguishable from a working one: wired into
# the Makefile only, or into neither, it looks exactly like one that runs.
check "gates_wired/unwired_gate" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='./scripts/check_empty_range_loops.sh';assert s.count(o)>=1;p.write_text(s.replace(o,'./scripts/check_nothing.sh',1))"

# A gate that runs but cannot fail, or may not run on a pull request, is as
# absent as an unwired one; a required job skipped by `if:` reports success.
check "gates_wired/continue_on_error" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='      - name: Log redaction guard'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,o+'        continue-on-error: true'+chr(10)))"

check "gates_wired/swallowed_exit" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='run: ./scripts/check_log_redaction.sh'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,'run: ./scripts/check_log_redaction.sh || true'+chr(10)))"

check "gates_wired/job_skipped_on_pull_requests" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='    name: Lint + tech-debt budgets'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,o+\"    if: github.event_name == 'schedule'\"+chr(10)))"

check "gates_wired/step_condition" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='      - name: Log redaction guard'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,o+\"        if: github.event_name == 'push'\"+chr(10)))"

check "gates_wired/pull_request_path_filter" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/gates.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/gates.yml');s=p.read_text();o='  pull_request:'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,o+\"    paths-ignore: ['docs/**']\"+chr(10)))"

check "gates_wired/validation_ports_dropped" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/gates.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/gates.yml');s=p.read_text();o='        run: make validation-ports'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,'        run: echo skipped'+chr(10)))"

# `CBPeripheralManager` prompts the user when it is CONSTRUCTED. A stored
# property that builds one shows the Bluetooth prompt to everyone, including the
# users who never enabled the Zwift broadcaster.
check "eager_permission_prompt/stored_property" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,'    @ObservationIgnored private var peripheralManager = CBPeripheralManager(delegate: nil, queue: nil)'))"

# The same construction inside init() is the other way it reaches every user.
check "eager_permission_prompt/in_init" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,'    @ObservationIgnored private var peripheralManager: CBPeripheralManager?'+chr(10)+'    init() { peripheralManager = CBPeripheralManager(delegate: nil, queue: nil) }'))"

# A lazy central that init() reads unconditionally is built in init() all the
# same: `_ = central` made the foot-pod manager prompt at launch for users with
# no sensor.
check "eager_permission_prompt/lazy_forced_in_init" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/FootPodManager.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/FootPodManager.swift');s=p.read_text();o='        super.init()'+chr(10)+'        loadKnownDevices()';assert s.count(o)==1;p.write_text(s.replace(o,'        super.init()'+chr(10)+'        _ = central'+chr(10)+'        loadKnownDevices()'))"

# POSIX decimal separators in sixteen locales that use a comma.
check "locale_formatting/unlocalised_decimal" \
    "./scripts/check_locale_formatting.sh" \
    "Emuqu/Sources/Views/SettingsView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFormat = String(format: \"%.1f\", 1.0)'+chr(10))"

check "locale_formatting/watch_decimal" \
    "./scripts/check_locale_formatting.sh" \
    "EmuquWatch Watch App/WatchSessionManager.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchSessionManager.swift');s=p.read_text();o='String(format: \"%.2f\", locale: .current, alpha1)';assert s.count(o)==1;p.write_text(s.replace(o,'String(format: \"%.2f\", alpha1)'))"

# A String(localized:) literal whose key is not in the catalogue ships English
# to every locale, and the two other localization gates both report perfect
# scores while exactly that happens.
check "localization_resolution/missing_key" \
    "./scripts/check_localization_resolution.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'let plantedMissing = String(localized: \"planted.key.absent.from.catalogue\", bundle: .main)'+chr(10))"

# A fixed-size font does not respond to Dynamic Type, so it is smallest for
# exactly the users who enlarged their text.
check "fixed_font/view_layer" \
    "./scripts/check_fixed_font_budget.sh" \
    "Emuqu/Sources/Views/SettingsView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFixedFont = Text(\"x\").font(.system(size: 17))'+chr(10))"

# A skipped test passes without asserting anything — the failure mode that lets
# a whole UI test class report green off a stale selector.
check "test_skip_budget/new_skip" \
    "./scripts/check_test_skip_budget.sh" \
    "EmuquTests/BaselineTrackerTests.swift" \
    "import pathlib;p=pathlib.Path('EmuquTests/BaselineTrackerTests.swift');s=p.read_text();o='final class BaselineTrackerTests: XCTestCase {';assert s.count(o)==1;p.write_text(s.replace(o,o+chr(10)+'    func testPlantedSkip() throws { try XCTSkipUnless(false, \"planted\") }'))"

# The ratchet's stop, unscrewed: a budget that rises with no `budget-raise-ok`
# trailer is the cheapest way to make CI green after adding debt.
# Baseline passed explicitly: with none, this gate skips by design, so the
# plant would prove only that skipping is green.
# +100000, not +50: with budgets lowered in the working tree, a small raise
# can still sit below the committed baseline and the gate would rightly stay green.
check "budget_monotonicity/silent_raise" \
    "./scripts/check_budget_monotonicity.sh HEAD" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/shared_usage_budget.txt');p.write_text(str(int(p.read_text().strip())+100000)+chr(10))"

# `83` -> `83.0` compares equal as a number, but the gates that read a debt
# ceiling accept only whole numbers.
check "budget_monotonicity/ceiling_made_decimal" \
    "./scripts/check_budget_monotonicity.sh HEAD" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/shared_usage_budget.txt');p.write_text(p.read_text().strip()+'.0'+chr(10))"

# A value holding a whole hub is the shape the coupling gate exists to stop.
check "coupling_budget/hub_back_reference" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthObservation.swift');p.write_text(p.read_text()+chr(10)+'struct PlantedHolder { let collector: RRCollector }'+chr(10))"

check "coupling_budget/locator_read" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthObservation.swift');p.write_text(p.read_text()+chr(10)+'let plantedLocator = AppDependencies.current'+chr(10))"

# A part's code left in a file named for its old owner.
check "file_names/extends_another_type" \
    "./scripts/check_file_names.sh" \
    "Emuqu/Sources/Collection/StrapRecordingCoordinator+Recording.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingCoordinator+Recording.swift');p.write_text(p.read_text()+chr(10)+'extension PolarManager {}'+chr(10))"

check "coupling_budget/below_budget" \
    "./scripts/check_coupling_budget.sh" \
    ".ci/hub_back_reference_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/hub_back_reference_budget.txt');p.write_text(str(int(p.read_text().strip())+1)+chr(10))"

check "tech_debt_budgets/below_budget" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;pathlib.Path('.ci/shared_usage_budget.txt').write_text('0'+chr(10))"

check "tech_debt_budgets/watch_debt" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    "EmuquWatch Watch App/WatchDependencies.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchDependencies.swift');p.write_text(p.read_text()+chr(10)+'let plantedWatchSingleton = WatchSessionManager.shared'+chr(10))"

# A budget written as a decimal makes `(( count > budget ))` a bash error,
# which `if` reads as false: the gate would pass with no limit at all.
check "tech_debt_budgets/decimal_budget" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/shared_usage_budget.txt');p.write_text(p.read_text().strip()+'.0'+chr(10))"

# `verify_tests_fail.sh` edits production source and restores it in an EXIT
# trap. A killed run skips the trap, and the mutation can be committed as if
# it were code. This gate is the backstop; it has to be able to see one.
check "leaked_mutations/unrestored_edit" \
    "./scripts/check_no_leaked_mutations.sh" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='abs('+chr(36)+'0) > 50';assert s.count(o)>=1;p.write_text(s.replace(o,'abs('+chr(36)+'0) > 75',1))"

# The `chr(36)`-built shape. A parser that reports it as "not
# literal-comparable" leaves it unchecked — and it is the normalized power
# formula.
check "leaked_mutations/chr_escaped_original" \
    "./scripts/check_no_leaked_mutations.sh" \
    "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift');s=p.read_text();o='pow('+chr(36)+'1, 4)';assert s.count(o)>=1;p.write_text(s.replace(o,'pow('+chr(36)+'1, 2)',1))"

# Gate coverage: each plant below is a spelling or shape the gate once read as clean.
check "unchecked_sendable/qualified_spelling" \
    "./scripts/check_unchecked_sendable.sh" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'final class PlantedBox: @unchecked Swift.Sendable { var x = 0 }\n'))"

check "logger_self_reference/file_writer_logs_through_logger" \
    "./scripts/check_logger_self_reference.sh" \
    "Emuqu/Sources/Utilities/DebugLog.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');s=p.read_text();o='NSLog(\"[DebugLog] append failed: '+chr(92)+'(error)\")';assert s.count(o)==1;p.write_text(s.replace(o,'debugLog(\"[DebugLog] append failed: '+chr(92)+'(error)\")'))"

check "logger_self_reference/logger_resolves_shared" \
    "./scripts/check_logger_self_reference.sh" \
    "Emuqu/Sources/Utilities/DebugLog.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');s=p.read_text();o='NSLog(\"[DebugLogger] relaxing file protection failed: %@\", error.localizedDescription)';assert s.count(o)==1;p.write_text(s.replace(o,'DebugLogger.shared.log(\"relax failed\")'))"

check "coremotion_handler_isolation/handler_by_name" \
    "./scripts/check_coremotion_handler_isolation.sh" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='        pedometer.startUpdates(from: start) { @Sendable [weak self] data, error in';assert s.count(o)==1;p.write_text(s.replace(o,'        let planted: CMPedometerHandler = { data, _ in _ = data }\n        pedometer.startUpdates(from: start, withHandler: planted)\n'+o))"

check "coremotion_handler_isolation/long_inline_handler" \
    "./scripts/check_coremotion_handler_isolation.sh" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='        pedometer.startUpdates(from: start) { @Sendable [weak self] data, error in';assert s.count(o)==1;p.write_text(s.replace(o,'        pedometer.startUpdates(from: start, withHandler: { data, _ in let pad = \"'+'x'*2100+'\"; _ = (data, pad) })\n'+o))"

check "hr_feed/qualified_feature_wait" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapHeartRateFeed.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapHeartRateFeed.swift');s=p.read_text();o='        var failures = 0\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = await manager?.link.awaitFeature(StrapFeature.heartRate, until: nil)\n'+o))"

check "hr_feed/link_defers_feed_start" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        feed.start(generation: generation)\n';assert s.count(o)==1;p.write_text(s.replace(o,'        Task { _ = await link.awaitFeature(.heartRate, until: nil, while: { true }); feed.start(generation: generation) }\n'))"

check "no_shared_outside_root/read_in_singleton_declaration" \
    "./scripts/check_no_shared_outside_root.sh" \
    "Emuqu/Sources/Collection/CollectorSessionControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'enum PlantedHolder { static let shared = SettingsManager.shared }\n'))"

check "no_shared_outside_root/read_beside_system_read" \
    "./scripts/check_no_shared_outside_root.sh" \
    "Emuqu/Sources/Collection/CollectorSessionControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl.swift');s=p.read_text();o='import Foundation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'private let plantedSession = URLSession.shared; private let plantedRead = SettingsManager.shared\n'))"

check "explicit_dependencies/defaulted_parameter" \
    "./scripts/check_explicit_dependencies.sh" \
    "Emuqu/Sources/Services/AppLaunchTasks.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/AppLaunchTasks.swift');s=p.read_text();o='import CoreLocation\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'private func plantedHelper(_ deps: AppDependencies = .current) -> AppDependencies { deps }\n'))"

check "empty_range/mapped_range" \
    "./scripts/check_empty_range_loops.sh" \
    "Emuqu/Sources/Assistant/Facts/BreadcrumbFacts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/BreadcrumbFacts.swift');s=p.read_text();o='        guard fixes.count >= 2 else { return (0, 0) }\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

check "empty_range/watch_target" \
    "./scripts/check_empty_range_loops.sh" \
    "EmuquWatch Watch App/WatchApp.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchApp.swift');s=p.read_text();o='import WatchKit\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'func plantedDiffs(_ xs: [Double]) -> [Double] {\n    var out: [Double] = []\n    for i in 1 ..< xs.count { out.append(xs[i] - xs[i - 1]) }\n    return out\n}\n'))"

check "eager_permission_prompt/closure_initialised_property" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,'    @ObservationIgnored private var peripheralManager: CBPeripheralManager? = {\n        let manager = CBPeripheralManager(delegate: nil, queue: nil)\n        return manager\n    }()'))"

check "eager_permission_prompt/dot_init_in_stored_property" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,'    @ObservationIgnored private var peripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil)'))"

check "eager_permission_prompt/attributed_init" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,o+'\n    @MainActor init() {\n        peripheralManager = CBPeripheralManager(delegate: nil, queue: nil)\n    }'))"

check "uitest_fresh_install/second_app_without_flag" \
    "./scripts/check_uitest_fresh_install.sh" \
    "EmuquUITests/DashboardUITests.swift" \
    "import pathlib;p=pathlib.Path('EmuquUITests/DashboardUITests.swift');s=p.read_text();o='    override func tearDown() async throws {';assert s.count(o)==1;p.write_text(s.replace(o,'    func testPlantedSecondLaunch() {\n        let other = XCUIApplication()\n        other.launchArguments += [\"-UITests\"] + UITestLanguage.english\n        other.launch()\n    }\n\n'+o))"

check "test_skip_budget/skipped_in_test_plan" \
    "./scripts/check_test_skip_budget.sh" \
    "Emuqu.xctestplan" \
    "import pathlib;p=pathlib.Path('Emuqu.xctestplan');s=p.read_text();o='        \"name\": \"EmuquUITests\"\n      },\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'      \"skippedTests\": [\"DataDeletionUITests\"],\n'))"

check "test_skip_budget/second_skip_on_a_line" \
    "./scripts/check_test_skip_budget.sh" \
    "EmuquTests/ArchiveIntegrityTests.swift" \
    "import pathlib;p=pathlib.Path('EmuquTests/ArchiveIntegrityTests.swift');s=p.read_text();o='        try XCTSkipUnless(EncryptionManager.shared.isAvailable, \"Encryption unavailable on this test runner\")';assert s.count(o)==1;p.write_text(s.replace(o,o+'; try XCTSkipIf(true, \"planted\")'))"

check "no_orphan_swift/membership_exception" \
    "./scripts/check_no_orphan_swift.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='\t\t\t\tInfo.plist,\n\t\t\t);\n\t\t\ttarget = EFEA95CA2F96B4A100CE7D82';assert s.count(o)==1;p.write_text(s.replace(o,'\t\t\t\tInfo.plist,\n\t\t\t\tWatchApp.swift,\n\t\t\t);\n\t\t\ttarget = EFEA95CA2F96B4A100CE7D82'))"

check "snapshot_references/commented_out_caller" \
    "./scripts/check_snapshot_references.sh" \
    "EmuquTests/StateSnapshotTests.swift" \
    "import pathlib;p=pathlib.Path('EmuquTests/StateSnapshotTests.swift');s=p.read_text();o='        assertSnapshot(of: hosted(ScoreRing(state: .loading, size: .hero)), named: \"ring-loading\")';assert s.count(o)==1;p.write_text(s.replace(o,'        // '+o.strip()))"

check "snapshot_references/name_not_a_literal" \
    "./scripts/check_snapshot_references.sh" \
    "EmuquTests/StateSnapshotTests.swift" \
    "import pathlib;p=pathlib.Path('EmuquTests/StateSnapshotTests.swift');s=p.read_text();o='        assertSnapshot(of: hosted(ScoreRing(state: .loading, size: .hero)), named: \"ring-loading\")';assert s.count(o)==1;p.write_text(s.replace(o,o+'\n        let plantedName = \"ring-loading-planted\"\n        assertSnapshot(of: hosted(ScoreRing(state: .loading, size: .hero)), named: plantedName)'))"

check "leaked_mutations/additive_mutation" \
    "./scripts/check_no_leaked_mutations.sh" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        clearLinkReadings(preserveDeviceIdentity: wasStreaming)';assert s.count(o)==1;p.write_text(s.replace(o,o+'; recording.device.isRecordingOnDevice = false'))"

# An attribution that no longer matches Package.resolved is a licence
# compliance gap, not a cosmetic one.
# Permission strings that live in pbxproj silently override the detailed
# Info.plist text, and they ship that way unnoticed.
check "infoplist_key_drift/usage_description_in_pbxproj" \
    "./scripts/check_infoplist_key_drift.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='PRODUCT_BUNDLE_IDENTIFIER = ';assert s.count(o)>=1;p.write_text(s.replace(o,'INFOPLIST_KEY_NSPlantedUsageDescription = planted;'+chr(10)+chr(9)+chr(9)+chr(9)+chr(9)+o,1))"

# A key nothing requests is a translation paid for in sixteen locales and
# shown to nobody. The budget ratchets down, so one new orphan must go red.
check "localization_orphans/unused_key" \
    "./scripts/check_localization_orphans.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['planted.orphan.key.nothing.requests']={'extractionState':'manual','localizations':{}};p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

# Ten translations reordered %@ and %lld without numbering them and crashed
# the formatter. One planted Spanish reorder must go red.
check "localization_format_args/unnumbered_reorder" \
    "./scripts/check_localization_format_args.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['planted %lld-minute %@ reorder']={'localizations':{'es':{'stringUnit':{'state':'translated','value':'%@ de %lld minutos'}}}};p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

# A lone "%" in a formatted translation is undefined to the formatter.
check "localization_format_args/lone_percent" \
    "./scripts/check_localization_format_args.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['planted %lld %% corrected']={'localizations':{'zh-Hans':{'stringUnit':{'state':'translated','value':'已校正 %lld% 的'}}}};p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

# The three prohibited-term lists must stay reconciled; a term added to one
# and not the others is exactly the drift this gate exists for.
check "perimeter_sync/term_in_one_list_only" \
    "./scripts/check_perimeter_sync.sh" \
    "Tools/copy_linter/prohibited_terms.json" \
    "import json,pathlib;p=pathlib.Path('Tools/copy_linter/prohibited_terms.json');d=json.loads(p.read_text());d['user_facing_prohibited'].append({'pattern':'plantedunreconciledterm','reason':'planted by verify_gates_fail'});p.write_text(json.dumps(d,indent=2))"

# SwiftLint's budget is the same ratchet shape as the others; this proves the
# comparison half runs, not just the linting half.
check "swiftlint_budget/below_budget" \
    "./scripts/enforce_swiftlint_budget.sh" \
    ".ci/swiftlint_warning_budget.txt" \
    "import pathlib;pathlib.Path('.ci/swiftlint_warning_budget.txt').write_text('0'+chr(10))"

# A white paper is checked against the revision it names; a path that did not
# exist there either is still a broken citation.
check "doc_links/pinned_path_absent_at_revision" \
    "./scripts/check_doc_links.sh" \
    "docs/whitepapers/04-claims-governance.md" \
    "import pathlib;p=pathlib.Path('docs/whitepapers/04-claims-governance.md');p.write_text(p.read_text()+chr(10)+'Planted: \`scripts/check_planted_absent.sh\`'+chr(10))"

# The SwiftLint custom rules: each plant must turn the lint budget red.
check "swiftlint_rule/no_unowned" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'final class PlantedUnowned { unowned let owner: AnyObject; init(owner: AnyObject) { self.owner = owner } }'+chr(10))"

check "swiftlint_rule/no_dated_comment" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'// Planted on 2026-01-02.'+chr(10))"

check "swiftlint_rule/no_license_header" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'// Licensed under a planted licence.'+chr(10))"

check "swiftlint_rule/raw_date_ms_conversion" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedMs(_ a: Date, _ b: Date) -> Int64 { Int64(a.timeIntervalSince(b) * 1000) }'+chr(10))"

# No fatalError and no force-unwrap: both are errors, not budgeted warnings,
# and the app root outside Sources is linted too.
check "swiftlint_rule/no_fatal_error" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedCrash() -> Never { fatalError(\"planted\") }'+chr(10))"

check "swiftlint_rule/force_unwrap_in_app_root" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/EmuquApp.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/EmuquApp.swift');p.write_text(p.read_text()+chr(10)+'private func plantedUnwrap(_ value: Int?) -> Int { value! }'+chr(10))"

check "swiftlint_rule/invalid_configuration" \
    "./scripts/enforce_swiftlint_budget.sh" \
    ".swiftlint.yml" \
    "import pathlib;p=pathlib.Path('.swiftlint.yml');p.write_text(p.read_text().replace('match_kinds: [comment, doccomment]','match_kinds: [comment, plantedkind]',1))"

# Every locale sits at 100%; a single untranslated key must drop the worst
# locale below the floor.
check "localization_coverage/untranslated_key" \
    "./scripts/check_localization_coverage.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['planted.untranslated.key']={'extractionState':'manual','localizations':{}};p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

# A plural translation counts only when every case ships: a case Xcode left
# in "new" state must drop the locale below the floor too.
check "localization_coverage/untranslated_plural_case" \
    "./scripts/check_localization_coverage.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['%lld climbs']['localizations']['de']['variations']['plural']['one']['stringUnit']['state']='new';p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

check "sbom_drift/unattributed_package" \
    "./scripts/check_sbom_drift.sh" \
    "Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "import json,pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');d=json.loads(p.read_text());pins=d.get('pins') or d['object']['pins'];pins.append(dict(pins[0], identity='planted-unattributed-package'));p.write_text(json.dumps(d, indent=2))"

# The science register must reject a status that is not one of the declared
# meanings — that is the whole point of a closed vocabulary.
# A retracted evidence phrasing pasted back into an entry must go red.
check "science_register/retracted_claim" \
    "./scripts/check_science_register.sh" \
    "Tools/science_register/register.json" \
    "import json,pathlib;p=pathlib.Path('Tools/science_register/register.json');d=json.loads(p.read_text());d['entries'][0]['evidence']+=' (2024 replication ICC 0.77-0.84)';p.write_text(json.dumps(d))"

check "science_register/unknown_status" \
    "./scripts/check_science_register.sh" \
    "Tools/science_register/register.json" \
    "import json,pathlib;p=pathlib.Path('Tools/science_register/register.json');d=json.loads(p.read_text());d['entries'][0]['status']='planted-unknown-status';p.write_text(json.dumps(d,indent=2))"

# Scoring governance ties the constants hash to the version string. A baseline
# whose hash no longer matches the sources, with the version unchanged, is the
# "changed a weight without bumping the version" case.
check "scoring_governance/constants_changed_without_version_bump" \
    "./scripts/check_scoring_governance.sh" \
    ".ci/scoring_constants_hash.txt" \
    "import pathlib;p=pathlib.Path('.ci/scoring_constants_hash.txt');f=p.read_text().split();f[1]='0'*16;p.write_text(' '.join(f)+chr(10))"

# A version bump that leaves the baseline alone must not switch the check off:
# the recorded version no longer matching is itself a failure.
check "scoring_governance/version_bump_without_baseline" \
    "./scripts/check_scoring_governance.sh" \
    ".ci/scoring_constants_hash.txt" \
    "import pathlib;p=pathlib.Path('.ci/scoring_constants_hash.txt');f=p.read_text().split();f[0]='v0.planted';p.write_text(' '.join(f)+chr(10))"

# A constant changed and the baseline rewritten to match, with the version
# left as it is: the baseline is edited in the same change, so the gate reads
# the version the base recorded. The gate refreshes a copy of the baseline
# each run, as an author updating it in step would, and measures from the
# checked-out commit, so a branch that has already bumped the version for
# its own changes still has a base under that version.
check "scoring_governance/baseline_relabelled_without_version_bump" \
    'b="$BACKUP_DIR/relabelled_baseline.txt"; h="$(./scripts/check_scoring_governance.sh 2>&1 | sed -n "s/.*hashed (\([0-9a-f]*\)).*/\1/p")"; sed "s/ [0-9a-f]\{16\}/ $h/" .ci/scoring_constants_hash.txt > "$b"; SCORING_BASELINE="$b" SCORING_BASE_REF=HEAD ./scripts/check_scoring_governance.sh' \
    "Emuqu/Sources/Utilities/RecoveryScoreConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/RecoveryScoreConstants.swift');s=p.read_text();o='static let rhrZScoreMultiplier: Double = -5.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let rhrZScoreMultiplier: Double = -6.0'))"

# The same change pushed straight to main: committed, baseline rewritten to
# match, version unchanged, and origin/main already the pushed tip, as it is
# when CI runs after a push. Only the tip before the push still records the
# old hash under this version. A throwaway clone takes the working copy's
# constants and gate, commits them and moves origin/main to the commit, then
# runs the gate as the push workflow does, clearing what a pull-request run
# would otherwise pass down.
check "scoring_governance/direct_push_without_version_bump" \
    'd="$BACKUP_DIR/push_clone"; rm -rf "$d"; git clone -q --no-hardlinks . "$d" && cp Emuqu/Sources/Utilities/RecoveryScoreConstants.swift "$d/Emuqu/Sources/Utilities/" && cp scripts/check_scoring_governance.sh "$d/scripts/" && cp scripts/lib/scoring_hash.py "$d/scripts/lib/" && cp .ci/scoring_constants_hash.txt "$d/.ci/" && (cd "$d" && h="$(./scripts/check_scoring_governance.sh 2>&1 | sed -n "s/.*hashed (\([0-9a-f]*\)).*/\1/p")"; [[ -z "$h" ]] || sed -i.bak "s/ [0-9a-f]\{16\}/ $h/" .ci/scoring_constants_hash.txt; rm -f .ci/scoring_constants_hash.txt.bak; git -c user.name=gate -c user.email=gate@localhost commit -qam "planted push" --allow-empty && git update-ref refs/remotes/origin/main HEAD && env -u GITHUB_BASE_REF -u SCORING_BASE_REF -u GITHUB_EVENT_PATH GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push PUSH_BEFORE="$(git rev-parse HEAD~1)" ./scripts/check_scoring_governance.sh)' \
    "Emuqu/Sources/Utilities/RecoveryScoreConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/RecoveryScoreConstants.swift');s=p.read_text();o='static let rhrZScoreMultiplier: Double = -5.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let rhrZScoreMultiplier: Double = -6.0'))"

# Numbers written inline in the scoring code shape a score as much as the
# named constants do. Each of these edits one with the version and baseline
# left alone, and the gate must go red: a z-score band, the band table the
# score binds to, an age norm, the z clamp and the sleep-duration cap.
check "scoring_governance/band_table_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='(-0.75, 64.0),';assert s.count(o)==1;p.write_text(s.replace(o,'(-0.75, 60.0),'))"

check "scoring_governance/band_table_rebound" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='defaultScoringParameters: ScoringParameters = scoringParametersV2';assert s.count(o)==1;p.write_text(s.replace(o,'defaultScoringParameters: ScoringParameters = scoringParametersV1'))"

check "scoring_governance/age_norm_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/HRVThresholds.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVThresholds.swift');s=p.read_text();o='case 20 ..< 30: 45.0';assert s.count(o)==1;p.write_text(s.replace(o,'case 20 ..< 30: 50.0'))"

check "scoring_governance/inline_z_clamp" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='max(-3.0, min(3.0, z))';assert s.count(o)==1;p.write_text(s.replace(o,'max(-2.5, min(2.5, z))'))"

check "scoring_governance/sleep_cap_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator+Tiers.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator+Tiers.swift');s=p.read_text();o='max(typicalSleepHours, 1.0), 1.2)';assert s.count(o)==1;p.write_text(s.replace(o,'max(typicalSleepHours, 1.0), 1.3)'))"

# A constant that reaches the score from outside the scoring files, and the
# scoring code's operators, move the hash too: the baseline SD floor, the
# baseline's night window and minimum night count, a fragmentation weight
# the sleep analyzer reads, and a comparison flipped in the band
# interpolation each go red with the version left alone.
check "scoring_governance/baseline_sd_floor_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Utilities/SleepAndDisplayConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/SleepAndDisplayConstants.swift');s=p.read_text();o='static let lnRmssdSDFloor: Double = 0.10';assert s.count(o)==1;p.write_text(s.replace(o,'static let lnRmssdSDFloor: Double = 0.30'))"

check "scoring_governance/baseline_window_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/BaselineTracker.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BaselineTracker.swift');s=p.read_text();o='static let recoveryWindowNights = 60';assert s.count(o)==1;p.write_text(s.replace(o,'static let recoveryWindowNights = 7'))"

check "scoring_governance/baseline_minimum_days_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/BaselineTracker.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BaselineTracker.swift');s=p.read_text();o='static let minimumDays = 3';assert s.count(o)==1;p.write_text(s.replace(o,'static let minimumDays = 1'))"

check "scoring_governance/fragmentation_weight_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Utilities/SleepAndDisplayConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/SleepAndDisplayConstants.swift');s=p.read_text();o='static let fragmentationWakePercentWeight: Double = 2.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let fragmentationWakePercentWeight: Double = 3.0'))"

check "scoring_governance/flipped_operator" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='where z <= bands[i + 1].z';assert s.count(o)==1;p.write_text(s.replace(o,'where z < bands[i + 1].z'))"

# Inputs that reach a stored score through an instance value rather than a
# name the scoring files write move the hash too: the ANS norms and the SNS
# index the composite's ANS balance reads, the HRV quality rule that swaps
# in the baseline, the overnight window's time floor, the sleep staging
# epoch floor and the training readiness curve.
check "scoring_governance/ans_norm_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Utilities/Constants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Constants.swift');s=p.read_text();o='static let refRMSSD: Double = 42.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let refRMSSD: Double = 40.0'))"

check "scoring_governance/sns_index_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/StressAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/StressAnalysis.swift');s=p.read_text();o='let zMeanHR = (meanHR - StressNormativeConstants.refMeanHR)';assert s.count(o)==1;p.write_text(s.replace(o,'let zMeanHR = (meanHR + StressNormativeConstants.refMeanHR)'))"

check "scoring_governance/hrv_quality_rule_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Services/SessionAcceptanceService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='let longEnough = sessionDuration >= HRVConstants';assert s.count(o)==1;p.write_text(s.replace(o,'let longEnough = sessionDuration > HRVConstants'))"

check "scoring_governance/window_span_floor_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/WindowSelector+Scoring.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Scoring.swift');s=p.read_text();o='var minWindowSpanMs: Int64 = HRVConstants.MinimumDuration.forReliableWindowMs';assert s.count(o)==1;p.write_text(s.replace(o,'var minWindowSpanMs: Int64 = 0'))"

check "scoring_governance/sleep_epoch_floor_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift');s=p.read_text();o='private static let minValidRRsPerWindow = 8';assert s.count(o)==1;p.write_text(s.replace(o,'private static let minValidRRsPerWindow = 9'))"

check "scoring_governance/readiness_curve_edit" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/ReadinessScoring.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/ReadinessScoring.swift');s=p.read_text();o='guard capacityRatio > 0 else { return r.readinessAtZero }';assert s.count(o)==1;p.write_text(s.replace(o,'guard capacityRatio >= 0 else { return r.readinessAtZero }'))"

# A change of hashing scheme must not open a window for a constant change:
# with the base's baseline written under the older `static-lets` scheme, a
# constant edited and the baseline rewritten under the current scheme still
# fails, because the tree is rehashed the base's way. A throwaway clone
# commits a `static-lets` baseline as the base, then takes the working copy's
# constants and gate and records their current-scheme hash.
check "scoring_governance/scheme_change_hides_constant_change" \
    'd="$BACKUP_DIR/scheme_clone"; rm -rf "$d"; git clone -q --no-hardlinks . "$d" && cp scripts/check_scoring_governance.sh "$d/scripts/" && cp scripts/lib/scoring_hash.py "$d/scripts/lib/" && (cd "$d" && printf "%s %s\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py static-lets | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && git -c user.name=gate -c user.email=gate@localhost commit -qam "static-lets base" --allow-empty) && cp Emuqu/Sources/Utilities/RecoveryScoreConstants.swift "$d/Emuqu/Sources/Utilities/" && (cd "$d" && printf "%s %s decl-flow\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py decl-flow | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && SCORING_BASE_REF=HEAD ./scripts/check_scoring_governance.sh)' \
    "Emuqu/Sources/Utilities/RecoveryScoreConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/RecoveryScoreConstants.swift');s=p.read_text();o='static let rhrZScoreMultiplier: Double = -5.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let rhrZScoreMultiplier: Double = -6.0'))"

# A scheme that measures more must not carry an edit only it can see: with
# the base recorded under `decl-literals`, which reads numbers only, a
# comparison flipped in the scoring code and the baseline rewritten under the
# current scheme, version unchanged, still fails, because the base's own
# sources are hashed under the current scheme as well.
check "scoring_governance/scheme_change_hides_operator_change" \
    'd="$BACKUP_DIR/operator_clone"; rm -rf "$d"; git clone -q --no-hardlinks . "$d" && cp scripts/check_scoring_governance.sh "$d/scripts/" && cp scripts/lib/scoring_hash.py "$d/scripts/lib/" && (cd "$d" && printf "%s %s decl-literals\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py decl-literals | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && git -c user.name=gate -c user.email=gate@localhost commit -qam "decl-literals base" --allow-empty) && cp Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift "$d/Emuqu/Sources/Analysis/" && (cd "$d" && printf "%s %s decl-flow\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py decl-flow | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && SCORING_BASE_REF=HEAD ./scripts/check_scoring_governance.sh)' \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='where z <= bands[i + 1].z';assert s.count(o)==1;p.write_text(s.replace(o,'where z < bands[i + 1].z'))"

# The mutation harness credits a mutation only to a recorded assertion
# failure. With that requirement taken out, a run that stopped after a test
# started reads as a catch again, and the probe must go red.
check "mutation_harness/interrupted_run_counted_as_catch" \
    "./scripts/lib/mutation_result_probe.sh" \
    "scripts/verify_tests_fail.sh" \
    "import pathlib;p=pathlib.Path('scripts/verify_tests_fail.sh');s=p.read_text();o='        return 1\n    fi\n    return 4\n}';assert s.count(o)==1;p.write_text(s.replace(o,'        return 1\n    fi\n    return 1\n}'))"

# Constants the pattern no longer matches hash nothing and would never move.
check "scoring_governance/no_constants_matched" \
    "./scripts/check_scoring_governance.sh" \
    "Emuqu/Sources/Analysis/HRVThresholds.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVThresholds.swift');s=p.read_text();assert 'static let' in s;p.write_text(s.replace('static let','static var'))"

# Putting a heart-rate readiness wait back in front of the feed's subscribe
# restores the stall that cost a night of sleep. The gate must go red on it.
check "hr_feed/readiness_wait" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapHeartRateFeed.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapHeartRateFeed.swift');s=p.read_text();o='        var failures = 0\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = await manager?.link.awaitFeature(.heartRate, until: nil)\n'+o))"

# Warnings as errors must hold in every shipping configuration. Dropped from
# the project's Release configuration, or overridden to NO in the watch app's
# Release, one YES line is still left in the file; both must go red.
check "strict_concurrency_enabled/werror_dropped_from_release" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='\t\t\t\tSWIFT_TREAT_WARNINGS_AS_ERRORS = YES;\n';assert s.count(o)==2;i=s.rindex(o);assert s.find('name = Release;',i)<s.find('name = Debug;',i) or s.find('name = Debug;',i)<0;p.write_text(s[:i]+s[i+len(o):])"

check "strict_concurrency_enabled/werror_off_in_watch_release" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();o='\t\tEFEA95DA2F96B4A200CE7D82 /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n';assert s.count(o)==1;p.write_text(s.replace(o,o+'\t\t\t\tSWIFT_TREAT_WARNINGS_AS_ERRORS = NO;\n'))"

# Dropping `@Sendable` from the pedometer handler restores the exact code that
# trapped in the field. The gate must go red on it.
check "coremotion_isolation/inherited_actor" \
    "./scripts/check_coremotion_handler_isolation.sh" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='{ @Sendable [weak self] data, error in';assert s.count(o)==1;p.write_text(s.replace(o,'{ [weak self] data, error in'))"

# The logger may not call itself: one planted `attempt(` in DebugLog.swift must go red.
check "logger_self_reference/planted_attempt" \
    "./scripts/check_logger_self_reference.sh" \
    "Emuqu/Sources/Utilities/DebugLog.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');p.write_text(p.read_text()+'\\nprivate func plantedGateCheck() { _ = attempt(\"planted\") { try FileManager.default.removeItem(atPath: \"/nope\") } }\\n')"


# A single `.shared` read outside the composition root must go red.
check "no_shared_outside_root/planted_read" \
    "./scripts/check_no_shared_outside_root.sh" \
    "Emuqu/Sources/Collection/CollectorSessionControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl.swift');p.write_text(p.read_text()+chr(10)+'private let plantedRead = SettingsManager.shared'+chr(10))"

# An `AppDependencies.current` read in a file handed its dependencies, and a
# container installed in app code, must each go red.
check "explicit_dependencies/planted_lookup" \
    "./scripts/check_explicit_dependencies.sh" \
    "Emuqu/Sources/Services/AppLaunchTasks.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/AppLaunchTasks.swift');p.write_text(p.read_text()+chr(10)+'private let plantedLookup = AppDependencies.current.app'+chr(10))"

check "explicit_dependencies/planted_reanalysis_lookup" \
    "./scripts/check_explicit_dependencies.sh" \
    "Emuqu/Sources/Services/ReanalysisService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService.swift');p.write_text(p.read_text()+chr(10)+'private let plantedLookup = AppDependencies.current.app'+chr(10))"

check "explicit_dependencies/planted_service_list" \
    "./scripts/check_explicit_dependencies.sh" \
    "Emuqu/Sources/Assistant/Facts/SleepFacts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/SleepFacts.swift');p.write_text(p.read_text()+chr(10)+'private let plantedLookup = FactServices(.current)'+chr(10))"

check "explicit_dependencies/planted_install" \
    "./scripts/check_explicit_dependencies.sh" \
    "Emuqu/Sources/Views/DeleteAllDataPage.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/DeleteAllDataPage.swift');p.write_text(p.read_text()+chr(10)+'private let plantedInstall = AppDependencies.install(AppDependencies())'+chr(10))"

# A UI-test suite whose launch drops -UITests-FreshInstall must go red; the
# flag left in the file's doc comment must not satisfy the gate.
check "uitest_fresh_install/dropped_flag" \
    "./scripts/check_uitest_fresh_install.sh" \
    "EmuquUITests/DashboardUITests.swift" \
    "import pathlib;p=pathlib.Path('EmuquUITests/DashboardUITests.swift');s=p.read_text();t=s.replace('app.launchArguments += [\"-UITests\", \"-UITests-FreshInstall\"]','app.launchArguments += [\"-UITests\"]',1);assert t!=s;p.write_text(t)"


# Localization lookups in every call shape and in the app root.
check "localization_bundle/split_after_paren" "./scripts/check_localization_bundle.sh" "Emuqu/Sources/Utilities/Errors.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'let plantedSplit = String('+chr(10)+'    localized: \"planted no bundle\")'+chr(10))"
check "localization_bundle/nil_bundle" "./scripts/check_localization_bundle.sh" "Emuqu/Sources/Utilities/Errors.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'let plantedNil = String(localized: \"planted nil bundle\", bundle: nil)'+chr(10))"
check "localization_bundle/app_root" "./scripts/check_localization_bundle.sh" "Emuqu/EmuquApp.swift" "import pathlib;p=pathlib.Path('Emuqu/EmuquApp.swift');s=p.read_text();o='Button(String(localized: \"Resume\", bundle: LanguageManager.appBundle))';assert s.count(o)==1;p.write_text(s.replace(o,'Button(String(localized: \"Resume\"))'))"
check "localization_resolution/app_root" "./scripts/check_localization_resolution.sh" "Emuqu/EmuquApp.swift" "import pathlib;p=pathlib.Path('Emuqu/EmuquApp.swift');s=p.read_text();o='Button(String(localized: \"Resume\", bundle: LanguageManager.appBundle))';assert s.count(o)==1;p.write_text(s.replace(o,'Button(String(localized: \"Resume planted absent key\", bundle: LanguageManager.appBundle))'))"
check "localization_resolution/single_letter_unit" "./scripts/check_localization_resolution.sh" "Emuqu/Sources/Utilities/Errors.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfunc plantedUnit(_ n: Int) -> String { String(localized: \"\\\\(n) q\", bundle: LanguageManager.appBundle) }\n')"
check "localization_resolution/navigation_link" "./scripts/check_localization_resolution.sh" "Emuqu/Sources/Views/SettingsView.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+'\nimport SwiftUI\nprivate struct PlantedNav: View { var body: some View { NavigationLink(\"Planted absent nav key\") { EmptyView() } } }\n')"
check "localization_orphans/commented_request" "./scripts/check_localization_orphans.sh" "Emuqu/Sources/Views/ConnectionPanelViews.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/ConnectionPanelViews.swift');s=p.read_text();o='.accessibilityHint(Text(String(localized: \"Connects to this device\", bundle: LanguageManager.appBundle)))';assert s.count(o)==1;p.write_text(s.replace(o,'// '+o))"
check "localization_coverage/plist_prompt_absent" "./scripts/check_localization_coverage.sh Emuqu/InfoPlist.xcstrings" "Emuqu/Info.plist" "import pathlib;p=pathlib.Path('Emuqu/Info.plist');s=p.read_text();o='<key>NSMicrophoneUsageDescription</key>';assert s.count(o)==1;p.write_text(s.replace(o,'<key>NSCameraUsageDescription</key>\n\t<string>Planted English-only camera prompt.</string>\n\t'+o))"
check "locale_formatting/localized_template" "./scripts/check_locale_formatting.sh" "Emuqu/Sources/Views/SettingsView.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFormat = String(format: String(localized: \"%.1f km\", bundle: LanguageManager.appBundle), 1.0)'+chr(10))"
check "locale_formatting/assistant_view" "./scripts/check_locale_formatting.sh" "Emuqu/Sources/Assistant/Views/ChatBubble.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Views/ChatBubble.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFormat = String(format: \"%.1f\", 1.0)'+chr(10))"
check "fixed_font/split_call" "./scripts/check_fixed_font_budget.sh" "Emuqu/Sources/Views/SettingsView.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFixedFont = Text(\"x\").font(.system('+chr(10)+'    size: 17, weight: .bold))'+chr(10))"
check "fixed_font/watch_split" "./scripts/check_fixed_font_budget.sh" "EmuquWatch Watch App/WatchSessionManager.swift" "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchSessionManager.swift');p.write_text(p.read_text()+chr(10)+'import SwiftUI'+chr(10)+'private let plantedFixedFont = Font.system('+chr(10)+'    size: 17)'+chr(10))"
check "fixed_font/custom_fixed_size" "./scripts/check_fixed_font_budget.sh" "Emuqu/Sources/Views/SettingsView.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFixedFont = Text(\"x\").font(.custom(\"Menlo\", fixedSize: 17))'+chr(10))"

# Declaration shapes the spec measures, budgets bash would misread, and limits
# kept outside .ci/.
check "spec_conformance/property_comment_on_brace" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['        let v%d = %d' % (i,i) for i in range(25)]);p.write_text(p.read_text()+'\nstruct PlantedProperty {\n    var planted: Int { // layout\n'+body+'\n        return 0\n    }\n}\n')"
check "spec_conformance/deinit" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['        let v%d = %d' % (i,i) for i in range(25)]);p.write_text(p.read_text()+'\nfinal class PlantedDeinit {\n    deinit {\n'+body+'\n    }\n}\n')"
check "spec_conformance/operator_func" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['        let v%d = %d' % (i,i) for i in range(25)]);p.write_text(p.read_text()+'\nstruct PlantedEquatable: Equatable {\n    static func == (lhs: PlantedEquatable, rhs: PlantedEquatable) -> Bool {\n'+body+'\n        return true\n    }\n}\n')"
check "spec_conformance/property_observer" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['            let v%d = %d' % (i,i) for i in range(25)]);p.write_text(p.read_text()+'\nstruct PlantedObserver {\n    var planted = 0 {\n        didSet {\n'+body+'\n        }\n    }\n}\n')"
check "spec_conformance/closure_property_with_signature" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');body='\n'.join(['        let v%d = %d' % (i,i) for i in range(25)]);p.write_text(p.read_text()+'\nfinal class PlantedLazy {\n    lazy var planted: Int = { () -> Int in\n'+body+'\n        return 0\n    }()\n}\n')"
check "spec_conformance/empty_catch_with_where" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfunc plantedWhere() {\n    do { try plantedThrow() } catch let e as NSError where e.code == 1 {\n        // ignore\n    } catch { print(error) }\n}\nfunc plantedThrow() throws {}\n')"
check "spec_conformance/watch_empty_catch" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "EmuquWatch Watch App/WatchDependencies.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchDependencies.swift');p.write_text(p.read_text()+'\nfunc plantedWatchCatch() {\n    do { try plantedWatchThrow() } catch {\n        // ignore\n    }\n}\nfunc plantedWatchThrow() throws {}\n')"
check "spec_conformance/watch_waiver_uncapped" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "EmuquWatch Watch App/WatchDependencies.swift" \
    "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchDependencies.swift');body='\n'.join(['    let v%d = %d' % (i,i) for i in range(30)]);p.write_text(p.read_text()+'\n// spec:long-function planted reason\nfunc plantedWatchLong() {\n'+body+'\n}\n')"
check "tech_debt_budgets/leading_zero_budget" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    ".ci/try_optional_budget.txt" \
    "import pathlib;pathlib.Path('.ci/try_optional_budget.txt').write_text('08'+chr(10))"
check "tech_debt_budgets/write_continued_on_next_line" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    "Emuqu/Sources/Assistant/TTSTextNormalizer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/TTSTextNormalizer.swift');s=p.read_text();o='        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = try? payload'+chr(10)+'            .write(to: url, options: .atomic)'+chr(10)+'        guard let regex = Self.cachedRegex(pattern) else { return text }'))"
check "tech_debt_budgets/replace_item_write" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    "Emuqu/Sources/Assistant/TTSTextNormalizer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/TTSTextNormalizer.swift');s=p.read_text();o='        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)'+chr(10)+'        guard let regex = Self.cachedRegex(pattern) else { return text }'))"
check "coupling_budget/hub_in_collection_type" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthObservation.swift');p.write_text(p.read_text()+chr(10)+'struct PlantedHolder { let collectors: [RRCollector] }'+chr(10))"
check "coupling_budget/optional_chained_forwarder" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthObservation.swift');p.write_text(p.read_text()+chr(10)+'struct PlantedForwarder { weak var recorder: PlantedStopper?; func stop() { recorder?.stop() } }'+chr(10))"
check "coupling_budget/root_by_file_name" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;pathlib.Path('Emuqu/Sources/Collection/AppDependenciesPlanted.swift').write_text('let plantedLocator = AppDependencies.current'+chr(10))"
# That plant creates a file, which restore_all cannot remove.
rm -f Emuqu/Sources/Collection/AppDependenciesPlanted.swift
check "swiftlint_rule/disable_next_in_app" \
    "./scripts/enforce_swiftlint_budget.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'// swiftlint:disable:next force_unwrapping'+chr(10)+'private func plantedUnwrap(_ value: Int?) -> Int { value! }'+chr(10))"
check "swiftlint_budget/slack" \
    "./scripts/enforce_swiftlint_budget.sh" \
    ".ci/swiftlint_warning_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/swiftlint_warning_budget.txt');p.write_text(str(int(p.read_text().strip())+1)+chr(10))"
check "budget_monotonicity/leading_zero_ceiling" \
    "./scripts/check_budget_monotonicity.sh HEAD" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/shared_usage_budget.txt');p.write_text('0'+str(int(p.read_text().strip())-1)+chr(10))"
check "budget_monotonicity/spec_limit_raised" \
    "./scripts/check_budget_monotonicity.sh HEAD" \
    "scripts/check_refactor_spec_conformance.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_refactor_spec_conformance.sh');s=p.read_text();o='MAX_BODY = 20';assert s.count(o)==1;p.write_text(s.replace(o,'MAX_BODY = 60'))"
check "budget_monotonicity/swiftlint_threshold_raised" \
    "./scripts/check_budget_monotonicity.sh HEAD" \
    ".swiftlint.yml" \
    "import pathlib;p=pathlib.Path('.swiftlint.yml');s=p.read_text();o='line_length:'+chr(10)+'  warning: 300';assert s.count(o)==1;p.write_text(s.replace(o,'line_length:'+chr(10)+'  warning: 1700'))"

# Spellings each gate's header claims and an earlier pattern missed.
check "logger_self_reference/self_shared" \
    "./scripts/check_logger_self_reference.sh" \
    "Emuqu/Sources/Utilities/DebugLog.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');p.write_text(p.read_text()+chr(10)+'extension DebugLogger { func plantedReentry() { Self.shared.flush() } }'+chr(10))"

check "hr_feed/guarded_start" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        feed.start(generation: generation)';assert s.count(o)==1;p.write_text(s.replace(o,'        guard plantedReady else { return }'+chr(10)+o))"

check "hr_feed/thread_sleep" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapHeartRateFeed.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapHeartRateFeed.swift');p.write_text(p.read_text()+chr(10)+'func plantedWait() { Thread.sleep(forTimeInterval: 10) }'+chr(10))"

check "test_skip_budget/multiline_disabled" \
    "./scripts/check_test_skip_budget.sh" \
    "EmuquTests/StressAnalysisTests.swift" \
    "import pathlib;p=pathlib.Path('EmuquTests/StressAnalysisTests.swift');p.write_text(p.read_text()+chr(10)+'@Test('+chr(10)+'    \"planted\",'+chr(10)+'    .disabled(\"radio\")'+chr(10)+')'+chr(10)+'func plantedDisabled() {}'+chr(10))"

check "test_skip_budget/slack" \
    "./scripts/check_test_skip_budget.sh" \
    ".ci/test_skip_budget.txt" \
    "import pathlib;p=pathlib.Path('.ci/test_skip_budget.txt');p.write_text(str(int(p.read_text().strip())+1)+chr(10))"

check "spec_conformance/discarded_error" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfunc plantedDiscard() {\n    do { try plantedDiscardThrow() } catch { _ = error }\n}\nfunc plantedDiscardThrow() throws {}\n')"

check "spec_conformance/example_inside_a_word" \
    "./scripts/check_refactor_spec_conformance.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfunc plantedCorpse() {\n    // let memoryUsage = Probe.read()\n    // archive.save(memoryUsage)\n}\n')"

check "coremotion_handler_isolation/event_updates" \
    "./scripts/check_coremotion_handler_isolation.sh" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='        pedometer.startUpdates(from: start) { @Sendable [weak self] data, error in';assert s.count(o)==1;p.write_text(s.replace(o,'        pedometer.startEventUpdates { event, _ in _ = event }'+chr(10)+o))"

check "locale_formatting/nsstring_format" \
    "./scripts/check_locale_formatting.sh" \
    "Emuqu/Sources/Views/SettingsView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFormat = NSString(format: \"%.1f km\", 1.0) as String'+chr(10))"

check "xcodebuild_pinned/spaced_make_alias" \
    "./scripts/check_xcodebuild_pinned.sh" \
    "Makefile" \
    "import pathlib;p=pathlib.Path('Makefile');p.write_text(p.read_text()+chr(10)+'PLANTED_XCODEBUILD = xcode'+'build'+chr(10)+'planted-build:'+chr(10)+chr(9)+'\$(PLANTED_XCODEBUILD) test -scheme Emuqu'+chr(10))"

check "xcodebuild_pinned/python_heredoc_in_shell" \
    "./scripts/check_xcodebuild_pinned.sh" \
    "scripts/check_file_names.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_file_names.sh');p.write_text(p.read_text()+chr(10)+'python3 - <<PLANTED'+chr(10)+'import subprocess; subprocess.run([\"xcode'+'build\", \"test\", \"-scheme\", \"Emuqu\"])'+chr(10)+'PLANTED'+chr(10))"

check "eager_permission_prompt/qualified_builder_in_init" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,o+chr(10)+'    init() { peripheralManager = Self.plantedMake() }'+chr(10)+'    static func plantedMake() -> CBPeripheralManager { CBPeripheralManager(delegate: nil, queue: nil) }'))"

check "eager_permission_prompt/wrapped_stored_property" \
    "./scripts/check_no_eager_permission_prompts.sh" \
    "Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ZwiftPeripheralBroadcaster.swift');s=p.read_text();o='    @ObservationIgnored private var peripheralManager: CBPeripheralManager?';assert s.count(o)==1;p.write_text(s.replace(o,o+chr(10)+'    private let plantedManager: CBPeripheralManager ='+chr(10)+'        CBPeripheralManager(delegate: nil, queue: nil)'))"

check "no_developer_endpoint/unlisted_sdk" \
    "./scripts/check_no_developer_endpoint.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');p.write_text(p.read_text()+'\n/* planted https://github.com/TelemetryDeck/SwiftSDK reference */\n')"

check "gates_wired/fallback_echo" \
    "./scripts/check_gates_wired.sh" \
    ".github/workflows/ci.yml" \
    "import pathlib;p=pathlib.Path('.github/workflows/ci.yml');s=p.read_text();o='run: ./scripts/check_log_redaction.sh'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,'run: ./scripts/check_log_redaction.sh || echo \"::warning::failed\"'+chr(10)))"

check "gates_wired/make_ignore_errors" \
    "./scripts/check_gates_wired.sh" \
    "Makefile" \
    "import pathlib;p=pathlib.Path('Makefile');s=p.read_text();o=chr(9)+'@build/validation-venv/bin/python -I Tools/validation/test_ports.py';assert s.count(o)==1;p.write_text(s.replace(o,chr(9)+'@-build/validation-venv/bin/python -I Tools/validation/test_ports.py'))"

check "doc_links/watch_path" \
    "./scripts/check_doc_links.sh" \
    "README.md" \
    "import pathlib;p=pathlib.Path('README.md');p.write_text(p.read_text()+'\nSee \`EmuquWatch Watch App/PlantedGone.swift\` for details.\n')"

check "doc_links/budget_value_on_the_line_before" \
    "./scripts/check_doc_links.sh" \
    "docs/LOCALIZATION.md" \
    "import pathlib;p=pathlib.Path('docs/LOCALIZATION.md');p.write_text(p.read_text()+'\nThe floor is 100 percent; see\nmin_localization_coverage.txt for details.\n')"

check "fixed_font/qualified_constant" \
    "./scripts/check_fixed_font_budget.sh" \
    "Emuqu/Sources/Views/SettingsView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private enum PlantedLayout {'+chr(10)+'    static let plantedTitleSize: CGFloat = 34'+chr(10)+'}'+chr(10)+'private let plantedFixedFont = Text(\"x\").font(.system(size: PlantedLayout.plantedTitleSize, weight: .bold))'+chr(10))"

check "localization_bundle/inside_interpolation" \
    "./scripts/check_localization_bundle.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'let plantedNested = \"\\\\(String(localized: \"planted average\")): 1\"'+chr(10))"

check "log_redaction/wrapped_value" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedWrapped(email: String?) { debugLog(\"to \\\\(String(describing: email))\") }'+chr(10))"

check "log_redaction/logger_sink" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedSink(query: String) { DebugLogger.shared.log(\"asked \\\\(query)\") }'+chr(10))"

check "log_redaction/optional_logger" \
    "./scripts/check_log_redaction.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'func plantedOptional(logger: Logger?, query: String) { logger?.info(\"asked \\\\(query)\") }'+chr(10))"

check "cloudkit/key_from_enum_raw_value" \
    "./scripts/check_no_health_data_in_cloudkit.sh" \
    "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');p.write_text(p.read_text()+chr(10)+'func plantedWrite(record: CKRecord, s: HRVSession) { record[PlantedField.meanRMSSD.rawValue] = 1.0 as CKRecordValue }'+chr(10))"

check "science_register/computed_property" \
    "./scripts/check_science_register.sh" \
    "Emuqu/Sources/Collection/TrainingLoad.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingLoad.swift');p.write_text(p.read_text()+chr(10)+'extension TrainingLoad { var plantedSleepDebtPenalty: Double { 1.0 } }'+chr(10))"

check "coupling_budget/implicit_member_read" \
    "./scripts/check_coupling_budget.sh" \
    "Emuqu/Sources/Collection/HealthObservation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthObservation.swift');p.write_text(p.read_text()+chr(10)+'let plantedServices = WorkoutServices(.current)'+chr(10))"

check "empty_range/guard_that_does_not_dominate" \
    "./scripts/check_empty_range_loops.sh" \
    "Emuqu/Sources/Analysis/Verification.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/Verification.swift');p.write_text(p.read_text()+'\nfunc plantedRange(xs: [Int]) {\n    if xs.count >= 2 { print(xs) }\n    for i in 0 ..< xs.count - 2 { print(i) }\n}\n')"

check "empty_range/guard_of_the_wrong_polarity" \
    "./scripts/check_empty_range_loops.sh" \
    "Emuqu/Sources/Analysis/Verification.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/Verification.swift');p.write_text(p.read_text()+'\nfunc plantedRange(xs: [Int]) {\n    guard xs.isEmpty else { return }\n    for i in 1 ..< xs.count { print(i) }\n}\n')"

# The Thread Sanitizer gate needs a simulator build, so here it runs against a
# stand-in xcodebuild that behaves as the real one does in the ways the gate
# depends on: a race report reaches the output only when parallel testing is
# off (with it on, the host's stderr goes to per-clone logs), a race ends the
# host unless it is told `halt_on_error=0`, the canary races only when the host
# gets `EMUQU_TSAN_CANARY=1`, and a blind host reports nothing at all. The fixture file says whether the
# suite holds a race (`race`) or the host is blind (`blind`).
TSAN_STUB_BIN="$BACKUP_DIR/tsan-bin"
TSAN_SUITE_FIXTURE="$BACKUP_DIR/tsan-suite-races"
mkdir -p "$TSAN_STUB_BIN"
printf 'none\n' > "$TSAN_SUITE_FIXTURE"
cat > "$TSAN_STUB_BIN/xcodebuild" <<'STUB'
#!/usr/bin/env bash
parallel=YES prev=""
for arg in "$@"; do
    [[ "$prev" == "-parallel-testing-enabled" ]] && parallel="$arg"
    prev="$arg"
done
report() {
    [[ "$parallel" == "NO" ]] || return 0
    grep -q blind "$TSAN_SUITE_FIXTURE" && return 0
    echo "WARNING: ThreadSanitizer: data race (pid=1)"
    echo "SUMMARY: ThreadSanitizer: Swift access race (/tmp/EmuquTests.xctest/EmuquTests:arm64+0x6b184) in closure #1 in $1()"
    # The simulator's sanitizer halts on its first report unless told not to.
    if [[ "${TEST_RUNNER_TSAN_OPTIONS:-}" != *halt_on_error=0* ]]; then
        echo "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches."
        echo "Test Case '-[EmuquTests.StubTests testOne]' failed (0.001 seconds)."
        echo "** TEST FAILED **"
        exit 65
    fi
}
echo "Test Case '-[EmuquTests.StubTests testOne]' started."
# `lostcanary`: the first run reports a suite race but loses the canary, so the
# gate retries it as blind; the second run reports only the canary.
if grep -q lostcanary "$TSAN_SUITE_FIXTURE"; then
    runs="$TSAN_SUITE_FIXTURE.runs"; n=$(( $(cat "$runs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$runs"
    if (( n == 1 )); then report StubTests.testOne
    else report ThreadSanitizerCanaryTests.testUnsynchronizedWritesRaceWhenTheCanaryIsRequested; fi
    echo "Test Case '-[EmuquTests.StubTests testOne]' passed (0.001 seconds)."; echo "** TEST SUCCEEDED **"; exit 0
fi
[[ "${TEST_RUNNER_EMUQU_TSAN_CANARY:-}" == "1" ]] && report ThreadSanitizerCanaryTests.testUnsynchronizedWritesRaceWhenTheCanaryIsRequested
grep -q race "$TSAN_SUITE_FIXTURE" && report StubTests.testOne
echo "Test Case '-[EmuquTests.StubTests testOne]' passed (0.001 seconds)."
echo "** TEST SUCCEEDED **"
STUB
chmod +x "$TSAN_STUB_BIN/xcodebuild"
TSAN_GATE="PATH=$TSAN_STUB_BIN:\$PATH TSAN_SUITE_FIXTURE=$TSAN_SUITE_FIXTURE DESTINATION=stub ./scripts/check_thread_sanitizer.sh"

check "thread_sanitizer/race_in_suite" \
    "$TSAN_GATE" \
    "$TSAN_SUITE_FIXTURE" \
    "import pathlib;pathlib.Path('$TSAN_SUITE_FIXTURE').write_text('race'+chr(10))"

check "thread_sanitizer/parallel_testing_hides_races" \
    "$TSAN_GATE" \
    "scripts/check_thread_sanitizer.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_thread_sanitizer.sh');s=p.read_text();o='        -parallel-testing-enabled NO \\\\'+chr(10);assert s.count(o)==1;p.write_text(s.replace(o,''))"

check "thread_sanitizer/canary_not_asked_to_race" \
    "$TSAN_GATE" \
    "scripts/check_thread_sanitizer.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_thread_sanitizer.sh');s=p.read_text();o='env TEST_RUNNER_EMUQU_TSAN_CANARY=1 ';assert s.count(o)==1;p.write_text(s.replace(o,'env '))"

check "thread_sanitizer/race_halts_the_host" \
    "$TSAN_GATE" \
    "scripts/check_thread_sanitizer.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_thread_sanitizer.sh');s=p.read_text();o=' TEST_RUNNER_TSAN_OPTIONS=halt_on_error=0';assert s.count(o)==1;p.write_text(s.replace(o,''))"

check "thread_sanitizer/blind_host" \
    "$TSAN_GATE" \
    "$TSAN_SUITE_FIXTURE" \
    "import pathlib;pathlib.Path('$TSAN_SUITE_FIXTURE').write_text('blind'+chr(10))"

check "thread_sanitizer/race_in_run_retried_as_blind" \
    "$TSAN_GATE" \
    "$TSAN_SUITE_FIXTURE" \
    "import pathlib;pathlib.Path('$TSAN_SUITE_FIXTURE').write_text('lostcanary'+chr(10));pathlib.Path('$TSAN_SUITE_FIXTURE.runs').unlink(missing_ok=True)"

echo
echo "  $PASS proven, $FAIL not protecting anything, $SKIP skipped"
echo
echo "  Not covered here — check_coverage.sh (coverage floors) needs a build,"
echo "  so it is verified by its own runs. Every other gate in scripts/ has a"
echo "  plant above. If you add a gate, add its plant in the same commit."

# ---------------------------------------------------------------------------
# The meta-check: a gate with no plant here.
#
# A gate can be added, wired into `ci.yml`, and trusted without anyone ever
# watching it fail — and some of those turn out to be measuring nothing.
# Counting on the next person to remember is what produces such a list, so the
# harness refuses to report success while a gate it does not cover exists.
# Adding a gate and adding its plant are one change.
#
# The exemptions need a build or a simulator, which this file deliberately
# does not do — they are verified by their own CI runs instead.
# ---------------------------------------------------------------------------
NEEDS_BUILD=(
    check_coverage.sh
)

unplanted=()
for gate in scripts/check_*.sh scripts/enforce_*.sh; do
    base="$(basename "$gate")"
    exempt=false
    for e in "${NEEDS_BUILD[@]}"; do
        [[ "$base" == "$e" ]] && exempt=true && break
    done
    $exempt && continue
    # Planted means run: the gate's path has to be in a `check` case's gate
    # command (a quoted argument line, or a NAME="…" command it is given), not
    # just named in a comment or a message.
    grep -qE "^[[:space:]]*(\"|[A-Z_]+=\")[^\"]*\./scripts/${base//./\\.}" "$0" || unplanted+=("$base")
done

if (( ${#unplanted[@]} > 0 )); then
    echo >&2
    echo "ERROR: ${#unplanted[@]} gate(s) have no planted violation here:" >&2
    for g in "${unplanted[@]}"; do echo "  - $g" >&2; done
    echo >&2
    echo "A gate nobody has watched fail is a gate nobody knows works. Add a" >&2
    echo "check \"<name>\" entry that plants the violation it claims to catch," >&2
    echo "or add it to NEEDS_BUILD with the reason it cannot run here." >&2
    exit 1
fi

# The planted orphan is created, not modified, so restore_all cannot remove it.
rm -f Emuqu/Sources/Utilities/PlantedOrphan.swift Emuqu/Sources/Collection/AppDependenciesPlanted.swift

(( FAIL == 0 )) || exit 1

# A skipped case proved nothing: its gate was already red, or the plant's
# anchor text has changed. Counting it as success let a permanently red gate
# or a stale plant drop out of verification silently — the "reports clean
# while measuring nothing" shape this file exists to catch. Same rule as
# verify_tests_fail.sh.
if (( SKIP > 0 )); then
    echo "ERROR: ${SKIP} case(s) skipped; a skipped case is not a verified gate." >&2
    echo "Make the gate green, or re-anchor its plant, and run again." >&2
    exit 1
fi
