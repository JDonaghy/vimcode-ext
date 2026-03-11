# VimCode Extensions Registry

This repository contains the official extension registry for [VimCode](https://github.com/JDonaghy/vimcode), a Vim+VSCode hybrid editor in Rust.

## How it works

VimCode fetches `registry.json` from this repo on startup and caches it locally. Extensions provide LSP server configs, DAP debugger adapters, and Lua scripts — all discoverable from VimCode's Extensions sidebar panel.

## Available Extensions

| Extension | Description | LSP | DAP |
|-----------|-------------|-----|-----|
| `bash` | Bash / Shell Support | bash-language-server | — |
| `bicep` | Bicep Language Support | bicep-langserver | — |
| `cpp` | C / C++ Language Support | clangd | codelldb |
| `csharp` | C# Language Support | csharp-ls | netcoredbg |
| `git-insights` | Inline git blame, file history, stash management | — | — |
| `go` | Go Language Support | gopls | delve |
| `java` | Java Language Support | jdtls | java-debug |
| `javascript` | JavaScript / TypeScript Support | typescript-language-server | js-debug |
| `json` | JSON Language Support | vscode-json-languageserver | — |
| `markdown` | Markdown Language Support | marksman | — |
| `php` | PHP Language Support | intelephense | — |
| `python` | Python Language Support | pyright | debugpy |
| `ruby` | Ruby Language Support | ruby-lsp | — |
| `rust` | Rust Language Support | rust-analyzer | codelldb |
| `terraform` | Terraform Language Support | terraform-ls | — |
| `xml` | XML Language Support | lemminx | — |
| `yaml` | YAML Language Support | yaml-language-server | — |

## Contributing a New Extension

1. Create a directory with your extension name (lowercase, hyphens ok)
2. Add a `manifest.toml` — see [EXTENSIONS.md](EXTENSIONS.md) for the full schema
3. Add any Lua scripts referenced in the manifest's `scripts` field
4. Add a `README.md` describing your extension
5. Add an entry to `registry.json`
6. Submit a pull request

### Testing Locally

Before submitting, test your extension locally in VimCode:

```bash
# Copy your extension to VimCode's local extensions directory
cp -r my-extension ~/.config/vimcode/extensions/my-extension

# Open VimCode — your extension appears in the Extensions panel
# Install it with :ExtInstall my-extension
# Iterate with :Plugin reload after editing Lua scripts
```

## Repository Structure

```
├── registry.json          # Extension manifest index (fetched by VimCode)
├── EXTENSIONS.md          # Extension development guide
├── bash/                  # One directory per extension
│   ├── manifest.toml
│   └── README.md
├── git-insights/
│   ├── manifest.toml
│   ├── blame.lua
│   ├── history.lua
│   ├── ...
│   └── README.md
└── ...
```

## License

Extensions in this repository are provided under the same license as VimCode unless otherwise noted in individual extension directories.
