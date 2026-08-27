#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$REPO_ROOT/bridge"
OUTPUT="${1:-/usr/local/bin/merry-bridge}"

echo "Building merry-bridge → $OUTPUT"
cd "$BRIDGE_DIR"
go build -o "$OUTPUT" ./cmd/merry-bridge
echo "Done."
