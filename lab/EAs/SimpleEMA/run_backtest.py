"""
SimpleEMA — Python bar backtest mirroring main.mq5 (MT5 live data).

Outputs in this folder:
  backtest_report.json, trades.csv, report.png, equity_curve.png, ...

Usage:
  python run_backtest.py
  python run_backtest.py --start 2023-01-01 --end 2026-01-01
  python run_backtest.py --fast 12 --slow 26 --atr-sl 1.5
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
from indicator_utils import calculate_atr, calculate_ema  # noqa: E402

STRATEGY_ID = "SimpleEMA"
DEFAULT_SYMBOL = "EURUSD"
DEFAULT_TF = mt5.TIMEFRAME_H1


def pip_size(symbol: str) -> float:
    info = mt5.symbol_info(symbol)
    if not info:
        return 0.0001
    pt = float(info.point)
    return pt * 10.0 if info.digits in (3, 5) else pt


@dataclass
class StrategyParams:
    fast_ema: int = 12
    slow_ema: int = 26
    min_ema_gap_pips: float = 0.0
    lot_size: float = 0.10
    use_atr_stops: bool = True
    atr_period: int = 14
    atr_sl_mult: float = 1.5
    atr_tp_mult: float = 2.5
    stop_loss_pips: int = 30
    take_profit_pips: int = 60
    use_trailing: bool = False
    trail_pips: int = 20
    exit_on_cross: bool = True
    max_bars_in_trade: int = 48
    max_spread_pips: int = 5
    initial_balance: float = 10_000.0

    def to_dict(self) -> dict:
        return asdict(self)


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

    if not report.trades_list:
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
    eq = report.equity_curve if report.equity_curve is not None and len(report.equity_curve) > 1 else None
    if eq is None:
        eq = pd.Series(bal0 + df["profit"].cumsum().values, index=df["close_time"])
    equity_times, equity = eq.index, eq
    dd = (equity - equity.cummax()) / equity.cummax() * 100

    fig = plt.figure(figsize=(14, 10))
    gs = fig.add_gridspec(3, 2, height_ratios=[2, 1.2, 1.2])
    ax1 = fig.add_subplot(gs[0, :])
    ax1.plot(equity_times, equity, lw=1.8)
    ax1.axhline(bal0, color="gray", ls="--")
    ax1.set_title("Equity Curve")
    ax1.grid(alpha=0.3)
    ax2 = fig.add_subplot(gs[1, 0])
    ax2.fill_between(equity_times, dd, 0, color="#d62728", alpha=0.35)
    ax2.set_title("Drawdown %")
    ax2.grid(alpha=0.3)
    ax3 = fig.add_subplot(gs[1, 1])
    df["month"] = df["close_time"].dt.to_period("M")
    monthly = df.groupby("month")["profit"].sum()
    ax3.bar(range(len(monthly)), monthly.values, color=["#2ca02c" if v >= 0 else "#d62728" for v in monthly])
    ax3.set_title("Monthly PnL")
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


def run_backtest(df, symbol, params: StrategyParams, costs, period_label) -> BacktestReport:
    info = mt5.symbol_info(symbol)
    point = float(info.point) if info else 0.00001
    pip = pip_size(symbol)
    fast = calculate_ema(df["close"], params.fast_ema).to_numpy()
    slow = calculate_ema(df["close"], params.slow_ema).to_numpy()
    atr = calculate_atr(df, params.atr_period).to_numpy()
    p = params.to_dict()

    def on_bar(i, st, open_pos, close):
        if i < 3 or np.isnan(fast[i - 1]) or np.isnan(slow[i - 1]):
            return

        fast1, fast2 = fast[i - 1], fast[i - 2]
        slow1, slow2 = slow[i - 1], slow[i - 2]
        bull = fast2 <= slow2 and fast1 > slow1
        bear = fast2 >= slow2 and fast1 < slow1
        gap_pips = abs(fast1 - slow1) / pip if pip > 0 else 0.0
        mid = float(df["open"].iloc[i])
        hi, lo = float(df["high"].iloc[i]), float(df["low"].iloc[i])
        atr1 = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0

        bars_held = i - st.entry_i if st.side else 0
        if st.side and params.max_bars_in_trade > 0 and bars_held >= params.max_bars_in_trade:
            close(i, mid, "max_bars")
            return

        if st.side and params.exit_on_cross:
            if st.side == "BUY" and bear:
                close(i, mid, "bear_cross")
                return
            if st.side == "SELL" and bull:
                close(i, mid, "bull_cross")
                return

        if st.side and params.use_trailing:
            trail = params.trail_pips * pip
            if st.side == "BUY" and hi - st.entry > trail:
                new_sl = hi - trail
                if st.sl is None or new_sl > st.sl:
                    st.sl = new_sl
            elif st.side == "SELL" and st.entry - lo > trail:
                new_sl = lo + trail
                if st.sl is None or new_sl < st.sl:
                    st.sl = new_sl

        if st.side == "BUY":
            if params.use_atr_stops and atr1 > 0:
                sl_px = st.entry - atr1 * params.atr_sl_mult
                tp_px = st.entry + atr1 * params.atr_tp_mult
            else:
                sl_px = st.entry - params.stop_loss_pips * pip
                tp_px = st.entry + params.take_profit_pips * pip
            if lo <= sl_px:
                close(i, sl_px, "sl")
                return
            if hi >= tp_px:
                close(i, tp_px, "tp")
                return
        elif st.side == "SELL":
            if params.use_atr_stops and atr1 > 0:
                sl_px = st.entry + atr1 * params.atr_sl_mult
                tp_px = st.entry - atr1 * params.atr_tp_mult
            else:
                sl_px = st.entry + params.stop_loss_pips * pip
                tp_px = st.entry - params.take_profit_pips * pip
            if hi >= sl_px:
                close(i, sl_px, "sl")
                return
            if lo <= tp_px:
                close(i, tp_px, "tp")
                return
        else:
            spread_pips = costs.spread_points * point / pip if pip > 0 else 0
            if params.max_spread_pips > 0 and spread_pips > params.max_spread_pips:
                return
            if bull and gap_pips >= params.min_ema_gap_pips:
                open_pos(i, "BUY", mid)
            elif bear and gap_pips >= params.min_ema_gap_pips:
                open_pos(i, "SELL", mid)

    return run_single_position(
        df, symbol, point, costs, params.lot_size,
        STRATEGY_ID, "H1", period_label, p, params.initial_balance, on_bar,
    )


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=f"{STRATEGY_ID} Python backtest (MT5 data)")
    p.add_argument("--symbol", default=DEFAULT_SYMBOL)
    p.add_argument("--start", default="2023-01-01")
    p.add_argument("--end", default="2026-01-01")
    p.add_argument("--balance", type=float, default=10_000.0)
    p.add_argument("--fast", type=int, default=12)
    p.add_argument("--slow", type=int, default=26)
    p.add_argument("--lot", type=float, default=0.10)
    p.add_argument("--atr-sl", type=float, default=1.5)
    p.add_argument("--atr-tp", type=float, default=2.5)
    p.add_argument("--no-atr", action="store_true")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(__file__).resolve().parent
    params = StrategyParams(
        fast_ema=args.fast,
        slow_ema=args.slow,
        lot_size=args.lot,
        atr_sl_mult=args.atr_sl,
        atr_tp_mult=args.atr_tp,
        use_atr_stops=not args.no_atr,
        initial_balance=args.balance,
    )
    if not mt5.initialize():
        raise SystemExit("MetaTrader5 initialize() failed — open MT5 and log in first")
    try:
        symbol = resolve_symbol(args.symbol)
        start = datetime.fromisoformat(args.start)
        end = datetime.fromisoformat(args.end)
        period_label = f"{args.start}_{args.end}"
        print(f"Loading {symbol} H1 bars {args.start} → {args.end} ...")
        df = load_bars(symbol, DEFAULT_TF, start, end)
        costs = CostModel.for_symbol(symbol)
        report = run_backtest(df, symbol, params, costs, period_label)
        save_reports(report, out_dir)
        print(
            f"Net: ${report.net_profit:,.2f} | Trades: {report.total_trades} | "
            f"WR: {report.win_rate:.1f}% | PF: {report.profit_factor:.2f} | "
            f"MaxDD: {report.max_drawdown_pct:.2f}%"
        )
        print(f"Saved trades.csv + charts → {out_dir}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
