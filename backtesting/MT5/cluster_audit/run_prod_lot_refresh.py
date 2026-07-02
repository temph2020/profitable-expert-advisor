#!/usr/bin/env python3
"""Lot-opt new production strategies, merge keepers, apply, combined backtest."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.run_lot_genetic import (
    SUMMARY_PATH,
    apply_lots_to_mq5,
    apply_lots_to_set_text,
    common_patches,
    optimize_one,
    save_summary,
)

from cluster_audit.united_mt5_manifest import UNITED_MT5_STRATEGIES
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    CLUSTER,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

# Lots from prior genetic run (unchanged strategies)
KEEPER_LOTS: dict[str, float] = {
    "LOT_DB_DarvasBox": 0.01,
    "LOT_ES_EMASlopeDistance": 0.07,
    "LOT_RC_RSICrossOver": 0.1,
    "LOT_RM_RSIMidPointHijack": 0.01,
    "LOT_RS_NVDA": 5.0,
    "LOT_RS_TSLA": 5.0,
    "LOT_RRA_AUDUSD": 0.05,
    "LOT_UB_USDJPY": 0.03,
    "LOT_RS_NAS100": 0.03,
    "LOT_UKB_UK100": 0.01,
}

NEW_OPT_IDS = (
    "RS_BTCUSD", "RS_XAUUSD", "SE", "ST_BTC", "ST_XAU",
    "RRA_GBP", "GB", "U5B", "RS_US30",
)


def production_enables() -> dict[str, bool]:
    from cluster_audit.united_mt5_manifest import ALL_ENABLE_KEYS, HIGH_MARGIN_STOCK_ENABLES, PRODUCTION_IDS
    prod = set(PRODUCTION_IDS)
    o = {s["enable"]: s["id"] in prod for s in UNITED_MT5_STRATEGIES}
    for k in HIGH_MARGIN_STOCK_ENABLES:
        o[k] = False
    return o


def main() -> None:
    sm = {s["id"]: s for s in UNITED_MT5_STRATEGIES}
    summary = {"results": [], "best_lots": dict(KEEPER_LOTS), "timestamp": datetime.now().isoformat(timespec="seconds")}
    save_summary(summary)

    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])

    print(f"Optimizing {len(NEW_OPT_IDS)} new/changed strategies...", flush=True)
    for sid in NEW_OPT_IDS:
        r = optimize_one(ctx, sm[sid], opt_mode=1, grid_only=True)
        summary["results"].append(r)
        summary["best_lots"][r["lot_key"]] = r["best_lot"]
        save_summary(summary)
        print(f"  {sid} -> {r['lot_key']}={r['best_lot']}", flush=True)

    # Apply all production lots
    lots = summary["best_lots"]
    mq5 = CLUSTER / "main.mq5"
    st = CLUSTER / "123.set"
    mq5.write_text(apply_lots_to_mq5(mq5.read_text(encoding="utf-8"), lots), encoding="utf-8")
    st.write_text(apply_lots_to_set_text(st.read_text(encoding="utf-8"), lots), encoding="utf-8")
    print(f"Applied {len(lots)} lots to main.mq5 + 123.set", flush=True)

    ov = {**common_patches(), **production_enables(), **lots}
    m = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, ov), "prod_v2_combined.set", "prod_v2_combined",
    )
    print(
        f"\nCOMBINED v2  PF={m.get('profit_factor')} net={m.get('net_profit')} "
        f"sharpe={m.get('sharpe')} trades={m.get('total_trades')} dd={m.get('max_drawdown')}",
        flush=True,
    )
    summary["combined_v2"] = m
    save_summary(summary)
    print(f"Saved {SUMMARY_PATH}", flush=True)


if __name__ == "__main__":
    main()
