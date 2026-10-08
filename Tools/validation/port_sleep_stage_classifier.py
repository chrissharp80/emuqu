"""Python port of HRVSleepStageClassifier.classify (RR-only path).

Ported line by line from, all at commit e028039:
  Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift        (features, ranks, scores, classify)
  Emuqu/Sources/Analysis/HRVSleepStageClassifier+Watch.swift  (smoothStages, buildIntervals only;
                                                               the Watch augmentation path is NOT ported)
  Emuqu/Sources/Analysis/SleepBoundaryResolver.swift          (RRWindowSweep: t_ms in [start, end))
  Emuqu/Sources/Utilities/Constants+SleepAndDisplay.swift     (SleepClassifierConstants)
  Emuqu/Sources/Utilities/Constants.swift                     (HRVConstants.RRInterval 300...2000 ms)
  Emuqu/Sources/Utilities/Statistics.swift                    (rootMeanSquare)
  Emuqu/Sources/Models/SleepDomain.swift                      (durationMinutes = Int(seconds / 60))
Per-window features call the ported DFAAnalyzer.compute (port_dfa.py) and
FrequencyDomainAnalyzer.computeFromCleanPairs (port_frequency_domain.py).

Input: rr_points = list of (t_ms, rr_ms) ints, t_ms monotonic, ms since recording start.
Times are kept in ms since recording start instead of Date objects.
"""
import math
import port_dfa
import port_frequency_domain as fd

WINDOW_MS = 5 * 60 * 1000
MIN_POINTS = 10
MIN_VALID = 8
MIN_WINDOWS = 6
MIN_BEATS_DFA = 64
MIN_TIME_BEFORE_REM_MS = 60 * 60 * 1000
RR_MIN, RR_MAX = 300, 2000

DEEP_T, REM_T, AWAKE_T = 0.60, 0.63, 0.80
DEEP_EARLY_END, DEEP_MID_END, DEEP_MID_BONUS, DEEP_LATE_BONUS = 0.4, 0.6, 0.4, 0.15
REM_LATE_START, REM_MID_START, REM_MID_BONUS = 0.6, 0.35, 0.25
FALLBACK_MEDIAN_DFA = 0.85

W_DEEP_ALL = dict(hr=0.12, rmssd=0.10, cv=0.08, hf=0.15, lfHf=0.18, dfa=0.22, temporal=0.15)
W_DEEP_FREQ = dict(hr=0.15, rmssd=0.13, cv=0.10, hf=0.18, lfHf=0.24, temporal=0.20)
W_DEEP_DFA = dict(hr=0.18, rmssd=0.18, cv=0.12, dfa=0.32, temporal=0.20)
W_DEEP_TD = dict(hr=0.25, rmssd=0.25, cv=0.15, temporal=0.35)
W_REM_ALL = dict(rmssd=0.10, cv=0.10, lfHf=0.24, hf=0.12, dfa=0.26, temporal=0.18)
W_REM_FREQ = dict(rmssd=0.12, cv=0.12, lfHf=0.30, hf=0.18, temporal=0.28)
W_REM_DFA = dict(rmssd=0.16, cv=0.16, dfa=0.38, temporal=0.30)
W_REM_TD = dict(rmssd=0.32, cv=0.43, temporal=0.25)
W_AWAKE_FREQ = dict(hr=0.30, rmssd=0.25, cv=0.15, lfHf=0.20, hf=0.10)
W_AWAKE_NOFREQ = dict(hr=0.35, rmssd=0.30, cv=0.20, dfa=0.15)

DEEP, REM, CORE, AWAKE = "deep", "rem", "core", "awake"


def is_valid_rr(ms):
    return RR_MIN <= ms <= RR_MAX


def root_mean_square(vals):
    if not vals:
        return 0.0
    return math.sqrt(sum(v * v for v in vals) / len(vals))


def window_variability(valid, avg):
    if len(valid) <= 1:
        return 0.0, 0.0, 0.0
    diffs = [valid[i] - valid[i - 1] for i in range(1, len(valid))]
    var = sum((v - avg) ** 2 for v in valid) / len(valid)
    sdnn = math.sqrt(var)
    return root_mean_square(diffs), sdnn, (sdnn / avg if avg > 0 else 0.0)


def feature_window(points, ws, we):
    if len(points) < MIN_POINTS:
        return None
    valid = [float(rr) for (_, rr) in points if is_valid_rr(int(rr))]
    if len(valid) < MIN_VALID:
        return None
    avg = sum(valid) / len(valid)
    rmssd, sdnn, cv = window_variability(valid, avg)
    a1 = None
    if len(valid) >= MIN_BEATS_DFA:
        r = port_dfa.compute(valid)
        a1 = r["alpha1"] if r else None
    vp = [(t, rr) for (t, rr) in points if is_valid_rr(rr)]
    freq = fd.compute_from_clean_pairs([(t + rr / 2.0) / 1000.0 for (t, rr) in vp], [float(rr) for (_, rr) in vp])
    return dict(start_ms=ws, end_ms=we, midpoint_ms=ws + WINDOW_MS // 2, hr=60000.0 / avg,
                rmssd=rmssd, sdnn=sdnn, hrCV=cv, dfaAlpha1=a1,
                lfHfRatio=freq["lfHfRatio"] if freq else None, hfPower=freq["hf"] if freq else None)


def build_feature_windows(rr_points, sleep_start_ms, sleep_end_ms):
    windows = []
    lo = hi = 0
    n = len(rr_points)
    ws = sleep_start_ms
    while ws < sleep_end_ms:
        we = min(ws + WINDOW_MS, sleep_end_ms)
        while lo < n and rr_points[lo][0] < ws:
            lo += 1
        if hi < lo:
            hi = lo
        while hi < n and rr_points[hi][0] < we:
            hi += 1
        w = feature_window(rr_points[lo:hi], ws, we)
        if w is not None:
            windows.append(w)
        ws += WINDOW_MS
    return windows


def compute_ranks(values):
    if len(values) <= 1:
        return [0.5 for _ in values]
    n = float(len(values) - 1)
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    g = 0
    while g < len(order):
        e = g + 1
        while e < len(order) and values[order[e]] == values[order[g]]:
            e += 1
        mr = float(g + e - 1) / 2.0 / n
        for k in range(g, e):
            ranks[order[k]] = mr
        g = e
    return ranks


def _feature_ranks(windows):
    dfa_vals = [w["dfaAlpha1"] for w in windows]
    valid = [v for v in dfa_vals if v is not None]
    med = FALLBACK_MEDIAN_DFA if not valid else sorted(valid)[len(valid) // 2]
    return dict(
        hr=compute_ranks([w["hr"] for w in windows]),
        rmssd=compute_ranks([w["rmssd"] for w in windows]),
        cv=compute_ranks([w["hrCV"] for w in windows]),
        hf=compute_ranks([w["hfPower"] if w["hfPower"] is not None else 0.0 for w in windows]),
        lfHf=compute_ranks([w["lfHfRatio"] if w["lfHfRatio"] is not None else 2.0 for w in windows]),
        dfa=compute_ranks([v if v is not None else med for v in dfa_vals]),
    )


def _deep_temporal(f):
    return 1.0 if f < DEEP_EARLY_END else (DEEP_MID_BONUS if f < DEEP_MID_END else DEEP_LATE_BONUS)


def _rem_temporal(f):
    return 1.0 if f > REM_LATE_START else (REM_MID_BONUS if f > REM_MID_START else 0.0)


def _deep_score(R, i, f, has_freq, has_dfa):
    t = _deep_temporal(f)
    if has_freq and has_dfa:
        W = W_DEEP_ALL
        return ((1.0 - R["hr"][i]) * W["hr"] + R["rmssd"][i] * W["rmssd"] + (1.0 - R["cv"][i]) * W["cv"]
                + R["hf"][i] * W["hf"] + (1.0 - R["lfHf"][i]) * W["lfHf"] + (1.0 - R["dfa"][i]) * W["dfa"] + t * W["temporal"])
    if has_freq:
        W = W_DEEP_FREQ
        return ((1.0 - R["hr"][i]) * W["hr"] + R["rmssd"][i] * W["rmssd"] + (1.0 - R["cv"][i]) * W["cv"]
                + R["hf"][i] * W["hf"] + (1.0 - R["lfHf"][i]) * W["lfHf"] + t * W["temporal"])
    if has_dfa:
        W = W_DEEP_DFA
        return ((1.0 - R["hr"][i]) * W["hr"] + R["rmssd"][i] * W["rmssd"] + (1.0 - R["cv"][i]) * W["cv"]
                + (1.0 - R["dfa"][i]) * W["dfa"] + t * W["temporal"])
    W = W_DEEP_TD
    return (1.0 - R["hr"][i]) * W["hr"] + R["rmssd"][i] * W["rmssd"] + (1.0 - R["cv"][i]) * W["cv"] + t * W["temporal"]


def _rem_score(R, i, f, has_freq, has_dfa):
    t = _rem_temporal(f)
    if has_freq and has_dfa:
        W = W_REM_ALL
        return ((1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"] + R["lfHf"][i] * W["lfHf"]
                + (1.0 - R["hf"][i]) * W["hf"] + R["dfa"][i] * W["dfa"] + t * W["temporal"])
    if has_freq:
        W = W_REM_FREQ
        return ((1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"] + R["lfHf"][i] * W["lfHf"]
                + (1.0 - R["hf"][i]) * W["hf"] + t * W["temporal"])
    if has_dfa:
        W = W_REM_DFA
        return (1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"] + R["dfa"][i] * W["dfa"] + t * W["temporal"]
    W = W_REM_TD
    return (1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"] + t * W["temporal"]


def _awake_score(R, i, has_freq):
    if has_freq:
        W = W_AWAKE_FREQ
        return (R["hr"][i] * W["hr"] + (1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"]
                + R["lfHf"][i] * W["lfHf"] + (1.0 - R["hf"][i]) * W["hf"])
    W = W_AWAKE_NOFREQ
    return R["hr"][i] * W["hr"] + (1.0 - R["rmssd"][i]) * W["rmssd"] + R["cv"][i] * W["cv"] + R["dfa"][i] * W["dfa"]


def classify_stage(deep, rem, awake):
    if awake > AWAKE_T:
        return AWAKE
    if deep > DEEP_T and deep >= rem:
        return DEEP
    if rem > REM_T and rem > deep:
        return REM
    return CORE


def compute_window_scores(windows, sleep_start_ms):
    R = _feature_ranks(windows)
    has_freq = any(w["lfHfRatio"] is not None for w in windows)
    has_dfa = any(w["dfaAlpha1"] is not None for w in windows)
    night = max(1, (windows[-1]["midpoint_ms"] if windows else sleep_start_ms) - sleep_start_ms)
    out = []
    for i, w in enumerate(windows):
        elapsed = w["midpoint_ms"] - sleep_start_ms
        f = float(elapsed) / float(night)
        d = _deep_score(R, i, f, has_freq, has_dfa)
        r = _rem_score(R, i, f, has_freq, has_dfa)
        if elapsed < MIN_TIME_BEFORE_REM_MS:
            r = 0.0
        a = _awake_score(R, i, has_freq)
        out.append(dict(deep=d, rem=r, awake=a, stage=classify_stage(d, r, a), hasFreqDomain=has_freq))
    return out


def smooth_stages(stages):
    if len(stages) < 3:
        return list(stages)
    s = list(stages)
    for i in range(1, len(stages) - 1):
        prev, curr, nxt = s[i - 1], s[i], s[i + 1]
        if curr == AWAKE:
            continue
        if prev == nxt and curr != prev:
            s[i] = prev
    return s


def build_intervals(windows, stages):
    if len(windows) != len(stages) or not windows:
        return []
    out = []
    cur = stages[0]
    seg_start = windows[0]["start_ms"]
    for i in range(1, len(windows)):
        if stages[i] != cur or windows[i]["start_ms"] > windows[i - 1]["end_ms"]:
            out.append((cur, seg_start, windows[i - 1]["end_ms"]))
            cur = stages[i]
            seg_start = windows[i]["start_ms"]
    out.append((cur, seg_start, windows[-1]["end_ms"]))
    return out


def duration_minutes(start_ms, end_ms):
    return int((end_ms - start_ms) / 1000.0 / 60)


def classify(rr_points, sleep_start_ms, sleep_end_ms):
    """HRVSleepStageClassifier.classify. Returns None or a dict with stage minutes,
    intervals, and (for validation) the per-window stages and features."""
    if not sleep_end_ms > sleep_start_ms:
        return None
    windows = build_feature_windows(rr_points, sleep_start_ms, sleep_end_ms)
    if len(windows) < MIN_WINDOWS:
        return None
    raw = [s["stage"] for s in compute_window_scores(windows, sleep_start_ms)]
    stages = smooth_stages(raw)
    intervals = build_intervals(windows, stages)
    mins = {DEEP: 0, REM: 0, CORE: 0, AWAKE: 0}
    for st, a, b in intervals:
        mins[st] += duration_minutes(a, b)
    return dict(deepSleepMinutes=mins[DEEP], remSleepMinutes=mins[REM], coreSleepMinutes=mins[CORE],
                awakeMinutes=mins[AWAKE], stageIntervals=intervals, windows=windows,
                rawStages=raw, stages=stages)
