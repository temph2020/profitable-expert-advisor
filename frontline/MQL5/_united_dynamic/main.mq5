//+------------------------------------------------------------------+
//|                                                    UnitedEA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.17"
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
double g_DynMultLast = 1.0;
double g_equityPeakHighWater = 0.0;   // for drawdown lot cap (updated each tick via Refresh)
datetime g_ddLotCapAnchorTime = 0;    // tester/attach start — grace period before DD cap may apply

// Include strategy implementations early so structs are available
#include "Strategies/DarvasBoxStrategy.mqh"
#include "Strategies/EMASlopeDistanceStrategy.mqh"
#include "Strategies/RSICrossOverReversalStrategy.mqh"
#include "Strategies/RSIMidPointHijackStrategy.mqh"
#include "Strategies/RSIScalpingStrategy.mqh"
#include "Strategies/RSIReversalAsianStrategy.mqh"
#include "Strategies/RSISecretSauceStrategy.mqh"
#include "Strategies/SuperEMAStrategy.mqh"

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
input bool EnableRSIReversalEURUSD = true;   // RSI Reversal Asian session (EURUSD)
input bool EnableRSIReversalAUDUSD = true;   // RSI Reversal Asian session (AUDUSD)
input bool EnableRSISecretSauceXAUUSD = true;
input bool EnableSuperEMA = true;

//+------------------------------------------------------------------+
//| SuperEMA — EMA + CCI + MACD (XAUUSD default)                      |
//+------------------------------------------------------------------+
input group "=== SuperEMA (EMA + CCI + MACD) ==="
input string              SE_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES     SE_Timeframe = PERIOD_M15;
input double              SE_LotSize = 0.01;
input int                 SE_SlippagePoints = 55;
input int                 SE_MagicNumber = 940001;
input int                 SE_EmaFast = 40;
input int                 SE_EmaMid = 180;
input int                 SE_EmaSlow = 125;
input int                 SE_EmaTrendBars = 3;
input int                 SE_CciPeriod = 17;
input double              SE_CciOverbought = 80.0;
input double              SE_CciOversold = -140.0;
input int                 SE_PullbackCciLookback = 20;
input int                 SE_MacdFast = 14;
input int                 SE_MacdSlow = 38;
input int                 SE_MacdSignal = 9;
input ENUM_SE_ENTRY_STYLE SE_EntryStyle = SE_ENTRY_LAMBERT;
input bool                SE_OneTradeOnly = true;
input bool                SE_UseStructuralSL = false;
input double              SE_SlBufferPoints = 110;
input bool                SE_ExitOnTrendFlip = false;
input bool                SE_ExitOnMacdFlip = false;
input bool                SE_ExitOnCciZeroCross = true;
input int                 SE_MaxHoldingBars = 168;
input bool                SE_ExitBelowMidEma = false;
input bool                SE_DebugLogs = false;

//+------------------------------------------------------------------+
//| Dynamic lot sizing — scale base lots vs reference deposit        |
//| mult=(equity/ref)^exp; maxMult<=0 上不封顶; minMult<=0 不锁下限      |
//+------------------------------------------------------------------+
input group "=== Dynamic lot sizing (动态手数) ==="
input bool   InpDynamicLotEnable = true;           // Enable balance/equity-based scaling
input double InpDynamicRefDeposit = 3000.0;        // Reference balance (match Tester initial deposit)
input double InpDynamicExponent = 1.15;             // 1.0=linear; >1 faster growth; <1 conservative
input double InpDynamicMinMult = 0.0;               // <=0 不锁下限; >0 例如0.25 为最低倍数
input double InpDynamicMaxMult = 0.0;                // <=0 动态倍数不封顶; >0 上限封顶
input bool   InpDynamicUseEquity = true;            // true=ACCOUNT_EQUITY, false=ACCOUNT_BALANCE
input double InpDynamicStockLotCap = 0.0;            // Extra cap for stock CFDs (0 = none)

//+------------------------------------------------------------------+
//| Lot cap: optional account-wide DD from peak, and/or per-strategy |
//| (last *closed* calendar month losing for that magic).            |
//+------------------------------------------------------------------+
input group "=== Drawdown / loser lot cap ==="
input bool   InpDdLotCapEnable = true;               // master: allow clamping when a mode below triggers
input bool   InpDdLotCapGlobalEquityEnable = false;  // cap *all* robots when equity DD from peak >= X% (after grace)
input bool   InpDdLotCapPerStratEnable = true;       // cap only robots whose last closed month was red (by magic)
input bool   InpDdLotCapUseEquity = true;            // true=ACCOUNT_EQUITY, false=BALANCE (global mode + peak tracking)
input double InpDdLotCapFromPeakPercent = 7.0;       // global: trigger if (peak-equity)/peak*100 >= this
input double InpDdLotCapMaxLots = 0.01;              // max volume per order while that mode is triggered
input int    InpDdLotCapGraceDays = 90;              // global only: wait N days from attach before DD cap can apply (0=immediate)
input double InpDdLotCapStratLossThreshold = 0.0;    // per-strat: month P/L < -this counts as losing (0 = any loss)
input int    InpDdLotCapUpdateSeconds = 3600;        // min 60; refresh last-month P/L when adaptive monthly is off

//+------------------------------------------------------------------+
//| Strategy 1: DarvasBoxXAUUSD                                      |
//+------------------------------------------------------------------+
input group "=== DarvasBox Strategy ==="
input string DB_Symbol = "XAUUSD";
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
input double DB_BaseLotSize = 0.01;                 // Base lot at InpDynamicRefDeposit (Darvas)

//+------------------------------------------------------------------+
//| Strategy 2: EMASlopeDistanceCocktailXAUUSD                     |
//| PEPPERSTONE US: Gold symbol is typically "XAUUSD" or "GOLD"    |
//+------------------------------------------------------------------+
input group "=== EMA Slope Distance Strategy ==="
input string ES_Symbol = "XAUUSD";
input int    ES_EMA_Periode = 46;
input double ES_PreisSchwelle = 600.0;
input double ES_SteigungSchwelle = 80.0;
input int    ES_ÜberwachungTimeout = 800;
input double ES_TrailingStop = 250.0;
input double ES_LotGröße = 0.03;
input int    ES_MagicNumber = 12350;
input bool   ES_UseSpreadAdjustment = true;
input ENUM_TIMEFRAMES ES_Timeframe = PERIOD_H1;
input bool   ES_UseBarData = true;
input int    ES_MaxTradesPerCrossover = 9;
input int    ES_ProfitCheckBars = 18;
input bool   ES_CloseUnprofitableTrades = true;

//+------------------------------------------------------------------+
//| Strategy 3: RSICrossOverReversalXAUUSD                          |
//| PEPPERSTONE US: Gold symbol is typically "XAUUSD" or "GOLD"    |
//+------------------------------------------------------------------+
input group "=== RSI CrossOver Reversal Strategy ==="
input string RC_Symbol = "XAUUSD";
input int    RC_MagicNumber = 7;
input int    RC_rsiPeriod = 19;
input int    RC_overboughtLevel = 93;
input int    RC_oversoldLevel = 22;
input double RC_entryRSIBuySpread = 0;
input double RC_entryRSISellSpread = 0;
input double RC_lotSize = 0.01;
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
//| PEPPERSTONE US: Gold symbol is typically "XAUUSD" or "GOLD"    |
//+------------------------------------------------------------------+
input group "=== RSI MidPoint Hijack Strategy ==="
input string RM_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES RM_InpTimeframe = PERIOD_H1;
input double RM_InpLotSize = 0.02;
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
//| PEPPERSTONE US SYMBOL FORMATS:                                    |
//| - Stocks may use: "AAPL.US", "NASDAQ:AAPL", or just "AAPL"      |
//| - To find correct symbols:                                       |
//|   1. Open Market Watch (Ctrl+M)                                   |
//|   2. Right-click > Show All                                       |
//|   3. Search for the stock name                                    |
//|   4. Use the exact symbol name shown                              |
//+------------------------------------------------------------------+
input group "=== RSI Scalping APPL (AAPL) - Pepperstone US ==="
input string RS_APPL_Symbol = "AAPL.US";  // Try: "AAPL.US", "NASDAQ:AAPL", or "AAPL"
input ENUM_TIMEFRAMES RS_APPL_TimeFrame = PERIOD_M10;
input int    RS_APPL_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_APPL_RSI_Applied_Price = PRICE_CLOSE;
input double RS_APPL_RSI_Overbought = 80;
input double RS_APPL_RSI_Oversold = 78;
input double RS_APPL_RSI_Target_Buy = 94;
input double RS_APPL_RSI_Target_Sell = 44;
input int    RS_APPL_BarsToWait = 7;
input double RS_APPL_LotSize = 25;
input int    RS_APPL_MagicNumber = 20001;
input int    RS_APPL_Slippage = 3;

input group "=== RSI Scalping BTCUSD ==="
input string RS_BTCUSD_Symbol = "BTCUSD";  // Pepperstone may use: "BTCUSD", "BTC/USD", or "BTCUSD.c"
input ENUM_TIMEFRAMES RS_BTCUSD_TimeFrame = PERIOD_H1;
input int    RS_BTCUSD_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_BTCUSD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_BTCUSD_RSI_Overbought = 90;
input double RS_BTCUSD_RSI_Oversold = 73;
input double RS_BTCUSD_RSI_Target_Buy = 88;
input double RS_BTCUSD_RSI_Target_Sell = 48;
input int    RS_BTCUSD_BarsToWait = 6;
input double RS_BTCUSD_LotSize = 0.1;
input int    RS_BTCUSD_MagicNumber = 123459123;
input int    RS_BTCUSD_Slippage = 3;

input group "=== RSI Scalping NVDA - Pepperstone US ==="
input string RS_NVDA_Symbol = "NVDA.US";  // Try: "NVDA.US", "NASDAQ:NVDA", or "NVDA"
input ENUM_TIMEFRAMES RS_NVDA_TimeFrame = PERIOD_M15;
input int    RS_NVDA_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_NVDA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_NVDA_RSI_Overbought = 36;
input double RS_NVDA_RSI_Oversold = 38;
input double RS_NVDA_RSI_Target_Buy = 90;
input double RS_NVDA_RSI_Target_Sell = 70;
input int    RS_NVDA_BarsToWait = 5;
input double RS_NVDA_LotSize = 50;
input int    RS_NVDA_MagicNumber = 20003;
input int    RS_NVDA_Slippage = 3;

input group "=== RSI Scalping TSLA - Pepperstone US ==="
input string RS_TSLA_Symbol = "TSLA.US";  // Try: "TSLA.US", "NASDAQ:TSLA", or "TSLA"
input ENUM_TIMEFRAMES RS_TSLA_TimeFrame = PERIOD_H1;
input int    RS_TSLA_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_TSLA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_TSLA_RSI_Overbought = 54;
input double RS_TSLA_RSI_Oversold = 73;
input double RS_TSLA_RSI_Target_Buy = 87;
input double RS_TSLA_RSI_Target_Sell = 33;
input int    RS_TSLA_BarsToWait = 1;
input double RS_TSLA_LotSize = 50;
input int    RS_TSLA_MagicNumber = 125421321;
input int    RS_TSLA_Slippage = 3;

input group "=== RSI Scalping XAUUSD ==="
input string RS_XAUUSD_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES RS_XAUUSD_TimeFrame = PERIOD_H1;
input int    RS_XAUUSD_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_XAUUSD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_XAUUSD_RSI_Overbought = 71;
input double RS_XAUUSD_RSI_Oversold = 57;
input double RS_XAUUSD_RSI_Target_Buy = 80;
input double RS_XAUUSD_RSI_Target_Sell = 57;
input int    RS_XAUUSD_BarsToWait = 4;
input double RS_XAUUSD_LotSize = 0.1;
input int    RS_XAUUSD_MagicNumber = 129102315;
input int    RS_XAUUSD_Slippage = 3;

//+------------------------------------------------------------------+
//| Strategy: RSI Secret Sauce XAUUSD (leave zone → re-entry peak/bottom) |
//| Defaults match secret_sauce.set except symbol stays XAUUSD here.      |
//+------------------------------------------------------------------+
input group "=== RSI Secret Sauce XAUUSD ==="
input string RSS_XAUUSD_Symbol = "XAUUSD";             // not BTCUSD — gold chart / portfolio default
input double RSS_XAUUSD_LotSize = 0.1;
input int    RSS_XAUUSD_MagicNumber = 789012;
input int    RSS_XAUUSD_Slippage = 10;
input ENUM_TIMEFRAMES RSS_XAUUSD_Timeframe = PERIOD_M30;
input int    RSS_XAUUSD_RSIPeriod = 16;
input double RSS_XAUUSD_RSIOverbought = 72.5;
input double RSS_XAUUSD_RSIOversold = 32.5;
input int    RSS_XAUUSD_RSILookback = 60;
input int    RSS_XAUUSD_PeakBars = 2;
input bool   RSS_XAUUSD_RequireDivergence = false;
input double RSS_XAUUSD_StopLossATR = 2.75;
input double RSS_XAUUSD_TakeProfitATR = 5.0;
input int    RSS_XAUUSD_ATRPeriod = 14;
input bool   RSS_XAUUSD_UseSwingStopLoss = false;
input int    RSS_XAUUSD_SwingLookback = 30;
input int    RSS_XAUUSD_MaxPositions = 1;
input int    RSS_XAUUSD_MinBarsBetweenTrades = 7;

//+------------------------------------------------------------------+
//| Strategy 11-12: RSI Reversal (Asian session) EURUSD & AUDUSD      |
//| Same logic as RSIReversalAsianEURUSD / RSIReversalAsianAUDUSD EAs |
//+------------------------------------------------------------------+
input group "=== RSI Reversal EURUSD (Asian session) ==="
input string RRA_EURUSD_Symbol = "EURUSD";
input int    RRA_EURUSD_RSIPeriod = 28;
input double RRA_EURUSD_OverboughtLevel = 60;
input double RRA_EURUSD_OversoldLevel = 8;
input int    RRA_EURUSD_TakeProfitPips = 175;
input int    RRA_EURUSD_StopLossPips = 5;
input double RRA_EURUSD_MaxLotSize = 0.1;
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

input group "=== RSI Reversal AUDUSD (Asian session) ==="
input string RRA_AUDUSD_Symbol = "AUDUSD";
input int    RRA_AUDUSD_RSIPeriod = 28;
input double RRA_AUDUSD_OverboughtLevel = 68;
input double RRA_AUDUSD_OversoldLevel = 30;
input int    RRA_AUDUSD_TakeProfitPips = 175;
input int    RRA_AUDUSD_StopLossPips = 5;
input double RRA_AUDUSD_MaxLotSize = 0.2;
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
//| Chart panel: closed-deal P&L by strategy (magic) + optional open |
//+------------------------------------------------------------------+
input group "=== Chart profit panel (by magic) ==="
input bool UnitedPanel_Enable = false;          // OBJ_LABEL + background on chart
input int  UnitedPanel_Seconds = 60;            // refresh interval (min 5); history scan once per tick
input int  UnitedPanel_Corner = 0;              // ENUM_BASE_CORNER e.g. 0=left upper
input int  UnitedPanel_X = 8;
input int  UnitedPanel_Y = 24;
input int  UnitedPanel_Width = 360;
input int  UnitedPanel_FontSize = 9;
input int  UnitedPanel_XMargin = 6;
input int  UnitedPanel_YMargin = 6;
input bool UnitedPanel_ShowFloating = false;     // open P/L+swap per magic

enum ENUM_ADAPTIVE_STREAK_UNIT
{
   ADAPTIVE_STREAK_BY_MONTH = 0,   // consecutive closed calendar months
   ADAPTIVE_STREAK_BY_DAY = 1      // consecutive closed calendar days (server time)
};

//+------------------------------------------------------------------+
//| Pause strategies after consecutive losing periods (month or day)|
//+------------------------------------------------------------------+
input group "=== Adaptive regime (per robot / magic) ==="
input bool   InpAdaptiveEnable = true;           // If false, every other InpAdaptive* input is ignored (no streak / canary / pause). Set true to optimize or use adaptive regime.
input ENUM_ADAPTIVE_STREAK_UNIT InpAdaptiveStreakUnit = ADAPTIVE_STREAK_BY_DAY;
input int    InpAdaptiveRedStreak = 5;           // consecutive red months OR red days (see streak unit)
input double InpAdaptiveRedThreshold = 0.0;      // period P/L < -threshold counts red (0 = any loss)
input int    InpAdaptiveLookbackMonths = 14;     // if unit=MONTH: history depth in months (>= streak+1)
input int    InpAdaptiveLookbackDays = 36;       // if unit=DAY: closed days of history (>= streak+1)
input int    InpAdaptiveUpdateSeconds = 3600;    // min 60; how often to recompute
input double InpAdaptiveCanaryLotMult = 0.07;     // probation: scale lots (0 = hard pause on streak, no canary)
input int    InpAdaptiveHardRetryMonths = 3;     // if unit=MONTH: 0=no auto retry; else retry after N months
input int    InpAdaptiveHardRetryDays = 32;      // if unit=DAY: 0=no auto retry; else retry after N days
input int    InpAdaptivePostCanaryCooldownDays = 37; // after successful canary, block re-arming another canary (days)

#include "UnitedProfitPanel.mqh"
#include "AdaptiveMonthlyRegime.mqh"

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
RSISecretSauceData rsSecretSauceXAUUSDData;
SuperEMAData       seData;

//+------------------------------------------------------------------+
//| Dynamic lot helpers                                              |
//+------------------------------------------------------------------+
double DynClamp(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

// maxMult<=0: no ceiling. minMult<=0: no floor on raw (equity/ref)^exp.
double ApplyDynamicMultClamp(const double mult)
{
   double m = mult;
   if(InpDynamicMinMult > 0.0)
      m = MathMax(m, InpDynamicMinMult);
   if(InpDynamicMaxMult > 0.0)
      m = MathMin(m, InpDynamicMaxMult);
   return m;
}

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

void UpdateEquityPeakForDdCap()
{
   if(!InpDdLotCapEnable || !InpDdLotCapGlobalEquityEnable)
      return;
   const double cur = InpDdLotCapUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   if(cur > g_equityPeakHighWater)
      g_equityPeakHighWater = cur;
}

// After dynamic sizing: global equity DD and/or per-strategy last-month loser -> clamp to InpDdLotCapMaxLots.
double LotsAfterDrawdownCap(const string symbol, const double lotsRaw, const int ddStratId = -1)
{
   double lots = NormalizeVolumeForSymbol(symbol, lotsRaw);
   if(!InpDdLotCapEnable)
      return lots;

   bool needCap = false;

   if(InpDdLotCapGlobalEquityEnable)
   {
      bool globalCheck = true;
      if(InpDdLotCapGraceDays > 0 && g_ddLotCapAnchorTime > 0)
      {
         const long needSec = (long)InpDdLotCapGraceDays * 86400L;
         if((long)(TimeCurrent() - g_ddLotCapAnchorTime) < needSec)
            globalCheck = false;
      }
      if(globalCheck && g_equityPeakHighWater > 0.0)
      {
         const double cur = InpDdLotCapUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
         if(cur < g_equityPeakHighWater)
         {
            const double ddPct = 100.0 * (g_equityPeakHighWater - cur) / g_equityPeakHighWater;
            if(ddPct >= InpDdLotCapFromPeakPercent)
               needCap = true;
         }
      }
   }

   if(InpDdLotCapPerStratEnable && ddStratId >= 0 && UnitedAdaptive_StratLastMonthIsLosing(ddStratId))
      needCap = true;

   if(!needCap)
      return lots;
   return NormalizeVolumeForSymbol(symbol, MathMin(lots, InpDdLotCapMaxLots));
}

double GetDynamicMultiplier()
{
   if(!InpDynamicLotEnable)
      return 1.0;
   double cap = InpDynamicUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   if(cap <= 0.0)
      cap = InpDynamicRefDeposit;
   double refv = MathMax(InpDynamicRefDeposit, 1.0);
   double ratio = cap / refv;
   if(ratio <= 0.0)
      ratio = 1.0;
   double mult = MathPow(ratio, InpDynamicExponent);
   return ApplyDynamicMultClamp(mult);
}

// baseLot = size at reference deposit; optionalCap 0 = no extra ceiling (broker min/max still apply)
double DynamicLotForSymbol(const string symbol, const double baseLot, const double optionalCap = 0.0, const int ddStratId = -1)
{
   double mult = GetDynamicMultiplier();
   g_DynMultLast = mult;
   double v = baseLot * mult;
   if(optionalCap > 0.0 && v > optionalCap)
      v = optionalCap;
   return LotsAfterDrawdownCap(symbol, v, ddStratId);
}

void RefreshDynamicStrategyLots()
{
   UpdateEquityPeakForDdCap();

   if(!InpDynamicLotEnable)
   {
      g_ES_LotSize = LotsAfterDrawdownCap(ES_Symbol, ES_LotGröße * UnitedAdaptive_GetLotMult(UNITED_AD_ES), UNITED_AD_ES);
      g_RC_LotSize = LotsAfterDrawdownCap(RC_Symbol, RC_lotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RC), UNITED_AD_RC);
      g_RM_LotSize = LotsAfterDrawdownCap(RM_Symbol, RM_InpLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RM), UNITED_AD_RM);
      g_DB_LotSize = LotsAfterDrawdownCap(DB_Symbol, DB_BaseLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_DARVAS), UNITED_AD_DARVAS);
      g_DynMultLast = 1.0;
      return;
   }
   g_ES_LotSize = DynamicLotForSymbol(ES_Symbol, ES_LotGröße * UnitedAdaptive_GetLotMult(UNITED_AD_ES), 0.0, UNITED_AD_ES);
   g_RC_LotSize = DynamicLotForSymbol(RC_Symbol, RC_lotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RC), 0.0, UNITED_AD_RC);
   g_RM_LotSize = DynamicLotForSymbol(RM_Symbol, RM_InpLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RM), 0.0, UNITED_AD_RM);
   g_DB_LotSize = DynamicLotForSymbol(DB_Symbol, DB_BaseLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_DARVAS), 0.0, UNITED_AD_DARVAS);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int initResult = INIT_SUCCEEDED;

   UnitedAdaptive_Init();

   g_equityPeakHighWater = InpDdLotCapUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_equityPeakHighWater <= 0.0)
      g_equityPeakHighWater = MathMax(InpDynamicRefDeposit, 1.0);
   g_ddLotCapAnchorTime = TimeCurrent();

   UnitedAdaptive_UpdateIfDue();

   RefreshDynamicStrategyLots();
   
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
   if(EnableRSIReversalEURUSD)
      if(!InitRSIReversalAsian(rraEURUSDData, RRA_EURUSD_Symbol, RRA_EURUSD_RSIPeriod, RRA_EURUSD_OverboughtLevel, RRA_EURUSD_OversoldLevel,
                               RRA_EURUSD_TakeProfitPips, RRA_EURUSD_StopLossPips, RRA_EURUSD_MaxLotSize,
                               RRA_EURUSD_MaxSpread, RRA_EURUSD_MaxDuration, RRA_EURUSD_UseStopLoss,
                               RRA_EURUSD_UseTakeProfit, RRA_EURUSD_UseRSIExit, RRA_EURUSD_RSIExitLevel,
                               RRA_EURUSD_CloseOutsideSession, RRA_EURUSD_TimeFrame, RRA_EURUSD_MagicNumber, RRA_EURUSD_Slippage))
         Print("Warning: RSIReversalEURUSD strategy failed to initialize for symbol '", RRA_EURUSD_Symbol, "'");
   
   if(EnableRSIReversalAUDUSD)
      if(!InitRSIReversalAsian(rraAUDUSDData, RRA_AUDUSD_Symbol, RRA_AUDUSD_RSIPeriod, RRA_AUDUSD_OverboughtLevel, RRA_AUDUSD_OversoldLevel,
                               RRA_AUDUSD_TakeProfitPips, RRA_AUDUSD_StopLossPips, RRA_AUDUSD_MaxLotSize,
                               RRA_AUDUSD_MaxSpread, RRA_AUDUSD_MaxDuration, RRA_AUDUSD_UseStopLoss,
                               RRA_AUDUSD_UseTakeProfit, RRA_AUDUSD_UseRSIExit, RRA_AUDUSD_RSIExitLevel,
                               RRA_AUDUSD_CloseOutsideSession, RRA_AUDUSD_TimeFrame, RRA_AUDUSD_MagicNumber, RRA_AUDUSD_Slippage))
         Print("Warning: RSIReversalAUDUSD strategy failed to initialize for symbol '", RRA_AUDUSD_Symbol, "'");

   if(EnableRSISecretSauceXAUUSD)
      if(!InitRSISecretSauce(rsSecretSauceXAUUSDData, RSS_XAUUSD_Symbol, RSS_XAUUSD_Timeframe, RSS_XAUUSD_RSIPeriod,
                               RSS_XAUUSD_RSIOverbought, RSS_XAUUSD_RSIOversold, RSS_XAUUSD_RSILookback, RSS_XAUUSD_PeakBars,
                               RSS_XAUUSD_RequireDivergence, RSS_XAUUSD_StopLossATR, RSS_XAUUSD_TakeProfitATR, RSS_XAUUSD_ATRPeriod,
                               RSS_XAUUSD_UseSwingStopLoss, RSS_XAUUSD_SwingLookback, RSS_XAUUSD_MaxPositions,
                               RSS_XAUUSD_MinBarsBetweenTrades, RSS_XAUUSD_MagicNumber, RSS_XAUUSD_Slippage))
         Print("Warning: RSISecretSauceXAUUSD failed to initialize for symbol '", RSS_XAUUSD_Symbol, "'");

   if(EnableSuperEMA)
      if(!InitSuperEMA(seData, SE_Symbol, SE_Timeframe, SE_SlippagePoints, SE_MagicNumber,
                       SE_EmaFast, SE_EmaMid, SE_EmaSlow, SE_EmaTrendBars,
                       SE_CciPeriod, SE_CciOverbought, SE_CciOversold, SE_PullbackCciLookback,
                       SE_MacdFast, SE_MacdSlow, SE_MacdSignal,
                       SE_EntryStyle, SE_OneTradeOnly, SE_UseStructuralSL, SE_SlBufferPoints,
                       SE_ExitOnTrendFlip, SE_ExitOnMacdFlip, SE_ExitOnCciZeroCross,
                       SE_MaxHoldingBars, SE_ExitBelowMidEma, SE_DebugLogs))
         Print("Warning: SuperEMA failed to initialize for symbol '", SE_Symbol, "'");
   
   string acctCur = AccountInfoString(ACCOUNT_CURRENCY);
   double eq0 = AccountInfoDouble(ACCOUNT_EQUITY);
   double refvInit = MathMax(InpDynamicRefDeposit, 1.0);
   double capInit = InpDynamicUseEquity ? eq0 : AccountInfoDouble(ACCOUNT_BALANCE);
   if(capInit <= 0.0)
      capInit = refvInit;
   double ratioInit = capInit / refvInit;
   double rawPowInit = MathPow(ratioInit, InpDynamicExponent);
   Print("United EA v1.17 ", acctCur, " equity=", DoubleToString(eq0, 2), " equity/ref=", DoubleToString(ratioInit, 6),
         " raw^exp=", DoubleToString(rawPowInit, 6), " multOut=", DoubleToString(g_DynMultLast, 6),
         " minM=", InpDynamicMinMult, " maxM=", InpDynamicMaxMult, " ref=", InpDynamicRefDeposit, " exp=", InpDynamicExponent,
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
         (EnableRSIReversalEURUSD ? "RSIReversalEURUSD " : ""),
         (EnableRSIReversalAUDUSD ? "RSIReversalAUDUSD " : ""),
         (EnableRSISecretSauceXAUUSD ? "RSISecretSauceXAUUSD " : ""),
         (EnableSuperEMA ? "SuperEMA " : ""));

   EventSetTimer(0);
   int timerSec = 0;
   if(UnitedPanel_Enable)
      timerSec = MathMax(5, UnitedPanel_Seconds);
   if(InpAdaptiveEnable)
   {
      const int adSec = MathMax(60, InpAdaptiveUpdateSeconds);
      timerSec = (timerSec == 0) ? adSec : MathMin(timerSec, adSec);
   }
   if(InpDdLotCapEnable && InpDdLotCapPerStratEnable && !InpAdaptiveEnable)
   {
      const int ddSec = MathMax(60, InpDdLotCapUpdateSeconds);
      timerSec = (timerSec == 0) ? ddSec : MathMin(timerSec, ddSec);
   }
   if(timerSec > 0)
      EventSetTimer(timerSec);
   UnitedProfitPanelInit();

   return initResult;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventSetTimer(0);
   UnitedProfitPanelDeinit();

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
   
   if(EnableRSIReversalEURUSD)
      DeinitRSIReversalAsian(rraEURUSDData);
   
   if(EnableRSIReversalAUDUSD)
      DeinitRSIReversalAsian(rraAUDUSDData);

   if(EnableRSISecretSauceXAUUSD)
      DeinitRSISecretSauce(rsSecretSauceXAUUSDData);

   if(EnableSuperEMA)
      DeinitSuperEMA(seData);
   
   Print("United EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UnitedAdaptive_ProcessCanaryTransitions();
   RefreshDynamicStrategyLots();
   
   if(EnableDarvasBox && UnitedAdaptive_StrategyActive(UNITED_AD_DARVAS))
      ProcessDarvasBox(DB_Symbol);
   
   if(EnableEMASlopeDistance && UnitedAdaptive_StrategyActive(UNITED_AD_ES))
      ProcessEMASlopeDistance(ES_Symbol);
   
   if(EnableRSICrossOverReversal && UnitedAdaptive_StrategyActive(UNITED_AD_RC))
      ProcessRSICrossOverReversal(RC_Symbol);
   
   if(EnableRSIMidPointHijack && UnitedAdaptive_StrategyActive(UNITED_AD_RM))
      ProcessRSIMidPointHijack(RM_Symbol);
   
   if(EnableRSIScalpingAPPL && UnitedAdaptive_StrategyActive(UNITED_AD_RS_APPL))
      ProcessRSIScalping(rsAPPLData, RS_APPL_Symbol, RS_APPL_TimeFrame, RS_APPL_RSI_Period, RS_APPL_RSI_Applied_Price,
                        RS_APPL_RSI_Overbought, RS_APPL_RSI_Oversold, RS_APPL_RSI_Target_Buy, RS_APPL_RSI_Target_Sell,
                        RS_APPL_BarsToWait,
                        DynamicLotForSymbol(RS_APPL_Symbol, RS_APPL_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RS_APPL), InpDynamicStockLotCap, UNITED_AD_RS_APPL),
                        RS_APPL_MagicNumber);
   
   if(EnableRSIScalpingBTCUSD && UnitedAdaptive_StrategyActive(UNITED_AD_RS_BTC))
      ProcessRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price,
                        RS_BTCUSD_RSI_Overbought, RS_BTCUSD_RSI_Oversold, RS_BTCUSD_RSI_Target_Buy, RS_BTCUSD_RSI_Target_Sell,
                        RS_BTCUSD_BarsToWait, DynamicLotForSymbol(RS_BTCUSD_Symbol, RS_BTCUSD_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RS_BTC), 0.0, UNITED_AD_RS_BTC), RS_BTCUSD_MagicNumber);
   
   if(EnableRSIScalpingNVDA && UnitedAdaptive_StrategyActive(UNITED_AD_RS_NVDA))
      ProcessRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price,
                        RS_NVDA_RSI_Overbought, RS_NVDA_RSI_Oversold, RS_NVDA_RSI_Target_Buy, RS_NVDA_RSI_Target_Sell,
                        RS_NVDA_BarsToWait,
                        DynamicLotForSymbol(RS_NVDA_Symbol, RS_NVDA_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RS_NVDA), InpDynamicStockLotCap, UNITED_AD_RS_NVDA),
                        RS_NVDA_MagicNumber);
   
   if(EnableRSIScalpingTSLA && UnitedAdaptive_StrategyActive(UNITED_AD_RS_TSLA))
      ProcessRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price,
                        RS_TSLA_RSI_Overbought, RS_TSLA_RSI_Oversold, RS_TSLA_RSI_Target_Buy, RS_TSLA_RSI_Target_Sell,
                        RS_TSLA_BarsToWait,
                        DynamicLotForSymbol(RS_TSLA_Symbol, RS_TSLA_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RS_TSLA), InpDynamicStockLotCap, UNITED_AD_RS_TSLA),
                        RS_TSLA_MagicNumber);
   
   if(EnableRSIScalpingXAUUSD && UnitedAdaptive_StrategyActive(UNITED_AD_RS_XAU))
      ProcessRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price,
                        RS_XAUUSD_RSI_Overbought, RS_XAUUSD_RSI_Oversold, RS_XAUUSD_RSI_Target_Buy, RS_XAUUSD_RSI_Target_Sell,
                        RS_XAUUSD_BarsToWait, DynamicLotForSymbol(RS_XAUUSD_Symbol, RS_XAUUSD_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RS_XAU), 0.0, UNITED_AD_RS_XAU), RS_XAUUSD_MagicNumber);
   
   if(EnableRSIReversalEURUSD && UnitedAdaptive_StrategyActive(UNITED_AD_RRA_EUR))
      ProcessRSIReversalAsian(rraEURUSDData, DynamicLotForSymbol(RRA_EURUSD_Symbol, RRA_EURUSD_MaxLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RRA_EUR), 0.0, UNITED_AD_RRA_EUR));
   
   if(EnableRSIReversalAUDUSD && UnitedAdaptive_StrategyActive(UNITED_AD_RRA_AUD))
      ProcessRSIReversalAsian(rraAUDUSDData, DynamicLotForSymbol(RRA_AUDUSD_Symbol, RRA_AUDUSD_MaxLotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RRA_AUD), 0.0, UNITED_AD_RRA_AUD));

   if(EnableRSISecretSauceXAUUSD && UnitedAdaptive_StrategyActive(UNITED_AD_RSS))
      ProcessRSISecretSauce(rsSecretSauceXAUUSDData, DynamicLotForSymbol(RSS_XAUUSD_Symbol, RSS_XAUUSD_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_RSS), 0.0, UNITED_AD_RSS));

   if(EnableSuperEMA && UnitedAdaptive_StrategyActive(UNITED_AD_SUPEREMA))
      ProcessSuperEMA(seData, DynamicLotForSymbol(SE_Symbol, SE_LotSize * UnitedAdaptive_GetLotMult(UNITED_AD_SUPEREMA), 0.0, UNITED_AD_SUPEREMA));
}

//+------------------------------------------------------------------+
//| Timer — refresh profit panel (history scan)                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpAdaptiveEnable)
      UnitedAdaptive_ProcessCanaryTransitions();
   if(InpAdaptiveEnable || (InpDdLotCapEnable && InpDdLotCapPerStratEnable))
      UnitedAdaptive_UpdateIfDue();
   if(UnitedPanel_Enable)
      UnitedProfitPanelRefresh();
}

//+------------------------------------------------------------------+
//| Chart events — panel layout on resize                            |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   UnitedProfitPanelOnChartEvent(id);
}

//+------------------------------------------------------------------+
