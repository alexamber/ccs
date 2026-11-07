#!/usr/bin/env python3
"""Developer-only CLI/PTY smoke tests; Python is not used by the shipped app."""
import fcntl
import json
import os
from pathlib import Path
import pty
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
    env = {**os.environ, "HOME": str(home), "PATH": str(bin_dir) + ":/usr/bin:/bin", "TERM": "xterm-256color", "CCS_SETTINGS_PATH": str(home / "settings.json")}

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
    assert "Authentication fix" in run("--list")
    run("--days", "-1", code=2)
    run("--watch", "-1", code=2)
    run("--fresh", code=2)
    run("--json", "--list", code=2)
    run("--activate", "missing", code=1)
    run("--activate=missing", code=1)
    run("--json", "--days=0")
    print("CLI metadata, list, error statuses, and legacy flags: passed", flush=True)

    unused, in_use = home / "2026-11-08-1", home / "2026-11-08-2"
    unused.mkdir(); in_use.mkdir()
    holder = subprocess.Popen(["/bin/sleep", "30"], cwd=in_use)
    try:
        run("--prune", str(unused)); run("--prune", str(in_use))
        assert not unused.exists(), "Unused folder was not pruned"
        assert in_use.exists(), "An active working directory was removed"
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
        read_until(b"Claude sessions")
        output.clear(); os.write(master, b"nothing-matches-this")
        read_until(b"No sessions match")
        os.write(master, b"\x1b")
        output.clear(); read_until(b"Authentication fix")
        os.write(master, b"\x03")
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
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)
        os.close(master)
    print("Native terminal picker, search, Escape, watch, and clean exit: passed")
