"""Build the browsable code-map report from docs/codemap/records.

Output: OUTDIR/index.html plus OUTDIR/data/*.json. The page loads the data files with relative
fetches, so serve the directory (python3 -m http.server) rather than opening the file directly.
"""
from __future__ import annotations

import collections
import html
import json
import re
import shutil
from pathlib import Path

from inventory import inventory

AREA_NAMES = {
    "A_shell": "App shell & launch", "B_recording": "Recording & sensors", "C1_workout": "Workouts",
    "C2_location": "Location & routes", "D_health_sleep": "HealthKit & sleep", "E_scoring": "Analysis & scoring",
    "F1_morning": "Morning results & UI", "F2_storage": "Archive, sync & storage", "G1_assistant_core": "Assistant core",
    "G2_assistant_facts_ui": "Assistant facts & UI", "G3_voice_coach": "Voice & coaching",
    "H_export_import": "Reports, export & import", "I_commerce_settings": "Purchases & settings", "W_watch": "Watch app",
    "T_tests": "Tests", "N_nonswift": "Build, CI & tools", "X_docs": "Docs", "L_strings": "String catalogs"}
PROD = [a for a in AREA_NAMES if a not in ("T_tests", "N_nonswift", "X_docs", "L_strings")]
STATUS = {"first read, upheld on second": "confirmed", "second read": "new-in-verify"}


def _area_resolver(root: Path):
    known = json.loads((root / "docs/codemap/areas.json").read_text())

    def area(f: str) -> str:
        if f in known:
            return known[f]
        d = f
        while "/" in d:
            d = d.rsplit("/", 1)[0]
            votes = collections.Counter(a for k, a in known.items() if k.startswith(d + "/"))
            if votes:
                return votes.most_common(1)[0][0]
        return "N_nonswift"
    return area


def _tok(text: str) -> set[str]:
    return set(re.findall(r"[A-Za-z_]\w*", text))


def build(root: Path, records: dict, out: Path) -> int:
    inv = inventory(root)
    area = _area_resolver(root)
    is_test = lambda f: f.startswith(("EmuquTests/", "EmuquUITests/"))
    is_prod_swift = lambda f: f.endswith(".swift") and not is_test(f)

    units, files, flags = {}, {}, []
    by_file_keys = collections.defaultdict(list)
    for f, d in inv.items():
        rec = records.get(f, {})
        have = {u["key"]: u for u in rec.get("units", [])}
        a = area(f)
        files[f] = {k: rec.get(k) for k in ("role", "types", "state", "toplevel")} | {"area": a, "flags": []}
        for fl in rec.get("flags") or []:
            x = {**fl, "status": STATUS.get(fl.get("found"), "later")}
            files[f]["flags"].append(x)
            flags.append({"id": f, "file": f, "area": a, **{k: x.get(k) for k in ("kind", "sev", "text", "evidence", "status")}})
        for u in d["units"]:
            r = have.get(u["key"], {})
            gk = f"{f}::{u['key']}"
            by_file_keys[f].append(gk)
            fl_list = [{**fl, "status": STATUS.get(fl.get("found"), "later")} for fl in r.get("flags") or []]
            units[gk] = {"file": f, "name": u["name"], "type": u["type"], "kind": u["kind"], "start": u["start"], "end": u["end"],
                         "area": a, "does": r.get("does", ""), "entry": r.get("entry"), "calls": r.get("calls") or [],
                         "reads": r.get("reads") or [], "writes": r.get("writes") or [],
                         "branches": [{**b, "line": u["start"] + int(b["at"][1:]) if str(b.get("at", "")).startswith("+") else b.get("at")} for b in r.get("branches") or []],
                         "flags": fl_list, "current": r.get("hash") == u["hash"]}
            for x in fl_list:
                flags.append({"id": gk, "file": f, "area": a, **{k: x.get(k) for k in ("kind", "sev", "text", "evidence", "status")}})

    # ---- call graph
    path_re = re.compile("(" + "|".join(re.escape(p) for p in sorted(by_file_keys, key=len, reverse=True)) + ")::") if by_file_keys else None

    def targets(c: str) -> list[str]:
        if c in units:
            return [c]
        if not c.startswith(("dyn:", "closure:")) or path_re is None:
            return []
        found = []
        for m in path_re.finditer(c):
            rest = c[m.start():]
            best = max((k for k in by_file_keys[m.group(1)] if rest.startswith(k)), key=len, default=None)
            if best:
                found.append(best)
        return found

    # Recorded calls (with keys embedded in dyn:/closure: text) merged with the mechanical graph.
    # Certain edges are callers; possible edges (an ambiguous name) are listed separately. Both
    # count for reachability, so the unreachable list errs toward leaving code out.
    import graph as graphmod
    g = graphmod.build(inv, records, root)
    callers, maybe = collections.defaultdict(set), collections.defaultdict(set)
    for k, u in units.items():
        sure = {t for c in u["calls"] if isinstance(c, str) for t in targets(c)}
        sure |= {t for t, kind in g["edges"].get(k, {}).items() if kind == "certain" and t in units}
        unsure = {t for t, kind in g["edges"].get(k, {}).items() if kind == "possible" and t in units} - sure
        u["targets"] = sorted(sure | unsure)
        for t in sure:
            callers[t].add(k)
        for t in unsure:
            maybe[t].add(k)
    for k, u in units.items():
        u["callers"] = sorted(callers.get(k, ()))
        u["possible_callers"] = sorted(maybe.get(k, ()))

    # ---- reachability: call graph from entry points, then a name-reference closure
    src = {}

    def lines(f):
        if f not in src:
            src[f] = (root / f).read_text(errors="replace").split("\n")
        return src[f]
    unit_tok, unit_lines = {}, collections.defaultdict(set)
    for k, u in units.items():
        if is_prod_swift(u["file"]):
            unit_tok[k] = _tok("\n".join(lines(u["file"])[u["start"] - 1:u["end"]]))
            unit_lines[u["file"]].update(range(u["start"], u["end"] + 1))
    free_tok = {f: _tok("\n".join(l for i, l in enumerate(lines(f), 1) if i not in unit_lines[f] and not l.strip().startswith("//")))
                for f in {u["file"] for u in units.values() if is_prod_swift(u["file"])}}
    top = lambda u: (u["type"] or "").split(".")[0]
    roots = {"EmuquMain", "EmuquApp", "WatchApp"}
    for k, u in units.items():
        if is_prod_swift(u["file"]) and any("@main" in l for l in lines(u["file"])[max(0, u["start"] - 40):u["start"]]):
            roots.add(top(u))
    entry_by_type = collections.defaultdict(list)
    for k, u in units.items():
        if is_prod_swift(u["file"]) and u.get("entry"):
            entry_by_type[top(u)].append(k)
    live, seen, stack, ref, touched = set(roots) | {""}, set(), [], set(), set()

    def seed(t):
        for k in entry_by_type.get(t, []):
            if k not in seen:
                seen.add(k)
                stack.append(k)

    def drain():
        while stack:
            k = stack.pop()
            u = units[k]
            ref.update(unit_tok.get(k, ()))
            if u["file"] not in touched:
                touched.add(u["file"])
                ref.update(free_tok.get(u["file"], ()))
            if top(u) not in live:
                live.add(top(u))
                seed(top(u))
            for t in u["targets"]:
                if t not in seen and is_prod_swift(units[t]["file"]):
                    seen.add(t)
                    stack.append(t)
    for t in list(live):
        seed(t)
    known_types = set(entry_by_type) | {top(u) for u in units.values() if is_prod_swift(u["file"])}
    while True:
        drain()
        new = {t for t in known_types - live if t in ref}
        if not new:
            break
        for t in new:
            live.add(t)
            seed(t)
    dead_types = sorted(t for t in known_types - live if t and not any(ch in t for ch in "<[("))
    changed = True
    while changed:
        changed = False
        for k, u in units.items():
            if k in seen or not is_prod_swift(u["file"]) or top(u) not in live:
                continue
            if u["name"] in ref or u["kind"].startswith(("init", "deinit")):
                seen.add(k)
                stack.append(k)
                changed = True
        drain()
        new = {t for t in known_types - live if t in ref}
        for t in new:
            live.add(t)
            seed(t)
            changed = True
    tseen = {k for k, u in units.items() if is_test(u["file"])}
    stack2 = list(tseen)
    while stack2:
        k = stack2.pop()
        for t in units[k]["targets"]:
            if t not in tseen:
                tseen.add(t)
                stack2.append(t)
    for k, u in units.items():
        if is_prod_swift(u["file"]):
            u["reach"] = "prod" if k in seen else ("tests-only" if k in tseen else "none")
    unreach = {k: {x: u[x] for x in ("file", "name", "area", "reach", "does", "entry", "callers", "kind", "start")}
               for k, u in units.items() if u.get("reach") in ("none", "tests-only") and u["kind"] != "protocol_function_declaration"}

    # ---- shared state
    def norm(s):
        m = re.match(r"^(\w+(?:\([^)]*\))?):\s*(.*)$", s.strip())
        if not m:
            return None
        key = re.split(r"[\s(—–-]{1,2}(?=[a-z ]{4,})|\s\(", m.group(2))[0].strip().strip("`\"'").rstrip(".")
        return f"{m.group(1).split('(')[0]}:{key[:80]}"
    store = collections.defaultdict(lambda: {"r": set(), "w": set()})
    for k, u in units.items():
        for s in u["reads"]:
            if isinstance(s, str) and (n := norm(s)):
                store[n]["r"].add(k)
        for s in u["writes"]:
            if isinstance(s, str) and (n := norm(s)):
                store[n]["w"].add(k)
    stores = []
    for n, d in store.items():
        if n.startswith(("mem:", "ext:")) and len(d["w"] | d["r"]) < 2:
            continue
        wa = sorted({units[x]["area"] for x in d["w"] if not is_test(units[x]["file"])})
        ra = sorted({units[x]["area"] for x in d["r"] if not is_test(units[x]["file"])})
        stores.append({"store": n, "writers": len(d["w"]), "readers": len(d["r"]), "writer_areas": wa, "reader_areas": ra,
                       "w": sorted(d["w"])[:40], "r": sorted(d["r"])[:40]})
    stores.sort(key=lambda x: (-len(x["writer_areas"]), -x["writers"] - x["readers"]))

    # ---- edges and charts
    area_edges, file_edges = collections.Counter(), collections.Counter()
    for k, u in units.items():
        if not is_prod_swift(u["file"]):
            continue
        for t in u["targets"]:
            v = units[t]
            if is_prod_swift(v["file"]):
                if u["area"] != v["area"]:
                    area_edges[(u["area"], v["area"])] += 1
                if u["file"] != v["file"]:
                    file_edges[(u["file"], v["file"])] += 1
    mid = lambda s: re.sub(r"\W", "_", s)
    ml = lambda s: s.replace('"', "'")
    area_units = collections.Counter(u["area"] for u in units.values())
    chart = ["flowchart LR"] + [f'  {mid(a)}["{ml(AREA_NAMES[a])}<br/>{area_units[a]} units"]' for a in PROD]
    chart += [f"  {mid(a)} -->|{n}| {mid(b)}" for (a, b), n in area_edges.most_common() if a in PROD and b in PROD and n >= 8]
    file_area = {f: files[f]["area"] for f in files}
    area_files = collections.defaultdict(list)
    for f, a in file_area.items():
        area_files[a].append(f)
    blocks = []
    for a in PROD:
        fs = set(area_files.get(a, []))
        inner = [((x, y), n) for (x, y), n in file_edges.most_common() if x in fs and y in fs][:45]
        outs, ins = collections.Counter(), collections.Counter()
        for (x, y), n in file_edges.items():
            if x in fs and y not in fs and file_area.get(y) in PROD:
                outs[file_area[y]] += n
            if y in fs and x not in fs and file_area.get(x) in PROD:
                ins[file_area[x]] += n
        nodes = sorted({x for (p, _) in inner for x in p})
        L = ["flowchart LR"] + [f'  {mid(n)}["{ml(n.split("/")[-1].replace(".swift", ""))}"]' for n in nodes]
        L += [f"  {mid(x)} -->|{n}| {mid(y)}" for (x, y), n in inner]
        if outs or ins:
            L.append(f'  HUB_{mid(a)}{{{{"{ml(AREA_NAMES[a])}"}}}}')
            for b, n in outs.most_common(6):
                L.append(f'  OUT_{mid(b)}(["→ {ml(AREA_NAMES[b])}"])')
                L.append(f"  HUB_{mid(a)} -->|{n}| OUT_{mid(b)}")
            for b, n in ins.most_common(6):
                L.append(f'  IN_{mid(b)}(["{ml(AREA_NAMES[b])} →"]) -->|{n}| HUB_{mid(a)}')
        blocks.append(f'<details class="chart"><summary>{html.escape(AREA_NAMES[a])} <span class="muted">{len(nodes)} files, '
                      f'{len(inner)} strongest file-to-file links, plus traffic to other areas</span></summary>'
                      f'<div class="scroll"><pre class="mermaid">{html.escape(chr(10).join(L))}</pre></div></details>')

    # ---- write
    if out.exists():
        shutil.rmtree(out)
    (out / "data" / "units").mkdir(parents=True)
    dump = lambda p, o: (out / p).write_text(json.dumps(o, separators=(",", ":"), ensure_ascii=False))
    dump("data/index.json", [[k, u["name"], u["area"], u["file"], u["start"], u.get("reach")] for k, u in units.items()])
    per_area = collections.defaultdict(dict)
    for k, u in units.items():
        per_area[u["area"]][k] = {x: u.get(x) for x in ("name", "type", "kind", "file", "start", "end", "does", "entry", "calls",
                                                        "callers", "possible_callers", "reads", "writes", "branches", "flags", "reach", "current")}
    for a in set(per_area) | set(area_files):
        dump(f"data/units/{a}.json", {"units": per_area.get(a, {}), "files": {f: files[f] for f in sorted(area_files.get(a, []))}})
    dump("data/flags.json", flags)
    dump("data/stores.json", stores)
    dump("data/unreachable.json", unreach)
    strings = root / "docs/codemap/strings.json"
    dump("data/strings.json", json.loads(strings.read_text()) if strings.is_file() else {})
    dump("data/meta.json", {"areas": AREA_NAMES})

    stale = sum(1 for u in units.values() if not u["current"])
    sev = collections.Counter(f["sev"] for f in flags)
    sev_area = collections.defaultdict(collections.Counter)
    for f in flags:
        sev_area[f["area"]][f["sev"]] += 1
    lines_by_area = collections.Counter()
    for f, d in inv.items():
        lines_by_area[file_area[f]] += d["lines"]
    esc = lambda s: html.escape(str(s or ""))
    highs = sorted((f for f in flags if f["sev"] == "high"), key=lambda f: (f["area"], f["file"]))
    st_label = {"confirmed": "confirmed", "new-in-verify": "found in verify", "later": "added later"}
    ctx = {
        "units_recorded": len(units), "units_total": len(units), "files_recorded": len(files),
        "branches": sum(len(u["branches"]) for u in units.values()), "ok": len(units) - stale, "corrected": stale,
        "unverified": stale, "n_high": sev["high"], "n_med": sev["med"], "n_low": sev["low"], "n_refuted": 0,
        "reach_none": sum(1 for u in units.values() if u.get("reach") == "none"),
        "reach_tests": sum(1 for u in units.values() if u.get("reach") == "tests-only"),
        "n_stores": len(stores), "n_multi": sum(1 for s in stores if len(s["writer_areas"]) > 1), "n_chunks": len(files), "n_verified": len(files),
    }
    tpl = (Path(__file__).parent / "report_template.html").read_text()
    for k, v in ctx.items():
        tpl = tpl.replace("{{" + k + "}}", f"{v:,}")
    tpl = tpl.replace("{{HIGH_ROWS}}", "\n".join(
        f'<tr><td><span class="pill k">{esc(f["kind"])}</span></td><td>{esc(AREA_NAMES.get(f["area"], f["area"]))}</td>'
        f'<td>{esc(f["text"])}<div class="ev">{", ".join(f"<code>{esc(e)}</code>" for e in (f.get("evidence") or [])[:4])}</div></td>'
        f'<td><span class="pill s-{esc(f["status"])}">{esc(st_label.get(f["status"], f["status"]))}</span></td></tr>' for f in highs))
    tpl = tpl.replace("{{AREA_ROWS}}", "".join(
        f'<tr><td>{esc(AREA_NAMES[a])}</td><td class="n">{len(area_files.get(a, []))}</td><td class="n">{lines_by_area[a]:,}</td>'
        f'<td class="n">{area_units[a]:,}</td><td class="n hi">{sev_area[a]["high"] or ""}</td><td class="n md">{sev_area[a]["med"] or ""}</td>'
        f'<td class="n">{sev_area[a]["low"] or ""}</td></tr>' for a in AREA_NAMES if a in area_units or a in area_files))
    tpl = tpl.replace("{{KINDS}}", "".join(f'<button class="chip" data-kind="{esc(k)}" type="button">{esc(k)} <b>{n}</b></button>'
                                           for k, n in collections.Counter(f["kind"] for f in flags).most_common()))
    tpl = tpl.replace("{{WHOLE_APP}}", html.escape("\n".join(chart))).replace("{{AREA_CHARTS}}", "\n".join(blocks))
    tpl = tpl.replace("{{DEAD_TYPES}}", ", ".join(f"<code>{esc(t)}</code>" for t in dead_types) or "none")
    left = re.findall(r"\{\{[A-Za-z_]+\}\}", tpl)
    if left:
        raise SystemExit(f"report: unfilled placeholders {left}")
    (out / "index.html").write_text(tpl)
    print(f"report: {len(units)} units, {len(files)} files, {len(flags)} findings, {stale} stale records -> {out}/index.html")
    return 0
