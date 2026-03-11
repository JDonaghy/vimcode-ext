# C / C++ Language Support

Language support for C and C++ — diagnostics, completions, go-to-definition, debugger.

**LSP**: `clangd`
**DAP**: codelldb (LLDB-based debugger)
**File types**: `.c`, `.h`, `.cc`, `.cpp`, `.cxx`, `.hh`, `.hpp`, `.hxx`

## Prerequisites

- **clangd** must be installed (usually bundled with LLVM/Clang).

The LSP server is installed automatically on Debian/Ubuntu. On other systems, install manually:

```
# macOS
brew install llvm

# Or download from https://clangd.llvm.org/installation
```

For best results, generate a `compile_commands.json` in your project root using CMake (`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`) or Bear.

## Debugger

Uses codelldb (LLDB adapter). Install via `:DapInstall cpp`.

Compile with debug symbols (`-g` flag or CMake Debug build type), then press F5 to start debugging.

## Features

- Real-time diagnostics and code analysis
- Completion with documentation
- Go-to-definition, find references
- Rename refactoring (`:Rename`)
