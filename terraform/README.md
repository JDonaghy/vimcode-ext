# Terraform Language Support

Language support for HashiCorp Terraform and OpenTofu — diagnostics, completions, go-to-definition.

**LSP**: `terraform-ls` (or `terraform-lsp`)
**File types**: `.tf`, `.tfvars`, `.hcl`

## Prerequisites

- **terraform-ls** must be installed manually and placed on PATH.

```
# macOS
brew install hashicorp/tap/terraform-ls

# Or download from https://releases.hashicorp.com/terraform-ls/
```

Note: terraform-ls cannot be auto-installed — use your platform's package manager or download directly.

## Features

- Diagnostics for configuration errors
- Completion for resource types, attributes, and functions
- Go-to-definition for modules and variables
- Hover documentation for providers and resources
