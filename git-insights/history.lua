-- Git Insights: :GitFileHistory — show commit history for the current file
-- Opens in a readonly vsplit scratch buffer.

vimcode.command("GitFileHistory", function(_)
  local entries = vimcode.git.file_log_detailed(100)
  if #entries == 0 then
    vimcode.message("No git history for this file")
    return
  end

  local lines = {}
  table.insert(lines, "Git File History: " .. (vimcode.buf.path() or "?"))
  table.insert(lines, string.rep("-", 80))

  for _, e in ipairs(entries) do
    local line = string.format("%-8s  %-20s  %-14s  %s", e.hash, e.author, e.date, e.message)
    if e.stat and e.stat ~= "" then
      line = line .. "  (" .. e.stat .. ")"
    end
    table.insert(lines, line)
  end

  vimcode.buf.open_scratch("GitFileHistory", table.concat(lines, "\n"), {
    readonly = true,
    split = "vertical",
  })
end)
