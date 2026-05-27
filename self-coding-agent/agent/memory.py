from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

from .config import AGENT_DIR


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def journal_path(cfg: Dict[str, Any]) -> Path:
    return AGENT_DIR / "state" / "journal.jsonl"


def evolution_path(cfg: Dict[str, Any]) -> Path:
    rel = (cfg.get("memory") or {}).get("evolution_path", "state/evolution.json")
    return (AGENT_DIR / rel).resolve()


def append_journal(cfg: Dict[str, Any], record: Dict[str, Any]) -> None:
    p = journal_path(cfg)
    p.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with p.open("a", encoding="utf-8") as f:
        f.write(line)


def tail_journal(cfg: Dict[str, Any], max_lines: int) -> str:
    p = journal_path(cfg)
    if not p.is_file():
        return ""
    lines: List[str] = []
    with p.open("r", encoding="utf-8") as f:
        for line in f:
            lines.append(line.rstrip("\n"))
    tail = lines[-max_lines:] if max_lines > 0 else lines
    return "\n".join(tail)


def load_evolution(cfg: Dict[str, Any]) -> Dict[str, Any]:
    p = evolution_path(cfg)
    if not p.is_file():
        return {
            "version": 1,
            "created": _utc_now_iso(),
            "best": None,
            "notes": [],
        }
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_evolution(cfg: Dict[str, Any], data: Dict[str, Any]) -> None:
    p = evolution_path(cfg)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def maybe_update_evolution(
    cfg: Dict[str, Any],
    iteration: int,
    backtest_stdout: str,
) -> str:
    """
    Heuristic: if stdout mentions profit / return, store snippet for self-improve prompts.
    """
    ev = load_evolution(cfg)
    snippet = backtest_stdout[-6000:] if backtest_stdout else ""
    note = {
        "t": _utc_now_iso(),
        "iteration": iteration,
        "stdout_tail": snippet[-2000:],
    }
    notes = ev.get("notes") or []
    notes.append(note)
    ev["notes"] = notes[-200:]
    save_evolution(cfg, ev)
    return json.dumps(note, ensure_ascii=False)
