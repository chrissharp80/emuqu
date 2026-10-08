"""Reproduce the Emuqu unit-test expectations (EmuquTests/* @ e028039) against
the Python ports. Each case names the Swift test it mirrors. Run:
    python3 -I test_ports.py
Prints PASS/FAIL per case and a summary; exit code 1 on any failure.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import port_dfa
import port_frequency_domain as fd
import port_sleep_stage_classifier as sc
import port_artifact_detection as ad
import port_live_dfa_clean as lc
import port_time_domain as td
from swift_rng import SplitMix64, deterministic_offset

RESULTS = []


def case(suite, name):
    def deco(fn):
        def run():
            try:
                ok, detail = fn()
            except Exception as e:  # noqa: BLE001
                ok, detail = False, f"exception {e!r}"
            RESULTS.append((suite, name, ok, detail))
        run.__name__ = name
        CASES.append(run)
        return fn
    return deco


CASES = []


def approx(a, b, tol):
    return a is not None and abs(a - b) <= tol


# ---------------- DFAAnalysisTests ----------------
def rr_sin(count, mean=850, var=50):
    return [mean + math.sin(i * 0.3) * var for i in range(count)]


def white_d1(count):
    g = SplitMix64(0xD1)
    return [850 + g.double_closed(-50, 50) for _ in range(count)]


def correlated_d2(count):
    g = SplitMix64(0xD2)
    out = []
    for i in range(count):
        out.append(850 + math.sin(i * 0.5) * 20 + math.sin(i * 0.1) * 30 + math.sin(i * 0.02) * 15
                   + g.double_closed(-5, 5))
    return out


S = "DFAAnalysisTests"


@case(S, "testDFARequiresMinimumSamples")
def _():
    return port_dfa.compute(rr_sin(50)) is None, ""


@case(S, "testDFAWithMinimumSamples")
def _():
    return port_dfa.compute(rr_sin(64)) is not None, ""


@case(S, "testDFAAlpha1InPhysiologicalRange")
def _():
    a = port_dfa.compute(correlated_d2(300))["alpha1"]
    return 0.3 < a < 2.0, f"a1={a:.4f}"


@case(S, "testDFAReturnsValidR2")
def _():
    r = port_dfa.compute(correlated_d2(200))["alpha1R2"]
    return 0 <= r <= 1, f"R2={r:.4f}"


@case(S, "testAlpha2RequiresSufficientData")
def _():
    r = port_dfa.compute(rr_sin(100))
    return r is not None and r["alpha2"] is None, ""


@case(S, "testAlpha2WithSufficientData")
def _():
    r = port_dfa.compute(correlated_d2(500))
    return r["alpha2"] is not None and r["alpha2R2"] is not None, f"a2={r['alpha2']:.4f}"


@case(S, "testAlpha2InReasonableRange")
def _():
    a2 = port_dfa.compute(correlated_d2(500))["alpha2"]
    return 0.2 < a2 < 2.0, f"a2={a2:.4f}"


@case(S, "testWhiteNoiseProducesLowAlpha")
def _():
    # Swift re-seeds 0xD1 per call, so all 5 series are identical.
    a = [port_dfa.compute(white_d1(300))["alpha1"] for _ in range(5)]
    m = sum(a) / len(a)
    return m < 0.9, f"mean a1={m:.4f}"


@case(S, "testCorrelatedSignalProducesModerateAlpha")
def _():
    a = port_dfa.compute(correlated_d2(300))["alpha1"]
    return 0.4 < a < 2.0, f"a1={a:.4f}"


@case(S, "testCustomAlpha1Range")
def _():
    rr = correlated_d2(200)
    a = port_dfa.compute(rr)["alpha1"]
    b = port_dfa.compute(rr, alpha1_range=(5, 12))["alpha1"]
    return abs(a - b) > 0.01, f"{a:.4f} vs {b:.4f}"


@case(S, "testDFAIsReproducible")
def _():
    rr = correlated_d2(300)
    return port_dfa.compute(rr)["alpha1"] == port_dfa.compute(rr)["alpha1"], ""


@case(S, "testDFAWithConstantRR")
def _():
    r = port_dfa.compute([850.0] * 100)
    return r is None or math.isfinite(r["alpha1"]), "" if r is None else f"a1={r['alpha1']}"


@case(S, "testDFAWithLargeDataset")
def _():
    r = port_dfa.compute(correlated_d2(7200))
    return r is not None and r["alpha2"] is not None, ""


@case(S, "testDFAWithHighVariability")
def _():
    r = port_dfa.compute([600 + math.sin(i * 0.2) * 300 for i in range(300)])
    return r is not None and not math.isnan(r["alpha1"]), ""


@case(S, "testGoodFitProducesHighR2")
def _():
    r = port_dfa.compute(correlated_d2(500))["alpha1R2"]
    return r > 0.7, f"R2={r:.4f}"


# ---------------- DFAReferenceValidationTests ----------------
N_REF = 4096


def gaussian(count, seed):
    g = SplitMix64(seed)
    out = []
    while len(out) < count:
        u1 = g.double_closed(1e-12, 1)
        u2 = g.double_closed(0, 1)
        rad = math.sqrt(-2 * math.log(u1))
        out.append(rad * math.cos(2 * math.pi * u2))
        if len(out) < count:
            out.append(rad * math.sin(2 * math.pi * u2))
    return out


def uncorrelated():
    return [850 + x * 40 for x in gaussian(N_REF, 0x5EED0001)]


def brownian():
    tot = 0.0
    walk = []
    for s in gaussian(N_REF, 0x5EED0002):
        tot += s
        walk.append(tot)
    m = sum(walk) / len(walk)
    return [850 + (w - m) * 2 for w in walk]


def pink():
    octs = 12
    g = SplitMix64(0x5EED0003)
    src = [g.double_closed(-1, 1) for _ in range(octs)]
    out = []
    for i in range(N_REF):
        for o in range(octs):
            if i % (1 << o) == 0:
                src[o] = g.double_closed(-1, 1)
        out.append(850 + sum(src) * 12)
    return out


S = "DFAReferenceValidationTests"
_REF = {}


def ref(name):
    if name not in _REF:
        _REF[name] = port_dfa.compute({"w": uncorrelated, "p": pink, "b": brownian}[name]())
    return _REF[name]


@case(S, "testUncorrelatedNoiseScalesAtOneHalf (+ quoted measured a1=0.581)")
def _():
    r = ref("w")
    ok = approx(r["alpha1"], 0.5, 0.15) and approx(r["alpha2"], 0.5, 0.10)
    return ok, f"a1={r['alpha1']:.4f} (test comment quotes 0.581) a2={r['alpha2']:.4f}"


@case(S, "testPinkNoiseScalesAtOne (+ quoted measured a1=1.088)")
def _():
    r = ref("p")
    ok = approx(r["alpha1"], 1.0, 0.15) and approx(r["alpha2"], 1.0, 0.15)
    return ok, f"a1={r['alpha1']:.4f} (test comment quotes 1.088) a2={r['alpha2']:.4f}"


@case(S, "testBrownianMotionScalesAtThreeHalves (+ quoted measured a1=1.526)")
def _():
    r = ref("b")
    ok = approx(r["alpha1"], 1.5, 0.15) and approx(r["alpha2"], 1.5, 0.10)
    return ok, f"a1={r['alpha1']:.4f} (test comment quotes 1.526) a2={r['alpha2']:.4f}"


@case(S, "quoted measured values 0.581/1.088/1.526 reproduced to 3 dp")
def _():
    got = [round(ref(k)["alpha1"], 3) for k in "wpb"]
    return got == [0.581, 1.088, 1.526], f"got {got}"


@case(S, "testExponentsSeparateTheThreeProcesses")
def _():
    w, p, b = (ref(k)["alpha1"] for k in "wpb")
    return w + 0.2 < p and p + 0.2 < b, ""


@case(S, "testExponentIsUnchangedByAConstantOffset")
def _():
    s = pink()
    return approx(port_dfa.compute(s)["alpha1"], port_dfa.compute([x + 250 for x in s])["alpha1"], 1e-9), ""


@case(S, "testExponentIsUnchangedByAmplitudeScaling")
def _():
    s = pink()
    return approx(port_dfa.compute(s)["alpha1"], port_dfa.compute([850 + (x - 850) * 3.5 for x in s])["alpha1"], 1e-9), ""


@case(S, "testAPureLinearRampProducesAFiniteExponent")
def _():
    r = port_dfa.compute([800 + i * 0.05 for i in range(N_REF)])
    return r is not None and math.isfinite(r["alpha1"]), f"a1={r['alpha1']}"


@case(S, "testTheSameSeriesGivesTheSameExponent")
def _():
    s = pink()
    a, b = port_dfa.compute(s), port_dfa.compute(s)
    return a["alpha1"] == b["alpha1"] and a["alpha2"] == b["alpha2"], ""


# ---------------- FrequencyDomainTests ----------------
S = "FrequencyDomainTests"


def sine(n, f, a, fs=4.0, dc=0.0):
    return [dc + a * math.sin(2 * math.pi * f * i / fs) for i in range(n)]


@case(S, "testSpectralWith025HzSine")
def _():
    m = fd.compute_psd(sine(1200, 0.25, 50))
    tot = m["hf"] + m["lf"] + (m["vlf"] or 0)
    ok = m["hf"] > m["lf"] * 10 and m["hf"] / tot > 0.9 and approx(m["hf"], 1250, 1250 * 0.25)
    return ok, f"hf={m['hf']:.2f} lf={m['lf']:.4f}"


@case(S, "testSpectralWith01HzSine")
def _():
    m = fd.compute_psd(sine(1200, 0.1, 50))
    tot = m["hf"] + m["lf"] + (m["vlf"] or 0)
    return m["lf"] > m["hf"] * 10 and m["lf"] / tot > 0.9, f"lf={m['lf']:.2f}"


@case(S, "testMixedFrequencySignal")
def _():
    s = [30 * math.sin(2 * math.pi * 0.1 * i / 4) + 40 * math.sin(2 * math.pi * 0.25 * i / 4) for i in range(1200)]
    m = fd.compute_psd(s)
    ok = approx(m["lf"], 450, 135) and approx(m["hf"], 800, 240) and approx(m["lfHfRatio"], 450 / 800, 0.2)
    return ok, f"lf={m['lf']:.2f} hf={m['hf']:.2f} ratio={m['lfHfRatio']:.3f}"


@case(S, "testVLFGatingShortWindow")
def _():
    return fd.compute_psd(sine(1200, 0.02, 50), usable_window_min=5.0)["vlf"] is None, ""


@case(S, "testVLFGatingLongWindow")
def _():
    v = fd.compute_psd(sine(2400, 0.02, 50), usable_window_min=10.0)["vlf"]
    return v is not None and v > 0, f"vlf={v}"


@case(S, "testVLFPowerMatchesASineInTheBand")
def _():
    v = fd.compute_psd(sine(2400, 0.02, 50), usable_window_min=10.0)["vlf"]
    return approx(v, 1250, 312.5), f"vlf={v:.2f}"


@case(S, "testLinearDriftDoesNotReadAsVLF")
def _():
    n = 2400
    s = [50 * math.sin(2 * math.pi * 0.25 * i / 4) + 200.0 * i / n for i in range(n)]
    m = fd.compute_psd(s, usable_window_min=10.0)
    return m["vlf"] < m["hf"] * 0.01 and approx(m["hf"], 1250, 312.5), f"vlf={m['vlf']:.4f} hf={m['hf']:.2f}"


@case(S, "testShortWindowPowerIsScaledToTheSignalNotThePadding")
def _():
    m = fd.compute_psd(sine(140, 0.25, 50))
    return approx(m["hf"], 1250, 125), f"hf={m['hf']:.2f}"


@case(S, "testLinearDetrendRemovesOffsetAndSlope")
def _():
    return all(abs(v) < 1e-9 for v in fd.linearly_detrended([3 + 0.5 * i for i in range(64)])), ""


@case(S, "testDCComponentRemoval")
def _():
    m = fd.compute_psd(sine(1200, 0.25, 50, dc=1000))
    return approx(m["hf"], 1250, 312.5), f"hf={m['hf']:.2f}"


@case(S, "testDFTCaching")
def _():
    return all(fd.compute_psd(sine(n, 0.25, 50))["totalPower"] > 0 for n in [256, 512, 1024, 512, 256]), ""


@case(S, "testSmallAmplitudes")
def _():
    h = fd.compute_psd(sine(1200, 0.25, 0.001))["hf"]
    return h > 0 and math.isfinite(h), ""


@case(S, "testZeroSignal")
def _():
    m = fd.compute_psd([0.0] * 1024)
    return abs(m["totalPower"]) < 1e-10 and m["lfHfRatio"] is None, ""


@case(S, "testVLFIsNilBelowOneLongSegment")
def _():
    m = fd.compute_psd(sine(1000, 0.25, 50), usable_window_min=10.0)
    return m["vlf"] is None and m["hf"] > 0, ""


@case(S, "testSingleWindowPathGatesVLFOnTheUsableWindow")
def _():
    s = sine(200, 0.25, 50)
    lo, sh = fd.compute_psd(s, usable_window_min=10.0), fd.compute_psd(s, usable_window_min=5.0)
    ok = lo["vlf"] is not None and math.isfinite(lo["vlf"]) and lo["vlf"] >= 0 and sh["vlf"] is None and lo["hf"] > lo["lf"]
    return ok, ""


@case(S, "testComputeFromCleanPairsPlacesRespiratoryModulationInHF")
def _():
    t, ts, rr = 0.0, [], []
    for _ in range(400):
        v = 800 + 40 * math.sin(2 * math.pi * 0.25 * t)
        t += v / 1000
        ts.append(t)
        rr.append(v)
    m = fd.compute_from_clean_pairs(ts, rr)
    return m["hf"] > m["lf"], f"hf={m['hf']:.2f} lf={m['lf']:.2f}"


@case(S, "testComputeFromCleanPairsRejectsTooLittleData")
def _():
    few = [i * 0.8 for i in range(59)]
    still = [5.0] * 100
    return fd.compute_from_clean_pairs(few, [800] * 59) is None and fd.compute_from_clean_pairs(still, [800] * 100) is None, ""


@case(S, "(extra) Welch port vs scipy.signal.welch, same settings")
def _():
    import numpy as np
    from scipy.signal import welch
    rng = np.random.default_rng(1)
    x = rng.normal(0, 30, 1200) + sine_np(1200)
    m = fd.compute_psd(list(x))
    f, p = welch(x - x.mean(), fs=4.0, window="hann", nperseg=256, noverlap=128, detrend="linear", scaling="density")
    res = f[1] - f[0]
    lf = float(np.sum(p[(f >= 0.04) & (f < 0.15)]) * res)
    hf = float(np.sum(p[(f >= 0.15) & (f <= 0.4)]) * res)
    return approx(m["lf"], lf, 1e-6 * lf) and approx(m["hf"], hf, 1e-6 * hf), f"port lf/hf={m['lf']:.3f}/{m['hf']:.3f} scipy={lf:.3f}/{hf:.3f}"


def sine_np(n):
    import numpy as np
    return 40 * np.sin(2 * np.pi * 0.25 * np.arange(n) / 4)


# ---------------- HRVSleepStageClassifierTests ----------------
S = "HRVSleepStageClassifierTests"


def sleep_night(hours=7.0):
    dur = int(hours * 3600 * 1000)
    pts, cur, bi = [], 0, 0
    cyc = 90 * 60 * 1000
    for c in range(max(1, dur // cyc)):
        cs = c * cyc
        ce = min(cs + cyc, dur)
        cd = ce - cs
        deep_end = cs + int(cd * (0.30 if c < 2 else 0.15))
        rem_start = ce - int(cd * (0.15 if c < 2 else 0.30))
        awake_end = min(cs + 2 * 60 * 1000, ce)
        while cur < ce:
            if cur < awake_end and c > 0:
                rr = 800 + deterministic_offset(bi, -40, 40)
            elif cur < deep_end:
                rr = 1154 + deterministic_offset(bi, -15, 15)
            elif cur >= rem_start:
                rr = 923 + deterministic_offset(bi, -60, 60)
            else:
                rr = 1000 + deterministic_offset(bi, -30, 30)
            rr = max(200, min(2000, rr))
            pts.append((cur, rr))
            cur += rr
            bi += 1
    return pts


def uniform(hr, minutes):
    rr = int(60000.0 / hr)
    pts, t = [], 0
    while t < minutes * 60000:
        pts.append((t, rr))
        t += rr
    return pts


_NIGHT = {}


def night_result(h):
    if h not in _NIGHT:
        p = sleep_night(h)
        _NIGHT[h] = sc.classify(p, 0, p[-1][0])
    return _NIGHT[h]


@case(S, "testClassifyProducesAllStages")
def _():
    p = sleep_night(7.0)
    r = night_result(7.0)
    tot = r["deepSleepMinutes"] + r["remSleepMinutes"] + r["coreSleepMinutes"] + r["awakeMinutes"]
    exp = int(p[-1][0] / 60000.0)
    ok = r["deepSleepMinutes"] > 0 and r["remSleepMinutes"] > 0 and r["coreSleepMinutes"] > 0 and abs(tot - exp) <= 15
    return ok, f"deep={r['deepSleepMinutes']} rem={r['remSleepMinutes']} core={r['coreSleepMinutes']} awake={r['awakeMinutes']} total={tot} exp={exp}"


@case(S, "testClassifyDeepSleepProportions")
def _():
    r = night_result(8.0)
    ts = r["deepSleepMinutes"] + r["remSleepMinutes"] + r["coreSleepMinutes"]
    d = r["deepSleepMinutes"] / ts * 100
    return 5 < d < 45, f"deep%={d:.1f}"


@case(S, "testClassifyREMNotInFirstHour")
def _():
    r = night_result(7.0)
    return not any(s == "rem" and a < 3600000 for s, a, b in r["stageIntervals"]), ""


@case(S, "testClassifyInsufficientDataReturnsNil")
def _():
    p = uniform(60, 10)
    return sc.classify(p, 0, p[-1][0]) is None, ""


@case(S, "testClassifyEmptyDataReturnsNil")
def _():
    return sc.classify([], 0, 100000) is None, ""


@case(S, "testClassifyInvertedBoundariesReturnsNil")
def _():
    return sc.classify(uniform(60, 120), 100000, 50000) is None, ""


@case(S, "testStageIntervalsAreContinuous")
def _():
    p = sleep_night(6.0)
    r = sc.classify(p, 0, p[-1][0])
    iv = r["stageIntervals"]
    return all(abs(iv[i - 1][2] - iv[i][1]) <= 1000 for i in range(1, len(iv))), f"{len(iv)} intervals"


@case(S, "testAdjacentIntervalsHaveDifferentStages")
def _():
    iv = night_result(7.0)["stageIntervals"]
    return all(iv[i - 1][0] != iv[i][0] for i in range(1, len(iv))), ""


@case(S, "testSmoothingRemovesSingleWindowBlips")
def _():
    return sc.smooth_stages(["deep", "deep", "core", "deep", "deep"]) == ["deep"] * 5, ""


@case(S, "testSmoothingPreservesBriefAwakenings")
def _():
    return sc.smooth_stages(["deep", "deep", "awake", "deep", "deep"])[2] == "awake", ""


@case(S, "testSmoothingPreservesRealTransitions")
def _():
    s = ["deep", "deep", "core", "core", "rem", "rem"]
    return sc.smooth_stages(s) == s, ""


@case(S, "testSmoothingShortInput")
def _():
    return sc.smooth_stages(["deep", "core"]) == ["deep", "core"], ""


@case(S, "testComputeRanksOrdering")
def _():
    r = sc.compute_ranks([50.0, 30.0, 70.0, 10.0, 90.0])
    return all(abs(a - b) <= 0.01 for a, b in zip(r, [0.5, 0.25, 0.75, 0.0, 1.0])), ""


@case(S, "testComputeRanksGivesTiesTheirAverageRank")
def _():
    a = sc.compute_ranks([1.0] * 4)
    m = sc.compute_ranks([3.0, 1.0, 3.0, 2.0, 3.0])
    return a == [0.5] * 4 and approx(m[1], 0, 1e-9) and approx(m[3], 0.25, 1e-9) and approx(m[0], 0.75, 1e-9) and approx(m[4], 0.75, 1e-9), ""


@case(S, "testComputeRanksSingleElement")
def _():
    return sc.compute_ranks([42.0]) == [0.5], ""


@case(S, "testDFARankDirectionLowAlpha1IsDeepLike")
def _():
    r = sc.compute_ranks([0.55, 0.85, 1.10, 0.95, 1.25])
    return approx(r[0], 0, 0.01) and approx(r[4], 1, 0.01), ""


@case(S, "testCoreSleepDominatesWithUniformPhysiology")
def _():
    pts, t, bi = [], 0, 0
    dur = 7 * 3600 * 1000
    while t < dur:
        rr = 1250 + deterministic_offset(bi, -20, 20)
        pts.append((t, rr))
        t += rr
        bi += 1
    r = sc.classify(pts, 0, dur)
    ts = r["deepSleepMinutes"] + r["remSleepMinutes"] + r["coreSleepMinutes"]
    c, d = r["coreSleepMinutes"] / ts * 100, r["deepSleepMinutes"] / ts * 100
    return c > 15 and d < 80, f"core%={c:.1f} deep%={d:.1f}"


@case(S, "testClassifyREMProportionWithinNorms")
def _():
    r = night_result(8.0)
    ts = r["deepSleepMinutes"] + r["remSleepMinutes"] + r["coreSleepMinutes"]
    p = r["remSleepMinutes"] / ts * 100
    return 5 < p < 35, f"rem%={p:.1f}"


@case(S, "testBuildIntervalsNoWindows")
def _():
    return sc.build_intervals([], []) == [], ""


def fw(i):
    return dict(start_ms=i * 300000, end_ms=i * 300000 + 300000, midpoint_ms=i * 300000 + 150000)


@case(S, "testBuildIntervalsMergesAdjacentSameStage")
def _():
    iv = sc.build_intervals([fw(i) for i in range(4)], ["deep", "deep", "core", "core"])
    return len(iv) == 2 and iv[0][0] == "deep" and iv[1][0] == "core", ""


@case(S, "testBuildIntervalsEndsAtADropoutGap")
def _():
    ws = [fw(i) for i in [0, 1, 20, 21]]
    iv = sc.build_intervals(ws, ["core"] * 4)
    return len(iv) == 2 and iv[0][2] == ws[1]["end_ms"] and iv[1][1] == ws[2]["start_ms"], ""


@case(S, "testBuildFeatureWindowsRMSSDParityExact")
def _():
    pts, t = [], 0
    for _ in range(3):
        for rr in [1000, 1050, 950, 1020, 980]:
            pts.append((t, rr))
            t += rr
    w = sc.build_feature_windows(pts, 0, 300000)
    return len(w) == 1 and approx(w[0]["rmssd"], 64.25396041156863, 1e-6), f"rmssd={w[0]['rmssd']!r}"


@case(S, "testSDNNUsesPopulationVarianceNotTheSampleForm")
def _():
    r = sc.window_variability([900, 950, 1050, 1100], 1000)
    return approx(r[1], 79.0569, 0.001), ""


@case(S, "testSDNNMatchesThePopulationFormulaForEveryWindowSize")
def _():
    for c in range(2, 13):
        rr = [1000.0 + i * 13.0 for i in range(c)]
        m = sum(rr) / len(rr)
        pop = math.sqrt(sum((v - m) ** 2 for v in rr) / len(rr))
        if not approx(sc.window_variability(rr, m)[1], pop, 1e-9):
            return False, f"count {c}"
    return True, ""


@case(S, "testRMSSDIsTheRootMeanSquareOfSuccessiveDifferences")
def _():
    return approx(sc.window_variability([900, 1000, 1100, 1200], 1050)[0], 100, 0.001), ""


@case(S, "testCoefficientOfVariationIsSDNNOverTheMean")
def _():
    r = sc.window_variability([900, 950, 1050, 1100], 1000)
    return approx(r[2], r[1] / 1000, 1e-9), ""


@case(S, "testTooFewBeatsYieldsZeroesRatherThanTrapping")
def _():
    return sc.window_variability([], 1000) == (0, 0, 0) and sc.window_variability([1000.0], 1000) == (0, 0, 0), ""


@case(S, "testAZeroMeanYieldsZeroCoefficientRatherThanNaN")
def _():
    return sc.window_variability([0, 0, 0], 0)[2] == 0, ""


# ---------------- ArtifactDetectionTests ----------------
S = "ArtifactDetectionTests"


@case(S, "testCleanBeatsDetection (Int.random: 200 seeds)")
def _():
    worst = 100.0
    for seed in range(200):
        rnd = random.Random(seed)
        fl = ad.detect_artifacts([800 + rnd.randint(-30, 30) for _ in range(100)])
        worst = min(worst, sum(1 for f in fl if not f["isArtifact"]))
    return worst > 95, f"min clean% over seeds={worst}"


@case(S, "testEctopicDetection")
def _():
    rr = []
    for i in range(50):
        rr += [500, 1100] if i == 25 else [800]
    fl = ad.detect_artifacts(rr)
    fs = fl_ = False
    ok = True
    for v, f in zip(rr, fl):
        if v == 500 and f["isArtifact"]:
            fs = True
            ok &= f["type"] in ("ectopic", "extra")
        if v == 1100 and f["isArtifact"]:
            fl_ = True
            ok &= f["type"] in ("ectopic", "missed")
    return ok and fs and fl_, ""


@case(S, "testTechnicalArtifacts")
def _():
    fl = ad.detect_artifacts([800, 150, 800, 2500, 800])
    return fl[1]["type"] == "technical" and fl[3]["type"] == "technical", ""


@case(S, "testMissedBeatDetection")
def _():
    fl = ad.detect_artifacts([1500 if i == 10 else 800 for i in range(20)])
    return fl[10]["isArtifact"] and fl[10]["type"] == "missed", ""


@case(S, "testArtifactPercentage")
def _():
    fl = ad.detect_artifacts([800] * 100)
    for i in range(10):
        fl[i] = {"isArtifact": True, "type": "ectopic", "confidence": 1.0}
    return approx(ad.artifact_percentage(fl, 0, 100), 10.0, 0.1), ""


@case(S, "testArtifactPercentageWithBounds")
def _():
    fl = [dict(ad.CLEAN) for _ in range(100)]
    for i in range(20, 30):
        fl[i] = {"isArtifact": True, "type": "ectopic", "confidence": 1.0}
    return approx(ad.artifact_percentage(fl, 20, 30), 100, 0.1) and approx(ad.artifact_percentage(fl, 0, 20), 0, 0.1), ""


@case(S, "testSearchClampToZero")
def _():
    return ad.artifact_percentage([dict(ad.CLEAN)] * 50, -10, 20) == 0.0, ""


@case(S, "testEdgeEffects")
def _():
    fl = ad.detect_artifacts([800] * 100)
    return not fl[0]["isArtifact"] and not fl[-1]["isArtifact"], ""


# ---------------- LiveDFAAnalyzerTests (cleanRRForDFA) ----------------
S = "LiveDFAAnalyzerTests"


def steady(n, rr=1000.0):
    return [rr] * n


def cl(rrs):
    return lc.clean_rr_for_dfa(rrs)


def _mod(n, changes, rr=1000.0):
    s = steady(n, rr)
    for k, v in changes.items():
        s[k] = v
    return s


@case(S, "testBeatsFasterThan200BPMAreReplaced")
def _():
    v = cl(_mod(20, {10: 250}))[0]
    return v[10] != 250 and approx(v[10], 1000, 1), ""


@case(S, "testBeatsSlowerThan30BPMAreReplaced")
def _():
    return approx(cl(_mod(20, {10: 2500}))[0][10], 1000, 1), ""


@case(S, "testEctopicBeatBeyondTwentyPercentIsReplaced")
def _():
    return approx(cl(_mod(20, {12: 700}))[0][12], 1000, 1), ""


@case(S, "testNormalVariationIsPreserved")
def _():
    return approx(cl(_mod(20, {12: 1080}))[0][12], 1080, 0.01), ""


@case(S, "testCleaningPreservesSeriesLength")
def _():
    return len(cl(_mod(40, {5: 250, 20: 2400}))[0]) == 40, ""


@case(S, "testShortSeriesIsReturnedUnchanged")
def _():
    return cl([1000, 250, 1000])[0] == [1000, 250, 1000], ""


@case(S, "testEmptySeriesIsSafe")
def _():
    return cl([])[0] == [], ""


@case(S, "testArtifactAtSeriesStartUsesTheFollowingCleanBeat")
def _():
    return approx(cl(_mod(20, {0: 250}))[0][0], 1000, 1), ""


@case(S, "testArtifactAtSeriesEndUsesThePrecedingCleanBeat")
def _():
    return approx(cl(_mod(20, {19: 2400}))[0][19], 1000, 1), ""


@case(S, "testConsecutiveArtifactsInterpolateAcrossTheGap")
def _():
    v = cl(_mod(20, {9: 250, 10: 250, 11: 250}))[0]
    return all(approx(v[i], 1000, 1) for i in (9, 10, 11)), ""


@case(S, "testCleanSeriesIsUnchanged")
def _():
    s = [950.0 + 30 * math.sin(i / 4) for i in range(30)]
    return all(abs(a - b) < 0.001 for a, b in zip(s, cl(s)[0])), ""


@case(S, "testCorrectionCountIsReportedIndependentlyOfLength")
def _():
    v, c = cl(_mod(20, {5: 250, 11: 2400, 15: 700}))
    return len(v) == 20 and c == 3, f"count={c}"


@case(S, "testCorrectedFractionMatchesTheCorrectedShare")
def _():
    v, c = cl(_mod(20, {4: 250, 9: 250}))
    return approx(lc.corrected_fraction(v, c), 0.10, 1e-4), ""


@case(S, "testCleanSeriesReportsNoCorrections")
def _():
    s = [950.0 + 30 * math.sin(i / 4) for i in range(30)]
    v, c = cl(s)
    return c == 0 and lc.corrected_fraction(v, c) == 0, ""


@case(S, "testEmptySeriesFractionIsZeroNotNaN")
def _():
    return lc.corrected_fraction([], 0) == 0, ""


@case(S, "testShortSeriesReportsNoCorrections")
def _():
    return cl([1000, 250, 1000])[1] == 0, ""


@case(S, "testRejectionThresholdsMatchThePublishedBias")
def _():
    return lc.LOW_CONFIDENCE_CORRECTED_FRACTION == 0.03 and lc.MAX_CORRECTED_FRACTION == 0.06, ""


@case(S, "testAHeavilyCorruptedWindowExceedsTheRejectionThreshold")
def _():
    s = steady(40)
    for i in range(0, 40, 4):
        s[i] = 250
    v, c = cl(s)
    return c == 10 and lc.corrected_fraction(v, c) > 0.06, ""


@case(S, "testARealisticStrapGlitchStaysUnderTheRejectionThreshold")
def _():
    v, c = cl(_mod(100, {50: 2400}))
    return c == 1 and lc.corrected_fraction(v, c) < 0.03, ""


# ---------------- TimeDomainTests (RMSSD path) ----------------
S = "TimeDomainTests"


def series(rrs, gaps=None):
    pts, t = [], 0
    for i, rr in enumerate(rrs):
        if gaps and i in gaps:
            t += gaps[i]
        pts.append((t, rr))
        t += rr
    return pts


@case(S, "testRMSSDAccuracy")
def _():
    p = series([800, 820, 790, 830, 780] * 2)
    m = td.compute_time_domain(p, [False] * 10, 0, 10)
    return approx(m["rmssd"], math.sqrt(11200 / 9), 0.01), f"{m['rmssd']:.4f}"


@case(S, "testRMSSDParityExact")
def _():
    p = series([800, 820, 790, 830, 780] * 2)
    m = td.compute_time_domain(p, [False] * 10, 0, 10)
    return approx(m["rmssd"], 35.276684147527874, 1e-6), f"{m['rmssd']!r}"


@case(S, "testSDNNParityExact")
def _():
    p = series([800, 900, 700, 850, 750] * 2)
    m = td.compute_time_domain(p, [False] * 10, 0, 10)
    return approx(m["sdnn"], 74.53559924999298, 1e-6), ""


@case(S, "testArtifactExclusion (meanRR)")
def _():
    rr = [800, 810, 400, 790, 800, 805, 795, 800, 810, 790, 800]
    fl = [False] * 11
    fl[2] = True
    m = td.compute_time_domain(series(rr), fl, 0, 11)
    return approx(m["meanRR"], 800, 1), f"{m['meanRR']:.2f}"


@case(S, "testRMSSDDoesNotBridgeARemovedBeat")
def _():
    rr = [(800 if i < 7 else 900) + (0 if i % 2 == 0 else 10) for i in range(14)]
    fl = [False] * 14
    fl[6] = True
    m = td.compute_time_domain(series(rr), fl, 0, 14)
    return approx(m["rmssd"], 10, 1e-9), f"{m['rmssd']}"


@case(S, "testInsufficientData")
def _():
    return td.compute_time_domain(series([800, 810]), [False] * 2, 0, 2) is None, ""


@case(S, "testWindowBounds")
def _():
    p = [(i * 800, 800 + (20 if i % 2 == 0 else -20)) for i in range(20)]
    return td.compute_time_domain(p, [False] * 20, 5, 15) is not None, ""


@case(S, "testNoSuccessiveDifferenceAcrossARecordingBreak")
def _():
    rr = [800 if i % 2 == 0 else 820 for i in range(16)] + [900 if i % 2 == 0 else 920 for i in range(16)]
    p = series(rr, gaps={16: 10000})
    m = td.compute_time_domain(p, [False] * 32, 0, 32)
    br = [i for i in range(1, 32) if td.is_recording_break(p[i - 1], p[i])]
    return approx(m["rmssd"], 20, 1e-9) and br == [16], f"rmssd={m['rmssd']} breaks={br}"


@case(S, "testPNN50")
def _():
    rr = [800, 860, 840, 895, 865, 935, 900, 820, 880, 830, 890]
    m = td.compute_time_domain(series(rr), [False] * 11, 0, 11)
    return approx(m["pnn50"], 60.0, 0.1), f"{m['pnn50']:.2f}"


@case(S, "testSDNN")
def _():
    m = td.compute_time_domain(series([800, 900, 700, 850, 750] * 2), [False] * 10, 0, 10)
    return 70 < m["sdnn"] < 90, f"{m['sdnn']:.3f}"


# ---------------- HRVReferenceValidationTests (nsr2db fixtures) ----------------
S = "HRVReferenceValidationTests"


def _fixtures():
    import json
    import subprocess
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    src = subprocess.run(["git", "-C", root, "show", "e028039:EmuquTests/HRVReferenceFixtures.swift"],
                         capture_output=True, text=True, check=True).stdout
    body = src.split('static let json = """', 1)[1].split('"""', 1)[0]
    return json.loads(body.replace("\n", ""))["records"]


_FIX = []


def fix():
    if not _FIX:
        _FIX.extend(_fixtures())
    return _FIX


def _an(rec):
    return td.compute_time_domain(series(rec["rrMs"]), [False] * len(rec["rrMs"]), 0, len(rec["rrMs"]))


def _raw_rmssd(rr):
    return math.sqrt(sum((rr[i] - rr[i - 1]) ** 2 for i in range(1, len(rr))) / (len(rr) - 1))


@case(S, "testFixtureCorpusIsPresentAndPlausible")
def _():
    r = fix()
    return len(r) == 20 and sum(len(x["rrMs"]) for x in r) == 6000, ""


@case(S, "testMeanRRAndSDNNMatchTheReferenceOnEveryRecord")
def _():
    worst = 0.0
    for r in fix():
        m = _an(r)
        worst = max(worst, abs(m["meanRR"] - r["expected"]["meanRR"]), abs(m["sdnn"] - r["expected"]["sdnn"]))
    return worst <= 1e-6, f"max abs diff={worst:.2e}"


@case(S, "testUnfilteredRMSSDMatchesTheReferenceOnEveryRecord")
def _():
    worst = max(abs(_raw_rmssd(r["rrMs"]) - r["expected"]["rmssdUnfiltered"]) for r in fix())
    return worst <= 1e-6, f"max abs diff={worst:.2e}"


@case(S, "testPipelineRMSSDIsNeverLargerThanTheUnfilteredValue")
def _():
    narrowed, ok = 0, True
    for r in fix():
        m = _an(r)["rmssd"]
        raw = _raw_rmssd(r["rrMs"])
        ok &= m <= raw + 1e-6
        narrowed += m < raw - 1e-6
    return ok and narrowed > 0, f"narrowed={narrowed}"


@case(S, "(comment value) nsr005 '16.03 against 28.98' -- stale: from the pre-5c4a23d collapsed-array rule")
def _():
    # The doc comment quotes the first version of the suite (2026-09-08). Commit
    # 5c4a23d (2026-10-04) changed successiveDifferences to skip non-adjacent
    # pairs, so at e028039 the pipeline value is lower. We check both: raw
    # 28.98, the old collapsed rule 16.03, and report the current-rule value.
    r = [x for x in fix() if x["record"] == "nsr005"][0]
    rr = [float(v) for v in r["rrMs"]]
    keep = td.ectopic_keep_mask(rr)
    c = [v for v, k in zip(rr, keep) if k]
    collapsed = math.sqrt(sum((c[i] - c[i - 1]) ** 2 for i in range(1, len(c))) / (len(c) - 1))
    cur = _an(r)["rmssd"]
    ok = round(_raw_rmssd(r["rrMs"]), 2) == 28.98 and round(collapsed, 2) == 16.03
    return ok, f"raw={_raw_rmssd(r['rrMs']):.2f} old-rule={collapsed:.2f} e028039-rule={cur:.2f}"


@case(S, "testPNN50MatchesTheReferenceWhereNoBeatIsFiltered")
def _():
    compared, ok = 0, True
    for r in fix():
        rr = [float(v) for v in r["rrMs"]]
        if not all(td.ectopic_keep_mask(rr)):
            continue
        ok &= abs(_an(r)["pnn50"] - r["expected"]["pnn50Unfiltered"]) <= 1e-5
        compared += 1
    return ok and compared > 0, f"compared={compared}"


@case(S, "testVariabilityIsInvariantUnderAConstantShift")
def _():
    for r in fix()[:5]:
        b = _an(r)
        m = td.compute_time_domain(series([v + 100 for v in r["rrMs"]]), [False] * 300, 0, 300)
        if abs(m["meanRR"] - b["meanRR"] - 100) > 1e-9 or abs(m["sdnn"] - b["sdnn"]) > 1e-9:
            return False, r["record"]
    return True, ""


if __name__ == "__main__":
    for c in CASES:
        c()
    nfail = 0
    for suite, name, ok, detail in RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}  {suite}.{name}  {detail}")
        nfail += 0 if ok else 1
    print(f"\n{len(RESULTS) - nfail}/{len(RESULTS)} cases matched")
    sys.exit(1 if nfail else 0)
