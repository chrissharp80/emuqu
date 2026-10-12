#!/usr/bin/env bash
# Creates .venv-codemap with the pinned, hash-checked tree-sitter wheels
# (scripts/codemap/requirements.txt). `make codemap-setup` runs this when the
# venv is missing or cannot import them.
#
# tree-sitter 0.26 needs Python 3.10 or newer. macOS's own python3 (the Xcode
# command line tools') is 3.9, so the first python3 on PATH is not good
# enough: pip found no matching wheel and the setup failed. This takes the
# first interpreter that is 3.10+ (installing a pinned standalone one when
# there is none), and rebuilds a venv made by an older one.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Where Python 3.10+ is usually installed without being on PATH: Homebrew on
# Apple silicon and Intel, the python.org installer, pyenv.
installed_pythons() {
    local dir version
    for dir in /opt/homebrew/bin /usr/local/bin "${HOME:-}/.pyenv/shims"; do
        for version in 3.13 3.12 3.11 3.10; do
            echo "$dir/python$version"
        done
    done
    for version in 3.13 3.12 3.11 3.10; do
        echo "/Library/Frameworks/Python.framework/Versions/$version/bin/python3"
    done
}

python_for_codemap() {
    local candidate
    for candidate in "${CODEMAP_BASE_PYTHON:-}" python3.13 python3.12 python3.11 python3.10 python3 $(installed_pythons); do
        [[ -n "$candidate" ]] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# With no Python 3.10+ installed, a standalone CPython 3.12.7 from
# python-build-standalone (the builds uv installs), pinned by release and
# SHA-256 (the release's own SHA256SUMS), unpacked into .codemap-python/.
STANDALONE_RELEASE="20241016"
STANDALONE_VERSION="3.12.7"
STANDALONE_DIR=".codemap-python"

standalone_sha256() {
    case "$1" in
        aarch64-apple-darwin) echo "4c18852bf9c1a11b56f21bcf0df1946f7e98ee43e9e4c0c5374b2b3765cf9508" ;;
        x86_64-apple-darwin) echo "60c5271e7edc3c2ab47440b7abf4ed50fbc693880b474f74f05768f5b657045a" ;;
        x86_64-unknown-linux-gnu) echo "43576f7db1033dd57b900307f09c2e86f371152ac8a2607133afa51cbfc36064" ;;
        aarch64-unknown-linux-gnu) echo "bba3c6be6153f715f2941da34f3a6a69c2d0035c9c5396bc5bb68c6d2bd1065a" ;;
        *) return 1 ;;
    esac
}

standalone_platform() {
    local arch os
    case "$(uname -m)" in
        arm64 | aarch64) arch="aarch64" ;;
        x86_64) arch="x86_64" ;;
        *) return 1 ;;
    esac
    case "$(uname -s)" in
        Darwin) os="apple-darwin" ;;
        Linux) os="unknown-linux-gnu" ;;
        *) return 1 ;;
    esac
    echo "$arch-$os"
}

file_sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# Prints the standalone interpreter, downloading and checking it first when it
# is not already unpacked. Returns 1 for a platform without a pinned build or a
# download whose checksum does not match.
standalone_python() {
    local interpreter="$STANDALONE_DIR/python/bin/python3"
    if [[ -x "$interpreter" ]]; then echo "$interpreter"; return 0; fi
    local platform expected archive url
    platform="$(standalone_platform)" || return 1
    expected="$(standalone_sha256 "$platform")" || return 1
    archive="$(mktemp "${TMPDIR:-/tmp}/codemap-python.XXXXXX")"
    url="https://github.com/astral-sh/python-build-standalone/releases/download/$STANDALONE_RELEASE/cpython-$STANDALONE_VERSION%2B$STANDALONE_RELEASE-$platform-install_only.tar.gz"
    echo "codemap-setup: no Python 3.10+ installed; fetching standalone CPython $STANDALONE_VERSION ($platform)" >&2
    if ! curl -fsSL --retry 3 -o "$archive" "$url"; then rm -f "$archive"; return 1; fi
    if [[ "$(file_sha256 "$archive")" != "$expected" ]]; then
        echo "codemap-setup: the downloaded Python's checksum does not match the pinned one; not using it." >&2
        rm -f "$archive"
        return 1
    fi
    rm -rf "$STANDALONE_DIR" && mkdir -p "$STANDALONE_DIR"
    if ! tar -xzf "$archive" -C "$STANDALONE_DIR" || [[ ! -x "$interpreter" ]]; then
        rm -rf "$STANDALONE_DIR" "$archive"
        return 1
    fi
    rm -f "$archive"
    echo "$interpreter"
}

if ! python="$(python_for_codemap)" && ! python="$(standalone_python)"; then
    echo "codemap-setup: the code map needs Python 3.10 or newer; none was found on PATH," >&2
    echo "  in Homebrew (/opt/homebrew, /usr/local), the python.org installer or pyenv," >&2
    echo "  and the pinned standalone build could not be fetched for this machine." >&2
    echo "  python3 here is $(python3 --version 2>&1 || echo 'missing'). Install one (e.g. brew install python@3.12)," >&2
    echo "  or point CODEMAP_BASE_PYTHON at it, then run make codemap-setup again." >&2
    exit 1
fi

"$python" -m venv --clear .venv-codemap
.venv-codemap/bin/python -m pip install --quiet --disable-pip-version-check --require-hashes -r scripts/codemap/requirements.txt
echo "codemap-setup: .venv-codemap ready ($("$python" --version 2>&1))"
