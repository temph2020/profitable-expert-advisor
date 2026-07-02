"""
RSICrossOverReversalXAUUSD — bar backtest mirroring main.mq5 inputs.

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

STRATEGY_ID = "RSICrossOverReversalXAUUSD"


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
  rsi_period: int = 19
  ema_period: int = 140
  overbought_level: float = 93
  oversold_level: float = 22
  exit_buy_rsi: float = 86
  exit_sell_rsi: float = 10
  trailing_stop_pts: float = 295
  ema_slope_threshold: float = 105
  ema_distance_threshold: float = 165
  use_trend_strength_filter: bool = True
  cooldown_seconds: int = 209
  lot_size: float = 0.1
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)



def _price_to_ema_score(close: float, ema: float) -> float:
  return abs(close - ema) * 10.0


def run_backtest(df_m12, df_m1, symbol, params: StrategyParams, costs, period_label):
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  rsi_s = calculate_rsi(df_m1["close"], params.rsi_period).reindex(df_m12.index, method="ffill")
  ema_s = calculate_ema(df_m1["close"], params.ema_period).reindex(df_m12.index, method="ffill")
  rsi = rsi_s.to_numpy()
  ema = ema_s.to_numpy()
  trail = params.trailing_stop_pts * point
  prev_rsi = 0.0
  last_trade_time: pd.Timestamp | None = None
  p = params.to_dict()
  weekday_ok = {0: False, 1: False, 2: True, 3: True, 4: True, 5: False, 6: False}
  cooldown = pd.Timedelta(seconds=params.cooldown_seconds)

  def hours_ok(ts) -> bool:
    h = ts.hour
    def win(b, e):
      b, e = b % 24, e % 24
      if b < e:
        return b <= h < e
      return h >= b or h < e
    return win(24, 22) or win(6, 19)

  def on_bar(i, st, open_pos, close):
    nonlocal prev_rsi, last_trade_time
    if i < 3 or np.isnan(rsi[i - 1]) or np.isnan(ema[i - 1]):
      return
    ts = df_m12.index[i]
    if not weekday_ok.get(ts.weekday(), False) or not hours_ok(ts):
      if st.side:
        close(i, float(df_m12["open"].iloc[i]), "hours")
      return
    cur = float(rsi[i - 1])
    if prev_rsi == 0.0:
      prev_rsi = cur
      return
    ema_slope = (float(ema[i - 1]) - float(ema[i - 2])) * 100.0
    bar_close = float(df_m12["close"].iloc[i - 1])
    price_to_ema = abs((float(df_m12["close"].iloc[i - 1]) - ema[i - 1]) * 10.0)
    slope_th = params.ema_slope_threshold
    dist_th = params.ema_distance_threshold
    trend_strong = params.use_trend_strength_filter and (
      (slope_th > 0 and abs(ema_slope) > slope_th)
      or (dist_th > 0 and price_to_ema > dist_th)
    )
    mid = float(df_m12["open"].iloc[i])
    if st.side == "BUY" and trail > 0:
      bid = float(df_m12["close"].iloc[i])
      if bid - st.entry > trail:
        st.sl = max(st.sl, bid - trail)
      if st.sl > 0 and float(df_m12["low"].iloc[i]) <= st.sl:
        close(i, st.sl, "trail")
        prev_rsi = cur
        return
    if st.side == "SELL" and trail > 0:
      ask = float(df_m12["close"].iloc[i])
      if st.entry - ask > trail:
        st.sl = ask + trail if st.sl == 0 else min(st.sl, ask + trail)
      if st.sl > 0 and float(df_m12["high"].iloc[i]) >= st.sl:
        close(i, st.sl, "trail")
        prev_rsi = cur
        return
    if st.side == "BUY" and cur > params.exit_buy_rsi:
      close(i, mid, "exit_rsi")
    elif st.side == "SELL" and cur < params.exit_sell_rsi:
      close(i, mid, "exit_rsi")
    elif trend_strong and st.side:
      close(i, mid, "trend_strong")
    elif not st.side and not trend_strong:
      cooled = last_trade_time is None or (ts - last_trade_time) >= cooldown
      if cooled and prev_rsi >= params.overbought_level and cur < params.overbought_level:
        open_pos(i, "SELL", mid)
        last_trade_time = ts
      elif cooled and prev_rsi <= params.oversold_level and cur > params.oversold_level:
        open_pos(i, "BUY", mid)
        last_trade_time = ts
    prev_rsi = cur

  return run_single_position(
    df_m12, symbol, point, costs, params.lot_size,
    STRATEGY_ID, "M12", period_label, p, params.initial_balance, on_bar, bar_seconds=720,
  )



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
    print(f"Loading {symbol} M1 + M12 bars ...")
    df_m1 = load_bars(symbol, mt5.TIMEFRAME_M1, start, end)
    df_m12 = load_bars(symbol, mt5.TIMEFRAME_M12, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df_m12, df_m1, symbol, params, costs, period_label)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
