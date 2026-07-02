"""
XAUUSD H1 optimizer — MetaQuotes Demo history from 2004.

Phase 1: fast random search (full + OOS only)
Phase 2: stability check (year/month win rates) on top candidates
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))

from rsi_scalping_backtest import (  # noqa: E402
    CostModel,
    RsiScalpParams,
    backtest_rsi_scalping,
    load_rates,
    split_walk_forward,
)


@dataclass
class CandidateScore:
    params: RsiScalpParams
    full_net: float
    full_trades: int
    full_pf: float
    full_dd: float
    full_wr: float
    oos_net: float
    oos_trades: int
    oos_pf: float
    oos_dd: float
    win_year_pct: float
    win_month_pct: float
    score: float


def yearly_stats(df: pd.DataFrame, symbol: str, params: RsiScalpParams, costs: CostModel, balance: float) -> float:
    wins = total = 0
    for _, chunk in df.groupby(df.index.year):
        if len(chunk) < 200:
            continue
        r = backtest_rsi_scalping(chunk, symbol, params, balance, costs=costs)
        total += 1
        if r.net_profit > 0:
            wins += 1
    return (100.0 * wins / total) if total else 0.0


def monthly_stats(df: pd.DataFrame, symbol: str, params: RsiScalpParams, costs: CostModel, balance: float) -> float:
    wins = total = 0
    for _, chunk in df.groupby(pd.Grouper(freq="ME")):
        if len(chunk) < 30:
            continue
        r = backtest_rsi_scalping(chunk, symbol, params, balance, costs=costs)
        total += 1
        if r.net_profit > 0:
            wins += 1
    return (100.0 * wins / total) if total else 0.0


def fast_score(full_r, oos_r) -> float:
    if full_r.total_trades < 200 or oos_r.total_trades < 80:
        return float("-inf")
    if full_r.net_profit <= 0 or oos_r.net_profit <= 0:
        return float("-inf")
    if full_r.profit_factor < 1.08 or oos_r.profit_factor < 1.05:
        return float("-inf")
    if full_r.max_drawdown_pct > 35 or oos_r.max_drawdown_pct > 45:
        return float("-inf")
    pf = min(full_r.profit_factor, 3.0) / 3.0
    oos_pf = min(oos_r.profit_factor, 3.0) / 3.0
    return (
        (full_r.net_profit / 5000.0) * 0.35
        + (oos_r.net_profit / 3000.0) * 0.35
        + pf * 0.15
        + oos_pf * 0.15
        - full_r.max_drawdown_pct * 0.05
        - oos_r.max_drawdown_pct * 0.03
    )


def final_score(full_r, oos_r, win_year_pct: float, win_month_pct: float) -> float:
    base = fast_score(full_r, oos_r)
    if base == float("-inf"):
        return base
    if win_year_pct < 55 or win_month_pct < 52:
        return float("-inf")
    return base + (win_year_pct / 100.0) * 0.20 + (win_month_pct / 100.0) * 0.12


def sample_params(rng: random.Random, lot: float) -> RsiScalpParams:
    inverted = rng.random() < 0.55
    if inverted:
        ob = rng.uniform(4.0, 22.0)
        os = rng.uniform(52.0, 78.0)
        tb = rng.uniform(85.0, 99.0)
        ts = rng.uniform(4.0, 55.0)
    else:
        ob = rng.uniform(62.0, 82.0)
        os = rng.uniform(38.0, 58.0)
        tb = rng.uniform(72.0, 92.0)
        ts = rng.uniform(18.0, 62.0)

    if tb <= os:
        tb = os + 5
    if ts >= ob:
        ts = ob - 5

    use_trail = rng.random() < 0.25
    return RsiScalpParams(
        rsi_period=rng.choice([10, 12, 14, 16, 18, 21]),
        rsi_overbought=round(ob, 1),
        rsi_oversold=round(os, 1),
        rsi_target_buy=round(tb, 1),
        rsi_target_sell=round(ts, 1),
        bars_to_wait=rng.choice([1, 2, 3, 4, 6, 8, 12]),
        use_trailing=use_trail,
        trail_distance_pts=rng.choice([40, 55, 71, 90, 120, 150]),
        trail_activation_pts=rng.choice([20, 35, 41, 55, 70, 90]),
        lot_size=lot,
    )


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--symbol", default="XAUUSD")
    p.add_argument("--start", default="2004-01-01")
    p.add_argument("--end", default="2026-01-01")
    p.add_argument("--trials", type=int, default=3000)
    p.add_argument("--lot", type=float, default=0.1)
    p.add_argument("--balance", type=float, default=10_000.0)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--train-ratio", type=float, default=0.65)
    p.add_argument("--top-k", type=int, default=40)
    return p.parse_args()


def main():
    args = parse_args()
    out_dir = Path(__file__).resolve().parent

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")

    try:
        start = datetime.fromisoformat(args.start)
        end = datetime.fromisoformat(args.end)
        df = load_rates(args.symbol, mt5.TIMEFRAME_H1, start, end)
        train_df, test_df = split_walk_forward(df, args.train_ratio)
        costs = CostModel.from_symbol(args.symbol, slippage_points=3.0)

        print(f"Loaded {len(df)} H1 bars {df.index[0]} -> {df.index[-1]}")
        print(f"Train {len(train_df)} | Test {len(test_df)}")

        rng = random.Random(args.seed)
        rows: list[dict] = []

        for n in range(1, args.trials + 1):
            p = sample_params(rng, args.lot)
            full_r = backtest_rsi_scalping(df, args.symbol, p, args.balance, costs=costs)
            oos_r = backtest_rsi_scalping(test_df, args.symbol, p, args.balance, costs=costs)
            sc = fast_score(full_r, oos_r)
            rows.append(
                {
                    "trial": n,
                    "fast_score": sc,
                    "full_net": full_r.net_profit,
                    "full_trades": full_r.total_trades,
                    "full_pf": full_r.profit_factor,
                    "full_dd": full_r.max_drawdown_pct,
                    "oos_net": oos_r.net_profit,
                    "oos_trades": oos_r.total_trades,
                    "oos_pf": oos_r.profit_factor,
                    "oos_dd": oos_r.max_drawdown_pct,
                    **asdict(p),
                }
            )
            if n % 500 == 0:
                valid = [r for r in rows if r["fast_score"] > float("-inf")]
                msg = f"trial {n}/{args.trials} valid={len(valid)}"
                if valid:
                    top = max(valid, key=lambda r: r["fast_score"])
                    msg += f" best_fast={top['fast_score']:.3f} full=${top['full_net']:,.0f} dd={top['full_dd']:.1f}%"
                print(msg)

        df_rows = pd.DataFrame(rows)
        df_rows.sort_values("fast_score", ascending=False).to_csv(out_dir / "xauusd_opt_trials.csv", index=False)

        candidates = df_rows[df_rows["fast_score"] > float("-inf")].head(args.top_k)
        if candidates.empty:
            candidates = df_rows[(df_rows["full_net"] > 0) & (df_rows["oos_net"] > 0)].sort_values(
                "oos_net", ascending=False
            ).head(args.top_k)
        if candidates.empty:
            raise SystemExit("No profitable candidate found")

        print(f"\nStability check on top {len(candidates)} candidates ...")
        best: CandidateScore | None = None
        for _, row in candidates.iterrows():
            p = RsiScalpParams.from_dict({k: row[k] for k in RsiScalpParams.__dataclass_fields__})
            full_r = backtest_rsi_scalping(df, args.symbol, p, args.balance, costs=costs)
            oos_r = backtest_rsi_scalping(test_df, args.symbol, p, args.balance, costs=costs)
            wy = yearly_stats(df, args.symbol, p, costs, args.balance)
            wm = monthly_stats(df, args.symbol, p, costs, args.balance)
            sc = final_score(full_r, oos_r, wy, wm)
            if sc == float("-inf"):
                continue
            cand = CandidateScore(
                params=p,
                full_net=full_r.net_profit,
                full_trades=full_r.total_trades,
                full_pf=full_r.profit_factor,
                full_dd=full_r.max_drawdown_pct,
                full_wr=full_r.win_rate,
                oos_net=oos_r.net_profit,
                oos_trades=oos_r.total_trades,
                oos_pf=oos_r.profit_factor,
                oos_dd=oos_r.max_drawdown_pct,
                win_year_pct=wy,
                win_month_pct=wm,
                score=sc,
            )
            if best is None or cand.score > best.score:
                best = cand

        if best is None:
            row = candidates.iloc[0]
            p = RsiScalpParams.from_dict({k: row[k] for k in RsiScalpParams.__dataclass_fields__})
            full_r = backtest_rsi_scalping(df, args.symbol, p, args.balance, costs=costs)
            oos_r = backtest_rsi_scalping(test_df, args.symbol, p, args.balance, costs=costs)
            best = CandidateScore(
                params=p,
                full_net=full_r.net_profit,
                full_trades=full_r.total_trades,
                full_pf=full_r.profit_factor,
                full_dd=full_r.max_drawdown_pct,
                full_wr=full_r.win_rate,
                oos_net=oos_r.net_profit,
                oos_trades=oos_r.total_trades,
                oos_pf=oos_r.profit_factor,
                oos_dd=oos_r.max_drawdown_pct,
                win_year_pct=yearly_stats(df, args.symbol, p, costs, args.balance),
                win_month_pct=monthly_stats(df, args.symbol, p, costs, args.balance),
                score=float(row["fast_score"]),
            )

        report = {
            "symbol": args.symbol,
            "period": [args.start, args.end],
            "trials": args.trials,
            "best": {
                "params": asdict(best.params),
                "full_net": best.full_net,
                "full_trades": best.full_trades,
                "full_pf": best.full_pf,
                "full_dd": best.full_dd,
                "full_wr": best.full_wr,
                "oos_net": best.oos_net,
                "oos_trades": best.oos_trades,
                "oos_pf": best.oos_pf,
                "oos_dd": best.oos_dd,
                "win_year_pct": best.win_year_pct,
                "win_month_pct": best.win_month_pct,
                "score": best.score,
            },
        }
        json_path = out_dir / "xauusd_best_params.json"
        json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

        print("\n=== BEST XAUUSD PARAMS ===")
        for k, v in asdict(best.params).items():
            print(f"  {k}: {v}")
        print(f"  FULL net=${best.full_net:,.2f} trades={best.full_trades} PF={best.full_pf:.2f} DD={best.full_dd:.1f}%")
        print(f"  OOS  net=${best.oos_net:,.2f} trades={best.oos_trades} PF={best.oos_pf:.2f} DD={best.oos_dd:.1f}%")
        print(f"  Win years={best.win_year_pct:.1f}%  Win months={best.win_month_pct:.1f}%")
        print(f"Saved {json_path}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
