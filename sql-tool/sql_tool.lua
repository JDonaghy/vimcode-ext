-- sql-tool: sqlite3-backed query runner with an async results grid.
--
-- :SqlOpen <path.db>  connect to a sqlite3 database file (persists to recents)
-- :SqlPickRecent      pick a recently-opened database from a fuzzy picker
-- :SqlRun             run the whole query buffer (or, with a visual range,
--                      just the selection) through `sqlite3 -json` and show
--                      the rows in a results tab beside the query buffer
-- <leader>r           normal mode: runs the whole buffer
--                      visual mode: runs the selected lines
--
-- Requires the `sqlite3` CLI on PATH. Every `sqlite3` invocation runs via
-- `vimcode.loop.spawn`, never a blocking shell call, so the editor stays
-- responsive while a query is in flight.

local QUERY_BUFFER_NAME = "sql-tool query.sql"
local RESULTS_VIEW = "sql_tool_results"
local MAX_RECENTS = 10

-- Connection + results state. None of this is persisted except `recents`
-- (via vimcode.storage); everything else is in-memory and reset on reload.
local current_db = nil
local running = false
local status_text = "no database open -- :SqlOpen <path.db>"
local error_text = nil
local columns = {}
local rows = {}
local results_pane_opened = false

-- `vimcode.storage.*` is the one API documented to work at any point,
-- including top-level load, so recents are loaded once here.
local function load_recents()
    local ok, recents = pcall(vimcode.storage.get, "recents")
    if ok and type(recents) == "table" then
        return recents
    end
    return {}
end

local function save_recents(recents)
    pcall(vimcode.storage.set, "recents", recents)
end

local function remember_recent(path)
    local recents = load_recents()
    local deduped = {}
    for _, existing in ipairs(recents) do
        if existing ~= path then
            deduped[#deduped + 1] = existing
        end
    end
    table.insert(deduped, 1, path)
    while #deduped > MAX_RECENTS do
        table.remove(deduped)
    end
    save_recents(deduped)
end

-- Convert a decoded `sqlite3 -json` cell into display text. Lua's JSON
-- decoder represents `null` as the `vimcode.json.null` sentinel and booleans
-- as real booleans; sqlite3 itself has no boolean type, but normalize it
-- here defensively in case a column stores 0/1 via an affinity check.
local function cell_to_string(value)
    if value == nil or value == vimcode.json.null then
        return ""
    elseif value == true then
        return "true"
    elseif value == false then
        return "false"
    else
        return tostring(value)
    end
end

-- Table-kind view rows need a stable `id` per row and `cells` as a flat
-- list of strings, in column order. Column names come from the union of
-- keys across every returned row (sqlite3 -json rows can vary in which
-- keys are present with NULL columns), sorted for a stable column order.
local function rows_from_json(decoded)
    local cols, result_rows = {}, {}
    if type(decoded) ~= "table" or decoded[1] == nil then
        -- Empty result set: `sqlite3 -json` prints "[]" for zero rows, so
        -- there is no header to recover column names from. This is a real
        -- limitation of driving `sqlite3 -json` rather than PRAGMA
        -- table_info -- an empty SELECT shows an empty table with no
        -- column headers, not "0 of N columns".
        return cols, result_rows
    end
    local seen = {}
    for _, row in ipairs(decoded) do
        if type(row) == "table" then
            for key in pairs(row) do
                if not seen[key] then
                    seen[key] = true
                    cols[#cols + 1] = key
                end
            end
        end
    end
    table.sort(cols)
    for i, row in ipairs(decoded) do
        local cells = {}
        for ci, col in ipairs(cols) do
            cells[ci] = cell_to_string(row[col])
        end
        result_rows[i] = { id = "row" .. i, cells = cells }
    end
    return cols, result_rows
end

-- Opening the results view in a side-by-side split is done once, the
-- first time a query runs. `vimcode.command_run` is queued (applied after
-- this callback returns) while `vimcode.ui.open_view` is immediate, so the
-- split has to land first: `vimcode.schedule` defers the open_view call to
-- the next idle tick, after the queued vsplit has been applied. This
-- ordering is the best fit for the documented primitives, but it is not
-- independently verified against a live editor in this sandbox -- see
-- README.md's "Known assumptions" section.
local function ensure_results_pane_open()
    if results_pane_opened then
        return
    end
    results_pane_opened = true
    vimcode.command_run("vsplit")
    vimcode.schedule(function()
        vimcode.ui.open_view(RESULTS_VIEW, { location = "tab" })
    end)
end

local function run_query(sql)
    sql = sql and sql:match("^%s*(.-)%s*$") or ""
    if current_db == nil then
        vimcode.message("sql-tool: no database open -- :SqlOpen <path.db>")
        return
    end
    if sql == "" then
        vimcode.message("sql-tool: nothing to run")
        return
    end
    if running then
        vimcode.message("sql-tool: a query is already running")
        return
    end

    running = true
    status_text = "running..."
    error_text = nil
    ensure_results_pane_open()
    vimcode.ui.refresh(RESULTS_VIEW)

    local out_chunks, err_chunks = {}, {}
    local ok_spawn, err = pcall(vimcode.loop.spawn, "sqlite3", { current_db, "-json", sql }, {
        on_stdout = function(chunk)
            out_chunks[#out_chunks + 1] = chunk
        end,
        on_stderr = function(chunk)
            err_chunks[#err_chunks + 1] = chunk
        end,
        on_exit = function(code, signal)
            running = false
            local stdout = table.concat(out_chunks)
            local stderr = table.concat(err_chunks)

            if signal ~= nil then
                status_text = "error"
                error_text = "sqlite3 was killed (signal " .. tostring(signal) .. ")"
            elseif code ~= 0 then
                status_text = "error"
                error_text = (stderr ~= "" and stderr) or ("sqlite3 exited with status " .. tostring(code))
            else
                local ok_json, decoded = pcall(vimcode.json.decode, stdout == "" and "[]" or stdout)
                if not ok_json then
                    status_text = "error"
                    error_text = "could not parse sqlite3 output as JSON: " .. tostring(decoded)
                else
                    columns, rows = rows_from_json(decoded)
                    if stderr ~= "" then
                        -- sqlite3 can print warnings to stderr on a clean
                        -- exit (e.g. deprecated pragma warnings); surface
                        -- them without discarding the rows it did return.
                        status_text = "ok (" .. #rows .. " row(s), with warnings)"
                        error_text = stderr
                    else
                        status_text = "ok (" .. #rows .. " row(s))"
                        error_text = nil
                    end
                end
            end

            vimcode.ui.refresh(RESULTS_VIEW)
        end,
    })

    if not ok_spawn then
        running = false
        status_text = "error"
        error_text = "could not start sqlite3: " .. tostring(err)
        vimcode.ui.refresh(RESULTS_VIEW)
    end
end

local function open_db(path)
    current_db = path
    remember_recent(path)
    status_text = "connected -- no query run yet"
    error_text = nil
    columns, rows = {}, {}
    -- `open_scratch` is queued; it either creates or re-focuses the named
    -- scratch buffer. The buffer name is independent of `path` on purpose:
    -- switching databases keeps the query you were editing, only the
    -- connection used by :SqlRun changes. If no such buffer exists yet,
    -- seed it with a one-line comment; if it already exists, the `content`
    -- argument's effect on re-open is not documented one way or the other
    -- (see README.md's "Known assumptions").
    vimcode.buf.open_scratch(QUERY_BUFFER_NAME, { "-- " .. path, "" }, { filetype = "sql" })
    vimcode.message("sql-tool: connected to " .. path)
end

vimcode.command("SqlOpen", function(args)
    local path = args and args:match("^%s*(.-)%s*$") or ""
    if path == "" then
        vimcode.message("sql-tool: usage :SqlOpen <path.db>")
        return
    end
    open_db(path)
end)

vimcode.command("SqlPickRecent", function(_)
    local recents = load_recents()
    if #recents == 0 then
        vimcode.message("sql-tool: no recent databases -- :SqlOpen <path.db>")
        return
    end
    local items = {}
    for i, path in ipairs(recents) do
        items[i] = { display = path, data = path }
    end
    vimcode.picker.open({
        title = "sql-tool: recent databases",
        items = items,
        on_select = function(path)
            open_db(path)
        end,
    })
end)

-- `vimcode.command` passes "start_line,end_line" as `args` when invoked
-- with a visual-mode range (e.g. `:'<,'>SqlRun`), and an empty string
-- otherwise -- see EXTENSIONS.md's WordCountSelection example.
vimcode.command("SqlRun", function(args)
    local s, e = args and args:match("(%d+),(%d+)")
    local sql
    if s and e then
        local selected = {}
        for i = tonumber(s), tonumber(e) do
            selected[#selected + 1] = vimcode.buf.line(i) or ""
        end
        sql = table.concat(selected, "\n")
    else
        sql = table.concat(vimcode.buf.lines(), "\n")
    end
    run_query(sql)
end)

vimcode.keymap.set("n", "<leader>r", function()
    vimcode.command_run("SqlRun")
end)

vimcode.keymap.set("v", "<leader>r", function()
    vimcode.command_run("'<,'>SqlRun")
end)

vimcode.ui.register_view(RESULTS_VIEW, {
    title = "SQL Results",
    icon = "",
    fallback_icon = "R",

    render = function(_)
        if error_text then
            return {
                kind = "text_view",
                text = status_text .. "\n\n" .. error_text,
                filetype = "text",
            }
        end
        if #columns == 0 then
            return {
                kind = "text_view",
                text = status_text,
                filetype = "text",
            }
        end
        local view_columns = {}
        for i, name in ipairs(columns) do
            view_columns[i] = { title = name, editable = false }
        end
        return {
            kind = "table",
            columns = view_columns,
            rows = rows,
        }
    end,
})
