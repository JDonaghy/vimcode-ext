# LaTeX Language Support

Provides LSP intelligence, build tools, and PDF viewing for LaTeX documents via [texlab](https://github.com/latex-lsp/texlab).

## Features

- Completions for commands, environments, labels, citations, and file paths
- Go-to-definition for labels, citations, and includes
- Document symbols / outline
- Diagnostics from the build engine
- Build on save (configurable)
- PDF viewer integration

## Build Engines

Three LaTeX compilation engines are supported:

- **pdflatex** (default) — standard LaTeX engine
- **xelatex** — Unicode and system font support
- **lualatex** — Lua scripting and Unicode support

Configure with `:ExtSettings latex` or in the extension settings panel.

## Settings

| Setting | Default | Description |
|---|---|---|
| `pdf_viewer` | (system default) | Command used to open compiled PDFs |
| `build_on_save` | `false` | Automatically compile when saving `.tex` files |
| `build_engine` | `pdflatex` | LaTeX compilation engine |

## Installation

**texlab** (primary LSP):

```
cargo install --git https://github.com/latex-lsp/texlab
```

**digestif** (fallback LSP):

Available via LuaRocks or your system package manager.

## Workspace Detection

Recognized project markers: `.latexmkrc`, `latexmkrc`, `main.tex`
