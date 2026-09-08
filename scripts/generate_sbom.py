#!/usr/bin/env python3
"""Generate an SPDX 2.3 software bill of materials from Package.resolved.

Both external audits (2026-08-26, 2026-08-27) filed the same finding: the
repository has good pinning discipline — `Package.resolved` is committed, every
GitHub Action is SHA-pinned, and `check_sbom_drift.sh` proves the in-app
acknowledgements screen mirrors the lockfile — but produces no machine-readable
SBOM, so an automated supply-chain scanner has nothing to read.

That is a gap in *evidence*, not in practice, and it is the cheapest kind to
close: every fact needed is already in the lockfile, pinned to a commit SHA.

Writes SPDX JSON, which is the format SCA tooling and GitHub's dependency
graph both accept. Deterministic: same lockfile in, byte-identical file out, so
committing the result produces no spurious diffs and
`check_sbom_drift.sh` can verify it has not gone stale.

Usage:
    python3 scripts/generate_sbom.py            # write sbom.spdx.json
    python3 scripts/generate_sbom.py --check    # verify the committed file matches
"""

import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOLVED = ROOT / "Emuqu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
OUTPUT = ROOT / "sbom.spdx.json"

# Direct dependencies of the app target. Everything else in the lockfile arrives
# transitively — almost all of it through polar-ble-sdk. The distinction matters
# to a reviewer: a transitive pin can only move when its parent moves.
DIRECT = {"polar-ble-sdk", "whisperkit"}

# License identifiers, read from each project's published LICENSE. Recorded here
# rather than guessed at parse time, because SPDX treats an unverified licence
# as worse than a declared "NOASSERTION".
LICENSES = {
    "polar-ble-sdk": "BSD-3-Clause",
    "whisperkit": "MIT",
    "swift-argument-parser": "Apache-2.0",
    "swift-asn1": "Apache-2.0",
    "swift-collections": "Apache-2.0",
    "swift-crypto": "Apache-2.0",
    "swift-jinja": "MIT",
    "swift-protobuf": "Apache-2.0",
    "swift-transformers": "Apache-2.0",
    "yyjson": "MIT",
    "zip": "MIT",
}


def spdx_id(identity: str) -> str:
    """SPDX element ids allow only letters, digits, '.' and '-'."""
    safe = "".join(ch if ch.isalnum() or ch in ".-" else "-" for ch in identity)
    return f"SPDXRef-Package-{safe}"


def purl(pin: dict) -> str:
    """Package URL, the identifier vulnerability scanners actually match on."""
    location = pin.get("location", "").removesuffix(".git")
    version = pin.get("state", {}).get("version") or pin.get("state", {}).get("revision", "")
    if location.startswith("https://github.com/"):
        owner_repo = location.removeprefix("https://github.com/")
        return f"pkg:github/{owner_repo.lower()}@{version}"
    return f"pkg:generic/{pin['identity']}@{version}"


def build() -> dict:
    resolved = json.loads(RESOLVED.read_text())
    pins = sorted(resolved.get("pins", []), key=lambda p: p["identity"])

    packages = [{
        "SPDXID": "SPDXRef-Package-Emuqu",
        "name": "Emuqu",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        # The root package carries the repository's own licence, the
        # PolyForm Strict 1.0.0: source-available, no changes, no
        # redistribution, noncommercial use only. On the SPDX license list.
"licenseConcluded": "PolyForm-Strict-1.0.0",
        "licenseDeclared": "PolyForm-Strict-1.0.0",
        "copyrightText": "Copyright (c) Chris Sharp",
        "supplier": "Person: Chris Sharp",
        "comment": "The application itself, listed as the root of the graph. Source-available under PolyForm Strict 1.0.0; see LICENSE.",
    }]

    relationships = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": "SPDXRef-Package-Emuqu",
    }]

    for pin in pins:
        identity = pin["identity"]
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision", "")[:12]
        revision = state.get("revision", "")
        direct = identity in DIRECT

        packages.append({
            "SPDXID": spdx_id(identity),
            "name": identity,
            "versionInfo": version,
            "downloadLocation": pin.get("location", "NOASSERTION"),
            "filesAnalyzed": False,
            "licenseConcluded": LICENSES.get(identity, "NOASSERTION"),
            "licenseDeclared": LICENSES.get(identity, "NOASSERTION"),
            "copyrightText": "NOASSERTION",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": purl(pin),
            }],
            "checksums": ([{"algorithm": "SHA1", "checksumValue": revision}] if len(revision) == 40 else []),
            "comment": (
                "Direct dependency of the app target."
                if direct else
                "Transitive dependency; moves only when its parent package moves."
            ),
        })
        relationships.append({
            "spdxElementId": "SPDXRef-Package-Emuqu",
            "relationshipType": "DEPENDS_ON" if direct else "DEPENDENCY_OF",
            "relatedSpdxElement": spdx_id(identity),
        })

    # Deterministic namespace: derived from the lockfile, not from the clock, so
    # regenerating without a dependency change produces no diff.
    digest = hashlib.sha256(RESOLVED.read_bytes()).hexdigest()[:16]

    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "Emuqu-SBOM",
        "documentNamespace": f"https://github.com/chrissharp80/emuqu/sbom/{digest}",
        "creationInfo": {
            "creators": ["Tool: scripts/generate_sbom.py"],
            # No timestamp: a clock in the output would make every regeneration a
            # diff, and the thing being described is the lockfile, not the moment.
            "created": "2026-08-27T00:00:00Z",
            "comment": (
                "Generated from Package.resolved. Deterministic: the same lockfile "
                "always produces this exact document. Regenerate with "
                "`python3 scripts/generate_sbom.py`; verify with `--check`."
            ),
        },
        "packages": packages,
        "relationships": relationships,
    }


def main() -> int:
    document = json.dumps(build(), indent=2, sort_keys=False) + "\n"

    if "--check" in sys.argv:
        if not OUTPUT.exists():
            print(f"generate_sbom: {OUTPUT.name} is missing. Run: python3 scripts/generate_sbom.py", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != document:
            print(
                f"generate_sbom: {OUTPUT.name} is stale — the dependency graph changed.\n"
                f"  Regenerate it: python3 scripts/generate_sbom.py",
                file=sys.stderr,
            )
            return 1
        count = len(json.loads(document)["packages"]) - 1
        print(f"generate_sbom: {OUTPUT.name} matches Package.resolved. {count} packages.")
        return 0

    OUTPUT.write_text(document)
    count = len(json.loads(document)["packages"]) - 1
    print(f"generate_sbom: wrote {OUTPUT.name} — SPDX 2.3, {count} packages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
