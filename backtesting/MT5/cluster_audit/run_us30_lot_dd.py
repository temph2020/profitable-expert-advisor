#!/usr/bin/env python3
"""US30 lot sweep — pick lot balancing return vs equity drawdown."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.united_mt5_manifest import ALL_ENABLE_KEYS, UNITED_MT5_STRATEGIES
from cluster_audit.united_mt5_runner import BASE_SET, deploy_united, mt5_context, patch_set, run_backtest

OUT = Path(__file__).resolve().parent / "reports" / "us30_lot_dd"
LOTS = [0.03, 0.04, 0.05, 0.06, 0.07, 0.08]
MAX_DD_PCT = 35.0  # reject lots with equity DD above this


def parse_dd_pct(dd: str | None) -> float | None:
    if not dd:
        return None
    m = re.search(r"([\d.]+)\s*%", str(dd).replace(",", ""))
    return float(m.group(1)) if m else None


def main() -> None:
    sm = {s["id"]: s for s in UNITED_MT5_STRATEGIES}
    spec = sm["RS_US30"]
    ov_base = {
        k: False for k in ALL_ENABLE_KEYS
    }
    ov_base[spec["enable"]] = True
    ov_base.update({
        "ORCH_ReferenceBalance": 3000.0,
        "ORCH_ScaleLotsByBalance": True,
        "GAP_Enable": False,
        "OPT_GuardOptimizationMode": True,
        "EnableRSIScalpingMU": False,
    })

    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])
    OUT.mkdir(parents=True, exist_ok=True)

    trials: list[dict] = []
    best_lot, best_sc, best_row = LOTS[0], -1e18, {}

    for lot in LOTS:
        ov = {**ov_base, spec["lot"]: lot}
        tag = str(lot).replace(".", "p")
        m = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            patch_set(BASE_SET, ov), f"us30_dd_{tag}.set", f"us30_dd_{tag}",
        )
        dd_pct = parse_dd_pct(m.get("max_drawdown"))
        pf = float(m.get("profit_factor") or 0)
        sharpe = float(m.get("sharpe") or 0)
        profit = float(m.get("net_profit") or 0)
        trades = int(m.get("total_trades") or 0)
        if not m.get("ready") or trades < 20 or pf < 1.0:
            sc = -1e10
        elif dd_pct is not None and dd_pct > MAX_DD_PCT:
            sc = sharpe * 500 + profit / 2000 - dd_pct * 100
        else:
            sc = sharpe * 2000 + profit / 500 + pf * 50 - (dd_pct or 0) * 20
        row = {"lot": lot, "dd_pct": dd_pct, "score": sc, "metrics": m}
        trials.append(row)
        print(
            f"lot={lot} PF={pf} net={profit} sharpe={sharpe} dd={m.get('max_drawdown')} sc={sc:.0f}",
            flush=True,
        )
        if sc > best_sc:
            best_sc, best_lot, best_row = sc, lot, row

    # Prefer highest lot under DD cap with PF>=1.1
    under_cap = [t for t in trials if t.get("dd_pct") is not None and t["dd_pct"] <= MAX_DD_PCT
                 and (t["metrics"].get("profit_factor") or 0) >= 1.1]
    if under_cap:
        best_lot = max(under_cap, key=lambda t: t["lot"])["lot"]
        best_row = next(t for t in trials if t["lot"] == best_lot)

    result = {"best_lot": best_lot, "max_dd_cap_pct": MAX_DD_PCT, "best": best_row, "trials": trials}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "us30_lot_dd.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"BEST lot={best_lot} dd={best_row.get('dd_pct')}% PF={best_row['metrics'].get('profit_factor')}", flush=True)


if __name__ == "__main__":
    main()
