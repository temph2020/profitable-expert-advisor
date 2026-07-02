#!/usr/bin/env python3
"""代客理财产品介绍 PDF — 从 MT5 客户端回测报告解析数据并生成。"""
from __future__ import annotations

import re
import sys
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm, mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    HRFlowable,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[2] / "backtesting" / "MT5"))

from cluster_audit.united_mt5_manifest import PRODUCTION_IDS, UNITED_MT5_STRATEGIES
from cluster_audit.united_mt5_runner import mt5_terminal_data_dir, parse_report, read_text, grab_metric


def _mt5_data() -> Path:
    data = mt5_terminal_data_dir()
    if data is None:
        raise SystemExit(
            "MT5 data folder not found. Set MT5_TERMINAL_DATA_ID in .env or log into MT5 once."
        )
    return data


OUT_PDF = ROOT / "UnitedEA_ManagedAccount_Brochure.pdf"

BEST_LOTS = {
    "DB": 0.01, "ES": 0.07, "RC": 0.10, "RM": 0.01,
    "RS_NVDA": 5.0, "RS_TSLA": 5.0, "RS_BTCUSD": 0.06, "RS_XAUUSD": 0.04,
    "SE": 0.01, "ST_BTC": 0.01, "ST_XAU": 0.01,
    "RRA_AUD": 0.05, "RRA_GBP": 0.03, "UB": 0.03,
    "RS_NAS100": 0.03, "RS_US30": 0.02, "UKB": 0.01, "GB": 0.01, "U5B": 0.05,
}

CLOSE_ON = {"ES", "RS_XAUUSD", "RS_US30"}
TIER = {
    "star": {"RS_BTCUSD", "RS_XAUUSD", "RS_US30", "RS_NAS100", "DB", "ES"},
    "stable": {"RC", "RM", "RS_NVDA", "RS_TSLA", "ST_BTC", "UB", "U5B", "GB", "UKB"},
    "weak": {"SE", "ST_XAU", "RRA_AUD", "RRA_GBP"},
}

SM = {s["id"]: s for s in UNITED_MT5_STRATEGIES}


def register_fonts() -> str:
    for name, path in [
        ("CN", r"C:\Windows\Fonts\msyh.ttc"),
        ("CN", r"C:\Windows\Fonts\simhei.ttf"),
        ("CN", r"C:\Windows\Fonts\simsun.ttc"),
    ]:
        if Path(path).exists():
            try:
                pdfmetrics.registerFont(TTFont("CN", path, subfontIndex=0 if path.endswith(".ttc") else None))
                return "CN"
            except Exception:
                continue
    return "Helvetica"


def parse_extra(path: Path) -> dict:
    text = read_text(path)
    wr = grab_metric(text, "profit_factor")  # reuse grab - need win rate manually
    gross_profit = None
    gross_loss = None
    for label in ("Gross Profit", "总获利"):
        m = re.search(rf">{re.escape(label)}</td>\s*<td[^>]*>(?:<b>)?([^<]+)", text, re.I)
        if m:
            gross_profit = m.group(1).strip()
            break
    for label in ("Gross Loss", "总亏损"):
        m = re.search(rf">{re.escape(label)}</td>\s*<td[^>]*>(?:<b>)?([^<]+)", text, re.I)
        if m:
            gross_loss = m.group(1).strip()
            break
    for label in ("Profit Trades (% of total)", "盈利交易 (%占总百分比)"):
        m = re.search(rf">{re.escape(label)}</td>\s*<td[^>]*>(?:<b>)?([^<]+)", text, re.I)
        if m:
            win_rate = m.group(1).strip()
            break
    else:
        win_rate = "—"
    dd = grab_metric(text, "equity_dd")
    return {"win_rate": win_rate, "max_drawdown": dd or "—", "gross_profit": gross_profit, "gross_loss": gross_loss}


def load_strategy_metrics() -> list[dict]:
    rows = []
    for sid in PRODUCTION_IDS:
        spec = SM[sid]
        report_name = f"solo_{sid}_off"
        m = parse_report(_mt5_data(), report_name)
        if not m.get("ready"):
            # fallback: lot genetic best-lot report
            lot = BEST_LOTS.get(sid, 0.01)
            lot_s = f"{lot:g}".replace(".", "p")
            for pat in (f"lot_{sid}_{lot_s}", f"lot_{sid}_{lot:g}"):
                m = parse_report(_mt5_data(), pat)
                if m.get("ready"):
                    break
        extra = {}
        if m.get("report"):
            extra = parse_extra(Path(m["report"]))
        net = m.get("net_profit")
        ret_pct = f"{net / 30:.1f}%" if net is not None else "—"  # $3000 base, 3yr approx
        tier = "明星" if sid in TIER["star"] else ("稳健" if sid in TIER["stable"] else "观察")
        rows.append({
            "id": sid,
            "name": spec["name"],
            "lot": BEST_LOTS.get(sid, "—"),
            "pf": m.get("profit_factor"),
            "net": net,
            "sharpe": m.get("sharpe"),
            "trades": m.get("total_trades"),
            "dd": extra.get("max_drawdown", "—"),
            "win_rate": extra.get("win_rate", "—"),
            "ret_pct": ret_pct,
            "tier": tier,
            "close_on": "是" if sid in CLOSE_ON else "否",
            "ready": m.get("ready", False),
        })
    return rows


def load_portfolio() -> dict:
    for name in ("prod_v2_combined", "lot_genetic_combined", "close_NEW", "lot_combined_optimized"):
        m = parse_report(_mt5_data(), name)
        if m.get("ready"):
            extra = parse_extra(Path(m["report"]))
            m.update(extra)
            m["source"] = name
            return m
    return {"ready": False}


def fmt(v, nd=2):
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def make_watermark(font_name: str):
    WATERMARK = "Namelos.xyz Research"

    def _draw(c, _doc):
        c.saveState()
        c.setFillColor(colors.Color(0.5, 0.5, 0.5, alpha=0.10))
        c.setFont(font_name, 16)
        w, h = A4
        step_x, step_y = 125, 85
        x0, y0 = step_x * 0.6, step_y * 0.8
        x = x0
        while x < w + step_x:
            y = y0
            while y < h + step_y:
                c.saveState()
                c.translate(x, y)
                c.rotate(35)
                c.drawCentredString(0, 0, WATERMARK)
                c.restoreState()
                y += step_y
            x += step_x
        c.restoreState()

    return _draw


def build_pdf(font: str) -> None:
    styles = getSampleStyleSheet()
    title = ParagraphStyle("T", parent=styles["Title"], fontName=font, fontSize=22, leading=28, alignment=TA_CENTER)
    h1 = ParagraphStyle("H1", parent=styles["Heading1"], fontName=font, fontSize=16, leading=22, spaceAfter=8)
    h2 = ParagraphStyle("H2", parent=styles["Heading2"], fontName=font, fontSize=13, leading=18, spaceAfter=6)
    body = ParagraphStyle("B", parent=styles["Normal"], fontName=font, fontSize=10, leading=15, alignment=TA_JUSTIFY)
    small = ParagraphStyle("S", parent=body, fontSize=8, textColor=colors.grey)
    center = ParagraphStyle("C", parent=body, alignment=TA_CENTER)

    portfolio = load_portfolio()
    strategies = load_strategy_metrics()
    ready_n = sum(1 for s in strategies if s["ready"])

    doc = SimpleDocTemplate(str(OUT_PDF), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=2 * cm, bottomMargin=2 * cm)
    story: list = []

    # Cover
    story.append(Spacer(1, 3 * cm))
    story.append(Paragraph("UnitedEA 智能交易集群", title))
    story.append(Spacer(1, 0.5 * cm))
    story.append(Paragraph("代客理财 · 产品介绍与业绩分析", ParagraphStyle("sub", parent=title, fontSize=14)))
    story.append(Spacer(1, 1.5 * cm))
    story.append(Paragraph(f"回测区间：2023年7月 — 2026年6月（近三年）", center))
    story.append(Paragraph(f"报告日期：{date.today().isoformat()}", center))
    story.append(Spacer(1, 2 * cm))
    story.append(Paragraph(
        "本材料基于 MetaTrader 5 策略测试器历史回测数据整理，仅供合格投资者参考。"
        "过往业绩不代表未来收益，外汇及差价合约交易存在本金损失风险。",
        small,
    ))
    story.append(PageBreak())

    # Product intro
    story.append(Paragraph("一、产品介绍", h1))
    story.append(Paragraph(
        "UnitedEA 是一套运行于 MetaTrader 5 平台的多策略智能交易集群（Expert Advisor Cluster）。"
        "通过在同一账户内并行运行 19 个经独立优化、低相关性的子策略机器人，实现跨品种、跨逻辑的风险分散："
        "涵盖黄金趋势（DarvasBox、EMA 斜率）、RSI 反转与剥头皮、亚洲时段均值回归、指数突破（美日指数、德指、标普）"
        "以及加密货币趋势跟踪等。",
        body,
    ))
    story.append(Spacer(1, 0.3 * cm))
    story.append(Paragraph("核心服务要素", h2))
    bullets = [
        "▸ <b>全自动执行</b>：7×24 监控信号，无需人工盯盘",
        "▸ <b>组合化管理</b>：19 个子策略统一风控、统一资金调度",
        "▸ <b>动态仓位</b>：按账户净值相对基准余额（$3,000）自动缩放手数",
        "▸ <b>逐策略审计</b>：定期对每机器人进行手数遗传优化、信号替换 A/B 测试",
        "▸ <b>风险隔离</b>：高保证金品种（如 MU）默认关闭；单策略最大手数有上限",
    ]
    for b in bullets:
        story.append(Paragraph(b, body))
        story.append(Spacer(1, 0.15 * cm))

    story.append(Spacer(1, 0.4 * cm))
    story.append(Paragraph("适用投资者", h2))
    story.append(Paragraph(
        "具备外汇/差价合约基础知识、风险承受能力中等及以上、追求长期稳健复利（非短期暴利）的投资者。"
        "建议起始资金不低于 $3,000，与系统参考余额一致，以便手数缩放比例合理。",
        body,
    ))
    story.append(PageBreak())

    # Methodology
    story.append(Paragraph("二、回测方法与数据来源", h1))
    story.append(Paragraph(
        "本报告数据直接解析自本地 MT5 客户端策略测试器生成的 HTML 报告"
        "（%APPDATA%\\MetaQuotes\\Terminal\\&lt;terminal-id&gt;）。",
        body,
    ))
    meth = [
        ["初始资金", "$3,000"],
        ["杠杆", "1:1000"],
        ["回测区间", "2023.07.01 — 2026.06.01"],
        ["测试模型", "1 分钟 OHLC（每个即时价位）"],
        ["组合测试品种", "NAS100 H1（集群统一调度）"],
        ["仓位缩放", "ORCH_ScaleLotsByBalance = true，参考余额 $3,000"],
        ["生产策略数", f"{len(PRODUCTION_IDS)} 个"],
        ["报告解析", f"已解析 {ready_n}/{len(PRODUCTION_IDS)} 个单策略报告 + 组合报告"],
    ]
    t = Table(meth, colWidths=[5 * cm, 11 * cm])
    t.setStyle(TableStyle([
        ("FONT", (0, 0), (-1, -1), font, 9),
        ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#f0f4f8")),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.lightgrey),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
    ]))
    story.append(Spacer(1, 0.3 * cm))
    story.append(t)
    story.append(Spacer(1, 0.4 * cm))
    story.append(Paragraph(
        "<b>说明：</b>组合层面「总净盈利」在余额复利缩放下会随净值膨胀而数值极大，"
        "不宜与初始资金直接对比。评估策略质量应优先参考盈利因子（PF）、夏普比率、最大回撤及单策略独立回测。",
        small,
    ))
    story.append(PageBreak())

    # Portfolio
    story.append(Paragraph("三、组合层面业绩（近三年）", h1))
    if portfolio.get("ready"):
        pf = portfolio
        port_data = [
            ["指标", "数值"],
            ["数据来源", pf.get("source", "—")],
            ["盈利因子 PF", fmt(pf.get("profit_factor"))],
            ["夏普比率", fmt(pf.get("sharpe"))],
            ["总交易笔数", fmt(pf.get("total_trades"), 0)],
            ["总净盈利（复利缩放后）", f"${fmt(pf.get('net_profit'))}"],
            ["最大净值回撤", pf.get("max_drawdown", "—")],
            ["胜率", pf.get("win_rate", "—")],
        ]
        pt = Table(port_data, colWidths=[5.5 * cm, 10.5 * cm])
        pt.setStyle(TableStyle([
            ("FONT", (0, 0), (-1, -1), font, 10),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1a365d")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.lightgrey),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f7fafc")]),
        ]))
        story.append(pt)
        story.append(Spacer(1, 0.5 * cm))
        story.append(Paragraph(
            f"当前生产组合（19 策略）经遗传算法优化手数后，"
            f"盈利因子 <b>{fmt(pf.get('profit_factor'))}</b>、夏普 <b>{fmt(pf.get('sharpe'))}</b>，"
            f"在三年回测期内共执行约 <b>{fmt(pf.get('total_trades'), 0)}</b> 笔交易。"
            "组合通过多策略互补降低单一品种风险，但黄金相关策略仍占利润权重较高，需持续关注。",
            body,
        ))
    else:
        story.append(Paragraph("未找到组合回测报告（prod_v2_combined.htm），请先在 MT5 运行组合回测。", body))
    story.append(PageBreak())

    # Per-robot table
    story.append(Paragraph("四、各子机器人独立业绩分析", h1))
    story.append(Paragraph(
        "下表为各策略在优化手数下、单独运行的近三年回测结果（Close-on-reverse 关闭状态，除标注外）。"
        "「三年回报」= 净盈利 ÷ 基准资金 $3,000，仅为粗略参考。",
        body,
    ))
    story.append(Spacer(1, 0.3 * cm))

    header = ["代码", "策略名称", "手数", "PF", "夏普", "净盈利$", "三年回报", "交易数", "最大回撤", "分级", "信号平仓"]
    table_data = [header]
    for s in sorted(strategies, key=lambda x: (x["tier"], -(x["net"] or 0))):
        table_data.append([
            s["id"],
            s["name"][:12],
            fmt(s["lot"], 2) if isinstance(s["lot"], float) else s["lot"],
            fmt(s["pf"]),
            fmt(s["sharpe"]),
            fmt(s["net"], 0),
            s["ret_pct"],
            fmt(s["trades"], 0),
            str(s["dd"])[:18],
            s["tier"],
            s["close_on"],
        ])

    col_w = [1.1 * cm, 2.6 * cm, 1.0 * cm, 0.9 * cm, 0.9 * cm, 1.6 * cm, 1.4 * cm, 1.2 * cm, 2.2 * cm, 1.0 * cm, 1.2 * cm]
    st = Table(table_data, colWidths=col_w, repeatRows=1)
    st.setStyle(TableStyle([
        ("FONT", (0, 0), (-1, -1), font, 7),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#2d3748")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f8f9fa")]),
        ("ALIGN", (2, 1), (7, -1), "CENTER"),
    ]))
    story.append(st)

    story.append(Spacer(1, 0.5 * cm))
    story.append(Paragraph("分级说明", h2))
    story.append(Paragraph(
        "<b>明星</b>（PF≥1.5 或夏普≥5）：RS_BTCUSD、RS_XAUUSD、RS_US30、RS_NAS100、DB、ES — 组合核心利润来源。<br/>"
        "<b>稳健</b>（PF 1.1–1.5）：RC、RM、NVDA、TSLA、ST_BTC、UB、U5B、GB、UKB — 提供分散与缓冲。<br/>"
        "<b>观察</b>（PF&lt;1.15 或夏普&lt;1）：SE、ST_XAU、RRA_AUD、RRA_GBP — 已降至最小手数，持续监控。",
        body,
    ))
    story.append(PageBreak())

    # Adjustments
    story.append(Paragraph("五、已完成的策略调整（2026年）", h1))
    adj = [
        ["调整项", "内容", "效果"],
        ["组合扩容", "由 11 策略扩至 19 策略，新增 BTC/XAU 剥头皮、趋势、亚式、指数等", "分散品种，提升夏普"],
        ["手数遗传优化", "逐策略网格搜索最优手数（股票 5–15，其余 0.01–0.1）", "PF/夏普最大化"],
        ["US30 降杠杆", "US30 手数 0.08→0.02，控制回撤", "夏普 8.67→10.47"],
        ["高保证金剔除", "MU 等高保证金股票默认关闭", "降低爆仓风险"],
        ["信号替换审计", "19 策略逐一 A/B 测试「亏损单遇反向信号平仓」", "仅 ES/XAU/US30 开启"],
        ["TSLA 关闭信号平仓", "原开启，新审计为中性偏负", "减少无效换手"],
        ["GAP 跳空防护", "测试后保持关闭（影响微小）", "简化逻辑"],
    ]
    at = Table(adj, colWidths=[3.2 * cm, 8.3 * cm, 4.5 * cm])
    at.setStyle(TableStyle([
        ("FONT", (0, 0), (-1, -1), font, 9),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1a365d")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.lightgrey),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story.append(at)
    story.append(PageBreak())

    # Roadmap
    story.append(Paragraph("六、后续优化路线图", h1))
    roadmap = [
        ("Q3 2026 — 监控与微调", [
            "每月重跑单策略 + 组合回测，对比实盘滑点",
            "观察 SE（SuperEMA）是否继续拖累，考虑移出生产组合",
            "RRA_AUD / RRA_GBP 亚式策略：信号平仓已证实有害，保持关闭并评估是否降权",
        ]),
        ("Q4 2026 — 风控强化", [
            "引入组合层面最大回撤熔断（如净值回撤 >20% 暂停开仓）",
            "黄金高相关策略（RM、RS_XAU、ST_XAU）设利润集中度上限",
            "实盘与回测逐月对账脚本自动化",
        ]),
        ("2027 — 扩展研究", [
            "新指数/外汇机器人候选池定期审计（disabled_audit 流程）",
            "探索 AI 信号过滤层（ONNX 模型）与规则策略混合",
            "多账户分策略托管方案（高夏普策略独立账户）",
        ]),
    ]
    for title_txt, items in roadmap:
        story.append(Paragraph(title_txt, h2))
        for it in items:
            story.append(Paragraph(f"• {it}", body))
            story.append(Spacer(1, 0.1 * cm))
        story.append(Spacer(1, 0.2 * cm))

    story.append(Spacer(1, 0.8 * cm))
    story.append(HRFlowable(width="100%", color=colors.lightgrey))
    story.append(Spacer(1, 0.3 * cm))
    story.append(Paragraph(
        "<b>免责声明</b>：本文件不构成投资建议。外汇、贵金属、指数及股票差价合约具有高风险，"
        "您可能损失全部本金。请在充分了解风险后自主决策，必要时咨询持牌金融顾问。",
        small,
    ))

    doc.build(story, onFirstPage=make_watermark(font), onLaterPages=make_watermark(font))
    print(f"Generated: {OUT_PDF}")


if __name__ == "__main__":
    f = register_fonts()
    build_pdf(f)
