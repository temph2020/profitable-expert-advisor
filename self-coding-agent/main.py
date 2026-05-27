from __future__ import annotations

import argparse
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from agent.loop import run_loop


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Self-coding agent (Ollama + sandboxed tools)")
    p.add_argument(
        "--max-iterations",
        type=int,
        default=None,
        help="Stop after N iterations (overrides config). Default: from config, 0 = infinite.",
    )
    p.add_argument("--model", type=str, default=None, help="Ollama model name (overrides config).")
    p.add_argument(
        "--sleep-seconds",
        type=float,
        default=None,
        help="Pause after each successful iteration (overrides config).",
    )
    p.add_argument(
        "--no-mt5-backtest",
        action="store_true",
        help="Disable subprocess MT5 Python backtests for this run.",
    )
    p.add_argument(
        "--mt5-backtest",
        action="store_true",
        help="Force-enable MT5 Python backtests for this run.",
    )
    return p.parse_args()


def main() -> None:
    args = _parse_args()
    mt5: bool | None = None
    if args.no_mt5_backtest and args.mt5_backtest:
        raise SystemExit("Use only one of --no-mt5-backtest / --mt5-backtest")
    if args.no_mt5_backtest:
        mt5 = False
    elif args.mt5_backtest:
        mt5 = True

    run_loop(
        max_iterations=args.max_iterations,
        model=args.model,
        sleep_seconds=args.sleep_seconds,
        mt5_backtest_enabled=mt5,
    )


if __name__ == "__main__":
    main()
