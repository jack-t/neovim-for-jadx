#!/bin/bash
# End-to-end tests for jadx.nvim
# Tests the full plugin workflow: initialization, opening classes, navigation, etc.
#
# This script:
# 1. Builds the jadx-lsp server
# 2. Extracts test DEX file
# 3. Runs Neovim E2E tests
# 4. Cleans up

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Determine the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Cleanup function
cleanup() {
  log_info "Cleaning up..."

  # Kill any remaining java processes from this test run
  pkill -f "java.*jadx-lsp.jar" 2>/dev/null || true

  if [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi

  log_success "Cleanup complete"
}

trap cleanup EXIT

# ─── Prerequisites Check ──────────────────────────────────────────────────────

log_info "Checking prerequisites..."

if ! command -v nvim &> /dev/null; then
  log_error "Neovim is not installed or not in PATH"
  exit 1
fi

if ! command -v java &> /dev/null; then
  log_error "Java is not installed or not in PATH"
  exit 1
fi

log_success "Prerequisites check passed"

# ─── Build Server ─────────────────────────────────────────────────────────────

log_info "Building jadx-lsp server..."

JAR_PATH="$SCRIPT_DIR/server/build/libs/jadx-lsp.jar"

if [ ! -f "$JAR_PATH" ]; then
  cd "$SCRIPT_DIR/server"
  ./gradlew shadowJar -q
  cd "$SCRIPT_DIR"
  log_success "Server built: $JAR_PATH"
else
  log_info "Server JAR already exists: $JAR_PATH"
fi

if [ ! -f "$JAR_PATH" ]; then
  log_error "Failed to build server JAR"
  exit 1
fi

# ─── Extract Test DEX ─────────────────────────────────────────────────────────

log_info "Extracting test DEX file..."

TEMP_DIR="$(mktemp -d)"
DEX_FILE="$TEMP_DIR/test.dex"

# Extract test.dex from the JAR
if ! unzip -q "$JAR_PATH" "test.dex" -d "$TEMP_DIR" 2>/dev/null; then
  log_error "Failed to extract test.dex from server JAR"
  exit 1
fi

if [ ! -f "$DEX_FILE" ]; then
  log_error "test.dex not found in extracted files"
  exit 1
fi

log_success "Test DEX extracted: $DEX_FILE"

# ─── Create Test Config ───────────────────────────────────────────────────────

log_info "Creating isolated Neovim config..."

NVIM_CONFIG_DIR="$TEMP_DIR/nvim_config"
mkdir -p "$NVIM_CONFIG_DIR"

# Main init.lua for isolated Neovim - includes embedded tests
cat > "$NVIM_CONFIG_DIR/init.lua" << 'INIT_EOF'
-- Isolated Neovim configuration for E2E testing
-- Sets up the jadx plugin with the test DEX file and runs tests

vim.opt.more = false

-- Add plugin directory to runtime path
vim.opt.runtimepath:prepend(vim.env.JADX_PLUGIN_DIR)

-- Setup the jadx plugin
require("jadx").setup({
  cmd = { "java", "-jar", vim.env.JADX_SERVER_JAR },
  file = vim.env.JADX_TEST_DEX,
})

-- Wait for server to initialize
vim.fn.system("sleep 1")

-- ─── E2E Test Suite ──────────────────────────────────────────────────────────

local test_results = { passed = 0, failed = 0 }

local function assert_true(cond, msg)
  if not cond then error("ASSERT: " .. (msg or "false")) end
end

local function run_test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    test_results.passed = test_results.passed + 1
    print("[PASS] " .. name)
  else
    test_results.failed = test_results.failed + 1
    print("[FAIL] " .. name .. ": " .. tostring(err))
  end
end

-- Tests
run_test("Plugin Loaded", function()
  assert_true(package.loaded["jadx"] ~= nil, "jadx should be loaded")
end)

run_test("JADX Commands Exist", function()
  local cmds = vim.api.nvim_get_commands({})
  assert_true(cmds["JadxOpen"] ~= nil, "JadxOpen should exist")
  assert_true(cmds["JadxLoad"] ~= nil, "JadxLoad should exist")
  assert_true(cmds["JadxStatus"] ~= nil, "JadxStatus should exist")
end)

run_test("Open Class from URI", function()
  vim.cmd("edit jadx://com.example.Hello")
  vim.fn.system("sleep 2")
  local bufnr = vim.fn.bufnr("jadx://com.example.Hello")
  assert_true(bufnr ~= -1, "buffer should exist")
  local linecount = vim.api.nvim_buf_line_count(bufnr)
  assert_true(linecount > 0, "buffer should have content")
end)

run_test("JadxOpen Command", function()
  vim.cmd("JadxOpen com.example.Caller")
  vim.fn.system("sleep 2")
  local bufnr = vim.fn.bufnr("jadx://com.example.Caller")
  assert_true(bufnr ~= -1, "JadxOpen should create buffer")
end)

run_test("Status Buffer", function()
  vim.cmd("JadxStatus")
  vim.fn.system("sleep 1")
  local bufnr = vim.fn.bufnr("jadx://status")
  assert_true(bufnr ~= -1, "status buffer should exist")
end)

run_test("Load File Command", function()
  vim.cmd("JadxLoad " .. vim.env.JADX_TEST_DEX)
  vim.fn.system("sleep 1")
  assert_true(true, "JadxLoad should not crash")
end)

-- Print results and exit
print("\n" .. string.rep("─", 50))
print(string.format("Results: %d passed, %d failed", test_results.passed, test_results.failed))
print(string.rep("─", 50))

vim.fn.system("sleep 1")
os.exit(test_results.failed > 0 and 1 or 0)
INIT_EOF

log_success "Neovim config created"

# ─── Run Tests ────────────────────────────────────────────────────────────────

log_info "Running E2E tests..."

# Export environment for test
export JADX_PLUGIN_DIR="$SCRIPT_DIR"
export JADX_SERVER_JAR="$JAR_PATH"
export JADX_TEST_DEX="$DEX_FILE"

# Run Neovim in headless mode with test config
# The init.lua will set up the plugin and run the tests
TEST_LOG="$TEMP_DIR/test.log"

if NVIM_APPNAME="jadx_e2e_test_$$" \
   nvim --noplugin \
     -u "$NVIM_CONFIG_DIR/init.lua" \
     2>&1 | tee "$TEST_LOG"; then
  log_success "E2E tests passed"
  exit 0
else
  TEST_EXIT_CODE=${PIPESTATUS[0]}
  log_error "E2E tests failed (exit code: $TEST_EXIT_CODE)"

  # Print test log for debugging
  log_info "Test output:"
  cat "$TEST_LOG"

  exit $TEST_EXIT_CODE
fi
