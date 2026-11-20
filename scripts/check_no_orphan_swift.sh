#!/usr/bin/env bash
set -euo pipefail

# Every Swift file on disk must be a member of a build target.
#
# A file of purely additive code that is in no target vanishes from the build
# with no error at all. This checks that every `.swift` under the source roots
# is referenced by project.pbxproj.

# The project file and the roots are relative: from any other directory the
# roots would hold no files and the gate would report clean.
cd "$(dirname "$0")/.."

PROJECT="${1:-Emuqu.xcodeproj/project.pbxproj}"

# The roots are every directory that carries first-party Swift, test targets
# and the watch app included.
SOURCE_ROOTS=("${@:2}")
if (( ${#SOURCE_ROOTS[@]} == 0 )); then
    SOURCE_ROOTS=("Emuqu" "EmuquTests" "EmuquUITests" "EmuquWatch Watch App")
fi

if [[ ! -f "$PROJECT" ]]; then
    echo "check_no_orphan_swift: project file not found: $PROJECT" >&2
    exit 2
fi
for root in "${SOURCE_ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
        echo "check_no_orphan_swift: source root not found: $root" >&2
        exit 2
    fi
done

# Membership is resolved by PATH, through the project's group tree, and only a
# reference that a Sources build phase compiles counts. Matching a basename in
# a comment anywhere in the file passed a file whose PBXFileReference exists
# but is in no Sources phase, and a file that merely shares a name with a
# registered one.
#
# A folder registered as a PBXFileSystemSynchronizedRootGroup (Xcode 16+
# "synchronised" group) includes its contents BY BEING ON DISK — individual
# files are deliberately not listed, and `membershipExceptions` is the only way
# to remove one. Those files are counted as covered, and the count is printed
# so the exemption is visible rather than silent.
#
# No file may be in the SAME Sources phase twice. A duplicate row does not
# fail loudly: it fails as "Multiple commands produce .../Foo.stringsdata",
# which reads like a build-system problem rather than a project-file problem.
# A file compiled into two different targets is listed once in each phase and
# is not a duplicate.
python3 - "$PROJECT" "${SOURCE_ROOTS[@]}" <<'PY'
import pathlib
import re
import sys

project_path, roots = sys.argv[1], sys.argv[2:]
text = pathlib.Path(project_path).read_text(encoding="utf-8")

OBJECT = re.compile(r"(\w+) /\* (.*?) \*/ = \{")


def objects():
    """id -> body text of every object in the project, braces matched."""
    found = {}
    for m in OBJECT.finditer(text):
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        found.setdefault(m.group(1), text[m.end():i])
    return found


def prop(body, name):
    m = re.search(rf"\b{name} = (\"(?:[^\"\\]|\\.)*\"|[^;]+);", body)
    return m.group(1).strip().strip('"') if m else None


def ids(body, name):
    m = re.search(rf"\b{name} = \((.*?)\);", body, re.S)
    return re.findall(r"(\w+) /\*", m.group(1)) if m else []


objs = objects()
isa = {k: prop(v, "isa") for k, v in objs.items()}
parent = {}
for gid, body in objs.items():
    if isa[gid] in ("PBXGroup", "PBXVariantGroup"):
        for child in ids(body, "children"):
            parent[child] = gid


def full_path(oid):
    body = objs[oid]
    path = prop(body, "path") or ""
    tree = prop(body, "sourceTree")
    if tree == "SOURCE_ROOT" or oid not in parent:
        return path
    base = full_path(parent[oid])
    return f"{base}/{path}" if base and path else (base or path)


compiled, duplicates = set(), []
for phase_id, kind in isa.items():
    if kind != "PBXSourcesBuildPhase":
        continue
    seen = set()
    for build_file in ids(objs[phase_id], "files"):
        ref = prop(objs.get(build_file, ""), "fileRef")
        ref = ref.split()[0] if ref else None
        if not ref or ref not in objs:
            continue
        path = full_path(ref)
        if path in seen:
            duplicates.append(path)
        seen.add(path)
        compiled.add(path)

synced_roots = sorted(full_path(k) for k, v in isa.items() if v == "PBXFileSystemSynchronizedRootGroup")

missing, scanned, synced = [], 0, 0
for root in roots:
    for file in sorted(pathlib.Path(root).rglob("*.swift")):
        scanned += 1
        rel = file.as_posix()
        if any(rel.startswith(r + "/") for r in synced_roots):
            synced += 1
        elif rel not in compiled:
            missing.append(rel)

if scanned == 0:
    print(f"check_no_orphan_swift: no Swift files under {' '.join(roots)}.", file=sys.stderr)
    sys.exit(2)
if not compiled:
    print(f"check_no_orphan_swift: no Sources build phase lists a file in {project_path}.", file=sys.stderr)
    sys.exit(2)

if missing:
    print("ERROR: Swift files on disk but not compiled by any target's Sources phase:", file=sys.stderr)
    for f in missing:
        print(f"  - {f}", file=sys.stderr)
    print("\nAdd them with scripts/add_swift_file.py, or delete them.", file=sys.stderr)
    sys.exit(1)

if duplicates:
    print("ERROR: Swift files listed more than once in the same Sources build phase:", file=sys.stderr)
    for f in sorted(set(duplicates)):
        print(f"  - {f}", file=sys.stderr)
    print("\nXcode reports this as 'Multiple commands produce ... .stringsdata'.", file=sys.stderr)
    print("Remove the duplicate PBXBuildFile row and its PBXFileReference.", file=sys.stderr)
    sys.exit(1)

print(f"check_no_orphan_swift: clean. {scanned} Swift files under {' '.join(roots)} are in a target, none twice in one.")
if synced:
    print(f"check_no_orphan_swift: {synced} of those are covered by a synchronised root group "
          f"({', '.join(synced_roots)}) rather than an explicit reference.")
PY
