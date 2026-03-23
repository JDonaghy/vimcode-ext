-- Git Insights: Git Log Panel — lazygit-inspired interactive sidebar panel
-- Expandable commits with file children, hover details, and action keys.

vimcode.panel.register("git_log", {
  title = "GIT LOG",
  icon = "\u{f1d3}",
  sections = { "Branches", "Log", "Stash" },
})

vimcode.panel.set_help("git_log", {
  {"j/k", "Navigate"},
  {"Tab", "Expand / collapse"},
  {"Enter", "Open / expand"},
  {"o", "Open diff"},
  {"y", "Copy hash / path"},
  {"b", "Open in browser"},
  {"r", "Refresh"},
  {"/", "Search / filter"},
  {"d", "Pop stash"},
  {"p", "Push stash"},
  {"q/Esc", "Close panel"},
})

-- Set of commit hashes we've already fetched files for.
-- We always send ALL items to set_items() and let the engine's tree
-- expand/collapse system handle visibility via parent_id + expandable.
local fetched_commits = {}
-- The full unfiltered log
local full_log = nil
-- Current search query
local search_query = ""
-- Hover content cache: hash → markdown (fetched lazily)
local hover_cache = {}

-- Status char to human-readable label
local function status_label(s)
  if s == "A" then return "added"
  elseif s == "D" then return "deleted"
  elseif s == "R" then return "renamed"
  else return "modified"
  end
end

-- Simple file icon based on extension
local function file_icon_for(path)
  local ext = path:match("%.(%w+)$")
  if not ext then return "\u{f15b}" end  -- generic file
  ext = ext:lower()
  local icons = {
    rs = "\u{e7a8}", py = "\u{f81f}", js = "\u{e74e}", ts = "\u{e628}",
    lua = "\u{e620}", go = "\u{e626}", rb = "\u{e739}", java = "\u{e738}",
    c = "\u{e61e}", h = "\u{e61e}", cpp = "\u{e61d}", cs = "\u{f81a}",
    json = "\u{e60b}", toml = "\u{e6b2}", yaml = "\u{e6a8}", yml = "\u{e6a8}",
    md = "\u{e73e}", html = "\u{e736}", css = "\u{e749}", sh = "\u{e795}",
    lock = "\u{f023}",
  }
  return icons[ext] or "\u{f15b}"
end

-- Build the full list of log section items.
local function build_log_items(log_entries)
  local items = {}
  for _, e in ipairs(log_entries) do
    local has_children = fetched_commits[e.hash] ~= nil
    table.insert(items, {
      text = e.message,
      hint = e.hash:sub(1, 8),
      style = "normal",
      id = e.hash,
      expandable = true,
      expanded = false,
    })
    if has_children then
      local files = fetched_commits[e.hash]
      for _, f in ipairs(files) do
        table.insert(items, {
          text = f.path:match("[^/]+$") or f.path,
          hint = status_label(f.status),
          icon = file_icon_for(f.path),
          style = f.status == "D" and "dim" or "normal",
          id = e.hash .. ":" .. f.path,
          indent = 1,
          parent_id = e.hash,
        })
      end
    end
  end
  return items
end

-- Apply search filter to log entries
local function filtered_log()
  if not full_log then return {} end
  if search_query == "" then return full_log end
  local q = search_query:lower()
  local result = {}
  for _, e in ipairs(full_log) do
    if e.message:lower():find(q, 1, true) or e.hash:lower():find(q, 1, true) then
      table.insert(result, e)
    end
  end
  return result
end

-- Refresh and rebuild the Log section items.
-- Hover content is set lazily (only for the first few visible) to avoid
-- spawning 100 git subprocesses on every refresh.
local function refresh_log_section()
  local entries = filtered_log()
  local items = build_log_items(entries)
  vimcode.panel.set_items("git_log", "Log", items)
  -- Set basic hover for all commits (just the message — no subprocess)
  for _, e in ipairs(entries) do
    if hover_cache[e.hash] then
      vimcode.panel.set_hover("git_log", e.hash, hover_cache[e.hash])
    else
      vimcode.panel.set_hover("git_log", e.hash, e.hash:sub(1, 8) .. " " .. e.message)
    end
  end
end

local function refresh_all()
  -- Branches
  local branches = vimcode.git.branches()
  local branch_items = {}
  if branches then
    for _, b in ipairs(branches) do
      local hint = ""
      if b.ahead_behind and b.ahead_behind ~= "" then
        hint = b.ahead_behind
      end
      table.insert(branch_items, {
        text = b.name,
        icon = b.is_current and "\u{f111}" or " ",
        style = b.is_current and "accent" or "normal",
        hint = hint,
        id = b.name,
      })
    end
  end
  vimcode.panel.set_items("git_log", "Branches", branch_items)

  -- Log
  full_log = vimcode.git.log(100)

  -- If a reveal target was set, ensure the commit is in the log.
  if _git_log_reveal_target and #_git_log_reveal_target >= 7 then
    local target = _git_log_reveal_target
    _git_log_reveal_target = nil
    local found = false
    for _, e in ipairs(full_log) do
      if e.hash == target or e.hash:sub(1, #target) == target or target:sub(1, #e.hash) == e.hash then
        found = true
        break
      end
    end
    if not found then
      -- Fetch the specific commit info and append it
      local extra = vimcode.git.log_commit(target)
      if extra then
        table.insert(full_log, extra)
      end
    end
  end

  refresh_log_section()

  -- Stash
  local stashes = vimcode.git.stash_list()
  local stash_items = {}
  if stashes then
    for _, s in ipairs(stashes) do
      table.insert(stash_items, {
        text = s.message ~= "" and s.message or ("stash@{" .. s.index .. "}"),
        hint = s.branch,
        style = "dim",
        id = tostring(s.index),
      })
    end
  end
  vimcode.panel.set_items("git_log", "Stash", stash_items)
end

vimcode.on("panel_focus", function(name)
  if name ~= "git_log" then return end
  refresh_all()
end)

-- Expand: fetch files for commit and rebuild items so children exist
vimcode.on("panel_expand", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" or e.section ~= "Log" then return end
  if e.id == "" or e.id:find(":") then return end
  if not fetched_commits[e.id] then
    local files = vimcode.git.commit_files(e.id)
    fetched_commits[e.id] = files or {}
    -- Also fetch detailed hover now (single commit, not 100)
    local detail = vimcode.git.commit_detail(e.id)
    if detail then
      local md = string.format("**%s** %s\n\n%s", detail.author or "", detail.date or "", detail.message or "")
      if detail.stat and detail.stat ~= "" then
        md = md .. "\n\n`" .. detail.stat .. "`"
      end
      hover_cache[e.id] = md
      vimcode.panel.set_hover("git_log", e.id, md)
    end
    refresh_log_section()
  end
end)

-- Helper: open a side-by-side diff for a file at a commit vs its parent
local function open_file_diff(hash, path)
  vimcode.git.open_diff(hash, path)
end

-- Select: Enter on an item (only fires for non-expandable items)
vimcode.on("panel_select", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" then return end

  if e.section == "Log" and e.id ~= "" then
    local hash, path = e.id:match("^(%x+):(.+)$")
    if hash and path then
      open_file_diff(hash, path)
    else
      -- Commit: open full diff (shouldn't normally reach here since
      -- commits are expandable, but handle as fallback)
      local content = vimcode.git.show(e.id)
      if content then
        vimcode.buf.open_scratch("GitShow " .. e.id:sub(1, 8), content, {
          readonly = true,
          filetype = "diff",
        })
      else
        vimcode.message("git show failed for: " .. e.id)
      end
    end
  elseif e.section == "Stash" and e.id ~= "" then
    local content = vimcode.git.stash_show(tonumber(e.id) or 0)
    if content then
      vimcode.buf.open_scratch("GitStash @{" .. e.id .. "}", content, {
        readonly = true,
        filetype = "diff",
      })
    else
      vimcode.message("git stash show failed for: " .. e.id)
    end
  end
end)

-- Action keys
vimcode.on("panel_action", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" then return end

  -- r = refresh (any section)
  if e.key == "r" then
    fetched_commits = {}
    hover_cache = {}
    refresh_all()
    vimcode.message("Git Log: refreshed")
    return
  end

  if e.section == "Log" and e.id ~= "" then
    local hash, path = e.id:match("^(%x+):(.+)$")

    -- o = open diff
    if e.key == "o" then
      if hash and path then
        open_file_diff(hash, path)
      else
        local content = vimcode.git.show(e.id)
        if content then
          vimcode.buf.open_scratch("GitShow " .. e.id:sub(1, 8), content, {
            readonly = true,
            filetype = "diff",
          })
        end
      end
      return
    end

    -- y = copy hash or path
    if e.key == "y" then
      if hash and path then
        vimcode.state.set_register("+", path, false)
        vimcode.message("Copied: " .. path)
      else
        local short = e.id:sub(1, 8)
        vimcode.state.set_register("+", short, false)
        vimcode.message("Copied: " .. short)
      end
      return
    end

    -- b = open commit in browser
    if e.key == "b" and not hash then
      local url = vimcode.git.commit_url(e.id:sub(1, 8))
      if url then
        vimcode.open_url(url)
      else
        vimcode.message("No remote URL available")
      end
      return
    end
  end

  -- Stash actions
  if e.section == "Stash" then
    if e.key == "d" and e.id ~= "" then
      local result = vimcode.git.stash_pop(tonumber(e.id) or 0)
      vimcode.message(result or "Stash pop failed")
      refresh_all()
    end
  end

  if e.key == "p" then
    local result = vimcode.git.stash_push()
    vimcode.message(result or "Stash push failed")
    refresh_all()
  end
end)

-- Search/filter via panel input
vimcode.on("panel_input", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" then return end
  search_query = vimcode.panel.get_input("git_log"):lower()
  refresh_log_section()
end)
