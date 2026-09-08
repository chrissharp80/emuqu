#!/usr/bin/env python3
"""
Script to add a Swift file to the Xcode project (Emuqu.xcodeproj).

This script automates adding new Swift files to the Xcode project by:
1. Creating a PBXFileReference entry
2. Creating a PBXBuildFile entry
3. Adding the file to the appropriate PBXGroup (folder)
4. Adding it to the PBXSourcesBuildPhase (so it gets compiled)

Usage:
    python3 scripts/add_swift_file.py <relative_path_to_swift_file>

Example:
    python3 scripts/add_swift_file.py Emuqu/Sources/Collection/RRRecoveryEngine.swift

Supported folder paths:
    - Emuqu/Sources/Models
    - Emuqu/Sources/Analysis
    - Emuqu/Sources/Analysis/CauseDetection
    - Emuqu/Sources/Collection
    - Emuqu/Sources/Storage
    - Emuqu/Sources/Export
    - Emuqu/Sources/Views
    - Emuqu/Sources/Views/Onboarding
    - Emuqu/Sources/Views/Record
    - Emuqu/Sources/Views/Results
    - Emuqu/Sources/Views/MorningResults
    - Emuqu/Sources/Views/Utilities
    - Emuqu/Sources/Import
    - Emuqu/Sources/Protocols
    - Emuqu/Sources/Services
    - Emuqu/Sources/ViewModels
    - Emuqu/Sources/Utilities
    - Emuqu/Sources/Assistant
    - Emuqu/Sources/Assistant/Chat
    - Emuqu/Sources/Assistant/Context
    - Emuqu/Sources/Assistant/Facts
    - Emuqu/Sources/Assistant/Keys
    - Emuqu/Sources/Assistant/Providers
    - Emuqu/Sources/Assistant/ViewModel
    - Emuqu/Sources/Assistant/Views
    - EmuquTests
    - EmuquTests/Helpers
    - EmuquTests/Mocks
"""

import sys
import os
import re
import random
from pathlib import Path


def generate_unique_id(existing_ids):
    """Generate a unique hex ID that doesn't collide with existing ones."""
    while True:
        # Generate a random 12-character hex ID similar to Xcode format
        # Format: combination of letters and numbers like A1100047001
        prefix = random.choice(['A1', 'EF', 'UC', 'P2', 'CK', 'RF', 'OB'])
        number = random.randint(100000, 999999)
        suffix = random.choice(['000', '001'])
        new_id = f"{prefix}{number}{suffix}"

        if new_id not in existing_ids:
            return new_id


def extract_all_ids(content):
    """Extract all existing IDs from the pbxproj file."""
    # Match patterns like A1100047001, EF3A13382F285DBA009037DA, etc.
    id_pattern = re.compile(r'\b([A-Z0-9]{11,24})\b')
    ids = set(id_pattern.findall(content))
    return ids


def find_group_id_for_path(content, folder_path):
    """Find the PBXGroup ID that matches the given folder path."""
    # Normalize path
    folder_path = folder_path.strip('/')

    # Common mappings based on the project structure
    path_to_group = {
        'Emuqu/Sources/Models': 'A0000000007',
        'Emuqu/Sources/Analysis': 'A0000000008',
        'Emuqu/Sources/Analysis/CauseDetection': 'UC000000015',
        'Emuqu/Sources/Collection': 'A0000000009',
        'Emuqu/Sources/Storage': 'A0000000010',
        'Emuqu/Sources/Export': 'A0000000011',
        'Emuqu/Sources/Views': 'A0000000012',
        'Emuqu/Sources/Views/Onboarding': 'OB000000001',
        'Emuqu/Sources/Views/Record': 'NWG000000002',
        'Emuqu/Sources/Views/Results': '239AB2B0091929D1B54019B3',
        'Emuqu/Sources/Import': 'A0000000013',
        'Emuqu/Sources/Protocols': 'P2000000001',
        'Emuqu/Sources/Services': 'P2000000002',
        'Emuqu/Sources/ViewModels': 'P2000000003',
        'Emuqu/Sources/Utilities': 'EF989B882F27AD02001E453C',
        'Emuqu/Sources/Assistant': '6D13558C4E5998B5971993E4',
        'Emuqu/Sources/Assistant/Chat': '359C0DD96356DA73CF92C181',
        'Emuqu/Sources/Assistant/Context': 'D65BF5BA4F6FFA53CDDE9EF1',
        'Emuqu/Sources/Assistant/Facts': 'FAC00000999',
        'Emuqu/Sources/Assistant/Keys': 'ADB6B62F21B5912DAC589998',
        'Emuqu/Sources/Assistant/Providers': '48DB7E0E425B909D34498A58',
        'Emuqu/Sources/Assistant/ViewModel': '574E3BB50346906A1F36D911',
        'Emuqu/Sources/Assistant/Views': 'DDC81248DA2E0A461997FE50',
        'EmuquTests': 'A0000000004',
        'EmuquTests/Mocks': 'P2000000004',
        'EmuquTests/Helpers': 'TH000000001',
    }

    if folder_path in path_to_group:
        return path_to_group[folder_path]

    # Try to find the group by searching for path = <folder_name>; pattern
    folder_name = os.path.basename(folder_path)
    pattern = rf'([A-Z0-9]+) /\* {re.escape(folder_name)} \*/ = \{{\s+isa = PBXGroup;.*?path = {re.escape(folder_name)};'
    match = re.search(pattern, content, re.DOTALL)

    if match:
        return match.group(1)

    return None


# Which build target owns each supported folder. This map
# did not exist, and `find_sources_build_phase_id` hardcoded the APP target's
# Sources phase (A0000001004) for every path. The docstring advertised
# `EmuquTests`, `EmuquTests/Helpers` and `EmuquTests/Mocks`, and a file added to
# any of them landed in the app target's compile phase: the group was right, the
# membership was wrong, and the build failed with
#
#     file 'X.swift' is part of module 'Emuqu'; ignoring import
#     compilation search paths unable to resolve module dependency: 'XCTest'
#
# which reads as a broken file rather than a broken tool. That is the exact
# failure this script exists to prevent, and `check_no_orphan_swift.sh` could
# not catch it either because it only scans `Emuqu/`.
TARGET_FOR_PREFIX = (
    ('EmuquUITests', 'EmuquUITests'),
    ('EmuquTests', 'EmuquTests'),
    ('EmuquWatch Watch App', 'EmuquWatch Watch App'),
    ('Emuqu', 'Emuqu'),
)


def target_for_path(folder_path):
    """The build target that should compile a file in `folder_path`."""
    normalized = folder_path.replace('\\', '/')
    for prefix, target in TARGET_FOR_PREFIX:
        if normalized == prefix or normalized.startswith(prefix + '/'):
            return target
    return None


def find_sources_build_phase_id(content, target_name):
    """Find the PBXSourcesBuildPhase ID belonging to `target_name`.

    Resolved from the target, never hardcoded: locate the PBXNativeTarget whose
    name matches, read its buildPhases list, and return the id in that list that
    is a PBXSourcesBuildPhase.
    """
    target_pattern = (
        r'([A-Z0-9]+) /\* ' + re.escape(target_name) + r' \*/ = \{\s*'
        r'isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);'
    )
    target_match = re.search(target_pattern, content, re.DOTALL)
    if not target_match:
        return None

    sources_ids = set(
        re.findall(r'([A-Z0-9]+) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;', content)
    )
    for phase_id in re.findall(r'([A-Z0-9]+) /\* [^*]* \*/,', target_match.group(2)):
        if phase_id in sources_ids:
            return phase_id
    return None


def add_file_to_project(pbxproj_path, file_path):
    """Add a Swift file to the Xcode project."""

    # Read the pbxproj file
    with open(pbxproj_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Extract all existing IDs
    existing_ids = extract_all_ids(content)

    # Get file information
    file_path = Path(file_path)
    file_name = file_path.name

    # Determine the folder path (parent directory)
    folder_path = str(file_path.parent)

    # Find the appropriate group
    group_id = find_group_id_for_path(content, folder_path)
    if not group_id:
        print(f"Error: Could not find group for path: {folder_path}")
        print(f"Available groups are in paths like: Emuqu/Sources/Collection, Emuqu/Sources/Models, etc.")
        return False

    # Generate unique IDs
    file_ref_id = generate_unique_id(existing_ids)
    existing_ids.add(file_ref_id)

    build_file_id = generate_unique_id(existing_ids)
    existing_ids.add(build_file_id)

    print(f"Generated IDs:")
    print(f"  PBXFileReference: {file_ref_id}")
    print(f"  PBXBuildFile: {build_file_id}")
    print(f"  Group: {group_id}")

    # Create entries
    # Quote the path so names with special characters (e.g. a '+' in
    # "RRCollector+Foo.swift", or spaces) don't break the old-style plist parse.
    file_ref_entry = f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"{file_name}\"; sourceTree = \"<group>\"; }};"
    build_file_entry = f"\t\t{build_file_id} /* {file_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"

    # 1. Add PBXBuildFile entry
    build_file_section = re.search(r'(/\* Begin PBXBuildFile section \*/\n)', content)
    if not build_file_section:
        print("Error: Could not find PBXBuildFile section")
        return False

    insert_pos = build_file_section.end()
    content = content[:insert_pos] + build_file_entry + "\n" + content[insert_pos:]

    # 2. Add PBXFileReference entry
    file_ref_section = re.search(r'(/\* Begin PBXFileReference section \*/\n)', content)
    if not file_ref_section:
        print("Error: Could not find PBXFileReference section")
        return False

    insert_pos = file_ref_section.end()
    content = content[:insert_pos] + file_ref_entry + "\n" + content[insert_pos:]

    # 3. Add file reference to the appropriate PBXGroup
    # TWO bugs were here:
    #   (a) Original `.*` was GREEDY in re.DOTALL mode → spanned
    #       across multiple group definitions.
    #   (b) Even non-greedy `.*?` in DOTALL spans across comment
    #       blocks because `re.search` starts at the FIRST occurrence
    #       of `group_id` (which is often a reference inside a parent
    #       group's children list at a higher line number than the
    #       group's own definition). The non-greedy match then
    #       expands across newlines until the next ` */ = {` is
    #       found — which is some OTHER group's header.
    #
    # Fix: forbid `*` inside the comment body so the match cannot
    # span across multiple `/* ... */` blocks. `[^*]*?` matches any
    # char that isn't `*`. The group's comment text never contains
    # `*` literally (group names are alphanumerics + spaces), so this
    # is safe.
    group_pattern = rf'({group_id} /\* [^*]*? \*/ = \{{)\s+(isa = PBXGroup;\s+children = \(\s+)'
    group_match = re.search(group_pattern, content, re.DOTALL)

    if not group_match:
        print(f"Error: Could not find group {group_id} children section")
        return False

    insert_pos = group_match.end()
    group_entry = f"\t\t\t\t{file_ref_id} /* {file_name} */,\n"
    content = content[:insert_pos] + group_entry + content[insert_pos:]

    # 4. Add build file to PBXSourcesBuildPhase
    target_name = target_for_path(folder_path)
    if not target_name:
        print(f"Error: no build target owns path: {folder_path}")
        return False
    sources_phase_id = find_sources_build_phase_id(content, target_name)
    if not sources_phase_id:
        print("Error: Could not find Sources build phase")
        return False

    sources_pattern = rf'({sources_phase_id} /\* Sources \*/ = \{{)\s+(isa = PBXSourcesBuildPhase;.*?files = \(\s+)'
    sources_match = re.search(sources_pattern, content, re.DOTALL)

    if not sources_match:
        print("Error: Could not find Sources build phase files section")
        return False

    insert_pos = sources_match.end()
    sources_entry = f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,\n"
    content = content[:insert_pos] + sources_entry + content[insert_pos:]

    # Write the modified content back
    with open(pbxproj_path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"\nSuccessfully added {file_name} to the Xcode project!")
    print(f"File will be in group: {folder_path}")
    return True


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/add_swift_file.py <relative_path_to_swift_file>")
        print("\nExample:")
        print("  python3 scripts/add_swift_file.py Emuqu/Sources/Collection/RRRecoveryEngine.swift")
        sys.exit(1)

    # Get the file path argument
    file_path = sys.argv[1]

    # Get project root (script is in scripts/ directory)
    script_dir = Path(__file__).parent
    project_root = script_dir.parent

    # Path to pbxproj
    pbxproj_path = project_root / "Emuqu.xcodeproj" / "project.pbxproj"

    if not pbxproj_path.exists():
        print(f"Error: Could not find project file at {pbxproj_path}")
        sys.exit(1)

    # Validate the Swift file path
    full_file_path = project_root / file_path
    if not file_path.endswith('.swift'):
        print(f"Error: File must be a .swift file")
        sys.exit(1)

    # Check if file exists (optional - file might not exist yet)
    if not full_file_path.exists():
        print(f"Warning: File does not exist yet at {full_file_path}")
        print("Continuing anyway - you'll need to create this file.")

    # Add the file to the project
    success = add_file_to_project(pbxproj_path, file_path)

    if success:
        print("\nDone! Open Xcode to verify the changes.")
        sys.exit(0)
    else:
        print("\nFailed to add file to project.")
        sys.exit(1)


if __name__ == "__main__":
    main()
