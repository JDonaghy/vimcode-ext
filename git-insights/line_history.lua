-- Git Insights: :GitLineHistory — show commits that touched the current line

vimcode.command("GitLineHistory", function(_)
  local cur = vimcode.buf.cursor()
  local entries = vimcode.git.line_log(cur.line, cur.line, 50)

  if #entries == 0 then
    vimcode.message("No git history for line " .. cur.line)
    return
  end

  local lines = {}
  table.insert(lines, "Git Line History: " .. (vimcode.buf.path() or "?") .. ":" .. cur.line)
  table.insert(lines, string.rep("-", 80))

  for _, e in ipairs(entries) do
    table.insert(lines, string.format("%-8s  %-20s  %-14s  %s", e.hash, e.author, e.date, e.message))
  end

  vimcode.buf.open_scratch("GitLineHistory", table.concat(lines, "\n"), {
    readonly = true,
    split = "vertical",
  })
end)
