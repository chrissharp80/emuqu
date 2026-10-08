"""Validation 2: artifact / ectopic handling vs MIT-BIH Arrhythmia Database
(mitdb 1.0.0) beat annotations, using the ports @ e028039 of
ArtifactDetector.detectArtifacts, LiveDFAAnalyzer.cleanRRForDFA and
TimeDomainAnalyzer.computeTimeDomain (RMSSD path).

RR series ("strap-like"): every consecutive pair of annotated beats, in
order; RR point i = (t_ms of beat i, interval to beat i+1). Paced records
102, 104, 107, 217 are excluded (AAMI convention). Beats labelled Q or ? and
paced/fusion-of-paced (/, f) are "unknown": intervals touching them are left
out of the detection scoring but stay in the series the app sees.

Scoring rules (an ectopic beat k shortens the interval that ends at k and
lengthens the one that starts at k, so both are "affected"):
  Interval rule (primary): truth-positive interval = at least one endpoint is
    an ectopic beat; truth-negative = both endpoints normal (N, L, R, e, j).
    Predicted positive = the interval is flagged / corrected / excluded.
  Beat rule: an ectopic beat is detected if either adjacent interval is
    flagged. A normal beat whose two adjacent intervals are both
    normal->normal is a false positive if either is flagged; normal beats next
    to an ectopic beat are not scored.

RMSSD per 5-min segment (t_ms in [5k, 5k+5) min): app value =
computeTimeDomain over the segment with ArtifactDetector flags from the
whole record; reference = RMSSD of successive differences between
consecutive normal->normal intervals (three consecutive normal beats) in the
segment. Segments need >= 30 reference differences and an app value.
Output: results/artifacts_mitdb.json
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import numpy as np
import wfdb

import port_artifact_detection as ad
import port_live_dfa_clean as lc
import port_time_domain as td
from validation_common import DATA_ROOT, BEAT_SYMBOLS, NORMAL_SYMBOLS, ECTOPIC_SYMBOLS, bland_altman

HERE = os.path.dirname(os.path.abspath(__file__))
PACED = {"102", "104", "107", "217"}
SEG_MS = 5 * 60 * 1000


def cls(sym):
    if sym in NORMAL_SYMBOLS:
        return "N"
    if sym in ECTOPIC_SYMBOLS:
        return "E"
    return "U"


def rhythm_at(ann):
    """List of (sample, rhythm) changes from '+' annotations."""
    return [(int(s), a.strip("\x00").strip()) for s, sym, a in zip(ann.sample, ann.symbol, ann.aux_note) if sym == "+"]


def counts(truth, pred):
    tp = sum(1 for t, p in zip(truth, pred) if t and p)
    fn = sum(1 for t, p in zip(truth, pred) if t and not p)
    fp = sum(1 for t, p in zip(truth, pred) if not t and p)
    tn = sum(1 for t, p in zip(truth, pred) if not t and not p)
    return dict(tp=tp, fn=fn, fp=fp, tn=tn)


def rates(c):
    sens = c["tp"] / (c["tp"] + c["fn"]) if c["tp"] + c["fn"] else float("nan")
    spec = c["tn"] / (c["tn"] + c["fp"]) if c["tn"] + c["fp"] else float("nan")
    ppv = c["tp"] / (c["tp"] + c["fp"]) if c["tp"] + c["fp"] else float("nan")
    return dict(sens=sens, spec=spec, ppv=ppv, **c)


def add(a, b):
    return {k: a.get(k, 0) + b[k] for k in b}


def main():
    d = os.path.join(DATA_ROOT, "mitdb")
    recs = [r for r in open(os.path.join(d, "RECORDS")).read().split() if r not in PACED]
    det_names = ["ArtifactDetector", "cleanRRForDFA", "RMSSD_pipeline"]
    tot_int = {k: {} for k in det_names}
    tot_beat = {k: {} for k in det_names}
    per_rec = {}
    seg_rows = []
    by_sym = {k: {} for k in det_names}  # beat-rule sensitivity per ectopic annotation symbol
    n_beats_total = n_ect_total = 0
    for rec in recs:
        h = wfdb.rdheader(os.path.join(d, rec))
        fs = h.fs
        ann = wfdb.rdann(os.path.join(d, rec), "atr")
        beats = [(int(s), sym) for s, sym in zip(ann.sample, ann.symbol) if sym in BEAT_SYMBOLS]
        rhy = rhythm_at(ann)
        bcls = [cls(s) for _, s in beats]
        n_beats_total += len(beats)
        n_ect_total += sum(1 for c in bcls if c == "E")
        pts = [(int(round(beats[i][0] / fs * 1000)), int(round((beats[i + 1][0] - beats[i][0]) / fs * 1000)))
               for i in range(len(beats) - 1)]
        rr = [p[1] for p in pts]
        n = len(pts)
        # --- detectors (per interval i = beat i -> beat i+1) ---
        flags_ad = [f["isArtifact"] for f in ad.detect_artifacts(rr)]
        _, _ = lc.clean_rr_for_dfa(rr)
        flags_lc = lc.artifact_mask([float(v) for v in rr]) if n >= 8 else [False] * n
        # RMSSD pipeline exclusion: flagged by ArtifactDetector, or removed by the
        # ectopic keep-mask inside the 5-min computeTimeDomain window.
        flags_pipe = list(flags_ad)
        seg_of = [p[0] // SEG_MS for p in pts]
        for sgi in sorted(set(seg_of)):
            idx = [i for i in range(n) if seg_of[i] == sgi]
            clean_idx = [i for i in idx if not flags_ad[i]]
            keep = td.ectopic_keep_mask([float(rr[i]) for i in clean_idx])
            for i, k in zip(clean_idx, keep):
                if not k:
                    flags_pipe[i] = True
        dets = {"ArtifactDetector": flags_ad, "cleanRRForDFA": flags_lc, "RMSSD_pipeline": flags_pipe}
        # --- interval truth ---
        it_truth, it_keep = [], []
        for i in range(n):
            a, b = bcls[i], bcls[i + 1]
            if "U" in (a, b):
                it_keep.append(False)
                it_truth.append(False)
            else:
                it_keep.append(True)
                it_truth.append(a == "E" or b == "E")
        # --- beat truth: beats 1..n-1 have both adjacent intervals (i-1, i) ---
        bt_truth, bt_keep, bt_idx = [], [], []
        for k in range(1, n):
            c = bcls[k]
            if c == "E":
                bt_truth.append(True); bt_keep.append(True)
            elif c == "N" and bcls[k - 1] == "N" and bcls[k + 1] == "N":
                bt_truth.append(False); bt_keep.append(True)
            else:
                bt_truth.append(False); bt_keep.append(False)
            bt_idx.append(k)
        pr = {"n_beats": len(beats), "n_ectopic": int(sum(1 for c in bcls if c == "E"))}
        for name, fl in dets.items():
            ci = counts([t for t, k in zip(it_truth, it_keep) if k], [f for f, k in zip(fl, it_keep) if k])
            pb = [fl[k - 1] or fl[k] for k in bt_idx]
            for k, p_ in zip(bt_idx, pb):
                if bcls[k] == "E":
                    sym = beats[k][1]
                    dct = by_sym[name].setdefault(sym, [0, 0])
                    dct[0] += int(p_)
                    dct[1] += 1
            cb = counts([t for t, k in zip(bt_truth, bt_keep) if k], [p for p, k in zip(pb, bt_keep) if k])
            tot_int[name] = add(tot_int[name], ci)
            tot_beat[name] = add(tot_beat[name], cb)
            pr[name + "_interval"] = rates(ci)
            pr[name + "_beat"] = rates(cb)
        per_rec[rec] = pr
        # --- RMSSD per 5-min segment ---
        bool_flags = flags_ad
        for sgi in sorted(set(seg_of)):
            idx = [i for i in range(n) if seg_of[i] == sgi]
            ws, we = idx[0], idx[-1] + 1
            app = td.compute_time_domain(pts, bool_flags, ws, we)
            # reference NN successive differences inside the segment
            diffs = []
            for i in range(ws + 1, we):
                if bcls[i - 1] == "N" and bcls[i] == "N" and bcls[i + 1] == "N":
                    diffs.append(rr[i] - rr[i - 1])
            raw = [rr[i] - rr[i - 1] for i in range(ws + 1, we)]
            # rhythm at segment midpoint (sample domain)
            mid = (pts[ws][0] + pts[we - 1][0]) / 2 / 1000 * fs
            r_now = "(N"
            for s, rname in rhy:
                if s <= mid:
                    r_now = rname
            n_ect = sum(1 for i in range(ws, we + 1) if bcls[i] == "E")
            if len(diffs) >= 30 and app is not None:
                seg_rows.append(dict(record=rec, seg=int(sgi), ref=float(np.sqrt(np.mean(np.square(diffs)))),
                                     app=app["rmssd"], raw=float(np.sqrt(np.mean(np.square(raw)))),
                                     n_beats=we - ws + 1, n_ectopic=n_ect, rhythm=r_now))
    pooled = {k: {"interval": rates(tot_int[k]), "beat": rates(tot_beat[k])} for k in det_names}
    rm = {}
    for label, sel in [("all", lambda r: True),
                       ("no_AF_AFL", lambda r: r["rhythm"] not in ("(AFIB", "(AFL")),
                       ("no_AF_AFL_with_ectopy", lambda r: r["rhythm"] not in ("(AFIB", "(AFL") and r["n_ectopic"] > 0),
                       ("no_AF_AFL_no_ectopy", lambda r: r["rhythm"] not in ("(AFIB", "(AFL") and r["n_ectopic"] == 0),
                       ("no_AF_AFL_ectopy_ge_5pct", lambda r: r["rhythm"] not in ("(AFIB", "(AFL") and r["n_ectopic"] >= 0.05 * r["n_beats"])]:
        rows = [r for r in seg_rows if sel(r)]
        lr = [float(np.log(r["app"] / r["ref"])) for r in rows if r["app"] > 0 and r["ref"] > 0]
        lraw = [float(np.log(r["raw"] / r["ref"])) for r in rows if r["raw"] > 0 and r["ref"] > 0]

        def ratio_ba(v):
            if len(v) < 2:
                return None
            m, sd = float(np.mean(v)), float(np.std(v, ddof=1))
            return {"ratio_bias": float(np.exp(m)), "ratio_loa_low": float(np.exp(m - 1.96 * sd)), "ratio_loa_high": float(np.exp(m + 1.96 * sd))}
        rm_ratio = {"app_vs_ref_ratio": ratio_ba(lr), "raw_vs_ref_ratio": ratio_ba(lraw)}
        rm[label] = {**rm_ratio, "n_segments": len(rows), "n_records": len({r["record"] for r in rows}),
                     "app_vs_ref": bland_altman([r["app"] for r in rows], [r["ref"] for r in rows]),
                     "raw_vs_ref": bland_altman([r["raw"] for r in rows], [r["ref"] for r in rows]),
                     "median_abs_err_app": float(np.median([abs(r["app"] - r["ref"]) for r in rows])) if rows else float("nan"),
                     "median_abs_err_raw": float(np.median([abs(r["raw"] - r["ref"]) for r in rows])) if rows else float("nan"),
                     "median_ref": float(np.median([r["ref"] for r in rows])) if rows else float("nan"),
                     "within10pct_app": float(np.mean([abs(r["app"] - r["ref"]) <= 0.1 * r["ref"] for r in rows])) if rows else float("nan"),
                     "within10pct_raw": float(np.mean([abs(r["raw"] - r["ref"]) <= 0.1 * r["ref"] for r in rows])) if rows else float("nan")}
    out = {"db": "mitdb 1.0.0", "commit": "e028039", "records": recs, "n_records": len(recs),
           "n_beats": n_beats_total, "n_ectopic_beats": n_ect_total, "pooled": pooled,
           "beat_sensitivity_by_symbol": by_sym, "rmssd": rm,
           "per_record": per_rec, "segments": seg_rows}
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    json.dump(out, open(os.path.join(HERE, "results", "artifacts_mitdb.json"), "w"), indent=1)
    print("records", len(recs), "beats", n_beats_total, "ectopic", n_ect_total)
    for k in det_names:
        for lvl in ("interval", "beat"):
            r = pooled[k][lvl]
            print(f"{k:18s} {lvl:8s} sens={r['sens']:.3f} spec={r['spec']:.4f} ppv={r['ppv']:.3f}  tp={r['tp']} fn={r['fn']} fp={r['fp']} tn={r['tn']}")
    for k in det_names:
        print(k, {s_: (a, b, round(a / b, 3)) for s_, (a, b) in sorted(by_sym[k].items())})
    for k, v in rm.items():
        a, b = v["app_vs_ref"], v["raw_vs_ref"]
        print("   ratio app", v["app_vs_ref_ratio"], "raw", v["raw_vs_ref_ratio"])
        print(f"RMSSD {k:28s} n={v['n_segments']:4d} recs={v['n_records']:2d} app bias={a['bias']:.2f} LoA=[{a['loa_low']:.2f},{a['loa_high']:.2f}]  raw bias={b['bias']:.2f} LoA=[{b['loa_low']:.2f},{b['loa_high']:.2f}] medAE app={v['median_abs_err_app']:.2f} raw={v['median_abs_err_raw']:.2f} medRef={v['median_ref']:.1f} w10 app={v['within10pct_app']:.2f} raw={v['within10pct_raw']:.2f}")


if __name__ == "__main__":
    main()
