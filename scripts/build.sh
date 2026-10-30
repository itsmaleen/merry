#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$REPO_ROOT/bridge"
OUTPUT="${1:-/usr/local/bin/cmux-bridge}"

echo "Building cmux-bridge → $OUTPUT"
cd "$BRIDGE_DIR"
# Build with exactly the Go that go.mod names (fetched on demand), not just "at
# least" it. A newer local Go breaks the build: Go 1.27 enables the jsonv2
# experiment, which compiles tailscale's go-json-experiment alias.go against a
# std API it no longer matches. Set GOTOOLCHAIN yourself to override.
if [ -z "${GOTOOLCHAIN:-}" ]; then
    export GOTOOLCHAIN="go$(awk '/^go /{print $2; exit}' go.mod)"
fi
go build -o "$OUTPUT" ./cmd/cmux-bridge
echo "Done."
