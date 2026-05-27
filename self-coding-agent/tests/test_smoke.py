"""Smoke tests (no Ollama required). Run: python -m unittest discover -s tests -p 'test_*.py' -v"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from agent.config import load_config, workspace_path
from agent.tools import ToolExecutor, parse_model_json


class TestParseModelJson(unittest.TestCase):
    def test_fence(self):
        raw = """Here you go:
```json
{"reflection": "x", "actions": []}
```
"""
        d = parse_model_json(raw)
        self.assertEqual(d["reflection"], "x")
        self.assertEqual(d["actions"], [])

    def test_prose_then_braces(self):
        raw = 'Thought: ok\n{"reflection": "r", "actions": [{"type": "list_dir", "path": "frontline/units"}]} trailing'
        d = parse_model_json(raw)
        self.assertEqual(d["reflection"], "r")
        self.assertEqual(len(d["actions"]), 1)


class TestToolExecutor(unittest.TestCase):
    def test_list_dir(self):
        cfg = load_config()
        ws = workspace_path(cfg)
        ex = ToolExecutor(cfg, ws)
        r = ex.execute({"type": "list_dir", "path": "frontline/units"})
        self.assertTrue(r.get("ok"))
        self.assertIn("entries", r)
        self.assertIsInstance(r["entries"], list)

    def test_disallowed_path(self):
        cfg = load_config()
        ws = workspace_path(cfg)
        ex = ToolExecutor(cfg, ws)
        from agent.tools import ToolError

        with self.assertRaises(ToolError):
            ex.execute({"type": "read_file", "path": "README.md"})


if __name__ == "__main__":
    unittest.main()
