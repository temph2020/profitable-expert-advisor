"""United EA sub-strategy manifest for MT5 solo audits (123.set)."""

from __future__ import annotations

UNITED_MT5_STRATEGIES: list[dict] = [
    {"id": "DB", "name": "DarvasBox", "enable": "EnableDarvasBox", "close": "DB_CloseUnprofitableOnNewSignal", "lot": "LOT_DB_DarvasBox"},
    {"id": "ES", "name": "EMASlopeDistance", "enable": "EnableEMASlopeDistance", "close": "ES_CloseUnprofitableOnNewSignal", "lot": "LOT_ES_EMASlopeDistance"},
    {"id": "RC", "name": "RSICrossOverReversal", "enable": "EnableRSICrossOverReversal", "close": "RC_CloseUnprofitableOnNewSignal", "lot": "LOT_RC_RSICrossOver"},
    {"id": "RM", "name": "RSIMidPointHijack", "enable": "EnableRSIMidPointHijack", "close": "RM_CloseUnprofitableOnNewSignal", "lot": "LOT_RM_RSIMidPointHijack"},
    {"id": "RS_APPL", "name": "RSIScalping APPL", "enable": "EnableRSIScalpingAPPL", "close": "RS_APPL_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_APPL", "test_symbol": "AAPL.NAS", "lot_class": "stock"},
    {"id": "RS_ADBE", "name": "RSIScalping ADBE", "enable": "EnableRSIScalpingADBE", "close": "RS_ADBE_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_ADBE", "test_symbol": "ADBE.NAS", "lot_class": "stock"},
    {"id": "RS_BTCUSD", "name": "RSIScalping BTCUSD", "enable": "EnableRSIScalpingBTCUSD", "close": "RS_BTCUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_BTCUSD"},
    {"id": "RS_NVDA", "name": "RSIScalping NVDA", "enable": "EnableRSIScalpingNVDA", "close": "RS_NVDA_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_NVDA", "test_symbol": "NVDA.NAS", "lot_class": "stock"},
    {"id": "RS_TSLA", "name": "RSIScalping TSLA", "enable": "EnableRSIScalpingTSLA", "close": "RS_TSLA_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_TSLA", "test_symbol": "TSLA.NAS", "lot_class": "stock"},
    {"id": "RS_XAUUSD", "name": "RSIScalping XAUUSD", "enable": "EnableRSIScalpingXAUUSD", "close": "RS_XAUUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_XAUUSD"},
    {"id": "RS_MU", "name": "RSIScalping MU", "enable": "EnableRSIScalpingMU", "close": "RS_MU_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_MU"},
    {"id": "SE", "name": "SuperEMA", "enable": "EnableSuperEMA", "close": "SE_CloseUnprofitableOnNewSignal", "lot": "LOT_SE_SuperEMA"},
    {"id": "RCO", "name": "RSIConsolidation", "enable": "EnableRSIConsolidation", "close": "RCO_CloseUnprofitableOnNewSignal", "lot": "LOT_RCO_RSIConsolidation"},
    {"id": "RRA_EUR", "name": "RSI Asian EURUSD", "enable": "EnableRSIReversalAsianEURUSD", "close": "RRA_EURUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RRA_EURUSD"},
    {"id": "RRA_AUD", "name": "RSI Asian AUDUSD", "enable": "EnableRSIReversalAsianAUDUSD", "close": "RRA_AUDUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RRA_AUDUSD"},
    {"id": "ST_BTC", "name": "SimpleTrendline BTC", "enable": "EnableSimpleTrendlineBTCUSD", "close": "ST_BTC_CloseUnprofitableOnNewSignal", "lot": "LOT_ST_BTCUSD"},
    {"id": "ST_XAU", "name": "SimpleTrendline XAU", "enable": "EnableSimpleTrendlineXAUUSD", "close": "ST_XAU_CloseUnprofitableOnNewSignal", "lot": "LOT_ST_XAUUSD"},
    {"id": "ST_GER", "name": "SimpleTrendline GER40", "enable": "EnableSimpleTrendlineGER40", "close": "ST_GER_CloseUnprofitableOnNewSignal", "lot": "LOT_ST_GER40"},
    {"id": "RSS", "name": "RSISecretSauce", "enable": "EnableRSISecretSauce", "close": "RSS_CloseUnprofitableOnNewSignal", "lot": "LOT_RSS_SecretSauce"},
    {"id": "UB", "name": "USDJPYBuster", "enable": "EnableUSDJPYBuster", "close": "UB_CloseUnprofitableOnNewSignal", "lot": "LOT_UB_USDJPY"},
    {"id": "XBT", "name": "XAUBearTrend", "enable": "EnableXAUBearTrend", "close": "XBT_CloseUnprofitableOnNewSignal", "lot": "LOT_XBT_XAUUSD"},
    {"id": "XMB", "name": "XAUMomentumBreakdown", "enable": "EnableXAUMomentumBreakdown", "close": "XMB_CloseUnprofitableOnNewSignal", "lot": "LOT_XMB_XAUUSD"},
    {"id": "RRA_GBP", "name": "RSI Asian GBPUSD", "enable": "EnableRSIReversalAsianGBPUSD", "close": "RRA_GBPUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RRA_GBPUSD"},
    {"id": "GB", "name": "GER40Buster", "enable": "EnableGER40Buster", "close": "GB_CloseUnprofitableOnNewSignal", "lot": "LOT_GB_GER40"},
    {"id": "RS_NAS100", "name": "RSIScalping NAS100", "enable": "EnableRSIScalpingNAS100", "close": "RS_NAS100_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_NAS100"},
    {"id": "RS_US500", "name": "RSIScalping US500", "enable": "EnableRSIScalpingUS500", "close": "RS_US500_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_US500"},
    {"id": "RRA_USDCHF", "name": "RSI Asian USDCHF", "enable": "EnableRSIReversalAsianUSDCHF", "close": "RRA_USDCHF_CloseUnprofitableOnNewSignal", "lot": "LOT_RRA_USDCHF"},
    {"id": "RRA_NZDUSD", "name": "RSI Asian NZDUSD", "enable": "EnableRSIReversalAsianNZDUSD", "close": "RRA_NZDUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RRA_NZDUSD"},
    {"id": "NB", "name": "NAS100Buster", "enable": "EnableNAS100Buster", "close": "NB_CloseUnprofitableOnNewSignal", "lot": "LOT_NB_NAS100"},
    {"id": "U5B", "name": "US500Buster", "enable": "EnableUS500Buster", "close": "U5B_CloseUnprofitableOnNewSignal", "lot": "LOT_U5B_US500"},
    {"id": "RS_US30", "name": "RSIScalping US30", "enable": "EnableRSIScalpingUS30", "close": "RS_US30_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_US30"},
    {"id": "RS_XAGUSD", "name": "RSIScalping XAGUSD", "enable": "EnableRSIScalpingXAGUSD", "close": "RS_XAGUSD_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_XAGUSD"},
    {"id": "RS_EURJPY", "name": "RSIScalping EURJPY", "enable": "EnableRSIScalpingEURJPY", "close": "RS_EURJPY_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_EURJPY"},
    {"id": "RS_GBPJPY", "name": "RSIScalping GBPJPY", "enable": "EnableRSIScalpingGBPJPY", "close": "RS_GBPJPY_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_GBPJPY"},
    {"id": "U30B", "name": "US30Buster", "enable": "EnableUS30Buster", "close": "U30B_CloseUnprofitableOnNewSignal", "lot": "LOT_U30B_US30"},
    {"id": "UKB", "name": "UK100Buster", "enable": "EnableUK100Buster", "close": "UKB_CloseUnprofitableOnNewSignal", "lot": "LOT_UKB_UK100"},
    {"id": "XGB", "name": "XAGUSDBuster", "enable": "EnableXAGUSDBuster", "close": "XGB_CloseUnprofitableOnNewSignal", "lot": "LOT_XGB_XAGUSD"},
    {"id": "RS_F", "name": "RSIScalping F", "enable": "EnableRSIScalpingF", "close": "RS_F_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_F", "test_symbol": "F.NYS"},
    {"id": "RS_SOFI", "name": "RSIScalping SOFI", "enable": "EnableRSIScalpingSOFI", "close": "RS_SOFI_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_SOFI", "test_symbol": "SOFI.NAS"},
    {"id": "RS_SNAP", "name": "RSIScalping SNAP", "enable": "EnableRSIScalpingSNAP", "close": "RS_SNAP_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_SNAP", "test_symbol": "SNAP.NYS"},
    {"id": "RS_WBD", "name": "RSIScalping WBD", "enable": "EnableRSIScalpingWBD", "close": "RS_WBD_CloseUnprofitableOnNewSignal", "lot": "LOT_RS_WBD", "test_symbol": "WBD.NAS"},
]

ALL_ENABLE_KEYS = [s["enable"] for s in UNITED_MT5_STRATEGIES]

# Round-1 expansion (retired except survivor).
EXPANSION_RETIRED_IDS = (
    "XBT", "XMB", "RRA_GBP", "GB", "RS_US500", "RRA_USDCHF", "RRA_NZDUSD", "NB", "U5B",
)

# Survivor kept on baseline + enhanced.
SURVIVOR_IDS = ("RS_NAS100", "RS_US30", "UKB")

# Round-2 candidates (audited; non-survivors stay off).
ROUND2_IDS = (
    "RS_US30", "RS_XAGUSD", "RS_EURJPY", "RS_GBPJPY", "U30B", "UKB", "XGB",
)

# Round-3 low-margin stock candidates (~$1–2 margin per share @ 5% leverage).
ROUND3_IDS = ("RS_F", "RS_SOFI", "RS_SNAP", "RS_WBD")

# High share-price stocks — force off in expansion audits (margin call risk).
HIGH_MARGIN_STOCK_ENABLES = ("EnableRSIScalpingMU",)

# Production cluster (matches main.mq5 defaults).
PRODUCTION_IDS: tuple[str, ...] = (
    "DB", "ES", "RC", "RM",
    "RS_NVDA", "RS_TSLA",
    "RS_BTCUSD", "RS_XAUUSD", "SE", "ST_BTC", "ST_XAU",
    "RRA_AUD", "RRA_GBP", "UB",
    "RS_NAS100", "RS_US30", "UKB", "GB", "U5B",
)

LOT_GRIDS: dict[str, list[float]] = {
    "stock": [5.0, 10.0, 15.0],
    "index": [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1],
    "forex": [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1],
    "gold": [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1],
    "crypto": [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1],
}

LOT_GENETIC_RANGE: dict[str, tuple[float, float, float]] = {
    "stock": (5.0, 5.0, 15.0),
    "default": (0.01, 0.01, 0.1),
}

LOT_CLASS_BY_ID: dict[str, str] = {
    "DB": "gold", "ES": "gold", "RC": "gold", "RM": "gold",
    "RS_XAUUSD": "gold", "ST_XAU": "gold", "XBT": "gold", "XMB": "gold", "XGB": "gold",
    "RS_APPL": "stock", "RS_ADBE": "stock", "RS_NVDA": "stock", "RS_TSLA": "stock", "RS_MU": "stock",
    "RS_F": "stock", "RS_SOFI": "stock", "RS_SNAP": "stock", "RS_WBD": "stock",
    "RS_NAS100": "index", "RS_US500": "index", "RS_US30": "index", "UKB": "index",
    "NB": "index", "U5B": "index", "U30B": "index", "GB": "index",
    "RRA_EUR": "forex", "RRA_AUD": "forex", "RRA_GBP": "forex", "RRA_USDCHF": "forex", "RRA_NZDUSD": "forex",
    "UB": "forex", "RS_EURJPY": "forex", "RS_GBPJPY": "forex",
    "RS_BTCUSD": "crypto", "ST_BTC": "crypto",
    "ST_GER": "index", "RS_XAGUSD": "gold",
}

PARAM_TWEAKS: dict[str, list[dict]] = {
    "ES": [{"ES_TrailingStop": 250}, {"ES_TrailingStop": 300, "ES_ProfitCheckBars": 12}],
    "RC": [{"RC_cooldownSeconds": 120}, {"RC_TrailingStop": 250}],
    "RS_NVDA": [{"RS_NVDA_BarsToWait": 3}, {"RS_NVDA_TrailDistancePoints": 300}],
    "RS_TSLA": [{"RS_TSLA_BarsToWait": 2}, {"RS_TSLA_TrailActivationPoints": 500}],
    "RCO": [{"RCO_ADX_Max": 32}, {"RCO_SL_ATR_Mult": 1.9}],
    "UB": [{"UB_MinRangePoints": 12}, {"UB_OrderBufferPoints": 3.5}],
}
