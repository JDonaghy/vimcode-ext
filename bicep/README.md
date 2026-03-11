# Bicep Language Support

Language support for Azure Bicep infrastructure-as-code files — diagnostics, completions, go-to-definition.

**LSP**: `bicep-langserver` (Azure/bicep)
**File types**: `.bicep`, `.bicepparam`

## Prerequisites

- **.NET Runtime** (6.0 or later) must be installed. Download from [dot.net](https://dot.net/download).
- `curl`, `unzip` must be available (standard on most Linux/macOS systems).
- `~/.local/bin` must be on your PATH.

The LSP server is installed automatically when you install this extension. It downloads the latest `bicep-langserver.zip` from Azure/bicep GitHub releases, extracts it to `~/.local/share/bicep-langserver/`, and creates a `bicep-langserver` wrapper script in `~/.local/bin/`.

## Manual Install

If auto-install fails, download manually:

1. Download `bicep-langserver.zip` from [Azure/bicep releases](https://github.com/Azure/bicep/releases)
2. Extract to a directory (e.g., `~/.local/share/bicep-langserver/`)
3. Create a wrapper script on your PATH:

```sh
#!/bin/sh
exec dotnet ~/.local/share/bicep-langserver/Bicep.LangServer.dll "$@"
```

4. Make it executable: `chmod +x ~/.local/bin/bicep-langserver`

## Features

- Syntax and type diagnostics
- Completion for resource types, properties, and functions
- Go-to-definition for modules and parameters
- Hover documentation for Azure resource types
