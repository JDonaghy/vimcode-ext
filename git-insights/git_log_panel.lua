-- Git Insights: Git Log Panel — lazygit-inspired interactive sidebar panel

vimcode.panel.register("git_log", {
  title = "GIT LOG",
  icon = "\u{f1d3}",
  sections = { "Branches", "Log", "Stash" },
})

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
        icon = b.is_current and "●" or " ",
        style = b.is_current and "accent" or "normal",
        hint = hint,
        id = b.name,
      })
    end
  end
  vimcode.panel.set_items("git_log", "Branches", branch_items)

  -- Log
  local log = vimcode.git.log(100)
  local log_items = {}
  if log then
    for _, e in ipairs(log) do
      table.insert(log_items, {
        text = e.message,
        hint = e.hash,
        style = "normal",
        id = e.hash,
      })
    end
  end
  vimcode.panel.set_items("git_log", "Log", log_items)

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

vimcode.on("panel_select", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" then return end

  if e.section == "Log" and e.id ~= "" then
    local content = vimcode.git.show(e.id)
    if content then
      vimcode.buf.open_scratch("GitShow " .. e.id:sub(1, 8), content, {
        readonly = true,
        filetype = "diff",
      })
    else
      vimcode.message("git show failed for: " .. e.id)
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

vimcode.on("panel_action", function(arg)
  local e = vimcode.panel.parse_event(arg)
  if e.panel ~= "git_log" then return end

  if e.key == "r" then
    refresh_all()
    vimcode.message("Git Log: refreshed")
  end
  if e.key == "d" and e.section == "Stash" and e.id ~= "" then
    local result = vimcode.git.stash_pop(tonumber(e.id) or 0)
    vimcode.message(result or "Stash pop failed")
    refresh_all()
  end
  if e.key == "p" then
    local result = vimcode.git.stash_push()
    vimcode.message(result or "Stash push failed")
    refresh_all()
  end
end)
