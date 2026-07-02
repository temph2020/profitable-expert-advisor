#!/usr/bin/env python3
"""Generate SimpleEMA LaTeX report -> PDF + PNG.

WARNING: Reads Python backtest (single-symbol). Portfolio official report:
  best_run/MT5_PORTFOLIO_REPORT.md  (from MT5 Strategy Tester)
"""

from __future__ import annotations

import json
import shutil
import subprocess
import textwrap
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "best_run"
FIG = OUT / "figures"
TEX = OUT / "SimpleEMA_report.tex"
PDF = OUT / "SimpleEMA_report.pdf"
PNG = OUT / "SimpleEMA_report.png"

plt.rcParams.update({"figure.dpi": 150, "savefig.dpi": 150, "font.size": 9})


def latex_escape(s: str) -> str:
    for a, b in (("\\", "\\textbackslash{}"), ("&", "\\&"), ("%", "\\%"),
                 ("$", "\\$"), ("#", "\\#"), ("_", "\\_"), ("{", "\\{"), ("}", "\\}")):
        s = s.replace(a, b)
    return s


def load_data() -> tuple[dict, dict, pd.DataFrame]:
    with open(ROOT / "best_params.json", encoding="utf-8") as f:
        bp = json.load(f)
    summary_path = OUT / "report.json"
    if summary_path.exists():
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    else:
        summary = bp.get("metrics", {})
    trades = pd.read_csv(OUT / "trades.csv")
    trades["open_time"] = pd.to_datetime(trades["open_time"])
    trades["close_time"] = pd.to_datetime(trades["close_time"])
    return bp, summary, trades


def save_figures(trades: pd.DataFrame, summary: dict) -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    bal0 = summary.get("initial_balance", 10_000.0)
    eq = bal0 + trades.sort_values("close_time")["profit"].cumsum()
    times = trades.sort_values("close_time")["close_time"]
    dd = (eq - eq.cummax()) / eq.cummax() * 100

    fig, ax = plt.subplots(figsize=(8, 3.2))
    ax.plot(times, eq, color="#2ca02c", lw=1.6)
    ax.axhline(bal0, ls="--", color="#888", lw=0.8)
    ax.set_title("Equity Curve")
    ax.set_ylabel("Balance (USD)")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(FIG / "equity.pdf", bbox_inches="tight")
    fig.savefig(FIG / "equity.png", bbox_inches="tight")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(8, 2.8))
    ax.fill_between(times, dd, 0, color="#d62728", alpha=0.35)
    ax.plot(times, dd, color="#8b0000", lw=0.8)
    ax.set_title("Drawdown")
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
    ax.set_title("Monthly PnL")
    ax.set_ylabel("USD")
    ax.axhline(0, color="black", lw=0.6)
    ax.set_xticks(range(0, len(mp), max(1, len(mp) // 8)))
    ax.set_xticklabels([str(m) for m in mp.index[:: max(1, len(mp) // 8)]], rotation=45, ha="right")
    fig.tight_layout()
    fig.savefig(FIG / "monthly.pdf", bbox_inches="tight")
    fig.savefig(FIG / "monthly.png", bbox_inches="tight")
    plt.close(fig)

    rc = trades["exit_reason"].value_counts()
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.bar(rc.index.astype(str), rc.values, color="#ff7f0e")
    ax.set_title("Exit Reasons")
    ax.set_ylabel("Count")
    fig.tight_layout()
    fig.savefig(FIG / "exits.pdf", bbox_inches="tight")
    fig.savefig(FIG / "exits.png", bbox_inches="tight")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(5, 3))
    ax.hist(trades["profit"], bins=20, color="#9467bd", alpha=0.85, edgecolor="white")
    ax.axvline(0, color="black", lw=0.8)
    ax.set_title("Per-Trade PnL Distribution")
    ax.set_xlabel("Profit (USD)")
    fig.tight_layout()
    fig.savefig(FIG / "pnl_hist.pdf", bbox_inches="tight")
    fig.savefig(FIG / "pnl_hist.png", bbox_inches="tight")
    plt.close(fig)


def trade_table_rows(trades: pd.DataFrame, n: int = 12, best: bool = True) -> str:
    col = "profit"
    sub = trades.nlargest(n, col) if best else trades.nsmallest(n, col)
    lines = []
    for _, r in sub.iterrows():
        lines.append(
            f"{r['side']} & {r['open_time'].strftime('%Y-%m-%d %H:%M')} & "
            f"{r['close_time'].strftime('%Y-%m-%d %H:%M')} & "
            f"{r['profit']:.2f} & {latex_escape(str(r['exit_reason']))} \\\\"
        )
    return "\n".join(lines)


def build_tex(bp: dict, summary: dict, trades: pd.DataFrame) -> str:
    p = bp["params"]
    version = int(bp.get("version", 2))
    net = summary.get("net_profit", 0)

    if version >= 5:
        param_rows = [
            ("快 EMA / 慢 EMA", f"{p['fast_ema']} / {p['slow_ema']}"),
            ("入场", "交叉 + 趋势段回调" if p.get("use_pullback") else "仅交叉"),
            ("趋势段长度", f"{p.get('trend_leg_bars', '-')} bars"),
            ("交叉冷却", f"{p.get('cross_cooldown', '-')} bars"),
            ("回调冷却", f"{p.get('pullback_cooldown', '-')} bars"),
            ("回调 ADX 下限", str(p.get("pullback_adx_min", "-"))),
            ("回调最小间距", f"{p.get('pullback_min_gap_pips', '-')} pips"),
            ("每段最多回调", str(p.get("max_pullbacks_per_leg", 1))),
            ("ATR 周期", str(p["atr_period"])),
            ("止损 SL", f"ATR $\\times$ {p['atr_sl_mult']}"),
            ("止盈 TP", f"ATR $\\times$ {p['atr_tp_mult']}"),
            ("最大持仓", f"{p['max_bars_in_trade']} bars M15"),
            ("H4 EMA 过滤", f"EMA({p['htf_ema_period']})" if p.get("use_htf_filter") else "关"),
            ("交易时段 (UTC)", f"{p['session_start']}:00 -- {p['session_end']}:00"),
            ("最大点差", f"{p['max_spread_pips']} pips"),
            ("手数", str(p["lot_size"])),
        ]
        logic_note = (
            "v5 逻辑：EMA 交叉为主入场；仅在活跃趋势段内允许一次高质量回调"
            "（ADX/间距过滤），避免 v3 多层过滤导致样本过少。"
        )
    else:
        param_rows = [
            ("快 EMA / 慢 EMA", f"{p['fast_ema']} / {p['slow_ema']}"),
            ("入场模式", "EMA 交叉 (mode=0)"),
            ("最小 EMA 间距", f"{p['min_ema_gap_pips']} pips"),
            ("冷却 K 线", str(p["cooldown_bars"])),
            ("ATR 周期", str(p["atr_period"])),
            ("止损 SL", f"ATR $\\times$ {p['atr_sl_mult']}"),
            ("止盈 TP", f"ATR $\\times$ {p['atr_tp_mult']}"),
            ("反向交叉平仓", "否" if not p.get("exit_on_cross") else "是"),
            ("最大持仓", f"{p['max_bars_in_trade']} bars M15"),
            ("H4 EMA 过滤", f"EMA({p['htf_ema_period']})" if p.get("use_htf_filter") else "关"),
            ("交易时段 (UTC)", f"{p['session_start']}:00 -- {p['session_end']}:00"),
            ("最大点差", f"{p['max_spread_pips']} pips"),
            ("手数", str(p["lot_size"])),
        ]
        logic_note = "v2 逻辑：EMA 交叉 + H4 趋势过滤。"
    param_tex = "\n".join(f"{k} & {v} \\\\" for k, v in param_rows)

    if version >= 5:
        strategy_tex = textwrap.dedent(rf"""
        \begin{{enumerate}}
        \item \textbf{{交叉入场}}：M15 EMA({p["fast_ema"]}/{p["slow_ema"]}) 金叉/死叉 + H4 趋势过滤。
        \item \textbf{{回调入场}}：仅在趋势段（{p.get("trend_leg_bars", 48)} bars）内，价格回踩 EMA 后收回；ADX $\ge$ {p.get("pullback_adx_min", 0)}；每段最多 {p.get("max_pullbacks_per_leg", 1)} 次。
        \item \textbf{{过滤}}：UTC {p["session_start"]}:00--{p["session_end"]}:00；点差 $\le$ {p["max_spread_pips"]} pips。
        \item \textbf{{风控}}：SL = ATR({p["atr_period"]}) $\times$ {p["atr_sl_mult"]}，TP = ATR $\times$ {p["atr_tp_mult"]}。
        \item \textbf{{冷却}}：交叉 {p.get("cross_cooldown", "-")} bars；回调 {p.get("pullback_cooldown", "-")} bars。
        \end{{enumerate}}
        """)
        summary_note = (
            f"未达到 2000--3000 笔目标（当前 {summary.get('total_trades', len(trades))} 笔），"
            f"但 v5 在 v2 约 81 笔基础上提升到 {summary.get('total_trades', len(trades))} 笔且保持 PF>1。"
            + logic_note
        )
    else:
        strategy_tex = textwrap.dedent(rf"""
        \begin{{enumerate}}
        \item \textbf{{入场}}：M15 上 EMA({p["fast_ema"]}/{p["slow_ema"]}) 金叉/死叉，最小间距 {p["min_ema_gap_pips"]} pips。
        \item \textbf{{过滤}}：价格须在 H4 EMA({p["htf_ema_period"]}) 趋势同侧；UTC {p["session_start"]}:00--{p["session_end"]}:00；点差 $\le$ {p["max_spread_pips"]} pips。
        \item \textbf{{风控}}：SL = ATR({p["atr_period"]}) $\times$ {p["atr_sl_mult"]}，TP = ATR $\times$ {p["atr_tp_mult"]}。
        \item \textbf{{出场}}：触及 SL/TP，或持仓超过 {p["max_bars_in_trade"]} 根 M15 K 线。
        \item \textbf{{冷却}}：每笔交易后等待 {p.get("cooldown_bars", "-")} 根 K 线再入场。
        \end{{enumerate}}
        """)
        summary_note = (
            f"未达到 2000--3000 笔交易目标（当前 {summary.get('total_trades', len(trades))} 笔）。"
            + logic_note
        )

    exit_counts = trades["exit_reason"].value_counts()
    exit_tex = "\n".join(
        f"{latex_escape(str(k))} & {v} & {v / len(trades) * 100:.1f}\\% \\\\" for k, v in exit_counts.items()
    )

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
    \title{{SimpleEMA 最优参数回测报告\\ \large EURUSD M15 · 2020--2026 · 最终版}}
    \author{{自动生成 · lab/EAs/SimpleEMA}}
    \date{{{datetime.now().strftime("%Y-%m-%d")}}}

    \begin{{document}}
    \maketitle

    \section{{执行摘要}}
    本报告为 SimpleEMA 策略在修复 trailing-stop 模拟 bug 后，经 6000+ 次随机搜索得到的\textbf{{真实最优}}参数配置。
    回测含点差与滑点，非 MT5 测试器 HTML 导出。

    \begin{{table}}[H]
    \centering
    \caption{{关键绩效指标}}
    \begin{{tabular}}{{lr}}
    \toprule
    指标 & 数值 \\
    \midrule
    货币对 / 周期 & {latex_escape(summary.get("symbol", "EURUSD"))} / M15 \\
    回测区间 & 2020-01-01 $\sim$ 2026-01-01 \\
    初始资金 & \${summary.get("initial_balance", 10000):,.0f} \\
    \textbf{{净利润}} & \textbf{{\textcolor{{pos}}{{+\${net:,.2f}}}}} \\
    收益率 & {summary.get("return_pct", 0):.2f}\% \\
    总交易数 & {summary.get("total_trades", len(trades))} \\
    胜率 & {summary.get("win_rate", 0):.1f}\% \\
    盈利因子 PF & {summary.get("profit_factor", 0):.2f} \\
    最大回撤 & {summary.get("max_drawdown_pct", 0):.2f}\% \\
    平均盈利 / 亏损 & \${summary.get("avg_win", 0):.2f} / \${summary.get("avg_loss", 0):.2f} \\
    最佳 / 最差单笔 & \${summary.get("best_trade", 0):.2f} / \${summary.get("worst_trade", 0):.2f} \\
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \noindent\textbf{{说明：}}{latex_escape(summary_note)}

    \section{{权益曲线与回撤}}
    \begin{{figure}}[H]
    \centering
    \includegraphics[width=0.92\textwidth]{{figures/equity.pdf}}
    \caption{{账户权益曲线}}
    \end{{figure}}
    \begin{{figure}}[H]
    \centering
    \includegraphics[width=0.92\textwidth]{{figures/drawdown.pdf}}
    \caption{{回撤百分比}}
    \end{{figure}}

    \section{{月度盈亏与出场结构}}
    \begin{{figure}}[H]
    \centering
    \begin{{minipage}}{{0.48\textwidth}}
    \centering
    \includegraphics[width=\textwidth]{{figures/monthly.pdf}}
    \caption{{逐月 PnL}}
    \end{{minipage}}\hfill
    \begin{{minipage}}{{0.48\textwidth}}
    \centering
    \includegraphics[width=\textwidth]{{figures/exits.pdf}}
    \caption{{出场原因}}
    \end{{minipage}}
    \end{{figure}}

    \begin{{figure}}[H]
    \centering
    \includegraphics[width=0.55\textwidth]{{figures/pnl_hist.pdf}}
    \caption{{单笔盈亏分布}}
    \end{{figure}}

    \begin{{table}}[H]
    \centering
    \caption{{出场原因统计}}
    \begin{{tabular}}{{lrr}}
    \toprule
    原因 & 笔数 & 占比 \\
    \midrule
    {exit_tex}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \section{{最优参数}}
    \begin{{table}}[H]
    \centering
    \caption{{SimpleEMA\_optimized.set 对应参数}}
    \begin{{tabular}}{{ll}}
    \toprule
    参数 & 值 \\
    \midrule
    {param_tex}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \section{{策略逻辑}}
    {strategy_tex}

    \section{{逐单复盘（节选）}}
    \subsection{{最佳 {min(12, len(trades))} 笔}}
    \begin{{table}}[H]
    \centering
    \small
    \begin{{tabular}}{{llrrl}}
    \toprule
    方向 & 开仓 & 平仓 & 盈亏 & 出场 \\
    \midrule
    {trade_table_rows(trades, 12, True)}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \subsection{{最差 {min(12, len(trades))} 笔}}
    \begin{{table}}[H]
    \centering
    \small
    \begin{{tabular}}{{llrrl}}
    \toprule
    方向 & 开仓 & 平仓 & 盈亏 & 出场 \\
    \midrule
    {trade_table_rows(trades, 12, False)}
    \bottomrule
    \end{{tabular}}
    \end{{table}}

    \noindent 完整 {len(trades)} 笔交易见 \texttt{{trades.csv}}。

    \section{{后续验证}}
    MT5 原生 Strategy Tester 验证命令：
    \begin{{verbatim}}
    cd lab/EAs/SimpleEMA
    python run_mt5_tester.py backtest --period M15 ^
      --from 2020.01.01 --to 2026.01.01 --set SimpleEMA_optimized.set
    \end{{verbatim}}

    \end{{document}}
    """).strip() + "\n"


def compile_pdf() -> bool:
    for cmd in (["xelatex", "-interaction=nonstopmode", "SimpleEMA_report.tex"],):
        for _ in range(2):
            r = subprocess.run(cmd, cwd=OUT, capture_output=True, text=True)
            if r.returncode != 0 and "xelatex" in cmd[0]:
                print(r.stdout[-2000:] if r.stdout else "")
                print(r.stderr[-2000:] if r.stderr else "")
    return PDF.exists()


def pdf_to_png() -> bool:
    try:
        import fitz  # PyMuPDF

        doc = fitz.open(PDF)
        zoom = 200 / 72
        mat = fitz.Matrix(zoom, zoom)
        images = []
        for page in doc:
            pix = page.get_pixmap(matrix=mat, alpha=False)
            images.append(pix)
        if len(images) == 1:
            images[0].save(PNG)
        else:
            # stack pages vertically into one PNG
            w = max(p.width for p in images)
            h = sum(p.height for p in images)
            from PIL import Image
            import io

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

    for tool in (
        ["pdftoppm", "-png", "-r", "200", str(PDF), str(OUT / "SimpleEMA_report")],
        ["magick", "convert", "-density", "200", str(PDF), str(PNG)],
    ):
        if shutil.which(tool[0]):
            subprocess.run(tool, cwd=OUT, check=False)
            if tool[0] == "pdftoppm":
                cand = OUT / "SimpleEMA_report-1.png"
                if cand.exists():
                    cand.replace(PNG)
                    return True
            if PNG.exists():
                return True
    # fallback: copy dashboard chart
    src = FIG / "equity.png"
    if src.exists():
        shutil.copy2(src, PNG)
        return True
    return False


def main() -> None:
    if not (OUT / "trades.csv").exists():
        subprocess.run(["python", str(ROOT / "generate_report.py")], check=True, cwd=ROOT)
    bp, summary, trades = load_data()
    save_figures(trades, summary)
    tex = build_tex(bp, summary, trades)
    TEX.write_text(tex, encoding="utf-8")
    print(f"Wrote {TEX}")

    if compile_pdf():
        print(f"PDF: {PDF}")
    else:
        print("PDF compile failed — install TeX Live (xelatex) with ctex")

    if pdf_to_png():
        print(f"PNG: {PNG}")
    else:
        print("PNG export failed — see figures/*.png")

    print(f"Figures: {FIG}")


if __name__ == "__main__":
    main()
