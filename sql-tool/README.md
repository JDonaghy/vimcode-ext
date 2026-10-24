# SQL Tool

SQLite-backed query runner with an async results grid. Open a `.db` file, write
SQL in a normal editor buffer (full vim motions, undo, syntax highlighting),
run it, and see the rows in a results tab.

**Requires**: the `sqlite3` CLI on PATH. Every query runs it with `-json`
through `vimcode.loop.spawn` — a real child process, never a blocking shell
call — so the editor never freezes while a query is in flight.

## Commands

| Command | Effect |
|---|---|
| `:SqlOpen <path.db>` | Connect to a sqlite3 database file. The path must exist and be readable — a missing or unreadable path is refused up front (sqlite3 would otherwise create an empty db and the error would surface only later as "no such table"). Remembered in recents. |
| `:SqlPickRecent` | Fuzzy-pick a previously opened database and switch to it. |
| `:SqlRun` | Run the whole query buffer, or just lines `<start>,<end>` when given a hand-typed numeric range (e.g. `:SqlRun 3,7`). |
| `:SqlSort <column\|index> [asc\|desc]` | Reorder the current result rows in place by one column, without re-querying. Numeric columns sort numerically (not lexicographically); `NULL`s sort first ascending / last descending. The column may be named or given as a 1-based index into the displayed columns. There is no click-a-header sort — see "Known limitations". |

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
  view (`vimcode.ui.register_view`, `kind = "table"`) opened as its own
  tab, reused across runs. Column names come from the union of keys
  across every returned row (sorted, since `sqlite3 -json` does not
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
- **Results columns cannot be resized, and there is no click-a-header sort.**
  The `kind = "table"` plugin view exposes only `title` and `editable` per
  column — no width — and emits no column/header event (only row
  select/activate and cell-edit), so neither interactive column resizing nor
  click-to-sort is reachable from Lua. `:SqlSort` works around the sort half
  by reordering rows from a command instead. Both would need new surface in
  `vimcode` core (a column width field + resize handling; a header/column
  event). Tracked upstream in `vimcode` as JDonaghy/vimcode#2018.
- **The results pane cannot be a side-by-side split.** `vimcode.ui.open_view`
  always opens a `kind = "table"` plugin view as a brand-new tab; there is
  no engine primitive that can place one as a sibling split of the query
  buffer. The results pane is therefore its own tab, reused across
  `:SqlRun` calls rather than duplicated. A split-capable plugin-view API
  would need to land in `vimcode` itself for this to change.
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
