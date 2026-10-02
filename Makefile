SHELL := /bin/bash

SCHEME ?= Emuqu
PROJECT ?= Emuqu.xcodeproj

.PHONY: release-build shared-root-guard dated-comment-budget no-unowned-guard logger-self-reference-guard license-header-guard clean-build date-ms-guard doc-counts-guard empty-range-guard leaked-mutations-guard eager-prompt-guard gates-wired-guard snapshot-refs-guard ci-local ci-local-unit verify-gates gate-preflight sbom sbom-check no-phone-home strict-concurrency-enabled localization-orphan-guard aggregate-type-size comment-citations perimeter-sync spec-conformance locale-format-guard lint lint-budget format test test-coverage debt-budget infoplist-guard sendable-guard sbom-guard log-redaction-guard localization-guard localization-bundle-guard localization-resolution-guard localization-orphan-guard localization-format-guard uitest-reset-guard skip-budget budget-monotonicity orphan-swift-guard fixed-font-budget thread-sanitizer copy-perimeter doc-links ci setup-hooks

lint:
	@swiftlint lint --config .swiftlint.yml

lint-budget:
	@./scripts/enforce_swiftlint_budget.sh

format:
	@swiftformat Emuqu EmuquTests --config .swiftformat

test:
	@DEST="$$(./scripts/select_simulator_destination.sh $(SCHEME) $(PROJECT))"; \
	echo "Using destination: $$DEST"; \
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination "$$DEST"

test-coverage:
	@./scripts/run_tests_with_coverage.sh

debt-budget:
	@./scripts/enforce_tech_debt_budgets.sh

infoplist-guard:
	@./scripts/check_no_health_data_in_cloudkit.sh
	@./scripts/check_privacy_manifest_vocabulary.sh
	@./scripts/check_infoplist_key_drift.sh

# `.shared` is read only in the composition root (2026-09-03).
shared-root-guard:
	@./scripts/check_no_shared_outside_root.sh

# Dated changelog comments — ratchets down (2026-09-03).
dated-comment-budget:
	@./scripts/check_dated_comment_budget.sh

# No `unowned` back-references — the class of crash removed on 2026-09-03.
no-unowned-guard:
	@./scripts/check_no_unowned.sh

logger-self-reference-guard:
	@./scripts/check_logger_self_reference.sh

license-header-guard:
	@./scripts/check_no_license_headers.sh

sendable-guard:
	@./scripts/check_unchecked_sendable.sh

# The in-app acknowledgements list is hand-maintained and
# had already drifted once. This pins it to Package.resolved.
spec-conformance:
	@./scripts/check_refactor_spec_conformance.sh

locale-format-guard:
	@./scripts/check_locale_formatting.sh

doc-counts-guard:
	./scripts/check_doc_file_counts.sh

date-ms-guard:
	./scripts/check_date_ms_conversion.sh

empty-range-guard:
	./scripts/check_empty_range_loops.sh

# The backstop for a killed `verify_tests_fail.sh` run leaving production source
# mutated. See the script's header for the pNN50 leak it exists to catch.
leaked-mutations-guard:
	@./scripts/check_no_leaked_mutations.sh

# CBCentralManager / CBPeripheralManager prompt on CONSTRUCTION.
eager-prompt-guard:
	@./scripts/check_no_eager_permission_prompts.sh

# A gate CI never runs is a gate that does not exist.
gates-wired-guard:
	@./scripts/check_gates_wired.sh

snapshot-refs-guard:
	./scripts/check_snapshot_references.sh

sbom-guard:
	@./scripts/check_sbom_drift.sh

# Enforces the refactor spec's "never log sensitive user
# data", which was the only principle in that doc with no gate behind it.
log-redaction-guard:
	@./scripts/check_log_redaction.sh

# The app ships 17 locales and every non-English one sat at
# 51.8% translated, with nothing measuring it. Same ratchet shape as the other
# budgets: the floor lives in .ci/min_localization_coverage.txt.
localization-guard:
	@./scripts/check_localization_coverage.sh
	@./scripts/check_localization_coverage.sh Emuqu/InfoPlist.xcstrings
	@./scripts/check_localization_coverage.sh "EmuquWatch Watch App/InfoPlist.xcstrings"
	@./scripts/check_localization_coverage.sh Emuqu/Help.xcstrings

# Coverage measures whether a translation exists. This measures whether the
# lookup can actually reach it — a `String(localized:)` without `bundle:` reads
# from Bundle.main and silently ignores the in-app language picker.
localization-bundle-guard:
	@./scripts/check_localization_bundle.sh

# Coverage asks "is every catalogue key translated?" and answered 100%. Bundle
# asks "will this lookup read the right bundle?" and answered "all qualified".
# Neither asks whether the key the code requests EXISTS. Editing a localized
# literal changes the key, orphaning its translations silently — which is how a
# medical-claim string shipped in English to all 16 locales while both gates
# stayed green.
localization-resolution-guard:
	@./scripts/check_localization_resolution.sh

# A UI suite that launches without `-UITests-FreshInstall` inherits the previous
# test's onboarding and scroll state and starts asserting about the wrong
# screen. Thirteen suites were migrated onto the shared launch harness in one
# pass and the fourteenth was missed, which turned seven tests red.
uitest-reset-guard:
	@./scripts/check_uitest_fresh_install.sh

# A skipped test passes without asserting. This repo has already had a stale
# selector silently turn a whole class into skips.
skip-budget:
	@./scripts/check_test_skip_budget.sh

# Every debt budget sits at its measured value, and every gate is `count >
# budget`. Without this, the cheapest way to go green is to edit the budget.
# 2026-08-26 — pass an explicit baseline. With no argument and no
# GITHUB_BASE_REF/BUDGET_BASE_REF the script prints "no PR baseline … Skipping"
# and exits 0, which is exactly how `make ci` invoked it: locally, raising
# .ci/try_optional_budget.txt from 377 to 999 passed. `HEAD` catches the case
# the developer is actually in — an uncommitted budget edit in the working
# tree. CI still overrides with `github.event.before`.
budget-monotonicity:
	@./scripts/check_budget_monotonicity.sh $${BUDGET_BASE_REF:-HEAD}

# `.font(.system(size:))` ignores the user's text-size setting. `scaledFont`
# is the migration target; this stops the holdouts growing back.
fixed-font-budget:
	@./scripts/check_fixed_font_budget.sh

# Swift 6 migration, measured. Runs a full build — minutes, not seconds — so it
# is deliberately not part of `ci`; CI runs it as its own job.
strict-concurrency-enabled:
	@./scripts/check_strict_concurrency_enabled.sh

# Data races, detected at runtime. The only evidence that can exist for the 30
# unchecked-Sendable escapes while the project is still in Swift 5 mode.
# Slow — its own CI job, not part of `ci`.
thread-sanitizer:
	@./scripts/check_thread_sanitizer.sh

# A split that writes to an existing path destroys that file's contents; a
# split that forgets to register the new file leaves it out of the build.
# Both are silent. This catches the second directly and the first by proxy.
orphan-swift-guard:
	@./scripts/check_no_orphan_swift.sh

copy-perimeter:
	@python3 Tools/copy_linter/lint.py

# Ten broken relative links and four documentation
# constants that contradicted the .ci/ values they described. Both classes
# were written accurately and went stale, so they are now enforced.
doc-links:
	@./scripts/check_doc_links.sh

# The app has no server and no analytics. This is what keeps that true.
no-phone-home:
	@./scripts/check_no_developer_endpoint.sh

# SPDX bill of materials, generated from Package.resolved. `sbom` rewrites it;
# `sbom-check` fails if the committed copy has gone stale.
# A gate that reports clean without measuring is worse than no gate. F-05.
gate-preflight:
	@./scripts/check_gate_preflight.sh

# Plants a real violation for each gate and requires a non-zero exit.
# A gate nobody has watched fail is not protecting anything.
verify-gates:
	@./scripts/verify_gates_fail.sh

sbom:
	@python3 scripts/generate_sbom.py

sbom-check:
	@python3 scripts/generate_sbom.py --check

# 2026-08-26 — the build-time perimeter and the two runtime guards had three
# separate term lists and nothing reconciled them, so `atrial fibrillation`,
# `diagnose`, `pathology`, `cure`, `prescription`, `FDA-cleared` and five more
# were forbidden in static copy and unhandled in model output. This proves the
# runtime lexicon still covers every build-time term.
perimeter-sync:
	@./scripts/check_perimeter_sync.sh

# 2026-09-02 — the copy linter matches phrasings, so a claim can outrun it by
# rephrasing. The register classifies every operative heuristic by validation
# status; this keeps it complete and its cited tests real.
science-register:
	@./scripts/check_science_register.sh

# 2026-09-02 — rankingWeight must not surface as a confidence, and a change to
# any scoring constant must be accompanied by a scoring-version bump.
scoring-governance:
	@./scripts/check_scoring_governance.sh

# 2026-08-26 — eight of nine `File.swift:NNN` citations in comments pointed past
# the end of the file they named, all broken by the same splitting refactor.
# A line number in a cross-file citation is on a timer in this repo.
comment-citations:
	@./scripts/check_comment_citations.sh

# 2026-08-26 — `.ci/large_swift_files_1500_budget.txt` is 0 and no FILE exceeds
# 1500 lines, while RRCollector is 6,691 lines across 23 files. A per-file limit
# cannot see a type that was split rather than reduced. Budget starts at the
# measured 19 and ratchets down, same as every other budget here.
aggregate-type-size:
	@./scripts/check_aggregate_type_size.sh

# 2026-08-26 — three localization gates measured catalogue->locale,
# lookup->bundle and code->catalogue, and all three read 100%. Nothing measured
# catalogue->code, which is the direction an orphan runs in: edit a literal and
# the old key stays behind, translated into sixteen locales, requested by
# nothing.
localization-orphan-guard:
	@./scripts/check_localization_orphans.sh

# The four gates above measure whether a translation exists and is reachable.
# This one measures whether it can be formatted: a translation that reorders
# %@ and %lld without numbering them reads an integer as an object and crashes.
localization-format-guard:
	@./scripts/check_localization_format_args.sh

# 2026-08-26 — `localization-orphan-guard` added. It existed as a target, was
# in `.PHONY`, and ran as its own job in ci.yml, but was left out of this list:
# the fourth localization gate was the one a developer running `make ci` never
# saw. Exactly the ci.yml/Makefile divergence the note below is about.
#
# 2026-08-25 — `orphan-swift-guard` and `localization-resolution-guard` added,
# and `test-coverage` moved off the end.
#
# `orphan-swift-guard` was in ci.yml but not here, so the guard against a new
# file never reaching the build — the exact failure mode a splitting refactor
# produces — was missing from the composite a developer actually runs.
#
# The ordering matters more than it looks. Make stops at the first failing
# target, and `copy-perimeter` sat second-to-last: one red copy gate and the
# whole test suite never ran locally, while ci.yml (separate jobs) ran it
# anyway. The two pipelines disagreed about what "ci passed" meant. Static
# gates are seconds; tests are forty minutes. Fail fast on the cheap ones,
# then run the expensive one.
# Run what CI runs, locally, before paying for a 10x macOS runner. Parses
# .github/workflows/ci.yml rather than keeping its own list, so it cannot drift.
# The configuration that gets archived. Debug builds and the test suite never
# run the optimizer, and some diagnostics only it raises.
release-build:
	@mkdir -p build
	@xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath build/release \
		CODE_SIGNING_ALLOWED=NO > build/release-build.log 2>&1 \
		|| { grep -E 'error:' build/release-build.log | sort -u; echo "release-build: FAILED (full log: build/release-build.log)"; exit 1; }
	@echo "release-build: OK"

ci-local:
	./scripts/simulate_ci.sh

ci-local-unit:
	./scripts/simulate_ci.sh --scope unit

ci: lint lint-budget debt-budget budget-monotonicity infoplist-guard sendable-guard no-unowned-guard logger-self-reference-guard license-header-guard dated-comment-budget shared-root-guard spec-conformance locale-format-guard sbom-guard snapshot-refs-guard empty-range-guard leaked-mutations-guard eager-prompt-guard gates-wired-guard date-ms-guard doc-counts-guard log-redaction-guard localization-guard localization-bundle-guard localization-resolution-guard localization-orphan-guard localization-format-guard uitest-reset-guard skip-budget fixed-font-budget orphan-swift-guard copy-perimeter perimeter-sync science-register scoring-governance comment-citations aggregate-type-size doc-links strict-concurrency-enabled no-phone-home sbom-check gate-preflight verify-gates test-coverage

# Every gate that builds the app writes its derived data under build/ in its
# own directory (coverage, Thread Sanitizer, strict concurrency, mutation
# runs, the clean-room verify). The cache is what makes a second run take
# seconds instead of five minutes, so this keeps anything used in the last
# two weeks and removes the rest. A dozen stale copies reach 30 GB.
clean-build:
	@stale=$$(find build -mindepth 1 -maxdepth 1 -type d -mtime +14 2>/dev/null); \
	if [ -z "$$stale" ]; then echo "clean-build: nothing under build/ is older than 14 days"; \
	else du -sh $$stale; rm -rf $$stale; echo "clean-build: removed the directories above"; fi

setup-hooks:
	@./scripts/install-git-hooks.sh
