# Terraform Language Support

Language support for HashiCorp Terraform and OpenTofu — diagnostics, completions, go-to-definition.

**LSP**: `terraform-ls` (or `terraform-lsp`)
**File types**: `.tf`, `.tfvars`, `.hcl`

## Prerequisites

- **terraform-ls** must be on PATH.

`:ExtInstall terraform` installs terraform-ls into `~/.local/bin` on Linux/WSL (needs
`curl` + `unzip`).

```
# macOS
brew install hashicorp/tap/terraform-ls

# Or download from https://releases.hashicorp.com/terraform-ls/
```

## Features

- Diagnostics for configuration errors
- Completion for resource types, attributes, and functions
- Go-to-definition for modules and variables
- Hover documentation for providers and resources
