-- rest-client: a mini Postman-style HTTP client, rebuilt as a registry
-- extension (the earlier MVP was bundled in the vimcode core repo under
-- contrib/extensions/rest-client and fragmented into seven separate
-- `register_view` panels, each with its own activity-bar icon).
--
-- This rebuild deliberately exercises the "rich form in an editor-area tab"
-- capability and keeps the surface area tiny, to probe where the extension
-- API still falls short of a real request/response client. See README.md's
-- "Known limitations" for the walls this hit.
--
-- Shape:
--   * ONE request form, opened as an editor tab (`sidebar = false`, so it adds
--     no activity-bar icon; `open_view{location="tab"}`). The form carries the
--     whole request: URL, method, headers and params (folded in as
--     `text_area`s, "Key: Value" / "key=value" per line), body, and the Send /
--     Save / Copy-as-curl / navigation buttons.
--   * The response is written into a real scratch buffer in a vertical split
--     (`vimcode.buf.open_scratch`, filetype `json`): foldable, searchable,
--     yankable — a true file-buffer-level view, not a read-only text widget.
--   * History and saved collections are fuzzy pickers (`vimcode.picker.open`),
--     so neither needs a panel or an icon.
--   * A second tiny form tab (`:RestEnv`) edits `{{name}}` environment vars.
--
-- Why headers/params are text_areas and the response is a separate buffer: a
-- `vimcode.ui.register_view` view is a field stack OR a single body (list /
-- tree / table / text_view), never both (vimcode src/core/plugin_ui.rs, and
-- EXTENSIONS.md's View API section). A cohesive form-plus-grid-plus-response
-- screen is simply not expressible as one view today — the headline limitation
-- this extension exists to surface.
--
-- Persistence is `vimcode.storage` (global scope): `history`, `collections`
-- and `env_vars` survive a reload / restart regardless of the working dir.

local REQUEST_VIEW = "rest_client_request"
local ENV_VIEW = "rest_client_env"
local RESPONSE_BUF = "rest-client response"
local MAX_HISTORY = 50

local METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }
local BODY_METHODS = { POST = true, PUT = true, PATCH = true }

local function method_index(m)
  for i, opt in ipairs(METHODS) do
    if opt == m then
      return i - 1
    end
  end
  return 0
end

-- ── Persisted state ────────────────────────────────────────────────────────
-- `vimcode.storage.*` is documented to work at any point, including top-level
-- load, so state is loaded once here.

local function load_stored(key, default)
  local ok, value = pcall(vimcode.storage.get, key)
  if ok and type(value) == "table" then
    return value
  end
  return default
end

local function persist(key, value)
  pcall(vimcode.storage.set, key, value)
end

local history = load_stored("history", {})
local collections = load_stored("collections", {})
local env_vars = load_stored("env_vars", {})

-- ── In-memory request-builder state ──────────────────────────────────────────
-- Headers/params are kept as raw multi-line text (one entry per line), exactly
-- as typed into their text_area fields, and parsed at send time. This is the
-- compromise the field-stack-XOR-body rule forces: a structured key/value grid
-- would have to be its own view in its own tab.

local current = {
  method = "GET",
  url = "",
  headers_text = "",
  params_text = "",
  body = "",
}
local status_text = "idle"
-- `send_gen` supersedes an in-flight request: every send bumps it and captures
-- the value, and a response callback only touches shared state if its captured
-- generation is still current. A superseded (or hung) request can therefore
-- never wedge the form in "sending..." forever. (Same discipline as sql-tool's
-- `query_gen`.)
local send_gen = 0

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- `{{name}}` substitution against `env_vars`. An unknown variable is left
-- verbatim so a typo is visible in what actually went out, rather than becoming
-- an empty string. Names are `[%w_]`, matching the Environment view's parser.
local function substitute(s)
  return (s:gsub("{{%s*([%w_]+)%s*}}", function(name)
    return env_vars[name] or ("{{" .. name .. "}}")
  end))
end

-- Parse the Headers text_area ("Key: Value" per line) into a substituted map.
-- Blank lines and `#` comment lines are skipped; a line with no colon is
-- ignored rather than guessed at.
local function parse_headers()
  local map = {}
  for line in current.headers_text:gmatch("[^\n]+") do
    if not line:match("^%s*#") then
      local name, value = line:match("^%s*([^:%s][^:]-)%s*:%s*(.-)%s*$")
      if name then
        map[substitute(name)] = substitute(value)
      end
    end
  end
  return map
end

-- Fold the Params text_area ("key=value" per line) onto a (already substituted)
-- URL as a query string.
local function url_with_params(base_url)
  local parts = {}
  for line in current.params_text:gmatch("[^\n]+") do
    if not line:match("^%s*#") then
      local key, value = line:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
      if key then
        parts[#parts + 1] = substitute(key) .. "=" .. substitute(value)
      end
    end
  end
  if #parts == 0 then
    return base_url
  end
  local sep = base_url:find("?", 1, true) and "&" or "?"
  return base_url .. sep .. table.concat(parts, "&")
end

-- Pretty-print a JSON body; returns (text, filetype). A body that is not valid
-- JSON (HTML, plain text, empty) is returned unchanged with a `text` filetype,
-- rather than guessing at another formatter.
local function pretty_body(body)
  body = body or ""
  local ok, decoded = pcall(vimcode.json.decode, body)
  if ok then
    local ok2, encoded = pcall(vimcode.json.encode, decoded, { pretty = true })
    if ok2 then
      return encoded, "json"
    end
  end
  return body, "text"
end

local function has_body()
  return BODY_METHODS[current.method] == true
end

-- A single-quote-safe shell token for the Copy-as-curl helper.
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Open (a fresh split holding) the response. `open_scratch` always creates a
-- new buffer (see README limitation L3), so each send opens another split;
-- `split = "vertical"` keeps it beside the request form instead of replacing
-- it. `readonly` defaults true, but we set it explicitly.
local function show_response(text, filetype)
  vimcode.buf.open_scratch(RESPONSE_BUF .. "." .. filetype, text, {
    filetype = filetype,
    readonly = true,
    split = "vertical",
  })
end

-- ── Send ──────────────────────────────────────────────────────────────────────

local function do_send()
  local url = substitute(current.url)
  if url:match("^%s*$") then
    vimcode.message("rest-client: URL is empty")
    return
  end
  url = url_with_params(url)

  send_gen = send_gen + 1
  local my_gen = send_gen
  status_text = "sending..."
  vimcode.ui.refresh(REQUEST_VIEW)

  local request = {
    method = current.method,
    url = url,
    headers = parse_headers(),
    body = has_body() and substitute(current.body) or nil,
    timeout_ms = 30000,
  }

  local ok, err = pcall(vimcode.http.request, request, function(resp)
    -- A later send superseded this one; drop its (stale) result.
    if my_gen ~= send_gen then
      return
    end
    if resp.error then
      status_text = "ERROR: " .. tostring(resp.error)
      vimcode.message("rest-client: " .. status_text)
    else
      local size = #(resp.body or "")
      status_text = string.format("%d · %dms · %dB", resp.status, resp.elapsed_ms or 0, size)
      table.insert(history, 1, {
        method = current.method,
        url = url,
        headers_text = current.headers_text,
        params_text = current.params_text,
        body = current.body,
        status = resp.status,
        elapsed_ms = resp.elapsed_ms or 0,
        size = size,
      })
      while #history > MAX_HISTORY do
        table.remove(history)
      end
      persist("history", history)

      local text, filetype = pretty_body(resp.body)
      show_response(text, filetype)
      vimcode.message("rest-client: " .. status_text)
    end
    vimcode.ui.refresh(REQUEST_VIEW)
  end)

  if not ok and my_gen == send_gen then
    status_text = "ERROR: could not start request: " .. tostring(err)
    vimcode.ui.refresh(REQUEST_VIEW)
  end
end

-- ── Request state loaders (history / collections) ──────────────────────────────

-- Copy a saved/recent request into the live form. Missing fields default so an
-- older history entry (pre headers/params text) still loads cleanly.
local function load_into_form(entry)
  current.method = entry.method or "GET"
  current.url = entry.url or ""
  current.headers_text = entry.headers_text or ""
  current.params_text = entry.params_text or ""
  current.body = entry.body or ""
  status_text = "loaded"
  vimcode.ui.refresh(REQUEST_VIEW)
end

local function open_history_picker()
  if #history == 0 then
    vimcode.message("rest-client: no history yet")
    return
  end
  local items = {}
  for i, h in ipairs(history) do
    items[i] = {
      display = string.format("%s %s  (%s)", h.method, h.url, tostring(h.status)),
      data = i,
    }
  end
  vimcode.picker.open({
    title = "rest-client: history",
    items = items,
    on_select = function(i)
      load_into_form(history[i])
    end,
  })
end

local function open_collections_picker()
  if #collections == 0 then
    vimcode.message("rest-client: no saved requests — use Save")
    return
  end
  local items = {}
  for i, c in ipairs(collections) do
    items[i] = { display = string.format("%s %s", c.method, c.url), data = i }
  end
  vimcode.picker.open({
    title = "rest-client: collections",
    items = items,
    on_select = function(i)
      load_into_form(collections[i])
    end,
  })
end

local function save_current()
  table.insert(collections, 1, {
    method = current.method,
    url = current.url,
    headers_text = current.headers_text,
    params_text = current.params_text,
    body = current.body,
  })
  persist("collections", collections)
  vimcode.message("rest-client: saved " .. current.method .. " " .. current.url)
end

-- Build a `curl` command line equivalent to the current request and copy it to
-- the system clipboard (the "+" register is bridged to the OS clipboard by the
-- engine, as sql-tool relies on for :SqlCopyResults).
local function copy_as_curl()
  local parts = { "curl" }
  if current.method ~= "GET" then
    parts[#parts + 1] = "-X " .. current.method
  end
  for name, value in pairs(parse_headers()) do
    parts[#parts + 1] = "-H " .. shell_quote(name .. ": " .. value)
  end
  if has_body() and current.body ~= "" then
    parts[#parts + 1] = "--data " .. shell_quote(substitute(current.body))
  end
  parts[#parts + 1] = shell_quote(url_with_params(substitute(current.url)))
  vimcode.state.set_register("+", table.concat(parts, " "), false)
  vimcode.message("rest-client: copied curl command to clipboard")
end

-- ── Request view (the hub form) ─────────────────────────────────────────────────

local function open_request_tab()
  vimcode.ui.open_view(REQUEST_VIEW, { location = "tab" })
end

vimcode.ui.register_view(REQUEST_VIEW, {
  title = "REST Client",
  -- Tab-only: opened via :RestClient / buttons, never from the activity bar, so
  -- it contributes no icon. `icon`/`fallback_icon` are ignored when false.
  sidebar = false,

  render = function()
    return {
      id = "request",
      schema_version = 1,
      fields = {
        { type = "text", id = "url", label = "URL", value = current.url,
          placeholder = "https://host/path or {{base}}/path" },
        { type = "dropdown", id = "method", label = "Method",
          options = METHODS, selected = method_index(current.method) },
        { type = "text_area", id = "headers", label = "Headers (Key: Value per line)",
          value = current.headers_text, rows = 3,
          placeholder = "Accept: application/json" },
        { type = "text_area", id = "params", label = "Query params (key=value per line)",
          value = current.params_text, rows = 2, placeholder = "page=2" },
        { type = "text_area", id = "body", label = "Body", value = current.body, rows = 6,
          placeholder = '{ "key": "value" }  (Ctrl-Enter to commit)' },
        { type = "buttons", id = "actions", buttons = {
          { id = "send", label = "Send" },
          { id = "save", label = "Save" },
          { id = "curl", label = "Copy as curl" },
        } },
        { type = "read_only", id = "status", label = "Status", value = status_text },
        { type = "buttons", id = "nav", buttons = {
          { id = "history", label = "History" },
          { id = "collections", label = "Collections" },
          { id = "env", label = "Environment" },
        } },
      },
    }
  end,

  on_event = function(_ctx, event)
    local kind = event.kind
    local wid = event.widget_id or ""
    if kind == "TextChanged" or kind == "TextCommitted" then
      -- Record the latest value on every keystroke (text_area Enter inserts a
      -- newline; it only commits on Ctrl-Enter / blur, so waiting for
      -- TextCommitted would miss in-progress edits). No refresh here: the
      -- engine owns the focused field's edit state.
      if wid == "url" then
        current.url = event.value or ""
      elseif wid == "headers" then
        current.headers_text = event.value or ""
      elseif wid == "params" then
        current.params_text = event.value or ""
      elseif wid == "body" then
        current.body = event.value or ""
      end
    elseif kind == "DropdownChanged" and wid == "method" then
      current.method = METHODS[(event.value or 0) + 1] or "GET"
      vimcode.ui.refresh(REQUEST_VIEW)
    elseif kind == "ButtonClicked" then
      if wid == "send" then
        do_send()
      elseif wid == "save" then
        save_current()
      elseif wid == "curl" then
        copy_as_curl()
      elseif wid == "history" then
        open_history_picker()
      elseif wid == "collections" then
        open_collections_picker()
      elseif wid == "env" then
        vimcode.ui.open_view(ENV_VIEW, { location = "tab" })
      end
    end
  end,
})

-- ── Environment view ─────────────────────────────────────────────────────────────

local function env_vars_text()
  local names = {}
  for name in pairs(env_vars) do
    names[#names + 1] = name
  end
  table.sort(names)
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. "=" .. env_vars[name]
  end
  return table.concat(lines, "\n")
end

vimcode.ui.register_view(ENV_VIEW, {
  title = "REST Environment",
  sidebar = false,

  render = function()
    return {
      id = "env",
      schema_version = 1,
      fields = {
        { type = "label", id = "hdr", label = "Environment variables ({{name}})" },
        { type = "text_area", id = "vars", label = "name=value (one per line)",
          value = env_vars_text(), rows = 8 },
      },
    }
  end,

  on_event = function(_ctx, event)
    if event.widget_id ~= "vars" or event.value == nil then
      return
    end
    local next_vars = {}
    for line in event.value:gmatch("[^\n]+") do
      local name, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if name then
        next_vars[name] = value
      end
    end
    env_vars = next_vars
    persist("env_vars", env_vars)
  end,
})

-- ── Commands ────────────────────────────────────────────────────────────────────

vimcode.command("RestClient", open_request_tab)
vimcode.command("RestSend", do_send)
vimcode.command("RestHistory", open_history_picker)
vimcode.command("RestCollections", open_collections_picker)
vimcode.command("RestEnv", function()
  vimcode.ui.open_view(ENV_VIEW, { location = "tab" })
end)
