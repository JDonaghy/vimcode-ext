# JavaScript / TypeScript Support

Language support for JavaScript and TypeScript — diagnostics, completions, go-to-definition.

**LSP**: `typescript-language-server`
**File types**: `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`, `.cjs`

## Prerequisites

- **Node.js** and npm must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
npm install -g typescript typescript-language-server
```

## Debugger

Not available through this extension. js-debug (vscode-js-debug) does publish a prebuilt bundle on
every GitHub release, but it is a multi-file package (bundled dependencies, platform-specific native
modules) with no fixed install location vimcode's extension schema can reference — `[dap]`'s
`binary`/`args` are static TOML with no per-user path substitution. Matches vimcode's own assessment
of js-debug as needing "complex multi-step builds" with no automated install.

## Features

- Real-time diagnostics and type checking
- Completion with JSDoc/TSDoc documentation
- Go-to-definition, find references, type definition
- Rename refactoring (`:Rename`)
- Works with JavaScript, TypeScript, JSX, and TSX
