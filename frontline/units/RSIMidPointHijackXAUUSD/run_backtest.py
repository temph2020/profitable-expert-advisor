"""
RSIMidPointHijackXAUUSD — bar backtest mirroring main.mq5 (3 concurrent strategies).

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
from indicator_utils import calculate_ema, calculate_rsi  # noqa: E402

STRATEGY_ID = "RSIMidPointHijackXAUUSD"


@dataclass
class PositionSlot:
  name: str
  side: str | None = None
  entry: float = 0.0
  entry_i: int = 0
  entry_time: object = None


@dataclass
class StrategyParams:
  lot_size: float = 0.1
  enable_rsi_follow: bool = True
  enable_rsi_reverse: bool = True
  enable_ema_cross: bool = True
  enable_strategy_lock: bool = True
  lock_profit_threshold_pts: float = 6.0
  close_opposite_trades: bool = True
  rsi_period: int = 32
  rsi_ob: float = 78
  rsi_os: float = 46
  rsi_exit: float = 44
  follow_start: int = 23
  follow_end: int = 8
  follow_close_outside: bool = False
  rev_period: int = 59
  rev_ob: float = 51
  rev_os: float = 49
  rev_cross: float = 53
  rev_exit: float = 48
  rev_start: int = 7
  rev_end: int = 13
  rev_close_outside: bool = False
  rev_cooldown_bars: int = 15
  rev_cooldown_on_loss: bool = True
  ema_period: int = 120
  ema_start: int = 8
  ema_end: int = 14
  ema_close_outside: bool = True
  use_ema_distance_entry: bool = True
  ema_distance_pts: float = 160.0
  ema_distance_period: int = 26
  initial_balance: float = 10_000.0

  def to_dict(self) -> dict:
    return asdict(self)


def make_params(balance: float) -> StrategyParams:
  return StrategyParams(initial_balance=balance)


def _in_hours(h: int, start: int, end: int) -> bool:
  if start <= end:
    return start <= h < end
  return h >= start or h < end


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


def run_backtest(df: pd.DataFrame, symbol: str, params: StrategyParams, costs: CostModel, period_label: str) -> BacktestReport:
  info = mt5.symbol_info(symbol)
  point = float(info.point) if info else 0.01
  lot = params.lot_size
  lock_px = params.lock_profit_threshold_pts * point

  rsi_f = calculate_rsi(df["close"], params.rsi_period).to_numpy()
  rsi_r = calculate_rsi(df["close"], params.rev_period).to_numpy()
  ema = calculate_ema(df["close"], params.ema_period).to_numpy()
  closes = df["close"].to_numpy()

  slots = {
    "follow": PositionSlot("follow"),
    "reverse": PositionSlot("reverse"),
    "ema": PositionSlot("ema"),
  }
  trades: list[Trade] = []
  equity = [params.initial_balance]

  rsi_ob = rsi_os = False
  rev_ob = rev_os = False
  ema_buy_sig = ema_sell_sig = False
  ema_sig_bar = 0
  rev_cooldown_until = -1

  def unrealized(slot: PositionSlot, mid: float) -> float:
    if slot.side is None:
      return 0.0
    return calc_profit(symbol, slot.side, lot, slot.entry, mid)

  def close_slot(slot: PositionSlot, i: int, mid: float, reason: str) -> float:
    nonlocal rev_cooldown_until
    if slot.side is None:
      return 0.0
    exit_px = fill_price(mid, point, costs, slot.side, entry=False)
    commission = costs.commission_per_lot * lot * 2.0
    profit = calc_profit(symbol, slot.side, lot, slot.entry, exit_px) - commission
    trades.append(
      Trade(
        side=slot.side,
        open_time=slot.entry_time,
        close_time=df.index[i],
        open_price=slot.entry,
        close_price=exit_px,
        volume=lot,
        profit=profit,
        bars_held=i - slot.entry_i,
        exit_reason=reason,
      )
    )
    if slot.name == "reverse":
      if not params.rev_cooldown_on_loss or profit < 0:
        rev_cooldown_until = i + params.rev_cooldown_bars
    slot.side = None
    slot.entry = 0.0
    return profit

  def open_slot(slot: PositionSlot, i: int, side: str, mid: float) -> None:
    slot.side = side
    slot.entry = fill_price(mid, point, costs, side, entry=True)
    slot.entry_i = i
    slot.entry_time = df.index[i]

  def is_opposite(a: str, b: str) -> bool:
    return (a, b) in {("follow", "reverse"), ("reverse", "follow"), ("ema", "follow"), ("ema", "reverse"), ("follow", "ema"), ("reverse", "ema")}

  def apply_strategy_lock(requesting: str, mid: float) -> bool:
    if not params.enable_strategy_lock:
      return False
    blocked = False
    for name, slot in slots.items():
      if name == requesting or slot.side is None:
        continue
      pnl = unrealized(slot, mid)
      if pnl > lock_px:
        blocked = True
        if params.close_opposite_trades and is_opposite(requesting, name):
          close_slot(slot, i, mid, "opposite_close")
    return blocked

  def distance_buy_ok(i: int) -> bool:
    for j in range(params.ema_distance_period):
      bar = i - 1 - j
      if bar < 0 or np.isnan(ema[bar]):
        return False
      if (closes[bar] - ema[bar]) / point < params.ema_distance_pts:
        return False
    return True

  def distance_sell_ok(i: int) -> bool:
    for j in range(params.ema_distance_period):
      bar = i - 1 - j
      if bar < 0 or np.isnan(ema[bar]):
        return False
      if (ema[bar] - closes[bar]) / point < params.ema_distance_pts:
        return False
    return True

  warmup = max(params.rsi_period, params.rev_period, params.ema_period, params.ema_distance_period) + 3

  for i in range(1, len(df)):
    bar_pnl = 0.0
    if i < warmup or np.isnan(rsi_f[i - 1]) or np.isnan(rsi_r[i - 1]) or np.isnan(ema[i - 1]):
      equity.append(equity[-1])
      continue

    h = df.index[i].hour
    mid = float(df["open"].iloc[i])
    rf = float(rsi_f[i - 1])
    rr = float(rsi_r[i - 1])
    em = float(ema[i - 1])
    cl = float(closes[i - 1])
    em_prev = float(ema[i - 2]) if not np.isnan(ema[i - 2]) else em
    cl_prev = float(closes[i - 2])

    # --- exits (CheckExitConditions) ---
    follow = slots["follow"]
    if follow.side == "BUY" and rf < params.rsi_exit:
      bar_pnl += close_slot(follow, i, mid, "follow_exit")
    elif follow.side == "SELL" and rf > params.rsi_exit:
      bar_pnl += close_slot(follow, i, mid, "follow_exit")

    reverse = slots["reverse"]
    if reverse.side == "BUY" and rr < params.rev_exit:
      bar_pnl += close_slot(reverse, i, mid, "rev_exit")
    elif reverse.side == "SELL" and rr > params.rev_exit:
      bar_pnl += close_slot(reverse, i, mid, "rev_exit")

    ema_slot = slots["ema"]
    if ema_slot.side == "BUY" and em > cl:
      bar_pnl += close_slot(ema_slot, i, mid, "ema_exit")
    elif ema_slot.side == "SELL" and em < cl:
      bar_pnl += close_slot(ema_slot, i, mid, "ema_exit")

    # close EMA outside trading hours
    if params.ema_close_outside and ema_slot.side and not _in_hours(h, params.ema_start, params.ema_end):
      bar_pnl += close_slot(ema_slot, i, mid, "ema_hours")

    if params.follow_close_outside and follow.side and not _in_hours(h, params.follow_start, params.follow_end):
      bar_pnl += close_slot(follow, i, mid, "follow_hours")

    if params.rev_close_outside and reverse.side and not _in_hours(h, params.rev_start, params.rev_end):
      bar_pnl += close_slot(reverse, i, mid, "rev_hours")

    # --- RSI Follow entries ---
    if params.enable_rsi_follow and _in_hours(h, params.follow_start, params.follow_end):
      if not apply_strategy_lock("follow", mid):
        if rf > params.rsi_ob:
          rsi_ob = True
        elif rf < params.rsi_os:
          rsi_os = True
        if rsi_ob and rf < params.rsi_exit and follow.side is None:
          open_slot(follow, i, "SELL", mid)
          rsi_ob = False
        elif rsi_os and rf > params.rsi_exit and follow.side is None:
          open_slot(follow, i, "BUY", mid)
          rsi_os = False

    # --- RSI Reverse entries ---
    if params.enable_rsi_reverse and _in_hours(h, params.rev_start, params.rev_end):
      in_cooldown = params.rev_cooldown_bars > 0 and i < rev_cooldown_until
      if not in_cooldown and not apply_strategy_lock("reverse", mid):
        if rr > params.rev_ob:
          rev_ob = True
        elif rr < params.rev_os:
          rev_os = True
        if rev_ob and rr < params.rev_cross and reverse.side is None:
          open_slot(reverse, i, "SELL", mid)
          rev_ob = False
        elif rev_os and rr > params.rev_cross and reverse.side is None:
          open_slot(reverse, i, "BUY", mid)
          rev_os = False

    # --- EMA cross signals ---
    if em_prev < cl_prev and em > cl:
      ema_buy_sig = True
      ema_sell_sig = False
      ema_sig_bar = 0
    elif em_prev > cl_prev and em < cl:
      ema_sell_sig = True
      ema_buy_sig = False
      ema_sig_bar = 0

    if params.enable_ema_cross and _in_hours(h, params.ema_start, params.ema_end):
      if not apply_strategy_lock("ema", mid) and ema_slot.side is None:
        if params.use_ema_distance_entry:
          if ema_buy_sig and distance_buy_ok(i):
            open_slot(ema_slot, i, "BUY", mid)
            ema_buy_sig = False
          elif ema_sell_sig and distance_sell_ok(i):
            open_slot(ema_slot, i, "SELL", mid)
            ema_sell_sig = False
        else:
          if em_prev < cl_prev and em > cl:
            open_slot(ema_slot, i, "BUY", mid)
          elif em_prev > cl_prev and em < cl:
            open_slot(ema_slot, i, "SELL", mid)

    if ema_buy_sig or ema_sell_sig:
      ema_sig_bar += 1
      if ema_sig_bar > params.ema_distance_period * 2:
        ema_buy_sig = ema_sell_sig = False

    equity.append(equity[-1] + bar_pnl)

  for slot in slots.values():
    if slot.side is not None:
      profit = close_slot(slot, len(df) - 1, float(closes[-1]), "eod")
      equity[-1] += profit

  eq = pd.Series(equity[: len(df)], index=df.index[: len(equity)])
  return build_report(
    STRATEGY_ID, symbol, "H1", period_label, trades, eq, params.initial_balance, params.to_dict(),
  )


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest")
  p.add_argument("--symbol", default="XAUUSD")
  p.add_argument("--start", default="2021-01-01")
  p.add_argument("--end", default="2026-01-01")
  p.add_argument("--balance", type=float, default=10_000.0)
  p.add_argument("--no-strategy-lock", action="store_true", help="Match MT5 report with lock disabled")
  p.add_argument("--lot", type=float, default=None, help="Override lot size (default 0.1 from main.mq5)")
  return p.parse_args()


def main() -> None:
  args = parse_args()
  out_dir = Path(__file__).resolve().parent
  params = make_params(args.balance)
  if args.no_strategy_lock:
    params.enable_strategy_lock = False
    params.close_opposite_trades = False
  if args.lot is not None:
    params.lot_size = args.lot
  if not mt5.initialize():
    raise SystemExit("MetaTrader5 initialize() failed")
  try:
    symbol = resolve_symbol(args.symbol)
    start = datetime.fromisoformat(args.start)
    end = datetime.fromisoformat(args.end)
    period_label = f"{args.start}_{args.end}"
    print(f"Loading {symbol} H1 bars ...")
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
