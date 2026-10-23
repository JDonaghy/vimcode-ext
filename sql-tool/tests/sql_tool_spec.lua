-- Black-box test for sql-tool, driving open -> run -> results against a real
-- fixture .db through the real `sqlite3` CLI.
--
-- This mocks the `vimcode` global table (the only surface sql_tool.lua talks
-- to) well enough to load and drive ../sql_tool.lua unmodified, then asserts
-- on the state it produces: the recents list, the query buffer, and the
-- rendered body of the registered results view.
--
-- Run it with:
--   lua5.4 sql_tool_spec.lua
-- from this directory. Requires `lua5.4` and `sqlite3` on PATH; both create
-- and delete a scratch file under /tmp. Neither binary is available in the
-- sandbox this test was written in, so it has been written and committed
-- WITHOUT being run -- see ../README.md's "Manual verification" section.
-- Treat it as a starting point for CI, not as proof the extension works.

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

-- ---------------------------------------------------------------------------
-- Mock `vimcode` global. `storage_backing` is a plain Lua table passed in so
-- two separate "sessions" (two separate loads of sql_tool.lua into two
-- separate mock environments) can share it, simulating vimcode.storage's
-- documented persistence-across-restarts without a real VimCode process.
-- ---------------------------------------------------------------------------

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
                mock.buffer = { name = name, lines = content, opts = opts }
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
                    opts.on_exit(code, nil)
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

local fixture_path = os.tmpname() .. ".db"
os.remove(fixture_path) -- os.tmpname() creates an empty file; sqlite3 wants to create its own

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

mock1.commands.SqlOpen(fixture_path)

ok(mock1.buffer ~= nil, "query scratch buffer opened on SqlOpen")
equals(mock1.buffer.opts and mock1.buffer.opts.filetype, "sql", "query buffer filetype is sql")
equals(mock1.buffer.name, "sql-tool query.sql", "query buffer has a stable, db-independent name")
equals(storage.recents and storage.recents[1], fixture_path, "fixture path remembered as most recent")

-- Simulate the user typing a query into the (now-current) buffer.
mock1.buffer.lines = { "SELECT * FROM t ORDER BY a;" }

mock1.commands.SqlRun("")

ok(mock1.opened_views.sql_tool_results ~= nil, "results view opened on first run")
ok(#mock1.refresh_calls >= 2, "results view refreshed at least once before and after the query")

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
-- Session 1, continued: visual-range execution runs only the selected lines.
-- ---------------------------------------------------------------------------

mock1.buffer.lines = {
    "SELECT * FROM t WHERE a = 1;",
    "SELECT * FROM t WHERE a = 2;",
}
mock1.commands.SqlRun("2,2")
local body4 = mock1.views.sql_tool_results.render(nil)
equals(#body4.rows, 1, "visual-range run executes only the selected line")
equals(body4.rows[1].cells[1], "2", "visual-range run picked the second SELECT, not the first")

-- ---------------------------------------------------------------------------
-- Session 2: a fresh mock sharing the same storage table simulates "recents
-- persist across restarts" without a real VimCode process to restart.
-- ---------------------------------------------------------------------------

local other_fixture = os.tmpname() .. ".db"
os.remove(other_fixture)
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

-- Switching via the picker's on_select must behave exactly like :SqlOpen.
mock2.last_picker.on_select(fixture_path)
mock2.buffer.lines = { "SELECT * FROM t WHERE a = 2;" }
mock2.commands.SqlRun("")
local body5 = mock2.views.sql_tool_results.render(nil)
equals(body5.kind, "table", "switching db via the recents picker reconnects sqlite3 correctly")
equals(body5.rows[1].cells[2], "y", "query after picker-switch ran against the picked database")

-- ---------------------------------------------------------------------------

os.remove(fixture_path)
os.remove(other_fixture)

if failures == 0 then
    print("OK " .. checks .. " checks passed")
    os.exit(0)
else
    io.stderr:write(failures .. " of " .. checks .. " checks failed\n")
    os.exit(1)
end
