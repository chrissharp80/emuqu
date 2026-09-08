# shellcheck shell=bash
#
# Shared preflight for verification gates. Source it, do not execute it:
#
#     source "$(dirname "$0")/lib/preflight.sh"
#     log="$(gate_mktemp gate-name)" || exit $?
#
# The `|| exit $?` is LOAD-BEARING and not optional. `gate_mktemp` runs inside
# command substitution, which is a subshell — an `exit` inside it terminates
# only that subshell, so without the guard the caller sails on with an empty
# path and reports clean anyway. That is the identical failure this helper
# exists to prevent.
# `check_gate_preflight.sh` fails the build if a call site omits the guard.
#
# ## Why this exists
#
# Run with an invalid `TMPDIR`, a gate such as `check_unchecked_sendable.sh`
# or `check_log_redaction.sh` reports **clean, exit 0**: it prints a setup
# error, measures nothing, and announces success. The same shape is available
# in every gate that calls `mktemp`.
#
# The mechanism is `set -uo pipefail` without `-e`: `mktemp` fails, the variable
# is empty, the redirect into it fails, and execution simply continues. `grep`
# over a file that was never written finds nothing, and "nothing found" is
# exactly what these gates report as success.
#
# That is a verification tool failing OPEN, which is worse than having no gate:
# a green check is read as evidence, and a broken runner or a full disk turns it
# into a lie. Everything in this repository ratchets on the assumption that
# these numbers are real.
#
# `-e` is deliberately NOT set globally here. Several gates rely on `grep`
# exiting non-zero when it matches nothing, and flipping that on would trade a
# false-green for a false-red. The narrow fix is to make the one operation that
# silently produces the false green — temp-file creation — impossible to get
# wrong.

# Fail loudly if a temp file cannot be created. Prints the reason to stderr and
# exits non-zero rather than returning an empty path.
gate_mktemp() {
    local label="${1:-gate}"
    local path
    # Explicit template, not `mktemp -t label`: BSD mktemp treats `-t` as a
    # prefix, GNU mktemp requires X's in the template and fails on the same
    # call, which is exactly the fail-open shape this helper guards against.
    if ! path="$(mktemp "${TMPDIR:-/tmp}/${label}.XXXXXX" 2>/dev/null)" || [[ -z "$path" ]]; then
        echo "FATAL: could not create a temporary file (label: ${label})." >&2
        echo "  TMPDIR=${TMPDIR:-<unset>}" >&2
        echo "  A verification gate cannot report a result it did not measure," >&2
        echo "  so this exits non-zero rather than continuing and printing 'clean'." >&2
        exit 70   # EX_OSERR
    fi
    if [[ ! -w "$path" ]]; then
        echo "FATAL: temporary file ${path} is not writable (label: ${label})." >&2
        exit 70
    fi
    printf '%s' "$path"
}

# Assert a file exists and is non-empty before a gate draws conclusions from it.
# Use after producing a log or report that the measurement then parses.
gate_require_nonempty() {
    local path="$1" what="${2:-input}"
    if [[ ! -s "$path" ]]; then
        echo "FATAL: ${what} is missing or empty (${path})." >&2
        echo "  Reporting 'clean' from an empty measurement would be a false green." >&2
        exit 70
    fi
}

# Directory variant of `gate_mktemp`, same contract and same requirement:
#     dir="$(gate_mktemp_dir label)" || exit $?
gate_mktemp_dir() {
    local label="${1:-gate}"
    local path
    if ! path="$(mktemp -d -t "$label" 2>/dev/null)" || [[ ! -d "$path" ]]; then
        echo "FATAL: could not create a temporary directory (label: ${label})." >&2
        echo "  TMPDIR=${TMPDIR:-<unset>}" >&2
        exit 70
    fi
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Working-tree mutation lock.
#
# `verify_gates_fail.sh` and `verify_tests_fail.sh` both edit tracked source in
# place and restore it in an EXIT trap. Two consequences:
#
#   * A killed run skips the trap, and the mutation stays applied. That is how
#     a pNN50 threshold of 75 ms instead of 50 ships;
#     `check_no_leaked_mutations.sh` exists as the backstop.
#   * Anything else that reads the tree WHILE one of them runs sees the planted
#     violation as if it were real: `make ci-local` fails on a planted
#     `WrongDir/EmuquApp.swift` citation or a planted privacy-manifest type
#     that is restored moments later — a red run about nothing, which on a
#     hosted macOS runner is billed at 10x for the privilege.
#
# One lock, held by whoever is mutating, checked by whoever is measuring.
# `mkdir` is the atomic primitive; a lock whose owner PID is gone is stale and
# gets taken over rather than blocking forever.
# ---------------------------------------------------------------------------

# In a linked worktree or a submodule, `.git` is a FILE pointing elsewhere, so
# `mkdir .git/<lock>` would fail and every run would abort on a setup problem
# rather than a real one. Ask git where its directory actually is, and fall back
# to a temp path if this is somehow not a repository at all.
_gate_git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
GATE_TREE_LOCK="${GATE_TREE_LOCK:-${_gate_git_dir:-${TMPDIR:-/tmp}}/emuqu-tree-mutation.lock}"

# Take the lock, or exit non-zero explaining who holds it.
#     gate_acquire_tree_lock "verify_gates_fail"
#     trap 'gate_release_tree_lock' EXIT INT TERM HUP
gate_acquire_tree_lock() {
    local owner="${1:-unknown}"
    if ! mkdir "$GATE_TREE_LOCK" 2>/dev/null; then
        local held_by held_pid
        held_by="$(cat "$GATE_TREE_LOCK/owner" 2>/dev/null || echo unknown)"
        held_pid="$(cat "$GATE_TREE_LOCK/pid" 2>/dev/null || echo 0)"
        if [[ "$held_pid" != "0" ]] && kill -0 "$held_pid" 2>/dev/null; then
            echo "FATAL: ${held_by} (pid ${held_pid}) is mutating the working tree." >&2
            echo "  Running now would measure ITS planted violations as if they were" >&2
            echo "  yours. Wait for it to finish, then re-run." >&2
            exit 75   # EX_TEMPFAIL
        fi
        # The holder is gone. Its restore never ran, so say so — the tree may
        # still carry a planted edit.
        echo "WARNING: stale lock from ${held_by} (pid ${held_pid}); taking it over." >&2
        echo "  That run was killed before it could restore. Check the tree with" >&2
        echo "  ./scripts/check_no_leaked_mutations.sh and \`git diff\`." >&2
        rm -rf "$GATE_TREE_LOCK"
        mkdir "$GATE_TREE_LOCK" 2>/dev/null || {
            echo "FATAL: could not take the tree lock at ${GATE_TREE_LOCK}." >&2
            exit 70
        }
    fi
    printf '%s' "$owner" > "$GATE_TREE_LOCK/owner"
    printf '%s' "$$" > "$GATE_TREE_LOCK/pid"
}

gate_release_tree_lock() {
    [[ -d "$GATE_TREE_LOCK" ]] && rm -rf "$GATE_TREE_LOCK"
    return 0
}

# For readers: refuse to draw conclusions from a tree someone else is editing.
gate_require_unmutated_tree() {
    local who="${1:-this check}"
    [[ -d "$GATE_TREE_LOCK" ]] || return 0
    local held_by held_pid
    held_by="$(cat "$GATE_TREE_LOCK/owner" 2>/dev/null || echo unknown)"
    held_pid="$(cat "$GATE_TREE_LOCK/pid" 2>/dev/null || echo 0)"
    if [[ "$held_pid" != "0" ]] && kill -0 "$held_pid" 2>/dev/null; then
        echo "FATAL: ${who} cannot run — ${held_by} (pid ${held_pid}) is mutating" >&2
        echo "  the working tree right now. Its planted violations would be read as" >&2
        echo "  real findings. Wait for it to finish." >&2
        exit 75
    fi
    echo "WARNING: stale mutation lock from ${held_by}; that run never restored." >&2
    echo "  Run ./scripts/check_no_leaked_mutations.sh before trusting this result." >&2
    rm -rf "$GATE_TREE_LOCK"
    return 0
}
