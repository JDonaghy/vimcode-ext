-- Git Insights: stash commands
-- :GitStash [msg]      — push changes to stash
-- :GitStashPop [n]     — pop stash entry (default 0)
-- :GitStashList        — show stash entries in scratch buffer
-- :GitStashShow [n]    — show stash diff in scratch buffer

vimcode.command("GitStash", function(args)
  local msg = args
  if msg == "" then msg = nil end
  local result = vimcode.git.stash_push(msg)
  vimcode.message(result)
end)

vimcode.command("GitStashPop", function(args)
  local index = tonumber(args) or 0
  local result = vimcode.git.stash_pop(index)
  vimcode.message(result)
end)

vimcode.command("GitStashList", function(_)
  local entries = vimcode.git.stash_list()
  if #entries == 0 then
    vimcode.message("No stash entries")
    return
  end

  local lines = {}
  table.insert(lines, "Git Stash List")
  table.insert(lines, string.rep("-", 60))

  for _, e in ipairs(entries) do
    table.insert(lines, string.format("stash@{%d}  [%s]  %s", e.index, e.branch, e.message))
  end

  vimcode.buf.open_scratch("GitStashList", table.concat(lines, "\n"), {
    readonly = true,
    split = "vertical",
  })
end)

vimcode.command("GitStashShow", function(args)
  local index = tonumber(args) or 0
  local content = vimcode.git.stash_show(index)
  if not content then
    vimcode.message("No stash at index " .. index)
    return
  end

  vimcode.buf.open_scratch("GitStash@{" .. index .. "}", content, {
    readonly = true,
    filetype = "diff",
    split = "vertical",
  })
end)
