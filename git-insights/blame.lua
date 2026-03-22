-- Git Insights: inline blame annotation on current line
-- Shows author, relative date, and commit message as virtual text.
-- Uses vimcode.async_shell() so git blame runs in a background thread
-- and never blocks the UI. Results arrive via the "blame_result" event.
-- A second async call fetches the commit diff for "Changes" in the hover.

local last_line = -1
local last_path = ""
local blame_line_num = -1
local blame_state = {}  -- cached per-line: { hash, author, rel, abs_date, summary, short_hash, url }

-- Format a Unix timestamp + tz offset string into a human-readable date.
-- e.g. "March 21, 2026 4:30 PM"
local function format_absolute_date(ts, tz_str)
  local sign = 1
  local tz_secs = 0
  if tz_str and #tz_str >= 5 then
    if tz_str:sub(1,1) == "-" then sign = -1 end
    local h = tonumber(tz_str:sub(2,3)) or 0
    local m = tonumber(tz_str:sub(4,5)) or 0
    tz_secs = sign * (h * 3600 + m * 60)
  end
  local adjusted = ts + tz_secs
  local d = os.date("!*t", adjusted)
  if not d then return "" end
  local months = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  }
  local month_name = months[d.month] or "???"
  local hour12 = d.hour % 12
  if hour12 == 0 then hour12 = 12 end
  local ampm = d.hour < 12 and "AM" or "PM"
  return string.format("%s %d, %d %d:%02d %s",
    month_name, d.day, d.year, hour12, d.min, ampm)
end

-- Build the hover markdown from blame_state + optional diff output.
local function build_hover(state, diff_output)
  local hash_link
  if state.url then
    hash_link = string.format("[`%s`](%s)", state.short_hash, state.url)
  else
    hash_link = string.format("`%s`", state.short_hash)
  end

  local md = string.format(
    "**%s**, %s (%s)\n\n%s",
    state.author, state.rel, state.abs_date, state.summary
  )

  -- Add Changes section if we have diff output
  if diff_output and diff_output ~= "" then
    -- Extract just the file-relevant hunk lines (skip diff header)
    local lines = {}
    local in_hunk = false
    local path_pattern = state.path and state.path:match("[^/]+$") or nil
    for line in diff_output:gmatch("[^\n]+") do
      if line:match("^@@") then
        in_hunk = true
      elseif in_hunk then
        if line:match("^diff %-%-git") then
          in_hunk = false
        else
          table.insert(lines, line)
        end
      end
    end
    if #lines > 0 then
      -- Cap at 12 lines to keep the popup reasonable
      local display = {}
      for i = 1, math.min(#lines, 12) do
        table.insert(display, lines[i])
      end
      if #lines > 12 then
        table.insert(display, string.format("... +%d more lines", #lines - 12))
      end
      md = md .. "\n\n---\n\n**Changes**\n\n```\n" .. table.concat(display, "\n") .. "\n```"
    end
  end

  -- Action links — labels are clickable, command URI shown as (:Name?args)
  local actions = {}
  table.insert(actions, "[Open Commit](command:GitShow?" .. state.short_hash .. ")")
  table.insert(actions, "[Copy Hash](command:GitCopyHash?" .. state.short_hash .. ")")
  md = md .. "\n\n---\n\n" .. table.concat(actions, " &nbsp;|&nbsp; ")
  md = md .. "\n\n" .. hash_link
  return md
end

vimcode.on("cursor_move", function(_)
  local cur = vimcode.buf.cursor()
  local path = vimcode.buf.path()

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
  if hash:match("^0+$") then
    vimcode.buf.annotate_line(blame_line_num, "   Not committed yet")
    return
  end

  local author = output:match("\nauthor (.-)\n") or "Unknown"
  local ts = tonumber(output:match("\nauthor%-time (%d+)")) or 0
  local tz_str = output:match("\nauthor%-tz ([%+%-]%d+)") or "+0000"
  local summary = output:match("\nsummary (.-)\n") or ""
  local path = vimcode.buf.path()

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

  local text = "   " .. author .. " \u{2022} " .. rel .. " \u{2022} " .. summary
  vimcode.buf.annotate_line(blame_line_num, text)

  local short_hash = hash:sub(1, 8)
  local abs_date = format_absolute_date(ts, tz_str)
  local url = vimcode.git.commit_url(short_hash)

  -- Store state so the diff callback can build the full hover.
  blame_state = {
    line = blame_line_num,
    author = author,
    rel = rel,
    abs_date = abs_date,
    summary = summary,
    short_hash = short_hash,
    url = url,
    path = path,
  }

  -- Show hover immediately (without diff), then enhance when diff arrives.
  local md = build_hover(blame_state, nil)
  vimcode.editor.set_hover(blame_line_num, md)

  -- Fetch the commit diff for just this line to show Changes section.
  local diff_cmd = string.format(
    "git log -1 -p -L %d,%d:%s %s",
    blame_line_num, blame_line_num, path, short_hash
  )
  vimcode.async_shell(diff_cmd, "blame_diff_result")
end)

vimcode.on("blame_diff_result", function(output)
  if not blame_state.line or blame_state.line < 1 then return end
  -- Rebuild hover with the diff included.
  local md = build_hover(blame_state, output)
  vimcode.editor.set_hover(blame_state.line, md)
end)

-- Command URI handlers for hover popup action links
vimcode.command("GitShow", function(hash)
  vimcode.command_run("Gshow " .. hash)
end)

vimcode.command("GitCopyHash", function(hash)
  vimcode.state.set_register("+", hash, false)
  vimcode.message("Copied " .. hash)
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
