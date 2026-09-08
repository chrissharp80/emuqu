# Scripts

Utility scripts for the Emuqu project.

## Quality / CI scripts

### `select_simulator_destination.sh`

Selects the first usable iOS Simulator destination for the `Emuqu` scheme.

```bash
./scripts/select_simulator_destination.sh
```

### `run_tests_with_coverage.sh`

Runs tests with code coverage enabled and evaluates the coverage gate.

Environment variables:

- `SCHEME` (default: `Emuqu`)
- `PROJECT` (default: `Emuqu.xcodeproj`)
- `RESULT_BUNDLE` (default: `build/TestResults.xcresult`)
- `MIN_COVERAGE` (optional override; normally **unset** so the committed floors
  in `.ci/min_coverage.txt` and `.ci/min_coverage_logic.txt` are the single
  source of truth)
- `DESTINATION` (optional override, e.g. `id=<sim-id>`)
- `MAX_TEST_WORKERS` (default: `3` — above three simulator clones this machine
  loses one per run to an `xctrunner` preflight failure)

```bash
./scripts/run_tests_with_coverage.sh
```

### `check_coverage.sh`

Checks app line coverage from an `.xcresult` bundle and fails if below threshold.

```bash
./scripts/check_coverage.sh build/TestResults.xcresult
```

### `check_budget_monotonicity.sh`

Fails any diff that **raises** a value in `.ci/*.txt`. Every debt gate is a
`count > budget` comparison and every budget sits at its measured value, so the
cheapest way to turn CI green is to edit the number rather than pay the debt.
This is the pawl on the ratchet. A legitimate raise needs a commit trailer:

```
budget-raise-ok: .ci/<file>.txt <why this budget legitimately grew>
```

Needs history — CI checks out with `fetch-depth: 0` for this reason.

### `check_uitest_fresh_install.sh`

Every UI-test suite must launch with `-UITests-FreshInstall`. Without it a suite
inherits the previous test's onboarding and scroll state and starts asserting
about the wrong screen. Thirteen suites were migrated onto the shared
`UITestLaunch` harness in one pass; the fourteenth was missed and turned seven
tests red against the wrong screen.

### `check_test_skip_budget.sh`

Counts `XCTSkip` / `XCTSkipUnless` call sites against
`.ci/test_skip_budget.txt`. A skipped test passes without asserting anything,
and a stale selector has already turned a whole class into silent skips here
once. Ratchets toward zero.

### `check_localization_bundle.sh`

Every `String(localized:)` / `NSLocalizedString` must name
`LanguageManager.appBundle`. Without it the lookup reads from `Bundle.main` and
silently ignores the in-app language picker — the string still renders, still
looks right in English, and still counts as 100% translated in the coverage
gate, because the translation exists and is simply never read. 59 calls (mostly
VoiceOver labels) were in that state.

`check_localization_coverage.sh` measures whether a translation **exists**; this
measures whether it is **reachable**.

### `check_fixed_font_budget.sh`

Counts raw `.font(.system(size:))` in the view layer against
`.ci/fixed_font_budget.txt`. Those ignore Dynamic Type;
`View.scaledFont(size:)` is the migration target. Stands in for XCTest's
`.dynamicType` accessibility audit, which cannot see through `@ScaledMetric` and
flags correctly-scaling call sites.

### `check_strict_concurrency_enabled.sh`

Proves every build configuration is in Swift 6 language mode with
`SWIFT_STRICT_CONCURRENCY = complete` and that warnings are errors. The
compiler is the gate for isolation hazards; this only makes sure nobody
switches it off. No build, seconds on Ubuntu (ADR 006).

Runs a full build (minutes), so it is its own CI job rather than part of the
fast lint path, and is not in `make ci`.

### `check_thread_sanitizer.sh`

Runs the unit suite under Thread Sanitizer and fails on any race report.

`check_unchecked_sendable.sh` proves the count of concurrency escapes has not
grown. This is the only thing that can show any of them is actually correct,
because it tests them as executed rather than as annotated. First run
(2026-08-18): 1,444 tests, zero races.

Unit suite only — the UI suite runs the app in a separate process where TSan
would have to be injected into the runner too, at prohibitive cost for a
per-PR gate. Slow enough to be its own CI job; not in `make ci`.

### `remove_swift_file.py`

The inverse of `add_swift_file.py` — strips all four `project.pbxproj` entries
for a file (build file, file reference, group child, sources build phase).
Pass `--delete` to remove the file from disk too.

Exists because deleting a file with explicit build membership by hand is fiddly
enough that three dead protocol files were left in the tree as empty "tombstone"
comments rather than removed.

```bash
python3 scripts/remove_swift_file.py --delete Emuqu/Sources/Protocols/Dead.swift
```

### `install-git-hooks.sh`

Configures repository-local git hooks (`.githooks`).

```bash
./scripts/install-git-hooks.sh
```

## add_swift_file.py

A Python script that adds a new Swift file to the Xcode project (`Emuqu.xcodeproj`).

### Purpose

When you create a new Swift file in the project, Xcode needs to know about it. This script automates the process of adding the file to the Xcode project file (`project.pbxproj`), which involves:

1. Creating a `PBXFileReference` entry for the file
2. Creating a `PBXBuildFile` entry that references the file
3. Adding the file to the appropriate `PBXGroup` (folder in Xcode)
4. Adding the build file to the `PBXSourcesBuildPhase` so it gets compiled

### Usage

```bash
python3 scripts/add_swift_file.py <relative_path_to_swift_file>
```

### Example

```bash
# Add a new file to the Collection folder
python3 scripts/add_swift_file.py Emuqu/Sources/Collection/RRRecoveryEngine.swift

# Add a new file to the Models folder
python3 scripts/add_swift_file.py Emuqu/Sources/Models/RecoveryMetrics.swift

# Add a new file to the Views folder
python3 scripts/add_swift_file.py Emuqu/Sources/Views/RecoveryView.swift
```

### Supported Folders

The script recognizes the following folder paths:

- `Emuqu/Sources/Models`
- `Emuqu/Sources/Analysis`
- `Emuqu/Sources/Collection`
- `Emuqu/Sources/Storage`
- `Emuqu/Sources/Export`
- `Emuqu/Sources/Views`
- `Emuqu/Sources/Import`
- `Emuqu/Sources/Protocols`
- `Emuqu/Sources/Services`
- `Emuqu/Sources/ViewModels`
- `Emuqu/Sources/Utilities`

### How It Works

1. **ID Generation**: The script generates unique hexadecimal IDs that don't collide with existing IDs in the project. IDs follow Xcode's format (e.g., `A1100047001`).

2. **File Reference**: Creates a `PBXFileReference` entry that tells Xcode about the new Swift file.

3. **Build File**: Creates a `PBXBuildFile` entry that references the file and marks it for compilation.

4. **Group Assignment**: Adds the file to the appropriate `PBXGroup` based on its folder path, so it appears in the correct location in Xcode's file navigator.

5. **Build Phase**: Adds the file to the `PBXSourcesBuildPhase` so it gets compiled when you build the app.

### Notes

- The file doesn't need to exist yet when you run the script - the script will add it to the project, and you can create the file afterward.
- The script validates that the path ends with `.swift`.
- After running the script, open Xcode to verify the changes. The file should appear in the appropriate folder in the Project Navigator.
- If you get an error about not finding a group, make sure your file path matches one of the supported folders listed above.

### Troubleshooting

**Error: "Could not find group for path"**
- Make sure your file path starts with `Emuqu/Sources/` and uses one of the supported folder names.
- Check that the folder name is spelled correctly and matches exactly.

**Error: "Could not find project file"**
- Make sure you're running the script from the project root directory or using the correct path.

**File doesn't appear in Xcode after running the script**
- Try closing and reopening Xcode.
- Check that the script completed successfully with no errors.
- Verify that the `project.pbxproj` file was modified (check the file's modification timestamp).

### Safety

The script:
- Only modifies the `project.pbxproj` file
- Generates unique IDs to avoid collisions
- Does not delete or modify existing entries
- Can be safely re-run if something goes wrong (though you may want to revert the pbxproj file first)

It's recommended to commit your changes before running the script so you can easily revert if needed.
