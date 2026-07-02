"""
Walk-forward random-search optimizer for RSI scalping.

Optimizes on in-sample (train), ranks by out-of-sample (validation) score.
"""

from __future__ import annotations

import argparse
import json
import random
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import MetaTrader5 as mt5
import pandas as pd

from rsi_scalping_backtest import (
    CostModel,
    RsiScalpParams,
    backtest_rsi_scalping,
    load_rates,
    split_walk_forward,
)
from set_parser import SetParam, parse_set_file

TF_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M10": mt5.TIMEFRAME_M10,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}

SET_TO_PARAM = {
    "RSI_Period": "rsi_period",
    "RSI_Overbought": "rsi_overbought",
    "RSI_Oversold": "rsi_oversold",
    "RSI_Target_Buy": "rsi_target_buy",
    "RSI_Target_Sell": "rsi_target_sell",
    "BarsToWait": "bars_to_wait",
    "UseTrailingStop": "use_trailing",
    "TrailingStopDistancePoints": "trail_distance_pts",
    "TrailingActivationPoints": "trail_activation_pts",
}


def _sample_value(p: SetParam, rng: random.Random) -> Any:
    if not p.optimize:
        return p.value
    if isinstance(p.start, bool):
        return rng.choice([p.start, p.stop])
    if isinstance(p.start, int) and isinstance(p.stop, int):
        step = int(p.step) if int(p.step) != 0 else 1
        vals = list(range(int(p.start), int(p.stop) + 1, step))
        return rng.choice(vals) if vals else p.value
    step = float(p.step) if float(p.step) != 0 else 1.0
    start, stop = float(p.start), float(p.stop)
    n = int((stop - start) / step) + 1
    idx = rng.randint(0, max(n - 1, 0))
    return round(start + idx * step, 4)


def sample_params(set_params: dict[str, SetParam], rng: random.Random, defaults: dict, fixed_lot: float) -> RsiScalpParams:
    raw = dict(defaults)
    for set_name, field in SET_TO_PARAM.items():
        if set_name in set_params:
            raw[field] = _sample_value(set_params[set_name], rng)
    raw["lot_size"] = fixed_lot
    return RsiScalpParams.from_dict(raw)


def _result_dict(r, label: str) -> dict:
    return {
        "label": label,
        "net_profit": r.net_profit,
        "total_trades": r.total_trades,
        "win_rate": r.win_rate,
        "profit_factor": r.profit_factor,
        "max_drawdown_pct": r.max_drawdown_pct,
        "total_costs": r.total_costs,
        "score": r.score,
        "params": r.params.__dict__,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Walk-forward RSI scalping optimizer")
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--timeframe", default="H1", choices=TF_MAP.keys())
    parser.add_argument("--set", required=True)
    parser.add_argument("--trials", type=int, default=800)
    parser.add_argument("--days", type=int, default=730)
    parser.add_argument("--balance", type=float, default=10000.0)
    parser.add_argument("--lot", type=float, default=0.1)
    parser.add_argument("--train-ratio", type=float, default=0.6)
    parser.add_argument("--slippage", type=float, default=3.0)
    parser.add_argument("--commission", type=float, default=0.0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", default="optimization_results")
    args = parser.parse_args()

    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")

    try:
        end = datetime.now()
        start = end - timedelta(days=args.days)
        tf = TF_MAP[args.timeframe]
        df_all = load_rates(args.symbol, tf, start, end)
        train_df, test_df = split_walk_forward(df_all, args.train_ratio)
        costs = CostModel.from_symbol(args.symbol, slippage_points=args.slippage, commission_per_lot=args.commission)

        info = mt5.symbol_info(args.symbol)
        spread = info.spread if info else 0
        print(f"Symbol {args.symbol} spread={spread} pts  slippage={args.slippage}  commission/lot={args.commission}")
        print(f"All: {len(df_all)} bars  train: {len(train_df)} ({train_df.index[0]} -> {train_df.index[-1]})")
        print(f"Test:  {len(test_df)} bars ({test_df.index[0]} -> {test_df.index[-1]})")

        set_params = parse_set_file(args.set)
        defaults = {
            "rsi_period": 14,
            "rsi_overbought": 71.0,
            "rsi_oversold": 57.0,
            "rsi_target_buy": 80.0,
            "rsi_target_sell": 57.0,
            "bars_to_wait": 1,
            "use_trailing": True,
            "trail_distance_pts": 71.0,
            "trail_activation_pts": 41.0,
        }

        baseline_params = RsiScalpParams.from_dict({**defaults, "lot_size": args.lot})
        baseline_train = backtest_rsi_scalping(train_df, args.symbol, baseline_params, args.balance, costs=costs)
        baseline_test = backtest_rsi_scalping(test_df, args.symbol, baseline_params, args.balance, costs=costs)
        baseline_full = backtest_rsi_scalping(df_all, args.symbol, baseline_params, args.balance, costs=costs)

        print("\n--- BASELINE (current SuperEA XAUUSD trailing defaults) ---")
        print(f"  train net=${baseline_train.net_profit:.2f}  trades={baseline_train.total_trades}  dd={baseline_train.max_drawdown_pct:.1f}%")
        print(f"  test  net=${baseline_test.net_profit:.2f}  trades={baseline_test.total_trades}  dd={baseline_test.max_drawdown_pct:.1f}%")
        print(f"  full  net=${baseline_full.net_profit:.2f}  trades={baseline_full.total_trades}  dd={baseline_full.max_drawdown_pct:.1f}%")

        rng = random.Random(args.seed)
        rows = []
        best_oos = None
        best_oos_score = float("-inf")

        for n in range(1, args.trials + 1):
            params = sample_params(set_params, rng, defaults, args.lot)
            train_r = backtest_rsi_scalping(train_df, args.symbol, params, args.balance, costs=costs)
            test_r = backtest_rsi_scalping(test_df, args.symbol, params, args.balance, costs=costs)
            full_r = backtest_rsi_scalping(df_all, args.symbol, params, args.balance, costs=costs)

            row = {
                "trial": n,
                "oos_score": test_r.score,
                "train_net": train_r.net_profit,
                "test_net": test_r.net_profit,
                "full_net": full_r.net_profit,
                "train_trades": train_r.total_trades,
                "test_trades": test_r.total_trades,
                "test_pf": test_r.profit_factor,
                "test_dd_pct": test_r.max_drawdown_pct,
                "test_win_rate": test_r.win_rate,
                **params.__dict__,
            }
            rows.append(row)

            if test_r.total_trades >= 15 and test_r.score > best_oos_score:
                best_oos_score = test_r.score
                best_oos = (params, train_r, test_r, full_r)

            if n % 200 == 0 and best_oos:
                _, _, br_test, _ = best_oos
                print(f"  trial {n}/{args.trials} best OOS net=${br_test.net_profit:.2f} score={best_oos_score:.2f}")

        if best_oos is None:
            raise SystemExit("No valid OOS candidate (need >=15 test trades)")

        best_params, best_train, best_test, best_full = best_oos

        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        results_df = pd.DataFrame(rows).sort_values("oos_score", ascending=False)
        tag = f"{args.symbol}_{args.timeframe}_v2"
        csv_path = out_dir / f"{tag}_rsi_scalp_opt.csv"
        results_df.to_csv(csv_path, index=False)

        report = {
            "version": "v2-conservative-walkforward",
            "symbol": args.symbol,
            "timeframe": args.timeframe,
            "costs": {"spread_pts": spread, "slippage_pts": args.slippage, "commission_per_lot": args.commission},
            "bars": {"all": len(df_all), "train": len(train_df), "test": len(test_df)},
            "periods": {
                "all": [str(df_all.index[0]), str(df_all.index[-1])],
                "train": [str(train_df.index[0]), str(train_df.index[-1])],
                "test": [str(test_df.index[0]), str(test_df.index[-1])],
            },
            "trials": args.trials,
            "baseline": {
                "train": _result_dict(baseline_train, "train"),
                "test": _result_dict(baseline_test, "test"),
                "full": _result_dict(baseline_full, "full"),
            },
            "best_by_oos": {
                "train": _result_dict(best_train, "train"),
                "test": _result_dict(best_test, "test"),
                "full": _result_dict(best_full, "full"),
            },
            "top10_oos": results_df.head(10).to_dict(orient="records"),
        }
        json_path = out_dir / f"{tag}_rsi_scalp_best.json"
        json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

        print("\n=== BEST BY OUT-OF-SAMPLE (validation) ===")
        for k, v in best_params.__dict__.items():
            print(f"  {k}: {v}")
        print(f"  TRAIN net=${best_train.net_profit:.2f}  trades={best_train.total_trades}  dd={best_train.max_drawdown_pct:.1f}%")
        print(f"  TEST  net=${best_test.net_profit:.2f}  trades={best_test.total_trades}  pf={best_test.profit_factor:.2f}  dd={best_test.max_drawdown_pct:.1f}%")
        print(f"  FULL  net=${best_full.net_profit:.2f}  trades={best_full.total_trades}  dd={best_full.max_drawdown_pct:.1f}%")
        print(f"\nSaved: {csv_path}")
        print(f"Saved: {json_path}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
