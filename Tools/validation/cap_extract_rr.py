"""CAP Sleep Database (capslpdb 1.0.0) healthy controls: R-peak detection and
hypnogram parsing for validate_sleep.py (not a port of app code).

R-peak detector: wfdb.processing.XQRS (wfdb-python 4.3.1, default config) run
on the ECG channel resampled to 250 Hz (scipy.signal.resample_poly), in
consecutive 5-min chunks (10-s overlap, peaks kept only in each chunk's own
5 min) so the detector re-learns its thresholds after amplitude changes (a
single whole-night pass stalled on n4 after ~30 min). Each
detection then refined to the largest |band-passed (5-20 Hz)| sample within
+/-50 ms at the channel's native rate. RR = differences of consecutive refined
peaks (all detected beats; no beat classification). Physiologically
implausible RR are left in: the classifier applies its own 300-2000 ms gate.

Hypnogram: RemLogic .txt, 30-s rows whose Event is SLEEP-S0..S4 / SLEEP-REM
(-> W, 1-4, R); SLEEP-MT / SLEEP-UNSCORED are excluded. Clock times are
converted to seconds after the EDF start time (midnight wrap handled).

Usage: python3 -I cap_extract_rr.py n1 [n2 ...]   -> <DATA_ROOT>/capslpdb/derived/<rec>.json
"""
import json
import os
import sys
import time
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import numpy as np
from scipy.signal import butter, filtfilt, resample_poly
import wfdb
from wfdb import processing

from validation_common import DATA_ROOT, edf_read_channel

EPOCH_MAP = {"SLEEP-S0": "wake", "SLEEP-S1": "core", "SLEEP-S2": "core", "SLEEP-S3": "deep",
             "SLEEP-S4": "deep", "SLEEP-REM": "rem"}
TOK = {"SLEEP-S0": "W", "SLEEP-S1": "1", "SLEEP-S2": "2", "SLEEP-S3": "3", "SLEEP-S4": "4",
       "SLEEP-REM": "R", "SLEEP-MT": "MT", "SLEEP-UNSCORED": "U"}
ECG_LABELS = ["ECG1-ECG2", "ECG", "EKG", "ekg"]


def hms(s):
    h, m, x = s.replace(".", ":").split(":")
    return int(h) * 3600 + int(m) * 60 + float(x)


def parse_hypnogram(path, edf_start_s):
    lines = open(path, encoding="latin-1").read().splitlines()
    hi = next(i for i, l in enumerate(lines) if l.startswith("Sleep Stage"))
    cols = lines[hi].split("\t")
    ti, ei, di = cols.index("Time [hh:mm:ss]"), cols.index("Event"), cols.index("Duration[s]")
    rows = []
    for l in lines[hi + 1:]:
        c = l.split("\t")
        if len(c) <= max(ti, ei, di) or not c[ei].startswith("SLEEP-"):
            continue
        t = hms(c[ti]) - edf_start_s
        if t < -6 * 3600:
            t += 86400
        rows.append((t, c[ei], float(c[di])))
    t0 = rows[0][0]
    n = int(round((rows[-1][0] - t0) / 30.0)) + 1
    ep, tok = [None] * n, [None] * n
    for t, ev, dur in rows:
        k = int(round((t - t0) / 30.0))
        for j in range(max(1, int(round(dur / 30.0)))):
            if 0 <= k + j < n:
                ep[k + j] = EPOCH_MAP.get(ev)
                tok[k + j] = TOK.get(ev, ev)
    return t0, ep, tok


def detect(sig, fs):
    target = 250.0
    fr = Fraction(target / fs).limit_denominator(1000)
    x = resample_poly(sig.astype(np.float64), fr.numerator, fr.denominator) if abs(fs - target) > 1e-6 else sig.astype(np.float64)
    chunk, pad = int(300 * target), int(10 * target)
    found = []
    for c0 in range(0, len(x), chunk):
        lo, hi = max(0, c0 - pad), min(len(x), c0 + chunk + pad)
        if hi - lo < int(20 * target):
            continue
        q = processing.XQRS(sig=x[lo:hi], fs=target)
        q.detect(verbose=False)
        inds = np.asarray(q.qrs_inds, dtype=np.int64) + lo
        found.append(inds[(inds >= c0) & (inds < c0 + chunk)])
    approx = (np.concatenate(found) if found else np.zeros(0)).astype(float) * fs / target
    hi_cut = min(20.0, 0.45 * fs)
    b, a = butter(2, [5.0 / (fs / 2), hi_cut / (fs / 2)], btype="band")
    bp = np.abs(filtfilt(b, a, sig.astype(np.float64)))
    r = max(1, int(round(0.05 * fs)))
    out = []
    for p in approx.astype(int):
        lo, hi = max(0, p - r), min(len(bp), p + r + 1)
        out.append(lo + int(np.argmax(bp[lo:hi])))
    return np.unique(np.asarray(out, dtype=np.int64))


def main():
    outdir = os.path.join(DATA_ROOT, "capslpdb", "derived")
    os.makedirs(outdir, exist_ok=True)
    for rec in sys.argv[1:]:
        t_start = time.time()
        edf = os.path.join(DATA_ROOT, "capslpdb", rec + ".edf")
        lab = None
        sig = fs = start = None
        for L in ECG_LABELS:
            try:
                sig, fs, start, labels = edf_read_channel(edf, L)
                lab = L
                break
            except ValueError:
                continue
        if sig is None:
            print(rec, "no ECG channel; skipped", flush=True)
            json.dump({"record": rec, "skipped": "no ECG channel"}, open(os.path.join(outdir, rec + ".skip.json"), "w"))
            continue
        edf_start_s = hms(start)
        t0, ep, tok = parse_hypnogram(os.path.join(DATA_ROOT, "capslpdb", rec + ".txt"), edf_start_s)
        peaks = detect(sig, fs)
        tms = np.round(peaks / fs * 1000.0).astype(np.int64)
        rr = [(int(a), int(b - a)) for a, b in zip(tms[:-1], tms[1:])]
        json.dump({"record": rec, "ecg_label": lab, "fs": fs, "edf_start": start,
                   "detector": f"wfdb {wfdb.__version__} XQRS @250 Hz + native-rate peak refinement",
                   "n_peaks": int(len(peaks)), "duration_h": len(sig) / fs / 3600,
                   "first_epoch_ms": int(round(t0 * 1000)), "epochs": ep, "epoch_tokens": tok,
                   "rr_points": rr}, open(os.path.join(outdir, rec + ".json"), "w"))
        rrv = np.array([r for _, r in rr])
        print(rec, lab, fs, f"{len(sig)/fs/3600:.2f} h", "peaks", len(peaks), "median RR", np.median(rrv),
              "frac RR outside 300-2000", float(np.mean((rrv < 300) | (rrv > 2000))),
              f"{time.time()-t_start:.0f}s", flush=True)


if __name__ == "__main__":
    main()
