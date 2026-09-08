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


def probe_for(pattern_source):
    """A concrete string the build-time regex matches.

    Handles the small regex dialect the prohibited list actually uses:
    inline (?i), \\b, \\s+, optional groups, alternations and a lookbehind.
    """
    s = pattern_source
    s = s.replace("(?i)", "")
    s = re.sub(r"\(\?<![^)]*\)", "", s)          # drop lookbehinds
    s = re.sub(r"\(\?![^)]*\)", "", s)           # drop lookaheads
    s = s.replace("(?:", "(")                     # non-capturing -> capturing
    s = s.replace("\\s+", " ").replace("\\s*", "").replace("\\b", "")

    # 2026-08-26 — WAS `\[([^\]])[^\]]*\]` -> first character. That takes the
    # backslash out of `[\s-]` and produced `danger\+zone`, which matches
    # nothing. The gate caught its own synthesiser, which is the behaviour to
    # keep: it exits 2 and says "widen probe_for rather than skipping the rule".
    def _class_char(match):
        body = match.group(1)
        if body.startswith("\\s"):
            return " "
        return body[1] if body.startswith("\\") else body[0]

    s = re.sub(r"\[((?:\\.|[^\]])+)\]", _class_char, s)
    s = re.sub(r"(?<=[^\\])[+*]", "", s)          # quantifier left by the above
    # (a|b) -> a ; (a|b)? -> ""  (prefer the shortest match-preserving form)
    while True:
        new = re.sub(r"\(([^()|]*)\|([^()]*)\)\?", "", s)
        new = re.sub(r"\(([^()|]*)\|[^()]*\)", r"\1", new)
        new = re.sub(r"\(([^()|]*)\)\?", "", new)
        new = re.sub(r"\(([^()|]*)\)", r"\1", new)
        if new == s:
            break
        s = new
    return s.replace("?", "").strip()


missing = []
checked = 0
for item in config.get("user_facing_prohibited", []):
    pattern_source = item["pattern"]
    probe = probe_for(pattern_source)
    if not probe:
        continue
    # Sanity: the probe must actually match the rule it came from, otherwise the
    # synthesiser is wrong and this gate would pass vacuously.
    try:
        if not re.search(pattern_source, probe, re.IGNORECASE):
            sys.stderr.write(
                f"check_perimeter_sync: could not synthesise a probe for {pattern_source!r} "
                f"(got {probe!r}). Widen probe_for rather than skipping the rule.\n"
            )
            sys.exit(2)
    except re.error as exc:
        sys.stderr.write(f"check_perimeter_sync: bad pattern {pattern_source!r}: {exc}\n")
        sys.exit(2)

    checked += 1
    if not any(rx.search(probe) for rx in alternatives):
        missing.append((pattern_source, probe, item.get("reason", "")))

print(f"check_perimeter_sync: {checked} build-time patterns probed against "
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
