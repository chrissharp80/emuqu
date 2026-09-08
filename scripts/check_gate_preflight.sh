#!/usr/bin/env bash
#
# The gates must fail closed.
#
# ## Why
#
# Two verification gates were found reporting **clean,
# exit 0** when they had measured nothing: an invalid `TMPDIR` made `mktemp`
# fail, and because the scripts use `set -uo pipefail` without `-e`, execution
# continued with an empty path. `grep` over a file that was never written finds
# nothing, and these gates report "nothing found" as success.
#
# A verification tool failing open is worse than no tool. A green check is read
# as evidence, and every ratcheted budget in `.ci/` assumes these numbers are
# real.
#
# The fix routes temp-file creation through `gate_mktemp` in `lib/preflight.sh`.
# That helper is called inside command substitution — a subshell — so its `exit`
# cannot terminate the caller on its own. Every call site therefore needs
# `|| exit $?`, and the first version of the fix shipped without it, reproducing
# the exact bug it was written to remove.
#
# That is the third time in one session that a check reported clean while
# missing the thing it was named for. Hence this: a gate for the gates.
#
# Enforces:
#   1. Any script calling `mktemp` directly, instead of `gate_mktemp`, is
#      flagged — that is the unguarded path.
#   2. Every `gate_mktemp` call site carries `|| exit $?`.
#   3. Every script sourcing `lib/preflight.sh` does so with a path that
#      resolves, so a typo cannot silently define no functions at all.

set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

failures = []

# `lib/` holds sourced helpers, not gates; `generate_sbom.py` is Python.
scripts = sorted(
    p for p in pathlib.Path("scripts").glob("*.sh")
    if p.name != "check_gate_preflight.sh"
)

for path in scripts:
    text = path.read_text()

    # 1. Direct mktemp, outside the helper itself.
    for lineno, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if re.search(r"(?<!gate_)\bmktemp\b", line) and "gate_mktemp" not in line:
            failures.append(
                f"{path}:{lineno} calls `mktemp` directly.\n"
                f"      Use: name=\"$(gate_mktemp label)\" || exit $?\n"
                f"      A bare mktemp that fails leaves an empty path and the gate reports clean."
            )

    # 2. gate_mktemp without the subshell guard.
    for lineno, line in enumerate(text.split("\n"), 1):
        if "gate_mktemp" not in line or line.strip().startswith("#"):
            continue
        if "|| exit" not in line:
            failures.append(
                f"{path}:{lineno} calls `gate_mktemp` without `|| exit $?`.\n"
                f"      gate_mktemp runs in a subshell; its exit cannot stop the caller.\n"
                f"      Without the guard the script continues with an empty path — the original bug."
            )

    # 3. A source line that does not resolve defines nothing, silently.
    for lineno, line in enumerate(text.split("\n"), 1):
        m = re.search(r'source\s+"\$\(dirname "\$0"\)/([^"]+)"', line)
        if m and not (pathlib.Path("scripts") / m.group(1)).exists():
            failures.append(f"{path}:{lineno} sources a file that does not exist: scripts/{m.group(1)}")

if failures:
    print(f"check_gate_preflight: {len(failures)} gate(s) can fail open.\n")
    for f in failures:
        print(f"  {f}\n")
    print("  A verification gate that reports 'clean' without measuring anything")
    print("  is worse than no gate: the green is read as evidence.")
    sys.exit(1)

guarded = sum(t.count("gate_mktemp") for t in (p.read_text() for p in scripts))
print(f"check_gate_preflight: clean. {len(scripts)} gates, {guarded} guarded temp-file uses, no direct mktemp.")
PY
