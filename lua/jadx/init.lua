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

-- ─── Status buffer ──────────────────────────────────────────────────────────

local status_bufnr = nil
local status_lines = {}

--- Append a timestamped line to the status buffer.
local function status_log(level, msg)
  local ts = os.date("%H:%M:%S")
  local prefix = ({ INFO = " ", WARN = "!", ERROR = "X", DEBUG = "." })[level] or " "
  local line = string.format("[%s] %s %s", ts, prefix, msg)
  table.insert(status_lines, line)

  -- Update the buffer if it exists and is valid.
  if status_bufnr and vim.api.nvim_buf_is_valid(status_bufnr) then
    vim.bo[status_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(status_bufnr, -1, -1, false, { line })
    vim.bo[status_bufnr].modifiable = false
    -- Auto-scroll any window showing the status buffer.
    for _, win in ipairs(vim.fn.win_findbuf(status_bufnr)) do
      local lc = vim.api.nvim_buf_line_count(status_bufnr)
      pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
    end
  end
end

--- Open (or focus) the jadx status buffer in a split.
local function open_status_buf()
  -- Reuse the buffer if it already exists.
  if status_bufnr and vim.api.nvim_buf_is_valid(status_bufnr) then
    local wins = vim.fn.win_findbuf(status_bufnr)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
      return
    end
    vim.cmd("botright split")
    vim.cmd("resize 12")
    vim.api.nvim_win_set_buf(0, status_bufnr)
    return
  end

  vim.cmd("botright split")
  vim.cmd("resize 12")
  status_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, status_bufnr)
  vim.api.nvim_buf_set_name(status_bufnr, "jadx://status")
  vim.bo[status_bufnr].buftype    = "nofile"
  vim.bo[status_bufnr].swapfile   = false
  vim.bo[status_bufnr].filetype   = "jadx-status"
  vim.bo[status_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(status_bufnr, 0, -1, false, status_lines)
  vim.bo[status_bufnr].modifiable = false
end

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

-- ─── LSP client attachment ───────────────────────────────────────────────────

--- Attach the LSP client to a buffer.
--- Uses client.attach() if available (nvim 0.11+), otherwise falls back to
--- vim.lsp.buf_attach_client (deprecated in 0.10+ but still functional).
local function attach_client(bufnr, cid)
  local client = vim.lsp.get_client_by_id(cid)
  if not client then return end
  if type(client.attach) == "function" then
    client.attach(bufnr)
  else
    vim.lsp.buf_attach_client(bufnr, cid)
  end
end

-- ─── BufReadCmd handler ──────────────────────────────────────────────────────

--- Called whenever Neovim opens a buffer whose name matches jadx://*.
local function read_jadx_buf(bufnr)
  local uri = vim.api.nvim_buf_get_name(bufnr)

  -- Don't try to fetch source for the status buffer.
  if uri == "jadx://status" then return end

  -- Mark the buffer as a scratch buffer so Neovim won't try to read it from disk.
  vim.bo[bufnr].buftype  = "nofile"
  vim.bo[bufnr].swapfile = false

  local fqn = fqn_from_uri(uri)

  if not fqn then
    vim.notify("jadx: malformed URI: " .. uri, vim.log.levels.ERROR)
    status_log("ERROR", "Malformed URI: " .. uri)
    return
  end

  if not client_id then
    vim.notify("jadx: LSP server not running — call require('jadx').setup() first", vim.log.levels.ERROR)
    status_log("ERROR", "LSP server not running")
    return
  end

  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    vim.notify("jadx: LSP client gone (id=" .. tostring(client_id) .. ")", vim.log.levels.ERROR)
    status_log("ERROR", "LSP client gone (id=" .. tostring(client_id) .. ")")
    client_id = nil
    return
  end

  status_log("INFO", "Decompiling " .. fqn .. " ...")

  -- Request decompiled source via the custom jadx/classSource method.
  client.request("jadx/classSource", { fqn = fqn }, function(err, result)
    -- This callback runs on a libuv thread; all vim.* calls must go through vim.schedule.
    if err then
      vim.schedule(function()
        vim.notify("jadx: error fetching source for " .. fqn .. ": " .. vim.inspect(err), vim.log.levels.ERROR)
        status_log("ERROR", "Failed to decompile " .. fqn .. ": " .. vim.inspect(err))
      end)
      return
    end

    local source = (result and result.source) or ("-- no source returned for " .. fqn)
    local lines  = vim.split(source, "\n", { plain = true })

    vim.schedule(function()
      fill_buffer(bufnr, lines)
      status_log("INFO", "Decompiled " .. fqn .. " (" .. #lines .. " lines)")
      -- Mark the buffer as loaded so the definition handler can jump immediately
      -- if the user navigates back to this buffer later.
      vim.b[bufnr].jadx_loaded = true
      -- Attach the LSP client so textDocument/hover and textDocument/definition work.
      if client_id then
        attach_client(bufnr, client_id)
      end
      -- Apply any position that was deferred while the source was in-flight.
      local buf_uri = vim.api.nvim_buf_get_name(bufnr)
      local jump = pending_jumps[buf_uri]
      if jump then
        pending_jumps[buf_uri] = nil
        local wins = vim.fn.win_findbuf(bufnr)
        if #wins > 0 then
          pcall(vim.api.nvim_win_set_cursor, wins[1], { jump.line + 1, jump.character })
        end
      end
    end)
  end)
end

-- ─── FZF integration ────────────────────────────────────────────────────────

--- Fetch symbols from the server and present them in fzf for fuzzy selection.
local function fzf_search()
  if not client_id then
    vim.notify("jadx: LSP server not running", vim.log.levels.ERROR)
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    vim.notify("jadx: LSP client gone", vim.log.levels.ERROR)
    client_id = nil
    return
  end

  status_log("INFO", "Fetching symbols for search ...")

  client.request("jadx/symbols", vim.empty_dict(), function(err, result)
    if err then
      vim.schedule(function()
        vim.notify("jadx: symbol search error: " .. vim.inspect(err), vim.log.levels.ERROR)
        status_log("ERROR", "Symbol search failed: " .. vim.inspect(err))
      end)
      return
    end

    vim.schedule(function()
      local symbols = (result and result.symbols) or {}
      if #symbols == 0 then
        vim.notify("jadx: no symbols found (is a file loaded?)", vim.log.levels.WARN)
        status_log("WARN", "No symbols found for search")
        return
      end

      status_log("INFO", "Search: " .. #symbols .. " symbols available")

      -- Build display lines: "kind\tname\tparent_class"
      local fzf_lines = {}
      for _, sym in ipairs(symbols) do
        local display
        if sym.kind == "class" then
          display = "[class]  " .. sym.name
        elseif sym.kind == "method" then
          display = "[method] " .. sym.parent .. "." .. sym.name
        elseif sym.kind == "field" then
          display = "[field]  " .. sym.parent .. "." .. sym.name
        else
          display = "[" .. sym.kind .. "] " .. sym.name
        end
        table.insert(fzf_lines, display)
      end

      -- Write lines to a temp file for fzf input.
      local tmpfile = vim.fn.tempname()
      vim.fn.writefile(fzf_lines, tmpfile)

      -- Run fzf in a terminal buffer.
      local fzf_cmd = string.format(
        "fzf --ansi --prompt='jadx> ' --header='Search classes, methods, fields' < %s",
        vim.fn.shellescape(tmpfile)
      )

      -- Open a floating window for fzf.
      local width  = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines * 0.6)
      local row    = math.floor((vim.o.lines - height) / 2)
      local col    = math.floor((vim.o.columns - width) / 2)
      local float_buf = vim.api.nvim_create_buf(false, true)
      local float_win = vim.api.nvim_open_win(float_buf, true, {
        relative = "editor",
        width    = width,
        height   = height,
        row      = row,
        col      = col,
        style    = "minimal",
        border   = "rounded",
      })

      vim.fn.termopen(fzf_cmd, {
        on_exit = function(_job_id, exit_code, _event)
          vim.schedule(function()
            -- Read the terminal buffer contents to find the selected line.
            local selected = nil
            if exit_code == 0 then
              local term_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
              -- fzf writes the selected item as the last non-empty line before exit.
              for i = #term_lines, 1, -1 do
                local l = vim.trim(term_lines[i])
                if l ~= "" then
                  selected = l
                  break
                end
              end
            end

            -- Close the float.
            if vim.api.nvim_win_is_valid(float_win) then
              vim.api.nvim_win_close(float_win, true)
            end
            if vim.api.nvim_buf_is_valid(float_buf) then
              vim.api.nvim_buf_delete(float_buf, { force = true })
            end
            vim.fn.delete(tmpfile)

            if not selected or selected == "" then return end

            -- Parse the selection to determine which class to open.
            -- Format: "[kind]  parent.name" or "[class]  fqn"
            local class_fqn = nil
            -- Try class pattern first: "[class]  com.example.Foo"
            class_fqn = selected:match("^%[class%]%s+(.+)$")
            if not class_fqn then
              -- Method/field pattern: "[method] com.example.Foo.bar"
              local full = selected:match("^%[%w+%]%s+(.+)$")
              if full then
                -- Extract the class FQN (everything before the last dot).
                class_fqn = full:match("^(.+)%.[^.]+$")
              end
            end

            if class_fqn then
              status_log("INFO", "Opening " .. class_fqn .. " from search")
              vim.cmd("edit jadx://" .. class_fqn)
            end
          end)
        end,
      })

      -- Enter terminal mode so user can type immediately.
      vim.cmd("startinsert")
    end)
  end)
end

-- ─── Config file ─────────────────────────────────────────────────────────────

--- Source the user's jadx-init.vim config file if it exists.
--- Looks in the plugin directory first (shipped default), then in the user's
--- Neovim config directory for overrides.
local function load_config()
  -- Determine the plugin root directory.
  local plugin_dir = vim.env.JADX_PLUGIN_DIR
  if not plugin_dir then
    -- Derive from the runtime path entry that contains this file.
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
      local lua_path = info.source:sub(2)
      plugin_dir = vim.fn.fnamemodify(lua_path, ":h:h:h")
    end
  end

  local sourced = false

  -- 1. Source the shipped default config from the plugin directory.
  if plugin_dir then
    local default_config = plugin_dir .. "/jadx-init.vim"
    if vim.fn.filereadable(default_config) == 1 then
      vim.cmd("source " .. vim.fn.fnameescape(default_config))
      status_log("INFO", "Loaded default config: " .. default_config)
      sourced = true
    end
  end

  -- 2. Source the user's override config (takes precedence).
  local user_config = vim.fn.stdpath("config") .. "/jadx-init.vim"
  if vim.fn.filereadable(user_config) == 1 then
    vim.cmd("source " .. vim.fn.fnameescape(user_config))
    status_log("INFO", "Loaded user config: " .. user_config)
    sourced = true
  end

  if not sourced then
    status_log("DEBUG", "No jadx-init.vim found (using built-in defaults)")
  end
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

  status_log("INFO", "jadx.nvim starting up")
  status_log("INFO", "Server command: " .. table.concat(cmd, " "))
  if opts.file then
    status_log("INFO", "Initial file: " .. opts.file)
  end

  -- Capture the default handler before starting the client so the per-client
  -- handler can delegate non-jadx results correctly (including multi-location).
  local default_def_handler = vim.lsp.handlers["textDocument/definition"]

  -- Start the LSP client.
  client_id = vim.lsp.start_client({
    name         = "jadx",
    cmd          = cmd,
    init_options = init_options,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
    -- Per-client handler: only intercepts jadx:// definition results.
    -- Other LSP clients (lua_ls, clangd, …) are completely unaffected.
    --
    -- The default handler is called for non-jadx URIs so that multi-location
    -- results (quickfix list / picker) continue to work correctly.
    handlers = {
      ["textDocument/definition"] = function(err, result, ctx, config)
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
          -- Non-jadx URI: delegate to the default handler so multi-location
          -- results (quickfix list / picker) work correctly.
          default_def_handler(err, result, ctx, config)
        end
      end,
      -- Capture server log/info messages and route them to the status buffer.
      ["window/showMessage"] = function(_err, result, _ctx, _config)
        if not result then return end
        local level_map = {
          [1] = "ERROR",   -- Error
          [2] = "WARN",    -- Warning
          [3] = "INFO",    -- Info
          [4] = "DEBUG",   -- Log
        }
        local level = level_map[result.type] or "INFO"
        status_log(level, result.message or "")
        -- Also show errors and warnings via vim.notify so users see them.
        if result.type == 1 then
          vim.notify(result.message, vim.log.levels.ERROR)
        elseif result.type == 2 then
          vim.notify(result.message, vim.log.levels.WARN)
        elseif result.type == 3 then
          vim.notify(result.message, vim.log.levels.INFO)
        end
      end,
    },
    on_init = function(_client, _init_result)
      vim.schedule(function()
        status_log("INFO", "LSP server initialized")
      end)
    end,
    on_exit = function(code, _signal)
      vim.schedule(function()
        if code == 0 then
          status_log("INFO", "LSP server exited normally")
        else
          status_log("ERROR", "LSP server exited with code " .. code)
          vim.notify(("jadx: LSP server exited (code %d)"):format(code), vim.log.levels.WARN)
        end
      end)
      client_id = nil
    end,
  })

  if not client_id then
    vim.notify("jadx: failed to start LSP client", vim.log.levels.ERROR)
    status_log("ERROR", "Failed to start LSP client")
    return
  end

  status_log("INFO", "LSP client started (id=" .. client_id .. ")")

  -- Handle `:edit jadx://com.example.ClassName`.
  -- Use a named augroup that is cleared first so repeated setup() calls do not
  -- accumulate duplicate autocmds.
  local augroup = vim.api.nvim_create_augroup("jadx", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group    = augroup,
    pattern  = "jadx://*",
    callback = function(ev)
      read_jadx_buf(ev.buf)
    end,
    desc = "jadx: load decompiled source into buffer",
  })

  -- Register user commands.
  vim.api.nvim_create_user_command("JadxLoad", function(cmd_opts)
    M.load_file(cmd_opts.args)
  end, { nargs = 1, desc = "jadx: hot-load a new APK/DEX/JAR file" })

  vim.api.nvim_create_user_command("JadxStatus", function()
    M.show_status()
  end, { nargs = 0, desc = "jadx: open the status buffer" })

  vim.api.nvim_create_user_command("JadxSearch", function()
    M.search()
  end, { nargs = 0, desc = "jadx: fuzzy-search symbols with fzf" })

  vim.api.nvim_create_user_command("JadxOpen", function(cmd_opts)
    M.open(cmd_opts.args)
  end, { nargs = 1, desc = "jadx: open a class by fully-qualified name",
    complete = function() return {} end })

  -- Load configuration files.
  load_config()
end

--- Open (or focus) the jadx status buffer.
function M.show_status()
  open_status_buf()
end

--- Fuzzy-search symbols (classes, methods, fields) using fzf.
function M.search()
  fzf_search()
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
    status_log("ERROR", "Cannot load file: LSP server not running")
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    vim.notify("jadx: LSP client gone", vim.log.levels.ERROR)
    status_log("ERROR", "LSP client gone")
    client_id = nil
    return
  end
  status_log("INFO", "Requesting load of " .. path .. " ...")
  client.request("workspace/executeCommand", {
    command   = "jadx.loadFile",
    arguments = { path },
  }, function(err, _)
    if err then
      vim.schedule(function()
        vim.notify("jadx: load_file error: " .. vim.inspect(err), vim.log.levels.ERROR)
        status_log("ERROR", "Load file error: " .. vim.inspect(err))
      end)
    end
  end)
end

return M
