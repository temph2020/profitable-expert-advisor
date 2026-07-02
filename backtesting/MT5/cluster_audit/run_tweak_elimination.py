#!/usr/bin/env python3
"""
Multi-round elimination audit: small per-strategy tricks vs solo baseline.

Round 1 — each trick vs baseline (123.set, one strategy enabled).
Round 2 — stack non-conflicting WIN tricks from round 1.
Round 3 — ±15% numeric refine around best single winner.

Usage:
  python -m cluster_audit.run_tweak_elimination
  python -m cluster_audit.run_tweak_elimination --only ES --rounds 1
  python -m cluster_audit.run_tweak_elimination --enabled-only --apply
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from set_parser import parse_set_file

from cluster_audit.tweak_manifest import STRATEGY_TWEAKS
from cluster_audit.united_mt5_manifest import ALL_ENABLE_KEYS, UNITED_MT5_STRATEGIES
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    CLUSTER,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

OUT = Path(__file__).resolve().parent / "reports" / "tweak_elimination"
CHECKPOINT = OUT / "checkpoint.json"


def solo_overrides(spec: dict) -> dict:
    o: dict = {k: False for k in ALL_ENABLE_KEYS}
    o[spec["enable"]] = True
    o["GAP_Enable"] = False
    o["OPT_GuardOptimizationMode"] = True
    return o


def g(m: dict, k: str) -> float:
    v = m.get(k)
    return float(v) if v is not None else 0.0


def classify(base: dict, var: dict) -> str:
    if not var.get("ready"):
        return "BROKEN"
    if var.get("total_trades", 0) == 0:
        return "NO_TRADES"
    d_net = g(var, "net_profit") - g(base, "net_profit")
    d_sh = g(var, "sharpe") - g(base, "sharpe")
    if d_net > 35 and d_sh >= -0.05:
        return "WIN"
    if d_net < -35 or d_sh < -0.12:
        return "LOSE"
    return "NEUTRAL"


def delta(base: dict, var: dict) -> dict:
    return {
        "net_profit_delta": g(var, "net_profit") - g(base, "net_profit"),
        "sharpe_delta": g(var, "sharpe") - g(base, "sharpe"),
        "pf_delta": g(var, "profit_factor") - g(base, "profit_factor"),
        "trades_delta": int(g(var, "total_trades") - g(base, "total_trades")),
    }


def merge_params(*dicts: dict) -> dict:
    out: dict = {}
    for d in dicts:
        out.update(d)
    return out


def numeric_refine(params: dict, factor: float) -> dict:
    out: dict = {}
    for k, v in params.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            nv = round(v * factor, 4)
            out[k] = int(nv) if isinstance(v, int) else nv
        else:
            out[k] = v
    return out


def run_variant(ctx: dict, spec: dict, base_ov: dict, extra: dict, tag: str) -> dict:
    ov = {**base_ov, **extra}
    body = patch_set(BASE_SET, ov)
    safe_tag = re.sub(r"[^\w.-]", "_", tag)[:48]
    last: dict = {"ready": False}
    for attempt in range(3):
        if attempt:
            time.sleep(6)
            print(f"    retry {attempt} {safe_tag}", flush=True)
        last = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            body, f"twk_{spec['id']}_{safe_tag}.set", f"twk_{spec['id']}_{safe_tag}",
        )
        if last.get("ready"):
            break
    time.sleep(2)
    return last


def load_checkpoint() -> dict[str, dict]:
    if CHECKPOINT.exists():
        return json.loads(CHECKPOINT.read_text(encoding="utf-8"))
    return {}


def save_checkpoint(all_results: list[dict], *, rounds: int, strategies: list[dict]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    done = {r["id"]: r for r in all_results if "final" in r}
    payload = {
        "updated": datetime.now().isoformat(),
        "rounds": rounds,
        "completed": list(done.keys()),
        "results": all_results,
    }
    CHECKPOINT.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
    summary = {
        "generated": payload["updated"],
        "rounds": rounds,
        "strategies_tested": len(strategies),
        "completed": payload["completed"],
        "applied": [sid for sid, r in done.items() if r.get("final", {}).get("action") == "APPLY"],
        "kept_baseline": [sid for sid, r in done.items() if r.get("final", {}).get("action") == "KEEP_BASELINE"],
        "results": all_results,
    }
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2, default=str), encoding="utf-8")


def round1(ctx: dict, spec: dict, base_ov: dict) -> tuple[dict, list[dict]]:
    sid = spec["id"]
    tricks = STRATEGY_TWEAKS.get(sid, [])
    print(f"\n{'='*60}\n[{sid}] Round 1 — {len(tricks)} tricks\n{'='*60}", flush=True)

    base = run_variant(ctx, spec, base_ov, {}, "base")
    print(f"  BASE net={base.get('net_profit')} sharpe={base.get('sharpe')} "
          f"trades={base.get('total_trades')} ({base.get('elapsed_sec')}s)", flush=True)

    results: list[dict] = []
    for tw in tricks:
        m = run_variant(ctx, spec, base_ov, tw["params"], tw["name"])
        v = classify(base, m)
        d = delta(base, m)
        row = {
            "round": 1,
            "name": tw["name"],
            "params": tw["params"],
            "verdict": v,
            "delta": d,
            "metrics": m,
        }
        results.append(row)
        print(f"  {tw['name']:22s} {v:8s} dNet={d['net_profit_delta']:+.0f} "
              f"dSharpe={d['sharpe_delta']:+.3f} trades={m.get('total_trades')}", flush=True)

    return base, results


def round2(ctx: dict, spec: dict, base_ov: dict, winners: list[dict]) -> list[dict]:
    if len(winners) < 2:
        return []
    sid = spec["id"]
    print(f"  [{sid}] Round 2 — stack {len(winners)} winners", flush=True)
    out: list[dict] = []
    for a, b in combinations(winners, 2):
        keys_a = set(a["params"])
        keys_b = set(b["params"])
        if keys_a & keys_b:
            continue
        combo_name = f"{a['name']}+{b['name']}"
        params = merge_params(a["params"], b["params"])
        m = run_variant(ctx, spec, base_ov, params, combo_name.replace("+", "_"))
        # compare vs best single winner metrics stored in winners
        best_single = max(winners, key=lambda w: g(w["metrics"], "net_profit"))
        v = classify(best_single["metrics"], m)
        d = delta(best_single["metrics"], m)
        row = {
            "round": 2,
            "name": combo_name,
            "params": params,
            "verdict": v,
            "delta_vs_best_single": d,
            "metrics": m,
        }
        out.append(row)
        print(f"    {combo_name:30s} {v:8s} dNet={d['net_profit_delta']:+.0f} "
              f"dSharpe={d['sharpe_delta']:+.3f}", flush=True)
    return out


def round3(ctx: dict, spec: dict, base_ov: dict, best: dict) -> list[dict]:
    sid = spec["id"]
    numeric = {k: v for k, v in best["params"].items() if isinstance(v, (int, float))}
    if not numeric:
        return []
    print(f"  [{sid}] Round 3 — refine {best['name']}", flush=True)
    out: list[dict] = []
    for fac, label in ((0.85, "refine_lo"), (1.15, "refine_hi")):
        params = merge_params(
            {k: v for k, v in best["params"].items() if k not in numeric},
            numeric_refine(numeric, fac),
        )
        m = run_variant(ctx, spec, base_ov, params, f"{best['name']}_{label}")
        v = classify(best["metrics"], m)
        d = delta(best["metrics"], m)
        out.append({
            "round": 3,
            "name": f"{best['name']}_{label}",
            "params": params,
            "verdict": v,
            "delta_vs_best": d,
            "metrics": m,
        })
        print(f"    {label:12s} {v:8s} dNet={d['net_profit_delta']:+.0f} "
              f"dSharpe={d['sharpe_delta']:+.3f}", flush=True)
    return out


def pick_final(base: dict, r1: list[dict], r2: list[dict], r3: list[dict]) -> dict:
    candidates: list[dict] = []
    for r in r1:
        if r["verdict"] == "WIN":
            candidates.append({"source": f"r1:{r['name']}", "params": r["params"], "metrics": r["metrics"]})
    for r in r2:
        if r["verdict"] == "WIN":
            candidates.append({"source": f"r2:{r['name']}", "params": r["params"], "metrics": r["metrics"]})
    for r in r3:
        if r["verdict"] == "WIN":
            candidates.append({"source": f"r3:{r['name']}", "params": r["params"], "metrics": r["metrics"]})

    if not candidates:
        return {"action": "KEEP_BASELINE", "params": {}, "baseline": base}

    best = max(candidates, key=lambda c: (g(c["metrics"], "sharpe"), g(c["metrics"], "net_profit")))
    return {
        "action": "APPLY",
        "source": best["source"],
        "params": best["params"],
        "metrics": best["metrics"],
        "baseline": base,
        "improvement": delta(base, best["metrics"]),
    }


def _format_mq5_value(old_val: str, val: object) -> str:
    old = old_val.strip()
    if isinstance(val, bool):
        return "true" if val else "false"
    if isinstance(val, int):
        return str(val)
    if isinstance(val, float):
        if "." in old:
            return f"{val:.1f}" if val == int(val) else str(val)
        return str(int(val)) if val == int(val) else str(val)
    if isinstance(val, str):
        return f'"{val}"' if not (old.startswith('"') and old.endswith('"')) else f'"{val}"'
    return str(val)


def apply_to_mq5_and_set(winners: dict[str, dict]) -> None:
    mq5 = CLUSTER / "main.mq5"
    st = CLUSTER / "123.set"
    text = mq5.read_text(encoding="utf-8")
    set_lines = st.read_text(encoding="utf-8", errors="ignore").splitlines()
    n_applied = 0

    for _sid, w in winners.items():
        if w.get("action") != "APPLY":
            continue
        for key, val in w["params"].items():
            pat = rf"(input\s+(?:bool|int|double|string|ENUM_\w+)\s+{re.escape(key)}\s*=\s*)([^;]+)(;)"

            def repl(m: re.Match, v: object = val) -> str:
                return f"{m.group(1)}{_format_mq5_value(m.group(2), v)}{m.group(3)}"

            new_text, n = re.subn(pat, repl, text, count=1)
            if n:
                text = new_text
                n_applied += 1
            else:
                print(f"  WARN mq5 miss {key}", flush=True)

            for i, line in enumerate(set_lines):
                if not line.startswith(f"{key}="):
                    continue
                sv = "true" if val is True else "false" if val is False else str(val)
                parts = line.split("||")
                if len(parts) >= 5:
                    parts[0] = f"{key}={sv}"
                    set_lines[i] = "||".join(parts)
                else:
                    set_lines[i] = f"{key}={sv}"
                break

    if re.search(r'#property version\s+"[\d.]+"', text):
        text = re.sub(r'(#property version\s+)"[\d.]+"', r'\g<1>"1.27"', text, count=1)

    mq5.write_text(text, encoding="utf-8")
    st.write_text("\n".join(set_lines) + "\n", encoding="utf-8")
    print(f"Applied {n_applied} param updates -> main.mq5 + 123.set", flush=True)


def audit_strategy(ctx: dict, spec: dict, rounds: int) -> dict:
    base_ov = solo_overrides(spec)
    base, r1 = round1(ctx, spec, base_ov)
    winners = [r for r in r1 if r["verdict"] == "WIN"]

    r2: list[dict] = []
    r3: list[dict] = []
    if rounds >= 2 and len(winners) >= 2:
        r2 = round2(ctx, spec, base_ov, winners)
        winners += [r for r in r2 if r["verdict"] == "WIN"]

    if rounds >= 3 and winners:
        best = max(winners, key=lambda w: g(w["metrics"], "net_profit"))
        r3 = round3(ctx, spec, base_ov, best)
        winners += [r for r in r3 if r["verdict"] == "WIN"]

    final = pick_final(base, r1, r2, r3)
    print(f"  => {final['action']} {final.get('source', '')} "
          f"dNet={final.get('improvement', {}).get('net_profit_delta', 0):+.0f}", flush=True)
    return {
        "id": spec["id"],
        "name": spec["name"],
        "baseline": base,
        "round1": r1,
        "round2": r2,
        "round3": r3,
        "final": final,
        "eliminated": [r["name"] for r in r1 if r["verdict"] == "LOSE"],
        "neutral": [r["name"] for r in r1 if r["verdict"] == "NEUTRAL"],
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--only", default=None)
    p.add_argument("--from", dest="from_id", default=None)
    p.add_argument("--enabled-only", action="store_true")
    p.add_argument("--rounds", type=int, default=3, choices=[1, 2, 3])
    p.add_argument("--apply", action="store_true", help="Write WIN params into main.mq5 + 123.set")
    p.add_argument("--resume", action="store_true", help="Skip strategies already in checkpoint.json")
    args = p.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    base_params = parse_set_file(BASE_SET)

    strategies = list(UNITED_MT5_STRATEGIES)
    if args.enabled_only:
        strategies = [
            s for s in strategies
            if base_params.get(s["enable"], type("x", (), {"value": False})).value
        ]
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

    print(f"Tweak elimination | {len(strategies)} strategies | rounds={args.rounds} | base={BASE_SET.name}")
    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])
    print("Compiled main.ex5 OK", flush=True)

    all_results: list[dict] = []
    if args.resume and CHECKPOINT.exists():
        ck = json.loads(CHECKPOINT.read_text(encoding="utf-8"))
        all_results = ck.get("results", [])
        done_ids = {r["id"] for r in all_results if "final" in r}
        strategies = [s for s in strategies if s["id"] not in done_ids]
        print(f"Resume: skipping {len(done_ids)} done, {len(strategies)} remaining", flush=True)

    for spec in strategies:
        try:
            result = audit_strategy(ctx, spec, args.rounds)
            all_results.append(result)
            save_checkpoint(all_results, rounds=args.rounds, strategies=strategies)
        except Exception as ex:
            print(f"  ERROR {spec['id']}: {ex}", flush=True)
            all_results.append({"id": spec["id"], "error": str(ex)})
            save_checkpoint(all_results, rounds=args.rounds, strategies=strategies)

    apply_map = {r["id"]: r["final"] for r in all_results if "final" in r}
    applied = [sid for sid, f in apply_map.items() if f.get("action") == "APPLY"]

    summary = {
        "generated": datetime.now().isoformat(),
        "rounds": args.rounds,
        "strategies_tested": len(strategies),
        "applied": applied,
        "kept_baseline": [sid for sid, f in apply_map.items() if f.get("action") == "KEEP_BASELINE"],
        "results": all_results,
    }
    out_path = OUT / "summary.json"
    out_path.write_text(json.dumps(summary, indent=2, default=str), encoding="utf-8")
    print(f"\nSaved {out_path}")
    print(f"APPLY ({len(applied)}): {applied}")

    if args.apply and applied:
        apply_to_mq5_and_set(apply_map)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
