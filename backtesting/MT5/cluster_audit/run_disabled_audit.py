#!/usr/bin/env python3
"""
Solo MT5 audit for all currently-disabled sub-strategies (main.mq5 enable=false).

Finds profitable passers to add to the cluster; compares enhanced portfolio vs production baseline.

Usage:
  python -m cluster_audit.run_disabled_audit
  python -m cluster_audit.run_disabled_audit --min-trades 40
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.united_mt5_manifest import (
    ALL_ENABLE_KEYS,
    HIGH_MARGIN_STOCK_ENABLES,
    PRODUCTION_IDS,
    UNITED_MT5_STRATEGIES,
)
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    CLUSTER,
    FROM_DATE,
    TO_DATE,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

OUT = Path(__file__).resolve().parent / "reports" / "disabled_audit"
REF_BALANCE = 3000.0


def g(m: dict, k: str) -> float:
    v = m.get(k)
    return float(v) if v is not None else 0.0


def parse_dd_pct(dd: str | None) -> float | None:
    if not dd:
        return None
    m = re.search(r"([\d.]+)\s*%", dd.replace(",", ""))
    return float(m.group(1)) if m else None


def disabled_ids_from_mq5() -> list[str]:
    text = (CLUSTER / "main.mq5").read_text(encoding="utf-8")
    off: set[str] = set()
    for m in re.finditer(r"input bool (Enable\w+) = false", text):
        off.add(m.group(1))
    for key in HIGH_MARGIN_STOCK_ENABLES:
        off.discard(key)
    ids: list[str] = []
    for s in UNITED_MT5_STRATEGIES:
        if s["enable"] in off:
            ids.append(s["id"])
    return ids


def common_patches() -> dict[str, float | bool]:
    return {
        "ORCH_ReferenceBalance": REF_BALANCE,
        "ORCH_ScaleLotsByBalance": True,
        "GAP_Enable": False,
        "OPT_GuardOptimizationMode": True,
    }


def production_enables() -> dict[str, bool]:
    prod = set(PRODUCTION_IDS)
    o: dict[str, bool] = {}
    for s in UNITED_MT5_STRATEGIES:
        o[s["enable"]] = s["id"] in prod
    for key in HIGH_MARGIN_STOCK_ENABLES:
        o[key] = False
    return o


def solo_overrides(spec: dict) -> dict[str, bool]:
    o: dict[str, bool] = {k: False for k in ALL_ENABLE_KEYS}
    o[spec["enable"]] = True
    return o


def classify(m: dict, min_trades: int) -> str:
    if not m.get("ready"):
        return "BROKEN"
    trades = int(m.get("total_trades") or 0)
    if trades < min_trades:
        return "LOW_TRADES"
    if g(m, "net_profit") > 0 and g(m, "profit_factor") >= 1.05:
        return "PASS"
    if g(m, "net_profit") > 50 and g(m, "profit_factor") >= 1.0:
        return "MARGINAL"
    return "FAIL"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--from", dest="from_date", default=FROM_DATE)
    p.add_argument("--to", dest="to_date", default=TO_DATE)
    p.add_argument("--min-trades", type=int, default=60)
    args = p.parse_args()

    import cluster_audit.united_mt5_runner as runner

    runner.FROM_DATE = args.from_date.replace("-", ".")
    runner.TO_DATE = args.to_date.replace("-", ".")
    runner.DEPOSIT = int(REF_BALANCE)

    sm = {s["id"]: s for s in UNITED_MT5_STRATEGIES}
    disabled = disabled_ids_from_mq5()
    OUT.mkdir(parents=True, exist_ok=True)

    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])

    print(
        f"Disabled audit  n={len(disabled)}  production={PRODUCTION_IDS}  "
        f"{runner.FROM_DATE}->{runner.TO_DATE}",
        flush=True,
    )

    prod_ov = {**common_patches(), **production_enables()}
    baseline = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, prod_ov), "dis_prod_baseline.set", "dis_prod_baseline",
    )
    print(
        f"PROD baseline PF={baseline.get('profit_factor')} net={baseline.get('net_profit')} "
        f"sharpe={baseline.get('sharpe')} dd={baseline.get('max_drawdown')}",
        flush=True,
    )

    solo_rows: list[dict] = []
    passed_ids: list[str] = []

    for sid in disabled:
        spec = sm[sid]
        m = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            patch_set(BASE_SET, {**common_patches(), **solo_overrides(spec)}),
            f"dis_solo_{sid}.set", f"dis_solo_{sid}",
            test_symbol=spec.get("test_symbol"),
        )
        verdict = classify(m, args.min_trades)
        dd_pct = parse_dd_pct(m.get("max_drawdown"))
        print(
            f"  {sid:12} {verdict:10} PF={m.get('profit_factor')} net={m.get('net_profit')} "
            f"sharpe={m.get('sharpe')} trades={m.get('total_trades')} dd={m.get('max_drawdown')}",
            flush=True,
        )
        row = {"id": sid, "enable": spec["enable"], "verdict": verdict, "dd_pct": dd_pct, "metrics": m}
        solo_rows.append(row)
        if verdict in ("PASS", "MARGINAL"):
            passed_ids.append(sid)

    enhanced_ov = dict(prod_ov)
    for sid in passed_ids:
        enhanced_ov[sm[sid]["enable"]] = True
    enhanced = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, enhanced_ov), "dis_enhanced.set", "dis_enhanced",
    )
    print(
        f"ENHANCED +{len(passed_ids)} PF={enhanced.get('profit_factor')} net={enhanced.get('net_profit')} "
        f"sharpe={enhanced.get('sharpe')} dd={enhanced.get('max_drawdown')}",
        flush=True,
    )
    print(f"PASS/MARGINAL: {passed_ids}", flush=True)

    summary = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "period": {"from": runner.FROM_DATE, "to": runner.TO_DATE},
        "min_trades": args.min_trades,
        "disabled_ids": disabled,
        "production_baseline": baseline,
        "solo": solo_rows,
        "passed_ids": passed_ids,
        "enhanced": enhanced,
    }
    path = OUT / "disabled_audit_summary.json"
    path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Saved {path}", flush=True)


if __name__ == "__main__":
    main()
