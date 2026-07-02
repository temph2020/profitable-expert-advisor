#!/usr/bin/env python3
"""Enable/disable portfolio members from MT5 backtest results (source of truth)."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

LAB = Path(__file__).resolve().parent
PARAMS = LAB / "portfolio_params.json"
MT5 = LAB / "best_run" / "mt5_results.json"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-pf", type=float, default=1.0)
    ap.add_argument("--min-trades", type=int, default=8)
    ap.add_argument("--min-net", type=float, default=0.01)
    args = ap.parse_args()

    if not PARAMS.exists() or not MT5.exists():
        raise SystemExit("Need portfolio_params.json and best_run/mt5_results.json")

    params = json.loads(PARAMS.read_text(encoding="utf-8"))
    mt5 = json.loads(MT5.read_text(encoding="utf-8"))
    by_sym = {r["symbol"]: r for r in mt5.get("per_symbol", []) if r.get("ready")}

    enabled = 0
    for m in params.get("members", []):
        sym = m.get("symbol", "")
        r = by_sym.get(sym)
        if not r:
            m["enabled"] = False
            m["mt5_status"] = "no_mt5_run"
            continue
        ok = (
            (r.get("net_profit") or 0) >= args.min_net
            and (r.get("profit_factor") or 0) >= args.min_pf
            and (r.get("total_trades") or 0) >= args.min_trades
        )
        m["enabled"] = ok
        m["mt5_status"] = "ok" if ok else "rejected"
        m["mt5_metrics"] = {
            "net_profit": r.get("net_profit"),
            "total_trades": r.get("total_trades"),
            "profit_factor": r.get("profit_factor"),
        }
        if ok:
            enabled += 1

    params["selection_source"] = "mt5_strategy_tester"
    params["mt5_enabled_count"] = enabled
    PARAMS.write_text(json.dumps(params, indent=2), encoding="utf-8")

    pf = mt5.get("portfolio", {})
    print(f"Synced {enabled} enabled symbols from MT5")
    print(f"MT5 portfolio trades (all tested): {pf.get('total_trades', 0)}")
    en_trades = sum(m["mt5_metrics"]["total_trades"] for m in params["members"] if m.get("enabled"))
    en_net = sum(m["mt5_metrics"]["net_profit"] for m in params["members"] if m.get("enabled"))
    print(f"MT5 enabled-only: {en_trades} trades  net=${en_net:,.2f}")


if __name__ == "__main__":
    main()
