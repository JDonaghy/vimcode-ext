-- sql-tool: sqlite3-backed query runner with an async results grid.
--
-- :SqlOpen <path.db>  connect to a sqlite3 database file that exists and is
--                     readable (the path is probed first); persists to recents
-- :SqlPickRecent      pick a recently-opened database from a fuzzy picker
-- :SqlRun [s,e]        run the whole query buffer, or just lines s..e if a
--                      hand-typed numeric range is given, through
--                      `sqlite3 -json` and show the rows in a results tab
-- :SqlSort <col> [dir] reorder the current results by one column (numeric
--                      columns sort numerically), ascending or `desc`
-- <leader>r           normal mode: runs the whole buffer
--
-- There is also a "SQL" activity-bar panel: once connected it lists the
-- database's Tables and Views; Enter (or right-click) on one runs a
-- "select top N rows" into the results grid. See the "Database panel" block
-- at the end of this file.
--
-- Requires the `sqlite3` CLI on PATH. Every `sqlite3` invocation runs via
-- `vimcode.loop.spawn`, never a blocking shell call, so the editor stays
-- responsive while a query is in flight.

local QUERY_BUFFER_NAME = "sql-tool query.sql"
local RESULTS_VIEW = "sql_tool_results"
local MAX_RECENTS = 10

-- Connection + results state. None of this is persisted except `recents`
-- (via vimcode.storage); everything else is in-memory and reset on reload.
-- `current_adapter` is the engine driver (see "Database adapters" below) and
-- `current_conn` the opaque handle it returned from open(); both nil until the
-- first :SqlOpen.
local current_adapter = nil
local current_conn = nil
local running = false
local status_text = "no database open -- :SqlOpen <path.db>"
local error_text = nil
local columns = {}
local rows = {}
-- `row_values` parallels `rows`: for each row, the raw decoded cell values
-- (numbers/strings/booleans/null) in the same column order as `rows[i].cells`.
-- The view only ever consumes `cells` (display strings), but :SqlSort needs the
-- typed values so a numeric column sorts numerically, not lexicographically.
local row_values = {}
local results_pane_opened = false
local query_buffer_opened = false
-- Sidebar object-panel refresh, defined in the "Database panel" block at the
-- end of the file. Forward-declared so open_db can trigger a refresh the
-- moment a connection opens (assigned at load, called only at runtime).
local refresh_objects

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
  local cols, result_rows, result_values = {}, {}, {}
  if type(decoded) ~= "table" or decoded[1] == nil then
    -- Empty result set: `sqlite3 -json` prints "[]" for zero rows, so
    -- there is no header to recover column names from. This is a real
    -- limitation of driving `sqlite3 -json` rather than PRAGMA
    -- table_info -- an empty SELECT shows an empty table with no
    -- column headers, not "0 of N columns".
    return cols, result_rows, result_values
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
    local cells, values = {}, {}
    for ci, col in ipairs(cols) do
      cells[ci] = cell_to_string(row[col])
      -- Keep the raw decoded value (number/string/boolean/null sentinel, or
      -- nil for an absent key) alongside the display string, so :SqlSort can
      -- compare by type rather than by the stringified cell.
      values[ci] = row[col]
    end
    result_rows[i] = { id = "row" .. i, cells = cells }
    result_values[i] = values
  end
  return cols, result_rows, result_values
end

-- ===========================================================================
-- Database adapters
--
-- Everything engine-specific lives behind an adapter so the query runner,
-- results grid, sort and recents code below stay database-agnostic. An adapter
-- is a table:
--
--   kind            unique id, e.g. "sqlite"
--   display         human name for messages, e.g. "SQLite"
--   binary          the CLI executable driven via vimcode.loop.spawn
--   open(target)          -> conn, nil   |   nil, err_string
--                   validate a connection target and return an opaque conn
--                   handle. SQLite is file-based, so it read-probes the path;
--                   a server adapter would validate host/credentials instead.
--   label(conn)           -> string      short name for messages / the seed line
--   query_args(conn, sql) -> { arg, ... }
--                   argv (after `binary`) that runs `sql` and prints a
--                   machine-readable result to stdout.
--   parse(stdout)         -> columns, rows, row_values   |   nil, err_string
--                   turn that stdout into the grid's column/row/typed-value
--                   shape (see rows_from_json), or an error to show instead.
--
-- Adding Postgres/MySQL later is a new entry in `adapters` plus its install
-- command in manifest.toml -- nothing below this block changes.
-- ===========================================================================

local sqlite_adapter = {
  kind = "sqlite",
  display = "SQLite",
  binary = "sqlite3",

  open = function(target)
    -- SQLite is file-based: a read probe (the same io.open latex.lua uses)
    -- refuses a missing/unreadable path up front. Without it :SqlOpen would
    -- "connect" to anything and sqlite3's create-on-open would turn a wrong
    -- path into a later "no such table" rather than "no such file".
    local probe = io.open(target, "r")
    if probe == nil then
      return nil, "no such file or not readable"
    end
    probe:close()
    return { path = target }, nil
  end,

  label = function(conn)
    return conn.path
  end,

  query_args = function(conn, sql)
    -- The `--` is an end-of-options sentinel, not cosmetic. The query buffer
    -- is seeded with a leading `-- <path>` comment, so a whole-buffer run
    -- hands sqlite3 a `sql` starting with "--"; without `--` it parses that
    -- leading dash as a flag and dies with `Error: unknown option: -`.
    return { conn.path, "-json", "--", sql }
  end,

  parse = function(stdout)
    local ok, decoded = pcall(vimcode.json.decode, stdout == "" and "[]" or stdout)
    if not ok then
      return nil, "could not parse sqlite3 output as JSON: " .. tostring(decoded)
    end
    return rows_from_json(decoded)
  end,

  -- Argv that lists the connection's user tables and views (for the sidebar
  -- object panel). sqlite_master is SQLite's catalog; a Postgres adapter would
  -- query information_schema instead.
  objects_args = function(conn)
    return {
      conn.path, "-json", "--",
      "SELECT name, type FROM sqlite_master "
        .. "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
        .. "ORDER BY type, name;",
    }
  end,

  -- Parse that catalog output into a normalized { {name=, type=}, ... } list,
  -- or (nil, err). `type` is "table" or "view".
  parse_objects = function(stdout)
    local ok, decoded = pcall(vimcode.json.decode, stdout == "" and "[]" or stdout)
    if not ok then
      return nil, "could not parse sqlite3 catalog output: " .. tostring(decoded)
    end
    local objs = {}
    if type(decoded) == "table" then
      for _, row in ipairs(decoded) do
        if type(row) == "table" and type(row.name) == "string" then
          objs[#objs + 1] = { name = row.name, type = row.type }
        end
      end
    end
    return objs
  end,

  -- The dialect's "first N rows of a table" query. SQLite uses double-quoted
  -- identifiers and LIMIT (Postgres too; SQL Server would be TOP, etc.).
  top_n_sql = function(name, n)
    return 'SELECT * FROM "' .. name:gsub('"', '""') .. '" LIMIT ' .. n .. ";"
  end,
}

local adapters = { [sqlite_adapter.kind] = sqlite_adapter }

-- SQLite is the only adapter today, so it is the default. A future
-- :SqlConnect that picks an engine would set current_adapter per connection.
current_adapter = sqlite_adapter

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
  if current_conn == nil then
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

  -- Snapshot the adapter + connection for this query so the async callbacks
  -- below use the engine that was current when it launched, even if the user
  -- switches connections while it is in flight.
  local adapter = current_adapter
  local out_chunks, err_chunks = {}, {}
  local ok_spawn, err = pcall(vimcode.loop.spawn, adapter.binary, adapter.query_args(current_conn, sql), {
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
        error_text = adapter.binary .. " was killed (signal " .. tostring(signal) .. ")"
      elseif code ~= 0 then
        status_text = "error"
        error_text = (stderr ~= "" and stderr) or (adapter.binary .. " exited with status " .. tostring(code))
      else
        -- parse() returns (columns, rows, row_values) on success, or
        -- (nil, err_string) when the engine's output could not be parsed.
        local cols, parsed_rows, parsed_values = adapter.parse(stdout)
        if cols == nil then
          status_text = "error"
          error_text = parsed_rows
        else
          columns, rows, row_values = cols, parsed_rows, parsed_values
          status_text = "ok (" .. #rows .. " row(s))"
          error_text = nil
          if stderr ~= "" then
            -- A CLI can print warnings to stderr on a clean exit (e.g. a
            -- deprecated-pragma notice). Fold the warning into status_text
            -- rather than error_text: render() below treats a non-nil
            -- error_text as "hide the rows, show text instead", which would
            -- otherwise discard rows the query did return.
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
    error_text = "could not start " .. adapter.binary .. ": " .. tostring(err)
    vimcode.ui.refresh(RESULTS_VIEW)
  end
end

local function open_db(target)
  -- Delegate target validation to the adapter, and change no state if it
  -- fails. For SQLite this is the io.open read-probe (a missing/unreadable
  -- path would otherwise "connect" and later surface as "no such table"
  -- once sqlite3 creates the empty file on first query); a server adapter
  -- would validate host/credentials here instead.
  local conn, err = current_adapter.open(target)
  if conn == nil then
    vimcode.message("sql-tool: cannot open " .. target .. " -- " .. err)
    return
  end
  current_conn = conn
  remember_recent(target)
  status_text = "connected -- no query run yet"
  error_text = nil
  columns, rows, row_values = {}, {}, {}
  if not query_buffer_opened then
    -- `open_scratch` always creates a brand-new buffer and replaces
    -- the active window's buffer -- there is no "re-focus an existing
    -- scratch buffer by name" mode in the engine. So this only runs on
    -- the first connection, seeded with a one-line comment naming the
    -- connection; later :SqlOpen / :SqlPickRecent calls intentionally
    -- skip it, which is what keeps your in-progress query untouched
    -- when you switch databases. `content` must be a real string, and
    -- `readonly` defaults to true unless set to false here -- both
    -- required for a buffer you can actually type SQL into.
    query_buffer_opened = true
    vimcode.buf.open_scratch(QUERY_BUFFER_NAME, "-- " .. current_adapter.label(conn) .. "\n\n", {
      filetype = "sql",
      readonly = false,
    })
  end
  vimcode.message("sql-tool: connected to " .. current_adapter.label(conn))
  refresh_objects()
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
  -- `(args or "")`, not `args and args:match(...)`: the `and` operator adjusts
  -- its right operand to a single value, so a two-capture match silently lost
  -- its second capture (`e` was always nil) and every `:SqlRun <s>,<e>` fell
  -- through to running the whole buffer. Matching on `(args or "")` keeps both.
  local s, e = (args or ""):match("(%d+),(%d+)")
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

-- Type rank for cross-type ordering. `sqlite3 -json` can return a mix of
-- numbers, strings, booleans and nulls in one column (dynamic typing), so a
-- sort needs a total order across types, not just within one. Nulls rank
-- lowest, matching SQLite's own "NULLs sort first ascending" convention.
local function value_rank(v)
  if v == nil or v == vimcode.json.null then
    return 0
  end
  local t = type(v)
  if t == "number" then
    return 1
  elseif t == "string" then
    return 2
  elseif t == "boolean" then
    return 3
  end
  return 4
end

-- Strict-less-than over raw decoded cell values, giving table.sort a valid
-- weak ordering. Same-ranked values compare by their natural order (numbers
-- numerically -- the whole point of keeping typed values -- strings
-- lexicographically, false before true); differently-ranked values compare by
-- rank, so nulls cluster at one end rather than erroring against numbers.
local function value_less(a, b)
  local ra, rb = value_rank(a), value_rank(b)
  if ra ~= rb then
    return ra < rb
  end
  if ra == 1 or ra == 2 then
    return a < b
  elseif ra == 3 then
    return a == false and b == true
  end
  return false
end

-- :SqlSort <column|index> [asc|desc]   reorder the current result rows in
-- place (no re-query) by one column, comparing the typed values kept in
-- `row_values`. There is deliberately no header-click sort: the `kind="table"`
-- plugin view emits no column/header event (only ItemSelected/ItemActivated/
-- CellEdited), so a click-to-sort UX is not reachable from Lua -- see
-- README.md's "Known limitations". A column may be named or given as a
-- 1-based index into the displayed (alphabetically sorted) columns.
vimcode.command("SqlSort", function(args)
  args = (args or ""):match("^%s*(.-)%s*$")
  if args == "" then
    vimcode.message("sql-tool: usage :SqlSort <column|index> [asc|desc]")
    return
  end
  if #columns == 0 or #rows == 0 then
    vimcode.message("sql-tool: no results to sort -- run a query first")
    return
  end

  -- Peel an optional trailing asc/desc direction off the end; whatever
  -- remains is the column spec (so a column name with spaces still works).
  local descending = false
  local spec = args
  local tail = args:match("%s+(%a+)$")
  if tail then
    local lowered = tail:lower()
    if lowered == "asc" or lowered == "desc" then
      descending = lowered == "desc"
      spec = args:sub(1, #args - #tail):match("^%s*(.-)%s*$")
    end
  end

  -- Resolve the column: exact name match first, then a 1-based index.
  local ci = nil
  for i, name in ipairs(columns) do
    if name == spec then
      ci = i
      break
    end
  end
  if ci == nil then
    local n = tonumber(spec)
    if n and n == math.floor(n) and n >= 1 and n <= #columns then
      ci = n
    end
  end
  if ci == nil then
    vimcode.message("sql-tool: no such column: " .. spec)
    return
  end

  -- Sort an index permutation, then reorder `rows` and `row_values` together
  -- so each display row keeps its own typed values. Row `id`s travel with
  -- their row objects (they stay unique), which keeps selection stable.
  local order = {}
  for i = 1, #rows do
    order[i] = i
  end
  table.sort(order, function(x, y)
    local a, b = row_values[x][ci], row_values[y][ci]
    if descending then
      a, b = b, a
    end
    return value_less(a, b)
  end)
  local new_rows, new_values = {}, {}
  for pos, i in ipairs(order) do
    new_rows[pos] = rows[i]
    new_values[pos] = row_values[i]
  end
  rows, row_values = new_rows, new_values

  vimcode.ui.refresh(RESULTS_VIEW)
  vimcode.message("sql-tool: sorted by " .. columns[ci] .. (descending and " desc" or " asc"))
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

-- ===========================================================================
-- Database panel (activity-bar sidebar)
--
-- A tree of the connected database's objects: a "Tables" section and a "Views"
-- section. Selecting (Enter) an object, or right-clicking it, runs "Select top
-- N rows" into the results grid. The tree is (re)built by spawning the
-- adapter's catalog query through the same non-blocking vimcode.loop.spawn
-- path queries use, so a large catalog never freezes the editor.
--
-- Column-level children (lazy-loaded when a table node is expanded) are a
-- planned follow-on; today each object is a flat row in its section. A native
-- anchored right-click menu is not available to panels yet (tracked upstream
-- as vimcode#2022), so right-click presents the actions as a picker.
-- ===========================================================================

local PANEL = "sql_tool"
local TOP_N = 1000

vimcode.panel.register(PANEL, {
  title = "SQL",
  icon = "\u{f1c0}", -- database glyph
  sections = { "Tables", "Views" },
})

vimcode.panel.set_help(PANEL, {
  { "Enter", "Select top " .. TOP_N .. " rows" },
  { "Right-click", "Actions (select top N, copy name)" },
  { "r", "Refresh object list" },
  { "q/Esc", "Close panel" },
})

local function object_items(objs, want_type, icon)
  local items = {}
  for _, o in ipairs(objs) do
    if o.type == want_type then
      items[#items + 1] = { text = o.name, id = o.name, icon = icon }
    end
  end
  return items
end

-- Assigns the forward-declared upvalue (no `local`), so open_db above can call
-- it. Clears the tree when disconnected; otherwise spawns the adapter's
-- catalog query and fills the Tables/Views sections from the parsed result.
function refresh_objects()
  if current_conn == nil then
    vimcode.panel.set_items(PANEL, "Tables", {})
    vimcode.panel.set_items(PANEL, "Views", {})
    return
  end
  local adapter = current_adapter
  local out_chunks = {}
  pcall(vimcode.loop.spawn, adapter.binary, adapter.objects_args(current_conn), {
    on_stdout = function(chunk)
      out_chunks[#out_chunks + 1] = chunk
    end,
    on_exit = function(code, _)
      if code ~= 0 then
        return
      end
      local objs = adapter.parse_objects(table.concat(out_chunks))
      if objs == nil then
        return
      end
      vimcode.panel.set_items(PANEL, "Tables", object_items(objs, "table", "\u{f0ce}"))
      vimcode.panel.set_items(PANEL, "Views", object_items(objs, "view", "\u{f06e}"))
    end,
  })
end

-- Run the default action (select the first N rows) for an object by name.
local function select_top_n(name)
  run_query(current_adapter.top_n_sql(name, TOP_N))
end

vimcode.on("panel_focus", function(name)
  if name == PANEL then
    refresh_objects()
  end
end)

vimcode.on("panel_select", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL or e.id == "" then
    return
  end
  select_top_n(e.id)
end)

vimcode.on("panel_action", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  if e.key == "r" then
    refresh_objects()
    vimcode.message("sql-tool: object list refreshed")
  end
end)

vimcode.on("panel_context_menu", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL or e.id == "" then
    return
  end
  local name = e.id
  vimcode.picker.open({
    title = name,
    items = {
      { display = "Select top " .. TOP_N .. " rows", data = "top" },
      { display = "Copy name", data = "copy" },
    },
    on_select = function(action)
      if action == "top" then
        select_top_n(name)
      elseif action == "copy" then
        vimcode.state.set_register("+", name, false)
        vimcode.message("sql-tool: copied " .. name)
      end
    end,
  })
end)
