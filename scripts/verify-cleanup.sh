#!/bin/bash
# Re-cleans every capture on disk with the current cleaner and prints the
# gate decisions. Run this before committing any SplatEngine cleanup change:
# a fix validated on one capture can silently zero out another (see
# docs/v6-silhouette-consensus.md — the isEnvironment knife-edge).
#
# Usage: scripts/verify-cleanup.sh [captures-dir] [output-dir]
# Sanity to look for per object capture: isEnvironment=false, kept fraction
# roughly 20–60%, isolated > 0. Anything at ~100% kept means cleanup no-oped.
set -euo pipefail

CAPTURES="${1:-$HOME/Library/Application Support/SavorNative/captures}"
OUT="${2:-$(mktemp -d /tmp/savor-verify.XXXXXX)}"
RECLEAN=".build/debug/phase2-reclean"

swift build --product phase2-reclean >/dev/null

shopt -s nullglob
found=0
for dir in "$CAPTURES"/*/; do
    [ -f "$dir/capture.json" ] || continue
    name=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sourceFilename'])" "$dir/capture.json")
    raw=""
    if [ -f "$dir/training/splat.ply" ]; then
        raw="$dir/training/splat.ply"
    else
        newest=$(ls "$dir"/training/splat_*.ply 2>/dev/null | sort -t_ -k2 -n | tail -1 || true)
        [ -n "$newest" ] && raw="$newest"
    fi
    if [ -z "$raw" ]; then
        echo "-- $name: no raw splat, skipped"
        continue
    fi
    found=$((found + 1))
    id=$(basename "$dir")
    echo "== $name ($id)"
    "$RECLEAN" "$raw" "$OUT/$id.ply" "$dir/dataset" | head -1
done

if [ "$found" -eq 0 ]; then
    echo "No captures with raw splats found under: $CAPTURES"
    exit 1
fi
echo
echo "Cleaned outputs in: $OUT (render with phase2-snapshot to inspect)"
