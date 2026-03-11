# VimCode Extension Development Guide

This document covers everything needed to build VimCode extensions, including the Lua plugin API
and the TOML manifest format. An extension bundles an LSP server config, optional DAP (debugger)
adapter, and optional Lua scripts into a single named package.

> **Registry:** Official extensions live in the [vimcode-ext](https://github.com/JDonaghy/vimcode-ext)
> repository. VimCode fetches the registry on startup and caches it locally. You can also develop
> and test extensions locally before submitting them to the registry.

## Quick Start

Create a directory under `~/.config/vimcode/extensions/` with a `manifest.toml` and optional
Lua scripts:

```
~/.config/vimcode/extensions/my-extension/
├── manifest.toml    # Required: extension metadata + LSP/DAP config
├── my_script.lua    # Optional: Lua plugin script
└── README.md        # Optional: shown in Extensions panel on Enter
```

Install with `:ExtInstall my-extension`, manage with `:ExtList`, `:ExtDisable`, `:ExtEnable`,
`:ExtRemove`.

## Local Extension Development

You can develop and test extensions entirely locally without publishing to the registry:

1. **Create the extension directory:**
   ```bash
   mkdir -p ~/.config/vimcode/extensions/my-extension
   ```

2. **Write a `manifest.toml`** (see schema below):
   ```toml
   name = "my-extension"
   display_name = "My Extension"
   description = "What it does"
   version = "0.1.0"
   scripts = ["my_script.lua"]
   ```

3. **Write your Lua scripts** in the same directory.

4. **Install it:** Open VimCode, open the Extensions panel — your local extension appears
   in the AVAILABLE list. Press `i` or run `:ExtInstall my-extension` to activate it.
   Alternatively, you can directly run `:ExtInstall my-extension` without opening the panel.

5. **Iterate:** Edit your scripts, then `:Plugin reload` to reload without restarting.

Local extensions override registry extensions with the same name, so you can fork and modify
an existing extension by copying it to `~/.config/vimcode/extensions/<name>/`.

### Submitting to the Registry

When your extension is ready, submit a PR to
[vimcode-ext](https://github.com/JDonaghy/vimcode-ext) adding your extension directory
(manifest.toml + scripts + README.md) and an entry in `registry.json`. Once merged,
it becomes available to all VimCode users via the Extensions panel.

### Self-Hosted Registry

Set `extension_registry_url` in `~/.config/vimcode/settings.json` to point to your own
`registry.json` URL. The format is the same as the official registry — a JSON array of
extension manifest objects.

---

## Manifest Format (`manifest.toml`)

Every extension needs a `manifest.toml` describing its capabilities.

### Complete Schema

```toml
# ── Required ──────────────────────────────────────────────
name = "my-extension"                       # Identifier (lowercase, hyphens ok)
display_name = "My Extension"               # Human-readable name

# ── Optional metadata ────────────────────────────────────
description = "What this extension does"    # One-liner
version = "1.0.0"                           # Semver

# ── File / language activation ────────────────────────────
file_extensions = [".py", ".pyi"]           # File types that activate this extension
language_ids = ["python"]                   # LSP language identifiers
workspace_markers = ["pyproject.toml"]      # Files indicating project root

# ── LSP server ────────────────────────────────────────────
[lsp]
binary = "pyright-langserver"               # Primary binary name (must be on PATH)
install = "npm install -g pyright"          # Shell command to install (shown to user)
fallback_binaries = ["pylsp"]               # Tried in order if primary not found
args = ["--stdio"]                          # Arguments passed to the LSP binary

# ── DAP debugger adapter ──────────────────────────────────
[dap]
adapter = "debugpy"                         # Adapter registry name
binary = "python"                           # Executable to launch
install = "pip install debugpy"             # Install command
transport = "stdio"                         # "stdio" or "tcp"
args = ["-m", "debugpy.adapter"]            # Launch arguments

# ── Lua scripts ───────────────────────────────────────────
scripts = ["my_script.lua"]                 # Filenames of bundled Lua scripts

# ── Comment style override ────────────────────────────────
[comment]
line = "//"                                 # Single-line comment prefix
block_open = "/*"                           # Block comment open
block_close = "*/"                          # Block comment close
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | Yes | Unique identifier, used in `:ExtInstall` |
| `display_name` | String | Yes | Shown in the Extensions sidebar |
| `description` | String | No | Short description |
| `version` | String | No | Semver version |
| `file_extensions` | String[] | No | File extensions (e.g., `[".py", ".pyi"]`) |
| `language_ids` | String[] | No | LSP language IDs (e.g., `["python"]`) |
| `workspace_markers` | String[] | No | Files/dirs indicating project root |
| `scripts` | String[] | No | Lua script filenames to load |

#### `[lsp]` Section

| Field | Type | Description |
|-------|------|-------------|
| `binary` | String | Primary LSP server binary name |
| `install` | String | Shell command to install the server |
| `fallback_binaries` | String[] | Alternative binaries tried in order |
| `args` | String[] | Command-line arguments (e.g., `["--stdio"]`) |

#### `[dap]` Section

| Field | Type | Description |
|-------|------|-------------|
| `adapter` | String | Adapter name for DAP registry |
| `binary` | String | Executable to launch |
| `install` | String | Shell command to install |
| `transport` | String | `"stdio"` (default) or `"tcp"` |
| `args` | String[] | Launch arguments |

#### `[comment]` Section

Override comment style for languages handled by this extension.

| Field | Type | Description |
|-------|------|-------------|
| `line` | String | Line comment prefix (e.g., `"//"`, `"#"`, `"--"`) |
| `block_open` | String | Block comment open (e.g., `"/*"`) |
| `block_close` | String | Block comment close (e.g., `"*/"`) |

---

## Example Manifests

### Language Extension (Python)

```toml
name = "python"
display_name = "Python Language Support"
file_extensions = [".py", ".pyi", ".pyw"]
language_ids = ["python"]
workspace_markers = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"]

[lsp]
binary = "pyright-langserver"
install = "npm install -g pyright"
fallback_binaries = ["basedpyright-langserver", "pylsp", "jedi-language-server"]
args = ["--stdio"]

[dap]
adapter = "debugpy"
binary = "python"
transport = "stdio"
args = ["-m", "debugpy.adapter"]
```

### Tooling Extension (Git Insights)

```toml
name = "git-insights"
display_name = "Git Insights"
description = "Inline git blame annotations and file history"
file_extensions = []
language_ids = []
scripts = ["blame.lua", "history.lua", "show.lua", "line_history.lua",
           "diff.lua", "stash.lua", "repo_log.lua", "git_log_panel.lua"]
```

### Minimal LSP-Only Extension

```toml
name = "terraform"
display_name = "Terraform Language Support"
file_extensions = [".tf", ".tfvars", ".hcl"]
language_ids = ["terraform", "terraform-vars"]
workspace_markers = ["main.tf", "terraform.tfstate"]

[lsp]
binary = "terraform-ls"
install = "brew install hashicorp/tap/terraform-ls"
args = ["serve"]
```

---

## Lua Plugin API

Lua scripts have access to the `vimcode` global object. Scripts run in Lua 5.4.

### Registration Functions

Call these at the top level of your script (during load time):

```lua
-- Register a custom command (callable via :MyCommand args)
vimcode.command("MyCommand", function(args)
    -- args is a string containing everything after the command name
    vimcode.message("Got: " .. args)
end)

-- Register an event hook
vimcode.on("save", function(path)
    vimcode.message("Saved: " .. path)
end)

-- Register a key mapping
-- Modes: "n" (normal), "i" (insert), "v" (visual), "c" (command)
vimcode.keymap("n", "<leader>h", function()
    vimcode.message("Hello from keymap!")
end)
```

### Core Functions

```lua
vimcode.message(text)           -- Display a status bar message
vimcode.cwd()                   -- Get current working directory (string)
vimcode.command_run(cmd)        -- Execute a VimCode command (e.g., "w", "q", "split")
```

### Buffer Functions (`vimcode.buf.*`)

All line numbers are **1-indexed**.

```lua
vimcode.buf.lines()             -- All buffer lines as a table
vimcode.buf.line(n)             -- Get line n (returns string or nil)
vimcode.buf.set_line(n, text)   -- Replace line n with text
vimcode.buf.insert_line(n, text)-- Insert new line before position n
vimcode.buf.delete_line(n)      -- Delete line n
vimcode.buf.line_count()        -- Total number of lines
vimcode.buf.path()              -- File path (string or nil for unnamed buffers)
vimcode.buf.cursor()            -- Returns {line=N, col=M} (1-indexed)
vimcode.buf.set_cursor(line, col) -- Move cursor to position
vimcode.buf.annotate_line(n, text) -- Add virtual text annotation to line n
vimcode.buf.clear_annotations() -- Clear all line annotations
vimcode.buf.open_scratch(name, content, opts) -- Open a scratch buffer
  -- opts (optional table): readonly=bool, filetype=string, split="vertical"|"horizontal"
```

### Settings Functions (`vimcode.opt.*`)

```lua
vimcode.opt.get("tabstop")      -- Query a setting value (returns string)
vimcode.opt.set("tabstop", "4") -- Set a setting value
```

Available settings include: `number`, `relativenumber`, `tabstop`, `shiftwidth`, `expandtab`,
`autoindent`, `wrap`, `hlsearch`, `ignorecase`, `smartcase`, `scrolloff`, `cursorline`,
`colorcolumn`, `textwidth`, `splitbelow`, `splitright`, `colorscheme`, and more.

### State Functions (`vimcode.state.*`)

```lua
vimcode.state.mode()            -- Current mode: "Normal", "Insert", "Visual", etc.
vimcode.state.filetype()        -- Buffer language ID: "rust", "python", etc.
vimcode.state.register("a")     -- Get register: {content="...", linewise=false} or nil
vimcode.state.set_register("a", "text", false) -- Set register (char, content, linewise)
vimcode.state.mark("a")         -- Get mark position: {line=N, col=M} or nil
```

### Git Functions (`vimcode.git.*`)

```lua
-- Get blame info for a single line (returns table or nil)
local blame = vimcode.git.blame_line(10)
-- blame = {hash="abc123", author="Name", date=1700000000,
--          relative_date="3 days ago", message="Fix bug", not_committed=false}

-- Get structured blame for every line in the current buffer
local all_blame = vimcode.git.blame_file()
-- all_blame = {{hash="abc123", author="Name", ...}, ...}

-- Get recent commits for the current file (simple)
local log = vimcode.git.log_file(20)
-- log = {{hash="abc123", message="Fix bug"}, ...}

-- Get detailed commits for the current file (with author, date, stat)
local detailed = vimcode.git.file_log_detailed(20)
-- detailed = {{hash="abc123", author="Name", date="3 days ago", message="Fix bug", stat="1 file changed"}, ...}

-- Get commits that touched a specific line range
local line_commits = vimcode.git.line_log(10, 20, 50)
-- line_commits = {{hash="abc123", author="Name", date="3 days ago", message="Fix"}, ...}

-- Get repo-wide commit log
local repo_log = vimcode.git.log(100)
-- repo_log = {{hash="abc123", message="Fix bug"}, ...}

-- Show full commit details
local show = vimcode.git.show("abc123")  -- string or nil

-- Diff against a ref (branch, tag, HEAD, etc.)
local diff = vimcode.git.diff_ref("main")  -- string or nil

-- Repository info
local root = vimcode.git.repo_root()  -- string or nil
local branch = vimcode.git.branch()   -- string or nil

-- Stash operations
local stashes = vimcode.git.stash_list()
-- stashes = {{index=0, message="WIP", branch="main"}, ...}
local result = vimcode.git.stash_push("save my work")  -- string
local result = vimcode.git.stash_pop(0)                 -- string
local diff = vimcode.git.stash_show(0)                   -- string or nil

-- List all branches with tracking info
local branches = vimcode.git.branches()
-- branches = {{name="main", tracking="origin/main", is_current=true}, ...}
```

### Async Shell Execution

Run shell commands in a background thread with results delivered via event hooks:

```lua
-- Basic usage
vimcode.async_shell("git status", "my_result_event")

-- With options
vimcode.async_shell("grep -n pattern", "search_done", {
    stdin = "input text",   -- Optional: pipe to stdin
    cwd = "/path/to/dir"    -- Optional: working directory
})

-- Handle the result
vimcode.on("my_result_event", function(output)
    vimcode.message("Result: " .. output)
end)
```

### Panel API (`vimcode.panel.*`)

Extensions can register custom sidebar panels that appear in the activity bar. This is the same mechanism used by the git-insights extension's Git Log panel.

```lua
-- Register a custom sidebar panel (call at load time)
vimcode.panel.register("my_panel", {
    icon = "X",                          -- Single character for activity bar icon
    sections = {"Section A", "Section B"}, -- Named collapsible sections
    on_focus = function()                -- Called when panel gains focus
        -- Populate sections here
    end
})

-- Populate a section with items
vimcode.panel.set_items("my_panel", "Section A", {
    {label = "Item 1", hint = "description", icon = "*", style = "normal"},
    {label = "Item 2", hint = "extra info",  icon = "+", style = "dim"},
    {label = "Item 3", hint = "important",   icon = "!", style = "bold"},
})

-- Parse event argument from panel_select/panel_action hooks
local info = vimcode.panel.parse_event(arg)
-- info = {panel="my_panel", section="Section A", index=0, label="Item 1", key="a"}
```

**Panel navigation keys** (when panel has focus):

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate items |
| `Tab` | Expand/collapse section |
| `Enter` | Fire `panel_select` event for current item |
| `q` / `Escape` | Unfocus panel |
| Other keys | Fire `panel_action` event with the key |

**Panel events:**

| Event | Argument | When |
|-------|----------|------|
| `panel_focus` | panel name | Panel gains focus in sidebar |
| `panel_select` | `"panel:section:index:label"` | Enter pressed on item |
| `panel_action` | `"key:panel:section:index:label"` | Other key pressed on item |

**Item styles:**

| Style | Effect |
|-------|--------|
| `"normal"` | Default foreground color |
| `"dim"` | Muted/grey text |
| `"bold"` | Highlighted/bright text |

### Comment Style Override

Override comment syntax for a language (useful for custom/niche languages):

```lua
vimcode.set_comment_style("haskell", {
    line = "--",
    block_open = "{-",
    block_close = "-}"
})
```

---

## Events Reference

| Event | Argument | When |
|-------|----------|------|
| `save` | file path | Before buffer is written to disk |
| `BufWrite` | file path | After buffer is written to disk |
| `open` | file path | File opened in editor |
| `BufNew` | file path | New buffer created |
| `BufEnter` | file path | Buffer/window entered |
| `cursor_move` | `"line,col"` | Cursor moves (Normal mode only) |
| `VimEnter` | `""` | Editor initialization complete |
| `InsertEnter` | mode name | Entered Insert mode |
| `InsertLeave` | mode name | Left Insert mode |
| `ModeChanged` | `"Old->New"` | Any mode change (e.g., `"Normal->Insert"`) |
| `panel_focus` | panel name | Extension panel gains focus |
| `panel_select` | `"panel:section:index:label"` | Enter pressed on extension panel item |
| `panel_action` | `"key:panel:section:index:label"` | Other key pressed on extension panel item |
| Custom | shell output | `async_shell()` callback event |

---

## Complete Example: Word Count Extension

```lua
-- ~/.config/vimcode/extensions/wordcount/wordcount.lua

-- Count words in the current buffer
vimcode.command("WordCount", function(_)
    local lines = vimcode.buf.lines()
    local count = 0
    for _, line in ipairs(lines) do
        for _ in line:gmatch("%S+") do
            count = count + 1
        end
    end
    vimcode.message("Word count: " .. count)
end)

-- Count words in selection (visual mode)
vimcode.command("WordCountSelection", function(args)
    -- args contains "start_line,end_line" when called from visual mode
    local s, e = args:match("(%d+),(%d+)")
    if not s then
        vimcode.message("No selection")
        return
    end
    local count = 0
    for i = tonumber(s), tonumber(e) do
        local line = vimcode.buf.line(i)
        if line then
            for _ in line:gmatch("%S+") do
                count = count + 1
            end
        end
    end
    vimcode.message("Selected word count: " .. count)
end)

-- Show word count on save
vimcode.on("save", function(_)
    local lines = vimcode.buf.lines()
    local count = 0
    for _, line in ipairs(lines) do
        for _ in line:gmatch("%S+") do
            count = count + 1
        end
    end
    vimcode.message("Saved (" .. count .. " words)")
end)
```

With manifest:

```toml
name = "wordcount"
display_name = "Word Count"
description = "Word counting commands and save-time word count display"
scripts = ["wordcount.lua"]
```

## Complete Example: Inline Git Blame

```lua
-- blame.lua — show inline blame annotations as you move the cursor

vimcode.on("cursor_move", function(pos)
    local line, _ = pos:match("(%d+),(%d+)")
    line = tonumber(line)
    if not line then return end

    local blame = vimcode.git.blame_line(line)
    if blame and not blame.not_committed then
        local text = blame.author .. " • " .. blame.relative_date .. " • " .. blame.message
        vimcode.buf.clear_annotations()
        vimcode.buf.annotate_line(line, text)
    else
        vimcode.buf.clear_annotations()
    end
end)
```

## Complete Example: Auto-Format on Save

```lua
-- autoformat.lua — run formatter on save for specific filetypes

local formatters = {
    rust = "rustfmt",
    python = "black -q -",
    javascript = "prettier --stdin-filepath %",
    go = "gofmt",
}

vimcode.on("save", function(path)
    local ft = vimcode.state.filetype()
    local cmd = formatters[ft]
    if cmd then
        -- Use built-in LSP format if available, otherwise shell out
        vimcode.command_run("Lformat")
    end
end)
```

---

## Plugin Loading Details

### Load Order

1. User plugins from `~/.config/vimcode/plugins/` (alphabetical)
2. Extension scripts from `~/.config/vimcode/extensions/<name>/` (for installed extensions)

### Plugin Formats

- **Single file**: `~/.config/vimcode/plugins/my_plugin.lua`
- **Directory**: `~/.config/vimcode/plugins/my_plugin/init.lua`

### Disabling Plugins

```vim
:Plugin disable my_plugin
:Plugin enable my_plugin
:Plugin list
:Plugin reload
```

Or set in `~/.config/vimcode/settings.json`:

```json
{
    "disabled_plugins": ["my_plugin"]
}
```

### Extension Commands

```vim
:ExtInstall <name>     " Install an extension
:ExtRemove <name>      " Uninstall an extension
:ExtEnable <name>      " Enable a disabled extension
:ExtDisable <name>     " Disable without removing
:ExtList               " List all extensions and status
:ExtRefresh            " Refresh the extension registry
```

---

## Tips for AI-Assisted Development

When asking an AI to write a VimCode extension:

1. **Specify the manifest fields** — name, display_name, file_extensions, language_ids
2. **For LSP extensions** — provide the binary name and install command
3. **For script extensions** — describe the behavior, which events to hook, and which commands to register
4. **All line numbers are 1-indexed** in the Lua API
5. **Use `vimcode.async_shell()`** for any I/O that might block (git, network, file search)
6. **The cursor_move event** only fires in Normal mode (suppressed in Insert mode for performance)
7. **Buffer modifications** via `set_line`/`insert_line`/`delete_line` are applied after the callback returns
8. **Test with** `:Plugin reload` to reload scripts without restarting the editor
