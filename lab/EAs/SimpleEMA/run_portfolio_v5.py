#!/usr/bin/env python3
"""SimpleEMA v5 — 20-symbol portfolio backtest (shared params, per-symbol spread)."""

from __future__ import annotations

import argparse
import json
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
from strategy_v5 import V5Params, load_v5_cache, market_from_cache, simulate_v5  # noqa: E402


def load_portfolio_config(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_best_params(path: Path) -> V5Params:
    data = json.loads(path.read_text(encoding="utf-8"))
    return V5Params(**data["params"])


def portfolio_metrics(trades: pd.DataFrame, initial: float) -> dict:
    if trades.empty:
        return {"net_profit": 0, "total_trades": 0, "profit_factor": 0, "win_rate": 0, "max_drawdown_pct": 0}
    wins = trades[trades["profit"] > 0]["profit"]
    losses = trades[trades["profit"] <= 0]["profit"]
    gp = float(wins.sum()) if len(wins) else 0.0
    gl = abs(float(losses.sum())) if len(losses) else 0.0
    eq = initial + trades.sort_values("close_time")["profit"].cumsum()
    dd = abs(float(((eq - eq.cummax()) / eq.cummax() * 100).min())) if len(eq) else 0.0
    return {
        "net_profit": round(float(trades["profit"].sum()), 2),
        "total_trades": len(trades),
        "profit_factor": round(gp / gl, 2) if gl > 0 else 0.0,
        "win_rate": round(100.0 * len(wins) / len(trades), 1),
        "max_drawdown_pct": round(dd, 2),
        "profitable_symbols": int((trades.groupby("symbol")["profit"].sum() > 0).sum()),
        "symbol_count": trades["symbol"].nunique(),
    }


def load_params_map(args) -> tuple[dict[str, V5Params], float, list[dict]]:
    """Return symbol->params, lot, member metadata (may be empty)."""
    if args.params and args.params.name == "portfolio_params.json" and args.params.exists():
        data = json.loads(args.params.read_text(encoding="utf-8"))
        lot = data.get("config", {}).get("lot_per_symbol", 0.05)
        mapping: dict[str, V5Params] = {}
        members = []
        for m in data.get("members", []):
            if not m.get("enabled", True) or "params" not in m:
                continue
            mapping[m["symbol"]] = V5Params(**m["params"])
            members.append(m)
        return mapping, lot, members

    base = load_best_params(args.params)
    lot = base.lot_size
    return {}, lot, []


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=LAB / "portfolio_symbols.json")
    ap.add_argument("--params", type=Path, default=LAB / "portfolio_params.json")
    ap.add_argument("--shared-params", type=Path, default=LAB / "best_params.json", help="fallback single-param set")
    args = ap.parse_args()

    cfg = load_portfolio_config(args.config)
    per_sym, lot, members = load_params_map(args)
    if not per_sym:
        base = load_best_params(args.shared_params)
        lot = cfg.get("lot_per_symbol", base.lot_size)
    else:
        lot = cfg.get("lot_per_symbol", lot)
    initial = cfg.get("initial_balance", 10000)

    start = datetime.fromisoformat(cfg["period"][0])
    end = datetime.fromisoformat(cfg["period"][1])

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        sym_rows = []
        all_trades: list[dict] = []
        skipped: list[str] = []

        for entry in cfg["symbols"]:
            req = entry["name"]
            try:
                sym = resolve_symbol(req)
                if per_sym and sym not in per_sym:
                    if members:
                        print(f"  SKIP {sym}: disabled in portfolio_params")
                        continue
                spread_cap = entry.get("max_spread_pips", 8.0)
                if per_sym and sym in per_sym:
                    p = per_sym[sym]
                else:
                    base = load_best_params(args.shared_params)
                    p = replace(base, lot_size=lot, max_spread_pips=spread_cap)
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
                        "trades": r.total_trades,
                        "net_profit": round(r.net_profit, 2),
                        "profit_factor": round(r.profit_factor, 2),
                        "win_rate": round(r.win_rate, 1),
                    }
                )
                print(f"  {sym}: t={r.total_trades} net=${r.net_profit:,.0f} PF={r.profit_factor:.2f}")
            except Exception as exc:  # noqa: BLE001
                skipped.append(f"{req}: {exc}")
                print(f"  SKIP {req}: {exc}")

        tdf = pd.DataFrame(all_trades).sort_values(["close_time", "symbol"]) if all_trades else pd.DataFrame()
        metrics = portfolio_metrics(tdf, initial)
        metrics["target_met_2000_trades"] = metrics["total_trades"] >= 2000
        metrics["target_met_profit"] = metrics["net_profit"] > 0

        out = LAB / "best_run"
        out.mkdir(exist_ok=True)
        tdf.to_csv(out / "portfolio_trades.csv", index=False)
        pd.DataFrame(sym_rows).to_csv(out / "portfolio_by_symbol.csv", index=False)

        mode = "per_symbol" if per_sym else "shared"
        payload = {
            "version": 5,
            "mode": mode,
            "symbol_count": len(sym_rows),
            "skipped": skipped,
            "metrics": metrics,
            "per_symbol": sym_rows,
        }
        (LAB / "portfolio_report.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

        print(
            f"\nPORTFOLIO ({len(sym_rows)} symbols): "
            f"net=${metrics['net_profit']:,.0f} trades={metrics['total_trades']} "
            f"PF={metrics['profit_factor']:.2f} WR={metrics['win_rate']:.1f}% "
            f"DD={metrics['max_drawdown_pct']:.1f}% "
            f"2000+={'YES' if metrics['target_met_2000_trades'] else 'no'} "
            f"profit={'YES' if metrics['target_met_profit'] else 'no'}"
        )
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
