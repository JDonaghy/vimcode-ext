-- Git Insights: :GitShow [hash] — show a commit's full diff
-- If no hash is given, uses the first word on the current line
-- (useful from :GitFileHistory or :GitRepoLog buffers).

vimcode.command("GitShow", function(args)
  local hash = args
  if not hash or hash == "" then
    -- Try to grab the first word on the current line (likely a commit hash)
    local cur = vimcode.buf.cursor()
    local line = vimcode.buf.line(cur.line) or ""
    hash = line:match("^(%x+)")
  end

  if not hash or hash == "" then
    vimcode.message("Usage: :GitShow <hash>")
    return
  end

  local content = vimcode.git.show(hash)
  if not content then
    vimcode.message("git show failed for: " .. hash)
    return
  end

  vimcode.buf.open_scratch("GitShow " .. hash:sub(1, 8), content, {
    readonly = true,
    filetype = "diff",
    split = "vertical",
  })
end)
