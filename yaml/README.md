# YAML Language Support

Language support for YAML — formatting, validation, and schema support.

**LSP**: `yaml-language-server`
**File types**: `.yml`, `.yaml`

## Prerequisites

- **Node.js** and npm must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
npm install -g yaml-language-server
```

## Features

- Syntax validation and error highlighting
- Formatting (`:Lformat`)
- Schema support (Kubernetes, Docker Compose, GitHub Actions, etc.)
- Completion for schema-aware keys and values
