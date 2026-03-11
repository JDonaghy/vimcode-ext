# C# Language Support

Language support for C# (.NET) — diagnostics, completions, go-to-definition, debugger.

**LSP**: `csharp-ls`
**DAP**: netcoredbg
**File types**: `.cs`, `.csproj`, `.sln`

## Prerequisites

- **.NET SDK** (6.0 or later) must be installed. Download from [dot.net](https://dot.net/download).

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
dotnet tool install -g csharp-ls
```

## Debugger

Uses netcoredbg for .NET debugging. Install via `:DapInstall csharp` or from the netcoredbg releases page.

Set breakpoints with F9, start debugging with F5.

## Features

- Diagnostics and code analysis
- Completion with XML doc comments
- Go-to-definition across projects and NuGet packages
- Rename refactoring (`:Rename`)
