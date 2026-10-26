# REST Client

A mini, Postman-style HTTP request builder for VimCode. The whole request lives
in a **rich form opened as an editor-area tab** (peer to a file buffer, no
activity-bar icon), and the response opens as a real scratch buffer you can
fold, search and yank.

It is intentionally small. Its second purpose is to **probe the limits of the
extension API** — see *Known limitations* below.

## Commands

| Command | Does |
|---------|------|
| `:RestClient` | Open the request form in a new editor tab |
| `:RestSend` | Send the current request without the form focused |
| `:RestHistory` | Fuzzy-pick a past request and load it back into the form |
| `:RestCollections` | Fuzzy-pick a saved request and load it |
| `:RestEnv` | Open the environment-variables form (for `{{name}}` substitution) |

In the form: **Send** fires the request, **Save** stores it in collections,
**Copy as curl** puts an equivalent `curl` command on the system clipboard, and
the **History / Collections / Environment** buttons open those surfaces.

Headers go one `Key: Value` per line, query params one `key=value` per line
(lines starting with `#` are ignored). `{{name}}` anywhere in the URL, headers,
params or body is replaced from the environment; an unknown name is left
verbatim so a typo is visible in what was actually sent.

The response body is pretty-printed when it is JSON (and opened as a `json`
buffer); other content types open unchanged. Status, timing and byte size show
in the form's **Status** field and on the status line. History and the
environment persist across restarts (`vimcode.storage`); collections too.

## Requirements

`curl` on `PATH` (VimCode's `vimcode.http` runs through it). No language server,
debugger or install step — this is a pure-Lua extension.

## Known limitations

These are **engine (VimCode core) limitations**, not things this extension can
work around in Lua. They are the reason the UI is shaped the way it is, and each
is a candidate VimCode issue:

- **L1 — a view is a form *or* one body, never both.** `vimcode.ui.register_view`
  renders either a field stack or a single list/tree/table/text_view
  (`src/core/plugin_ui.rs`). So a real request screen — form **plus** a
  headers/params grid **plus** a response pane — cannot be one view. Headers and
  params are folded into `text_area` fields here, and the response lives in a
  separate buffer, purely because of this. The fix is a composite/sectioned view.
- **L2 — no "focus existing tab" API.** `vimcode.ui.open_view` always opens a
  *new* tab and cannot raise an existing one, so re-sending can't bring the form
  (or a prior response) back to the front.
- **L3 — no reusable response buffer.** `vimcode.buf.open_scratch` always creates
  a *new* buffer; there is no reuse-by-name / refresh-in-place. Each **Send**
  therefore opens another response split rather than updating one in place.
- **L4 — no visual-selection access.** Plugins can't read the `'<`/`'>` marks and
  ranged `:'<,'>`-style plugin commands don't dispatch, so "send the request the
  cursor/selection is on" from an ordinary buffer isn't possible.
- **L5 — text_area commit ergonomics.** In a `text_area`, `Enter` inserts a
  newline; the edit commits on `Ctrl-Enter` or on leaving the field. The form
  tracks every keystroke so a send never misses an in-progress edit.
- **L6 — no structured key/value widget.** Following from L1, headers/params can
  only be flat text or a separate table body — there is no inline repeatable
  key/value row inside a form.
- **L7 — reverse field navigation is broken in the TUI.** `Tab` cycles forward
  through fields, but `Shift-Tab` does not move back, so you can only walk the
  form one way.
- **L8 — no control over where output lands.** Sending opens the response in a
  vertical split (an artefact of L2/L3). There is no way to route results into a
  dedicated horizontal tab group / bottom result dock, or to reuse one output
  surface across sends. A dockable, reusable result area is what this really
  wants.
- **Note — `dropdown` has no TUI popup.** A `dropdown` field in the terminal just
  cycles options on `Enter` (no list). This client uses a `segmented` control for
  Method instead so every option stays visible; a real searchable dropdown /
  combobox field kind does not exist.

Possible future work, pending a released binding: export/import collections to a
file via `vimcode.fs.write` / `vimcode.fs.read`.

## Manual smoke (how to actually verify a behaviour change)

`scripts/validate.py` proves the manifest parses and `registry.json` mirrors it —
**it does not run a line of this Lua.** To verify the extension itself, in a
running VimCode with it installed:

1. `:RestClient` → the **REST Client form opens as an editor tab** (no new
   activity-bar icon appears).
2. URL `https://httpbin.org/get`, Method `GET`, Headers line
   `Accept: application/json`, click **Send** → **Status** shows
   `200 · <ms>B` and a `json` response buffer opens in a split.
3. Method `POST`, URL `https://httpbin.org/post`, Body `{"x":1}` (commit with
   `Ctrl-Enter`), **Send** → the response echoes the posted JSON.
4. `:RestEnv`, add `base=https://httpbin.org`; back in the form set URL
   `{{base}}/get` and **Send** → the variable resolves.
5. **Save**, then `:RestCollections` → the request is listed; selecting it
   reloads the form. `:RestHistory` lists sent requests.
6. **Copy as curl** → paste elsewhere; the command reproduces method, headers,
   body and URL.
