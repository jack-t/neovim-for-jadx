#!/bin/bash
# Run the jadx.nvim plugin in an isolated Neovim environment
# This allows testing without interfering with your existing Neovim setup

set -e

# Determine the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if Neovim is installed
if ! command -v nvim &> /dev/null; then
    echo "Error: Neovim is not installed or not in PATH"
    exit 1
fi

# Create a temporary directory for the isolated Neovim config
TEMP_NVIM_CONFIG="$(mktemp -d)"
trap "rm -rf $TEMP_NVIM_CONFIG" EXIT

# Create a minimal init.lua that only loads this plugin
cat > "$TEMP_NVIM_CONFIG/init.lua" << 'EOF'
-- Isolated Neovim configuration for testing jadx.nvim plugin

-- Add this repo to the runtime path
vim.opt.runtimepath:prepend(vim.env.JADX_PLUGIN_DIR)

-- Setup the jadx plugin
require("jadx").setup({
  cmd = { "python3", vim.env.JADX_SERVER_CMD },
})

-- Optional: Print a helpful message
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.notify(
      "jadx.nvim loaded in isolated mode\n\n" ..
      "Test commands:\n" ..
      "  :edit jadx://java.lang.String\n" ..
      "  :JadxLoad /path/to/app.apk\n" ..
      "  :q to exit",
      vim.log.levels.INFO
    )
  end,
})
EOF

# Export paths for the init.lua script
export JADX_PLUGIN_DIR="$SCRIPT_DIR"
export JADX_SERVER_CMD="$SCRIPT_DIR/stub/server.py"

# Launch Neovim with the isolated config
NVIM_APPNAME="jadx_test_$$" nvim -u "$TEMP_NVIM_CONFIG/init.lua"
