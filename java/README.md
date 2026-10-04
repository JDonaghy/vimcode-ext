# Java Language Support

Language support for Java — diagnostics, completions, go-to-definition.

**LSP**: `jdtls` (Eclipse JDT Language Server)
**File types**: `.java`

## Prerequisites

- **Java JDK** (11 or later) must be installed.

## Installation

`:ExtInstall java` downloads the [eclipse-jdtls](https://download.eclipse.org/jdtls/snapshots/)
snapshot tarball (platform-neutral — the same archive on every OS) on Linux and Windows, and
installs via Homebrew (`brew install jdtls`) on macOS.

eclipse-jdtls publishes no GitHub releases and no stable "latest milestone" URL (only an index page
that needs JavaScript to render), so Linux/Windows install the **snapshot** channel instead, which
does publish a stable `jdt-language-server-latest.tar.gz` alias. That trades "milestone" for
"nightly build" — the same tradeoff `brew install jdtls`'s own "whatever's current" model makes.

On Windows, the installer also adds `%USERPROFILE%\.local\bin` to your user `PATH` (same reason as
the `bicep` extension — vimcode's binary lookup doesn't probe for a bare name plus `.cmd`, only
`.exe`) — **restart vimcode once** after the first install for `jdtls` to resolve.

## Debugger

Not available through this extension. `java-debug` (the usual Java DAP adapter) is not a standalone
process — it is a jar that jdtls loads as an OSGi bundle, and the debug session is then driven
through jdtls's own custom LSP commands, not a spawned binary speaking DAP over stdio/tcp. vimcode's
extension schema models the latter, and vimcode has no bundle-loading support for jdtls, so there is
no install this extension could advertise that would actually produce a working debugger.

## Features

- Diagnostics and compilation errors
- Completion with Javadoc
- Go-to-definition across source and JAR dependencies
- Works with Maven (`pom.xml`) and Gradle projects
