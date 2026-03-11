# Git Insights

Inline git blame annotations — see who last changed each line, when, and why.

**Requires**: `git` on PATH

## How It Works

Move the cursor to any line in a git-tracked file and the blame annotation appears inline at the end of the line, showing the author, relative date, and commit message.

Annotations are suppressed in Insert mode to avoid distraction while editing.

## Features

- Inline blame annotations on the current line
- Automatic update as you navigate
- Clean display: uncommitted changes show no annotation
- Works with unsaved buffers (uses `--contents -` to blame working copy)

## Lua API

The following functions are available under `vimcode.git.*` for plugin authors:

| Function | Returns | Description |
|---|---|---|
| `show(hash)` | string or nil | Full `git show` output for a commit |
| `blame_file()` | table | Structured blame for every line in the current buffer |
| `blame_line(n)` | table or nil | Blame info for a single line |
| `line_log(start, end, limit)` | table | Commits that touched a line range |
| `file_log(limit)` | table | Simple log for current file |
| `file_log_detailed(limit)` | table | Detailed log with author, date, stat |
| `log(limit)` | table | Repo-wide commit log |
| `diff_ref(ref)` | string or nil | Diff against a ref (branch, tag, HEAD) |
| `repo_root()` | string or nil | Git repository root path |
| `branch()` | string or nil | Current branch name |
| `stash_list()` | table | List of stash entries |
| `stash_push(msg)` | string | Push to stash with optional message |
| `stash_pop(index)` | string | Pop stash entry by index |
| `stash_show(index)` | string or nil | Show stash diff |
