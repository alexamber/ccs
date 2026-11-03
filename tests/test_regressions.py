import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_ccs import ccs, session


class Window:
    """Reject out-of-bounds draws rather than swallowing curses errors in a mock."""
    def __init__(self, height=24, width=80, keys=()):
        self.height, self.width = height, width
        self.keys = iter(keys)
        self.text = []

    def getmaxyx(self):
        return self.height, self.width

    def addnstr(self, y, x, text, limit, attr=0):
        assert 0 <= y < self.height and 0 <= x < self.width
        assert 0 < limit <= self.width - x
        self.text.append(text[:limit])

    def erase(self):
        self.text = []

    def refresh(self):
        pass

    def timeout(self, delay):
        pass

    def get_wch(self):
        return next(self.keys)


class RegressionTest(unittest.TestCase):
    def test_nonzero_or_malformed_live_list_cannot_authorize_resume(self):
        for code, output in [(1, "[]"), (0, "{}"), (0, "[1]"), (0, '[{"sessionId": 1}]'), (0, "null")]:
            with self.subTest(code=code, output=output), patch.object(
                ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output, "")
            ):
                self.assertIsNone(ccs.open_sessions())

    def test_attach_matching_does_not_focus_a_session_with_a_similar_name(self):
        processes = "1 0 ttys001 claude attach abc-other\n2 0 ttys002 claude attach abc\n"
        with patch.object(ccs.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, processes, "")):
            self.assertEqual(ccs.candidate_ttys(session("abc"), {}), ["ttys002"])

    def test_metadata_accepts_json_spacing_and_legacy_human_prompts(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "session.jsonl"
            records = [
                {"cwd": "/tmp/work", "type": "user", "message": {"content": "My question"}},
                {"type": "user", "isMeta": True, "message": {"content": "Injected instruction"}},
                {"type": "cost-state", "totalCostUSD": "invalid"},
                {"type": "custom-title", "customTitle": "Title\n with control\x1b"},
            ]
            transcript.write_text("\n".join(json.dumps(rec) for rec in records))
            metadata = ccs.scan_transcript(transcript)
            self.assertEqual(metadata["cwd"], "/tmp/work")
            self.assertEqual(metadata["title"], "Title with control")
            self.assertEqual(metadata["prompts"], "My question")
            self.assertEqual(metadata["turns"], 1)
            self.assertIsNone(metadata["cost"])

    def test_cache_recovers_from_valid_json_of_the_wrong_shape_and_prunes_deleted_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "projects/example"
            project.mkdir(parents=True)
            transcript = project / "saved.jsonl"
            transcript.write_text('{"cwd":"/tmp/work","type":"custom-title","customTitle":"Hi"}\n')
            cache = root / "cache.json"
            cache.write_text("[]")
            with patch.object(ccs, "CACHE", cache), patch.object(ccs, "PROJECTS", root / "projects"):
                self.assertIn("saved", ccs.load_index(0))
                self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
                cached_mtime = cache.stat().st_mtime_ns
                ccs.load_index(0)
                self.assertEqual(cache.stat().st_mtime_ns, cached_mtime)
                transcript.unlink()
                self.assertEqual(ccs.load_index(0), {})
                self.assertEqual(json.loads(cache.read_text()), {})

    def test_narrow_rows_and_confirmation_stay_in_bounds(self):
        colors = {key: 0 for key in ("busy", "idle", "closed", "unknown", "large")}
        for width in (12, 24, 30, 80):
            win = Window(height=6, width=width, keys=["\n"])
            row = {"depth": 50, "session": session(title="Long title" * 20, turns=20)}
            ccs.draw_row(win, 2, width, row, True, colors)
            ccs.draw_header(win, width, [session(unknown=True)], False, 7, 5)
            self.assertEqual(ccs.confirm_large(win, row["session"], colors), "fresh")

    def test_watch_refreshes_even_while_typing(self):
        now = [0]
        win = Window()
        def key():
            if now[0] == 0:
                now[0] = 2
                return "a"
            raise KeyboardInterrupt
        win.get_wch = key
        with patch.object(ccs.curses, "curs_set"), patch.object(ccs.curses, "use_default_colors"), \
                patch.object(ccs.curses, "init_pair"), patch.object(ccs.curses, "color_pair", return_value=0), \
                patch.object(ccs.time, "monotonic", side_effect=lambda: now[0]), \
                patch.object(ccs, "collect", return_value=[]) as collect:
            with self.assertRaises(KeyboardInterrupt):
                ccs.ui(win, 7, False, watch=1)
            self.assertEqual(collect.call_count, 2)

    def test_hotkey_setup_is_idempotent_and_preserves_custom_config(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(ccs.Path, "home", return_value=Path(directory)):
            config = Path(directory) / ".hammerspoon"
            config.mkdir()
            init = config / "init.lua"
            init.write_text('-- Personal config\nprint("hello")\n')
            with patch("builtins.print"):
                ccs.install_hotkey()
                ccs.install_hotkey()
            self.assertEqual(init.read_text().count('require("ccs")'), 1)
            self.assertIn('print("hello")', init.read_text())
            self.assertEqual(len(list(config.glob("init.lua.backup-*"))), 1)
            self.assertTrue((config / "ccs.lua").is_file())
            custom = 'require("ccs").start({ key = "k" })\n'
            init.write_text(custom)
            with patch("builtins.print"):
                ccs.install_hotkey()
            self.assertEqual(init.read_text(), custom)


if __name__ == "__main__":
    unittest.main()
