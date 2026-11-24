"""The code map's call graph, built mechanically from the code and merged with the recorded calls.

Nodes are unit keys (`path::key`) plus one node per file for its file-level record (`path::`).
Edges are `certain` or `possible`:

  certain   the target is the only unit the reference can mean: a call or property read on
            `self`, `super`, an implicit self or a named type that matches exactly one unit of that
            type (or its extensions, superclass or protocols); a free call matching one global
            function; a member reference whose name and argument labels match exactly one unit in
            the whole repository and is not a common library name; a call recorded by a reader;
            a protocol requirement to each implementation; a Makefile prerequisite or recipe call;
            a workflow step's `make` target or script; a same-file Python or shell function call.
  possible  the reference matches more than one unit and nothing narrows it (no type checker
            runs here), or a call to a stored closure that some unit assigns.

Without a compiler the graph cannot be exact. `certain` edges are what the dependency re-check
uses; `possible` edges are listed by the impact report so a change can be checked against them.
"""
from __future__ import annotations

import collections
import re
from pathlib import Path

from inventory import NS_CODE

# Member names so common in Swift, Foundation and SwiftUI that a repo unit with the same name is
# not evidence the reference means it when the receiver's type is unknown.
COMMON = set("""
count isEmpty first last description debugDescription id body value values name data date start end
map compactMap flatMap filter reduce forEach append insert remove removeAll contains sorted sort min max
prefix suffix dropFirst dropLast joined split lowercased uppercased trimmingCharacters replacingOccurrences
keys index firstIndex lastIndex enumerated zip isNaN isFinite rounded magnitude
string text title label color font image view key url path absoluteString lastPathComponent
reset clear load save update refresh start stop cancel run send close open fetch apply
duration seconds minutes hours timeIntervalSince distance addingTimeInterval
""".split())

# Parents under which a simple_identifier is a declaration, a label, a type or a member name, not a
# reference to a property or function by its bare name.
NOT_A_REFERENCE = {
    "navigation_suffix", "value_argument_label", "parameter", "pattern", "function_declaration",
    "class_declaration", "protocol_declaration", "property_declaration", "user_type", "type_identifier",
    "enum_entry", "import_declaration", "lambda_parameter", "typealias_declaration", "init_declaration",
    "protocol_function_declaration", "subscript_declaration", "type_annotation", "inheritance_specifier",
    "identifier", "attribute", "external_name", "capture_list_item", "switch_pattern", "binding_pattern",
    "tuple_type_item", "protocol_property_declaration", "associatedtype_declaration", "precedence_group_declaration",
    "operator_declaration", "macro_invocation", "key_path_expression", "enum_type_parameters",
}

FUNC_KINDS = ("function_declaration", "protocol_function_declaration", "function_declaration(fallback)",
              "init_declaration", "subscript_declaration", "ns-cfunc", "ns-objcmethod")
PROP_KINDS = ("computed", "observed", "closure-init")


def _swift_refs(raw: bytes, parser, units: list[dict]):
    """References made inside each unit, the parameter lists of the file's functions, the
    conformances declared in the file, and the names of stored closures each unit assigns."""
    tree = parser.parse(raw)

    def txt(n):
        return raw[n.start_byte:n.end_byte].decode(errors="replace")

    by_start = {u["start"]: u for u in units}
    refs = collections.defaultdict(list)          # unit start line -> [ref]
    params = {}                                   # unit start line -> [(label, has_default)]
    conforms = collections.defaultdict(set)       # type name -> {inherited names}
    closure_assigns = collections.defaultdict(set)  # name -> {unit start}

    def arg_labels(call):
        labels, trailing = [], 0
        for c in call.children:
            if c.type != "call_suffix":
                continue
            for a in c.children:
                if a.type == "value_arguments":
                    for v in a.children:
                        if v.type == "value_argument":
                            lab = v.child_by_field_name("name")
                            labels.append(txt(lab).strip() if lab else "_")
                elif a.type == "lambda_literal":
                    trailing += 1
        return labels, trailing

    def receiver(target):
        if target is None:
            return ("implicit", None)
        if target.type == "self_expression":
            return ("self", None)
        if target.type == "super_expression":
            return ("super", None)
        if target.type == "call_expression" and target.children and target.children[0].type == "simple_identifier" \
                and txt(target.children[0])[:1].isupper():
            return ("type", txt(target.children[0]))
        t = txt(target)
        if t == "Self":
            return ("self", None)
        if re.fullmatch(r"[A-Z]\w*(\.[A-Z]\w*)*", t):
            return ("type", t.split(".")[-1])
        return ("unknown", None)

    def walk(n, cur):
        if n.type in ("class_declaration", "protocol_declaration"):
            nm = n.child_by_field_name("name")
            name = txt(nm).split("<")[0].split(".")[-1] if nm else "?"
            for c in n.children:
                if c.type == "inheritance_specifier":
                    conforms[name].add(txt(c).split("<")[0].split(".")[-1].strip())
        u = by_start.get(n.start_point[0] + 1)
        if u is not None and n.type in (
                "function_declaration", "init_declaration", "deinit_declaration", "subscript_declaration",
                "protocol_function_declaration", "property_declaration"):
            cur = u["start"]
            if n.type != "property_declaration":
                ps, last = [], None
                for c in n.children:
                    if c.type == "parameter":
                        ext = c.child_by_field_name("external_name")
                        nm = c.child_by_field_name("name")
                        ps.append([txt(ext) if ext else txt(nm) if nm else "_", False])
                        last = ps[-1]
                    elif c.type == "=" and last is not None:
                        last[1] = True
                params[cur] = [tuple(p) for p in ps]
        if cur is not None:
            if n.type == "call_expression" and n.children:
                head = n.children[0]
                labels, trailing = arg_labels(n)
                # `!f(x)` and `-f(x)` parse as a call whose callee is the prefix expression.
                while head.type == "prefix_expression" and not txt(head).startswith(".") and head.child_by_field_name("target") is not None:
                    head = head.child_by_field_name("target")
                if head.type == "simple_identifier":
                    refs[cur].append(("call", txt(head), labels, trailing, ("implicit", None)))
                elif head.type == "navigation_expression":
                    suf = head.child_by_field_name("suffix")
                    name = txt(suf).lstrip(".") if suf else ""
                    refs[cur].append(("call", name, labels, trailing, receiver(head.child_by_field_name("target"))))
                elif head.type == "prefix_expression" and txt(head).startswith("."):
                    refs[cur].append(("call", txt(head)[1:], labels, trailing, ("unknown", None)))
            elif n.type == "navigation_expression" and not (n.parent is not None and n.parent.type == "call_expression"
                                                            and n.parent.children and n.parent.children[0] == n):
                suf = n.child_by_field_name("suffix")
                if suf is not None:
                    refs[cur].append(("prop", txt(suf).lstrip("."), None, 0, receiver(n.child_by_field_name("target"))))
            elif n.type == "simple_identifier" and n.parent is not None and n.parent.type not in NOT_A_REFERENCE \
                    and not (n.parent.type == "call_expression" and n.parent.children and n.parent.children[0] == n):
                refs[cur].append(("prop", txt(n), None, 0, ("implicit", None)))
            elif n.type == "assignment":
                tgt = n.child_by_field_name("target")
                res = n.child_by_field_name("result")
                if tgt is not None and res is not None and res.type == "lambda_literal":
                    m = re.search(r"(\w+)\s*$", txt(tgt))
                    if m:
                        closure_assigns[m.group(1)].add(cur)
        for c in n.children:
            walk(c, cur)

    walk(tree.root_node, None)
    return refs, params, conforms, closure_assigns


TEST_TARGETS = ("EmuquTests/", "EmuquUITests/")


def is_test_file(node: str) -> bool:
    """Whether a node (`path::key`) is in a test target."""
    return node.startswith(TEST_TARGETS)


def _labels_match(decl: list[tuple[str, bool]] | None, labels: list[str], trailing: int) -> bool:
    """Whether a call's argument labels (plus trailing closures) can bind to a parameter list,
    allowing parameters with default values to be skipped."""
    if decl is None:
        return True
    i = 0
    for lab in labels:
        while i < len(decl) and decl[i][0] != lab and decl[i][1]:
            i += 1
        if i >= len(decl) or decl[i][0] != lab:
            return False
        i += 1
    rest = decl[i:]
    required = [p for p in rest if not p[1]]
    return len(required) <= trailing <= len(rest)


def build(inv: dict, records: dict, root: Path) -> dict:
    """{"edges": {src: {dst: "certain"|"possible"}}, "units": {node: inventory entry plus its file},
    "why": {(src, dst): reasons}}, built from scratch: every Swift file parsed and every reference
    resolved. The code map's commands read the same graph, kept up to date incrementally, from
    index.py; this is the definition it is checked against (`index.py --verify`)."""
    units = unit_table(inv)
    found = recorded_edges(records)
    swift = {f: swift_file(f, (root / f).read_bytes(), inv[f]["units"]) for f in inv if f.endswith(".swift")}
    r = Resolver(units, swift)
    for refs, _, _, _ in swift.values():
        found += r.resolve_file(refs)
    found += r.protocol_edges()
    found += wiring_edges(inv, root, units)
    return assemble(found, units)


def unit_table(inv: dict) -> dict:
    """{node: inventory entry plus its file} for every unit, and a `file` node per file."""
    units = {}
    for f, d in inv.items():
        units[f"{f}::"] = {"file": f, "key": "", "kind": "file", "name": f, "type": "", "start": 1, "end": d["lines"]}
        for u in d["units"]:
            units[f"{f}::{u['key']}"] = {"file": f, **u}
    return units


def assemble(found, units: dict) -> dict:
    """The graph from (src, dst, kind, reason) contributions: an edge from or to a node that does not
    exist, or to itself, is dropped; an edge is certain when any contribution is (never downgraded), and a
    certain edge keeps every reason that made it certain."""
    edges = collections.defaultdict(dict)
    why = collections.defaultdict(set)
    for a, b, kind, reason in found:
        if a == b or a not in units or b not in units:
            continue
        if edges[a].get(b) != "certain":
            edges[a][b] = kind
        if kind == "certain":
            why[(a, b)].add(reason)
    return {"edges": {k: dict(v) for k, v in edges.items()}, "units": units,
            "why": {k: sorted(v) for k, v in why.items()}}


def recorded_edges(records: dict) -> list:
    """Certain edges for every `path::key` a record's `calls` names (reader-resolved)."""
    out = []
    for f, rec in records.items():
        for u in rec.get("units", []):
            src = f"{f}::{u['key']}"
            for c in u.get("calls") or []:
                if isinstance(c, str) and "::" in c and not c.startswith(("ext:", "dyn:", "closure:")):
                    out.append((src, c, "certain", "recorded"))
    return out


_PARSER = []


def swift_file(f: str, raw: bytes, us: list[dict]):
    """One Swift file's (references by node, parameter lists by node, conformances, closure
    assignments by name), with unit start lines turned into node keys."""
    if not _PARSER:
        import tree_sitter as ts
        import tree_sitter_swift as tss
        _PARSER.append(ts.Parser(ts.Language(tss.language())))
    refs, params, conf, clos = _swift_refs(raw, _PARSER[0], us)
    key_at = {u["start"]: f"{f}::{u['key']}" for u in us}
    return ({key_at[s]: rs for s, rs in refs.items() if s in key_at},
            {key_at[s]: ps for s, ps in params.items() if s in key_at},
            {t: set(v) for t, v in conf.items()},
            {n: {key_at[s] for s in starts if s in key_at} for n, starts in clos.items()})


def short(t):
    return (t or "").split(".")[-1]


class Resolver:
    """Resolves Swift references against every unit, given each Swift file's swift_file data."""

    def __init__(self, units: dict, swift: dict):
        self.units = units
        self.params, self.conforms, self.closure_assigns = {}, collections.defaultdict(set), collections.defaultdict(set)
        for refs, params, conf, clos in swift.values():
            self.params.update(params)
            for t, v in conf.items():
                self.conforms[t] |= v
            for n, v in clos.items():
                self.closure_assigns[n] |= v
        self.by_name = collections.defaultdict(list)
        for k, u in units.items():
            if u["kind"] != "file" and (k.split("::")[0].endswith(".swift") or u["kind"] in ("ns-cfunc", "ns-objcmethod")):
                self.by_name[u["name"]].append(k)
        # A receiver typed by a framework type (Text, Date, Array...) says nothing about which repo
        # extension it reaches, so it is resolved like an unknown receiver.
        self.repo_types = {short(u["type"]) for u in units.values() if u["type"]} | set(self.conforms)

    def family(self, t):
        """A type with its ancestors and protocols, transitively."""
        out, todo = set(), [short(t)]
        while todo:
            x = todo.pop()
            if x and x not in out:
                out.add(x)
                todo.extend(self.conforms.get(x, ()))
        return out

    def takes_arguments(self, k):
        """A function or initializer with a parameter that has no default value."""
        return self.units[k]["kind"] in FUNC_KINDS and any(not d for _, d in self.params.get(k) or [])

    def candidates(self, name, kind, labels, trailing, types=None, global_only=False):
        out = []
        for k in self.by_name.get(name, ()):
            u = self.units[k]
            if kind == "call" and u["kind"] not in FUNC_KINDS and u["kind"] not in PROP_KINDS:
                continue
            if kind == "prop" and u["kind"] not in PROP_KINDS and u["kind"] not in FUNC_KINDS:
                continue
            if kind == "call" and u["kind"] in FUNC_KINDS and not _labels_match(self.params.get(k), labels, trailing):
                continue
            if global_only and u["type"]:
                continue
            if types is not None and short(u["type"]) not in types:
                continue
            out.append(k)
        return out

    def resolve_file(self, refs: dict) -> list:
        """(src, dst, kind, reason) for every reference in one file's units."""
        return [(src, dst, kind, reason) for src, rs in refs.items() for dst, kind, reason in self.resolve(src, rs)]

    def resolve(self, src, rs):
        """The edges one unit's references resolve to: [(dst, kind, reason)]."""
        units, by_name, repo_types, closure_assigns = self.units, self.by_name, self.repo_types, self.closure_assigns
        candidates, family, takes_arguments, params = self.candidates, self.family, self.takes_arguments, self.params
        found = []
        own = family(units[src]["type"])
        for kind, name, labels, trailing, (rkind, rtype) in rs:
            if not name or name in ("self", "super"):
                continue
            if kind == "call" and rkind == "implicit" and name in repo_types:
                cs = [k for k in by_name.get("init", ()) if short(units[k]["type"]) == name
                      and _labels_match(params.get(k), labels or [], trailing)]
                for k in cs:
                    found.append((k, "certain" if len(cs) == 1 else "possible", "initializer"))
                continue
            unresolved = False  # the receiver's type is unknown, or a framework type
            if rkind in ("self", "super", "implicit"):
                reason = "own type"
                cs = candidates(name, kind, labels or [], trailing, types=own)
                if not cs and rkind == "implicit":
                    # a unit whose type is unknown (parse fallback) or a file-private helper
                    same_file = [k for k in candidates(name, kind, labels or [], trailing)
                                 if k.split("::")[0] == src.split("::")[0]]
                    reason = "same file" if same_file else "global function"
                    cs = same_file or candidates(name, kind, labels or [], trailing, global_only=True)
            elif rkind == "type" and rtype in repo_types:
                reason = "typed receiver"
                cs = candidates(name, kind, labels or [], trailing, types=family(rtype))
            else:
                unresolved = True
                reason = "unique name"
                cs = candidates(name, kind, labels or [], trailing)
            # Certainty is judged on every unit the name could mean. The filters below drop
            # candidates the reference cannot mean; they never promote what is left, so they only
            # remove edges.
            sole = len(cs) == 1 and not (unresolved and name in COMMON)
            if kind == "prop" and unresolved:
                # `x.name` on a receiver of unknown or framework type reads a value: not a
                # function that needs arguments (a function passed as a value is reached through a
                # repo-typed or implicit receiver).
                cs = [k for k in cs if not takes_arguments(k)]
            if not is_test_file(src):
                # App code is not linked with the test bundle: a match in a test target is a
                # name collision, never a call.
                cs = [k for k in cs if not is_test_file(k)]
            if kind == "prop" and rkind == "implicit" and not cs:
                continue
            for k in cs:
                found.append((k, "certain" if sole else "possible", reason))
            if kind == "call" and not cs and name in closure_assigns:
                for k in closure_assigns[name]:
                    found.append((k, "possible", "stored closure"))
        return found

    def protocol_edges(self) -> list:
        """A certain edge from each protocol requirement to each same-named, label-compatible function
        of a type that conforms to the protocol."""
        out = []
        for k, u in self.units.items():
            if u["kind"] != "protocol_function_declaration":
                continue
            proto = short(u["type"])
            impl_types = {t for t, s in self.conforms.items() if proto in s} | {proto}
            for c in self.by_name.get(u["name"], ()):
                v = self.units[c]
                if c != k and v["kind"] in FUNC_KINDS and v["kind"] != "protocol_function_declaration" \
                        and short(v["type"]) in impl_types and _labels_match(self.params.get(c), [p[0] for p in self.params.get(k, [])], 0):
                    out.append((k, c, "certain", "protocol requirement"))
        return out


def wiring_edges(inv: dict, root: Path, units: dict) -> list:
    """Certain edges between scripts, Makefile targets and workflow jobs and steps: a target to its
    prerequisites; recipes, jobs and steps to the targets they make and the scripts they run; a
    job to its steps; script functions to the local (and, in Python, imported) functions they
    name; and a script's top-level code to its functions and the scripts it runs."""
    out = []

    def add(a, b, kind, reason):
        out.append((a, b, kind, reason))

    # ---- scripts, Makefile, workflows
    targets = {u["name"].split()[0]: k for k, u in units.items() if u["kind"] == "ns-target"}
    for f, d in inv.items():
        if not NS_CODE.search(f):
            continue
        lines = (root / f).read_text(errors="replace").split("\n")
        local = {u["name"]: f"{f}::{u['key']}" for u in d["units"] if u["kind"] in ("ns-pydef", "ns-shfunc")}
        if f.endswith(".py"):
            # `from module import a, b` / `import module` resolve to top-level defs of a sibling module
            text = "\n".join(lines)
            here = str(Path(f).parent)
            for m in re.finditer(r"^\s*from\s+([\w.]+)\s+import\s+([\w, ]+)", text, re.M):
                mod = f"{here}/{m.group(1).replace('.', '/')}.py" if here != "." else f"{m.group(1).replace('.', '/')}.py"
                for name in (x.strip() for x in m.group(2).split(",")):
                    k = f"{mod}::def {name}"
                    if k in units:
                        local.setdefault(name, k)
            for m in re.finditer(r"^\s*import\s+([\w.]+)", text, re.M):
                mod = f"{here}/{m.group(1).replace('.', '/')}.py" if here != "." else f"{m.group(1).replace('.', '/')}.py"
                for v in inv.get(mod, {}).get("units", []):
                    if v["kind"] == "ns-pydef" and "." not in v["key"][4:]:
                        local.setdefault(f"{m.group(1)}.{v['name']}", f"{mod}::{v['key']}")
        for u in d["units"]:
            src = f"{f}::{u['key']}"
            body = "\n".join(lines[u["start"] - 1:u["end"]])
            if u["kind"] == "ns-target":
                pre = lines[u["start"] - 1].split(":", 1)[1] if ":" in lines[u["start"] - 1] else ""
                for t in pre.split():
                    if t in targets:
                        add(src, targets[t], "certain", "build wiring")
            if u["kind"] in ("ns-target", "ns-step", "ns-job"):
                for m in re.finditer(r"\b(?:make|\$\(MAKE\))\s+([\w .-]+)", body):
                    for t in m.group(1).split():
                        if t in targets:
                            add(src, targets[t], "certain", "build wiring")
                for m in re.finditer(r"((?:scripts|Tools)/[\w/.+-]+\.(?:sh|py))", body):
                    add(src, f"{m.group(1)}::", "certain", "build wiring")
            if u["kind"] == "ns-job":
                for v in d["units"]:
                    if v["kind"] == "ns-step" and v["type"] == u["name"]:
                        add(src, f"{f}::{v['key']}", "certain", "build wiring")
            if u["kind"] in ("ns-pydef", "ns-shfunc"):
                for name, k in local.items():
                    if name != u["name"] and re.search(rf"(?<![\w.]){re.escape(name)}\b", body):
                        add(src, k, "certain", "build wiring")
        # file-level code of a script calls its own functions and the scripts it runs
        src = f"{f}::"
        outside = set(range(1, len(lines) + 1))
        for u in d["units"]:
            outside -= set(range(u["start"], u["end"] + 1))
        top = "\n".join(lines[i - 1] for i in sorted(outside))
        for name, k in local.items():
            if re.search(rf"(?<![\w.]){re.escape(name)}\b", top):
                add(src, k, "certain", "build wiring")
        for m in re.finditer(r"((?:scripts|Tools)/[\w/.+-]+\.(?:sh|py))", top):
            add(src, f"{m.group(1)}::", "certain", "build wiring")

    return out
