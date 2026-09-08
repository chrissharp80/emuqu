#!/usr/bin/env python3
"""
Remove a Swift file from the Xcode project (Emuqu.xcodeproj).

The inverse of add_swift_file.py. Deleting a source file that carries explicit
build-file membership means removing four entries from project.pbxproj:

1. The PBXBuildFile line
2. The PBXFileReference line
3. The file's entry in its PBXGroup children list
4. The file's entry in the PBXSourcesBuildPhase files list

Leaving any of them behind either breaks the build ("Build input file cannot be
found") or leaves a dangling reference Xcode shows in red. Doing it by hand is
why three dead protocol files in this repo were left as empty "tombstones"
rather than removed — this script exists so that is no longer the trade-off.

Usage:
    python3 scripts/remove_swift_file.py <relative_path_to_swift_file> [...]

The file itself is NOT deleted from disk; remove it with `rm` afterwards, or
pass --delete to do both.
"""

import os
import re
import sys

PROJECT = "Emuqu.xcodeproj/project.pbxproj"


def remove_file(content: str, filename: str) -> tuple[str, list[str]]:
    """Strip every pbxproj entry for `filename`. Returns (content, notes)."""
    notes = []

    # 1. PBXBuildFile: `<id> /* name in Sources */ = {isa = PBXBuildFile; fileRef = <ref> ...};`
    build_file_ids = re.findall(
        r"^\s*([A-Z0-9]+) /\* " + re.escape(filename) + r" in Sources \*/ = \{isa = PBXBuildFile.*$",
        content,
        re.MULTILINE,
    )
    content, n = re.subn(
        r"^\s*[A-Z0-9]+ /\* " + re.escape(filename) + r" in Sources \*/ = \{isa = PBXBuildFile.*\n",
        "",
        content,
        flags=re.MULTILINE,
    )
    notes.append(f"PBXBuildFile entries removed: {n}")

    # 2. PBXFileReference
    content, n = re.subn(
        r"^\s*[A-Z0-9]+ /\* " + re.escape(filename) + r" \*/ = \{isa = PBXFileReference.*\n",
        "",
        content,
        flags=re.MULTILINE,
    )
    notes.append(f"PBXFileReference entries removed: {n}")

    # 3. Group children — `<id> /* name */,`
    content, n = re.subn(
        r"^\s*[A-Z0-9]+ /\* " + re.escape(filename) + r" \*/,\n",
        "",
        content,
        flags=re.MULTILINE,
    )
    notes.append(f"Group child entries removed: {n}")

    # 4. Sources build phase — `<id> /* name in Sources */,`
    content, n = re.subn(
        r"^\s*[A-Z0-9]+ /\* " + re.escape(filename) + r" in Sources \*/,\n",
        "",
        content,
        flags=re.MULTILINE,
    )
    notes.append(f"Sources build-phase entries removed: {n}")

    if build_file_ids:
        notes.append(f"(build file ids: {', '.join(build_file_ids)})")
    return content, notes


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--delete"]
    also_delete = "--delete" in sys.argv[1:]
    if not args:
        print(__doc__)
        return 2

    if not os.path.exists(PROJECT):
        print(f"error: {PROJECT} not found — run from the repo root", file=sys.stderr)
        return 1

    with open(PROJECT, encoding="utf-8") as handle:
        content = handle.read()

    for path in args:
        filename = os.path.basename(path)
        if filename not in content:
            print(f"warning: {filename} not referenced in project.pbxproj")
        content, notes = remove_file(content, filename)
        print(f"{filename}:")
        for note in notes:
            print(f"  {note}")
        if also_delete and os.path.exists(path):
            os.remove(path)
            print(f"  deleted from disk: {path}")

    with open(PROJECT, "w", encoding="utf-8") as handle:
        handle.write(content)
    print("project.pbxproj updated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
