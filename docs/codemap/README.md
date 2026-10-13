# Code map

One record for every unit of code in this repository, a call graph over all of them, and CI rules
that keep both in step with the code.

A unit is a Swift function, initializer, deinitializer, subscript, computed property, observed
property, closure-initialised stored property or protocol requirement; a Python `def`; a shell
function; a C or Objective-C function; a `Makefile` target; a workflow job or step; or a Markdown
heading section. Every tracked file except images, PDFs, snapshot `.raw` files, `LICENSE` and the
two large string catalogs also has a file-level record.

## What a record holds

`records/<path>.json` holds the record for `<path>`:

| Field | Meaning |
| --- | --- |
| `role`, `types`, `state`, `toplevel` | What the file is for, the types it declares, the stored state it declares, and what any code outside the units does. |
| `units[].key` | Stable name of the unit: kind, enclosing type, name and argument labels, e.g. `func HRVSession.isValidForAnalysis(minimumBeats:)`. Overloads that share labels add parameter types; identical signatures add `#2`. A unit's full name is `<path>::<key>`; a file's top-level code is `<path>::`. |
| `units[].does` | What the unit does, concretely. |
| `units[].entry` | What triggers it when app code does not call it directly (SwiftUI, a delegate, a notification, a timer, XCTest, CI). |
| `units[].calls` | Units it calls, as `path::key`, plus `ext:` framework calls and `dyn:` / `closure:` dispatch. |
| `units[].reads`, `writes` | Persistent or shared state, prefixed `ud:` `file:` `archive:` `hk:` `ck:` `kc:` `kvs:` `mem:` `notif:` `net:` `ble:` `wc:`. |
| `units[].branches` | Every branch point, `at` as an offset from the unit's first line, with its condition and effect. |
| `hash` | Hash of the code the record was written against. |
| `deps` | For each unit it certainly calls: a hash of what that callee's record said when this record was last checked. Written by `stamp`. |

`areas.json` assigns each file to a product area for the report. A new file takes the area of the
other files in its directory. `strings.json` is the key-by-key audit of the two string catalogs.

## The call graph

`scripts/codemap/graph.py` builds the graph every time it is needed, from two sources:

- the calls each record names (a reader resolved these, including dispatch through protocols and
  stored closures that the code alone does not show), and
- the code itself, parsed with tree-sitter: every call with its argument labels, every property
  read, every bare reference to a function or property, every closure assigned to a stored
  property, every protocol requirement's implementations, each Makefile prerequisite and recipe
  line, each workflow step's `make` targets and scripts, and Python and shell calls.

An edge is **certain** when the reference can only mean one unit: a call on `self`, `super`, an
implicit self or a named repo type that matches one unit of that type (its extensions,
superclasses and protocols included); a free call matching one global function; a member name and
label set that matches one unit in the whole repository and is not a common library name; a
recorded call; a protocol requirement to each implementation; build wiring. An edge is
**possible** when the name matches several units and nothing narrows it: there is no type checker
here, so `x.load()` on a variable of unknown type is a possible call to every `load()` in the repo.

Certain edges drive the re-check rule below. Possible edges are listed by `impact` and the report,
so a change can be checked against them by hand.

## The CI check

`scripts/check_codemap.sh` (in `make ci`, `ci.yml`, `gates.yml` and the pre-commit hook) fails
when:

- a file or unit in scope has no record, or a record has no `role` / `does`;
- the code of a unit, or the code of a file outside its units, has changed since its record was
  stamped;
- a record exists for a unit or file that no longer does;
- with the local findings overlay present, the number of open high- or medium-severity findings
  differs from its budget (below).

It also lists, without failing, the records to re-check:

- **a callee changed what it does**: a unit's certain callee has a record that now says something
  different from when the unit was last checked, or the unit now resolves a call to a unit it was
  not checked against. The unit must be re-read. If its own behaviour changed too, its record
  changes, and its callers are listed in turn, so a behaviour change is followed up the graph as
  far as it reaches;
- a record names a callee that no longer exists.

`codemap.py status` prints every re-check line; `check` prints only how many there are. Each one
is cleared by re-reading the unit and stamping it (see "Changing code").

Findings are kept out of the public records. Each record's `flags` (kind, severity, text and
evidence of a problem found) live in a local, untracked overlay, `do_not_ship/codemap/flags/<path>.json`
(`{"file": [...], "units": {key: [...]}}`; `$CODEMAP_OVERLAY` points elsewhere). `codemap.py`
merges the overlay into each record it loads and writes flags only to it. Where the overlay exists,
the open-findings ratchet runs too: `do_not_ship/codemap/codemap_open_high.txt` and
`codemap_open_med.txt` hold the number of open high- and medium-severity flags, and the check fails
unless the overlay contains exactly that many. A change that adds a high or medium flag fails; a
change that fixes one removes its flag and lowers the budget by the same amount. Without the
overlay (a public clone, GitHub Actions) the ratchet does not run.

The code hash leaves out whole-line comments and the lines of units nested inside a unit, so
editing a comment or a nested function does not make the outer record stale. What a caller is
checked against is the callee's `does`, `entry`, `reads`, `writes` and branches: rewording
a record therefore sends its callers back, so change a record only when the behaviour changed.

The check proves that each record was written after the last change to its code, and lists the
records whose callees have changed since. It cannot prove a record is right; that is the author's
and the reviewer's job.

## Impact

`make codemap-impact` (or `codemap.py impact --base <ref>`) lists, for every unit whose code
differs from `<ref>` (default `origin/main`), or for units named as `path::key`:

- what the unit does (from its record);
- its direct callers, certain and possible;
- the units with an outside trigger (screens, actions, notifications, timers, launch) that reach
  it through certain callers;
- the tests and doc sections that reach it;
- the shared state it reads and writes, and every other unit that reads or writes the same state;
- with the overlay present, the open findings on it and on its direct callers.

On a pull request, `gates.yml` writes the same list to the job summary, even when the check
failed. `codemap.py callers <path::key>` lists one unit's direct callers.

## Changing code

1. Before changing a unit, run `make codemap-impact` or `codemap.py impact <path::key>` and read the
   unit's record, its callers, the triggers and tests that reach it, the shared state, and (with the
   overlay) the open findings. Those are the paths the change has to keep working.
2. Make the change, including whatever the impact list shows the callers need.
3. `make codemap-guard` lists every record the change affects.
4. For new or deleted units: `codemap.py sync <path>` adds empty records and drops the ones whose
   code is gone.
5. Re-read the code and rewrite each listed record so it describes the code as it now is: `does`,
   `entry`, `calls`, `reads`, `writes` and every branch. With the overlay, delete the flags the
   change fixed and lower the matching `codemap_open_*.txt` budget.
6. For each "re-check" line, re-read that unit against the callee's new behaviour. If the unit
   still behaves as its record says, stamp it unchanged. If it does not, fix the unit or rewrite its
   record, which sends its own callers back.
7. Stamp each record once it is right, callees before callers:
   `codemap.py stamp <path> [<key> ...]` (no key stamps the file-level record). `stamp` refuses a
   record with an empty description and records the code hash and the callees' current
   descriptions. Stamping a caller before its callee leaves it to be re-checked again.
8. `make codemap-guard` is clean.

Run these with the interpreter `make codemap-setup` creates (`.venv-codemap/bin/python`); the
inventory needs tree-sitter, which needs Python 3.10 or newer. `scripts/codemap/setup_venv.sh`
picks the first such interpreter on PATH, then in Homebrew, the python.org installer or pyenv
(or `CODEMAP_BASE_PYTHON`); with none installed it downloads a pinned, checksum-verified
standalone CPython 3.12 into `.codemap-python/`. It rebuilds a venv an older interpreter made.

`stamp` records hashes; it does not read anything. Stamping without re-reading defeats the check,
and review is the only thing that catches that.

## The report

`make codemap-report` builds a browsable report in `build/codemap`: the whole-app and per-area
call flowcharts, every finding in the local overlay with filters, every unit with its certain and possible callers and
its callees, unreachable code, shared state written from more than one area, and the
string-catalog audit. Serve it with `python3 -m http.server -d build/codemap` and open the printed
address; it loads its data with relative fetches, so opening the file directly does not work.

## Where the records came from

The first full set was written against main at `8d32097`: one reader went through every line of
every file and wrote a record per unit, and a second reader re-checked every record against the
code. Doc sections were then linked to the code that implements them. The `deps` of those records
were set from the graph at the same time.
