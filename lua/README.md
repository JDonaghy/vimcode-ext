# Lua Language Support

Provides LSP intelligence for Lua files via [lua-language-server](https://github.com/LuaLS/lua-language-server).

## Features

- Completions, hover, go-to-definition, references
- Diagnostics and type checking
- Workspace symbol search

## Installation

**Linux:** Installs the latest release from GitHub into `~/.local/share/lua-language-server/` and symlinks the binary to `~/.local/bin/`.

**macOS:** Installs via Homebrew (`brew install lua-language-server`).

**Windows:** Manual install required — download from [GitHub releases](https://github.com/LuaLS/lua-language-server/releases) and add to PATH.

## Configuration

Place a `.luarc.json` or `.luarc.jsonc` in your project root to configure diagnostics, libraries, and runtime version. See the [wiki](https://luals.github.io/wiki/configuration/) for details.
