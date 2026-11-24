"""Units whose code looks like a given unit's: where a bug fixed in one is likely to be in the other.

A unit's code is reduced to tokens (identifiers split at camel case, keywords and operators; string
and number literals collapse to one token each, comments are dropped) and to the set of 4-token
runs it contains. Two units are compared by how much of the seed's runs the other unit also has,
each run weighted by how rare it is across the whole repository, so shared boilerplate counts for
little and a shared distinctive shape counts for a lot.
"""
from __future__ import annotations

import collections
import math
import re

TOKEN = re.compile(r'"(?:[^"\\\n]|\\.)*"|\d[\d_.]*|[A-Za-z_][A-Za-z0-9_]*|==|!=|<=|>=|->|&&|\|\||\?\?|[{}()\[\].,:;=<>!?+\-*/%&|^~@#$]')
CAMEL = re.compile(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+")
WIDTH = 4


def tokens(text: str, hash_comments: bool = False) -> list[str]:
    """The code's tokens: comments removed, literals collapsed, identifiers split at camel case
    and lower-cased, so `holdsSaves(afterReadError:)` and `outcome(forReadError:)` share `read`,
    `error`."""
    text = re.sub(r"//[^\n]*|/\*.*?\*/", " ", text, flags=re.S)
    if hash_comments:  # shell, Python, Makefile and YAML comments
        text = re.sub(r"(^|\s)#[^\n]*", " ", text)
    out = []
    for t in TOKEN.findall(text):
        if t[0] == '"':
            out.append("STR")
        elif t[0].isdigit():
            out.append("NUM")
        elif t[0].isalpha() or t[0] == "_":
            out += [p.lower() for p in CAMEL.findall(t)] or [t.lower()]
        else:
            out.append(t)
    return out


def shingles(text: str, hash_comments: bool = False) -> set[tuple[str, ...]]:
    t = tokens(text, hash_comments)
    return {tuple(t[i:i + WIDTH]) for i in range(max(len(t) - WIDTH + 1, 0))}


class Index:
    """Shingle sets for every unit given as {node: code text}, with each shingle's rarity."""

    def __init__(self, texts: dict[str, str]):
        self.sets = {n: shingles(t, not n.split("::")[0].endswith((".swift", ".c", ".m", ".h")))
                     for n, t in texts.items()}
        df = collections.Counter(s for v in self.sets.values() for s in v)
        n = max(len(self.sets), 1)
        self.idf = {s: math.log(n / c) for s, c in df.items()}
        self.posting = collections.defaultdict(list)
        for node, v in self.sets.items():
            for s in v:
                if df[s] <= 50:  # a run shared by more than 50 units says nothing about any pair
                    self.posting[s].append(node)

    def similar(self, node: str, minimum: float = 0.35, limit: int = 15) -> list[tuple[str, float]]:
        """Units sharing the largest weighted part of `node`'s code (score 0-1, best first), at
        least `minimum`. A unit too short to have distinctive runs has none."""
        mine = self.sets.get(node) or set()
        total = sum(self.idf[s] for s in mine)
        if total < 25:
            return []
        shared = collections.Counter()
        for s in mine:
            for other in self.posting.get(s, ()):
                if other != node:
                    shared[other] += self.idf[s]
        out = []
        for other, w in shared.items():
            theirs = sum(self.idf[s] for s in self.sets[other])
            score = w / max(total, theirs)  # both ways: a short unit inside a long one is not a twin
            if score >= minimum:
                out.append((other, round(score, 2)))
        out.sort(key=lambda x: -x[1])
        return out[:limit]


def unit_texts(inv: dict, root) -> dict[str, str]:
    """{node: the unit's code} for every Swift, script and C unit in the inventory."""
    out = {}
    for f, d in inv.items():
        if f.endswith(".md") or not d["units"]:
            continue
        try:
            lines = (root / f).read_text(errors="replace").split("\n")
        except OSError:
            continue
        for u in d["units"]:
            out[f"{f}::{u['key']}"] = "\n".join(lines[u["start"] - 1:u["end"]])
    return out
