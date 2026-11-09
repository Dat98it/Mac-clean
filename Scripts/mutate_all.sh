#!/usr/bin/env bash
# Runs every mutation check: the disk explorer's (mutate.py) and the uninstaller's (mutate_uninstall.sh).
# Both edit source files in place and restore them; run this on a clean working tree, not while editing.
# Usage: Scripts/mutate_all.sh [name-filter]
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
python3 -I Scripts/mutate.py "${1:-}" || status=1
Scripts/mutate_uninstall.sh ${1:+"$1"} || status=1
exit $status
