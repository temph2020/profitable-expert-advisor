"""
RSIScalpingNVDA — bar backtest mirroring main.mq5 inputs.

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
from indicator_utils import calculate_adx, calculate_atr, calculate_dmi, calculate_ema, calculate_rsi  # noqa: E402

STRATEGY_ID = "RSIScalpingNVDA"


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

  trades = report.trades_list
  if not trades:
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.text(0.5, 0.5, "No trades in backtest window", ha="center", va="center", fontsize=14)
    ax.axis("off")
    fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
    plt.close(fig)
    return

  df = pd.DataFrame(rows)
  df["close_time"] = pd.to_datetime(df["close_time"])
  df = df.sort_values("close_time")
  bal0 = report.params.get("initial_balance", 10_000.0)
  if report.equity_curve is not None and len(report.equity_curve) > 1:
    eq = report.equity_curve
  else:
    eq = pd.Series(bal0 + df["profit"].cumsum().values, index=df["close_time"])
  equity_times = eq.index
  equity = eq

  fig = plt.figure(figsize=(14, 10))
  gs = fig.add_gridspec(3, 2, height_ratios=[2, 1.2, 1.2])
  ax1 = fig.add_subplot(gs[0, :])
  ax1.plot(equity_times, equity, lw=1.8)
  ax1.axhline(bal0, color="gray", ls="--")
  ax1.set_title("Equity Curve")
  ax1.grid(alpha=0.3)
  ax2 = fig.add_subplot(gs[1, 0])
  dd = (equity - equity.cummax()) / equity.cummax() * 100
  ax2.fill_between(equity_times, dd, 0, color="#d62728", alpha=0.35)
  ax2.set_title("Drawdown %")
  ax2.grid(alpha=0.3)
  ax3 = fig.add_subplot(gs[1, 1])
  df["month"] = df["close_time"].dt.to_period("M")
  monthly = df.groupby("month")["profit"].sum()
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
  plt.plot(equity_times, equity, lw=2)
  plt.title("Equity Curve")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(out_dir / "equity_curve.png", dpi=200, bbox_inches="tight")
  plt.close()

  plt.figure(figsize=(12, 5))
  plt.fill_between(equity_times, dd, 0, color="red", alpha=0.3)
  plt.plot(equity_times, dd, color="darkred")
  plt.title("Drawdown %")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(out_dir / "drawdown.png", dpi=200, bbox_inches="tight")
  plt.close()

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



@dataclass
class StrategyParams:
  rsi_period: int = 14
  rsi_overbought: float = 6
  rsi_oversold: float = 66
  rsi_target_buy: float = 98
  rsi_target_sell: float = 52
  bars_to_wait: int = 12
  lot_size: float = 5
  use_reversal_escape: bool = False
  reversal_atr_period: int = 14
  reversal_adverse_atr_mult: float = 1.5
  reversal_signs_required: int = 2
  reversal_rsi_velocity: float = 8.0
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)



def run_backtest(df, symbol, params: StrategyParams, costs, period_label, tf_label="H1"):
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  rsi = calculate_rsi(df["close"], params.rsi_period).to_numpy()
  atr = calculate_atr(df, params.reversal_atr_period).to_numpy()
  p = params.to_dict()

  def on_bar(i, st, open_pos, close):
    if i < 3 or np.isnan(rsi[i - 1]):
      return
    sig, prev, two = rsi[i - 1], rsi[i - 2], rsi[i - 3]
    mid = float(df["open"].iloc[i])
    hi, lo = float(df["high"].iloc[i]), float(df["low"].iloc[i])

    if st.side and params.use_reversal_escape:
      a = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
      if a > 0:
        signs = 0
        if st.side == "BUY":
          if st.entry - lo >= params.reversal_adverse_atr_mult * a:
            signs += 1
          if sig - prev >= params.reversal_rsi_velocity:
            signs += 1
        else:
          if hi - st.entry >= params.reversal_adverse_atr_mult * a:
            signs += 1
          if prev - sig >= params.reversal_rsi_velocity:
            signs += 1
        if signs >= params.reversal_signs_required:
          close(i, mid, "reversal_escape")
          return

    if st.side == "BUY":
      if sig < params.rsi_oversold:
        st.bars_against = st.bars_against + 1 if st.rsi_against else 1
        st.rsi_against = True
        if st.bars_against >= params.bars_to_wait:
          close(i, mid, "rsi_against")
      else:
        st.rsi_against = False
        st.bars_against = 0
        if sig >= params.rsi_target_buy:
          close(i, mid, "target")
    elif st.side == "SELL":
      if sig > params.rsi_overbought:
        st.bars_against = st.bars_against + 1 if st.rsi_against else 1
        st.rsi_against = True
        if st.bars_against >= params.bars_to_wait:
          close(i, mid, "rsi_against")
      else:
        st.rsi_against = False
        st.bars_against = 0
        if sig <= params.rsi_target_sell:
          close(i, mid, "target")
    else:
      if two <= params.rsi_oversold and prev > params.rsi_oversold:
        open_pos(i, "BUY", mid)
      elif two >= params.rsi_overbought and prev < params.rsi_overbought:
        open_pos(i, "SELL", mid)

  return run_single_position(
    df, symbol, point, costs, params.lot_size, STRATEGY_ID, tf_label, period_label, p, params.initial_balance, on_bar
  )



def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest")
  p.add_argument("--symbol", default="XAUUSD")
  p.add_argument("--start", default="2023-01-01")
  p.add_argument("--end", default="2026-01-01")
  p.add_argument("--balance", type=float, default=10_000.0)
  p.add_argument("--lot", type=float, default=0.1)
  p.add_argument("--timeframe", default="H1", choices=["M20", "H1"])
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
    tf_map = {"M20": mt5.TIMEFRAME_M20, "H1": mt5.TIMEFRAME_H1}
    tf = tf_map[args.timeframe]
    print(f"Loading {symbol} {args.timeframe} bars ...")
    df = load_bars(symbol, tf, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df, symbol, params, costs, period_label, args.timeframe)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
