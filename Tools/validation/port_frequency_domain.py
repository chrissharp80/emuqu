"""Python port of FrequencyDomainAnalyzer (Welch PSD on 4 Hz cubic-spline RR).

Ported line by line from Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift
at commit e028039 (computeFromCleanPairs, computePSD, the Welch, VLF and
single-window paths, natural cubic spline resampling, linear detrend, band
integration). Band edges from HRVConstants.FrequencyBands
(Emuqu/Sources/Utilities/Constants.swift @ e028039).

Accelerate primitives mapped to numpy:
  vDSP_hann_windowD(.., vDSP_HANN_DENORM) -> w[n] = 0.5*(1 - cos(2*pi*n/N)), n=0..N-1
  vDSP_DFT_zop_CreateSetupD(.FORWARD) + ExecuteD on real input -> numpy.fft.fft (unscaled)
"""
import math
import numpy as np

FS = 4.0
VLF = (0.003, 0.04)   # half-open
LF = (0.04, 0.15)     # half-open
HF = (0.15, 0.4)      # closed
VLF_MIN_DURATION_MIN = 5.0 * 2
WELCH_SEG = 256
VLF_SEG = 1024
OVERLAP = 0.5


def hann_denorm(n):
    k = np.arange(n, dtype=float)
    return 0.5 * (1.0 - np.cos(2.0 * math.pi * k / n))


def linearly_detrended(segment):
    seg = np.asarray(segment, dtype=float)
    n = float(len(seg))
    if len(seg) <= 1:
        return np.zeros(len(seg))
    x_mean = (n - 1) / 2
    y_mean = seg.sum() / n
    dx = np.arange(len(seg), dtype=float) - x_mean
    sxy = float(np.sum(dx * (seg - y_mean)))
    sxx = float(np.sum(dx * dx))
    slope = sxy / sxx if sxx > 0 else 0.0
    return seg - y_mean - slope * dx


def _accumulate(segment, avg, window, norm, seg_len):
    half = seg_len // 2
    spec = np.fft.fft(np.asarray(segment) * window)
    p = spec.real ** 2 + spec.imag ** 2
    avg[0] += p[0] / norm
    avg[1:half] += p[1:half] * 2.0 / norm
    avg[half] += p[half] / norm


def _welch_psd(data, fs, seg_len, step, nseg):
    half = seg_len // 2
    w = hann_denorm(seg_len)
    wp = float(np.dot(w, w)) / seg_len
    norm = fs * seg_len * wp
    avg = np.zeros(half + 1)
    for s in range(nseg):
        _accumulate(linearly_detrended(data[s * step: s * step + seg_len]), avg, w, norm, seg_len)
    return avg / nseg


def _band_powers(psd, fs, fft_n):
    res = fs / fft_n
    vlf = lf = hf = 0.0
    for k in range(fft_n // 2 + 1):
        f = k * res
        p = psd[k] * res
        if VLF[0] <= f < VLF[1]:
            vlf += p
        elif LF[0] <= f < LF[1]:
            lf += p
        elif HF[0] <= f <= HF[1]:
            hf += p
    return vlf, lf, hf


def _metrics(vlf, lf, hf):
    return {"vlf": vlf, "lf": lf, "hf": hf,
            "lfHfRatio": (lf / hf) if hf > 0 else None,
            "totalPower": (vlf or 0.0) + lf + hf}


def _vlf_power(data, fs):
    seg = VLF_SEG
    step = int(seg * (1.0 - OVERLAP))
    if len(data) < seg:
        return None
    psd = _welch_psd(data, fs, seg, step, (len(data) - seg) // step + 1)
    return _band_powers(psd, fs, seg)[0]


def _single_window(signal, fs, usable_min):
    n = len(signal)
    fft_n = 1 << int(math.ceil(math.log2(float(n))))
    w = hann_denorm(n)
    padded = np.zeros(fft_n)
    padded[:n] = linearly_detrended(signal) * w
    energy = float(np.dot(w, w))
    if not energy > 0:
        return {"vlf": None, "lf": 0.0, "hf": 0.0, "lfHfRatio": None, "totalPower": 0.0}
    psd = np.zeros(fft_n // 2 + 1)
    _accumulate(padded, psd, np.ones(fft_n), fs * energy, fft_n)
    vlf, lf, hf = _band_powers(psd, fs, fft_n)
    wmin = usable_min if usable_min is not None else n / fs / 60.0
    ok = wmin >= VLF_MIN_DURATION_MIN
    return {"vlf": vlf if ok else None, "lf": lf, "hf": hf,
            "lfHfRatio": (lf / hf) if hf > 0 else None,
            "totalPower": (vlf if ok else 0.0) + lf + hf}


def compute_psd(signal, fs=FS, segment_length=None, usable_window_min=None):
    sig = np.asarray(signal, dtype=float)
    mean = sig.sum() / len(sig)
    data = sig - mean
    want = segment_length if segment_length is not None else WELCH_SEG
    seg_len = 1 << int(math.floor(math.log2(float(want))))
    step = int(seg_len * (1.0 - OVERLAP))
    if not (len(data) >= want and (len(data) - seg_len) // step + 1 >= 1):
        # welchFallback: a DFT setup always exists for a power of two here.
        return _single_window(data, fs, usable_window_min)
    psd = _welch_psd(data, fs, seg_len, step, (len(data) - seg_len) // step + 1)
    _, lf, hf = _band_powers(psd, fs, seg_len)
    wmin = usable_window_min if usable_window_min is not None else len(data) / fs / 60.0
    return _metrics(_vlf_power(data, fs) if wmin >= VLF_MIN_DURATION_MIN else None, lf, hf)


def _spline_resample(t, v, fs, count, t_start):
    n = len(t)
    if n < 2:
        return np.full(count, v[0] if v else 0.0)
    if n == 2:
        out = np.zeros(count)
        for i in range(count):
            tt = t_start + i / fs
            frac = (tt - t[0]) / (t[1] - t[0]) if (t[1] - t[0]) > 0 else 0
            out[i] = v[0] + frac * (v[1] - v[0])
        return out
    h = [0.0] * (n - 1)
    d = [0.0] * (n - 1)
    for i in range(n - 1):
        h[i] = t[i + 1] - t[i]
        d[i] = (v[i + 1] - v[i]) / h[i] if h[i] > 0 else 0.0
    m = [0.0] * n
    cp = [0.0] * (n - 2)
    dp = [0.0] * (n - 2)
    b0 = 2.0 * (h[0] + h[1])
    cp[0] = h[1] / b0
    dp[0] = 6.0 * (d[1] - d[0]) / b0
    for i in range(1, n - 2):
        b = 2.0 * (h[i] + h[i + 1]) - h[i] * cp[i - 1]
        cp[i] = h[i + 1] / b
        dp[i] = (6.0 * (d[i + 1] - d[i]) - h[i] * dp[i - 1]) / b
    m[n - 2] = dp[n - 3]
    for i in range(n - 3, 0, -1):
        m[i] = dp[i - 1] - cp[i - 1] * m[i + 1]
    out = np.zeros(count)
    seg = 0
    for i in range(count):
        tt = t_start + i / fs
        while seg < n - 2 and t[seg + 1] < tt:
            seg += 1
        s = max(0, min(n - 2, seg))
        if h[s] > 0:
            hi = h[s]
            c = m[s] / 2.0
            dd = (m[s + 1] - m[s]) / (6.0 * hi)
            b = d[s] - hi * (2.0 * m[s] + m[s + 1]) / 6.0
            dt = tt - t[s]
            out[i] = v[s] + dt * (b + dt * (c + dt * dd))
        else:
            out[i] = v[s]
    return out


def compute_from_clean_pairs(times, rr_values):
    """FrequencyDomainAnalyzer.computeFromCleanPairs(times: s, rrValues: ms)."""
    if len(times) < 60:
        return None
    t0, t1 = float(times[0]), float(times[-1])
    dur = t1 - t0
    if not dur > 0:
        return None
    count = int(math.floor(dur * FS + 0.5)) + 1  # Swift round(): half away from zero
    if count < 64:
        return None
    res = _spline_resample([float(x) for x in times], [float(x) for x in rr_values], FS, count, t0)
    return compute_psd(res, FS, usable_window_min=dur / 60.0)
