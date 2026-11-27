#!/usr/bin/env bash
set -euo pipefail

# Coupling only falls.
#
# File and function size limits are easy to pass without changing a design:
# move code into another `Type+Part.swift` file, or into a value that holds
# the whole type and reaches back into it. Those moves leave every dependency
# where it was. This gate counts the dependencies themselves, so moving code
# around changes nothing here and only giving a part what it uses lowers a
# number:
#
#   * Hub back-references: stored properties typed as one of the app's hubs
#     (`RRCollector`, `WorkoutRecorder`, `HealthKitManager`, `PolarManager`)
#     outside the views (which observe them) and the composition root. Each
#     is a part that can reach everything the hub holds.
#   * Service-locator reads: `AppDependencies.current` outside the
#     composition root. Each is a dependency the type's initializer hides.
#   * Pass-through forwarders: a function whose whole body calls the
#     same-named function on another value.
#
# Each count has its own budget file, so `check_budget_monotonicity.sh` holds
# each one: it may fall, and a rise needs a `budget-raise-ok:` trailer. A
# count below its budget fails too, so a gain is locked in by lowering the
# file in the same change.

SOURCE_ROOT="${1:-Emuqu/Sources}"
HUB_BUDGET_FILE="${HUB_BUDGET_FILE:-.ci/hub_back_reference_budget.txt}"
LOCATOR_BUDGET_FILE="${LOCATOR_BUDGET_FILE:-.ci/locator_read_budget.txt}"
FORWARDER_BUDGET_FILE="${FORWARDER_BUDGET_FILE:-.ci/passthrough_forwarder_budget.txt}"

if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "Source root not found: $SOURCE_ROOT" >&2
    exit 66
fi

python3 - "$SOURCE_ROOT" "$HUB_BUDGET_FILE" "$LOCATOR_BUDGET_FILE" "$FORWARDER_BUDGET_FILE" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
budget_files = dict(zip(("hub", "locator", "forwarder"), (pathlib.Path(p) for p in sys.argv[2:5])))

HUBS = "RRCollector|WorkoutRecorder|HealthKitManager|PolarManager"
# Anywhere on a line, so `struct Part { let collector: RRCollector }` on one
# line counts as well as the usual one property per line.
# `[RRCollector]`, `Optional<RRCollector>` and `Weak<RRCollector>` hold the hub too.
HUB_PROPERTY = re.compile(rf"\b(?:let|var)\s+\w+\s*:\s*(?:\[\s*|\w+<\s*)*(?:{HUBS})\b(?!\.)")
LOCATOR = re.compile(r"\bAppDependencies\.current\b")
FORWARDER = re.compile(r"func (\w+)[^{]*\{\s*(?:return\s+)?(?:try\s+)?(?:await\s+)?(?:self\.)?\w+\??\.(\w+)\(")


# By path, not by name prefix: any file called `AppDependencies<anything>.swift`
# would otherwise be exempt wherever it sits.
ROOT_FILES = {
    "Utilities/AppDependencies.swift",
    "Utilities/AppDependencies+Reanalysis.swift",
    "Utilities/AppDependenciesEnvironment.swift",
    "Utilities/SharedInstances.swift",
}


def is_root(path):
    return path.relative_to(root).as_posix() in ROOT_FILES


def in_views(path):
    return any(part in ("Views", "ViewModels") for part in path.parts)


def code_lines(text):
    """Lines that are not comments."""
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped.startswith("//"):
            yield line


def closes_after_call(text, start):
    """Whether the call opened just before `start` is the whole body."""
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        i += 1
    return text[i:i + 8].strip().startswith("}")


def forwarders(text):
    return sum(
        1 for m in FORWARDER.finditer(text)
        if m.group(1) == m.group(2) and closes_after_call(text, m.end())
    )


counts = {"hub": 0, "locator": 0, "forwarder": 0}
for path in sorted(root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    lines = list(code_lines(text))
    if not is_root(path) and not in_views(path):
        counts["hub"] += sum(len(HUB_PROPERTY.findall(line)) for line in lines)
    if not is_root(path):
        counts["locator"] += sum(len(LOCATOR.findall(line)) for line in lines)
    counts["forwarder"] += forwarders("\n".join(lines))


def read_budget(path):
    if not path.is_file():
        print(f"Budget file not found: {path}", file=sys.stderr)
        raise SystemExit(66)
    value = path.read_text().strip()
    if not value.isdigit():
        print(f"Budget file is not a whole number: {path}", file=sys.stderr)
        raise SystemExit(65)
    return int(value)


labels = {
    "hub": "hub back-references",
    "locator": "AppDependencies.current reads",
    "forwarder": "pass-through forwarders",
}
failed = False
for key, label in labels.items():
    budget = read_budget(budget_files[key])
    count = counts[key]
    print(f"- {label}: {count} (budget: {budget}; ratchet toward 0)")
    if count > budget:
        print(f"  FAIL: {label} rose above {budget_files[key]}. Pass the part what it uses instead.", file=sys.stderr)
        failed = True
    elif count < budget:
        print(f"  FAIL (slack): lower {budget_files[key]} to {count} in this change to lock the gain in.", file=sys.stderr)
        failed = True
raise SystemExit(1 if failed else 0)
PY
