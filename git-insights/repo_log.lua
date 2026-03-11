-- Git Insights: :GitRepoLog — show repo-wide commit log in scratch buffer

vimcode.command("GitRepoLog", function(_)
  local entries = vimcode.git.log(200)
  if #entries == 0 then
    vimcode.message("No git log (not a git repository?)")
    return
  end

  local lines = {}
  table.insert(lines, "Git Repository Log")
  table.insert(lines, string.rep("-", 80))

  for _, e in ipairs(entries) do
    table.insert(lines, string.format("%-8s  %s", e.hash, e.message))
  end

  vimcode.buf.open_scratch("GitRepoLog", table.concat(lines, "\n"), {
    readonly = true,
    split = "vertical",
  })
end)
