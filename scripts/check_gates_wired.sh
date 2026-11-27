#!/usr/bin/env bash
#
# CI guard: every gate in `scripts/` actually runs in CI.
#
# Why this exists. A gate that CI never invokes is a gate that does not exist,
# and it is indistinguishable from a working one when you read the directory
# listing. A gate wired into the `Makefile` only runs when someone remembers
# `make ci` locally and never on a push.
#
# Two workflows, two questions:
#
#   * `ci.yml` (the complete list): every gate must run there.
#   * `gates.yml` (every push and pull request): every gate must run there too,
#     unless it is in NOT_ON_PUSH with the reason it cannot run on a Linux
#     runner (SwiftLint, Xcode, a simulator).
#
# "Runs" means named by a `run:` command of a step that runs on every pull
# request and can fail it, either directly or through a `make` target whose
# recipe (or a prerequisite's) names it. A mention in a YAML comment is not a
# run, and neither is a step that cannot fail or may not run:
#
#   * a step or job with `continue-on-error`, or a run line that ends a gate in
#     `|| true`, `|| :` or `|| exit 0`, or a step that turns `set +e` on;
#   * a step with an `if:` other than `always()` / `success()`, and a job with
#     an `if:` other than the scope condition (`inputs.scope != 'gates'`), which
#     is true on every pull request. A required job that `if:` skips reports
#     "skipped", and GitHub counts a skipped required check as passed.
#
# Both workflows must also trigger on every pull request and on pushes to
# `main` with no `paths`, `paths-ignore`, `branches` or `types` filter: a
# filtered workflow never starts for the changes it filters out.
#
# Gates that are not `check_*.sh` / `enforce_*.sh` scripts are listed in
# REQUIRED_COMMANDS with the workflows that must run them.
#
# `verify_gates_fail.sh` proves a gate goes red on a real violation; this proves
# it is reached at all.
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

# A step condition that still runs the step whenever the gate has a chance to
# fail it. A job condition true on every pull request and push.
STEP_IF_OK = re.compile(r"^\s*if:\s*(?:\$\{\{\s*)?(?:always|success)\(\)(?:\s*\}\})?\s*$")
JOB_IF_OK = re.compile(r"^\s*if:\s*inputs\.scope\s*!=\s*'gates'\s*$")
CONTINUE = re.compile(r"^\s*continue-on-error:\s*(?!false\s*$)\S")
SWALLOWED = re.compile(r"\|\|\s*(?:true|:|exit\s+0)\b")

# Gates that are not check_*/enforce_* scripts: the text a run must contain,
# and which workflows must run it.
REQUIRED_COMMANDS = {
    "Tools/copy_linter/lint.py": ("ci", "push"),
    "generate_sbom.py --check": ("ci", "push"),
    "Tools/validation/test_ports.py": ("ci", "push"),
    "verify_gates_fail.sh": ("ci",),
    "run_tests_with_coverage.sh": ("ci",),
}


def strip_comment(line):
    """The line without a shell or YAML comment (a `#` at the start or after a space)."""
    return re.sub(r"(^|\s)#.*$", "", line)


def run_text(path):
    """The text of every `run:` command of every step that is not disabled."""
    lines = path.read_text(encoding="utf-8").split("\n")
    out = []
    job_disabled = False
    step_lines = []

    def step_disabled(step):
        keys = [l for l in step[1:] if re.match(r"^\s{8}[\w-]+:", l)]
        first = re.sub(r"^(\s*)-\s+", r"\1  ", step[0])
        keys.append(first)
        if any(CONTINUE.match(k) for k in keys):
            return True
        if any(re.match(r"^\s*if:", k) and not STEP_IF_OK.match(k) for k in keys):
            return True
        return any(re.match(r"^\s*set\s+[^#]*\+e\b", l) for l in step)

    def flush(step):
        if not step or job_disabled or step_disabled(step):
            return
        for i, line in enumerate(step):
            m = re.match(r"^(\s*)(?:-\s+)?run:\s*(.*)$", line)
            if not m:
                continue
            value = m.group(2).strip()
            if value and value[0] not in "|>":
                if not SWALLOWED.search(value):
                    out.append(strip_comment(value))
                continue
            key_indent = len(m.group(1))
            for body in step[i + 1:]:
                if body.strip() and len(body) - len(body.lstrip()) <= key_indent:
                    break
                if not body.strip().startswith("#") and not SWALLOWED.search(body):
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
            job_disabled = job_disabled or not JOB_IF_OK.match(line)
            continue
        if re.match(r"^    continue-on-error:", line):
            job_disabled = job_disabled or bool(CONTINUE.match(line))
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

def trigger_problems(path):
    """Why `path` would not start on every pull request and push to main."""
    lines = path.read_text(encoding="utf-8").split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if re.match(r"^on:\s*$", l))
    except StopIteration:
        return ["no block-form `on:` trigger"]
    events, current = {}, None
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith(" ") and not line.lstrip().startswith("#"):
            break
        m = re.match(r"^  ([\w-]+):\s*(.*)$", line)
        if m:
            current = m.group(1)
            events[current] = [m.group(2)] if m.group(2) and not m.group(2).startswith("#") else []
        elif current and line.strip() and not line.lstrip().startswith("#"):
            events[current].append(line.strip())
    problems = []
    if "pull_request" not in events:
        problems.append("does not run on pull requests")
    elif events["pull_request"]:
        problems.append("filters pull requests: " + "; ".join(events["pull_request"]))
    push_keys = events.get("push")
    if push_keys is None:
        problems.append("does not run on pushes to main")
    elif push_keys != ["branches: [main]"]:
        problems.append("push trigger is not exactly `branches: [main]`: " + "; ".join(push_keys))
    return problems


manual = expand_make(run_text(workflow_path))
push = expand_make(run_text(push_path))

triggers = {str(p): trigger_problems(p) for p in (workflow_path, push_path)}
missing_commands = [
    f"{command} in {path}"
    for command, where in REQUIRED_COMMANDS.items()
    for key, path, text in (("ci", workflow_path, manual), ("push", push_path, push))
    if key in where and command not in text
]
if any(triggers.values()) or missing_commands:
    for path, problems in triggers.items():
        for problem in problems:
            print(f"check_gates_wired: {path} {problem}", file=sys.stderr)
    for item in missing_commands:
        print(f"check_gates_wired: no step that can fail runs {item}", file=sys.stderr)
    raise SystemExit(1)

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
