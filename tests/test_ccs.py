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

    def test_date_range_cycles_through_windows(self):
        self.assertEqual(ccs.cycle_window(7, 1), 30)
        self.assertEqual(ccs.cycle_window(30, 1), 0)
        self.assertEqual(ccs.cycle_window(0, 1), 1)
        self.assertEqual(ccs.cycle_window(1, -1), 0)
        self.assertEqual(ccs.cycle_window(14, 1), 30)
        self.assertEqual(ccs.cycle_window(14, -1), 7)

    def test_watch_refresh_keeps_selected_session(self):
        rows = ccs.build_rows([session("a", mtime=3), session("b", mtime=2), session("c", mtime=1)], "", recent=True)
        selectable = list(range(len(rows)))
        self.assertEqual(ccs.index_of(rows, selectable, "b", 0), 1)
        self.assertEqual(ccs.index_of(rows, selectable, "gone", 2), 2)

    def test_json_output_is_most_recent_first(self):
        old = session("old", mtime=1, prompts="private prompt text")
        new = session("new", mtime=2, cwd=str(Path.home() / "work"), name="helper",
                      live={"status": "busy"})
        result = ccs.to_json([old, new])
        self.assertEqual([s["id"] for s in result], ["new", "old"])
        self.assertEqual(result[0]["dir"], "~/work")
        self.assertEqual([s["status"] for s in result], ["busy", "closed"])
        self.assertNotIn("prompts", result[1])
        self.assertEqual([s["mtime"] for s in result], [2, 1])
        self.assertEqual([s["large"] for s in result], [False, False])
        self.assertEqual(ccs.to_json([session(turns=25)])[0]["large"], True)
        self.assertEqual(ccs.to_json([session(unknown=True)])[0]["status"], "unknown")

    def test_large_sessions(self):
        self.assertFalse(ccs.is_large(session(turns=19, cost=19.9)))
        self.assertTrue(ccs.is_large(session(turns=20)))
        self.assertTrue(ccs.is_large(session(cost=20.0)))
        self.assertFalse(ccs.is_large(session(turns=50, live={"status": "idle"})))

    def test_unreadable_live_list_marks_sessions_unknown(self):
        with patch.object(ccs, "load_index", return_value={"a": session("a")}), \
                patch.object(ccs, "open_sessions", return_value=None):
            self.assertEqual(ccs.state(ccs.collect(7)[0]), "unknown")
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
            self.assertIsNone(ccs.open_sessions())

    def test_activate_by_id(self):
        with patch.object(ccs, "collect", return_value=[session("abc")]), \
                patch.object(ccs, "activate", return_value=None) as activate:
            self.assertIsNone(ccs.activate_by_id("abc", fresh=True))
            activate.assert_called_once_with(session("abc"), True)
            self.assertIn("missing", ccs.activate_by_id("missing"))

    def test_resume_is_refused_or_redirected_by_a_fresh_live_check(self):
        closed = session("abc")
        with patch.object(ccs, "open_sessions", return_value=None), patch.object(ccs.subprocess, "run") as run:
            self.assertIn("not resumed", ccs.activate(closed))
            run.assert_not_called()
        with patch.object(ccs, "open_sessions", return_value={"abc": {"kind": "background", "name": "bg"}}), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIsNone(ccs.activate(closed))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), ["claude", "attach", "bg"])

    def test_fresh_session_starts_in_the_session_folder(self):
        with patch.object(ccs, "open_sessions") as running, \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIsNone(ccs.activate(session(cwd="/tmp/it's here", live={"kind": "interactive", "pid": 1}), fresh=True))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), ["cd", "/tmp/it's here", "&&", "claude"])
            running.assert_not_called()

    def test_activation_quotes_shell_arguments(self):
        name = "helper'; echo injected; #"
        with patch.object(ccs, "open_sessions", return_value={}), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIsNone(ccs.activate(session(live={"kind": "background", "name": name})))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), ["claude", "attach", name])
            self.assertIsNone(ccs.activate(session("id'; bad", cwd="/tmp/it's a project")))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]),
                             ["cd", "/tmp/it's a project", "&&", "claude", "--resume", "id'; bad"])

    def test_candidate_ttys_finds_viewers_and_the_starting_tab(self):
        ps = ("  10     1 ??       login\n"
              "  20    10 ttys001  claude\n"
              "  30    20 ??       claude daemon run\n"
              "  40    30 ttys010  claude --bg-pty-host /tmp/x.sock\n"
              "  50    10 ttys015  claude attach My task\n"
              "  60    10 ttys016  claude attach other\n")
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, ps, "")):
            self.assertEqual(ccs.candidate_ttys(session("abc"), {"pid": 40, "name": "My task"}),
                             ["ttys015", "ttys010", "ttys001"])

    def test_open_sessions_are_focused_never_attached_twice(self):
        background = session(live={"kind": "background", "pid": 40, "name": "My task"})
        with patch.object(ccs, "candidate_ttys", return_value=["ttys010", "ttys001"]), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ok\n", "")) as run:
            self.assertIsNone(ccs.activate(background))
            self.assertEqual(run.call_args.args[0], ["osascript", "-", "/dev/ttys010", "/dev/ttys001"])
            run.assert_called_once()
        with patch.object(ccs, "candidate_ttys", return_value=[]), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIsNone(ccs.activate(background))
            self.assertEqual(shlex.split(run.call_args.args[0][-1]), ["claude", "attach", "My task"])
            self.assertIn("not found", ccs.activate(session(live={"kind": "interactive", "pid": 1})))

    def test_focus_and_automation_errors(self):
        live = session(live={"kind": "interactive", "pid": 123})
        with patch.object(ccs, "candidate_ttys", return_value=["ttys001"]), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ok\n", "")) as run:
            self.assertIsNone(ccs.activate(live))
            self.assertEqual(run.call_args.args[0], ["osascript", "-", "/dev/ttys001"])
        with patch.object(ccs, "open_sessions", return_value={}), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "Permission denied")):
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
            result = subprocess.run([os.sys.executable, str(installed), "--watch", "-1"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            result = subprocess.run([os.sys.executable, str(installed), "--json"], env=env,
                                    check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout), [])
            result = subprocess.run([os.sys.executable, str(installed), "--activate", "nope"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)

    def test_piped_installer_and_failed_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            curl = fake_bin / "curl"
            curl.write_text('#!/bin/sh\ncase "$2" in\n*/hammerspoon/*) cp "$CCS_TEST_HOTKEY" "$4" ;;\n*) cp "$CCS_TEST_SOURCE" "$4" ;;\nesac\n')
            curl.chmod(0o755)
            destination = root / "installed"
            env = {**os.environ, "PATH": str(fake_bin) + ":" + os.environ["PATH"],
                   "CCS_TEST_SOURCE": str(ROOT / "ccs"), "CCS_TEST_HOTKEY": str(ROOT / "hammerspoon/ccs.lua")}
            installer = (ROOT / "install.sh").read_text()
            subprocess.run(["sh", "-s", "--", str(destination)], input=installer,
                           env=env, check=True, capture_output=True, text=True)
            installed = destination / "ccs"
            self.assertEqual(installed.read_bytes(), (ROOT / "ccs").read_bytes())
            self.assertEqual((root / "share/ccs/hammerspoon/ccs.lua").read_bytes(),
                             (ROOT / "hammerspoon/ccs.lua").read_bytes())
            installed.write_text("previous installation")
            curl.write_text('#!/bin/sh\nexit 22\n')
            result = subprocess.run(["sh", "-s", "--", str(destination)], input=installer,
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(installed.read_text(), "previous installation")


class NewSessionTest(unittest.TestCase):
    def test_folders_are_numbered_per_day_and_never_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "base"
            with patch.object(ccs, "prune"):
                self.assertEqual(ccs.make_new_dir(root, "2026-11-05").name, "2026-11-05-1")
                self.assertEqual(ccs.make_new_dir(root, "2026-11-05").name, "2026-11-05-2")
                (root / "2026-11-05-9").mkdir()
                self.assertEqual(ccs.make_new_dir(root, "2026-11-05").name, "2026-11-05-10")
                self.assertEqual(ccs.make_new_dir(root, "2026-11-06").name, "2026-11-06-1")
                real_mkdir = Path.mkdir
                def lose_race(path, *args, **kwargs):
                    if path.name == "2026-11-06-2":
                        real_mkdir(path)
                    return real_mkdir(path, *args, **kwargs)
                with patch.object(ccs.Path, "mkdir", lose_race):
                    self.assertEqual(ccs.make_new_dir(root, "2026-11-06").name, "2026-11-06-3")

    def test_prune_removes_only_unused_empty_dated_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            names = ("2026-11-01-1", "2026-11-01-2", "2026-11-01-3", "2026-11-01-4", "2026-11-01-5", "notes")
            for name in names:
                (root / name).mkdir()
            (root / "2026-11-01-2" / "file.txt").write_text("kept")
            old = time.time() - 2 * ccs.PRUNE_AFTER
            for name in ("2026-11-01-1", "2026-11-01-2", "2026-11-01-3", "2026-11-01-5", "notes"):
                os.utime(root / name, (old, old))
            used = {"x": session(cwd=str(root / "2026-11-01-3"))}
            with patch.object(ccs, "load_index", return_value=used), \
                    patch.object(ccs, "busy_dirs", return_value={str(root / "2026-11-01-5")}):
                ccs.prune(list(root.iterdir()), ccs.PRUNE_AFTER)
            self.assertEqual(sorted(p.name for p in root.iterdir()),
                             ["2026-11-01-2", "2026-11-01-3", "2026-11-01-4", "2026-11-01-5", "notes"])
            with patch.object(ccs, "load_index", return_value={}), patch.object(ccs, "busy_dirs", return_value=None):
                ccs.prune(list(root.iterdir()), 0)
            self.assertIn("2026-11-01-4", [p.name for p in root.iterdir()])

    def test_busy_dirs_reads_process_working_directories(self):
        out = "p1\nfcwd\nn/\np2\nfcwd\nn/Users/me/it's here\n"
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, out, "")):
            self.assertEqual(ccs.busy_dirs(), {"/", "/Users/me/it's here"})
        for result in (subprocess.CompletedProcess([], 1, "", "error"), OSError("missing")):
            with patch.object(ccs.subprocess, "run", side_effect=[result]):
                self.assertIsNone(ccs.busy_dirs())

    def test_prune_command_removes_an_unused_folder_and_keeps_one_in_use(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            unused, in_use = home / "2026-11-05-1", home / "2026-11-05-2"
            unused.mkdir()
            in_use.mkdir()
            holder = subprocess.Popen(["sleep", "30"], cwd=in_use)
            try:
                for folder in (unused, in_use):
                    subprocess.run([str(ROOT / "ccs"), "--prune", str(folder)], check=True,
                                   env={**os.environ, "HOME": str(home)}, capture_output=True)
            finally:
                holder.kill()
                holder.wait()
            self.assertFalse(unused.exists())
            self.assertTrue(in_use.exists())

    def test_new_session_uses_configured_root_and_cleans_up_on_failure(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"CCS_NEW_DIR": str(Path(directory) / "it's mine")}), \
                patch.object(ccs, "load_index", return_value={}), \
                patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            path, error = ccs.new_session()
            self.assertIsNone(error)
            self.assertEqual(path.parent, Path(directory) / "it's mine")
            self.assertTrue(path.is_dir())
            self.assertEqual(shlex.split(run.call_args.args[0][-1]),
                             ["cd", str(path), "&&", "claude;", "cd;", str(ROOT / "ccs"), "--prune", str(path)])
            run.return_value = subprocess.CompletedProcess([], 1, "", "Permission denied")
            path, error = ccs.new_session()
            self.assertEqual(error, "Permission denied")
            self.assertFalse(path.exists())

    def test_default_root(self):
        with patch.dict(os.environ, {"HOME": "/u", "CCS_NEW_DIR": ""}):
            self.assertEqual(ccs.new_root(), Path("/u/ccs-sessions"))


if __name__ == "__main__":
    unittest.main()
