#!/usr/bin/env python3
"""Extension install matrix (#17): for every registry manifest, run the
install command vimcode would run on this host, then resolve the binary the
way vimcode does and prove it speaks LSP/DAP.

This is the 2026-10-03 bugbash harness (``bugbash.py``), committed so the
checks it found (vimcode#1712, #1715, #1716, #1717, vimcode-ext#13-#16) run
again instead of only existing as a one-off log. It is deliberately NOT part
of ``scripts/validate.py`` / the CI ``validate`` job: that gate is static,
offline and never executes an install string on purpose (see its own
docstring). This script's entire reason to exist is to execute them for
real, which makes it slow, network-dependent and machine-mutating -- run it
on a dedicated, disposable machine or container per OS, never on a box you
care about. code-coordinator#3319 is the standing reminder that the
registry *liveness* check never runs an install; this script is the
deliberate exception, and whoever wires its schedule should confirm that
before turning it on (see .github/workflows/install-matrix.yml).

Usage: install_matrix.py <vimcode-ext dir> <platform: macos|linux|windows> [ext ...]
Emits one JSON line per (extension, component) to stdout.

The argv-driven run lives in main(), behind ``if __name__ == "__main__":``,
specifically so this module can be imported -- with no argv and no install
executed -- by scripts/test_install_matrix.py, which covers the pure
decision logic below (``_is_reply``, ``pick``, ``builtin_dap_cmd``,
``resolve_python_dap_binary``).

Known gaps fixed while adopting this from the bugbash log (#17):

- The php row false-failed in the original harness: ``framed_roundtrip``
  matched any message carrying ``id: 1`` (or ``request_seq: 1``) as "the
  reply", including a server-to-client request that happens to reuse that
  id. Fixed below to additionally require ``result``/``error`` (LSP) or
  ``type == "response"`` (DAP) before treating a message as the answer.
- ``python``'s DAP binary is resolved through a dedicated
  ``resolve_python_dap_binary()`` that mirrors vimcode's
  ``find_python_binary()``: the managed debugpy venv's own interpreter
  first, then whatever ``python3`` resolves to on PATH -- not the generic
  ``resolve("python")``, which would usually find nothing on Linux/macOS
  (there is no bare ``python`` there) or the wrong interpreter on Windows.

Known gap NOT fixed, left for whoever next touches this file:

- ``builtin_dap_cmd``'s Windows ``debugpy`` string is still hand-built from
  reading the Linux/macOS shape and guessing, same as the original harness.
  It has not been checked against vimcode's actual
  ``install_cmd_for_adapter`` match arm for "debugpy" on Windows (that's in
  ``vimcode/src/core/dap_manager.rs``, outside this repo's worktree, and
  this file's author did not have it open). Do not trust this row's
  ``install`` result on Windows without checking that source first.
"""
import json, os, platform as _pf, shutil, subprocess, sys, tempfile, time, tomllib, glob, threading, socket, re, urllib.request, zipfile, io

# Everything below that depends on argv (EXT_DIR, PLAT, ONLY, WIN_HOME,
# LINE_LIMIT) is set up inside main(), not at import time -- so this module
# can be imported by scripts/test_install_matrix.py to exercise the pure
# helpers (``_is_reply``, ``pick``, ``builtin_dap_cmd``, ...) without
# requiring argv or running any install. Running it as a script
# (``python3 install_matrix.py <dir> <platform> [ext ...]``) behaves exactly
# as before.
EXT_DIR = PLAT = WIN_HOME = LINE_LIMIT = None
ONLY: set = set()
HOME = os.path.expanduser("~")
INSTALL_TIMEOUT = 900
WIN_PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
ARCH = _pf.machine().lower()


def builtin_dap_cmd(adapter):
    a_vs = "arm64" if ARCH in ("arm64", "aarch64") else "x64"
    if adapter == "codelldb":
        if PLAT == "windows":
            return ("curl.exe -fSL https://github.com/vadimcn/codelldb/releases/latest/download/"
                    "codelldb-win32-x64.vsix -o %TEMP%\\vimcode-codelldb.vsix"
                    " && powershell -NoProfile -Command \""
                    "Expand-Archive $env:TEMP\\vimcode-codelldb.vsix $env:TEMP\\vimcode-codelldb -Force;"
                    "$d=$env:USERPROFILE+'\\.local\\bin';"
                    "New-Item -ItemType Directory -Force $d|Out-Null;"
                    "Copy-Item $env:TEMP\\vimcode-codelldb\\extension\\adapter\\codelldb.exe $d\"")
        os_, ext = ("darwin", "dylib") if PLAT == "macos" else ("linux", "so")
        return (f"curl -fSL 'https://github.com/vadimcn/codelldb/releases/latest/download/codelldb-{os_}-{a_vs}.vsix' -o /tmp/vimcode-codelldb.vsix && "
                f"unzip -o /tmp/vimcode-codelldb.vsix 'extension/adapter/codelldb' 'extension/adapter/scripts/*' 'extension/lldb/bin/*' "
                f"'extension/lldb/lib/liblldb.{ext}' 'extension/lldb/lib/libpython312.{ext}' 'extension/lldb/lib/python3.12/*' 'extension/lldb/lib/lldb-python/*' -d /tmp/vimcode-codelldb && "
                f"mkdir -p \"$HOME/.local/bin\" \"$HOME/.local/lldb/bin\" \"$HOME/.local/lldb/lib\" \"$HOME/.local/bin/scripts\" && "
                f"cp /tmp/vimcode-codelldb/extension/adapter/codelldb \"$HOME/.local/bin/codelldb\" && "
                f"cp -r /tmp/vimcode-codelldb/extension/adapter/scripts/. \"$HOME/.local/bin/scripts/\" && "
                f"cp -r /tmp/vimcode-codelldb/extension/lldb/bin/. \"$HOME/.local/lldb/bin/\" && "
                f"cp /tmp/vimcode-codelldb/extension/lldb/lib/liblldb.{ext} \"$HOME/.local/lldb/lib/liblldb.{ext}\" && "
                f"cp /tmp/vimcode-codelldb/extension/lldb/lib/libpython312.{ext} \"$HOME/.local/lldb/lib/libpython312.{ext}\" && "
                f"cp -r /tmp/vimcode-codelldb/extension/lldb/lib/python3.12 \"$HOME/.local/lldb/lib/\" && "
                f"cp -r /tmp/vimcode-codelldb/extension/lldb/lib/lldb-python/lldb \"$HOME/.local/lldb/lib/python3.12/\" && "
                f"chmod +x \"$HOME/.local/bin/codelldb\" \"$HOME/.local/lldb/bin/\"*")
    if adapter == "debugpy":
        if PLAT == "windows":
            # NOT VERIFIED against vimcode's actual Windows match arm -- see
            # the module docstring's "Known gap NOT fixed".
            v = "$HOME\\.config\\vimcode\\debugpy-venv"
            return f"python -m venv {v} && {v}\\Scripts\\python -m pip install debugpy"
        v = f"{HOME}/.config/vimcode/debugpy-venv"
        py = shutil.which("python3") or "python3"
        return f"{py} -m venv {v} && {v}/bin/python -m pip install debugpy"
    if adapter == "delve":
        return "go install github.com/go-delve/delve/cmd/dlv@latest"
    if adapter == "netcoredbg":
        a = "arm64" if ARCH in ("arm64", "aarch64") else "amd64"
        os_ = "osx" if PLAT == "macos" else "linux"  # vimcode has no windows branch
        return (f"curl -fSL 'https://github.com/Samsung/netcoredbg/releases/latest/download/netcoredbg-{os_}-{a}.tar.gz' -o /tmp/vimcode-netcoredbg.tar.gz && "
                "mkdir -p /tmp/vimcode-netcoredbg && tar -xzf /tmp/vimcode-netcoredbg.tar.gz -C /tmp/vimcode-netcoredbg && "
                "mkdir -p \"$HOME/.local/bin\" && cp /tmp/vimcode-netcoredbg/netcoredbg/netcoredbg \"$HOME/.local/bin/netcoredbg\" && "
                "chmod +x \"$HOME/.local/bin/netcoredbg\"")
    return ""


def pick(sec):
    f = {"macos": "install_macos", "linux": "install_linux", "windows": "install_windows"}[PLAT]
    return sec.get(f) or sec.get("install") or ""


def tool_dirs():
    if PLAT == "windows":
        h = WIN_HOME
        return [h + "\\.dotnet\\tools", h + "\\.cargo\\bin", h + "\\.local\\bin", h + "\\go\\bin", h + "\\.npm-global\\bin"]
    d = [f"{HOME}/.local/share/nvim/mason/bin", f"{HOME}/.dotnet/tools", f"{HOME}/.cargo/bin", f"{HOME}/.local/bin",
         f"{HOME}/go/bin", f"{HOME}/.npm-global/bin"]
    if PLAT == "macos":
        d += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]
    return d


def managed_hit(binary):
    roots = [f"{HOME}/Library/Application Support/vimcode/tools", f"{HOME}/.local/share/vimcode/tools"]
    for r in roots:
        for p in glob.glob(f"{r}/{binary}/*/{binary}") + glob.glob(f"{r}/{binary}/*/bin/{binary}"):
            if os.access(p, os.X_OK):
                return p
    return None


def resolve(binary):
    """Mirror lsp_manager::resolve_command, but with the *desktop* PATH a
    Finder/Start-menu launched vimcode gets, not our login shell's."""
    if PLAT == "windows":
        for d in tool_dirs():
            for suf in ("", ".exe", ".cmd"):
                wp = d + "\\" + binary + suf
                lp = subprocess.run(["wslpath", "-u", wp], capture_output=True, text=True).stdout.strip()
                if lp and os.path.exists(lp):
                    return wp
        r = subprocess.run([WIN_PS, "-NoProfile", "-Command", f"(Get-Command {binary} -ErrorAction SilentlyContinue).Source"],
                           capture_output=True, text=True).stdout.strip()
        return r or None
    m = managed_hit(binary)
    if m:
        return m
    for d in tool_dirs():
        p = os.path.join(d, binary)
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    desk_path = "/usr/bin:/bin:/usr/sbin:/sbin" if PLAT == "macos" else os.environ.get("PATH", "")
    return shutil.which(binary, path=desk_path)


def resolve_python_dap_binary():
    """Mirror vimcode's ``find_python_binary()`` for the python/debugpy DAP
    row specifically: the managed debugpy venv's own interpreter first, then
    whatever ``python3`` resolves to on PATH. The generic ``resolve()``
    above is wrong for this binary -- it would look for a literal ``python``
    executable, which plain Linux/macOS boxes don't have, and which on
    Windows is not necessarily the venv's interpreter."""
    if PLAT == "windows":
        venv_py = (WIN_HOME or "") + "\\.config\\vimcode\\debugpy-venv\\Scripts\\python.exe"
        lp = subprocess.run(["wslpath", "-u", venv_py], capture_output=True, text=True).stdout.strip()
        if lp and os.path.exists(lp):
            return venv_py
        r = subprocess.run([WIN_PS, "-NoProfile", "-Command",
                            "(Get-Command python3 -ErrorAction SilentlyContinue).Source"],
                           capture_output=True, text=True).stdout.strip()
        return r or None
    venv_py = f"{HOME}/.config/vimcode/debugpy-venv/bin/python"
    if os.path.exists(venv_py) and os.access(venv_py, os.X_OK):
        return venv_py
    desk_path = "/usr/bin:/bin:/usr/sbin:/sbin" if PLAT == "macos" else os.environ.get("PATH", "")
    return shutil.which("python3", path=desk_path)


def run_install(cmd):
    t0 = time.time()
    if PLAT == "windows":
        argv = [WIN_PS, "-NoProfile", "-NonInteractive", "-Command", cmd]
    else:
        argv = [os.environ.get("SHELL", "/bin/bash"), "-lc", cmd]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=INSTALL_TIMEOUT,
                           stdin=subprocess.DEVNULL, env={**os.environ, "DEBIAN_FRONTEND": "noninteractive",
                                                          "HOMEBREW_NO_AUTO_UPDATE": "1"})
        out = (p.stdout + p.stderr)
        return p.returncode, out[-1500:], round(time.time() - t0)
    except subprocess.TimeoutExpired as e:
        return "timeout", str(e.stdout or "")[-800:], INSTALL_TIMEOUT


def spawn(path, args):
    if PLAT == "windows":
        lp = subprocess.run(["wslpath", "-u", path], capture_output=True, text=True).stdout.strip() if "\\" in path else path
        if path.lower().endswith(".cmd"):
            return subprocess.Popen(["/mnt/c/Windows/System32/cmd.exe", "/C", path, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return subprocess.Popen([lp, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return subprocess.Popen([path, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _is_reply(data):
    """A framed message is the answer to our request 1 only if it is
    actually a *response* carrying that id/seq -- not merely any message
    that happens to reuse the number 1 (#17: this is what false-failed php,
    whose server sends a server-to-client request before replying)."""
    if data.get("id") == 1 and "method" not in data and ("result" in data or "error" in data):
        return True  # LSP response
    if data.get("request_seq") == 1 and data.get("type") == "response":
        return True  # DAP response
    return False


def framed_roundtrip(proc, msg, timeout=60):
    body = json.dumps(msg).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()
    result = {}

    def reader():
        try:
            while True:
                hdrs = {}
                while True:
                    line = proc.stdout.readline()
                    if not line:
                        return
                    line = line.strip()
                    if not line:
                        break
                    k, _, v = line.decode(errors="replace").partition(":")
                    hdrs[k.lower()] = v.strip()
                n = int(hdrs.get("content-length", 0))
                data = json.loads(proc.stdout.read(n))
                if _is_reply(data):
                    result["msg"] = data
                    return
        except Exception as e:
            result["err"] = repr(e)

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    t.join(timeout)
    return result


def lsp_handshake(path, args):
    root = tempfile.mkdtemp()
    uri = "file://" + root
    try:
        proc = spawn(path, args)
    except Exception as e:
        return False, f"spawn failed: {e!r}"
    try:
        r = framed_roundtrip(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": {"processId": None, "rootUri": uri, "capabilities": {},
                                               "workspaceFolders": [{"uri": uri, "name": "bb"}]}})
        if "msg" in r and "result" in r["msg"]:
            name = (r["msg"]["result"].get("serverInfo") or {}).get("name", "?")
            return True, f"initialize OK (serverInfo={name})"
        err = r.get("msg", {}).get("error") or r.get("err")
        proc.kill()
        se = proc.stderr.read()[-600:].decode(errors="replace") if proc.stderr else ""
        return False, f"no initialize result (err={err}) stderr={se!r}"
    finally:
        try:
            proc.kill()
        except Exception:
            pass


def dap_handshake(path, args, transport):
    init = {"seq": 1, "type": "request", "command": "initialize",
            "arguments": {"adapterID": "bb", "clientID": "vimcode", "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path"}}
    if transport == "tcp":
        try:
            proc = spawn(path, [a for a in args if a not in ("--port", "0")] + ["--port", "0"])
        except Exception as e:
            return False, f"spawn failed: {e!r}"
        time.sleep(4)
        alive = proc.poll() is None
        out = b""
        if not alive:
            out = proc.stdout.read()[-400:] + proc.stderr.read()[-400:]
        proc.kill()
        return alive, ("adapter started and stayed up (tcp)" if alive else f"adapter exited rc={proc.returncode}: {out!r}")
    try:
        proc = spawn(path, args)
    except Exception as e:
        return False, f"spawn failed: {e!r}"
    r = framed_roundtrip(proc, init)
    proc.kill()
    if r.get("msg", {}).get("success"):
        return True, "DAP initialize OK"
    se = proc.stderr.read()[-500:].decode(errors="replace")
    return False, f"no DAP initialize response ({r.get('err') or r.get('msg')}) stderr={se!r}"


def emulate_acquire(acq, binary):
    """Emulate vimcode's in-process hashicorp-release acquisition (tier 2)."""
    if acq.get("kind") != "hashicorp-release":
        return None, f"acquire kind {acq.get('kind')} not emulated"
    prod = acq["product"]
    idx = json.load(urllib.request.urlopen(f"https://api.releases.hashicorp.com/v1/releases/{prod}/latest"))
    os_ = {"macos": "darwin", "linux": "linux", "windows": "windows"}[PLAT]
    a = "arm64" if ARCH in ("arm64", "aarch64") else "amd64"
    b = [x for x in idx["builds"] if x["os"] == os_ and x["arch"] == a]
    if not b:
        return None, f"no {os_}/{a} build for {prod}"
    data = urllib.request.urlopen(b[0]["url"]).read()
    d = tempfile.mkdtemp()
    zipfile.ZipFile(io.BytesIO(data)).extractall(d)
    exe = os.path.join(d, binary + (".exe" if PLAT == "windows" else ""))
    os.chmod(exe, 0o755)
    if PLAT == "windows":
        wd = subprocess.run([WIN_PS, "-NoProfile", "-Command", "$env:TEMP"], capture_output=True, text=True).stdout.strip()
        lwd = subprocess.run(["wslpath", "-u", wd], capture_output=True, text=True).stdout.strip()
        shutil.copy(exe, os.path.join(lwd, os.path.basename(exe)))
        exe = wd + "\\" + os.path.basename(exe)
    return exe, f"acquired {prod} {idx['version']} ({len(data)//1024} KiB)"


def deps_missing(deps):
    out = []
    for d in deps:
        if PLAT == "windows":
            ok = bool(subprocess.run([WIN_PS, "-NoProfile", "-Command", f"(Get-Command {d} -ErrorAction SilentlyContinue).Source"],
                                     capture_output=True, text=True).stdout.strip())
        else:
            ok = subprocess.run([os.environ.get("SHELL", "/bin/bash"), "-lc", f"command -v {d}"], capture_output=True).returncode == 0
        if not ok:
            out.append(d)
    return out


def emit(**kw):
    kw["platform"] = PLAT
    print(json.dumps(kw), flush=True)


def main() -> int:
    global EXT_DIR, PLAT, ONLY, WIN_HOME, LINE_LIMIT
    EXT_DIR, PLAT = sys.argv[1], sys.argv[2]
    ONLY = set(sys.argv[3:])
    WIN_HOME = None
    if PLAT == "windows":
        WIN_HOME = subprocess.run([WIN_PS, "-NoProfile", "-Command", "$env:USERPROFILE"],
                                  capture_output=True, text=True).stdout.strip()
    # tty canonical input line limits (MAX_CANON); vimcode types the command into a PTY.
    LINE_LIMIT = {"macos": 1024, "linux": 4096, "windows": None}[PLAT]

    for mf in sorted(glob.glob(os.path.join(EXT_DIR, "*/manifest.toml"))):
        m = tomllib.load(open(mf, "rb"))
        name = m.get("name") or os.path.basename(os.path.dirname(mf))
        if ONLY and name not in ONLY:
            continue
        for comp in ("lsp", "dap"):
            sec = m.get(comp)
            if not sec:
                continue
            binary = sec.get("binary", "")
            if not binary:
                continue
            rec = dict(ext=name, comp=comp, binary=binary)
            cmd = pick(sec)
            source = "manifest"
            if comp == "dap" and not cmd:
                cmd = builtin_dap_cmd(sec.get("adapter", ""))
                source = "builtin" if cmd else "none"
            acq = sec.get("acquire")
            rec["source"] = "acquire" if acq else source
            rec["cmd_len"] = len(cmd)
            if LINE_LIMIT and cmd and len(cmd) + 40 > LINE_LIMIT:  # + "echo '── Installing x ──' ; " prefix
                rec["line_limit"] = f"command {len(cmd)}B exceeds the {LINE_LIMIT}B tty input limit: vimcode's install pane will hang"
            missing = deps_missing(sec.get("dependencies", []))
            if missing:
                rec["deps_missing"] = missing
            path = None
            if acq:
                try:
                    path, note = emulate_acquire(acq, binary)
                    rec["install"] = note
                except Exception as e:
                    rec["install"] = f"acquire failed: {e!r}"
            elif not cmd:
                rec["install"] = "NO INSTALL COMMAND for this platform"
            else:
                rc, out, secs = run_install(cmd)
                rec["install_rc"] = rc
                rec["install_secs"] = secs
                if rc != 0:
                    rec["install_tail"] = out
            if not path:
                if comp == "dap" and sec.get("adapter") == "debugpy" and binary == "python":
                    path = resolve_python_dap_binary()
                else:
                    cands = [binary] + sec.get("fallback_binaries", [])
                    for c in cands:
                        path = resolve(c)
                        if path:
                            break
            rec["resolved"] = path
            if path:
                if comp == "lsp":
                    ok, detail = lsp_handshake(path, sec.get("args", []))
                else:
                    ok, detail = dap_handshake(path, sec.get("args", []), sec.get("transport", "stdio"))
                rec["works"], rec["detail"] = ok, detail
            else:
                rec["works"], rec["detail"] = False, "binary not resolvable where vimcode looks"
            emit(**rec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
