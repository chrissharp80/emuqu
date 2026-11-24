# Working in this repository

**Build and test what you change before you push.** CI on a pull request is the second check, not the
first. `make test` runs the suites; `make ci-local` runs every script gate the workflows run in about two
minutes. Warnings are errors, and a change has to build with the Xcode CI pins (`.github/workflows/ci.yml`)
as well as any newer one.

**Scores are versioned.** The constants that decide a score are hashed
(`scripts/check_scoring_governance.sh`). A change to one needs a new `ScoringVersion.current`, a new hash
in `.ci/scoring_constants_hash.txt` and an entry in the science register. Nights already scored keep the
version they were scored with; never rescore history.

**Health data stays on the device unless it is sealed.** CloudKit uploads go through
`CloudPayloadCodec.sealForUpload`, and logs never carry what the user said, typed or where they were
(`scripts/check_log_redaction.sh`).

**Every user-facing string is in every language.** Add it to the string catalogue for all locales and run
`make localization-guard`.

**Dependencies are passed in.** Services are built in the composition root (`AppDependencies`) and handed
to what uses them; new code takes them as parameters rather than reading `AppDependencies.current`.

Architecture decisions and the reasons for them are in `docs/adr/`.
