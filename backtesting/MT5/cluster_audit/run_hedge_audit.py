#!/usr/bin/env python3
"""
Symbol mining audit for cluster-latest (round 2 = indices, round 3 = low-margin stocks).

Baseline = 123.set + survivors only; solo each candidate round; enhanced = baseline + passers.

Usage:
  python -m cluster_audit.run_hedge_audit --round 2
  python -m cluster_audit.run_hedge_audit --round 3
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.united_mt5_manifest import (
    ALL_ENABLE_KEYS,
    EXPANSION_RETIRED_IDS,
    HIGH_MARGIN_STOCK_ENABLES,
    ROUND2_IDS,
    ROUND3_IDS,
    SURVIVOR_IDS,
    UNITED_MT5_STRATEGIES,
)
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    FROM_DATE,
    TO_DATE,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

OUT = Path(__file__).resolve().parent / "reports" / "hedge_audit"

MIN_TRADES_DEFAULT = 60

ROUND_CONFIG = {
    2: {"candidate_ids": ROUND2_IDS, "prefix": "r2"},
    3: {"candidate_ids": ROUND3_IDS, "prefix": "r3"},
}


def g(m: dict, k: str) -> float:
    v = m.get(k)
    return float(v) if v is not None else 0.0


def spec_map() -> dict[str, dict]:
    return {s["id"]: s for s in UNITED_MT5_STRATEGIES}


def candidate_ids_for_round(round_num: int) -> tuple[str, ...]:
    return ROUND_CONFIG[round_num]["candidate_ids"]


def baseline_overrides(round_num: int) -> dict[str, bool]:
    o: dict[str, bool] = {}
    retired = set(EXPANSION_RETIRED_IDS)
    survivors = set(SURVIVOR_IDS)
    candidates = set(candidate_ids_for_round(round_num))
    all_candidates = set(ROUND2_IDS) | set(ROUND3_IDS)

    for s in UNITED_MT5_STRATEGIES:
        sid = s["id"]
        if sid in retired:
            o[s["enable"]] = False
        elif sid in survivors:
            o[s["enable"]] = True
        elif sid in all_candidates and sid not in candidates:
            o[s["enable"]] = False
        elif sid in candidates:
            o[s["enable"]] = False

    for key in HIGH_MARGIN_STOCK_ENABLES:
        o[key] = False

    o["GAP_Enable"] = False
    o["OPT_GuardOptimizationMode"] = True
    return o


def solo_overrides(spec: dict) -> dict:
    o: dict[str, bool] = {k: False for k in ALL_ENABLE_KEYS}
    o[spec["enable"]] = True
    for key in HIGH_MARGIN_STOCK_ENABLES:
        o[key] = False
    o["GAP_Enable"] = False
    o["OPT_GuardOptimizationMode"] = True
    return o


def classify_solo(m: dict, min_trades: int) -> str:
    if not m.get("ready"):
        return "BROKEN"
    trades = int(m.get("total_trades", 0) or 0)
    if trades < min_trades:
        return "LOW_TRADES"
    if g(m, "net_profit") > 0 and g(m, "profit_factor") >= 1.05:
        return "PASS"
    if g(m, "net_profit") > 50 and g(m, "profit_factor") >= 1.0:
        return "MARGINAL"
    return "FAIL"


def delta(base: dict, var: dict) -> dict:
    return {
        "net_profit_delta": g(var, "net_profit") - g(base, "net_profit"),
        "sharpe_delta": g(var, "sharpe") - g(base, "sharpe"),
        "pf_delta": g(var, "profit_factor") - g(base, "profit_factor"),
        "trades_delta": int(g(var, "total_trades") - g(base, "total_trades")),
    }


def portfolio_verdict(d: dict) -> str:
    if d["net_profit_delta"] > 100 and d["sharpe_delta"] >= -0.05:
        return "IMPROVED"
    if d["net_profit_delta"] < -150 or d["sharpe_delta"] < -0.15:
        return "WORSE"
    return "NEUTRAL"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--from", dest="from_date", default=FROM_DATE)
    p.add_argument("--to", dest="to_date", default=TO_DATE)
    p.add_argument("--min-trades", type=int, default=MIN_TRADES_DEFAULT)
    p.add_argument("--round", type=int, default=3, choices=(2, 3))
    args = p.parse_args()

    import cluster_audit.united_mt5_runner as runner

    runner.FROM_DATE = args.from_date.replace("-", ".")
    runner.TO_DATE = args.to_date.replace("-", ".")

    cfg = ROUND_CONFIG[args.round]
    prefix = cfg["prefix"]
    candidates = cfg["candidate_ids"]

    OUT.mkdir(parents=True, exist_ok=True)
    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])

    sm = spec_map()
    print(
        f"Round {args.round}  {runner.FROM_DATE}->{runner.TO_DATE}  "
        f"min_trades={args.min_trades}  survivor={SURVIVOR_IDS}  "
        f"candidates={candidates}",
        flush=True,
    )

    baseline = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, baseline_overrides(args.round)),
        f"{prefix}_baseline.set", f"{prefix}_baseline",
    )
    print(
        f"BASELINE  PF={baseline.get('profit_factor')} net={baseline.get('net_profit')} "
        f"sharpe={baseline.get('sharpe')} trades={baseline.get('total_trades')}",
        flush=True,
    )

    solo_results: list[dict] = []
    passed: list[str] = []

    for sid in candidates:
        spec = sm[sid]
        m = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            patch_set(BASE_SET, solo_overrides(spec)),
            f"{prefix}_solo_{sid}.set", f"{prefix}_solo_{sid}",
            test_symbol=spec.get("test_symbol"),
        )
        verdict = classify_solo(m, args.min_trades)
        print(
            f"SOLO {sid:10} {verdict:10} PF={m.get('profit_factor')} net={m.get('net_profit')} "
            f"sharpe={m.get('sharpe')} trades={m.get('total_trades')}",
            flush=True,
        )
        solo_results.append({"id": sid, "verdict": verdict, "metrics": m})
        if verdict in ("PASS", "MARGINAL"):
            passed.append(spec["enable"])

    enhanced_ov = baseline_overrides(args.round)
    for sid in candidates:
        spec = sm[sid]
        if spec["enable"] in passed:
            enhanced_ov[spec["enable"]] = True

    enhanced = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, enhanced_ov),
        f"{prefix}_enhanced.set", f"{prefix}_enhanced",
    )
    d = delta(baseline, enhanced)
    pv = portfolio_verdict(d)
    print(
        f"ENHANCED {pv}  PF={enhanced.get('profit_factor')} net={enhanced.get('net_profit')} "
        f"sharpe={enhanced.get('sharpe')} trades={enhanced.get('total_trades')} "
        f"dNet={d['net_profit_delta']:.0f} dSharpe={d['sharpe_delta']:.3f}",
        flush=True,
    )
    print(f"PASSED ({len(passed)}): {', '.join(passed)}", flush=True)

    summary = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "round": args.round,
        "survivors": list(SURVIVOR_IDS),
        "candidates": list(candidates),
        "high_margin_disabled": list(HIGH_MARGIN_STOCK_ENABLES),
        "period": {"from": runner.FROM_DATE, "to": runner.TO_DATE},
        "min_trades": args.min_trades,
        "baseline": baseline,
        "solo": solo_results,
        "passed_enables": passed,
        "enhanced": enhanced,
        "delta": d,
        "portfolio_verdict": pv,
    }
    out_path = OUT / f"round{args.round}_audit_summary.json"
    out_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Saved {out_path}", flush=True)


if __name__ == "__main__":
    main()
