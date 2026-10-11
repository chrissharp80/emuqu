#!/usr/bin/env python3
"""The code map: one record per source file and per unit, kept in step with the code.

    codemap.py check            fail if any record is missing, stale, orphaned or incomplete
    codemap.py status           the same list, exit 0
    codemap.py sync PATH...     add empty records for new units in PATH, drop records of deleted ones
    codemap.py stamp PATH [KEY...]
                                after re-reading the code and updating the record text, mark the
                                file record (no KEY) or the named units as written against the
                                current code
    codemap.py impact [--base REF] [NODE...]
                                everything a change can affect: for each unit changed since REF
                                (default origin/main) or each named `path::key`, its callers up to
                                their triggers, the tests that reach it, the shared state it
                                touches and who else touches it, and the open findings on all of it
    codemap.py callers NODE     direct callers of one `path::key` (certain and possible)
    codemap.py report OUTDIR    build the browsable report from the records

Records live in docs/codemap/records/<path>.json. See docs/codemap/README.md.
"""
from __future__ import annotations

import collections
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECORDS = ROOT / "docs" / "codemap" / "records"
sys.path.insert(0, str(Path(__file__).resolve().parent))


def record_path(path: str) -> Path:
    return RECORDS / (path + ".json")


def load(path: str) -> dict | None:
    p = record_path(path)
    if not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def save(rec: dict) -> None:
    p = record_path(rec["file"])
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(rec, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def all_records() -> dict[str, dict]:
    out = {}
    for dirpath, _, files in os.walk(RECORDS):
        for name in files:
            if name.endswith(".json"):
                rec = json.loads((Path(dirpath) / name).read_text(encoding="utf-8"))
                out[rec["file"]] = rec
    return out


def problems(inv: dict, recs: dict) -> list[tuple[str, str, str]]:
    """(path, key or '', what is wrong)."""
    out = []
    known = {f"{f}::{u['key']}" for f, d in inv.items() for u in d["units"]}
    for f, d in sorted(inv.items()):
        rec = recs.get(f)
        if rec is None:
            out.append((f, "", "no record for this file"))
            continue
        if rec.get("hash") != d["hash"]:
            out.append((f, "", "file record is stale: code outside every unit changed"))
        if not (rec.get("role") or "").strip():
            out.append((f, "", "file record has no role"))
        have = {u["key"]: u for u in rec.get("units", [])}
        for u in d["units"]:
            r = have.get(u["key"])
            if r is None:
                out.append((f, u["key"], "new unit with no record"))
                continue
            if not (r.get("does") or "").strip():
                out.append((f, u["key"], "record says nothing about what the unit does"))
            if r.get("hash") != u["hash"]:
                out.append((f, u["key"], "stale: the code changed after the record was written"))
            for c in r.get("calls") or []:
                if "::" in c and not c.startswith(("ext:", "dyn:", "closure:")) and c not in known:
                    out.append((f, u["key"], f"calls a unit that no longer exists: {c}"))
        for k in have.keys() - {u["key"] for u in d["units"]}:
            out.append((f, k, "record for a unit that no longer exists"))
    for f in sorted(recs.keys() - inv.keys()):
        out.append((f, "", "record for a file that is no longer tracked or is out of scope"))
    return out


def described(rec_unit: dict | None, file_level: bool = False) -> str:
    """Hash of what a record says a unit (or a file's top-level code) does: the part its callers
    rely on. Calls are left out (they are how, not what)."""
    if rec_unit is None:
        return ""
    if file_level:
        fields = [rec_unit.get("role"), rec_unit.get("toplevel"), rec_unit.get("state")]
    else:
        fields = [rec_unit.get("does"), rec_unit.get("entry"), rec_unit.get("reads"), rec_unit.get("writes"),
                  [(b.get("cond"), b.get("effect")) for b in rec_unit.get("branches") or []]]
    fields.append([(f.get("kind"), f.get("sev"), f.get("text")) for f in rec_unit.get("flags") or []])
    return hashlib.sha256(json.dumps(fields, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]


def descriptions(recs: dict) -> dict[str, str]:
    out = {}
    for f, rec in recs.items():
        out[f"{f}::"] = described(rec, file_level=True)
        for u in rec.get("units", []):
            out[f"{f}::{u['key']}"] = described(u)
    return out


def record_of(recs: dict, node: str) -> dict | None:
    f, key = node.split("::", 1)
    rec = recs.get(f)
    if rec is None or key == "":
        return rec
    return next((u for u in rec.get("units", []) if u["key"] == key), None)


def current_deps(graph: dict, desc: dict, node: str) -> dict[str, str]:
    return {c: desc.get(c, "") for c, kind in sorted(graph["edges"].get(node, {}).items()) if kind == "certain"}


def dependency_problems(inv: dict, recs: dict, graph: dict) -> list[tuple[str, str, str]]:
    """A record is checked against what its callees did when it was stamped. When a callee's record
    now says something different, or the code now calls a unit it was not checked against, the
    caller must be re-read and re-stamped: its own behaviour may have changed with the callee's."""
    desc = descriptions(recs)
    out = []
    for f, d in inv.items():
        rec = recs.get(f)
        if rec is None:
            continue
        nodes = [(f"{f}::", rec, rec.get("hash") == d["hash"])]
        have = {u["key"]: u for u in rec.get("units", [])}
        for u in d["units"]:
            r = have.get(u["key"])
            if r is not None:
                nodes.append((f"{f}::{u['key']}", r, r.get("hash") == u["hash"]))
        for node, r, current in nodes:
            if not current:
                continue  # already reported as stale; re-reading it covers its callees too
            deps = r.get("deps") or {}
            for callee, h in current_deps(graph, desc, node).items():
                if callee not in deps:
                    out.append((f, node.split("::", 1)[1], f"re-check: now resolves a call to {callee}, which it was not checked against"))
                elif deps[callee] != h:
                    out.append((f, node.split("::", 1)[1], f"re-check: {callee} changed what it does since this record was checked"))
    return out


def open_findings(recs: dict) -> dict[str, int]:
    """Open findings by severity, across file and unit records."""
    counts = {"high": 0, "med": 0, "low": 0}
    for rec in recs.values():
        for fl in list(rec.get("flags") or []) + [fl for u in rec.get("units", []) for fl in u.get("flags") or []]:
            if fl.get("sev") in counts:
                counts[fl["sev"]] += 1
    return counts


def budget_problems(counts: dict[str, int]) -> list[tuple[str, str, str]]:
    """Open high and medium findings must equal their ratcheted budgets in .ci/.

    More than the budget means a change added a finding. Fewer means a fix landed without lowering
    the budget; lowering it in the same change is what stops the count creeping back up.
    check_budget_monotonicity.sh stops the budgets themselves from being raised.
    """
    out = []
    for sev in ("high", "med"):
        path = ROOT / ".ci" / f"codemap_open_{sev}.txt"
        rel = f".ci/codemap_open_{sev}.txt"
        try:
            budget = int(path.read_text().strip())
        except (OSError, ValueError):
            out.append((rel, "open-findings ratchet", f"budget file missing or not an integer; the {sev} findings ratchet cannot run"))
            continue
        if counts[sev] > budget:
            out.append((rel, "open-findings ratchet", f"{counts[sev]} open {sev}-severity findings, budget {budget}: a change added "
                                 f"{counts[sev] - budget}. Fix it instead of recording it as open."))
        elif counts[sev] < budget:
            out.append((rel, "open-findings ratchet", f"{counts[sev]} open {sev}-severity findings, budget {budget}: lower the budget "
                                 f"to {counts[sev]} in this change."))
    return out


def cmd_check(strict: bool) -> int:
    from inventory import inventory
    import graph as graphmod
    recs = all_records()
    inv = inventory(ROOT)
    probs = problems(inv, recs)
    probs += dependency_problems(inv, recs, graphmod.build(inv, recs, ROOT))
    probs += budget_problems(open_findings(recs))
    if not probs:
        c = open_findings(recs)
        print(f"codemap: clean. Every unit and file in scope has a current record. "
              f"Open findings: {c['high']} high, {c['med']} medium, {c['low']} low (high and medium can only go down).")
        return 0
    by_file: dict[str, list] = {}
    for f, k, what in probs:
        by_file.setdefault(f, []).append((k, what))
    print(f"codemap: {len(probs)} problem(s) in {len(by_file)} file(s).\n")
    for f, items in by_file.items():
        print(f"  {f}")
        for k, what in items:
            print(f"      {k or '(file record)'}: {what}")
    print("\n  Update the record text in docs/codemap/records/<path>.json to match the code,")
    print("  then mark it current:  python3 scripts/codemap/codemap.py stamp <path> [key ...]")
    print("  're-check' lines: re-read that unit against the changed callee, fix the unit or its")
    print("  record if its behaviour changed too, then stamp it. Stamp callees before callers.")
    print("  New or deleted units:  python3 scripts/codemap/codemap.py sync <path>")
    print("  See docs/codemap/README.md.")
    return 1 if strict else 0


def cmd_sync(paths: list[str]) -> int:
    from inventory import inventory
    inv = inventory(ROOT, only=set(paths))
    for p in paths:
        if p not in inv:
            rec = load(p)
            if rec is not None:
                record_path(p).unlink()
                print(f"{p}: file is out of scope or untracked; record removed")
            else:
                print(f"{p}: not tracked by git, or out of scope (git add it first)")
            continue
        rec = load(p) or {"file": p, "hash": None, "role": "", "types": [], "state": [], "toplevel": "", "flags": [], "units": []}
        have = {u["key"]: u for u in rec["units"]}
        units = []
        for u in inv[p]["units"]:
            if u["key"] in have:
                units.append(have[u["key"]])
            else:
                units.append({"key": u["key"], "hash": None, "does": "", "entry": None, "calls": [], "reads": [],
                              "writes": [], "branches": [], "flags": []})
                print(f"{p}: added empty record for {u['key']}")
        for k in have.keys() - {u["key"] for u in inv[p]["units"]}:
            print(f"{p}: dropped record for {k} (no longer in the code)")
        rec["units"] = units
        save(rec)
    return 0


def cmd_stamp(path: str, keys: list[str]) -> int:
    from inventory import inventory
    import graph as graphmod
    full = inventory(ROOT)
    inv = {path: full[path]} if path in full else {}
    rec = load(path)
    if path not in inv or rec is None:
        print(f"{path}: no record or not in scope. Run sync first.", file=sys.stderr)
        return 2
    if not keys:
        if not (rec.get("role") or "").strip():
            print(f"{path}: write the file record's role before stamping it.", file=sys.stderr)
            return 1
        recs = all_records()
        g = graphmod.build(full, recs, ROOT)
        rec["hash"] = inv[path]["hash"]
        rec["deps"] = current_deps(g, descriptions(recs), f"{path}::")
        print(f"{path}: file record stamped")
    else:
        recs = all_records()
        g = graphmod.build(full, recs, ROOT)
        desc = descriptions(recs)
        current = {u["key"]: u["hash"] for u in inv[path]["units"]}
        have = {u["key"]: u for u in rec["units"]}
        for k in keys:
            if k not in current or k not in have:
                print(f"{path}: no unit {k!r}. Run sync, or check the key.", file=sys.stderr)
                return 2
            if not (have[k].get("does") or "").strip():
                print(f"{path}: {k}: write what it does before stamping it.", file=sys.stderr)
                return 1
            have[k]["hash"] = current[k]
            have[k]["deps"] = current_deps(g, desc, f"{path}::{k}")
            print(f"{path}: stamped {k}")
    save(rec)
    return 0


def changed_since(base: str, inv: dict) -> list[tuple[str, str]]:
    """(node, how) for every unit or file-level code that differs from `base`, judged against the
    records at `base` (which held each unit's code hash when the gate last passed there)."""
    names = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only", base, "--"], capture_output=True, text=True)
    if names.returncode != 0:
        raise SystemExit(f"impact: cannot diff against {base}: {names.stderr.strip()}")
    out = []
    for f in names.stdout.splitlines():
        old = subprocess.run(["git", "-C", str(ROOT), "show", f"{base}:docs/codemap/records/{f}.json"],
                             capture_output=True, text=True)
        old_rec = json.loads(old.stdout) if old.returncode == 0 else {"hash": None, "units": []}
        if f not in inv:
            if old.returncode == 0:
                out.append((f"{f}::", "deleted"))
                out += [(f"{f}::{u['key']}", "deleted") for u in old_rec.get("units", [])]
            continue
        before = {u["key"]: u.get("hash") for u in old_rec.get("units", [])}
        if old_rec.get("hash") != inv[f]["hash"]:
            out.append((f"{f}::", "changed" if old_rec.get("hash") else "new"))
        for u in inv[f]["units"]:
            if u["key"] not in before:
                out.append((f"{f}::{u['key']}", "new"))
            elif before[u["key"]] != u["hash"]:
                out.append((f"{f}::{u['key']}", "changed"))
        out += [(f"{f}::{k}", "deleted") for k in before.keys() - {u["key"] for u in inv[f]["units"]}]
    return out


def cmd_impact(args: list[str]) -> int:
    from inventory import inventory
    import graph as graphmod
    base = "origin/main"
    if args[:1] == ["--base"]:
        if len(args) < 2:
            print("impact: --base needs a git ref", file=sys.stderr)
            return 2
        base, args = args[1], args[2:]
    recs = all_records()
    inv = inventory(ROOT)
    g = graphmod.build(inv, recs, ROOT)
    callers = graphmod.callers(g)
    units = g["units"]
    targets = [(a, "named") for a in args] if args else changed_since(base, inv)
    unknown = [a for a, how in targets if how == "named" and a not in units]
    if unknown:
        for a in unknown:
            near = sorted(k for k in units if a.split("::")[-1].split("(")[0].split(".")[-1] in k)[:15]
            print(f"impact: no unit {a!r}. Units with that name:\n  " + "\n  ".join(near or ["(none)"]), file=sys.stderr)
        return 2
    is_test = lambda n: n.startswith(("EmuquTests/", "EmuquUITests/"))
    is_doc = lambda n: n.split("::")[0].endswith(".md")

    store_users = collections.defaultdict(lambda: {"reads": set(), "writes": set()})
    for f, rec in recs.items():
        for u in rec.get("units", []):
            for which in ("reads", "writes"):
                for st in u.get(which) or []:
                    if isinstance(st, str) and ":" in st:
                        store_users[st.split(" (")[0].strip()][which].add(f"{f}::{u['key']}")

    lines = [f"# Code map impact{'' if args else f' since {base}'}", ""]
    if not targets:
        lines.append("No mapped code changed.")
    for node, how in targets:
        r = record_of(recs, node)
        lines += [f"## `{node}` ({how})", ""]
        if r is not None and how != "deleted":
            lines.append(f"Does: {(r.get('does') or r.get('role') or '').strip()[:400]}")
        direct = callers.get(node, {})
        cert = sorted(c for c, k in direct.items() if k == "certain")
        poss = sorted(c for c, k in direct.items() if k == "possible")
        lines.append(f"\n**Direct callers:** {len(cert)} certain, {len(poss)} possible.")
        lines += [f"- {c}" for c in cert]
        lines += [f"- (possible) {c}" for c in poss[:40]] + ([f"- ... {len(poss) - 40} more possible"] if len(poss) > 40 else [])
        # walk certain callers to triggers
        seen, todo, triggers, tests, docs = {node}, [node], [], set(), set()
        while todo:
            x = todo.pop()
            for c, k in callers.get(x, {}).items():
                if k != "certain" or c in seen:
                    continue
                seen.add(c)
                if is_test(c):
                    tests.add(c)
                    continue
                if is_doc(c):
                    docs.add(c)
                    continue
                cr = record_of(recs, c)
                if cr is not None and cr.get("entry"):
                    triggers.append((c, cr["entry"]))
                todo.append(c)
        lines.append(f"\n**Reached from {len(triggers)} trigger(s)** (units with an outside trigger, through certain callers):")
        lines += [f"- {c}: {e}" for c, e in sorted(triggers)[:80]] + ([f"- ... {len(triggers) - 80} more"] if len(triggers) > 80 else [])
        lines.append(f"\n**Tests that reach it:** {len(tests)}")
        lines += [f"- {t}" for t in sorted(tests)[:60]] + ([f"- ... {len(tests) - 60} more"] if len(tests) > 60 else [])
        lines.append(f"\n**Docs that describe it or its callers:** {len(docs)}")
        lines += [f"- {d}" for d in sorted(docs)]
        if r is not None and how != "deleted" and "::" in node and node.split("::", 1)[1]:
            shared = []
            for which in ("reads", "writes"):
                for st in r.get(which) or []:
                    if isinstance(st, str):
                        key = st.split(" (")[0].strip()
                        others = (store_users[key]["reads"] | store_users[key]["writes"]) - {node}
                        if others:
                            shared.append(f"- {which[:-1]}s `{key}`: also written by {len(store_users[key]['writes'] - {node})}, "
                                          f"read by {len(store_users[key]['reads'] - {node})}: "
                                          + ", ".join(sorted(others)[:12]) + (" ..." if len(others) > 12 else ""))
            lines.append(f"\n**Shared state:** {len(shared)} store(s) also used elsewhere")
            lines += shared
        open_flags = []
        for n in [node] + cert:
            nr = record_of(recs, n)
            for fl in (nr or {}).get("flags") or []:
                open_flags.append(f"- [{fl.get('sev')}] {n}: {fl.get('text', '')[:300]}")
        lines.append(f"\n**Open findings on it and its direct callers:** {len(open_flags)}")
        lines += open_flags
        lines.append("")
    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text[:900_000])
    return 0


def cmd_callers(node: str) -> int:
    from inventory import inventory
    import graph as graphmod
    recs = all_records()
    inv = inventory(ROOT)
    cl = graphmod.callers(graphmod.build(inv, recs, ROOT)).get(node, {})
    for c, k in sorted(cl.items(), key=lambda x: (x[1], x[0])):
        print(f"{k:8} {c}")
    if not cl:
        print("no callers found (check the key: path::key, e.g. from a record's units[].key)")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "check":
        return cmd_check(strict=True)
    if cmd == "status":
        return cmd_check(strict=False)
    if cmd == "sync" and rest:
        return cmd_sync(rest)
    if cmd == "stamp" and rest:
        return cmd_stamp(rest[0], rest[1:])
    if cmd == "impact":
        return cmd_impact(rest)
    if cmd == "callers" and len(rest) == 1:
        return cmd_callers(rest[0])
    if cmd == "report" and len(rest) == 1:
        from report import build
        return build(ROOT, all_records(), Path(rest[0]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
