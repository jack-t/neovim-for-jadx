#!/bin/bash
# test-plugin.sh — Standalone test harness for jadx.nvim
#
# Usage:
#   ./test-plugin.sh                    # Opens Neovim with the plugin loaded
#   ./test-plugin.sh /path/to/app.apk   # Also loads the APK file on startup

set -e

# Get the absolute path to the plugin directory
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for this session's config
NVIM_HOME=$(mktemp -d)
trap "rm -rf '$NVIM_HOME'" EXIT

# Create the init.lua that loads our plugin
mkdir -p "$NVIM_HOME"
cat > "$NVIM_HOME/init.lua" <<EOF
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

# Launch Neovim with the isolated config
NVIM_APPNAME="$NVIM_HOME" exec nvim "$@"
