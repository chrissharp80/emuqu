"""Python port of DFAAnalyzer.compute (DFA alpha1 / alpha2).

Ported line by line from Emuqu/Sources/Analysis/DFAAnalysis.swift at commit
e028039, plus the helper it delegates to, Statistics.linearRegression
(Emuqu/Sources/Utilities/Statistics.swift @ e028039), and the constants in
HRVConstants.DFA / HRVConstants.MinimumBeats (Emuqu/Sources/Utilities/Constants.swift).

Known numeric differences from the Swift build: vDSP_meanvD may sum in a
different order than a Python loop (last-bit differences only).
"""
import math

ALPHA1_MIN, ALPHA1_MAX = 4, 16
ALPHA2_MIN, ALPHA2_MAX = 16, 64
MIN_BEATS_FOR_DFA_ALPHA2 = 256  # HRVConstants.MinimumBeats.forDFA


def _swift_round(x):
    # Swift Double.rounded() / round(): half away from zero.
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def linear_regression(x, y):
    """Statistics.linearRegression -> (slope, intercept, r2) or None."""
    n = len(x)
    if n < 2 or n != len(y):
        return None
    sx = sy = sxy = sx2 = sy2 = 0.0
    for i in range(n):
        sx += x[i]
        sy += y[i]
        sxy += x[i] * y[i]
        sx2 += x[i] * x[i]
        sy2 += y[i] * y[i]
    nd = float(n)
    denom = nd * sx2 - sx * sx
    if not abs(denom) > 1e-10:
        return None
    slope = (nd * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / nd
    ss_total = sy2 - (sy * sy) / nd
    if not ss_total > 0:
        r2 = 0.0
    else:
        ss_res = 0.0
        for i in range(n):
            r = y[i] - (intercept + slope * x[i])
            ss_res += r * r
        r2 = max(0.0, min(1.0, 1.0 - ss_res / ss_total))
    return slope, intercept, r2


def _integrated_series(rr):
    mean = sum(rr) / len(rr)
    out = []
    c = 0.0
    for v in rr:
        c += v - mean
        out.append(c)
    return out


def _log_spaced_box_sizes(lower, upper):
    if upper < lower:
        return []
    ratio = math.pow(2.0, 1.0 / 8.0)
    sizes = []
    current = float(lower)
    while _swift_round(current) <= upper:
        r = _swift_round(current)
        if not sizes or sizes[-1] != r:
            sizes.append(r)
        current *= ratio
    if sizes and sizes[-1] != upper:
        sizes.append(upper)
    return sizes


def _least_squares_line(seg):
    count = float(len(seg))
    sx = sy = sxy = sxx = 0.0
    for i, v in enumerate(seg):
        x = float(i)
        sx += x
        sy += v
        sxy += x * v
        sxx += x * x
    den = count * sxx - sx * sx
    if den == 0:
        return None
    slope = (count * sxy - sx * sy) / den
    return slope, (sy - slope * sx) / count


def _detrended_sum_of_squares(seg):
    line = _least_squares_line(seg) if len(seg) >= 2 else None
    if line is None:
        return sum(v * v for v in seg)
    slope, intercept = line
    s = 0.0
    for i, v in enumerate(seg):
        r = v - (intercept + slope * float(i))
        s += r * r
    return s


def _fluctuation(integrated, box):
    nb = len(integrated) // box
    if nb <= 0:
        return 0.0
    tot = 0.0
    for b in range(nb):
        st = b * box
        tot += _detrended_sum_of_squares(integrated[st:st + box])
    return math.sqrt(tot / float(nb * box))


def _log_log_regression(sizes, fl):
    if len(sizes) < 2:
        return 0.0, 0.0
    lx = [math.log(float(s)) for s in sizes]
    ly = [math.log(f) if f > 0 else -10.0 for f in fl]
    res = linear_regression(lx, ly)
    if res is None:
        return 0.0, 0.0
    return res[0], res[2]


def compute(rr, alpha1_range=(ALPHA1_MIN, ALPHA1_MAX), alpha2_range=(ALPHA2_MIN, ALPHA2_MAX)):
    """DFAAnalyzer.compute. Returns dict(alpha1, alpha2, alpha1R2, alpha2R2) or None."""
    rr = [float(v) for v in rr]
    if len(rr) < ALPHA2_MAX:
        return None
    integ = _integrated_series(rr)
    max_box = len(rr) // 4
    a1s = _log_spaced_box_sizes(alpha1_range[0], min(alpha1_range[1], max_box))
    a2s = _log_spaced_box_sizes(alpha2_range[0], min(alpha2_range[1], max_box))
    if len(a1s) < 3:
        return None
    a1f = [_fluctuation(integ, s) for s in a1s]
    alpha1, r2 = _log_log_regression(a1s, a1f)
    alpha2 = alpha2r2 = None
    if len(a2s) >= 3 and len(rr) >= MIN_BEATS_FOR_DFA_ALPHA2:
        a2f = [_fluctuation(integ, s) for s in a2s]
        alpha2, alpha2r2 = _log_log_regression(a2s, a2f)
    return {"alpha1": alpha1, "alpha2": alpha2, "alpha1R2": r2, "alpha2R2": alpha2r2}
