# SQL Tool

SQLite-backed query runner with an async results grid. Open a `.db` file, write
SQL in a normal editor buffer (full vim motions, undo, syntax highlighting),
run it, and see the rows in a results tab.

**Requires**: the `sqlite3` CLI on PATH. Every query runs it with `-json`
through `vimcode.loop.spawn` — a real child process, never a blocking shell
call — so the editor never freezes while a query is in flight.

## Database panel

A **SQL** panel in the activity-bar sidebar is the home for browsing and
connecting. It has three sections:

- **Connection** — a clickable toolbar (**Connect**, **New**, **Disconnect**,
  **Refresh**) under the panel header, a status line, and one row per saved
  connection. Click a toolbar button, or use the keys `c` / `n` / `d` / `r`.
  Selecting a saved connection connects to it; right-click it to connect or
  delete.
- **Tables** — the connected database's tables. Press `Tab` on a table to
  expand it to its **columns** (fetched lazily and cached). Press `Enter` (or
  right-click → "Select top 1000 rows") to run `SELECT * FROM <table> LIMIT
  1000` into the results grid. `Enter` on a column copies its name.
- **Views** — the database's views, same `Enter` / right-click behaviour.

The panel is engine-agnostic — each adapter supplies its own catalog query,
column query and `SELECT TOP N` dialect (see "Adapters" below).

**New connection** (the `n` action, or `:SqlNewConnection`) opens a connection
**dialog** — a form with a name, an engine dropdown, the engine's connection
fields (for SQLite, a file path; a server engine would add host/port/user and a
masked password) and a **Connect** button. It opens as an editor tab. On
connect it opens the database and saves the connection (minus any password —
see "Adapters") to the Connection section. `:SqlConnections` reconnects to a
saved connection from a picker.

## Commands

| Command | Effect |
|---|---|
| `:SqlOpen <path.db>` | Connect to a sqlite3 database file. The path must exist and be readable — a missing or unreadable path is refused up front (sqlite3 would otherwise create an empty db and the error would surface only later as "no such table"). Remembered in recents. |
| `:SqlPickRecent` | Fuzzy-pick a previously opened database and switch to it. |
| `:SqlRun` | Run the whole query buffer, or just lines `<start>,<end>` when given a hand-typed numeric range (e.g. `:SqlRun 3,7`). |
| `:SqlSort <column\|index> [asc\|desc]` | Reorder the current result rows in place by one column, without re-querying. Numeric columns sort numerically (not lexicographically); `NULL`s sort first ascending / last descending. The column may be named or given as a 1-based index into the displayed columns. Complements click-a-header sort (which the engine handles) with decoded-value, NULL-aware, scriptable ordering — see "Known limitations". |
| `:SqlNewConnection` | Open the connection dialog (a form, in a tab) to define and connect to a new database. |
| `:SqlConnections` | Pick a saved connection from a fuzzy picker and connect to it. |

## Keymaps

| Mode | Key | Effect |
|---|---|---|
| Normal | `<leader>r` | Run the whole query buffer. |

There is no visual-mode binding: see "Known limitations" below.

## How it works

- `:SqlOpen` creates a scratch buffer named `sql-tool query.sql` with
  `filetype = "sql"`, so VimCode's native SQL syntax highlighting and vim
  motions apply — there is no custom query widget. This only happens on
  the *first* successful connection in a session; later `:SqlOpen` /
  `:SqlPickRecent` calls change which database `:SqlRun` targets without
  touching the buffer, so your in-progress query survives switching
  databases.
- Recently opened databases are persisted with `vimcode.storage`, so they
  survive restarts. The list holds the 10 most recent, most-recent first,
  deduplicated by path.
- `:SqlRun` reads the buffer (or a hand-typed numeric range), spawns
  `sqlite3 <db> -json '<query>'`, and shows the parsed rows in a results
  view (`vimcode.ui.register_view`, `kind = "table"`) opened as its own tab,
  reused across runs. Because a re-run can update that tab while it sits
  behind the query buffer, each run also prints a one-line status message
  (row count, or an error pointer) so it never looks like nothing happened.
  Column names come from the union of keys
  across every returned row (sorted, since `sqlite3 -json` does not
  guarantee key order and a query can return rows with different NULL
  columns present/absent).
- A non-zero `sqlite3` exit, a process that fails to even start, or output
  that isn't valid JSON all surface as text in the results pane and via
  `vimcode.message`, instead of failing silently. The editor stays
  responsive throughout — a failing or slow query never blocks typing in
  another buffer.
- Running a query while one is still in flight **supersedes** it: the new run
  takes over the results view and the earlier query's (now stale) result is
  discarded when it eventually finishes. Runs are tracked by a generation
  token rather than a hard "a query is running" lock, so a query whose process
  is killed or whose exit is never delivered can never wedge the extension
  into refusing every later command.

## Adapters

Everything engine-specific lives behind a small **adapter** table in
`sql_tool.lua`, so the results grid, sorting, recents and the object panel stay
database-agnostic. An adapter provides: the CLI `binary`; `open(target)` to
validate a connection; `query_args`/`parse` to run a query and shape its
output; and `objects_args`/`parse_objects`/`top_n_sql` for the panel's catalog
and "select top N" dialect. **SQLite is the only adapter today** (it needs the
`sqlite3` CLI). Adding Postgres (`psql`) or MySQL (`mysql`) is a new adapter
entry plus its install command — no changes to the UI code. Note there is no
secrets store in VimCode yet (`vimcode.storage` is plaintext), so a server
adapter should prompt for the password at connect time or defer to the engine's
own credential files (`~/.pgpass`, `~/.my.cnf`, `PGSERVICE`), not persist it.

## Known limitations

- **Empty result sets show no columns.** `sqlite3 -json` prints `[]` for a
  zero-row result, which carries no column names. A `SELECT` that matches no
  rows shows an empty table with no headers rather than "0 of N columns" —
  a consequence of driving `sqlite3 -json` instead of `PRAGMA table_info`.
- **Results are read-only.** The table view's columns are declared
  non-editable; editing query results back into the database is explicitly
  out of scope for this extension (tracked as a separate, unfiled
  follow-on).
- **Header-click sort vs. `:SqlSort`.** Clicking a results-grid column header
  now sorts the grid: the engine reorders the rows in a three-state cycle
  (unsorted → ascending → descending), and it is numeric-aware (numeric cells
  sort numerically). sql-tool handles the `HeaderClicked` event only to echo
  what the click did on the status line — it does **not** re-sort the rows
  itself (that would fight the engine's own ordering). Header-click sort and
  declarable column widths both landed upstream in JDonaghy/vimcode#2034; the
  grid also gained header-divider resize in JDonaghy/vimcode#2018. `:SqlSort`
  stays because it sorts the **decoded** values rather than the painted cell
  strings, so it can order a numeric column numerically *and* place `NULL`s
  predictably (first ascending / last descending) — which the engine's
  string-based overlay cannot — and because it is scriptable and keyboard-only.
- **Result columns are floored at their header width, then size to content.**
  Each column declares a `min_width` equal to its header text (JDonaghy/vimcode
  #2034), so a column name is never squeezed to an unreadable sliver when a
  result is wide; above that floor the column sizes to its content instead of
  the old even split. (Units are character cells on the TUI, pixels on the GUI
  backends.) On an engine predating that field the declaration is ignored and
  the columns fall back to the even Flex split.
- **Column headers are currently not drawn in the results grid.** A regression
  landed upstream (the results grid's `kind = "table"` view shows its data rows
  but no header row); the extension still supplies the column titles and
  `:SqlSort` still reorders the rows, so this is a `vimcode`/quadraui table-
  rendering regression, not a change here. Tracked as JDonaghy/vimcode#2037.
- **Re-runs update the results tab in the background.** The results open in
  their own tab, opened once and reused. `open_view` has no "focus/reopen the
  existing tab" mode (only "open a brand new one"), so a re-run refreshes that
  tab even when it is behind the query buffer — and if you *close* it, later
  runs update it offscreen until you reload. The per-run status-line message
  (row count / error) is the mitigation; a real fix needs a focus-existing-tab
  mode in `vimcode`'s `open_view`. (Opening the grid as a split avoids this but
  was not the preferred layout.)
- **There is no visual-mode `:SqlRun`.** `:'<,'>SqlRun` (vim-native visual
  range syntax) can never dispatch to a plugin command — any `'`-prefixed
  command name is routed to a dispatcher that only recognizes built-in
  commands. There is also no plugin-facing API that exposes the `'<`/`'>`
  visual-selection marks a keymap callback could read instead. Use
  `:SqlRun <start>,<end>` with hand-typed line numbers to run a subset of
  the buffer. Both gaps would need new bindings in `vimcode` to fix.
- **The query buffer is only (re)created on the first successful
  `:SqlOpen`/`:SqlPickRecent` in a session.** `vimcode.buf.open_scratch`
  always creates a brand-new buffer and replaces the active window's
  buffer — there is no "re-focus an existing scratch buffer by name" mode
  in the engine. Calling it again on every database switch would silently
  discard whatever query you were mid-typing, so later switches change
  only which database `:SqlRun` targets, not the buffer.

## Manual verification (no automated Lua runtime wired into CI)

This repository's Lua is not executed by the repo's CI gate — see the root
`README.md`'s "What is NOT tested here" section. `scripts/validate.py` only
proves `manifest.toml` parses and matches `registry.json`; it never loads
`sql_tool.lua`. `tests/sql_tool_spec.lua` in this directory is a genuine,
runnable black-box test (mocking the `vimcode` table) that drives the real
`sql_tool.lua` against the real `sqlite3` CLI; it is run during development
with `luajit` (or `lua5.4`) + `sqlite3` on PATH and currently passes 111
checks. Two caveats keep it from being proof the extension works in VimCode:
it is not wired into CI, and `luajit` is Lua 5.1, not the Lua 5.4/mlua sandbox
VimCode embeds — so the manual smoke below (in a real build) remains the real
proof, especially for the panel and dialog, which the mock can only approximate.

To verify by hand in a real VimCode build:

1. Copy this directory to `~/.config/vimcode/extensions/sql-tool/` and run
   `:ExtInstall` / `:Plugin reload` (see the root README's "Testing
   Locally").
2. Create a fixture database: `sqlite3 /tmp/smoke.db "CREATE TABLE t(a, b);
   INSERT INTO t VALUES (1, 'x'), (2, 'y');"`.
3. `:SqlOpen /tmp/smoke.db` — expect a status-bar message, and a `.sql`
   scratch buffer with SQL syntax highlighting.
4. Type `SELECT * FROM t;` on a line below the seeded `-- <path>` comment and
   press `<leader>r` — expect a new tab to open with a table showing columns
   `a`, `b` and two rows. (The whole buffer, seed comment included, is run; the
   leading `--` comment is passed to sqlite3 after a `--` end-of-options
   sentinel so it is treated as SQL, not a command-line option.)
   Separately, `:SqlOpen /tmp/does-not-exist.db` on a path that isn't there —
   expect a `cannot open ... no such file or not readable` message and *no*
   query buffer, rather than a silent "connected".
5. Change the query to `SELECT * FROM nosuchtable;` and run again — expect
   the same results tab to update in place (not a second tab) showing
   sqlite3's error text instead of silently showing stale or empty rows,
   and the query buffer to stay responsive (keep typing in it immediately).
6. Run `:SqlOpen /tmp/other.db` against a second fixture file — expect the
   status message to report the new connection and the query buffer's text
   to be left exactly as you last edited it (not reset to the seed comment).
   Then run `:SqlPickRecent` — expect both paths in the picker, most recent
   first. Restart VimCode and run `:SqlPickRecent` again — expect the same
   two entries to still be there.
