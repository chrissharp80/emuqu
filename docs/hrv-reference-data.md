# HRV reference data

The app reports RMSSD, SDNN and pNN50, and nothing demonstrated those
numbers were right until this data set.

## What is validated, and what is not

Two questions hide inside "is the HRV accurate":

1. **Does the app compute the standard metrics correctly from a beat series?**
2. **Does a Polar H10 find beats as well as a clinical ECG?**

(2) is the sensor manufacturer's claim, established in published validation
literature. No test in this repository can reach it — the app never sees an ECG
to compare against, so any assertion about sensor accuracy would be unearned.

(1) is entirely the app's responsibility, and it is what
`EmuquTests/HRVReferenceValidationTests.swift` covers: 6,000 real RR intervals
from 20 subjects, run through the app's own analyser and compared against an
independent implementation of the Task Force (1996) time-domain definitions.

Independence is the point. Two callers of the same library agree while both
being wrong; a second implementation written from the published definitions
disagrees whenever either side is.

## Source

MIT Normal Sinus Rhythm RR Interval Database (nsr2db) v1.0.0, from PhysioNet —
24-hour Holter recordings of subjects in normal sinus rhythm, beat-annotated by
the database authors.

- Database: <https://physionet.org/content/nsr2db/1.0.0/>
- Licence: Open Data Commons Attribution License (ODC-By) v1.0,
  <https://physionet.org/content/nsr2db/view-license/1.0.0/>

ODC-By permits redistribution and derivative databases with attribution. The
committed fixtures are a derivative database; the attribution travels with them
in the generated file header and here.

> Contains information from the MIT Normal Sinus Rhythm RR Interval Database
> (nsr2db), made available under the Open Data Commons Attribution License v1.0.

Beat annotations rather than raw ECG, deliberately: the reference is *where the
beats are*, which is exactly the input the app's analyser takes. Decoding raw
ECG would be testing a beat detector the app does not have.

## Regenerating

```bash
python3 scripts/fetch_hrv_reference.py          # rewrite the fixtures
python3 scripts/fetch_hrv_reference.py --check  # verify against a fresh fetch
```

Needs network access and is never run in CI. The generated Swift file is
committed so the tests run offline. Each record carries the SHA-256 of the
annotation file it came from.

## Three things the first version of this got wrong

Worth recording, because each looked like an app defect and was not.

**SDNN divisor.** The reference used the population standard deviation and
disagreed with the app by exactly `sqrt(N/(N-1))` on every record — 19.8456
against 19.8125 on nsr001. The app was right: N-1 is what HRV software reports.
A ratio that small is easy to dismiss as floating-point noise. It was not.

**Ectopic filtering.** `computeTimeDomain` filters ectopic beats before taking
successive differences; the reference did not. On nsr005 the app reported RMSSD
16.03 against 28.98. That is the filter working — removing beats that are not
sinus rhythm — and reading it as an error would have meant "fixing" a correct,
documented design choice. The suite now compares the unfiltered reference
against `rmssd(fromCleanRRs:)`, which is the pure formula, and separately
asserts that the filtered pipeline never reports a *larger* RMSSD than the raw
one.

**Mean heart rate.** The app derives mean HR from rolling 10-second windows,
not as `60000 / meanRR`. The two differ because the mean of reciprocals is not
the reciprocal of the mean — 88.53 against 88.46 on nsr001. Jensen's
inequality, not a bug. The suite asserts they agree in scale, not exactly.
