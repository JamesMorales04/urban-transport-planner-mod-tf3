#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <Transport Fever 3 staging_area path>"
  echo "Example: $0 \"$HOME/.local/share/Transport Fever 3/staging_area\""
  exit 2
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="$1"
DEST="$DEST_ROOT/urban_transport_planner"

mkdir -p "$DEST_ROOT"
rm -rf "$DEST"
cp -a "$SRC_DIR" "$DEST"

# Defensive cleanup in case an older alpha was manually merged in the past.
rm -f "$DEST/content/urban_transit/urban_tram_planner_alpha.script.lua"

echo "Installed Urban Tram Planner Alpha 0.7 to: $DEST"
echo "Enable/reload it in Transport Fever 3 and test on a COPY of the save."
