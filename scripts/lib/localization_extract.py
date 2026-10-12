"""The localized-literal extractor shared by the localization gates.

`check_localization_resolution.sh` (code -> catalogue) and
`check_localization_orphans.sh` (catalogue -> code) must agree on what a
localized literal is and what key it looks up. When each carried its own copy
they drifted: multi-line literals and `NSLocalizedString(` were read only by
the orphan gate, so the resolution gate read every `String(localized: \"\"\"...\"\"\")`
as an empty literal and never checked it. One extractor, imported by both.

The gates import this with `sys.dont_write_bytecode = True` and `scripts/lib` on
`sys.path`, after `cd`-ing to the repository root.

It does not re-implement Xcode's extractor. It normalises the two transforms
that matter - interpolations become format specifiers, literal `%` doubles - and
accepts either form where the developer authored a format template by hand.
Unrecognised specifier spellings (`%lld`, `%1$@`, `%.1f`) are matched
permissively (`SPECIFIER`) rather than reported, because a false positive costs
more than a missed edge case: a gate has to stay believable to be worth having.
"""

import re

INTERP = "\x00INTERP\x00"
QUOTE = chr(34)
SPECIFIER = r"%(?:\d+\$)?(?:@|lld|ld|d|u|\.\d+f|f|s)"


def scan_multiline_literal(text, i):
    """text[i:i+3] is an opening triple quote. Swift's rules: the body starts
    after the newline that follows the delimiter, the closing delimiter's
    indentation is removed from every line, and a backslash at a line's end
    joins it to the next. Read as one-line literals, these all came out as ""."""
    end = text.find('"""', i + 3)
    if end < 0:
        return "", len(text)
    raw = text[i + 3:end]
    raw = raw[raw.find("\n") + 1:] if "\n" in raw else raw
    lines = raw.split("\n")
    indent = lines[-1] if lines[-1].strip() == "" else ""
    lines = lines[:-1] if lines[-1].strip() == "" else lines
    body = "\n".join(l[len(indent):] if l.startswith(indent) else l for l in lines)
    body = re.sub(r"\\\n", "", body)
    inner, _ = scan_literal('"' + body.replace('"', '\\"') + '"', 0)
    return inner, end + 3


def scan_literal(text, i):
    """text[i] is the opening quote. Return (body, index_after_closing_quote).

    Swift string interpolation nests arbitrarily - `"a \\(f(x, "b")) c"` is one
    literal containing another. A flat regex stops at the inner quote and
    reports the truncated fragment as a missing key. Walking the literal with a
    paren counter is the only way to get this right. Interpolations come back
    as INTERP.
    """
    if text.startswith('"""', i):
        return scan_multiline_literal(text, i)
    i += 1
    out = []
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            if i + 1 < len(text) and text[i + 1] == "(":
                j, depth = i + 2, 1
                while j < len(text) and depth:
                    if text[j] == '"':
                        _, j = scan_literal(text, j)
                        continue
                    if text[j] == "(":
                        depth += 1
                    elif text[j] == ")":
                        depth -= 1
                    j += 1
                out.append(INTERP)
                i = j
                continue
            out.append(text[i:i + 2])
            i += 2
            continue
        if ch == '"':
            return "".join(out), i + 1
        out.append(ch)
        i += 1
    return "".join(out), i


UNICODE_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]+)\}")


def unescape(s):
    s = UNICODE_ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), s)
    return (s.replace('\\"', '"')
             .replace("\\n", "\n")
             .replace("\\t", "\t")
             .replace("\\'", "'")
             .replace("\\\\", "\\"))


def candidate_keys(raw):
    """Both plausible extractions of one literal.

    Xcode doubles a literal `%` when it writes the key, because the key doubles
    as a format string. But a developer who hand-authored `"%.1f min"` as a
    template meant that percent literally. Accept either rather than guess.
    """
    body = unescape(raw)
    return {
        body.replace("%", "%%").replace(INTERP, "%@"),
        body.replace(INTERP, "%@"),
    }


def key_pattern(candidate):
    """A regex matching catalogue keys `candidate` resolves to, any specifier spelling."""
    return re.compile("^" + re.escape(candidate).replace(re.escape("%@"), SPECIFIER) + "$", re.S)


def skip_literal_at(text, start):
    """Whether the literal beginning at `start` is NOT a LocalizedStringKey.

    Two shapes, both genuinely untranslatable rather than merely untranslated:

      * A subscript key. In Text(payload[k] as? String ?? fallback) the k is a
        dictionary lookup, not copy.
      * The right-hand side of a nil-coalescing operator. Text(optional ?? lit)
        resolves to the Text(String) overload, which does NOT localize, so the
        literal has no catalogue key by construction and never gets one.

    Both are recognised by what precedes the opening quote, because no regex
    can do Swift type inference.
    """
    j = start - 1
    while j >= 0 and text[j] in " \t\n":
        j -= 1
    if j < 0:
        return False
    if text[j] == "[":
        return True
    return j >= 1 and text[j] == "?" and text[j - 1] == "?"


def first_argument_literals(text, i):
    """String literals in the FIRST argument of a call, paren already consumed.

    An extractor that only looks at a literal sitting IMMEDIATELY after the
    paren gets nothing from a call whose first argument is an EXPRESSION:
    Text(min < 60 ? a : b), a Swift Charts `.value(label, x)`.

    Two deliberate limits, because widening this the wrong way marks keys as
    requested that nothing actually localizes, which HIDES real orphans:

      * First argument only - stop at the first top-level comma. That is where
        the LocalizedStringKey goes. Label(title, systemImage: symbol) must
        contribute the title and never the SF Symbol name.
      * Depth 1 only. A literal nested inside another call within that
        argument belongs to that call, not to this one.
    """
    depth, out = 1, []
    while i < len(text) and depth:
        ch = text[i]
        if ch == QUOTE:
            start = i
            body, i = scan_literal(text, i)
            if depth == 1 and not skip_literal_at(text, start):
                out.append(body)
            continue
        if ch == "," and depth == 1:
            break
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        i += 1
    return out


# Every form that takes a LocalizedStringKey is a catalogue lookup, not only
# `String(localized:)`: SwiftUI's `Text("...")`, `Button`, `Section`,
# `.navigationTitle`, `.alert`, `.accessibilityLabel`, `Toggle`, `TextField`,
# `Picker`, `Label`, Swift Charts' `.value`, and Foundation's
# `NSLocalizedString(`.
SWIFTUI_IMPLICIT = ("Text", "Button", "Label", "Toggle", "TextField", "Picker", "Section")
SWIFTUI_MODIFIERS = ("navigationTitle", "navigationBarTitle", "alert",
                     "confirmationDialog", "accessibilityLabel", "accessibilityHint",
                     "value")
CALL = re.compile(
    r"String\(\s*localized:\s*"
    r"|AttributedString\(\s*localized:\s*"
    r"|LocalizedStringKey\(\s*"
    r"|NSLocalizedString\(\s*"
    r"|\b(?:" + "|".join(SWIFTUI_IMPLICIT) + r")\(\s*"
    r"|\.(?:" + "|".join(SWIFTUI_MODIFIERS) + r")\(\s*"
)


def localized_literals(text):
    """Yield (line, body) for every literal `text` looks up in the catalogue."""
    for match in CALL.finditer(text):
        i = match.end()
        # Text(verbatim:) is the explicit opt OUT of localization; it has no
        # catalogue key, and is neither a request nor something to resolve.
        if text.startswith("verbatim:", i):
            continue
        if i < len(text) and text[i] == QUOTE:
            bodies = [scan_literal(text, i)[0]]
        else:
            bodies = first_argument_literals(text, i)
        line = text.count("\n", 0, i) + 1
        for body in bodies:
            yield line, body
