"""
Sequential United EA audit (main.mq5 strategies from 123.set).

Usage:
  python -m cluster_audit.run_united_sequential [trials] [--only ID] [--from ID] [--continue-on-fail]
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.run_sequential import run_one_strategy  # noqa: E402
from cluster_audit.scoring import (  # noqa: E402
    DEFAULT_TRADES_PER_DAY,
    min_trades_for_period,
    period_days,
    score_label,
)
from cluster_audit.trace_log import TraceLog  # noqa: E402
from cluster_audit.united_registry import PERIODS, UNITED_STRATEGIES  # noqa: E402

PRIMARY_PERIOD = "2021-2026"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="United EA sequential audit (main.mq5)")
    p.add_argument("trials", nargs="?", type=int, default=80)
    p.add_argument("--from", dest="from_id", default=None)
    p.add_argument("--only", default=None)
    p.add_argument("--trial-every", type=int, default=10)
    p.add_argument("--trades-per-day", type=float, default=DEFAULT_TRADES_PER_DAY)
    p.add_argument("--continue-on-fail", action="store_true")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    log = TraceLog(enabled=True, trial_every=args.trial_every)

    start, end = PERIODS[PRIMARY_PERIOD]
    days = period_days(datetime.fromisoformat(start), datetime.fromisoformat(end))
    strategies = UNITED_STRATEGIES
    if args.only:
        strategies = [s for s in UNITED_STRATEGIES if s["id"] == args.only]
    elif args.from_id:
        found = False
        filtered = []
        for s in UNITED_STRATEGIES:
            if s["id"] == args.from_id:
                found = True
            if found:
                filtered.append(s)
        strategies = filtered if found else UNITED_STRATEGIES

    log.banner(
        f"UNITED EA AUDIT - {len(strategies)} strategies | "
        f">={args.trades_per_day:.1f} trade/day | {args.trials} trials"
    )

    if not mt5.initialize():
        log.error(f"MT5 init failed: {mt5.last_error()}")
        raise SystemExit(1)

    out_dir = Path(__file__).parent / "reports" / "united_sequential"
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(42)
    results: list[dict] = []
    passed_ids: list[str] = []
    failed_ids: list[str] = []

    try:
        for i, spec in enumerate(strategies, 1):
            r = run_one_strategy(
                spec, PRIMARY_PERIOD, start, end, args.trials, rng, i, len(strategies),
                days, args.trades_per_day,
            )
            # relocate report to united folder
            src = Path(__file__).parent / "reports" / "sequential" / f"{spec['id']}_{PRIMARY_PERIOD}.json"
            dst = out_dir / f"{spec['id']}_{PRIMARY_PERIOD}.json"
            if src.exists():
                dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

            results.append(r)
            if r.get("passed"):
                passed_ids.append(r["id"])
            elif "error" not in r:
                failed_ids.append(r["id"])
                if not args.continue_on_fail and not args.only:
                    log.warn(f"STOPPED at {r['id']} — resume with --from {r['id']} --continue-on-fail")
                    break

        summary = {
            "generated": datetime.now().isoformat(),
            "period_days": days,
            "passed": passed_ids,
            "failed": failed_ids,
            "results": [{k: v for k, v in r.items() if k != "spec"} for r in results],
        }
        (out_dir / "united_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

        try:
            from cluster_audit.sync_united import main as sync_united
            sync_united()
            log.info("main.mq5 + UnitedEA_Optimized.set updated")
        except Exception as ex:
            log.warn(f"sync_united skipped: {ex}")

        log.banner(f"PASSED {len(passed_ids)} / FAILED {len(failed_ids)}")
        for r in results:
            if not r.get("passed"):
                continue
            o = r["optimized"]
            log.info(
                f"  {r['id']:28} net=${o['net_profit']:9.0f} "
                f"trades={o['total_trades']:5} pf={o['profit_factor']:.2f}"
            )
        for fid in failed_ids:
            log.warn(f"  NEEDS FIX: {fid}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
