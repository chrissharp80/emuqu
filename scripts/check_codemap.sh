#!/usr/bin/env bash
#
# CI guard: the code map is current.
#
# docs/codemap/records holds one record per source file and per unit (function, initializer,
# computed property, script function, Makefile target, workflow step, doc section): what it does,
# what calls it, what it calls, what state it reads and writes, what each branch does. Each record
# stores a hash of the code it describes and of what each certain callee's record said. This gate
# fails when a unit or file has no record, a record says nothing, a record is older than its code,
# a callee now describes different behaviour than when the caller was checked (re-check), a record
# names a callee that no longer exists, or the open high/medium findings differ from their
# budgets in .ci/. It cannot tell whether a description is right; it proves only that someone
# wrote it after the last change to the code and to what the code calls.
#
# The inventory needs tree-sitter. `make codemap-setup` installs the pinned, hash-checked wheels
# into .venv-codemap; CODEMAP_PYTHON points this script at that interpreter. Without tree-sitter
# the gate fails rather than skipping, so a missing install cannot read as clean.
#
# How to bring a record up to date: docs/codemap/README.md.
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${CODEMAP_PYTHON:-python3}"

if ! "$PY" -c "import tree_sitter, tree_sitter_swift" 2>/dev/null; then
    echo "check_codemap: tree-sitter is not installed for $PY." >&2
    echo "  Run: make codemap-setup   (then CODEMAP_PYTHON=.venv-codemap/bin/python)" >&2
    exit 2
fi

exec "$PY" scripts/codemap/codemap.py check
