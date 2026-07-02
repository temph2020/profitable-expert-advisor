"""
EMASlopeDistanceCocktailXAUUSD — bar backtest mirroring main.mq5 inputs.

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
from indicator_utils import calculate_dmi, calculate_ema  # noqa: E402

STRATEGY_ID = "EMASlopeDistanceCocktailXAUUSD"


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
  ema_period: int = 65
  price_threshold_pips: float = 375
  slope_threshold_pips: float = 15.0
  monitor_timeout_sec: int = 340
  trailing_stop_pips: float = 74.0
  lot_size: float = 0.07
  max_trades_per_crossover: int = 48
  profit_check_bars: int = 36
  close_unprofitable_trades: bool = True
  use_weekly_adx_filter: bool = True
  weekly_adx_period: int = 28
  weekly_adx_min: float = 25.0
  weekly_adx_bar_shift: int = 8
  weekly_adx_use_direction: bool = True
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)


def _pip_multiplier(symbol: str) -> float:
  info = mt5.symbol_info(symbol)
  digits = int(info.digits) if info else 2
  return 10.0 if digits in (3, 5) else 1.0


def run_backtest(df, symbol, params: StrategyParams, costs, period_label):
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  mult = _pip_multiplier(symbol)
  ema = calculate_ema(df["close"], params.ema_period).to_numpy()
  closes = df["close"].to_numpy()
  opens = df["open"].to_numpy()
  highs = df["high"].to_numpy()
  lows = df["low"].to_numpy()
  wdf = df.resample("W-FRI").agg({"high": "max", "low": "min", "close": "last"}).dropna()
  dmi = calculate_dmi(wdf, params.weekly_adx_period)
  w_adx = dmi["adx"].shift(params.weekly_adx_bar_shift).reindex(df.index, method="ffill")
  w_plus = dmi["plus_di"].shift(params.weekly_adx_bar_shift).reindex(df.index, method="ffill")
  w_minus = dmi["minus_di"].shift(params.weekly_adx_bar_shift).reindex(df.index, method="ffill")
  p = params.to_dict()
  timeout_bars = max(0, int(params.monitor_timeout_sec / 3600))  # H1 = 3600s, same as MQL int cast

  price_trig = slope_trig = monitor = False
  monitor_i = -1
  trades_cross = 0
  last_close = last_ema = 0.0
  profit_checked = False

  def weekly_ok(i: int, side: str) -> bool:
    if not params.use_weekly_adx_filter:
      return True
    adx_v = float(w_adx.iloc[i - 1])
    if np.isnan(adx_v) or adx_v < params.weekly_adx_min:
      return False
    if not params.weekly_adx_use_direction:
      return True
    pdi, mdi = float(w_plus.iloc[i - 1]), float(w_minus.iloc[i - 1])
    return pdi > mdi if side == "BUY" else mdi > pdi

  def on_bar(i, st, open_pos, close):
    nonlocal price_trig, slope_trig, monitor, monitor_i, trades_cross, last_close, last_ema, profit_checked
    if i < params.ema_period + 3 or np.isnan(ema[i - 1]) or np.isnan(ema[i - 2]):
      return

    mid = float(opens[i])
    bar_close = float(closes[i - 1])
    ema_now, ema_prev = float(ema[i - 1]), float(ema[i - 2])

    if last_close != 0.0:
      if (last_close <= last_ema and bar_close > ema_now) or (last_close >= last_ema and bar_close < ema_now):
        trades_cross = 0
    last_close, last_ema = bar_close, ema_now

    price_dist = abs(bar_close - ema_now) / point / mult
    if price_dist > params.price_threshold_pips and not price_trig:
      price_trig = True
    slope = (ema_now - ema_prev) / point / mult
    if abs(slope) > params.slope_threshold_pips and not slope_trig:
      slope_trig = True

    if price_trig and slope_trig and not monitor:
      monitor, monitor_i = True, i

    if monitor and monitor_i >= 0 and (i - monitor_i) > timeout_bars:
      monitor = price_trig = slope_trig = False

    if st.side:
      bar_close_now = float(closes[i - 1])
      unrealized = calc_profit(symbol, st.side, params.lot_size, st.entry, bar_close_now)

      # Trailing stop — MQL: only when position_profit > 0
      if unrealized > 0 and params.trailing_stop_pips > 0:
        trail_px = params.trailing_stop_pips * point * mult
        if st.side == "BUY":
          new_sl = bar_close_now - trail_px
          st.sl = max(st.sl, new_sl) if st.sl > 0 else new_sl
          if st.sl > 0 and float(lows[i]) <= st.sl:
            close(i, st.sl, "trail")
            profit_checked = False
            return
        else:
          new_sl = bar_close_now + trail_px
          st.sl = min(st.sl, new_sl) if st.sl > 0 else new_sl
          if st.sl > 0 and float(highs[i]) >= st.sl:
            close(i, st.sl, "trail")
            profit_checked = False
            return

      # EMA crossover exit — MQL: no profit requirement
      if (st.side == "BUY" and bar_close_now < ema_now) or (st.side == "SELL" and bar_close_now > ema_now):
        close(i, mid, "ema_cross")
        profit_checked = False
        return

      # Profit check after X bars — MQL: close if profit <= 0, then stop checking
      if params.close_unprofitable_trades and not profit_checked:
        if (i - st.entry_i) >= params.profit_check_bars:
          if unrealized <= 0:
            close(i, mid, "profit_check")
          profit_checked = True
      return

    if not monitor or trades_cross >= params.max_trades_per_crossover:
      return

    if bar_close > ema_now and weekly_ok(i, "BUY"):
      open_pos(i, "BUY", mid)
      trades_cross += 1
      monitor = price_trig = slope_trig = False
      profit_checked = False
    elif bar_close < ema_now and weekly_ok(i, "SELL"):
      open_pos(i, "SELL", mid)
      trades_cross += 1
      monitor = price_trig = slope_trig = False
      profit_checked = False

  return run_single_position(df, symbol, point, costs, params.lot_size, "H1", period_label, p, params.initial_balance, on_bar)



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
    df = load_bars(symbol, mt5.TIMEFRAME_H1, start, end)
    costs = CostModel.for_symbol(symbol)
    report = run_backtest(df, symbol, params, costs, period_label)
    save_reports(report, out_dir)
    print(f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f}")
    print(f"Saved to {out_dir}")
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
