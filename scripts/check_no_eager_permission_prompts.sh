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
#
# `HKHealthStore()` is deliberately NOT covered: constructing one prompts
# nothing, only `requestAuthorization` does.
set -euo pipefail

python3 - <<'PY'
import pathlib
import re
import sys

# Types whose INITIALISER triggers a system permission prompt.
PROMPTING = re.compile(r"\b(CBCentralManager|CBPeripheralManager)\s*\(")

ROOTS = ["Emuqu/Sources", "EmuquWatch Watch App", "Emuqu/EmuquApp.swift"]

problems = []
scanned = 0
for root in ROOTS:
    path = pathlib.Path(root)
    files = [path] if path.is_file() else (sorted(path.rglob("*.swift")) if path.is_dir() else [])
    for file in files:
        lines = file.read_text(encoding="utf-8", errors="ignore").split("\n")
        scanned += 1
        in_init = False
        init_depth = 0
        depth = 0
        for n, raw in enumerate(lines, 1):
            line = raw.split("//")[0]
            if re.match(r"\s*(?:(?:public|internal|private|fileprivate|required|convenience|override)\s+)*init\s*[(<]", line):
                in_init, init_depth = True, depth
            opened = depth
            depth += line.count("{") - line.count("}")
            if in_init and depth <= init_depth and opened != init_depth:
                in_init = False
            if not PROMPTING.search(line):
                continue
            # Depth distinguishes a STORED PROPERTY from a local. A member of a
            # type sits at brace depth 1 (0 at file scope); anything inside a
            # function or closure is 2 or more, and a local built there is
            # exactly the lazy construction this gate is asking for. Matching on
            # `let x =` alone flagged `existingOrNewPeripheralManager`'s own
            # local on the first run of this gate.
            stored_property = opened <= 1 and re.match(
                r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|static|final|nonisolated)(?:\(\w+\))?\s+)*(?:let|var)\s+\w+",
                line,
            )
            if stored_property and " lazy " not in f" {line} ":
                problems.append((file, n, line.strip(), "built in a stored property"))
            elif in_init:
                problems.append((file, n, line.strip(), "built inside init()"))

if problems:
    print(f"check_no_eager_permission_prompts: {len(problems)} eager construction(s).\n", file=sys.stderr)
    for file, n, code, why in problems:
        print(f"  {file}:{n}  ({why})", file=sys.stderr)
        print(f"      {code[:96]}", file=sys.stderr)
    print(
        "\n  These types prompt the user when CONSTRUCTED. Building one eagerly shows"
        "\n  the Bluetooth prompt to people who never enabled the feature."
        "\n  Make it `lazy`, or build it inside the method that starts the feature.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"check_no_eager_permission_prompts: clean. {scanned} file(s); no prompting type is built eagerly.")
PY
