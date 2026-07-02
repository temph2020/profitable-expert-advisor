"""
Margin-aware portfolio simulator — merges strategy trades chronologically.

Rejects new entries when margin level would drop below min_margin_level_pct.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import numpy as np
import pandas as pd

from .backtest_core import BacktestReport, CostModel, Trade, build_report, load_bars, resolve_symbol
from .engines import ENGINE_MAP
from .margin import calc_margin, normalize_volume
from .united_registry import TF


@dataclass
class OpenPosition:
    strategy_id: str
    symbol: str
    side: str
    volume: float
    entry_price: float
    entry_time: Any
    margin: float


@dataclass
class PortfolioSimResult:
    members: list[str]
    lot_scales: dict[str, float]
    initial_balance: float
    net_profit: float
    total_trades: int
    rejected_margin: int
    min_margin_level_pct: float
    lowest_margin_level_pct: float
    max_drawdown_pct: float
    sharpe: float
    equity_curve: pd.Series = field(repr=False)
    member_reports: list[dict] = field(default_factory=list)


def _scale_trade(t: Trade, scale: float) -> Trade:
    if scale == 1.0:
        return t
    return Trade(
        side=t.side,
        open_time=t.open_time,
        close_time=t.close_time,
        open_price=t.open_price,
        close_price=t.close_price,
        volume=t.volume * scale,
        profit=t.profit * scale,
        bars_held=t.bars_held,
        exit_reason=t.exit_reason,
    )


def run_member_backtest(
    spec: dict,
    params: dict,
    lot: float,
    df: pd.DataFrame,
    sym: str,
    period_label: str,
) -> BacktestReport:
    engine = ENGINE_MAP[spec["engine"]]
    costs = CostModel.for_symbol(sym)
    return engine(df, sym, period_label, spec["id"], params, lot, costs)


def simulate_portfolio(
    members: list[dict],
    period_label: str,
    start: str,
    end: str,
    initial_balance: float = 1000.0,
    lot_scales: dict[str, float] | None = None,
    min_margin_level_pct: float = 150.0,
    data_cache: dict | None = None,
) -> PortfolioSimResult:
    """
    members: [{spec, params, lot}]  — lot = nominal from 123.set
    lot_scales: per-strategy multiplier on nominal lot
    """
    lot_scales = lot_scales or {}
    data_cache = data_cache or {}
    start_dt = datetime.fromisoformat(start)
    end_dt = datetime.fromisoformat(end)

    events: list[tuple[Any, str, str, Trade]] = []
    member_reports: list[dict] = []

    for m in members:
        spec = m["spec"]
        sid = spec["id"]
        sym = resolve_symbol(spec["symbol"])
        cache_key = (sym, spec["tf"])
        if cache_key not in data_cache:
            data_cache[cache_key] = load_bars(sym, TF[spec["tf"]], start_dt, end_dt)
        df = data_cache[cache_key]
        scale = lot_scales.get(sid, m.get("lot_scale", 1.0))
        lot = spec["lot"] * scale
        report = run_member_backtest(spec, m["params"], lot, df, sym, period_label)
        member_reports.append({**report.to_dict(), "lot_used": lot, "lot_scale": scale})
        for t in report.trades_list:
            events.append((t.open_time, "open", sid, t))
            events.append((t.close_time, "close", sid, t))

    events.sort(key=lambda x: (pd.Timestamp(x[0]), 0 if x[1] == "close" else 1))

    balance = initial_balance
    equity = initial_balance
    open_pos: dict[str, OpenPosition] = {}
    realized: list[Trade] = []
    rejected = 0
    equity_points: list[tuple[Any, float]] = [(events[0][0] if events else start_dt, initial_balance)]
    lowest_ml = 9999.0

    for ts, kind, sid, raw_t in events:
        m = next(x for x in members if x["spec"]["id"] == sid)
        spec = m["spec"]
        sym = resolve_symbol(spec["symbol"])
        scale = lot_scales.get(sid, m.get("lot_scale", 1.0))
        t = _scale_trade(raw_t, scale / (raw_t.volume / spec["lot"]) if raw_t.volume else scale)

        if kind == "close":
            key = f"{sid}"
            if key not in open_pos:
                continue
            op = open_pos.pop(key)
            balance += t.profit
            equity = balance + sum(
                calc_profit(op2.symbol, op2.side, op2.volume, op2.entry_price, t.close_price)
                for op2 in open_pos.values()
                if op2.symbol == sym
            )
            # simpler: balance only on close
            balance = equity_points[-1][1] + t.profit if equity_points else balance + t.profit
            realized.append(t)
            equity_points.append((ts, balance))
            continue

        # open
        vol = normalize_volume(sym, spec["lot"] * lot_scales.get(sid, 1.0))
        if vol <= 0:
            rejected += 1
            continue
        margin_req = calc_margin(sym, t.side, vol, t.open_price)
        used_margin = sum(p.margin for p in open_pos.values())
        free = balance - used_margin
        if margin_req > free:
            rejected += 1
            continue
        new_used = used_margin + margin_req
        equity = balance  # simplified
        ml = (equity / new_used * 100.0) if new_used > 0 else 9999.0
        if ml < min_margin_level_pct:
            rejected += 1
            continue
        lowest_ml = min(lowest_ml, ml)
        open_pos[sid] = OpenPosition(sid, sym, t.side, vol, t.open_price, ts, margin_req)

    if not equity_points:
        equity_points = [(start_dt, initial_balance)]

    eq = pd.Series(
        [p[1] for p in equity_points],
        index=pd.DatetimeIndex([p[0] for p in equity_points]),
    )
    combined = build_report(
        "portfolio",
        "MIXED",
        "H1",
        period_label,
        realized,
        eq,
        initial_balance,
        {"members": [m["spec"]["id"] for m in members], "lot_scales": lot_scales},
    )

    return PortfolioSimResult(
        members=[m["spec"]["id"] for m in members],
        lot_scales={m["spec"]["id"]: lot_scales.get(m["spec"]["id"], 1.0) for m in members},
        initial_balance=initial_balance,
        net_profit=combined.net_profit,
        total_trades=len(realized),
        rejected_margin=rejected,
        min_margin_level_pct=min_margin_level_pct,
        lowest_margin_level_pct=lowest_ml if lowest_ml < 9999 else 0.0,
        max_drawdown_pct=combined.max_drawdown_pct,
        sharpe=combined.sharpe,
        equity_curve=eq,
        member_reports=member_reports,
    )


def optimize_lot_scales(
    members: list[dict],
    period_label: str,
    start: str,
    end: str,
    initial_balance: float,
    min_margin_level_pct: float,
    trials: int,
    rng,
) -> PortfolioSimResult:
    """Grid-search lot scales down from 1.0 — margin-safe, maximize net."""
    best_scales = {m["spec"]["id"]: 1.0 for m in members}
    best = simulate_portfolio(
        members, period_label, start, end, initial_balance, best_scales, min_margin_level_pct
    )
    best_score = _portfolio_score(best)

    # Coarse: try uniform scale factors
    for factor in [1.0, 0.75, 0.5, 0.35, 0.25, 0.15, 0.1]:
        scales = {m["spec"]["id"]: factor for m in members}
        r = simulate_portfolio(members, period_label, start, end, initial_balance, scales, min_margin_level_pct)
        sc = _portfolio_score(r)
        if sc > best_score:
            best_score = sc
            best = r
            best_scales = dict(scales)

    # Fine-tune per member around best uniform
    for _ in range(trials):
        scales = {}
        for m in members:
            sid = m["spec"]["id"]
            base = best_scales.get(sid, 1.0)
            scales[sid] = round(max(0.05, min(1.5, base * rng.uniform(0.7, 1.3))), 3)
        r = simulate_portfolio(members, period_label, start, end, initial_balance, scales, min_margin_level_pct)
        sc = _portfolio_score(r)
        if sc > best_score and r.lowest_margin_level_pct >= min_margin_level_pct * 0.9:
            best_score = sc
            best = r
            best_scales = dict(scales)

    best.lot_scales = best_scales
    return best


def _portfolio_score(r: PortfolioSimResult) -> float:
    if r.net_profit <= 0:
        return float("-inf")
    if r.lowest_margin_level_pct < r.min_margin_level_pct:
        return float("-inf")
    return r.sharpe * 0.4 + (r.net_profit / 500.0) * 0.4 - r.max_drawdown_pct * 0.15 - r.rejected_margin * 0.001


def build_progressive_margin_portfolio(
    ranked: list[dict],
    period_label: str,
    start: str,
    end: str,
    initial_balance: float,
    min_margin_level_pct: float,
    trials_per_step: int,
    rng,
) -> list[dict]:
    """ranked: [{spec, params, lot, baseline_report}] sorted best-first."""
    steps: list[dict] = []
    members: list[dict] = []

    for i, r in enumerate(ranked, 1):
        members.append({
            "spec": r["spec"],
            "params": r["params"],
            "lot_scale": 1.0,
        })
        baseline = simulate_portfolio(
            members, period_label, start, end, initial_balance,
            {m["spec"]["id"]: 1.0 for m in members}, min_margin_level_pct,
        )
        optimized = optimize_lot_scales(
            members, period_label, start, end, initial_balance,
            min_margin_level_pct, trials_per_step, rng,
        )
        steps.append({
            "step": i,
            "members": [m["spec"]["id"] for m in members],
            "baseline_net": baseline.net_profit,
            "baseline_trades": baseline.total_trades,
            "baseline_lowest_margin_pct": baseline.lowest_margin_level_pct,
            "optimized_net": optimized.net_profit,
            "optimized_trades": optimized.total_trades,
            "optimized_sharpe": optimized.sharpe,
            "optimized_max_dd_pct": optimized.max_drawdown_pct,
            "lowest_margin_level_pct": optimized.lowest_margin_level_pct,
            "rejected_margin": optimized.rejected_margin,
            "lot_scales": optimized.lot_scales,
            "lots_final": {
                m["spec"]["id"]: round(m["spec"]["lot"] * optimized.lot_scales.get(m["spec"]["id"], 1.0), 4)
                for m in members
            },
        })
    return steps
