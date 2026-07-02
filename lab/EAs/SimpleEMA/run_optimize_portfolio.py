#!/usr/bin/env python3
"""Per-symbol v5 optimization + portfolio assembly."""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import asdict, replace
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
from run_optimize_v5 import seed_params  # noqa: E402
from run_portfolio_v5 import load_portfolio_config, portfolio_metrics  # noqa: E402
from strategy_v5 import V5Params, load_v5_cache, market_from_cache, sample_v5, simulate_v5  # noqa: E402

OUT_PATH = LAB / "portfolio_params.json"
TRIALS_DIR = LAB / "portfolio_opt_trials"


def is_metal(name: str) -> bool:
    base = name.upper().split(".")[0]
    return base.startswith("XAU") or base.startswith("XAG")


def is_index(name: str) -> bool:
    base = name.upper().split(".")[0]
    return base in {"US500", "NAS100", "US30", "GER40", "UK100", "JPN225", "SPX500", "USTEC"}


def is_crypto(name: str) -> bool:
    base = name.upper().split(".")[0]
    return base.startswith("BTC") or base.startswith("ETH")


def high_freq_seeds() -> list[V5Params]:
    return [
        V5Params(fast_ema=8, slow_ema=30, cross_cooldown=2, pullback_cooldown=2, use_pullback=True, trend_leg_bars=48),
        V5Params(fast_ema=9, slow_ema=34, cross_cooldown=3, pullback_cooldown=2, use_pullback=True, htf_ema_period=100),
        V5Params(fast_ema=10, slow_ema=36, cross_cooldown=2, use_pullback=False, htf_ema_period=100),
        V5Params(fast_ema=11, slow_ema=40, cross_cooldown=4, use_pullback=True, pullback_touch=1, pullback_adx_min=20),
    ]


def all_seeds() -> list[V5Params]:
    return seed_params() + high_freq_seeds()


def sample_for_symbol(rng: random.Random, name: str) -> V5Params:
    p = sample_v5(rng)
    p.cross_cooldown = rng.choice([2, 3, 4, 5, 6])
    p.pullback_cooldown = rng.choice([2, 3, 4])
    if is_metal(name):
        p.max_spread_pips = rng.choice([30.0, 35.0, 40.0, 50.0, 60.0])
        p.min_ema_gap_pips = round(rng.uniform(1.0, 4.0), 1)
        p.atr_sl_mult = round(rng.uniform(2.0, 3.5), 2)
        p.atr_tp_mult = round(rng.uniform(3.5, 6.5), 2)
    elif is_index(name) or is_crypto(name):
        p.max_spread_pips = rng.choice([15.0, 20.0, 30.0, 40.0, 50.0])
        p.min_ema_gap_pips = round(rng.uniform(2.0, 8.0), 1)
        p.atr_sl_mult = round(rng.uniform(2.0, 3.2), 2)
        p.atr_tp_mult = round(rng.uniform(3.0, 5.5), 2)
    elif "JPY" in name.upper():
        p.max_spread_pips = rng.choice([8.0, 10.0, 12.0, 15.0, 18.0])
    return p


def score_result(r, min_trades: int) -> float:
    if r.total_trades < min_trades:
        return -1e6 + r.net_profit
    if r.net_profit > 0 and r.profit_factor >= 1.05:
        return r.net_profit + r.total_trades * 4.0
    if r.net_profit > 0 and r.profit_factor >= 1.0:
        return r.net_profit + r.total_trades * 2.0
    return r.net_profit + r.total_trades * 0.1


def pick_best(trials: list[tuple], min_trades: int) -> tuple | None:
    if not trials:
        return None
    profitable = [t for t in trials if t[0].net_profit > 0 and t[0].profit_factor >= 1.03 and t[0].total_trades >= min_trades]
    if profitable:
        return max(profitable, key=lambda t: score_result(t[0], min_trades))
    positive = [t for t in trials if t[0].net_profit > 0 and t[0].total_trades >= min_trades]
    if positive:
        return max(positive, key=lambda t: score_result(t[0], min_trades))
    return max(trials, key=lambda t: score_result(t[0], min_trades))


def optimize_symbol(
    req: str,
    spread_cap: float,
    lot: float,
    start: datetime,
    end: datetime,
    trials: int,
    min_trades: int,
    seed: int,
) -> dict:
    sym = resolve_symbol(req)
    df = load_bars(sym, mt5.TIMEFRAME_M15, start, end)
    cache = load_v5_cache(df)
    pip = pip_size(sym)
    point = float(mt5.symbol_info(sym).point)
    costs = CostModel.for_symbol(sym)
    rng = random.Random(hash(sym) ^ seed)

    results: list[tuple] = []
    seeds = all_seeds()
    for p0 in seeds:
        p = replace(p0, lot_size=lot, max_spread_pips=spread_cap)
        r = simulate_v5(market_from_cache(cache, p), sym, p, costs, pip, point)
        results.append((r, p))

    for _ in range(max(0, trials - len(seeds))):
        p = replace(sample_for_symbol(rng, sym), lot_size=lot, max_spread_pips=spread_cap)
        r = simulate_v5(market_from_cache(cache, p), sym, p, costs, pip, point)
        results.append((r, p))

    best_r, best_p = pick_best(results, min_trades)
    assert best_r and best_p

    enabled = best_r.net_profit > 0 and best_r.profit_factor >= 1.0 and best_r.total_trades >= min_trades
    row = {
        "requested": req,
        "symbol": sym,
        "enabled": True,
        "max_spread_pips": spread_cap,
        "params": asdict(best_p),
        "metrics": {k: v for k, v in asdict(best_r).items() if k != "trades"},
        "score": round(score_result(best_r, min_trades), 2),
    }

    TRIALS_DIR.mkdir(exist_ok=True)
    pd.DataFrame(
        [{"net": r.net_profit, "trades": r.total_trades, "pf": r.profit_factor, **asdict(p)} for r, p in results]
    ).to_csv(TRIALS_DIR / f"{sym.replace('.', '_')}.csv", index=False)

    flag = "PY" if enabled else "py-"
    print(
        f"  [{flag}] {sym}: net=${best_r.net_profit:,.0f} t={best_r.total_trades} "
        f"PF={best_r.profit_factor:.2f} WR={best_r.win_rate:.1f}%"
    )
    return row


def run_portfolio_backtest(members: list[dict], start: datetime, end: datetime, initial: float) -> tuple[pd.DataFrame, list[dict], dict]:
    all_trades: list[dict] = []
    sym_rows: list[dict] = []

    for m in members:
        if not m.get("enabled", True):
            continue
        sym = m["symbol"]
        p = V5Params(**m["params"])
        df = load_bars(sym, mt5.TIMEFRAME_M15, start, end)
        pip = pip_size(sym)
        point = float(mt5.symbol_info(sym).point)
        costs = CostModel.for_symbol(sym)
        r = simulate_v5(market_from_cache(load_v5_cache(df), p), sym, p, costs, pip, point)
        for t in r.trades:
            all_trades.append(
                {
                    "symbol": sym,
                    "side": t["side"],
                    "open_time": df.index[t["open_i"]],
                    "close_time": df.index[t["close_i"]],
                    "profit": round(t["profit"], 2),
                    "exit_reason": t["exit_reason"],
                }
            )
        sym_rows.append(
            {
                "symbol": sym,
                "enabled": True,
                "trades": r.total_trades,
                "net_profit": round(r.net_profit, 2),
                "profit_factor": round(r.profit_factor, 2),
                "win_rate": round(r.win_rate, 1),
            }
        )

    tdf = pd.DataFrame(all_trades).sort_values(["close_time", "symbol"]) if all_trades else pd.DataFrame()
    metrics = portfolio_metrics(tdf, initial)
    metrics["target_met_2000_trades"] = metrics["total_trades"] >= 2000
    metrics["target_met_profit"] = metrics["net_profit"] > 0
    return tdf, sym_rows, metrics


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=LAB / "portfolio_symbols.json")
    ap.add_argument("--trials", type=int, default=350, help="trials per symbol")
    ap.add_argument("--min-trades", type=int, default=15)
    ap.add_argument("--min-pf", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip-opt", action="store_true", help="only rebuild portfolio from existing portfolio_params.json")
    args = ap.parse_args()

    cfg = load_portfolio_config(args.config)
    start = datetime.fromisoformat(cfg["period"][0])
    end = datetime.fromisoformat(cfg["period"][1])
    lot = cfg.get("lot_per_symbol", 0.05)
    initial = cfg.get("initial_balance", 10000.0)

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        members: list[dict] = []
        if not args.skip_opt:
            print(f"Per-symbol optimize: {len(cfg['symbols'])} symbols x {args.trials} trials")
            for entry in cfg["symbols"]:
                try:
                    members.append(
                        optimize_symbol(
                            entry["name"],
                            entry.get("max_spread_pips", 8.0),
                            lot,
                            start,
                            end,
                            args.trials,
                            args.min_trades,
                            args.seed,
                        )
                    )
                except Exception as exc:  # noqa: BLE001
                    print(f"  FAIL {entry['name']}: {exc}")
                    members.append(
                        {
                            "requested": entry["name"],
                            "symbol": entry["name"],
                            "enabled": False,
                            "error": str(exc),
                        }
                    )
        else:
            existing = json.loads(OUT_PATH.read_text(encoding="utf-8"))
            members = existing["members"]

        enabled_n = sum(1 for m in members if m.get("enabled"))
        print(f"\nPortfolio assembly: {enabled_n}/{len(members)} symbols enabled")

        tdf, sym_rows, metrics = run_portfolio_backtest(members, start, end, initial)

        out = LAB / "best_run"
        out.mkdir(exist_ok=True)
        tdf.to_csv(out / "portfolio_trades.csv", index=False)
        pd.DataFrame(sym_rows).to_csv(out / "portfolio_by_symbol.csv", index=False)

        payload = {
            "version": 5,
            "mode": "per_symbol_optimized",
            "optimized_at": datetime.now().isoformat(timespec="seconds"),
            "config": cfg,
            "selection": {
                "min_trades": args.min_trades,
                "min_pf": args.min_pf,
                "trials_per_symbol": args.trials,
            },
            "members": members,
            "portfolio_metrics": metrics,
            "per_symbol_live": sym_rows,
        }
        OUT_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        (LAB / "portfolio_report.json").write_text(
            json.dumps({"metrics": metrics, "per_symbol": sym_rows, "enabled_count": enabled_n}, indent=2),
            encoding="utf-8",
        )

        print(
            f"\nPORTFOLIO: net=${metrics['net_profit']:,.0f} trades={metrics['total_trades']} "
            f"PF={metrics['profit_factor']:.2f} WR={metrics['win_rate']:.1f}% DD={metrics['max_drawdown_pct']:.1f}% "
            f"2000+={'YES' if metrics['target_met_2000_trades'] else 'no'} profit={'YES' if metrics['target_met_profit'] else 'no'}"
        )
        print(f"Saved {OUT_PATH}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
