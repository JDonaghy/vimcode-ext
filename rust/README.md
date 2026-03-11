# Rust Language Support

Language support for Rust — diagnostics, completions, go-to-definition, debugger.

**LSP**: `rust-analyzer`
**DAP**: codelldb (LLDB-based debugger)
**File types**: `.rs`

## Prerequisites

- **Rust** toolchain (rustup) must be installed.

The LSP server is installed automatically when you install this extension. If rust-analyzer is already available via rustup, it will be used directly.

Manual install:

```
# Via rustup (recommended)
rustup component add rust-analyzer

# Or standalone
cargo install rust-analyzer
```

## Debugger

Uses codelldb (LLDB adapter). Install via `:DapInstall rust`.

Set breakpoints with F9, start debugging with F5. Compile with `cargo build` first so the binary is up to date.

## Features

- Real-time diagnostics and borrow-checker errors
- Completion with documentation
- Go-to-definition, find references, type definition
- Rename refactoring (`:Rename`)
- Format on save (`:Lformat`)
