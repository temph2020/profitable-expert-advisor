"""
RSIScalpingAdaptive XAUUSD — monthly walk-forward validation (Python).

Mirrors the in-EA optimizer: each calendar month, grid-search the prior month,
pick the best score, then forward-test that month with the selected params.

Usage:
  python run_walk_forward.py
  python run_walk_forward.py --symbol XAUUSD --start 2023-01-01 --end 2026-01-01
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from run_backtest import StrategyParams, run_backtest  # noqa: E402

STRATEGY_ID = "RSIScalpingAdaptiveXAUUSD"


@dataclass
class SearchGrid:
    rsi_period: tuple[int, int, int] = (12, 18, 2)
    rsi_overbought: tuple[float, float, float] = (65.0, 77.0, 3.0)
    rsi_oversold: tuple[float, float, float] = (50.0, 63.0, 3.0)
    rsi_target_buy: tuple[float, float, float] = (75.0, 86.0, 3.0)
    rsi_target_sell: tuple[float, float, float] = (50.0, 63.0, 3.0)
    bars_to_wait: tuple[int, int, int] = (1, 4, 1)
    min_trades: int = 8
    max_combos: int = 600
    weight_sharpe: float = 0.35
    weight_net: float = 0.25
    weight_pf: float = 0.15
    weight_dd: float = 0.10


def _frange(start: float, stop: float, step: float) -> list[float]:
    out: list[float] = []
    v = start
    while v <= stop + 1e-9:
        out.append(round(v, 6))
        v += step
    return out


def _irange(start: int, stop: int, step: int) -> list[int]:
    return list(range(start, stop + 1, step))


def score_report(report, min_trades: int, grid: SearchGrid) -> float:
    if report.total_trades < min_trades or report.net_profit <= 0 or report.profit_factor < 1.05:
        return float("-inf")
    pf = min(report.profit_factor, 4.0) / 4.0
    return (
        report.sharpe * grid.weight_sharpe
        + (report.net_profit / 2000.0) * grid.weight_net
        + pf * grid.weight_pf
        - report.max_drawdown_pct * grid.weight_dd
    )


def is_valid(p: StrategyParams) -> bool:
    return p.rsi_target_buy > p.rsi_oversold and p.rsi_target_sell < p.rsi_overbought


def iter_params(fallback: StrategyParams, grid: SearchGrid):
    yield fallback
    tested = 0
    for rp in _irange(*grid.rsi_period):
        for ob in _frange(*grid.rsi_overbought):
            for os in _frange(*grid.rsi_oversold):
                for tb in _frange(*grid.rsi_target_buy):
                    for ts in _frange(*grid.rsi_target_sell):
                        for bw in _irange(*grid.bars_to_wait):
                            if tested >= grid.max_combos:
                                return
                            p = StrategyParams(
                                rsi_period=rp,
                                rsi_overbought=ob,
                                rsi_oversold=os,
                                rsi_target_buy=tb,
                                rsi_target_sell=ts,
                                bars_to_wait=bw,
                                lot_size=fallback.lot_size,
                                initial_balance=fallback.initial_balance,
                            )
                            if is_valid(p):
                                tested += 1
                                yield p


def month_starts(start: datetime, end: datetime) -> list[pd.Timestamp]:
    idx = pd.date_range(start=start, end=end, freq="MS")
    return list(idx)


def previous_month_bounds(ts: pd.Timestamp) -> tuple[datetime, datetime]:
    prev_end = ts - pd.Timedelta(seconds=1)
    prev_start = prev_end.replace(day=1)
    return prev_start.to_pydatetime(), prev_end.to_pydatetime()


def month_bounds(ts: pd.Timestamp) -> tuple[datetime, datetime]:
    start = ts.to_pydatetime()
    end = (ts + pd.offsets.MonthBegin(1) - pd.Timedelta(seconds=1)).to_pydatetime()
    return start, end


def optimize_month(
    df_all: pd.DataFrame,
    symbol: str,
    costs: CostModel,
    opt_start: datetime,
    opt_end: datetime,
    fallback: StrategyParams,
    grid: SearchGrid,
):
    df = df_all.loc[(df_all.index >= opt_start) & (df_all.index <= opt_end)]
    if len(df) < 80:
        return fallback, None, 0

    best_p = fallback
    best_r = None
    best_score = float("-inf")
    combos = 0

    for p in iter_params(fallback, grid):
        report = run_backtest(df, symbol, p, costs, f"{opt_start.date()}_{opt_end.date()}", "H1")
        combos += 1
        sc = score_report(report, grid.min_trades, grid)
        if sc > best_score:
            best_score = sc
            best_p = p
            best_r = report

    return best_p, best_r, combos


def forward_month(
    df_all: pd.DataFrame,
    symbol: str,
    costs: CostModel,
    fwd_start: datetime,
    fwd_end: datetime,
    params: StrategyParams,
):
    df = df_all.loc[(df_all.index >= fwd_start) & (df_all.index <= fwd_end)]
    if len(df) < 20:
        return None
    return run_backtest(df, symbol, params, costs, f"{fwd_start.date()}_{fwd_end.date()}", "H1")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=f"{STRATEGY_ID} walk-forward")
    p.add_argument("--symbol", default="XAUUSD")
    p.add_argument("--start", default="2023-01-01")
    p.add_argument("--end", default="2026-01-01")
    p.add_argument("--balance", type=float, default=10_000.0)
    p.add_argument("--lot", type=float, default=0.1)
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = Path(__file__).resolve().parent
    fallback = StrategyParams(lot_size=args.lot, initial_balance=args.balance)
    grid = SearchGrid()

    if not mt5.initialize():
        raise SystemExit("MetaTrader5 initialize() failed")

    try:
        symbol = resolve_symbol(args.symbol)
        start = datetime.fromisoformat(args.start)
        end = datetime.fromisoformat(args.end)
        warmup = start - pd.Timedelta(days=45)
        print(f"Loading {symbol} H1 bars from {warmup.date()} to {end.date()} ...")
        df_all = load_bars(symbol, mt5.TIMEFRAME_H1, warmup.to_pydatetime(), end)
        costs = CostModel.for_symbol(symbol)

        rows = []
        cumulative = 0.0
        for month_ts in month_starts(start, end):
            if month_ts.to_pydatetime() >= end:
                break
            opt_start, opt_end = previous_month_bounds(month_ts)
            fwd_start, fwd_end = month_bounds(month_ts)
            if fwd_start >= end:
                continue

            best_p, opt_report, combos = optimize_month(
                df_all, symbol, costs, opt_start, opt_end, fallback, grid
            )
            fwd_report = forward_month(df_all, symbol, costs, fwd_start, fwd_end, best_p)
            if fwd_report is None:
                continue

            cumulative += fwd_report.net_profit
            rows.append(
                {
                    "month": str(month_ts.date())[:7],
                    "opt_window": f"{opt_start.date()}..{opt_end.date()}",
                    "combos_tested": combos,
                    "selected": asdict(best_p),
                    "opt_net": opt_report.net_profit if opt_report else 0.0,
                    "opt_sharpe": opt_report.sharpe if opt_report else 0.0,
                    "fwd_net": fwd_report.net_profit,
                    "fwd_trades": fwd_report.total_trades,
                    "fwd_sharpe": fwd_report.sharpe,
                    "fwd_pf": fwd_report.profit_factor,
                    "fwd_dd_pct": fwd_report.max_drawdown_pct,
                    "cumulative_net": cumulative,
                }
            )
            print(
                f"{rows[-1]['month']} | opt ${rows[-1]['opt_net']:,.0f} "
                f"-> fwd ${rows[-1]['fwd_net']:,.0f} | cum ${cumulative:,.0f} | "
                f"RSI={best_p.rsi_period} OB={best_p.rsi_overbought} OS={best_p.rsi_oversold}"
            )

        summary = {
            "strategy": STRATEGY_ID,
            "symbol": symbol,
            "start": args.start,
            "end": args.end,
            "months": len(rows),
            "cumulative_net": cumulative,
            "rows": rows,
        }
        out_path = out_dir / "walk_forward_report.json"
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        pd.DataFrame(rows).to_csv(out_dir / "walk_forward_monthly.csv", index=False)
        print(f"\nWalk-forward cumulative net: ${cumulative:,.2f} over {len(rows)} months")
        print(f"Saved {out_path}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
