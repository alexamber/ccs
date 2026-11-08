#!/usr/bin/env python3
"""Developer-only CLI/PTY smoke tests; Python is not used by the shipped app."""
import fcntl
import json
import os
from pathlib import Path
import pty
import plistlib
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="ccs-native-check-") as temp:
    home = Path(temp)
    project = home / ".claude/projects/example"
    project.mkdir(parents=True)
    records = [
        {"type": "user", "cwd": "/tmp/it's a project", "message": {"content": "Fix authentication"}},
        {"type": "custom-title", "customTitle": "Authentication fix"},
        {"type": "cost-state", "totalCostUSD": 1.25},
    ]
    (project / "example.jsonl").write_text("\n".join(json.dumps(x) for x in records))
    bin_dir = home / "bin"
    bin_dir.mkdir()
    (bin_dir / "claude").write_text("#!/bin/sh\nprintf '[]\\n'\n")
    (bin_dir / "claude").chmod(0o755)
    fixture = Path(__file__).resolve().parents[1] / "Tests/Fixtures/codex.py"
    (bin_dir / "codex").write_text("#!" + sys.executable + "\n" + fixture.read_text().split("\n", 1)[1])
    (bin_dir / "codex").chmod(0o755)
    (home / ".codex").mkdir()
    env = {**os.environ, "HOME": str(home), "CODEX_HOME": str(home / ".codex"), "PATH": str(bin_dir) + ":/usr/bin:/bin", "TERM": "xterm-256color", "CCS_SETTINGS_PATH": str(home / "settings.json")}

    def run(*args, code=0):
        result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == code, (args, result.returncode, result.stderr)
        return result.stdout

    exported = json.loads(run("--json"))
    assert exported[0]["title"] == "Authentication fix"
    assert exported[0]["dir"] == "/tmp/it's a project"
    assert exported[0]["cost"] == 1.25
    assert exported[0]["name"] is None
    assert "prompts" not in exported[0]
    assert "provider" not in exported[0] and "key" not in exported[0]
    assert "Authentication fix" in run("--list")
    combined = json.loads(run("--provider", "all", "--json"))
    assert len(combined) == 3 and len({s["key"] for s in combined}) == 3
    assert {s["provider"] for s in combined} == {"claude", "codex"}
    codex = json.loads(run("--provider=codex", "--json"))
    assert len(codex) == 2 and all(s["turns"] is None and s["cost"] is None for s in codex)
    assert not any("Hidden" in s["title"] for s in codex)
    # Auto-detection works even when old history from the other tool remains.
    (bin_dir / "claude").rename(bin_dir / "claude.disabled")
    listing = run("--list")
    assert "Codex authentication review" in listing and "Authentication fix" not in listing
    (bin_dir / "claude.disabled").rename(bin_dir / "claude")
    (bin_dir / "codex").rename(bin_dir / "codex.disabled")
    listing = run("--list")
    assert "Authentication fix" in listing and "Codex authentication review" not in listing
    (bin_dir / "codex.disabled").rename(bin_dir / "codex")
    preference_path = Path(env["CCS_SETTINGS_PATH"])
    preference_path.write_text(json.dumps({"defaultDays": 7, "folders": False, "newDirectory": "~/ccs-sessions", "cleanup": True,
                                          "hotkeyCode": 49, "hotkeyModifiers": 2048, "hotkeyLabel": "⌥Space",
                                          "enabledProviders": ["claude"], "newProvider": "claude"}))
    assert "Codex authentication review" not in run("--list")
    assert "Codex authentication review" in run("--provider", "codex", "--list")
    assert json.loads(preference_path.read_text())["enabledProviders"] == ["claude"]
    preference_path.unlink()
    run("--activate", "example", code=1)  # Ambiguous IDs must not open a terminal.
    run("--provider", "invalid", code=2)
    run("--provider", "all", "--new", code=2)
    run("--days", "-1", code=2)
    run("--watch", "-1", code=2)
    run("--fresh", code=2)
    run("--json", "--list", code=2)
    run("--activate", "missing", code=1)
    run("--activate=missing", code=1)
    run("--json", "--days=0")
    run("--install-cli")
    link = home / ".local/bin/ccs"
    assert link.is_symlink() and link.resolve() == binary
    run("--install-cli")
    assert len(list(link.parent.iterdir())) == 1, "Repeated installation created a backup"
    info_path = binary.parent.parent / "Info.plist"
    version = plistlib.loads(info_path.read_bytes())["CFBundleShortVersionString"]
    assert run("--version").strip() == "ccs " + version
    # A login shell invokes the command with argv[0] == "ccs", not its full path.
    installed_env = {**env, "PATH": str(link.parent) + ":" + env["PATH"]}
    via_path = subprocess.run(["ccs", "--version"], env=installed_env, capture_output=True, text=True, timeout=20)
    assert via_path.returncode == 0 and via_path.stdout.strip() == "ccs " + version, via_path
    run("--install-cli", "--json", code=2)
    # Partial metadata must remain visible for browsing, but never look like a
    # successful complete export/list or authorize deleting an unknown folder.
    partial = project / "partial.jsonl"
    partial.write_text('{"type":"user","cwd":"/unfinished')
    failure = subprocess.run([str(binary), "--provider", "claude", "--list"], env=env, capture_output=True, text=True, timeout=20)
    assert failure.returncode == 1 and "Authentication fix" in failure.stdout and failure.stderr.strip(), failure
    run("--provider", "claude", "--json", code=1)
    partial.unlink()
    extreme = project / "extreme.jsonl"
    extreme.write_text('{"type":"user","cwd":"/tmp/extreme"}\n{"type":"cost-state","totalCostUSD":1e100}')
    assert "[Claude]" in run("--provider", "claude", "--list")
    extreme.unlink()
    print("CLI metadata, list, error statuses, installation, version, and flags: passed", flush=True)

    unused, in_use = home / "2026-11-08-1", home / "2026-11-08-2"
    archived, subagent = home / "2026-11-08-3", home / "2026-11-08-4"
    for folder in (unused, in_use, archived, subagent):
        folder.mkdir()
    holder = subprocess.Popen(["/bin/sleep", "30"], cwd=in_use)
    try:
        run("--prune", str(unused)); run("--prune", str(in_use))
        assert not unused.exists(), "Unused folder was not pruned"
        assert in_use.exists(), "An active working directory was removed"
        run("--prune", str(archived)); run("--prune", str(subagent))
        assert archived.exists() and subagent.exists(), "A saved Codex folder was removed"
        env["CCS_TEST_CODEX_FAILURE"] = "1"
        listing = subprocess.run([str(binary), "--provider", "codex", "--list"], env=env, capture_output=True, text=True, timeout=20)
        assert listing.returncode == 1 and not listing.stdout and "Codex history unavailable" in listing.stderr, listing
        listing = subprocess.run([str(binary), "--provider", "all", "--list"], env=env, capture_output=True, text=True, timeout=20)
        assert listing.returncode == 1 and "Authentication fix" in listing.stdout and "Codex history unavailable" in listing.stderr, listing
        retry = home / "2026-11-08-5"; retry.mkdir()
        run("--prune", str(retry), code=1)
        assert retry.exists(), "A folder was pruned when Codex history could not be read"
        run("--provider", "codex", "--json", code=1)
        assert json.loads(run("--json"))[0]["title"] == "Authentication fix"
        env.pop("CCS_TEST_CODEX_FAILURE")
    finally:
        holder.terminate(); holder.wait()
    print("Real-process cleanup protection: passed", flush=True)

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
    process = subprocess.Popen([str(binary), "--watch", "1"], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()

    def read_until(fragment, timeout=5):
        deadline = time.monotonic() + timeout
        while fragment not in output and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        assert fragment in output, (fragment, bytes(output[-1500:]))

    try:
        read_until(b"CCS sessions")
        output.clear(); os.write(master, b"nothing-matches-this")
        read_until(b"No sessions match")
        os.write(master, b"\x1b")
        output.clear(); read_until(b"Authentication fix")
        output.clear(); os.write(master, b"\x06\x06")  # All → Claude → Codex.
        read_until(b"Codex authentication review")
        output.clear(); os.write(master, b"\x02")
        # ncurses may emit only the changed suffix of "Claude" → "Codex".
        read_until(b"odex")
        assert json.loads(Path(env["CCS_SETTINGS_PATH"]).read_text())["newProvider"] == "codex"
        preferences = json.loads(Path(env["CCS_SETTINGS_PATH"]).read_text())
        preferences.update(enabledProviders=["claude"], providerFilter="claude", newProvider="claude")
        Path(env["CCS_SETTINGS_PATH"]).write_text(json.dumps(preferences))
        # An already-open saved-mode TUI follows the new provider settings.
        output.clear(); read_until(b"Authentication fix")
        os.write(master, b"\x02\x03")
        # Continue draining the PTY while curses restores terminal modes. A
        # parent waiting without draining can block the child's final redraw.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    os.read(master, 65536)
                except OSError:
                    break
        assert process.wait(timeout=1) == 0
        assert json.loads(Path(env["CCS_SETTINGS_PATH"]).read_text())["providerFilter"] == "claude"
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)
        os.close(master)
    # Explicit --provider remains an override when the saved app enables only Claude.
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 90, 0, 0))
    process = subprocess.Popen([str(binary), "--provider", "all", "--watch", "9223372036854775807"], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave); output.clear()
    try:
        read_until(b"Codex authentication review")
        os.write(master, b"\x06\x06\x03")  # All → Claude → disabled Codex; only Claude can persist.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try: os.read(master, 65536)
                except OSError: break
        assert process.wait(timeout=1) == 0
        assert json.loads(preference_path.read_text())["providerFilter"] == "claude"
    finally:
        if process.poll() is None: process.kill(); process.wait(timeout=5)
        os.close(master)
    print("Native terminal picker, search, Escape, settings sync, explicit override, watch, and clean exit: passed")
