# Go Language Support

Language support for Go — diagnostics, completions, go-to-definition, debugger.

**LSP**: `gopls`
**DAP**: Delve (`dlv`)
**File types**: `.go`

## Prerequisites

- **Go** (1.18 or later) must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
go install golang.org/x/tools/gopls@latest
```

## Debugger

The Delve debugger is also installed automatically. Manual install:

```
go install github.com/go-delve/delve/cmd/dlv@latest
```

Set breakpoints with F9, start debugging with F5.

## Features

- Real-time diagnostics and type checking
- Completion with documentation
- Go-to-definition, find references, type definition
- Rename refactoring (`:Rename`)
- Format on save (`:Lformat`)
