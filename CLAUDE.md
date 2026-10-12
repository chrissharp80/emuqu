# Working in this repository

## The code map is part of every change

`docs/codemap/records/` holds a record for every function, initializer, computed property, script
function, Makefile target, workflow step and doc section: what it does, what triggers it, what it
calls, what state it reads and writes, what each branch does, and known problems. A call graph is
built from those records and from the code. CI (`scripts/check_codemap.sh`, in `gates.yml`,
`ci.yml` and `make ci`) and the pre-commit hook fail while any record is missing or older than its
code, and list the records that are older than a change in what one of their callees does.

Before you change code:

1. Run `.venv-codemap/bin/python scripts/codemap/codemap.py impact <path::key>` for each unit you
   will change (or `make codemap-impact` for the whole branch). Read the unit's record, its
   callers, the triggers and tests that reach it, the shared state it touches, and the open
   findings. Every path it lists has to keep working.

When you change code:

2. Run `make codemap-guard` to list the records your change affects.
3. Run `.venv-codemap/bin/python scripts/codemap/codemap.py sync <path>` for files whose units
   were added or removed.
4. Re-read the changed code and rewrite each listed record so it describes the code as it now is:
   `does`, `entry`, `calls`, `reads`, `writes`, every branch, and flags. Remove flags the change
   fixed; add any problem you find.
5. For each "re-check" line your change adds (`codemap.py status` lists them), re-read that caller against the callee's new behaviour. If the caller
   no longer does what its record says, fix the caller or rewrite its record.
6. Only then stamp, callees before callers:
   `.venv-codemap/bin/python scripts/codemap/codemap.py stamp <path> [<key> ...]`.
7. `make codemap-guard` must be clean before you commit.

High- and medium-severity findings can only go down. When you fix one, delete its flag and lower
`.ci/codemap_open_high.txt` or `.ci/codemap_open_med.txt` by the same amount in the same change.
Do not record a new high or medium problem as open; fix it.

Never stamp a record you have not rewritten against the current code, and never stamp a re-check
you have not re-read. A stamp without a re-read defeats the check and leaves a wrong record that
reads as verified. Do not reword a record whose behaviour did not change: it sends every caller
back for a re-check. The full procedure is in `docs/codemap/README.md`.
