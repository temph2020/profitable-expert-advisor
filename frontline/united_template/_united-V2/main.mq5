//+------------------------------------------------------------------+
//|                                                    UnitedEA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict
#property description "LOT_* nominal at ORCH_ReferenceBalance; scale = balance/equity ÷ reference (clamped). No performance-evaluator ranking."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Volumes.mqh>
#include "MagicNumberHelpers.mqh"
#define UNITED_V2_DYNAMIC_LOTS
double               g_DB_LotSize;
// Include strategy implementations early so structs are available
#include "Strategies/DarvasBoxStrategy.mqh"
#include "Strategies/EMASlopeDistanceStrategy.mqh"
#include "Strategies/RSICrossOverReversalStrategy.mqh"
#include "Strategies/RSIMidPointHijackStrategy.mqh"
#include "Strategies/RSIScalpingStrategy.mqh"
#include "Strategies/SuperEMAStrategy.mqh"
#include "Strategies/RSIReversalAsianStrategy.mqh"
#include "Strategies/RSIConsolidationStrategy.mqh"
#include "Strategies/SimpleTrendlineStrategy.mqh"

//+------------------------------------------------------------------+
//| Global Lot Size Variables (for dynamic lot sizing)               |
//+------------------------------------------------------------------+
double g_ES_LotSize;  // EMA Slope Distance lot size
double g_RC_LotSize;  // RSI CrossOver Reversal lot size
double g_RM_LotSize;  // RSI MidPoint Hijack lot size

double g_Pos_RS_APPL;
double g_Pos_RS_BTCUSD;
double g_Pos_RS_NVDA;
double g_Pos_RS_TSLA;
double g_Pos_RS_XAUUSD;
double g_Pos_RRA_EURUSD;
double g_Pos_RRA_AUDUSD;
double g_Pos_SE;
double g_Pos_RCO;
double g_Pos_ST_BTCUSD;
double g_Pos_ST_XAUUSD;

bool United_MayOpenNewEntry(const string symbol, const ulong magic, const bool isBuy)
{
   if(PositionExistsByMagic(symbol, magic))
      return false;
   return true;
}

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
input bool EnableSuperEMA = true;
input bool EnableRSIConsolidation = true;
input bool EnableRSIReversalAsianEURUSD = true;
input bool EnableRSIReversalAsianAUDUSD = true;
input bool EnableSimpleTrendlineBTCUSD = true;
input bool EnableSimpleTrendlineXAUUSD = true;

input group "=== Centralized Lot Size (Granular Per Robot) ==="
input double LOT_DB_DarvasBox = 0.01;
input double LOT_ES_EMASlopeDistance = 0.05;
input double LOT_RC_RSICrossOver = 0.1;
input double LOT_RM_RSIMidPointHijack = 0.01;
input double LOT_RS_APPL = 100.0;
input double LOT_RS_BTCUSD = 0.15;
input double LOT_RS_NVDA = 60.0;
input double LOT_RS_TSLA = 20.0;
input double LOT_RS_XAUUSD = 0.02;
input double LOT_RRA_EURUSD = 0.01;
input double LOT_RRA_AUDUSD = 0.10;
input double LOT_SE_SuperEMA = 0.01;
input double LOT_RCO_RSIConsolidation = 0.04;
input double LOT_ST_BTCUSD = 0.19;
input double LOT_ST_XAUUSD = 0.02;

input group "=== Balance-based position sizing ==="
input bool   ORCH_ScaleLotsByBalance = true;
input bool   ORCH_UseEquityInsteadOfBalance = false;
input double ORCH_ReferenceBalance = 10000.0;
input double ORCH_MinBalanceScale = 0.1;
input double ORCH_MaxBalanceScale = 10.0;

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
input bool   RC_UseTrendStrengthFilter = true;
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

input group "=== RSI Scalping Reversal Escape (XAUUSD only) ==="
input bool   RS_UseReversalEscape = true;
input int    RS_ReversalATRPeriod = 14;
input double RS_ReversalAdverseAtrMult = 5.25;
input int    RS_ReversalSignsRequired = 2;
input double RS_ReversalRsiVelocity = 16.0;
input double RS_ReversalBodyAtrMult = 5.1;

//+------------------------------------------------------------------+
//| Strategy 11-12: RSI Reversal Asian Strategies                    |
//| Each RSI Reversal Asian strategy trades on its own symbol:       |
//| - EURUSD: Euro/USD                                                |
//| - AUDUSD: Australian Dollar/USD                                   |
//+------------------------------------------------------------------+
input group "=== RSI Reversal Asian EURUSD ==="
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

input group "=== RSI Reversal Asian AUDUSD ==="
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

input group "=== RSI Consolidation (ranging / mean-reversion) ==="
input string              RCO_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES     RCO_SignalTF = PERIOD_M15;
input bool                RCO_EntryOnNewBarOnly = true;
input int                 RCO_ADX_Period = 23;
input double              RCO_ADX_Max = 29.0;
input bool                RCO_UseATRRatioFilter = true;
input int                 RCO_ATR_Period = 8;
input int                 RCO_ATR_SMA_Period = 35;
input double              RCO_ATR_Ratio_Max = 1.36;
input bool                RCO_UseFlatEMAFilter = true;
input int                 RCO_EMA_Fast = 13;
input int                 RCO_EMA_Slow = 17;
input double              RCO_EMA_Separation_MaxPct = 0.26;
input int                 RCO_RSI_Period = 8;
input ENUM_APPLIED_PRICE  RCO_RSI_Price = PRICE_OPEN;
input double              RCO_RSI_Oversold = 22.0;
input double              RCO_RSI_Overbought = 63.0;
input bool                RCO_UseRSI_MeanExit = true;
input double              RCO_RSI_Exit_Long = 48.0;
input double              RCO_RSI_Exit_Short = 52.0;
input double              RCO_SL_ATR_Mult = 2.15;
input double              RCO_TP_ATR_Mult = 2.40;
input int                 RCO_MaxBarsInTrade = 54;
input double              RCO_Lots = 0.10;
input ulong               RCO_MagicNumber = 20250420;
input int                 RCO_Slippage = 10;
input int                 RCO_MaxSpreadPoints = 28;

input group "=== SimpleTrendline BTCUSD ==="
input string              ST_BTC_Symbol = "BTCUSD";
input ENUM_TIMEFRAMES     ST_BTC_SignalTF = PERIOD_H1;
input ENUM_TIMEFRAMES     ST_BTC_HigherTF = PERIOD_H4;
input int                 ST_BTC_MAPeriod = 150;
input ENUM_MA_METHOD      ST_BTC_MAMethod = MODE_SMMA;
input ENUM_APPLIED_PRICE  ST_BTC_AppliedPrice = PRICE_OPEN;
input int                 ST_BTC_HTFBarsToScan = 1200;
input double              ST_BTC_LineTouchTolerance = 170.0;
input double              ST_BTC_BreakBuffer = 90.0;
input ulong               ST_BTC_MagicNumber = 26042501;
input bool                ST_BTC_DrawTrendline = true;

input group "=== SimpleTrendline XAUUSD ==="
input string              ST_XAU_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES     ST_XAU_SignalTF = PERIOD_H1;
input ENUM_TIMEFRAMES     ST_XAU_HigherTF = PERIOD_M10;
input int                 ST_XAU_MAPeriod = 65;
input ENUM_MA_METHOD      ST_XAU_MAMethod = MODE_EMA;
input ENUM_APPLIED_PRICE  ST_XAU_AppliedPrice = PRICE_OPEN;
input int                 ST_XAU_HTFBarsToScan = 500;
input double              ST_XAU_LineTouchTolerance = 220.0;
input double              ST_XAU_BreakBuffer = 110.0;
input ulong               ST_XAU_MagicNumber = 26042503;
input bool                ST_XAU_DrawTrendline = true;

//+------------------------------------------------------------------+
//| Balance scaling: LOT_* = nominal size at ORCH_ReferenceBalance    |
//+------------------------------------------------------------------+
double United_BalanceScaleFactor()
{
   if(!ORCH_ScaleLotsByBalance || ORCH_ReferenceBalance <= 0.0)
      return 1.0;
   const double money = ORCH_UseEquityInsteadOfBalance
                        ? AccountInfoDouble(ACCOUNT_EQUITY)
                        : AccountInfoDouble(ACCOUNT_BALANCE);
   double raw = money / ORCH_ReferenceBalance;
   if(raw < ORCH_MinBalanceScale)
      raw = ORCH_MinBalanceScale;
   if(raw > ORCH_MaxBalanceScale)
      raw = ORCH_MaxBalanceScale;
   return raw;
}

double United_ScaledLot(const double baseLot)
{
   const double lot = baseLot * United_BalanceScaleFactor();
   return (lot > 0.0 ? lot : 0.0);
}

void United_RefreshScaledLots()
{
   g_DB_LotSize = United_ScaledLot(LOT_DB_DarvasBox);
   g_ES_LotSize = United_ScaledLot(LOT_ES_EMASlopeDistance);
   g_RC_LotSize = United_ScaledLot(LOT_RC_RSICrossOver);
   g_RM_LotSize = United_ScaledLot(LOT_RM_RSIMidPointHijack);
   g_Pos_RS_APPL = United_ScaledLot(LOT_RS_APPL);
   g_Pos_RS_BTCUSD = United_ScaledLot(LOT_RS_BTCUSD);
   g_Pos_RS_NVDA = United_ScaledLot(LOT_RS_NVDA);
   g_Pos_RS_TSLA = United_ScaledLot(LOT_RS_TSLA);
   g_Pos_RS_XAUUSD = United_ScaledLot(LOT_RS_XAUUSD);
   g_Pos_RRA_EURUSD = United_ScaledLot(LOT_RRA_EURUSD);
   g_Pos_RRA_AUDUSD = United_ScaledLot(LOT_RRA_AUDUSD);
   g_Pos_SE = United_ScaledLot(LOT_SE_SuperEMA);
   g_Pos_RCO = United_ScaledLot(LOT_RCO_RSIConsolidation);
   g_Pos_ST_BTCUSD = United_ScaledLot(LOT_ST_BTCUSD);
   g_Pos_ST_XAUUSD = United_ScaledLot(LOT_ST_XAUUSD);
}

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
SuperEMAData seData;
RSIConsolidationData rcoData;
SimpleTrendlineData stBTCData;
SimpleTrendlineData stXAUData;

//+------------------------------------------------------------------+
//| Global Variables - RSI Reversal Asian                            |
//+------------------------------------------------------------------+
RSIReversalAsianData rraEURUSDData;
RSIReversalAsianData rraAUDUSDData;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int initResult = INIT_SUCCEEDED;
   
   United_RefreshScaledLots();
   
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

   if(EnableSuperEMA)
      if(!InitSuperEMA(seData, SE_Symbol, SE_Timeframe, SE_SlippagePoints, SE_MagicNumber,
                       SE_EmaFast, SE_EmaMid, SE_EmaSlow, SE_EmaTrendBars,
                       SE_CciPeriod, SE_CciOverbought, SE_CciOversold, SE_PullbackCciLookback,
                       SE_MacdFast, SE_MacdSlow, SE_MacdSignal,
                       SE_EntryStyle, SE_OneTradeOnly, SE_UseStructuralSL, SE_SlBufferPoints,
                       SE_ExitOnTrendFlip, SE_ExitOnMacdFlip, SE_ExitOnCciZeroCross,
                       SE_MaxHoldingBars, SE_ExitBelowMidEma, SE_DebugLogs))
         Print("Warning: SuperEMA failed to initialize for symbol '", SE_Symbol, "'");

   if(EnableRSIConsolidation)
      if(!InitRSIConsolidation(rcoData, RCO_Symbol, RCO_SignalTF, RCO_EntryOnNewBarOnly,
            RCO_ADX_Period, RCO_ADX_Max, RCO_UseATRRatioFilter, RCO_ATR_Period, RCO_ATR_SMA_Period, RCO_ATR_Ratio_Max,
            RCO_UseFlatEMAFilter, RCO_EMA_Fast, RCO_EMA_Slow, RCO_EMA_Separation_MaxPct,
            RCO_RSI_Period, RCO_RSI_Price, RCO_RSI_Oversold, RCO_RSI_Overbought,
            RCO_UseRSI_MeanExit, RCO_RSI_Exit_Long, RCO_RSI_Exit_Short, RCO_SL_ATR_Mult, RCO_TP_ATR_Mult,
            RCO_MaxBarsInTrade, RCO_MagicNumber, RCO_Slippage, RCO_MaxSpreadPoints))
         Print("Warning: RSIConsolidation failed to initialize for symbol '", RCO_Symbol, "'");
   
   // Initialize RSI Reversal Asian strategies
   if(EnableRSIReversalAsianEURUSD)
      if(!InitRSIReversalAsian(rraEURUSDData, RRA_EURUSD_Symbol, RRA_EURUSD_RSIPeriod, RRA_EURUSD_OverboughtLevel, RRA_EURUSD_OversoldLevel,
                               RRA_EURUSD_TakeProfitPips, RRA_EURUSD_StopLossPips, LOT_RRA_EURUSD,
                               RRA_EURUSD_MaxSpread, RRA_EURUSD_MaxDuration, RRA_EURUSD_UseStopLoss,
                               RRA_EURUSD_UseTakeProfit, RRA_EURUSD_UseRSIExit, RRA_EURUSD_RSIExitLevel,
                               RRA_EURUSD_CloseOutsideSession, RRA_EURUSD_TimeFrame, RRA_EURUSD_MagicNumber, RRA_EURUSD_Slippage))
         Print("Warning: RSIReversalAsianEURUSD strategy failed to initialize for symbol '", RRA_EURUSD_Symbol, "'");
   
   if(EnableRSIReversalAsianAUDUSD)
      if(!InitRSIReversalAsian(rraAUDUSDData, RRA_AUDUSD_Symbol, RRA_AUDUSD_RSIPeriod, RRA_AUDUSD_OverboughtLevel, RRA_AUDUSD_OversoldLevel,
                               RRA_AUDUSD_TakeProfitPips, RRA_AUDUSD_StopLossPips, LOT_RRA_AUDUSD,
                               RRA_AUDUSD_MaxSpread, RRA_AUDUSD_MaxDuration, RRA_AUDUSD_UseStopLoss,
                               RRA_AUDUSD_UseTakeProfit, RRA_AUDUSD_UseRSIExit, RRA_AUDUSD_RSIExitLevel,
                               RRA_AUDUSD_CloseOutsideSession, RRA_AUDUSD_TimeFrame, RRA_AUDUSD_MagicNumber, RRA_AUDUSD_Slippage))
         Print("Warning: RSIReversalAsianAUDUSD strategy failed to initialize for symbol '", RRA_AUDUSD_Symbol, "'");

   if(EnableSimpleTrendlineBTCUSD)
      if(!InitSimpleTrendline(stBTCData, ST_BTC_Symbol, ST_BTC_SignalTF, ST_BTC_HigherTF, ST_BTC_MAPeriod,
                              ST_BTC_MAMethod, ST_BTC_AppliedPrice, ST_BTC_HTFBarsToScan,
                              ST_BTC_LineTouchTolerance, ST_BTC_BreakBuffer, ST_BTC_MagicNumber, ST_BTC_DrawTrendline))
         Print("Warning: SimpleTrendlineBTCUSD failed to initialize for symbol '", ST_BTC_Symbol, "'");

   if(EnableSimpleTrendlineXAUUSD)
      if(!InitSimpleTrendline(stXAUData, ST_XAU_Symbol, ST_XAU_SignalTF, ST_XAU_HigherTF, ST_XAU_MAPeriod,
                              ST_XAU_MAMethod, ST_XAU_AppliedPrice, ST_XAU_HTFBarsToScan,
                              ST_XAU_LineTouchTolerance, ST_XAU_BreakBuffer, ST_XAU_MagicNumber, ST_XAU_DrawTrendline))
         Print("Warning: SimpleTrendlineXAUUSD failed to initialize for symbol '", ST_XAU_Symbol, "'");
   
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
         (EnableSuperEMA ? "SuperEMA " : ""),
         (EnableRSIConsolidation ? "RSIConsolidation " : ""),
         (EnableRSIReversalAsianEURUSD ? "RSIReversalAsianEURUSD " : ""),
         (EnableRSIReversalAsianAUDUSD ? "RSIReversalAsianAUDUSD " : ""),
         (EnableSimpleTrendlineBTCUSD ? "SimpleTrendlineBTCUSD " : ""),
         (EnableSimpleTrendlineXAUUSD ? "SimpleTrendlineXAUUSD " : ""));
   
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

   if(EnableSuperEMA)
      DeinitSuperEMA(seData);

   if(EnableRSIConsolidation)
      DeinitRSIConsolidation(rcoData);
   
   if(EnableRSIReversalAsianEURUSD)
      DeinitRSIReversalAsian(rraEURUSDData);
   
   if(EnableRSIReversalAsianAUDUSD)
      DeinitRSIReversalAsian(rraAUDUSDData);

   if(EnableSimpleTrendlineBTCUSD)
      DeinitSimpleTrendline(stBTCData);
   if(EnableSimpleTrendlineXAUUSD)
      DeinitSimpleTrendline(stXAUData);
   
   Print("United EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   United_RefreshScaledLots();

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
                        RS_APPL_BarsToWait, g_Pos_RS_APPL, RS_APPL_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult);
   
   if(EnableRSIScalpingBTCUSD)
      ProcessRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price,
                        RS_BTCUSD_RSI_Overbought, RS_BTCUSD_RSI_Oversold, RS_BTCUSD_RSI_Target_Buy, RS_BTCUSD_RSI_Target_Sell,
                        RS_BTCUSD_BarsToWait, g_Pos_RS_BTCUSD, RS_BTCUSD_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult);
   
   if(EnableRSIScalpingNVDA)
      ProcessRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price,
                        RS_NVDA_RSI_Overbought, RS_NVDA_RSI_Oversold, RS_NVDA_RSI_Target_Buy, RS_NVDA_RSI_Target_Sell,
                        RS_NVDA_BarsToWait, g_Pos_RS_NVDA, RS_NVDA_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult);
   
   if(EnableRSIScalpingTSLA)
      ProcessRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price,
                        RS_TSLA_RSI_Overbought, RS_TSLA_RSI_Oversold, RS_TSLA_RSI_Target_Buy, RS_TSLA_RSI_Target_Sell,
                        RS_TSLA_BarsToWait, g_Pos_RS_TSLA, RS_TSLA_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult);
   
   if(EnableRSIScalpingXAUUSD)
      ProcessRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price,
                        RS_XAUUSD_RSI_Overbought, RS_XAUUSD_RSI_Oversold, RS_XAUUSD_RSI_Target_Buy, RS_XAUUSD_RSI_Target_Sell,
                        RS_XAUUSD_BarsToWait, g_Pos_RS_XAUUSD, RS_XAUUSD_MagicNumber,
                        RS_UseReversalEscape, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult);
   
   if(EnableRSIReversalAsianEURUSD)
      ProcessRSIReversalAsian(rraEURUSDData, g_Pos_RRA_EURUSD);
   
   if(EnableRSIReversalAsianAUDUSD)
      ProcessRSIReversalAsian(rraAUDUSDData, g_Pos_RRA_AUDUSD);

   if(EnableSuperEMA)
      ProcessSuperEMA(seData, g_Pos_SE);

   if(EnableRSIConsolidation)
      ProcessRSIConsolidation(rcoData, g_Pos_RCO);

   if(EnableSimpleTrendlineBTCUSD)
      ProcessSimpleTrendline(stBTCData, g_Pos_ST_BTCUSD);
   if(EnableSimpleTrendlineXAUUSD)
      ProcessSimpleTrendline(stXAUData, g_Pos_ST_XAUUSD);
}

//+------------------------------------------------------------------+
