-- jadx.nvim — Neovim plugin for navigating decompiled Android bytecode
--
-- Usage (in your init.lua):
--   require("jadx").setup({
--     cmd = { "python3", vim.fn.stdpath("data") .. "/jadx-lsp/stub/server.py" },
--     file = "/path/to/app.apk",   -- optional at startup; set later via :JadxLoad
--   })
--
-- Then open a class with:
--   :edit jadx://com.example.MyClass

local M = {}

-- Active LSP client id, nil if not running.
local client_id = nil

-- ─── URI helpers ────────────────────────────────────────────────────────────

--- Extract the fully-qualified class name from a jadx:// URI.
--- Returns nil if the URI is not a valid jadx URI.
local function fqn_from_uri(uri)
  return uri:match("^jadx://(.+)$")
end

-- ─── Buffer filling ──────────────────────────────────────────────────────────

--- Set buffer contents and mark it read-only with filetype=java.
local function fill_buffer(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly   = true
  vim.bo[bufnr].filetype   = "java"
end

-- ─── BufReadCmd handler ──────────────────────────────────────────────────────

--- Called whenever Neovim opens a buffer whose name matches jadx://*.
local function read_jadx_buf(bufnr)
  -- Mark the buffer as a scratch buffer so Neovim won't try to read it from disk.
  vim.bo[bufnr].buftype  = "nofile"
  vim.bo[bufnr].swapfile = false

  local uri = vim.api.nvim_buf_get_name(bufnr)
  local fqn = fqn_from_uri(uri)

  if not fqn then
    vim.notify("jadx: malformed URI: " .. uri, vim.log.levels.ERROR)
    return
  end

  if not client_id then
    vim.notify("jadx: LSP server not running — call require('jadx').setup() first", vim.log.levels.ERROR)
    return
  end

  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    vim.notify("jadx: LSP client gone (id=" .. tostring(client_id) .. ")", vim.log.levels.ERROR)
    client_id = nil
    return
  end

  -- Request decompiled source via the custom jadx/classSource method.
  client.request("jadx/classSource", { fqn = fqn }, function(err, result)
    if err then
      vim.notify("jadx: error fetching source for " .. fqn .. ": " .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end

    local source = (result and result.source) or ("-- no source returned for " .. fqn)
    local lines  = vim.split(source, "\n", { plain = true })

    vim.schedule(function()
      fill_buffer(bufnr, lines)
      -- Attach the LSP client so textDocument/hover and textDocument/definition work.
      vim.lsp.buf_attach_client(bufnr, client_id)
    end)
  end)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Start the jadx LSP server and register jadx:// URI handling.
---
--- @param opts table
---   .cmd   string|table  Command to launch the LSP server (required).
---   .file  string|nil    APK/DEX/JAR path forwarded as initializationOptions.jadxFile.
function M.setup(opts)
  opts = opts or {}

  if not opts.cmd then
    vim.notify("jadx: setup() requires 'cmd' (path to jadx LSP server)", vim.log.levels.ERROR)
    return
  end

  local cmd = type(opts.cmd) == "string" and { opts.cmd } or opts.cmd

  local init_options = {}
  if opts.file then
    init_options.jadxFile = opts.file
  end

  -- Start the LSP client.
  client_id = vim.lsp.start_client({
    name    = "jadx",
    cmd     = cmd,
    init_options = init_options,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    on_exit = function(code, _signal)
      vim.schedule(function()
        vim.notify(("jadx: LSP server exited (code %d)"):format(code), vim.log.levels.WARN)
      end)
      client_id = nil
    end,
  })

  if not client_id then
    vim.notify("jadx: failed to start LSP client", vim.log.levels.ERROR)
    return
  end

  -- Handle `:edit jadx://com.example.ClassName`
  vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern  = "jadx://*",
    callback = function(ev)
      read_jadx_buf(ev.buf)
    end,
    desc = "jadx: load decompiled source into buffer",
  })
end

--- Convenience command: open a class by FQN in a new buffer.
---
--- Example: require("jadx").open("com.example.MainActivity")
function M.open(fqn)
  vim.cmd("edit jadx://" .. fqn)
end

return M
