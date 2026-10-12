#!/usr/bin/env bash
# Creates .venv-codemap with the pinned, hash-checked tree-sitter wheels
# (scripts/codemap/requirements.txt). `make codemap-setup` runs this when the
# venv is missing or cannot import them.
#
# tree-sitter 0.26 needs Python 3.10 or newer. macOS's own python3 (the Xcode
# command line tools') is 3.9, so the first python3 on PATH is not good
# enough: pip found no matching wheel and the setup failed. This takes the
# first interpreter that is 3.10+, and rebuilds a venv made by an older one.
set -euo pipefail
cd "$(dirname "$0")/../.."

python_for_codemap() {
    local candidate
    for candidate in "${CODEMAP_BASE_PYTHON:-}" python3.13 python3.12 python3.11 python3.10 python3; do
        [[ -n "$candidate" ]] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if ! python="$(python_for_codemap)"; then
    echo "codemap-setup: the code map needs Python 3.10 or newer; none was found on PATH." >&2
    echo "  python3 here is $(python3 --version 2>&1 || echo 'missing'). Install one (e.g. brew install python@3.12)," >&2
    echo "  or point CODEMAP_BASE_PYTHON at it, then run make codemap-setup again." >&2
    exit 1
fi

"$python" -m venv --clear .venv-codemap
.venv-codemap/bin/python -m pip install --quiet --disable-pip-version-check --require-hashes -r scripts/codemap/requirements.txt
echo "codemap-setup: .venv-codemap ready ($("$python" --version 2>&1))"
