"""Shared helpers for the PhysioNet validation scripts (not ports of app code):
beat-symbol sets, RR-series construction, agreement statistics, a minimal EDF
channel reader. Commit under test: e028039.
"""
import math
import os
import struct

import numpy as np

DATA_ROOT = "/tmp/claude-0/-home-user/62b78298-79d2-549a-9361-61e9b461286b/scratchpad/physionet"
COMMIT = "e028039"

# WFDB beat annotation codes (PhysioNet "ecgcodes"); non-beat codes ('+', '~', '|', '"', 'x', '[', ']', '!' ...) are ignored.
BEAT_SYMBOLS = set("NLRBAaJSVrFejnE/fQ?")
NORMAL_SYMBOLS = set("NLRej")          # normal: N, L, R, e, j
ECTOPIC_SYMBOLS = BEAT_SYMBOLS - NORMAL_SYMBOLS - set("/fQ?")  # A a J S V r F n E B (paced/unclassifiable excluded)


def beats_from_ann(ann):
    """(sample, symbol) for beat annotations only, in time order."""
    return [(int(s), sym) for s, sym in zip(ann.sample, ann.symbol) if sym in BEAT_SYMBOLS]


def nn_rr_points(beats, fs):
    """App-style RR points (t_ms, rr_ms) from consecutive NORMAL->NORMAL beat pairs
    only. An interval touching a non-normal beat is omitted, so t_ms jumps there
    (the app sees that as a short gap). t_ms = time of the interval's first R peak."""
    pts = []
    for (s0, a), (s1, b) in zip(beats, beats[1:]):
        if a in NORMAL_SYMBOLS and b in NORMAL_SYMBOLS:
            pts.append((int(round(s0 / fs * 1000.0)), int(round((s1 - s0) / fs * 1000.0))))
    return pts


def all_beat_rr_points(beats, fs):
    """Strap-like RR points from every consecutive annotated beat pair."""
    return [(int(round(s0 / fs * 1000.0)), int(round((s1 - s0) / fs * 1000.0)))
            for (s0, _), (s1, _) in zip(beats, beats[1:])]


# ---------------- agreement statistics ----------------
CLASSES = ["wake", "core", "deep", "rem"]


def confusion(ref, pred, classes=CLASSES):
    idx = {c: i for i, c in enumerate(classes)}
    m = np.zeros((len(classes), len(classes)), dtype=int)
    for r, p in zip(ref, pred):
        m[idx[r], idx[p]] += 1
    return m


def kappa_from_cm(m):
    n = m.sum()
    if n == 0:
        return float("nan")
    po = np.trace(m) / n
    pe = float((m.sum(0) * m.sum(1)).sum()) / (n * n)
    return (po - pe) / (1 - pe) if pe < 1 else float("nan")


def summary_from_cm(m, classes=CLASSES):
    n = int(m.sum())
    out = {"n": n, "accuracy": float(np.trace(m) / n) if n else float("nan"), "kappa": kappa_from_cm(m)}
    for i, c in enumerate(classes):
        tp = m[i, i]
        out[f"sens_{c}"] = float(tp / m[i].sum()) if m[i].sum() else float("nan")
        out[f"prec_{c}"] = float(tp / m[:, i].sum()) if m[:, i].sum() else float("nan")
    return out


def bland_altman(device, reference):
    d = np.asarray(device, float) - np.asarray(reference, float)
    if len(d) < 2:
        return {"n": len(d), "bias": float(d.mean()) if len(d) else float("nan"), "sd": float("nan"),
                "loa_low": float("nan"), "loa_high": float("nan")}
    sd = float(d.std(ddof=1))
    b = float(d.mean())
    return {"n": len(d), "bias": b, "sd": sd, "loa_low": b - 1.96 * sd, "loa_high": b + 1.96 * sd}


def fmt(x, nd=2):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "n/a"
    return f"{x:.{nd}f}"


# ---------------- minimal EDF reader ----------------
def edf_read_channel(path, label):
    """Return (signal_physical float32, fs, start_hhmmss) for one channel of an EDF file."""
    with open(path, "rb") as f:
        h = f.read(256)
        ns = int(h[252:256])
        hdr = f.read(ns * 256)
    start_time = h[176:184].decode()
    header_bytes = int(h[184:192])
    nrec = int(h[236:244])
    dur = float(h[244:252])

    def field(off, width, i):
        return hdr[ns * off + i * width: ns * off + (i + 1) * width].decode("latin-1").strip()

    offs = {}
    o = 0
    for name, w in [("label", 16), ("trans", 80), ("dim", 8), ("pmin", 8), ("pmax", 8), ("dmin", 8),
                    ("dmax", 8), ("prefilt", 80), ("nsamp", 8), ("res", 32)]:
        offs[name] = (o, w)
        o += w
    labels = [field(*offs["label"], i) for i in range(ns)]
    ci = labels.index(label)
    nsamp = [int(field(*offs["nsamp"], i)) for i in range(ns)]
    pmin, pmax = float(field(*offs["pmin"], ci)), float(field(*offs["pmax"], ci))
    dmin, dmax = float(field(*offs["dmin"], ci)), float(field(*offs["dmax"], ci))
    rec_len = sum(nsamp)
    size = os.path.getsize(path)
    if nrec < 0:
        nrec = (size - header_bytes) // (2 * rec_len)
    nrec = min(nrec, (size - header_bytes) // (2 * rec_len))
    mm = np.memmap(path, dtype="<i2", mode="r", offset=header_bytes, shape=(nrec, rec_len))
    start = sum(nsamp[:ci])
    dig = np.asarray(mm[:, start:start + nsamp[ci]]).reshape(-1).astype(np.float32)
    gain = (pmax - pmin) / (dmax - dmin)
    sig = (dig - dmin) * gain + pmin
    return sig, nsamp[ci] / dur, start_time, labels
