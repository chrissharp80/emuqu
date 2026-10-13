# Working in this repository

## The code map is part of every change

`docs/codemap/records/` holds a record for every function, initializer, computed property, script
function, Makefile target, workflow step and doc section: what it does, what triggers it, what it
calls, what state it reads and writes, and what each branch does. A call graph is built from those
records and from the code. CI (`scripts/check_codemap.sh`, in `gates.yml`, `ci.yml` and `make ci`)
and the pre-commit hook fail while any record is missing or older than its code, and list the
records that are older than a change in what one of their callees does.

Findings (`flags`) and the open-findings budgets are not in the public records. They live in a
local, untracked overlay, `do_not_ship/codemap/` (`flags/<path>.json`, `codemap_open_high.txt`,
`codemap_open_med.txt`). `codemap.py` merges it when present and writes flags only there; the
open-findings ratchet runs only where the overlay exists (the pre-commit hook and a local `make ci`).

Before you change code:

1. Run `.venv-codemap/bin/python scripts/codemap/codemap.py impact <path::key>` for each unit you
   will change (or `make codemap-impact` for the whole branch). Read the unit's record, its
   callers, the triggers and tests that reach it, the shared state it touches, and, with the
   overlay, the open findings. Every path it lists has to keep working.

When you change code:

2. Run `make codemap-guard` to list the records your change affects.
3. Run `.venv-codemap/bin/python scripts/codemap/codemap.py sync <path>` for files whose units
   were added or removed.
4. Re-read the changed code and rewrite each listed record so it describes the code as it now is:
   `does`, `entry`, `calls`, `reads`, `writes` and every branch. With the overlay, remove flags the
   change fixed and add any problem you find. Public records describe behaviour only; keep defect
   notes out of them.
5. For each "re-check" line your change adds (`codemap.py status` lists them), re-read that caller
   against the callee's new behaviour. If the caller no longer does what its record says, fix the
   caller or rewrite its record.
6. Only then stamp, callees before callers:
   `.venv-codemap/bin/python scripts/codemap/codemap.py stamp <path> [<key> ...]`.
7. `make codemap-guard` must be clean before you commit.

High- and medium-severity findings can only go down. When you fix one, delete its flag and lower
`do_not_ship/codemap/codemap_open_high.txt` or `codemap_open_med.txt` by the same amount. Do not
record a new high or medium problem as open; fix it.

Never stamp a record you have not rewritten against the current code, and never stamp a re-check
you have not re-read. A stamp without a re-read defeats the check and leaves a wrong record that
reads as verified. Do not reword a record whose behaviour did not change: it sends every caller
back for a re-check. The full procedure is in `docs/codemap/README.md`.
