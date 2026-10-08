"""Bit-exact Python versions of the deterministic random sources used by the
Emuqu unit tests at commit e028039, so their fixtures can be regenerated:
  * DFAReferenceValidationTests.SeededGenerator (SplitMix64)
  * Swift stdlib Double.random(in: ClosedRange, using:) (Lemire next(upperBound:))
  * HRVSleepStageClassifierTests.deterministicOffset (LCG)
"""
M64 = (1 << 64) - 1


class SplitMix64:
    def __init__(self, seed):
        self.state = seed & M64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & M64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)

    def next_upper_bound(self, upper):
        r = self.next()
        m = r * upper
        low, high = m & M64, m >> 64
        if low < upper:
            t = ((0 - upper) & M64) % upper
            while low < t:
                r = self.next()
                m = r * upper
                low, high = m & M64, m >> 64
        return high

    def double_closed(self, lo, hi):
        delta = hi - lo
        max_sig = 1 << 53
        rand = self.next_upper_bound(max_sig + 1)
        if rand == max_sig:
            return hi
        unit = float(rand) * (2.220446049250313e-16 / 2)
        return delta * unit + lo


def deterministic_offset(step, lo, hi):
    span = hi - lo + 1
    value = (step * 1103515245 + 12345) & 0x7FFFFFFF
    return lo + value % span
