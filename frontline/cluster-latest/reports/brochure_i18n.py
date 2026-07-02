"""Brochure strings and flowcharts: zh / de / ar."""
from __future__ import annotations

from dataclasses import dataclass, field

_T = r"node distance=0.65cm, every node/.style={draw, rounded corners, align=center, font=\footnotesize, inner sep=4pt, text width=6.8cm}, >=Stealth, thick"
_TH = r"node distance=0.65cm and 2.2cm, every node/.style={draw, rounded corners, align=center, font=\footnotesize, inner sep=4pt, text width=3.4cm}, >=Stealth, thick"
_TAR = r"node distance=0.65cm, every node/.style={draw, rounded corners, align=center, font=\footnotesize\arabicfont, inner sep=4pt, text width=6.8cm}, >=Stealth, thick"
_THAR = r"node distance=0.65cm and 2.2cm, every node/.style={draw, rounded corners, align=center, font=\footnotesize\arabicfont, inner sep=4pt, text width=3.2cm}, >=Stealth, thick"


@dataclass
class Locale:
    code: str
    tex_stem: str
    pdf_name: str
    preamble: list[str]
    title: str
    author: str
    abstract_tpl: str  # {n_prof}, {n_pf1}, {deposit}
    s1_title: str
    s1_body: str
    s1_1_title: str
    s1_1_items: list[str]
    s1_2_title: str
    table_headers: tuple[str, str]
    table_rows: list[tuple[str, str]]
    s2_title: str
    s2_body_tpl: str  # {pf}, {sharpe}, {trades}
    s2_caption: str
    s3_title: str
    s3_body: str
    s4_title: str
    s4_caption: str
    table_cols: str
    s5_title: str
    s5_body: str
    close_note: str
    s6_title: str
    s6_items: list[str]
    disclaimer: str
    equity_ylabel: str
    equity_combined_title: str
    caption_pf_net_sharpe: tuple[str, str, str]  # PF, net, sharpe labels
    flowcharts: dict[str, str] = field(default_factory=dict)
    rtl: bool = False


def _fc(lang: str, key: str, body: str, *, wide: bool = False) -> str:
    t = _THAR if (lang == "ar" and wide) else (_TAR if lang == "ar" else (_TH if wide else _T))
    return rf"\begin{{tikzpicture}}[{t}]{body}\end{{tikzpicture}}"


FLOW_ZH = {
    "DB": _fc("zh", "DB", r"""
\node (a) {H1 扫描 BoxPeriod 根 K 线};
\node (b) [below=of a] {计算高低点，形成 Darvas 箱体};
\node (c) [below=of b] {箱体有效？幅度 $\leq$ 偏差阈值\\{\scriptsize 无效则继续等待}};
\node (d) [below=of c] {趋势 MA 斜率 + 成交量放大过滤};
\node (e) [below=of d] {突破上沿 $\rightarrow$ Buy\\突破下沿 $\rightarrow$ Sell};
\node (f) [below=of e] {固定 SL/TP 持仓管理};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "ES": _fc("zh", "ES", r"""
\node (a) {EMA 金叉 / 死叉检测};
\node (b) [below=of a] {价格距 EMA 超过阈值？};
\node (c) [below=of b] {EMA 斜率超过阈值？};
\node (d) [below=of c] {周线 ADX 趋势强度与方向过滤};
\node (e) [below=of d] {开仓（每交叉限最大笔数）};
\node (f) [below=of e] {移动止损；反向信号平亏损单（已启用）};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "RC": _fc("zh", "RC", r"""
\node (a) {RSI 超买 / 超卖穿越};
\node (b) [below=of a] {EMA 斜率 + 价格距离过滤};
\node (c) [below=of b] {交易时段白名单过滤};
\node (d) [below=of c] {反向信号入场};
\node (e) [below=of d] {RSI 目标位 / 移动止损出场};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RM": _fc("zh", "RM", r"""
\node (a) [text width=7cm] {子策略路由（三选一）};
\node (b) [below left=1.1cm and 2.8cm of a] {RSI Follow\\{\scriptsize 时段内顺势}};
\node (c) [below=1.1cm of a] {RSI Reverse\\{\scriptsize 交叉反转}};
\node (d) [below right=1.1cm and 2.8cm of a] {EMA Cross\\{\scriptsize 距离过滤}};
\node (e) [below=1.6cm of c, text width=7.5cm] {独立持仓管理：时段外平仓 / 策略锁};
\draw[->] (a)--(b); \draw[->] (a)--(c); \draw[->] (a)--(d);
\draw[->] (b)--(e); \draw[->] (c)--(e); \draw[->] (d)--(e);""", wide=True),
    "RS_SCALP": _fc("zh", "RS_SCALP", r"""
\node (a) {新 K 线：更新 RSI};
\node (b) [below=of a] {RSI 达到目标买 / 卖位？};
\node (c) [below=of b] {BarsToWait 冷却等待};
\node (d) [below=of c] {开仓 + 移动止损跟踪};
\node (e) [below=of d] {反转逃离（ATR/RSI/实体）\\可选：反向信号平亏损单};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "SE": _fc("zh", "SE", r"""
\node (a) {EMA 快 / 中 / 慢多头排列？};
\node (b) [below=of a] {CCI 进入超卖区回调};
\node (c) [below=of b] {MACD 金叉确认};
\node (d) [below=of c] {入场（单笔持仓限制）};
\node (e) [below=of d] {CCI 零轴穿越或最大持仓 K 线退出};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "ST": _fc("zh", "ST", r"""
\node (a) {高周期扫描趋势线};
\node (b) [below=of a] {价格触及趋势线（容差内）？};
\node (c) [below=of b] {突破缓冲带确认方向};
\node (d) [below=of c] {顺势开仓（多 / 空双向）};
\node (e) [below=of d] {趋势线失效或反向突破平仓};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RRA": _fc("zh", "RRA", r"""
\node (a) {亚洲时段 00:00--08:00 UTC};
\node (b) [below=of a] {RSI 穿越超买 / 超卖极值};
\node (c) [below=of b] {均值回归方向入场};
\node (d) [below=of c] {RSI 回归中性或时段结束平仓};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d);"""),
    "BUSTER": _fc("zh", "BUSTER", r"""
\node (a) {定义日内区间（开盘前固定时段）};
\node (b) [below=of a] {区间宽度 $\geq$ 最小点数？};
\node (c) [below=of b] {区间上下挂突破止损单（含缓冲）};
\node (d) [below=of c] {成交后持仓管理};
\node (e) [below=of d] {收盘前强制平仓};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
}

FLOW_EN = {
    "DB": _fc("en", "DB", r"""
\node (a) {H1: scan BoxPeriod bars};
\node (b) [below=of a] {High/low form Darvas box};
\node (c) [below=of b] {Valid box? range $\leq$ threshold\\{\scriptsize else wait}};
\node (d) [below=of c] {Trend MA slope + volume filter};
\node (e) [below=of d] {Break above $\rightarrow$ Buy\\below $\rightarrow$ Sell};
\node (f) [below=of e] {Fixed SL/TP management};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "ES": _fc("en", "ES", r"""
\node (a) {EMA golden/death cross};
\node (b) [below=of a] {Price distance $>$ threshold?};
\node (c) [below=of b] {EMA slope $>$ threshold?};
\node (d) [below=of c] {Weekly ADX filter};
\node (e) [below=of d] {Entry (max trades per cross)};
\node (f) [below=of e] {Trailing stop; close loss on reverse};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "RC": _fc("en", "RC", r"""
\node (a) {RSI overbought/oversold cross};
\node (b) [below=of a] {EMA slope + distance filter};
\node (c) [below=of b] {Trading hours whitelist};
\node (d) [below=of c] {Counter-signal entry};
\node (e) [below=of d] {RSI target / trailing exit};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RM": _fc("en", "RM", r"""
\node (a) [text width=7cm] {Sub-strategy router};
\node (b) [below left=1.1cm and 2.8cm of a] {RSI Follow\\{\scriptsize intraday}};
\node (c) [below=1.1cm of a] {RSI Reverse\\{\scriptsize reversal}};
\node (d) [below right=1.1cm and 2.8cm of a] {EMA Cross\\{\scriptsize distance}};
\node (e) [below=1.6cm of c, text width=7.5cm] {Close outside session / strategy lock};
\draw[->] (a)--(b); \draw[->] (a)--(c); \draw[->] (a)--(d);
\draw[->] (b)--(e); \draw[->] (c)--(e); \draw[->] (d)--(e);""", wide=True),
    "RS_SCALP": _fc("en", "RS_SCALP", r"""
\node (a) {New bar: update RSI};
\node (b) [below=of a] {RSI hit buy/sell target?};
\node (c) [below=of b] {BarsToWait cooldown};
\node (d) [below=of c] {Entry + trailing stop};
\node (e) [below=of d] {Reversal escape (ATR/RSI)\\optional: close on reverse};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "SE": _fc("en", "SE", r"""
\node (a) {EMA fast/mid/slow aligned?};
\node (b) [below=of a] {CCI oversold pullback};
\node (c) [below=of b] {MACD golden cross};
\node (d) [below=of c] {Entry (one position)};
\node (e) [below=of d] {CCI zero cross or max hold bars};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "ST": _fc("en", "ST", r"""
\node (a) {Higher TF trendline scan};
\node (b) [below=of a] {Price touches line (tolerance)?};
\node (c) [below=of b] {Breakout buffer confirmed};
\node (d) [below=of c] {Trend entry long/short};
\node (e) [below=of d] {Line break $\rightarrow$ close};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RRA": _fc("en", "RRA", r"""
\node (a) {Asian session 00:00--08:00 UTC};
\node (b) [below=of a] {RSI extreme cross};
\node (c) [below=of b] {Mean-reversion entry};
\node (d) [below=of c] {RSI neutral or session end};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d);"""),
    "BUSTER": _fc("en", "BUSTER", r"""
\node (a) {Define intraday range (pre-open)};
\node (b) [below=of a] {Range width $\geq$ minimum?};
\node (c) [below=of b] {Breakout stop orders (buffer)};
\node (d) [below=of c] {Position management};
\node (e) [below=of d] {Force close before session end};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
}

FLOW_DE = {
    "DB": _fc("de", "DB", r"""
\node (a) {H1: BoxPeriod Kerzen scannen};
\node (b) [below=of a] {Hoch/Tief bilden Darvas-Box};
\node (c) [below=of b] {Box g\"ultig? Range $\leq$ Abweichung\\{\scriptsize sonst warten}};
\node (d) [below=of c] {Trend-MA-Steigung + Volumenfilter};
\node (e) [below=of d] {Breakout oben $\rightarrow$ Buy\\unten $\rightarrow$ Sell};
\node (f) [below=of e] {Feste SL/TP Verwaltung};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "ES": _fc("de", "ES", r"""
\node (a) {EMA Golden/Death Cross};
\node (b) [below=of a] {Preisabstand zu EMA $>$ Schwelle?};
\node (c) [below=of b] {EMA-Steigung $>$ Schwelle?};
\node (d) [below=of c] {W\"ochentlicher ADX-Filter};
\node (e) [below=of d] {Einstieg (max. Trades pro Cross)};
\node (f) [below=of e] {Trailing Stop; Verlust bei Gegensignal schlie\ss en};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "RC": _fc("de", "RC", r"""
\node (a) {RSI \"Uberkauft/\"Uberverkauft Cross};
\node (b) [below=of a] {EMA-Steigung + Abstandsfilter};
\node (c) [below=of b] {Handelszeiten-Whitelist};
\node (d) [below=of c] {Gegensignal-Einstieg};
\node (e) [below=of d] {RSI-Ziel / Trailing Stop Ausstieg};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RM": _fc("de", "RM", r"""
\node (a) [text width=7cm] {Sub-Strategie Router};
\node (b) [below left=1.1cm and 2.8cm of a] {RSI Follow\\{\scriptsize intraday}};
\node (c) [below=1.1cm of a] {RSI Reverse\\{\scriptsize Cross-Reversal}};
\node (d) [below right=1.1cm and 2.8cm of a] {EMA Cross\\{\scriptsize Abstand}};
\node (e) [below=1.6cm of c, text width=7.5cm] {Session-Ende schlie\ss en / Strategie-Lock};
\draw[->] (a)--(b); \draw[->] (a)--(c); \draw[->] (a)--(d);
\draw[->] (b)--(e); \draw[->] (c)--(e); \draw[->] (d)--(e);""", wide=True),
    "RS_SCALP": _fc("de", "RS_SCALP", r"""
\node (a) {Neue Kerze: RSI aktualisieren};
\node (b) [below=of a] {RSI Ziel Buy/Sell erreicht?};
\node (c) [below=of b] {BarsToWait Cooldown};
\node (d) [below=of c] {Einstieg + Trailing Stop};
\node (e) [below=of d] {Reversal Escape (ATR/RSI)\\optional: Verlust bei Gegensignal};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "SE": _fc("de", "SE", r"""
\node (a) {EMA schnell/mittel/langsam bullisch?};
\node (b) [below=of a] {CCI \"Uberverkauft Pullback};
\node (c) [below=of b] {MACD Golden Cross};
\node (d) [below=of c] {Einstieg (eine Position)};
\node (e) [below=of d] {CCI Null-Linie oder max. Haltedauer};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "ST": _fc("de", "ST", r"""
\node (a) {H\"oherer TF: Trendlinie scannen};
\node (b) [below=of a] {Preis ber\"uhrt Linie (Toleranz)?};
\node (c) [below=of b] {Breakout-Puffer best\"atigt};
\node (d) [below=of c] {Trendfolge Long/Short};
\node (e) [below=of d] {Linie bricht $\rightarrow$ schlie\ss en};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RRA": _fc("de", "RRA", r"""
\node (a) {Asien-Session 00:00--08:00 UTC};
\node (b) [below=of a] {RSI Extrem-Cross};
\node (c) [below=of b] {Mean-Reversion Einstieg};
\node (d) [below=of c] {RSI neutral oder Session-Ende};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d);"""),
    "BUSTER": _fc("de", "BUSTER", r"""
\node (a) {Intraday-Range vor Er\"offnung};
\node (b) [below=of a] {Range-Breite $\geq$ Minimum?};
\node (c) [below=of b] {Breakout-Stop-Orders (Puffer)};
\node (d) [below=of c] {Positionsverwaltung};
\node (e) [below=of d] {Zwangsschluss vor Close};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
}

FLOW_AR = {
    "DB": _fc("ar", "DB", r"""
\node (a) {مسح H1 لعدد BoxPeriod};
\node (b) [below=of a] {حساب القمة/القاع وتكوين صندوق دارفاس};
\node (c) [below=of b] {الصندوق صالح؟ النطاق $\leq$ العتبة\\{\scriptsize وإلا الانتظار}};
\node (d) [below=of c] {فلتر ميل MA + حجم التداول};
\node (e) [below=of d] {اختراق أعلى $\rightarrow$ شراء\\أسفل $\rightarrow$ بيع};
\node (f) [below=of e] {إدارة SL/TP ثابتة};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "ES": _fc("ar", "ES", r"""
\node (a) {كشف تقاطع EMA الذهبي/الموت};
\node (b) [below=of a] {المسافة عن EMA $>$ العتبة؟};
\node (c) [below=of b] {ميل EMA $>$ العتبة؟};
\node (d) [below=of c] {فلتر ADX الأسبوعي};
\node (e) [below=of d] {دخول (حد أقصى لكل تقاطع)};
\node (f) [below=of e] {وقف متحرك؛ إغلاق الخسارة عند إشارة عكسية};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e); \draw[->] (e)--(f);"""),
    "RC": _fc("ar", "RC", r"""
\node (a) {عبور RSI تشبع شراء/بيع};
\node (b) [below=of a] {ميل EMA + فلتر المسافة};
\node (c) [below=of b] {فلتر أوقات التداول};
\node (d) [below=of c] {دخول بإشارة عكسية};
\node (e) [below=of d] {هدف RSI / وقف متحرك};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RM": _fc("ar", "RM", r"""
\node (a) [text width=7cm] {موجّه الاستراتيجيات الفرعية};
\node (b) [below left=1.1cm and 2.5cm of a] {RSI Follow\\{\scriptsize داخل الجلسة}};
\node (c) [below=1.1cm of a] {RSI Reverse\\{\scriptsize انعكاس}};
\node (d) [below right=1.1cm and 2.5cm of a] {EMA Cross\\{\scriptsize مسافة}};
\node (e) [below=1.6cm of c, text width=7.5cm] {إغلاق خارج الجلسة / قفل الاستراتيجية};
\draw[->] (a)--(b); \draw[->] (a)--(c); \draw[->] (a)--(d);
\draw[->] (b)--(e); \draw[->] (c)--(e); \draw[->] (d)--(e);""", wide=True),
    "RS_SCALP": _fc("ar", "RS_SCALP", r"""
\node (a) {شمعة جديدة: تحديث RSI};
\node (b) [below=of a] {RSI وصل هدف الشراء/البيع؟};
\node (c) [below=of b] {انتظار BarsToWait};
\node (d) [below=of c] {دخول + وقف متحرك};
\node (e) [below=of d] {هروب انعكاسي (ATR/RSI)\\اختياري: إغلاق عند إشارة عكسية};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "SE": _fc("ar", "SE", r"""
\node (a) {تراص EMA سريع/متوسط/بطيء صاعد؟};
\node (b) [below=of a] {تراجع CCI من تشبع بيع};
\node (c) [below=of b] {تأكيد MACD ذهبي};
\node (d) [below=of c] {دخول (صفقة واحدة)};
\node (e) [below=of d] {عبور CCI صفر أو حد زمني};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "ST": _fc("ar", "ST", r"""
\node (a) {مسح خط الاتجاه بإطار أعلى};
\node (b) [below=of a] {السعر يلامس الخط (ضمن التسامح)؟};
\node (c) [below=of b] {تأكيد كسر الحاجز};
\node (d) [below=of c] {دخول مع الاتجاه (شراء/بيع)};
\node (e) [below=of d] {كسر عكسي $\rightarrow$ إغلاق};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
    "RRA": _fc("ar", "RRA", r"""
\node (a) {جلسة آسيا 00:00--08:00 UTC};
\node (b) [below=of a] {عبور RSI للنقاط القصوى};
\node (c) [below=of b] {دخول ارتداد للمتوسط};
\node (d) [below=of c] {RSI محايد أو نهاية الجلسة};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d);"""),
    "BUSTER": _fc("ar", "BUSTER", r"""
\node (a) {تحديد نطاق اليوم قبل الافتتاح};
\node (b) [below=of a] {عرض النطاق $\geq$ الحد الأدنى؟};
\node (c) [below=of b] {أوامر كسر مع حاجز};
\node (d) [below=of c] {إدارة المركز};
\node (e) [below=of d] {إغلاق إجباري قبل الإقفال};
\draw[->] (a)--(b); \draw[->] (b)--(c); \draw[->] (c)--(d); \draw[->] (d)--(e);"""),
}

_COMMON_PKGS = [
    r"\usepackage{graphicx}",
    r"\usepackage{booktabs}",
    r"\usepackage{geometry}",
    r"\usepackage{float}",
    r"\usepackage{subcaption}",
    r"\usepackage{tikz}",
    r"\usetikzlibrary{arrows.meta, positioning}",
    r"\usepackage{hyperref}",
    r"\usepackage{xcolor}",
    r"\geometry{margin=2cm}",
]

LOCALES: dict[str, Locale] = {
    "zh": Locale(
        code="zh",
        tex_stem="managed_account_brochure",
        pdf_name="ManagedAccount_Brochure.pdf",
        preamble=[r"\documentclass[11pt,a4paper]{ctexart}"] + _COMMON_PKGS,
        title=r"UnitedEA 智能交易集群\\代客理财产品介绍 · 业绩与策略逻辑",
        author=r"Namelos.xyz Research · MetaTrader\,5 策略测试器回测",
        abstract_tpl=(
            r"本报告基于 MT5 客户端本地回测（2023.07--2026.06，初始资金 \${deposit:,.0f}，杠杆 1:1000，"
            r"余额复利缩放），展示 19 个生产子策略的独立净值曲线与组合表现。"
            r"近三年回测中，\textbf{{{n_prof}/19}} 个子策略净盈利为正，\textbf{{{n_pf1}/19}} 个盈利因子 $\geq 1$。"
            r"过往业绩不代表未来收益。"
        ),
        s1_title="产品介绍",
        s1_body="UnitedEA 是一套多策略 MetaTrader\\,5 智能交易集群，通过在同一账户并行运行 "
        "19 个经独立优化、低相关性子机器人，实现跨品种风险分散。",
        s1_1_title="服务模式（代客理财）",
        s1_1_items=[
            r"\textbf{全权委托执行}：策略信号自动下单，无需人工干预",
            r"\textbf{组合风控}：统一资金调度、动态手数缩放（基准余额 \$3,000）",
            r"\textbf{定期审计}：手数遗传优化、信号替换 A/B 测试、禁用策略筛查",
            r"\textbf{建议起始资金}：不低于 \$3,000，与系统参考余额一致",
        ],
        s1_2_title="回测设置",
        table_headers=("项目", "设置"),
        table_rows=[
            ("回测区间", "2023.07.01 -- 2026.06.01"),
            ("初始资金", r"\$3,000"),
            ("杠杆", "1:1000"),
            ("测试模型", "1 分钟 OHLC"),
            ("组合调度品种", "NAS100 H1"),
            ("数据来源", "MT5 本地终端数据目录"),
        ],
        s2_title="组合净值曲线",
        s2_body_tpl="下图展示 19 个子策略同时运行时的组合净值（对数坐标）。"
        "组合盈利因子 \\textbf{{{pf}}}，夏普比率 \\textbf{{{sharpe}}}，总交易 \\textbf{{{trades}}} 笔。",
        s2_caption="UnitedEA 19 策略组合净值曲线（2023.07--2026.06）",
        s3_title="各子机器人独立净值曲线",
        s3_body="以下每个子策略在\\textbf{单独启用}、优化手数下运行三年回测。"
        "所有曲线均从 \\$3,000 起步；虚线为初始资金参考线。"
        "\\textbf{全部 19 个机器人在三年期内均实现正净盈利。}",
        s4_title="各机器人业绩汇总",
        s4_caption="19 个子策略三年独立回测业绩",
        table_cols="代码 & 策略 & 品种 & PF & 净盈利(\\$) & 夏普 & 交易数",
        s5_title="各机器人底层逻辑流程图",
        s5_body=r"以下流程图概括各子策略的核心决策链路（与 \texttt{Strategies/} 源码一致）。",
        close_note=r"\noindent\textit{注：该策略已启用「反向信号平亏损单」优化。}",
        s6_title="后续策略调整",
        s6_items=[
            r"\textbf{手数}：已完成逐策略遗传优化，US30 降至 0.02 控制回撤",
            r"\textbf{信号平仓}：仅 ES、RS\_XAUUSD、RS\_US30 开启；其余保持关闭",
            r"\textbf{观察名单}：SE（PF 偏低）、亚式 AUD/GBP 维持最小手数",
            r"\textbf{风控}：计划引入组合层面 20\% 回撤熔断与黄金集中度上限",
        ],
        disclaimer="本文件基于历史回测，不构成投资建议。外汇及差价合约交易存在高风险，可能损失全部本金。",
        equity_ylabel="净值 (USD)",
        equity_combined_title="UnitedEA 19策略组合净值 (2023.07–2026.06)",
        caption_pf_net_sharpe=("PF", "净盈利", "夏普"),
        flowcharts=FLOW_ZH,
    ),
    "de": Locale(
        code="de",
        tex_stem="managed_account_brochure_de",
        pdf_name="ManagedAccount_Brochure_DE.pdf",
        preamble=[
            r"\documentclass[11pt,a4paper]{article}",
            r"\usepackage{fontspec}",
            r"\usepackage{polyglossia}",
            r"\setdefaultlanguage{german}",
            r"\setmainfont{TeX Gyre Termes}",
        ] + _COMMON_PKGS,
        title=r"UnitedEA Multi-Strategie-Cluster\\Verm\"ogensverwaltung · Performance \& Logik",
        author=r"Namelos.xyz Research · MetaTrader\,5 Strategietester",
        abstract_tpl=(
            r"Dieser Bericht basiert auf lokalen MT5-Backtests (07/2023--06/2026, Startkapital \${deposit:,.0f}, "
            r"Hebel 1:1000, skalierte Lots). Er zeigt Eigenkapitalkurven von 19 Produktions-Substrategien und dem Portfolio. "
            r"In drei Jahren erzielten \textbf{{{n_prof}/19}} Strategien positiven Nettogewinn, \textbf{{{n_pf1}/19}} haben Profit Factor $\geq 1$. "
            r"Vergangene Ergebnisse garantieren keine zuk\"unftigen Renditen."
        ),
        s1_title="Produkt\"ubersicht",
        s1_body="UnitedEA ist ein Multi-Strategie-Expert-Advisor-Cluster auf MetaTrader\\,5. "
        "19 unabh\"angig optimierte, wenig korrelierte Roboter laufen parallel auf einem Konto zur Risikostreuung.",
        s1_1_title="Service-Modell (Verm\"ogensverwaltung)",
        s1_1_items=[
            r"\textbf{Vollautomatisch}: Signale werden ohne manuelles Eingreifen ausgef\"uhrt",
            r"\textbf{Portfolio-Risiko}: Einheitliches Kapitalmanagement, dynamische Lots (Referenz \$3.000)",
            r"\textbf{Regelm\"a\ssige Audits}: Lot-Optimierung, A/B-Tests f\"ur Signal-Ersetzung",
            r"\textbf{Empfohlenes Startkapital}: mindestens \$3.000",
        ],
        s1_2_title="Backtest-Einstellungen",
        table_headers=("Parameter", "Wert"),
        table_rows=[
            ("Zeitraum", "2023.07.01 -- 2026.06.01"),
            ("Startkapital", r"\$3.000"),
            ("Hebel", "1:1000"),
            ("Modell", "1-Minuten-OHLC"),
            ("Portfolio-Symbol", "NAS100 H1"),
            ("Datenquelle", "Lokales MT5-Terminal"),
        ],
        s2_title="Portfolio-Eigenkapitalkurve",
        s2_body_tpl="Kombinierte Eigenkapitalkurve von 19 Strategien (logarithmische Skala). "
        "Profit Factor \\textbf{{{pf}}}, Sharpe \\textbf{{{sharpe}}}, Trades \\textbf{{{trades}}}.",
        s2_caption="UnitedEA 19-Strategien-Portfolio (07/2023--06/2026)",
        s3_title="Einzelne Roboter-Eigenkapitalkurven",
        s3_body="Jede Substrategie einzeln aktiviert, optimierte Lots, drei Jahre Backtest. "
        "Start bei \\$3.000; gestrichelte Linie = Referenz. "
        "\\textbf{Alle 19 Roboter mit positivem Nettogewinn.}",
        s4_title="Leistungs\"ubersicht",
        s4_caption="Drei-Jahres-Solo-Backtests der 19 Strategien",
        table_cols="Code & Strategie & Symbol & PF & Netto (\$) & Sharpe & Trades",
        s5_title="Logik-Flowcharts",
        s5_body="Kernentscheidungslogik jeder Substrategie (entspricht \\texttt{Strategies/}-Quellcode).",
        close_note=r"\noindent\textit{Hinweis: Verlustschlie\ssung bei Gegensignal ist aktiviert.}",
        s6_title="Geplante Anpassungen",
        s6_items=[
            r"\textbf{Lots}: Genetische Optimierung abgeschlossen; US30 auf 0{,}02 reduziert",
            r"\textbf{Signal-Close}: nur ES, RS\_XAUUSD, RS\_US30 aktiv",
            r"\textbf{Beobachtung}: SE (niedriger PF); Asian AUD/GBP minimale Lots",
            r"\textbf{Risiko}: Portfolio-Drawdown-Circuit-Breaker 20\% geplant",
        ],
        disclaimer="Historische Backtests, keine Anlageberatung. Forex/CFD mit hohem Verlustrisiko.",
        equity_ylabel="Eigenkapital (USD)",
        equity_combined_title="UnitedEA 19-Strategien Portfolio (2023.07--2026.06)",
        caption_pf_net_sharpe=("PF", "Netto", "Sharpe"),
        flowcharts=FLOW_DE,
    ),
    "ar": Locale(
        code="ar",
        tex_stem="managed_account_brochure_ar",
        pdf_name="ManagedAccount_Brochure_AR.pdf",
        preamble=[
            r"\documentclass[11pt,a4paper]{article}",
            r"\usepackage{fontspec}",
            r"\usepackage{polyglossia}",
            r"\setdefaultlanguage{arabic}",
            r"\setotherlanguage{english}",
            r"\newfontfamily\arabicfont[Script=Arabic]{Arial}",
            r"\newfontfamily\arabicfontsf[Script=Arabic]{Arial}",
        ] + _COMMON_PKGS,
        title=r"مجموعة UnitedEA للتداول الآلي\\إدارة محافظ · الأداء ومنطق الاستراتيجيات",
        author=r"Namelos.xyz Research · اختبار MT5",
        abstract_tpl=(
            r"يعتمد هذا التقرير على اختبار MT5 المحلي (07/2023--06/2026، رأس مال \${deposit:,.0f}، "
            r"رافعة 1:1000، تحجيم اللوت). يعرض منحنيات 19 استراتيجية فرعية والمحفظة المجمّعة. "
            r"خلال ثلاث سنوات، \textbf{{{n_prof}/19}} استراتيجية بربح صافٍ موجب، \textbf{{{n_pf1}/19}} بعامل ربح $\geq 1$. "
            r"الأداء السابق لا يضمن النتائج المستقبلية."
        ),
        s1_title="نظرة على المنتج",
        s1_body="UnitedEA هو عنقود مستشار خبير متعدد الاستراتيجيات على MetaTrader\\,5. "
        "يعمل 19 روبوتاً محسّناً ومستقلاً بالتوازي لتوزيع المخاطر عبر الأصول.",
        s1_1_title="نموذج الخدمة (إدارة المحافظ)",
        s1_1_items=[
            r"\textbf{تنفيذ آلي كامل}: إشارات تُنفَّذ دون تدخل يدوي",
            r"\textbf{مخاطر المحفظة}: إدارة موحّدة للرأسمال، تحجيم ديناميكي للوت (مرجع 3{,}000\$)",
            r"\textbf{تدقيق دوري}: تحسين اللوت، اختبارات A/B لإشارات الإغلاق",
            r"\textbf{رأس مال مقترح}: 3{,}000\$ كحد أدنى",
        ],
        s1_2_title="إعدادات الاختبار",
        table_headers=("البند", "القيمة"),
        table_rows=[
            ("الفترة", "2023.07.01 -- 2026.06.01"),
            ("رأس المال", r"\$3.000"),
            ("الرافعة", "1:1000"),
            ("النموذج", "OHLC دقيقة واحدة"),
            ("رمز المحفظة", "NAS100 H1"),
            ("مصدر البيانات", "مجلد بيانات MT5 المحلي"),
        ],
        s2_title="منحنى محفظة مجمّعة",
        s2_body_tpl="منحنى رأس المال لـ 19 استراتيجية (مقياس لوغاريتمي). "
        "عامل الربح \\textbf{{{pf}}}، شارب \\textbf{{{sharpe}}}، الصفقات \\textbf{{{trades}}}.",
        s2_caption="محفظة UnitedEA — 19 استراتيجية (07/2023--06/2026)",
        s3_title="منحنيات الروبوتات المنفردة",
        s3_body="كل استراتيجية فرعية مفعّلة منفردة، لوت محسّن، اختبار ثلاث سنوات. "
        "البداية من 3{,}000\$؛ الخط المتقطع = مرجع. "
        "\\textbf{الـ 19 روبوتاً جميعها بربح صافٍ موجب.}",
        s4_title="ملخص الأداء",
        s4_caption="اختبارات منفردة لثلاث سنوات — 19 استراتيجية",
        table_cols="الرمز & الاستراتيجية & الأصل & PF & صافي (\$) & شارب & صفقات",
        s5_title="مخططات منطق الاستراتيجيات",
        s5_body="ملخص مسار القرار لكل استراتيجية. المخططات بالإنجليزية لضمان عرض صحيح في TikZ.",
        close_note=r"\noindent\textbf{ملاحظة:} إغلاق الخسارة عند إشارة عكسية مفعّل لهذه الاستراتيجية.",
        s6_title="التعديلات المخططة",
        s6_items=[
            r"\textbf{اللوت}: تحسين وراثي؛ US30 خُفّض إلى 0{,}02",
            r"\textbf{إغلاق الإشارة}: ES و RS\_XAUUSD و RS\_US30 فقط",
            r"\textbf{مراقبة}: SE (PF منخفض); Asian AUD/GBP أقل لوت",
            r"\textbf{مخاطر}: قاطع سحب 20\% على مستوى المحفظة",
        ],
        disclaimer="اختبار تاريخي وليس نصيحة استثمارية. تداول الفوركس والعقود عالي المخاطر.",
        equity_ylabel="رأس المال (USD)",
        equity_combined_title="UnitedEA 19 استراتيجية (2023.07--2026.06)",
        caption_pf_net_sharpe=("PF", "صافي", "شارب"),
        flowcharts=FLOW_EN,
        rtl=True,
    ),
}

FLOW_KEY = {
    "RS_NVDA": "RS_SCALP", "RS_TSLA": "RS_SCALP", "RS_BTCUSD": "RS_SCALP",
    "RS_XAUUSD": "RS_SCALP", "RS_NAS100": "RS_SCALP", "RS_US30": "RS_SCALP",
    "ST_BTC": "ST", "ST_XAU": "ST",
    "RRA_AUD": "RRA", "RRA_GBP": "RRA",
    "UB": "BUSTER", "GB": "BUSTER", "U5B": "BUSTER", "UKB": "BUSTER",
}


def flowchart_for(sid: str, loc: Locale) -> str:
    key = FLOW_KEY.get(sid, sid)
    return loc.flowcharts.get(key, loc.flowcharts.get(sid, r"\textit{---}"))
