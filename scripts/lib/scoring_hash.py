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

CURRENT_SCHEME = "decl-flow"

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

    def __init__(self):
        self.stack = []
        self.pending = None
        self.items = {}

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
            self._declare(tokens, i, tok)
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
            if tok == "=" and self.pending and self.pending[0] == "func" and not self._in_function():
                self.pending = None
            self._record(_normalize_number(tok) if NUMBER_RE.match(tok) else tok)
        return self.items


def _token_index():
    """{file: TokenWalker items} for every Swift file under the app sources."""
    index = {}
    for path in sorted(pathlib.Path(TOKEN_SOURCE_ROOT).rglob("*.swift")):
        index[str(path)] = TokenWalker().walk(path.read_text(encoding="utf-8"))
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


def decl_tokens_items(sources=None, globs=None, token_roots=None):
    """{key: [token, ...]}: the scoring files whole, the roots, and every
    declaration they reach by name, each key once."""
    index = _token_index()
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


SCHEMES = {
    "static-lets": static_lets_hash, "decl-literals": decl_literals_hash,
    "decl-tokens": decl_tokens_hash, CURRENT_SCHEME: decl_flow_hash,
}


def scheme_of(fields):
    """The scheme a baseline line was hashed under."""
    return fields[2] if len(fields) == 3 else "static-lets"


if __name__ == "__main__":
    scheme = sys.argv[1] if len(sys.argv) > 1 else CURRENT_SCHEME
    if scheme == "--dump":
        for key, values in sorted(decl_flow_items().items()):
            print(f"{key}={' '.join(values)}")
        raise SystemExit(0)
    try:
        h, n = SCHEMES[scheme]()
    except (ConfigError, KeyError) as error:
        sys.stderr.write(f"scoring_hash: {error}\n")
        raise SystemExit(2)
    print(h, n)
