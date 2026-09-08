<!-- Emuqu does not accept outside pull requests (see CONTRIBUTING.md).
     This template is for the maintainer's own branches. -->

## What changed

<!-- One paragraph. What does this do, and why now? -->

## Why this is safe

<!-- Behaviour preserved, or behaviour deliberately changed? If a refactor
     changed no behaviour, say what proves that — a parity test, an unchanged
     golden output, a pinned prompt. -->

## Verification

- [ ] `make ci` passes end to end (exit status checked, not just the last line)
- [ ] Built and ran the affected flow on a simulator or device
- [ ] New or changed logic has a test that fails without the change

## Gates

- [ ] No new `swiftlint:disable`, and no gate waived
- [ ] Any budget I lowered is lowered in `.ci/` in this same change
- [ ] Any budget I raised has a written reason and a repayment plan below
- [ ] New Swift files are registered in `project.pbxproj` at all four points

## Surface changes

- [ ] No new user-facing string, **or** every new string is localized and
      bundle-qualified and `make localization-guard` passes
- [ ] No change to what leaves the device, **or** the consent sheet,
      `PrivacyInfo.xcprivacy`, the privacy policy, and the App Store Connect
      answers were all updated together
- [ ] No new health claim, **or** `make copy-perimeter` passes and the wording
      describes an observation rather than a diagnosis

## Notes for the next reader

<!-- Anything that surprised you, anything you nearly got wrong, anything you
     deliberately left undone. This is the only review record this project
     gets — a note here is worth more than a tidy diff. -->
