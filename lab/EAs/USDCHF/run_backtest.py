"""
USDCHF Playbook — Python bar backtest via MT5 live data.

Usage:
  python run_backtest.py
  python run_backtest.py --start 2022-01-01 --end 2026-01-01
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import MetaTrader5 as mt5
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from strategy_core import PlaybookParams, STRATEGY_ID, build_market, pip_size, simulate  # noqa: E402


def save_reports(result, params: PlaybookParams, df: pd.DataFrame, out_dir: Path) -> None:
    rows = [
        {
            "side": t["side"],
            "open_time": df.index[t["open_i"]],
            "close_time": df.index[t["close_i"]],
            "profit": t["profit"],
            "exit_reason": t["exit_reason"],
        }
        for t in result.trades
    ]
    pd.DataFrame(rows).to_csv(out_dir / "trades.csv", index=False)
    report = {
        "strategy_id": STRATEGY_ID,
        "symbol": "USDCHF",
        "net_profit": result.net_profit,
        "total_trades": result.total_trades,
        "win_rate": result.win_rate,
        "profit_factor": result.profit_factor,
        "max_drawdown_pct": result.max_drawdown_pct,
        "sharpe": result.sharpe,
        "params": params.to_dict(),
    }
    with open(out_dir / "backtest_report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    if not result.trades:
        fig, ax = plt.subplots(figsize=(10, 4))
        ax.text(0.5, 0.5, "No trades", ha="center", va="center")
        ax.axis("off")
        fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
        plt.close(fig)
        return

    tdf = pd.DataFrame(rows).sort_values("close_time")
    bal0 = params.initial_balance
    eq = bal0 + tdf["profit"].cumsum()
    fig, axes = plt.subplots(2, 1, figsize=(12, 8))
    axes[0].plot(tdf["close_time"], eq, lw=1.8)
    axes[0].set_title(f"{STRATEGY_ID} Equity")
    axes[0].grid(alpha=0.3)
    axes[1].hist(tdf["profit"], bins=30, color="#6a5acd", alpha=0.85)
    axes[1].axvline(0, color="black")
    axes[1].set_title("Trade PnL")
    fig.suptitle(
        f"Net ${result.net_profit:,.0f} | Trades {result.total_trades} | "
        f"PF {result.profit_factor:.2f} | WR {result.win_rate:.1f}% | DD {result.max_drawdown_pct:.1f}%"
    )
    fig.tight_layout()
    fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=f"{STRATEGY_ID} backtest")
    p.add_argument("--symbol", default="USDCHF")
    p.add_argument("--start", default="2022-01-01")
    p.add_argument("--end", default="2026-01-01")
    p.add_argument("--balance", type=float, default=10_000.0)
    p.add_argument("--params", default="", help="JSON file with PlaybookParams overrides")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(__file__).resolve().parent
    params = PlaybookParams(initial_balance=args.balance)
    if args.params:
        overrides = json.loads(Path(args.params).read_text(encoding="utf-8"))
        params = PlaybookParams(**{**params.to_dict(), **overrides})

    if not mt5.initialize():
        raise SystemExit("MT5 initialize() failed")
    try:
        symbol = resolve_symbol(args.symbol)
        df = load_bars(symbol, mt5.TIMEFRAME_M15, datetime.fromisoformat(args.start), datetime.fromisoformat(args.end))
        costs = CostModel.for_symbol(symbol)
        pip = pip_size(symbol)
        point = float(mt5.symbol_info(symbol).point)
        print(f"Loaded {len(df)} M15 bars for {symbol}")
        md = build_market(df, params)
        result = simulate(md, symbol, params, costs, pip, point)
        save_reports(result, params, df, out_dir)
        print(
            f"Net: ${result.net_profit:,.2f} | Trades: {result.total_trades} | "
            f"PF: {result.profit_factor:.2f} | WR: {result.win_rate:.1f}% | DD: {result.max_drawdown_pct:.1f}%"
        )
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
