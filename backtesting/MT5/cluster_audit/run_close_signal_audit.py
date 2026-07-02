#!/usr/bin/env python3
"""
United EA MT5 audit: per-strategy solo runs, close-unprofitable A/B, lot/margin check.

Usage:
  python -m cluster_audit.run_close_signal_audit
  python -m cluster_audit.run_close_signal_audit --only DB
  python -m cluster_audit.run_close_signal_audit --from RS_NVDA --combo
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from set_parser import parse_set_file

from cluster_audit.united_mt5_manifest import (
    ALL_ENABLE_KEYS,
    PARAM_TWEAKS,
    PRODUCTION_IDS,
    UNITED_MT5_STRATEGIES,
)
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

OUT = Path(__file__).parent / "reports" / "close_signal_audit"
LOT_SUMMARY = Path(__file__).parent / "reports" / "lot_genetic" / "lot_genetic_summary.json"
REF_BALANCE = 3000.0


def load_best_lots() -> dict[str, float]:
    if not LOT_SUMMARY.exists():
        return {}
    data = json.loads(LOT_SUMMARY.read_text(encoding="utf-8"))
    return {k: float(v) for k, v in data.get("best_lots", {}).items()}


def solo_patches(spec: dict, *, close_on: bool, lots: dict[str, float]) -> dict:
    ov = solo_overrides(spec, close_on=close_on)
    ov["ORCH_ReferenceBalance"] = REF_BALANCE
    ov["ORCH_ScaleLotsByBalance"] = True
    if spec.get("lot") in lots:
        ov[spec["lot"]] = lots[spec["lot"]]
    return ov


def solo_overrides(target: dict, *, close_on: bool) -> dict[str, bool]:
    o: dict[str, bool] = {k: False for k in ALL_ENABLE_KEYS}
    o[target["enable"]] = True
    o[target["close"]] = close_on
    o["GAP_Enable"] = False
    o["OPT_GuardOptimizationMode"] = True
    return o


def audit_one(ctx: dict, spec: dict, base_params: dict, lots: dict[str, float]) -> dict:
    sid = spec["id"]
    print(f"\n{'='*60}\n[{sid}] {spec['name']}\n{'='*60}", flush=True)

    off_ov = solo_patches(spec, close_on=False, lots=lots)
    on_ov = solo_patches(spec, close_on=True, lots=lots)

    off_body = patch_set(BASE_SET, off_ov)
    on_body = patch_set(BASE_SET, on_ov)
    ts = spec.get("test_symbol")

    off = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        off_body, f"solo_{sid}_off.set", f"solo_{sid}_off",
        test_symbol=ts,
    )
    print(f"  OFF  PF={off.get('profit_factor')} net={off.get('net_profit')} "
          f"trades={off.get('total_trades')} sharpe={off.get('sharpe')} "
          f"ready={off.get('ready')} ({off.get('elapsed_sec')}s)", flush=True)

    on = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        on_body, f"solo_{sid}_on.set", f"solo_{sid}_on",
        test_symbol=ts,
    )
    print(f"  ON   PF={on.get('profit_factor')} net={on.get('net_profit')} "
          f"trades={on.get('total_trades')} sharpe={on.get('sharpe')} "
          f"ready={on.get('ready')} ({on.get('elapsed_sec')}s)", flush=True)

    d = delta_metrics(off, on)
    v = verdict(d, off, on)
    print(f"  -> {v}  dNet={d['net_profit_delta']:.0f} dSharpe={d['sharpe_delta']:.3f} "
          f"dTrades={d['trades_delta']}", flush=True)

    tweaks: list[dict] = []
    if v == "POSITIVE" and sid in PARAM_TWEAKS:
        for i, tw in enumerate(PARAM_TWEAKS[sid], 1):
            ov = {**on_ov, **tw}
            body = patch_set(BASE_SET, ov)
            r = run_backtest(
                ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
                body, f"solo_{sid}_tw{i}.set", f"solo_{sid}_tw{i}",
                test_symbol=ts,
            )
            tweaks.append({"tweak": tw, "metrics": r})
            print(f"  tweak{i} net={r.get('net_profit')} sharpe={r.get('sharpe')} "
                  f"trades={r.get('total_trades')}", flush=True)

    lot_key = spec["lot"]
    lot_val = lots.get(lot_key)
    if lot_val is None and lot_key in base_params:
        lot_val = base_params[lot_key].value

    return {
        "id": sid,
        "name": spec["name"],
        "enable": spec["enable"],
        "close_key": spec["close"],
        "lot_key": lot_key,
        "lot_value": lot_val,
        "close_off": off,
        "close_on": on,
        "delta": d,
        "verdict": v,
        "margin_ok_off": margin_ok(off),
        "margin_ok_on": margin_ok(on),
        "param_tweaks": tweaks,
        "recommend_close_on": v == "POSITIVE",
    }


def delta_metrics(off: dict, on: dict) -> dict:
    def g(d, k):
        v = d.get(k)
        return v if v is not None else 0

    return {
        "net_profit_delta": g(on, "net_profit") - g(off, "net_profit"),
        "pf_delta": (g(on, "profit_factor") - g(off, "profit_factor")),
        "sharpe_delta": g(on, "sharpe") - g(off, "sharpe"),
        "trades_delta": g(on, "total_trades") - g(off, "total_trades"),
    }


def verdict(delta: dict, off: dict, on: dict) -> str:
    if not off.get("ready") or not on.get("ready"):
        return "BROKEN"
    if off.get("total_trades", 0) == 0 and on.get("total_trades", 0) == 0:
        return "NO_TRADES"
    if delta["net_profit_delta"] > 50 and delta["sharpe_delta"] >= 0:
        return "POSITIVE"
    if delta["net_profit_delta"] < -50 or delta["sharpe_delta"] < -0.1:
        return "NEGATIVE"
    return "NEUTRAL"


def margin_ok(m: dict) -> bool:
    ml = m.get("min_margin_level")
    if not ml:
        return True
    if isinstance(ml, str) and "%" in ml:
        try:
            return float(ml.replace("%", "").strip()) >= 100.0
        except ValueError:
            return True
    return True


def run_combo(ctx: dict, winners: list[dict], base_params: dict) -> dict:
    """Combo: enable all strategies that benefit from close-on, with flag set."""
    overrides: dict = {k: False for k in ALL_ENABLE_KEYS}
    overrides["GAP_Enable"] = False
    for w in winners:
        overrides[w["enable"]] = True
        overrides[w["close_key"]] = True
    for spec in UNITED_MT5_STRATEGIES:
        if spec["enable"] not in overrides or not overrides[spec["enable"]]:
            continue
        if spec["id"] not in {w["id"] for w in winners}:
            overrides[spec["close_key"]] = False

    body = patch_set(BASE_SET, overrides)
    m = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        body, "combo_close_winners.set", "combo_close_winners",
    )
    return {"members": [w["id"] for w in winners], "metrics": m}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--only", default=None)
    p.add_argument("--from", dest="from_id", default=None)
    p.add_argument("--production", action="store_true", help="Only PRODUCTION_IDS (19 strategies)")
    p.add_argument("--combo", action="store_true")
    p.add_argument("--enabled-only", action="store_true", help="Only strategies enabled in 123.set")
    args = p.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    base_params = parse_set_file(BASE_SET)
    lots = load_best_lots()
    sm = {s["id"]: s for s in UNITED_MT5_STRATEGIES}

    if args.production:
        strategies = [sm[sid] for sid in PRODUCTION_IDS if sid in sm]
    elif args.enabled_only:
        strategies = [
            s for s in UNITED_MT5_STRATEGIES
            if base_params.get(s["enable"], type("x", (), {"value": False})).value
        ]
    else:
        strategies = list(UNITED_MT5_STRATEGIES)

    if args.only:
        strategies = [s for s in strategies if s["id"] == args.only]
    elif args.from_id:
        found = False
        filtered = []
        for s in strategies:
            if s["id"] == args.from_id:
                found = True
            if found:
                filtered.append(s)
        strategies = filtered if found else strategies

    print(f"United EA close-signal audit | {len(strategies)} strategies | lots={len(lots)}")
    import cluster_audit.united_mt5_runner as runner
    runner.DEPOSIT = int(REF_BALANCE)
    ctx = mt5_context()
    print(f"MT5 server={ctx['server']} (account from local terminal)")
    deploy_united(ctx["data"], ctx["mt5_path"])
    print("Compiled main.ex5 OK")

    results: list[dict] = []
    for spec in strategies:
        try:
            results.append(audit_one(ctx, spec, base_params, lots))
        except Exception as ex:
            print(f"  ERROR {spec['id']}: {ex}", flush=True)
            results.append({"id": spec["id"], "error": str(ex), "verdict": "ERROR"})

    positive = [r for r in results if r.get("verdict") == "POSITIVE"]
    negative = [r for r in results if r.get("verdict") == "NEGATIVE"]
    broken = [r for r in results if r.get("verdict") in ("BROKEN", "NO_TRADES", "ERROR")]

    combo_result = None
    if args.combo and positive:
        combo_result = run_combo(ctx, positive, base_params)
        print(f"\nCOMBO winners ({len(positive)}): net={combo_result['metrics'].get('net_profit')} "
              f"sharpe={combo_result['metrics'].get('sharpe')}")

    summary = {
        "generated": datetime.now().isoformat(),
        "base_set": str(BASE_SET),
        "positive_close_on": [r["id"] for r in positive],
        "negative_close_on": [r["id"] for r in negative],
        "broken": [r["id"] for r in broken],
        "results": results,
        "combo": combo_result,
    }
    out_path = OUT / "summary.json"
    out_path.write_text(json.dumps(summary, indent=2, default=str), encoding="utf-8")
    print(f"\nSaved {out_path}")
    print(f"POSITIVE ({len(positive)}): {[r['id'] for r in positive]}")
    print(f"NEGATIVE ({len(negative)}): {[r['id'] for r in negative]}")
    print(f"BROKEN   ({len(broken)}): {[r['id'] for r in broken]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
