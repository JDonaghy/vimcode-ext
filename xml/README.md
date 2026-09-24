# XML Language Support

Language support for XML — formatting, validation, and schema support.

**LSP**: `lemminx` (Eclipse LemMinX)
**File types**: `.xml`, `.xsd`, `.xsl`, `.xslt`, `.svg`, `.pom`

## Prerequisites

- **lemminx** must be on PATH.

`:ExtInstall xml` downloads the lemminx binary into `~/.local/bin` on Linux/WSL and
macOS (x86_64 and arm64, needs `curl` + `unzip`), from the
[redhat-developer/vscode-xml](https://github.com/redhat-developer/vscode-xml/releases)
releases — upstream `eclipse/lemminx` publishes no GitHub releases of its own.

## Features

- Syntax validation and well-formedness checking
- XSD/DTD schema validation and completion
- Formatting (`:Lformat`)
- Tag auto-completion
