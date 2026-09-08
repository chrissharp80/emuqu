#!/usr/bin/env python3
"""Build HRV reference fixtures from ECG-derived beat annotations.

## Why this exists

The app reports RMSSD, SDNN and pNN50. Unit tests against hand-made input do
not demonstrate those numbers are right: none of it is real cardiac data, and
none of it is checked against an independent implementation.

This closes the half that is closable without a lab. Two different questions
hide inside "is the HRV accurate":

  1. Does the app compute the standard metrics correctly from a beat series?
  2. Does a Polar H10 detect beats as well as a clinical ECG?

(2) is the sensor manufacturer's claim, established in published validation
studies, and no amount of code here can test it — the app never sees the ECG.
(1) is entirely the app's responsibility, and it is what this validates: real
ECG-derived beat annotations in, metrics out, compared against an independent
implementation of the Task Force (1996) definitions written here in Python.

## Source

MIT Normal Sinus Rhythm RR Interval Database (nsr2db) on PhysioNet: 24-hour
Holter recordings from subjects in normal sinus rhythm, beat-annotated by the
database authors. Licensed Open Data Commons Attribution (ODC-By) v1.0, which
permits redistribution and derivative databases with attribution. The fixtures
this writes are a derivative database; the attribution travels with them, in
the generated header and in docs/hrv-reference-data.md.

Beat annotations rather than raw ECG on purpose: the reference is where the
beats are, which is exactly the input the app's analyser takes. Decoding raw
ECG would be testing a beat detector the app does not have.

## Usage

    python3 scripts/fetch_hrv_reference.py            # regenerate fixtures
    python3 scripts/fetch_hrv_reference.py --check    # verify without writing

Network access required; nothing here runs in CI. The generated Swift file is
committed, so the tests run offline.
"""

import argparse
import hashlib
import json
import pathlib
import statistics
import struct
import sys
import urllib.request

BASE = "https://physionet.org/files/nsr2db/1.0.0"
LICENSE_URL = "https://physionet.org/content/nsr2db/view-license/1.0.0/"
DATABASE = "MIT Normal Sinus Rhythm RR Interval Database (nsr2db) v1.0.0"
RECORDS = [f"nsr{n:03d}" for n in range(1, 21)]
SAMPLES_PER_SECOND = 128
WINDOW_BEATS = 300
SKIP_BEATS = 5000          # step past the start of the tape, where leads settle

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT_OUT = ROOT / "EmuquTests/HRVReferenceFixtures.swift"

# WFDB annotation codes.
SKIP, NUM, SUB, CHN, AUX = 59, 60, 61, 62, 63
BEAT_CODES = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 25, 30, 31, 34, 35, 38}


def beat_samples(blob: bytes) -> list[int]:
    """Sample offsets of every beat annotation in a WFDB annotation file.

    16-bit little-endian words: the top 6 bits are the annotation code and the
    low 10 the sample delta since the previous annotation. SKIP carries a
    32-bit delta in the next four bytes; NUM/SUB/CHN carry data in the delta
    field and do not advance time; AUX is followed by `delta` bytes of text,
    padded to an even length.
    """
    out, i, t = [], 0, 0
    while i + 1 < len(blob):
        word = struct.unpack_from("<H", blob, i)[0]
        i += 2
        code, delta = (word >> 10) & 0x3F, word & 0x3FF
        if code == 0 and delta == 0:
            break
        if code == SKIP:
            hi, lo = struct.unpack_from("<hH", blob, i)
            i += 4
            t += (hi << 16) | lo
            continue
        if code in (NUM, SUB, CHN):
            continue
        if code == AUX:
            i += delta + (delta & 1)
            continue
        t += delta
        if code in BEAT_CODES:
            out.append(t)
    return out


def metrics(rr: list[float]) -> dict:
    """The Task Force (1996) time-domain measures, computed independently.

    Deliberately written from the definitions rather than by calling a library:
    the point is to disagree with the Swift implementation if either is wrong,
    and two callers of the same library would agree while both being wrong.
    """
    diffs = [b - a for a, b in zip(rr, rr[1:])]
    mean = statistics.fmean(rr)
    return {
        "meanRR": round(mean, 6),
        # SAMPLE standard deviation (N-1).
        #
        # The population form disagrees with the app by exactly sqrt(N/(N-1))
        # on every record — 19.8456 against 19.8125 on nsr001 — and the app is
        # right: N-1 is what HRV software reports, so that discrepancy is the
        # reference being naive rather than a defect. Noted because the ratio
        # is a small one and easy to wave away as floating-point noise, which
        # it is not.
        "sdnn": round((sum((x - mean) ** 2 for x in rr) / (len(rr) - 1)) ** 0.5, 6),
        # Unfiltered RMSSD and pNN50, straight from the definitions.
        #
        # `computeTimeDomain` applies an ectopic-beat filter before taking
        # successive differences, so these values are NOT what it returns —
        # they are what `rmssd(fromCleanRRs:)` returns, which is the pure
        # formula. Keeping the reference unfiltered is deliberate: replicating
        # the app's local-median rule here would make this a copy of the code
        # it is meant to check.
        "rmssdUnfiltered": round((sum(d * d for d in diffs) / len(diffs)) ** 0.5, 6),
        "pnn50Unfiltered": round(100.0 * sum(1 for d in diffs if abs(d) > 50) / len(diffs), 6),
        # Reciprocal of the mean interval. The app reports mean HR from rolling
        # 10-second windows instead, which is a different and defensible
        # quantity (the mean of reciprocals is not the reciprocal of the mean),
        # so this is carried for scale only and is not asserted as equality.
        "hrFromMeanRR": round(60000.0 / mean, 6),
    }


def fetch(name: str, suffix: str) -> bytes:
    url = f"{BASE}/{name}{suffix}"
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def build() -> list[dict]:
    records = []
    for name in RECORDS:
        header = fetch(name, ".hea").decode("utf-8", "replace")
        age = sex = None
        for line in header.splitlines():
            if "Age:" in line:
                parts = line.replace("#", "").split()
                for i, p in enumerate(parts):
                    if p == "Age:" and i + 1 < len(parts):
                        age = parts[i + 1]
                    if p == "Sex:" and i + 1 < len(parts):
                        sex = parts[i + 1]
        raw = fetch(name, ".ecg")
        beats = beat_samples(raw)
        if len(beats) < SKIP_BEATS + WINDOW_BEATS + 1:
            print(f"  {name}: too few beats ({len(beats)}), skipped", file=sys.stderr)
            continue
        window = beats[SKIP_BEATS: SKIP_BEATS + WINDOW_BEATS + 1]
        rr = [(b - a) * 1000.0 / SAMPLES_PER_SECOND for a, b in zip(window, window[1:])]
        # A window straddling a dropout would test the analyser against an
        # artefact rather than against a rhythm; the app filters those upstream.
        if not all(300 <= x <= 2000 for x in rr):
            print(f"  {name}: window contains a non-physiological interval, skipped", file=sys.stderr)
            continue
        # The app stores rr_ms as an Int, so the reference is computed on the
        # SAME rounded series. Comparing against metrics from the fractional
        # values would measure the model's integer resolution rather than the
        # analyser's arithmetic, and would fail for a reason that is not a bug.
        rounded = [float(round(x)) for x in rr]
        records.append({
            "record": name,
            "age": age,
            "sex": sex,
            "sourceSHA256": hashlib.sha256(raw).hexdigest(),
            "rrMs": [int(x) for x in rounded],
            "expected": metrics(rounded),
        })
        print(f"  {name}: {len(rr)} intervals, mean {statistics.fmean(rr):.1f} ms")
    return records


def swift_source(records: list[dict]) -> str:
    payload = json.dumps({"records": records}, separators=(",", ":"))
    wrapped = "\n".join(payload[i:i + 110] for i in range(0, len(payload), 110))
    return f'''import Foundation

// Reference HRV fixtures — GENERATED, do not edit by hand.
//
// Regenerate with `python3 scripts/fetch_hrv_reference.py`. Provenance,
// licensing and the reasoning behind the choice of source are in
// docs/hrv-reference-data.md.
//
// Contains information from the {DATABASE},
// made available under the Open Data Commons Attribution License v1.0:
// {LICENSE_URL}
//
// Each record holds a {WINDOW_BEATS}-interval window of ECG-derived beat
// annotations from a 24-hour Holter recording, plus the time-domain metrics
// computed independently in Python from the Task Force (1996) definitions.
// The Swift analyser must reproduce them.
//
// Stored as JSON in a string literal rather than as a Swift array literal on
// purpose: an array of several thousand numeric literals is exactly the shape
// that took `EmuquApp.body` to 9,766 ms of type-checking. A string literal is
// one token.
enum HRVReferenceFixtures {{
    static let json = """
{wrapped}
"""
}}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify the committed file matches a fresh fetch")
    args = parser.parse_args()

    print(f"Fetching {len(RECORDS)} records from {DATABASE}")
    records = build()
    if not records:
        print("fetch_hrv_reference: no usable records", file=sys.stderr)
        return 1
    source = swift_source(records)

    if args.check:
        if not SWIFT_OUT.exists():
            print(f"fetch_hrv_reference: {SWIFT_OUT.name} is missing", file=sys.stderr)
            return 1
        if SWIFT_OUT.read_text() != source:
            print(f"fetch_hrv_reference: {SWIFT_OUT.name} differs from a fresh fetch", file=sys.stderr)
            return 1
        print(f"fetch_hrv_reference: {SWIFT_OUT.name} matches. {len(records)} records.")
        return 0

    SWIFT_OUT.write_text(source)
    print(f"fetch_hrv_reference: wrote {SWIFT_OUT.name} — {len(records)} records, "
          f"{sum(len(r['rrMs']) for r in records)} intervals.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
