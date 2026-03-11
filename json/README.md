# JSON Language Support

Language support for JSON — formatting, validation, and schema support.

**LSP**: `vscode-json-languageserver`
**File types**: `.json`, `.jsonc`, `.json5`

## Prerequisites

- **Node.js** and npm must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
npm install -g vscode-langservers-extracted
```

## Features

- Syntax validation and error highlighting
- Formatting (`:Lformat`)
- JSON Schema support for auto-completion and validation
- Support for JSONC (JSON with comments)
