-- Git Insights: :GitDiff [ref] — show diff against a ref (default: HEAD)

vimcode.command("GitDiff", function(args)
  local ref = args
  if not ref or ref == "" then
    ref = "HEAD"
  end

  local content = vimcode.git.diff_ref(ref)
  if not content then
    vimcode.message("No diff against " .. ref .. " (working tree clean?)")
    return
  end

  vimcode.buf.open_scratch("GitDiff " .. ref, content, {
    readonly = true,
    filetype = "diff",
    split = "vertical",
  })
end)
