#!/usr/bin/env python3
"""Generate portfolio report from MT5 Strategy Tester results only."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

LAB = Path(__file__).resolve().parent
RESULTS = LAB / "best_run" / "mt5_results.json"
OUT = LAB / "best_run"


def main() -> None:
    if not RESULTS.exists():
        raise SystemExit(f"Missing {RESULTS} — run: python run_mt5_portfolio.py")

    data = json.loads(RESULTS.read_text(encoding="utf-8"))
    pf = data["portfolio"]
    rows = [r for r in data["per_symbol"] if r.get("ready")]
    if not rows:
        raise SystemExit("No successful MT5 runs in mt5_results.json")

    df = pd.DataFrame(rows).sort_values("net_profit", ascending=False)

    # Bar chart: net profit by symbol
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    colors = ["#2ca02c" if v >= 0 else "#d62728" for v in df["net_profit"]]
    axes[0].barh(df["symbol"], df["net_profit"], color=colors)
    axes[0].axvline(0, color="gray", lw=0.8)
    axes[0].set_title("MT5 Net Profit by Symbol")
    axes[0].set_xlabel("USD")

    axes[1].barh(df["symbol"], df["total_trades"], color="#1f77b4")
    axes[1].set_title("MT5 Trades by Symbol")
    axes[1].set_xlabel("Trades")

    fig.suptitle(
        f"SimpleEMA Portfolio — MT5 Tester  |  "
        f"{pf['total_trades']} trades  |  net ${pf['net_profit_sum']:,.0f}",
        fontsize=12,
    )
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    chart_png = OUT / "MT5_portfolio_summary.png"
    fig.savefig(chart_png, dpi=200, bbox_inches="tight")
    plt.close(fig)

    md = [
        "# SimpleEMA Portfolio — MT5 Strategy Tester Report",
        "",
        "> **Source of truth: MT5 native backtest only.** Python `portfolio_trades.csv` is for dev iteration.",
        "",
        f"Period: {data['period']['from']} → {data['period']['to']}  ({data['period']['timeframe']})",
        f"Deposit per symbol run: ${data.get('deposit_per_symbol', 10000):,.0f}",
        "",
        "## Combined (sum of per-symbol MT5 runs)",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Symbols tested | {pf['symbols_tested']} |",
        f"| **Total trades** | **{pf['total_trades']}** |",
        f"| **Net profit (sum)** | **${pf['net_profit_sum']:,.2f}** |",
        f"| PF (approx from net) | {pf.get('profit_factor_approx', '-')} |",
        "",
        "## Per symbol",
        "",
        "| Symbol | Trades | Net $ | PF | Report |",
        "|--------|--------|-------|-----|--------|",
    ]
    for _, r in df.iterrows():
        rep = r.get("report", "")
        link = f"[HTML]({rep})" if rep else "-"
        md.append(
            f"| {r['symbol']} | {int(r['total_trades'])} | {r['net_profit']:,.2f} | "
            f"{r.get('profit_factor', '-')} | {link} |"
        )

    md += [
        "",
        "## Files",
        "",
        "- `best_run/mt5_results.json` — parsed MT5 metrics",
        "- `best_run/mt5_reports/*.htm` — raw MT5 HTML reports (逐单复盘在 MT5 里打开)",
        "- `best_run/MT5_portfolio_summary.png` — summary chart",
        "",
        "## Note on SimpleEMA_report.pdf",
        "",
        "`SimpleEMA_report.pdf` is the **single-symbol EURUSD** report (~115 trades).",
        "Portfolio results are in **this file** and `mt5_results.json`.",
    ]
    md_path = OUT / "MT5_PORTFOLIO_REPORT.md"
    md_path.write_text("\n".join(md), encoding="utf-8")

    df[["symbol", "total_trades", "net_profit", "profit_factor", "report"]].to_csv(
        OUT / "mt5_by_symbol.csv", index=False
    )

    # Copy summary as primary portfolio PNG user may expect
    shutil.copy2(chart_png, OUT / "SimpleEMA_report.png")

    print(f"Wrote {md_path}")
    print(f"Wrote {chart_png}")
    print(f"Updated {OUT / 'SimpleEMA_report.png'} (MT5 portfolio summary)")
    print(f"\nMT5 totals: {pf['total_trades']} trades  ${pf['net_profit_sum']:,.2f}")

    from generate_mt5_portfolio_pdf import generate_pdf_png

    print("\nGenerating PDF + PNG report …")
    generate_pdf_png(data)


if __name__ == "__main__":
    main()
