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
}

DAP_FIELDS: dict[str, object] = {
    "adapter": "",
    "binary": "",
    "install": "",
    "transport": "",
    "args": [],
}

# Substrings that have no business in a declarative install command. Not a
# sandbox -- a cheap guard against the obviously destructive.
FORBIDDEN_IN_INSTALL = ("rm -rf /", ":(){", "mkfs", "dd if=", "> /dev/sd", "curl | sh", "curl|sh")

INSTALL_KEYS = ("install", "install_linux", "install_macos", "install_windows")


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
