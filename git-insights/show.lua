-- Git Insights: :GitShow [hash] — reveal commit in the Git Log panel
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

  -- Set target so refresh_all() ensures this commit is in the log.
  -- Cleared by refresh_all() after use (panel_focus fires asynchronously).
  _git_log_reveal_target = hash
  vimcode.panel.reveal("git_log", "Log", hash)
end)
