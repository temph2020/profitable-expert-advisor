"""Strategy scoring — requires ~1 trade per calendar day over the backtest period."""

from __future__ import annotations

from datetime import date, datetime

from .backtest_core import BacktestReport

DEFAULT_TRADES_PER_DAY = 1.0


def period_days(start: date | datetime | str, end: date | datetime | str) -> int:
    if isinstance(start, str):
        start = datetime.fromisoformat(start)
    if isinstance(end, str):
        end = datetime.fromisoformat(end)
    if isinstance(start, datetime):
        start = start.date()
    if isinstance(end, datetime):
        end = end.date()
    return max(1, (end - start).days)


def min_trades_for_period(days: int, trades_per_day: float = DEFAULT_TRADES_PER_DAY) -> int:
    return max(30, int(days * trades_per_day))


def trades_per_day(report: BacktestReport, days: int) -> float:
    if report.total_trades == 0 or days <= 0:
        return 0.0
    return report.total_trades / days


def winning_months_pct(report: BacktestReport) -> float:
    if not report.monthly_returns:
        return 0.0
    vals = list(report.monthly_returns.values())
    return 100.0 * sum(1 for v in vals if v > 0) / len(vals)


def score_report(
    report: BacktestReport,
    period_days_count: int,
    trades_per_day_target: float = DEFAULT_TRADES_PER_DAY,
) -> float:
    """Higher is better. Hard-fails below activity + profit gates."""
    min_t = min_trades_for_period(period_days_count, trades_per_day_target)
    t = report.total_trades
    tpd = trades_per_day(report, period_days_count)

    if t < min_t or tpd < trades_per_day_target:
        return float("-inf")

    if report.net_profit <= 0 or report.profit_factor < 1.05:
        return float("-inf")

    win_mo = winning_months_pct(report) / 100.0
    activity = min(tpd / (trades_per_day_target * 1.5), 1.0)
    pf = min(report.profit_factor, 4.0) / 4.0
    wr = min(report.win_rate, 70.0) / 70.0

    return (
        report.sharpe * 0.25
        + (report.net_profit / 2000.0) * 0.18
        - report.max_drawdown_pct * 0.10
        + activity * 0.22
        + win_mo * 0.12
        + pf * 0.08
        + wr * 0.05
    )


def score_label(
    score: float,
    trades: int,
    period_days_count: int,
    trades_per_day_target: float = DEFAULT_TRADES_PER_DAY,
) -> str:
    min_t = min_trades_for_period(period_days_count, trades_per_day_target)
    tpd = trades / period_days_count if period_days_count else 0
    if trades < min_t:
        return f"N/A ({trades}<{min_t}, need {trades_per_day_target:.1f}/day)"
    if tpd < trades_per_day_target:
        return f"N/A ({tpd:.2f}/day < {trades_per_day_target:.1f}/day)"
    if score == float("-inf"):
        return "N/A (fails profit gates)"
    return f"{score:.2f}"


def acceptance(
    report: BacktestReport,
    period_days_count: int,
    trades_per_day_target: float = DEFAULT_TRADES_PER_DAY,
) -> tuple[bool, list[str]]:
    min_t = min_trades_for_period(period_days_count, trades_per_day_target)
    tpd = trades_per_day(report, period_days_count)
    issues: list[str] = []

    if report.total_trades < min_t:
        issues.append(f"trades={report.total_trades} need >={min_t} ({trades_per_day_target:.1f}/day x {period_days_count}d)")
    if tpd < trades_per_day_target:
        issues.append(f"trades/day={tpd:.2f} need >={trades_per_day_target:.1f}")
    if report.net_profit <= 0:
        issues.append(f"net=${report.net_profit:.0f} not positive")
    if report.profit_factor < 1.15:
        issues.append(f"pf={report.profit_factor:.2f} need >=1.15")
    if report.sharpe < 0.3:
        issues.append(f"sharpe={report.sharpe:.2f} need >=0.30")
    if report.max_drawdown_pct > 25:
        issues.append(f"dd={report.max_drawdown_pct:.1f}% too high")

    win_mo = winning_months_pct(report)
    if win_mo < 45:
        issues.append(f"winning_months={win_mo:.0f}% need >=45%")

    return len(issues) == 0, issues


def format_quality_line(report: BacktestReport, period_days_count: int) -> str:
    tpd = trades_per_day(report, period_days_count)
    return (
        f"net=${report.net_profit:.0f} sharpe={report.sharpe:.2f} "
        f"trades={report.total_trades} ({tpd:.2f}/day) pf={report.profit_factor:.2f} "
        f"wr={report.win_rate:.0f}% win_mo={winning_months_pct(report):.0f}% "
        f"dd={report.max_drawdown_pct:.1f}%"
    )
