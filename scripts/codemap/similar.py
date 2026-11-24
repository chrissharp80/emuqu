"""Tokens and 4-token runs of a unit's code, for finding units whose code looks alike: where a bug
fixed in one is likely to be in the other.

A unit's code is reduced to tokens (identifiers split at camel case, keywords and operators; string
and number literals collapse to one token each, comments are dropped) and to the set of 4-token
runs it contains. index.py stores every unit's runs and compares units by how much of one's runs
the other also has, each run weighted by how rare it is across the repository, so shared
boilerplate counts for little and a shared distinctive shape counts for a lot.
"""
from __future__ import annotations

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
