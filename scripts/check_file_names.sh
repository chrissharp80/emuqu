#!/usr/bin/env bash
set -euo pipefail

# A `Type+Part.swift` file extends `Type`.
#
# Splitting a type into `Type+Part.swift` files is the convention in
# docs/MAINTAINERS.md. When a part becomes a type of its own, the file can keep
# the old owner's name: `PolarManager+Recording.swift` holding
# `extension StrapRecordingCoordinator`. The name then says the code still
# belongs to the old owner, and a reader looking for the type does not find it.
#
# Every tracked Swift file whose name has a `+` must extend, or declare, the
# type named before the `+` (or a type nested in it, or a nested type of that
# name), and
# nothing else: a second type gets a file of its own. `Notification.Name`
# extensions are allowed alongside, since a notification sits with the type
# that posts it.

cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import pathlib
import re
import subprocess
import sys

roots = sys.argv[1:] or None
listed = subprocess.run(["git", "ls-files", "*.swift"], capture_output=True, text=True, check=True).stdout.split("\n")
paths = [pathlib.Path(p) for p in listed if p and "+" in pathlib.Path(p).name]
if roots:
    paths = [p for p in paths if any(str(p).startswith(r) for r in roots)]

BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE = re.compile(r"//[^\n]*")
EXTENSION = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|nonisolated)\s+)*extension\s+([A-Za-z0-9_.]+)",
    re.M,
)
DECLARATION = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final|nonisolated|indirect)\s+)*"
    r"(?:class|struct|enum|actor|protocol)\s+([A-Za-z0-9_]+)",
    re.M,
)
ALLOWED_ALONGSIDE = {"Notification.Name"}

failures = []
for path in sorted(paths):
    owner = path.name.split("+")[0]
    code = LINE.sub("", BLOCK.sub("", path.read_text(encoding="utf-8", errors="replace")))
    extended = {name for name in EXTENSION.findall(code) if name not in ALLOWED_ALONGSIDE}
    if not extended and owner in DECLARATION.findall(code):
        continue
    if not extended:
        failures.append(f"{path}: names {owner} but extends nothing")
        continue
    others = sorted(name for name in extended if owner not in (name.split(".")[0], name.split(".")[-1]))
    if others:
        failures.append(f"{path}: names {owner} but extends {', '.join(others)}")

if failures:
    print("FAIL: a Type+Part.swift file extends a type its name does not give:", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    print("Rename the file for the type it extends, or move the other type to a file of its own.", file=sys.stderr)
    raise SystemExit(1)
print(f"check_file_names: clean. {len(paths)} Type+Part.swift files each extend the type they name.")
PY
