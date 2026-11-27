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

    eval "$gate" >/dev/null 2>&1
    local code=$?
    restore_all

    if (( code != 0 )); then
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
# the version the base branch recorded. The gate refreshes a copy of the
# baseline each run, as an author updating it in step would.
check "scoring_governance/baseline_relabelled_without_version_bump" \
    'b="$BACKUP_DIR/relabelled_baseline.txt"; h="$(./scripts/check_scoring_governance.sh 2>&1 | sed -n "s/.*hashed (\([0-9a-f]*\)).*/\1/p")"; sed "s/ [0-9a-f]\{16\}/ $h/" .ci/scoring_constants_hash.txt > "$b"; SCORING_BASELINE="$b" ./scripts/check_scoring_governance.sh' \
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

# A change of hashing scheme must not open a window for a constant change:
# with the base's baseline written under the older `static-lets` scheme, a
# constant edited and the baseline rewritten under the current scheme still
# fails, because the tree is rehashed the base's way. A throwaway clone
# commits a `static-lets` baseline as the base, then takes the working copy's
# constants and gate and records their current-scheme hash.
check "scoring_governance/scheme_change_hides_constant_change" \
    'd="$BACKUP_DIR/scheme_clone"; rm -rf "$d"; git clone -q --no-hardlinks . "$d" && cp scripts/check_scoring_governance.sh "$d/scripts/" && cp scripts/lib/scoring_hash.py "$d/scripts/lib/" && (cd "$d" && printf "%s %s\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py static-lets | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && git -c user.name=gate -c user.email=gate@localhost commit -qam "static-lets base" --allow-empty) && cp Emuqu/Sources/Utilities/RecoveryScoreConstants.swift "$d/Emuqu/Sources/Utilities/" && (cd "$d" && printf "%s %s decl-literals\n" "$(cut -d" " -f1 .ci/scoring_constants_hash.txt)" "$(python3 scripts/lib/scoring_hash.py decl-literals | cut -d" " -f1)" > .ci/scoring_constants_hash.txt && SCORING_BASE_REF=HEAD ./scripts/check_scoring_governance.sh)' \
    "Emuqu/Sources/Utilities/RecoveryScoreConstants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/RecoveryScoreConstants.swift');s=p.read_text();o='static let rhrZScoreMultiplier: Double = -5.0';assert s.count(o)==1;p.write_text(s.replace(o,'static let rhrZScoreMultiplier: Double = -6.0'))"

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
rm -f Emuqu/Sources/Utilities/PlantedOrphan.swift

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
