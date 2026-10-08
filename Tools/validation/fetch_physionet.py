"""Download PhysioNet files from the open-data S3 mirror with retry.

The mirror (https://physionet-open.s3.amazonaws.com/<db>/<version>/<file>)
intermittently answers 404/NoSuchBucket through the sandbox proxy, so every
GET is retried until it returns 200 with a non-XML-error body.

Usage: python3 -I fetch_physionet.py <db> <version> <outdir> [file ...]
With no files, fetches RECORDS and then <rec>.hea/.atr/... per --ext list.
"""
import os
import sys
import time
import urllib.request

BASE = "https://physionet-open.s3.amazonaws.com"


def fetch(db, ver, name, outdir, tries=40):
    dest = os.path.join(outdir, name)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest) or outdir, exist_ok=True)
    url = f"{BASE}/{db}/{ver}/{name}"
    last = None
    for i in range(tries):
        try:
            tmp = dest + ".part"
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                expected = r.headers.get("Content-Length")
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            size = os.path.getsize(tmp)
            if expected is not None and size != int(expected):
                raise IOError(f"short read {size} != {expected}")
            with open(tmp, "rb") as f:
                head = f.read(64)
            if head.startswith(b"<?xml") and b"<Error>" in open(tmp, "rb").read(400):
                raise IOError("S3 error body")
            os.replace(tmp, dest)
            return dest
        except Exception as e:  # noqa: BLE001 - retry any transport failure
            last = e
            time.sleep(min(2 + i, 15))
    raise RuntimeError(f"failed {url}: {last}")


def main():
    db, ver, outdir = sys.argv[1:4]
    names = sys.argv[4:]
    for n in names:
        p = fetch(db, ver, n, outdir)
        print(p, os.path.getsize(p), flush=True)


if __name__ == "__main__":
    main()
