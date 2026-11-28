"""The hashing schemes check_scoring_governance.sh measures scoring code with.

A baseline line is `<version> <hash> <scheme>`; a line with two fields was
written under `static-lets`, the scheme that came first. Every scheme a
baseline in the history can name stays here, so a base recorded under an
older scheme is compared with the tree hashed under that same scheme, and a
change of scheme is never mistaken for a change of constants, or the reverse.

    python3 scripts/lib/scoring_hash.py <scheme>   # prints '<hash> <count>'
    python3 scripts/lib/scoring_hash.py --dump     # the current scheme's hashed tokens
    python3 scripts/lib/scoring_hash.py --self-check   # holes in its coverage, if any
"""

import hashlib
import pathlib
import re
import sys
from decimal import Decimal, InvalidOperation

CURRENT_SCHEME = "stored-defuse"

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


def _decl_sources(sources=None, globs=None):
    """Groups of files that must each yield a number: one per fixed source,
    one per glob (a glob's extension files may hold none of their own)."""
    sources = DECL_SOURCES if sources is None else sources
    globs = DECL_GLOBS if globs is None else globs
    groups = [(name, [name]) for name in sources]
    for pattern in globs:
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


# --- decl-tokens ----------------------------------------------------------
# The code of every declaration that decides a recovery score, token by
# token: numbers, operators, identifiers and keywords, keyed by declaration
# as in `decl-literals`. A flipped comparison or a swapped operand moves the
# hash as a moved number does; comments, whitespace, string contents, access
# modifiers and attributes do not. The scoring files are read whole. Outside
# them, the gate starts from the declarations listed in TOKEN_ROOTS (the
# baseline statistics the z-score divides by, the statistics helpers they
# call) and follows every reference it can resolve by name, from those roots
# and from the scoring files alike: a constant or static function written
# `Type.name`, `Self.name` or bare inside its own type, and every member of a
# type named as `Type.self`. A constant that reaches the score is therefore
# hashed wherever it is declared, while the rest of a big file such as
# BaselineTracker.swift (storage, logging, file handling) is not, so editing
# it needs no version bump. A value read through an instance (a field of the
# baseline stats, a session property) is followed only from its listed root.
TOKEN_SOURCE_ROOT = "Emuqu/Sources"
TOKEN_ROOTS = {
    "Emuqu/Sources/Utilities/Constants.swift": ["ScoringBounds", "ScoringWeights"],
    "Emuqu/Sources/Analysis/BaselineTracker.swift": [
        "BaselineTracker.recoveryBaselineStats",
        "BaselineTracker.stats",
        "BaselineTracker.RecoveryBaselineStats",
        "BaselineTracker.maxHistoricalPoints",
    ],
    "Emuqu/Sources/Utilities/Statistics.swift": ["[Double].mean", "[Double].sampleSD"],
}
# Types whose code only puts a score into words (breakdown copy, the
# narrative language, PDF layout, bundle lookup): a reference into them is
# not followed, so rewording the copy needs no version bump.
TOKEN_TEXT_TYPES = {"ScoreBreakdownCopy", "NarrativeLanguage", "LanguageManager", "PDFReadingDirection", "String", "NSAttributedString", "AppConfig"}
# Words that change no number a declaration computes.
TOKEN_SKIPPED = {"private", "fileprivate", "internal", "public", "open", "final", "nonisolated", "static", "override"}


class _TokenScope:
    def __init__(self, kind, name):
        self.kind = kind  # "type", "func" or "block"
        self.name = name
        self.member = ""


class TokenWalker:
    """Records every token of one file under its declaration.

    A key is the dotted path of the enclosing types and functions
    (`BaselineTracker.stats`); at type level a stored property, enum case or
    type alias records under `<type path>#<name>`, and a type's own header
    under `<type path>#`. Each key also names the declaration it belongs to
    (`decl`, the outermost function or member) and the type that encloses it
    (`type`), which reference resolution reads.
    """

    def __init__(self, signature_defaults=False):
        self.stack = []
        self.pending = None
        self.items = {}
        # With `signature_defaults`, an `=` inside a function's parameter
        # list (a default argument) keeps the function pending, so its body
        # is recorded under the function. Without it, as the older schemes
        # read, the body after a default argument lands in the type header.
        self.signature_defaults = signature_defaults
        self.parens = 0
        self.pending_parens = 0

    def _names(self, kinds):
        return [s.name for s in self.stack if s.kind in kinds]

    def _type_path(self):
        names = []
        for scope in self.stack:
            if scope.kind == "func":
                break
            if scope.kind == "type":
                names.append(scope.name)
        return ".".join(names)

    def _where(self):
        """(key, declaration path, enclosing type path) of the next token."""
        tpath = self._type_path()
        join = lambda *parts: ".".join(p for p in parts if p)
        if self.pending and self.pending[0] == "func":
            return join(tpath, self.pending[1]), join(tpath, self.pending[1]), tpath
        if self.pending and self.pending[0] == "type":
            name = join(tpath, self.pending[1])
            return name + "#", name, name
        funcs = [s for s in self.stack if s.kind == "func"]
        if funcs:
            decl = join(tpath, funcs[0].name)
            return ".".join(self._names({"type", "func"})), decl, tpath
        types = [s for s in self.stack if s.kind == "type"]
        member = types[-1].member if types else ""
        return tpath + "#" + member, join(tpath, member), tpath

    def _record(self, tok):
        key, decl, tpath = self._where()
        entry = self.items.setdefault(key, {"tokens": [], "decl": decl, "type": tpath})
        entry["tokens"].append(tok)

    def _next_name(self, tokens, i):
        j = i + 1
        while j < len(tokens) and tokens[j] == "\n":
            j += 1
        if j < len(tokens) and tokens[j] == "[":
            end = j
            while end < len(tokens) and tokens[end] != "]":
                end += 1
            return "".join(tokens[j:end + 1])
        parts = []
        while j < len(tokens) and re.match(r"[A-Za-z_`]", tokens[j]):
            parts.append(tokens[j].strip("`"))
            if j + 1 < len(tokens) and tokens[j + 1] == ".":
                j += 2
                continue
            break
        return ".".join(parts) if parts else (tokens[j] if j < len(tokens) else "")

    def _in_function(self):
        return any(s.kind == "func" for s in self.stack)

    def _declare(self, tokens, i, tok):
        if i and tokens[i - 1] == ".":
            return
        nxt = self._next_name(tokens, i)
        if tok in TYPE_KEYWORDS and nxt not in DECL_MODIFIERS:
            self.pending = ("type", nxt)
        elif tok == "func" or tok in FUNC_KEYWORDS:
            self.pending = ("func", nxt if tok == "func" else tok)
        elif tok in ("let", "var", "case", "typealias") and not self._in_function():
            if self.stack and self.stack[-1].kind == "type":
                self.stack[-1].member = nxt
            self.pending = ("func", nxt) if tok == "var" else None

    def walk(self, text):
        tokens = TOKEN_RE.findall(strip_comments_and_strings(text))
        skip_next = False
        for i, tok in enumerate(tokens):
            if tok == "\n" or tok in TOKEN_SKIPPED:
                continue
            if skip_next:
                skip_next = False
                continue
            if tok in ("@", "import"):
                skip_next = True
                continue
            before = self.pending
            self._declare(tokens, i, tok)
            if self.pending is not before:
                self.pending_parens = self.parens
            self.parens += {"(": 1, ")": -1}.get(tok, 0)
            if tok == "{":
                kind, name = self.pending or ("block", "")
                self.stack.append(_TokenScope(kind, name))
                self.pending = None
                continue
            if tok == "}":
                if self.stack:
                    self.stack.pop()
                self.pending = None
                continue
            in_signature = self.signature_defaults and self.parens > self.pending_parens
            if tok == "=" and self.pending and self.pending[0] == "func" and not self._in_function() and not in_signature:
                self.pending = None
            self._record(_normalize_number(tok) if NUMBER_RE.match(tok) else tok)
        return self.items


def _token_index(signature_defaults=False):
    """{file: TokenWalker items} for every Swift file under the app sources."""
    index = {}
    for path in sorted(pathlib.Path(TOKEN_SOURCE_ROOT).rglob("*.swift")):
        walker = TokenWalker(signature_defaults=signature_defaults)
        index[str(path)] = walker.walk(path.read_text(encoding="utf-8"))
    return index


def _by_decl(index):
    """{declaration path: [(file, key)]} for the members of types, not the
    type headers, and none of the text-only types."""
    decls = {}
    for name, items in index.items():
        for key, entry in items.items():
            text_only = entry["decl"].split(".")[0] in TOKEN_TEXT_TYPES
            if entry["type"] and not key.endswith("#") and not text_only:
                decls.setdefault(entry["decl"], []).append((name, key))
    return decls


def _chains(tokens):
    """Each `a.b.c` identifier chain not itself reached through a `.`."""
    i = 0
    while i < len(tokens):
        if re.match(r"[A-Za-z_]", tokens[i]) and (i == 0 or tokens[i - 1] != "."):
            chain = [tokens[i]]
            while i + 2 < len(tokens) and tokens[i + 1] == "." and re.match(r"[A-Za-z_]", tokens[i + 2]):
                chain.append(tokens[i + 2])
                i += 2
            yield chain
        i += 1


def _resolve(chain, tpath, decls):
    """The declaration paths a chain written inside type `tpath` names."""
    scope = tpath.split(".") if tpath else []
    if chain[0] == "Self":
        chain = scope + chain[1:]
    for k in range(len(scope), -1, -1):
        for j in range(len(chain), 0, -1):
            path = ".".join(scope[:k] + chain[:j])
            if j < len(chain) and chain[j] == "self":
                members = [d for d in decls if d == path or d.startswith(path + ".")]
                if members:
                    return members
            if path in decls:
                return [path]
    return []


def _root_decls(index, decls, token_roots=None):
    found = []
    for name, roots in (TOKEN_ROOTS if token_roots is None else token_roots).items():
        if name not in index:
            raise ConfigError(f"missing {name}")
        for root in roots:
            mine = sorted({entry["decl"] for entry in index[name].values()
                           if entry["decl"] in decls and (entry["decl"] == root or entry["decl"].startswith(root + "."))})
            if not mine:
                raise ConfigError(f"{root} not found in {name}")
            found.extend(mine)
    return found


def decl_tokens_items(sources=None, globs=None, token_roots=None, signature_defaults=False):
    """{key: [token, ...]}: the scoring files whole, the roots, and every
    declaration they reach by name, each key once."""
    index = _token_index(signature_defaults)
    decls = _by_decl(index)
    whole = set()
    for label, names in _decl_sources(sources, globs):
        if not any(_has_number({k: e["tokens"] for k, e in index.get(n, {}).items()}) for n in names):
            raise ConfigError(f"no numeric literals found in {label}")
        whole.update(names)
    chosen = {(name, key) for name in whole for key in index[name]}
    work = list(chosen)
    for decl in _root_decls(index, decls, token_roots):
        work.extend(decls[decl])
    seen_decls = set()
    while work:
        name, key = work.pop()
        chosen.add((name, key))
        entry = index[name][key]
        for chain in _chains(entry["tokens"]):
            for decl in _resolve(chain, entry["type"], decls):
                if decl not in seen_decls:
                    seen_decls.add(decl)
                    work.extend(ref for ref in decls[decl] if ref not in chosen)
    merged = {}
    for name, key in sorted(chosen):
        merged.setdefault(key, []).extend(index[name][key]["tokens"])
    return merged


def _tokens_digest(items):
    digest = hashlib.sha256()
    seen = 0
    for key, values in sorted(items.items()):
        digest.update(f"{key}={' '.join(values)}\n".encode())
        seen += len(values)
    return digest.hexdigest()[:16], seen


def decl_tokens_hash():
    return _tokens_digest(decl_tokens_items())


# --- decl-flow ------------------------------------------------------------
# `decl-tokens` over every declaration that reaches a stored score, not only
# the ones the scoring files name. The score also reads values carried on
# instances (the analysis result's RMSSD, mean HR, DFA α1, PNS and SNS
# indices, its data quality, the night's sleep stages, the vitals baselines,
# the training readiness frozen beside it), and following names alone stops
# at those: an edit to the ANS norms or to the window geometry changed stored
# scores with the hash unmoved. So the files that compute a stored score
# input are hashed whole, as the scoring files are: the overnight analysis
# from beats to metrics (artifact detection, window selection, the time,
# frequency, nonlinear, DFA, stress and respiration analyses), the sleep
# staging and boundary rules, and training readiness. In files that also
# hold storage, networking or UI, the declarations that turn those inputs
# into a stored score are roots: the HRV quality rule, the score assembly
# of each path that stores a score, and the constant enums they read.
# Collection code (Bluetooth, strap download, source selection) and copy
# stay out: they decide which beats exist, not how a score is computed.
FLOW_SOURCES = DECL_SOURCES + [
    "Emuqu/Sources/Analysis/ArtifactDetection.swift",
    "Emuqu/Sources/Analysis/ScoredRecoveryBlock.swift",
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift",
    "Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift",
    "Emuqu/Sources/Analysis/NonlinearAnalysis.swift",
    "Emuqu/Sources/Analysis/DFAAnalysis.swift",
    "Emuqu/Sources/Analysis/StressAnalysis.swift",
    "Emuqu/Sources/Analysis/RespirationAnalysis.swift",
    "Emuqu/Sources/Analysis/ReadinessScoring.swift",
    "Emuqu/Sources/Analysis/SleepResolver.swift",
    "Emuqu/Sources/Analysis/SleepBoundaryResolver.swift",
    "Emuqu/Sources/Collection/HRSleepEstimator.swift",
]
FLOW_GLOBS = DECL_GLOBS + [
    "Emuqu/Sources/Analysis/HRVAnalysisPipeline*.swift",
    "Emuqu/Sources/Analysis/WindowSelector*.swift",
    "Emuqu/Sources/Analysis/HRVSleepStageClassifier*.swift",
]
FLOW_ROOTS = {
    "Emuqu/Sources/Utilities/Constants.swift": [
        "ScoringBounds", "ScoringWeights", "StressNormativeConstants", "HRVConstants",
    ],
    **{name: roots for name, roots in TOKEN_ROOTS.items() if name != "Emuqu/Sources/Utilities/Constants.swift"},
    "Emuqu/Sources/Services/SessionAcceptanceService.swift": [
        "SessionAcceptanceService.classifyHRVQuality",
        "SessionAcceptanceService.scoreBreakdown",
    ],
    "Emuqu/Sources/Services/ReanalysisService.swift": [
        "ReanalysisService.hasInsufficientData",
        "ReanalysisService.computeFrozenReadiness",
        "ReanalysisService.rescoredBreakdown",
    ],
    "Emuqu/Sources/Collection/MorningSessionPipeline+Analysis.swift": [
        "MorningSessionPipeline.computeRecoveryScore",
        "MorningSessionPipeline.scoreBreakdown",
    ],
    "Emuqu/Sources/Services/MorningProcessingService+Merging.swift": [
        "MorningProcessingService.ansBalance",
        "MorningProcessingService.computeRecoveryScore",
    ],
}


def decl_flow_items():
    return decl_tokens_items(FLOW_SOURCES, FLOW_GLOBS, FLOW_ROOTS)


def decl_flow_hash():
    return _tokens_digest(decl_flow_items())


# --- stored-flow ----------------------------------------------------------
# `decl-flow` plus every declaration that computes a value stored beside a
# score and read back into it. The training snapshot frozen on each night
# (ATL, CTL, TSB, yesterday's load, the recent workouts, days since a hard
# session, VO2max) decides the frozen training readiness
# (`ReanalysisService.computeFrozenReadiness`) and the recovery score's
# training tier, and it is built from the training-load chain: the EWMA and
# its time constants, the Banister coefficients and load caps
# (`TrainingConstants`), each workout's load (`effectiveLoad`, the precedence
# ladder, the TSS-scale conversion, the strap's TRIMP and hrTSS, the route
# estimate, the METs load), the Health and archive workout merge, and the
# heart-rate anchors. The vitals snapshot is built from Apple Health's
# readings by window and baseline rules and the strap's sleep heart rate, and
# the sleep snapshot from Apple Health's sleep samples, the naps folded into
# the night and the heart-rate sleep estimate.
# `decl-flow` followed none of them: their values reach the score on an
# instance (`trainingContext.atl`), so an edit to the CTL time constant
# changed every stored readiness with the hash unmoved. It also lost the body
# of any function with a default argument: the `=` read as a stored
# property's initializer, so the body fell under the type header, which a
# root never reaches. This scheme keeps such a body under its function.
STORED_SOURCES = FLOW_SOURCES + [
    "Emuqu/Sources/Analysis/TrainingLoadSeries.swift",
    "Emuqu/Sources/Collection/TrainingLoadPrecedence.swift",
]
STORED_ROOTS = {
    **FLOW_ROOTS,
    "Emuqu/Sources/Utilities/Constants.swift": FLOW_ROOTS["Emuqu/Sources/Utilities/Constants.swift"] + ["TrainingConstants"],
    "Emuqu/Sources/Collection/HealthDataTypes.swift": [
        "HealthWorkoutSummary.effectiveLoad",
        "HealthWorkoutSummary.calculateTrimp",
        "HealthWorkoutSummary.fromAppArchive",
        "HealthWorkoutSummary.summaryFromIndex",
        "HealthWorkoutSummary.intensityScore",
        "HealthWorkoutSummary.isHardWorkout",
    ],
    "Emuqu/Sources/Collection/WorkoutSummary+UserLoad.swift": [
        "HealthKitManager.WorkoutSummary.userScaledLoad",
        "WorkoutLoadRestingHR",
    ],
    "Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift": [
        "TrainingHealthQueries.calculateTrainingMetrics",
        "TrainingHealthQueries.calculateTrainingLoad",
        "TrainingHealthQueries.answeredTrainingLoad",
        "TrainingHealthQueries.trainingLoad",
        "TrainingHealthQueries.trainingHeartRateAnchors",
        "TrainingHealthQueries.fetchAppleRestingHR",
        "TrainingHealthQueries.fetchVO2MaxTrend",
        "TrainingHealthQueries.deduplicateWorkouts",
        "TrainingHealthQueries.mergeArchiveAuthoritative",
        "TrainingHealthQueries.workoutSummaries",
        "TrainingHealthQueries.ewmaLookbackDays",
    ],
    "Emuqu/Sources/Collection/TrainingLoad.swift": ["TrainingLoad"],
    "Emuqu/Sources/Collection/TrainingMetrics.swift": ["TrainingMetrics"],
    "Emuqu/Sources/Models/RRModels.swift": ["TrainingContext"],
    "Emuqu/Sources/Models/WorkoutMetadata.swift": [
        "WorkoutMetadata.computedMETLoad",
        "WorkoutMetadata.storedPowerTSS",
        "WorkoutMetadata.routeEstimateReplacesHRLoad",
        "WorkoutMetadata.TrainingLoadSource",
    ],
    "Emuqu/Sources/Analysis/WorkoutAnalyzer.swift": [
        "WorkoutAnalyzer.computeTRIMP",
        "WorkoutAnalyzer.computeHrTSS",
        "WorkoutAnalyzer.banisterTRIMP",
    ],
    "Emuqu/Sources/Analysis/RouteTRIMPEstimator.swift": ["RouteTRIMPEstimator"],
    "Emuqu/Sources/Collection/SessionScoringContext.swift": [
        "SessionScoringContext.createTrainingContext",
        "SessionScoringContext.createTrainingContextEnsuringFresh",
        "SessionScoringContext.ansConfig",
    ],
    "Emuqu/Sources/Collection/MorningSessionPipeline+Analysis.swift": FLOW_ROOTS["Emuqu/Sources/Collection/MorningSessionPipeline+Analysis.swift"] + [
        "MorningSessionPipeline.scoringTrainingContext",
    ],
    "Emuqu/Sources/Collection/SessionDataMigrations+TrainingRecalibration.swift": [
        "SessionDataMigrations.recalibratedContext",
        "SessionDataMigrations.trainingAnchor",
    ],
    "Emuqu/Sources/Collection/VitalsHealthQueries+Queries.swift": [
        "VitalsHealthQueries.fetchRecoveryVitals",
    ],
    "Emuqu/Sources/Models/HRVSession+SleepHeartRate.swift": [
        "HRVSession.withSleepHeartRate",
        "HRVSession.refreshSleepHeartRate",
    ],
    "Emuqu/Sources/Models/RecoveryVitals.swift": ["RecoveryVitals"],
    "Emuqu/Sources/Collection/SleepHealthQueries+Queries.swift": [
        "SleepHealthQueries.fetchLastNightSleep",
        "SleepHealthQueries.fetchSleepData",
        "SleepHealthQueries.fetchDaytimeNapMinutesIfReadable",
        "SleepHealthQueries.qualifyingNapMinutes",
        "SleepHealthQueries.estimateSleepFromHealthKitHR",
    ],
    "Emuqu/Sources/Models/SleepData.swift": ["SleepData"],
}


# Every root above is a declaration the base branch has too, so the base's
# own sources hash under this scheme and the gate compares them; a root that
# only the tree has would leave that comparison skipped.
def stored_flow_items():
    return decl_tokens_items(STORED_SOURCES, FLOW_GLOBS, STORED_ROOTS, signature_defaults=True)


def stored_flow_hash():
    return _tokens_digest(stored_flow_items())


# --- stored-reach ---------------------------------------------------------
# Every scheme above hashes what someone listed: files read whole and named
# roots, followed only through `Type.name` references. Each list missed a
# live input (the baseline admission rule, the night key the baseline counts
# nights by) that a stored score depended on through an instance call. This
# scheme lists no code. It starts from every writer of a stored score field
# (STORED_FIELDS, the fields of a reading and of the baseline that a score is
# stored in or read back from) and follows a call graph over the app
# sources: static and instance calls, property reads and writes (a stored
# property's default and its observers included), initializers, the stored
# members, cases and operators of every type a reached declaration names,
# protocol requirements to every conformer's implementation, and closures
# (their bodies are part of the declaration that writes them). A receiver's
# type is inferred from parameters, annotations, initializers, `self`, the
# enclosing type's properties, declared return types and the element type of
# a collection a closure iterates; when it cannot be inferred, or the type
# declares no member of that name, every declaration of that name is taken.
# Over-inclusion only means an unrelated edit asks for a version bump;
# under-inclusion is the failure this exists to prevent. Every reached
# declaration is hashed token by token, as `stored-flow` hashes its set.
STORED_FIELDS = {
    "HRVSession": [
        "recoveryScore", "scoreBreakdown", "autoWindowScore", "autoWindowResult", "analysisResult",
        "frozenReadiness", "trainingSnapshot", "vitalsSnapshot", "sleepSnapshot", "hrvDataQuality",
    ],
    "BaselineTracker": ["historicalData"],
}
# Methods that change a stored collection or value in place.
REACH_MUTATORS = {
    "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "removeSubrange",
    "removeValue", "sort", "reverse", "replaceSubrange", "updateValue", "merge", "formUnion",
    "subtract", "formIntersection", "toggle", "popLast", "swapAt", "shuffle",
}
REACH_ASSIGN = {"=", "+=", "-=", "*=", "/="}
REACH_NOMINAL = {"struct", "class", "enum", "actor", "protocol"}
REACH_KEYWORDS = {
    "let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "switch", "case",
    "default", "true", "false", "nil", "try", "await", "async", "throws", "throw", "where", "is",
    "as", "some", "any", "do", "catch", "break", "continue", "defer", "inout", "mutating", "lazy",
    "weak", "unowned", "get", "set", "didSet", "willSet", "repeat", "fallthrough", "_", "rethrows",
    "convenience", "required", "indirect", "consuming", "borrowing", "nonmutating", "subscript",
    "deinit", "typealias", "struct", "class", "enum", "extension", "protocol", "actor", "import",
}
IDENT_RE = re.compile(r"[A-Za-z_$][\w$]*$")
# Library types a receiver can be inferred as: a member named on one is the
# library's or an app extension's, never another app type's.
REACH_LIBRARY = {
    "Double", "Float", "CGFloat", "Int", "Int64", "Int32", "Int16", "Int8", "UInt", "UInt64",
    "UInt32", "UInt16", "UInt8", "Bool", "String", "Substring", "Character", "Date", "TimeInterval",
    "UUID", "Data", "URL", "Calendar", "DateComponents", "DateInterval", "Dictionary", "Range",
    "ClosedRange", "Decimal", "Locale", "TimeZone",
}


_LEXICAL_RE = re.compile(r'//|/\*|#*"')


def _blank_comments_and_strings(text):
    """`strip_comments_and_strings`, with every removed character kept as a
    space (newlines as newlines), so a token's offset is its offset in the
    source and a mutation can be planted at it. Also returns, for the two
    quote tokens a string leaves, the offset its literal ends at."""
    out = []
    ends = {}
    i = 0
    while True:
        match = _LEXICAL_RE.search(text, i)
        if not match:
            out.append(text[i:])
            return "".join(out), ends
        start = match.start()
        out.append(text[i:start])
        lead = match.group()
        if lead == "//":
            end = text.find("\n", start)
            end = len(text) if end < 0 else end
            out.append(" " * (end - start))
        elif lead == "/*":
            end = text.find("*/", start + 2)
            end = len(text) if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[start:end]))
        else:
            end = _skip_string(text, start)
            out.append('""' + re.sub(r"[^\n]", " ", text[start + 2:end]))
            ends[start] = ends[start + 1] = end
        i = end


_DECLARING = TYPE_KEYWORDS | FUNC_KEYWORDS | {"func", "let", "var", "case", "typealias", "#"}


class ReachWalker(TokenWalker):
    """`TokenWalker` that also keeps, per key, every token with its offset,
    braces included (`raw`), and the offset just inside the body of each
    function, initializer and computed property (`body`), which the call
    graph and the coverage self-check read."""

    def __init__(self):
        super().__init__(signature_defaults=True)

    def _raw(self, tok, pos):
        key, decl, tpath = self._where()
        entry = self.items.setdefault(key, {"tokens": [], "decl": decl, "type": tpath})
        entry.setdefault("raw", []).append((tok, pos))
        entry.setdefault("lines", []).append(self.line)
        return entry

    def _declare(self, tokens, i, tok):
        if tok not in _DECLARING:
            return
        super()._declare(tokens, i, tok)
        if not self.stack and not (i and tokens[i - 1] == "."):
            if tok in ("let", "var"):
                self.top_member = self._next_name(tokens, i)
            elif tok in TYPE_KEYWORDS or tok in FUNC_KEYWORDS or tok in ("func", "#"):
                self.top_member = ""

    def _where(self):
        """A function declared inside another files its signature under the
        enclosing function, as its body is, not as a member of the type; a
        file-level constant files under its own name."""
        if not self.stack and not self.pending and getattr(self, "top_member", ""):
            return "#" + self.top_member, self.top_member, ""
        if self.pending and self.pending[0] == "func" and self._in_function():
            tpath = self._type_path()
            funcs = [s for s in self.stack if s.kind == "func"]
            key = ".".join(self._names({"type", "func"}) + [self.pending[1]])
            return key, ".".join(p for p in (tpath, funcs[0].name) if p), tpath
        return super()._where()

    def walk(self, text):
        blanked, string_ends = _blank_comments_and_strings(text)
        matches = list(TOKEN_RE.finditer(blanked))
        tokens = [m.group() for m in matches]
        skip_next = False
        self.line = 0
        for i, tok in enumerate(tokens):
            if tok == "\n":
                self.line += 1
                continue
            if tok in TOKEN_SKIPPED:
                continue
            if skip_next:
                skip_next = False
                continue
            if tok in ("@", "import"):
                skip_next = True
                continue
            before = self.pending
            self._declare(tokens, i, tok)
            if self.pending is not before:
                self.pending_parens = self.parens
            self.parens += {"(": 1, ")": -1}.get(tok, 0)
            pos = matches[i].start()
            in_signature = self.parens > self.pending_parens
            if tok == "{":
                entry = self._raw(tok, pos)
                if self.pending and self.pending[0] == "func" and in_signature:
                    # A closure default argument: its braces belong to the
                    # signature, and the body still follows.
                    scope = _TokenScope("block", "")
                    scope.signature = self.pending
                    self.stack.append(scope)
                    continue
                kind, name = self.pending or ("block", "")
                if kind == "func" and not self._in_function():
                    entry.setdefault("body", pos + 1)
                self.stack.append(_TokenScope(kind, name))
                self.pending = None
                continue
            if tok == "}":
                self._raw(tok, pos)
                closed = self.stack.pop() if self.stack else None
                self.pending = getattr(closed, "signature", None)
                continue
            if tok == "=" and self.pending and self.pending[0] == "func" and not self._in_function() and not in_signature:
                self.pending = None
            entry = self._raw(tok, pos)
            entry["tokens"].append(_normalize_number(tok) if NUMBER_RE.match(tok) else tok)
            entry["end"] = string_ends.get(pos, pos + len(tok))
        return self.items


def _reach_index(root=TOKEN_SOURCE_ROOT):
    index = {}
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        index[str(path)] = ReachWalker().walk(path.read_text(encoding="utf-8"))
    return index


def _skip_balanced(raw, i):
    """Index just past the bracket group opening at raw[i]."""
    pairs = {"(": ")", "[": "]", "{": "}", "<": ">"}
    opener, closer = raw[i][0], pairs[raw[i][0]]
    depth = 0
    while i < len(raw):
        tok = raw[i][0]
        if tok == opener:
            depth += 1
        elif tok == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        elif opener == "<" and tok in ("{", "}", "=", "->"):
            return i
        i += 1
    return i


class Program:
    """The declarations of the app sources and what they reference."""

    def __init__(self, index):
        self.index = index
        self.decls = {}
        for name, items in index.items():
            for key, entry in items.items():
                # File-level tokens outside any declaration are compiler
                # directives (`#if`); they compute nothing.
                if entry["decl"]:
                    self.decls.setdefault(entry["decl"], []).append((name, key))
        self.by_name = {}
        self.members = {}
        for decl in self.decls:
            owner, _, member = decl.rpartition(".")
            self.by_name.setdefault(member, set()).add(decl)
            self.members.setdefault(owner, set()).add(decl)
        self._read_types()
        self._declared = {}

    def _read_types(self):
        self.types, self.nominal, self.supers, self.kinds = set(), set(), {}, {}
        for decl, refs in self.decls.items():
            for name, key in refs:
                if key.endswith("#"):
                    self.types.add(decl)
                    self._read_header(decl, self.index[name][key].get("raw", []))
        self.short = {}
        for tpath in self.types:
            self.short.setdefault(tpath.rpartition(".")[2], set()).add(tpath)
        self.conformers = {}
        for tpath, written in self.supers.items():
            for sup in written:
                for resolved in self.resolve_type(sup, tpath.rpartition(".")[0]):
                    self.conformers.setdefault(resolved, set()).add(tpath)

    def _read_header(self, tpath, raw):
        toks = [t for t, _ in raw]
        for i, tok in enumerate(toks):
            if tok not in REACH_NOMINAL and tok != "extension":
                continue
            if tok in REACH_NOMINAL:
                self.nominal.add(tpath)
                self.kinds[tpath] = tok
            j = i + 2
            while j < len(toks) and toks[j] == ".":
                j += 2
            if j < len(toks) and toks[j] == "<":
                j = _skip_balanced(raw, j)
            if j < len(toks) and toks[j] == ":":
                j += 1
                while j < len(toks) and IDENT_RE.match(toks[j]):
                    name, j = self._dotted(toks, j)
                    self.supers.setdefault(tpath, set()).add(name)
                    if j < len(toks) and toks[j] == "<":
                        j = _skip_balanced(raw, j)
                    if j >= len(toks) or toks[j] != ",":
                        break
                    j += 1

    @staticmethod
    def _dotted(toks, j):
        parts = [toks[j]]
        j += 1
        while j + 1 < len(toks) and toks[j] == "." and IDENT_RE.match(toks[j + 1]):
            parts.append(toks[j + 1])
            j += 2
        return ".".join(parts), j

    def resolve_type(self, written, context=""):
        """The app type paths a type written inside `context` names."""
        if not written:
            return set()
        if written in ("Self",):
            return {context} if context in self.types else set()
        scope = context.split(".") if context else []
        for k in range(len(scope), -1, -1):
            path = ".".join(scope[:k] + [written])
            if path in self.nominal:
                return {path}
            if path in self.types:
                return {path} | (self._alias(written, context) or set())
        alias = self._alias(written, context)
        if alias is not None:
            return alias
        last = written.rpartition(".")[2]
        exact = {t for t in self.short.get(last, ()) if t == written or t.endswith("." + written)}
        return exact or set(self.short.get(last, ()))

    def _alias(self, written, context):
        """What a `typealias` written as `written` names, or None."""
        if not hasattr(self, "_aliases"):
            self._aliases, self._resolving = {}, set()
            for decl, refs in self.decls.items():
                for name, key in refs:
                    toks = [t for t, _ in self.index[name][key].get("raw", [])]
                    if toks[:1] == ["typealias"] and "=" in toks:
                        self._aliases.setdefault(decl.rpartition(".")[2], []).append((decl, toks, toks.index("=")))
        last = written.rpartition(".")[2]
        if last not in self._aliases or written in self._resolving:
            return None
        self._resolving.add(written)
        found = set()
        for decl, toks, eq in self._aliases[last]:
            if decl == written or decl.endswith("." + written) or "." not in written:
                found |= {n.strip("[]") for n in self.parse_type(toks, eq + 1, decl.rpartition(".")[0])[0]} & self.types
        self._resolving.discard(written)
        return found or None

    def lineage(self, tpaths):
        """The types, every type they inherit from or conform to, and the
        extensions of those, transitively."""
        seen, work = set(), list(tpaths)
        while work:
            tpath = work.pop()
            if tpath in seen:
                continue
            seen.add(tpath)
            for sup in self.supers.get(tpath, ()):
                work.extend(self.resolve_type(sup, tpath.rpartition(".")[0]) or {sup})
        return seen

    def descendants(self, tpath):
        seen, work = set(), [tpath]
        while work:
            current = work.pop()
            for sub in self.conformers.get(current, ()):
                if sub not in seen:
                    seen.add(sub)
                    work.append(sub)
        return seen

    def lookup(self, tpaths, member, fallback=True):
        """Declarations `member` names on a receiver of one of `tpaths`; every
        declaration of that name when the receiver is unknown or declares none."""
        found = set()
        if tpaths:
            for tpath in self.lineage(tpaths):
                if tpath + "." + member in self.decls:
                    found.add(tpath + "." + member)
            for decl in list(found):
                owner = decl.rpartition(".")[0]
                for sub in self.descendants(owner):
                    if sub + "." + member in self.decls:
                        found.add(sub + "." + member)
        if found or not fallback:
            return found
        return set(self.by_name.get(member, ()))

    # A type is a frozenset of names: app type paths, external names as
    # written (`Double`, `Date`), and `[X]` for an array of X.
    def parse_type(self, toks, j, context):
        """(type, index after it) of the type expression at toks[j]."""
        while j < len(toks) and toks[j] in ("some", "any", "inout", "borrowing", "consuming", "("):
            if toks[j] == "(":
                return frozenset(), j
            j += 1
        if j >= len(toks):
            return frozenset(), j
        if toks[j] == "[":
            inner, k = self.parse_type(toks, j + 1, context)
            if k < len(toks) and toks[k] == ":":
                _, k = self.parse_type(toks, k + 1, context)
                inner = None
            k = k + 1 if k < len(toks) and toks[k] == "]" else k
            while k < len(toks) and toks[k] in ("?", "!"):
                k += 1
            return (frozenset("[" + n + "]" for n in inner) if inner else frozenset({"Dictionary"})), k
        if not IDENT_RE.match(toks[j]):
            return frozenset(), j
        name, k = self._dotted(toks, j)
        args = frozenset()
        if k < len(toks) and toks[k] == "<":
            args, _ = self.parse_type(toks, k + 1, context)
            depth = 0
            while k < len(toks):
                depth += {"<": 1, ">": -1}.get(toks[k], 0)
                k += 1
                if depth == 0:
                    break
        while k < len(toks) and toks[k] in ("?", "!"):
            k += 1
        if name in ("Optional", "Set"):
            return args, k
        if name in ("Array", "ArraySlice"):
            return frozenset("[" + n + "]" for n in args), k
        resolved = self.resolve_type(name, context)
        return frozenset(resolved or {name}), k

    @staticmethod
    def element(tset):
        return frozenset(n[1:-1] for n in tset if n.startswith("[") and n.endswith("]"))

    def declared_type(self, decl):
        """The type a reference to `decl` evaluates to: a property's type, a
        function's return type, the owner for an initializer or case."""
        if decl in self._declared:
            return self._declared[decl]
        self._declared[decl] = frozenset()
        owner, _, member = decl.rpartition(".")
        result = frozenset()
        if decl in self.types:
            result = frozenset({decl} | (set() if decl in self.nominal else self._alias(decl, "") or set()))
        elif member == "init":
            result = frozenset({owner})
        else:
            for name, key in self.decls[decl]:
                result = result | self._written_type(self.index[name][key].get("raw", []), owner, member)
        self._declared[decl] = result
        return result

    def _written_type(self, raw, owner, member):
        toks = [t for t, _ in raw]
        if toks[:1] == ["case"]:
            return frozenset({owner})
        depth = 0
        for j, tok in enumerate(toks):
            if tok == "{" and depth == 0:
                break
            depth += {"(": 1, ")": -1}.get(tok, 0)
            if depth == 0 and tok == "->":
                return self.parse_type(toks, j + 1, owner)[0]
            if depth == 0 and tok == ":" and j and toks[j - 1] == member and toks[0] in ("let", "var"):
                return self.parse_type(toks, j + 1, owner)[0]
            if depth == 0 and tok == "=" and toks[0] in ("let", "var") and j + 1 < len(toks):
                head = toks[j + 1]
                if IDENT_RE.match(head) and self.resolve_type(head, owner):
                    return frozenset(self.resolve_type(head, owner))
        return frozenset()

    def any_named(self, member):
        """Every declaration of `member` outside a SwiftUI view: what an
        untyped receiver may name. A view's members compute what a screen
        shows and are reached through the view's own code, not a stored
        score's."""
        if not hasattr(self, "_views"):
            self._views = {t for t in self.types if "View" in self.lineage({t})}
            self._named = {}
        if member not in self._named:
            self._named[member] = {d for d in self.by_name.get(member, ()) if d.rpartition(".")[0] not in self._views}
        return self._named[member]

    def any_read(self, member):
        """`any_named` for a member read, not called: its properties and
        cases, or its methods when it has nothing else of that name."""
        named = self.any_named(member)
        values = {d for d in named if not self.is_function(d)}
        return values or named

    def file_text(self, name):
        if not hasattr(self, "_texts"):
            self._texts = {}
        if name not in self._texts:
            self._texts[name] = pathlib.Path(name).read_text(encoding="utf-8")
        return self._texts[name]

    def is_case(self, decl):
        return any(self.index[name][key].get("raw", [("", 0)])[0][0] == "case" for name, key in self.decls[decl])

    def is_function(self, decl):
        return any(self.index[name][key].get("raw", [("", 0)])[0][0] in ("func", "init", "subscript")
                   for name, key in self.decls[decl])

    def typed_lookup(self, tset, member, called=True):
        """`lookup` for a receiver of type `tset`: app types by their
        lineage, external types (`Double`, `[X]`) by the app's extensions."""
        self.guessed = True
        if not tset:
            return set((self.any_named(member) if called else self.any_read(member)))
        app = {n for n in tset if n in self.nominal}
        found = set()
        if app:
            found = self.lookup(app, member, fallback=False)
            if not found:
                # A member the type does not declare is synthesized from its
                # stored layout (`rawValue`, `allCases`, Codable) or comes
                # from where the inference could not see: both.
                return set((self.any_named(member) if called else self.any_read(member))).union(*(self.type_members(t) for t in app))
        other = tset - app
        library = {n for n in other if n.startswith("[") or n in REACH_LIBRARY or n in self.types}
        if other - library:
            return found | set((self.any_named(member) if called else self.any_read(member)))
        self.guessed = False
        if library:
            found |= {d for d in self.by_name.get(member, ()) if d.rpartition(".")[0] not in self.nominal and "." in d}
        return found

    def _below(self, app):
        out = set()
        for tpath in self.lineage(app):
            out |= self.descendants(tpath)
        return out

    def parameter_type(self, decl, label):
        """The type of `decl`'s parameter labelled `label`, or of the stored
        property `decl` itself when it is one."""
        if self.is_stored(decl):
            return self.declared_type(decl) if decl.rpartition(".")[2] == label else frozenset()
        found = frozenset()
        for name, key in self.decls[decl]:
            toks = [t for t, _ in self.index[name][key].get("raw", [])]
            if "(" not in toks:
                continue
            start = toks.index("(")
            depth = 0
            group = start + 1
            for k in range(start, len(toks)):
                depth += {"(": 1, ")": -1}.get(toks[k], 0)
                if (toks[k] == "," and depth == 1) or depth == 0:
                    if toks[group:group + 1] == [label] and ":" in toks[group:k]:
                        colon = group + toks[group:k].index(":")
                        found |= self.parse_type(toks, colon + 1, decl.rpartition(".")[0])[0]
                    group = k + 1
                if depth == 0:
                    break
        return found

    def operators(self, tpath):
        """What naming a type brings in: its header (conformances, raw
        type) and its operators."""
        return {tpath} | {d for d in self.members.get(tpath, ()) if not IDENT_RE.match(d.rpartition(".")[2])}

    def sink_fields(self):
        return {owner + "." + field for owner, names in STORED_FIELDS.items() for field in names}

    def type_members(self, tpath):
        """What naming a type brings in: its header, its stored properties,
        cases and aliases (their defaults and raw values), and its operators."""
        if not hasattr(self, "_type_members"):
            self._type_members = {}
        if tpath not in self._type_members:
            out = {tpath}
            for decl in self.members.get(tpath, ()):
                member = decl.rpartition(".")[2]
                if self.is_stored(decl) or not IDENT_RE.match(member):
                    out.add(decl)
            self._type_members[tpath] = out
        return self._type_members[tpath]

    def scans(self, decl):
        if not hasattr(self, "_scans"):
            self._scans = {}
        if decl not in self._scans:
            found = []
            for name, key in self.decls[decl]:
                entry = self.index[name][key]
                scan = _DeclScan(self, entry.get("raw", []), entry["type"])
                scan.lines = entry.get("lines", [])
                scan.file = name
                scan.run()
                found.append(scan)
            self._scans[decl] = found
        return self._scans[decl]

    def references(self, decl):
        return set().union(set(), *(scan.out for scan in self.scans(decl)))

    def stored_members(self, tpath):
        out = set()
        return {decl for decl in self.members.get(tpath, ()) if self.is_stored(decl)}

    def is_stored(self, decl):
        """A stored property, case or alias: a `let`, or a `var` with no
        body but its observers."""
        member = decl.rpartition(".")[2]
        for name, key in self.decls[decl]:
            if key.endswith("#" + member):
                return True
            toks = [t for t, _ in self.index[name][key].get("raw", [])]
            if toks[:1] == ["var"]:
                brace = toks.index("{") if "{" in toks else -1
                if brace < 0 or (brace + 1 < len(toks) and toks[brace + 1] in ("didSet", "willSet")):
                    return True
        return False

    def stored_values(self):
        """(fields, value types): the stored score fields, and every app type
        their values hold, closed over those types' stored properties."""
        fields = set()
        for owner, names in STORED_FIELDS.items():
            for field in names:
                decl = owner + "." + field
                if decl not in self.stored_members(owner):
                    raise ConfigError(f"stored field {decl} not found")
                fields.add(decl)
        types, work = set(), [n.strip("[]") for f in fields for n in self.declared_type(f)]
        while work:
            tpath = work.pop()
            if tpath in types or tpath not in self.nominal:
                continue
            types.add(tpath)
            for decl in self.stored_members(tpath):
                fields.add(decl)
                work.extend(n.strip("[]") for n in self.declared_type(decl))
        return fields, types


class _DeclScan:
    """The declarations one declaration's tokens reference."""

    def __init__(self, program, raw, context):
        self.p = program
        self.toks = [t for t, _ in raw]
        self.line_of = None
        self.raw = raw
        self.ctx = context
        self.env = {}
        self.generics = {}
        self.closures = []
        self.labels = set()
        self.returns = frozenset()
        self.out = set()
        self.constructs = set()
        self.writes = set()
        self.lines = []
        self.params = {}
        self.feeds = []
        self.calls = []
        # For `stored-defuse`: what each token refers to, where each local
        # is defined, the expressions written into stored fields, and the
        # arguments of each resolved call.
        self.refs_at = {}
        self.precise_at = set()
        self.defs = {}
        self.spans = []
        self.call_args = []
        self.param_list = []
        self.param_writes = {}
        self.closure_params = set()

    def _ref(self, i, decls, precise=False):
        self.out |= decls
        if decls:
            self.refs_at.setdefault(i, set()).update(decls)
            if precise:
                self.precise_at.add(i)

    def run(self):
        self._signature()
        toks = self.toks
        for i, tok in enumerate(toks):
            if i in self.labels or not IDENT_RE.match(tok) or tok in REACH_KEYWORDS:
                continue
            prev = toks[i - 1] if i else ""
            nxt = toks[i + 1] if i + 1 < len(toks) else ""
            if prev == ".":
                before = toks[i - 2] if i > 1 else ""
                if not (IDENT_RE.match(before) or before in (")", "]", "?", "!", ">")) or before in REACH_KEYWORDS - {"self", "Self", "super"}:
                    self._implicit(i)
                continue
            if nxt == ":" and prev in ("(", ","):
                continue
            if prev in ("let", "var", "func", "case", "typealias") or (prev == "," and self._in_binding(i)):
                self._bind(i)
                continue
            if prev in ("(", ",") and self._in_tuple_binding(i):
                continue
            if tok in self.params and (nxt in REACH_ASSIGN or (nxt == "." and i + 2 < len(toks) and toks[i + 2] in REACH_MUTATORS)):
                self.param_writes.setdefault(tok, []).append((i + 2, self._statement_end(i + 2)))
            if tok in self.env and tok not in self.params and nxt in REACH_ASSIGN:
                self.defs.setdefault(tok, []).append((i + 2, self._statement_end(i + 2)))
            elif tok in self.env and nxt == "." and i + 2 < len(toks) and toks[i + 2] in REACH_MUTATORS:
                self.defs.setdefault(tok, []).append((i + 3, self._statement_end(i + 3)))
            elif tok in self.env and nxt == "." and i + 3 < len(toks) and IDENT_RE.match(toks[i + 2]) and toks[i + 3] == "(" \
                    and i and self.lines and self.lines[i - 1] != self.lines[i]:
                # `local.method(...)` as a statement: a mutating call may change it.
                self.defs.setdefault(tok, []).append((i + 2, self._statement_end(i + 2)))
            elif tok in self.env and nxt == "[" and prev != ".":
                close = _skip_balanced(self.raw, i + 1)
                if close < len(toks) and toks[close] in REACH_ASSIGN:
                    self.defs.setdefault(tok, []).append((i + 1, self._statement_end(close + 1)))
            if prev == "&" and tok in self.env:
                self.defs.setdefault(tok, []).append(self._enclosing_call(i))
            if prev == "for":
                self._bind_for(i)
                continue
            self._chain(i)
        return self.out

    def _implicit(self, i):
        """An implicit member (`.init(...)`, `.overnight`): looked up on the
        type an annotation or the declaration's return type gives it, else
        by name."""
        toks = self.toks
        context = frozenset()
        if i > 1 and toks[i - 2] == "return":
            context = self.returns
        elif i > 1 and toks[i - 2] == "=":
            k = i - 3
            while k >= 0 and k > i - 16 and toks[k] not in ("let", "var", "{", "}", "(", "=", ","):
                if toks[k] == ":" and k > 1 and toks[k - 2] in ("let", "var"):
                    context = self._type(k + 1)[0]
                    break
                k -= 1
        elif i > 3 and toks[i - 2] == ":" and IDENT_RE.match(toks[i - 3]) and toks[i - 4] in ("(", ","):
            context = self._argument_type(i - 3)
        called = i + 1 < len(toks) and toks[i + 1] in ("(", "{")
        found = self.p.typed_lookup(context, toks[i], called)
        self._ref(i, found)
        if toks[i] == "init":
            for tpath in context & self.p.types:
                self.constructs.add(tpath)
                self._ref(i, self.p.type_members(tpath))
                if i + 1 < len(toks) and toks[i + 1] == "(":
                    self.spans.append((frozenset(), frozenset({tpath}), (i + 2, _skip_balanced(self.raw, i + 1) - 1)))
        return self._types_of(found)

    def _argument_type(self, k):
        """The type of the parameter the argument labelled toks[k] is passed
        to, from the callee's signature or, for a memberwise initializer, the
        stored property of that name."""
        toks = self.toks
        depth, j = 0, k - 1
        while j >= 0:
            depth += {")": 1, "(": -1}.get(toks[j], 0)
            if depth < 0:
                break
            j -= 1
        if j < 1 or not IDENT_RE.match(toks[j - 1]):
            return frozenset()
        callee = toks[j - 1]
        owners = self.p.resolve_type(callee, self.ctx)
        if callee == "init" and j > 2 and toks[j - 2] == ".":
            owners = {n for n in self._chain_type_before(j - 2) if n in self.p.types}
        if owners:
            decls = {o + ".init" for o in owners} | {o + "." + toks[k] for o in owners}
        else:
            decls = self.p.by_name.get(callee, set())
        found = frozenset()
        for decl in decls:
            if decl in self.p.decls:
                found |= self.p.parameter_type(decl, toks[k])
        return found

    def _chain_type_before(self, j):
        return self.p.resolve_type(self.toks[j - 1], self.ctx) if j and IDENT_RE.match(self.toks[j - 1]) else set()

    def value_params(self):
        """Parameters that carry data, not a handle: everything but a class,
        actor or protocol instance and the reading itself."""
        handles = {"HRVSession"}
        out = set()
        for name, tset in self.params.items():
            bare = {n.strip("[]") for n in tset}
            if bare and all(n in handles or self.p.kinds.get(n) in ("class", "actor", "protocol") for n in bare):
                continue
            out.add(name)
        return out

    def _enclosing_call(self, i):
        """The span of the call an `&argument` at toks[i] is passed to, its
        callee chain included."""
        toks = self.toks
        depth, j = 0, i - 1
        while j >= 0:
            depth += {")": 1, "(": -1}.get(toks[j], 0)
            if depth < 0:
                break
            j -= 1
        if j < 0:
            return (i, i + 1)
        start = j
        while start > 0 and (IDENT_RE.match(toks[start - 1]) or toks[start - 1] in (".", "?", "!")):
            start -= 1
        return (start, _skip_balanced(self.raw, j))

    def closure_sources(self):
        """{name: [(label, callee, position)]} for each parameter of a closure
        passed as a labelled argument (`Editor(onSave: { data in ... })`):
        its values are what the callee passes when it invokes `onSave`."""
        if hasattr(self, "_closure_sources"):
            return self._closure_sources
        toks, out = self.toks, {}
        for k in range(3, len(toks)):
            if toks[k] != "{" or toks[k - 1] != ":" or not IDENT_RE.match(toks[k - 2]) or toks[k - 3] not in ("(", ","):
                continue
            names, m = [], k + 1
            while m < len(toks) and (IDENT_RE.match(toks[m]) or toks[m] in (",", "(", ")")) and toks[m] != "in":
                if IDENT_RE.match(toks[m]):
                    names.append(toks[m])
                m += 1
            if m >= len(toks) or toks[m] != "in" or not names:
                names = [f"${n}" for n in range(4)]  # shorthand parameters
            depth, j = 0, k - 3
            while j >= 0:
                depth += {")": 1, "(": -1}.get(toks[j], 0)
                if depth < 0:
                    break
                j -= 1
            callee = toks[j - 1] if j > 0 else ""
            for position, name in enumerate(names):
                out.setdefault(name, []).append((toks[k - 2], callee, position))
        self._closure_sources = out
        return out

    def _in_tuple_binding(self, i):
        """`let (a, b) = expr`: each name is defined by the whole expression."""
        toks = self.toks
        j = i - 1
        while j >= 0 and (IDENT_RE.match(toks[j]) or toks[j] in (",", "(")):
            if toks[j] == "(":
                break
            j -= 1
        if j < 1 or toks[j] != "(" or toks[j - 1] not in ("let", "var"):
            return False
        end = _skip_balanced(self.raw, j)
        if end < len(toks) and toks[end] == "=":
            self.defs.setdefault(toks[i], []).append((end + 1, self._statement_end(end + 1)))
        return True

    def controls(self, w):
        """The condition spans that decide whether toks[w] runs: every
        enclosing `if`, `while`, `for`, `switch`, and every `guard` before it
        in an enclosing block."""
        toks = self.toks
        out = []
        for k, tok in enumerate(toks[:w]):
            if tok == "case" and self._case_controls(k, w):
                out.append(self._case_controls(k, w))
                continue
            if tok not in ("if", "guard", "while", "switch", "for") or (k and toks[k - 1] == "."):
                continue
            c = k + 1
            while c < len(toks) and toks[c] != "{" and not (tok == "guard" and toks[c] == "else"):
                c = _skip_balanced(self.raw, c) if toks[c] in ("(", "[") else c + 1
            if c >= len(toks):
                continue
            if tok == "guard":
                body_end = _skip_balanced(self.raw, c + 1) if c + 1 < len(toks) and toks[c + 1] == "{" else c
                if body_end <= w and self._same_block(k, w):
                    out.append((k + 1, c))
            else:
                end = _skip_balanced(self.raw, c)
                while end + 1 < len(toks) and toks[end] == "else":
                    nxt = end + 1
                    while nxt < len(toks) and toks[nxt] != "{":
                        nxt += 1
                    end = _skip_balanced(self.raw, nxt) if nxt < len(toks) else nxt
                if c < w < end:
                    out.append((k + 1, c))
        return out

    def _case_controls(self, k, w):
        """The pattern of the `switch` case at toks[k] when toks[w] runs in
        its body, else None."""
        toks = self.toks
        if k and toks[k - 1] in ("if", "guard", ",", "for", "while"):
            return None
        depth, colon = 0, None
        for c in range(k + 1, w):
            t = toks[c]
            if t in ("(", "[", "{"):
                depth += 1
            elif t in (")", "]", "}"):
                depth -= 1
                if depth < 0:
                    return None
            elif depth == 0 and t == ":" and colon is None:
                colon = c
            elif depth == 0 and colon is not None and t in ("case", "default"):
                return None
        return (k + 1, colon) if colon is not None else None

    def _same_block(self, k, w):
        """True when toks[w] sits in the block that encloses toks[k]."""
        depth = 0
        for t in self.toks[k:w]:
            depth += {"{": 1, "}": -1}.get(t, 0)
            if depth < 0:
                return False
        return True

    def argument(self, j, end, label, position):
        """The span of the argument passed for a parameter, by its label, or
        by its position when it has none, in the call whose `(` is toks[j]."""
        toks = self.toks
        depth, start, index = 0, j + 1, 0
        for k in range(j, end):
            depth += {"(": 1, ")": -1, "[": 1, "]": -1, "{": 1, "}": -1}.get(toks[k], 0)
            if (toks[k] == "," and depth == 1) or k == end - 1:
                labelled = start + 1 < k and IDENT_RE.match(toks[start]) and toks[start + 1] == ":"
                if label != "_" and labelled and toks[start] == label:
                    return (start + 2, k)
                if label == "_" and index == position:
                    return (start + 2, k) if labelled else (start, k)
                start, index = k + 1, index + 1
        return None

    def _in_binding(self, i):
        j = i - 1
        while j >= 0 and self.toks[j] not in ("let", "var", "\n", "{", "}", "(", "="):
            j -= 1
        if j >= 0 and self.toks[j] in ("let", "var"):
            return True
        # `var a = 0, b = 0`: a later name on the same line as its `var`.
        if not self.lines or j < 0 or self.toks[j] != "=":
            return False
        depth = 0
        for k in range(i - 1, -1, -1):
            if self.lines[k] != self.lines[i]:
                return False
            depth += {")": 1, "]": 1, "(": -1, "[": -1}.get(self.toks[k], 0)
            if depth < 0 or self.toks[k] in ("{", "}"):
                return False
            if self.toks[k] in ("let", "var") and depth == 0:
                return True
        return False

    def _type(self, j):
        tset, k = self.p.parse_type(self.toks, j, self.ctx)
        resolved = set()
        for name in tset:
            bare = name.strip("[]")
            if bare in self.generics:
                wrap = name.startswith("[")
                resolved |= {("[" + g + "]") if wrap else g for g in self.generics[bare]}
            else:
                resolved.add(name)
        app = {n.strip("[]") for n in resolved if n.strip("[]") in self.p.types}
        for tpath in app:
            self._ref(j, self.p.operators(tpath))
        return frozenset(resolved), k

    def _signature(self):
        toks = self.toks
        if not toks or toks[0] not in ("func", "init", "subscript"):
            return
        j = 2 if toks[0] == "func" else 1
        if j < len(toks) and toks[j] in ("?", "!"):
            j += 1
        if j < len(toks) and toks[j] == "<":
            end = _skip_balanced(self.raw, j)
            self._generics(j + 1, end)
            j = end
        if j >= len(toks) or toks[j] != "(":
            return
        end = _skip_balanced(self.raw, j)
        k = end
        while k < len(toks) and toks[k] in ("async", "throws", "rethrows"):
            k += 1
        if k < len(toks) and toks[k] == "->":
            self.returns = self._type(k + 1)[0]
        depth, start = 0, j + 1
        for k in range(j, end):
            depth += {"(": 1, ")": -1, "[": 1, "]": -1, "<": 1, ">": -1}.get(toks[k], 0)
            if (toks[k] == "," and depth == 1) or k == end - 1:
                self._param(start, k)
                start = k + 1

    def _generics(self, start, end):
        toks = self.toks
        for k in range(start, end):
            if IDENT_RE.match(toks[k]) and k + 1 < end and toks[k + 1] == ":":
                self.generics[toks[k]] = self._type(k + 2)[0]

    def _param(self, start, stop):
        toks = self.toks
        for k in range(start, stop):
            if toks[k] == ":":
                for label in range(start, k):
                    self.labels.add(label)
                self.env[toks[k - 1]] = self._type(k + 1)[0]
                self.params[toks[k - 1]] = self.env[toks[k - 1]]
                self.param_list.append((toks[start], toks[k - 1]))
                if "->" in toks[k + 1:stop]:
                    self.closure_params.add(toks[k - 1])
                return

    def _bind(self, i):
        toks = self.toks
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        if nxt == ":":
            self.env[toks[i]], k = self._type(i + 2)
            k = i + 2
            while k < len(toks) and toks[k] not in ("=", "{", "}", "let", "var", "func"):
                k = _skip_balanced(self.raw, k) if toks[k] in ("(", "[") else k + 1
            if k < len(toks) and toks[k] == "=":
                self.defs.setdefault(toks[i], []).append((k + 1, self._statement_end(k + 1)))
        elif nxt == "=":
            self.defs.setdefault(toks[i], []).append((i + 2, self._statement_end(i + 2)))
            j = i + 2
            while j < len(toks) and toks[j] in ("try", "await", "?", "!"):
                j += 1
            if j < len(toks) and IDENT_RE.match(toks[j]) and toks[j] not in ("true", "false", "nil"):
                self.env[toks[i]] = self._chain(j)
            elif j < len(toks):
                self.env[toks[i]] = self._literal_type(toks[j])

    @staticmethod
    def _literal_type(tok):
        if tok in ("true", "false"):
            return frozenset({"Bool"})
        if NUMBER_RE.match(tok):
            return frozenset({"Double" if "." in tok else "Int"})
        if tok == '""':
            return frozenset({"String"})
        return frozenset()

    def _bind_for(self, i):
        toks = self.toks
        j = i + 1
        while j < len(toks) and toks[j] != "in":
            j += 1
        if j + 1 < len(toks) and IDENT_RE.match(toks[j + 1]):
            self.env[toks[i]] = self.p.element(self._chain(j + 1))
        end = j + 1
        while end < len(toks) and toks[end] != "{":
            end = _skip_balanced(self.raw, end) if toks[end] in ("(", "[") else end + 1
        self.defs.setdefault(toks[i], []).append((j + 1, end))

    def _closure_type(self, i):
        for start, end, tset in reversed(self.closures):
            if start <= i < end:
                return tset
        return frozenset()

    def _open_closure(self, j, recv):
        """Types a closure opening at toks[j] whose parameters are the
        elements of `recv` (or `recv` itself, for an optional's map)."""
        toks = self.toks
        elem = self.p.element(recv) or recv
        end = _skip_balanced(self.raw, j)
        self.closures.append((j, end, elem))
        k = j + 1
        names = []
        while k < end and toks[k] != "in" and (IDENT_RE.match(toks[k]) or toks[k] in (",", "(", ")")):
            if IDENT_RE.match(toks[k]):
                if toks[k + 1] == "(":
                    return
                names.append(toks[k])
            k += 1
        if k + 1 < end and toks[k] == "in" and toks[k + 1] != ":":
            for name in names:
                self.env[name] = elem

    def _head(self, i):
        self.found = set()
        tok = self.toks[i]
        p = self.p
        if tok in ("self", "Self"):
            return frozenset({self.ctx}) if self.ctx else frozenset()
        if tok == "super":
            return frozenset(p.lineage({self.ctx}) - {self.ctx})
        if tok.startswith("$"):
            return self._closure_type(i)
        if tok in self.env:
            return self.env[tok]
        if tok in self.generics:
            return self.generics[tok]
        tpaths = p.resolve_type(tok, self.ctx)
        if tpaths:
            nxt = self.toks[i + 1] if i + 1 < len(self.toks) else ""
            after = self.toks[i + 2] if i + 2 < len(self.toks) else ""
            for tpath in tpaths:
                built = nxt in ("(", "{") or (nxt == "." and after in ("init", "self"))
                self._ref(i, p.type_members(tpath) if built else p.operators(tpath))
            if nxt in ("(", "{") or (nxt == "." and after == "init"):
                self.found = p.typed_lookup(frozenset(tpaths), "init") & {t + ".init" for t in p.lineage(tpaths)}
                self._ref(i, self.found, precise=True)
                self.constructs |= tpaths
                if nxt == "(":
                    end = _skip_balanced(self.raw, i + 1)
                    self.feeds.append((frozenset(), frozenset(tpaths), self._idents(i + 1, end)))
                    self.spans.append((frozenset(), frozenset(tpaths), (i + 2, end - 1)))
            return frozenset(tpaths)
        found = set()
        scope = self.ctx.split(".") if self.ctx else []
        for k in range(len(scope), 0, -1):
            prefix = ".".join(scope[:k])
            found |= p.lookup({prefix}, tok, fallback=False)
        if tok in p.decls and tok not in p.types:
            found.add(tok)
        self._ref(i, found, precise=True)
        self.found = found
        self._written_at(i + 1, found)
        if i and self.toks[i - 1] == "&":
            self.writes |= found
            if found:
                self.spans.append((frozenset(found), frozenset(), self._enclosing_call(i)))
        return self._types_of(found)

    def _written_at(self, j, found):
        """Records `found` as written when the token at j assigns, mutates
        in place or subscripts-and-assigns what precedes it."""
        toks, n = self.toks, len(self.toks)
        tok = toks[j] if j < n else ""
        span = None
        if tok in REACH_ASSIGN:
            span = (j + 1, self._statement_end(j + 1))
        if tok == "." and j + 2 < n and toks[j + 1] in REACH_MUTATORS and toks[j + 2] == "(":
            span = (j + 2, _skip_balanced(self.raw, j + 2))
        trailing = None
        if tok == "." and j + 2 < n and toks[j + 1] in REACH_MUTATORS and toks[j + 2] == "{":
            trailing = (j + 2, _skip_balanced(self.raw, j + 2))
        if trailing and found:
            self.spans.append((frozenset(found), frozenset(), trailing))
        if tok == "[":
            end = _skip_balanced(self.raw, j)
            if end < n and toks[end] in REACH_ASSIGN:
                span = (end + 1, self._statement_end(end + 1))
        if span:
            self.writes |= found
            self.feeds.append((frozenset(found), frozenset(), self._idents(*span)))
            self.spans.append((frozenset(found), frozenset(), span))

    def _idents(self, start, end):
        """The names an expression between toks[start:end] reads."""
        toks = self.toks
        return frozenset(toks[k] for k in range(start, min(end, len(toks)))
                         if IDENT_RE.match(toks[k]) and toks[k] not in REACH_KEYWORDS and (k == 0 or toks[k - 1] != "."))

    def _statement_end(self, j):
        """Index just past the expression starting at toks[j]: it runs on
        while brackets are open, a line ends in an operator, or the next
        line continues with one."""
        toks, lines, n = self.toks, self.lines, len(self.toks)
        depth = 0
        k = j
        while k < n:
            tok = toks[k]
            if tok in ("(", "[", "{"):
                depth += 1
            elif tok in (")", "]", "}"):
                depth -= 1
                if depth < 0:
                    return k
            elif depth == 0 and k > j and lines[k] != lines[k - 1]:
                continued = tok in (".", "?", ":", "??", "&&", "||", "+", "-", "*", "/", "==", "!=", "<", ">", "<=", ">=")
                if not continued and toks[k - 1] not in (",", "=", "+", "-", "*", "/", "??", "&&", "||", ":", "?", "in"):
                    return k
            k += 1
        return k

    def _types_of(self, decls):
        types = set()
        for decl in decls:
            types |= self.p.declared_type(decl)
        return frozenset(types)

    def _chain(self, i):
        """The type of the postfix chain headed at toks[i]; every member it
        names is a reference."""
        toks, n = self.toks, len(self.toks)
        tset = self._head(i)
        last = self.found
        guessed = False
        j = i + 1
        while j < n:
            tok = toks[j]
            if tok in ("?", "!") and j + 1 < n and toks[j + 1] in (".", "(", "["):
                j += 1
            elif tok == "(":
                end = _skip_balanced(self.raw, j)
                if last and (not guessed or len(last) == 1):
                    self.calls.append((frozenset(last), self._idents(j + 1, end)))
                    self.call_args.append((frozenset(last), j, end))
                    if any(d.endswith(".init") for d in last):
                        owners = frozenset(d.rpartition(".")[0] for d in last)
                        self.feeds.append((frozenset(), owners, self._idents(j + 1, end)))
                        self.spans.append((frozenset(), owners, (j + 1, end - 1)))
                last = set()
                j = end
            elif tok == "[":
                j = _skip_balanced(self.raw, j)
                tset = self.p.element(tset)
                last = set()
            elif tok == "." and j + 1 < n and toks[j + 1] == "self":
                j += 2
            elif tok == "." and j + 1 < n and IDENT_RE.match(toks[j + 1]):
                recv = tset
                called = j + 2 < n and toks[j + 2] in ("(", "{")
                found = self.p.typed_lookup(tset, toks[j + 1], called)
                guessed = self.p.guessed
                last = found
                self._ref(j + 1, found, precise=not guessed or len(found) == 1)
                if toks[j + 1] == "init":
                    self.constructs |= {t for t in recv if t in self.p.types}
                tset = self._types_of(found)
                j += 2
                certain = found if not guessed else found & self.p.sink_fields()
                self._written_at(j, certain)
                if i and toks[i - 1] == "&" and not (j < n and toks[j] in (".", "?", "!", "(", "[")):
                    self.writes |= certain
                    if certain:
                        self.spans.append((frozenset(certain), frozenset(), self._enclosing_call(i)))
                if j < n and toks[j] == "(" and j + 1 < n and toks[j + 1] == "{":
                    self._open_closure(j + 1, recv)
                elif j < n and toks[j] == "{":
                    self._open_closure(j, recv)
            else:
                break
        return tset


def stored_entry_points(program):
    """Every declaration that creates or changes a stored score's data: it
    builds a value of a stored type, or assigns, mutates in place or passes
    inout a stored field or a stored property of such a value. A writer
    whose written value reads one of its parameters is fed by its callers,
    so each caller is an entry point too, and is fed in turn when the
    arguments it passes read its own parameters."""
    fields, types = program.stored_values()
    entries, fed, callers = set(), set(), {}
    for decl in program.decls:
        for scan in program.scans(decl):
            values = scan.value_params()
            for written, built, names in scan.feeds:
                if written & fields or built & types:
                    entries.add(decl)
                    if names & values:
                        fed.add(decl)
            for callees, names in scan.calls:
                for callee in callees:
                    callers.setdefault(callee, []).append((decl, bool(names & values)))
    work = list(fed)
    while work:
        for caller, passes_own in callers.get(work.pop(), ()):
            entries.add(caller)
            if passes_own and caller not in fed:
                fed.add(caller)
                work.append(caller)
    return entries


def stored_reach(program):
    """Every declaration reachable from the writers of a stored score, closed
    so that every function of Analysis/** the reached code names is reached
    too: the scoring code's own helpers are never left out on a guess about
    which of two same-named functions a call meant."""
    seen = set()
    work = list(stored_entry_points(program))
    analysis = {}
    for decl, refs in program.decls.items():
        if any(name.startswith("Emuqu/Sources/Analysis/") for name, _ in refs) and program.is_function(decl):
            analysis.setdefault(decl.rpartition(".")[2], set()).add(decl)
    while work:
        decl = work.pop()
        if decl in seen or decl not in program.decls:
            continue
        seen.add(decl)
        work.extend(ref for ref in program.references(decl) if ref not in seen)
        for name, key in program.decls[decl]:
            for tok in program.index[name][key]["tokens"]:
                work.extend(d for d in analysis.get(tok, ()) if d not in seen)
    return seen


def _reach_items(program, reached):
    merged = {}
    for name, key in sorted(ref for decl in reached for ref in program.decls[decl]):
        merged.setdefault(key, []).extend(program.index[name][key]["tokens"])
    return merged


_STORED_REACH = {}


def _stored_reach_program():
    """The program and its reached set, built once per run."""
    root = str(pathlib.Path(TOKEN_SOURCE_ROOT).resolve())
    if root not in _STORED_REACH:
        program = Program(_reach_index())
        _STORED_REACH[root] = (program, stored_reach(program))
    return _STORED_REACH[root]


def stored_reach_items():
    return _reach_items(*_stored_reach_program())


def stored_reach_hash():
    return _tokens_digest(stored_reach_items())


# --- stored-defuse --------------------------------------------------------
# `stored-reach` hashed every declaration a writer's whole body reached, and
# a writer's body does much more than compute what it stores: it saves,
# syncs, logs, speaks and redraws. That made most of the app scoring code,
# so almost any edit asked for a version bump. This scheme roots the graph
# at the EXPRESSIONS a stored field is given (the right side of an
# assignment, the argument of an in-place mutation, the arguments of a
# stored type's initializer) and at the conditions that decide whether that
# write runs (enclosing `if`, `while`, `for`, `switch`, and the `guard`s
# before it). From each root expression it follows:
#   * every declaration the expression refers to, and from those callees the
#     whole call graph `stored-reach` follows;
#   * each local the expression reads, back to the expressions that define
#     it in the same function (`let x = ...`, `x = ...`, `x.append(...)`,
#     `for x in ...`);
#   * each parameter it reads, back to the argument callers pass at that
#     parameter's label or position;
#   * each stored property of another type it reads, to every expression
#     that writes that property, so a value carried through a struct is
#     traced to where it was computed.
# The writer itself is hashed whole, so an edit anywhere in a function that
# stores a score asks for a bump, but only its root expressions are
# followed. SwiftUI views and copy-only types are never hashed: what they
# compute is shown, and the analysis a view hands to a stored field is
# reached through the expression it passes.
def _excluded_owner(program, decl):
    owner = decl.split(".")[0]
    if owner in TOKEN_TEXT_TYPES:
        return True
    program.any_named("")
    return any(decl == v or decl.startswith(v + ".") for v in _view_roots(program))


def _view_roots(program):
    if not hasattr(program, "_view_roots"):
        program.any_named("")
        program._view_roots = sorted(program._views)
        program._view_set = set(program._views)
    return program._view_roots


def _is_excluded(program, decl):
    if not hasattr(program, "_excluded"):
        program._excluded = {}
    if decl not in program._excluded:
        _view_roots(program)
        parts = decl.split(".")
        program._excluded[decl] = parts[0] in TOKEN_TEXT_TYPES or any(
            ".".join(parts[:k]) in program._view_set for k in range(1, len(parts) + 1))
    return program._excluded[decl]


def _defuse_index(program, fields, types):
    """(roots, writers of each stored member, callers of each declaration)."""
    roots, writers, callers = [], {}, {}
    sinks = program.sink_fields()
    for decl in program.decls:
        for scan in program.scans(decl):
            scan.value_owner = program.kinds.get(scan.ctx) in ("struct", "enum")
            for written, built, span in scan.spans:
                # A write to a stored field is traced up through the callers
                # that feed it; a value of a stored type is built in many
                # places that never store it, so its arguments are traced
                # but not its callers.
                if written & sinks:
                    roots.append((decl, scan, span, True))
                elif written & fields or built & types:
                    roots.append((decl, scan, span, False))
                # A traced property's writers: an assignment to it, or the
                # argument a construction of its type passes for it. The
                # values are followed from there, and up through callers only
                # from a value type's initializer, to the argument for that
                # parameter: a service's initializer wires the app, and its
                # callers are the composition root.
                for member in written:
                    value_init = decl.endswith(".init") and program.kinds.get(decl[:-5]) in ("struct", "enum")
                    writers.setdefault(member, []).append((decl, scan, span, "once" if value_init else False))
                for tpath in built:
                    whole = program.kinds.get(tpath) in ("struct", "enum")
                    for member in program.stored_members(tpath):
                        arg = scan.argument(span[0] - 1, span[1] + 1, member.rpartition(".")[2], -1)
                        if arg or whole:
                            writers.setdefault(member, []).append((decl, scan, arg or span, False))
            for callees, j, end in scan.call_args:
                for callee in callees:
                    callers.setdefault(callee, []).append((decl, scan, j, end))
    return roots, writers, callers


def _result_spans(scan):
    """What a declaration hands back to an expression that names it: its
    `return` expressions and the conditions before them, the whole body of an
    initializer, a single-expression body, the writes to its `inout`
    parameters, or a stored property's whole declaration (its default).
    Overloads share one key, so each is read on its own."""
    toks = scan.toks
    starts = [k for k, depth in _top_level(toks) if toks[k] in ("func", "init", "subscript", "var")]
    if not starts or starts[0] != 0:
        starts = [0] + starts
    spans = []
    for n, start in enumerate(starts):
        spans.extend(_segment_results(scan, start, starts[n + 1] if n + 1 < len(starts) else len(toks)))
    return spans


def _top_level(toks):
    depth = 0
    for k, tok in enumerate(toks):
        if depth == 0:
            yield k, depth
        depth += {"{": 1, "}": -1, "(": 1, ")": -1}.get(tok, 0)


def _segment_results(scan, start, stop):
    toks = scan.toks
    head = toks[start] if start < stop else ""
    body = next((k for k in range(start, stop) if toks[k] == "{"), -1)
    if head not in ("func", "init", "subscript", "var") or body < 0:
        return [(start, stop)]
    if head == "var" and body + 1 < stop and toks[body + 1] in ("didSet", "willSet"):
        return [(start, stop)]
    if head == "init":
        return [(body, stop)]
    returns = [k for k in range(body, stop) if toks[k] == "return"]
    # The signature too: default arguments and parameter types.
    spans = [(start, body)] + [(k + 1, scan._statement_end(k + 1)) for k in returns]
    spans += [c for k in returns for c in scan.controls(k)]
    # A single-expression body returns its expression; a function that
    # returns nothing hands back only what it writes through `inout`.
    if not returns and (head != "func" or "->" in toks[start:body] or scan.value_owner):
        spans.append((body, stop))
    if "inout" in toks[start:body]:
        for _, name in scan.param_list:
            spans.extend(scan.defs.get(name, ()))
            spans.extend(scan.param_writes.get(name, ()))
    return spans


def _trace(program, item, writers, callers, traced_fields):
    """The items one expression leads to, and the declarations it names."""
    decl, scan, (start, end), upward = item
    spans = [(start, end)] + scan.controls(start)
    more, refs = [], set()
    for a, b in spans:
        for k in range(a, min(b, len(scan.toks))):
            found = scan.refs_at.get(k, ())
            if k in scan.precise_at or len(found) <= _GUESS_LIMIT:
                refs.update(found)
            elif found:
                refs.update(d for d in found if _in_analysis(program, d) or program.is_case(d))
            if k in scan.precise_at:
                for member in found:
                    if member not in traced_fields and _traceable_field(program, member):
                        traced_fields.add(member)
                        more.extend(writers.get(member, ()))
        for name in scan._idents(a, b):
            more.extend((decl, scan, d, upward) for d in scan.defs.get(name, ()))
            # A root's context climbs through every caller; an initializer
            # reached from a traced property goes one step, to the argument
            # its construction passes, since that construction may be
            # anywhere the type is built.
            onward = upward is True
            if upward and name in scan.params and name in scan.value_params() and _passes_value(scan, name, a, b):
                more.extend(_argument_items(scan, decl, name, callers, onward))
            if upward and name not in scan.params:
                for label, callee, position in scan.closure_sources().get(name, ()):
                    more.extend(_invocation_items(program, scan, label, callee, position, onward))
    return more, refs


# A guessed reference (receiver type unknown) with more candidates than this
# names a common word (`id`, `start`, `entries`); only its Analysis/**
# candidates are taken. A typed receiver is always followed.
_GUESS_LIMIT = 3
_SLICE_CALLEES = True


def _namespace_members(program, decl):
    """The constants of the caseless enum `decl` belongs to, when it does: a
    namespace of constants (`RecoveryScoreConstants.Vitals`) is one table,
    so a sibling constant is taken with the one an expression named."""
    owner = decl.rpartition(".")[0]
    if program.kinds.get(owner) != "enum" or _is_excluded(program, owner):
        return set()
    if not hasattr(program, "_namespaces"):
        program._namespaces = {}
    if owner not in program._namespaces:
        members = program.members.get(owner, set())
        caseless = not any(program.index[n][k].get("raw", [("", 0)])[0][0] == "case"
                           for m in members for n, k in program.decls[m])
        program._namespaces[owner] = {m for m in members if m not in program.types and program.is_stored(m)} if caseless else set()
    return program._namespaces[owner]


def _is_handle(program, decl):
    """A type named in an expression, or something that yields a service
    rather than a value: a class, actor or protocol instance held in a
    property (`static let shared = Store(...)`) or built by an initializer.
    What the service then computes is reached through the members an
    expression calls on it; building it, which wires up the app, is not."""
    owner, _, member = decl.rpartition(".")
    kind = lambda names: names and all(program.kinds.get(n) in ("class", "actor", "protocol") for n in names)
    if member == "init":
        return program.kinds.get(owner) in ("class", "actor")
    if not program.is_stored(decl):
        return False
    return bool(kind({n.strip("[]") for n in program.declared_type(decl)}))


def _in_analysis(program, decl):
    return any(name.startswith("Emuqu/Sources/Analysis/") for name, _ in program.decls[decl])


def _traceable_field(program, member):
    """A property (stored, or computed with a setter) of a type other than
    the reading itself, whose writers are traced when a traced expression
    reads it: a value carried through a struct or an analyzer's state is
    traced to where it was computed. The reading's other fields are its
    inputs (its beats, its times), which collection and sync decide."""
    owner = member.rpartition(".")[0]
    if program.kinds.get(owner) not in ("struct", "enum", "class", "actor") or owner == "HRVSession":
        return False
    if program.is_function(member) or _is_excluded(program, member):
        return False
    held = {name.strip("[]") for name in program.declared_type(member)}
    return bool(held) and all(name in _TRACED_LIBRARY or program.kinds.get(name) in ("struct", "enum") for name in held)


# Library types a traced property may hold: numbers and times. A flag, a
# string or a reference to a service is state, not a computed value.
_TRACED_LIBRARY = {"Double", "Float", "CGFloat", "Int", "Int64", "Int32", "TimeInterval", "Date", "DateInterval"}


def _invocation_items(program, scan, label, callee, position, onward=True):
    """The arguments a type passes when it invokes the closure property
    `label` it was given: the values a closure parameter receives."""
    owners = program.resolve_type(callee, scan.ctx) or {d.rpartition(".")[0] for d in program.by_name.get(callee, ())}
    out = []
    for owner in owners:
        for member in program.members.get(owner, ()):
            for other in program.scans(member):
                toks = other.toks
                for k in range(len(toks) - 1):
                    if toks[k] == label and toks[k + 1] in ("(", "?") and (k == 0 or toks[k - 1] != "." or toks[k - 2] == "self"):
                        open_at = k + 1 if toks[k + 1] == "(" else k + 2
                        if open_at < len(toks) and toks[open_at] == "(":
                            span = other.argument(open_at, _skip_balanced(other.raw, open_at), "_", position)
                            if span:
                                out.append((member, other, span, onward))
    return out


def _passes_value(scan, name, a, b):
    """A closure parameter feeds the expression only where the expression
    calls it; naming it (to pass it on, or to store it) carries no value."""
    if name not in scan.closure_params:
        return True
    toks = scan.toks
    return any(toks[k] == name and k + 1 < len(toks) and toks[k + 1] == "(" for k in range(a, min(b, len(toks))))


def _argument_items(scan, decl, name, callers, onward=True):
    names = [param for _, param in scan.param_list]
    if name not in names:
        return []
    position = names.index(name)
    label = scan.param_list[position][0]
    out = []
    for cdecl, cscan, j, end in callers.get(decl, ()):
        span = cscan.argument(j, end, label, position)
        if span:
            out.append((cdecl, cscan, span, onward))
    return out


def stored_defuse(program):
    """(hashed declarations, names the traced expressions read)."""
    fields, types = program.stored_values()
    roots, writers, callers = _defuse_index(program, fields, types)
    analysis = {}
    for decl in program.decls:
        if _in_analysis(program, decl) and program.is_function(decl):
            analysis.setdefault(decl.rpartition(".")[2], set()).add(decl)
    traced_fields = set(fields)
    hashed, names, entered, seen = set(), set(), set(), set()
    work = list(roots)
    persisted = _persistence_index(program)
    handed_off = set()
    while True:
        if not work:
            work = _persisted_hand_offs(program, persisted, hashed, handed_off)
            if not work:
                break
        item = work.pop()
        key = (id(item[1]), item[2], item[3])
        if key in seen:
            continue
        seen.add(key)
        if not _is_excluded(program, item[0]):
            hashed.add(item[0])
        a, b = item[2]
        read = {t for t in item[1].toks[a:b] if IDENT_RE.match(t)}
        names |= read
        more, refs = _trace(program, item, writers, callers, traced_fields)
        work.extend(more)
        for name in read:
            refs |= analysis.get(name, set())
        refs |= {m for ref in refs if ref in program.decls for m in _namespace_members(program, ref)}
        for ref in refs:
            if ref in entered or ref not in program.decls or _is_excluded(program, ref):
                continue
            entered.add(ref)
            hashed.add(ref)
            if ref in program.types or _is_handle(program, ref):
                continue  # hashed, not followed: see _is_handle
            for scan in program.scans(ref):
                spans = _result_spans(scan) if _SLICE_CALLEES else [(0, len(scan.toks))]
                work.extend((ref, scan, span, False) for span in spans)
    return hashed, names


# Calls that persist or read a value by key: UserDefaults, the Keychain,
# files. The label names the key; the method says which way the value goes.
_PERSIST_LABELS = {"forKey", "key", "account", "service", "to", "contentsOf", "atPath"}
_PERSIST_WRITES = {
    "set", "setValue", "setObject", "setData", "setString", "setBool", "setDouble", "setInteger",
    "removeObject", "write", "save", "store", "update", "add", "createFile",
}


def _persistence_index(program):
    """(decl, scan, key, is_write, call span) for every keyed persistence call."""
    out = []
    for decl in program.decls:
        for scan in program.scans(decl):
            toks = scan.toks
            for k in range(1, len(toks) - 1):
                if toks[k] not in _PERSIST_LABELS or toks[k + 1] != ":" or toks[k - 1] not in ("(", ","):
                    continue
                depth, j = 0, k - 1
                while j >= 0:
                    depth += {")": 1, "(": -1}.get(toks[j], 0)
                    if depth < 0:
                        break
                    j -= 1
                if j < 1:
                    continue
                key = _persist_key(program, scan, k + 2)
                if key:
                    end = _skip_balanced(scan.raw, j)
                    value = scan.argument(j, end, "_", 0) or scan._enclosing_call(k)
                    out.append((decl, scan, key, toks[j - 1] in _PERSIST_WRITES, value))
    return out


def _persist_key(program, scan, k):
    """What identifies the key an argument at toks[k] names: the constant it
    reads, or the text of a string literal."""
    toks = scan.toks
    if k >= len(toks):
        return None
    if toks[k] == '"':
        text = program.file_text(scan.file)
        pos = scan.raw[k][1]
        return ("literal", text[pos:_skip_string(text, pos)])
    end = k
    while end + 1 < len(toks) and (IDENT_RE.match(toks[end + 1]) or toks[end + 1] in (".", "?", "!")):
        end += 1
    if toks[k] == "." or end not in scan.precise_at:
        return None  # an implicit member (a Codable key) or an untyped name identifies no key
    found = {d for d in scan.refs_at.get(end, set()) if program.is_stored(d) and not program.is_case(d)}
    return ("decl", frozenset(found)) if found else None


def _persisted_hand_offs(program, persisted, hashed, handed_off):
    """The writes that hand a value to a hashed reader through storage: a
    write to a key a hashed declaration reads, or any write in the type of a
    hashed value type or namespace that reads storage (its own accessor
    pair; a service class's other stores are not taken). Each is traced
    from the value it stores, one step up to the argument its callers pass."""
    read_keys, read_owners = set(), set()
    for decl, scan, key, is_write, span in persisted:
        if not is_write and decl in hashed:
            read_keys.add(key)
            owner = decl.rpartition(".")[0]
            if program.kinds.get(owner) in ("enum", "struct"):
                read_owners.add(owner)
    items = []
    for decl, scan, key, is_write, span in persisted:
        marker = (id(scan), span)
        if not is_write or marker in handed_off or _is_excluded(program, decl):
            continue
        shares_key = key in read_keys or (key[0] == "decl" and any(
            other[0] == "decl" and key[1] & other[1] for other in read_keys))
        if shares_key or decl.rpartition(".")[0] in read_owners:
            handed_off.add(marker)
            items.append((decl, scan, span, "once"))
    return items


_STORED_DEFUSE = {}


def _stored_defuse_program():
    root = str(pathlib.Path(TOKEN_SOURCE_ROOT).resolve())
    if root not in _STORED_DEFUSE:
        program = _STORED_REACH[root][0] if root in _STORED_REACH else Program(_reach_index())
        _STORED_DEFUSE[root] = (program,) + stored_defuse(program)
    return _STORED_DEFUSE[root]


def stored_defuse_items():
    program, hashed, _ = _stored_defuse_program()
    return _reach_items(program, hashed)


def stored_defuse_hash():
    return _tokens_digest(stored_defuse_items())


# --- stored-reach self-check ----------------------------------------------
# The hash is only as good as two things the gate cannot see from its
# output: that every token of a reached declaration's body is filed under
# that declaration (a closure default argument once filed a function's whole
# body under a stored property nothing reached), and that the reach is
# closed. These checks prove both on every run.

def _body_spans(raw):
    """(func offset, body start, body end) of every function, initializer
    and subscript in one file's token stream, found by bracket matching
    alone, independently of the walker's declaration tracking."""
    toks = [t for t, _ in raw]
    spans = []
    for i, tok in enumerate(toks):
        if tok not in ("func", "init", "subscript") or (i and toks[i - 1] == "."):
            continue
        depth, j = 0, i + 1
        while j < len(toks):
            t = toks[j]
            if t in ("(", "["):
                depth += 1
            elif t in (")", "]"):
                depth -= 1
            elif t == "{" and depth == 0:
                break
            elif t == "{":
                j = _skip_balanced(raw, j) - 1
            elif depth == 0 and t in ("}", "func", "var", "let", "case", "init", "subscript", "struct", "class", "enum"):
                j = len(toks)
                break
            j += 1
        if j < len(toks):
            spans.append((i, j, _skip_balanced(raw, j) - 1))
    return spans


def _attribution_problems(program, reached):
    """Body tokens of a reached function filed under another declaration."""
    problems = []
    for name, items in program.index.items():
        stream = sorted((pos, tok, entry["decl"]) for entry in items.values()
                        for (tok, pos) in entry.get("raw", []))
        raw = [(tok, pos) for pos, tok, _ in stream]
        owner = [decl for _, _, decl in stream]
        for start, body, end in _body_spans(raw):
            decl = owner[start]
            if decl not in reached:
                continue
            nested = []
            for b in range(body + 1, end):
                if raw[b][0] in REACH_NOMINAL and raw[b - 1][0] != ".":
                    brace = next((c for c in range(b, end) if raw[c][0] == "{"), end)
                    nested.append((b, _skip_balanced(raw, brace)))
            for k in range(body, end + 1):
                if owner[k] != decl and not any(a <= k < z for a, z in nested):
                    problems.append(f"{name}: the body of {decl} files `{raw[k][0]}` (offset {raw[k][1]}) "
                                    f"under {owner[k]}, so an edit there would not move the hash")
                    break
    return problems


def _planted_problems(program, reached):
    """A number planted in every reached declaration of every file must land
    in that declaration's hashed tokens."""
    problems = []
    marker = 7_919_000_000
    targets = {}
    for decl in reached:
        if decl.rpartition(".")[2] in TOKEN_SKIPPED:
            continue  # a case named like a modifier (`case open`): the walker drops the word
        for name, key in program.decls[decl]:
            entry = program.index[name][key]
            at = entry.get("body", entry.get("end"))
            if at is not None:
                targets.setdefault(name, []).append((at, key, decl))
    for name, plants in sorted(targets.items()):
        text = pathlib.Path(name).read_text(encoding="utf-8")
        expected = {}
        for at, key, decl in sorted(plants, reverse=True):
            marker += 1
            text = text[:at] + f" {marker} " + text[at:]
            expected[str(marker)] = (key, decl)
        landed = {}
        for key, entry in ReachWalker().walk(text).items():
            for tok in entry["tokens"]:
                if tok in expected:
                    landed[tok] = entry["decl"]
        for tok, (key, decl) in expected.items():
            if landed.get(tok) != decl:
                problems.append(f"{name}: a number planted in {decl} was filed under "
                                f"{landed.get(tok, 'nothing')}, so editing {decl} would not move the hash")
    return problems


def _named_analysis_problems(program, reached, hashed_names=None):
    """Every function of Analysis/** that the traced code names must be
    hashed: the whole hashed code under `stored-reach`, the traced
    expressions under `stored-defuse`."""
    if hashed_names is None:
        hashed_names = set()
        for decl in reached:
            for name, key in program.decls[decl]:
                hashed_names.update(t for t in program.index[name][key]["tokens"] if IDENT_RE.match(t))
    problems = []
    for decl, refs in sorted(program.decls.items()):
        in_analysis = any(name.startswith("Emuqu/Sources/Analysis/") for name, _ in refs)
        if in_analysis and decl not in reached and program.is_function(decl) and decl.rpartition(".")[2] in hashed_names \
                and not _is_excluded(program, decl):
            problems.append(f"{decl} is named by hashed code but is not hashed")
    return problems


def stored_reach_self_check():
    """Problems with the stored-reach hash's coverage; empty when sound."""
    program, reached = _stored_reach_program()
    return (_attribution_problems(program, reached) + _planted_problems(program, reached)
            + _named_analysis_problems(program, reached))


def stored_defuse_self_check():
    """Problems with the stored-defuse hash's coverage; empty when sound."""
    program, hashed, names = _stored_defuse_program()
    return (_attribution_problems(program, hashed) + _planted_problems(program, hashed)
            + _named_analysis_problems(program, hashed, names))


def self_check():
    """The current scheme's coverage problems."""
    return stored_defuse_self_check()


SCHEMES = {
    "static-lets": static_lets_hash, "decl-literals": decl_literals_hash,
    "decl-tokens": decl_tokens_hash, "decl-flow": decl_flow_hash,
    "stored-flow": stored_flow_hash, "stored-reach": stored_reach_hash,
    CURRENT_SCHEME: stored_defuse_hash,
}


def scheme_of(fields):
    """The scheme a baseline line was hashed under."""
    return fields[2] if len(fields) == 3 else "static-lets"


if __name__ == "__main__":
    scheme = sys.argv[1] if len(sys.argv) > 1 else CURRENT_SCHEME
    if scheme == "--dump":
        for key, values in sorted(stored_defuse_items().items()):
            print(f"{key}={' '.join(values)}")
        raise SystemExit(0)
    if scheme == "--self-check":
        found = self_check()
        for problem in found:
            print(problem)
        raise SystemExit(1 if found else 0)
    try:
        h, n = SCHEMES[scheme]()
    except (ConfigError, KeyError) as error:
        sys.stderr.write(f"scoring_hash: {error}\n")
        raise SystemExit(2)
    print(h, n)
