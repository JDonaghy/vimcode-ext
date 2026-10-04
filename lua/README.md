# Lua Language Support

Provides LSP intelligence for Lua files via [lua-language-server](https://github.com/LuaLS/lua-language-server).

## Features

- Completions, hover, go-to-definition, references
- Diagnostics and type checking
- Workspace symbol search

## Installation

**Linux:** Installs the latest release from GitHub (x86_64 or arm64, matched to `uname -m`) into `~/.local/share/lua-language-server/` and symlinks the binary to `~/.local/bin/`.

**macOS:** Installs via Homebrew (`brew install lua-language-server`).

**Windows:** Downloads the latest `win32-x64` release from GitHub into `%USERPROFILE%\.local\bin\lua-language-server.exe`.

## Configuration

Place a `.luarc.json` or `.luarc.jsonc` in your project root to configure diagnostics, libraries, and runtime version. See the [wiki](https://luals.github.io/wiki/configuration/) for details.
