"""Per-strategy problem diagnosis and loss tracing."""

from __future__ import annotations

from typing import Any

from .backtest_core import BacktestReport
from .trace_log import TraceLog

ENGINE_FIX_HINTS = {
    "rsi_crossover": "trend_strong closes positions in strong trends; high ema_slope/distance thresholds block entries.",
    "rsi_scalp": "rsi_against exits + spread costs dominate; check OB/OS vs target gap and bars_to_wait.",
    "rsi_asian": "session window or extreme RSI levels may block entries; verify broker server hour offset.",
    "mean_reversion": "ADX proxy may differ from MQL iADX; min_ema_distance_pts can block all entries on volatile symbols.",
    "ema_slope": "needs EMA-cross exit + profit trail even when use_trailing_stop=False; weekly ADX filter missing.",
    "darvas": "box must be narrow (box_deviation); volume MA filter not yet ported.",
    "rsi_secret": "zone re-entry in chop; add divergence confirm or widen min_bars_between_trades.",
}


def diagnose(spec: dict, baseline: BacktestReport, optimized: BacktestReport | None, log: TraceLog) -> dict[str, Any]:
    sid = spec["id"]
    engine = spec["engine"]
    issues: list[str] = []
    actions: list[str] = []

    if baseline.total_trades == 0:
        issues.append("ZERO_TRADES")
        actions.append("Engine logic or params too strict - compare Python port to MQL defaults.")
    elif baseline.total_trades < 10:
        issues.append("LOW_TRADE_COUNT")
        actions.append("Relax entry filters or widen optimization ranges.")

    if baseline.net_profit < 0:
        issues.append("NEGATIVE_PNL")
    if baseline.sharpe < 0:
        issues.append("NEGATIVE_SHARPE")
    if baseline.max_drawdown_pct > 25:
        issues.append("HIGH_DRAWDOWN")

    br = baseline.exit_reason_breakdown
    loss_reasons = sorted(
        ((k, v["pnl"]) for k, v in br.items() if v["pnl"] < 0),
        key=lambda x: x[1],
    )
    if loss_reasons:
        top = loss_reasons[0]
        issues.append(f"TOP_LOSS_REASON:{top[0]}")
        if top[0] == "rsi_against":
            actions.append("Widen RSI targets or increase bars_to_wait before rsi_against exit.")
        elif top[0] == "trend_strong":
            actions.append("Raise ema_slope/distance thresholds or only block new entries (MQL also force-closes).")
        elif top[0] == "trail":
            actions.append("Trail too tight - widen trail_distance_pts or raise activation.")
        elif top[0] == "sl":
            actions.append("Stop loss too tight for symbol volatility - scale SL by ATR.")
        elif top[0] == "hours" or top[0] == "session":
            actions.append("Trading hours/session filter closing positions — align to broker server time.")
        elif top[0] == "adx_escape":
            actions.append("ADX escape fires too early — raise adx_escape threshold.")

    hint = ENGINE_FIX_HINTS.get(engine, "")
    if hint:
        actions.append(hint)

    if optimized and optimized is not baseline:
        from .scoring import DEFAULT_TRADES_PER_DAY, acceptance, min_trades_for_period, period_days, trades_per_day
        from .strategy_registry import PERIODS

        start, end = PERIODS.get("2021-2026", ("2021-01-01", "2026-06-01"))
        days = period_days(start, end)
        min_t = min_trades_for_period(days, DEFAULT_TRADES_PER_DAY)
        opt_tpd = trades_per_day(optimized, days)
        base_tpd = trades_per_day(baseline, days)
        if opt_tpd < DEFAULT_TRADES_PER_DAY:
            issues.append("LOW_TRADES_PER_DAY")
            actions.append(
                f"Only {opt_tpd:.2f} trades/day (need >={DEFAULT_TRADES_PER_DAY:.1f}); "
                "use lower TF, tighter SL/TP, or relax entry filters."
            )
        if optimized.total_trades < min_t and baseline.total_trades >= min_t:
            issues.append("OPT_COLLAPSED_TRADES")
            actions.append(
                f"Optimization cut trades {baseline.total_trades}->{optimized.total_trades} "
                f"({base_tpd:.2f}->{opt_tpd:.2f}/day)."
            )
        opt_ok, opt_issues = acceptance(optimized, days, DEFAULT_TRADES_PER_DAY)
        if not opt_ok and optimized.net_profit > baseline.net_profit:
            issues.append("OPT_PROFIT_BUT_FAILS_GATES")
            actions.append("Higher net but fails gates: " + "; ".join(opt_issues[:4]))
        if optimized.sharpe > baseline.sharpe + 0.1:
            issues.append("OPTIMIZATION_HELPED")

    log.banner(f"DIAGNOSIS: {sid}")
    log.info(f"engine={engine} symbol={baseline.symbol} trades={baseline.total_trades}")
    if issues:
        log.warn("issues: " + ", ".join(issues))
    else:
        log.info("no critical issues flagged")

    trace_losses(baseline, log, label="baseline")

    if optimized and optimized is not baseline:
        log.info(
            f"optimized: net=${optimized.net_profit:.0f} sharpe={optimized.sharpe:.2f} "
            f"trades={optimized.total_trades}"
        )
        if optimized.net_profit < baseline.net_profit:
            trace_losses(optimized, log, label="optimized", max_rows=10)

    if actions:
        log.info("suggested actions:")
        for a in actions[:6]:
            log.debug(f"  - {a}")

    return {
        "issues": issues,
        "actions": actions,
        "top_loss_reasons": loss_reasons[:5],
        "exit_reason_breakdown": br,
    }


def trace_losses(report: BacktestReport, log: TraceLog, label: str = "baseline", max_rows: int = 15) -> None:
    if not report.losing_trades:
        log.debug(f"{label}: no losing trades")
        return

    log.info(f"{label} loss trace ({len(report.losing_trades)} losers logged, showing worst {max_rows}):")
    for i, t in enumerate(report.losing_trades[:max_rows], 1):
        log.info(
            f"  #{i:02d} {t['side']:4} ${t['profit']:8.2f}  {t['exit_reason']:12}  "
            f"bars={t['bars_held']:4}  {t['open_time']} -> {t['close_time']}"
        )

    if report.exit_reason_breakdown:
        log.debug(f"{label} exit reason PnL:")
        for reason, stats in sorted(
            report.exit_reason_breakdown.items(),
            key=lambda x: x[1]["pnl"],
        ):
            log.debug(
                f"  {reason:14} count={int(stats['count']):4}  "
                f"wins={int(stats['wins']):3} losses={int(stats['losses']):3}  pnl=${stats['pnl']:.0f}"
            )
