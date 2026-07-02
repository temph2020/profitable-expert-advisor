"""
Random-search optimizer for USDCHF Playbook.

Targets: net_profit > 0, trades >= min_trades, stable PF.

Usage:
  python run_optimize.py --trials 3000 --min-trades 150
  python run_optimize.py --profile balanced --trials 5000
"""

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
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from strategy_core import PlaybookParams, build_market, pip_size, simulate  # noqa: E402

LAB = Path(__file__).resolve().parent
EA_SET = LAB / "USDCHF_Playbook.set"


def sample_params(rng: random.Random, high_freq: bool) -> PlaybookParams:
    if high_freq:
        return PlaybookParams(
            daily_ema_period=rng.choice([34, 50, 100]),
            use_daily_bias=rng.choice([True, True, False]),
            htf_zone_bars=rng.choice([12, 16, 20]),
            min_break_body_ratio=round(rng.uniform(0.45, 0.65), 2),
            use_double_trap=rng.choice([True, True, False]),
            ny_chaos_start=rng.choice([11, 12, 13]),
            ny_chaos_end=rng.choice([14, 15, 16]),
            momentum_start=rng.choice([14, 15, 16]),
            momentum_end=rng.choice([1, 2, 3]),
            ltf_fast_ema=rng.randint(5, 12),
            ltf_slow_ema=rng.choice([18, 21, 26, 34]),
            entry_mode=rng.choice([0, 1, 1, 2]),
            atr_sl_mult=round(rng.uniform(1.4, 2.4), 2),
            atr_tp_mult=round(rng.uniform(3.0, 6.0), 2),
            use_trailing=rng.choice([True, False]),
            trail_atr_mult=round(rng.uniform(0.9, 1.6), 2),
            max_bars_in_trade=rng.choice([64, 96, 128]),
            use_compression_filter=rng.choice([True, False]),
            compress_atr_ratio=round(rng.uniform(0.55, 0.80), 2),
            cooldown_bars=rng.choice([2, 3, 4]),
        )
    return PlaybookParams(
        daily_ema_period=rng.choice([50, 100]),
        htf_zone_bars=rng.choice([16, 20, 24]),
        min_break_body_ratio=round(rng.uniform(0.50, 0.70), 2),
        use_double_trap=rng.choice([True, False]),
        ny_chaos_start=rng.choice([12, 13]),
        ny_chaos_end=rng.choice([14, 15, 16]),
        momentum_start=rng.choice([15, 16]),
        momentum_end=rng.choice([2, 3]),
        entry_mode=rng.choice([1, 1, 2]),
        atr_sl_mult=round(rng.uniform(1.6, 2.2), 2),
        atr_tp_mult=round(rng.uniform(3.5, 5.5), 2),
        max_bars_in_trade=rng.choice([80, 96, 120]),
        cooldown_bars=rng.choice([4, 6, 8]),
    )


def write_set(p: PlaybookParams, path: Path) -> None:
    lines = [
        "; USDCHF Playbook optimized",
        "Timeframe=15",
        f"UseDailyBias={'true' if p.use_daily_bias else 'false'}",
        f"DailyEmaPeriod={p.daily_ema_period}",
        f"HtfZoneBars={p.htf_zone_bars}",
        f"MinBreakBodyRatio={p.min_break_body_ratio}",
        f"UseDoubleTrap={'true' if p.use_double_trap else 'false'}",
        f"NyChaosStartHour={p.ny_chaos_start}",
        f"NyChaosEndHour={p.ny_chaos_end}",
        f"MomentumStartHour={p.momentum_start}",
        f"MomentumEndHour={p.momentum_end}",
        f"LtfFastEma={p.ltf_fast_ema}",
        f"LtfSlowEma={p.ltf_slow_ema}",
        f"EntryMode={p.entry_mode}",
        f"AtrPeriod={p.atr_period}",
        f"AtrSlMult={p.atr_sl_mult}",
        f"AtrTpMult={p.atr_tp_mult}",
        f"UseTrailing={'true' if p.use_trailing else 'false'}",
        f"TrailAtrMult={p.trail_atr_mult}",
        f"MaxBarsInTrade={p.max_bars_in_trade}",
        f"ExtendHoldMomentum={'true' if p.extend_hold_in_momentum else 'false'}",
        f"CooldownBars={p.cooldown_bars}",
        f"UseCompressionFilter={'true' if p.use_compression_filter else 'false'}",
        f"CompressAtrRatio={p.compress_atr_ratio}",
        f"LotSize={p.lot_size}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def score_result(r, min_trades: int, profile: str) -> float:
    if r.total_trades < min_trades:
        return float("-inf")
    if r.net_profit <= 0:
        return float("-inf")
    if r.profit_factor < 1.02:
        return float("-inf")
    base = r.net_profit
    if profile == "high-freq":
        return base + r.total_trades * 2.0
    if profile == "balanced":
        return base + r.total_trades * 5.0 - r.max_drawdown_pct * 50.0
    return base - r.max_drawdown_pct * 80.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="USDCHF")
    ap.add_argument("--start", default="2022-01-01")
    ap.add_argument("--end", default="2026-01-01")
    ap.add_argument("--trials", type=int, default=3000)
    ap.add_argument("--min-trades", type=int, default=120)
    ap.add_argument("--max-trades", type=int, default=800)
    ap.add_argument("--profile", choices=["profit", "high-freq", "balanced"], default="balanced")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        sym = resolve_symbol(args.symbol)
        df = load_bars(sym, mt5.TIMEFRAME_M15, datetime.fromisoformat(args.start), datetime.fromisoformat(args.end))
        costs = CostModel.for_symbol(sym)
        pip = pip_size(sym)
        point = float(mt5.symbol_info(sym).point)
        print(f"{sym} M15 bars={len(df)} trials={args.trials} profile={args.profile}", flush=True)

        best_sc = float("-inf")
        best = None
        best_p = None
        rows = []
        high_freq = args.profile == "high-freq"

        for n in range(1, args.trials + 1):
            p = sample_params(rng, high_freq)
            md = build_market(df, p)
            r = simulate(md, sym, p, costs, pip, point)
            sc = score_result(r, args.min_trades, args.profile)
            if args.max_trades and r.total_trades > args.max_trades:
                sc = float("-inf")
            rows.append({"trial": n, "score": sc, "net": r.net_profit, "trades": r.total_trades, "pf": r.profit_factor, **asdict(p)})
            if sc > best_sc:
                best_sc, best, best_p = sc, r, p
                print(
                    f"  NEW BEST {n}: net=${r.net_profit:,.0f} trades={r.total_trades} "
                    f"PF={r.profit_factor:.2f} DD={r.max_drawdown_pct:.1f}%",
                    flush=True,
                )
            if n % 500 == 0:
                b = best
                print(f"  ... {n}/{args.trials} best_net=${b.net_profit if b else 0:,.0f}", flush=True)

        pd.DataFrame(rows).sort_values("score", ascending=False).to_csv(LAB / "optimize_trials.csv", index=False)
        assert best and best_p

        with open(LAB / "best_params.json", "w", encoding="utf-8") as f:
            json.dump(
                {
                    "metrics": {
                        "net_profit": best.net_profit,
                        "total_trades": best.total_trades,
                        "profit_factor": best.profit_factor,
                        "win_rate": best.win_rate,
                        "max_drawdown_pct": best.max_drawdown_pct,
                        "sharpe": best.sharpe,
                    },
                    "params": asdict(best_p),
                },
                f,
                indent=2,
            )
        write_set(best_p, EA_SET)

        trows = [
            {
                "side": t["side"],
                "open_time": df.index[t["open_i"]],
                "close_time": df.index[t["close_i"]],
                "profit": t["profit"],
                "exit_reason": t["exit_reason"],
            }
            for t in best.trades
        ]
        pd.DataFrame(trows).to_csv(LAB / "best_trades.csv", index=False)

        print(
            f"\nBEST: net=${best.net_profit:,.2f} trades={best.total_trades} "
            f"PF={best.profit_factor:.2f} WR={best.win_rate:.1f}% MaxDD={best.max_drawdown_pct:.1f}%",
            flush=True,
        )
        print(f"Saved {EA_SET.name} and best_params.json", flush=True)
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
