#!/usr/bin/env bash
# Run the jadx.nvim headless integration tests.
#
# Usage: ./test/run_tests.sh
#
# Requirements:
#   - neovim (nvim) in PATH
#   - python3 in PATH

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SCRIPT="$REPO_DIR/test/test_plugin.lua"
RESULTS_FILE="/tmp/jadx-test-results.txt"

echo "=== jadx.nvim integration tests ==="
echo "Repo:    $REPO_DIR"
echo "Results: $RESULTS_FILE"
echo ""

nvim --headless \
    --cmd "set runtimepath+=$REPO_DIR" \
    -c "lua dofile('$TEST_SCRIPT')" \
    2>&1

echo ""
echo "=== Full results ==="
cat "$RESULTS_FILE"
