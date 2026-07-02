"""
USDJPYBuster — bar backtest mirroring main.mq5 inputs.

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
    Trade,
    build_report,
    calc_profit,
    fill_price,
    load_bars,
    resolve_symbol,
)
from indicator_utils import calculate_adx, calculate_atr, calculate_dmi, calculate_ema, calculate_rsi  # noqa: E402

STRATEGY_ID = "USDJPYBuster"


@dataclass
class SimState:
  side: str | None = None
  entry: float = 0.0
  entry_i: int = 0
  entry_time: object = None
  sl: float = 0.0
  tp: float = 0.0
  bars_against: int = 0
  rsi_against: bool = False


def run_single_position(
  df: pd.DataFrame,
  symbol: str,
  point: float,
  costs: CostModel,
  lot: float,
  tf_label: str,
  period_label: str,
  params: dict,
  initial_balance: float,
  on_bar,
) -> BacktestReport:
  trades: list[Trade] = []
  equity = [initial_balance]
  st = SimState()

  def close(i: int, mid: float, reason: str) -> None:
    nonlocal st
    if st.side is None:
      return
    exit_px = fill_price(mid, point, costs, st.side, entry=False)
    commission = costs.commission_per_lot * lot * 2.0
    profit = calc_profit(symbol, st.side, lot, st.entry, exit_px) - commission
    trades.append(
      Trade(
        side=st.side,
        open_time=st.entry_time,
        close_time=df.index[i],
        open_price=st.entry,
        close_price=exit_px,
        volume=lot,
        profit=profit,
        bars_held=i - st.entry_i,
        exit_reason=reason,
      )
    )
    equity.append(equity[-1] + profit)
    st = SimState()

  def open_pos(i: int, side: str, mid: float) -> None:
    nonlocal st
    st.side = side
    st.entry = fill_price(mid, point, costs, side, entry=True)
    st.entry_i = i
    st.entry_time = df.index[i]

  for i in range(1, len(df)):
    on_bar(i, st, open_pos, close)
    if len(equity) == len(trades) + 1:
      equity.append(equity[-1])

  if st.side is not None:
    close(len(df) - 1, float(df["close"].iloc[-1]), "eod")

  eq = pd.Series(equity[: len(df)], index=df.index[: len(equity)])
  return build_report(STRATEGY_ID, symbol, tf_label, period_label, trades, eq, initial_balance, params)


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
  equity = bal0 + df["profit"].cumsum()

  fig = plt.figure(figsize=(14, 10))
  gs = fig.add_gridspec(3, 2, height_ratios=[2, 1.2, 1.2])
  ax1 = fig.add_subplot(gs[0, :])
  ax1.plot(df["close_time"], equity, lw=1.8)
  ax1.axhline(bal0, color="gray", ls="--")
  ax1.set_title("Equity Curve")
  ax1.grid(alpha=0.3)
  ax2 = fig.add_subplot(gs[1, 0])
  dd = (equity - equity.cummax()) / equity.cummax() * 100
  ax2.fill_between(df["close_time"], dd, 0, color="#d62728", alpha=0.35)
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
  plt.plot(df["close_time"], equity, lw=2)
  plt.title("Equity Curve")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(out_dir / "equity_curve.png", dpi=200, bbox_inches="tight")
  plt.close()

  plt.figure(figsize=(12, 5))
  plt.fill_between(df["close_time"], dd, 0, color="red", alpha=0.3)
  plt.plot(df["close_time"], dd, color="darkred")
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
  range_start_hour: int = 3
  range_end_hour: int = 6
  close_hour: int = 18
  min_range_pts: float = 5
  order_buffer_pts: float = 1.0
  first_trade_only: bool = False
  allow_long: bool = True
  allow_short: bool = True
  lot_size: float = 0.01
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)



def run_backtest(df, symbol, params: StrategyParams, costs, period_label):
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.001
  buf = params.order_buffer_pts * point
  day_state: dict = {}
  p = params.to_dict()

  def on_bar(i, st, open_pos, close):
    ts = df.index[i]
    dk = ts.date().isoformat()
    h = ts.hour
    mid = float(df["open"].iloc[i])
    if st.side and h >= params.close_hour:
      close(i, mid, "eod")
      return
    if dk not in day_state:
      day_state[dk] = {"hi": -np.inf, "lo": np.inf, "built": False, "trades": 0, "range_done": False}
    ds = day_state[dk]
    if params.range_start_hour <= h < params.range_end_hour:
      ds["hi"] = max(ds["hi"], float(df["high"].iloc[i]))
      ds["lo"] = min(ds["lo"], float(df["low"].iloc[i]))
      return
    if not ds["range_done"] and h >= params.range_end_hour:
      ds["range_done"] = True
      if ds["hi"] > ds["lo"] and (ds["hi"] - ds["lo"]) / point >= params.min_range_pts:
        ds["built"] = True
    if not ds["built"] or st.side:
      return
    max_tr = 1 if params.first_trade_only else 2
    if ds["trades"] >= max_tr:
      return
    hi_lvl = ds["hi"] + buf
    lo_lvl = ds["lo"] - buf
    bar_hi = float(df["high"].iloc[i])
    bar_lo = float(df["low"].iloc[i])
    if params.allow_long and bar_hi >= hi_lvl:
      open_pos(i, "BUY", mid)
      st.sl = ds["lo"]
      ds["trades"] += 1
    elif params.allow_short and bar_lo <= lo_lvl:
      open_pos(i, "SELL", mid)
      st.sl = ds["hi"]
      ds["trades"] += 1
    if st.side:
      if st.side == "BUY" and bar_lo <= st.sl:
        close(i, st.sl, "sl")
      elif st.side == "SELL" and bar_hi >= st.sl:
        close(i, st.sl, "sl")

  return run_single_position(df, symbol, point, costs, params.lot_size, "M1", period_label, p, params.initial_balance, on_bar)



def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest")
  p.add_argument("--symbol", default="USDJPY")
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
    print(f"Loading {symbol} bars ...")
    df = load_bars(symbol, mt5.TIMEFRAME_M1, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df, symbol, params, costs, period_label)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
