#!/bin/bash
# test-plugin.sh — Standalone test harness for jadx.nvim
#
# Usage:
#   ./test-plugin.sh                    # Opens Neovim with the plugin loaded
#   ./test-plugin.sh /path/to/app.apk   # Also loads the APK file on startup

set -e

# Get the absolute path to the plugin directory
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create temporary directories for isolated Neovim environment
NVIM_CONFIG=$(mktemp -d)
NVIM_DATA=$(mktemp -d)
trap "rm -rf '$NVIM_CONFIG' '$NVIM_DATA'" EXIT

# Create the init.lua that loads our plugin
cat > "$NVIM_CONFIG/init.lua" <<EOF
-- Temporary config for testing jadx.nvim

-- Add the plugin to the runtime path
vim.opt.rtp:prepend("$PLUGIN_DIR")

-- Configure the jadx plugin
require("jadx").setup({
  cmd = { "python3", "$PLUGIN_DIR/stub/server.py" },
  file = "${1:-}",  -- Optional APK file from command line
})

-- Optional: print startup message
vim.notify("jadx.nvim loaded from: $PLUGIN_DIR", vim.log.levels.INFO)
EOF

# Launch Neovim with the isolated config and data directories
export XDG_CONFIG_HOME="$NVIM_CONFIG"
export XDG_DATA_HOME="$NVIM_DATA"
exec nvim "$@"
