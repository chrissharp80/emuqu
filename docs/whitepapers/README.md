# Emuqu technical white papers

Five technical white papers by Chris Sharp. Papers 1 to 4 (v1.4) describe the methods in Emuqu (formerly Flow HRV, then Flow Recovery) at source revision `44a11ce` (2026-11-21), scoring version `v3.3.nov2026`. Paper 5 describes the design method used to build it. Where a paper and the code disagree, the code is authoritative. Emuqu is a consumer wellness app, not a medical device.

| # | Paper | Covers |
|---|---|---|
| 1 | [Overnight Recovery Measurement from Raw Beat Intervals](01-overnight-recovery-measurement.md) ([PDF](01-overnight-recovery-measurement.pdf)) | Source selection and gap filling, artifact handling, sleep-anchored and score-ranked window selection, anti-ratchet baseline, frozen and versioned scores, beat-interval-only sleep staging |
| 2 | [Real-Time DFA α1 and Dropout-Robust Training Load](02-exercise-hrv-and-training-load.md) ([PDF](02-exercise-hrv-and-training-load.pdf)) | Gated live DFA α1, ectopic-shadow and sustained-crossing logic, route-matched load substitution, training-load ladder, readiness model, phone/Watch strap merge |
| 3 | [A Measurement-Grounded Assistant with a Multilingual Regulated-Claim Perimeter](03-grounded-health-assistant.md) ([PDF](03-grounded-health-assistant.pdf)) | Typed fact catalog, absence taxonomy, runtime number verification and correction loop, 17-language regulated-claim perimeter at input, output and build time |
| 4 | [Build-Time Governance of a Consumer Physiology Score](04-claims-governance.md) ([PDF](04-claims-governance.pdf)) | Constants-hash version lock, machine-checked science register, gates that must prove they fail, one-way budget ratchets |
| 5 | [Blind-Audit Convergence: A Method for Directing AI to Produce Converged Software Designs](05-blind-audit-convergence-method.md) ([PDF](05-blind-audit-convergence-method.pdf)) | Creator and memory-blind auditors, do-not-flag list carried in the document, adjudication against one goal, convergence by the character of findings, stack choice and graded code audit after convergence |

Each paper's "What Is New" section lists the methods it discloses, with the earliest dated record of each; its "Provenance and Dates" section gives the repository lineage, public disclosures and authorship. The cross-implementation scripts for the measurement methods are in [`Tools/validation/`](../../Tools/validation/).

Earlier versions were all published 2026-10-08: v1.0; v1.1 (prior-art comparison and provenance); v1.2 (method-first restructure); v1.3 of Papers 1–4 and v1.1 of Paper 5 (editorial review: series-wide format, corrected internal references, tightened claims). Published 2026-11-22: v1.4 of Papers 1 to 4, which brings them up to source revision `44a11ce` and scoring version `v3.3.nov2026`.
