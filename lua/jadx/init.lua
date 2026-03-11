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

-- When textDocument/definition points to a jadx:// URI, the buffer fill is
-- async.  We store the target position here (keyed by URI) so read_jadx_buf
-- can apply it once the source has actually arrived.
local pending_jumps = {}

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
    -- This callback runs on a libuv thread; all vim.* calls must go through vim.schedule.
    if err then
      vim.schedule(function()
        vim.notify("jadx: error fetching source for " .. fqn .. ": " .. vim.inspect(err), vim.log.levels.ERROR)
      end)
      return
    end

    local source = (result and result.source) or ("-- no source returned for " .. fqn)
    local lines  = vim.split(source, "\n", { plain = true })

    vim.schedule(function()
      fill_buffer(bufnr, lines)
      -- Mark the buffer as loaded so the definition handler can jump immediately
      -- if the user navigates back to this buffer later.
      vim.b[bufnr].jadx_loaded = true
      -- Attach the LSP client so textDocument/hover and textDocument/definition work.
      if client_id then
        vim.lsp.buf_attach_client(bufnr, client_id)
      end
      -- Apply any position that was deferred while the source was in-flight.
      local uri = vim.api.nvim_buf_get_name(bufnr)
      local jump = pending_jumps[uri]
      if jump then
        pending_jumps[uri] = nil
        local wins = vim.fn.win_findbuf(bufnr)
        if #wins > 0 then
          pcall(vim.api.nvim_win_set_cursor, wins[1], { jump.line + 1, jump.character })
        end
      end
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

  -- Override the definition handler for jadx:// targets.
  --
  -- The default handler calls jump_to_location, which opens the buffer and
  -- immediately tries to set the cursor.  For jadx:// buffers the source
  -- arrives asynchronously, so the cursor positioning must be deferred until
  -- after fill_buffer runs.  If the buffer is already loaded (the user opened
  -- it before), we jump right away.
  vim.lsp.handlers["textDocument/definition"] = function(err, result, ctx, _)
    if err or not result then return end
    local locs = vim.islist(result) and result or { result }
    if #locs == 0 then return end
    local loc = locs[1]

    if type(loc.uri) == "string" and loc.uri:match("^jadx://") then
      local pos    = loc.range and loc.range.start
      local bufnr  = vim.fn.bufnr(loc.uri)
      local loaded = bufnr ~= -1 and vim.b[bufnr] and vim.b[bufnr].jadx_loaded

      if pos and not loaded then
        -- Source not yet in the buffer; stash the position for read_jadx_buf.
        pending_jumps[loc.uri] = pos
      end

      -- Open (or switch to) the jadx:// buffer, triggering BufReadCmd if new.
      vim.cmd("edit " .. loc.uri)

      if pos and loaded then
        -- Buffer already filled; jump now.
        pcall(vim.api.nvim_win_set_cursor, 0, { pos.line + 1, pos.character })
      end
    else
      local client = vim.lsp.get_client_by_id(ctx.client_id)
      local enc    = client and client.offset_encoding or "utf-8"
      vim.lsp.util.jump_to_location(loc, enc)
    end
  end
end

--- Convenience command: open a class by FQN in a new buffer.
---
--- Example: require("jadx").open("com.example.MainActivity")
function M.open(fqn)
  vim.cmd("edit jadx://" .. fqn)
end

--- Hot-load a new APK/DEX/JAR without restarting the server.
---
--- Sends the workspace/executeCommand "jadx.loadFile" to the running server.
--- The server swaps in a new JadxDecompiler instance transparently; already-open
--- buffers still show their old source (re-open them to pick up the new one).
---
--- Example: require("jadx").load_file("/path/to/other.apk")
function M.load_file(path)
  if not client_id then
    vim.notify("jadx: LSP server not running — call require('jadx').setup() first", vim.log.levels.ERROR)
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    vim.notify("jadx: LSP client gone", vim.log.levels.ERROR)
    client_id = nil
    return
  end
  client.request("workspace/executeCommand", {
    command   = "jadx.loadFile",
    arguments = { path },
  }, function(err, _)
    if err then
      vim.schedule(function()
        vim.notify("jadx: load_file error: " .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end
  end)
end

return M
