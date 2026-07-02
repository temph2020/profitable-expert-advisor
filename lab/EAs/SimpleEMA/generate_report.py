"""Generate REPORT.md + charts for best_params.json.

WARNING: Python simulation only. For official results use:
  python run_mt5_portfolio.py && python generate_mt5_portfolio_report.py
"""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import MetaTrader5 as mt5
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
LAB = Path(__file__).resolve().parent
sys.path.insert(0, str(LAB))
sys.path.insert(1, str(ROOT / "backtesting" / "MT5"))

from run_optimize import Params, load_market, simulate, write_set  # noqa: E402
from strategy_v5 import V5Params, load_v5_cache, market_from_cache, simulate_v5, write_v5_set  # noqa: E402
from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from run_backtest import pip_size  # noqa: E402

OUT = Path(__file__).resolve().parent / "best_run"
PARAM_LABELS = {
    "fast_ema": "Fast EMA period",
    "slow_ema": "Slow EMA period",
    "entry_mode": "Entry mode (0=cross, 1=cross+pullback, 2=pullback)",
    "min_ema_gap_pips": "Min EMA gap (pips)",
    "cooldown_bars": "Cooldown bars",
    "atr_period": "ATR period",
    "atr_sl_mult": "SL = ATR x",
    "atr_tp_mult": "TP = ATR x",
    "exit_on_cross": "Exit on opposite cross",
    "max_bars_in_trade": "Max bars in trade",
    "use_trailing": "Trailing stop",
    "use_adx_filter": "ADX filter",
    "use_htf_filter": "H4 EMA trend filter",
    "htf_ema_period": "H4 EMA period",
    "session_start": "Session start (UTC hour)",
    "session_end": "Session end (UTC hour)",
    "max_spread_pips": "Max spread (pips)",
    "lot_size": "Lot size",
}


def main() -> None:
    with open(Path(__file__).parent / "best_params.json", encoding="utf-8") as f:
        data = json.load(f)
    version = data.get("version", 2)

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        sym = resolve_symbol("EURUSD")
        df = load_bars(sym, mt5.TIMEFRAME_M15, datetime(2020, 1, 1), datetime(2026, 1, 1))
        costs = CostModel.for_symbol(sym)
        pip = pip_size(sym)
        point = float(mt5.symbol_info(sym).point)

        if version >= 5:
            p = V5Params(**data["params"])
            r = simulate_v5(market_from_cache(load_v5_cache(df), p), sym, p, costs, pip, point)
            write_v5_set(p, Path(__file__).parent / "SimpleEMA_optimized.set")
            initial_balance = p.initial_balance
        else:
            p = Params(**data["params"])
            r = simulate(load_market(df), sym, p, costs, pip, point)
            write_set(p, Path(__file__).parent / "SimpleEMA_optimized.set")
            initial_balance = p.initial_balance

        rows = [
            {
                "side": t["side"],
                "open_time": df.index[t["open_i"]],
                "close_time": df.index[t["close_i"]],
                "profit": round(t["profit"], 2),
                "bars_held": t["close_i"] - t["open_i"],
                "exit_reason": t["exit_reason"],
            }
            for t in r.trades
        ]
        tdf = pd.DataFrame(rows)
        tdf.to_csv(OUT / "trades.csv", index=False)

        wins = tdf[tdf["profit"] > 0]["profit"]
        losses = tdf[tdf["profit"] <= 0]["profit"]
        exit_counts = tdf["exit_reason"].value_counts()

        eq = [initial_balance]
        for pr in tdf["profit"]:
            eq.append(eq[-1] + pr)
        eq_times = pd.to_datetime(tdf["close_time"])
        eq_s = pd.Series(eq[1:], index=eq_times)
        dd = (eq_s - eq_s.cummax()) / eq_s.cummax() * 100
        max_dd = abs(float(dd.min())) if len(dd) else 0.0

        monthly = tdf.copy()
        monthly["month"] = pd.to_datetime(monthly["close_time"]).dt.to_period("M")
        monthly_pnl = monthly.groupby("month")["profit"].sum()

        summary = {
            "symbol": sym,
            "timeframe": "M15",
            "period": "2020-01-01 to 2026-01-01",
            "initial_balance": initial_balance,
            "net_profit": round(r.net_profit, 2),
            "return_pct": round(r.net_profit / initial_balance * 100, 2),
            "total_trades": r.total_trades,
            "win_rate": round(r.win_rate, 1),
            "profit_factor": round(r.profit_factor, 2),
            "max_drawdown_pct": round(max_dd, 2),
            "avg_win": round(float(wins.mean()), 2) if len(wins) else 0,
            "avg_loss": round(float(losses.mean()), 2) if len(losses) else 0,
            "best_trade": round(float(tdf["profit"].max()), 2),
            "worst_trade": round(float(tdf["profit"].min()), 2),
            "target_met_2000_trades": data.get("target_met", False),
        }
        with open(OUT / "report.json", "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        axes[0, 0].plot(eq_times, eq[1:], lw=1.8, color="#2ca02c")
        axes[0, 0].axhline(initial_balance, ls="--", color="gray")
        axes[0, 0].set_title("Equity Curve")
        axes[0, 0].grid(alpha=0.3)
        axes[0, 1].fill_between(eq_times, dd, 0, color="#d62728", alpha=0.35)
        axes[0, 1].set_title("Drawdown %")
        axes[0, 1].grid(alpha=0.3)
        axes[1, 0].bar(
            range(len(monthly_pnl)),
            monthly_pnl.values,
            color=["#2ca02c" if v >= 0 else "#d62728" for v in monthly_pnl.values],
        )
        axes[1, 0].set_title("Monthly PnL")
        axes[1, 0].axhline(0, color="black", lw=0.6)
        axes[1, 1].bar(exit_counts.index.astype(str), exit_counts.values, color="#ff7f0e")
        axes[1, 1].set_title("Exit Reasons")
        fig.suptitle(
            f"SimpleEMA Best | Net ${r.net_profit:,.0f} | {r.total_trades} trades | "
            f"PF {r.profit_factor:.2f} | WR {r.win_rate:.1f}%",
            fontsize=12,
        )
        fig.tight_layout(rect=[0, 0, 1, 0.96])
        fig.savefig(OUT / "report.png", dpi=200, bbox_inches="tight")
        plt.close()

        md = [
            "# SimpleEMA Best Config Report",
            "",
            "## Overview",
            "",
            "| Metric | Value |",
            "|--------|-------|",
            f"| Symbol | {sym} |",
            "| Timeframe | M15 |",
            "| Period | 2020-01-01 ~ 2026-01-01 |",
            f"| Initial balance | ${initial_balance:,.0f} |",
            f"| **Net profit** | **${summary['net_profit']:,.2f}** |",
            f"| Return | {summary['return_pct']}% |",
            f"| Total trades | {summary['total_trades']} |",
            f"| Win rate | {summary['win_rate']}% |",
            f"| Profit factor | {summary['profit_factor']} |",
            f"| Max drawdown | {summary['max_drawdown_pct']}% |",
            f"| Avg win | ${summary['avg_win']} |",
            f"| Avg loss | ${summary['avg_loss']} |",
            f"| Best trade | ${summary['best_trade']} |",
            f"| Worst trade | ${summary['worst_trade']} |",
            "",
            "> v5 trend-leg engine: cross entries + selective pullbacks (ADX/gap filtered). "
            "Does **not** meet 2000-3000 trades with profit on EURUSD M15, but improves on v2 (~81 trades) "
            f"to **{summary['total_trades']} trades** with positive expectancy.",
            "",
            "## Best parameters",
            "",
            "| Parameter | Value |",
            "|-----------|-------|",
        ]
        for k, v in data["params"].items():
            label = PARAM_LABELS.get(k, k.replace("_", " ").title())
            md.append(f"| {label} | {v} |")

        md += ["", "## Exit reasons", ""]
        for reason, cnt in exit_counts.items():
            md.append(f"- **{reason}**: {cnt} ({cnt / r.total_trades * 100:.1f}%)")

        if version >= 5:
            logic = [
                "",
                "## Strategy logic (v5)",
                "",
                "1. **Cross entry**: fast/slow EMA cross + H4 trend + session/spread filters",
                "2. **Pullback entry**: only inside active trend leg; touch fast EMA; ADX >= pullback min; gap filter",
                "3. **Leg cap**: max 1 pullback per trend leg to avoid chop re-entries",
                "4. **Exit**: ATR SL/TP + max bars in trade",
            ]
        else:
            logic = [
                "",
                "## Strategy logic",
                "",
                "1. **Entry**: EMA cross only (fast 10 / slow 46)",
                "2. **Filters**: H4 EMA(200) trend alignment; UTC 08:00-22:00; spread <= 6 pips",
                "3. **Stops**: SL = ATR(20) x 2.71, TP = ATR(20) x 6.36",
                "4. **Exit**: TP / SL / max 64 M15 bars (~16h); no trailing; no cross exit",
                "5. **Cooldown**: 8 bars between entries",
            ]
        md += logic + [
            "## Artifacts",
            "",
            "- `best_run/trades.csv` — per-trade review",
            "- `best_run/report.png` — equity / drawdown / monthly chart",
            "- `SimpleEMA_optimized.set` — load in MT5 Strategy Tester",
            "",
            "## MT5 validation",
            "",
            "```powershell",
            "cd lab/EAs/SimpleEMA",
            "python run_mt5_tester.py backtest --period M15 --from 2020.01.01 --to 2026.01.01 --set SimpleEMA_optimized.set",
            "```",
        ]
        (OUT / "REPORT.md").write_text("\n".join(md), encoding="utf-8")
        print(f"Report saved to {OUT}")
        print(json.dumps(summary, indent=2))
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
