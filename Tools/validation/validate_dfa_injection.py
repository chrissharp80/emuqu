"""Validation 3: effect of artifact handling on DFA alpha1 (ports @ e028039 of
DFAAnalyzer.compute and LiveDFAAnalyzer.cleanRRForDFA), by injecting known
artifacts into clean normal-to-normal RR windows from the MIT-BIH Normal
Sinus Rhythm Database (nsr2db 1.0.0, .ecg beat annotations, 128 Hz).

Windows: non-overlapping 120-s windows (LiveDFAAnalyzer.windowSec) in which
every beat is annotated N, every RR is 300-2000 ms, and cleanRRForDFA
corrects nothing (so the clean reference is not itself altered by the
corrector). Up to 20 windows per record, evenly spaced over the candidates.

Injection at rate p in {1, 3, 6, 10} % of the window's intervals, at random
non-adjacent positions (seeded):
  ectopic: RR_i -> 0.70*RR_i, RR_{i+1} -> RR_{i+1} + 0.30*RR_i (premature beat
           with full compensatory pause; total time preserved)
  missed:  RR_i, RR_{i+1} -> RR_i + RR_{i+1} (one beat undetected)
Conditions: "uncorrected" = DFA on the corrupted window; "app" =
cleanRRForDFA then DFA, as LiveDFAAnalyzer/WorkoutAlpha1Reanalyzer do; the
app additionally withholds alpha1 when correctedFraction > 0.06, reported
separately. Error = alpha1(condition) - alpha1(clean window). 3 seeds per
window x rate x type.
Output: results/dfa_injection_nsr2db.json
"""
import json
import os
import random
import zlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import numpy as np
import wfdb

import port_dfa
import port_live_dfa_clean as lc
from validation_common import DATA_ROOT, BEAT_SYMBOLS, bland_altman

HERE = os.path.dirname(os.path.abspath(__file__))
WIN_MS = 120000
PER_RECORD = 20
RATES = [0.01, 0.03, 0.06, 0.10]
SEEDS = 3


def candidate_windows(beats, fs):
    t = [s / fs * 1000.0 for s, _ in beats]
    out = []
    flagged = []
    i = 0
    n = len(beats)
    excluded_by_corrector = 0
    while i < n - 1:
        j = i
        while j + 1 < n and t[j + 1] - t[i] <= WIN_MS:
            j += 1
        seg = beats[i:j + 1]
        rr = [int(round((seg[k + 1][0] - seg[k][0]) / fs * 1000)) for k in range(len(seg) - 1)]
        ok = len(rr) >= 64 and all(sym == "N" for _, sym in seg) and all(300 <= r <= 2000 for r in rr) \
            and (t[j] - t[i]) >= WIN_MS - 2000
        if ok:
            if lc.clean_rr_for_dfa(rr)[1] == 0:
                out.append(rr)
            else:
                excluded_by_corrector += 1
                flagged.append(rr)
        i = j + 1
    return out, excluded_by_corrector, flagged


def inject(rr, rate, kind, rng):
    rr = list(map(float, rr))
    n = len(rr)
    m = max(1, int(round(rate * n)))
    pos = []
    cands = list(range(1, n - 2))
    rng.shuffle(cands)
    taken = set()
    for c in cands:
        if len(pos) >= m:
            break
        if any(x in taken for x in (c - 2, c - 1, c, c + 1, c + 2)):
            continue
        pos.append(c)
        taken.add(c)
    pos.sort(reverse=True)
    for i in pos:
        if kind == "ectopic":
            d = 0.30 * rr[i]
            rr[i] -= d
            rr[i + 1] += d
        else:
            rr[i] = rr[i] + rr[i + 1]
            del rr[i + 1]
    return [int(round(x)) for x in rr], len(pos)


def main():
    d = os.path.join(DATA_ROOT, "nsr2db")
    recs = open(os.path.join(d, "RECORDS")).read().split()
    windows = []
    excl = 0
    n_cand_total = 0
    all_flagged = []
    for rec in recs:
        fs = wfdb.rdheader(os.path.join(d, rec)).fs
        ann = wfdb.rdann(os.path.join(d, rec), "ecg")
        beats = [(int(s), sym) for s, sym in zip(ann.sample, ann.symbol) if sym in BEAT_SYMBOLS]
        cands, e, fl = candidate_windows(beats, fs)
        excl += e
        all_flagged.extend(fl)
        n_cand_total += len(cands) + e
        if not cands:
            continue
        pick = np.unique(np.linspace(0, len(cands) - 1, min(PER_RECORD, len(cands))).round().astype(int))
        for k in pick:
            windows.append((rec, cands[k]))
        print(rec, "candidates", len(cands), "excluded_by_corrector", e, flush=True)
    rows = []
    for wi, (rec, rr) in enumerate(windows):
        base = port_dfa.compute(rr)
        if base is None:
            continue
        a0 = base["alpha1"]
        for kind in ("ectopic", "missed"):
            for rate in RATES:
                for s in range(SEEDS):
                    rng = random.Random(zlib.crc32(f"{wi}|{kind}|{rate}|{s}".encode()))
                    bad, m = inject(rr, rate, kind, rng)
                    u = port_dfa.compute(bad)
                    vals, cnt = lc.clean_rr_for_dfa(bad)
                    frac = lc.corrected_fraction(vals, cnt)
                    c = port_dfa.compute(vals)
                    rows.append(dict(record=rec, w=wi, kind=kind, rate=rate, seed=s, n=len(rr), injected=m,
                                     a_clean=a0, a_uncorr=u["alpha1"] if u else None,
                                     a_app=c["alpha1"] if c else None, corrected_fraction=frac,
                                     app_publishes=frac <= lc.MAX_CORRECTED_FRACTION and c is not None))
    summary = {}
    for kind in ("ectopic", "missed"):
        for rate in RATES:
            rs = [r for r in rows if r["kind"] == kind and r["rate"] == rate]
            pub = [r for r in rs if r["app_publishes"]]
            summary[f"{kind}_{int(rate*100)}"] = {
                "n_trials": len(rs), "n_windows": len({r["w"] for r in rs}),
                "uncorrected": bland_altman([r["a_uncorr"] for r in rs], [r["a_clean"] for r in rs]),
                "app_corrected": bland_altman([r["a_app"] for r in rs], [r["a_clean"] for r in rs]),
                "app_published_only": bland_altman([r["a_app"] for r in pub], [r["a_clean"] for r in pub]),
                "mae_uncorrected": float(np.mean([abs(r["a_uncorr"] - r["a_clean"]) for r in rs])),
                "mae_app": float(np.mean([abs(r["a_app"] - r["a_clean"]) for r in rs])),
                "frac_published": len(pub) / len(rs),
                "mean_corrected_fraction": float(np.mean([r["corrected_fraction"] for r in rs])),
                # how many intervals the corrector touched relative to the intervals the
                # injection actually corrupted (ectopic: 2 per event, missed: 1 per event)
                "published_mean_corrected_per_corrupted": float(np.mean([
                    r["corrected_fraction"] * (r["n"] - (r["injected"] if r["kind"] == "missed" else 0))
                    / (r["injected"] * (2 if r["kind"] == "ectopic" else 1)) for r in pub])) if pub else None,
                "all_mean_corrected_per_corrupted": float(np.mean([
                    r["corrected_fraction"] * (r["n"] - (r["injected"] if r["kind"] == "missed" else 0))
                    / (r["injected"] * (2 if r["kind"] == "ectopic" else 1)) for r in rs])),
            }
    a0s = [port_dfa.compute(rr)["alpha1"] for _, rr in windows]
    # False corrections on artifact-free (all-N) windows: what cleanRRForDFA does to them.
    fc_raw, fc_app, fc_frac = [], [], []
    for rr in all_flagged:
        a = port_dfa.compute(rr)
        vals, cnt = lc.clean_rr_for_dfa(rr)
        b = port_dfa.compute(vals)
        if a and b:
            fc_raw.append(a["alpha1"]); fc_app.append(b["alpha1"]); fc_frac.append(lc.corrected_fraction(vals, cnt))
    false_corr = {"n_windows": len(fc_raw), "share_of_all_normal_windows": excl / n_cand_total,
                  "corrected_fraction_mean": float(np.mean(fc_frac)), "corrected_fraction_median": float(np.median(fc_frac)),
                  "share_over_3pct": float(np.mean(np.array(fc_frac) > 0.03)), "share_over_6pct": float(np.mean(np.array(fc_frac) > 0.06)),
                  "alpha1_change": bland_altman(fc_app, fc_raw)}
    out = {"db": "nsr2db 1.0.0", "commit": "e028039", "n_records_used": len({r for r, _ in windows}),
           "n_windows": len(windows), "n_all_normal_windows": n_cand_total,
           "excluded_windows_corrector_flagged_clean": excl,
           "clean_alpha1_mean_sd": [float(np.mean(a0s)), float(np.std(a0s, ddof=1))],
           "window_beats_mean": float(np.mean([len(rr) for _, rr in windows])),
           "false_corrections_on_normal_windows": false_corr,
           "summary": summary}
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    json.dump(out, open(os.path.join(HERE, "results", "dfa_injection_nsr2db.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "summary"}, indent=1))
    for k, v in summary.items():
        u, a, p = v["uncorrected"], v["app_corrected"], v["app_published_only"]
        print(f"{k:12s} trials={v['n_trials']} uncorr bias={u['bias']:+.3f} LoA[{u['loa_low']:+.3f},{u['loa_high']:+.3f}] | "
              f"app bias={a['bias']:+.3f} LoA[{a['loa_low']:+.3f},{a['loa_high']:+.3f}] | published {v['frac_published']*100:.0f}% "
              f"bias={p['bias']:+.3f} cpc_pub={v['published_mean_corrected_per_corrupted']} cpc_all={v['all_mean_corrected_per_corrupted']:.2f} | MAE u={v['mae_uncorrected']:.3f} a={v['mae_app']:.3f} corr%={v['mean_corrected_fraction']*100:.1f}")


if __name__ == "__main__":
    main()
