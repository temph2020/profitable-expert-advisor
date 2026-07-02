#!/usr/bin/env python3
"""Write best_run/PORTFOLIO_REPORT.md from portfolio_params.json."""

from __future__ import annotations

import json
from pathlib import Path

LAB = Path(__file__).resolve().parent
OUT = LAB / "best_run" / "PORTFOLIO_REPORT.md"


def main() -> None:
    data = json.loads((LAB / "portfolio_params.json").read_text(encoding="utf-8"))
    metrics = data.get("portfolio_metrics", {})
    members = data.get("members", [])
    enabled = [m for m in members if m.get("enabled")]
    disabled = [m for m in members if not m.get("enabled")]

    lines = [
        "# SimpleEMA v5 Portfolio Report (per-symbol optimized)",
        "",
        "## Combined metrics",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Net profit | **${metrics.get('net_profit', 0):,.2f}** |",
        f"| Total trades | {metrics.get('total_trades', 0)} |",
        f"| Profit factor | {metrics.get('profit_factor', 0)} |",
        f"| Win rate | {metrics.get('win_rate', 0)}% |",
        f"| Max drawdown | {metrics.get('max_drawdown_pct', 0)}% |",
        f"| 2000+ trades | {'YES' if metrics.get('target_met_2000_trades') else 'no'} |",
        f"| Profitable | {'YES' if metrics.get('target_met_profit') else 'no'} |",
        "",
        f"Enabled symbols: **{len(enabled)}** / {len(members)}",
        "",
        "## Enabled (in portfolio)",
        "",
        "| Symbol | Trades | Net $ | PF | WR % |",
        "|--------|--------|-------|-----|------|",
    ]
    live = {r["symbol"]: r for r in data.get("per_symbol_live", [])}
    for m in sorted(enabled, key=lambda x: -live.get(x["symbol"], {}).get("net_profit", 0)):
        sym = m["symbol"]
        r = live.get(sym, m.get("metrics", {}))
        lines.append(
            f"| {sym} | {r.get('trades', r.get('total_trades', '-'))} | "
            f"{r.get('net_profit', 0):,.0f} | {r.get('profit_factor', 0):.2f} | "
            f"{r.get('win_rate', 0):.1f} |"
        )

    if disabled:
        lines += ["", "## Disabled (failed selection)", ""]
        for m in disabled:
            met = m.get("metrics", {})
            lines.append(
                f"- **{m.get('symbol', m.get('requested'))}**: net=${met.get('net_profit', 0):,.0f} "
                f"t={met.get('total_trades', 0)} PF={met.get('profit_factor', 0):.2f}"
            )

    lines += [
        "",
        "## Files",
        "",
        "- `portfolio_params.json` — per-symbol params + enabled flag",
        "- `best_run/portfolio_trades.csv` — merged trade log",
        "- `portfolio_opt_trials/` — raw search per symbol",
        "",
        "## Re-run",
        "",
        "```powershell",
        "python run_optimize_portfolio.py --skip-opt",
        "python generate_portfolio_report.py",
        "```",
    ]
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
