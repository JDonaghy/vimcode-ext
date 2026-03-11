# Java Language Support

Language support for Java — diagnostics, completions, go-to-definition.

**LSP**: `jdtls` (Eclipse JDT Language Server)
**DAP**: java-debug-adapter
**File types**: `.java`

## Prerequisites

- **Java JDK** (11 or later) must be installed.
- **jdtls** must be installed manually and placed on PATH. Download from the Eclipse JDT.LS releases page.

Note: jdtls cannot be auto-installed — you must download and configure it yourself.

## Debugger

Install java-debug-adapter for breakpoint debugging. See the microsoft/java-debug repository for setup instructions.

## Features

- Diagnostics and compilation errors
- Completion with Javadoc
- Go-to-definition across source and JAR dependencies
- Works with Maven (`pom.xml`) and Gradle projects
