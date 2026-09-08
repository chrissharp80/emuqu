#!/usr/bin/env bash
# Run what CI runs, locally, before paying for a hosted run.
#
# Why this exists. macOS runners bill at 10x, so a CI failure that a laptop
# could have caught costs real money — and the typical failure is exactly that
# kind: a budget file that needs a justification trailer, a step-level env
# override, a renamed file a gate still references. None of them needs a
# runner to find.
#
# The important property is that this CANNOT drift from `.github/workflows/ci.yml`.
# It does not keep its own list of checks — it parses the workflow and executes
# the same `run:` blocks in the same order. A step added to CI is picked up
# automatically. A step this script does not know how to run locally is a hard
# error, never a silent skip: the whole point is that green here means green
# there, and a skipped step breaks that promise.
#
# Usage:
#   ./scripts/simulate_ci.sh              # gates only (fast, no simulator)
#   ./scripts/simulate_ci.sh --scope unit # gates + the unit test suite
#   ./scripts/simulate_ci.sh --list       # show what would run, run nothing
#
# Run it AFTER committing. CI checks out a commit, and the budget-ratchet gate
# compares HEAD against HEAD~1, so an uncommitted budget change is invisible to
# it here exactly as it would be there. The script warns when the tree is dirty.
set -uo pipefail

SCOPE="gates"
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --scope) SCOPE="${2:-gates}"; shift 2 ;;
        --list)  LIST_ONLY=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f .github/workflows/ci.yml ]; then
    echo "simulate_ci: .github/workflows/ci.yml not found — run from the repo root." >&2
    exit 2
fi

# Refuse to measure a tree `verify_gates_fail.sh` is mutating. A planted
# `WrongDir/EmuquApp.swift` citation or a planted privacy-manifest type, put
# there moments earlier and restored moments later, reads here as a failure —
# a red run about nothing, and on a hosted macOS runner that is billed at 10x.
source "$(dirname "$0")/lib/preflight.sh"
gate_require_unmutated_tree "simulate_ci"

export SIMULATE_CI_SCOPE="$SCOPE"
export SIMULATE_CI_LIST="$LIST_ONLY"

python3 - <<'PY'
import os, re, subprocess, sys, pathlib, tempfile
import yaml

scope = os.environ["SIMULATE_CI_SCOPE"]
list_only = os.environ["SIMULATE_CI_LIST"] == "1"
wf = yaml.safe_load(pathlib.Path(".github/workflows/ci.yml").read_text())

# Steps that genuinely cannot run on a developer machine, each with the reason.
# A step matching none of these and none of the runnable cases is an ERROR — see
# the header: a silent skip would make a green result here meaningless.
CANNOT_RUN_LOCALLY = [
    (r"^sudo xcode-select",
     "picks the runner's Xcode; your local one is already selected"),
    (r"\bbrew (install|update|tap)\b",
     "installs runner tooling; assumed present locally"),
    (r"actions/(checkout|cache|upload-artifact|download-artifact)",
     "GitHub Actions infrastructure"),
]

# `$GITHUB_OUTPUT` steps are NOT skipped. They are run against a real temp file
# and their outputs are fed to later steps, because skipping a producer while
# running its consumer is how you get a false red: the budget-monotonicity check
# refuses to run without a baseline, and its baseline comes from exactly such a
# step. A simulator that cries wolf is one you learn to ignore.
INPUT_DEFAULTS = {"scope": os.environ["SIMULATE_CI_SCOPE"], "baseline-ref": ""}

# Jobs whose cost is the reason you are running this script at all. `gates` scope
# runs only the cheap job, mirroring the same choice the workflow makes.
EXPENSIVE_JOBS = {"tests", "thread-sanitizer", "strict-concurrency"}

steps = []
step_ids = {}
step_outputs = {}

def expand(text):
    """Resolve the GitHub Actions expressions a local run can actually know."""
    def sub(m):
        expr = m.group(1).strip()
        so = re.match(r"steps\.([\w-]+)\.outputs\.([\w-]+)$", expr)
        if so:
            return step_outputs.get((so.group(1), so.group(2)), "")
        inp = re.match(r"inputs\.([\w-]+)$", expr)
        if inp:
            return INPUT_DEFAULTS.get(inp.group(1), "")
        tern = re.match(r"inputs\.([\w-]+) == '([^']*)' && '([^']*)' \|\| '([^']*)'$", expr)
        if tern:
            return tern.group(3) if INPUT_DEFAULTS.get(tern.group(1)) == tern.group(2) else tern.group(4)
        return ""
    return re.sub(r"\$\{\{([^}]*)\}\}", sub, text)

for job_name, job in (wf.get("jobs") or {}).items():
    if scope == "gates" and job_name in EXPENSIVE_JOBS:
        continue
    if scope == "unit" and job_name in {"thread-sanitizer"}:
        continue
    # Job-level `env:` is carried, not only step-level. That is exactly the
    # axis `ci.yml`'s own note about run 33230172290 warns on: `TEST_SCOPE` is
    # set on the JOB, so dropping job env makes a local `--scope unit` fall
    # back to the script's `full` default and run the UI target — over an hour
    # locally to simulate a job that would not run it at all. A simulator that
    # diverges from the workflow on the expensive axis is worse than no
    # simulator, because its green is read as evidence. Step env still wins
    # over job env, matching GitHub's precedence.
    job_env = job.get("env") or {}
    for step in (job.get("steps") or []):
        run = step.get("run")
        name = step.get("name", "(unnamed)")
        if step.get("uses"):
            continue
        if not run:
            continue
        merged_env = dict(job_env)
        merged_env.update(step.get("env") or {})
        steps.append((job_name, name, run.strip(), merged_env))
        if step.get("id"):
            step_ids[(job_name, name)] = step["id"]

def why_skipped(cmd):
    for pattern, reason in CANNOT_RUN_LOCALLY:
        if re.search(pattern, cmd):
            return reason
    return None

if list_only:
    print(f"simulate_ci: scope={scope}\n")
    for job, name, cmd, _ in steps:
        skip = why_skipped(cmd)
        mark = "SKIP" if skip else "RUN "
        print(f"  {mark}  [{job}] {name}")
        if skip:
            print(f"          ^ {skip}")
    sys.exit(0)

GREEN, RED, YELLOW, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
print(f"simulate_ci: running what CI runs, scope={scope}.")
print("Green here is not a promise of green there, but every failure it finds")
print("is one you did not pay a 10x macOS runner to find.\n")

# CI checks out a commit. Two of these gates compare HEAD against HEAD~1 rather
# than reading the working tree, so with uncommitted changes they are answering
# a different question than the hosted run will. Say so rather than let a green
# result imply more than it means.
dirty = subprocess.run(["git", "status", "--porcelain"],
                       capture_output=True, text=True).stdout.strip()
if dirty:
    n = len(dirty.splitlines())
    print(f"  {YELLOW}NOTE{OFF}  {n} uncommitted change(s) in the working tree.")
    print("        File-reading gates see them; the budget-ratchet gate compares")
    print("        HEAD against HEAD~1 and does not. Commit first for a faithful")
    print("        reproduction of what CI will evaluate.\n")

passed, failed, skipped = [], [], []

for job, name, cmd, env in steps:
    reason = why_skipped(cmd)
    if reason:
        skipped.append((name, reason))
        print(f"  {YELLOW}SKIP{OFF}  {name}")
        print(f"        {reason}")
        continue
    merged = dict(os.environ)
    merged.update({k: expand(str(v)) for k, v in env.items()})
    out_file = tempfile.NamedTemporaryFile("w+", delete=False, suffix=".ghout")
    out_file.close()
    merged["GITHUB_OUTPUT"] = out_file.name
    merged["GITHUB_ENV"] = out_file.name + ".env"
    merged["GITHUB_STEP_SUMMARY"] = out_file.name + ".summary"
    proc = subprocess.run(["bash", "-lc", expand(cmd)], capture_output=True,
                          text=True, env=merged)
    step_id = step_ids.get((job, name))
    if step_id:
        for line in pathlib.Path(out_file.name).read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                step_outputs[(step_id, k)] = v
    os.unlink(out_file.name)
    if proc.returncode == 0:
        passed.append(name)
        print(f"  {GREEN}PASS{OFF}  {name}")
    else:
        failed.append((name, cmd, proc))
        print(f"  {RED}FAIL{OFF}  {name}")

print()
if failed:
    print(f"{RED}{len(failed)} step(s) would fail on CI:{OFF}\n")
    for name, cmd, proc in failed:
        print(f"  --- {name}")
        print(f"      $ {cmd.splitlines()[0]}")
        tail = (proc.stdout + proc.stderr).strip().splitlines()
        for line in tail[-12:]:
            print(f"      {line}")
        print()

print(f"  {len(passed)} passed, {len(failed)} failed, {len(skipped)} not runnable locally")
if scope == "gates":
    print("  (scope=gates — the test, sanitizer and concurrency jobs were not run;")
    print("   use --scope unit to include the test suite)")
sys.exit(1 if failed else 0)
PY
