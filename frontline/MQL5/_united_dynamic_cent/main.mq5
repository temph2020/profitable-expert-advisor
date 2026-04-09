//+------------------------------------------------------------------+
//|                                                    UnitedEA.mq5 |
//|  Cent ".c" symbols; InpDynamicRefDeposit MUST match ACCOUNT_     |
//|  CURRENCY numbers (USC ~50k for ~$500, or USD ~500 — not mixed). |
//|  Per-order max lots = broker spec 最大量 SYMBOL_VOLUME_MAX       |
//|  (often 1000 on *.c); EA cannot exceed it — see symbol contract. |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Volumes.mqh>
#include "MagicNumberHelpers.mqh"

// Lot globals must exist before strategy .mqh (Darvas uses g_DB_LotSize; EMA/RC/RM use g_ES/g_RC/g_RM)
double g_ES_LotSize;
double g_RC_LotSize;
double g_RM_LotSize;
double g_DB_LotSize;
double g_DynLotScaleLast = 1.0;   // last applied scale: lots = baseLot * scale * InpLotSizeScale
double g_DynamicRefBaseline = 0.0;   // when InpDynamicRefDeposit<=0, frozen ref = equity at first sizing call

// Include strategy implementations early so structs are available
#include "Strategies/DarvasBoxStrategy.mqh"
#include "Strategies/EMASlopeDistanceStrategy.mqh"
#include "Strategies/RSICrossOverReversalStrategy.mqh"
#include "Strategies/RSIMidPointHijackStrategy.mqh"
#include "Strategies/RSIScalpingStrategy.mqh"
#include "Strategies/RSIReversalAsianStrategy.mqh"

//+------------------------------------------------------------------+
//| Strategy Enable/Disable Switches                                 |
//+------------------------------------------------------------------+
input group "=== Strategy Enable/Disable ==="
input bool EnableDarvasBox = true;
input bool EnableEMASlopeDistance = true;
input bool EnableRSICrossOverReversal = true;
input bool EnableRSIMidPointHijack = true;
input bool EnableRSIScalpingAPPL = true;
input bool EnableRSIScalpingBTCUSD = true;
input bool EnableRSIScalpingNVDA = true;
input bool EnableRSIScalpingTSLA = true;
input bool EnableRSIScalpingXAUUSD = true;
input bool EnableRSIReversalAsianEURUSD = true;
input bool EnableRSIReversalAsianAUDUSD = true;

//+------------------------------------------------------------------+
//| Dynamic lot sizing — 默认「按比例」：lots = base × (equity/ref) × lotScale |
//| 可选幂曲线：lots = base × (equity/ref)^exp × lotScale（旧行为）          |
//| min/max 约束的是「比例系数」不是手数本身；max<=0 表示比例系数上不封顶      |
//|                                                                   |
//| USC (deposit currency) vs "lot size":                             |
//| • Equity/ref for the multiplier are BOTH in account currency      |
//|   (USC). Same units → ratio is correct; no ×100 on the ratio.     |
//| • Strategy base lots (e.g. DB_BaseLotSize) are ORDER VOLUME in    |
//|   lots, not "USC lots". Broker SYMBOL_VOLUME_* / contract define  |
//|   how much margin and P/L appear in USC.                         |
//| • Do not multiply lot inputs by 100 only because balance is USC.   |
//| If DD too high: raise InpDynamicRefDeposit and/or lower base lots.|
//| If balance is USD ~500 but ref is ~50k–300k: mult→floor, lots→0.01.|
//| Ref<=0: 挂上时余额/净值为参考，之后手数随净值相对该基准的比例变化。   |
//| 单笔上限：品种规格里的「最大量」(SYMBOL_VOLUME_MAX)，非 EA 参数。   |
//| InpMaxLotsPerOrder：EA 再截一刀，防止动态+scale 顶满 1000 爆仓。   |
//+------------------------------------------------------------------+
enum ENUM_LOT_SCALE_CURVE
{
   LOT_CURVE_PROPORTIONAL = 0,  // 按比例：scale = 净值/参考（线性）
   LOT_CURVE_POWER        = 1   // 幂：scale = (净值/参考)^exp
};

input group "=== Dynamic lot sizing (动态手数) ==="
input bool   InpDynamicLotEnable = true;           // Enable balance/equity-based scaling
input ENUM_LOT_SCALE_CURVE InpDynamicLotCurve = LOT_CURVE_PROPORTIONAL; // 默认按比例；幂曲线=旧 (equity/ref)^exp
input double InpDynamicRefDeposit = 0.0;          // <=0: auto — ref=挂上时净值/余额(与测试器初始一致则手数随盈利涨); >0 手动参考金
input bool   InpDynamicRefEqualsEquity = false;     // true: 比例系数固定为 1（只用基础手×lotScale）
input double InpDynamicExponent = 1.22;             // 仅 LOT_CURVE_POWER 时：(净值/参考) 的指数
input double InpDynamicMinMult = 0.0;               // 比例系数下限；<=0 不抬（按比例时净值<参考会缩小手数）
input double InpDynamicMaxMult = 20.0;               // 比例系数上限；<=0 不封顶(高风险)
input bool   InpDynamicUseEquity = true;            // true=ACCOUNT_EQUITY, false=ACCOUNT_BALANCE
input double InpDynamicStockLotCap = 0.0;            // Max lots after scale (0=off); raise if InpLotSizeScale is large
input double InpLotSizeScale = 1.0;                  // 全局手数倍率; 曾用100易过大，默认1按需再加
input double InpMaxLotsPerOrder = 20.0;              // 单笔最大手数(0=仅券商SYMBOL_VOLUME_MAX); 保守可设5~10

//+------------------------------------------------------------------+
//| Strategy 1: DarvasBoxXAUUSD (cent symbol)                        |
//+------------------------------------------------------------------+
input group "=== DarvasBox Strategy ==="
input string DB_Symbol = "XAUUSD.c";
input int    DB_BoxPeriod = 165;
input double DB_BoxDeviation = 30000;  // Increased to allow larger ranges (was 25140)
input int    DB_VolumeThreshold = 0;  // Set to 0 to disable volume threshold check. Volume data from indicator used instead.
input double DB_StopLoss = 1665;
input double DB_TakeProfit = 3685;
input bool   DB_EnableLogging = false;
input color  DB_BoxColor = clrBlue;
input int    DB_BoxWidth = 1;
input ENUM_TIMEFRAMES DB_TrendTimeframe = PERIOD_H2;
input int    DB_MA_Period = 125;
input ENUM_MA_METHOD DB_MA_Method = MODE_EMA;
input ENUM_APPLIED_PRICE DB_MA_Price = PRICE_WEIGHTED;
input double DB_TrendThreshold = 4.94;
input int    DB_VolumeMA_Period = 110;
input double DB_VolumeThresholdMultiplier = 1.5;
input int    DB_MagicNumber = 135790;
input double DB_BaseLotSize = 0.02;                 // Base lot at InpDynamicRefDeposit (Darvas)

//+------------------------------------------------------------------+
//| Strategy 2: EMASlopeDistanceCocktailXAUUSD                     |
//| Cent: gold is usually "XAUUSD.c" (verify in Market Watch).      |
//+------------------------------------------------------------------+
input group "=== EMA Slope Distance Strategy ==="
input string ES_Symbol = "XAUUSD.c";
input int    ES_EMA_Periode = 46;
input double ES_PreisSchwelle = 600.0;
input double ES_SteigungSchwelle = 80.0;
input int    ES_ÜberwachungTimeout = 800;
input double ES_TrailingStop = 250.0;
input double ES_LotGröße = 0.05;
input int    ES_MagicNumber = 12350;
input bool   ES_UseSpreadAdjustment = true;
input ENUM_TIMEFRAMES ES_Timeframe = PERIOD_H1;
input bool   ES_UseBarData = true;
input int    ES_MaxTradesPerCrossover = 9;
input int    ES_ProfitCheckBars = 18;
input bool   ES_CloseUnprofitableTrades = true;

//+------------------------------------------------------------------+
//| Strategy 3: RSICrossOverReversalXAUUSD                          |
//| Cent: use "XAUUSD.c" if that is what the broker lists.           |
//+------------------------------------------------------------------+
input group "=== RSI CrossOver Reversal Strategy ==="
input string RC_Symbol = "XAUUSD.c";
input int    RC_MagicNumber = 7;
input int    RC_rsiPeriod = 19;
input int    RC_overboughtLevel = 93;
input int    RC_oversoldLevel = 22;
input double RC_entryRSIBuySpread = 0;
input double RC_entryRSISellSpread = 0;
input double RC_lotSize = 0.02;
input int    RC_slippage = 3;
input int    RC_cooldownSeconds = 209;
input ENUM_TIMEFRAMES RC_TimeFrame1 = PERIOD_M1;
input ENUM_TIMEFRAMES RC_TimeFrame2 = PERIOD_M1;
input ENUM_TIMEFRAMES RC_BarTimeFrame = PERIOD_M12;
input int    RC_emaPeriod = 140;
input double RC_emaSlopeThreshold = 105;
input double RC_exitBuyRSI = 86;
input double RC_exitSellRSI = 10;
input double RC_TrailingStop = 295;
input double RC_emaDistanceThreshold = 165;
input int    RC_tradingHourOneBegin = 24;
input int    RC_tradingHourOneEnd = 22;
input int    RC_tradingHourTwoBegin = 6;
input int    RC_tradingHourTwoEnd = 19;
input bool   RC_Sunday = false;
input bool   RC_Monday = false;
input bool   RC_Tuesday = true;
input bool   RC_Wednesday = true;
input bool   RC_Thursday = true;
input bool   RC_Friday = false;
input bool   RC_Saturday = false;

//+------------------------------------------------------------------+
//| Strategy 4: RSIMidPointHijackXAUUSD                              |
//| Cent: use "XAUUSD.c" if that is what the broker lists.           |
//+------------------------------------------------------------------+
input group "=== RSI MidPoint Hijack Strategy ==="
input string RM_Symbol = "XAUUSD.c";
input ENUM_TIMEFRAMES RM_InpTimeframe = PERIOD_H1;
input double RM_InpLotSize = 0.03;
input int    RM_InpMagicNumberRSIFollow = 1001;
input int    RM_InpMagicNumberRSIReverse = 1002;
input int    RM_InpMagicNumberEMACross = 1003;
input bool   RM_InpEnableRSIFollow = true;
input bool   RM_InpEnableRSIReverse = true;
input bool   RM_InpEnableEMACross = true;
input bool   RM_InpEnableStrategyLock = false;
input double RM_InpLockProfitThreshold = 0.0;
input bool   RM_InpCloseOppositeTrades = false;
input int    RM_InpRSIPeriod = 32;
input int    RM_InpRSIOverbought = 78;
input int    RM_InpRSIOversold = 46;
input int    RM_InpRSIExitLevel = 44;
input int    RM_InpRSIFollowStartHour = 23;
input int    RM_InpRSIFollowEndHour = 8;
input bool   RM_InpRSIFollowCloseOutsideHours = false;
input int    RM_InpRSIReversePeriod = 59;
input int    RM_InpRSIReverseOverbought = 51;
input int    RM_InpRSIReverseOversold = 49;
input int    RM_InpRSIReverseCrossLevel = 53;
input int    RM_InpRSIReverseExitLevel = 48;
input int    RM_InpRSIReverseStartHour = 7;
input int    RM_InpRSIReverseEndHour = 13;
input bool   RM_InpRSIReverseCloseOutsideHours = false;
input int    RM_InpRSIReverseCooldownBars = 15;
input bool   RM_InpRSIReverseCooldownOnLoss = true;
input int    RM_InpEMAPeriod = 120;
input int    RM_InpEMACrossStartHour = 8;
input int    RM_InpEMACrossEndHour = 14;
input bool   RM_InpEMACrossCloseOutsideHours = true;
input bool   RM_InpUseEMADistanceEntry = true;
input double RM_InpEMADistancePips = 160.0;
input int    RM_InpEMADistancePeriod = 26;

//+------------------------------------------------------------------+
//| Strategy 5-10: RSI Scalping Strategies                           |
//| Each RSI Scalping strategy trades on its own symbol:             |
//| - APPL: Apple stock (AAPL)                                       |
//| - BTCUSD: Bitcoin/USD                                            |
//| - NVDA: NVIDIA stock                                              |
//| - TSLA: Tesla stock                                               |
//| - XAUUSD: Gold/USD                                                |
//|                                                                   |
//| USC cent: many symbols end with ".c" — use Market Watch names.   |
//| Stocks may be "AAPL.US.c" or unchanged; verify before live.      |
//+------------------------------------------------------------------+
input group "=== RSI Scalping APPL (AAPL) - cent ==="
input string RS_APPL_Symbol = "AAPL.US.c";  // If missing, try AAPL.US / NASDAQ:AAPL / AAPL
input ENUM_TIMEFRAMES RS_APPL_TimeFrame = PERIOD_M10;
input int    RS_APPL_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_APPL_RSI_Applied_Price = PRICE_CLOSE;
input double RS_APPL_RSI_Overbought = 80;
input double RS_APPL_RSI_Oversold = 78;
input double RS_APPL_RSI_Target_Buy = 94;
input double RS_APPL_RSI_Target_Sell = 44;
input int    RS_APPL_BarsToWait = 7;
input double RS_APPL_LotSize = 38;
input int    RS_APPL_MagicNumber = 20001;
input int    RS_APPL_Slippage = 3;

input group "=== RSI Scalping BTCUSD ==="
input string RS_BTCUSD_Symbol = "BTCUSD.c";  // If missing, try BTCUSD or BTC/USD
input ENUM_TIMEFRAMES RS_BTCUSD_TimeFrame = PERIOD_H1;
input int    RS_BTCUSD_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_BTCUSD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_BTCUSD_RSI_Overbought = 90;
input double RS_BTCUSD_RSI_Oversold = 73;
input double RS_BTCUSD_RSI_Target_Buy = 88;
input double RS_BTCUSD_RSI_Target_Sell = 48;
input int    RS_BTCUSD_BarsToWait = 6;
input double RS_BTCUSD_LotSize = 0.15;
input int    RS_BTCUSD_MagicNumber = 123459123;
input int    RS_BTCUSD_Slippage = 3;

input group "=== RSI Scalping NVDA - cent ==="
input string RS_NVDA_Symbol = "NVDA.US.c";  // If missing, try NVDA.US / NASDAQ:NVDA / NVDA
input ENUM_TIMEFRAMES RS_NVDA_TimeFrame = PERIOD_M15;
input int    RS_NVDA_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_NVDA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_NVDA_RSI_Overbought = 36;
input double RS_NVDA_RSI_Oversold = 38;
input double RS_NVDA_RSI_Target_Buy = 90;
input double RS_NVDA_RSI_Target_Sell = 70;
input int    RS_NVDA_BarsToWait = 5;
input double RS_NVDA_LotSize = 75;
input int    RS_NVDA_MagicNumber = 20003;
input int    RS_NVDA_Slippage = 3;

input group "=== RSI Scalping TSLA - cent ==="
input string RS_TSLA_Symbol = "TSLA.US.c";  // If missing, try TSLA.US / NASDAQ:TSLA / TSLA
input ENUM_TIMEFRAMES RS_TSLA_TimeFrame = PERIOD_H1;
input int    RS_TSLA_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_TSLA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_TSLA_RSI_Overbought = 54;
input double RS_TSLA_RSI_Oversold = 73;
input double RS_TSLA_RSI_Target_Buy = 87;
input double RS_TSLA_RSI_Target_Sell = 33;
input int    RS_TSLA_BarsToWait = 1;
input double RS_TSLA_LotSize = 75;
input int    RS_TSLA_MagicNumber = 125421321;
input int    RS_TSLA_Slippage = 3;

input group "=== RSI Scalping XAUUSD ==="
input string RS_XAUUSD_Symbol = "XAUUSD.c";
input ENUM_TIMEFRAMES RS_XAUUSD_TimeFrame = PERIOD_H1;
input int    RS_XAUUSD_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_XAUUSD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_XAUUSD_RSI_Overbought = 71;
input double RS_XAUUSD_RSI_Oversold = 57;
input double RS_XAUUSD_RSI_Target_Buy = 80;
input double RS_XAUUSD_RSI_Target_Sell = 57;
input int    RS_XAUUSD_BarsToWait = 4;
input double RS_XAUUSD_LotSize = 0.15;
input int    RS_XAUUSD_MagicNumber = 129102315;
input int    RS_XAUUSD_Slippage = 3;

//+------------------------------------------------------------------+
//| Strategy 11-12: RSI Reversal Asian Strategies                    |
//| Each RSI Reversal Asian strategy trades on its own symbol:       |
//| - EURUSD: Euro/USD                                                |
//| - AUDUSD: Australian Dollar/USD                                   |
//+------------------------------------------------------------------+
input group "=== RSI Reversal Asian EURUSD ==="
input string RRA_EURUSD_Symbol = "EURUSD.c";
input int    RRA_EURUSD_RSIPeriod = 28;
input double RRA_EURUSD_OverboughtLevel = 60;
input double RRA_EURUSD_OversoldLevel = 8;
input int    RRA_EURUSD_TakeProfitPips = 175;
input int    RRA_EURUSD_StopLossPips = 5;
input double RRA_EURUSD_MaxLotSize = 0.15;
input int    RRA_EURUSD_MaxSpread = 1000;
input int    RRA_EURUSD_MaxDuration = 270;
input bool   RRA_EURUSD_UseStopLoss = false;
input bool   RRA_EURUSD_UseTakeProfit = false;
input bool   RRA_EURUSD_UseRSIExit = true;
input double RRA_EURUSD_RSIExitLevel = 55;
input bool   RRA_EURUSD_CloseOutsideSession = false;
input ENUM_TIMEFRAMES RRA_EURUSD_TimeFrame = PERIOD_M15;
input int    RRA_EURUSD_MagicNumber = 30001;
input int    RRA_EURUSD_Slippage = 3;

input group "=== RSI Reversal Asian AUDUSD ==="
input string RRA_AUDUSD_Symbol = "AUDUSD.c";
input int    RRA_AUDUSD_RSIPeriod = 28;
input double RRA_AUDUSD_OverboughtLevel = 68;
input double RRA_AUDUSD_OversoldLevel = 30;
input int    RRA_AUDUSD_TakeProfitPips = 175;
input int    RRA_AUDUSD_StopLossPips = 5;
input double RRA_AUDUSD_MaxLotSize = 0.3;
input int    RRA_AUDUSD_MaxSpread = 1000;
input int    RRA_AUDUSD_MaxDuration = 340;
input bool   RRA_AUDUSD_UseStopLoss = false;
input bool   RRA_AUDUSD_UseTakeProfit = false;
input bool   RRA_AUDUSD_UseRSIExit = true;
input double RRA_AUDUSD_RSIExitLevel = 48;
input bool   RRA_AUDUSD_CloseOutsideSession = true;
input ENUM_TIMEFRAMES RRA_AUDUSD_TimeFrame = PERIOD_M15;
input int    RRA_AUDUSD_MagicNumber = 30002;
input int    RRA_AUDUSD_Slippage = 3;

//+------------------------------------------------------------------+
//| Global Variables - DarvasBox                                      |
//+------------------------------------------------------------------+
struct DarvasBoxData {
   string symbol;
   bool isInitialized;
   double boxHigh;
   double boxLow;
   bool boxFormed;
   datetime lastBoxTime;
   string boxName;
   double minStopLevel;
   double point;
   CTrade trade;
   int maHandle;
   int volumeHandle;
   datetime lastBarTime;
};

//+------------------------------------------------------------------+
//| Global Variables - EMA Slope Distance                            |
//+------------------------------------------------------------------+
struct EMASlopeData {
   string symbol;
   bool isInitialized;
   int ema_handle;
   double ema_array[];
   datetime letzte_überwachung_zeit;
   bool überwachung_aktiv;
   bool preis_trigger_aktiv;
   bool steigung_trigger_aktiv;
   int ticket;
   CTrade trade;
   int trades_in_current_crossover;
   bool crossover_detected;
   datetime trade_open_time;
   datetime last_bar_time;
};

//+------------------------------------------------------------------+
//| Global Variables - RSI CrossOver Reversal                       |
//+------------------------------------------------------------------+
struct RSICrossOverData {
   string symbol;
   bool isInitialized;
   int rsiHandle;
   int emaHandle;
   double previousRSIDef;
   CTrade trade;
   datetime lastTradeTime;
   datetime bartime;
   bool WeekDays[7];
   datetime lastBarTime;
};

//+------------------------------------------------------------------+
//| Global Variables - RSI MidPoint Hijack                          |
//+------------------------------------------------------------------+
struct RSIMidPointData {
   string symbol;
   bool isInitialized;
   int rsiHandle;
   int rsiReverseHandle;
   int emaHandle;
   bool rsiOverbought;
   bool rsiOversold;
   bool rsiReverseOverbought;
   bool rsiReverseOversold;
   CTrade trade;
   CPositionInfo positionInfo;
   bool emaCrossBuySignal;
   bool emaCrossSellSignal;
   int emaCrossSignalBar;
   datetime lastBarTime;
   datetime rsiReverseLastCloseTime;
   bool rsiReverseInCooldown;
   double lastBarRSI;
   double lastBarRSIReverse;
   double lastBarEMA;
   double lastBarClose;
   double lastBarEMAPrev;
   double lastBarClosePrev;
};

//+------------------------------------------------------------------+
//| Global Strategy Instances                                        |
//+------------------------------------------------------------------+
DarvasBoxData dbData;
EMASlopeData esData;
RSICrossOverData rcData;
RSIMidPointData rmData;
RSIScalpingData rsAPPLData;
RSIScalpingData rsBTCUSDData;
RSIScalpingData rsNVDAData;
RSIScalpingData rsTSLAData;
RSIScalpingData rsXAUUSDData;

//+------------------------------------------------------------------+
//| Global Variables - RSI Reversal Asian                            |
//+------------------------------------------------------------------+
RSIReversalAsianData rraEURUSDData;
RSIReversalAsianData rraAUDUSDData;

//+------------------------------------------------------------------+
//| Dynamic lot helpers                                              |
//+------------------------------------------------------------------+
double DynClamp(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

// Clamp scale factor (proportion or pow result). max<=0 = no upper clamp.
double ApplyDynamicScaleClamp(const double scaleRaw)
{
   double s = scaleRaw;
   if(InpDynamicMinMult > 0.0)
      s = MathMax(s, InpDynamicMinMult);
   if(InpDynamicMaxMult > 0.0)
      s = MathMin(s, InpDynamicMaxMult);
   return s;
}

// Reference for (equity/ref)^exp: manual deposit, or first-seen balance when input <= 0
double GetDynamicRefForRatio()
{
   if(InpDynamicRefDeposit > 0.0)
      return MathMax(InpDynamicRefDeposit, 1.0);
   double capNow = InpDynamicUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_DynamicRefBaseline <= 0.0)
      g_DynamicRefBaseline = MathMax(capNow, 1.0);
   return MathMax(g_DynamicRefBaseline, 1.0);
}

// Broker hard cap: 最大量 = SYMBOL_VOLUME_MAX (e.g. 1000 on EURUSD.c / XAUUSD.c)
double NormalizeVolumeForSymbol(const string symbol, double lots)
{
   double minL = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      lots = MathFloor(lots / step + 1e-12) * step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return lots;
}

// Apply EA risk cap before broker min/step/max (InpMaxLotsPerOrder 0 = disabled)
double NormalizeVolumeForSymbolWithEACap(const string symbol, double lots)
{
   if(InpMaxLotsPerOrder > 0.0)
      lots = MathMin(lots, InpMaxLotsPerOrder);
   return NormalizeVolumeForSymbol(symbol, lots);
}

// Scale factor for lots: baseLot * scale * InpLotSizeScale (then caps)
double GetDynamicLotScaleFactor()
{
   if(!InpDynamicLotEnable)
      return 1.0;
   if(InpDynamicRefEqualsEquity)
      return ApplyDynamicScaleClamp(1.0);
   double cap = InpDynamicUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   double refv = GetDynamicRefForRatio();
   if(cap <= 0.0)
      cap = refv;
   double ratio = cap / refv;
   if(ratio <= 0.0)
      ratio = 1.0;
   double scaleRaw = ratio;
   if(InpDynamicLotCurve == LOT_CURVE_POWER)
      scaleRaw = MathPow(ratio, InpDynamicExponent);
   return ApplyDynamicScaleClamp(scaleRaw);
}

// baseLot = size at reference deposit; optionalCap 0 = no extra ceiling (broker min/max still apply)
double DynamicLotForSymbol(const string symbol, const double baseLot, const double optionalCap = 0.0)
{
   double scale = GetDynamicLotScaleFactor();
   g_DynLotScaleLast = scale;
   double sc = (InpLotSizeScale > 0.0 ? InpLotSizeScale : 1.0);
   double v = baseLot * scale * sc;
   if(optionalCap > 0.0 && v > optionalCap)
      v = optionalCap;
   return NormalizeVolumeForSymbolWithEACap(symbol, v);
}

void RefreshDynamicStrategyLots()
{
   double sc = (InpLotSizeScale > 0.0 ? InpLotSizeScale : 1.0);
   if(!InpDynamicLotEnable)
   {
      g_ES_LotSize = NormalizeVolumeForSymbolWithEACap(ES_Symbol, ES_LotGröße * sc);
      g_RC_LotSize = NormalizeVolumeForSymbolWithEACap(RC_Symbol, RC_lotSize * sc);
      g_RM_LotSize = NormalizeVolumeForSymbolWithEACap(RM_Symbol, RM_InpLotSize * sc);
      g_DB_LotSize = NormalizeVolumeForSymbolWithEACap(DB_Symbol, DB_BaseLotSize * sc);
      g_DynLotScaleLast = 1.0;
      return;
   }
   g_ES_LotSize = DynamicLotForSymbol(ES_Symbol, ES_LotGröße);
   g_RC_LotSize = DynamicLotForSymbol(RC_Symbol, RC_lotSize);
   g_RM_LotSize = DynamicLotForSymbol(RM_Symbol, RM_InpLotSize);
   g_DB_LotSize = DynamicLotForSymbol(DB_Symbol, DB_BaseLotSize);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int initResult = INIT_SUCCEEDED;
   
   g_DynamicRefBaseline = 0.0;
   
   RefreshDynamicStrategyLots();
   
   string acctCur = AccountInfoString(ACCOUNT_CURRENCY);
   double eq0 = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpDynamicLotEnable && !InpDynamicRefEqualsEquity && InpDynamicRefDeposit > 1000.0 && eq0 > 0.0
      && eq0 <= InpDynamicRefDeposit / 25.0)
      Print("United EA: equity ", DoubleToString(eq0, 2), " ", acctCur, " vs ref ", InpDynamicRefDeposit,
            " — dynamic mult is tiny; set InpDynamicRefDeposit to your balance in ", acctCur,
            " (e.g. 500 for USD) or enable InpDynamicRefEqualsEquity. Else lots stay at broker minimum.");
   
   // Initialize strategies - log warnings but don't fail entire EA if symbol unavailable
   if(EnableDarvasBox)
      if(!InitDarvasBox(DB_Symbol))
         Print("Warning: DarvasBox strategy failed to initialize for symbol '", DB_Symbol, "'");
   
   if(EnableEMASlopeDistance)
      if(!InitEMASlopeDistance(ES_Symbol))
         Print("Warning: EMASlopeDistance strategy failed to initialize for symbol '", ES_Symbol, "'");
   
   if(EnableRSICrossOverReversal)
      if(!InitRSICrossOverReversal(RC_Symbol))
         Print("Warning: RSICrossOverReversal strategy failed to initialize for symbol '", RC_Symbol, "'");
   
   if(EnableRSIMidPointHijack)
      if(!InitRSIMidPointHijack(RM_Symbol))
         Print("Warning: RSIMidPointHijack strategy failed to initialize for symbol '", RM_Symbol, "'");
   
   // Initialize RSI Scalping strategies - don't fail entire EA if symbol unavailable
   if(EnableRSIScalpingAPPL)
      InitRSIScalping(rsAPPLData, RS_APPL_Symbol, RS_APPL_TimeFrame, RS_APPL_RSI_Period, RS_APPL_RSI_Applied_Price, RS_APPL_MagicNumber, RS_APPL_Slippage);
   
   if(EnableRSIScalpingBTCUSD)
      InitRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price, RS_BTCUSD_MagicNumber, RS_BTCUSD_Slippage);
   
   if(EnableRSIScalpingNVDA)
      InitRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price, RS_NVDA_MagicNumber, RS_NVDA_Slippage);
   
   if(EnableRSIScalpingTSLA)
      InitRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price, RS_TSLA_MagicNumber, RS_TSLA_Slippage);
   
   if(EnableRSIScalpingXAUUSD)
      InitRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price, RS_XAUUSD_MagicNumber, RS_XAUUSD_Slippage);
   
   // Initialize RSI Reversal Asian strategies
   if(EnableRSIReversalAsianEURUSD)
      if(!InitRSIReversalAsian(rraEURUSDData, RRA_EURUSD_Symbol, RRA_EURUSD_RSIPeriod, RRA_EURUSD_OverboughtLevel, RRA_EURUSD_OversoldLevel,
                               RRA_EURUSD_TakeProfitPips, RRA_EURUSD_StopLossPips, RRA_EURUSD_MaxLotSize,
                               RRA_EURUSD_MaxSpread, RRA_EURUSD_MaxDuration, RRA_EURUSD_UseStopLoss,
                               RRA_EURUSD_UseTakeProfit, RRA_EURUSD_UseRSIExit, RRA_EURUSD_RSIExitLevel,
                               RRA_EURUSD_CloseOutsideSession, RRA_EURUSD_TimeFrame, RRA_EURUSD_MagicNumber, RRA_EURUSD_Slippage))
         Print("Warning: RSIReversalAsianEURUSD strategy failed to initialize for symbol '", RRA_EURUSD_Symbol, "'");
   
   if(EnableRSIReversalAsianAUDUSD)
      if(!InitRSIReversalAsian(rraAUDUSDData, RRA_AUDUSD_Symbol, RRA_AUDUSD_RSIPeriod, RRA_AUDUSD_OverboughtLevel, RRA_AUDUSD_OversoldLevel,
                               RRA_AUDUSD_TakeProfitPips, RRA_AUDUSD_StopLossPips, RRA_AUDUSD_MaxLotSize,
                               RRA_AUDUSD_MaxSpread, RRA_AUDUSD_MaxDuration, RRA_AUDUSD_UseStopLoss,
                               RRA_AUDUSD_UseTakeProfit, RRA_AUDUSD_UseRSIExit, RRA_AUDUSD_RSIExitLevel,
                               RRA_AUDUSD_CloseOutsideSession, RRA_AUDUSD_TimeFrame, RRA_AUDUSD_MagicNumber, RRA_AUDUSD_Slippage))
         Print("Warning: RSIReversalAsianAUDUSD strategy failed to initialize for symbol '", RRA_AUDUSD_Symbol, "'");
   
   double refEffInit = GetDynamicRefForRatio();
   double capInit = InpDynamicUseEquity ? eq0 : AccountInfoDouble(ACCOUNT_BALANCE);
   if(capInit <= 0.0)
      capInit = refEffInit;
   double ratioInit = capInit / refEffInit;
   double powInit = MathPow(ratioInit, InpDynamicExponent);
   string curveStr = (InpDynamicLotCurve == LOT_CURVE_POWER ? "POWER" : "PROP");
   Print("United EA v1.10 ", acctCur, " curve=", curveStr, " equity=", DoubleToString(eq0, 2), " refEff=", DoubleToString(refEffInit, 2),
         " (inpRef=", InpDynamicRefDeposit, " baseline=", DoubleToString(g_DynamicRefBaseline, 2), ") equity/ref=", DoubleToString(ratioInit, 6),
         " pow^exp=", DoubleToString(powInit, 6), " scaleOut=", DoubleToString(g_DynLotScaleLast, 6),
         " minS=", InpDynamicMinMult, " maxS=", InpDynamicMaxMult, " lotScale=", InpLotSizeScale, " maxLots=", InpMaxLotsPerOrder,
         " lots ES=", g_ES_LotSize, " RC=", g_RC_LotSize, " RM=", g_RM_LotSize, " DB=", g_DB_LotSize);
   Print("United EA initialized. Active strategies: ", 
         (EnableDarvasBox ? "DarvasBox " : ""),
         (EnableEMASlopeDistance ? "EMASlope " : ""),
         (EnableRSICrossOverReversal ? "RSICrossOver " : ""),
         (EnableRSIMidPointHijack ? "RSIMidPoint " : ""),
         (EnableRSIScalpingAPPL ? "RSIScalpingAPPL " : ""),
         (EnableRSIScalpingBTCUSD ? "RSIScalpingBTCUSD " : ""),
         (EnableRSIScalpingNVDA ? "RSIScalpingNVDA " : ""),
         (EnableRSIScalpingTSLA ? "RSIScalpingTSLA " : ""),
         (EnableRSIScalpingXAUUSD ? "RSIScalpingXAUUSD " : ""),
         (EnableRSIReversalAsianEURUSD ? "RSIReversalAsianEURUSD " : ""),
         (EnableRSIReversalAsianAUDUSD ? "RSIReversalAsianAUDUSD " : ""));
   
   return initResult;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(EnableDarvasBox)
      DeinitDarvasBox();
   
   if(EnableEMASlopeDistance)
      DeinitEMASlopeDistance();
   
   if(EnableRSICrossOverReversal)
      DeinitRSICrossOverReversal();
   
   if(EnableRSIMidPointHijack)
      DeinitRSIMidPointHijack();
   
   if(EnableRSIScalpingAPPL)
      DeinitRSIScalping(rsAPPLData);
   
   if(EnableRSIScalpingBTCUSD)
      DeinitRSIScalping(rsBTCUSDData);
   
   if(EnableRSIScalpingNVDA)
      DeinitRSIScalping(rsNVDAData);
   
   if(EnableRSIScalpingTSLA)
      DeinitRSIScalping(rsTSLAData);
   
   if(EnableRSIScalpingXAUUSD)
      DeinitRSIScalping(rsXAUUSDData);
   
   if(EnableRSIReversalAsianEURUSD)
      DeinitRSIReversalAsian(rraEURUSDData);
   
   if(EnableRSIReversalAsianAUDUSD)
      DeinitRSIReversalAsian(rraAUDUSDData);
   
   Print("United EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   RefreshDynamicStrategyLots();
   
   if(EnableDarvasBox)
      ProcessDarvasBox(DB_Symbol);
   
   if(EnableEMASlopeDistance)
      ProcessEMASlopeDistance(ES_Symbol);
   
   if(EnableRSICrossOverReversal)
      ProcessRSICrossOverReversal(RC_Symbol);
   
   if(EnableRSIMidPointHijack)
      ProcessRSIMidPointHijack(RM_Symbol);
   
   if(EnableRSIScalpingAPPL)
      ProcessRSIScalping(rsAPPLData, RS_APPL_Symbol, RS_APPL_TimeFrame, RS_APPL_RSI_Period, RS_APPL_RSI_Applied_Price,
                        RS_APPL_RSI_Overbought, RS_APPL_RSI_Oversold, RS_APPL_RSI_Target_Buy, RS_APPL_RSI_Target_Sell,
                        RS_APPL_BarsToWait,
                        DynamicLotForSymbol(RS_APPL_Symbol, RS_APPL_LotSize, InpDynamicStockLotCap),
                        RS_APPL_MagicNumber);
   
   if(EnableRSIScalpingBTCUSD)
      ProcessRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price,
                        RS_BTCUSD_RSI_Overbought, RS_BTCUSD_RSI_Oversold, RS_BTCUSD_RSI_Target_Buy, RS_BTCUSD_RSI_Target_Sell,
                        RS_BTCUSD_BarsToWait, DynamicLotForSymbol(RS_BTCUSD_Symbol, RS_BTCUSD_LotSize), RS_BTCUSD_MagicNumber);
   
   if(EnableRSIScalpingNVDA)
      ProcessRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price,
                        RS_NVDA_RSI_Overbought, RS_NVDA_RSI_Oversold, RS_NVDA_RSI_Target_Buy, RS_NVDA_RSI_Target_Sell,
                        RS_NVDA_BarsToWait,
                        DynamicLotForSymbol(RS_NVDA_Symbol, RS_NVDA_LotSize, InpDynamicStockLotCap),
                        RS_NVDA_MagicNumber);
   
   if(EnableRSIScalpingTSLA)
      ProcessRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price,
                        RS_TSLA_RSI_Overbought, RS_TSLA_RSI_Oversold, RS_TSLA_RSI_Target_Buy, RS_TSLA_RSI_Target_Sell,
                        RS_TSLA_BarsToWait,
                        DynamicLotForSymbol(RS_TSLA_Symbol, RS_TSLA_LotSize, InpDynamicStockLotCap),
                        RS_TSLA_MagicNumber);
   
   if(EnableRSIScalpingXAUUSD)
      ProcessRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price,
                        RS_XAUUSD_RSI_Overbought, RS_XAUUSD_RSI_Oversold, RS_XAUUSD_RSI_Target_Buy, RS_XAUUSD_RSI_Target_Sell,
                        RS_XAUUSD_BarsToWait, DynamicLotForSymbol(RS_XAUUSD_Symbol, RS_XAUUSD_LotSize), RS_XAUUSD_MagicNumber);
   
   if(EnableRSIReversalAsianEURUSD)
      ProcessRSIReversalAsian(rraEURUSDData, DynamicLotForSymbol(RRA_EURUSD_Symbol, RRA_EURUSD_MaxLotSize));
   
   if(EnableRSIReversalAsianAUDUSD)
      ProcessRSIReversalAsian(rraAUDUSDData, DynamicLotForSymbol(RRA_AUDUSD_Symbol, RRA_AUDUSD_MaxLotSize));
}

//+------------------------------------------------------------------+
