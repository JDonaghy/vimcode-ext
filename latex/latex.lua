-- LaTeX Language Support for VimCode
-- Provides compile, view, clean, and TOC navigation for LaTeX documents.

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Determine the main .tex file for the project.
--- Prefers main.tex in cwd, otherwise falls back to the current buffer.
local function find_main_tex()
  local cwd = vimcode.cwd()
  local main = cwd .. "/main.tex"
  -- Check if main.tex exists via a quick test
  local f = io.open(main, "r")
  if f then
    f:close()
    return main
  end
  -- Fall back to current buffer path
  local path = vimcode.buf.path()
  if path and path:match("%.tex$") then
    return path
  end
  return nil
end

--- Derive the PDF path from a .tex path.
local function pdf_path(tex_path)
  return tex_path:gsub("%.tex$", ".pdf")
end

-- ── Compile ──────────────────────────────────────────────────────────────────

local function latex_compile()
  local tex = find_main_tex()
  if not tex then
    vimcode.message("No .tex file found to compile")
    return
  end
  vimcode.message("Compiling " .. tex .. " ...")
  local cmd = string.format(
    "latexmk -pdf -interaction=nonstopmode -file-line-error %q 2>&1",
    tex
  )
  vimcode.async_shell(cmd, "latex_compile_done")
end

vimcode.on("latex_compile_done", function(output)
  if output:match("Latexmk: All targets.*are up to date")
      or output:match("Output written on") then
    vimcode.message("LaTeX: Build succeeded")
  else
    -- Try to extract the first error line
    local err = output:match("[^\n]*:[%d]+:[^\n]*")
    if err then
      vimcode.message("LaTeX error: " .. err)
    else
      vimcode.message("LaTeX: Build finished (check log for details)")
    end
  end
end)

-- ── View PDF ─────────────────────────────────────────────────────────────────

local function latex_view()
  local tex = find_main_tex()
  if not tex then
    vimcode.message("No .tex file found")
    return
  end
  local pdf = pdf_path(tex)
  -- Configurable viewer: set latex_pdf_viewer in settings.json
  -- e.g. "evince", "zathura", "okular", "open" (macOS)
  local viewer = vimcode.opt.get("latex_pdf_viewer")
  if not viewer or viewer == "" then
    viewer = "evince"
  end
  -- Use setsid to fully detach the viewer process from the terminal
  local cmd = string.format("setsid %s %q >/dev/null 2>&1 &", viewer, pdf)
  vimcode.async_shell(cmd, "latex_view_done")
  vimcode.message("Opening " .. pdf .. " with " .. viewer)
end

vimcode.on("latex_view_done", function(_) end)

-- ── Clean ────────────────────────────────────────────────────────────────────

local function latex_clean(full)
  local tex = find_main_tex()
  if not tex then
    vimcode.message("No .tex file found")
    return
  end
  local flag = full and "-C" or "-c"
  local cmd = string.format("latexmk %s %q 2>&1", flag, tex)
  vimcode.async_shell(cmd, "latex_clean_done")
  vimcode.message("Cleaning auxiliary files...")
end

vimcode.on("latex_clean_done", function(_)
  vimcode.message("LaTeX: Clean complete")
end)

-- ── TOC (Table of Contents) panel ────────────────────────────────────────────

vimcode.panel.register("latex-toc", {
  title = "LaTeX TOC",
  icon = "\u{f0c9}",  -- list icon
  sections = {"Sections"}
})

local function refresh_toc()
  local path = vimcode.buf.path()
  if not path or not path:match("%.tex$") then return end

  local items = {}
  local lines = vimcode.buf.lines()
  local section_cmds = {
    ["\\part"]            = {indent = 0, prefix = "Part"},
    ["\\chapter"]         = {indent = 0, prefix = "Ch"},
    ["\\section"]         = {indent = 0, prefix = ""},
    ["\\subsection"]      = {indent = 1, prefix = ""},
    ["\\subsubsection"]   = {indent = 2, prefix = ""},
    ["\\paragraph"]       = {indent = 3, prefix = ""},
    ["\\subparagraph"]    = {indent = 4, prefix = ""},
  }

  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    for cmd, info in pairs(section_cmds) do
      -- Match \section{Title} or \section*{Title}
      local title = trimmed:match("^" .. cmd:gsub("\\", "\\\\") .. "%*?{(.-)}")
      if title then
        local display = title
        if info.prefix ~= "" then
          display = info.prefix .. ": " .. title
        end
        table.insert(items, {
          text = display,
          hint = tostring(i),
          indent = info.indent,
          style = info.indent == 0 and "accent" or "normal",
          id = tostring(i)
        })
      end
    end
  end

  if #items == 0 then
    table.insert(items, {text = "(no sections found)", style = "dim", id = "empty"})
  end

  vimcode.panel.set_items("latex-toc", "Sections", items)
end

-- Refresh TOC on save and on panel focus
vimcode.on("save", function(_)
  refresh_toc()
end)

vimcode.on("panel_focus", function(arg)
  local evt = vimcode.panel.parse_event(arg)
  if evt.panel == "latex-toc" then
    refresh_toc()
  end
end)

-- Handle clicks on TOC items: jump to line
vimcode.on("panel_select", function(arg)
  local evt = vimcode.panel.parse_event(arg)
  if evt.panel == "latex-toc" and evt.id ~= "empty" then
    local line = tonumber(evt.id)
    if line then
      vimcode.buf.set_cursor(line, 1)
    end
  end
end)

-- ── Open compile log ─────────────────────────────────────────────────────────

local function latex_log()
  local tex = find_main_tex()
  if not tex then
    vimcode.message("No .tex file found")
    return
  end
  local log = tex:gsub("%.tex$", ".log")
  local f = io.open(log, "r")
  if not f then
    vimcode.message("Log file not found: " .. log)
    return
  end
  local content = f:read("*a")
  f:close()
  vimcode.buf.open_scratch("[LaTeX Log]", content, {readonly = true})
end

-- ── Commands ─────────────────────────────────────────────────────────────────

vimcode.command("LatexCompile", function() latex_compile() end)
vimcode.command("LatexView",    function() latex_view() end)
vimcode.command("LatexClean",   function() latex_clean(false) end)
vimcode.command("LatexCleanAll",function() latex_clean(true) end)
vimcode.command("LatexLog",     function() latex_log() end)
vimcode.command("LatexToc",     function() refresh_toc() end)

-- ── Keymaps (vimtex-inspired <leader>l prefix) ──────────────────────────────

vimcode.keymap("n", "<leader>ll", function() latex_compile() end)
vimcode.keymap("n", "<leader>lv", function() latex_view() end)
vimcode.keymap("n", "<leader>lc", function() latex_clean(false) end)
vimcode.keymap("n", "<leader>lC", function() latex_clean(true) end)
vimcode.keymap("n", "<leader>le", function() latex_log() end)
vimcode.keymap("n", "<leader>lt", function() refresh_toc() end)
