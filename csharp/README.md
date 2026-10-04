# C# Language Support

Language support for C# (.NET) — diagnostics, completions, go-to-definition, debugger.

**LSP**: `csharp-ls`
**DAP**: netcoredbg
**File types**: `.cs`, `.csproj`, `.sln`

## Prerequisites

- **.NET SDK** (6.0 or later) must be installed. Download from [dot.net](https://dot.net/download).

The LSP server is installed automatically when you install this extension. On Linux and
macOS, the installer reads your `dotnet --version` and pins `csharp-ls` to the newest
release that still supports your SDK's major version, since the newest `csharp-ls`
targets whatever .NET major is current at release time and won't install on an older
SDK. If your SDK is below .NET 6, the install fails with a message telling you so,
instead of NuGet's.

If you need to install it manually on a known-good SDK:

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
