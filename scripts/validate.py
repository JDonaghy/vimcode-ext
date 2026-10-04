#!/usr/bin/env python3
"""Static validation for the vimcode-ext extension registry.

Run from the repo root:

    python3 scripts/validate.py

Exits 0 when every check passes, 1 otherwise, printing one line per problem.
Stdlib only (``tomllib`` needs Python 3.11+), no network, and it never executes
an extension's install command -- see ``NOT EXECUTED`` below.

What it checks
--------------
1. every ``*/manifest.toml`` parses as TOML;
2. required keys are present and of the right type;
3. ``name`` equals the directory the manifest lives in;
4. ``registry.json`` parses, and agrees with the manifests it aggregates --
   same set of extensions, and every field equal once manifest defaults are
   applied (the registry is normalised: it spells out ``lsp``/``dap``/
   ``scripts``/``workspace_markers`` for every entry even where the manifest
   omits them, so a naive dict comparison reports false drift);
5. install commands, where declared, are non-empty and not obviously unsafe.
6. an ``[lsp.acquire]`` / ``[dap.acquire]`` table (#1345/#1346), where
   declared, has a valid ``kind`` and that kind's required keys.
7. an install command that resolves to ``npm install -g`` has an
   ``[lsp.acquire]``/``[dap.acquire]`` fallback (#14) -- on a stock Linux box
   with the distro's system node, a root-owned global npm prefix makes
   ``npm install -g`` fail with EACCES for a normal user, every time.

NOT EXECUTED: install commands are inspected as strings only. Several resolve
to ``brew install ...`` or ``npm install -g ...``; running them would make this
slow, network-dependent and machine-mutating. Live install verification is
operator smoke, not this gate.
"""

from __future__ import annotations

import json
import pathlib
import sys
import tomllib

# Top-level manifest keys that must be present, with their required type.
REQUIRED: dict[str, type | tuple[type, ...]] = {
    "name": str,
    "display_name": str,
    "description": str,
    "version": str,
    "file_extensions": list,
    "language_ids": list,
}

# The registry is a NORMALISED aggregate of the manifests, so a whole-dict
# comparison reports drift that isn't there. Instead of encoding whatever the
# current generator happens to emit, compare an explicit list of semantically
# meaningful fields, each with the default a manifest means when it omits it.
#
# Anything NOT listed here is deliberately not compared: `scripts` (the
# registry carries it at top level but never inside lsp/dap), `comment`
# (editorial), and generator-added nulls like `initialization_options`. If a
# field starts mattering, add it here rather than widening to a dict diff.
TOP_FIELDS: dict[str, object] = {
    "display_name": "",
    "description": "",
    "version": "",
    "file_extensions": [],
    "language_ids": [],
    "workspace_markers": [],
}

LSP_FIELDS: dict[str, object] = {
    "binary": "",
    "install": "",
    "install_linux": "",
    "install_macos": "",
    "install_windows": "",
    "fallback_binaries": [],
    "args": [],
    "dependencies": [],
    "acquire": None,
}

DAP_FIELDS: dict[str, object] = {
    "adapter": "",
    "binary": "",
    "install": "",
    "transport": "",
    "args": [],
    "acquire": None,
}

# Native tool acquisition (#1345, `vimcode::core::tool_acquire::AcquireConfig`).
# `acquire` mirrors like `dependencies` above -- copied byte-for-byte from the
# manifest, not expanded with the Rust struct's per-kind field defaults (there
# is no established "always fully spelled out" convention for it the way
# TOP_FIELDS has for the extension-level table).
#
# `npm` (#1346/#14) is the only package-manager kind opted in here -- it's
# the only one any manifest in this registry uses today. `pip`/`go`/`cargo`/
# `dotnet-tool` (also #1346) are real vimcode kinds but unused in this
# registry; add them here, deliberately, the day a manifest needs one.
ACQUIRE_KINDS = ("hashicorp-release", "github-release", "url-template", "npm")

# Non-empty keys each `kind` requires, matching the `BadConfig` errors
# `tool_acquire.rs`'s `resolve_hashicorp_release` / `resolve_github_release` /
# `resolve_url_template` / `package_manager_argv` raise at runtime for the
# same thing.
ACQUIRE_REQUIRED_KEYS: dict[str, tuple[str, ...]] = {
    "hashicorp-release": ("product",),
    "github-release": ("repo", "asset"),
    "url-template": ("url",),
    "npm": ("package",),
}

ACQUIRE_STR_KEYS = (
    "kind",
    "product",
    "repo",
    "asset",
    "url",
    "package",
    "version",
    "binary_path",
)
ACQUIRE_DICT_KEYS = ("os_map", "arch_map")

# Substrings that have no business in a declarative install command. Not a
# sandbox -- a cheap guard against the obviously destructive.
FORBIDDEN_IN_INSTALL = ("rm -rf /", ":(){", "mkfs", "dd if=", "> /dev/sd", "curl | sh", "curl|sh")

INSTALL_KEYS = ("install", "install_linux", "install_macos", "install_windows")

# #14: on a stock Linux box, the distro's system node has a global prefix
# (typically `/usr/lib/node_modules`) owned by root -- `npm install -g`
# fails with EACCES for a normal user every time, unless node itself came
# from Homebrew/nvm/fnm (a private, user-owned prefix). An install command
# built on this string must not be a manifest's only install path; it needs
# an `[lsp.acquire]`/`[dap.acquire]` kind="npm" table (installs into a
# private prefix under vimcode's managed tools dir, no sudo, no global
# prefix) ahead of it. The bare string is still fine as the tier-3 fallback
# for vimcode older than #1346's `[lsp.acquire]` kind="npm" support.
NPM_GLOBAL_INSTALL = "npm install -g"

# npm's `typescript` jumped to a native (Go) rewrite at major 7 that ships no
# `tsserver`, which typescript-language-server requires (#13). An install
# command that names the bare package, or pins it to a moving tag, resolves
# to 7 today. `typescript-language-server` is a separate npm token and is
# unaffected.
UNPINNED_TYPESCRIPT_TOKENS = ("typescript", "typescript@latest", "typescript@*")


def load_manifests(root: pathlib.Path) -> tuple[dict[str, dict], list[str]]:
    """Parse every ``*/manifest.toml``. Returns (by-name, problems)."""
    problems: list[str] = []
    by_name: dict[str, dict] = {}

    for path in sorted(root.glob("*/manifest.toml")):
        rel = path.relative_to(root)
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
            problems.append(f"{rel}: does not parse as TOML: {exc}")
            continue

        for key, want in REQUIRED.items():
            if key not in data:
                problems.append(f"{rel}: missing required key '{key}'")
            elif not isinstance(data[key], want):
                got = type(data[key]).__name__
                problems.append(f"{rel}: '{key}' must be {want.__name__}, got {got}")

        name = data.get("name")
        if isinstance(name, str):
            if name != path.parent.name:
                problems.append(
                    f"{rel}: name '{name}' does not match its directory "
                    f"'{path.parent.name}'"
                )
            if name in by_name:
                problems.append(f"{rel}: duplicate extension name '{name}'")
            else:
                by_name[name] = data

        problems.extend(check_install_commands(rel, data))
        problems.extend(check_acquire_tables(rel, data))

    if not by_name and not problems:
        problems.append("no */manifest.toml found -- wrong directory?")

    return by_name, problems


def check_install_commands(rel: pathlib.Path, data: dict) -> list[str]:
    """Install strings are non-empty where present, and not obviously unsafe."""
    problems: list[str] = []
    for table in ("lsp", "dap"):
        section = data.get(table)
        if not isinstance(section, dict):
            continue
        for key in INSTALL_KEYS:
            if key not in section:
                continue
            cmd = section[key]
            if not isinstance(cmd, str):
                problems.append(f"{rel}: [{table}].{key} must be a string")
                continue
            # An empty `install` is how a manifest says "ships with the
            # runtime" (e.g. debugpy via python -m). Only whitespace-only
            # strings are a mistake.
            if cmd != "" and not cmd.strip():
                problems.append(f"{rel}: [{table}].{key} is whitespace-only")
            for bad in FORBIDDEN_IN_INSTALL:
                if bad in cmd:
                    problems.append(f"{rel}: [{table}].{key} contains {bad!r}")
            if set(cmd.split()) & set(UNPINNED_TYPESCRIPT_TOKENS):
                problems.append(
                    f"{rel}: [{table}].{key} installs 'typescript' without a "
                    "pinned major version (npm typescript 7 has no tsserver, "
                    "see #13) -- pin it, e.g. 'typescript@5'"
                )

        # #14: `npm install -g` must not be the only install path -- it
        # needs an `[{table}.acquire]` kind="npm" table (installed into a
        # private, vimcode-managed prefix) ahead of it, with the global
        # string kept only as the tier-3 fallback for pre-#1346 vimcode.
        uses_npm_global = any(
            isinstance(section.get(key), str) and NPM_GLOBAL_INSTALL in section[key]
            for key in INSTALL_KEYS
        )
        if uses_npm_global:
            acquire = section.get("acquire")
            has_npm_acquire = isinstance(acquire, dict) and acquire.get("kind") == "npm"
            if not has_npm_acquire:
                problems.append(
                    f"{rel}: [{table}] installs via {NPM_GLOBAL_INSTALL!r} with no "
                    f"[{table}.acquire] kind=\"npm\" fallback (#14) -- this fails "
                    "with EACCES for a normal user on a stock Linux box's system "
                    "node"
                )
    return problems


def check_acquire_tables(rel: pathlib.Path, data: dict) -> list[str]:
    """``[lsp.acquire]`` / ``[dap.acquire]``, where declared: a valid ``kind``,
    and that ``kind``'s required keys present and non-empty."""
    problems: list[str] = []
    for table in ("lsp", "dap"):
        section = data.get(table)
        if not isinstance(section, dict):
            continue
        acquire = section.get("acquire")
        if acquire is None:
            continue
        label = f"{rel}: [{table}.acquire]"
        if not isinstance(acquire, dict):
            problems.append(f"{label} must be a table")
            continue

        kind = acquire.get("kind")
        if kind not in ACQUIRE_KINDS:
            problems.append(f"{label}.kind must be one of {ACQUIRE_KINDS}, got {kind!r}")
            kind = None

        for key in ACQUIRE_STR_KEYS:
            if key in acquire and not isinstance(acquire[key], str):
                problems.append(f"{label}.{key} must be a string")
        for key in ACQUIRE_DICT_KEYS:
            if key in acquire and not isinstance(acquire[key], dict):
                problems.append(f"{label}.{key} must be a table")

        if kind is not None:
            for key in ACQUIRE_REQUIRED_KEYS[kind]:
                if not acquire.get(key):
                    problems.append(f"{label} kind {kind!r} requires non-empty '{key}'")
            # `resolve_url_template` has no release API to resolve "latest"
            # against -- it rejects an unpinned version at runtime.
            if kind == "url-template" and acquire.get("version", "latest") in ("", "latest"):
                problems.append(f"{label} kind 'url-template' requires a pinned 'version'")
    return problems


def compare_table(
    label: str,
    fields: dict[str, object],
    manifest_tbl: object,
    registry_tbl: object,
) -> list[str]:
    """Compare one table field-by-field, absent meaning the documented default.

    A table the manifest omits entirely is equivalent to one where every field
    is its default -- that is how the registry spells it, and it is also what
    the manifest means.
    """
    man = manifest_tbl if isinstance(manifest_tbl, dict) else {}
    reg = registry_tbl if isinstance(registry_tbl, dict) else {}
    problems: list[str] = []
    for field, default in fields.items():
        want = man.get(field, default)
        got = reg.get(field, default)
        if want != got:
            problems.append(
                f"{label}.{field} disagrees: manifest={want!r} registry={got!r}"
            )
    return problems


def check_registry(root: pathlib.Path, manifests: dict[str, dict]) -> list[str]:
    """registry.json parses, and matches the manifests it aggregates."""
    problems: list[str] = []
    path = root / "registry.json"
    if not path.exists():
        return ["registry.json: missing"]

    try:
        entries = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"registry.json: does not parse as JSON: {exc}"]

    if not isinstance(entries, list):
        return [f"registry.json: must be a JSON array, got {type(entries).__name__}"]

    by_name: dict[str, dict] = {}
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            problems.append(f"registry.json[{i}]: entry must be an object")
            continue
        name = entry.get("name")
        if not isinstance(name, str):
            problems.append(f"registry.json[{i}]: missing or non-string 'name'")
            continue
        if name in by_name:
            problems.append(f"registry.json: duplicate entry for '{name}'")
        by_name[name] = entry

    for name in sorted(set(manifests) - set(by_name)):
        problems.append(f"registry.json: no entry for '{name}/manifest.toml'")
    for name in sorted(set(by_name) - set(manifests)):
        problems.append(f"registry.json: entry '{name}' has no {name}/manifest.toml")

    for name in sorted(set(manifests) & set(by_name)):
        man, reg = manifests[name], by_name[name]
        problems += compare_table(f"'{name}'", TOP_FIELDS, man, reg)
        problems += compare_table(f"'{name}'.lsp", LSP_FIELDS, man.get("lsp"), reg.get("lsp"))
        problems += compare_table(f"'{name}'.dap", DAP_FIELDS, man.get("dap"), reg.get("dap"))

    return problems


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    manifests, problems = load_manifests(root)
    problems += check_registry(root, manifests)

    for line in problems:
        print(f"FAIL {line}")

    if problems:
        print(f"\n{len(problems)} problem(s) across {len(manifests)} extension(s)")
        return 1

    print(f"OK {len(manifests)} extensions, registry.json agrees with every manifest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
