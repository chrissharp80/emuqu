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
# This is the third member of a family: `verify_gates_fail.sh` proves a gate
# goes red on a real violation, `check_gate_preflight.sh` proves it fails closed
# on a missing input, and this proves it is reached at all. A gate needs all
# three to be worth its runtime.
set -euo pipefail

WORKFLOW="${GATES_WORKFLOW_FILE:-.github/workflows/ci.yml}"

python3 - "$WORKFLOW" <<'PY'
import pathlib
import sys

workflow_path = pathlib.Path(sys.argv[1])
if not workflow_path.is_file():
    print(f"check_gates_wired: workflow not found at {workflow_path}", file=sys.stderr)
    raise SystemExit(2)
workflow = workflow_path.read_text(encoding="utf-8")

# Gates that are deliberately not steps of their own.
#
#   * `check_gate_preflight.sh` and `verify_gates_fail.sh` ARE steps, and are
#     listed here only because they are the meta-gates checking the others.
#   * `check_coverage.sh` is invoked by `run_tests_with_coverage.sh`, which is
#     the step; giving it a step of its own would run the suite twice.
NOT_A_STEP = {
    "check_coverage.sh": "invoked by run_tests_with_coverage.sh, which is the step",
}

gates = sorted(
    p for p in pathlib.Path("scripts").glob("*.sh")
    if p.name.startswith(("check_", "enforce_"))
)

unwired = []
for gate in gates:
    if gate.name in NOT_A_STEP:
        continue
    if gate.name not in workflow:
        unwired.append(gate.name)

if unwired:
    print(f"check_gates_wired: {len(unwired)} gate(s) never run in CI.\n", file=sys.stderr)
    for name in unwired:
        print(f"  scripts/{name}", file=sys.stderr)
    print(
        f"\n  Add a step to {workflow_path} that runs it, or record why it is not a"
        "\n  step in this gate's NOT_A_STEP map. A gate CI never invokes is"
        "\n  indistinguishable from a working one when you read the directory.",
        file=sys.stderr,
    )
    raise SystemExit(1)

covered = len(gates) - len(NOT_A_STEP)
print(f"check_gates_wired: clean. {covered} gate(s) run in {workflow_path}; "
      f"{len(NOT_A_STEP)} invoked by another step.")
PY
