# Quick Start

## Testing the Plugin

The `test-plugin.sh` script launches Neovim with jadx.nvim in an isolated environment, leaving your existing Neovim setup untouched.

### Basic Usage

```bash
./test-plugin.sh
```

This opens Neovim with the plugin loaded and ready to use.

### Loading an APK File

```bash
./test-plugin.sh /path/to/app.apk
```

Neovim will start with the APK file already loaded in the plugin. You can then navigate classes:

```vim
:edit jadx://com.example.MainActivity
```

### Requirements

- Neovim (recent version with Lua support)
- Python 3 (for the LSP server stub during development)

### What's Isolated

- Neovim configuration (temporary, isolated `init.lua`)
- Plugin runtime path (only loads jadx.nvim, not your other plugins)
- No files are written to your home directory

When the session ends, all temporary files are cleaned up automatically.
