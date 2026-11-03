import importlib.machinery
import importlib.util
import json
import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("ccs", str(ROOT / "ccs"))
spec = importlib.util.spec_from_loader(loader.name, loader)
ccs = importlib.util.module_from_spec(spec)
loader.exec_module(ccs)


def session(sid="abc", **changes):
    return {"id": sid, "cwd": "/tmp/project", "mtime": 1, "title": "Session",
            "name": None, "recap": "", "last": "", "turns": 0, "cost": None,
            "prompts": "", **changes}


class SessionsTest(unittest.TestCase):
    def test_transcript_metadata_and_human_prompts(self):
        records = [
            {"type": "user", "cwd": "/tmp/A 'project'", "turnOrigin": "human",
             "message": {"content": [{"type": "text", "text": "Fix   the bug"}]}},
            {"type": "user", "turnOrigin": "human", "message": {"content": "<system>ignore</system>"}},
            {"type": "ai-title", "aiTitle": "Generated title"},
            {"type": "custom-title", "customTitle": "My title"},
            {"type": "agent-name", "agentName": "helper"},
            {"type": "last-prompt", "lastPrompt": "Last\n question"},
            {"type": "cost-state", "totalCostUSD": 1.25},
            {"type": "system", "subtype": "away_summary", "content": "A\n recap"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.jsonl"
            path.write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in records)
                            + '\n{"turnOrigin":"human",bad json\n')
            result = ccs.scan_transcript(path)
        self.assertEqual(result["title"], "My title")
        self.assertEqual(result["cwd"], "/tmp/A 'project'")
        self.assertEqual(result["turns"], 1)
        self.assertEqual(result["prompts"], "Fix the bug")
        self.assertEqual(result["recap"], "A recap")
        self.assertEqual(result["last"], "Last question")
        self.assertEqual(result["cost"], 1.25)

    def test_filter_and_sort(self):
        old = session("old", mtime=1, prompts="Repair authentication")
        new = session("new", mtime=2, live={"status": "idle"})
        found = ccs.build_rows([old, new], "AUTHENTICATION", recent=True)
        self.assertEqual([r["session"]["id"] for r in found], ["old"])
        rows = ccs.build_rows([old, new], "")
        self.assertEqual([r["session"]["id"] for r in rows if r["kind"] == "session"], ["new", "old"])
        rows = ccs.build_rows([old, new], "", recent=True)
        self.assertEqual([r["session"]["id"] for r in rows], ["new", "old"])

    def test_cache_refresh_and_age_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            projects = root / "projects"
            project = projects / "example"
            project.mkdir(parents=True)
            path = project / "saved.jsonl"
            path.write_text('{"cwd":"/tmp/project","type":"custom-title","customTitle":"Before"}\n')
            with patch.object(ccs, "PROJECTS", projects), patch.object(ccs, "CACHE", root / "cache/index.json"):
                self.assertEqual(ccs.load_index(0)["saved"]["title"], "Before")
                with patch.object(ccs, "scan_transcript", side_effect=AssertionError("cache not used")):
                    self.assertEqual(ccs.load_index(0)["saved"]["title"], "Before")
                path.write_text('{"cwd":"/tmp/project","type":"custom-title","customTitle":"After change"}\n')
                self.assertEqual(ccs.load_index(0)["saved"]["title"], "After change")
                old = time.time() - 30 * 86400
                os.utime(path, (old, old))
                self.assertEqual(ccs.load_index(14), {})

    def test_live_sessions_survive_age_filter(self):
        with patch.object(ccs, "load_index", return_value={}), patch.object(
            ccs, "open_sessions", return_value={"live": {"cwd": "/tmp/project", "startedAt": 1000}}
        ):
            self.assertEqual(ccs.collect(14)[0]["id"], "live")

    def test_activation_quotes_shell_arguments(self):
        name = "helper'; echo injected; #"
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIsNone(ccs.activate(session(live={"kind": "background", "name": name})))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), ["claude", "attach", name])
            self.assertIsNone(ccs.activate(session("id'; bad", cwd="/tmp/it's a project")))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]),
                             ["cd", "/tmp/it's a project", "&&", "claude", "--resume", "id'; bad"])

    def test_focus_and_automation_errors(self):
        live = session(live={"kind": "interactive", "pid": 123})
        with patch.object(ccs.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 0, "ttys001\n", ""),
            subprocess.CompletedProcess([], 0, "ok\n", ""),
        ]) as run:
            self.assertIsNone(ccs.activate(live))
            self.assertEqual(run.call_args.args[0], ["osascript", "-", "/dev/ttys001"])
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "Permission denied")):
            self.assertEqual(ccs.activate(session()), "Permission denied")

    def test_installer_and_cli_without_user_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "bin with spaces"
            subprocess.run([str(ROOT / "install.sh"), str(destination)], check=True, capture_output=True)
            installed = destination / "ccs"
            self.assertEqual(installed.read_bytes(), (ROOT / "ccs").read_bytes())
            self.assertTrue(os.access(installed, os.X_OK))
            env = {**os.environ, "HOME": directory, "PATH": str(Path(os.sys.executable).parent) + ":/usr/bin:/bin"}
            result = subprocess.run([os.sys.executable, str(installed), "--list"], env=env,
                                    check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout, "")
            result = subprocess.run([os.sys.executable, str(installed), "--days", "-1"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)

    def test_piped_installer_and_failed_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            curl = fake_bin / "curl"
            curl.write_text('#!/bin/sh\ncp "$CCS_TEST_SOURCE" "$4"\n')
            curl.chmod(0o755)
            destination = root / "installed"
            env = {**os.environ, "PATH": str(fake_bin) + ":" + os.environ["PATH"],
                   "CCS_TEST_SOURCE": str(ROOT / "ccs")}
            installer = (ROOT / "install.sh").read_text()
            subprocess.run(["sh", "-s", "--", str(destination)], input=installer,
                           env=env, check=True, capture_output=True, text=True)
            installed = destination / "ccs"
            self.assertEqual(installed.read_bytes(), (ROOT / "ccs").read_bytes())
            installed.write_text("previous installation")
            curl.write_text('#!/bin/sh\nexit 22\n')
            result = subprocess.run(["sh", "-s", "--", str(destination)], input=installer,
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(installed.read_text(), "previous installation")


if __name__ == "__main__":
    unittest.main()
