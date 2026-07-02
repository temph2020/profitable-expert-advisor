#!/usr/bin/env python3
"""
MT5 lot-size sweep per production sub-strategy, then combined portfolio.

Constraints:
  - ORCH_ReferenceBalance = 3000 (deposit also 3000)
  - Stock lots capped at 15 shares

Usage:
  python -m cluster_audit.run_lot_optimize
  python -m cluster_audit.run_lot_optimize --only RS_NVDA
  python -m cluster_audit.run_lot_optimize --apply
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
    LOT_CLASS_BY_ID,
    LOT_GRIDS,
    PRODUCTION_IDS,
    UNITED_MT5_STRATEGIES,
)
from cluster_audit.united_mt5_runner import (
    BASE_SET,
    CLUSTER,
    DEPOSIT,
    FROM_DATE,
    TO_DATE,
    deploy_united,
    mt5_context,
    patch_set,
    run_backtest,
)

OUT = Path(__file__).resolve().parent / "reports" / "lot_optimize"
STOCK_LOT_MAX = 15.0
REF_BALANCE = 3000.0
MIN_TRADES = 20


def g(m: dict, k: str) -> float:
    v = m.get(k)
    return float(v) if v is not None else 0.0


def spec_map() -> dict[str, dict]:
    return {s["id"]: s for s in UNITED_MT5_STRATEGIES}


def lot_class(sid: str) -> str:
    return LOT_CLASS_BY_ID.get(sid, "forex")


def lot_grid(sid: str) -> list[float]:
    cls = lot_class(sid)
    grid = list(LOT_GRIDS.get(cls, LOT_GRIDS["forex"]))
    if cls == "stock":
        grid = [x for x in grid if x <= STOCK_LOT_MAX]
    return grid


def score(m: dict) -> float:
    if not m.get("ready"):
        return -1e12
    trades = int(m.get("total_trades") or 0)
    if trades < MIN_TRADES:
        return -1e11 + trades
    net = g(m, "net_profit")
    pf = g(m, "profit_factor")
    sharpe = g(m, "sharpe")
    if net <= 0 or pf < 1.0:
        return -1e10 + net
    return sharpe * 2000.0 + net / 500.0 + pf * 50.0


def common_patches() -> dict[str, float | bool]:
    o: dict[str, float | bool] = {
        "ORCH_ReferenceBalance": REF_BALANCE,
        "ORCH_ScaleLotsByBalance": True,
        "GAP_Enable": False,
        "OPT_GuardOptimizationMode": True,
    }
    for key in HIGH_MARGIN_STOCK_ENABLES:
        o[key] = False
    return o


def production_enables() -> dict[str, bool]:
    prod = set(PRODUCTION_IDS)
    o: dict[str, bool] = {}
    for s in UNITED_MT5_STRATEGIES:
        o[s["enable"]] = s["id"] in prod
    return o


def solo_overrides(spec: dict) -> dict[str, bool]:
    o: dict[str, bool] = {k: False for k in ALL_ENABLE_KEYS}
    o[spec["enable"]] = True
    return o


def apply_lots_to_set_text(text: str, lots: dict[str, float]) -> str:
    lines_out: list[str] = []
    for line in text.splitlines():
        if "=" not in line or line.strip().startswith(";"):
            lines_out.append(line)
            continue
        key = line.split("=", 1)[0].strip()
        if key in lots:
            val = lots[key]
            sval = str(int(val)) if val == int(val) else str(val)
            if "||" in line:
                parts = line.split("||")
                parts[0] = f"{key}={sval}"
                lines_out.append("||".join(parts))
            else:
                lines_out.append(f"{key}={sval}")
        else:
            lines_out.append(line)
    for key, val in lots.items():
        if not any(l.startswith(f"{key}=") for l in lines_out):
            sval = str(int(val)) if val == int(val) else str(val)
            lines_out.append(f"{key}={sval}||{sval}||0||{sval}||N")
    return "\n".join(lines_out) + "\n"


def apply_lots_to_mq5(text: str, lots: dict[str, float]) -> str:
    for key, val in lots.items():
        sval = str(int(val)) if val == int(val) else str(val)
        text, n = re.subn(
            rf"(input double {re.escape(key)} = )[0-9.]+;",
            rf"\g<1>{sval};",
            text,
            count=1,
        )
        if n == 0:
            print(f"  warn: {key} not found in main.mq5", flush=True)
    text, n = re.subn(
        r"(input double ORCH_ReferenceBalance = )[0-9.]+;",
        rf"\g<1>{REF_BALANCE};",
        text,
        count=1,
    )
    return text


def optimize_one(ctx: dict, spec: dict, sm: dict[str, dict]) -> dict:
    sid = spec["id"]
    lot_key = spec["lot"]
    grid = lot_grid(sid)
    print(f"\n[{sid}] grid={grid} class={lot_class(sid)}", flush=True)

    best_lot = grid[0]
    best_m: dict = {"ready": False}
    best_sc = -1e12
    trials: list[dict] = []

    for lot in grid:
        ov: dict = {**common_patches(), **solo_overrides(spec), lot_key: lot}
        body = patch_set(BASE_SET, ov)
        m = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            body, f"lot_{sid}_{lot}.set", f"lot_{sid}_{lot}",
            test_symbol=spec.get("test_symbol"),
        )
        sc = score(m)
        trials.append({"lot": lot, "score": sc, "metrics": m})
        print(
            f"  lot={lot:6} sc={sc:10.1f} PF={m.get('profit_factor')} "
            f"net={m.get('net_profit')} sharpe={m.get('sharpe')} trades={m.get('total_trades')}",
            flush=True,
        )
        if sc > best_sc:
            best_sc = sc
            best_lot = lot
            best_m = m

    return {
        "id": sid,
        "lot_key": lot_key,
        "lot_class": lot_class(sid),
        "best_lot": best_lot,
        "best_score": best_sc,
        "best_metrics": best_m,
        "trials": trials,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--from", dest="from_date", default=FROM_DATE)
    p.add_argument("--to", dest="to_date", default=TO_DATE)
    p.add_argument("--only", action="append", default=[], help="Strategy id(s) to optimize")
    p.add_argument("--apply", action="store_true", help="Write best lots to main.mq5 and 123.set")
    args = p.parse_args()

    import cluster_audit.united_mt5_runner as runner

    runner.FROM_DATE = args.from_date.replace("-", ".")
    runner.TO_DATE = args.to_date.replace("-", ".")
    runner.DEPOSIT = int(REF_BALANCE)

    OUT.mkdir(parents=True, exist_ok=True)
    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])
    sm = spec_map()

    ids = args.only if args.only else list(PRODUCTION_IDS)
    print(
        f"Lot optimize  deposit={DEPOSIT} ref={REF_BALANCE}  "
        f"{runner.FROM_DATE}->{runner.TO_DATE}  n={len(ids)}",
        flush=True,
    )

    results: list[dict] = []
    best_lots: dict[str, float] = {}

    for sid in ids:
        if sid not in sm:
            print(f"skip unknown id {sid}", flush=True)
            continue
        r = optimize_one(ctx, sm[sid], sm)
        results.append(r)
        best_lots[r["lot_key"]] = r["best_lot"]

    # Baseline combined (123.set lots + production enables)
    base_ov: dict = {**common_patches(), **production_enables()}
    baseline = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, base_ov),
        "lot_combined_baseline.set", "lot_combined_baseline",
    )
    print(
        f"\nCOMBINED baseline PF={baseline.get('profit_factor')} net={baseline.get('net_profit')} "
        f"sharpe={baseline.get('sharpe')} trades={baseline.get('total_trades')}",
        flush=True,
    )

    opt_ov: dict = {**common_patches(), **production_enables(), **best_lots}
    optimized = run_backtest(
        ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
        patch_set(BASE_SET, opt_ov),
        "lot_combined_optimized.set", "lot_combined_optimized",
    )
    print(
        f"COMBINED optimized PF={optimized.get('profit_factor')} net={optimized.get('net_profit')} "
        f"sharpe={optimized.get('sharpe')} trades={optimized.get('total_trades')} "
        f"dNet={g(optimized, 'net_profit') - g(baseline, 'net_profit'):.0f} "
        f"dSharpe={g(optimized, 'sharpe') - g(baseline, 'sharpe'):.3f}",
        flush=True,
    )

    summary = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "period": {"from": runner.FROM_DATE, "to": runner.TO_DATE},
        "deposit": DEPOSIT,
        "reference_balance": REF_BALANCE,
        "stock_lot_max": STOCK_LOT_MAX,
        "solo": results,
        "best_lots": best_lots,
        "combined_baseline": baseline,
        "combined_optimized": optimized,
        "combined_delta": {
            "net_profit": g(optimized, "net_profit") - g(baseline, "net_profit"),
            "sharpe": g(optimized, "sharpe") - g(baseline, "sharpe"),
            "pf": g(optimized, "profit_factor") - g(baseline, "profit_factor"),
        },
    }
    out_path = OUT / "lot_optimize_summary.json"
    out_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nSaved {out_path}", flush=True)

    print("\nBest lots:", flush=True)
    for sid in ids:
        if sid not in sm:
            continue
        row = next(x for x in results if x["id"] == sid)
        m = row["best_metrics"]
        print(
            f"  {sid:12} {row['lot_key']}={row['best_lot']}  "
            f"PF={m.get('profit_factor')} sharpe={m.get('sharpe')} net={m.get('net_profit')}",
            flush=True,
        )

    if args.apply:
        mq5_path = CLUSTER / "main.mq5"
        set_path = CLUSTER / "123.set"
        mq5_path.write_text(apply_lots_to_mq5(mq5_path.read_text(encoding="utf-8"), best_lots), encoding="utf-8")
        set_path.write_text(
            apply_lots_to_set_text(set_path.read_text(encoding="utf-8"), best_lots),
            encoding="utf-8",
        )
        # Ensure reference balance in set
        set_text = set_path.read_text(encoding="utf-8")
        set_text = re.sub(
            r"ORCH_ReferenceBalance=[^\n]+",
            f"ORCH_ReferenceBalance={int(REF_BALANCE)}||{int(REF_BALANCE)}.0||100.000000||10000.000000||N",
            set_text,
            count=1,
        )
        set_path.write_text(set_text, encoding="utf-8")
        print(f"Applied lots to {mq5_path} and {set_path}", flush=True)


if __name__ == "__main__":
    main()
