#!/usr/bin/env python3
"""Generate cluster backtest evaluation: charts + LaTeX PDF."""
from __future__ import annotations

import json
import re
import subprocess
import textwrap
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from html import unescape
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import MetaTrader5 as mt5
import numpy as np
import pandas as pd
from matplotlib.patches import Rectangle

ROOT = Path(__file__).resolve().parent


def _find_tester_report() -> Path:
    """Locate MT5 Strategy Tester HTML (ReportTester-*.html) in cluster-latest."""
    candidates = sorted(ROOT.parent.glob("ReportTester*.html"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        raise FileNotFoundError(
            "No ReportTester*.html found. Export from MT5 Strategy Tester into frontline/cluster-latest/"
        )
    return candidates[0]


REPORT_HTML = _find_tester_report()
FIG_DIR = ROOT / "figures"
DATA_DIR = ROOT / "data"
TEX_FILE = ROOT / "cluster_evaluation.tex"

plt.rcParams.update({
    "figure.dpi": 150,
    "savefig.dpi": 150,
    "font.size": 9,
    "axes.titlesize": 10,
    "axes.labelsize": 9,
})

STRATEGY_META = {
    "RM_EMA_Cross": {"name": "RM MidPoint EMA Cross", "group": "gold_core", "type": "trend"},
    "RM_RSI_Follow": {"name": "RM MidPoint RSI Follow", "group": "gold_core", "type": "trend"},
    "RM_RSI_Reverse": {"name": "RM MidPoint RSI Reverse", "group": "gold_core", "type": "mean_rev"},
    "RS_XAUUSD": {"name": "RSI Scalping XAUUSD", "group": "gold_core", "type": "scalp"},
    "RCO_RSIConsolidation": {"name": "RSI Consolidation", "group": "gold_core", "type": "range"},
    "RS_BTCUSD": {"name": "RSI Scalping BTCUSD", "group": "crypto", "type": "scalp"},
    "RS_TSLA": {"name": "RSI Scalping TSLA", "group": "equity", "type": "scalp"},
    "RS_NVDA": {"name": "RSI Scalping NVDA", "group": "equity", "type": "scalp"},
    "RS_APPL": {"name": "RSI Scalping AAPL", "group": "equity", "type": "scalp"},
    "RC_RSICrossOver": {"name": "RSI CrossOver Reversal", "group": "gold_core", "type": "reversal"},
    "SE_SuperEMA": {"name": "SuperEMA", "group": "gold_core", "type": "trend"},
    "DB_DarvasBox": {"name": "Darvas Box", "group": "gold_core", "type": "breakout"},
    "ES_EMASlope": {"name": "EMA Slope Distance", "group": "gold_core", "type": "trend"},
    "ST_SimpleTrendline": {"name": "SimpleTrendline", "group": "multi", "type": "hedge"},
    "RRA_EURUSD": {"name": "RSI Asian EURUSD", "group": "fx", "type": "session"},
    "RRA_AUDUSD": {"name": "RSI Asian AUDUSD", "group": "fx", "type": "session"},
    "UB_USDJPY": {"name": "USDJPY Buster", "group": "fx", "type": "breakout"},
}


def classify_comment(c: str, symbol: str = "") -> str | None:
    c = c.strip()
    if not c:
        return None
    cl = c.lower()
    if "darvas" in cl:
        return "DB_DarvasBox"
    if "ema cross distance" in cl:
        return "ES_EMASlope"
    if "ema crossover trade" in cl:
        return "RM_EMA_Cross"
    if c in ("Buy Order", "Sell Order"):
        return "RC_RSICrossOver"
    if "united superema" in cl:
        return "SE_SuperEMA"
    if "rsiconsolidation" in cl.replace(" ", ""):
        return "RCO_RSIConsolidation"
    if "simpletrendline" in cl.replace(" ", ""):
        return "ST_SimpleTrendline"
    if "rsi overbought crossover" in cl or "rsi oversold crossover" in cl:
        return "RRA_EURUSD" if "EUR" in symbol else "RRA_AUDUSD" if "AUD" in symbol else "RRA_Asian"
    if c.startswith("UB range"):
        return "UB_USDJPY"
    if "rsi follow" in cl:
        return "RM_RSI_Follow"
    if "rsi reverse" in cl:
        return "RM_RSI_Reverse"
    if "rsi scalping" in cl:
        sym_map = {
            "AAPL.NAS": "RS_APPL", "ADBE.NAS": "RS_ADBE", "BTCUSD": "RS_BTCUSD",
            "NVDA.NAS": "RS_NVDA", "TSLA.NAS": "RS_TSLA", "XAUUSD": "RS_XAUUSD", "MU.NAS": "RS_MU",
        }
        return sym_map.get(symbol, f"RS_{symbol}")
    if c.startswith("sl ") or c.startswith("tp ") or c == "end of test":
        return None
    return None


def st_side(comment: str) -> str | None:
    cl = comment.lower().replace(" ", "")
    if "simpletrendlinebuy" in cl:
        return "long"
    if "simpletrendlinesell" in cl:
        return "short"
    return None


def parse_num(s: str) -> float:
    s = s.strip().replace(" ", "").replace(",", "")
    if not s:
        return 0.0
    if s.endswith("K"):
        return float(s[:-1]) * 1000
    return float(s)


def parse_deals(html: str) -> list[dict]:
    marker = '<div style="font: 10pt Tahoma"><b>成交</b></div>'
    start = html.find(marker)
    sub = html[start:] if start >= 0 else html
    row_re = re.compile(
        r"align=right><td>([^<]*)</td><td>(\d+)</td><td>([^<]*)</td><td>([^<]*)</td>"
        r"<td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td><td>(\d+)</td><td>([^<]*)</td>"
        r"<td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td><td>([^<]*)</td></tr>",
        re.I,
    )
    open_map: dict[str, str] = {}
    open_side: dict[str, str] = {}
    open_stack: dict[str, list[tuple[str, str, str | None]]] = defaultdict(list)
    deals = []

    for row in row_re.findall(sub):
        time_s, _did, symbol, typ, direction, _vol, _price, order, comm, swap, profit, balance, comment = row
        if typ.strip().lower() == "balance":
            continue
        net = parse_num(profit) + parse_num(comm) + parse_num(swap)
        comment = unescape(comment.strip())
        symbol = symbol.strip()
        direction = direction.strip().lower()
        strategy = classify_comment(comment, symbol)
        side = st_side(comment) if strategy == "ST_SimpleTrendline" else None

        if direction == "in":
            if strategy:
                open_map[order] = strategy
                if side:
                    open_side[order] = side
                open_stack[symbol].append((order, strategy, side))
            continue
        if direction != "out":
            continue

        if strategy is None:
            if open_stack[symbol]:
                _o, strategy, side = open_stack[symbol].pop(0)
            elif order in open_map:
                strategy = open_map[order]
                side = open_side.get(order)
            else:
                strategy = "UNATTRIBUTED"
        elif open_stack[symbol]:
            # explicit close comment: still consume FIFO slot for side/symbol match
            for i, (o, s, sd) in enumerate(open_stack[symbol]):
                if s == strategy:
                    _o, _, side = open_stack[symbol].pop(i)
                    break

        open_map.pop(order, None)
        open_side.pop(order, None)
        open_stack[symbol] = [(o, s, sd) for o, s, sd in open_stack[symbol] if o != order]

        try:
            ts = pd.to_datetime(time_s, format="%Y.%m.%d %H:%M:%S")
        except Exception:
            ts = pd.to_datetime(time_s.replace(".", "-", 2))

        deals.append({
            "time": ts,
            "symbol": symbol,
            "strategy": strategy,
            "side": side,
            "net": net,
            "balance": parse_num(balance),
            "comment": comment,
        })
    return deals


def load_xau_h1(start: datetime, end: datetime) -> pd.DataFrame:
    if not mt5.initialize():
        raise RuntimeError("MT5 init failed")
    sym = "XAUUSD"
    if not mt5.symbol_select(sym, True):
        for alt in ("GOLD", "XAUUSDm", "XAUUSD."):
            if mt5.symbol_select(alt, True):
                sym = alt
                break
    rates = mt5.copy_rates_range(sym, mt5.TIMEFRAME_H1, start, end)
    mt5.shutdown()
    if rates is None or len(rates) < 100:
        raise RuntimeError("No XAUUSD H1 data from MT5")
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df.set_index("time", inplace=True)
    return df


def market_features(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out["ret"] = out["close"].pct_change()
    out["ema20"] = out["close"].ewm(span=20).mean()
    out["ema50"] = out["close"].ewm(span=50).mean()
    hl = out["high"] - out["low"]
    hc = (out["high"] - out["close"].shift()).abs()
    lc = (out["low"] - out["close"].shift()).abs()
    tr = pd.concat([hl, hc, lc], axis=1).max(axis=1)
    out["atr14"] = tr.rolling(14).mean()
    out["atr_pct"] = out["atr14"] / out["close"] * 100
    up = out["high"].diff()
    down = -out["low"].diff()
    plus_dm = np.where((up > down) & (up > 0), up, 0.0)
    minus_dm = np.where((down > up) & (down > 0), down, 0.0)
    atr = out["atr14"]
    plus_di = 100 * pd.Series(plus_dm, index=out.index).rolling(14).mean() / atr
    minus_di = 100 * pd.Series(minus_dm, index=out.index).rolling(14).mean() / atr
    dx = (plus_di - minus_di).abs() / (plus_di + minus_di) * 100
    out["adx14"] = dx.rolling(14).mean()
    out["trend_slope"] = (out["ema20"] - out["ema50"]) / out["close"] * 100
    out["chop"] = out["ret"].rolling(24).std() * np.sqrt(24) * 100
    return out


def find_drawdowns(equity: pd.Series, top_n: int = 5) -> list[dict]:
    peak = equity.cummax()
    dd = equity - peak
    dd_pct = dd / peak.replace(0, np.nan) * 100
    episodes = []
    in_dd = False
    start = None
    trough_t = None
    trough_v = 0.0
    peak_v = 0.0
    for t, v in dd.items():
        if v < -1 and not in_dd:
            in_dd = True
            start = t
            trough_t = t
            trough_v = v
            peak_v = peak.loc[t]
        elif in_dd:
            if v < trough_v:
                trough_v = v
                trough_t = t
            if v >= -0.5:
                episodes.append({
                    "start": start, "trough": trough_t, "end": t,
                    "depth_usd": abs(trough_v), "depth_pct": abs(trough_v / peak_v * 100) if peak_v else 0,
                })
                in_dd = False
    if in_dd:
        episodes.append({
            "start": start, "trough": trough_t, "end": equity.index[-1],
            "depth_usd": abs(trough_v), "depth_pct": abs(trough_v / peak_v * 100) if peak_v else 0,
        })
    episodes.sort(key=lambda x: x["depth_usd"], reverse=True)
    return episodes[:top_n]


def plot_candles(ax, df: pd.DataFrame, title: str):
    sub = df.tail(min(120, len(df)))
    xs = np.arange(len(sub))
    for i, (t, row) in enumerate(sub.iterrows()):
        o, h, l, c = row["open"], row["high"], row["low"], row["close"]
        color = "#26a69a" if c >= o else "#ef5350"
        ax.plot([i, i], [l, h], color=color, linewidth=0.8)
        ax.add_patch(Rectangle((i - 0.35, min(o, c)), 0.7, abs(c - o) or 0.5, facecolor=color, edgecolor=color))
    ax.plot(xs, sub["ema20"].values, color="#1565c0", linewidth=1, label="EMA20")
    ax.plot(xs, sub["ema50"].values, color="#ff8f00", linewidth=1, label="EMA50")
    ax.set_title(title)
    ax.set_xlim(-1, len(sub))
    ax.legend(loc="upper left", fontsize=7)
    step = max(1, len(sub) // 6)
    ax.set_xticks(xs[::step])
    ax.set_xticklabels([sub.index[j].strftime("%m-%d") for j in range(0, len(sub), step)], rotation=30, ha="right")


def monthly_issue_text(strat: str, monthly: pd.Series, meta: dict) -> list[str]:
    issues = []
    neg = monthly[monthly < 0]
    if len(neg) > 0:
        worst_m = neg.idxmin()
        issues.append(f"{worst_m} 单月亏损 {neg.min():,.0f} USD")
    pos = monthly[monthly > 0]
    if len(pos) > 0 and len(neg) > len(pos):
        issues.append(f"亏损月份 ({len(neg)}) 多于盈利月份 ({len(pos)})")
    if strat == "ST_SimpleTrendline":
        issues.append("对冲型策略：多空均有信号，需分方向评估而非整体关停")
    if meta.get("type") == "scalp" and monthly.std() > abs(monthly.mean()) * 2:
        issues.append("月度波动大，手数复利放大后尾部风险显著")
    if monthly.tail(3).sum() < 0 and monthly.sum() > 0:
        issues.append("近 3 个月转弱，存在 regime change 迹象")
    return issues[:4]


def latex_escape(s: str) -> str:
    return s.replace("\\", "\\textbackslash{}").replace("_", "\\_").replace("&", "\\&").replace("%", "\\%")


def build_latex(summary: dict) -> str:
    s = summary
    robots_tex = []
    for strat in s["strategy_order"]:
        meta = STRATEGY_META.get(strat, {"name": strat, "type": "other"})
        m = s["monthly"].get(strat, {})
        issues = s["issues"].get(strat, [])
        total = s["totals"].get(strat, 0)
        robots_tex.append(
            f"\\subsubsection{{{latex_escape(meta['name'])}}}\n"
            f"累计净利润 \\textbf{{{total:,.0f}}} USD。"
            + ("\\par\\noindent\\textbf{逐月问题：}\\begin{itemize}\\setlength\\itemsep{2pt}\n"
               + "".join(f"\\item {latex_escape(x)}" for x in issues)
               + "\\end{itemize}" if issues else "")
        )

    dd_rows = []
    for i, ep in enumerate(s["drawdowns"][:5], 1):
        dd_rows.append(
            f"{i} & {ep['start'].strftime('%Y-%m-%d')} & {ep['trough'].strftime('%Y-%m-%d')} & "
            f"{ep['end'].strftime('%Y-%m-%d')} & {ep['depth_usd']:,.0f} & {ep['depth_pct']:.1f}\\% \\\\"
        )

    st_total = s["totals"].get("ST_SimpleTrendline", 0)
    body = f"""
    \\section{{执行摘要}}
    本报告基于 MT5 策略测试器 HTML 报告（初始资金 \\$3,000，杠杆 1:1000，余额复利缩放）对 UnitedEA 集群进行逐机器人、逐月、回撤期市场结构分析。

    \\begin{{table}}[H]
    \\centering
    \\caption{{组合层面关键指标}}
    \\begin{{tabular}}{{lr}}
    \\toprule
    指标 & 数值 \\\\
    \\midrule
    总净盈利 & {s['portfolio']['net_profit']:,.0f} USD \\\\
    盈利因子 & {s['portfolio']['pf']:.2f} \\\\
    夏普比率 & {s['portfolio']['sharpe']:.2f} \\\\
    最大净值回撤 & {s['portfolio']['max_dd_pct']:.2f}\\% \\\\
    总交易笔数 & {s['portfolio']['trades']:,} \\\\
    胜率 & {s['portfolio']['win_rate']:.2f}\\% \\\\
    \\bottomrule
    \\end{{tabular}}
    \\end{{table}}

    \\textbf{{核心结论：}}
    \\begin{{itemize}}
    \\item 利润高度集中于 XAUUSD 上的 RM EMA Cross、RSI Scalping XAU、RSI Consolidation；名义多品种分散，实际为黄金 beta 集群。
    \\item 2025 末至 2026 初复利手数放大后，收益与回撤同步膨胀；评估 edge 需配合固定手数对照。
    \\item SimpleTrendline 为\\textbf{{对冲型}}（多空双向），整体虽亏但分方向与品种后可能仍有价值，不宜简单一刀切关闭。
    \\item 最大回撤期 XAUUSD 呈现更高 ATR、更低 ADX（震荡/假突破增多），趋势型与突破型策略易共振亏损。
    \\end{{itemize}}

    \\section{{组合曲线与回撤}}
    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.95\\textwidth]{{figures/equity_drawdown.pdf}}
    \\caption{{净值曲线与回撤百分比}}
    \\end{{figure}}

    \\begin{{table}}[H]
    \\centering
    \\caption{{主要回撤 episode（Top 5）}}
    \\begin{{tabular}}{{clllrr}}
    \\toprule
    \\# & 起始 & 谷底 & 恢复 & 深度(USD) & 深度(\\%) \\\\
    \\midrule
    {chr(10).join(dd_rows)}
    \\bottomrule
    \\end{{tabular}}
    \\end{{table}}

    \\section{{逐机器人月度热力与累计贡献}}
    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.98\\textwidth]{{figures/monthly_heatmap.pdf}}
    \\caption{{各机器人逐月净利润热力图（USD）}}
    \\end{{figure}}

    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.85\\textwidth]{{figures/strategy_contribution.pdf}}
    \\caption{{各机器人累计净利润贡献}}
    \\end{{figure}}

    \\section{{SimpleTrendline：对冲型专项分析}}
    SimpleTrendline 基于高周期 MA 交叉趋势线，\\textbf{{多空双向}}触发，设计目标是对冲而非单边趋势押注。
    回测合计 {st_total:,.0f} USD，但 2026 年在黄金高位剧烈震荡中大幅回撤。

    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.95\\textwidth]{{figures/st_long_short_monthly.pdf}}
    \\caption{{SimpleTrendline 多空方向逐月 P/L 分解}}
    \\end{{figure}}

    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.95\\textwidth]{{figures/st_by_symbol_monthly.pdf}}
    \\caption{{SimpleTrendline 分品种（XAU/GER/BTC）逐月 P/L}}
    \\end{{figure}}

    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.98\\textwidth]{{figures/top6_monthly.pdf}}
    \\caption{{核心六机器人逐月 P/L 明细}}
    \\end{{figure}}

    \\textbf{{建议：}}保留策略框架，但 (1) 在 ADX>{s['regime']['dd_adx']:.0f} 且 ATR 分位>{s['regime']['dd_atr_pct']:.0f}\\% 的强趋势月减少逆势侧仓位；
    (2) 与 RM/RCO 等同向 exposure 设上限；(3) 2026 类高位宽幅震荡月单独降 LOT。

    \\section{{回撤期 vs 平稳期：XAUUSD H1 市场结构}}
    从 MT5 拉取 XAUUSD H1。回撤窗口取 Top3 drawdown episode（{', '.join(s['regime'].get('dd_months', []))}），对照期为 2024-03 至 2024-09 平稳盈利段。

    \\begin{{table}}[H]
    \\centering
    \\caption{{市场特征对比（亏损月 vs 对照月）}}
    \\begin{{tabular}}{{lrr}}
    \\toprule
    特征 & 亏损月均值 & 对照月均值 \\\\
    \\midrule
    ADX(14) & {s['regime']['dd_adx']:.1f} & {s['regime']['calm_adx']:.1f} \\\\
    ATR\\% & {s['regime']['dd_atr_pct']:.2f} & {s['regime']['calm_atr_pct']:.2f} \\\\
    日收益波动(chop) & {s['regime']['dd_chop']:.2f} & {s['regime']['calm_chop']:.2f} \\\\
    EMA20-50 斜率\\% & {s['regime']['dd_slope']:.3f} & {s['regime']['calm_slope']:.3f} \\\\
    \\bottomrule
    \\end{{tabular}}
    \\end{{table}}

    \\begin{{figure}}[H]
    \\centering
    \\begin{{subfigure}}{{0.48\\textwidth}}
    \\includegraphics[width=\\textwidth]{{figures/xau_dd_candles.pdf}}
    \\caption{{回撤谷底附近 K 线 + EMA}}
    \\end{{subfigure}}
    \\hfill
    \\begin{{subfigure}}{{0.48\\textwidth}}
    \\includegraphics[width=\\textwidth]{{figures/xau_calm_candles.pdf}}
    \\caption{{盈利平稳期 K 线 + EMA}}
    \\end{{subfigure}}
    \\caption{{XAUUSD H1 形态对比}}
    \\end{{figure}}

    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.95\\textwidth]{{figures/xau_regime_monthly.pdf}}
    \\caption{{XAUUSD 逐月 ADX / ATR\\% 与组合月度 P/L 对照}}
    \\end{{figure}}

    \\section{{各机器人逐月问题诊断}}
    {chr(10).join(robots_tex)}

    \\section{{分品种月度 P/L}}
    \\begin{{figure}}[H]
    \\centering
    \\includegraphics[width=0.95\\textwidth]{{figures/symbol_monthly.pdf}}
    \\caption{{主要交易品种逐月净利润}}
    \\end{{figure}}

    \\section{{改进路线图}}
    \\begin{{enumerate}}
    \\item \\textbf{{P0 风控：}}设置 ORCH\\_MaxBalanceScale 上限、每机器人 max lot cap；XAUUSD 总 exposure 上限。
    \\item \\textbf{{P1 精简：}}关闭 RRA EURUSD、RS AAPL；SuperEMA 降权；RS NVDA 观察。
    \\item \\textbf{{P2 SimpleTrendline：}}分方向/分品种调参，震荡月（低 ADX + 高 ATR）减半 LOT，勿整体删除。
    \\item \\textbf{{P3 验证：}}固定手数复测 2023--2026；Walk-forward 2026 Q1 作为 OOS。
    \\item \\textbf{{P4 监控：}}月度 dashboard 跟踪 RM EMA Cross 与 ST 多空比、ADX 过滤命中率。
    \\end{{enumerate}}

    \\appendix
    \\section{{数据来源}}
    报告 HTML: ReportTester-*.html（MT5 导出）；K 线: MT5 XAUUSD H1；成交归因基于 order comment FIFO。
    """

    header = textwrap.dedent(r"""
    \documentclass[11pt,a4paper]{ctexart}
    \usepackage{graphicx}
    \usepackage{booktabs}
    \usepackage{geometry}
    \usepackage{float}
    \usepackage{caption}
    \usepackage{subcaption}
    \usepackage{hyperref}
    \usepackage{xcolor}
    \geometry{margin=2.2cm}
    \title{UnitedEA 集群回测综合评估报告\\ \large 2023.07 -- 2026.06 · 逐月诊断 · 回撤期 K 线对比}
    \author{自动生成 · cluster-latest/main.mq5}
    \date{\today}

    \begin{document}
    \maketitle
    \tableofcontents
    \newpage
    """)

    return header + body + "\n\\end{document}\n"


def main():
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    html = REPORT_HTML.read_text(encoding="utf-16")
    deals = parse_deals(html)
    df = pd.DataFrame(deals).sort_values("time")
    df["month"] = df["time"].dt.to_period("M").astype(str)

    # Portfolio summary from HTML header
    m_net = re.search(r"总净盈利:</td>\s*<td[^>]*><b>([^<]+)</b>", html)
    m_pf = re.search(r"盈利因子:</td>\s*<td[^>]*><b>([^<]+)</b>", html)
    m_sh = re.search(r"夏普比率:</td>\s*<td[^>]*><b>([^<]+)</b>", html)
    m_dd = re.search(r"相对净值亏损:</td>\s*<td[^>]*><b>([0-9.]+)%", html)
    m_tr = re.search(r"交易总计:</td>\s*<td[^>]*><b>([^<]+)</b>", html)
    m_wr = re.search(r"盈利交易 \(% 全部\):</td>\s*<td[^>]*><b>[0-9]+ \(([0-9.]+)%\)", html)

    portfolio = {
        "net_profit": parse_num(m_net.group(1)) if m_net else df["net"].sum(),
        "pf": float(m_pf.group(1)) if m_pf else 0,
        "sharpe": float(m_sh.group(1)) if m_sh else 0,
        "max_dd_pct": float(m_dd.group(1)) if m_dd else 0,
        "trades": int(m_tr.group(1).replace(" ", "")) if m_tr else len(df),
        "win_rate": float(m_wr.group(1)) if m_wr else 0,
    }

    # Equity curve
    eq = df.groupby("time")["balance"].last().sort_index()
    eq_daily = eq.resample("D").last().ffill()
    peak = eq_daily.cummax()
    dd_pct = (eq_daily - peak) / peak * 100

    fig, axes = plt.subplots(2, 1, figsize=(11, 5), sharex=True, gridspec_kw={"height_ratios": [3, 1]})
    axes[0].semilogy(eq_daily.index, eq_daily.values, color="#1565c0", linewidth=1.2)
    axes[0].set_ylabel("Balance (USD, log)")
    axes[0].set_title("Portfolio Equity")
    axes[0].grid(True, alpha=0.3)
    axes[1].fill_between(dd_pct.index, dd_pct.values, 0, color="#ef5350", alpha=0.5)
    axes[1].set_ylabel("Drawdown %")
    axes[1].set_xlabel("Date")
    axes[1].grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(FIG_DIR / "equity_drawdown.pdf")
    plt.close()

    drawdowns = find_drawdowns(eq_daily, 5)

    # Monthly by strategy
    monthly_strat = df.pivot_table(index="month", columns="strategy", values="net", aggfunc="sum", fill_value=0)
    totals = df.groupby("strategy")["net"].sum().sort_values(ascending=False)
    strategy_order = [s for s in totals.index if s != "UNATTRIBUTED"]

    # Heatmap - top strategies
    top_strats = strategy_order[:14]
    heat = monthly_strat[top_strats].T
    fig, ax = plt.subplots(figsize=(14, 7))
    vmax = np.percentile(np.abs(heat.values), 95)
    im = ax.imshow(heat.values, aspect="auto", cmap="RdYlGn", vmin=-vmax, vmax=vmax)
    ax.set_yticks(range(len(top_strats)))
    ax.set_yticklabels([STRATEGY_META.get(s, {}).get("name", s) for s in top_strats], fontsize=7)
    ax.set_xticks(range(len(heat.columns)))
    ax.set_xticklabels(heat.columns, rotation=45, ha="right", fontsize=7)
    ax.set_title("Monthly Net P/L by Robot (USD)")
    plt.colorbar(im, ax=ax, shrink=0.6)
    fig.tight_layout()
    fig.savefig(FIG_DIR / "monthly_heatmap.pdf")
    plt.close()

    # Contribution bar
    fig, ax = plt.subplots(figsize=(9, 5))
    colors = ["#2e7d32" if v >= 0 else "#c62828" for v in totals[strategy_order]]
    ax.barh([STRATEGY_META.get(s, {}).get("name", s)[:28] for s in strategy_order], totals[strategy_order].values, color=colors)
    ax.axvline(0, color="black", linewidth=0.8)
    ax.set_xlabel("Net Profit (USD)")
    ax.set_title("Cumulative Contribution by Robot")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "strategy_contribution.pdf")
    plt.close()

    # ST long/short monthly
    st_df = df[df["strategy"] == "ST_SimpleTrendline"].copy()
    st_monthly = {"long": {}, "short": {}}
    for side in ("long", "short"):
        sub = st_df[st_df["side"] == side]
        if len(sub):
            st_monthly[side] = sub.groupby("month")["net"].sum().to_dict()
    all_months = sorted(monthly_strat.index)
    long_s = [st_monthly["long"].get(m, 0) for m in all_months]
    short_s = [st_monthly["short"].get(m, 0) for m in all_months]
    x = np.arange(len(all_months))
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.bar(x - 0.2, long_s, 0.4, label="Long", color="#26a69a")
    ax.bar(x + 0.2, short_s, 0.4, label="Short", color="#ef5350")
    ax.axhline(0, color="black", linewidth=0.6)
    ax.set_xticks(x)
    ax.set_xticklabels(all_months, rotation=45, ha="right", fontsize=7)
    ax.set_ylabel("USD")
    ax.set_title("SimpleTrendline: Long vs Short Monthly P/L")
    ax.legend()
    fig.tight_layout()
    fig.savefig(FIG_DIR / "st_long_short_monthly.pdf")
    plt.close()

    # ST by symbol
    st_sym = st_df.groupby(["month", "symbol"])["net"].sum().unstack(fill_value=0)
    if len(st_sym.columns):
        fig, ax = plt.subplots(figsize=(12, 4))
        st_sym.plot(kind="bar", stacked=True, ax=ax, width=0.85)
        ax.axhline(0, color="black", linewidth=0.6)
        ax.set_title("SimpleTrendline Monthly P/L by Symbol")
        ax.set_ylabel("USD")
        plt.xticks(rotation=45, ha="right", fontsize=7)
        ax.legend(fontsize=7, loc="upper left")
        fig.tight_layout()
        fig.savefig(FIG_DIR / "st_by_symbol_monthly.pdf")
        plt.close()

    # Top robots monthly lines
    top6 = strategy_order[:6]
    fig, axes = plt.subplots(3, 2, figsize=(12, 7), sharex=True)
    for ax, strat in zip(axes.flat, top6):
        if strat not in monthly_strat.columns:
            continue
        ser = monthly_strat[strat]
        ax.bar(ser.index, ser.values, color=np.where(ser.values >= 0, "#66bb6a", "#ef5350"), width=0.8)
        ax.axhline(0, color="black", linewidth=0.5)
        ax.set_title(STRATEGY_META.get(strat, {}).get("name", strat), fontsize=8)
        ax.tick_params(axis="x", labelrotation=45, labelsize=6)
    fig.suptitle("Top 6 Robots — Monthly P/L", fontsize=11)
    fig.tight_layout()
    fig.savefig(FIG_DIR / "top6_monthly.pdf")
    plt.close()

    # Symbol monthly
    sym_m = df.pivot_table(index="month", columns="symbol", values="net", aggfunc="sum", fill_value=0)
    main_syms = sym_m.sum().abs().sort_values(ascending=False).head(6).index
    fig, ax = plt.subplots(figsize=(12, 5))
    bottom = np.zeros(len(sym_m))
    for sym in main_syms:
        ax.bar(sym_m.index, sym_m[sym].values, bottom=bottom, label=sym)
        bottom += sym_m[sym].values
    ax.axhline(0, color="black", linewidth=0.6)
    ax.legend(fontsize=7)
    ax.set_title("Monthly P/L by Symbol (stacked)")
    plt.xticks(rotation=45, ha="right", fontsize=7)
    fig.tight_layout()
    fig.savefig(FIG_DIR / "symbol_monthly.pdf")
    plt.close()

    # XAUUSD regime analysis
    start = datetime(2023, 7, 1)
    end = datetime(2026, 6, 4)
    xau = load_xau_h1(start, end)
    xau = market_features(xau)
    xau.to_csv(DATA_DIR / "xau_h1_features.csv")

    port_monthly = df.groupby("month")["net"].sum()
    xau_m = xau.resample("ME").agg({"adx14": "mean", "atr_pct": "mean", "chop": "mean", "trend_slope": "mean", "close": "last"})
    xau_m.index = xau_m.index.strftime("%Y-%m")

    # Regime: portfolio drawdown windows vs calm reference (2024-03..2024-09)
    dd_months: set[str] = set()
    for ep in drawdowns[:3]:
        t0, t1 = pd.Timestamp(ep["start"]), pd.Timestamp(ep["trough"])
        for ts in pd.date_range(t0.to_period("M").to_timestamp(), t1.to_period("M").to_timestamp(), freq="MS"):
            dd_months.add(ts.strftime("%Y-%m"))
    calm_months = [m for m in xau_m.index if "2024-0" in m and m >= "2024-03" and m <= "2024-09"]
    dd_mask = xau_m.index.isin(sorted(dd_months))
    calm_mask = xau_m.index.isin(calm_months)

    common = sorted(set(port_monthly.index) & set(xau_m.index))
    pm = port_monthly.reindex(common, fill_value=0)
    regime = {
        "dd_adx": float(xau_m.loc[dd_mask, "adx14"].mean()) if dd_mask.any() else 0,
        "calm_adx": float(xau_m.loc[calm_mask, "adx14"].mean()) if calm_mask.any() else 0,
        "dd_atr_pct": float(xau_m.loc[dd_mask, "atr_pct"].mean()) if dd_mask.any() else 0,
        "calm_atr_pct": float(xau_m.loc[calm_mask, "atr_pct"].mean()) if calm_mask.any() else 0,
        "dd_chop": float(xau_m.loc[dd_mask, "chop"].mean()) if dd_mask.any() else 0,
        "calm_chop": float(xau_m.loc[calm_mask, "chop"].mean()) if calm_mask.any() else 0,
        "dd_slope": float(xau_m.loc[dd_mask, "trend_slope"].mean()) if dd_mask.any() else 0,
        "calm_slope": float(xau_m.loc[calm_mask, "trend_slope"].mean()) if calm_mask.any() else 0,
        "dd_months": sorted(dd_months),
    }

    # Regime monthly chart
    fig, ax1 = plt.subplots(figsize=(12, 4))
    ax2 = ax1.twinx()
    xs = np.arange(len(common))
    ax1.bar(xs, pm.values, color=np.where(pm.values >= 0, "#66bb6a", "#ef5350"), alpha=0.7, label="Portfolio P/L")
    ax2.plot(xs, xau_m.reindex(common)["adx14"].values, color="#1565c0", marker="o", markersize=3, label="ADX")
    ax2.plot(xs, xau_m.reindex(common)["atr_pct"].values * 2, color="#ff8f00", marker="s", markersize=3, label="ATR% x2")
    ax1.set_xticks(xs)
    ax1.set_xticklabels(common, rotation=45, ha="right", fontsize=7)
    ax1.set_ylabel("Portfolio Monthly P/L")
    ax2.set_ylabel("ADX / scaled ATR%")
    ax1.set_title("Monthly Portfolio P/L vs XAUUSD Regime")
    fig.tight_layout()
    fig.savefig(FIG_DIR / "xau_regime_monthly.pdf")
    plt.close()

    # Candle windows
    if drawdowns:
        trough = drawdowns[0]["trough"]
        dd_win = xau.loc[trough - pd.Timedelta(days=10): trough + pd.Timedelta(days=10)]
        calm_start = pd.Timestamp("2024-03-01")
        calm_win = xau.loc[calm_start: calm_start + pd.Timedelta(days=10)]
        fig, ax = plt.subplots(figsize=(8, 3.5))
        plot_candles(ax, dd_win, f"Drawdown trough window ~ {trough.strftime('%Y-%m-%d')}")
        fig.tight_layout()
        fig.savefig(FIG_DIR / "xau_dd_candles.pdf")
        plt.close()
        fig, ax = plt.subplots(figsize=(8, 3.5))
        plot_candles(ax, calm_win, "Calm period reference (2024-03)")
        fig.tight_layout()
        fig.savefig(FIG_DIR / "xau_calm_candles.pdf")
        plt.close()

    # Issues per strategy
    issues = {}
    monthly_dict = {}
    for strat in strategy_order:
        if strat in monthly_strat.columns:
            ser = monthly_strat[strat]
            monthly_dict[strat] = ser.to_dict()
            issues[strat] = monthly_issue_text(strat, ser, STRATEGY_META.get(strat, {}))

    summary = {
        "portfolio": portfolio,
        "drawdowns": drawdowns,
        "strategy_order": strategy_order,
        "totals": totals.to_dict(),
        "monthly": monthly_dict,
        "issues": issues,
        "st_monthly": st_monthly,
        "regime": regime,
    }
    (DATA_DIR / "summary.json").write_text(json.dumps(summary, default=str, indent=2), encoding="utf-8")

    tex = build_latex(summary)
    TEX_FILE.write_text(tex, encoding="utf-8")
    print(f"Wrote {TEX_FILE}")
    print(f"Figures in {FIG_DIR}")
    for _ in range(2):
        subprocess.run(
            ["xelatex", "-interaction=nonstopmode", "cluster_evaluation.tex"],
            cwd=ROOT,
            check=False,
            capture_output=True,
        )
    pdf = ROOT / "cluster_evaluation.pdf"
    if pdf.exists():
        print(f"PDF: {pdf}")
    return summary


if __name__ == "__main__":
    main()
