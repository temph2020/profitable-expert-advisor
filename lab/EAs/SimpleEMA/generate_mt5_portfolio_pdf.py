#!/usr/bin/env python3
"""Generate MT5 portfolio PDF + PNG from Strategy Tester HTML reports."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import textwrap
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

LAB = Path(__file__).resolve().parent
OUT = LAB / "best_run"
FIG = OUT / "figures"
RESULTS = OUT / "mt5_results.json"
REPORTS = OUT / "mt5_reports"
TEX = OUT / "SimpleEMA_report.tex"
PDF = OUT / "SimpleEMA_report.pdf"
PNG = OUT / "SimpleEMA_report.png"
REPORT_PNG = OUT / "report.png"
TRADES_CSV = OUT / "mt5_portfolio_trades.csv"

plt.rcParams.update({"figure.dpi": 150, "savefig.dpi": 150, "font.size": 9})


def read_html(path: Path) -> str:
    text = path.read_text(encoding="utf-16", errors="ignore")
    if not text.strip():
        text = path.read_text(encoding="utf-8", errors="ignore")
    return text


def latex_escape(s: str) -> str:
    for a, b in (("\\", "\\textbackslash{}"), ("&", "\\&"), ("%", "\\%"),
                 ("$", "\\$"), ("#", "\\#"), ("_", "\\_"), ("{", "\\{"), ("}", "\\}")):
        s = s.replace(a, b)
    return s


def parse_mt5_deals(html_path: Path, symbol: str) -> list[dict]:
    text = read_html(html_path)
    if "<b>成交</b>" not in text:
        return []
    section = text.split("<b>成交</b>", 1)[1].split("</table>", 1)[0]
    rows: list[dict] = []
    for tr in re.findall(r'<tr bgcolor="[^"]*" align=right>(.*?)</tr>', section, re.DOTALL | re.I):
        cols = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.DOTALL | re.I)
        if len(cols) < 11:
            continue
        typ = re.sub(r"<[^>]+>", "", cols[3]).strip().lower()
        direction = re.sub(r"<[^>]+>", "", cols[4]).strip().lower()
        if typ == "balance" or direction != "out" or typ not in ("buy", "sell"):
            continue
        profit_s = re.sub(r"<[^>]+>", "", cols[10]).replace(" ", "").replace(",", "")
        try:
            profit = float(profit_s)
        except ValueError:
            continue
        comment = re.sub(r"<[^>]+>", "", cols[12]).strip() if len(cols) > 12 else ""
        cl = comment.lower()
        if "sl " in cl or cl.startswith("sl"):
            exit_reason = "sl"
        elif "tp " in cl or cl.startswith("tp"):
            exit_reason = "tp"
        else:
            exit_reason = "other"
        close_time = pd.to_datetime(re.sub(r"<[^>]+>", "", cols[0]).strip())
        rows.append(
            {
                "symbol": symbol,
                "close_time": close_time,
                "profit": profit,
                "exit_reason": exit_reason,
                "side": typ,
            }
        )
    return rows


def load_portfolio_trades(rows: list[dict]) -> pd.DataFrame:
    all_rows: list[dict] = []
    for r in rows:
        if not r.get("ready"):
            continue
        rep = r.get("report") or r.get("report_local")
        if not rep:
            cand = REPORTS / f"SimpleEMA_pf_{r['symbol']}.htm"
            rep = str(cand) if cand.exists() else None
        if not rep or not Path(rep).exists():
            continue
        all_rows.extend(parse_mt5_deals(Path(rep), r["symbol"]))
    if not all_rows:
        return pd.DataFrame()
    return pd.DataFrame(all_rows).sort_values(["close_time", "symbol"]).reset_index(drop=True)


def portfolio_summary(trades: pd.DataFrame, pf: dict, deposit: float, n_syms: int) -> dict:
    if trades.empty:
        return {
            "total_trades": pf.get("total_trades", 0),
            "net_profit": pf.get("net_profit_sum", 0),
            "win_rate": 0.0,
            "profit_factor": pf.get("profit_factor_approx") or 0.0,
            "max_drawdown_pct": 0.0,
            "initial_balance": deposit * n_syms,
            "return_pct": 0.0,
            "avg_win": 0.0,
            "avg_loss": 0.0,
            "best_trade": 0.0,
            "worst_trade": 0.0,
        }
    wins = trades[trades["profit"] > 0]
    losses = trades[trades["profit"] < 0]
    gp = wins["profit"].sum()
    gl = abs(losses["profit"].sum())
    initial = deposit * n_syms
    eq = initial + trades["profit"].cumsum()
    dd = (eq - eq.cummax()) / eq.cummax() * 100
    net = trades["profit"].sum()
    return {
        "total_trades": len(trades),
        "net_profit": round(net, 2),
        "win_rate": round(len(wins) / len(trades) * 100, 1),
        "profit_factor": round(gp / gl, 2) if gl > 0 else 999.0,
        "max_drawdown_pct": round(abs(dd.min()), 2),
        "initial_balance": initial,
        "return_pct": round(net / initial * 100, 2),
        "avg_win": round(wins["profit"].mean(), 2) if len(wins) else 0.0,
        "avg_loss": round(losses["profit"].mean(), 2) if len(losses) else 0.0,
        "best_trade": round(trades["profit"].max(), 2),
        "worst_trade": round(trades["profit"].min(), 2),
    }


def save_figures(trades: pd.DataFrame, sym_df: pd.DataFrame, summary: dict, pf: dict) -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    initial = summary["initial_balance"]

    if not trades.empty:
        eq = initial + trades.sort_values("close_time")["profit"].cumsum()
        times = trades.sort_values("close_time")["close_time"]
        dd = (eq - eq.cummax()) / eq.cummax() * 100

        fig, ax = plt.subplots(figsize=(8, 3.2))
        ax.plot(times, eq, color="#2ca02c", lw=1.4)
        ax.axhline(initial, ls="--", color="#888", lw=0.8)
        ax.set_title("Portfolio Equity (MT5 deals, combined timeline)")
        ax.set_ylabel("Balance (USD)")
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(FIG / "equity.pdf", bbox_inches="tight")
        fig.savefig(FIG / "equity.png", bbox_inches="tight")
        plt.close(fig)

        fig, ax = plt.subplots(figsize=(8, 2.8))
        ax.fill_between(times, dd, 0, color="#d62728", alpha=0.35)
        ax.plot(times, dd, color="#8b0000", lw=0.8)
        ax.set_title("Portfolio Drawdown")
        ax.set_ylabel("Drawdown (%)")
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(FIG / "drawdown.pdf", bbox_inches="tight")
        fig.savefig(FIG / "drawdown.png", bbox_inches="tight")
        plt.close(fig)

        monthly = trades.copy()
        monthly["month"] = monthly["close_time"].dt.to_period("M")
        mp = monthly.groupby("month")["profit"].sum()
        fig, ax = plt.subplots(figsize=(8, 3))
        colors = ["#2ca02c" if v >= 0 else "#d62728" for v in mp.values]
        ax.bar(range(len(mp)), mp.values, color=colors, width=0.85)
        ax.set_title("Monthly PnL (all symbols)")
        ax.set_ylabel("USD")
        ax.axhline(0, color="black", lw=0.6)
        step = max(1, len(mp) // 8)
        ax.set_xticks(range(0, len(mp), step))
        ax.set_xticklabels([str(m) for m in mp.index[::step]], rotation=45, ha="right")
        fig.tight_layout()
        fig.savefig(FIG / "monthly.pdf", bbox_inches="tight")
        fig.savefig(FIG / "monthly.png", bbox_inches="tight")
        plt.close(fig)

        rc = trades["exit_reason"].value_counts()
        fig, ax = plt.subplots(figsize=(5, 3))
        ax.bar(rc.index.astype(str), rc.values, color="#ff7f0e")
        ax.set_title("Exit Reasons (from MT5 comments)")
        ax.set_ylabel("Count")
        fig.tight_layout()
        fig.savefig(FIG / "exits.pdf", bbox_inches="tight")
        fig.savefig(FIG / "exits.png", bbox_inches="tight")
        plt.close(fig)

        fig, ax = plt.subplots(figsize=(5, 3))
        ax.hist(trades["profit"], bins=30, color="#9467bd", alpha=0.85, edgecolor="white")
        ax.axvline(0, color="black", lw=0.8)
        ax.set_title("Per-Trade PnL Distribution")
        ax.set_xlabel("Profit (USD)")
        fig.tight_layout()
        fig.savefig(FIG / "pnl_hist.pdf", bbox_inches="tight")
        fig.savefig(FIG / "pnl_hist.png", bbox_inches="tight")
        plt.close(fig)

    # Summary bar chart
    fig, axes = plt.subplots(1, 2, figsize=(14, max(5, len(sym_df) * 0.22)))
    colors = ["#2ca02c" if v >= 0 else "#d62728" for v in sym_df["net_profit"]]
    axes[0].barh(sym_df["symbol"], sym_df["net_profit"], color=colors)
    axes[0].axvline(0, color="gray", lw=0.8)
    axes[0].set_title("MT5 Net Profit by Symbol")
    axes[0].set_xlabel("USD")
    axes[1].barh(sym_df["symbol"], sym_df["total_trades"], color="#1f77b4")
    axes[1].set_title("MT5 Trades by Symbol")
    axes[1].set_xlabel("Trades")
    fig.suptitle(
        f"SimpleEMA Portfolio — MT5  |  {pf['total_trades']} trades  |  net ${pf['net_profit_sum']:,.0f}",
        fontsize=12,
    )
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    summary_png = OUT / "MT5_portfolio_summary.png"
    fig.savefig(summary_png, dpi=200, bbox_inches="tight")
    fig.savefig(REPORT_PNG, dpi=200, bbox_inches="tight")
    plt.close(fig)


def symbol_table_tex(sym_df: pd.DataFrame, max_rows: int = 35) -> str:
    lines = []
    for _, r in sym_df.head(max_rows).iterrows():
        lines.append(
            f"{latex_escape(str(r['symbol']))} & {int(r['total_trades'])} & "
            f"{r['net_profit']:,.2f} & {r.get('profit_factor', '-')} \\\\"
        )
    return "\n".join(lines)


def trade_table_rows(trades: pd.DataFrame, n: int = 10, best: bool = True) -> str:
    if trades.empty:
        return "- & - & - & - \\\\"
    sub = trades.nlargest(n, "profit") if best else trades.nsmallest(n, "profit")
    lines = []
    for _, r in sub.iterrows():
        lines.append(
            f"{latex_escape(str(r['symbol']))} & {r['side']} & "
            f"{r['close_time'].strftime('%Y-%m-%d %H:%M')} & {r['profit']:.2f} & "
            f"{latex_escape(str(r['exit_reason']))} \\\\"
        )
    return "\n".join(lines)


def build_tex(data: dict, sym_df: pd.DataFrame, trades: pd.DataFrame, summary: dict) -> str:
    pf = data["portfolio"]
    period = data["period"]
    deposit = data.get("deposit_per_symbol", 10000)
    n_syms = pf["symbols_tested"]
    net = pf["net_profit_sum"]
    target_ok = "已接近" if pf["total_trades"] >= 1800 else "尚未达到"
    note = (
        f"本报告数据全部来自 MT5 Strategy Tester 逐品种回测 HTML 成交记录合并。"
        f"共 {n_syms} 个盈利品种独立优化后合并，非 Python 模拟。"
    )

    exit_tex = ""
    if not trades.empty:
        exit_counts = trades["exit_reason"].value_counts()
        exit_tex = "\n".join(
            f"{latex_escape(str(k))} & {v} & {v / len(trades) * 100:.1f}\\% \\\\"
            for k, v in exit_counts.items()
        )

    fig_block = ""
    if not trades.empty:
        fig_block = textwrap.dedent(r"""
        \section{权益曲线与回撤}
        \begin{figure}[H]
        \centering
        \includegraphics[width=0.92\textwidth]{figures/equity.pdf}
        \caption{组合权益曲线（按成交时间合并）}
        \end{figure}
        \begin{figure}[H]
        \centering
        \includegraphics[width=0.92\textwidth]{figures/drawdown.pdf}
        \caption{组合回撤}
        \end{figure}

        \section{月度盈亏与出场结构}
        \begin{figure}[H]
        \centering
        \begin{minipage}{0.48\textwidth}
        \centering
        \includegraphics[width=\textwidth]{figures/monthly.pdf}
        \caption{逐月 PnL}
        \end{minipage}\hfill
        \begin{minipage}{0.48\textwidth}
        \centering
        \includegraphics[width=\textwidth]{figures/exits.pdf}
        \caption{出场类型}
        \end{minipage}
        \end{figure}
        """)

    return textwrap.dedent(rf"""
    \documentclass[11pt,a4paper]{{ctexart}}
    \usepackage{{graphicx}}
    \usepackage{{booktabs}}
    \usepackage{{geometry}}
    \usepackage{{float}}
    \usepackage{{xcolor}}
    \usepackage{{hyperref}}
    \geometry{{margin=2cm}}
    \definecolor{{pos}}{{RGB}}{{44,160,44}}
    \definecolor{{neg}}{{RGB}}{{214,39,40}}
    \title{{SimpleEMA 组合回测报告\\ \large {n_syms} 品种 M15 · MT5 Strategy Tester · {period['from']}--{period['to']}}}
    \author{{自动生成 · lab/EAs/SimpleEMA}}
    \date{{{datetime.now().strftime("%Y-%m-%d")}}}

    \begin{{document}}
    \maketitle

    \section{{执行摘要}}
    {latex_escape(note)}

    \begin{{table}}[H]
    \centering
    \caption{{组合关键指标（MT5 官方回测）}}
    \begin{{tabular}}{{lr}}
    \toprule
    指标 & 数值 \\
    \midrule
    回测区间 & {period['from']} $\sim$ {period['to']} ({period['timeframe']}) \\
    入选品种数 & {n_syms} \\
    每品种初始资金 & \${deposit:,.0f} \\
    组合初始资金（合计） & \${summary['initial_balance']:,.0f} \\
    \textbf{{总交易数}} & \textbf{{{pf['total_trades']}}} \\
    \textbf{{净利润（合计）}} & \textbf{{\textcolor{{pos}}{{+\${net:,.2f}}}}} \\
    收益率（相对合计本金） & {summary['return_pct']:.2f}\% \\
    胜率 & {summary['win_rate']:.1f}\% \\
    盈利因子 PF & {summary['profit_factor']:.2f} \\
    最大回撤 & {summary['max_drawdown_pct']:.2f}\% \\
    2000+ 笔目标 & {target_ok}（当前 {pf['total_trades']} 笔） \\
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \section{{分品种绩效}}
    \begin{{table}}[H]
    \centering
    \small
    \caption{{各品种 MT5 回测结果（按净利润排序）}}
    \begin{{tabular}}{{lrrr}}
    \toprule
    品种 & 交易数 & 净利润 (\$) & PF \\
    \midrule
    {symbol_table_tex(sym_df)}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \begin{{figure}}[H]
    \centering
    \includegraphics[width=0.95\textwidth]{{MT5_portfolio_summary.png}}
    \caption{{分品种净利润与交易次数}}
    \end{{figure}}

    {fig_block}

    \section{{逐单复盘（节选）}}
    \begin{{table}}[H]
    \centering
    \small
    \caption{{最佳 10 笔}}
    \begin{{tabular}}{{llrrl}}
    \toprule
    品种 & 方向 & 平仓时间 & 盈亏 & 出场 \\
    \midrule
    {trade_table_rows(trades, 10, True)}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \begin{{table}}[H]
    \centering
    \small
    \caption{{最差 10 笔}}
    \begin{{tabular}}{{llrrl}}
    \toprule
    品种 & 方向 & 平仓时间 & 盈亏 & 出场 \\
    \midrule
    {trade_table_rows(trades, 10, False)}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \noindent 完整成交见 \texttt{{mt5\_portfolio\_trades.csv}} 及各品种 \texttt{{mt5\_reports/*.htm}}。

    \end{{document}}
    """).strip() + "\n"


def compile_pdf() -> bool:
    for _ in range(2):
        r = subprocess.run(
            ["xelatex", "-interaction=nonstopmode", "SimpleEMA_report.tex"],
            cwd=OUT,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            print(r.stdout[-1500:] if r.stdout else "")
            print(r.stderr[-1500:] if r.stderr else "")
    return PDF.exists()


def pdf_to_png() -> bool:
    try:
        import fitz

        doc = fitz.open(PDF)
        zoom = 200 / 72
        mat = fitz.Matrix(zoom, zoom)
        images = [page.get_pixmap(matrix=mat, alpha=False) for page in doc]
        if len(images) == 1:
            images[0].save(PNG)
        else:
            from PIL import Image
            import io

            w = max(p.width for p in images)
            h = sum(p.height for p in images)
            canvas = Image.new("RGB", (w, h), "white")
            y = 0
            for pix in images:
                img = Image.open(io.BytesIO(pix.tobytes("png")))
                canvas.paste(img, (0, y))
                y += pix.height
            canvas.save(PNG, dpi=(200, 200))
        doc.close()
        return PNG.exists()
    except ImportError:
        pass

    if shutil.which("magick"):
        subprocess.run(["magick", "convert", "-density", "200", str(PDF), str(PNG)], check=False)
        return PNG.exists()

    src = OUT / "MT5_portfolio_summary.png"
    if src.exists():
        shutil.copy2(src, PNG)
        return True
    return False


def generate_pdf_png(data: dict | None = None) -> None:
    if data is None:
        if not RESULTS.exists():
            raise SystemExit(f"Missing {RESULTS}")
        data = json.loads(RESULTS.read_text(encoding="utf-8"))

    rows = [r for r in data["per_symbol"] if r.get("ready")]
    sym_df = pd.DataFrame(rows).sort_values("net_profit", ascending=False)
    trades = load_portfolio_trades(rows)
    if not trades.empty:
        trades.to_csv(TRADES_CSV, index=False)

    deposit = data.get("deposit_per_symbol", 10000)
    summary = portfolio_summary(trades, data["portfolio"], deposit, len(rows))
    save_figures(trades, sym_df, summary, data["portfolio"])

    TEX.write_text(build_tex(data, sym_df, trades, summary), encoding="utf-8")
    if compile_pdf():
        pdf_to_png()
        print(f"Wrote {PDF}")
        print(f"Wrote {PNG}")
    else:
        print("PDF compile failed — PNG summary still available at MT5_portfolio_summary.png")
        shutil.copy2(OUT / "MT5_portfolio_summary.png", PNG)

    shutil.copy2(PNG, REPORT_PNG)
    print(f"Wrote {REPORT_PNG}")
    print(f"Trades parsed from MT5 HTML: {len(trades)}")


if __name__ == "__main__":
    generate_pdf_png()
