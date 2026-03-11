-- Headless integration test for jadx.nvim
--
-- Run via the wrapper (recommended):
--   ./test/run_tests.sh
--
-- Or manually:
--   nvim --headless \
--       --cmd "set runtimepath+=/path/to/neovim-for-jadx" \
--       -c "lua dofile('/path/to/neovim-for-jadx/test/test_plugin.lua')"
--
-- Results are written to /tmp/jadx-test-results.txt

-- Derive repo root from this file's own path so the test works regardless
-- of where the repo is cloned.  debug.getinfo source starts with '@'.
local _this_file = debug.getinfo(1, "S").source:sub(2)
local REPO_DIR    = _this_file:match("^(.+)/test/[^/]+$")
local STUB_SERVER = REPO_DIR .. "/stub/server.py"

local RESULTS_FILE = "/tmp/jadx-test-results.txt"

local results = {}
local pass_count = 0
local fail_count = 0

local function record(name, ok, detail)
  local status = ok and "PASS" or "FAIL"
  local line = string.format("[%s] %s%s", status, name, detail and (": " .. detail) or "")
  table.insert(results, line)
  if ok then pass_count = pass_count + 1 else fail_count = fail_count + 1 end
  -- Also print to stderr so it appears in terminal output
  io.stderr:write(line .. "\n")
end

local function write_results()
  local f = io.open(RESULTS_FILE, "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:write(string.format("\n%d passed, %d failed\n", pass_count, fail_count))
    f:close()
  end
end

-- ─── Test 1: plugin loads ─────────────────────────────────────────────────

local ok, jadx = pcall(require, "jadx")
record("plugin loads", ok, ok and nil or tostring(jadx))

if not ok then
  write_results()
  vim.cmd("qa!")
  return
end

-- ─── Test 2: setup() starts the LSP client ────────────────────────────────

jadx.setup({
  cmd  = { "python3", STUB_SERVER },
})

-- Give the LSP a moment to connect.
vim.wait(2000, function()
  return vim.lsp.get_active_clients({ name = "jadx" })[1] ~= nil
end, 50)

local clients = vim.lsp.get_active_clients({ name = "jadx" })
record("LSP client started", #clients > 0, #clients > 0 and ("client id=" .. tostring(clients[1].id)) or "no client")

-- ─── Test 3: open a jadx:// buffer ────────────────────────────────────────

local test_fqn = "com.example.MainActivity"
local test_uri = "jadx://" .. test_fqn

-- Open the buffer; BufReadCmd handler fires asynchronously.
vim.cmd("edit " .. test_uri)

local bufnr = vim.fn.bufnr(test_uri)
record("jadx:// buffer created", bufnr ~= -1, "bufnr=" .. tostring(bufnr))

-- ─── Test 4: buffer fills with decompiled source ──────────────────────────

-- Wait up to 5 s for the async jadx/classSource response.
local loaded = vim.wait(5000, function()
  return vim.b[bufnr] and vim.b[bufnr].jadx_loaded == true
end, 100)

record("buffer filled (jadx_loaded)", loaded)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local content = table.concat(lines, "\n")

record("buffer contains class declaration",
  content:find("class MainActivity") ~= nil,
  "lines=" .. tostring(#lines))

record("buffer filetype is java",
  vim.bo[bufnr].filetype == "java",
  "filetype=" .. tostring(vim.bo[bufnr].filetype))

record("buffer is readonly",
  vim.bo[bufnr].readonly == true,
  "readonly=" .. tostring(vim.bo[bufnr].readonly))

-- ─── Test 5: hover request ────────────────────────────────────────────────

-- We can't easily test the UI popup, but we can verify the LSP client is
-- attached by checking that the buffer has LSP clients.
local buf_clients = vim.lsp.get_active_clients({ bufnr = bufnr })
record("LSP client attached to jadx:// buffer", #buf_clients > 0,
  "clients=" .. tostring(#buf_clients))

-- ─── Test 6: open a second class ─────────────────────────────────────────

local fqn2 = "com.example.Helper"
jadx.open(fqn2)

local bufnr2 = vim.fn.bufnr("jadx://" .. fqn2)
record("second jadx:// buffer created", bufnr2 ~= -1)

local loaded2 = vim.wait(5000, function()
  return vim.b[bufnr2] and vim.b[bufnr2].jadx_loaded == true
end, 100)
record("second buffer filled", loaded2)

local lines2 = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
local content2 = table.concat(lines2, "\n")
record("second buffer contains Helper class", content2:find("class Helper") ~= nil)

-- ─── Test 7: unknown class returns fallback source ────────────────────────

jadx.open("com.example.NoSuchClass")
local bufnr3 = vim.fn.bufnr("jadx://com.example.NoSuchClass")
local loaded3 = vim.wait(5000, function()
  return vim.b[bufnr3] and vim.b[bufnr3].jadx_loaded == true
end, 100)
record("unknown class buffer filled", loaded3)

local lines3 = vim.api.nvim_buf_get_lines(bufnr3, 0, -1, false)
local content3 = table.concat(lines3, "\n")
record("unknown class returns fallback source", content3:find("jadx%-stub") ~= nil)

-- ─── Done ─────────────────────────────────────────────────────────────────

write_results()
io.stderr:write(string.format("\nDone: %d passed, %d failed\n", pass_count, fail_count))
vim.cmd("qa!")
