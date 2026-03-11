# JavaScript / TypeScript Support

Language support for JavaScript and TypeScript — diagnostics, completions, go-to-definition.

**LSP**: `typescript-language-server`
**DAP**: js-debug
**File types**: `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`, `.cjs`

## Prerequisites

- **Node.js** and npm must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
npm install -g typescript typescript-language-server
```

## Features

- Real-time diagnostics and type checking
- Completion with JSDoc/TSDoc documentation
- Go-to-definition, find references, type definition
- Rename refactoring (`:Rename`)
- Works with JavaScript, TypeScript, JSX, and TSX
