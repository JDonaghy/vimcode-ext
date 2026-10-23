-- sql-tool: sqlite3-backed query runner with an async results grid.
--
-- :SqlOpen <path.db>  connect to a sqlite3 database file (persists to recents)
-- :SqlPickRecent      pick a recently-opened database from a fuzzy picker
-- :SqlRun [s,e]        run the whole query buffer, or just lines s..e if a
--                      hand-typed numeric range is given, through
--                      `sqlite3 -json` and show the rows in a results tab
-- <leader>r           normal mode: runs the whole buffer
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
local query_buffer_opened = false

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

-- Opening the results view is done once, the first time a query runs.
-- `vimcode.ui.open_view(..., {location = "tab"})` always opens a brand-new
-- tab (there is no "focus the existing tab" mode in the engine), so this
-- guard is what keeps repeat `:SqlRun` calls from piling up duplicate
-- results tabs -- subsequent runs just call `vimcode.ui.refresh` instead.
--
-- A true side-by-side split with the query buffer is not possible: the
-- only engine primitive that can land a `kind = "table"` plugin view opens
-- it as a brand-new tab, never as a sibling split window. See README.md's
-- "Known limitations" section.
local function ensure_results_pane_open()
  if results_pane_opened then
    return
  end
  results_pane_opened = true
  vimcode.ui.open_view(RESULTS_VIEW, { location = "tab" })
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
          status_text = "ok (" .. #rows .. " row(s))"
          error_text = nil
          if stderr ~= "" then
            -- sqlite3 can print warnings to stderr on a clean
            -- exit (e.g. deprecated pragma warnings). Fold the
            -- warning into status_text rather than error_text:
            -- render() below treats a non-nil error_text as
            -- "hide the rows, show text instead", which would
            -- otherwise discard rows sqlite3 did return.
            status_text = status_text .. " -- warning: " .. stderr
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
  if not query_buffer_opened then
    -- `open_scratch` always creates a brand-new buffer and replaces
    -- the active window's buffer -- there is no "re-focus an existing
    -- scratch buffer by name" mode in the engine. So this only runs on
    -- the first connection, seeded with a one-line comment naming the
    -- database; later :SqlOpen / :SqlPickRecent calls intentionally
    -- skip it, which is what keeps your in-progress query untouched
    -- when you switch databases. `content` must be a real string, and
    -- `readonly` defaults to true unless set to false here -- both
    -- required for a buffer you can actually type SQL into.
    query_buffer_opened = true
    vimcode.buf.open_scratch(QUERY_BUFFER_NAME, "-- " .. path .. "\n\n", {
      filetype = "sql",
      readonly = false,
    })
  end
  vimcode.message("sql-tool: connected to " .. path)
end

vimcode.command("SqlOpen", function(args)
  local path = args and args:match("^%s*(.-)%s*$") or ""
  if path == "" or path:sub(1, 1) == "-" then
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

-- `:SqlRun <start>,<end>` (a hand-typed numeric range) runs just those
-- lines. Vim-native visual-range syntax (`:'<,'>SqlRun`) can never reach
-- this handler -- `execute_command` routes any `'`-prefixed command
-- through a ranged-command dispatcher that only knows built-in commands,
-- so a plugin command named this way is never invoked. There is also no
-- plugin-facing API that exposes the `'<`/`'>` visual-selection marks
-- (`vimcode.state.mark` only sees marks written into a different,
-- lowercase-keyed table that visual selection never populates), so there
-- is no way for a keymap callback to recover "the selected lines" either.
-- Both are upstream gaps in the engine, not something this extension can
-- work around -- see README.md's "Known limitations".
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
    -- `vimcode.buf.lines()` already returns each line with its
    -- trailing newline included, so joining with "" (not "\n")
    -- avoids doubling every newline in the buffer.
    sql = table.concat(vimcode.buf.lines(), "")
  end
  run_query(sql)
end)

vimcode.keymap.set("n", "<leader>r", function()
  vimcode.command_run("SqlRun")
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
