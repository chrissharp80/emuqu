# Emuqu technical white papers

Four technical white papers describing the methods in Emuqu, by Chris Sharp. Each one
describes the source code at revision `e028039` (2026-10-07), scoring version
`v3.1.oct2026`. Where these papers and the code disagree, the code is authoritative.

| # | Paper | Covers |
|---|---|---|
| 1 | [Overnight Recovery Measurement from Raw Beat Intervals](01-overnight-recovery-measurement.md) ([PDF](01-overnight-recovery-measurement.pdf)) | Source selection and gap filling, artifact handling, sleep-anchored and score-ranked window selection, anti-ratchet baseline, frozen and versioned scores, beat-interval-only sleep staging |
| 2 | [Real-Time DFA α1 and Dropout-Robust Training Load](02-exercise-hrv-and-training-load.md) ([PDF](02-exercise-hrv-and-training-load.pdf)) | Gated live DFA α1, ectopic-shadow and sustained-crossing logic, route-matched load substitution, training-load ladder, readiness model, phone/Watch strap merge |
| 3 | [A Measurement-Grounded Assistant with a Multilingual Regulated-Claim Perimeter](03-grounded-health-assistant.md) ([PDF](03-grounded-health-assistant.pdf)) | Typed fact catalogue, absence taxonomy, runtime number verification and correction loop, 17-language medical perimeter at input, output and build time |
| 4 | [Enforced Scientific Honesty: Build-Time Governance of a Consumer Physiology Score](04-claims-governance.md) ([PDF](04-claims-governance.pdf)) | Constants-hash version lock, machine-checked science register, gates that must prove they fail, one-way budget ratchets |

Published 2026-10-08 (v1.0); revised 2026-10-08 (v1.1: prior-art comparison, independent PhysioNet validation, full provenance). Each paper's section 4 ("What Is New") lists the specific novel
methods, and section 7 gives provenance and dates.
