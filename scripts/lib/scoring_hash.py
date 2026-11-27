"""The hashing schemes check_scoring_governance.sh measures scoring code with.

A baseline line is `<version> <hash> <scheme>`; a line with two fields was
written under `static-lets`, the scheme that came first. Every scheme a
baseline in the history can name stays here, so a base recorded under an
older scheme is compared with the tree hashed under that same scheme, and a
change of scheme is never mistaken for a change of constants, or the reverse.

    python3 scripts/lib/scoring_hash.py <scheme>   # prints '<hash> <count>'
"""

import hashlib
import pathlib
import re
import sys
from decimal import Decimal, InvalidOperation

CURRENT_SCHEME = "decl-literals"

# --- static-lets ----------------------------------------------------------
# `static let <name> = <number>` declarations only, in two files and two
# enums of Constants.swift. Each file is hashed under the key it had when the
# hash was first recorded, so moving a file leaves the hash alone.
STATIC_LET_SOURCES = [
    ("Emuqu/Sources/Utilities/RecoveryScoreConstants.swift", "Emuqu/Sources/Utilities/Constants+RecoveryScore.swift"),
    ("Emuqu/Sources/Analysis/HRVThresholds.swift", "Emuqu/Sources/Analysis/HRVThresholds.swift"),
]
STATIC_LET_ENUMS = {"Emuqu/Sources/Utilities/Constants.swift": ["ScoringBounds", "ScoringWeights"]}
CONST_RE = re.compile(r"static let\s+(\w+)\s*:?\s*[\w<>\[\], .]*=\s*([-\d.]+)")


class ConfigError(Exception):
    """A hashed source is missing or yields nothing: nothing was measured."""


def _read(name):
    path = pathlib.Path(name)
    if not path.is_file():
        raise ConfigError(f"missing {name}")
    return path.read_text(encoding="utf-8")


def static_lets_hash():
    digest = hashlib.sha256()
    seen = 0
    for name, key in STATIC_LET_SOURCES:
        found = sorted(CONST_RE.findall(re.sub(r"//[^\n]*", "", _read(name))))
        if not found:
            raise ConfigError(f"no scoring constants matched in {name}")
        for symbol, value in found:
            digest.update(f"{key}:{symbol}={value}\n".encode())
            seen += 1
    for name, enums in STATIC_LET_ENUMS.items():
        source = re.sub(r"//[^\n]*", "", _read(name))
        for enum in enums:
            block = re.search(r"^enum " + enum + r"\b.*?^\}", source, re.S | re.M)
            if not block:
                raise ConfigError(f"enum {enum} not found in {name}")
            found = sorted(CONST_RE.findall(block.group(0)))
            if not found:
                raise ConfigError(f"no scoring constants matched in {enum} ({name})")
            for symbol, value in found:
                digest.update(f"{name}:{enum}.{symbol}={value}\n".encode())
                seen += 1
    return digest.hexdigest()[:16], seen


# --- decl-literals --------------------------------------------------------
# Every numeric literal in the code that computes a recovery score, keyed by
# the declaration it sits in, so the band tables, the age/sex norms, clamps
# and caps written inline in a function are measured with the named
# constants. Files are read whole, except Constants.swift, which also holds
# unit conversions and settings keys: only its scoring enums count there.
DECL_SOURCES = [
    "Emuqu/Sources/Utilities/RecoveryScoreConstants.swift",
    "Emuqu/Sources/Analysis/HRVThresholds.swift",
    "Emuqu/Sources/Analysis/ScoreDetailBuilder.swift",
    "Emuqu/Sources/Analysis/VitalsScoring.swift",
    "Emuqu/Sources/Analysis/SleepScienceAnalyzer.swift",
]
DECL_GLOBS = ["Emuqu/Sources/Analysis/RecoveryScoreCalculator*.swift"]
DECL_ENUMS = {"Emuqu/Sources/Utilities/Constants.swift": ["ScoringBounds", "ScoringWeights"]}

TYPE_KEYWORDS = {"enum", "struct", "class", "extension", "actor", "protocol"}
FUNC_KEYWORDS = {"init", "deinit", "subscript"}
DECL_MODIFIERS = {"func", "var", "let", "subscript", "init", "final", "override", "static", "private", "fileprivate", "internal", "public"}
# Words that open a new type-level declaration, so the previous one's
# initializer has ended.
DECL_STARTERS = DECL_MODIFIERS | TYPE_KEYWORDS | FUNC_KEYWORDS | {
    "case", "typealias", "lazy", "nonisolated", "mutating", "open", "weak", "@",
}
TOKEN_RE = re.compile(
    r"\$\w+|[A-Za-z_]\w*|0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?"
    r"|->|==|!=|<=|>=|\+=|-=|\*=|/=|\.\.\.|\.\.<|\n|\S"
)
NUMBER_RE = re.compile(r"0x[0-9A-Fa-f_]+|\d")


def _skip_string(text, i):
    """Index just past the string literal starting at text[i] (a quote or `#`)."""
    hashes = 0
    while text[i] == "#":
        hashes += 1
        i += 1
    triple = text.startswith('"""', i)
    close = ('"""' if triple else '"') + "#" * hashes
    i += 3 if triple else 1
    escape = "\\" + "#" * hashes
    while i < len(text):
        if text.startswith(escape + "(", i):
            i = _skip_interpolation(text, i + len(escape) + 1)
        elif text.startswith(escape, i):
            i += len(escape) + 1
        elif text.startswith(close, i):
            return i + len(close)
        else:
            i += 1
    return i


def _skip_interpolation(text, i):
    depth = 1
    while i < len(text) and depth:
        if text[i] in '"#' and (text[i] == '"' or text.startswith('#"', i)):
            i = _skip_string(text, i)
            continue
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        i += 1
    return i


def strip_comments_and_strings(text):
    """The source with comments removed and every string literal emptied.

    Rewording a comment, a log message or user copy never moves the hash.
    """
    out = []
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
        elif text[i] == '"' or text.startswith('#"', i):
            i = _skip_string(text, i)
            out.append('""')
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _normalize_number(token):
    """`60`, `60.0` and `6_0` are one value; the hash follows values, not spelling."""
    clean = token.replace("_", "")
    if clean.lower().startswith("0x"):
        return str(int(clean, 16))
    try:
        return format(Decimal(clean).normalize(), "f")
    except InvalidOperation:
        return clean


class _Scope:
    def __init__(self, kind, name):
        self.kind = kind  # "type", "func" or "block"
        self.name = name
        self.member = ""
        self.after_assign = False


class DeclarationWalker:
    """Collects the literals of one file under declaration keys.

    Inside a function, initializer or computed property, every number is
    recorded, in source order, under the dotted path of the enclosing types
    and functions (`RecoveryScoreCalculator.zeroMinuteNightScore`). At type
    level, a stored property, enum case or default argument records its
    numbers and the identifiers on the right of its `=` under its own name,
    so re-binding `defaultScoringParameters` to another table moves the hash
    just as editing a band does. Keys are independent of the file, so moving
    a declaration between hashed files, or reordering declarations, leaves
    the hash alone; editing, adding or removing a number moves it.
    """

    def __init__(self):
        self.stack = []
        self.pending = None  # (kind, name) of a declaration whose `{` is next
        self.items = {}

    def _path(self, extra=None):
        names = [s.name for s in self.stack if s.kind != "block"]
        return ".".join(names + ([extra] if extra else []))

    def _in_function(self):
        return any(s.kind == "func" for s in self.stack)

    def _type_scope(self):
        return self.stack[-1] if self.stack and self.stack[-1].kind == "type" else None

    def _record(self, value, is_number, previous=""):
        if self.pending and self.pending[0] == "func":
            # In a signature only numbers and the names default arguments
            # are bound to count, not parameter names or types.
            if not is_number and previous != "=":
                return
            key = self._path(self.pending[1])
        elif self._in_function():
            key = self._path()
        else:
            scope = self._type_scope()
            member = scope.member if scope else ""
            if not is_number and not (scope and scope.after_assign):
                return
            key = self._path() + "#" + member
        if not is_number and self._in_function() and not (self.pending and self.pending[0] == "func"):
            return
        if not key:
            return
        self.items.setdefault(key, []).append(value)

    def _next_name(self, tokens, i):
        j = i + 1
        while j < len(tokens) and tokens[j] == "\n":
            j += 1
        parts = []
        while j < len(tokens) and re.match(r"[A-Za-z_`]", tokens[j]):
            parts.append(tokens[j].strip("`"))
            if j + 1 < len(tokens) and tokens[j + 1] == ".":
                j += 2
                continue
            break
        return ".".join(parts) if parts else (tokens[j] if j < len(tokens) else "")

    def _declare(self, tokens, i, tok):
        nxt = self._next_name(tokens, i)
        if tok in TYPE_KEYWORDS and nxt not in DECL_MODIFIERS:
            self.pending = ("type", nxt)
        elif tok == "func":
            self.pending = ("func", nxt)
        elif tok in FUNC_KEYWORDS and (i == 0 or tokens[i - 1] != "."):
            self.pending = ("func", tok)
        elif tok in ("let", "var", "case", "typealias") and not self._in_function():
            scope = self._type_scope()
            if scope:
                scope.member, scope.after_assign = nxt, False
            self.pending = ("func", nxt) if tok == "var" else None
        else:
            return False
        return True

    def walk(self, text):
        tokens = TOKEN_RE.findall(strip_comments_and_strings(text))
        previous = ""
        for i, tok in enumerate(tokens):
            if tok == "\n":
                continue
            scope = self._type_scope()
            if scope and tok in DECL_STARTERS:
                scope.after_assign = False
            if self._declare(tokens, i, tok):
                pass
            elif tok == "{":
                kind, name = self.pending or ("block", "")
                self.stack.append(_Scope(kind, name))
                self.pending = None
            elif tok == "}":
                if self.stack:
                    self.stack.pop()
                self.pending = None
            elif tok == "=":
                self._assign()
            elif NUMBER_RE.match(tok):
                negative = previous == "-" and self._unary_context(tokens, i)
                self._record(("-" if negative else "") + _normalize_number(tok), True)
            elif re.match(r"[A-Za-z_]", tok) and tok not in DECL_STARTERS:
                self._record(tok, False, previous)
            previous = tok
        return self.items

    def _assign(self):
        if self.pending and self.pending[0] == "func" and not self._in_function():
            scope = self._type_scope()
            if scope and scope.member == self.pending[1]:
                self.pending = None
        scope = self._type_scope()
        if scope and not self.pending and not self._in_function():
            scope.after_assign = True

    @staticmethod
    def _unary_context(tokens, i):
        j = i - 2
        while j >= 0 and tokens[j] == "\n":
            j -= 1
        return j < 0 or not re.match(r"[\w$)\]]", tokens[j])


def _decl_sources():
    """Groups of files that must each yield a number: one per fixed source,
    one per glob (a glob's extension files may hold none of their own)."""
    groups = [(name, [name]) for name in DECL_SOURCES]
    for pattern in DECL_GLOBS:
        matched = sorted(str(p) for p in pathlib.Path(".").glob(pattern))
        if not matched:
            raise ConfigError(f"no files match {pattern}")
        groups.append((pattern, matched))
    return groups


def _has_number(items):
    return any(NUMBER_RE.match(v.lstrip("-")) for values in items.values() for v in values)


def decl_literals_items():
    """{key: [literal, ...]} across every hashed source, in a fixed file order."""
    merged = {}
    for label, names in _decl_sources():
        found = False
        for name in names:
            items = DeclarationWalker().walk(_read(name))
            found = found or _has_number(items)
            for key, values in items.items():
                merged.setdefault(key, []).extend(values)
        if not found:
            raise ConfigError(f"no numeric literals found in {label}")
    for name, enums in DECL_ENUMS.items():
        items = DeclarationWalker().walk(_read(name))
        for enum in enums:
            mine = {k: v for k, v in items.items() if k == enum or k.startswith(enum + ".") or k.startswith(enum + "#")}
            if not mine:
                raise ConfigError(f"enum {enum} not found in {name}, or it holds no literals")
            for key, values in mine.items():
                merged.setdefault(key, []).extend(values)
    return merged


def decl_literals_hash():
    digest = hashlib.sha256()
    seen = 0
    for key, values in sorted(decl_literals_items().items()):
        digest.update(f"{key}={','.join(values)}\n".encode())
        seen += len(values)
    return digest.hexdigest()[:16], seen


SCHEMES = {"static-lets": static_lets_hash, CURRENT_SCHEME: decl_literals_hash}


def scheme_of(fields):
    """The scheme a baseline line was hashed under."""
    return fields[2] if len(fields) == 3 else "static-lets"


if __name__ == "__main__":
    scheme = sys.argv[1] if len(sys.argv) > 1 else CURRENT_SCHEME
    if scheme == "--dump":
        for key, values in sorted(decl_literals_items().items()):
            print(f"{key}={','.join(values)}")
        raise SystemExit(0)
    try:
        h, n = SCHEMES[scheme]()
    except (ConfigError, KeyError) as error:
        sys.stderr.write(f"scoring_hash: {error}\n")
        raise SystemExit(2)
    print(h, n)
