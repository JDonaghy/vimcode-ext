# Python Language Support

Language support for Python — diagnostics, completions, go-to-definition, debugger.

**LSP**: `pyright-langserver` (or pylsp, jedi-language-server)
**DAP**: debugpy
**File types**: `.py`, `.pyi`, `.pyw`

## Prerequisites

- **Node.js** and npm (for pyright), or **Python** and pip (for pylsp/jedi).

The LSP server (pyright) is installed automatically when you install this extension. VimCode also supports pylsp and jedi-language-server as fallbacks if pyright is not available.

Manual install:

```
# Pyright (recommended)
npm install -g pyright

# Or python-lsp-server
pip install python-lsp-server

# Or jedi-language-server
pip install jedi-language-server
```

## Debugger

Install debugpy for breakpoint debugging:

```
pip install debugpy
```

Set breakpoints with F9, start debugging with F5.

## Features

- Real-time type checking and diagnostics
- Completion with docstring documentation
- Go-to-definition, find references, type definition
- Rename refactoring (`:Rename`)
