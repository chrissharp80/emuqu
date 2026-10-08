"""Validation 1: HRVSleepStageClassifier (RR-only path, port @ e028039) vs PSG.

Datasets
  slpdb 1.0.0  MIT-BIH Polysomnographic Database: RR from the .ecg beat
               annotations, reference stages from the .st aux notes.
  capslpdb 1.0.0 CAP Sleep Database healthy controls n1-n16: RR from R peaks
               detected on the EDF ECG channel (see cap_extract_rr.py), stages
               from the RemLogic hypnogram .txt.

Reference mapping: W -> wake; 1, 2 -> core; 3, 4 -> deep; R -> rem; MT,
unscored -> excluded. The classifier is run once per record with
sleepStartMs = start of the first scored 30-s epoch and sleepEndMs = end of
the last one, so its 5-min windows align with blocks of ten 30-s epochs.

Boundary variants: "full" = whole scored recording (lights-out to end);
"sp" = reference sleep period only (first to last non-wake scored epoch),
which mimics the app receiving correct sleep-onset / wake times.

Usage: python3 -I validate_sleep.py slpdb|cap [nn|all] [full|sp]
       (writes results/sleep_<db>_<mode>_<bounds>.json)
"""
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import numpy as np
import wfdb

import port_sleep_stage_classifier as sc
from validation_common import (DATA_ROOT, CLASSES, beats_from_ann, nn_rr_points, all_beat_rr_points,
                               confusion, summary_from_cm, bland_altman)

HERE = os.path.dirname(os.path.abspath(__file__))
STAGE_MAP_SLPDB = {"W": "wake", "1": "core", "2": "core", "3": "deep", "4": "deep", "R": "rem"}
APP_TO_4 = {"awake": "wake", "core": "core", "deep": "deep", "rem": "rem"}
MIN_SCORABLE_IN_WINDOW = 5
EPOCH_MS = 30000


def slpdb_records(mode):
    d = os.path.join(DATA_ROOT, "slpdb")
    for rec in open(os.path.join(d, "RECORDS")).read().split():
        h = wfdb.rdheader(os.path.join(d, rec))
        fs = h.fs
        beats = beats_from_ann(wfdb.rdann(os.path.join(d, rec), "ecg"))
        st = wfdb.rdann(os.path.join(d, rec), "st")
        epoch_samples = int(round(30 * fs))
        first = int(st.sample[0])
        n_ep = int(round((int(st.sample[-1]) - first) / epoch_samples)) + 1
        raw = [None] * n_ep
        rawtok = [None] * n_ep
        for s, note in zip(st.sample, st.aux_note):
            note = note.replace("\x00", "")
            tok = note.split()[0] if note.strip() else ""
            k = int(round((int(s) - first) / epoch_samples))
            if 0 <= k < n_ep:
                raw[k] = STAGE_MAP_SLPDB.get(tok)
                rawtok[k] = tok
        rr = nn_rr_points(beats, fs) if mode == "nn" else all_beat_rr_points(beats, fs)
        n_beats = len(beats)
        n_normal = sum(1 for _, s in beats if s in "NLRej")
        yield rec, rr, raw, rawtok, int(round(first / fs * 1000)), {"age_sex": " ".join(h.comments[0].split()[:2]) if h.comments else "",
                                                                    "beats": n_beats, "normal_beats": n_normal}


def cap_records(mode):
    d = os.path.join(DATA_ROOT, "capslpdb", "derived")
    for i in range(1, 17):
        p = os.path.join(d, f"n{i}.json")
        if not os.path.exists(p):
            continue
        j = json.load(open(p))
        rr = [tuple(x) for x in j["rr_points"]]
        import port_artifact_detection as ad
        fl = ad.detect_artifacts([r for _, r in rr])
        yield f"n{i}", rr, j["epochs"], j["epoch_tokens"], j["first_epoch_ms"], {
            "beats": len(rr) + 1, "detector": j["detector"], "ecg_fs": j["fs"],
            "artifact_pct_ArtifactDetector": 100.0 * sum(f["isArtifact"] for f in fl) / max(1, len(fl))}


def majority(labels):
    lab = [x for x in labels if x is not None]
    if len(lab) < MIN_SCORABLE_IN_WINDOW:
        return None
    c = Counter(lab)
    top = max(c.values())
    for x in lab:  # tie-break: the tied class that occurs first in time
        if c[x] == top:
            return x


def evaluate_record(rr, ref, first_ms):
    start = first_ms
    end = first_ms + len(ref) * EPOCH_MS
    res = sc.classify(rr, start, end)
    n_windows_grid = (len(ref) + 9) // 10
    out = {"n_epochs_30s": len(ref), "n_scorable_30s": sum(1 for x in ref if x is not None),
           "n_windows_grid": n_windows_grid}
    ref_min = {"tst": sum(1 for x in ref if x in ("core", "deep", "rem")) * 0.5,
               "deep": sum(1 for x in ref if x == "deep") * 0.5,
               "rem": sum(1 for x in ref if x == "rem") * 0.5,
               "wake": sum(1 for x in ref if x == "wake") * 0.5}
    out["ref_minutes"] = ref_min
    if res is None:
        out["classified"] = False
        return out
    out["classified"] = True
    pred_by_win = {}
    for w, s in zip(res["windows"], res["stages"]):
        pred_by_win[(w["start_ms"] - start) // sc.WINDOW_MS] = APP_TO_4[s]
    out["n_windows_classified"] = len(pred_by_win)
    out["app_minutes"] = {"tst": res["deepSleepMinutes"] + res["remSleepMinutes"] + res["coreSleepMinutes"],
                          "deep": res["deepSleepMinutes"], "rem": res["remSleepMinutes"],
                          "core": res["coreSleepMinutes"], "wake": res["awakeMinutes"]}
    p5, r5, p30, r30 = [], [], [], []
    for j in range(n_windows_grid):
        m = majority(ref[10 * j: 10 * j + 10])
        if j in pred_by_win and m is not None:
            p5.append(pred_by_win[j])
            r5.append(m)
    for e, lab in enumerate(ref):
        if lab is not None and (e // 10) in pred_by_win:
            p30.append(pred_by_win[e // 10])
            r30.append(lab)
    out["pairs5"] = list(zip(r5, p5))
    out["pairs30"] = list(zip(r30, p30))
    out["cm5"] = confusion(r5, p5).tolist()
    out["cm30"] = confusion(r30, p30).tolist()
    out["stats5"] = summary_from_cm(confusion(r5, p5))
    out["stats30"] = summary_from_cm(confusion(r30, p30))
    out["has_freq"] = any(w["lfHfRatio"] is not None for w in res["windows"])
    out["has_dfa"] = any(w["dfaAlpha1"] is not None for w in res["windows"])
    out["app_stage_counts_5min"] = dict(Counter(res["stages"]))
    return out


def main():
    db = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "nn"
    bounds = sys.argv[3] if len(sys.argv) > 3 else "full"
    gen = slpdb_records(mode) if db == "slpdb" else cap_records(mode)
    per = {}
    for rec, rr, ref, tok, first_ms, meta in gen:
        if bounds == "sp":
            sl = [i for i, x in enumerate(ref) if x in ("core", "deep", "rem")]
            if not sl:
                continue
            first_ms += sl[0] * EPOCH_MS
            ref = ref[sl[0]: sl[-1] + 1]
            tok = tok[sl[0]: sl[-1] + 1]
        r = evaluate_record(rr, ref, first_ms)
        r["meta"] = meta
        r["n_rr_points"] = len(rr)
        r["ref_token_counts"] = dict(Counter(t for t in tok if t is not None))
        per[rec] = r
        s = r.get("stats5", {})
        print(rec, "classified" if r["classified"] else "NOT CLASSIFIED",
              {k: round(v, 3) for k, v in s.items() if k in ("n", "accuracy", "kappa")}, flush=True)
    recs = [k for k, v in per.items() if v["classified"]]
    pooled = {}
    for res in ("5", "30"):
        cm = np.zeros((4, 4), int)
        for k in recs:
            cm += np.array(per[k]["cm" + res])
        pooled["cm" + res] = cm.tolist()
        pooled["stats" + res] = summary_from_cm(cm)
        ks = [per[k]["stats" + res]["kappa"] for k in recs]
        accs = [per[k]["stats" + res]["accuracy"] for k in recs]
        pooled["per_record_kappa_mean_sd" + res] = [float(np.nanmean(ks)), float(np.nanstd(ks, ddof=1))]
        pooled["per_record_acc_mean_sd" + res] = [float(np.mean(accs)), float(np.std(accs, ddof=1))]
    for q in ("tst", "deep", "rem"):
        dev = [per[k]["app_minutes"][q] for k in recs]
        ref = [per[k]["ref_minutes"][q] for k in recs]
        pooled["ba_" + q] = bland_altman(dev, ref)
        pooled["mean_ref_" + q] = float(np.mean(ref))
        pooled["mean_app_" + q] = float(np.mean(dev))
    pooled["n_records_total"] = len(per)
    pooled["n_records_classified"] = len(recs)
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out = os.path.join(HERE, "results", f"sleep_{db}_{mode}_{bounds}.json")
    json.dump({"db": db, "mode": mode, "bounds": bounds, "commit": "e028039", "per_record": per, "pooled": pooled}, open(out, "w"), indent=1)
    print(json.dumps({k: v for k, v in pooled.items() if not k.startswith("cm")}, indent=1))


if __name__ == "__main__":
    main()
