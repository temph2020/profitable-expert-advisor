"""

Full cluster audit: baseline + optimize per strategy per period.

Outputs JSON report with worst losses and improvement hints.



Usage:

  python -m cluster_audit.run_audit [trials] [--trial-every N] [--quiet]



Examples:

  python -m cluster_audit.run_audit 80

  python -m cluster_audit.run_audit 120 --trial-every 5

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

from cluster_audit.engines import ENGINE_MAP

from cluster_audit.strategy_registry import PERIODS, STRATEGIES, TF

from cluster_audit.trace_log import TraceLog



LOG = TraceLog(enabled=True, trial_every=10)





def _sample_params(defaults: dict, opt_ranges: dict, rng: random.Random) -> dict:

    p = dict(defaults)

    for key, spec in opt_ranges.items():

        if not isinstance(spec, tuple) or len(spec) != 3:

            continue

        lo, hi, step = spec

        if isinstance(lo, int):

            vals = list(range(int(lo), int(hi) + 1, int(step)))

            p[key] = rng.choice(vals) if vals else p.get(key, lo)

        else:

            n = int((hi - lo) / step) + 1

            idx = rng.randint(0, max(n - 1, 0))

            p[key] = round(lo + idx * step, 4)

    return p





from cluster_audit.scoring import DEFAULT_TRADES_PER_DAY, period_days, score_label, score_report
from cluster_audit.strategy_registry import PERIODS


def _audit_period_days() -> int:
    start, end = PERIODS["2021-2026"]
    return period_days(start, end)


def _score_label(score: float, trades: int) -> str:
    return score_label(score, trades, _audit_period_days(), DEFAULT_TRADES_PER_DAY)


def _score(report) -> float:
    return score_report(report, _audit_period_days(), DEFAULT_TRADES_PER_DAY)





def run_strategy(

    spec: dict,

    period_label: str,

    start: str,

    end: str,

    trials: int,

    rng: random.Random,

    run_idx: int,

    run_total: int,

) -> dict:

    sid = spec["id"]

    label = f"{sid} @ {period_label} ({run_idx}/{run_total})"

    LOG.phase_start(label)



    engine_name = spec["engine"]

    if engine_name not in ENGINE_MAP:

        LOG.error(f"Unknown engine '{engine_name}'")

        return {"id": sid, "period": period_label, "error": f"unknown engine {engine_name}"}



    engine = ENGINE_MAP[engine_name]

    tf_key = spec["tf"]

    tf = TF[tf_key]



    LOG.debug(f"resolve symbol: requested={spec['symbol']}")

    raw_sym = spec["symbol"]

    sym = resolve_symbol(raw_sym)

    if sym != raw_sym:

        LOG.info(f"symbol mapped {raw_sym} -> {sym}")

    else:

        LOG.debug(f"symbol={sym}")



    start_dt = datetime.fromisoformat(start)

    end_dt = datetime.fromisoformat(end)

    LOG.debug(f"load bars: tf={tf_key} from={start} to={end} lot={spec['lot']}")



    t_load = time.perf_counter()

    try:

        df = load_bars(sym, tf, start_dt, end_dt)

    except Exception as e:

        LOG.error(f"data load failed: {e}")

        LOG.phase_end(label, "SKIPPED")

        return {"id": sid, "period": period_label, "error": str(e)}



    load_ms = (time.perf_counter() - t_load) * 1000

    LOG.info(

        f"loaded {len(df)} bars in {load_ms:.0f}ms "

        f"({df.index[0]} -> {df.index[-1]})"

    )



    costs = CostModel.for_symbol(sym)

    LOG.debug(

        f"costs: spread={costs.spread_points}pts slippage={costs.slippage_points}pts "

        f"commission/lot={costs.commission_per_lot}"

    )



    defaults = dict(spec["defaults"])

    opt_keys = list(spec.get("opt", {}).keys())

    LOG.debug(f"baseline params keys: {list(defaults.keys())}")

    LOG.debug(f"optimize keys ({len(opt_keys)}): {opt_keys}")



    LOG.debug("running baseline backtest...")

    t0 = time.perf_counter()

    baseline = engine(df, sym, period_label, sid, defaults, spec["lot"], costs)

    base_ms = (time.perf_counter() - t0) * 1000

    LOG.info(

        f"baseline done in {base_ms:.0f}ms: net=${baseline.net_profit:.2f} "

        f"sharpe={baseline.sharpe:.2f} trades={baseline.total_trades} "

        f"pf={baseline.profit_factor:.2f} max_dd={baseline.max_drawdown_pct:.1f}%"

    )

    if baseline.total_trades == 0:

        LOG.warn(f"{sid}: 0 trades on baseline — engine may not match MQL or params too strict")



    best = baseline

    best_params = defaults

    best_score = _score(baseline)

    LOG.debug(f"baseline score={_score_label(best_score, baseline.total_trades)}")



    if trials > 0:

        LOG.info(f"optimizing: {trials} random trials...")

    for n in range(1, trials + 1):

        params = _sample_params(defaults, spec.get("opt", {}), rng)

        r = engine(df, sym, period_label, sid, params, spec["lot"], costs)

        sc = _score(r)

        improved = sc > best_score

        if improved:

            best_score = sc

            best = r

            best_params = params

            LOG.trial(n, trials, sc, r.net_profit, r.sharpe, improved=True)

            LOG.debug(f"  new best params sample: { {k: best_params[k] for k in opt_keys[:6] if k in best_params} }")

        else:

            LOG.trial(n, trials, sc, r.net_profit, r.sharpe, improved=False)



    if trials > 0 and best is not baseline:

        LOG.info(

            f"optimized: net +${best.net_profit - baseline.net_profit:.0f} "

            f"sharpe +{best.sharpe - baseline.sharpe:.2f}"

        )

    elif trials > 0:

        LOG.info("optimization: no better params found (baseline kept)")



    loss_reasons: dict[str, float] = {}

    for t in baseline.worst_trades:

        reason = t.get("exit_reason", "?")

        loss_reasons[reason] = loss_reasons.get(reason, 0) + min(t["profit"], 0)

    if loss_reasons:

        top_loss = sorted(loss_reasons.items(), key=lambda x: x[1])[:3]

        LOG.debug(f"baseline loss by exit reason: {top_loss}")



    result = {

        "id": sid,

        "engine": engine_name,

        "symbol": sym,

        "timeframe": tf_key,

        "period": period_label,

        "bars": len(df),

        "baseline": baseline.to_dict(),

        "optimized": {**best.to_dict(), "params": best_params},

        "improvement_net": best.net_profit - baseline.net_profit,

        "improvement_sharpe": best.sharpe - baseline.sharpe,

        "loss_reasons_baseline": loss_reasons,

    }



    LOG.report_line(sid, result["baseline"], result["optimized"], len(df))

    LOG.phase_end(label)

    return result





def build_improvement_plan(results: list[dict]) -> dict:

    by_engine: dict[str, list] = {}

    for r in results:

        if "error" in r:

            continue

        by_engine.setdefault(r["engine"], []).append(r)



    plan = {"per_engine": {}, "portfolio": []}



    engine_notes = {

        "rsi_crossover": "Trend-strong filter closes/blocks too aggressively (ema_slope 105 + distance 165). "

                         "Raise thresholds or only block entries, not force-exit. Add pip-based scaling per symbol.",

        "rsi_scalp": "High trade count + rsi_against exits cause death by spread. Widen OB/OS gap, add ADX/session "

                     "filter, scale trail by ATR not fixed points. Stocks need .NAS symbols.",

        "rsi_asian": "Narrow session + extreme RSI levels -> few trades or bad fills. Align session to broker server "

                     "time; add spread cap in points not pips.",

        "mean_reversion": "ADX proxy weak in Python; large min_ema_distance on BTC blocks entries. "

                          "Use true ADX; cap concurrent positions; hard SL when ADX escapes.",

        "ema_slope": "Re-enters on same crossover too often; weekly ADX filter missing in audit. "

                     "Add cooldown after loss; separate unit vs trail param sets.",

        "darvas": "Box breakout without volume filter whipsaws. Add volume MA + trend MA filter from MQL.",

        "rsi_secret": "Zone re-entry fires too often in chop. Require divergence or RSI momentum confirm.",

    }



    for eng, rows in by_engine.items():

        sharpes = [x["baseline"]["sharpe"] for x in rows]

        opt_sharpes = [x["optimized"]["sharpe"] for x in rows]

        nets = [x["baseline"]["net_profit"] for x in rows]

        plan["per_engine"][eng] = {

            "count": len(rows),

            "avg_baseline_sharpe": sum(sharpes) / len(sharpes) if sharpes else 0,

            "avg_optimized_sharpe": sum(opt_sharpes) / len(opt_sharpes) if opt_sharpes else 0,

            "avg_baseline_net": sum(nets) / len(nets) if nets else 0,

            "logic_fixes": engine_notes.get(eng, ""),

            "worst_strategies": sorted(rows, key=lambda x: x["baseline"]["sharpe"])[:3],

        }



    plan["portfolio"] = [

        "Run correlation matrix on daily returns — disable highly correlated RSI scalps on same underlying (NVDA x3).",

        "Portfolio-level max daily loss circuit breaker (pause new entries cluster-wide).",

        "Per-asset-class lot caps: forex micro, gold 0.1, stocks margin-scaled not fixed 25 lots.",

        "Split optimization windows: long 2021-2026 for structure, short 2024-2026 for recency; only deploy params that pass both.",

        "Add core/ShockGuard.mqh: ATR spike pause + margin level gate before SE_TickAll.",

        "Enable robots by regime: Asian RSI only 00-08 server; EMA slope only when W1 ADX > threshold.",

        "Replace fixed magic collisions with 401xxx registry; log per-robot PnL for live attribution.",

    ]

    return plan





def parse_args() -> argparse.Namespace:

    p = argparse.ArgumentParser(description="SuperEA cluster audit with trace logging")

    p.add_argument("trials", nargs="?", type=int, default=80, help="Random trials per strategy (default 80)")

    p.add_argument("--trial-every", type=int, default=10, help="Log every N trials (default 10)")

    p.add_argument("--quiet", action="store_true", help="Suppress trace output")

    return p.parse_args()





def main() -> None:

    args = parse_args()

    global LOG

    LOG = TraceLog(enabled=not args.quiet, trial_every=args.trial_every)



    total_runs = len(STRATEGIES) * len(PERIODS)

    LOG.banner(

        f"CLUSTER AUDIT - {len(STRATEGIES)} strategies x {len(PERIODS)} periods "

        f"= {total_runs} runs, {args.trials} trials each"

    )



    LOG.phase_start("MT5 initialize")

    if not mt5.initialize():

        LOG.error(f"MT5 init failed: {mt5.last_error()}")

        raise SystemExit(1)

    acc = mt5.account_info()

    if acc:

        LOG.info(f"MT5 connected: server={acc.server} (account redacted)")

    LOG.phase_end("MT5 initialize")



    out_dir = Path(__file__).parent / "reports"

    out_dir.mkdir(exist_ok=True)

    rng = random.Random(42)

    all_results = []

    run_idx = 0

    errors = 0



    try:

        for period_label, (start, end) in PERIODS.items():

            LOG.banner(f"PERIOD {period_label}  ({start} -> {end})")

            for spec in STRATEGIES:

                run_idx += 1

                LOG.progress(run_idx, total_runs, f"next: {spec['id']}")

                r = run_strategy(spec, period_label, start, end, args.trials, rng, run_idx, total_runs)

                all_results.append(r)

                if "error" in r:

                    errors += 1



        LOG.phase_start("build improvement plan")

        plan = build_improvement_plan(all_results)

        LOG.phase_end("build improvement plan")



        report = {

            "generated": datetime.now().isoformat(),

            "trials_per_strategy": args.trials,

            "strategies": len(STRATEGIES),

            "periods": list(PERIODS.keys()),

            "runs_total": total_runs,

            "runs_failed": errors,

            "results": all_results,

            "improvement_plan": plan,

        }

        out_path = out_dir / "cluster_audit_report.json"

        out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

        LOG.info(f"report written: {out_path} ({out_path.stat().st_size // 1024} KB)")



        LOG.banner("SUMMARY - worst baseline Sharpe (2021-2026)")

        r21 = [x for x in all_results if x.get("period") == "2021-2026" and "error" not in x]

        for x in sorted(r21, key=lambda z: z["baseline"]["sharpe"])[:10]:

            b = x["baseline"]

            w = b["worst_trades"][:1]

            wtxt = f"${w[0]['profit']:.0f} {w[0]['exit_reason']}" if w else "n/a"

            LOG.info(

                f"  {x['id']:28} sharpe={b['sharpe']:6.2f}  net=${b['net_profit']:9.0f}  "

                f"trades={b['total_trades']:4}  worst={wtxt}"

            )



        if errors:

            LOG.warn(f"{errors}/{total_runs} runs failed - search report for \"error\" fields")
        LOG.banner(f"DONE - {run_idx} runs in {LOG._elapsed()}")

    finally:

        LOG.phase_start("MT5 shutdown")

        mt5.shutdown()

        LOG.phase_end("MT5 shutdown")





if __name__ == "__main__":

    main()


