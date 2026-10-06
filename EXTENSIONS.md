# VimCode Extension Development

**The extension guide lives in the vimcode repo: [`vimcode/EXTENSIONS.md`](https://github.com/JDonaghy/vimcode/blob/develop/EXTENSIONS.md).**

That one document covers the `manifest.toml` schema and the Lua plugin API (`vimcode.*`). It is kept current with each vimcode change. This file used to be a copy, made when the registry was extracted from vimcode, and it drifted: it never gained the native Lua API (events and keymaps, timers and spawn, picker, decorations, read APIs, extension UI, `http`/`json`/storage). Rather than maintain two copies, this repo points at the canonical one.

Registry-specific steps (adding a directory, `registry.json`, testing locally) are in this repo's [README](README.md#contributing-a-new-extension).
