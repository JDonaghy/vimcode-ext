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
-- :SqlNewConnection   open the connection dialog (a form, in a tab)
-- :SqlConnections     pick a saved connection and connect
-- <leader>r           normal mode: runs the whole buffer
--
-- There is also a "SQL" activity-bar panel: a toolbar row (Connect / New /
-- Disconnect / Refresh) plus a tree of the connected database's Tables (Tab
-- to expand a table to its columns) and Views. Enter / right-click on a table
-- or view runs "select top N rows" into the results grid. See the
-- "Connection manager + database panel" and "Connection dialog" blocks at the
-- end of this file.
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
-- `running` is a soft "a query is in flight" flag for the status line only --
-- NOT a hard gate. `query_gen` is the real concurrency control: every run_query
-- bumps it and captures the value, and a spawn's callbacks only touch shared
-- state if their captured generation is still the latest. That way a new run
-- always proceeds (it supersedes), so a spawn whose `on_exit` never fires -- a
-- killed/hung child, or an engine that drops the exit event -- can never wedge
-- the extension into "a query is already running" forever. (An earlier version
-- hard-blocked on `running`; a stuck query then disabled every later command.)
local running = false
local query_gen = 0
local status_text = "no database open -- :SqlOpen <path.db>"
local error_text = nil
local columns = {}
local rows = {}
-- `row_values` parallels `rows`: for each row, the raw decoded cell values
-- (numbers/strings/booleans/null) in the same column order as `rows[i].cells`.
-- The view only ever consumes `cells` (display strings), but :SqlSort needs the
-- typed values so a numeric column sorts numerically, not lexicographically.
local row_values = {}
-- Header-click sort state, mirroring the engine's OWN built-in table sort
-- cycle (unsorted -> asc -> desc -> unsorted) that landed in
-- JDonaghy/vimcode#2034. Since that change, a click on a results-grid column
-- header makes the *engine* reorder the painted rows (numeric-aware -- it
-- parses numeric cells) and also dispatches a `HeaderClicked` event to our
-- on_event. We deliberately do NOT re-sort `rows` ourselves on that event: the
-- engine's overlay already reordered the paint, so a second, plugin-side sort
-- would just fight it (see the on_event handler on RESULTS_VIEW below). We only
-- track the cycle here so the status-line feedback matches what the engine
-- painted. `:SqlSort` remains for scripted sorting and for exact typed/NULL
-- ordering of `row_values`, which the engine's string-based overlay can't do.
local header_sort_col = nil
local header_sort_dir = nil
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

  -- Argv listing one table's columns, for lazy tree expansion. SQLite's
  -- `PRAGMA table_info` returns cid/name/type/notnull/dflt_value/pk per column
  -- (a Postgres adapter would query information_schema.columns instead).
  columns_args = function(conn, table_name)
    return {
      conn.path, "-json", "--",
      "PRAGMA table_info('" .. table_name:gsub("'", "''") .. "');",
    }
  end,

  -- Parse that into a normalized { {name=, type=, pk=}, ... } list, in the
  -- table's definition order, or (nil, err).
  parse_columns = function(stdout)
    local ok, decoded = pcall(vimcode.json.decode, stdout == "" and "[]" or stdout)
    if not ok then
      return nil, "could not parse sqlite3 table_info output: " .. tostring(decoded)
    end
    local cols = {}
    if type(decoded) == "table" then
      for _, row in ipairs(decoded) do
        if type(row) == "table" and type(row.name) == "string" then
          cols[#cols + 1] = {
            name = row.name,
            type = (type(row.type) == "string" and row.type ~= "") and row.type or nil,
            pk = row.pk == 1 or row.pk == true,
          }
        end
      end
    end
    return cols
  end,

  -- The fields the connection dialog shows for this engine. SQLite is
  -- file-based, so a single path; a server adapter would list host/port/
  -- database/user and a `type = "password"` field. A password field is never
  -- persisted (see strip_secrets and the README's "Adapters" note).
  conn_fields = {
    { id = "path", label = "Database file", type = "text", placeholder = "/path/to/file.db" },
  },

  -- Build the open() target from a table of connection-field id -> value. For
  -- SQLite the target is just the file path.
  make_target = function(values)
    return values.path or ""
  end,
}

local adapters = { [sqlite_adapter.kind] = sqlite_adapter }
-- Ordered list (the map above has no order) for the engine dropdown in the
-- connection dialog. SQLite is the only entry today.
local adapter_list = { sqlite_adapter }

-- SQLite is the only adapter today, so it is the default. The connection
-- dialog's engine dropdown sets current_adapter per connection.
current_adapter = sqlite_adapter

-- Open the results view once, the first time a query runs, as its own editor
-- tab. Reused across runs via the guard below (open_view always opens a NEW
-- tab, so re-opening would pile up duplicates).
--
-- Caveat worth knowing: there is no "focus the existing tab" API, so on a
-- re-run the refresh lands in this tab even when it is sitting behind the
-- query buffer -- a background update can look like "nothing happened". To
-- counter that, run_query's on_exit also prints a one-line status message
-- (row count / error) so a re-run always announces itself in the status line
-- regardless of which tab is in front.
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
  -- A new run always proceeds and supersedes any in-flight one (see the
  -- `query_gen` note up top): bump the generation and capture it, so only the
  -- latest run's callbacks write to the shared view state.
  query_gen = query_gen + 1
  local my_gen = query_gen
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
      -- A later run_query superseded this one; its results are stale, so drop
      -- them (and leave `running`/the view to the newer run).
      if my_gen ~= query_gen then
        return
      end
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
          -- New result set: the engine's own header-sort overlay restarts from
          -- unsorted, so drop our mirror of it too.
          header_sort_col, header_sort_dir = nil, nil
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

      -- Announce the outcome in the status line too: the results tab may be in
      -- the background (open_view can't re-focus an existing tab), so this is
      -- how a re-run tells you it ran without you switching to the tab.
      if error_text then
        vimcode.message("sql-tool: query error -- see SQL Results tab")
      else
        vimcode.message("sql-tool: " .. status_text)
      end

      vimcode.ui.refresh(RESULTS_VIEW)
    end,
  })

  if not ok_spawn and my_gen == query_gen then
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
  header_sort_col, header_sort_dir = nil, nil
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
-- `row_values`. This is the typed/NULL-aware complement to the engine's
-- built-in header-click sort (JDonaghy/vimcode#2034, handled in RESULTS_VIEW's
-- on_event): clicking a header lets the engine reorder by the painted cell
-- strings, while `:SqlSort` sorts by the decoded values, so a numeric column
-- sorts numerically and NULLs order predictably (first asc / last desc). A
-- column may be named or given as a 1-based index into the displayed
-- (alphabetically sorted) columns.
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
  -- Tab-only: the results grid is opened as an editor split, never browsed
  -- from the activity bar, so suppress its sidebar panel (vimcode#2032).
  -- Ignored (no-op) on an engine predating that option.
  sidebar = false,

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
      -- `min_width` (JDonaghy/vimcode#2034) floors each column at its header
      -- width so the column name can't be squeezed to an unreadable sliver
      -- when a result has many columns; above that floor the column sizes to
      -- its content. Old engines without the field ignore it and fall back to
      -- the previous even Flex split. (Units are character cells on the TUI,
      -- pixels on the GUI backends -- #name is a sane floor in both: a readable
      -- minimum on the TUI, negligible on the GUI where content drives width.)
      view_columns[i] = { title = name, editable = false, min_width = #name }
    end
    return {
      kind = "table",
      columns = view_columns,
      rows = rows,
    }
  end,

  -- A click on a results-grid column header. Since JDonaghy/vimcode#2034 the
  -- engine already reordered the painted rows itself (numeric-aware, and in a
  -- 3-state unsorted->asc->desc cycle) BEFORE this fires, so we must NOT
  -- reorder `rows`/`row_values` again -- doing so would layer a second,
  -- conflicting sort on top. We only mirror the engine's cycle to report, on
  -- the status line, what the click just did (there is no other feedback that
  -- a header click registered). `:SqlSort` is still the way to get exact typed
  -- / NULL-aware ordering, which the engine's string overlay doesn't offer.
  on_event = function(_, event)
    if event == nil or event.kind ~= "HeaderClicked" then
      return
    end
    -- event.col is 0-based into the displayed columns; guard against a stale
    -- index (a header click racing a just-changed result set).
    local ci = (event.col or -1) + 1
    if ci < 1 or ci > #columns then
      return
    end
    if header_sort_col == ci and header_sort_dir == "asc" then
      header_sort_dir = "desc"
    elseif header_sort_col == ci and header_sort_dir == "desc" then
      header_sort_col, header_sort_dir = nil, nil
    else
      header_sort_col, header_sort_dir = ci, "asc"
    end
    if header_sort_col == nil then
      vimcode.message("sql-tool: cleared sort on " .. columns[ci])
    else
      vimcode.message(
        "sql-tool: sorted by " .. columns[ci] .. " " .. header_sort_dir .. " (header click)"
      )
    end
  end,
})

-- ===========================================================================
-- Connection manager + database panel (activity-bar sidebar)
--
-- The "SQL" panel has three sections:
--   Connection  a toolbar row (Connect / New / Disconnect / Refresh) plus one
--               row per saved connection.
--   Tables      the connected database's tables; Tab expands a table to its
--               columns (fetched lazily and cached).
--   Views       the connected database's views.
--
-- Selecting (Enter / click) a table or view runs "select top N" into the
-- results grid; a column copies its name. The Connect / New / Disconnect /
-- Refresh actions are a real clickable toolbar (panel.register's `toolbar`,
-- firing panel_toolbar) and also the keyboard keys c/n/d/r (panel_action).
-- Right-click a table/view for a context menu (JDonaghy/vimcode#2022), or a
-- saved connection to connect/delete.
--
-- The tree is (re)built by spawning the adapter's catalog/column queries
-- through the same non-blocking vimcode.loop.spawn path queries use, so a
-- large catalog never freezes the editor.
-- ===========================================================================

local PANEL = "sql_tool"
local TOP_N = 1000
local CONN_DIALOG = "sql_tool_conn"

-- Catalog of the connected database, its per-table column cache, and which
-- tables are expanded in the tree. Rebuilt on connect / refresh; columns and
-- expansion are lazy (see expand_table).
local catalog = { tables = {}, views = {} }
local columns_cache = {}
local expanded = {}
-- Section-qualified id -> node descriptor, rebuilt by render_panel so the
-- event handlers dispatch without re-parsing ids. See nkey().
local node_index = {}

vimcode.panel.register(PANEL, {
  title = "SQL",
  icon = "\u{f1c0}", -- database glyph
  sections = { "Connection", "Tables", "Views" },
  -- A real clickable button row under the panel header. Clicking a button
  -- fires `panel_toolbar` with "<panel>|<id>". The keyboard keys c/n/d/r
  -- (panel_action) run the same actions.
  toolbar = {
    { id = "connect", label = "Connect", icon = "\u{f0c1}" },
    { id = "new", label = "New", icon = "\u{f067}" },
    { id = "disconnect", label = "Disconnect", icon = "\u{f127}" },
    { id = "refresh", label = "Refresh", icon = "\u{f021}" },
  },
})

vimcode.panel.set_help(PANEL, {
  { "Enter", "Open (select top " .. TOP_N .. ") / connect / copy column" },
  { "Tab", "Expand a table to its columns" },
  { "c", "Connect to a saved connection" },
  { "n", "New connection" },
  { "d", "Disconnect" },
  { "r", "Refresh" },
  { "Right-click", "Context menu" },
  { "q/Esc", "Close panel" },
})

-- ── saved connections (vimcode.storage; never stores a password) ───────────
local function load_connections()
  local ok, list = pcall(vimcode.storage.get, "connections")
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

local function save_connections(list)
  pcall(vimcode.storage.set, "connections", list)
end

-- Drop any password-typed field before persisting: vimcode.storage is
-- plaintext and there is no secrets store (see README "Adapters").
local function strip_secrets(cfg)
  local adapter = adapters[cfg.engine]
  local values = {}
  for k, v in pairs(cfg.values or {}) do
    values[k] = v
  end
  if adapter and adapter.conn_fields then
    for _, f in ipairs(adapter.conn_fields) do
      if f.type == "password" then
        values[f.id] = nil
      end
    end
  end
  return { name = cfg.name, engine = cfg.engine, values = values }
end

local function remember_connection(cfg)
  if not cfg.name or cfg.name == "" then
    return
  end
  local list = load_connections()
  local deduped = {}
  for _, existing in ipairs(list) do
    if existing.name ~= cfg.name then
      deduped[#deduped + 1] = existing
    end
  end
  table.insert(deduped, 1, strip_secrets(cfg))
  save_connections(deduped)
end

-- ── panel rendering ────────────────────────────────────────────────────────
-- node_index key: section + id, NUL-joined. The id alone is not unique (a
-- table and a view can share a name), and the join char must not be "|" (the
-- panel event-arg delimiter parse_event splits on).
local function nkey(section, id)
  return section .. "\0" .. id
end

local TABLE_ICON = "\u{f0ce}"
local VIEW_ICON = "\u{f06e}"
local COLUMN_ICON = "\u{f0db}"

-- Rebuild all three sections (and node_index) from the current state. Cheap and
-- pure Lua; called after any state change.
local function render_panel()
  node_index = {}

  -- Connection section: a toolbar row, then one row per saved connection.
  local conn_items = {}
  local label
  if current_conn ~= nil then
    label = "\u{25cf} " .. current_adapter.label(current_conn)
  else
    label = "\u{25cb} not connected"
  end
  -- A non-interactive status line; the actions live in the panel's real
  -- toolbar (see panel.register above), not on this row.
  conn_items[#conn_items + 1] = {
    text = label,
    id = "__status__",
    style = "header",
  }
  for i, cfg in ipairs(load_connections()) do
    local id = "conn::" .. i
    local disp = adapters[cfg.engine]
    conn_items[#conn_items + 1] = {
      text = cfg.name,
      id = id,
      hint = disp and disp.display or cfg.engine,
      icon = "\u{f1c0}",
    }
    node_index[nkey("Connection", id)] = { kind = "connection", cfg = cfg }
  end
  vimcode.panel.set_items(PANEL, "Connection", conn_items)

  -- Tables section: a row per table, columns as children when expanded.
  local tbl_items = {}
  for _, t in ipairs(catalog.tables) do
    tbl_items[#tbl_items + 1] = {
      text = t.name,
      id = t.name,
      icon = TABLE_ICON,
      expandable = true,
      expanded = expanded[t.name] or false,
    }
    node_index[nkey("Tables", t.name)] = { kind = "table", name = t.name }
    if expanded[t.name] and columns_cache[t.name] then
      for _, c in ipairs(columns_cache[t.name]) do
        local cid = "col::" .. t.name .. "::" .. c.name
        tbl_items[#tbl_items + 1] = {
          text = c.name,
          id = cid,
          parent_id = t.name,
          indent = 1,
          hint = c.type,
          icon = COLUMN_ICON,
          style = "dim",
        }
        node_index[nkey("Tables", cid)] = { kind = "column", name = c.name, table = t.name }
      end
    end
  end
  vimcode.panel.set_items(PANEL, "Tables", tbl_items)

  -- Views section.
  local view_items = {}
  for _, v in ipairs(catalog.views) do
    view_items[#view_items + 1] = { text = v.name, id = v.name, icon = VIEW_ICON }
    node_index[nkey("Views", v.name)] = { kind = "view", name = v.name }
  end
  vimcode.panel.set_items(PANEL, "Views", view_items)
end

-- Assigns the forward-declared upvalue (no `local`): open_db / connect_config
-- call it when a connection opens. Clears the catalog when disconnected;
-- otherwise spawns the adapter's catalog query and fills Tables/Views.
function refresh_objects()
  if current_conn == nil then
    catalog = { tables = {}, views = {} }
    columns_cache = {}
    expanded = {}
    render_panel()
    return
  end
  local adapter = current_adapter
  local conn = current_conn
  local out_chunks = {}
  local ok_spawn = pcall(vimcode.loop.spawn, adapter.binary, adapter.objects_args(conn), {
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
      local tables, views = {}, {}
      for _, o in ipairs(objs) do
        if o.type == "view" then
          views[#views + 1] = o
        else
          tables[#tables + 1] = o
        end
      end
      catalog = { tables = tables, views = views }
      render_panel()
    end,
  })
  if not ok_spawn then
    render_panel()
  end
end

-- Lazy-load (and cache) a table's columns, then mark it expanded and repaint.
local function expand_table(name)
  expanded[name] = true
  if columns_cache[name] or current_conn == nil then
    render_panel()
    return
  end
  local adapter = current_adapter
  local out_chunks = {}
  local ok_spawn = pcall(vimcode.loop.spawn, adapter.binary, adapter.columns_args(current_conn, name), {
    on_stdout = function(chunk)
      out_chunks[#out_chunks + 1] = chunk
    end,
    on_exit = function(code, _)
      if code == 0 then
        local cols = adapter.parse_columns(table.concat(out_chunks))
        if cols ~= nil then
          columns_cache[name] = cols
        end
      end
      render_panel()
    end,
  })
  if not ok_spawn then
    render_panel()
  end
end

-- Run the default action (select the first N rows) for an object by name.
local function select_top_n(name)
  run_query(current_adapter.top_n_sql(name, TOP_N))
end

-- ── connection actions ──────────────────────────────────────────────────────
-- Connect using a connection config {name, engine, values}. Returns true on
-- success; on failure shows a message and returns false, changing no state.
local function connect_config(cfg)
  local adapter = adapters[cfg.engine]
  if adapter == nil then
    vimcode.message("sql-tool: unknown engine: " .. tostring(cfg.engine))
    return false
  end
  local conn, err = adapter.open(adapter.make_target(cfg.values or {}))
  if conn == nil then
    vimcode.message("sql-tool: cannot connect -- " .. err)
    return false
  end
  current_adapter = adapter
  current_conn = conn
  status_text = "connected -- no query run yet"
  error_text = nil
  columns, rows, row_values = {}, {}, {}
  header_sort_col, header_sort_dir = nil, nil
  remember_connection(cfg)
  if not query_buffer_opened then
    -- Same once-per-session scratch buffer as open_db; see its comment.
    query_buffer_opened = true
    vimcode.buf.open_scratch(QUERY_BUFFER_NAME, "-- " .. adapter.label(conn) .. "\n\n", {
      filetype = "sql",
      readonly = false,
    })
  end
  vimcode.message("sql-tool: connected to " .. adapter.label(conn))
  refresh_objects()
  return true
end

local function do_disconnect()
  current_conn = nil
  status_text = "no database open -- :SqlOpen <path.db>"
  error_text = nil
  columns, rows, row_values = {}, {}, {}
  refresh_objects() -- current_conn == nil, so this clears the tree
  vimcode.ui.refresh(RESULTS_VIEW)
  vimcode.message("sql-tool: disconnected")
end

local function open_conn_dialog()
  vimcode.ui.open_view(CONN_DIALOG, { location = "tab" })
end

local function connect_picker()
  local list = load_connections()
  if #list == 0 then
    vimcode.message("sql-tool: no saved connections -- opening New")
    open_conn_dialog()
    return
  end
  local items = {}
  for i, cfg in ipairs(list) do
    items[i] = { display = cfg.name, data = i }
  end
  vimcode.picker.open({
    title = "sql-tool: connect",
    items = items,
    on_select = function(i)
      connect_config(list[i])
    end,
  })
end

-- Toolbar actions, shared by the panel's real toolbar (panel_toolbar, keyed by
-- button id), the keyboard keys (panel_action: c/n/d/r) and the :Sql* commands.
local function run_action(name)
  if name == "connect" then
    connect_picker()
  elseif name == "new" then
    open_conn_dialog()
  elseif name == "disconnect" then
    do_disconnect()
  elseif name == "refresh" then
    refresh_objects()
  end
end

local KEY_ACTION = { c = "connect", n = "new", d = "disconnect", r = "refresh" }

-- ── panel events ─────────────────────────────────────────────────────────────
vimcode.on("panel_focus", function(name)
  if name == PANEL then
    render_panel()
  end
end)

vimcode.on("panel_select", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  local node = node_index[nkey(e.section, e.id)]
  if node == nil then
    return
  end
  if node.kind == "connection" then
    connect_config(node.cfg)
  elseif node.kind == "table" or node.kind == "view" then
    select_top_n(node.name)
  elseif node.kind == "column" then
    vimcode.state.set_register("+", node.name, false)
    vimcode.message("sql-tool: copied " .. node.name)
  end
end)

vimcode.on("panel_action", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  -- The toolbar's action keys work from anywhere in the panel.
  local name = KEY_ACTION[e.key]
  if name then
    run_action(name)
  end
end)

-- The real panel toolbar (panel.register's `toolbar`). Its arg is
-- "<panel>|<button_id>", so parse_event lands the button id in the `section`
-- field (there is no section/id for a toolbar click).
vimcode.on("panel_toolbar", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  run_action(e.section)
end)

vimcode.on("panel_expand", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  local node = node_index[nkey(e.section, e.id)]
  if node and node.kind == "table" then
    expand_table(node.name)
  end
end)

vimcode.on("panel_collapse", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  local node = node_index[nkey(e.section, e.id)]
  if node and node.kind == "table" then
    expanded[node.name] = false
    render_panel()
  end
end)

vimcode.on("panel_context_menu", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= PANEL then
    return
  end
  local node = node_index[nkey(e.section, e.id)]
  if node == nil then
    return
  end
  if node.kind == "table" or node.kind == "view" then
    local name = node.name
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
  elseif node.kind == "connection" then
    local cfg = node.cfg
    vimcode.picker.open({
      title = cfg.name,
      items = {
        { display = "Connect", data = "connect" },
        { display = "Delete", data = "delete" },
      },
      on_select = function(action)
        if action == "connect" then
          connect_config(cfg)
        elseif action == "delete" then
          local kept = {}
          for _, existing in ipairs(load_connections()) do
            if existing.name ~= cfg.name then
              kept[#kept + 1] = existing
            end
          end
          save_connections(kept)
          render_panel()
          vimcode.message("sql-tool: deleted connection " .. cfg.name)
        end
      end,
    })
  end
end)

-- ===========================================================================
-- Connection dialog (vimcode.ui.register_view form, opened in a tab)
--
-- A form: a name, an engine dropdown, the selected engine's connection fields
-- (SQLite: a file path; a server engine would add host/port/user and a masked
-- `password` field), and a Connect button. On connect it opens the connection
-- and saves it (minus any password) to the panel's saved-connection list.
--
-- Registered `sidebar = false` (vimcode#2032) so it has no activity-bar icon
-- of its own -- it is only ever opened as a tab via open_conn_dialog().
-- ===========================================================================

local conn_form = { engine = adapter_list[1].kind, name = "", values = {}, status = "" }

local function conn_form_engine_index()
  for i, a in ipairs(adapter_list) do
    if a.kind == conn_form.engine then
      return i - 1 -- dropdown `selected` is 0-based
    end
  end
  return 0
end

vimcode.ui.register_view(CONN_DIALOG, {
  title = "SQL Connection",
  icon = "\u{f1c0}",
  fallback_icon = "C",
  -- Tab-only: opened via open_conn_dialog(), never from the activity bar, so
  -- no sidebar icon (vimcode#2032). No-op on an engine predating the option.
  sidebar = false,

  render = function(_)
    local adapter = adapters[conn_form.engine] or adapter_list[1]
    local engine_options = {}
    for i, a in ipairs(adapter_list) do
      engine_options[i] = a.display
    end
    local fields = {
      { type = "label", id = "hdr", label = "New connection" },
      { type = "text", id = "name", label = "Name", value = conn_form.name,
        placeholder = "my database" },
      { type = "dropdown", id = "engine", label = "Engine",
        options = engine_options, selected = conn_form_engine_index() },
    }
    for _, f in ipairs(adapter.conn_fields or {}) do
      fields[#fields + 1] = {
        type = f.type,
        id = "f:" .. f.id,
        label = f.label,
        value = conn_form.values[f.id] or "",
        placeholder = f.placeholder,
      }
    end
    fields[#fields + 1] = { type = "button", id = "connect", label = "Connect" }
    if conn_form.status ~= "" then
      fields[#fields + 1] = { type = "read_only", id = "status", label = "Status",
        value = conn_form.status }
    end
    return { id = "conn", schema_version = 1, fields = fields }
  end,

  on_event = function(_, event)
    local kind = event.kind
    local wid = event.widget_id or ""
    if kind == "DropdownChanged" and wid == "engine" then
      local a = adapter_list[(event.value or 0) + 1]
      if a then
        conn_form.engine = a.kind
      end
      vimcode.ui.refresh(CONN_DIALOG)
    elseif kind == "TextChanged" or kind == "TextCommitted" then
      if wid == "name" then
        conn_form.name = event.value or ""
      elseif wid:sub(1, 2) == "f:" then
        conn_form.values[wid:sub(3)] = event.value or ""
      end
      -- No refresh on keystrokes: the engine owns the focused field's edit
      -- state; we just record the latest value for the next paint / connect.
    elseif kind == "ButtonClicked" and wid == "connect" then
      local name = conn_form.name
      if name == "" then
        name = conn_form.values.path or conn_form.engine
      end
      local connected = connect_config({
        name = name,
        engine = conn_form.engine,
        values = conn_form.values,
      })
      conn_form.status = connected
          and ("connected to " .. current_adapter.label(current_conn))
        or "connection failed"
      vimcode.ui.refresh(CONN_DIALOG)
    end
  end,
})

vimcode.command("SqlNewConnection", function(_)
  open_conn_dialog()
end)

vimcode.command("SqlConnections", function(_)
  connect_picker()
end)
