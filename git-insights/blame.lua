-- Git Insights: inline blame annotation on current line
-- Shows author, relative date, and commit message as virtual text.
-- Uses vimcode.async_shell() so git blame runs in a background thread
-- and never blocks the UI. Results arrive via the "blame_result" event.

local last_line = -1
local last_path = ""
local blame_line_num = -1

vimcode.on("cursor_move", function(_)
  local cur = vimcode.buf.cursor()
  local path = vimcode.buf.path()

  -- Reset when switching to a different file (tab switch, window switch, etc.)
  if path ~= last_path then
    last_path = path
    last_line = -1
  end

  if cur.line == last_line then return end
  last_line = cur.line
  blame_line_num = cur.line
  vimcode.buf.clear_annotations()

  if not path or path == "" then return end

  local cmd = string.format(
    "git blame -L %d,%d --porcelain -- %s",
    cur.line, cur.line, path
  )
  vimcode.async_shell(cmd, "blame_result")
end)

vimcode.on("blame_result", function(output)
  if output == "" or blame_line_num < 1 then return end
  local hash = output:match("^(%x+)")
  if not hash then return end
  local text
  if hash:match("^0+$") then
    text = "   Not committed yet"
  else
    local author = output:match("\nauthor (.-)\n") or "Unknown"
    local ts = tonumber(output:match("\nauthor%-time (%d+)")) or 0
    local summary = output:match("\nsummary (.-)\n") or ""
    -- Relative date from epoch timestamp
    local now = os.time()
    local diff = now - ts
    local rel
    if diff < 60 then rel = "just now"
    elseif diff < 3600 then rel = math.floor(diff/60) .. " minutes ago"
    elseif diff < 86400 then rel = math.floor(diff/3600) .. " hours ago"
    elseif diff < 2592000 then rel = math.floor(diff/86400) .. " days ago"
    elseif diff < 31536000 then rel = math.floor(diff/2592000) .. " months ago"
    else rel = math.floor(diff/31536000) .. " years ago"
    end
    text = "   " .. author .. " \u{2022} " .. rel .. " \u{2022} " .. summary
  end
  vimcode.buf.annotate_line(blame_line_num, text)
end)

-- :GitLog — show recent commits for current file in status bar
vimcode.command("GitLog", function(_)
  local entries = vimcode.git.log_file(10)
  if #entries == 0 then
    vimcode.message("No git history for this file")
    return
  end
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, e.hash .. " " .. e.message)
  end
  vimcode.message(table.concat(lines, " | "))
end)
