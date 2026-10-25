-- Black-box test for sql-tool, driving open -> run -> results against a real
-- fixture .db through the real `sqlite3` CLI.
--
-- This mocks the `vimcode` global table (the only surface sql_tool.lua talks
-- to) well enough to load and drive ../sql_tool.lua unmodified, then asserts
-- on the state it produces: the recents list, the query buffer, and the
-- rendered body of the registered results view.
--
-- Run it with:
--   lua5.4 sql_tool_spec.lua      (or: luajit sql_tool_spec.lua)
-- from this directory. Requires a Lua interpreter and `sqlite3` on PATH; it
-- creates and deletes scratch files under /tmp. It is run during development
-- with `luajit` + `sqlite3`. Two caveats (see ../README.md's "Manual
-- verification"): it is not wired into CI, and `luajit` is Lua 5.1, not the
-- Lua 5.4/mlua sandbox VimCode embeds -- so a real-build smoke is the real
-- proof. Treat this as a fast regression net, not as proof the extension works.

local failures = 0
local checks = 0

local function fail(msg)
  failures = failures + 1
  io.stderr:write("FAIL: " .. msg .. "\n")
end

local function ok(cond, msg)
  checks = checks + 1
  if not cond then
    fail(msg)
  end
end

local function equals(a, b, msg)
  checks = checks + 1
  if a ~= b then
    fail(msg .. " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
  end
end

-- ---------------------------------------------------------------------------
-- Minimal JSON decoder, just enough for `sqlite3 -json` output: arrays of
-- objects whose values are strings, numbers, booleans or null. This backs
-- the mocked vimcode.json.decode below; it is test scaffolding, not part of
-- the extension itself.
-- ---------------------------------------------------------------------------

local json_null = setmetatable({}, { __tostring = function() return "null" end })

local function json_decode(text)
  local pos = 1

  local function skip_ws()
    while pos <= #text and text:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- opening quote
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        error("unterminated string in JSON")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local nxt = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        out[#out + 1] = map[nxt] or nxt
        pos = pos + 2
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end

  local function parse_number()
    local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local numtext = text:sub(s, e)
    pos = e + 1
    return tonumber(numtext)
  end

  local function parse_array()
    pos = pos + 1 -- '['
    local out = {}
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return out
    end
    while true do
      skip_ws()
      out[#out + 1] = parse_value()
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "]" then
        pos = pos + 1
        return out
      else
        error("malformed JSON array at byte " .. pos)
      end
    end
  end

  local function parse_object()
    pos = pos + 1 -- '{'
    local out = {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return out
    end
    while true do
      skip_ws()
      if text:sub(pos, pos) ~= '"' then
        error("expected string key in JSON object at byte " .. pos)
      end
      local key = parse_string()
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        error("expected ':' in JSON object at byte " .. pos)
      end
      pos = pos + 1
      skip_ws()
      out[key] = parse_value()
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "}" then
        pos = pos + 1
        return out
      else
        error("malformed JSON object at byte " .. pos)
      end
    end
  end

  parse_value = function()
    skip_ws()
    local c = text:sub(pos, pos)
    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return json_null
    else
      return parse_number()
    end
  end

  skip_ws()
  return parse_value()
end

-- ---------------------------------------------------------------------------
-- Process helper: synchronously shells out and reports stdout, exit code and
-- stderr. sql_tool.lua only ever sees this through the mocked
-- vimcode.loop.spawn below, so the extension's own code never knows this
-- test runs it synchronously rather than through a real event loop.
-- ---------------------------------------------------------------------------

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run_process(cmd, args)
  local stderr_path = os.tmpname()
  local parts = { shell_quote(cmd) }
  for _, a in ipairs(args or {}) do
    parts[#parts + 1] = shell_quote(a)
  end
  local full = table.concat(parts, " ") .. " 2>" .. shell_quote(stderr_path)
  local pipe = io.popen(full .. "; echo EXITCODE:$?")
  local output = pipe:read("*a")
  pipe:close()
  local body, exit_code = output:match("^(.*)EXITCODE:(%d+)%s*\n?$")
  local stderr = ""
  local ef = io.open(stderr_path, "r")
  if ef then
    stderr = ef:read("*a") or ""
    ef:close()
  end
  os.remove(stderr_path)
  return body or "", tonumber(exit_code) or 1, stderr
end

-- Creates a fresh, not-yet-existing path suitable for a sqlite3 database
-- file. `os.tmpname()` creates an *empty file* at the name it returns, so
-- using that name directly (or appending a suffix and removing the wrong
-- path) leaks a stray /tmp file on every run; this removes the file
-- `os.tmpname()` actually created before handing back a `.db`-suffixed path
-- for sqlite3 to create itself.
local function fresh_db_path()
  local base = os.tmpname()
  os.remove(base)
  return base .. ".db"
end

-- ---------------------------------------------------------------------------
-- Mock `vimcode` global. `storage_backing` is a plain Lua table passed in so
-- two separate "sessions" (two separate loads of sql_tool.lua into two
-- separate mock environments) can share it, simulating vimcode.storage's
-- documented persistence-across-restarts without a real VimCode process.
-- ---------------------------------------------------------------------------

-- Mirrors the real engine's `vimcode.buf.lines()` contract (confirmed via
-- `plugin.rs`'s ropey-backed lines() path): splitting on "\n" keeps each
-- line's own trailing newline attached, so a scratch buffer's `lines` table
-- here looks the same as what sql_tool.lua would see for real.
local function content_to_lines(content)
  local lines = {}
  local pos = 1
  local len = #content
  while pos <= len do
    local nl = content:find("\n", pos)
    if nl then
      lines[#lines + 1] = content:sub(pos, nl)
      pos = nl + 1
    else
      lines[#lines + 1] = content:sub(pos)
      pos = len + 1
    end
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

local function make_mock(storage_backing)
  storage_backing = storage_backing or {}

  local mock = {
    commands = {},
    keymaps = {},
    views = {},
    messages = {},
    opened_views = {},
    refresh_calls = {},
    command_run_calls = {},
    last_picker = nil,
    panels = {},
    panel_items = {},
    panel_help = {},
    handlers = {},
    registers = {},
    -- Spawn lifecycle control. "sync" (default) fires on_exit inside spawn()
    -- like the original mock; "defer" captures each on_exit in pending_spawns
    -- so a test can fire (or never fire) them out of band, exercising the real
    -- engine's asynchronous on_exit the synchronous mock cannot.
    spawn_mode = "sync",
    pending_spawns = {},
  }

  mock.vimcode = {
    command = function(name, fn)
      mock.commands[name] = fn
    end,

    keymap = {
      set = function(mode, key, fn)
        mock.keymaps[mode .. ":" .. key] = fn
      end,
    },

    message = function(text)
      mock.messages[#mock.messages + 1] = text
    end,

    command_run = function(cmd)
      mock.command_run_calls[#mock.command_run_calls + 1] = cmd
    end,

    -- Event registration: store the handler so the test can fire it directly.
    on = function(event, fn)
      mock.handlers[event] = fn
    end,

    -- Sidebar panel surface (vimcode.panel.*). Enough to drive the object
    -- panel: register, help, per-section item lists, and parse_event, which
    -- splits the "panel|section|id|key|index" event argument the engine sends.
    panel = {
      register = function(name, def)
        mock.panels[name] = def
        mock.panel_items[name] = mock.panel_items[name] or {}
      end,
      set_help = function(name, help)
        mock.panel_help[name] = help
      end,
      set_items = function(name, section, items)
        mock.panel_items[name] = mock.panel_items[name] or {}
        mock.panel_items[name][section] = items
      end,
      set_hover = function() end,
      parse_event = function(arg)
        local parts = {}
        for field in (arg .. "|"):gmatch("([^|]*)|") do
          parts[#parts + 1] = field
        end
        return {
          panel = parts[1] or "",
          section = parts[2] or "",
          id = parts[3] or "",
          key = parts[4] or "",
          index = tonumber(parts[5]) or 0,
        }
      end,
    },

    state = {
      set_register = function(reg, text, linewise)
        mock.registers[reg] = text
        -- Keep the full last call so a test can assert the register char and
        -- the charwise/linewise flag, not just the text landing in `+`.
        mock.last_set_register = { reg = reg, text = text, linewise = linewise }
      end,
    },

    schedule = function(fn)
      -- Synchronous test harness: run on the "next idle tick" right now.
      fn()
    end,

    defer = function(_, fn)
      fn()
    end,

    json = {
      null = json_null,
      decode = function(text)
        return json_decode(text)
      end,
      encode = function(value)
        error("not implemented in this test's mock")
      end,
    },

    storage = {
      get = function(key)
        return storage_backing[key]
      end,
      set = function(key, value)
        storage_backing[key] = value
      end,
      delete = function(key)
        storage_backing[key] = nil
      end,
      keys = function()
        local out = {}
        for k in pairs(storage_backing) do
          out[#out + 1] = k
        end
        return out
      end,
    },

    buf = {
      open_scratch = function(name, content, opts)
        -- The real `vimcode.buf.open_scratch` takes `content` as a String;
        -- passing a table (as an earlier version of sql_tool.lua did) can't
        -- be coerced by mlua and raises. Enforcing the type here turns that
        -- class of regression into a loud test failure instead of a
        -- silently-swallowed runtime error.
        assert(type(content) == "string", "open_scratch content must be a string, got " .. type(content))
        mock.buffer = { name = name, lines = content_to_lines(content), opts = opts }
      end,
      lines = function()
        return mock.buffer and mock.buffer.lines or {}
      end,
      line = function(n)
        return mock.buffer and mock.buffer.lines[n] or nil
      end,
    },

    ui = {
      register_view = function(name, def)
        mock.views[name] = def
      end,
      open_view = function(name, opts)
        mock.opened_views[name] = opts
      end,
      refresh = function(name)
        mock.refresh_calls[#mock.refresh_calls + 1] = name
      end,
    },

    picker = {
      open = function(opts)
        mock.last_picker = opts
        return {
          set_items = function() end,
          append = function() end,
          set_loading = function() end,
          close = function() end,
        }
      end,
    },

    loop = {
      spawn = function(cmd, args, opts)
        opts = opts or {}
        local stdout, code, stderr = run_process(cmd, args)
        if opts.on_stdout and stdout ~= "" then
          opts.on_stdout(stdout)
        end
        if opts.on_stderr and stderr ~= "" then
          opts.on_stderr(stderr)
        end
        if opts.on_exit then
          if mock.spawn_mode == "defer" then
            -- Capture the exit; the test fires it (or doesn't) explicitly.
            mock.pending_spawns[#mock.pending_spawns + 1] = function()
              opts.on_exit(code, nil)
            end
          else
            opts.on_exit(code, nil)
          end
        end
        return {
          write = function() end,
          close_stdin = function() end,
          kill = function() end,
        }
      end,
    },
  }

  return mock
end

-- Loads sql_tool.lua into a fresh _ENV with `vimcode` as the given mock's
-- table, so each "session" gets its own copy of the extension's local state
-- (current_db, columns, rows, etc.) while optionally sharing storage. Lua
-- 5.4 has no setfenv, so the chunk is `load()`-ed directly with an explicit
-- env rather than patched after loadfile().
local function load_extension(mock)
  local self_dir = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
  local f = assert(io.open(self_dir .. "../sql_tool.lua", "r"))
  local source = f:read("*a")
  f:close()
  local env = setmetatable({ vimcode = mock.vimcode }, { __index = _G })
  local chunk = assert(load(source, "sql_tool.lua", "t", env))
  chunk()
end

-- ---------------------------------------------------------------------------
-- Fixture database
-- ---------------------------------------------------------------------------

local fixture_path = fresh_db_path()

local function sqlite_exec(path, sql)
  local _, code, stderr = run_process("sqlite3", { path, sql })
  if code ~= 0 then
    error("failed to set up fixture: " .. stderr)
  end
end

sqlite_exec(fixture_path, "CREATE TABLE t (a INTEGER, b TEXT); INSERT INTO t VALUES (1, 'x'), (2, 'y');")

-- ---------------------------------------------------------------------------
-- Session 1: open the fixture, run a SELECT, check the rendered results.
-- ---------------------------------------------------------------------------

local storage = {}
local mock1 = make_mock(storage)
load_extension(mock1)

ok(mock1.commands.SqlOpen ~= nil, "SqlOpen command registered")
ok(mock1.commands.SqlRun ~= nil, "SqlRun command registered")
ok(mock1.commands.SqlPickRecent ~= nil, "SqlPickRecent command registered")
ok(mock1.views.sql_tool_results ~= nil, "results view registered")
equals(mock1.views.sql_tool_results.sidebar, false,
  "results view registered sidebar=false (no stray activity-bar icon)")

mock1.commands.SqlOpen(fixture_path)

ok(mock1.buffer ~= nil, "query scratch buffer opened on SqlOpen")
equals(mock1.buffer.opts and mock1.buffer.opts.filetype, "sql", "query buffer filetype is sql")
equals(mock1.buffer.opts and mock1.buffer.opts.readonly, false, "query buffer opened writable, not read-only")
equals(mock1.buffer.name, "sql-tool query.sql", "query buffer has a stable, db-independent name")
equals(storage.recents and storage.recents[1], fixture_path, "fixture path remembered as most recent")

-- Regression: the seeded buffer's first line is a `-- <path>` comment, so a
-- whole-buffer run hands sqlite3 a SQL string starting with "--". Without the
-- `--` end-of-options sentinel in the spawn argv, sqlite3 rejects that as
-- `unknown option: -` and nothing runs. Append a real query to the *seeded*
-- buffer (do not replace it, which is what masked this bug before) and run the
-- whole thing -- the way <leader>r does by default.
do
  mock1.buffer.lines[#mock1.buffer.lines + 1] = "SELECT * FROM t ORDER BY a;"
  mock1.commands.SqlRun("")
  local seeded = mock1.views.sql_tool_results.render(nil)
  equals(seeded.kind, "table",
    "whole-buffer run including the seeded '-- <path>' comment executes (no 'unknown option: -')")
  equals(#seeded.rows, 2, "seeded-comment whole-buffer run returns both rows")
end

-- Simulate the user typing a query into the (now-current) buffer.
mock1.buffer.lines = { "SELECT * FROM t ORDER BY a;" }

mock1.commands.SqlRun("")

ok(mock1.opened_views.sql_tool_results ~= nil, "results view opened on first run")
equals(mock1.opened_views.sql_tool_results.location, "tab", "results open as their own tab")
ok(#mock1.refresh_calls >= 2, "results view refreshed at least once before and after the query")
-- A completion message is printed so a background re-run isn't silent.
ok(mock1.messages[#mock1.messages] and mock1.messages[#mock1.messages]:match("row"),
  "a successful run announces its row count in the status line")

local body1 = mock1.views.sql_tool_results.render(nil)
equals(body1.kind, "table", "render() returns a table body for a successful query")
equals(#body1.columns, 2, "two columns inferred from the query")
equals(body1.columns[1].title, "a", "columns sorted alphabetically: a first")
equals(body1.columns[2].title, "b", "columns sorted alphabetically: b second")
equals(#body1.rows, 2, "two rows returned")
equals(body1.rows[1].cells[1], "1", "row 1 column a")
equals(body1.rows[1].cells[2], "x", "row 1 column b")
equals(body1.rows[2].cells[1], "2", "row 2 column a")
equals(body1.rows[2].cells[2], "y", "row 2 column b")

-- #2034: each results column declares a `min_width` floored at its header
-- width, so a column name can't be squeezed to an unreadable sliver.
equals(body1.columns[1].min_width, #"a", "column 'a' declares min_width = its header width")
equals(body1.columns[2].min_width, #"b", "column 'b' declares min_width = its header width")

-- #2034: a header click is delivered to on_event. The engine itself reorders
-- the painted rows (numeric-aware, 3-state); our handler only mirrors that
-- cycle (unsorted -> asc -> desc -> unsorted) onto the status line, and must
-- NOT reorder our own rows. Column 'a' is display index 0 (0-based `col`).
ok(mock1.views.sql_tool_results.on_event ~= nil, "results view registers an on_event handler")
mock1.views.sql_tool_results.on_event(nil, { kind = "HeaderClicked", col = 0 })
ok(mock1.messages[#mock1.messages]:match("sorted by a asc"), "first header click reports asc")
mock1.views.sql_tool_results.on_event(nil, { kind = "HeaderClicked", col = 0 })
ok(mock1.messages[#mock1.messages]:match("sorted by a desc"), "second click on same header reports desc")
mock1.views.sql_tool_results.on_event(nil, { kind = "HeaderClicked", col = 0 })
ok(mock1.messages[#mock1.messages]:match("cleared sort on a"), "third click clears the sort")
local after_click = mock1.views.sql_tool_results.render(nil)
equals(after_click.rows[1].cells[1], "1",
  "a header click does not reorder our own rows (the engine's overlay paints the order)")
-- A non-header event, and an out-of-range column index, are both ignored.
local msgs_pre_hdr = #mock1.messages
mock1.views.sql_tool_results.on_event(nil, { kind = "ItemSelected", index = 0 })
mock1.views.sql_tool_results.on_event(nil, { kind = "HeaderClicked", col = 99 })
equals(#mock1.messages, msgs_pre_hdr, "a non-header event and an out-of-range header click are ignored")

equals(mock1.commands.SqlCopyResults ~= nil, true, "SqlCopyResults command registered")

-- ---------------------------------------------------------------------------
-- :SqlCopyResults formats the WHOLE result set and writes it to the "+"
-- register (the OS clipboard). Runs in its own throwaway session + database so
-- it can use a fixture with the tricky values each format must handle without
-- polluting the shared fixture the panel/catalog checks inspect: a comma + an
-- embedded double quote (CSV quoting), an embedded tab (TSV collapses it, JSON
-- escapes it), a pipe (Markdown escapes it) and a NULL (empty field / JSON
-- null / empty md cell). Column order is the sorted union c1,c2,c3; row order
-- is query order.
-- ---------------------------------------------------------------------------

local function has(haystack, needle)
  return haystack ~= nil and haystack:find(needle, 1, true) ~= nil
end

do
  local copy_db = fresh_db_path()
  sqlite_exec(copy_db,
    "CREATE TABLE weird (c1 TEXT, c2 TEXT, c3 INTEGER);"
    .. " INSERT INTO weird VALUES ('comma,\"q\"', 'tab' || char(9) || 'x', 7);"
    .. " INSERT INTO weird VALUES ('pipe|y', NULL, NULL);")
  local mc = make_mock({})
  load_extension(mc)
  mc.commands.SqlOpen(copy_db)
  mc.buffer.lines = { "SELECT c1, c2, c3 FROM weird ORDER BY c1;" }
  mc.commands.SqlRun("")
  equals(mc.views.sql_tool_results.render(nil).kind, "table", "weird-values query renders a table")

  mc.commands.SqlCopyResults("csv")
  local copy_csv = mc.registers["+"]
  ok(has(copy_csv, "c1,c2,c3\n"), "csv emits a header row first")
  ok(has(copy_csv, '"comma,""q"""'), "csv quotes a comma/quote field and doubles the quote (RFC 4180)")
  ok(has(copy_csv, "\tx,7"), "csv leaves an embedded tab unquoted (tab is not a CSV special)")
  ok(has(copy_csv, "pipe|y,,"), "csv renders two trailing NULLs as empty fields")
  equals(mc.last_set_register.reg, "+", "copy writes the \"+\" (system clipboard) register")
  equals(mc.last_set_register.linewise, false, "copy writes charwise, not linewise")

  mc.commands.SqlCopyResults("tsv")
  local copy_tsv = mc.registers["+"]
  ok(has(copy_tsv, "c1\tc2\tc3"), "tsv emits a tab-joined header")
  ok(has(copy_tsv, "tab x"), "tsv collapses an embedded tab in a value to a space")
  ok(has(copy_tsv, 'comma,"q"'), "tsv leaves commas/quotes in a value untouched")

  mc.commands.SqlCopyResults("json")
  local copy_json = mc.registers["+"]
  ok(has(copy_json, '"c3": 7'), "json keeps a numeric cell as a bare number")
  ok(has(copy_json, '"c3": null'), "json renders NULL as the json null literal")
  ok(has(copy_json, '"c2": "tab\\tx"'), "json escapes an embedded tab as \\t")
  ok(has(copy_json, '"c1": "comma,\\"q\\""'), "json escapes an embedded double quote")

  mc.commands.SqlCopyResults("md")
  local copy_md = mc.registers["+"]
  ok(has(copy_md, "| c1 | c2 | c3 |"), "md emits a header row")
  ok(has(copy_md, "| --- | --- | --- |"), "md emits the separator row")
  ok(has(copy_md, "| pipe\\|y |  |  |"), "md escapes a pipe and renders NULLs as empty cells")

  -- Default format is csv; aliases resolve; an unknown format is refused
  -- without touching the clipboard.
  mc.commands.SqlCopyResults("")
  ok(has(mc.registers["+"], "c1,c2,c3\n"), "no-arg copy defaults to csv")
  mc.commands.SqlCopyResults("markdown")
  ok(has(mc.registers["+"], "| --- | --- | --- |"), "\"markdown\" is an alias for md")
  local reg_before_bad = mc.registers["+"]
  local msgs_before_bad = #mc.messages
  mc.commands.SqlCopyResults("xml")
  equals(mc.registers["+"], reg_before_bad, "an unknown format leaves the clipboard unchanged")
  ok(mc.messages[#mc.messages]:match("unknown format"), "an unknown format reports the error")
  ok(#mc.messages > msgs_before_bad, "an unknown format still emits a message")
end

-- Copy with no result set yet (a fresh session, no query) writes nothing.
do
  local mock_empty = make_mock({})
  load_extension(mock_empty)
  mock_empty.commands.SqlCopyResults("")
  equals(mock_empty.registers["+"], nil, "copy with no results writes nothing to the clipboard")
  ok(mock_empty.messages[#mock_empty.messages]:match("nothing to copy"),
    "copy with no results reports nothing to copy")
end

-- ---------------------------------------------------------------------------
-- Session 1, continued: a failing query must surface an error and must not
-- discard the ability to keep issuing commands (the "editor stays responsive"
-- requirement -- this test can't prove non-blocking I/O, but it does prove
-- the extension doesn't throw or wedge its own state on error).
-- ---------------------------------------------------------------------------

mock1.buffer.lines = { "SELECT * FROM nosuchtable;" }
mock1.commands.SqlRun("")

local body2 = mock1.views.sql_tool_results.render(nil)
equals(body2.kind, "text_view", "render() falls back to text_view on error")
ok(body2.text:match("no such table"), "error text surfaces sqlite3's own message")

-- A later successful query must still work after an error -- state wasn't
-- left stuck in "running".
mock1.buffer.lines = { "SELECT * FROM t WHERE a = 1;" }
mock1.commands.SqlRun("")
local body3 = mock1.views.sql_tool_results.render(nil)
equals(body3.kind, "table", "a query after an error still renders a table")
equals(#body3.rows, 1, "the post-error query returns the expected single row")

-- ---------------------------------------------------------------------------
-- Session 1, continued: a hand-typed numeric range runs only those lines.
-- ---------------------------------------------------------------------------

mock1.buffer.lines = {
  "SELECT * FROM t WHERE a = 1;",
  "SELECT * FROM t WHERE a = 2;",
}
mock1.commands.SqlRun("2,2")
local body4 = mock1.views.sql_tool_results.render(nil)
equals(#body4.rows, 1, "numeric-range run executes only the selected line")
equals(body4.rows[1].cells[1], "2", "numeric-range run picked the second SELECT, not the first")

-- ---------------------------------------------------------------------------
-- Session 2: a fresh mock sharing the same storage table simulates "recents
-- persist across restarts" without a real VimCode process to restart.
-- ---------------------------------------------------------------------------

local other_fixture = fresh_db_path()
sqlite_exec(other_fixture, "CREATE TABLE u (c TEXT); INSERT INTO u VALUES ('z');")

local mock2 = make_mock(storage)
load_extension(mock2)
mock2.commands.SqlOpen(other_fixture)

equals(storage.recents[1], other_fixture, "newest open is most recent")
equals(storage.recents[2], fixture_path, "earlier session's database is still remembered")

mock2.commands.SqlPickRecent("")
ok(mock2.last_picker ~= nil, "SqlPickRecent opens a picker")
equals(#mock2.last_picker.items, 2, "picker lists both remembered databases")
equals(mock2.last_picker.items[1].data, other_fixture, "picker lists most-recent database first")

-- Switching via the picker's on_select must behave exactly like :SqlOpen,
-- and must not recreate (and so not clobber) the query buffer: it was
-- already opened once this session, by the SqlOpen call above.
local buffer_before_switch = mock2.buffer
mock2.last_picker.on_select(fixture_path)
ok(mock2.buffer == buffer_before_switch, "switching database via the picker does not recreate the query buffer")
mock2.buffer.lines = { "SELECT * FROM t WHERE a = 2;" }
mock2.commands.SqlRun("")
local body5 = mock2.views.sql_tool_results.render(nil)
equals(body5.kind, "table", "switching db via the recents picker reconnects sqlite3 correctly")
equals(body5.rows[1].cells[2], "y", "query after picker-switch ran against the picked database")

-- ---------------------------------------------------------------------------
-- Session 3: a nonexistent path is refused up front -- no query buffer, no
-- recents churn, and a message explaining why -- rather than a silent
-- "connected" that only fails later (sqlite3 would create an empty db on the
-- first query, hiding the mistake as a baffling "no such table").
-- ---------------------------------------------------------------------------

local mock3 = make_mock({})
load_extension(mock3)
local missing = fresh_db_path() -- fresh_db_path removes the file it names, so this points at nothing
mock3.commands.SqlOpen(missing)
ok(mock3.buffer == nil, "SqlOpen on a missing path does not open a query buffer")
ok(#mock3.messages > 0 and mock3.messages[#mock3.messages]:match("cannot open"),
  "SqlOpen on a missing path reports it cannot open the file")

-- ---------------------------------------------------------------------------
-- Session 4: :SqlSort reorders results by a column, numeric-aware. The whole
-- point is that a numeric column sorts numerically, not lexicographically
-- ("1000" < "750" as strings, but 90 < 750 < 1000 as numbers), and that NULLs
-- sort first ascending / last descending.
-- ---------------------------------------------------------------------------

local sort_fixture = fresh_db_path()
sqlite_exec(sort_fixture,
  "CREATE TABLE n (v INTEGER, label TEXT); " ..
  "INSERT INTO n VALUES (1000, 'k'), (750, 'm'), (90, 'z'), (NULL, 'nullrow');")

local mock4 = make_mock({})
load_extension(mock4)
mock4.commands.SqlOpen(sort_fixture)
mock4.buffer.lines = { "SELECT v, label FROM n;" }
mock4.commands.SqlRun("")

-- Columns are displayed alphabetically: label (index 1), v (index 2).
local pre_sort = mock4.views.sql_tool_results.render(nil)
equals(pre_sort.columns[1].title, "label", "sort fixture: column 1 is label")
equals(pre_sort.columns[2].title, "v", "sort fixture: column 2 is v")

mock4.commands.SqlSort("v asc")
local asc = mock4.views.sql_tool_results.render(nil)
equals(asc.rows[1].cells[2], "", "null sorts first when ascending")
equals(asc.rows[2].cells[2], "90", "numeric asc: 90 comes before 750/1000 (not lexicographic)")
equals(asc.rows[3].cells[2], "750", "numeric asc: 750 second")
equals(asc.rows[4].cells[2], "1000", "numeric asc: 1000 last")

mock4.commands.SqlSort("v desc")
local desc = mock4.views.sql_tool_results.render(nil)
equals(desc.rows[1].cells[2], "1000", "numeric desc: 1000 first")
equals(desc.rows[4].cells[2], "", "null sorts last when descending")

-- A 1-based column index is accepted as well as a name.
mock4.commands.SqlSort("1 asc")
local by_index = mock4.views.sql_tool_results.render(nil)
equals(by_index.rows[1].cells[1], "k", "string column sorted ascending by index (k < m < z)")
equals(by_index.rows[4].cells[1], "z", "string column ascending puts z last")

-- A bad column is reported, not silently ignored, and leaves rows untouched.
local msgs_before = #mock4.messages
mock4.commands.SqlSort("nosuchcol")
ok(mock4.messages[#mock4.messages]:match("no such column"), "SqlSort on an unknown column reports it")
local after_bad = mock4.views.sql_tool_results.render(nil)
equals(after_bad.rows[1].cells[1], "k", "a failed sort leaves the existing order untouched")
ok(#mock4.messages > msgs_before, "a failed sort still emits a message")

-- ---------------------------------------------------------------------------
-- Session 5: the database object panel. The panel is registered at load;
-- connecting populates Tables/Views from the catalog query; Enter and
-- right-click on a table run "Select top N" / expose actions.
-- ---------------------------------------------------------------------------

local mock5 = make_mock({})
load_extension(mock5)
ok(mock5.panels["sql_tool"] ~= nil, "database panel registered at load")

mock5.commands.SqlOpen(fixture_path) -- fixture has one table `t`, no views
local tables_section = mock5.panel_items["sql_tool"] and mock5.panel_items["sql_tool"]["Tables"]
ok(tables_section ~= nil and #tables_section == 1, "connecting populates the Tables section (one table)")
equals(tables_section[1].text, "t", "the fixture table 't' is listed in the panel")
equals(#(mock5.panel_items["sql_tool"]["Views"] or {}), 0, "no views listed for the fixture")

-- Enter on the table runs SELECT * ... LIMIT N into the results grid.
mock5.handlers["panel_select"]("sql_tool|Tables|t||0")
local panel_sel = mock5.views.sql_tool_results.render(nil)
equals(panel_sel.kind, "table", "selecting a panel table runs a query into the results grid")
equals(#panel_sel.rows, 2, "select-top-N returned the fixture's two rows")

-- Right-click opens an actions picker; "Copy name" copies the object name.
mock5.handlers["panel_context_menu"]("sql_tool|Tables|t||0")
ok(mock5.last_picker ~= nil and #mock5.last_picker.items == 2, "right-click opens a two-action picker")
mock5.last_picker.on_select("copy")
equals(mock5.registers["+"], "t", "the copy-name action copies the object name to the clipboard")

-- Tab-expanding a table lazily loads its columns as indented child rows.
mock5.handlers["panel_expand"]("sql_tool|Tables|t||0")
local expanded_tables = mock5.panel_items["sql_tool"]["Tables"]
equals(#expanded_tables, 3, "expanding table 't' adds its two columns as child rows")
equals(expanded_tables[1].text, "t", "the table row stays first after expansion")
ok(expanded_tables[1].expanded == true, "the expanded table row is marked expanded")
equals(expanded_tables[2].text, "a", "first column 'a' listed in definition order")
equals(expanded_tables[2].parent_id, "t", "column rows are children of their table")
equals(expanded_tables[2].indent, 1, "column rows are indented under the table")
equals(expanded_tables[3].text, "b", "second column 'b' listed after 'a'")

-- Selecting a column copies its name.
mock5.handlers["panel_select"]("sql_tool|Tables|col::t::b||0")
equals(mock5.registers["+"], "b", "selecting a column copies the column name to the clipboard")

-- Collapsing hides the column children again.
mock5.handlers["panel_collapse"]("sql_tool|Tables|t||0")
equals(#mock5.panel_items["sql_tool"]["Tables"], 1, "collapsing a table hides its column children")

-- The Disconnect action key 'd' (panel_action, from anywhere in the panel)
-- clears the tree.
mock5.handlers["panel_action"]("sql_tool|Connection|__status__|d|0")
equals(#(mock5.panel_items["sql_tool"]["Tables"] or {}), 0, "disconnect clears the Tables tree")
ok(mock5.messages[#mock5.messages]:match("disconnected"), "disconnect reports it")

-- ---------------------------------------------------------------------------
-- Session 6: the connection dialog (a register_view form). Filling in a name
-- and a path and clicking Connect opens the database, populates the tree, and
-- saves the connection -- which then appears in the panel's Connection section
-- and can be reconnected from the connect picker.
-- ---------------------------------------------------------------------------

local storage6 = {}
local mock6 = make_mock(storage6)
load_extension(mock6)

local dialog = mock6.views["sql_tool_conn"]
ok(dialog ~= nil, "connection dialog view registered at load")
equals(dialog.sidebar, false, "connection dialog registered sidebar=false (opened only as a tab)")
ok(mock6.commands.SqlNewConnection ~= nil, "SqlNewConnection command registered")
ok(mock6.commands.SqlConnections ~= nil, "SqlConnections command registered")

-- The dialog renders a field stack with a name, an engine dropdown, the
-- SQLite path field, and a Connect button.
local form = dialog.render(nil)
ok(form.fields ~= nil, "dialog renders a field stack")
local has_path, has_connect = false, false
for _, f in ipairs(form.fields) do
  if f.id == "f:path" then has_path = true end
  if f.id == "connect" and f.type == "button" then has_connect = true end
end
ok(has_path, "dialog shows the SQLite 'path' field")
ok(has_connect, "dialog has a Connect button")

-- Fill in the form and click Connect.
dialog.on_event(nil, { kind = "TextChanged", widget_id = "name", value = "myfix" })
dialog.on_event(nil, { kind = "TextChanged", widget_id = "f:path", value = fixture_path })
dialog.on_event(nil, { kind = "ButtonClicked", widget_id = "connect" })

local dlg_tables = mock6.panel_items["sql_tool"]["Tables"]
ok(dlg_tables and #dlg_tables == 1 and dlg_tables[1].text == "t",
  "dialog Connect opened the database and populated the tree")

equals(storage6.connections and #storage6.connections, 1, "the connection was persisted")
equals(storage6.connections[1].name, "myfix", "the saved connection kept its name")
equals(storage6.connections[1].values.path, fixture_path, "the saved connection kept its path")
local conn_section = mock6.panel_items["sql_tool"]["Connection"]
ok(#conn_section >= 2, "the saved connection appears below the toolbar row")
equals(conn_section[2].text, "myfix", "the saved connection row shows its name")

-- Reconnecting from a saved config (as the panel's connect picker does).
mock6.commands.SqlConnections("")
ok(mock6.last_picker ~= nil and #mock6.last_picker.items == 1,
  "SqlConnections lists the one saved connection")
mock6.last_picker.on_select(1)
local reconn_tables = mock6.panel_items["sql_tool"]["Tables"]
ok(reconn_tables and #reconn_tables == 1, "connecting from a saved connection repopulates the tree")

-- The panel registers a real clickable toolbar; its buttons drive the same
-- actions as the c/n/d/r keys and fire panel_toolbar("<panel>|<id>").
local toolbar = mock6.panels["sql_tool"].toolbar
ok(toolbar ~= nil and #toolbar == 4, "panel registers a four-button toolbar")
equals(toolbar[1].id, "connect", "first toolbar button is Connect")
equals(toolbar[3].id, "disconnect", "third toolbar button is Disconnect")

-- Clicking Disconnect via the toolbar clears the tree.
mock6.handlers["panel_toolbar"]("sql_tool|disconnect")
equals(#(mock6.panel_items["sql_tool"]["Tables"] or {}), 0, "toolbar Disconnect clears the tree")

-- Clicking Connect via the toolbar opens the connect picker (one saved conn),
-- and picking it repopulates the tree.
mock6.handlers["panel_toolbar"]("sql_tool|connect")
ok(mock6.last_picker ~= nil and #mock6.last_picker.items == 1,
  "toolbar Connect opens the connect picker")
mock6.last_picker.on_select(1)
equals(#mock6.panel_items["sql_tool"]["Tables"], 1,
  "connecting from the toolbar picker repopulates the tree")

-- ---------------------------------------------------------------------------
-- Session 7: asynchronous query lifecycle. The real engine fires on_exit on a
-- later idle tick, and may never fire it at all for a child it had to kill or
-- that an engine edge case dropped. A query whose on_exit never arrives must
-- NOT wedge the extension: a subsequent query must still run. (The earlier
-- hard `running` block stayed stuck true forever in that case -- the exact
-- "after the first error no subsequent command works" bug; the generation
-- token supersedes instead. The synchronous default mock could not catch this.)
-- ---------------------------------------------------------------------------

local mock7 = make_mock({})
load_extension(mock7)
mock7.commands.SqlOpen(fixture_path) -- sync: connect, open buffer, populate tree
mock7.spawn_mode = "defer"

-- Query 1 errors, and we simulate its on_exit NEVER firing (a stuck child).
mock7.buffer.lines = { "SELECT * FROM nosuchtable;" }
mock7.commands.SqlRun("")
equals(#mock7.pending_spawns, 1, "the first query's exit is pending (async, not yet delivered)")

-- Query 2 (valid) must still launch -- it is not blocked by query 1's missing exit.
mock7.buffer.lines = { "SELECT * FROM t ORDER BY a;" }
mock7.commands.SqlRun("")
equals(#mock7.pending_spawns, 2, "a second query launches even though the first's exit never fired")

-- Deliver ONLY query 2's exit (query 1 stays stuck forever).
mock7.pending_spawns[2]()
local body7 = mock7.views.sql_tool_results.render(nil)
equals(body7.kind, "table", "the second query renders results despite the first's exit never arriving")
equals(#body7.rows, 2, "the second query returned both rows")

-- Now deliver query 1's late, stale exit: it is superseded, so it must be
-- ignored rather than clobbering the newer results with its error.
mock7.pending_spawns[1]()
local body7b = mock7.views.sql_tool_results.render(nil)
equals(body7b.kind, "table", "a superseded query's late exit does not overwrite newer results")
equals(#body7b.rows, 2, "the newer results survive the stale exit")

-- ---------------------------------------------------------------------------
-- Session 8: the reported repro exactly -- a bad query, then a good one,
-- delivered sequentially (each query's exit arrives before the next run). The
-- good query must display its rows, not "nothing at all".
-- ---------------------------------------------------------------------------

local mock8 = make_mock({})
load_extension(mock8)
mock8.commands.SqlOpen(fixture_path)
mock8.spawn_mode = "defer"

mock8.buffer.lines = { "SELECT * FROM nosuchtable;" }
mock8.commands.SqlRun("")
mock8.pending_spawns[1]() -- query 1's exit: error
local e8 = mock8.views.sql_tool_results.render(nil)
equals(e8.kind, "text_view", "the bad query shows an error")

mock8.buffer.lines = { "SELECT * FROM t ORDER BY a;" }
mock8.commands.SqlRun("")
mock8.pending_spawns[2]() -- query 2's exit: rows
local g8 = mock8.views.sql_tool_results.render(nil)
equals(g8.kind, "table", "a good query after an error shows a table, not nothing")
equals(#g8.rows, 2, "the good query shows its rows")

-- ---------------------------------------------------------------------------

os.remove(fixture_path)
os.remove(other_fixture)
os.remove(sort_fixture)

if failures == 0 then
  print("OK " .. checks .. " checks passed")
  os.exit(0)
else
  io.stderr:write(failures .. " of " .. checks .. " checks failed\n")
  os.exit(1)
end
