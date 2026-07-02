"""
Sequential cluster audit: one strategy at a time, fix until it passes, then next.

Pass criteria (optimized result):
  - >= 1 trade per calendar day over the backtest window (~1977 for 2021-2026)
  - net > 0, profit factor >= 1.15, sharpe >= 0.3
  - winning months >= 45%, drawdown <= 25%

Usage:
  python -m cluster_audit.run_sequential [trials] [--only ID] [--from ID]
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol
from cluster_audit.diagnose import diagnose
from cluster_audit.engines import ENGINE_MAP
from cluster_audit.portfolio_build import build_progressive_portfolios
from cluster_audit.run_audit import _sample_params
from cluster_audit.scoring import (
    DEFAULT_TRADES_PER_DAY,
    acceptance,
    format_quality_line,
    min_trades_for_period,
    period_days,
    score_label,
    score_report,
    trades_per_day,
)
from cluster_audit.strategy_registry import PERIODS, STRATEGIES, TF
from cluster_audit.trace_log import TraceLog

LOG = TraceLog(enabled=True, trial_every=10)
PRIMARY_PERIOD = "2021-2026"


def run_one_strategy(
    spec: dict,
    period_label: str,
    start: str,
    end: str,
    trials: int,
    rng: random.Random,
    idx: int,
    total: int,
    days: int,
    trades_per_day_target: float,
) -> dict:
    sid = spec["id"]
    tf_key = spec["tf"]
    label = f"[{idx}/{total}] {sid} @ {period_label}"
    LOG.banner(label)

    engine = ENGINE_MAP[spec["engine"]]
    sym = resolve_symbol(spec["symbol"])
    start_dt = datetime.fromisoformat(start)
    end_dt = datetime.fromisoformat(end)

    try:
        df = load_bars(sym, TF[tf_key], start_dt, end_dt)
    except Exception as e:
        LOG.error(f"data load failed: {e}")
        return {"id": sid, "period": period_label, "error": str(e), "spec": spec, "passed": False}

    LOG.info(f"loaded {len(df)} bars  symbol={sym}  engine={spec['engine']}")
    costs = CostModel.for_symbol(sym)
    defaults = dict(spec["defaults"])

    min_t = min_trades_for_period(days, trades_per_day_target)
    LOG.info(f"activity gate: >={min_t} trades ({trades_per_day_target:.1f}/day x {days}d)")

    t0 = time.perf_counter()
    baseline = engine(df, sym, period_label, sid, defaults, spec["lot"], costs)
    LOG.info(f"baseline: {format_quality_line(baseline, days)}  ({(time.perf_counter()-t0)*1000:.0f}ms)")

    best = baseline
    best_params = defaults
    best_score = score_report(baseline, days, trades_per_day_target)

    base_ok, base_issues = acceptance(baseline, days, trades_per_day_target)
    if base_ok:
        LOG.info("baseline PASSES acceptance gates")
    else:
        LOG.warn("baseline fails: " + "; ".join(base_issues))

    if trials > 0:
        LOG.info(f"optimizing {trials} trials (score requires trades + profit + consistency)...")
    for n in range(1, trials + 1):
        params = _sample_params(defaults, spec.get("opt", {}), rng)
        r = engine(df, sym, period_label, sid, params, spec["lot"], costs)
        sc = score_report(r, days, trades_per_day_target)
        if sc > best_score:
            best_score = sc
            best = r
            best_params = params
            LOG.trial(n, trials, sc, r.net_profit, r.sharpe, improved=True)
            LOG.debug(f"  -> {format_quality_line(r, days)}")
        elif n % LOG.trial_every == 0 or n == trials:
            LOG.trial(n, trials, sc, r.net_profit, r.sharpe, improved=False)

    LOG.info(f"optimized: {format_quality_line(best, days)}")
    opt_ok, opt_issues = acceptance(best, days, trades_per_day_target)
    passed = opt_ok or base_ok

    if passed:
        LOG.info(f"PASS {sid} - ready for portfolio")
    else:
        LOG.warn(f"FAIL {sid} - needs engine/logic work before next strategy")
        LOG.warn("  " + "; ".join(opt_issues if not opt_ok else base_issues))

    diag = diagnose(spec, baseline, best, LOG)

    result = {
        "id": sid,
        "engine": spec["engine"],
        "symbol": sym,
        "timeframe": tf_key,
        "period": period_label,
        "bars": len(df),
        "period_days": days,
        "trades_per_day_target": trades_per_day_target,
        "baseline_trades_per_day": trades_per_day(baseline, days),
        "optimized_trades_per_day": trades_per_day(best, days),
        "passed": passed,
        "acceptance_issues": opt_issues if not opt_ok else ([] if base_ok else base_issues),
        "baseline": baseline.to_dict(),
        "optimized": {**best.to_dict(), "params": best_params},
        "optimized_params": best_params,
        "optimized_score": best_score,
        "improvement_net": best.net_profit - baseline.net_profit,
        "improvement_trades": best.total_trades - baseline.total_trades,
        "diagnosis": diag,
        "spec": spec,
    }

    out_dir = Path(__file__).parent / "reports" / "sequential"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{sid}_{period_label}.json"
    path.write_text(json.dumps({k: v for k, v in result.items() if k != "spec"}, indent=2), encoding="utf-8")
    LOG.info(f"saved {path.name}")

    try:
        from cluster_audit.sync_cluster import main as sync_cluster
        sync_cluster()
        LOG.info("cluster-latest SuperEA_AuditParams.mqh updated")
    except Exception as ex:
        LOG.warn(f"cluster sync skipped: {ex}")

    return result


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Sequential cluster audit - fix each before next")
    p.add_argument("trials", nargs="?", type=int, default=40)
    p.add_argument("--portfolio-trials", type=int, default=30)
    p.add_argument("--from", dest="from_id", default=None)
    p.add_argument("--only", default=None)
    p.add_argument("--skip-portfolio", action="store_true")
    p.add_argument("--trial-every", type=int, default=10)
    p.add_argument("--trades-per-day", type=float, default=DEFAULT_TRADES_PER_DAY)
    p.add_argument("--continue-on-fail", action="store_true", help="Run next strategy even if current fails")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    global LOG
    LOG = TraceLog(enabled=True, trial_every=args.trial_every)

    start, end = PERIODS[PRIMARY_PERIOD]
    days = period_days(datetime.fromisoformat(start), datetime.fromisoformat(end))
    strategies = STRATEGIES
    if args.only:
        strategies = [s for s in STRATEGIES if s["id"] == args.only]
    elif args.from_id:
        found = False
        filtered = []
        for s in STRATEGIES:
            if s["id"] == args.from_id:
                found = True
            if found:
                filtered.append(s)
        strategies = filtered if found else STRATEGIES

    LOG.banner(
        f"SEQUENTIAL AUDIT - {len(strategies)} strategies | "
        f">={args.trades_per_day:.1f} trade/day (~{min_trades_for_period(days, args.trades_per_day)} trades) | "
        f"{args.trials} opt trials"
    )

    if not mt5.initialize():
        LOG.error(f"MT5 init failed: {mt5.last_error()}")
        raise SystemExit(1)

    out_dir = Path(__file__).parent / "reports" / "sequential"
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
            results.append(r)
            if r.get("passed"):
                passed_ids.append(r["id"])
            elif "error" not in r:
                failed_ids.append(r["id"])
                if not args.continue_on_fail and not args.only:
                    LOG.warn(f"STOPPED at {r['id']} - fix engine/params then resume with --from {r['id']}")
                    break

        valid = [r for r in results if r.get("passed") and "error" not in r]
        valid.sort(key=lambda x: x.get("optimized_score", float("-inf")), reverse=True)

        summary = {
            "generated": datetime.now().isoformat(),
            "period_days": days,
            "trades_per_day_target": args.trades_per_day,
            "trials": args.trials,
            "passed": passed_ids,
            "failed": failed_ids,
            "ranking": [
                {
                    "id": r["id"],
                    "score": r.get("optimized_score"),
                    "net": r["optimized"]["net_profit"],
                    "trades": r["optimized"]["total_trades"],
                    "sharpe": r["optimized"]["sharpe"],
                    "pf": r["optimized"]["profit_factor"],
                }
                for r in valid
            ],
            "results": [{k: v for k, v in r.items() if k != "spec"} for r in results],
        }

        if not args.skip_portfolio and valid:
            LOG.banner("PROGRESSIVE PORTFOLIO BUILD (passed strategies only)")
            ranked = [{"spec": r["spec"], "optimized_params": r["optimized_params"]} for r in valid]
            summary["portfolio_steps"] = build_progressive_portfolios(
                ranked, PRIMARY_PERIOD, start, end, args.portfolio_trials, rng, LOG
            )

        (out_dir / "sequential_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

        LOG.banner(f"PASSED {len(passed_ids)} / FAILED {len(failed_ids)}")
        for r in valid:
            o = r["optimized"]
            LOG.info(
                f"  {r['id']:28} score={score_label(r['optimized_score'], o['total_trades'], days, args.trades_per_day):>22}  "
                f"net=${o['net_profit']:9.0f} trades={o['total_trades']:5} ({r.get('optimized_trades_per_day', 0):.2f}/day)"
            )
        for fid in failed_ids:
            LOG.warn(f"  NEEDS FIX: {fid}")

        LOG.banner(f"DONE in {LOG._elapsed()}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
