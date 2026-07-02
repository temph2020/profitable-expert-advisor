#!/usr/bin/env python3
"""
MT5 genetic lot optimization — one production sub-strategy at a time.

Ranges:
  stock  → 5..15 step 5
  other  → 0.01..0.1 step 0.01

Usage:
  python -m cluster_audit.run_lot_genetic
  python -m cluster_audit.run_lot_genetic --only RS_NVDA
  python -m cluster_audit.run_lot_genetic --apply
  python -m cluster_audit.run_lot_genetic --resume   # skip ids already in summary
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.united_mt5_manifest import (
    ALL_ENABLE_KEYS,
    HIGH_MARGIN_STOCK_ENABLES,
    LOT_CLASS_BY_ID,
    LOT_GENETIC_RANGE,
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
    patch_set_for_lot_genetic,
    run_backtest,
    run_genetic_lot_optimize,
)

OUT = Path(__file__).resolve().parent / "reports" / "lot_genetic"
REF_BALANCE = 3000.0
SUMMARY_PATH = OUT / "lot_genetic_summary.json"


def lot_class(sid: str) -> str:
    return LOT_CLASS_BY_ID.get(sid, "forex")


def genetic_range(sid: str) -> tuple[float, float, float]:
    if lot_class(sid) == "stock":
        return LOT_GENETIC_RANGE["stock"]
    return LOT_GENETIC_RANGE["default"]


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


def solo_overrides(spec: dict) -> dict[str, bool]:
    o: dict[str, bool] = {k: False for k in ALL_ENABLE_KEYS}
    o[spec["enable"]] = True
    return o


def apply_lots_to_mq5(text: str, lots: dict[str, float]) -> str:
    for key, val in lots.items():
        sval = str(int(val)) if val == int(val) else str(val)
        text, _ = re.subn(
            rf"(input double {re.escape(key)} = )[0-9.]+;",
            rf"\g<1>{sval};",
            text,
            count=1,
        )
    text, _ = re.subn(
        r"(input double ORCH_ReferenceBalance = )[0-9.]+;",
        rf"\g<1>{REF_BALANCE};",
        text,
        count=1,
    )
    return text


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
    return "\n".join(lines_out) + "\n"


def load_summary() -> dict:
    if SUMMARY_PATH.exists():
        return json.loads(SUMMARY_PATH.read_text(encoding="utf-8"))
    return {"results": [], "best_lots": {}}


def save_summary(summary: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    SUMMARY_PATH.write_text(json.dumps(summary, indent=2), encoding="utf-8")


def run_backtest_with_retry(
    ctx: dict,
    set_body: str,
    set_name: str,
    report: str,
    *,
    test_symbol: str | None = None,
    retries: int = 3,
) -> dict:
    last: dict = {"ready": False}
    for attempt in range(retries):
        if attempt:
            time.sleep(12)
        last = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            set_body, set_name, report, test_symbol=test_symbol,
        )
        if last.get("ready"):
            return last
    return last


def lot_report_tag(lot: float) -> str:
    return str(int(lot)) if lot == int(lot) else str(lot).replace(".", "p")


def optimize_one(ctx: dict, spec: dict, *, opt_mode: int, grid_only: bool) -> dict:
    sid = spec["id"]
    lot_key = spec["lot"]
    start, step, stop = genetic_range(sid)
    ov = {**common_patches(), **solo_overrides(spec)}
    report = f"lotgen_{sid}"

    print(
        f"\n[{sid}] lot sweep {lot_key}  range={start}..{stop} step={step}  "
        f"symbol={spec.get('test_symbol') or 'NAS100'}",
        flush=True,
    )

    if not grid_only:
        body = patch_set_for_lot_genetic(BASE_SET, ov, lot_key, start, step, stop)
        m = run_genetic_lot_optimize(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            body, f"{report}.set", report, lot_key,
            test_symbol=spec.get("test_symbol"),
            optimization=opt_mode,
        )
        best_lot = m.get("best_lot")
        if m.get("ready") and best_lot is not None:
            print(
                f"  BEST lot={best_lot} PF={m.get('profit_factor')} net={m.get('profit')} "
                f"sharpe={m.get('sharpe')} trades={m.get('trades')} passes={m.get('passes')} "
                f"({m.get('elapsed_sec')}s)",
                flush=True,
            )
            return {
                "id": sid,
                "lot_key": lot_key,
                "lot_class": lot_class(sid),
                "range": {"start": start, "step": step, "stop": stop},
                "best_lot": best_lot,
                "metrics": m,
            }
        print(f"  genetic XML miss ({m.get('error')}) — grid sweep", flush=True)

    from cluster_audit.united_mt5_manifest import LOT_GRIDS

    grid = LOT_GRIDS["stock"] if lot_class(sid) == "stock" else LOT_GRIDS["forex"]
    best_sc, best_lot, best_m = -1e18, grid[0], {}
    t0 = time.time()
    for lot in grid:
        tag = lot_report_tag(lot)
        ov2 = {**ov, lot_key: lot}
        bm = run_backtest_with_retry(
            ctx,
            patch_set(BASE_SET, ov2), f"lot_{sid}_{tag}.set", f"lot_{sid}_{tag}",
            test_symbol=spec.get("test_symbol"),
        )
        if not bm.get("ready"):
            print(f"    lot={lot} FAILED (no report)", flush=True)
            continue
        trades = int(bm.get("total_trades") or 0)
        profit = float(bm.get("net_profit") or 0)
        pf = float(bm.get("profit_factor") or 0)
        sharpe = float(bm.get("sharpe") or 0)
        if trades < 20 or pf < 1.0 or profit <= 0:
            sc = -1e10 + profit
        else:
            sc = sharpe * 2000 + profit / 500 + pf * 50
        print(
            f"    lot={lot} PF={pf} net={profit} sharpe={sharpe} trades={trades}",
            flush=True,
        )
        if sc > best_sc:
            best_sc, best_lot, best_m = sc, lot, bm
    elapsed = round(time.time() - t0, 1)
    best_m = {**best_m, "best_lot": best_lot, "method": "grid", "elapsed_sec": elapsed}
    print(
        f"  BEST lot={best_lot} PF={best_m.get('profit_factor')} net={best_m.get('net_profit')} "
        f"sharpe={best_m.get('sharpe')} trades={best_m.get('total_trades')} ({elapsed}s)",
        flush=True,
    )
    return {
        "id": sid,
        "lot_key": lot_key,
        "lot_class": lot_class(sid),
        "range": {"start": start, "step": step, "stop": stop},
        "best_lot": best_lot,
        "metrics": best_m,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--from", dest="from_date", default=FROM_DATE)
    p.add_argument("--to", dest="to_date", default=TO_DATE)
    p.add_argument("--only", action="append", default=[])
    p.add_argument("--apply", action="store_true")
    p.add_argument("--resume", action="store_true", help="Skip strategies already in summary")
    p.add_argument("--redo", action="append", default=[], help="Re-run these ids even if in summary")
    p.add_argument("--mode", choices=("genetic", "complete", "grid"), default="grid",
                   help="grid=direct lot sweep (default); genetic=try MT5 genetic first")
    args = p.parse_args()

    import cluster_audit.united_mt5_runner as runner

    runner.FROM_DATE = args.from_date.replace("-", ".")
    runner.TO_DATE = args.to_date.replace("-", ".")
    runner.DEPOSIT = int(REF_BALANCE)

    opt_mode = 2 if args.mode == "genetic" else 1
    grid_only = args.mode == "grid"
    ids = args.only if args.only else list(PRODUCTION_IDS)
    sm = {s["id"]: s for s in UNITED_MT5_STRATEGIES}

    summary = load_summary() if args.resume else {"results": [], "best_lots": {}}
    done_ids = set()
    if args.resume:
        for r in summary.get("results", []):
            m = r.get("metrics") or {}
            if m.get("ready") and r["id"] not in args.redo:
                done_ids.add(r["id"])

    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])

    print(
        f"Lot genetic  deposit={DEPOSIT} ref={REF_BALANCE}  "
        f"{runner.FROM_DATE}->{runner.TO_DATE}  mode={args.mode}  n={len(ids)}",
        flush=True,
    )

    for sid in ids:
        if sid not in sm:
            print(f"skip unknown {sid}", flush=True)
            continue
        if sid in done_ids and sid not in args.redo:
            print(f"skip done {sid}", flush=True)
            continue
        r = optimize_one(ctx, sm[sid], opt_mode=opt_mode, grid_only=grid_only)
        summary["results"] = [x for x in summary.get("results", []) if x["id"] != sid] + [r]
        summary["best_lots"][r["lot_key"]] = r["best_lot"]
        summary["timestamp"] = datetime.now().isoformat(timespec="seconds")
        summary["period"] = {"from": runner.FROM_DATE, "to": runner.TO_DATE}
        save_summary(summary)

    print(f"\nSaved {SUMMARY_PATH}", flush=True)
    for r in summary["results"]:
        print(
            f"  {r['id']:12} {r['lot_key']}={r['best_lot']}  "
            f"PF={r['metrics'].get('profit_factor')} sharpe={r['metrics'].get('sharpe')}",
            flush=True,
        )

    if args.apply and summary.get("best_lots"):
        mq5_path = CLUSTER / "main.mq5"
        set_path = CLUSTER / "123.set"
        mq5_path.write_text(
            apply_lots_to_mq5(mq5_path.read_text(encoding="utf-8"), summary["best_lots"]),
            encoding="utf-8",
        )
        set_path.write_text(
            apply_lots_to_set_text(set_path.read_text(encoding="utf-8"), summary["best_lots"]),
            encoding="utf-8",
        )
        print(f"Applied to {mq5_path} and {set_path}", flush=True)


if __name__ == "__main__":
    main()
