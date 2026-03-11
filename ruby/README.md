# Ruby Language Support

Language support for Ruby — diagnostics, completions, go-to-definition.

**LSP**: `ruby-lsp`
**File types**: `.rb`, `.rake`, `.gemspec`

## Prerequisites

- **Ruby** and gem must be installed.

The LSP server is installed automatically when you install this extension. If you need to install it manually:

```
gem install ruby-lsp
```

## Features

- Diagnostics and linting
- Completion with YARD documentation
- Go-to-definition, find references
- Works with Bundler projects (`Gemfile`)
