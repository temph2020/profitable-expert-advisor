#!/usr/bin/env python3
"""
Full pipeline: per-symbol param search -> MT5 validate -> sync enabled -> MT5 re-run enabled set.

Usage:
  python run_full_pipeline.py
  python run_full_pipeline.py --skip-python-opt   # MT5 only on existing params
  python run_full_pipeline.py --mt5-only-enabled  # second pass after sync
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent


def run(cmd: list[str]) -> None:
    print(f"\n>>> {' '.join(cmd)}\n")
    subprocess.run(cmd, cwd=LAB, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="portfolio_symbols_expanded.json")
    ap.add_argument("--trials", type=int, default=280)
    ap.add_argument("--from", dest="from_date", default="2020.01.01")
    ap.add_argument("--to", dest="to_date", default="2026.01.01")
    ap.add_argument("--skip-python-opt", action="store_true")
    ap.add_argument("--mt5-only-enabled", action="store_true", help="after sync, re-test enabled symbols only")
    args = ap.parse_args()

    py = sys.executable
    cfg = LAB / args.config

    if not args.skip_python_opt:
        run([py, "run_optimize_portfolio.py", "--config", str(cfg), "--trials", str(args.trials), "--min-trades", "8"])

    run([py, "run_mt5_portfolio.py", "--params", "portfolio_params.json", "--from", args.from_date, "--to", args.to_date])

    run([py, "sync_portfolio_from_mt5.py", "--min-pf", "1.0", "--min-trades", "8"])

    run([py, "run_mt5_portfolio.py", "--params", "portfolio_params.json", "--enabled-only", "--from", args.from_date, "--to", args.to_date])

    run([py, "generate_mt5_portfolio_report.py"])

    mt5 = json.loads((LAB / "best_run" / "mt5_results.json").read_text(encoding="utf-8"))
    params = json.loads((LAB / "portfolio_params.json").read_text(encoding="utf-8"))
    en = [m for m in params["members"] if m.get("enabled")]
    trades = sum(m.get("mt5_metrics", {}).get("total_trades", 0) for m in en)
    net = sum(m.get("mt5_metrics", {}).get("net_profit", 0) for m in en)
    total = mt5["portfolio"]["total_trades"]

    print("\n=== PIPELINE DONE ===")
    print(f"  MT5 tested (all): {total} trades")
    print(f"  MT5 enabled ({len(en)} syms): {trades} trades  net=${net:,.2f}")
    print(f"  Target 2000+: {'YES' if trades >= 2000 else 'NO — add symbols or run MT5 genetic optimize'}")
    print(f"  Report: best_run/MT5_PORTFOLIO_REPORT.md")


if __name__ == "__main__":
    main()
