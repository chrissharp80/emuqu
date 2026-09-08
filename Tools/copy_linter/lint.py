#!/usr/bin/env python3
"""
Emuqu FDA copy-perimeter linter.

Reads Tools/copy_linter/prohibited_terms.json and scans all configured paths
for prohibited user-facing strings. Exit 1 on any match. Wired into CI via
the `copy-perimeter` Make target.

Scope:
  • Swift String literals in scan_paths — every form, including multi-line
    and raw literals (see `iter_swift_strings`)
  • Localizable.xcstrings string values
  • Skips files under allowlist_paths (e.g. methodology page, voice guard)
  • Skips comments — best-effort: removes // line comments and /* ... */
    block comments before scanning Swift files

Usage:
  python3 Tools/copy_linter/lint.py [--root /path/to/repo]

Exit codes:
  0 — no violations
  1 — at least one violation
  2 — config error (missing JSON, regex compile failure)

This is the build-time enforcement of the FDA perimeter (build plan D10, §7).
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass
class Violation:
    path: Path
    line: int
    snippet: str
    pattern: str
    reason: str


def load_config(config_path: Path) -> dict:
    try:
        return json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.stderr.write(f"copy_linter: config not found at {config_path}\n")
        sys.exit(2)
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"copy_linter: config JSON error: {exc}\n")
        sys.exit(2)


def is_allowlisted(path: Path, allowlist: list[str], repo_root: Path) -> bool:
    """Prefix match, deliberately.

    A full-path entry such as `AIProvider+SystemPrompt.swift` is on a timer:
    this repo splits files to meet length budgets as a matter of routine, and
    the split moves the prompt text into a sibling like
    `AIProvider+SystemPromptText.swift` where the exemption silently stops
    applying. Nothing flags that, and the sibling's multi-line literals may not
    even be read until the string extractor is repaired — at which point they
    surface as violations. This is the exact failure `is_prohibition_context`
    warns about, and keying one level up — the family prefix
    `…/AIProvider+SystemPrompt` — is what defuses it, so the next split is
    covered on the day it happens. The content-keyed guard stays as the general
    mechanism; this covers the one file whose entire contents are instructions
    to a model rather than copy a user reads.
    """
    rel = path.relative_to(repo_root).as_posix()
    return any(rel.startswith(prefix) for prefix in allowlist)


def strip_swift_comments(source: str) -> str:
    """Strip // line and /* */ block comments. Preserves line numbers by
    replacing comment chars with spaces, so violation line numbers remain
    accurate.
    """
    # Block comments — non-greedy
    def _block(match: re.Match[str]) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    source = re.sub(r"/\*.*?\*/", _block, source, flags=re.DOTALL)
    # Line comments — preserve newline
    source = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), source)
    return source


def iter_swift_strings(source: str) -> Iterable[tuple[int, str]]:
    """Yield (line_number, string_content) for every string literal in `source`.

    This is a scanner, not a regex, because a single quote-pairing regex
    such as

        SWIFT_STRING_RE = re.compile(r'"((?:\\.|[^"\\])*)"')

    applied to the whole file with `finditer` does not parse Swift. A flat
    quote-pairing pass cannot survive `\"\"\"`: three quote characters read as
    one empty string plus the start of another, and the escaped quotes that
    appear inside prose blocks shift the pairing again. The scanner ends up an
    odd number of quotes out of phase, and what it extracts from that point is
    the CODE BETWEEN the literals instead of the prose inside them — in
    `HelpContent+ScienceArticles.swift` the "string" such a regex finds at
    line 217 is `'),\\n   .warning('`. Measured, that leaves 143,581 of the
    155,018 characters inside multi-line literals — 93%, across 31 files —
    never handed to the pattern matcher, including every one of the app's
    long-form help and science articles. A prohibited claim pasted into shipped
    help copy then produces "copy_linter: clean. FDA perimeter holds."

    So this walks the source once and understands the four things that break
    the regex: line comments, nestable block comments, `\"\"\"` blocks, and raw
    literals (`#"…"#`, `##\"\"\"…\"\"\"##`), whose escape rules differ. Comments
    are handled HERE rather than by a pre-pass, because blanking `//` before
    scanning also mangles the `https://` inside a string literal.
    """
    newlines = [i for i, ch in enumerate(source) if ch == "\n"]

    def line_of(offset: int) -> int:
        return bisect.bisect_right(newlines, offset - 1) + 1

    index, length = 0, len(source)
    while index < length:
        char = source[index]

        if char == "/" and source.startswith("//", index):
            end = source.find("\n", index)
            index = length if end < 0 else end
            continue

        if char == "/" and source.startswith("/*", index):
            depth, cursor = 1, index + 2
            while cursor < length and depth:
                if source.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif source.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            index = cursor
            continue

        hashes = ""
        if char == "#":
            cursor = index
            while cursor < length and source[cursor] == "#":
                cursor += 1
            if cursor >= length or source[cursor] != '"':
                index = cursor
                continue
            hashes = source[index:cursor]
            index = cursor
            char = '"'

        if char == '"':
            if source.startswith('"""', index):
                closing = '"""' + hashes
                end = source.find(closing, index + 3)
                body = source[index + 3:end if end >= 0 else length]
                yield line_of(index), body
                index = end + len(closing) if end >= 0 else length
                continue

            closing = '"' + hashes
            cursor, buffer = index + 1, []
            while cursor < length and source[cursor] != "\n":
                # A raw literal has no backslash escapes; `\"` ends nothing.
                if not hashes and source[cursor] == "\\" and cursor + 1 < length:
                    buffer.append(source[cursor:cursor + 2])
                    cursor += 2
                    continue
                if source.startswith(closing, cursor):
                    break
                buffer.append(source[cursor])
                cursor += 1
            yield line_of(index), "".join(buffer)
            index = cursor + len(closing) if source.startswith(closing, cursor) else cursor
            continue

        index += 1


INTERPOLATION_RE = re.compile(r"\\\([^)]*\)")


def strip_interpolations(text: str) -> str:
    """Blank out `\\(expr)` spans before matching.

    The interpolated expression is a Swift identifier, not text a
    user ever reads. `MorningNotificationScheduler` builds
    `"Recovery \\(scoreInt) · \\(prescription)"`, where `prescription` is a local
    variable holding an already-vetted verdict phrase — the rendered string
    never contains the word. Matching on it is a false positive, and false
    positives are what get a perimeter widened once and then narrowed back.
    """
    return INTERPOLATION_RE.sub(" ", text)


def is_prohibition_context(
    raw_lines: list[str],
    line: int,
    guards: list[re.Pattern[str]],
    snippet: str = "",
) -> bool:
    """True when the match sits inside a sentence that FORBIDS the phrase.

    The system prompt instructs the model never to use certain
    framings, and quotes those framings in order to name them:

        13. Never tell the user that a number "predicts injury," indicates
           "danger," or sits in an "advisory zone."

    Firing on all three is exactly backwards: that sentence is the perimeter,
    written in prose and shipped to the model.

    An `allowlist_paths` entry on the file that holds the prompt is not a fix.
    This repo splits files to meet length budgets as a matter of routine, a
    split moves the text into a sibling file, and the exemption silently stops
    applying — any path-keyed exemption is on a timer. This keys on the
    CONTENT of the sentence instead, so it survives renames, splits, and
    moves, and it stays narrow: only a phrase introduced by an
    explicit prohibition is excused, and only in Swift source. Catalogue
    entries are pure user copy and are never excused this way.
    """
    # `raw_lines` MUST be the comment-stripped source. A three-line window
    # over the raw lines is a skeleton key: any COMMENT matching
    # `never (tell|say|use|...)` within two lines above a string excuses that
    # string from all twenty-one patterns, so
    #
    #     // never tell the user this
    #     let x = "Your injury risk is high tonight."
    #
    # is a clean run — a one-line comment anyone could write, deliberately or
    # by accident, disabling the whole perimeter for the code below it.
    #
    # The real case this exists for is prompt COPY, not a comment: the system
    # prompt quotes forbidden framings in order to forbid them, and that text
    # ships to the model inside a string literal. So the guard searches the
    # COMMENT-STRIPPED source. A prohibition that survives comment-stripping is
    # prompt text; one that does not is a comment, and a comment cannot excuse
    # anything. The phrase must also sit inside the prohibiting sentence.
    lo = max(0, line - 1 - 2)
    hi = min(len(raw_lines), line + 1)
    window = " ".join(raw_lines[lo:hi])
    for guard in guards:
        match = guard.search(window)
        if match is None:
            continue
        sentence = _sentence_around(window, match.start())
        if _snippet_in_sentence(snippet, sentence):
            return True
    return False


def _snippet_in_sentence(snippet: str, sentence: str) -> bool:
    """Is the offending phrase inside the prohibiting sentence?

    Compared on a leading fragment with trailing punctuation stripped: the
    sentence boundary that ends the prohibition is usually the same period that
    ends the quoted phrase, so an exact containment test on the raw snippet
    fails on precisely the case this is meant to allow —
    `... or sits in an "advisory zone."`.
    """
    fragment = snippet.strip().rstrip(".,;:!?\"'\u201d\u2019").strip()
    if len(fragment) < 3:
        return False
    return fragment[:40] in sentence


_SENTENCE_END = re.compile(r"[.!?\n]")


def _sentence_around(text: str, index: int) -> str:
    """The sentence containing `index`."""
    start = 0
    for match in _SENTENCE_END.finditer(text[:index]):
        start = match.end()
    end_match = _SENTENCE_END.search(text, index)
    end = end_match.start() if end_match else len(text)
    return text[start:end]


def scan_swift_file(
    path: Path,
    patterns: list[tuple[re.Pattern[str], str]],
    allowlist_strings: set[str],
    negation_guards: list[re.Pattern[str]],
) -> list[Violation]:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:  # pragma: no cover
        sys.stderr.write(f"copy_linter: cannot read {path}: {exc}\n")
        # Fail closed: a file this gate could not read is not a clean file.
        raise SystemExit(2)
    stripped = strip_swift_comments(text)
    # Deliberately the STRIPPED lines: see is_prohibition_context.
    raw_lines = stripped.splitlines()
    violations: list[Violation] = []
    # The scanner skips comments itself, so it reads the ORIGINAL source. The
    # comment-stripped copy above is still what `is_prohibition_context` looks
    # at, which is the whole point of that function.
    for line, content in iter_swift_strings(text):
        content = strip_interpolations(content)
        if content.strip() in allowlist_strings:
            continue
        if is_prohibition_context(raw_lines, line, negation_guards, snippet=content):
            continue
        for pattern, reason in patterns:
            match = pattern.search(content)
            if match is None:
                continue
            # The prohibition check above compares the string's
            # FIRST 40 characters against a sentence two lines either side of
            # where the literal opens. That works for a one-line string and
            # cannot work for a `"""` block, where the prohibition and the
            # phrase it forbids are both inside the body, hundreds of
            # characters down. So also excuse a phrase whose own sentence,
            # within the literal, forbids it.
            if _forbidden_in_place(content, match.start(), negation_guards):
                continue
            violations.append(
                Violation(
                    path=path,
                    line=line + content.count("\n", 0, match.start()),
                    snippet=_snippet_around(content, match.start()),
                    pattern=pattern.pattern,
                    reason=reason,
                )
            )
    return violations


def _forbidden_in_place(
    content: str, offset: int, guards: list[re.Pattern[str]]
) -> bool:
    """True when the sentence CONTAINING the match forbids the phrase.

    Narrower than `is_prohibition_context`: the prohibition has to be in the
    same sentence as the phrase, inside the same string literal. It exists for
    the system prompt, which quotes the framings it bans in order to ban them.
    """
    sentence = _sentence_around(content, offset)
    return any(guard.search(sentence) for guard in guards)


def _snippet_around(content: str, offset: int, width: int = 120) -> str:
    """The reported excerpt. A multi-line literal can run to thousands of
    characters, and the first 120 of them usually do not contain the match."""
    start = max(0, offset - width // 3)
    return re.sub(r"\s+", " ", content[start:start + width]).strip()


def scan_xcstrings(
    path: Path,
    patterns: list[tuple[re.Pattern[str], str]],
    allowlist_strings: set[str],
) -> list[Violation]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        sys.stderr.write(f"copy_linter: cannot parse {path}: {exc}\n")
        # Fail closed: an unreadable catalogue means the copy was not linted.
        raise SystemExit(2)
    violations: list[Violation] = []
    strings = data.get("strings", {})
    for key, entry in strings.items():
        # An allowlisted KEY allowlists its translations too.
        #
        # Testing each localization independently makes the wellness
        # disclaimer — allowlisted in English precisely because it MUST say
        # "not medical advice, diagnosis, or treatment" — fire once per
        # locale, 16 times, for saying the approved thing in German. A
        # translation expresses the same approved concept as its source; if
        # the concept is cleared, the translation is cleared. Without this the
        # only way to a clean run is 16 near-duplicate allowlist entries per
        # disclaimer, which nobody maintains and which silently rot when a
        # translator rewords.
        key_allowlisted = key.strip() in allowlist_strings
        # Source key itself
        if not key_allowlisted:
            for pattern, reason in patterns:
                if pattern.search(key):
                    violations.append(
                        Violation(path=path, line=0, snippet=key[:120], pattern=pattern.pattern, reason=reason)
                    )
        # Localizations
        for _, loc in entry.get("localizations", {}).items():
            unit = loc.get("stringUnit") or {}
            value = unit.get("value")
            if not isinstance(value, str):
                continue
            if key_allowlisted or value.strip() in allowlist_strings:
                continue
            for pattern, reason in patterns:
                if pattern.search(value):
                    violations.append(
                        Violation(path=path, line=0, snippet=value[:120], pattern=pattern.pattern, reason=reason)
                    )
    return violations


class MissingScanPath(Exception):
    """A configured scan_path does not exist on disk."""


LEXICON_PATH = "Emuqu/Sources/Assistant/MedicalTermLexicon.swift"


def translated_claim_patterns(repo_root: Path) -> list[tuple[re.Pattern[str], str]]:
    """The multilingual patterns for `MedicalTermLexicon.neverInStaticCopy`.

    Every pattern in `prohibited_terms.json` is English, and the app ships
    59,650 translated string units. Without these, a prohibited claim injected
    into a German catalogue value passes this linter clean while the English
    original is caught. `check_perimeter_sync.sh` proves build-time terms are
    covered by the runtime lexicon, and nothing proves the reverse, so the
    asymmetry is invisible to CI by construction.

    These are read from the lexicon rather than copied into the JSON so there is
    one place to add a language. Only the concepts the lexicon marks as never
    legitimate static copy are used — see the note on `neverInStaticCopy` for
    why running the whole lexicon over the catalogue does not work.
    """
    source = (repo_root / LEXICON_PATH).read_text(encoding="utf-8")
    group = re.search(
        r"static let neverInStaticCopy: \[Concept\] = \[(.*?)\]", source, re.DOTALL
    )
    if group is None:
        raise MissingScanPath(f"{LEXICON_PATH}: neverInStaticCopy not found")
    names = re.findall(r"\b([a-z]\w+)\b", re.sub(r"//[^\n]*", "", group.group(1)))

    patterns: list[tuple[re.Pattern[str], str]] = []
    for name in names:
        concept = re.search(
            r'static let %s = Concept\(\s*\n\s*id: "([^"]+)",(.*?)\n    \)\n' % re.escape(name),
            source,
            re.DOTALL,
        )
        if concept is None:
            continue

        def alternatives(tag: str) -> list[str]:
            # Both spellings occur: the array on one line, and the array spread
            # over many with the closing bracket on its own. A pattern that only
            # handles the multi-line form silently drops every CJK and Arabic
            # alternative, because those are written inline — a Japanese claim
            # probe sails through while the German one is caught.
            start = concept.group(2).find(tag + ": [")
            if start < 0:
                return []
            cursor = concept.group(2).index("[", start)
            depth, end = 0, cursor
            while end < len(concept.group(2)):
                char = concept.group(2)[end]
                if char == "[":
                    depth += 1
                elif char == "]":
                    depth -= 1
                    if depth == 0:
                        break
                end += 1
            body = re.sub(r"//[^\n]*", "", concept.group(2)[cursor:end])
            return [item.replace("\\\\", "\\") for item in re.findall(r'"((?:[^"\\]|\\.)*)"', body)]

        latin, unbounded = alternatives("latin"), alternatives("unbounded")
        branches = []
        if latin:
            branches.append(r"\b(?:" + "|".join(latin) + r")\b")
        if unbounded:
            branches.append("(?:" + "|".join(unbounded) + ")")
        if not branches:
            continue
        try:
            compiled = re.compile("(?:" + "|".join(branches) + ")", re.IGNORECASE)
        except re.error:
            continue
        patterns.append((compiled, f"Regulated claim ({concept.group(1)}) in a translated string."))
    if not patterns:
        raise MissingScanPath(f"{LEXICON_PATH}: no usable concepts in neverInStaticCopy")
    return patterns


def collect_targets(repo_root: Path, scan_paths: list[str]) -> list[Path]:
    out: list[Path] = []
    for entry in scan_paths:
        target = repo_root / entry
        if not target.exists():
            # Fail loudly, never `continue`: a silent skip means a typo, or a
            # directory rename, disables a whole branch of the perimeter with
            # no signal — the linter still prints "clean".
            raise MissingScanPath(entry)
        if target.is_file():
            out.append(target)
            continue
        out.extend(target.rglob("*.swift"))
        # Also collect string catalogs. No scan_path names a catalog file, so
        # without this `scan_xcstrings` is unreachable dead code and 3,734 keys
        # x 17 locales — every user-facing string that lives ONLY in the
        # catalog — go unreviewed.
        out.extend(target.rglob("*.xcstrings"))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Emuqu FDA copy-perimeter linter")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent.parent),
                        help="Repository root (default: auto-detect)")
    parser.add_argument("--config", default=None, help="Override config path")
    args = parser.parse_args()

    repo_root = Path(args.root).resolve()
    config_path = Path(args.config) if args.config else (repo_root / "Tools/copy_linter/prohibited_terms.json")
    config = load_config(config_path)

    raw_patterns = config.get("user_facing_prohibited", [])
    try:
        patterns = [(re.compile(item["pattern"]), item.get("reason", "")) for item in raw_patterns]
    except re.error as exc:
        sys.stderr.write(f"copy_linter: regex compile failed: {exc}\n")
        return 2

    try:
        translated_patterns = translated_claim_patterns(repo_root)
    except MissingScanPath as exc:
        sys.stderr.write(f"copy_linter: {exc}\n")
        return 2

    allowlist = config.get("allowlist_paths", [])
    allowlist_strings = {s.strip() for s in config.get("allowlist_strings", [])}
    try:
        negation_guards = [re.compile(p) for p in config.get("negation_guards", [])]
    except re.error as exc:
        sys.stderr.write(f"copy_linter: negation_guard regex compile failed: {exc}\n")
        return 2
    try:
        targets = collect_targets(repo_root, config.get("scan_paths", []))
    except MissingScanPath as missing:
        sys.stderr.write(
            f"copy_linter: scan_path does not exist: {missing}\n"
            "copy_linter: fix the path in prohibited_terms.json, or remove the entry.\n"
            "copy_linter: (silently skipping it would disable part of the FDA\n"
            "copy_linter:  perimeter while still reporting 'clean'.)\n"
        )
        return 2

    violations: list[Violation] = []
    for path in targets:
        if is_allowlisted(path, allowlist, repo_root):
            continue
        if path.suffix == ".swift":
            violations.extend(scan_swift_file(path, patterns, allowlist_strings, negation_guards))
        elif path.name == "Localizable.xcstrings" or path.suffix == ".xcstrings":
            violations.extend(scan_xcstrings(path, patterns, allowlist_strings))
            # …and the same catalogue again, with the multilingual claim
            # patterns, which apply to EVERY locale rather than English alone.
            violations.extend(scan_xcstrings(path, translated_patterns, allowlist_strings))

    if not violations:
        print("copy_linter: clean. FDA perimeter holds.")
        return 0

    print(f"copy_linter: {len(violations)} violation(s) found.\n", file=sys.stderr)
    for v in violations:
        rel = v.path.relative_to(repo_root)
        loc = f"{rel}:{v.line}" if v.line else f"{rel}"
        print(f"  {loc}", file=sys.stderr)
        print(f"    pattern: {v.pattern}", file=sys.stderr)
        print(f"    reason:  {v.reason}", file=sys.stderr)
        print(f"    string:  {v.snippet!r}", file=sys.stderr)
        print("", file=sys.stderr)
    print(
        "copy_linter: see Tools/copy_linter/prohibited_terms.json for the full list.\n"
        "copy_linter: rephrase using observation/range language (build plan §6 voice rules).",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
