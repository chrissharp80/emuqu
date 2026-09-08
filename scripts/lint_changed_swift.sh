#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
changed_files=()
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        changed_files+=("$file")
    fi
done < <("$SCRIPT_DIR/changed_swift_files.sh")

if (( ${#changed_files[@]} == 0 )); then
    echo "No changed Swift files to lint/format."
    exit 0
fi

echo "Changed Swift files:"
printf '%s\n' "${changed_files[@]}"

echo "Running SwiftFormat (changed files, blocking)..."
swiftformat "${changed_files[@]}" --config .swiftformat --lint

echo "Running SwiftLint strict mode (changed files, blocking)..."
export SCRIPT_INPUT_FILE_COUNT="${#changed_files[@]}"
for i in "${!changed_files[@]}"; do
    export "SCRIPT_INPUT_FILE_${i}=${changed_files[$i]}"
done

swiftlint lint --strict --config .swiftlint-strict.yml --use-script-input-files
