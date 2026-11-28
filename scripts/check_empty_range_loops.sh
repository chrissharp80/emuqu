#!/usr/bin/env bash
# `for i in 1 ..< xs.count` traps when `xs` is empty: `1 ..< 0` is an invalid
# range, not an empty one. The same block usually also calls
# `reserveCapacity(xs.count - 1)`, which traps on -1.
#
# The same trap wears a second face: `for i in 0 ..< (xs.count - 2)`. It reads
# as "stop two short", but on a collection of 0 or 1 it is `0 ..< -1` or
# `0 ..< -2`: invalid, not empty, and it crashes exactly the same way. This
# gate covers both shapes.
#
# Why this exists. A loop that is safe only because every caller happens to
# guard loses that safety when a new caller appears.
#
# A guard in the enclosing function satisfies this gate only when it is strong
# enough: `0 ..< (xs.count - N)` needs `xs.count >= N` (or `> N-1`,
# `if xs.count < N { return }`); `1 ..< xs.count` needs a non-empty guard. The
# point is that the guard exists NEXT TO the loop, not somewhere up the call
# graph.
set -euo pipefail

# The scan roots are relative; from any other directory they hold no files and
# the gate would report clean having read nothing.
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib, re, sys

# Two shapes, one trap:
#   for i in 1 ..< xs.count           -> traps when xs is empty
#   for i in 0 ..< (xs.count - N)     -> traps when xs.count < N
# The range is the trap, wherever it is formed: a `for` loop, a mapped
# `(1 ..< xs.count).map`, or a slice `xs[1 ..< xs.count]`. A closed range
# `0 ... xs.count - N` traps for the same counts as `0 ..< xs.count - N` does.
RANGE_START = r'(?:for\s+\w+\s+in\s+|[(\[]\s*)'
PATTERNS = [
    re.compile(RANGE_START + r'1\s*\.\.<\s*([\w.]+)\.count\b(?!\s*-)'),
    re.compile(RANGE_START + r'0\s*(?:\.\.<|\.\.\.)\s*\(?\s*([\w.]+)\.count\s*-\s*(\d+)'),
]
# The enclosing unit's first line: a func, init, deinit or subscript.
UNIT_START = re.compile(
    r'\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|'
    r'mutating|final|class|override|convenience|required)\s+)*'
    r'(?:func\s|init[?!]?\s*[(<]|deinit\b|subscript\s*[(<])')


def required_count(m):
    """The smallest count for which the loop's range is valid."""
    return 1 if m.lastindex == 1 else int(m.group(2))


POSITIVE = (
    (r'{v}\.count\s*>=\s*(\d+)', 0), (r'{v}\.count\s*>\s*(\d+)', 1),
    (r'!\s*{v}\.isEmpty\b()', None), (r'{v}\.count\s*!=\s*0()', None),
)
NEGATIVE = ((r'{v}\.count\s*<\s*(\d+)', 0), (r'(?<!!)(?<![\w.]){v}\.isEmpty\b()', None))
EXIT = re.compile(r'\b(?:return|throw|continue|break|fatalError)\b')


def depths(lines):
    """Brace depth at the start of each line, string literals ignored."""
    out, depth = [], 0
    for line in lines:
        out.append(depth)
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line.split('//')[0])
        depth += code.count('{') - code.count('}')
    return out


def minimum(patterns, var, cond):
    """The count a condition establishes when true, or None."""
    for pattern, extra in patterns:
        m = re.search(pattern.format(v=var), cond)
        if m:
            return 1 if extra is None else int(m.group(1)) + extra
    return None


def open_through(level, depth_at, k, n):
    """Whether the scope at brace `level` entered by line `k` is still open at
    line `n`: no line between them starts below it."""
    return all(depth_at[j] >= level for j in range(k + 1, n + 1))


def guaranteed_counts(var, lines, n):
    """Every minimum count that is guaranteed for `var` at line `n`.

    A guard counts only where it governs the loop. `guard xs.count >= N else`
    holds for the rest of its scope; `if xs.count >= N {` only inside that
    block; `if xs.count < N { return }` (or `xs.isEmpty`) only when the block
    exits; `for ... where xs.count >= N {` inside its body. A condition with
    `||` guarantees neither side."""
    depth_at = depths(lines[:n + 1])
    found = []
    for k in range(n):
        code = lines[k].split('//')[0]
        head = re.match(r'\s*(?:\}\s*else\s+)?(guard|if|while|for)\b(.*)', code)
        if not head or '||' in head.group(2):
            continue
        keyword, cond = head.group(1), head.group(2)
        cond_text = cond.split(' else ')[0] if keyword == 'guard' else cond.split('{')[0]
        if keyword == 'for':
            m = re.search(r'\bwhere\b(.*)', cond_text)
            cond_text = m.group(1) if m else ''
        positive = minimum(POSITIVE, var, cond_text)
        if positive is not None:
            if keyword == 'guard' and open_through(depth_at[k], depth_at, k, n):
                found.append(positive)
            elif keyword != 'guard' and '{' in cond and open_through(depth_at[k] + 1, depth_at, k, n):
                found.append(positive)
            continue
        negative = minimum(NEGATIVE, var, cond_text)
        if negative is None or keyword != 'if' or not open_through(depth_at[k], depth_at, k, n):
            continue
        block, depth, j = [], 0, k
        while j < n:
            line = lines[j].split('//')[0]
            block.append(line.split('{', 1)[1] if j == k and '{' in line else line)
            depth += line.count('{') - line.count('}')
            if depth <= 0 and '{' in ''.join(lines[k:j + 1]):
                break
            j += 1
        if EXIT.search('\n'.join(block)):
            found.append(negative)
    return found


problems = []
ROOTS = ['Emuqu/Sources', 'EmuquWatch Watch App']
for root in ROOTS:
    if not pathlib.Path(root).is_dir():
        print(f"check_empty_range_loops: scan root missing: {root}", file=sys.stderr)
        sys.exit(2)
for f in sorted(p for root in ROOTS for p in pathlib.Path(root).rglob('*.swift')):
    lines = f.read_text(encoding='utf-8', errors='ignore').split('\n')
    for n, line in enumerate(lines):
        code_only = line.split('//')[0]
        # `max(0, xs.count - N)` cannot be negative — the range is empty, not
        # invalid, which is the fix this gate asks for.
        if re.search(r'max\s*\(\s*0\s*,', code_only):
            continue
        m = next((p.search(code_only) for p in PATTERNS if p.search(code_only)), None)
        if not m:
            continue
        var = re.escape(m.group(1))
        need = required_count(m)
        # Look back only as far as the ENCLOSING unit, however long it is.
        # A fixed window lets a guard belonging to the function ABOVE satisfy
        # this check — which it did for `RecurrenceClassifier.cumulativeDistances`,
        # whose own loop was unguarded while the previous function's
        # `guard pts.count >= 2` sat six lines up.
        start = next((k for k in range(n - 1, -1, -1) if UNIT_START.match(lines[k])), 0)
        # A guard counts only when it is strong enough for THIS range:
        # `xs.count > 0` does not protect `0 ..< xs.count - 2`, which still
        # traps at a count of 1.
        guarded = any(c >= need for c in guaranteed_counts(var, lines[start:n + 1], n - start))
        # An explicit waiver, in the same style as `swallow-ok` elsewhere in
        # this repo. It must carry a reason, so a future reader can check the
        # claim rather than trust a bare marker.
        waiver = re.search(r'empty-range-ok:\s*(\S.*)', '\n'.join(lines[max(0, n - 3):n + 1]))
        if not guarded and not waiver:
            problems.append((f, n + 1, line.strip(), need))

if problems:
    print(f"check_empty_range_loops: {len(problems)} unguarded count-arithmetic range loop(s).\n")
    for f, n, code, need in problems:
        print(f"  {f}:{n}  (needs a guard of count >= {need})")
        print(f"      {code[:78]}")
    print("\n  `1 ..< 0` and `0 ..< -1` are INVALID ranges and trap — not empty loops.")
    print("  Add a count guard immediately before the loop, e.g.")
    print("      guard xs.count > 1 else { return ... }")
    print("  Or clamp the bound so the range is empty rather than invalid:")
    print("      for i in 0 ..< max(0, xs.count - 2)")
    print("  Or, when the collection is non-empty by construction, waive it with")
    print("  a reason: // empty-range-ok: <why this cannot be empty>")
    sys.exit(1)

print("check_empty_range_loops: clean. Every count-arithmetic range loop guards its input.")
PY
