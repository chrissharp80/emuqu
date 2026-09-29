# Runbook: Hotfix Deployment

**When this fires.** A shipped build has a P0 bug — crash in a hot path,
data loss, or a clinical-language regression that needs to come out of
the wild fast. The TestFlight beta loop is too slow.

**Your goal.** Cut a new build, get it into App Store Review with the
"expedited" flag, ship to production within 24–48 hours.

## 1. Confirm the bug is actually P0

Don't expedite for cosmetic regressions. Apple grants ~3 expedited
reviews per year before they start asking pointed questions. The bar:

- Crash that affects > ~5% of sessions, OR
- Data loss / corruption (HRV samples lost, archive entries broken), OR
- Clinical-language regression (an AI message that crosses the wellness
  boundary), OR
- Privacy bug (data leaked to a third party that shouldn't have it).

Anything else: ship the fix in the next normal release.

## 2. Create the hotfix branch

```
git checkout main
git pull
git checkout -b hotfix/<short-description>
```

Don't branch from a tag — `main` carries fixes a tag may not.

## 3. Land the smallest possible change

One commit, one concern. If the fix needs > 50 lines of changes you
probably haven't isolated the bug yet. Stop and re-diagnose.

Add a regression test in the same commit. The test should fail without
the fix and pass with it. Without a test, the bug is one refactor away
from coming back.

## 4. Run the verification checklist

- `make ci` — must pass entirely (lint + budget + infoplist-guard +
  sendable-guard + test-coverage). Coverage floors and every debt ceiling
  are read from `.ci/*.txt` at runtime; check the current values with
  `head -n1 .ci/*.txt` rather than trusting a number written here, because
  every one of them ratchets. The budget gate reads the ratchet files in
  `.ci/` — notably `shared_usage_budget.txt` and
  `legacy_observable_object_budget.txt`, which ratchets
  `ObservableObject` conformances toward zero (new types must be
  `@Observable`). A hotfix that adds a `.shared` or a legacy
  `ObservableObject` will fail CI unless it also lowers/holds the budget.
- Build for Release config: `xcodebuild -project Emuqu.xcodeproj
  -scheme Emuqu -configuration Release -destination
  'generic/platform=iOS Simulator' build`
- Cold-start measurement on a physical device (use the
  `os_signpost("init.*")` events from `EmuquApp.swift` in
  Instruments → Logging template). Compare to the prior shipping build.
  > 10% regression → stop and investigate.
- Sanity-walk every flow listed in [`docs/REVIEW.md`](../REVIEW.md).

## 5. Bump versions

```bash
# Marketing (patch bump) — still manual:
# Edit Emuqu.xcodeproj/project.pbxproj — MARKETING_VERSION = X.Y.(Z+1)
# (all 10 sites).

# Build number — automatic in CI:
#   .github/workflows/testflight.yml archives with
#   CURRENT_PROJECT_VERSION="${{ github.run_number }}.${{ github.run_attempt }}",
#   so re-uploads can never collide on a duplicate
#   (MARKETING_VERSION, CURRENT_PROJECT_VERSION) pair.
#
# If you're cutting an archive locally instead of via CI, raise
# CURRENT_PROJECT_VERSION past the last upload at every site, the same way
# as MARKETING_VERSION above. (agvtool is not an option: it needs
# VERSIONING_SYSTEM = apple-generic, which this project does not set.)
```

Do this in a single commit so the diff is grep-able later.

## 6. Cut the archive

In Xcode: Product → Archive (Release config, Any iOS Device). After
the archive completes, Distribute App → App Store Connect → Upload.

Wait for App Store Connect to email you that processing finished
(usually 5–15 min).

## 7. Create the App Store submission

App Store Connect → My Apps → Emuqu → + Version → enter the
new version number. Attach the build. Fill out "What's New" with a
*specific* description of the fix:

> Fixed a crash that could occur when the recovery score band
> calculation received an empty input set. No data is lost.

Vague "bug fixes" notes ("various improvements") trigger longer review.

## 8. Request expedited review

Resolution Center → Contact Us → Expedited App Review. Cite the
P0 reason explicitly. They approve / deny within 1 business day.

## 9. Once approved

The build goes to "Pending Developer Release" by default. Release
manually from App Store Connect after a 1-hour soak in production
(staged rollout — use the App Store's phased release feature unless
the bug is severe enough that delaying the rollout for non-affected
users isn't worth it).

## 10. Post-mortem

Write a 1-page note in `docs/runbooks/incidents/YYYY-MM-DD-<short>.md`
covering: what broke, how it was detected, why CI didn't catch it,
what changed in the test suite to catch it next time. The post-mortem
is the deliverable, not the fix.

## Hard "do not" list

- Don't push directly to `main` without going through the branch + CI
  flow, even under pressure.
- Don't skip the regression test "to save time."
- Don't ship without a Release-config archive (Debug builds have
  different optimization passes and have shipped subtle bugs in the
  past).
- Don't bypass `make ci` (`--no-verify` on the commit) without a
  written reason in the commit message.
- Don't expedite-review for non-P0 bugs.
