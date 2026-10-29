#!/usr/bin/env bash
# swift test, retried while the toolchain reports the spurious "plugin for module 'TestingMacros' not found"
# (a Command Line Tools quirk: it goes away on a later attempt). Any other failure is returned as is.
# Usage: Scripts/test.sh [swift test arguments]
set -uo pipefail
cd "$(dirname "$0")/.."
for attempt in 1 2 3 4 5 6 7 8; do
    output="$(swift test "$@" 2>&1)"
    status=$?
    if grep -q "plugin for module 'TestingMacros' not found" <<<"$output"; then
        continue
    fi
    printf '%s\n' "$output"
    exit $status
done
printf '%s\n' "$output"
echo "TestingMacros plugin still missing after $attempt attempts" >&2
exit 1
