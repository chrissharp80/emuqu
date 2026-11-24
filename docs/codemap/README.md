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
| `units[].contract` | Optional. What callers may rely on: results, errors and effects, without the how. When present, callers are checked against it (with `entry` and `writes`) instead of the whole description. |
| `units[].entry` | What triggers it when app code does not call it directly (SwiftUI, a delegate, a notification, a timer, XCTest, CI). |
| `units[].calls` | Units it calls, as `path::key`, plus `ext:` framework calls and `dyn:` / `closure:` dispatch. |
| `units[].reads`, `writes` | Persistent or shared state the unit's own code touches, prefixed `ud:` `file:` `archive:` `hk:` `ck:` `kc:` `kvs:` `mem:` `notif:` `net:` `ble:` `wc:`. Not the state it reaches through its callees: those list their own, and `impact` shows the whole reach. |
| `units[].delegates` | Optional. The units it only runs or forwards to (a Makefile target that runs one script, a workflow step that runs one target, a forwarder). Such a record states nothing about what they do, so it is not re-checked against them, and its callers are checked against them instead. |
| `units[].branches` | Every branch point, `at` as an offset from the unit's first line, with its condition and effect. |
| `hash` | Hash of the code the record was written against. |
| `deps` | For each unit it certainly calls: a hash of what that callee's record said when this record was last checked. Written by `stamp`. |

A record describes its own unit and nothing more: not what its callees do, not the state they
touch. Text copied from a callee goes wrong whenever the callee changes, and every copy then has
to be found and fixed.

Records name units, targets and files, never line numbers: a `file:line` citation goes wrong
with every edit above that line while the record's own code is unchanged, so nothing would flag it.
The check rejects a record that cites one.

`areas.json` assigns each file to a product area for the report. A new file takes the area of the
other files in its directory. `strings.json` is the key-by-key audit of the two string catalogs.

## The call graph

`scripts/codemap/graph.py` defines the graph, from two sources:

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

Certainty is decided on every unit a name could mean. Two filters then drop references that
cannot be what they look like, and they only ever remove edges: a property-style read on a
receiver of unknown or framework type (`x.name`) is not a call to a function that needs
arguments, and app code is never linked with a test target, so a match there is a name collision.

Each certain edge also records why it is certain (a recorded call, the caller's own type, a
typed receiver, a same-file or global function, a name that matches one unit, a protocol
requirement, build wiring), so how much each kind of resolution is worth can be measured.

Every command reads the graph from `scripts/codemap/index.py`, a persistent index in
`build/codemap-index.sqlite` (untracked; deleting it is safe) that is brought up to date before each
command and re-reads only what changed since. A file whose size or modification time changed is
parsed again; its references are resolved again, and so are those of every file that refers to a
name whose units were added, removed or re-signed, or to a type whose conformances changed. A
changed record replaces only its own calls and stores. The code that builds the graph from
scratch, `graph.build`, is the definition: `.venv-codemap/bin/python scripts/codemap/index.py
--verify` compares the two and fails if they differ. With the index current, `impact` on one unit
takes well under a second; editing a file costs about half a second more; a cold build (a fresh
checkout, or after any change to the code map's own code) about 25 seconds.

Certain edges drive the re-check rule below. Possible edges are listed by `impact` and the report,
so a change can be checked against them by hand.

## The CI check

`scripts/check_codemap.sh` (in `make ci`, `ci.yml`, `gates.yml` and the pre-commit hook) fails
when:

- a file or unit in scope has no record, or a record has no `role` / `does`;
- the code of a unit, or the code of a file outside its units, has changed since its record was
  stamped;
- a record exists for a unit or file that no longer does;
- **a callee changed what it does**: a unit's certain callee has a record that now says something
  different from when the unit was last checked, or the unit now resolves a call to a unit it was
  not checked against (a "re-check" line). The unit must be re-read. If its own behaviour changed
  too, its record changes, and its callers are sent back in turn, so a behaviour change is
  followed up the graph as far as it reaches. Test units are never sent back: a test is checked
  by running it, and its record is kept current with its own code only. A caller of a unit that
  `delegates` is checked against what it delegates to as well;
- a record names a callee that no longer exists;
- a record cites a line number (`file:line`);
- with the local findings overlay present, the number of open high- or medium-severity findings
  differs from its budget (below).

`codemap.py status` prints every problem without failing.
`codemap.py status --by-callee [BASE]` groups them by the callee that caused them and prints what
that callee's record says now and at `BASE` (default `origin/main`), so its callers are read
against one change. Each line is cleared by re-reading the unit and either stamping it (its record
was rewritten) or acknowledging it with `ack` (it was unaffected); see "Changing code".

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
checked against is the callee's `does`, `entry`, `writes` and branches; for a callee whose
record has a `contract`, it is the contract, `entry` and `writes` only. `reads` is never part of
it: a caller depends on what a callee returns and writes, not on what it reads to get there. Without a
contract, rewording a record sends its callers back, so change a record only when the behaviour
changed. With one, `does` and the branches can be corrected or reworded freely; change the
contract only when what callers get changes (a different result, error or effect), and that change
sends them back. Adding a contract to a record sends its callers back once.

What belongs in a contract is what a caller would break on: what is returned and when (including
nil, empty and failure), what is thrown, what is written or posted, and what must hold first. Log
text, timing details callers do not depend on, and how the result is computed stay in `does`. A
contract that leaves out something callers rely on stops them being sent back when it changes, so
when in doubt, put it in.

The check proves that each record was written after the last change to its code, and lists the
records whose callees have changed since. It cannot prove a record is right; that is the author's
and the reviewer's job.

## Impact

`make codemap-impact` (or `codemap.py impact --base <ref>`) answers "if I change this, what else
can break?" for every unit whose code differs from `<ref>` (default `origin/main`), or for units
named as `path::key`. It starts with the test suites to run, as `-only-testing:` arguments for
`xcodebuild`: first those that call the unit or a direct caller, then all of them. Then, for each
unit, nearest first:

1. what it promises (its contract, or what it does);
2. the code that calls it, certain and possible, why each certain edge is certain, and the part of
   each caller's record that names it (what the caller relies on);
3. the test suites that reach it through certain callers, with how many calls away;
4. the same code elsewhere: units whose code is at least 35% alike (4-token runs weighted by how
   rare they are in the repository), where a bug fixed in one is likely to be in the other;
5. shared state: for each store it writes, the units that read it; for each store it reads, the
   other units that write it; and how many stores its callees write;
6. the entry points (screens, actions, notifications, timers, launch) that reach it, nearest ten;
7. the doc sections that describe it, and how many describe its callers;
8. with the overlay present, the open findings on it and on its direct callers.

It follows calls, shared state and alike code. It does not see links that are neither: a type
decoded by Swift's synthesized `Codable` code, a SwiftUI binding, or a closure stored and run
later; those show as no callers.

`scripts/codemap/measure.py` measures it against the history: for every commit that changed 2 to
25 mapped units, how many of the other units the commit had to change `impact` of its code would
have named. Commits that bundle unrelated fixes count as misses, so the figure is a floor. At this
revision: 87% of the co-changed test suites and 36% of the co-changed code units.

On a pull request, `gates.yml` writes the same list to the job summary, even when the check
failed. `codemap.py callers <path::key>` lists one unit's direct callers.

## Changing code

1. Before changing a unit, run `make codemap-impact` or `codemap.py impact <path::key>` and read the
   unit's promise, its callers and what each relies on, the same code elsewhere, the shared state,
   and (with the overlay) the open findings. Those are the paths the change has to keep working;
   run the test suites it lists.
2. Make the change, including whatever the impact list shows the callers need.
3. `make codemap-guard` lists every record the change affects.
4. For a moved or renamed file, or a renamed unit, run `codemap.py move <old path> <new path>
   [OLDKEY=NEWKEY ...]` before `sync` (the same path twice for a rename in place). It carries the
   record across and rewrites every other record's `calls` and `deps` that name it, so callers are
   neither sent back nor left naming a unit that is gone.
5. For new or deleted units: `codemap.py sync <path>` adds records and drops the ones whose code is
   gone. A new unit in a test target starts prefilled from its code (a test's `///` comment, or its
   name as a sentence, and its XCTest trigger); read it against the test before stamping, as any
   record.
6. Re-read the code and rewrite each listed record so it describes the code as it now is: `does`,
   `contract` where the record has one, `entry`, `calls`, `reads`, `writes` and every branch. Keep
   it to the unit's own code: its own state, not its callees'; a unit that only runs or forwards
   to another says so and names it in `delegates`. With the overlay, delete the flags the change
   fixed and lower the matching `codemap_open_*.txt` budget.
7. For each "re-check" line, re-read that unit against the callee's new behaviour
   (`codemap.py status --by-callee` shows the callee's change with its callers). If the unit still
   behaves as its record says, acknowledge it: `codemap.py ack <callee> [<caller> ...]` clears the
   named callers' lines for that callee (every caller's, when none is named), and only those lines.
   If it does not, fix the unit or rewrite its record, which sends its own callers back, and stamp
   it.
8. Stamp each record once it is right, after its callees' records are written (a stamp records
   what the callees' records say at that moment, so a callee record rewritten later sends the
   caller back): `codemap.py stamp <path> [<key> ...]` (no key stamps the
   file-level record), or any number of records across files in one pass with
   `codemap.py stamp <path>::<key> <path>:: ...`. `stamp` refuses a record with an empty
   description, checks every target before writing any, and records the code hash and the callees'
   current descriptions. Stamping a unit clears every open re-check line on it, so stamp only a
   unit re-read against all of them; `ack` clears one callee's lines without touching the rest.
9. `make codemap-guard` is clean.

Run these with the interpreter `make codemap-setup` creates (`.venv-codemap/bin/python`); the
inventory needs tree-sitter, which needs Python 3.10 or newer. `scripts/codemap/setup_venv.sh`
picks `CODEMAP_BASE_PYTHON` when it is set and 3.10 or newer, else the first such interpreter on
PATH, then in Homebrew, the python.org installer or pyenv; with none installed it downloads a
pinned, checksum-verified
standalone CPython 3.12 into `.codemap-python/`. It rebuilds a venv an older interpreter made.

`stamp` and `ack` record hashes; they do not read anything. Stamping or acknowledging without
re-reading defeats the check, and review is the only thing that catches that.

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
