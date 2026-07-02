#!/usr/bin/env python3
"""Optimize SimpleEMA v3 (trend pullback)."""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import asdict
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
LAB = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))
sys.path.insert(0, str(LAB))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from run_backtest import pip_size  # noqa: E402
from strategy_v3 import V3Params, load_v3_cache, market_from_cache, sample_v3, simulate_v3, write_v3_set  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", type=int, default=4000)
    ap.add_argument("--min-trades", type=int, default=400)
    ap.add_argument("--max-trades", type=int, default=2500)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    out = LAB
    rng = random.Random(args.seed)

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        sym = resolve_symbol("EURUSD")
        df = load_bars(sym, mt5.TIMEFRAME_M15, datetime(2020, 1, 1), datetime(2026, 1, 1))
        costs = CostModel.for_symbol(sym)
        pip = pip_size(sym)
        point = float(mt5.symbol_info(sym).point)
        print(f"v3 optimize {sym} M15 trials={args.trials} trades={args.min_trades}-{args.max_trades}")
        cache = load_v3_cache(df)

        best_profit = None
        best_balanced = None
        target = None

        for n in range(1, args.trials + 1):
            p = sample_v3(rng)
            md = market_from_cache(cache, p)
            r = simulate_v3(md, sym, p, costs, pip, point)

            if args.min_trades <= r.total_trades <= args.max_trades and r.net_profit > 0 and r.profit_factor >= 1.05:
                if target is None or r.net_profit > target[0].net_profit:
                    target = (r, p)
                    print(f"  HIT {n}: net=${r.net_profit:,.0f} t={r.total_trades} PF={r.profit_factor:.2f}")

            if r.net_profit > 0:
                if best_balanced is None or r.total_trades > best_balanced[0].total_trades or (
                    r.total_trades == best_balanced[0].total_trades and r.net_profit > best_balanced[0].net_profit
                ):
                    best_balanced = (r, p)

            if best_profit is None or r.net_profit > best_profit[0].net_profit:
                best_profit = (r, p)

            if n % 1000 == 0:
                b = best_balanced or best_profit
                print(f"  ... {n}/{args.trials} best_bal t={b[0].total_trades} net=${b[0].net_profit:,.0f} hit={'yes' if target else 'no'}")

        final_r, final_p = target or best_balanced or best_profit
        assert final_r and final_p

        write_v3_set(final_p, out / "SimpleEMA_optimized.set")
        payload = {
            "version": 3,
            "target_met": target is not None,
            "params": asdict(final_p),
            "metrics": asdict(final_r),
        }
        (out / "best_params.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

        (out / "best_run").mkdir(exist_ok=True)
        rows = [
            {
                "side": t["side"],
                "open_time": df.index[t["open_i"]],
                "close_time": df.index[t["close_i"]],
                "profit": t["profit"],
                "exit_reason": t["exit_reason"],
            }
            for t in final_r.trades
        ]
        pd.DataFrame(rows).to_csv(out / "best_run" / "trades.csv", index=False)

        print(
            f"\n{'TARGET' if target else 'BEST'}: net=${final_r.net_profit:,.2f} "
            f"trades={final_r.total_trades} PF={final_r.profit_factor:.2f} WR={final_r.win_rate:.1f}% DD={final_r.max_drawdown_pct:.1f}%"
        )
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
