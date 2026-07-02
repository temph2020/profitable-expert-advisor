"""
RSIReversalAsianEURUSD — bar backtest mirroring main.mq5 inputs.

Outputs in this folder:
  backtest_report.json, trades.csv, report.png,
  equity_curve.png, drawdown.png, monthly_returns.png,
  pnl_distribution.png, exit_reasons.png

Usage:
  python run_backtest.py
  python run_backtest.py --start 2021-01-01 --end 2026-01-01
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import MetaTrader5 as mt5
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))

from cluster_audit.backtest_core import (  # noqa: E402
    BacktestReport,
    CostModel,
    load_bars,
    resolve_symbol,
    run_single_position,
)
from indicator_utils import calculate_rsi  # noqa: E402

STRATEGY_ID = "RSIReversalAsianAUDUSD"


@dataclass
class StrategyParams:
  rsi_period: int = 28
  overbought_level: float = 68
  oversold_level: float = 30
  rsi_exit_level: float = 48
  close_outside_session: bool = True
  use_rsi_exit: bool = True
  max_duration_hours: int = 340
  max_spread_points: int = 1000
  lot_size: float = 0.2
  asian_session_start: int = 0
  asian_session_end: int = 8
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)


def save_reports(report: BacktestReport, out_dir: Path) -> None:
  rows = [
    {
      "side": t.side,
      "open_time": t.open_time,
      "close_time": t.close_time,
      "open_price": t.open_price,
      "close_price": t.close_price,
      "volume": t.volume,
      "profit": t.profit,
      "bars_held": t.bars_held,
      "exit_reason": t.exit_reason,
    }
    for t in report.trades_list
  ]
  pd.DataFrame(rows).to_csv(out_dir / "trades.csv", index=False)
  with open(out_dir / "backtest_report.json", "w", encoding="utf-8") as f:
    json.dump(report.to_dict(), f, indent=2, ensure_ascii=False)

  bal0 = report.params.get("initial_balance", 10_000.0)
  if report.equity_curve is not None and len(report.equity_curve) > 1:
    eq_s = report.equity_curve
    eq_times = eq_s.index
    equity = eq_s.values
  elif report.trades_list:
    df = pd.DataFrame(rows)
    df["close_time"] = pd.to_datetime(df["close_time"])
    df = df.sort_values("close_time")
    eq_times = df["close_time"]
    equity = bal0 + df["profit"].cumsum().values
  else:
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.text(0.5, 0.5, "No trades in backtest window", ha="center", va="center", fontsize=14)
    ax.axis("off")
    fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
    plt.close(fig)
    return

  dd = (equity - np.maximum.accumulate(equity)) / np.maximum.accumulate(equity) * 100

  fig = plt.figure(figsize=(14, 10))
  gs = fig.add_gridspec(3, 2, height_ratios=[2, 1.2, 1.2])
  ax1 = fig.add_subplot(gs[0, :])
  ax1.plot(eq_times, equity, lw=1.8)
  ax1.axhline(bal0, color="gray", ls="--")
  ax1.set_title("Equity Curve")
  ax1.grid(alpha=0.3)
  ax2 = fig.add_subplot(gs[1, 0])
  ax2.fill_between(eq_times, dd, 0, color="#d62728", alpha=0.35)
  ax2.set_title("Drawdown %")
  ax2.grid(alpha=0.3)
  if report.trades_list:
    df = pd.DataFrame(rows)
    df["close_time"] = pd.to_datetime(df["close_time"])
    df["month"] = df["close_time"].dt.to_period("M")
    monthly = df.groupby("month")["profit"].sum()
    ax3 = fig.add_subplot(gs[1, 1])
    ax3.bar(range(len(monthly)), monthly.values, color=["#2ca02c" if v >= 0 else "#d62728" for v in monthly])
    ax3.set_title("Monthly PnL")
    ax3.axhline(0, color="black", lw=0.6)
    ax4 = fig.add_subplot(gs[2, 0])
    ax4.hist(df["profit"], bins=30, color="#9467bd", alpha=0.85)
    ax4.axvline(0, color="black")
    ax4.set_title("Trade PnL Distribution")
    ax5 = fig.add_subplot(gs[2, 1])
    rc = df["exit_reason"].value_counts()
    ax5.bar(rc.index.astype(str), rc.values, color="#ff7f0e")
    ax5.set_title("Exit Reasons")
  fig.suptitle(
    f"{STRATEGY_ID} — Net ${report.net_profit:,.2f} | Trades {report.total_trades} | "
    f"WR {report.win_rate:.1f}% | PF {report.profit_factor:.2f} | MaxDD {report.max_drawdown_pct:.2f}%",
    fontsize=11,
  )
  fig.tight_layout(rect=[0, 0, 1, 0.96])
  fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
  plt.close(fig)

  plt.figure(figsize=(12, 5))
  plt.plot(eq_times, equity, lw=2)
  plt.title("Equity Curve")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(out_dir / "equity_curve.png", dpi=200, bbox_inches="tight")
  plt.close()

  plt.figure(figsize=(12, 5))
  plt.fill_between(eq_times, dd, 0, color="red", alpha=0.3)
  plt.plot(eq_times, dd, color="darkred")
  plt.title("Drawdown %")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(out_dir / "drawdown.png", dpi=200, bbox_inches="tight")
  plt.close()

  if report.trades_list:
    df = pd.DataFrame(rows)
    df["close_time"] = pd.to_datetime(df["close_time"])
    df["month"] = df["close_time"].dt.to_period("M")
    monthly = df.groupby("month")["profit"].sum()
    plt.figure(figsize=(12, 5))
    plt.bar(range(len(monthly)), monthly.values, color=["green" if v >= 0 else "red" for v in monthly], alpha=0.75)
    plt.title("Monthly PnL")
    plt.axhline(0, color="black")
    plt.grid(alpha=0.3, axis="y")
    plt.tight_layout()
    plt.savefig(out_dir / "monthly_returns.png", dpi=200, bbox_inches="tight")
    plt.close()

    plt.figure(figsize=(10, 5))
    plt.hist(df["profit"], bins=40, color="#6a5acd", alpha=0.85)
    plt.axvline(0, color="black")
    plt.title("Per-Trade PnL Distribution")
    plt.tight_layout()
    plt.savefig(out_dir / "pnl_distribution.png", dpi=200, bbox_inches="tight")
    plt.close()

    if report.exit_reason_breakdown:
      labels = list(report.exit_reason_breakdown.keys())
      counts = [report.exit_reason_breakdown[k]["count"] for k in labels]
      plt.figure(figsize=(8, 5))
      plt.bar(labels, counts, color="#e377c2")
      plt.title("Exit Reason Counts")
      plt.tight_layout()
      plt.savefig(out_dir / "exit_reasons.png", dpi=200, bbox_inches="tight")
      plt.close()


def run_backtest(df: pd.DataFrame, symbol: str, params: StrategyParams, costs: CostModel, period_label: str) -> BacktestReport:
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.00001
  rsi = calculate_rsi(df["close"], params.rsi_period).to_numpy()
  p = params.to_dict()
  session_close_done = False

  def in_session(ts) -> bool:
    return params.asian_session_start <= ts.hour < params.asian_session_end

  def on_bar(i, st, open_pos, close):
    nonlocal session_close_done
    if i < params.rsi_period + 2 or np.isnan(rsi[i - 1]) or np.isnan(rsi[i - 2]):
      return
    ts = df.index[i]
    prev, cur = float(rsi[i - 2]), float(rsi[i - 1])
    mid = float(df["open"].iloc[i])

    if not in_session(ts):
      if st.side and params.close_outside_session and not session_close_done:
        close(i, mid, "session")
        session_close_done = True
      return

    session_close_done = False

    if costs.spread_points > params.max_spread_points:
      return

    if st.side:
      hours_held = (ts - pd.Timestamp(st.entry_time)).total_seconds() / 3600.0
      if hours_held > params.max_duration_hours:
        close(i, mid, "timeout")
        return
      if params.use_rsi_exit:
        el = params.rsi_exit_level
        if st.side == "BUY" and prev < el <= cur:
          close(i, mid, "rsi_exit")
          return
        if st.side == "SELL" and prev > el >= cur:
          close(i, mid, "rsi_exit")
          return
      return

    if prev < params.overbought_level <= cur:
      open_pos(i, "SELL", mid)
    elif prev > params.oversold_level >= cur:
      open_pos(i, "BUY", mid)

  return run_single_position(
    df, symbol, point, costs, params.lot_size,
    STRATEGY_ID, "M15", period_label, p, params.initial_balance, on_bar, bar_seconds=900,
  )


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest")
  p.add_argument("--symbol", default="AUDUSD")
  p.add_argument("--start", default="2021-01-01")
  p.add_argument("--end", default="2026-01-01")
  p.add_argument("--balance", type=float, default=10_000.0)
  return p.parse_args()


def main() -> None:
  args = parse_args()
  out_dir = Path(__file__).resolve().parent
  params = make_params(args.balance)
  if not mt5.initialize():
    raise SystemExit("MetaTrader5 initialize() failed")
  try:
    symbol = resolve_symbol(args.symbol)
    start = datetime.fromisoformat(args.start)
    end = datetime.fromisoformat(args.end)
    period_label = f"{args.start}_{args.end}"
    print(f"Loading {symbol} M15 bars ...")
    df = load_bars(symbol, mt5.TIMEFRAME_M15, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df, symbol, params, costs, period_label)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
