# vimcode-ext

The official extension registry for [VimCode](https://github.com/JDonaghy/vimcode).
One directory per extension (`manifest.toml` + optional Lua scripts + `README.md`),
aggregated into a single `registry.json` that VimCode fetches on startup and caches
locally. This repo is **data and Lua** — there is nothing to compile.

## The one invariant

**`registry.json` must agree, field for field, with every `*/manifest.toml`.** It is a
*normalised* aggregate: it spells out `lsp` / `dap` / `scripts` / `workspace_markers`
for every entry even where the manifest omits them, adds `fallback_binaries: []` and
empty `install_linux` / `install_macos` / `install_windows`, and drops `scripts` from
inside `lsp` / `dap`. So a naive whole-dict comparison reports dozens of false drifts;
`scripts/validate.py` compares an explicit field list with documented defaults instead.

Consequences for anyone editing this repo:

- **A change to a `manifest.toml` is not done until `registry.json` mirrors it.** The
  two real drifts this gate has caught were both version bumps made in a manifest and
  never mirrored (`bicep` 1.0.0 vs 1.1.0, `git-insights` 2.0.0 vs 2.1.0).
- **Edit `registry.json` as targeted text, not `json.load` + `json.dump`.** It is
  written with compact one-line arrays on purpose; a round-trip through Python
  reformats all 19 entries and turns a two-line change into a whole-file diff.
- A new field in the manifest schema is **opted into** deliberately in
  `scripts/validate.py`'s field list. Adding a field to a manifest without adding it
  there means it is silently uncompared.

## Testing

```bash
python3 scripts/validate.py        # the whole gate; stdlib only, no network
```

This is exactly the `test_command` the coordinator gives this repo and exactly what
`.github/workflows/ci.yml` runs, so the Test gate and CI cannot prove different
things. Keep it that way — if you change one, change the other in the same PR.

It checks: every `manifest.toml` parses; required keys are present and correctly
typed; `name` equals the directory the manifest lives in; `registry.json` parses,
covers exactly the extension directories present, and agrees with each manifest;
install commands, where declared, are non-empty and not obviously destructive.

**Install commands are inspected as strings and NEVER executed.** Six extensions
resolve `install_macos` to `brew install ...` and others to `npm install -g ...`;
running them would make the gate slow, network-dependent and machine-mutating. Live
install verification is manual operator smoke, not this gate. Do not "improve" the
validator by running them.

### What is NOT tested here, and must be said out loud

**The shipped Lua has no automated test in any repo.** VimCode's own
`tests/extensions.rs` builds synthetic manifests (`test_manifests()`), never this
registry's real files, so nothing anywhere executes `git-insights/blame.lua` or
`git_log_panel.lua`. If your change edits Lua behaviour:

- say so explicitly in your final message, and
- state the manual smoke that would prove it — the exact keystrokes or clicks, in
  which panel, and what should appear.

Do not claim a Lua change is verified because `validate.py` passed. It proves the
manifest parses, nothing more.

## The Lua plugin API lives in the other repo

The `vimcode.*` surface a script may call, the manifest schema, and the
platform-select logic for `install_*` are all defined in `vimcode`, which is this
repo's `reference_repos` entry:

- `vimcode/EXTENSIONS.md` — the manifest schema and the plugin API, documented.
- `vimcode/src/core/plugin.rs` — the actual Lua bindings. The source of truth when
  the doc and the code disagree.
- `vimcode/src/core/extensions.rs` — manifest parsing and platform selection.

**Never invent a `vimcode.*` call.** If a binding you need is not registered in
`plugin.rs` at the version users are running, the script fails silently at runtime and
`validate.py` will not catch it. Say the binding is missing and stop; a new binding is
a `vimcode` issue, not a change to be worked around here.

A panel-heavy extension also depends on core behaviour that is not in this repo —
`git-insights`' Git Log panel is the standing example. Its bugs have been in
VimCode's sidebar routing, not in its Lua.

## Rules for workers

- **`registry.json` and the `README.md` extension table are part of the deliverable**
  when you add, remove or rename an extension — they are not "docs" to leave to the
  coordinator. Every other doc edit is: do not touch `EXTENSIONS.md` or the rest of
  `README.md` unless the issue's whole deliverable is that edit.
- **Never edit the local cache.** `~/.config/vimcode/extensions/<name>/` is a copy
  VimCode manages; this repo is the source of truth, and the cache is overwritten on
  reinstall. Propagating a merged change into the cache is operator work.
- **Stay in file scope.** Touching a file outside your briefing means saying so in
  your final message.
- **Commit and push before your final message**, even if something is unfinished.
- **`gh` is on the deny-list.** The coordinator owns all GitHub interaction; use
  plain `git`.

## Conventions

- Lua 5.4, as embedded by VimCode. Two-space indent, `local` by default.
- TOML manifests: `name` first, then `display_name`, `description`, `version`.
- `version` is semver and is bumped in the same PR as any behaviour change to that
  extension's scripts — the Extensions panel shows an update badge from it.
- Python: 3.11+ (`tomllib`), stdlib only. `scripts/validate.py` must stay
  dependency-free and offline so it runs identically in CI and on any fleet machine.
