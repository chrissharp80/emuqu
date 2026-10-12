#!/usr/bin/env bash
#
# CI guard: every gate in `scripts/` actually runs in CI.
#
# Why this exists (2026-09-01). A gate that CI never invokes is a gate that does
# not exist, and it is indistinguishable from a working one when you read the
# directory listing. Two gates in this repository shipped wired into the
# `Makefile` only, so they ran when someone remembered `make ci` locally and
# never on a push.
#
# Two workflows, two questions:
#
#   * `ci.yml` (manual, the complete list): every gate must run there.
#   * `gates.yml` (every push and pull request): every gate must run there too,
#     unless it is in NOT_ON_PUSH with the reason it cannot run on a Linux
#     runner (SwiftLint, Xcode, a simulator).
#
# "Runs" means named by a `run:` command of a step that is not disabled with a
# literal `if: false`, either directly or through a `make` target whose recipe
# (or a prerequisite's) names it. A mention in a YAML comment is not a run.
#
# This is the third member of a family: `verify_gates_fail.sh` proves a gate
# goes red on a real violation, `check_gate_preflight.sh` proves it fails closed
# on a missing input, and this proves it is reached at all. A gate needs all
# three to be worth its runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

WORKFLOW="${GATES_WORKFLOW_FILE:-.github/workflows/ci.yml}"
PUSH_WORKFLOW="${GATES_PUSH_WORKFLOW_FILE:-.github/workflows/gates.yml}"

python3 - "$WORKFLOW" "$PUSH_WORKFLOW" Makefile <<'PY'
import pathlib
import re
import sys

workflow_path, push_path, makefile_path = (pathlib.Path(a) for a in sys.argv[1:4])
for path in (workflow_path, push_path, makefile_path):
    if not path.is_file():
        print(f"check_gates_wired: {path} not found", file=sys.stderr)
        raise SystemExit(2)

# Gates that are deliberately not steps of their own, in either workflow.
#
#   * `check_coverage.sh` is invoked by `run_tests_with_coverage.sh`, which is
#     the step; giving it a step of its own would run the suite twice.
NOT_A_STEP = {
    "check_coverage.sh": "invoked by run_tests_with_coverage.sh, which is the step",
}

# Gates that run in ci.yml but cannot run in the push workflow's Linux job.
NOT_ON_PUSH = {
    "enforce_swiftlint_budget.sh": "needs SwiftLint, whose Linux rule set differs",
    "check_thread_sanitizer.sh": "needs Xcode and a simulator",
}

DISABLED_IF = re.compile(r"^\s*if:\s*(?:false|\$\{\{\s*false\s*\}\})\s*$")


def strip_comment(line):
    """The line without a shell or YAML comment (a `#` at the start or after a space)."""
    return re.sub(r"(^|\s)#.*$", "", line)


def run_text(path):
    """The text of every `run:` command of every step that is not disabled."""
    lines = path.read_text(encoding="utf-8").split("\n")
    out = []
    job_disabled = False
    step_lines = []

    def flush(step):
        if not step or job_disabled or any(DISABLED_IF.match(l) for l in step):
            return
        for i, line in enumerate(step):
            m = re.match(r"^(\s*)(?:-\s+)?run:\s*(.*)$", line)
            if not m:
                continue
            value = m.group(2).strip()
            if value and value[0] not in "|>":
                out.append(strip_comment(value))
                continue
            key_indent = len(m.group(1))
            for body in step[i + 1:]:
                if body.strip() and len(body) - len(body.lstrip()) <= key_indent:
                    break
                if not body.strip().startswith("#"):
                    out.append(strip_comment(body))

    for line in lines:
        if line.strip().startswith("#"):
            continue
        job = re.match(r"^  ([\w-]+):\s*$", line)
        if job:
            flush(step_lines)
            step_lines = []
            job_disabled = False
            continue
        if re.match(r"^    if:", line):
            job_disabled = bool(DISABLED_IF.match(line))
            continue
        if re.match(r"^\s{4,}-\s", line):
            flush(step_lines)
            step_lines = [line]
            continue
        if step_lines:
            step_lines.append(line)
    flush(step_lines)
    return "\n".join(out)


def make_targets(path):
    """target -> (prerequisites, recipe text)."""
    targets = {}
    current = None
    for line in path.read_text(encoding="utf-8").split("\n"):
        m = re.match(r"^([A-Za-z0-9_.-]+)\s*:(?!=)(.*)$", line)
        if m:
            current = m.group(1)
            targets[current] = (m.group(2).split(), [])
            continue
        if line.startswith("\t") and current:
            targets[current][1].append(strip_comment(line))
        elif line.strip() and not line.startswith("\t"):
            current = None
    return targets


TARGETS = make_targets(makefile_path)


def expand_make(text):
    """`text` plus the recipe of every make target it invokes, recursively."""
    seen = set()
    pending = []
    for m in re.finditer(r"(?:\bmake|\$\(MAKE\))\s+([^&|;\n]+)", text):
        pending += [t for t in m.group(1).split() if not t.startswith("-") and "=" not in t]
    parts = [text]
    while pending:
        target = pending.pop()
        if target in seen or target not in TARGETS:
            continue
        seen.add(target)
        prereqs, recipe = TARGETS[target]
        recipe_text = "\n".join(recipe)
        parts.append(recipe_text)
        pending += prereqs
        for m in re.finditer(r"(?:\bmake|\$\(MAKE\))\s+([^&|;\n]+)", recipe_text):
            pending += [t for t in m.group(1).split() if not t.startswith("-") and "=" not in t]
    return "\n".join(parts)


def runs(name, text):
    return re.search(rf"(?<![\w.-]){re.escape(name)}\b", text) is not None


gates = sorted(
    p for p in pathlib.Path("scripts").glob("*.sh")
    if p.name.startswith(("check_", "enforce_"))
)
if not gates:
    print("check_gates_wired: no gates found under scripts/", file=sys.stderr)
    raise SystemExit(2)

manual = expand_make(run_text(workflow_path))
push = expand_make(run_text(push_path))

unwired = [g.name for g in gates if g.name not in NOT_A_STEP and not runs(g.name, manual)]
not_on_push = [
    g.name for g in gates
    if g.name not in NOT_A_STEP and g.name not in NOT_ON_PUSH and not runs(g.name, push)
]

if unwired or not_on_push:
    if unwired:
        print(f"check_gates_wired: {len(unwired)} gate(s) never run in {workflow_path}.\n",
              file=sys.stderr)
        for name in unwired:
            print(f"  scripts/{name}", file=sys.stderr)
    if not_on_push:
        print(f"\ncheck_gates_wired: {len(not_on_push)} gate(s) never run on a push "
              f"({push_path}).\n", file=sys.stderr)
        for name in not_on_push:
            print(f"  scripts/{name}", file=sys.stderr)
    print(
        "\n  Add a step (or a make target in an existing step) that runs it, or record"
        "\n  why it cannot in this gate's NOT_A_STEP or NOT_ON_PUSH map. A gate CI never"
        "\n  invokes is indistinguishable from a working one when you read the directory.",
        file=sys.stderr,
    )
    raise SystemExit(1)

stale = sorted(n for n in list(NOT_A_STEP) + list(NOT_ON_PUSH)
               if not (pathlib.Path("scripts") / n).is_file())
if stale:
    print("check_gates_wired: exemptions name gates that no longer exist: "
          + ", ".join(stale), file=sys.stderr)
    raise SystemExit(1)

covered = len(gates) - len(NOT_A_STEP)
print(f"check_gates_wired: clean. {covered} gate(s) run in {workflow_path}, "
      f"{covered - len(NOT_ON_PUSH)} of them on every push ({push_path}); "
      f"{len(NOT_A_STEP)} invoked by another step.")
PY
