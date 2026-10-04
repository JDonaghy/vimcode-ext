#!/usr/bin/env python3
"""Unit tests for the pure, non-executing parts of scripts/install_matrix.py.

Run from the repo root:

    python3 scripts/test_install_matrix.py

Stdlib only, no network, and -- same discipline as scripts/validate.py --
never runs an install command for real. install_matrix.py's whole job is to
execute installs; what's testable without a disposable box is its
*decision* logic: which reply counts as "the answer" (#17's php false-
failure fix), which install command a platform picks, and which binary the
python/debugpy DAP row resolves to. Importing the module does not run any
of that -- see its own module docstring on why the argv-driven main loop is
behind ``if __name__ == "__main__":``.
"""
from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
import install_matrix as im  # noqa: E402


class IsReplyTests(unittest.TestCase):
    """#17: the original harness matched any message carrying id==1 /
    request_seq==1 as "the reply", which false-failed php -- its server
    sends a server-to-client request before the real response, and that
    request happened to reuse id 1."""

    def test_lsp_server_request_with_id_1_is_not_a_reply(self):
        msg = {"jsonrpc": "2.0", "id": 1, "method": "window/workDoneProgress/create", "params": {}}
        self.assertFalse(im._is_reply(msg))

    def test_lsp_result_response_is_a_reply(self):
        msg = {"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}}
        self.assertTrue(im._is_reply(msg))

    def test_lsp_error_response_is_a_reply(self):
        msg = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "nope"}}
        self.assertTrue(im._is_reply(msg))

    def test_dap_event_with_seq_1_is_not_a_reply(self):
        msg = {"seq": 1, "type": "event", "event": "output"}
        self.assertFalse(im._is_reply(msg))

    def test_dap_response_with_request_seq_1_is_a_reply(self):
        msg = {"seq": 2, "type": "response", "request_seq": 1, "success": True}
        self.assertTrue(im._is_reply(msg))

    def test_unrelated_message_is_not_a_reply(self):
        self.assertFalse(im._is_reply({"jsonrpc": "2.0", "id": 2, "result": {}}))


class PickTests(unittest.TestCase):
    """``pick()`` prefers the platform-specific install field, falling back
    to the generic ``install``."""

    def test_platform_specific_wins(self):
        im.PLAT = "linux"
        sec = {"install": "generic", "install_linux": "apt install foo"}
        self.assertEqual(im.pick(sec), "apt install foo")

    def test_falls_back_to_generic(self):
        im.PLAT = "macos"
        sec = {"install": "brew install foo"}
        self.assertEqual(im.pick(sec), "brew install foo")

    def test_empty_when_neither_present(self):
        im.PLAT = "windows"
        self.assertEqual(im.pick({}), "")


class BuiltinDapCmdTests(unittest.TestCase):
    """Every adapter vimcode ships a built-in installer for resolves to a
    non-empty command on every platform this script supports."""

    def test_known_adapters_non_empty_on_every_platform(self):
        for plat in ("linux", "macos", "windows"):
            im.PLAT = plat
            for adapter in ("codelldb", "debugpy", "delve", "netcoredbg"):
                with self.subTest(platform=plat, adapter=adapter):
                    self.assertTrue(im.builtin_dap_cmd(adapter), f"{adapter} on {plat}")

    def test_unknown_adapter_is_empty(self):
        im.PLAT = "linux"
        self.assertEqual(im.builtin_dap_cmd("not-a-real-adapter"), "")

    def test_debugpy_uses_managed_venv_path_on_posix(self):
        im.PLAT = "linux"
        cmd = im.builtin_dap_cmd("debugpy")
        self.assertIn(".config/vimcode/debugpy-venv", cmd)


class ResolvePythonDapBinaryTests(unittest.TestCase):
    """The python/debugpy DAP row must prefer the managed debugpy venv's own
    interpreter over anything found generically on PATH (mirrors vimcode's
    ``find_python_binary()``)."""

    def test_prefers_managed_venv_interpreter(self):
        im.PLAT = "linux"
        with tempfile.TemporaryDirectory() as fake_home:
            venv_bin = Path(fake_home) / ".config" / "vimcode" / "debugpy-venv" / "bin"
            venv_bin.mkdir(parents=True)
            venv_python = venv_bin / "python"
            venv_python.write_text("#!/bin/sh\n")
            venv_python.chmod(venv_python.stat().st_mode | stat.S_IEXEC)

            old_home = im.HOME
            try:
                im.HOME = fake_home
                self.assertEqual(im.resolve_python_dap_binary(), str(venv_python))
            finally:
                im.HOME = old_home

    def test_falls_back_to_python3_on_path_when_no_venv(self):
        im.PLAT = "linux"
        with tempfile.TemporaryDirectory() as fake_home:
            old_home = im.HOME
            try:
                im.HOME = fake_home  # no debugpy-venv under here
                result = im.resolve_python_dap_binary()
                # Whatever this host's python3 resolves to via the desktop
                # PATH (/usr/bin:/bin:/usr/sbin:/sbin) or None -- the point
                # is it did NOT fabricate a path under the missing venv.
                if result is not None:
                    self.assertNotIn("debugpy-venv", result)
            finally:
                im.HOME = old_home


if __name__ == "__main__":
    unittest.main()
