"""Python port of the RMSSD path of TimeDomainAnalyzer.computeTimeDomain.

Ported line by line from Emuqu/Sources/Analysis/TimeDomainAnalysis.swift at
commit e028039: computeTimeDomain (drop flagged beats; >= 10 clean beats),
successiveDifferences / adjacentDifferences (only beats adjacent in the
ORIGINAL series, both kept by ectopicKeepMask, no recording break between),
ectopicKeepMask / isWithinLocalMedian (local median of up to 10 neighbours
excluding the beat itself, 20 % gate = HRVThresholds.ectopicThresholdPercent),
isRecordingBreak (t_ms timeline only; wallClockMs is nil for these data),
Statistics.rootMeanSquare. meanRR/SDNN/pNN50 included; HR statistics are not ported.

points: list of (t_ms, rr_ms); flags: list of bools (isArtifact).
"""
import math

LOCAL_MEDIAN_WINDOW = 10
ECTOPIC_THRESHOLD = 0.20
BREAK_TOLERANCE_MS = 2000


def ectopic_keep_mask(rr):
    if not len(rr) > LOCAL_MEDIAN_WINDOW:
        return [True] * len(rr)
    half = LOCAL_MEDIAN_WINDOW // 2
    out = []
    n = len(rr)
    for i in range(n):
        lo, hi = max(0, i - half), min(n, i + half + 1)
        nb = sorted(rr[j] for j in range(lo, hi) if j != i)
        if not nb:
            out.append(True)
            continue
        mid = len(nb) // 2
        med = (nb[mid - 1] + nb[mid]) / 2.0 if len(nb) % 2 == 0 else nb[mid]
        if not med > 0:
            out.append(True)
            continue
        out.append(abs(rr[i] - med) / med <= ECTOPIC_THRESHOLD)
    return out


def is_recording_break(prev, nxt):
    tol = prev[1] + BREAK_TOLERANCE_MS
    return nxt[0] - (prev[0] + prev[1]) > tol


def _adjacent(rr, idx, breaks, kept):
    d = []
    for k in range(1, len(rr)):
        if kept(k) and kept(k - 1) and idx[k] == idx[k - 1] + 1 and idx[k] not in breaks:
            d.append(rr[k] - rr[k - 1])
    return d


def compute_time_domain(points, flags, ws, we):
    if not (0 <= ws <= we <= len(points) and we <= len(flags)):
        return None
    clean, idx = [], []
    for i in range(ws, we):
        if not flags[i]:
            clean.append(float(points[i][1]))
            idx.append(i)
    breaks = {i for i in range(ws, we) if i > 0 and is_recording_break(points[i - 1], points[i])}
    if len(clean) < 10:
        return None
    keep = ectopic_keep_mask(clean)
    diffs = _adjacent(clean, idx, breaks, lambda k: keep[k])
    if not diffs:
        diffs = _adjacent(clean, idx, breaks, lambda k: True)
        if not diffs:
            return None
    mean = sum(clean) / len(clean)
    sd = math.sqrt(sum((v - mean) ** 2 for v in clean) / (len(clean) - 1))
    return {"meanRR": mean, "sdnn": sd,
            "rmssd": math.sqrt(sum(x * x for x in diffs) / len(diffs)),
            "pnn50": sum(1 for x in diffs if abs(x) > 50) / len(diffs) * 100,
            "nDiffs": len(diffs)}
