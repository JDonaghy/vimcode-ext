# SQL Tool

SQLite-backed query runner with an async results grid. Open a `.db` file, write
SQL in a normal editor buffer (full vim motions, undo, syntax highlighting),
run it, and see the rows in a table view beside your query.

**Requires**: the `sqlite3` CLI on PATH. Every query runs it with `-json`
through `vimcode.loop.spawn` — a real child process, never a blocking shell
call — so the editor never freezes while a query is in flight.

## Commands

| Command | Effect |
|---|---|
| `:SqlOpen <path.db>` | Connect to a sqlite3 database file. Remembered in recents. |
| `:SqlPickRecent` | Fuzzy-pick a previously opened database and switch to it. |
| `:SqlRun` | Run the whole query buffer. With a visual range (`:'<,'>SqlRun`), runs just the selected lines. |

## Keymaps

| Mode | Key | Effect |
|---|---|---|
| Normal | `<leader>r` | Run the whole query buffer. |
| Visual | `<leader>r` | Run the selected lines only. |

## How it works

- `:SqlOpen` opens (or re-focuses) a scratch buffer named `sql-tool
  query.sql` with `filetype = "sql"`, so VimCode's native SQL syntax
  highlighting and vim motions apply — there is no custom query widget.
  The database path is tracked separately from the buffer, so switching
  databases with `:SqlOpen`/`:SqlPickRecent` does not touch your in-progress
  query.
- Recently opened databases are persisted with `vimcode.storage`, so they
  survive restarts. The list holds the 10 most recent, most-recent first,
  deduplicated by path.
- `:SqlRun` reads the buffer (or selection), spawns
  `sqlite3 <db> -json '<query>'`, and shows the parsed rows in a results
  view (`vimcode.ui.register_view`, `kind = "table"`) opened beside the
  query buffer in a vertical split. Column names come from the union of
  keys across every returned row (sorted, since `sqlite3 -json` does not
  guarantee key order and a query can return rows with different NULL
  columns present/absent).
- A non-zero `sqlite3` exit, a process that fails to even start, or output
  that isn't valid JSON all surface as text in the results pane and via
  `vimcode.message`, instead of failing silently. The editor stays
  responsive throughout — a failing or slow query never blocks typing in
  another buffer.

## Known limitations

- **Empty result sets show no columns.** `sqlite3 -json` prints `[]` for a
  zero-row result, which carries no column names. A `SELECT` that matches no
  rows shows an empty table with no headers rather than "0 of N columns" —
  a consequence of driving `sqlite3 -json` instead of `PRAGMA table_info`.
- **Results are read-only.** The table view's columns are declared
  non-editable; editing query results back into the database is explicitly
  out of scope for this extension (tracked as a separate, unfiled
  follow-on).
- **The side-by-side split is a best-effort ordering of two documented but
  separately-queued primitives.** Opening the results pane runs
  `vimcode.command_run("vsplit")` (queued, applied after the current
  callback returns) followed by `vimcode.ui.open_view` inside
  `vimcode.schedule` (deferred to the next idle tick, after the queued
  split lands). This is the ordering `EXTENSIONS.md` supports, but it has
  not been exercised against a live VimCode instance in this environment —
  see "Manual verification" below.
- **Reopening an already-open query buffer's seed content is unconfirmed.**
  `:SqlOpen`/`:SqlPickRecent` call `vimcode.buf.open_scratch` with a one-line
  seed comment every time. `EXTENSIONS.md` does not say whether re-opening
  an existing scratch buffer by name replaces its content or preserves it
  and ignores the `content` argument. If it replaces, switching databases
  while mid-query will discard unsaved SQL — worth confirming against a
  real VimCode build.

## Manual verification (no automated Lua runtime in this repo or sandbox)

This repository's Lua is not executed by any automated test — see the root
`README.md`'s "What is NOT tested here" section. `scripts/validate.py` only
proves `manifest.toml` parses and matches `registry.json`; it never loads
`sql_tool.lua`. `tests/sql_tool_spec.lua` in this directory is a genuine,
runnable black-box test (mocking the `vimcode` table) for anyone with
`lua5.4` and `sqlite3` installed, but it was written and committed without
being run — this sandbox has neither binary available, nor permission to
install them. Treat it as a starting point for CI, not as proof the
extension works.

To verify by hand in a real VimCode build:

1. Copy this directory to `~/.config/vimcode/extensions/sql-tool/` and run
   `:ExtInstall` / `:Plugin reload` (see the root README's "Testing
   Locally").
2. Create a fixture database: `sqlite3 /tmp/smoke.db "CREATE TABLE t(a, b);
   INSERT INTO t VALUES (1, 'x'), (2, 'y');"`.
3. `:SqlOpen /tmp/smoke.db` — expect a status-bar message, and a `.sql`
   scratch buffer with SQL syntax highlighting.
4. Type `SELECT * FROM t;` and press `<leader>r` — expect a vertical split
   to appear with a table showing columns `a`, `b` and two rows.
5. Change the query to `SELECT * FROM nosuchtable;` and run again — expect
   the results pane to show sqlite3's error text instead of silently
   showing stale or empty rows, and the query buffer to stay responsive
   (keep typing in it immediately).
6. Run `:SqlOpen /tmp/other.db` against a second fixture file, then
   `:SqlPickRecent` — expect both paths in the picker, most recent first.
   Restart VimCode and run `:SqlPickRecent` again — expect the same two
   entries to still be there.
