"""A persistent, incrementally updated index of the code map, for answering `impact` without
re-reading the repository.

It lives in build/codemap-index.sqlite (untracked; deleting it is always safe) and holds every
unit, every call-graph edge with its reasons, the stores each record reads and writes, and the
4-token runs of every unit's code with how many units have each. `refresh()` brings it up to date:

  * a source file whose size or modification time differs from the last refresh is parsed again
    (inventory and Swift references), and its units, edges and runs are replaced;
  * a Swift reference is resolved again only in a changed file, or in a file that refers to a name
    whose units were added, removed or changed type or parameters (every file when a conformance
    changed), so an edit inside a function resolves only its own file;
  * protocol-requirement edges are rebuilt when a Swift file changed, build-wiring edges when a
    script, Makefile or workflow changed, and a record's calls and stores when its record changed.

The edges it holds are exactly those graph.build computes; `Index.graph()` returns them in that
form. Queries (`callers`, `callees`, `similar`, `store_users`, ...) are indexed lookups, so their
cost follows the size of the answer, not of the repository. When the code that computes any of
this changes, the index is rebuilt from scratch.
"""
from __future__ import annotations

import collections
import hashlib
import json
import math
import os
import pickle
import sqlite3
import zlib
from pathlib import Path

import graph as graphmod
import inventory as invmod
import similar

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DB = ROOT / "build/codemap-index.sqlite"
RECORDS = ROOT / "docs/codemap/records"
SOURCES = ("inventory.py", "graph.py", "similar.py", "index.py")
TEST_ROOTS = ("EmuquTests/", "EmuquUITests/")

SCHEMA = """
create table meta(k text primary key, v blob);
create table files(path text primary key, stamp text, inv blob, meta blob, refs blob);
create table units(node text primary key, file text, data blob);
create index units_file on units(file);
create table refkeys(key text, file text);
create index refkeys_key on refkeys(key);
create index refkeys_file on refkeys(file);
create table ids(id integer primary key, name text unique);
create table edges(src integer, dst integer, rank integer, reason text, grp integer);
create index edges_dst on edges(dst);
create index edges_src on edges(src);
create index edges_grp on edges(grp);
create table records(path text primary key, stamp text);
create table stores(store text, which text, node text, grp text);
create index stores_store on stores(store);
create index stores_grp on stores(grp);
create table run_files(path text primary key, stamp text, nodes blob);
create table unit_runs(id integer primary key, runs blob);
create table posting(h integer, id integer, primary key(h, id)) without rowid;
create table df(h integer primary key, n integer) without rowid;
"""


def _stamp(p: Path) -> str | None:
    try:
        st = p.stat()
    except OSError:
        return None
    return f"{st.st_mtime_ns}:{st.st_size}"


_TOKEN_IDS: dict[str, int] = {}


def _run_id(run: tuple) -> int:
    """A stable 63-bit id for a 4-token run (Python's hash() differs between processes): each
    token's CRC-32, combined positionally."""
    h = 0
    for t in run:
        c = _TOKEN_IDS.get(t)
        if c is None:
            c = _TOKEN_IDS[t] = zlib.crc32(t.encode())
        h = (h * 4294967311 + c) & 0x7FFFFFFFFFFFFFFF
    return h


def _pack(hs) -> bytes:
    import array
    return array.array("q", hs).tobytes()


def _unpack(b: bytes) -> list[int]:
    import array
    a = array.array("q")
    a.frombytes(b)
    return a.tolist()


def _sig(u: dict, meta) -> tuple:
    """What resolution depends on about a unit: name, kind, type and parameter list."""
    params = (meta[0] if meta else {}).get(f"{u['file']}::{u['key']}")
    return (u["name"] or "", u["kind"], u["type"] or "", repr(params))


class Index:
    def __init__(self, path: Path = DB):
        version = hashlib.sha256(b"".join((HERE / m).read_bytes() for m in SOURCES)).hexdigest()
        path.parent.mkdir(parents=True, exist_ok=True)
        self.con = sqlite3.connect(path)
        try:
            ok = self.con.execute("select v from meta where k='version'").fetchone()
        except sqlite3.DatabaseError:
            ok = None
        if not ok or ok[0] != version:
            self.con.close()
            for p in (path, Path(str(path) + "-journal")):
                if p.exists():
                    p.unlink()
            self.con = sqlite3.connect(path)
            self.con.executescript(SCHEMA)
            self.con.execute("insert into meta values('version', ?)", (version,))
            self.con.commit()
        self._units: dict | None = None
        self._records: dict = {}
        self._idmap: dict | None = None
        self._runs_fresh = False

    # ---------------------------------------------------------------- ids

    def id(self, name: str) -> int:
        """The integer id of a node or edge group name, made on first use."""
        if self._idmap is None:
            self._idmap = dict(self.con.execute("select name, id from ids"))
        i = self._idmap.get(name)
        if i is None:
            i = self._idmap[name] = self.con.execute("insert into ids(name) values(?)", (name,)).lastrowid
        return i

    def _ids(self, names) -> dict[str, int]:
        return {n: self.id(n) for n in set(names)}

    def _put_edges(self, rows, grp: str) -> None:
        """Store (src, dst, kind, reason) contributions under one group, replacing what it had."""
        g = self.id(grp)
        self.con.execute("delete from edges where grp=?", (g,))
        rows = list(rows)
        ids = self._ids([r[0] for r in rows] + [r[1] for r in rows])
        self.con.executemany("insert into edges values(?,?,?,?,?)",
                             [(ids[a], ids[b], graphmod.RANK[k], why, g) for a, b, k, why in rows])

    # ---------------------------------------------------------------- refresh

    def refresh(self) -> dict:
        """Bring the index up to date with the working tree. Returns what was redone."""
        con = self.con
        self._units = None
        self._runs_fresh = False
        tracked = invmod.tracked_files(ROOT)
        now = {f: _stamp(ROOT / f) for f in tracked}
        now = {f: s for f, s in now.items() if s is not None}
        before = dict(con.execute("select path, stamp from files"))
        changed = sorted(f for f, s in now.items() if before.get(f) != s)
        removed = sorted(before.keys() - now.keys())
        done = {"files": len(changed) + len(removed), "resolved": 0, "records": 0}
        if changed or removed:
            self._refresh_files(changed, removed, done)
        self._refresh_records(done)
        con.commit()
        self._units = None
        return done

    def _refresh_files(self, changed: list[str], removed: list[str], done: dict) -> None:
        con = self.con
        fresh = invmod.inventory(ROOT, only=set(changed)) if changed else {}
        affected: set[str] = set()
        conf_changed: set[str] = set()      # types whose declared conformances changed
        old_conf_edges: set[tuple] = set()  # (type, parent) pairs as they were
        held_changed: set[str] = set()      # types whose stored values hold different types
        old_held_edges: set[tuple] = set()  # (type, held type) pairs as they were
        swift_changed, ns_changed = False, False
        for f in changed + removed:
            row = con.execute("select inv, meta from files where path=?", (f,)).fetchone()
            old_inv, old_meta = (pickle.loads(row[0]), pickle.loads(row[1]) if row[1] else None) if row else (None, None)
            new_inv = fresh.get(f)
            new_meta = refs = None
            if new_inv is not None and f.endswith(".swift"):
                raw = (ROOT / f).read_bytes()
                refs, params, conf, clos, held = graphmod.swift_file(f, raw, new_inv["units"])
                new_meta = (params, conf, clos, held)
            swift_changed |= f.endswith(".swift")
            ns_changed |= bool(invmod.NS_CODE.search(f))
            # what resolution elsewhere depends on: each unit's name, kind, type and parameters,
            # conformances and stored-closure names
            old_units = {f"{f}::{u['key']}": {"file": f, **u} for u in (old_inv or {}).get("units", [])}
            new_units = {f"{f}::{u['key']}": {"file": f, **u} for u in (new_inv or {}).get("units", [])}
            for n in old_units.keys() | new_units.keys():
                a, b = old_units.get(n), new_units.get(n)
                if a is None or b is None or _sig(a, old_meta) != _sig(b, new_meta):
                    for u in (a, b):
                        if u is None:
                            continue
                        affected.add("n:" + (u["name"] or ""))
                        t = graphmod.short(u["type"])
                        if t:
                            affected |= {"n:" + t, "t:" + t}
            om, nm = old_meta or ({}, {}, {}, {}), new_meta or ({}, {}, {}, {})
            for t in om[3].keys() | nm[3].keys():
                if om[3].get(t) != nm[3].get(t):
                    held_changed.add(t)
                    old_held_edges |= {(t, h) for h in om[3].get(t, ())}
            for t in om[1].keys() | nm[1].keys():
                if om[1].get(t) != nm[1].get(t):
                    conf_changed.add(t)
                    old_conf_edges |= {(t, p) for p in om[1].get(t, ())}
            for name in om[2].keys() | nm[2].keys():
                if om[2].get(name) != nm[2].get(name):
                    affected.add("n:" + name)
            # replace the file's rows
            con.execute("delete from units where file=?", (f,))
            con.execute("delete from refkeys where file=?", (f,))
            self._put_edges([], "swift:" + f)
            con.execute("delete from files where path=?", (f,))
            if new_inv is None:
                continue
            con.execute("insert into files values(?,?,?,?,?)", (
                f, _stamp(ROOT / f), pickle.dumps(new_inv),
                pickle.dumps(new_meta) if new_meta else None, pickle.dumps(refs) if refs is not None else None))
            nodes = {f"{f}::": {"file": f, "key": "", "kind": "file", "name": f, "type": "", "start": 1, "end": new_inv["lines"]}}
            nodes.update(new_units)
            con.executemany("insert into units values(?,?,?)", [(n, f, pickle.dumps(u)) for n, u in nodes.items()])
            if refs:
                keys = set()
                for rs in refs.values():
                    for _, name, _, _, (_, rtype) in rs:
                        keys.add("n:" + (name or ""))
                        if rtype:
                            keys |= {"t:" + rtype, "t:" + graphmod.short(rtype)}
                con.executemany("insert into refkeys values(?,?)", [(k, f) for k in keys])
        # resolve again: changed Swift files, and every file referring to an affected name
        units = self.units()
        if conf_changed:
            # A type's family (itself, its ancestors and protocols) changed for every type that
            # reaches a changed one, before or after: their own-type and typed-receiver references.
            down = collections.defaultdict(set)
            for (m,) in con.execute("select meta from files where meta is not null"):
                for t, ps in pickle.loads(m)[1].items():
                    for p in ps:
                        down[p].add(t)
            for t, p in old_conf_edges:
                down[p].add(t)
            reach, todo_t = set(), list(conf_changed)
            while todo_t:
                x = todo_t.pop()
                if x not in reach:
                    reach.add(x)
                    todo_t.extend(down.get(x, ()))
            for t in reach:
                affected |= {"n:" + t, "t:" + t}
            own_files = {u["file"] for u in units.values() if graphmod.short(u.get("type")) in reach}
        else:
            own_files = set()
        if held_changed:
            # decoding a type reaches what it holds, transitively: every type that holds a changed
            # one, before or after, resolves its `T.self` references differently
            up = collections.defaultdict(set)
            for (m,) in con.execute("select meta from files where meta is not null"):
                for t, hs in pickle.loads(m)[3].items():
                    for h in hs:
                        up[h].add(t)
            for t, h in old_held_edges:
                up[h].add(t)
            reach, todo_t = set(), list(held_changed)
            while todo_t:
                x = todo_t.pop()
                if x not in reach:
                    reach.add(x)
                    todo_t.extend(up.get(x, ()))
            for t in reach:
                affected |= {"n:" + t, "t:" + t}
        todo = {f for f in changed if f.endswith(".swift")} | {f for f in own_files if f.endswith(".swift")}
        for k in affected:
            todo |= {f for (f,) in con.execute("select file from refkeys where key=?", (k,))}
        if todo or swift_changed:
            swift = {f: pickle.loads(m) for f, m in con.execute("select path, meta from files where meta is not null")}
            r = graphmod.Resolver(units, {f: ({},) + m for f, m in swift.items()})
            for f in sorted(todo):
                row = con.execute("select refs from files where path=?", (f,)).fetchone()
                if not row or row[0] is None:
                    continue
                self._put_edges(r.resolve_file(pickle.loads(row[0])), "swift:" + f)
            done["resolved"] = len(todo)
            self._put_edges(r.protocol_edges() + r.format_edges(), "proto")
        if ns_changed:
            inv = {f: pickle.loads(b) for f, b in con.execute("select path, inv from files")}
            self._put_edges(graphmod.wiring_edges(
                {f: d for f, d in inv.items() if invmod.NS_CODE.search(f)}, ROOT, units), "wire")

    def _refresh_runs(self) -> None:
        """Bring the 4-token runs up to date for files whose content changed since they were last
        tokenized. Only `similar` needs them, so commands that never ask do not pay for them."""
        if self._runs_fresh:
            return
        con = self.con
        now = dict(con.execute("select path, stamp from files"))
        before = {f: (st, pickle.loads(nodes)) for f, st, nodes in con.execute("select path, stamp, nodes from run_files")}
        for f in sorted(before.keys() | now.keys()):
            if f in before and before[f][0] == now.get(f):
                continue
            if f in before:
                self._drop_runs(before[f][1])
                con.execute("delete from run_files where path=?", (f,))
            if f not in now:
                continue
            nodes = {}
            if not f.endswith(".md"):
                inv = pickle.loads(con.execute("select inv from files where path=?", (f,)).fetchone()[0])
                if inv["units"]:
                    lines = (ROOT / f).read_text(errors="replace").split("\n")
                    hashed = not f.endswith((".swift", ".c", ".m", ".h"))
                    nodes = {f"{f}::{u['key']}": similar.shingles("\n".join(lines[u["start"] - 1:u["end"]]), hashed)
                             for u in inv["units"]}
                    self._add_runs(nodes)
            con.execute("insert into run_files values(?,?,?)", (f, now[f], pickle.dumps(sorted(nodes))))
        con.commit()
        self._runs_fresh = True

    def _drop_runs(self, nodes: list[str]) -> None:
        con = self.con
        ids = [self.id(n) for n in nodes]
        dec, gone = collections.Counter(), []
        for i in ids:
            row = con.execute("select runs from unit_runs where id=?", (i,)).fetchone()
            if row:
                hs = _unpack(row[0])
                dec.update(hs)
                gone += [(h, i) for h in hs]
        con.executemany("update df set n = n - ? where h=?", [(c, h) for h, c in dec.items()])
        con.executemany("delete from posting where h=? and id=?", gone)
        con.executemany("delete from unit_runs where id=?", [(i,) for i in ids])
        if dec:
            con.execute("delete from df where n <= 0")

    def _add_runs(self, sets: dict) -> None:
        rows, posting, inc = [], [], collections.Counter()
        for n, runs in sets.items():
            i = self.id(n)
            hs = sorted({_run_id(r) for r in runs})
            rows.append((i, _pack(hs)))
            posting += [(h, i) for h in hs]
            inc.update(hs)
        con = self.con
        con.executemany("insert into unit_runs values(?,?)", rows)
        con.executemany("insert into posting values(?,?)", posting)
        con.executemany("insert into df values(?, ?) on conflict(h) do update set n = n + excluded.n", list(inc.items()))

    def _refresh_records(self, done: dict) -> None:
        con = self.con
        now = {}
        for dirpath, _, names in os.walk(RECORDS):
            for name in names:
                if name.endswith(".json"):
                    p = Path(dirpath) / name
                    now[str(p.relative_to(RECORDS))[:-5]] = _stamp(p)
        before = dict(con.execute("select path, stamp from records"))
        for f in sorted(before.keys() | now.keys()):
            if before.get(f) == now.get(f):
                continue
            done["records"] += 1
            self._put_edges([], "rec:" + f)
            con.execute("delete from stores where grp=?", ("rec:" + f,))
            con.execute("delete from records where path=?", (f,))
            if f not in now:
                continue
            rec = json.loads((RECORDS / (f + ".json")).read_text(encoding="utf-8"))
            self._put_edges(graphmod.recorded_edges({rec["file"]: rec}), "rec:" + f)
            rows = []
            for u in rec.get("units", []):
                for which in ("reads", "writes"):
                    for st in u.get(which) or []:
                        if isinstance(st, str) and ":" in st:
                            rows.append((st.split(" (")[0].strip(), which, f"{rec['file']}::{u['key']}", "rec:" + f))
            con.executemany("insert into stores values(?,?,?,?)", rows)
            con.execute("insert into records values(?,?)", (f, now[f]))

    # ---------------------------------------------------------------- queries

    def units(self) -> dict:
        """Every unit (and file node), as graph.build's `units`."""
        if self._units is None:
            self._units = {n: pickle.loads(d) for n, d in self.con.execute("select node, data from units")}
        return self._units

    def unit(self, node: str) -> dict | None:
        row = self.con.execute("select data from units where node=?", (node,)).fetchone()
        return pickle.loads(row[0]) if row else None

    def _combine(self, rows) -> tuple[dict, dict]:
        kinds, why = {}, collections.defaultdict(set)
        names = {v: k for k, v in graphmod.RANK.items()}
        for other, rank, reason in rows:
            if rank > graphmod.RANK.get(kinds.get(other), -1):
                kinds[other] = names[rank]
            if rank > 0:
                why[other].add(reason)
        return kinds, why

    def callers(self, node: str) -> dict[str, str]:
        """{caller: certain|possible}, as graph.callers(graph)[node]."""
        return self.callers_why(node)[0]

    def callers_why(self, node: str) -> tuple[dict, dict]:
        """({caller: kind}, {caller: reasons a certain edge is certain})."""
        if self.unit(node) is None:
            return {}, {}
        rows = self.con.execute(
            "select i.name, e.rank, e.reason from edges e join ids i on i.id = e.src join units u on u.node = i.name "
            "where e.dst = (select id from ids where name=?) and e.src != e.dst", (node,))
        return self._combine(rows)

    def callees(self, node: str) -> dict[str, str]:
        if self.unit(node) is None:
            return {}
        rows = self.con.execute(
            "select i.name, e.rank, e.reason from edges e join ids i on i.id = e.dst join units u on u.node = i.name "
            "where e.src = (select id from ids where name=?) and e.src != e.dst", (node,))
        return self._combine(rows)[0]

    def graph(self) -> dict:
        """The whole graph in graph.build's form."""
        units = self.units()
        rows = self.con.execute("select s.name, d.name, case e.rank when 2 then 'certain' when 1 then 'implicit' else 'possible' end, e.reason "
                                "from edges e join ids s on s.id = e.src join ids d on d.id = e.dst")
        return graphmod.assemble(rows, units)

    def record(self, f: str) -> dict | None:
        """The record of file `f` with the overlay's findings, read once per index."""
        if f not in self._records:
            import codemap
            self._records[f] = codemap.load(f)
        return self._records[f]

    def store_users(self, store: str) -> dict[str, set[str]]:
        out = {"reads": set(), "writes": set()}
        for which, node in self.con.execute("select which, node from stores where store=?", (store,)):
            out[which].add(node)
        return out

    def test_classes(self) -> set[str]:
        out = set()
        for (d,) in self.con.execute("select data from units where file like 'EmuquTests/%' or file like 'EmuquUITests/%'"):
            u = pickle.loads(d)
            if (u.get("name") or "").startswith("test"):
                out.add(f"{u['file'].split('/')[0]}/{(u.get('type') or '').split('.')[0]}")
        return out

    def similar(self, node: str, minimum: float = 0.35, limit: int = 15) -> list[tuple[str, float]]:
        """The same answer as similar.Index(...).similar(node), from the stored runs."""
        self._refresh_runs()
        con = self.con
        n = con.execute("select count(*) from unit_runs").fetchone()[0] or 1
        row = con.execute("select u.id, u.runs from unit_runs u join ids i on i.id = u.id where i.name=?", (node,)).fetchone()
        if not row:
            return []
        me, mine = row[0], _unpack(row[1])
        df = self._df(mine)
        idf = lambda c: math.log(n / max(c, 1))
        total = sum(idf(df.get(h, 0)) for h in mine)
        if total < 25:
            return []
        shared = collections.defaultdict(list)
        rare = [h for h in mine if df.get(h, 0) <= 50]
        for i in range(0, len(rare), 500):
            chunk = rare[i:i + 500]
            for h, other in con.execute(f"select h, id from posting where h in ({','.join('?' * len(chunk))})", chunk):
                if other != me:
                    shared[other].append(h)
        out = []
        for other, hs in shared.items():
            w = sum(idf(df[h]) for h in hs)
            theirs_runs = _unpack(con.execute("select runs from unit_runs where id=?", (other,)).fetchone()[0])
            if w / max(total, w) < minimum:
                continue
            tdf = self._df(theirs_runs)
            score = w / max(total, sum(idf(tdf.get(h, 0)) for h in theirs_runs))
            if score >= minimum:
                name = con.execute("select name from ids where id=?", (other,)).fetchone()[0]
                out.append((name, round(score, 2)))
        out.sort(key=lambda x: (-x[1], x[0]))
        return out[:limit]

    def _df(self, hs: list[int]) -> dict[int, int]:
        out = {}
        for i in range(0, len(hs), 500):
            chunk = hs[i:i + 500]
            out.update(self.con.execute(f"select h, n from df where h in ({','.join('?' * len(chunk))})", chunk))
        return out

    def inv(self, f: str) -> dict | None:
        """One file's inventory entry, or None when the file is not in scope."""
        row = self.con.execute("select inv from files where path=?", (f,)).fetchone()
        return pickle.loads(row[0]) if row else None

    def named_like(self, name: str) -> list[str]:
        """Units whose node contains `name`, sorted."""
        return sorted(n for (n,) in self.con.execute("select node from units where instr(node, ?) > 0", (name,)))

    def inventory(self) -> dict:
        """The inventory as inventory.inventory returns it, from the stored per-file entries."""
        return {f: pickle.loads(b) for f, b in self.con.execute("select path, inv from files")}


class View:
    """A read-only mapping over an index query, for code written against graph dicts:
    `view.get(node, {})` returns the query's answer for that node."""

    def __init__(self, query):
        self.query = query

    def get(self, key, default=None):
        found = self.query(key)
        return found if found else (default if default is not None else found)

    def __contains__(self, key):
        return self.query(key) is not None

    def __getitem__(self, key):
        found = self.query(key)
        if found is None:
            raise KeyError(key)
        return found


def open_index() -> Index:
    """The index, brought up to date."""
    ix = Index()
    ix.refresh()
    return ix


def verify() -> int:
    """Compare the index's graph and inventory with a full build from scratch. 0 when identical."""
    import codemap
    ix = open_index()
    inv = invmod.inventory(ROOT)
    full = graphmod.build(inv, codemap.all_records(), ROOT)
    mine = ix.graph()
    same = {"inventory": ix.inventory() == inv, "units": mine["units"] == full["units"],
            "edges": mine["edges"] == full["edges"], "why": mine["why"] == full["why"]}
    for k, ok in same.items():
        print(f"{k}: {'identical' if ok else 'DIFFERENT'}")
    return 0 if all(same.values()) else 1


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--verify"]:
        sys.exit(verify())
    done = open_index().refresh()
    print(f"index: {done['files']} file(s) re-read, {done['resolved']} re-resolved, {done['records']} record(s) re-read")
