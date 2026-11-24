SHELL := /bin/bash

SCHEME ?= Emuqu
PROJECT ?= Emuqu.xcodeproj

# XCODEBUILD_PINNED: the flag that holds every xcodebuild run to the committed
# Package.resolved. Defined once, in scripts/lib/xcodebuild.sh.
include scripts/lib/xcodebuild.sh

.PHONY: release-build coremotion-isolation-guard hr-feed-link-guard science-register scoring-governance shared-root-guard explicit-deps-guard dated-comment-budget no-unowned-guard logger-self-reference-guard license-header-guard clean-build date-ms-guard doc-counts-guard empty-range-guard leaked-mutations-guard eager-prompt-guard gates-wired-guard xcodebuild-pinned-guard snapshot-refs-guard ci-local ci-local-unit verify-gates gate-preflight sbom sbom-check no-phone-home strict-concurrency-enabled localization-orphan-guard aggregate-type-size comment-citations perimeter-sync spec-conformance locale-format-guard lint lint-budget format test test-coverage debt-budget infoplist-guard sendable-guard sbom-guard log-redaction-guard localization-guard localization-bundle-guard localization-resolution-guard localization-orphan-guard localization-format-guard uitest-reset-guard skip-budget budget-monotonicity orphan-swift-guard fixed-font-budget thread-sanitizer copy-perimeter doc-links ci setup-hooks

lint:
	@swiftlint lint --config .swiftlint.yml

lint-budget:
	@./scripts/enforce_swiftlint_budget.sh

format:
	@swiftformat Emuqu EmuquTests --config .swiftformat

test:
	@DEST="$$(./scripts/select_simulator_destination.sh $(SCHEME) $(PROJECT))"; \
	echo "Using destination: $$DEST"; \
	xcodebuild test $(XCODEBUILD_PINNED) -project $(PROJECT) -scheme $(SCHEME) -destination "$$DEST"

test-coverage:
	@./scripts/run_tests_with_coverage.sh

debt-budget:
	@./scripts/enforce_tech_debt_budgets.sh

infoplist-guard:
	@./scripts/check_no_health_data_in_cloudkit.sh
	@./scripts/check_privacy_manifest_vocabulary.sh
	@./scripts/check_infoplist_key_drift.sh

# `.shared` is read only in the composition root.
shared-root-guard:
	@./scripts/check_no_shared_outside_root.sh

# Code handed its dependencies reads no container; only tests install one.
explicit-deps-guard:
	@./scripts/check_explicit_dependencies.sh

# Dated changelog comments: a budget that ratchets down.
dated-comment-budget:
	@./scripts/check_dated_comment_budget.sh

# No `unowned` back-references: a use after its owner is freed crashes.
no-unowned-guard:
	@./scripts/check_no_unowned.sh

logger-self-reference-guard:
	@./scripts/check_logger_self_reference.sh

# These two ran only as ci.yml steps, so a local `make ci` skipped them.
coremotion-isolation-guard:
	@./scripts/check_coremotion_handler_isolation.sh

hr-feed-link-guard:
	@./scripts/check_hr_feed_subscribes_on_link.sh

license-header-guard:
	@./scripts/check_no_license_headers.sh

sendable-guard:
	@./scripts/check_unchecked_sendable.sh

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

# The in-app acknowledgements list is hand-maintained and
# had already drifted once. This pins it to Package.resolved.
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
# It is given an explicit baseline: with no argument and no
# GITHUB_BASE_REF/BUDGET_BASE_REF the script skips and exits 0.
#
# The baseline is where this branch left origin/main (their merge base), so a
# raise already committed on the branch is compared, not only an uncommitted
# one, and the trailer scan covers every commit the branch adds. A budget
# lowered on origin/main since the branch point is not read as a raise here.
# A clone with no origin/main falls back to HEAD, which still sees an
# uncommitted edit, and says so. BUDGET_BASE_REF overrides both. CI passes its
# own baseline: the parent commit, the tip before a push, or a pull request's
# base.
budget-monotonicity:
	@base="$${BUDGET_BASE_REF:-}"; \
	if [ -z "$$base" ]; then \
		if base="$$(git merge-base HEAD origin/main 2>/dev/null)"; then \
			echo "budget-monotonicity: comparing with the merge base of HEAD and origin/main ($$(git rev-parse --short "$$base"))"; \
		else \
			base=HEAD; \
			echo "budget-monotonicity: no origin/main here; comparing the working tree with HEAD only (commits already made are not compared; set BUDGET_BASE_REF to choose a baseline)"; \
		fi; \
	fi; \
	./scripts/check_budget_monotonicity.sh "$$base"

# `.font(.system(size:))` ignores the user's text-size setting. `scaledFont`
# is the migration target; this stops the holdouts growing back.
fixed-font-budget:
	@./scripts/check_fixed_font_budget.sh

# Every build configuration stays in Swift 6 language mode with complete
# strict concurrency. A grep of the project file, no build: seconds.
strict-concurrency-enabled:
	@./scripts/check_strict_concurrency_enabled.sh

# Data races, detected at runtime. The compiler cannot check the
# `@unchecked Sendable` escapes; this is the evidence for them.
# Slow — an instrumented build and run, so `ci` runs it after the static gates.
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

# Every xcodebuild run that loads the project builds against the committed
# Package.resolved, never a fresh resolution.
xcodebuild-pinned-guard:
	@./scripts/check_xcodebuild_pinned.sh

# Each gate fails closed when its input is missing.
# A gate that reports clean without measuring is worse than no gate.
gate-preflight:
	@./scripts/check_gate_preflight.sh

# Plants a real violation for each gate and requires a non-zero exit.
# A gate nobody has watched fail is not protecting anything.
verify-gates:
	@./scripts/verify_gates_fail.sh

# SPDX bill of materials, generated from Package.resolved. `sbom` rewrites it;
# `sbom-check` fails if the committed copy has gone stale.
sbom:
	@python3 scripts/generate_sbom.py

sbom-check:
	@python3 scripts/generate_sbom.py --check

# The build-time perimeter and the two runtime guards keep separate term
# lists. This proves the runtime lexicon still covers every build-time term,
# so nothing forbidden in static copy goes unhandled in model output.
perimeter-sync:
	@./scripts/check_perimeter_sync.sh

# The copy linter matches phrasings, so a claim can outrun it by
# rephrasing. The register classifies every operative heuristic by validation
# status; this keeps it complete and its cited tests real.
science-register:
	@./scripts/check_science_register.sh

# rankingWeight must not surface as a confidence, and a change to
# any scoring constant must be accompanied by a scoring-version bump.
scoring-governance:
	@./scripts/check_scoring_governance.sh

# A `File.swift:NNN` citation in a comment breaks silently when the file is
# split or edited. This checks that each one still points inside the file.
comment-citations:
	@./scripts/check_comment_citations.sh

# A per-FILE length limit (`.ci/large_swift_files_1500_budget.txt`) cannot see
# a type that was split across files rather than reduced; RRCollector, spread
# over its extension files, was the case that showed it. This gate sums each
# type's lines across all its files and prints the current figures. Its budgets
# ratchet down, same as every other budget here.
aggregate-type-size:
	@./scripts/check_aggregate_type_size.sh

# The other localization gates measure catalogue->locale, lookup->bundle and
# code->catalogue. This one measures catalogue->code, the direction an orphan
# runs in: edit a literal and the old key stays behind, translated into sixteen
# locales, requested by nothing.
localization-orphan-guard:
	@./scripts/check_localization_orphans.sh

# The four gates above measure whether a translation exists and is reachable.
# This one measures whether it can be formatted: a translation that reorders
# %@ and %lld without numbering them reads an integer as an object and crashes.
localization-format-guard:
	@./scripts/check_localization_format_args.sh

# The configuration that gets archived. Debug builds and the test suite never
# run the optimizer, and some diagnostics only it raises.
release-build:
	@mkdir -p build
	@xcodebuild build $(XCODEBUILD_PINNED) -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath build/release \
		CODE_SIGNING_ALLOWED=NO > build/release-build.log 2>&1 \
		|| { grep -E 'error:' build/release-build.log | sort -u; echo "release-build: FAILED (full log: build/release-build.log)"; exit 1; }
	@echo "release-build: OK"

# Run what CI runs, locally, before paying for a 10x macOS runner. Parses
# .github/workflows/ci.yml rather than keeping its own list, so it cannot drift.
ci-local:
	./scripts/simulate_ci.sh

ci-local-unit:
	./scripts/simulate_ci.sh --scope unit

# Every gate a developer runs, and the same set ci.yml runs. A gate missing
# from this list is one nobody sees fail locally, which has happened twice
# (`localization-orphan-guard`, `orphan-swift-guard`). That includes the two
# builds ci.yml runs besides the tests: the Release configuration and the
# unit suite under Thread Sanitizer.
#
# Order matters. Make stops at the first failing target, so the static gates
# (seconds) come first, then the Release build, then Thread Sanitizer, and the
# test suite (the slow part) last.
ci: lint lint-budget debt-budget budget-monotonicity infoplist-guard sendable-guard no-unowned-guard logger-self-reference-guard coremotion-isolation-guard hr-feed-link-guard license-header-guard dated-comment-budget shared-root-guard explicit-deps-guard spec-conformance locale-format-guard sbom-guard snapshot-refs-guard empty-range-guard leaked-mutations-guard eager-prompt-guard gates-wired-guard date-ms-guard doc-counts-guard log-redaction-guard localization-guard localization-bundle-guard localization-resolution-guard localization-orphan-guard localization-format-guard uitest-reset-guard skip-budget fixed-font-budget orphan-swift-guard copy-perimeter perimeter-sync science-register scoring-governance comment-citations aggregate-type-size doc-links strict-concurrency-enabled no-phone-home xcodebuild-pinned-guard sbom-check gate-preflight verify-gates release-build thread-sanitizer test-coverage

# Every gate that builds the app writes its derived data under build/ in its
# own directory (coverage, Thread Sanitizer, mutation runs, the clean-room
# verify). The cache is what makes a second run take
# seconds instead of five minutes, so this keeps anything used in the last
# two weeks and removes the rest. A dozen stale copies reach 30 GB.
clean-build:
	@stale=$$(find build -mindepth 1 -maxdepth 1 -type d -mtime +14 2>/dev/null); \
	if [ -z "$$stale" ]; then echo "clean-build: nothing under build/ is older than 14 days"; \
	else du -sh $$stale; rm -rf $$stale; echo "clean-build: removed the directories above"; fi

setup-hooks:
	@./scripts/install-git-hooks.sh
