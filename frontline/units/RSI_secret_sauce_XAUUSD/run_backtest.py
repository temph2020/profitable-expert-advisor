"""
RSI_secret_sauce_XAUUSD — bar backtest mirroring main.mq5 inputs.

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

STRATEGY_ID = "RSI_secret_sauce_XAUUSD"


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
  rsi_period: int = 16
  rsi_overbought: float = 73.0
  rsi_oversold: float = 42.5
  rsi_lookback: int = 60
  peak_bars: int = 2
  stop_loss_atr: float = 2.0
  take_profit_atr: float = 4.0
  atr_period: int = 14
  min_bars_between_trades: int = 7
  lot_size: float = 0.1
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)


def _is_rsi_peak(rsi: np.ndarray, i: int, peak_bars: int) -> bool:
  cur = float(rsi[i - 1])
  if cur != cur:
    return False
  if float(rsi[i - 2]) >= cur:
    return False
  for j in range(2, peak_bars + 2):
    if i - j < 0 or float(rsi[i - j]) >= cur:
      return False
  return True


def _is_rsi_bottom(rsi: np.ndarray, i: int, peak_bars: int) -> bool:
  cur = float(rsi[i - 1])
  if cur != cur:
    return False
  if float(rsi[i - 2]) <= cur:
    return False
  for j in range(2, peak_bars + 2):
    if i - j < 0 or float(rsi[i - j]) <= cur:
      return False
  return True


def run_backtest(df, symbol, params: StrategyParams, costs, period_label):
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  rsi = calculate_rsi(df["close"], params.rsi_period).to_numpy()
  atr = calculate_atr(df, params.atr_period).to_numpy()
  last_trade_i = -999
  was_ob = was_os = back_in_range = False
  p = params.to_dict()
  warmup = max(params.rsi_lookback, params.rsi_period) + 5

  def on_bar(i, st, open_pos, close):
    nonlocal last_trade_i, was_ob, was_os, back_in_range
    if i < warmup or np.isnan(rsi[i - 1]) or np.isnan(atr[i - 1]):
      return
    mid = float(df["open"].iloc[i])
    cur, prev = float(rsi[i - 1]), float(rsi[i - 2])
    a = float(atr[i - 1])

    if st.side:
      if st.side == "BUY":
        sl = st.entry - params.stop_loss_atr * a
        tp = st.entry + params.take_profit_atr * a
        if float(df["low"].iloc[i]) <= sl:
          close(i, sl, "sl")
        elif float(df["high"].iloc[i]) >= tp:
          close(i, tp, "tp")
      else:
        sl = st.entry + params.stop_loss_atr * a
        tp = st.entry - params.take_profit_atr * a
        if float(df["high"].iloc[i]) >= sl:
          close(i, sl, "sl")
        elif float(df["low"].iloc[i]) <= tp:
          close(i, tp, "tp")
      return

    if prev >= params.rsi_overbought and cur < params.rsi_overbought:
      was_ob, back_in_range = True, True
    if prev <= params.rsi_oversold and cur > params.rsi_oversold:
      was_os, back_in_range = True, True
    if cur >= params.rsi_overbought:
      was_ob = back_in_range = False
    if cur <= params.rsi_oversold:
      was_os = back_in_range = False

    if i - last_trade_i < params.min_bars_between_trades:
      return

    if was_ob and back_in_range and cur < params.rsi_overbought and _is_rsi_peak(rsi, i, params.peak_bars):
      open_pos(i, "BUY", mid)
      last_trade_i = i
      was_ob = back_in_range = False
    elif was_os and back_in_range and cur > params.rsi_oversold and _is_rsi_bottom(rsi, i, params.peak_bars):
      open_pos(i, "SELL", mid)
      last_trade_i = i
      was_os = back_in_range = False

  return run_single_position(df, symbol, point, costs, params.lot_size, "M30", period_label, p, params.initial_balance, on_bar)



def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest")
  p.add_argument("--symbol", default="XAUUSD")
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
    df = load_bars(symbol, mt5.TIMEFRAME_M30, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df, symbol, params, costs, period_label)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
