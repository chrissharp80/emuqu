"""Python port of ArtifactDetector.detectArtifacts (whole-series classifier).

Ported line by line from Emuqu/Sources/Analysis/ArtifactDetection.swift at
commit e028039 (Config defaults: window 50 = HRVConstants.Artifacts.windowSize,
ectopic 0.20, missed 0.50, extra 0.30, RR range 300...2000 ms).

Input: list of integer rr_ms. Output: list of dicts {isArtifact, type, confidence}.
"""
import bisect

WINDOW = 50
ECTOPIC, MISSED, EXTRA = 0.20, 0.50, 0.30
MIN_RR, MAX_RR = 300, 2000


def _median_sorted(s):
    mid = len(s) // 2
    if len(s) % 2 == 0:
        return (s[mid - 1] + s[mid]) / 2.0
    return s[mid]


def rolling_median(values, window=WINDOW):
    if not values:
        return []
    half = window // 2
    s = []
    for j in range(min(len(values), half + 1)):
        bisect.insort_left(s, values[j])
    out = [_median_sorted(s)]
    for i in range(1, len(values)):
        nr = i + half
        if nr < len(values):
            bisect.insort_left(s, values[nr])
        ol = i - half - 1
        if ol >= 0:
            k = bisect.bisect_left(s, values[ol])
            if k < len(s) and s[k] == values[ol]:
                del s[k]
        out.append(_median_sorted(s))
    return out


def _flag(is_art, typ, conf):
    return {"isArtifact": is_art, "type": typ, "confidence": conf}


CLEAN = {"isArtifact": False, "type": "none", "confidence": 0.0}


def classify(rr_ms, median):
    if not (MIN_RR <= rr_ms <= MAX_RR):
        return _flag(True, "technical", 1.0)
    rr = float(rr_ms)
    ratio = abs(rr - median) / median
    if rr < median * (1 - EXTRA):
        conf = min(1.0, ratio / EXTRA)
        if not rr >= median * 0.5:
            return _flag(True, "extra", conf)
        return _flag(ratio > ECTOPIC, "ectopic", conf)
    if rr > median * (1 + ECTOPIC):
        if not rr <= median * (1 + MISSED):
            return _flag(True, "missed", min(1.0, ratio / MISSED))
        return _flag(True, "ectopic", min(1.0, ratio / ECTOPIC))
    if ratio > ECTOPIC:
        return _flag(True, "ectopic", min(1.0, ratio / ECTOPIC))
    return dict(CLEAN)


def detect_artifacts(rr_ms_list):
    if not rr_ms_list:
        return []
    med = rolling_median([float(v) for v in rr_ms_list])
    return [classify(int(rr_ms_list[i]), med[i]) for i in range(len(rr_ms_list))]


def artifact_percentage(flags, start, end):
    s, e = max(0, start), min(len(flags), end)
    if e <= s:
        return 0.0
    w = flags[s:e]
    return sum(1 for f in w if f["isArtifact"]) / len(w) * 100.0
