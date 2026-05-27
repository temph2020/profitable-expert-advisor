from __future__ import annotations

import json
import subprocess
import re
from pathlib import Path
from typing import Any, Dict
from urllib.parse import urlparse

import httpx

from .config import AGENT_DIR


class ToolError(Exception):
    pass


def _norm_rel(p: str) -> str:
    return p.replace("\\", "/").strip().lstrip("/")


class ToolExecutor:
    def __init__(self, cfg: Dict[str, Any], workspace: Path):
        self.cfg = cfg
        self.workspace = workspace
        prefixes = cfg.get("allowed_path_prefixes") or []
        self.prefixes = tuple(_norm_rel(x) for x in prefixes)

    def _resolve_under_workspace(self, rel: str) -> Path:
        rel_n = _norm_rel(rel)
        if rel_n.startswith("..") or "/../" in f"/{rel_n}/":
            raise ToolError("Path traversal is not allowed")
        path = (self.workspace / rel_n).resolve()
        try:
            path.relative_to(self.workspace)
        except ValueError as e:
            raise ToolError("Path escapes workspace") from e
        ok = any(
            rel_n == pref.rstrip("/") or rel_n.startswith(pref.rstrip("/") + "/")
            for pref in self.prefixes
        )
        if not ok:
            raise ToolError(f"Path not allowed by allowed_path_prefixes: {rel_n}")
        return path

    def execute(self, action: Dict[str, Any]) -> Dict[str, Any]:
        t = action.get("type")
        if t == "read_file":
            return self._read_file(str(action.get("path", "")))
        if t == "write_file":
            return self._write_file(str(action.get("path", "")), str(action.get("content", "")))
        if t == "list_dir":
            return self._list_dir(str(action.get("path", "")))
        if t == "fetch_url":
            return self._fetch_url(str(action.get("url", "")))
        if t == "run_backtest":
            return self._run_backtest(action)
        if t == "run_python":
            return self._run_python(action)
        raise ToolError(f"Unknown action type: {t!r}")

    def _read_file(self, rel: str) -> Dict[str, Any]:
        path = self._resolve_under_workspace(rel)
        if not path.is_file():
            return {"ok": False, "error": f"Not a file: {rel}"}
        text = path.read_text(encoding="utf-8", errors="replace")
        if len(text) > 120_000:
            text = text[:120_000] + "\n\n...[truncated]..."
        return {"ok": True, "path": rel, "content": text}

    def _write_file(self, rel: str, content: str) -> Dict[str, Any]:
        path = self._resolve_under_workspace(rel)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        cursor_cfg = (self.cfg.get("cursor") or {})
        if cursor_cfg.get("open_in_cursor_after_write"):
            try:
                subprocess.Popen(
                    ["cursor", str(path)],
                    cwd=str(self.workspace),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass
        return {"ok": True, "path": rel, "bytes": len(content.encode("utf-8"))}

    def _list_dir(self, rel: str) -> Dict[str, Any]:
        path = self._resolve_under_workspace(rel)
        if not path.is_dir():
            return {"ok": False, "error": f"Not a directory: {rel}"}
        names = sorted(p.name for p in path.iterdir())
        return {"ok": True, "path": rel, "entries": names[:500]}

    def _fetch_url(self, url: str) -> Dict[str, Any]:
        web = self.cfg.get("web") or {}
        timeout = float(web.get("fetch_timeout_seconds", 25))
        max_bytes = int(web.get("max_response_bytes", 400_000))
        u = urlparse(url)
        if u.scheme not in ("http", "https") or not u.netloc:
            raise ToolError("Only http(s) URLs with a host are allowed")
        with httpx.Client(timeout=timeout, follow_redirects=True) as client:
            r = client.get(url, headers={"User-Agent": "self-coding-agent/1.0"})
            r.raise_for_status()
            body = r.content[:max_bytes]
        ctype = r.headers.get("content-type", "")
        text = body.decode("utf-8", errors="replace")
        if len(text) > 80_000:
            text = text[:80_000] + "\n\n...[truncated]..."
        return {"ok": True, "url": url, "status": r.status_code, "content_type": ctype, "text": text}

    def _run_backtest(self, action: Dict[str, Any]) -> Dict[str, Any]:
        mt5cfg = self.cfg.get("mt5_backtest") or {}
        if not mt5cfg.get("enabled", True):
            return {"ok": False, "skipped": True, "reason": "mt5_backtest.enabled is false"}
        py = str(mt5cfg.get("python_executable", "python"))
        script_rel = str(mt5cfg.get("script_relative", "backtesting/MT5/run_backtest.py"))
        script = (self.workspace / _norm_rel(script_rel)).resolve()
        try:
            script.relative_to(self.workspace)
        except ValueError as e:
            raise ToolError("Backtest script outside workspace") from e
        if not script.is_file():
            return {"ok": False, "error": f"Missing script: {script}"}

        strategy = str(action.get("strategy") or mt5cfg.get("default_strategy", "RSIReversalStrategy"))
        symbol = str(action.get("symbol") or mt5cfg.get("default_symbol", "XAUUSD"))
        start = str(action.get("start") or mt5cfg.get("default_start", "2023-01-01"))
        end = str(action.get("end") or mt5cfg.get("default_end", "2024-01-01"))
        timeframe = str(action.get("timeframe") or "H1")

        cmd = [
            py,
            str(script),
            "--strategy",
            strategy,
            "--symbol",
            symbol,
            "--start",
            start,
            "--end",
            end,
            "--timeframe",
            timeframe,
        ]
        proc = subprocess.run(
            cmd,
            cwd=str(self.workspace),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        out = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
        return {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout[-20000:] if proc.stdout else "",
            "stderr": proc.stderr[-20000:] if proc.stderr else "",
        }

    def _run_python(self, action: Dict[str, Any]) -> Dict[str, Any]:
        rel = _norm_rel(str(action.get("script_relative", "")))
        if not rel.endswith(".py"):
            raise ToolError("run_python only supports .py scripts")
        script = self._resolve_under_workspace(rel)
        if not script.is_file():
            return {"ok": False, "error": f"Missing script: {rel}"}
        args = action.get("args") or []
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ToolError("args must be a list of strings")
        py = str((self.cfg.get("mt5_backtest") or {}).get("python_executable", "python"))
        cmd = [py, str(script), *args]
        proc = subprocess.run(
            cmd,
            cwd=str(self.workspace),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": (proc.stdout or "")[-20000:],
            "stderr": (proc.stderr or "")[-20000:],
        }


def parse_model_json(text: str) -> Dict[str, Any]:
    s = text.strip().lstrip("\ufeff")
    fence = re.search(r"```(?:json)?\s*([\s\S]*?)\s*```", s, re.IGNORECASE)
    if fence:
        s = fence.group(1).strip()
    if not s.lstrip().startswith("{"):
        start = s.find("{")
        end = s.rfind("}")
        if start != -1 and end != -1 and end > start:
            s = s[start : end + 1]
    return json.loads(s)
