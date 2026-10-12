"""Inventory of every mapped unit in the repository, with a stable key and a content hash.

A *unit* is anything the code map keeps a record for: a Swift function, initializer, computed
property, observer, subscript, protocol requirement or closure-initialised stored property; a
Python def; a shell function; a C/Objective-C function; a Makefile target; a workflow job or step;
and a Markdown heading section.

Each unit gets
  * a key that survives edits elsewhere in the file (kind, enclosing type, name, argument labels,
    and an ordinal only when two units would otherwise share a key), and
  * a hash of its own lines. Lines of units nested inside it and whole-line comments are left out,
    so editing a nested function or a comment does not mark the outer record stale.

Each in-scope file also gets a hash of its lines that lie outside every unit; that is what the
file-level record (role, types, state, top-level code) describes.
"""
from __future__ import annotations

import fnmatch
import hashlib
import re
import subprocess
from pathlib import Path

# Files that carry records. Everything git tracks, minus binaries, the two large string catalogs
# (audited key by key, not line by line), the map itself, and the two open-findings budgets (a
# number that changes with every fix; codemap.py checks it against the records directly).
EXCLUDE = (
    "*.raw", "*.png", "*.pdf", "LICENSE",
    "Emuqu/Localizable.xcstrings", "Emuqu/Help.xcstrings",
    "docs/codemap/*", ".ci/codemap_open_*.txt",
)

NS_CODE = re.compile(r"\.(sh|py|c|m|h)$|^Makefile$|^\.githooks/|^\.github/workflows/")

SWIFT_UNIT = {"function_declaration", "init_declaration", "deinit_declaration",
              "subscript_declaration", "protocol_function_declaration"}
SWIFT_TYPES = {"class_declaration", "protocol_declaration"}
KIND_WORD = {"function_declaration": "func", "init_declaration": "init", "deinit_declaration": "deinit",
             "subscript_declaration": "subscript", "protocol_function_declaration": "requirement",
             "computed": "var", "observed": "var", "closure-init": "let",
             "function_declaration(fallback)": "func"}


def tracked_files(root: Path) -> list[str]:
    out = subprocess.check_output(["git", "-C", str(root), "ls-files"]).decode().split("\n")
    return [f for f in out if f and not any(fnmatch.fnmatch(f, p) for p in EXCLUDE)]


def digest(lines: list[str]) -> str:
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16]


def _comment_prefix(path: str) -> str | None:
    if path.endswith((".swift", ".c", ".m", ".h")):
        return "//"
    if NS_CODE.search(path) or path.endswith((".yml", ".yaml")):
        return "#"
    return None


def _significant(path: str, lines: list[str], numbers) -> list[str]:
    prefix = _comment_prefix(path)
    out = []
    for i in numbers:
        s = lines[i - 1].rstrip()
        if not s.strip():
            continue
        if prefix and s.lstrip().startswith(prefix) and not s.lstrip().startswith("#!"):
            continue
        out.append(s.strip())
    return out


# ---------------------------------------------------------------- Swift

def _swift_units(path: str, src: bytes, parser) -> list[dict]:
    lines = src.decode(errors="replace").split("\n")
    tree = parser.parse(src)

    def txt(n):
        return src[n.start_byte:n.end_byte].decode(errors="replace")

    def name_of(n):
        c = n.child_by_field_name("name")
        if c:
            return txt(c)
        if n.type == "init_declaration":
            return "init"
        if n.type == "deinit_declaration":
            return "deinit"
        if n.type == "subscript_declaration":
            return "subscript"
        for c in n.children:
            if c.type in ("simple_identifier", "pattern"):
                return txt(c).strip()
        return "?"

    def labels(n, typed=False):
        out = []
        for c in n.children:
            if c.type == "parameter":
                ext = c.child_by_field_name("external_name")
                nm = c.child_by_field_name("name")
                lab = (txt(ext) if ext else txt(nm) if nm else "_") + ":"
                if typed:
                    kids = list(c.children)
                    colon = next((i for i, k in enumerate(kids) if k.type == ":"), None)
                    if colon is not None and colon + 1 < len(kids):
                        lab += " " + re.sub(r"\s+", " ", txt(kids[colon + 1]))
                    lab += ", "
                out.append(lab)
        return "(" + "".join(out).rstrip(", ") + ")"

    def unit_kind(n):
        if n.type in SWIFT_UNIT:
            return n.type
        if n.type == "property_declaration":
            kids = {c.type for c in n.children}
            if "computed_property" in kids:
                return "computed"
            for c in n.children:
                if c.type == "willset_didset_block":
                    return "observed"
            if n.parent is not None and n.parent.type in ("class_body", "enum_class_body", "protocol_body"):
                for c in n.children:
                    if c.type in ("lambda_literal", "call_expression") and "lambda_literal" in "".join(x.type for x in c.children):
                        return "closure-init"
        return None

    units = []

    def walk(n, typ):
        k = unit_kind(n)
        if n.type in SWIFT_TYPES:
            nm = n.child_by_field_name("name")
            typ = typ + [txt(nm) if nm else "?"]
        if k:
            nm = name_of(n)
            sig = labels(n) if k in SWIFT_UNIT and k != "deinit_declaration" else ""
            t = ".".join(typ)
            tsig = labels(n, typed=True) if sig else ""
            if k in ("init_declaration", "deinit_declaration", "subscript_declaration"):
                base, typed = f"{KIND_WORD[k]} {t}{sig}", f"{KIND_WORD[k]} {t}{tsig}"
            else:
                head = f"{KIND_WORD[k]} {t + '.' if t else ''}{nm}"
                base, typed = head + sig, head + tsig
            units.append({"kind": k, "name": nm, "type": t, "start": n.start_point[0] + 1,
                          "end": n.end_point[0] + 1, "base": base, "typed": typed})
        for c in n.children:
            walk(c, typ)

    walk(tree.root_node, [])
    if tree.root_node.has_error:
        have = {u["start"] for u in units}
        for i, line in enumerate(lines):
            if re.search(r"^\s*(?:[@\w]+\s+)*(func|init|deinit)\b", line) and not line.strip().startswith("//") and i + 1 not in have:
                depth, end, started = 0, i, False
                for j in range(i, len(lines)):
                    depth += lines[j].count("{") - lines[j].count("}")
                    if "{" in lines[j]:
                        started = True
                    if started and depth <= 0:
                        end = j
                        break
                m = re.search(r"(func|init|deinit)\s*(\w*)", line)
                nm = m.group(2) or m.group(1)
                params = re.search(r"\(([^)]*)\)", line)
                labs = "(" + "".join((p.strip().split()[0].rstrip(":") if p.strip() else "_") + ":" for p in params.group(1).split(",") if p.strip()) + ")" if params else "()"
                units.append({"kind": "function_declaration(fallback)", "name": nm, "type": "", "start": i + 1,
                              "end": end + 1, "base": f"func {nm}{labs}"})
    return units


# ---------------------------------------------------------------- non-Swift code

def _brace_end(lines, i):
    depth, started = 0, False
    for j in range(i, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if "{" in lines[j]:
            started = True
        if started and depth <= 0:
            return j + 1
    return i + 1


def _trim(lines, start, end):
    while end > start and not lines[end - 1].strip():
        end -= 1
    return end


def _ns_units(path: str, lines: list[str]) -> list[dict]:
    units = []
    n = len(lines)
    if path.endswith(".sh") or path.startswith(".githooks/"):
        for i, l in enumerate(lines, 1):
            m = re.match(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?", l)
            if m:
                units.append({"kind": "ns-shfunc", "name": m.group(1), "type": "", "start": i,
                              "end": _brace_end(lines, i - 1), "base": f"fn {m.group(1)}"})
    elif path.endswith(".py"):
        stack = []
        for i, l in enumerate(lines, 1):
            if not l.strip() or l.lstrip().startswith("#"):
                continue
            ind = len(l) - len(l.lstrip())
            while stack and stack[-1][0] >= ind:
                stack.pop()
            m = re.match(r"^\s*(?:async\s+)?def\s+(\w+)", l)
            c = re.match(r"^\s*class\s+(\w+)", l)
            if m:
                end = n
                for j in range(i, n):
                    s = lines[j]
                    if s.strip() and not s.lstrip().startswith("#") and len(s) - len(s.lstrip()) <= ind and not s.lstrip().startswith((")", "]", "}")):
                        end = j
                        break
                qual = ".".join([x[1] for x in stack] + [m.group(1)])
                units.append({"kind": "ns-pydef", "name": m.group(1), "type": "", "start": i,
                              "end": _trim(lines, i, end), "base": f"def {qual}"})
                stack.append((ind, m.group(1)))
            elif c:
                stack.append((ind, c.group(1)))
    elif path.endswith((".c", ".m")):
        for i, l in enumerate(lines, 1):
            m = re.match(r"^(?:static\s+|inline\s+|extern\s+)*[\w\s\*]+?\b(\w+)\s*\([^;]*$", l)
            if m and not l.startswith((" ", "\t", "#", "//", "/*")) and m.group(1) not in ("if", "for", "while", "switch", "return"):
                units.append({"kind": "ns-cfunc", "name": m.group(1), "type": "", "start": i,
                              "end": _brace_end(lines, i - 1), "base": f"c {m.group(1)}"})
            m2 = re.match(r"^[-+]\s*\([^)]*\)\s*(\w+)", l)
            if m2:
                units.append({"kind": "ns-objcmethod", "name": m2.group(1), "type": "", "start": i,
                              "end": _brace_end(lines, i - 1), "base": f"objc {m2.group(1)}"})
    elif path == "Makefile":
        tgt = re.compile(r"^([A-Za-z0-9_.-]+(?:\s+[A-Za-z0-9_.-]+)*)\s*:(?!=)")
        starts = [i for i, l in enumerate(lines, 1) if tgt.match(l) and not l.startswith(".PHONY")]
        heads = [i for i, l in enumerate(lines, 1) if l and not l[0].isspace() and not l.startswith("#")]
        for i in starts:
            nxt = next((h for h in heads if h > i), n + 1)
            name = tgt.match(lines[i - 1]).group(1)
            units.append({"kind": "ns-target", "name": name, "type": "", "start": i,
                          "end": _trim(lines, i, nxt - 1), "base": f"target {name}"})
    elif path.startswith(".github/workflows/"):
        in_jobs = False
        job = ""
        for i, l in enumerate(lines, 1):
            if l.startswith("jobs:"):
                in_jobs = True
            m = re.match(r"^  ([\w-]+):\s*$", l)
            if m and i > 1 and in_jobs:
                job = m.group(1)
                end = next((j for j in range(i + 1, n + 1) if lines[j - 1].strip() and len(lines[j - 1]) - len(lines[j - 1].lstrip()) <= 2 and not lines[j - 1].lstrip().startswith("#")), n + 1)
                units.append({"kind": "ns-job", "name": job, "type": "", "start": i,
                              "end": _trim(lines, i, end - 1), "base": f"job {job}"})
            m = re.match(r"^(\s+)- name:\s*(.+)", l)
            if m:
                ind = len(m.group(1))
                end = n + 1
                for j in range(i + 1, n + 1):
                    s = lines[j - 1]
                    if not s.strip() or s.lstrip().startswith("#"):
                        continue
                    si = len(s) - len(s.lstrip())
                    if si < ind or (si == ind and s.lstrip().startswith("- ")):
                        end = j
                        break
                name = m.group(2)[:60]
                units.append({"kind": "ns-step", "name": name, "type": job, "start": i,
                              "end": _trim(lines, i, end - 1), "base": f"step {job}/{name.strip()}"})
    return units


# ---------------------------------------------------------------- Markdown

def _doc_units(lines: list[str]) -> list[dict]:
    heads = []
    fence = False
    for i, l in enumerate(lines, 1):
        if l.startswith("```"):
            fence = not fence
        if not fence and re.match(r"^#{1,4}\s", l):
            heads.append((i, len(l) - len(l.lstrip("#")), l.strip("# ").strip()))
    units = []
    path = []
    for idx, (i, lvl, title) in enumerate(heads):
        end = next((h[0] - 1 for h in heads[idx + 1:] if h[1] <= lvl), len(lines))
        path = [p for p in path if p[0] < lvl] + [(lvl, title[:80])]
        units.append({"kind": "doc-section", "name": title[:80], "type": "", "start": i,
                      "end": _trim(lines, i, end), "base": "§ " + " > ".join(p[1] for p in path)})
    return units


# ---------------------------------------------------------------- assembly

def _finish(path: str, lines: list[str], units: list[dict]) -> dict:
    units.sort(key=lambda u: (u["start"], -u["end"]))
    # Overloads that share argument labels are told apart by their parameter types first; an
    # ordinal is the last resort (two identical signatures, e.g. in different #if branches).
    count = {}
    for u in units:
        count[u["base"]] = count.get(u["base"], 0) + 1
    for u in units:
        if count[u["base"]] > 1 and u.get("typed"):
            u["base"] = u["typed"]
    seen = {}
    for u in units:
        seen[u["base"]] = seen.get(u["base"], 0) + 1
        u["key"] = u["base"] if seen[u["base"]] == 1 else f'{u["base"]} #{seen[u["base"]]}'
    for u in units:
        nested = set()
        for v in units:
            if v is not u and u["start"] <= v["start"] and v["end"] <= u["end"] and (v["start"], v["end"]) != (u["start"], u["end"]):
                nested.update(range(v["start"], v["end"] + 1))
        u["hash"] = digest(_significant(path, lines, [i for i in range(u["start"], u["end"] + 1) if i not in nested]))
    inside = set()
    for u in units:
        inside.update(range(u["start"], u["end"] + 1))
    file_hash = digest(_significant(path, lines, [i for i in range(1, len(lines) + 1) if i not in inside]))
    for u in units:
        u.pop("base", None)
        u.pop("typed", None)
    return {"hash": file_hash, "lines": len(lines), "units": units}


def inventory(root: Path, only: set[str] | None = None) -> dict[str, dict]:
    """Return {path: {"hash", "lines", "units": [{key, kind, name, type, start, end, hash}]}}."""
    import tree_sitter as ts
    import tree_sitter_swift as tss
    parser = ts.Parser(ts.Language(tss.language()))
    out = {}
    for path in tracked_files(root):
        if only is not None and path not in only:
            continue
        raw = (root / path).read_bytes()
        lines = raw.decode(errors="replace").split("\n")
        if path.endswith(".swift"):
            units = _swift_units(path, raw, parser)
        elif NS_CODE.search(path):
            units = _ns_units(path, lines)
        elif path.endswith(".md") and not path.startswith("Tools/validation"):
            units = _doc_units(lines)
        else:
            units = []
        out[path] = _finish(path, lines, units)
    return out
