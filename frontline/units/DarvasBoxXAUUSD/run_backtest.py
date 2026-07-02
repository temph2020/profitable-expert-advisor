"""
DarvasBoxXAUUSD bar backtest — mirrors main.mq5 inputs and logic.

Outputs (in this folder):
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


@dataclass
class DarvasParams:
  box_period: int = 165
  box_deviation: float = 25140.0
  volume_threshold: int = 938
  stop_loss_pts: float = 1665.0
  take_profit_pts: float = 3685.0
  ma_period: int = 125
  trend_threshold: float = 4.94
  volume_ma_period: int = 110
  volume_threshold_multiplier: float = 1.5
  lot_size: float = 0.01
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def weighted_price(df: pd.DataFrame) -> pd.Series:
  return (df["high"] + df["low"] + df["close"]) / 3.0


def align_higher_tf_ma(h1_index: pd.DatetimeIndex, h2_ma: pd.Series) -> np.ndarray:
  aligned = h2_ma.reindex(h1_index, method="ffill")
  return aligned.to_numpy()


def volume_ma_ratio(vols: np.ndarray, i: int, period: int) -> float:
  if i < period:
    return 0.0
  window = vols[i - period : i]
  if len(window) == 0:
    return 0.0
  vma = float(np.mean(window))
  if vma <= 0:
    return 0.0
  return float(vols[i]) / vma


def backtest_darvas_unit(
  h1: pd.DataFrame,
  h2_ma: np.ndarray,
  symbol: str,
  params: DarvasParams,
  costs: CostModel,
  period_label: str,
) -> BacktestReport:
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  max_range = params.box_deviation * point
  sl_dist = params.stop_loss_pts * point
  tp_dist = params.take_profit_pts * point

  highs = h1["high"].to_numpy()
  lows = h1["low"].to_numpy()
  opens = h1["open"].to_numpy()
  closes = h1["close"].to_numpy()
  vols = h1["tick_volume"].to_numpy() if "tick_volume" in h1.columns else np.zeros(len(h1))

  trades: list[Trade] = []
  equity = [params.initial_balance]
  side: str | None = None
  entry = 0.0
  entry_i = 0
  entry_time = None
  sl = 0.0
  tp = 0.0

  warmup = params.box_period + params.ma_period + params.volume_ma_period + 2

  def close_pos(i: int, mid: float, reason: str) -> None:
    nonlocal side, entry, entry_i, entry_time, sl, tp
    if side is None:
      return
    exit_px = fill_price(mid, point, costs, side, entry=False)
    commission = costs.commission_per_lot * params.lot_size * 2.0
    profit = calc_profit(symbol, side, params.lot_size, entry, exit_px) - commission
    trades.append(
      Trade(
        side=side,
        open_time=entry_time,
        close_time=h1.index[i],
        open_price=entry,
        close_price=exit_px,
        volume=params.lot_size,
        profit=profit,
        bars_held=i - entry_i,
        exit_reason=reason,
      )
    )
    equity.append(equity[-1] + profit)
    side = None

  def open_pos(i: int, order_side: str, mid: float) -> None:
    nonlocal side, entry, entry_i, entry_time, sl, tp
    side = order_side
    entry = fill_price(mid, point, costs, order_side, entry=True)
    entry_i = i
    entry_time = h1.index[i]
    if order_side == "BUY":
      sl = entry - sl_dist
      tp = entry + tp_dist
    else:
      sl = entry + sl_dist
      tp = entry - tp_dist

  def trend_ok(i: int, order_side: str, price: float) -> bool:
    ma_v = float(h2_ma[i - 1])
    if np.isnan(ma_v):
      return False
    strength = abs(price - ma_v) / point
    if order_side == "BUY":
      return price > ma_v and strength > params.trend_threshold
    return price < ma_v and strength > params.trend_threshold

  for i in range(warmup, len(h1)):
    bar_hi = float(highs[i])
    bar_lo = float(lows[i])
    mid = float(opens[i])

    if side:
      if side == "BUY":
        if sl > 0 and bar_lo <= sl:
          close_pos(i, sl, "sl")
        elif tp > 0 and bar_hi >= tp:
          close_pos(i, tp, "tp")
      else:
        if sl > 0 and bar_hi >= sl:
          close_pos(i, sl, "sl")
        elif tp > 0 and bar_lo <= tp:
          close_pos(i, tp, "tp")
      if len(equity) == len(trades) + 1:
        equity.append(equity[-1])
      continue

    window_hi = float(np.max(highs[i - params.box_period : i]))
    window_lo = float(np.min(lows[i - params.box_period : i]))
    if (window_hi - window_lo) > max_range:
      equity.append(equity[-1])
      continue

    box_high, box_low = window_hi, window_lo
    cur_vol = float(vols[i])
    if cur_vol <= params.volume_threshold:
      equity.append(equity[-1])
      continue

    vol_ratio = volume_ma_ratio(vols, i, params.volume_ma_period)
    if vol_ratio <= params.volume_threshold_multiplier:
      equity.append(equity[-1])
      continue

    ask_price = mid
    break_up = bar_hi > box_high or float(closes[i - 1]) > box_high
    break_dn = bar_lo < box_low or float(closes[i - 1]) < box_low

    if break_up and trend_ok(i, "BUY", ask_price):
      open_pos(i, "BUY", mid)
    elif break_dn and trend_ok(i, "SELL", ask_price):
      open_pos(i, "SELL", mid)

    equity.append(equity[-1])

  if side:
    close_pos(len(h1) - 1, float(closes[-1]), "eod")

  eq = pd.Series(equity[: len(h1)], index=h1.index[: len(equity)])
  return build_report(
    "DarvasBoxXAUUSD",
    symbol,
    "H1",
    period_label,
    trades,
    eq,
    params.initial_balance,
    params.to_dict(),
  )


def plot_dashboard(report: BacktestReport, out_dir: Path) -> None:
  trades = report.trades_list
  if not trades:
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.text(0.5, 0.5, "No trades in backtest window", ha="center", va="center", fontsize=14)
    ax.axis("off")
    fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
    plt.close(fig)
    return

  df = pd.DataFrame(
    [
      {
        "open_time": t.open_time,
        "close_time": t.close_time,
        "profit": t.profit,
        "exit_reason": t.exit_reason,
        "side": t.side,
      }
      for t in trades
    ]
  )
  df["close_time"] = pd.to_datetime(df["close_time"])
  df = df.sort_values("close_time")
  cumulative = df["profit"].cumsum()
  equity = report.params.get("initial_balance", 10_000.0) + cumulative

  fig = plt.figure(figsize=(14, 10))
  gs = fig.add_gridspec(3, 2, height_ratios=[2, 1.2, 1.2])

  ax1 = fig.add_subplot(gs[0, :])
  ax1.plot(df["close_time"], equity, color="#1f77b4", lw=1.8)
  ax1.axhline(report.params.get("initial_balance", 10_000.0), color="gray", ls="--", lw=1)
  ax1.set_title("Equity Curve")
  ax1.set_ylabel("Balance")
  ax1.grid(alpha=0.3)

  ax2 = fig.add_subplot(gs[1, 0])
  peak = equity.cummax()
  dd = (equity - peak) / peak * 100.0
  ax2.fill_between(df["close_time"], dd, 0, color="#d62728", alpha=0.35)
  ax2.plot(df["close_time"], dd, color="#8b0000", lw=1)
  ax2.set_title("Drawdown %")
  ax2.grid(alpha=0.3)

  ax3 = fig.add_subplot(gs[1, 1])
  df["month"] = df["close_time"].dt.to_period("M")
  monthly = df.groupby("month")["profit"].sum()
  colors = ["#2ca02c" if v >= 0 else "#d62728" for v in monthly]
  ax3.bar(range(len(monthly)), monthly.values, color=colors, alpha=0.8)
  ax3.set_title("Monthly PnL")
  ax3.set_xticks(range(0, len(monthly), max(1, len(monthly) // 8)))
  ax3.set_xticklabels([str(monthly.index[i]) for i in range(0, len(monthly), max(1, len(monthly) // 8))], rotation=45, ha="right")
  ax3.axhline(0, color="black", lw=0.6)
  ax3.grid(alpha=0.3, axis="y")

  ax4 = fig.add_subplot(gs[2, 0])
  ax4.hist(df["profit"], bins=30, color="#9467bd", alpha=0.85, edgecolor="white")
  ax4.axvline(0, color="black", lw=0.8)
  ax4.set_title("Trade PnL Distribution")
  ax4.grid(alpha=0.3)

  ax5 = fig.add_subplot(gs[2, 1])
  reasons = df["exit_reason"].value_counts()
  ax5.bar(reasons.index.astype(str), reasons.values, color="#ff7f0e", alpha=0.85)
  ax5.set_title("Exit Reasons")
  ax5.grid(alpha=0.3, axis="y")

  summary = (
    f"Net: ${report.net_profit:,.2f}  |  Trades: {report.total_trades}  |  "
    f"WR: {report.win_rate:.1f}%  |  PF: {report.profit_factor:.2f}  |  "
    f"MaxDD: {report.max_drawdown_pct:.2f}%  |  Sharpe: {report.sharpe:.2f}"
  )
  fig.suptitle(f"DarvasBoxXAUUSD — {summary}", fontsize=11, y=0.98)
  fig.tight_layout(rect=[0, 0, 1, 0.96])
  fig.savefig(out_dir / "report.png", dpi=200, bbox_inches="tight")
  plt.close(fig)


def plot_equity(report: BacktestReport, path: Path) -> None:
  trades = report.trades_list
  if not trades:
    return
  df = pd.DataFrame([{"close_time": t.close_time, "profit": t.profit} for t in trades])
  df["close_time"] = pd.to_datetime(df["close_time"])
  df = df.sort_values("close_time")
  equity = report.params.get("initial_balance", 10_000.0) + df["profit"].cumsum()
  plt.figure(figsize=(12, 5))
  plt.plot(df["close_time"], equity, lw=2)
  plt.title("Equity Curve")
  plt.xlabel("Time")
  plt.ylabel("Balance")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(path, dpi=200, bbox_inches="tight")
  plt.close()


def plot_drawdown(report: BacktestReport, path: Path) -> None:
  trades = report.trades_list
  if not trades:
    return
  df = pd.DataFrame([{"close_time": t.close_time, "profit": t.profit} for t in trades])
  df["close_time"] = pd.to_datetime(df["close_time"])
  df = df.sort_values("close_time")
  equity = report.params.get("initial_balance", 10_000.0) + df["profit"].cumsum()
  dd = (equity - equity.cummax()) / equity.cummax() * 100.0
  plt.figure(figsize=(12, 5))
  plt.fill_between(df["close_time"], dd, 0, color="red", alpha=0.3)
  plt.plot(df["close_time"], dd, color="darkred", lw=1)
  plt.title("Drawdown %")
  plt.xlabel("Time")
  plt.ylabel("Drawdown (%)")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(path, dpi=200, bbox_inches="tight")
  plt.close()


def plot_monthly(report: BacktestReport, path: Path) -> None:
  trades = report.trades_list
  if not trades:
    return
  df = pd.DataFrame([{"close_time": t.close_time, "profit": t.profit} for t in trades])
  df["close_time"] = pd.to_datetime(df["close_time"])
  df["month"] = df["close_time"].dt.to_period("M")
  monthly = df.groupby("month")["profit"].sum()
  colors = ["green" if v >= 0 else "red" for v in monthly]
  plt.figure(figsize=(12, 5))
  plt.bar(range(len(monthly)), monthly.values, color=colors, alpha=0.75)
  plt.xticks(range(len(monthly)), [str(x) for x in monthly.index], rotation=45, ha="right")
  plt.axhline(0, color="black", lw=0.5)
  plt.title("Monthly PnL")
  plt.ylabel("Profit")
  plt.grid(alpha=0.3, axis="y")
  plt.tight_layout()
  plt.savefig(path, dpi=200, bbox_inches="tight")
  plt.close()


def plot_pnl_hist(report: BacktestReport, path: Path) -> None:
  profits = [t.profit for t in report.trades_list]
  if not profits:
    return
  plt.figure(figsize=(10, 5))
  plt.hist(profits, bins=40, color="#6a5acd", alpha=0.85, edgecolor="white")
  plt.axvline(0, color="black", lw=0.8)
  plt.title("Per-Trade PnL Distribution")
  plt.xlabel("Profit")
  plt.grid(alpha=0.3)
  plt.tight_layout()
  plt.savefig(path, dpi=200, bbox_inches="tight")
  plt.close()


def plot_exit_reasons(report: BacktestReport, path: Path) -> None:
  if not report.exit_reason_breakdown:
    return
  labels = list(report.exit_reason_breakdown.keys())
  counts = [report.exit_reason_breakdown[k]["count"] for k in labels]
  plt.figure(figsize=(8, 5))
  plt.bar(labels, counts, color="#e377c2", alpha=0.85)
  plt.title("Exit Reason Counts")
  plt.grid(alpha=0.3, axis="y")
  plt.tight_layout()
  plt.savefig(path, dpi=200, bbox_inches="tight")
  plt.close()


def export_trades_csv(report: BacktestReport, path: Path) -> None:
  rows = []
  for t in report.trades_list:
    rows.append(
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
    )
  pd.DataFrame(rows).to_csv(path, index=False)


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description="DarvasBoxXAUUSD Python backtest")
  p.add_argument("--symbol", default="XAUUSD")
  p.add_argument("--start", default="2021-01-01")
  p.add_argument("--end", default="2026-01-01")
  p.add_argument("--balance", type=float, default=10_000.0)
  return p.parse_args()


def main() -> None:
  args = parse_args()
  out_dir = Path(__file__).resolve().parent
  params = DarvasParams(initial_balance=args.balance)

  if not mt5.initialize():
    raise SystemExit("MetaTrader5 initialize() failed — open MT5 and log in.")

  try:
    symbol = resolve_symbol(args.symbol)
    start = datetime.fromisoformat(args.start)
    end = datetime.fromisoformat(args.end)
    period_label = f"{args.start}_{args.end}"

    print(f"Loading H1/H2 bars for {symbol} ...")
    h1 = load_bars(symbol, mt5.TIMEFRAME_H1, start, end)
    h2 = load_bars(symbol, mt5.TIMEFRAME_H2, start, end)
    h2_ma = weighted_price(h2).ewm(span=params.ma_period, adjust=False).mean()
    ma_on_h1 = align_higher_tf_ma(h1.index, h2_ma)

    costs = CostModel.for_symbol(symbol)
    report = backtest_darvas_unit(h1, ma_on_h1, symbol, params, costs, period_label)

    export_trades_csv(report, out_dir / "trades.csv")
    with open(out_dir / "backtest_report.json", "w", encoding="utf-8") as f:
      json.dump(report.to_dict(), f, indent=2, ensure_ascii=False)

    plot_dashboard(report, out_dir)
    plot_equity(report, out_dir / "equity_curve.png")
    plot_drawdown(report, out_dir / "drawdown.png")
    plot_monthly(report, out_dir / "monthly_returns.png")
    plot_pnl_hist(report, out_dir / "pnl_distribution.png")
    plot_exit_reasons(report, out_dir / "exit_reasons.png")

    print("\n=== DarvasBoxXAUUSD Backtest ===")
    print(f"Symbol:      {symbol}")
    print(f"Period:      {period_label}")
    print(f"Net profit:  ${report.net_profit:,.2f}")
    print(f"Trades:      {report.total_trades}")
    print(f"Win rate:    {report.win_rate:.2f}%")
    print(f"Profit fac:  {report.profit_factor:.2f}")
    print(f"Max DD:      {report.max_drawdown_pct:.2f}%")
    print(f"Sharpe:      {report.sharpe:.2f}")
    print(f"\nReports saved to: {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
