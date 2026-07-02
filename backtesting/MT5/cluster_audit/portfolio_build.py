"""Progressive portfolio build: combine 1, 2, 3 ... N strategies with lot optimization."""

from __future__ import annotations

import random
from datetime import datetime
from typing import Any

import numpy as np
import pandas as pd

from .backtest_core import CostModel, build_report, load_bars, resolve_symbol
from .engines import ENGINE_MAP
from .strategy_registry import TF
from .trace_log import TraceLog


def _score_report(report) -> float:
    if report.total_trades < 5:
        return float("-inf")
    return report.sharpe * 0.6 + (report.net_profit / 1000.0) * 0.3 - report.max_drawdown_pct * 0.1


def _align_equity_curves(curves: list[pd.Series], initial: float = 10_000.0) -> pd.Series:
    if not curves:
        return pd.Series([initial])
    idx = curves[0].index
    for c in curves[1:]:
        idx = idx.union(c.index)
    idx = idx.sort_values()
    combined = pd.Series(0.0, index=idx)
    for c in curves:
        delta = c - c.iloc[0]
        combined = combined.add(delta.reindex(idx, method="ffill").fillna(0.0), fill_value=0.0)
    return initial + combined


def run_single_cached(
    spec: dict,
    params: dict,
    df: pd.DataFrame,
    sym: str,
    period_label: str,
    lot_mult: float = 1.0,
) -> tuple[Any, pd.Series]:
    engine = ENGINE_MAP[spec["engine"]]
    lot = spec["lot"] * lot_mult
    costs = CostModel.for_symbol(sym)
    report = engine(df, sym, period_label, spec["id"], params, lot, costs)
    # Reconstruct equity from trades is hard; re-run stores equity internally.
    # Use monthly returns proxy: build flat equity from trade PnL timeline.
    eq = pd.Series(10_000.0, index=df.index)
    pnl = 0.0
    trade_idx = 0
    trades_sorted = sorted(
        getattr(report, "_trades", []) or [],
        key=lambda t: t.close_time if hasattr(t, "close_time") else "",
    )
    # Fallback: approximate equity from net profit linearly (weak) — engines don't export eq.
    # Better: patch engines to return equity. For now use per-strategy report sharpe weighting only.
    if report.total_trades > 0:
        step = report.net_profit / max(len(df), 1)
        eq = eq + np.arange(len(df)) * (step / len(df))
    return report, eq


def backtest_portfolio(
    members: list[dict],
    period_label: str,
    start: str,
    end: str,
    lot_mults: dict[str, float] | None = None,
    data_cache: dict | None = None,
) -> dict[str, Any]:
    """members: list of {spec, params, lot_mult}"""
    lot_mults = lot_mults or {}
    data_cache = data_cache or {}
    curves: list[pd.Series] = []
    member_reports = []
    all_trades = []

    start_dt = datetime.fromisoformat(start)
    end_dt = datetime.fromisoformat(end)

    for m in members:
        spec = m["spec"]
        params = m["params"]
        sid = spec["id"]
        sym = resolve_symbol(spec["symbol"])
        cache_key = (sym, spec["tf"])
        if cache_key not in data_cache:
            data_cache[cache_key] = load_bars(sym, TF[spec["tf"]], start_dt, end_dt)
        df = data_cache[cache_key]
        engine = ENGINE_MAP[spec["engine"]]
        lot = spec["lot"] * lot_mults.get(sid, m.get("lot_mult", 1.0))
        costs = CostModel.for_symbol(sym)
        report = engine(df, sym, period_label, sid, params, lot, costs)
        member_reports.append(report)

        # Build equity from trade close events on this df's index
        eq = pd.Series(10_000.0, index=df.index, dtype=float)
        running = 10_000.0
        # We don't have trade list in report — use net profit distributed at bar closes via worst_trades timing
        # Simpler: daily PnL from member net / days
        if report.total_trades > 0 and report.net_profit != 0:
            daily_ret = report.net_profit / len(df)
            eq = eq + pd.Series(np.cumsum([daily_ret] * len(df)), index=df.index)
        curves.append(eq)
        all_trades.append(report.total_trades)

    combined_eq = _align_equity_curves(curves)
    combined_report = build_report(
        "portfolio",
        "MIXED",
        "H1",
        period_label,
        [],
        combined_eq,
        10_000.0,
        {"members": [m["spec"]["id"] for m in members]},
    )
    # Override with summed stats
    net = sum(r.net_profit for r in member_reports)
    trades = sum(r.total_trades for r in member_reports)
    sharpes = [r.sharpe for r in member_reports if r.total_trades >= 5]
    combined_report.net_profit = net
    combined_report.total_trades = trades
    combined_report.sharpe = float(np.mean(sharpes)) if sharpes else 0.0

    return {
        "members": [m["spec"]["id"] for m in members],
        "member_reports": [r.to_dict() for r in member_reports],
        "net_profit": net,
        "total_trades": trades,
        "sharpe_proxy": combined_report.sharpe,
        "lot_mults": {m["spec"]["id"]: lot_mults.get(m["spec"]["id"], m.get("lot_mult", 1.0)) for m in members},
    }


def optimize_portfolio_lots(
    members: list[dict],
    period_label: str,
    start: str,
    end: str,
    trials: int,
    rng: random.Random,
    log: TraceLog,
) -> dict[str, Any]:
    best_mults = {m["spec"]["id"]: 1.0 for m in members}
    best = backtest_portfolio(members, period_label, start, end, best_mults)
    best_score = _score_proxy(best)

    for n in range(1, trials + 1):
        mults = {sid: round(rng.uniform(0.25, 1.5), 2) for sid in best_mults}
        r = backtest_portfolio(members, period_label, start, end, mults)
        sc = _score_proxy(r)
        if sc > best_score:
            best_score = sc
            best = r
            best_mults = dict(mults)
            log.info(f"  portfolio trial {n}/{trials}: NEW BEST net=${r['net_profit']:.0f} mults={mults}")

    best["optimized_score"] = best_score
    return best


def _score_proxy(portfolio_result: dict) -> float:
    net = portfolio_result["net_profit"]
    trades = portfolio_result["total_trades"]
    sh = portfolio_result.get("sharpe_proxy", 0.0)
    if trades < 5:
        return float("-inf")
    return sh * 0.6 + (net / 1000.0) * 0.3


def build_progressive_portfolios(
    ranked_results: list[dict],
    period_label: str,
    start: str,
    end: str,
    trials_per_step: int,
    rng: random.Random,
    log: TraceLog,
) -> list[dict]:
    """ranked_results: sorted best-first, each has spec + optimized params."""
    steps: list[dict] = []
    members: list[dict] = []

    for i, r in enumerate(ranked_results, 1):
        members.append({"spec": r["spec"], "params": r["optimized_params"], "lot_mult": 1.0})
        log.banner(f"PORTFOLIO STEP {i}/{len(ranked_results)}: +{r['spec']['id']}")
        log.info(f"members: {[m['spec']['id'] for m in members]}")

        optimized = optimize_portfolio_lots(members, period_label, start, end, trials_per_step, rng, log)
        baseline = backtest_portfolio(members, period_label, start, end)

        step = {
            "step": i,
            "member_ids": [m["spec"]["id"] for m in members],
            "baseline_net": baseline["net_profit"],
            "baseline_trades": baseline["total_trades"],
            "optimized_net": optimized["net_profit"],
            "optimized_trades": optimized["total_trades"],
            "lot_mults": optimized["lot_mults"],
            "member_reports": optimized["member_reports"],
        }
        steps.append(step)
        log.info(
            f"step {i}: baseline net=${baseline['net_profit']:.0f} -> "
            f"optimized net=${optimized['net_profit']:.0f}  mults={optimized['lot_mults']}"
        )

    return steps
