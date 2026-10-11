#!/usr/bin/env bash
#
# CI guard: the build-time FDA perimeter and the two runtime guards share one
# vocabulary, and none of the three may quietly grow past the others.
#
# Why this exists. There were three prohibited-term
# lists and nothing reconciled them:
#
#   * Tools/copy_linter/prohibited_terms.json  user_facing_prohibited: 21 patterns
#   * Tools/copy_linter/prohibited_terms.json  coach_response_prohibited: 5
#   * CoachVoiceGuard.rules (Swift):                                     12
#
# CoachVoiceGuard's own header said the quiet part out loud — "Keeping these in
# sync is a manual responsibility — there is no runtime cross-check." The
# practical consequence was that `atrial fibrillation`, `arrhythmia`,
# `diagnose`, `pathology`, `cure`, `prescription`, `medical-grade`,
# `clinical-grade`, `FDA-approved`, `FDA-cleared` and `high risk` were forbidden
# in STATIC copy and unhandled in MODEL OUTPUT. A build-time perimeter that a
# language model can walk straight through is not a perimeter.
#
# The vocabulary now lives in `Emuqu/Sources/Assistant/MedicalTermLexicon.swift`
# and both guards compose from it. This gate proves the lexicon still covers the
# build-time list: for every regex in `user_facing_prohibited` it synthesises a
# string that regex matches, and asserts some lexicon concept matches it too.
#
# It is a coverage proof, not a string comparison — the two sides are allowed to
# spell a concept differently, they are not allowed to disagree about whether it
# is covered.
#
# Exit 0 clean, 1 on a gap, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG="Tools/copy_linter/prohibited_terms.json"

# The whole lexicon FAMILY, not one file.
#
# 2026-09-02 — this was the single path
# `Emuqu/Sources/Assistant/MedicalTermLexicon.swift`. Splitting that file to
# stay under the 1000-line limit moved a concept into a `+MetricVerdict`
# sibling, and this gate immediately reported six build-time terms as
# unmatched — not because the runtime lost them (`MedicalTermLexicon.all`
# still lists the concept; an extension does not hide a `static let`) but
# because the gate stopped reading the file they now live in.
#
# A gate that fails when a file is split is annoying. A gate that PASSES when
# the vocabulary moves out from under it would be worse, and is the same
# shape: both come from naming one file in a repo that splits files to meet
# budgets. Globbing the family fixes both directions.
LEXICONS=(Emuqu/Sources/Assistant/MedicalTermLexicon*.swift)

if [[ ! -f "$CONFIG" ]]; then
    echo "check_perimeter_sync: missing $CONFIG" >&2
    exit 2
fi
if [[ ! -f "${LEXICONS[0]}" ]]; then
    echo "check_perimeter_sync: no MedicalTermLexicon*.swift found" >&2
    exit 2
fi

python3 - "$CONFIG" "${LEXICONS[@]}" <<'PY'
import json
import re
import sys

config_path, lexicon_paths = sys.argv[1], sys.argv[2:]

try:
    config = json.loads(open(config_path, encoding="utf-8").read())
except Exception as exc:
    sys.stderr.write(f"check_perimeter_sync: cannot parse {config_path}: {exc}\n")
    sys.exit(2)

source = "\n".join(open(p, encoding="utf-8").read() for p in lexicon_paths)

# Pull the alternatives out of the lexicon's `latin:` and `unbounded:` arrays
# ONLY. An earlier draft of this gate scraped every string literal in the file
# and was vacuously green: `joined(separator: "|")` contributed the literal "|",
# which compiles to a regex matching the empty string, so every probe "matched"
# something. The empty-match assertion below is there so that class of mistake
# fails loudly instead of passing quietly — a gate that cannot fail is the exact
# thing this audit was about.
#
# The Swift source escapes backslashes for the string literal (\\b, \\s), so
# unescape one level to recover the regex the compiled NSRegularExpression sees.
# Bracket matching, not a non-greedy regex. `medical[- ]grade` contains a
# character class, so `\[(.*?)\]` stopped at the FIRST `]` and silently
# truncated the array — dropping every term after the first one that used a
# character class. Walk the brackets instead, skipping string literals so a `]`
# inside a term never closes the array.
ARRAY_START = re.compile(r'\b(latin|unbounded):\s*\[')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def arrays(text):
    """Yield (kind, body) for each `latin: [...]` / `unbounded: [...]`."""
    for start in ARRAY_START.finditer(text):
        i = start.end()
        depth = 1
        while i < len(text) and depth:
            ch = text[i]
            if ch == '"':
                match = LITERAL.match(text, i)
                i = match.end() if match else i + 1
                continue
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
            i += 1
        yield start.group(1), text[start.end():i - 1]


alternatives = []
for kind, body in arrays(source):
    for raw in LITERAL.findall(body):
        if not raw:
            continue
        pattern = raw.replace("\\\\", "\\")
        # Match the runtime's own semantics: Latin alternatives are word-bounded,
        # CJK / Arabic ones are bare substrings (see the lexicon's header).
        if kind == "latin":
            pattern = r"\b(?:" + pattern + r")\b"
        try:
            compiled_alt = re.compile(pattern, re.IGNORECASE)
        except re.error as exc:
            sys.stderr.write(f"check_perimeter_sync: lexicon alternative {raw!r} does not compile: {exc}\n")
            sys.exit(2)
        if compiled_alt.search(""):
            sys.stderr.write(
                f"check_perimeter_sync: lexicon alternative {raw!r} matches the empty string, "
                "which would make this gate vacuously green. Fix the pattern.\n"
            )
            sys.exit(2)
        alternatives.append(compiled_alt)

if len(alternatives) < 100:
    sys.stderr.write(
        f"check_perimeter_sync: only {len(alternatives)} alternatives extracted from the lexicon. "
        "That is far below the expected vocabulary size — the parser is probably broken.\n"
    )
    sys.exit(2)


WORD = "word"


def probes_for(pattern_source, limit=5000):
    """Every spelling the build-time regex matches, one per alternative:
    each alternation branch, each optional part present and absent, each
    character-class member. `*` and `{m,n}` take their minimum, `+` one
    repetition; `\\w` stands for a placeholder word. Lookarounds, `\\b` and
    `(?i)` are dropped."""
    s = pattern_source.replace("(?i)", "")
    pos = 0

    def parse_alt():
        nonlocal pos
        branches = [parse_seq()]
        while pos < len(s) and s[pos] == "|":
            pos += 1
            branches.append(parse_seq())
        out = []
        for b in branches:
            out.extend(b)
        return out

    def parse_seq():
        nonlocal pos
        result = [""]
        while pos < len(s) and s[pos] not in "|)":
            atom = parse_atom()
            atom = apply_quantifier(atom)
            result = [a + b for a in result for b in atom]
            if len(result) > limit:
                raise ValueError(f"more than {limit} spellings")
        return result

    def parse_atom():
        nonlocal pos
        c = s[pos]
        if c == "(":
            pos += 1
            if s.startswith("?<!", pos) or s.startswith("?<=", pos) or s.startswith("?!", pos) or s.startswith("?=", pos):
                depth = 1
                while depth:
                    if s[pos] == "\\":
                        pos += 2
                        continue
                    if s[pos] == "(":
                        depth += 1
                    elif s[pos] == ")":
                        depth -= 1
                    pos += 1
                return [""]
            if s.startswith("?:", pos):
                pos += 2
            inner = parse_alt()
            if pos >= len(s) or s[pos] != ")":
                raise ValueError("unbalanced group")
            pos += 1
            return inner
        if c == "[":
            end = pos + 1
            while s[end] != "]":
                end += 2 if s[end] == "\\" else 1
            body = s[pos + 1:end]
            pos = end + 1
            out, i = [], 0
            while i < len(body):
                if body[i] == "\\":
                    out.append({"s": " ", "w": WORD}.get(body[i + 1], body[i + 1]))
                    i += 2
                else:
                    out.append(body[i])
                    i += 1
            return out
        if c == "\\":
            e = s[pos + 1]
            pos += 2
            if e == "b":
                return [""]
            if e == "s":
                return [" "]
            if e == "w":
                return [WORD]
            if e == "d":
                return ["1"]
            return [e]
        if c == ".":
            pos += 1
            return ["x"]
        pos += 1
        return [c]

    def apply_quantifier(atom):
        nonlocal pos
        if pos >= len(s):
            return atom
        q = s[pos]
        if q == "?":
            pos += 1
            return [""] + atom
        if q == "*":
            pos += 1
            return [""]
        if q == "+":
            pos += 1
            return atom
        if q == "{":
            end = s.index("}", pos)
            low = int(s[pos + 1:end].split(",")[0] or 0)
            pos = end + 1
            out = [""]
            for _ in range(low):
                out = [a + b for a in out for b in atom]
            return out
        return atom

    out = parse_alt()
    if pos != len(s):
        raise ValueError(f"stopped at {pos}")
    # `\s+` next to an optional part leaves doubled or edge spaces.
    return sorted({re.sub(r" {2,}", " ", p).strip() for p in out} - {""})


# Every spelling, not one per pattern. Reducing `(a|b)` to `a` checked one
# spelling per rule, and `undiagnosed`, `curing`, `curative`, `pathological`
# and `ischaemic` went unmatched while this gate printed clean.
missing = []
checked = 0
for item in config.get("user_facing_prohibited", []):
    pattern_source = item["pattern"]
    try:
        probes = probes_for(pattern_source)
    except (ValueError, IndexError) as exc:
        sys.stderr.write(f"check_perimeter_sync: cannot expand {pattern_source!r}: {exc}. "
                         "Widen probes_for rather than skipping the rule.\n")
        sys.exit(2)
    if not probes:
        sys.stderr.write(f"check_perimeter_sync: no spelling synthesised for {pattern_source!r}.\n")
        sys.exit(2)
    for probe in probes:
        # Sanity: the probe must match the rule it came from, otherwise the
        # synthesiser is wrong and this gate would pass vacuously.
        try:
            if not re.search(pattern_source, probe, re.IGNORECASE):
                sys.stderr.write(
                    f"check_perimeter_sync: could not synthesise a probe for {pattern_source!r} "
                    f"(got {probe!r}). Widen probes_for rather than skipping the rule.\n"
                )
                sys.exit(2)
        except re.error as exc:
            sys.stderr.write(f"check_perimeter_sync: bad pattern {pattern_source!r}: {exc}\n")
            sys.exit(2)
        checked += 1
        if not any(rx.search(probe) for rx in alternatives):
            missing.append((pattern_source, probe, item.get("reason", "")))

print(f"check_perimeter_sync: {checked} build-time spellings probed against "
      f"{len(alternatives)} lexicon alternatives.")

if missing:
    print(f"check_perimeter_sync: {len(missing)} build-time term(s) the RUNTIME "
          f"guards cannot match.\n", file=sys.stderr)
    for pattern_source, probe, reason in missing:
        print(f"  pattern: {pattern_source}", file=sys.stderr)
        print(f"  example: {probe!r}", file=sys.stderr)
        print(f"  reason:  {reason}\n", file=sys.stderr)
    print("The build-time linter forbids these in static copy while the model is "
          "free to say them.\nAdd them to MedicalTermLexicon (with the shipped-locale "
          "translations) and give the\nconcept a deflection in CoachVoiceGuard.",
          file=sys.stderr)
    sys.exit(1)

print("check_perimeter_sync: clean. Every build-time prohibited term is also "
      "matched by the runtime lexicon.")
sys.exit(0)
PY
