# Terraform Language Support

Language support for HashiCorp Terraform and OpenTofu — diagnostics, completions, go-to-definition.

**LSP**: `terraform-ls` (or `terraform-lsp`)
**File types**: `.tf`, `.tfvars`, `.hcl`

## Prerequisites

None. `:ExtInstall terraform` installs terraform-ls automatically on Linux, macOS and
Windows — vimcode downloads the right build straight from HashiCorp's release API,
verifies its SHA-256 checksum, and unpacks it, with no shell command, `curl`, `unzip`,
`sudo`, or PATH setup of any kind.

If you'd rather install it yourself:

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
