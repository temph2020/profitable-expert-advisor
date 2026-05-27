from __future__ import annotations

import json
import time
import traceback
from typing import Any, Dict, List

from .config import load_config, workspace_path
from .memory import append_journal, load_evolution, maybe_update_evolution, tail_journal
from .ollama_client import chat
from .tools import ToolExecutor, ToolError, parse_model_json


ACTION_SCHEMA = r"""
You must reply with ONLY a single raw JSON object (no markdown fences, no commentary) of this form:
{
  "reflection": "short reasoning",
  "actions": [
    {"type": "list_dir", "path": "frontline/units"},
    {"type": "read_file", "path": "relative/path/from/repo/root.mq5"},
    {"type": "write_file", "path": "self-coding-agent/generated/example.txt", "content": "file contents"},
    {"type": "fetch_url", "url": "https://..."},
    {"type": "run_backtest", "strategy": "RSIReversalStrategy", "symbol": "XAUUSD", "start": "2023-01-01", "end": "2024-01-01", "timeframe": "H1"},
    {"type": "run_python", "script_relative": "backtesting/MT5/test_setup.py", "args": []}
  ]
}

Rules:
- Paths are relative to the repository root and must stay under allowed prefixes.
- Prefer reading before writing; keep edits minimal and compile-friendly for MQL5.
- Use fetch_url for MQL5 documentation pages when unsure about APIs.
- run_backtest uses the repo's Python MT5 harness (MetaTrader 5 terminal must be installed/running).
- If you only need to think, use an empty actions list.
"""


def build_system_message(cfg: Dict[str, Any]) -> str:
    mission = str(cfg.get("mission") or "").strip()
    prefixes = cfg.get("allowed_path_prefixes") or []
    return (
        mission
        + "\n\nAllowed path prefixes (read/write/list):\n"
        + "\n".join(f"- {p}" for p in prefixes)
        + "\n\n"
        + ACTION_SCHEMA
    )


def build_user_message(
    iteration: int,
    last_results: str,
    journal_tail: str,
    evolution_hint: str,
) -> str:
    parts = [
        f"Iteration: {iteration}",
        "Previous tool results (JSON):\n```json\n"
        + last_results
        + "\n```",
    ]
    if journal_tail.strip():
        parts.append("Recent journal (tail):\n" + journal_tail)
    if evolution_hint.strip():
        parts.append("Evolution memory hint:\n" + evolution_hint)
    parts.append(
        "Plan the next improvements and output your JSON response. "
        "If this is iteration 1 and there is no parse error yet, prefer list_dir/read_file only; "
        "avoid run_backtest until you have read relevant code."
    )
    return "\n\n".join(parts)


def run_loop(
    *,
    max_iterations: int | None = None,
    model: str | None = None,
    sleep_seconds: float | None = None,
    mt5_backtest_enabled: bool | None = None,
) -> None:
    cfg = load_config()
    if mt5_backtest_enabled is not None:
        cfg.setdefault("mt5_backtest", {})["enabled"] = bool(mt5_backtest_enabled)
    ws = workspace_path(cfg)
    ex = ToolExecutor(cfg, ws)

    ollama = cfg.get("ollama") or {}
    base_url = str(ollama.get("base_url", "http://127.0.0.1:11434"))
    model_name = str(model or ollama.get("model", "llama3.2"))
    options = ollama.get("options") or {}

    loop_cfg = cfg.get("loop") or {}
    max_iters = int(max_iterations if max_iterations is not None else loop_cfg.get("max_iterations", 0))
    sleep_s = float(sleep_seconds if sleep_seconds is not None else loop_cfg.get("sleep_seconds", 2.0))
    err_limit = int(loop_cfg.get("consecutive_error_limit", 15))

    mem_cfg = cfg.get("memory") or {}
    journal_max = int(mem_cfg.get("journal_max_lines", 80))

    system = build_system_message(cfg)

    iteration = 0
    consecutive_errors = 0
    last_results_json = json.dumps({"info": "No previous tool results yet."})

    while True:
        iteration += 1
        if max_iters and iteration > max_iters:
            print(f"Stopping: reached max_iterations={max_iters}", flush=True)
            return

        ev = load_evolution(cfg)
        ev_notes = ev.get("notes") or []
        evolution_hint = ""
        if ev_notes:
            evolution_hint = json.dumps(ev_notes[-3:], ensure_ascii=False)

        journal_tail = tail_journal(cfg, journal_max)
        user = build_user_message(iteration, last_results_json, journal_tail, evolution_hint)

        messages: List[Dict[str, str]] = [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]

        try:
            raw = chat(base_url, model_name, messages, options=options)
            try:
                plan = parse_model_json(raw)
            except json.JSONDecodeError:
                tail = raw if len(raw) <= 4000 else raw[:4000] + "\n...[truncated]..."
                print("Model returned non-JSON; raw (truncated):\n" + tail + "\n---", flush=True)
                raise
            actions = plan.get("actions") or []
            if not isinstance(actions, list):
                raise ValueError("actions must be a list")

            results: List[Dict[str, Any]] = []
            backtest_blob = ""
            max_actions = 12
            for i, action in enumerate(actions[:max_actions]):
                if not isinstance(action, dict):
                    results.append({"ok": False, "error": "action must be an object"})
                    continue
                try:
                    r = ex.execute(action)
                    results.append({"action": action, "result": r})
                    if action.get("type") == "run_backtest":
                        stdout = str((r or {}).get("stdout") or "")
                        stderr = str((r or {}).get("stderr") or "")
                        backtest_blob = stdout + "\n" + stderr
                except ToolError as e:
                    results.append({"action": action, "result": {"ok": False, "error": str(e)}})
                except Exception as e:
                    results.append(
                        {"action": action, "result": {"ok": False, "error": f"{type(e).__name__}: {e}"}}
                    )

            last_results_json = json.dumps(
                {
                    "reflection": plan.get("reflection"),
                    "parsed_ok": True,
                    "tool_results": results,
                },
                ensure_ascii=False,
            )

            if backtest_blob.strip():
                maybe_update_evolution(cfg, iteration, backtest_blob)

            append_journal(
                cfg,
                {
                    "iteration": iteration,
                    "reflection": plan.get("reflection"),
                    "actions": actions[:max_actions],
                    "ok": True,
                },
            )

            consecutive_errors = 0
            print(
                f"[iter {iteration}] ok reflection={str(plan.get('reflection', ''))[:160]!r} "
                f"actions={len(actions[:max_actions])}",
                flush=True,
            )
            time.sleep(max(0.0, sleep_s))

        except KeyboardInterrupt:
            print("Interrupted by user; exiting.", flush=True)
            return
        except Exception as e:
            consecutive_errors += 1
            err_text = f"{type(e).__name__}: {e}\n{traceback.format_exc()[-4000:]}"
            print(err_text, flush=True)
            append_journal(
                cfg,
                {
                    "iteration": iteration,
                    "ok": False,
                    "error": err_text,
                },
            )
            last_results_json = json.dumps({"parse_or_run_error": err_text}, ensure_ascii=False)
            backoff = min(300.0, float(2 ** min(consecutive_errors, 8)))
            if consecutive_errors >= err_limit:
                print(
                    f"Many consecutive errors ({consecutive_errors}); sleeping {backoff:.1f}s before retry.",
                    flush=True,
                )
            time.sleep(backoff)
