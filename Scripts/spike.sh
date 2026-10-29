#!/usr/bin/env bash
# Phase 1 spike: read-only scans of real volumes with each method, one process per run so memory
# figures are separate. Usage: Scripts/spike.sh <root> <output-dir> [runs...]
# A run is "method[:threads][:store]", e.g. fts bulk:1 bulk:8 bulk:8:store fm.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
P=.build/release/macclean-probe
for run in "$@"; do
    IFS=: read -r method threads store <<<"$run"
    args=(bench "$method" "$ROOT" --threads "${threads:-1}")
    [[ "${store:-}" == store ]] && args+=(--store)
    name="$(basename "$ROOT" | tr ' /' '__')-${run//:/_}"
    /usr/bin/time -l "$P" "${args[@]}" >"$OUT/$name.txt" 2>"$OUT/$name.time"
    echo "$name: $(grep '^time' "$OUT/$name.txt") | $(grep 'maximum resident' "$OUT/$name.time" | awk '{print int($1/1e6) " MB peak (time -l)"}')"
done
