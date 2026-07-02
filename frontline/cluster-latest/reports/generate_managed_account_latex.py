#!/usr/bin/env python3
"""LaTeX brochure: zh / de / ar — equity curves, flowcharts, watermark."""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from io import BytesIO
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[2] / "backtesting" / "MT5"))

from brochure_i18n import LOCALES, Locale, flowchart_for
from cluster_audit.united_mt5_manifest import PRODUCTION_IDS, UNITED_MT5_STRATEGIES
from cluster_audit.united_mt5_runner import mt5_terminal_data_dir, parse_report, read_text


def _mt5_data() -> Path:
    data = mt5_terminal_data_dir()
    if data is None:
        raise SystemExit(
            "MT5 data folder not found. Set MT5_TERMINAL_DATA_ID in .env or log into MT5 once."
        )
    return data
FIG_DIR = ROOT / "figures" / "brochure"
DEPOSIT = 3000.0
WATERMARK_TEXT = "Namelos.xyz Research"

SM = {s["id"]: s for s in UNITED_MT5_STRATEGIES}
SYMBOL_MAP = {
    "DB": "XAUUSD", "ES": "XAUUSD", "RC": "XAUUSD", "RM": "XAUUSD",
    "RS_NVDA": "NVDA", "RS_TSLA": "TSLA", "RS_BTCUSD": "BTCUSD",
    "RS_XAUUSD": "XAUUSD", "RS_NAS100": "NAS100", "RS_US30": "US30",
    "SE": "XAUUSD", "ST_BTC": "BTCUSD", "ST_XAU": "XAUUSD",
    "RRA_AUD": "AUDUSD", "RRA_GBP": "GBPUSD", "UB": "USDJPY",
    "UKB": "UK100", "GB": "GER40", "U5B": "US500",
}

plt.rcParams.update({"figure.dpi": 150, "savefig.dpi": 150, "font.size": 9, "axes.unicode_minus": False})
try:
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "Arial", "DejaVu Sans"]
except Exception:
    pass


def parse_num(s: str) -> float:
    s = s.strip().replace(" ", "").replace(",", "")
    if not s:
        return 0.0
    if s.endswith("K"):
        return float(s[:-1]) * 1000
    if s.endswith("%"):
        return float(s[:-1])
    return float(s)


def parse_equity_from_html(html: str) -> pd.Series:
    markers = ("<b>成交</b>", "<b>Deals</b>", "<b>Orders</b>")
    start = next((html.find(m) for m in markers if html.find(m) >= 0), -1)
    sub = html[start:] if start >= 0 else html
    row_re = re.compile(
        r"align=right><td>([^<]*)</td><td>(\d+)</td><td>([^<]*)</td><td>([^<]*)</td>"
        r"<td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td><td>(\d+)</td><td>([^<]*)</td>"
        r"<td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td></tr>",
        re.I,
    )
    points: list[tuple[datetime, float]] = []
    for row in row_re.findall(sub):
        time_s, _did, _sym, typ, _dir, _vol, _price, _order, _comm, _swap, _profit, balance, _comment = row
        if typ.strip().lower() == "balance":
            continue
        try:
            t = datetime.strptime(time_s.strip(), "%Y.%m.%d %H:%M:%S")
        except ValueError:
            continue
        try:
            bal = parse_num(balance)
        except ValueError:
            continue
        if bal > 0:
            points.append((t, bal))
    if not points:
        return pd.Series(dtype=float)
    df = pd.DataFrame(points, columns=["time", "balance"]).sort_values("time")
    return df.groupby("time")["balance"].last()


@dataclass
class StratResult:
    sid: str
    name: str
    symbol: str
    pf: float | None
    net: float | None
    sharpe: float | None
    trades: int | None
    fig_path: str


def plot_equity(eq: pd.Series, title: str, out: Path, ylabel: str, *, logy: bool = False) -> None:
    if eq.empty:
        return
    daily = eq.resample("D").last().ffill()
    if daily.iloc[0] <= 0:
        daily = daily + DEPOSIT
    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    color = "#1565c0" if daily.iloc[-1] >= daily.iloc[0] else "#c62828"
    (ax.semilogy if logy else ax.plot)(daily.index, daily.values, color=color, linewidth=1.3)
    ax.axhline(DEPOSIT, color="#888", linestyle="--", linewidth=0.8, alpha=0.7)
    ax.set_title(title, fontsize=10)
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)


def load_report_html(name: str) -> str | None:
    for ext in (".htm", ".html"):
        p = _mt5_data() / f"{name}{ext}"
        if p.exists():
            return read_text(p)
    return None


def process_strategies(loc: Locale) -> list[StratResult]:
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    results: list[StratResult] = []
    for sid in PRODUCTION_IDS:
        spec = SM[sid]
        html = load_report_html(f"solo_{sid}_off")
        m = parse_report(_mt5_data(), f"solo_{sid}_off")
        eq = parse_equity_from_html(html) if html else pd.Series(dtype=float)
        fig_name = f"equity_{sid}.pdf"
        fig_path = FIG_DIR / fig_name
        title = f"{sid} · {spec['name']} ({SYMBOL_MAP.get(sid, '')})"
        if not eq.empty:
            plot_equity(eq, title, fig_path, loc.equity_ylabel)
        results.append(StratResult(
            sid=sid, name=spec["name"], symbol=SYMBOL_MAP.get(sid, ""),
            pf=m.get("profit_factor"), net=m.get("net_profit"),
            sharpe=m.get("sharpe"), trades=m.get("total_trades"),
            fig_path=f"figures/brochure/{fig_name}",
        ))
    combo_html = load_report_html("prod_v2_combined")
    if combo_html:
        combo_eq = parse_equity_from_html(combo_html)
        if not combo_eq.empty:
            plot_equity(combo_eq, loc.equity_combined_title, FIG_DIR / "equity_combined.pdf",
                        loc.equity_ylabel, logy=True)
    return results


def tex_escape(s: str) -> str:
    return s.replace("_", r"\_").replace("&", r"\&").replace("%", r"\%").replace("#", r"\#")


def _flowchart_minipage(r: StratResult, loc: Locale) -> list[str]:
    return [
        r"\begin{minipage}[t]{0.46\textwidth}",
        r"\centering",
        rf"\textbf{{{tex_escape(r.sid)} · {tex_escape(r.name)}}}\\[0.15em]",
        rf"\scriptsize ({tex_escape(r.symbol)})\\[0.35em]",
        r"\resizebox{\linewidth}{!}{%",
        flowchart_for(r.sid, loc),
        r"}",
        r"\end{minipage}",
    ]


def date_str(loc: Locale) -> str:
    d = datetime.now()
    if loc.code == "zh":
        return d.strftime("%Y年%m月%d日")
    if loc.code == "ar":
        return d.strftime("%Y-%m-%d")
    return d.strftime("%d.%m.%Y")


def build_latex(results: list[StratResult], loc: Locale) -> str:
    n_prof = sum(1 for r in results if (r.net or 0) > 0)
    n_pf1 = sum(1 for r in results if (r.pf or 0) >= 1.0)
    combo_m = parse_report(_mt5_data(), "prod_v2_combined")
    pf_l, net_l, sh_l = loc.caption_pf_net_sharpe

    lines = list(loc.preamble)
    lines += [
        rf"\title{{{loc.title}}}",
        rf"\author{{{loc.author}}}",
        rf"\date{{{date_str(loc)}}}",
        r"\begin{document}",
        r"\maketitle",
        r"\begin{abstract}",
        loc.abstract_tpl.format(n_prof=n_prof, n_pf1=n_pf1, deposit=DEPOSIT),
        r"\end{abstract}",
        r"\tableofcontents",
        r"\newpage",
        rf"\section{{{loc.s1_title}}}",
        loc.s1_body,
        rf"\subsection{{{loc.s1_1_title}}}",
        r"\begin{itemize}",
    ]
    lines += [rf"\item {x}" for x in loc.s1_1_items]
    lines += [
        r"\end{itemize}",
        rf"\subsection{{{loc.s1_2_title}}}",
        r"\begin{tabular}{ll}",
        r"\toprule",
        rf"{loc.table_headers[0]} & {loc.table_headers[1]} \\",
        r"\midrule",
    ]
    for k, v in loc.table_rows:
        lines.append(rf"{k} & {v} \\")
    lines += [
        r"\bottomrule",
        r"\end{tabular}",
        r"\newpage",
        rf"\section{{{loc.s2_title}}}",
        loc.s2_body_tpl.format(
            pf=combo_m.get("profit_factor", "—"),
            sharpe=combo_m.get("sharpe", "—"),
            trades=combo_m.get("total_trades", "—"),
        ),
        r"\begin{figure}[H]",
        r"\centering",
        r"\includegraphics[width=0.95\textwidth]{figures/brochure/equity_combined.pdf}",
        rf"\caption{{{loc.s2_caption}}}",
        r"\end{figure}",
        r"\newpage",
        rf"\section{{{loc.s3_title}}}",
        loc.s3_body,
        r"\begin{figure}[H]",
        r"\centering",
    ]
    for i, r in enumerate(results):
        if i > 0 and i % 2 == 0:
            lines += [r"\end{figure}", r"\begin{figure}[H]", r"\centering"]
        lines += [
            r"\begin{subfigure}[t]{0.48\textwidth}",
            r"\centering",
            rf"\includegraphics[width=\textwidth]{{{r.fig_path}}}",
        ]
        pf_s = f"{r.pf:.2f}" if r.pf else "—"
        net_s = f"{r.net:,.0f}" if r.net else "—"
        sh_s = f"{r.sharpe:.2f}" if r.sharpe else "—"
        lines.append(
            rf"\caption{{{tex_escape(r.sid)} · {tex_escape(r.name)}\\"
            rf"{pf_l}={pf_s} \quad {net_l}=\${net_s} \quad {sh_l}={sh_s}}}"
        )
        lines += [r"\end{subfigure}"]
        if i % 2 == 0:
            lines.append(r"\hfill")
    lines += [
        r"\end{figure}",
        r"\newpage",
        rf"\section{{{loc.s4_title}}}",
        r"\begin{table}[H]",
        r"\centering",
        rf"\caption{{{loc.s4_caption}}}",
        r"\small",
        r"\begin{tabular}{clrrrrr}",
        r"\toprule",
        rf"{loc.table_cols} \\",
        r"\midrule",
    ]
    for r in sorted(results, key=lambda x: -(x.net or 0)):
        pf_s = f"{r.pf:.2f}" if r.pf else "—"
        net_s = f"{r.net:,.0f}" if r.net else "—"
        sh_s = f"{r.sharpe:.2f}" if r.sharpe else "—"
        tr_s = str(r.trades) if r.trades else "—"
        lines.append(
            rf"{tex_escape(r.sid)} & {tex_escape(r.name)} & {tex_escape(r.symbol)} "
            rf"& {pf_s} & {net_s} & {sh_s} & {tr_s} \\"
        )
    lines += [
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
        r"\newpage",
        rf"\section{{{loc.s5_title}}}",
        loc.s5_body,
    ]
    close_sids = {"ES", "RS_XAUUSD", "RS_US30"}
    i = 0
    while i < len(results):
        lines += [r"\begin{figure}[H]", r"\centering"]
        lines += _flowchart_minipage(results[i], loc)
        page_sids = [results[i].sid]
        if i + 1 < len(results):
            lines.append(r"\hfill")
            lines += _flowchart_minipage(results[i + 1], loc)
            page_sids.append(results[i + 1].sid)
            i += 2
        else:
            i += 1
        lines.append(r"\end{figure}")
        for sid in page_sids:
            if sid in close_sids:
                lines.append(loc.close_note)
        lines.append(r"\vspace{0.25cm}")
    lines += [
        rf"\section{{{loc.s6_title}}}",
        r"\begin{itemize}",
    ]
    lines += [rf"\item {x}" for x in loc.s6_items]
    lines += [
        r"\end{itemize}",
        rf"\section*{{{ 'إخلاء المسؤولية' if loc.code == 'ar' else ('Haftungsausschluss' if loc.code == 'de' else '免责声明')} }}",
        loc.disclaimer,
        r"\end{document}",
    ]
    return "\n".join(lines) + "\n"


def _watermark_page_template(width: float, height: float):
    from pypdf import PdfReader as PR
    from reportlab.lib.colors import Color
    from reportlab.pdfgen import canvas

    buf = BytesIO()
    c = canvas.Canvas(buf, pagesize=(width, height))
    c.setFillColor(Color(0.45, 0.45, 0.45, alpha=0.12))
    c.setFont("Helvetica-Bold", 13)
    step_x, step_y = 135, 90
    x = 35.0
    while x < width + step_x:
        y = 45.0
        while y < height + step_y:
            c.saveState()
            c.translate(x, y)
            c.rotate(35)
            c.drawCentredString(0, 0, WATERMARK_TEXT)
            c.restoreState()
            y += step_y
        x += step_x
    c.showPage()
    c.save()
    buf.seek(0)
    return PR(buf).pages[0]


def stamp_watermark_pdf(path: Path) -> None:
    from pypdf import PdfReader, PdfWriter

    reader = PdfReader(str(path))
    writer = PdfWriter()
    for page in reader.pages:
        w, h = float(page.mediabox.width), float(page.mediabox.height)
        wm = _watermark_page_template(w, h)
        wm.merge_page(page)
        writer.add_page(wm)
    tmp = path.with_suffix(".tmp.pdf")
    with open(tmp, "wb") as f:
        writer.write(f)
    tmp.replace(path)


def build_one(loc: Locale, results: list[StratResult]) -> bool:
    tex_file = ROOT / f"{loc.tex_stem}.tex"
    pdf_file = ROOT / f"{loc.tex_stem}.pdf"
    out_pdf = ROOT / loc.pdf_name

    tex_file.write_text(build_latex(results, loc), encoding="utf-8")
    print(f"  Wrote {tex_file.name}")

    for _ in range(2):
        subprocess.run(
            ["xelatex", "-interaction=nonstopmode", tex_file.name],
            cwd=ROOT, capture_output=True, text=True,
        )
    if not pdf_file.exists():
        print(f"  FAILED xelatex for {loc.code}")
        return False
    stamp_watermark_pdf(pdf_file)
    shutil.copy2(pdf_file, out_pdf)
    print(f"  PDF: {out_pdf.name}")
    return True


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--lang", default="all", choices=["zh", "de", "ar", "all"])
    args = p.parse_args()

    langs = list(LOCALES.keys()) if args.lang == "all" else [args.lang]
    print("MT5 data: <local MetaQuotes Terminal folder>")
    results = process_strategies(LOCALES["zh"])
    for r in results:
        print(f"  OK {r.sid:10} PF={r.pf} net={r.net}")

    ok = True
    for code in langs:
        loc = LOCALES[code]
        print(f"\n=== {code.upper()} ===")
        if not build_one(loc, results):
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
