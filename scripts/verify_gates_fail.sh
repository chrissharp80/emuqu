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
#   • `check_gate_preflight.sh`'s own helper failing open, because `exit`
#     inside `$( )` terminates only the subshell.
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
# `make ci`. Gates that need a build (coverage, TSan, strict-concurrency count)
# are verified by their own runs, and are listed at the bottom as not covered.

set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
source "$(dirname "$0")/lib/preflight.sh"
gate_acquire_tree_lock "verify_gates_fail.sh"
BACKUP_DIR="$(gate_mktemp_dir verify-gates)" || exit $?
trap 'restore_all; rm -rf "$BACKUP_DIR"; gate_release_tree_lock' EXIT INT TERM HUP

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');p.write_text(p.read_text().replace('return try encryptedForCloud(compressed)','return compressed',1))"

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

check "strict_concurrency_enabled" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();p.write_text(s.replace('\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;\n','',1))"

check "strict_concurrency_enabled/swift5_mode" \
    "./scripts/check_strict_concurrency_enabled.sh" \
    "Emuqu.xcodeproj/project.pbxproj" \
    "import pathlib;p=pathlib.Path('Emuqu.xcodeproj/project.pbxproj');s=p.read_text();p.write_text(s.replace('SWIFT_VERSION = 6.0;','SWIFT_VERSION = 5.0;',1))"

check "gate_preflight/bare_mktemp" \
    "./scripts/check_gate_preflight.sh" \
    "scripts/check_log_redaction.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_log_redaction.sh');s=p.read_text();p.write_text(s.replace('tmp=\"\$(gate_mktemp log-redaction)\" || exit \$?','tmp=\"\$(mktemp)\"',1))"

check "gate_preflight/missing_guard" \
    "./scripts/check_gate_preflight.sh" \
    "scripts/check_log_redaction.sh" \
    "import pathlib;p=pathlib.Path('scripts/check_log_redaction.sh');s=p.read_text();p.write_text(s.replace('tmp=\"\$(gate_mktemp log-redaction)\" || exit \$?','tmp=\"\$(gate_mktemp log-redaction)\"',1))"

# A deleted snapshot reference does not fail — the harness records a new one
# and passes against itself forever.
check "snapshot_refs/deleted_reference" \
    "./scripts/check_snapshot_references.sh" \
    "EmuquTests/__Snapshots__/alpha1-report.raw" \
    "import pathlib;pathlib.Path('EmuquTests/__Snapshots__/alpha1-report.raw').unlink()"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/NonlinearAnalysis.swift');s=p.read_text();o='        guard rr.count >= 2 else { return 0 }\n';assert s.count(o)>=1;p.write_text(s.replace(o,'',1))"

# File counts in MAINTAINERS.md drift, often by 50% or more, when nothing
# checks them.
check "doc_counts/stale" \
    "./scripts/check_doc_file_counts.sh" \
    "docs/MAINTAINERS.md" \
    "import pathlib;p=pathlib.Path('docs/MAINTAINERS.md');s=p.read_text();o='### 5.1 \`Analysis/\` — physiology math + scoring (~74 files)';assert s.count(o)==1;p.write_text(s.replace(o,'### 5.1 \`Analysis/\` — physiology math + scoring (~7 files)'))"

# Raw `Int64(interval * 1000)` on stored dates is a shape that ships live
# defects.
#
check "date_ms/raw_conversion" \
    "./scripts/check_date_ms_conversion.sh" \
    "Emuqu/Sources/Analysis/SleepResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/SleepResolver.swift');s=p.read_text();o='MillisecondOffset.between(first.start, and: recordingStart, fallback: 0)';assert s.count(o)>=1;p.write_text(s.replace(o,'Int64(first.start.timeIntervalSince(recordingStart) * 1000)',1))"

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

check "unchecked_sendable" \
    "./scripts/check_unchecked_sendable.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+'\nfinal class PlantedUnsafe: @unchecked Sendable { nonisolated(unsafe) static var x = 0 }\n')"

check "orphan_swift" \
    "./scripts/check_no_orphan_swift.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;pathlib.Path('Emuqu/Sources/Utilities/PlantedOrphan.swift').write_text('// planted\nimport Foundation\n')"

# ---------------------------------------------------------------------------
# Every cheap gate in `scripts/` needs a plant here. A gate with none has
# never been watched fail, which is the standing this file exists to end. The
# gates that need a build or a simulator are named at the bottom.
# ---------------------------------------------------------------------------

# A citation is only useful if it is checked; unchecked, nearly all of them
# rot.
check "comment_citations/past_end_of_file" \
    "./scripts/check_comment_citations.sh" \
    "Emuqu/Sources/Utilities/Errors.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Errors.swift');p.write_text(p.read_text()+chr(10)+'// Planted citation: Errors.swift:99999'+chr(10))"

# A path with a `:NNN` tail must not slip past the path check; otherwise a
# citation can name the wrong directory indefinitely as long as it carries a
# line number.
check "doc_links/wrong_directory_with_line_number" \
    "./scripts/check_doc_links.sh" \
    "docs/ARCHITECTURE.md" \
    "import pathlib;p=pathlib.Path('docs/ARCHITECTURE.md');p.write_text(p.read_text()+chr(10)+'Planted: \`WrongDir/EmuquApp.swift:42\`'+chr(10))"

# The Markdown half. `file:NNN` in docs rots exactly as it does in Swift
# comments — every AssistantViewModel and HealthKitManager citation in the
# architecture docs can point past the end of a file that has since been split.
check "comment_citations/markdown" \
    "./scripts/check_comment_citations.sh" \
    "docs/ARCHITECTURE.md" \
    "import pathlib;p=pathlib.Path('docs/ARCHITECTURE.md');p.write_text(p.read_text()+chr(10)+'Planted doc citation: EmuquApp.swift:99999'+chr(10))"

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

# POSIX decimal separators in sixteen locales that use a comma.
check "locale_formatting/unlocalised_decimal" \
    "./scripts/check_locale_formatting.sh" \
    "Emuqu/Sources/Views/SettingsView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/SettingsView.swift');p.write_text(p.read_text()+chr(10)+'private let plantedFormat = String(format: \"%.1f\", 1.0)'+chr(10))"

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

# A budget file below the measured value must go red; this proves the
# comparison runs at all, which is the half of a budget gate that can rot
# silently while the counting half still works.
# Lowering the budget stopped proving anything once the budget reached 0 — the
# mutation became a no-op and the gate stayed green while protecting nothing.
# Plant an actually-oversized type instead.
check "aggregate_type_size/oversized_type" \
    "./scripts/check_aggregate_type_size.sh" \
    "Emuqu/Sources/Collection/StrapPairingStore.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPairingStore.swift');p.write_text(p.read_text()+chr(10)+'extension StrapPairingStore {'+chr(10)+('    // padding'+chr(10))*1600+'}'+chr(10))"

check "tech_debt_budgets/below_budget" \
    "./scripts/enforce_tech_debt_budgets.sh" \
    ".ci/shared_usage_budget.txt" \
    "import pathlib;pathlib.Path('.ci/shared_usage_budget.txt').write_text('0'+chr(10))"

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
    "Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift');s=p.read_text();o='pow('+chr(36)+'0, 4)';assert s.count(o)>=1;p.write_text(s.replace(o,'pow('+chr(36)+'0, 2)',1))"

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

# Every locale sits at 100%; a single untranslated key must drop the worst
# locale below the floor.
check "localization_coverage/untranslated_key" \
    "./scripts/check_localization_coverage.sh" \
    "Emuqu/Localizable.xcstrings" \
    "import json,pathlib;p=pathlib.Path('Emuqu/Localizable.xcstrings');d=json.loads(p.read_text());d['strings']['planted.untranslated.key']={'extractionState':'manual','localizations':{}};p.write_text(json.dumps(d,indent=2,ensure_ascii=False))"

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
    "import pathlib;p=pathlib.Path('.ci/scoring_constants_hash.txt');v=p.read_text().split()[0];p.write_text(v+' 0000000000000000'+chr(10))"

# A single planted `unowned let` anywhere in app source must go red.
check "no_unowned/planted_reference" \
    "./scripts/check_no_unowned.sh" \
    "Emuqu/Sources/Collection/CollectorSessionControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl.swift');p.write_text(p.read_text()+chr(10)+'final class PlantedUnowned { unowned let collector: RRCollector; init(collector: RRCollector) { self.collector = collector } }'+chr(10))"

# Putting a heart-rate readiness wait back in front of the feed's subscribe
# restores the stall that cost a night of sleep. The gate must go red on it.
check "hr_feed/readiness_wait" \
    "./scripts/check_hr_feed_subscribes_on_link.sh" \
    "Emuqu/Sources/Collection/StrapHeartRateFeed.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapHeartRateFeed.swift');s=p.read_text();o='        var failures = 0\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = await manager?.link.awaitFeature(.heartRate, until: nil)\n'+o))"

# Dropping `@Sendable` from the pedometer handler restores the exact code that
# trapped in the field. The gate must go red on it.
check "coremotion_isolation/inherited_actor" \
    "./scripts/check_coremotion_handler_isolation.sh" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='{ @Sendable [weak self] data, error in';assert s.count(o)==1;p.write_text(s.replace(o,'{ [weak self] data, error in'))"

# A planted rights notice in any source file must go red.
check "license_headers/planted_notice" \
    "./scripts/check_no_license_headers.sh" \
    "Emuqu/Sources/Utilities/Constants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Constants.swift');p.write_text('// Copyright. All rights reserved.\\n'+p.read_text())"

# The logger may not call itself: one planted `attempt(` in DebugLog.swift must go red.
check "logger_self_reference/planted_attempt" \
    "./scripts/check_logger_self_reference.sh" \
    "Emuqu/Sources/Utilities/DebugLog.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');p.write_text(p.read_text()+'\\nprivate func plantedGateCheck() { _ = attempt(\"planted\") { try FileManager.default.removeItem(atPath: \"/nope\") } }\\n')"

# Dated-comment ratchet: the budget is zero, so one planted dated comment must go red.
check "dated_comment_budget/planted_date" \
    "./scripts/check_dated_comment_budget.sh" \
    "Emuqu/Sources/Utilities/Constants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Constants.swift');p.write_text(p.read_text()+chr(10)+'// 2026-01-01 — planted changelog comment'+chr(10))"


# A single `.shared` read outside the composition root must go red.
check "no_shared_outside_root/planted_read" \
    "./scripts/check_no_shared_outside_root.sh" \
    "Emuqu/Sources/Collection/CollectorSessionControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl.swift');p.write_text(p.read_text()+chr(10)+'private let plantedRead = SettingsManager.shared'+chr(10))"

echo
echo "  $PASS proven, $FAIL not protecting anything, $SKIP skipped"
echo
echo "  Not covered here — these three need a build or a simulator, so they are"
echo "  verified by their own runs: check_coverage.sh (coverage floors),"
echo "  check_thread_sanitizer.sh, and"
echo "  check_uitest_fresh_install.sh. Every other gate in scripts/ has a plant"
echo "  above. If you add a gate, add its plant in the same commit."

# ---------------------------------------------------------------------------
# The meta-check: a gate with no plant here.
#
# A gate can be added, wired into `ci.yml`, and trusted without anyone ever
# watching it fail — and some of those turn out to be measuring nothing.
# Counting on the next person to remember is what produces such a list, so the
# harness refuses to report success while a gate it does not cover exists.
# Adding a gate and adding its plant are one change.
#
# The four exemptions need a build or a simulator, which this file deliberately
# does not do — they are verified by their own CI runs instead.
# ---------------------------------------------------------------------------
NEEDS_BUILD=(
    check_coverage.sh
    check_thread_sanitizer.sh
    check_uitest_fresh_install.sh
)

unplanted=()
for gate in scripts/check_*.sh scripts/enforce_*.sh; do
    base="$(basename "$gate")"
    # This file, and the preflight library's own self-test, are not gates.
    [[ "$base" == "check_gate_preflight.sh" ]] && continue
    exempt=false
    for e in "${NEEDS_BUILD[@]}"; do
        [[ "$base" == "$e" ]] && exempt=true && break
    done
    $exempt && continue
    grep -q "$base" "$0" || unplanted+=("$base")
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
