#!/usr/bin/env bash
#
# CI guard: nothing that triggers an iOS permission prompt may be constructed
# eagerly.
#
# `CBCentralManager` and `CBPeripheralManager` show the Bluetooth prompt when
# they are CONSTRUCTED, not when they are first used. A stored property that
# builds one, or an `init()` that does, therefore prompts every user the moment
# the owning object exists — including users who never turned the feature on.
#
# Why this exists (2026-09-01). `ZwiftPeripheralBroadcaster` carries the warning
# twice, in two separate comments:
#
#     // Their getters MUST NOT touch `peripheralManager`, or they'd
#     // force-create the CBPeripheralManager and trigger the iOS
#     // bluetooth-peripheral permission prompt on users who never enabled the
#     // feature.
#
# Written twice because it is easy to undo and expensive when undone: a surprise
# Bluetooth prompt is an App Review question and a trust cost, and it is invisible
# in a simulator run. The comments were the only thing enforcing it.
#
# `lazy var` is fine — that is construction on first access, which is the fix,
# not the defect. Creation inside a function body is fine for the same reason.
# But a `lazy` (or computed) property that `init()` reads unconditionally is
# built in `init()` all the same: `_ = central` at the top of an init made the
# foot-pod manager prompt at launch, during onboarding, for users with no
# sensor. So the gate also flags any unconditional read of such a property in
# an init body. A read behind a condition (the Watch connector touches its
# central only when a strap is already paired, so permission was already
# given) is left alone.
#
# Constructions it recognises: `CBCentralManager(...)`,
# `let x: CBCentralManager = .init(...)`, and the Polar SDK's
# `PolarBleApiDefaultImpl.polarImplementation(...)`, which builds a
# `CBCentralManager` inside.
#
# `HKHealthStore()` is deliberately NOT covered: constructing one prompts
# nothing, only `requestAuthorization` does.
set -euo pipefail

python3 - <<'PY'
import pathlib
import re
import sys

PROMPT_TYPES = r"(?:CBCentralManager|CBPeripheralManager)"
# Expressions that CONSTRUCT something whose initialiser shows a system
# permission prompt.
PROMPTING = re.compile(
    rf"\b{PROMPT_TYPES}\s*\("
    rf"|:\s*{PROMPT_TYPES}\s*[!?]?\s*=\s*\.init\s*\("
    r"|\bPolarBleApiDefaultImpl\s*\.\s*polarImplementation\s*\("
)
# A member property that builds one when first read: `lazy var x = CBCentralManager(`,
# `lazy var x: CBCentralManager = .init(`, or a computed `var x: CBCentralManager {`.
# An optional (`CBPeripheralManager?`) is storage, not a builder, so it is skipped.
BUILDER_PROPERTY = re.compile(
    rf"\bvar\s+(\w+)\s*(?::\s*{PROMPT_TYPES}\b(?!\s*[?!])|=\s*{PROMPT_TYPES}\s*\()"
)
INIT_HEADER = re.compile(
    r"\s*(?:(?:public|internal|private|fileprivate|required|convenience|override|nonisolated)(?:\(\w+\))?\s+)*init\s*[(<]"
)
STORED = re.compile(
    r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|static|final|nonisolated)(?:\(\w+\))?\s+)*(?:let|var)\s+\w+"
)

ROOTS = ["Emuqu/Sources", "EmuquWatch Watch App", "Emuqu/EmuquApp.swift"]


def code_lines(file):
    return [raw.split("//")[0] for raw in file.read_text(encoding="utf-8", errors="ignore").split("\n")]


def builder_properties(lines):
    """Names of member properties that construct a prompting type on first read."""
    names, depth = set(), 0
    for line in lines:
        if depth <= 1:
            match = BUILDER_PROPERTY.search(line)
            if match:
                names.add(match.group(1))
        depth += line.count("{") - line.count("}")
    return names


def unconditional_init_touch(text, names):
    """The builder property this init-body text reads, if any (`_ = central`, `central.state`).

    Braced parts are dropped first: in `if paired { _ = central }` the read
    sits behind the condition.
    """
    while re.search(r"\{[^{}]*\}", text):
        text = re.sub(r"\{[^{}]*\}", "", text)
    for name in names:
        if re.search(rf"(?<![\w.])(?:self\s*\.\s*)?{name}\b(?!\s*:)", text):
            return name
    return None


def scan(file, problems):
    lines = code_lines(file)
    builders = builder_properties(lines)
    in_init, init_depth, depth = False, 0, 0
    for n, line in enumerate(lines, 1):
        header = bool(INIT_HEADER.match(line))
        if header:
            in_init, init_depth = True, depth
        opened = depth
        depth += line.count("{") - line.count("}")
        # Code at the init body's own top level runs every time; code nested
        # deeper sits behind a condition or in a closure.
        top_level = line.split("{", 1)[1] if header and "{" in line else (line if opened == init_depth + 1 else "")
        if PROMPTING.search(line):
            # Depth distinguishes a STORED PROPERTY from a local. A member of a
            # type sits at brace depth 1 (0 at file scope); anything inside a
            # function or closure is 2 or more, and a local built there is
            # exactly the lazy construction this gate is asking for.
            stored_property = opened <= 1 and STORED.match(line)
            if stored_property and " lazy " not in f" {line} ":
                problems.append((file, n, line.strip(), "built in a stored property"))
            elif in_init:
                problems.append((file, n, line.strip(), "built inside init()"))
        elif in_init and top_level:
            touched = unconditional_init_touch(top_level, builders)
            if touched:
                problems.append((file, n, line.strip(), f"init() reads `{touched}`, which builds one"))
        if in_init and depth <= init_depth and (opened != init_depth or (header and "{" in line)):
            in_init = False


problems = []
scanned = 0
for root in ROOTS:
    path = pathlib.Path(root)
    files = [path] if path.is_file() else (sorted(path.rglob("*.swift")) if path.is_dir() else [])
    for file in files:
        scanned += 1
        scan(file, problems)

if problems:
    print(f"check_no_eager_permission_prompts: {len(problems)} eager construction(s).\n", file=sys.stderr)
    for file, n, code, why in problems:
        print(f"  {file}:{n}  ({why})", file=sys.stderr)
        print(f"      {code[:96]}", file=sys.stderr)
    print(
        "\n  These types prompt the user when CONSTRUCTED. Building one eagerly shows"
        "\n  the Bluetooth prompt to people who never enabled the feature."
        "\n  Make it `lazy` or computed, build it inside the method that starts the"
        "\n  feature, and do not read it from init() except behind a condition that"
        "\n  proves permission was already given.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"check_no_eager_permission_prompts: clean. {scanned} file(s); no prompting type is built eagerly.")
PY
