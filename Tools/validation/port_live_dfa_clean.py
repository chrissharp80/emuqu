"""Python port of LiveDFAAnalyzer.cleanRRForDFA (Kubios-style trailing-median
correction with in-place linear interpolation) and its two thresholds.

Ported line by line from Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift at
commit e028039 (cleanRRForDFA, artifactMask, isArtifactBeat,
interpolatingArtifacts, lowConfidenceCorrectedFraction = 0.03,
maxCorrectedFraction = 0.06).

Returns (values, corrected_count).
"""

LOW_CONFIDENCE_CORRECTED_FRACTION = 0.03
MAX_CORRECTED_FRACTION = 0.06


def _is_artifact_beat(rr, recent):
    if rr < 300.0 or rr > 2000.0:
        return True
    if len(recent) < 3:
        return False
    s = sorted(recent)
    med = s[len(s) // 2]
    return abs(rr - med) / med > 0.20


def artifact_mask(rrs):
    mask = [False] * len(rrs)
    recent = []
    for i, rr in enumerate(rrs):
        mask[i] = _is_artifact_beat(rr, recent)
        if mask[i]:
            continue
        recent.append(rr)
        if len(recent) > 5:
            recent.pop(0)
    return mask


def _interpolate(rrs, mask):
    out = list(rrs)
    n = len(rrs)
    # nearest clean neighbours, precomputed (same result as the Swift scans)
    left = [None] * n
    last = None
    for i in range(n):
        left[i] = last
        if not mask[i]:
            last = i
    right = [None] * n
    nxt = None
    for i in range(n - 1, -1, -1):
        right[i] = nxt
        if not mask[i]:
            nxt = i
    for i in range(n):
        if not mask[i]:
            continue
        l, r = left[i], right[i]
        if l is not None and r is not None:
            out[i] = rrs[l] + (rrs[r] - rrs[l]) * float(i - l) / float(r - l)
        elif l is not None:
            out[i] = rrs[l]
        elif r is not None:
            out[i] = rrs[r]
    return out


def clean_rr_for_dfa(rrs):
    rrs = [float(v) for v in rrs]
    if len(rrs) < 8:
        return rrs, 0
    mask = artifact_mask(rrs)
    return _interpolate(rrs, mask), sum(mask)


def corrected_fraction(values, count):
    return 0.0 if not values else count / len(values)
