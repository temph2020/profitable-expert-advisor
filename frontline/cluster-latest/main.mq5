//+------------------------------------------------------------------+
//|                                                    UnitedEA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.26"
#property strict
#property description "LOT_* nominal at ORCH_ReferenceBalance; scale = balance/equity ÷ reference (clamped). No performance-evaluator ranking."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Volumes.mqh>
#include "MagicNumberHelpers.mqh"
#include "GapGuard.mqh"
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
#include "Strategies/RSISecretSauceStrategy.mqh"
#include "Strategies/USDJPYBusterStrategy.mqh"
#include "Strategies/XAUBearTrendStrategy.mqh"
#include "Strategies/XAUMomentumBreakdownStrategy.mqh"

//+------------------------------------------------------------------+
//| Global Lot Size Variables (for dynamic lot sizing)               |
//+------------------------------------------------------------------+
double g_ES_LotSize;  // EMA Slope Distance lot size
double g_RC_LotSize;  // RSI CrossOver Reversal lot size
double g_RM_LotSize;  // RSI MidPoint Hijack lot size

double g_Pos_RS_APPL;
double g_Pos_RS_ADBE;
double g_Pos_RS_BTCUSD;
double g_Pos_RS_NVDA;
double g_Pos_RS_TSLA;
double g_Pos_RS_XAUUSD;
double g_Pos_RS_MU;
double g_Pos_RRA_EURUSD;
double g_Pos_RRA_AUDUSD;
double g_Pos_SE;
double g_Pos_RCO;
double g_Pos_ST_BTCUSD;
double g_Pos_ST_XAUUSD;
double g_Pos_ST_GER40;
double g_RSS_LotSize;
double g_Pos_UB_USDJPY;
double g_Pos_XBT_XAUUSD;
double g_Pos_XMB_XAUUSD;
double g_Pos_RRA_GBPUSD;
double g_Pos_GB_GER40;
double g_Pos_RS_NAS100;
double g_Pos_RS_US500;
double g_Pos_RRA_USDCHF;
double g_Pos_RRA_NZDUSD;
double g_Pos_NB_NAS100;
double g_Pos_U5B_US500;
double g_Pos_RS_US30;
double g_Pos_RS_XAGUSD;
double g_Pos_RS_EURJPY;
double g_Pos_RS_GBPJPY;
double g_Pos_U30B_US30;
double g_Pos_UKB_UK100;
double g_Pos_XGB_XAGUSD;
double g_Pos_RS_F;
double g_Pos_RS_SOFI;
double g_Pos_RS_SNAP;
double g_Pos_RS_WBD;

input group "=== Signal Replacement — close unprofitable on new signal (per strategy) ==="
input bool DB_CloseUnprofitableOnNewSignal = false;
input bool ES_CloseUnprofitableOnNewSignal = true;   // audit 2026-07 +174 net / +1.46 sharpe
input bool RC_CloseUnprofitableOnNewSignal = false;
input bool RM_CloseUnprofitableOnNewSignal = false;
input bool RS_APPL_CloseUnprofitableOnNewSignal = false;
input bool RS_ADBE_CloseUnprofitableOnNewSignal = false;
input bool RS_BTCUSD_CloseUnprofitableOnNewSignal = false;
input bool RS_NVDA_CloseUnprofitableOnNewSignal = false;
input bool RS_TSLA_CloseUnprofitableOnNewSignal = false;   // audit 2026-07 NEUTRAL (-11 net)
input bool RS_XAUUSD_CloseUnprofitableOnNewSignal = true;   // audit 2026-07 +677 net / +1.92 sharpe
input bool RS_MU_CloseUnprofitableOnNewSignal = false;
input bool RRA_EURUSD_CloseUnprofitableOnNewSignal = false;
input bool RRA_AUDUSD_CloseUnprofitableOnNewSignal = false;
input bool SE_CloseUnprofitableOnNewSignal = false;
input bool RCO_CloseUnprofitableOnNewSignal = false;
input bool ST_BTC_CloseUnprofitableOnNewSignal = false;
input bool ST_XAU_CloseUnprofitableOnNewSignal = false;
input bool ST_GER_CloseUnprofitableOnNewSignal = false;
input bool RSS_CloseUnprofitableOnNewSignal = false;
input bool UB_CloseUnprofitableOnNewSignal = false;
input bool XBT_CloseUnprofitableOnNewSignal = false;
input bool XMB_CloseUnprofitableOnNewSignal = false;
input bool RRA_GBPUSD_CloseUnprofitableOnNewSignal = false;
input bool GB_CloseUnprofitableOnNewSignal = false;
input bool RS_NAS100_CloseUnprofitableOnNewSignal = false;
input bool RS_US500_CloseUnprofitableOnNewSignal = false;
input bool RRA_USDCHF_CloseUnprofitableOnNewSignal = false;
input bool RRA_NZDUSD_CloseUnprofitableOnNewSignal = false;
input bool NB_CloseUnprofitableOnNewSignal = false;
input bool U5B_CloseUnprofitableOnNewSignal = false;
input bool RS_US30_CloseUnprofitableOnNewSignal = true;   // audit 2026-07 +92 net / +0.68 sharpe
input bool RS_XAGUSD_CloseUnprofitableOnNewSignal = false;
input bool RS_EURJPY_CloseUnprofitableOnNewSignal = false;
input bool RS_GBPJPY_CloseUnprofitableOnNewSignal = false;
input bool U30B_CloseUnprofitableOnNewSignal = false;
input bool UKB_CloseUnprofitableOnNewSignal = false;
input bool XGB_CloseUnprofitableOnNewSignal = false;
input bool RS_F_CloseUnprofitableOnNewSignal = false;
input bool RS_SOFI_CloseUnprofitableOnNewSignal = false;
input bool RS_SNAP_CloseUnprofitableOnNewSignal = false;
input bool RS_WBD_CloseUnprofitableOnNewSignal = false;

bool United_MayOpenNewEntry(const string symbol, const ulong magic, const bool isBuy, CTrade &trade,
                              const bool closeUnprofitableOnNewSignal)
{
   if(!United_PrepareEntrySlot(trade, symbol, magic, closeUnprofitableOnNewSignal))
      return false;
   if(United_IsGapRiskWindow(symbol))
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
input bool EnableRSIScalpingAPPL = false;
input bool EnableRSIScalpingADBE = false;
input bool EnableRSIScalpingBTCUSD = true;
input bool EnableRSIScalpingNVDA = true;
input bool EnableRSIScalpingTSLA = true;
input bool EnableRSIScalpingXAUUSD = true;
input bool EnableRSIScalpingMU = false;  // high share price (~$1000+) — margin risk
input bool EnableSuperEMA = true;
input bool EnableRSIConsolidation = false;
input bool EnableRSIReversalAsianEURUSD = false;
input bool EnableRSIReversalAsianAUDUSD = true;
input bool EnableSimpleTrendlineBTCUSD = true;
input bool EnableSimpleTrendlineXAUUSD = true;
input bool EnableSimpleTrendlineGER40 = false;
input bool EnableRSISecretSauce = false;
input bool EnableUSDJPYBuster = true;
input bool EnableXAUBearTrend = false;
input bool EnableXAUMomentumBreakdown = false;
input bool EnableRSIReversalAsianGBPUSD = true;
input bool EnableGER40Buster = true;
input bool EnableRSIScalpingNAS100 = true;
input bool EnableRSIScalpingUS500 = false;
input bool EnableRSIReversalAsianUSDCHF = false;
input bool EnableRSIReversalAsianNZDUSD = false;
input bool EnableNAS100Buster = false;
input bool EnableUS500Buster = true;
input bool EnableRSIScalpingUS30 = true;
input bool EnableRSIScalpingXAGUSD = false;
input bool EnableRSIScalpingEURJPY = false;
input bool EnableRSIScalpingGBPJPY = false;
input bool EnableUS30Buster = false;
input bool EnableUK100Buster = true;
input bool EnableXAGUSDBuster = false;
input bool EnableRSIScalpingF = false;
input bool EnableRSIScalpingSOFI = false;
input bool EnableRSIScalpingSNAP = false;
input bool EnableRSIScalpingWBD = false;
input bool OPT_GuardOptimizationMode = true; // legacy compatibility with 123.set

input group "=== Centralized Lot Size (Granular Per Robot) ==="
input double LOT_DB_DarvasBox = 0.01;
input double LOT_ES_EMASlopeDistance = 0.07;
input double LOT_RC_RSICrossOver = 0.1;
input double LOT_RM_RSIMidPointHijack = 0.01;
input double LOT_RS_APPL = 5;
input double LOT_RS_ADBE = 5;
input double LOT_RS_BTCUSD = 0.06;
input double LOT_RS_NVDA = 5;
input double LOT_RS_TSLA = 5;
input double LOT_RS_XAUUSD = 0.04;
input double LOT_RS_MU = 5.0;
input double LOT_RRA_EURUSD = 0.03;
input double LOT_RRA_AUDUSD = 0.05;
input double LOT_SE_SuperEMA = 0.01;
input double LOT_RCO_RSIConsolidation = 0.1;
input double LOT_ST_BTCUSD = 0.01;
input double LOT_ST_XAUUSD = 0.01;
input double LOT_ST_GER40 = 0.10;
input double LOT_RSS_SecretSauce = 0.1;
input double LOT_UB_USDJPY = 0.03;
input double LOT_XBT_XAUUSD = 0.02;
input double LOT_XMB_XAUUSD = 0.02;
input double LOT_RRA_GBPUSD = 0.03;
input double LOT_GB_GER40 = 0.01;
input double LOT_RS_NAS100 = 0.03;
input double LOT_RS_US500 = 0.1;
input double LOT_RRA_USDCHF = 0.1;
input double LOT_RRA_NZDUSD = 0.1;
input double LOT_NB_NAS100 = 0.05;
input double LOT_U5B_US500 = 0.05;
input double LOT_RS_US30 = 0.02;
input double LOT_RS_XAGUSD = 0.05;
input double LOT_RS_EURJPY = 0.08;
input double LOT_RS_GBPJPY = 0.08;
input double LOT_U30B_US30 = 0.05;
input double LOT_UKB_UK100 = 0.01;
input double LOT_XGB_XAGUSD = 0.05;
input double LOT_RS_F = 10.0;    // ~$14 stock, ~$7 margin @ 10 sh
input double LOT_RS_SOFI = 10.0;
input double LOT_RS_SNAP = 10.0;
input double LOT_RS_WBD = 10.0;

input group "=== Balance-based position sizing ==="
input bool   ORCH_ScaleLotsByBalance = true;
input bool   ORCH_UseEquityInsteadOfBalance = false;
input double ORCH_ReferenceBalance = 3000.0;
input double ORCH_MinBalanceScale = 0.1;
input double ORCH_MaxBalanceScale = 100000.0;

input group "=== Gap Loss Prevention (跳空) ==="
input bool   GAP_Enable = false;  // match 123.set / audit backtests (true = more session flats)
input bool   GAP_CloseBeforeSessionEnd = true;
input int    GAP_MinutesBeforeClose = 15;
input bool   GAP_CloseBeforeWeekend = true;
input int    GAP_FridayCloseHour = 20;
input bool   GAP_CloseOnBarGapThroughSL = true;
input double GAP_MinGapPoints = 0.0;
input int    GAP_EquityDailyFlatHour = 21;

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
input color  DB_BoxColor = (color)16711680;
input int    DB_BoxWidth = 1;
input ENUM_TIMEFRAMES DB_TrendTimeframe = PERIOD_H2;
input int    DB_MA_Period = 125;
input ENUM_MA_METHOD DB_MA_Method = MODE_EMA;
input ENUM_APPLIED_PRICE DB_MA_Price = PRICE_WEIGHTED;
input double DB_TrendThreshold = 4.94;
input int    DB_VolumeMA_Period = 110;
input double DB_VolumeThresholdMultiplier = 1.5;
input bool   DB_UseVolumeSpikeFilter = true;
input bool   DB_UseTrendFilter = true;
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
input double ES_TrailingStop = 370.0;
input bool   ES_UseTrailingStop = true;
input double ES_TrailingActivationPips = 0.0;
input bool   ES_UseStaleStopLossExit = false;
input int    ES_StaleStopLossSeconds = 33800;
input double ES_LotGröße = 0.07;
input int    ES_MagicNumber = 12350;
input bool   ES_UseSpreadAdjustment = true;
input ENUM_TIMEFRAMES ES_Timeframe = PERIOD_H1;
input bool   ES_UseBarData = true;
input int    ES_MaxTradesPerCrossover = 9;
input int    ES_ProfitCheckBars = 18;
input bool   ES_CloseUnprofitableTrades = true;
input bool   ES_UseWeeklyADXFilter = true;
input int    ES_WeeklyADXPeriod = 15;
input double ES_WeeklyADXMin = 40.0;
input int    ES_WeeklyADXBarShift = 2;
input bool   ES_WeeklyADXUseDirection = true;

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
input double RC_lotSize = 0.1;
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
input double RM_InpLotSize = 0.1;
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
input string RS_APPL_Symbol = "AAPL.NAS";
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

input group "=== RSI Scalping ADBE - Pepperstone US ==="
input string RS_ADBE_Symbol = "ADBE.NAS";
input ENUM_TIMEFRAMES RS_ADBE_TimeFrame = (ENUM_TIMEFRAMES)6;
input int    RS_ADBE_RSI_Period = 15;
input ENUM_APPLIED_PRICE RS_ADBE_RSI_Applied_Price = PRICE_OPEN;
input double RS_ADBE_RSI_Overbought = 16;
input double RS_ADBE_RSI_Oversold = 42;
input double RS_ADBE_RSI_Target_Buy = 67;
input double RS_ADBE_RSI_Target_Sell = 62;
input int    RS_ADBE_BarsToWait = 8;
input double RS_ADBE_LotSize = 5.0;
input int    RS_ADBE_MagicNumber = 12345;
input int    RS_ADBE_Slippage = 3;

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
input string RS_NVDA_Symbol = "NVDA.NAS";
input ENUM_TIMEFRAMES RS_NVDA_TimeFrame = PERIOD_M15;
input int    RS_NVDA_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_NVDA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_NVDA_RSI_Overbought = 36;
input double RS_NVDA_RSI_Oversold = 38;
input double RS_NVDA_RSI_Target_Buy = 90;
input double RS_NVDA_RSI_Target_Sell = 70;
input int    RS_NVDA_BarsToWait = 5;
input double RS_NVDA_LotSize = 5;
input int    RS_NVDA_MagicNumber = 20003;
input int    RS_NVDA_Slippage = 3;

input group "=== RSI Scalping TSLA - Pepperstone US ==="
input string RS_TSLA_Symbol = "TSLA.NAS";
input ENUM_TIMEFRAMES RS_TSLA_TimeFrame = PERIOD_H1;
input int    RS_TSLA_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_TSLA_RSI_Applied_Price = PRICE_CLOSE;
input double RS_TSLA_RSI_Overbought = 54;
input double RS_TSLA_RSI_Oversold = 73;
input double RS_TSLA_RSI_Target_Buy = 87;
input double RS_TSLA_RSI_Target_Sell = 33;
input int    RS_TSLA_BarsToWait = 1;
input double RS_TSLA_LotSize = 5;
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

input group "=== RSI Scalping MU ==="
input string RS_MU_Symbol = "MU.NAS";
input ENUM_TIMEFRAMES RS_MU_TimeFrame = PERIOD_M20;
input int    RS_MU_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_MU_RSI_Applied_Price = PRICE_CLOSE;
input double RS_MU_RSI_Overbought = 32;
input double RS_MU_RSI_Oversold = 86;
input double RS_MU_RSI_Target_Buy = 100;
input double RS_MU_RSI_Target_Sell = 24;
input int    RS_MU_BarsToWait = 34;
input double RS_MU_LotSize = 5.0;
input int    RS_MU_MagicNumber = 129102316;
input int    RS_MU_Slippage = 3;

input group "=== RSI Scalping NAS100 ==="
input string RS_NAS100_Symbol = "NAS100";
input ENUM_TIMEFRAMES RS_NAS100_TimeFrame = PERIOD_H1;
input int    RS_NAS100_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_NAS100_RSI_Applied_Price = PRICE_CLOSE;
input double RS_NAS100_RSI_Overbought = 58;
input double RS_NAS100_RSI_Oversold = 42;
input double RS_NAS100_RSI_Target_Buy = 78;
input double RS_NAS100_RSI_Target_Sell = 46;
input int    RS_NAS100_BarsToWait = 4;
input int    RS_NAS100_MagicNumber = 20005;
input int    RS_NAS100_Slippage = 5;

input group "=== RSI Scalping US500 ==="
input string RS_US500_Symbol = "US500";
input ENUM_TIMEFRAMES RS_US500_TimeFrame = PERIOD_H1;
input int    RS_US500_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_US500_RSI_Applied_Price = PRICE_CLOSE;
input double RS_US500_RSI_Overbought = 62;
input double RS_US500_RSI_Oversold = 38;
input double RS_US500_RSI_Target_Buy = 80;
input double RS_US500_RSI_Target_Sell = 44;
input int    RS_US500_BarsToWait = 5;
input int    RS_US500_MagicNumber = 20006;
input int    RS_US500_Slippage = 5;

input group "=== RSI Scalping US30 ==="
input string RS_US30_Symbol = "US30";
input ENUM_TIMEFRAMES RS_US30_TimeFrame = PERIOD_H1;
input int    RS_US30_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_US30_RSI_Applied_Price = PRICE_CLOSE;
input double RS_US30_RSI_Overbought = 56;
input double RS_US30_RSI_Oversold = 44;
input double RS_US30_RSI_Target_Buy = 76;
input double RS_US30_RSI_Target_Sell = 48;
input int    RS_US30_BarsToWait = 4;
input int    RS_US30_MagicNumber = 20007;
input int    RS_US30_Slippage = 5;

input group "=== RSI Scalping XAGUSD ==="
input string RS_XAGUSD_Symbol = "XAGUSD";
input ENUM_TIMEFRAMES RS_XAGUSD_TimeFrame = PERIOD_H1;
input int    RS_XAGUSD_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_XAGUSD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_XAGUSD_RSI_Overbought = 65;
input double RS_XAGUSD_RSI_Oversold = 35;
input double RS_XAGUSD_RSI_Target_Buy = 82;
input double RS_XAGUSD_RSI_Target_Sell = 42;
input int    RS_XAGUSD_BarsToWait = 5;
input int    RS_XAGUSD_MagicNumber = 20008;
input int    RS_XAGUSD_Slippage = 5;

input group "=== RSI Scalping EURJPY ==="
input string RS_EURJPY_Symbol = "EURJPY";
input ENUM_TIMEFRAMES RS_EURJPY_TimeFrame = PERIOD_M30;
input int    RS_EURJPY_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_EURJPY_RSI_Applied_Price = PRICE_CLOSE;
input double RS_EURJPY_RSI_Overbought = 60;
input double RS_EURJPY_RSI_Oversold = 40;
input double RS_EURJPY_RSI_Target_Buy = 75;
input double RS_EURJPY_RSI_Target_Sell = 45;
input int    RS_EURJPY_BarsToWait = 4;
input int    RS_EURJPY_MagicNumber = 20009;
input int    RS_EURJPY_Slippage = 3;

input group "=== RSI Scalping GBPJPY ==="
input string RS_GBPJPY_Symbol = "GBPJPY";
input ENUM_TIMEFRAMES RS_GBPJPY_TimeFrame = PERIOD_M30;
input int    RS_GBPJPY_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_GBPJPY_RSI_Applied_Price = PRICE_CLOSE;
input double RS_GBPJPY_RSI_Overbought = 62;
input double RS_GBPJPY_RSI_Oversold = 38;
input double RS_GBPJPY_RSI_Target_Buy = 78;
input double RS_GBPJPY_RSI_Target_Sell = 44;
input int    RS_GBPJPY_BarsToWait = 4;
input int    RS_GBPJPY_MagicNumber = 20010;
input int    RS_GBPJPY_Slippage = 3;

input group "=== RSI Scalping Reversal Escape (XAUUSD only) ==="
input bool   RS_UseReversalEscape = true;
input int    RS_ReversalATRPeriod = 14;
input double RS_ReversalAdverseAtrMult = 5.25;
input int    RS_ReversalSignsRequired = 2;
input double RS_ReversalRsiVelocity = 16.0;
input double RS_ReversalBodyAtrMult = 5.1;

input group "=== RSI Scalping APPL — Trailing (cluster-fuck BTC-style defaults) ==="
input bool   RS_APPL_UseTrailingStop = true;
input double RS_APPL_TrailDistancePoints = 120.0;
input double RS_APPL_TrailActivationPoints = 0.0;

input group "=== RSI Scalping ADBE — Trailing ==="
input bool   RS_ADBE_UseTrailingStop = true;
input double RS_ADBE_TrailDistancePoints = 425.0;
input double RS_ADBE_TrailActivationPoints = 18.5;

input group "=== RSI Scalping BTCUSD — Trailing ==="
input bool   RS_BTCUSD_UseTrailingStop = true;
input double RS_BTCUSD_TrailDistancePoints = 120.0;
input double RS_BTCUSD_TrailActivationPoints = 0.0;

input group "=== RSI Scalping NVDA — Trailing ==="
input bool   RS_NVDA_UseTrailingStop = true;
input double RS_NVDA_TrailDistancePoints = 375.0;
input double RS_NVDA_TrailActivationPoints = 75.0;

input group "=== RSI Scalping TSLA — Trailing ==="
input bool   RS_TSLA_UseTrailingStop = true;
input double RS_TSLA_TrailDistancePoints = 900.0;
input double RS_TSLA_TrailActivationPoints = 500.0;

input group "=== RSI Scalping XAUUSD — Trailing ==="
input bool   RS_XAUUSD_UseTrailingStop = true;
input double RS_XAUUSD_TrailDistancePoints = 71.0;
input double RS_XAUUSD_TrailActivationPoints = 41.0;

input group "=== RSI Scalping NAS100 — Trailing ==="
input bool   RS_NAS100_UseTrailingStop = true;
input double RS_NAS100_TrailDistancePoints = 180.0;
input double RS_NAS100_TrailActivationPoints = 60.0;

input group "=== RSI Scalping US500 — Trailing ==="
input bool   RS_US500_UseTrailingStop = true;
input double RS_US500_TrailDistancePoints = 150.0;
input double RS_US500_TrailActivationPoints = 50.0;

input group "=== RSI Scalping US30 — Trailing ==="
input bool   RS_US30_UseTrailingStop = true;
input double RS_US30_TrailDistancePoints = 200.0;
input double RS_US30_TrailActivationPoints = 70.0;

input group "=== RSI Scalping XAGUSD — Trailing ==="
input bool   RS_XAGUSD_UseTrailingStop = true;
input double RS_XAGUSD_TrailDistancePoints = 90.0;
input double RS_XAGUSD_TrailActivationPoints = 35.0;

input group "=== RSI Scalping EURJPY — Trailing ==="
input bool   RS_EURJPY_UseTrailingStop = true;
input double RS_EURJPY_TrailDistancePoints = 45.0;
input double RS_EURJPY_TrailActivationPoints = 20.0;

input group "=== RSI Scalping GBPJPY — Trailing ==="
input bool   RS_GBPJPY_UseTrailingStop = true;
input double RS_GBPJPY_TrailDistancePoints = 55.0;
input double RS_GBPJPY_TrailActivationPoints = 25.0;

input group "=== RSI Scalping F (Ford, low margin) ==="
input string RS_F_Symbol = "F.NYS";
input ENUM_TIMEFRAMES RS_F_TimeFrame = PERIOD_M15;
input int    RS_F_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_F_RSI_Applied_Price = PRICE_CLOSE;
input double RS_F_RSI_Overbought = 36;
input double RS_F_RSI_Oversold = 38;
input double RS_F_RSI_Target_Buy = 90;
input double RS_F_RSI_Target_Sell = 70;
input int    RS_F_BarsToWait = 5;
input int    RS_F_MagicNumber = 20011;
input int    RS_F_Slippage = 5;

input group "=== RSI Scalping SOFI (low margin) ==="
input string RS_SOFI_Symbol = "SOFI.NAS";
input ENUM_TIMEFRAMES RS_SOFI_TimeFrame = PERIOD_M15;
input int    RS_SOFI_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_SOFI_RSI_Applied_Price = PRICE_CLOSE;
input double RS_SOFI_RSI_Overbought = 36;
input double RS_SOFI_RSI_Oversold = 38;
input double RS_SOFI_RSI_Target_Buy = 90;
input double RS_SOFI_RSI_Target_Sell = 70;
input int    RS_SOFI_BarsToWait = 5;
input int    RS_SOFI_MagicNumber = 20012;
input int    RS_SOFI_Slippage = 5;

input group "=== RSI Scalping SNAP (Snap, ultra-low margin) ==="
input string RS_SNAP_Symbol = "SNAP.NYS";
input ENUM_TIMEFRAMES RS_SNAP_TimeFrame = PERIOD_M15;
input int    RS_SNAP_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_SNAP_RSI_Applied_Price = PRICE_CLOSE;
input double RS_SNAP_RSI_Overbought = 36;
input double RS_SNAP_RSI_Oversold = 38;
input double RS_SNAP_RSI_Target_Buy = 90;
input double RS_SNAP_RSI_Target_Sell = 70;
input int    RS_SNAP_BarsToWait = 5;
input int    RS_SNAP_MagicNumber = 20013;
input int    RS_SNAP_Slippage = 5;

input group "=== RSI Scalping WBD (Warner Bros, low margin) ==="
input string RS_WBD_Symbol = "WBD.NAS";
input ENUM_TIMEFRAMES RS_WBD_TimeFrame = PERIOD_M15;
input int    RS_WBD_RSI_Period = 8;
input ENUM_APPLIED_PRICE RS_WBD_RSI_Applied_Price = PRICE_CLOSE;
input double RS_WBD_RSI_Overbought = 36;
input double RS_WBD_RSI_Oversold = 38;
input double RS_WBD_RSI_Target_Buy = 90;
input double RS_WBD_RSI_Target_Sell = 70;
input int    RS_WBD_BarsToWait = 5;
input int    RS_WBD_MagicNumber = 20014;
input int    RS_WBD_Slippage = 5;

input group "=== RSI Scalping F — Trailing ==="
input bool   RS_F_UseTrailingStop = true;
input double RS_F_TrailDistancePoints = 375.0;
input double RS_F_TrailActivationPoints = 75.0;

input group "=== RSI Scalping SOFI — Trailing ==="
input bool   RS_SOFI_UseTrailingStop = true;
input double RS_SOFI_TrailDistancePoints = 375.0;
input double RS_SOFI_TrailActivationPoints = 75.0;

input group "=== RSI Scalping SNAP — Trailing ==="
input bool   RS_SNAP_UseTrailingStop = true;
input double RS_SNAP_TrailDistancePoints = 375.0;
input double RS_SNAP_TrailActivationPoints = 75.0;

input group "=== RSI Scalping WBD — Trailing ==="
input bool   RS_WBD_UseTrailingStop = true;
input double RS_WBD_TrailDistancePoints = 375.0;
input double RS_WBD_TrailActivationPoints = 75.0;

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
input ulong               ST_XAU_MagicNumber = 26042501;
input bool                ST_XAU_DrawTrendline = true;

input group "=== SimpleTrendline GER40 ==="
input string              ST_GER_Symbol = "GER40";
input ENUM_TIMEFRAMES     ST_GER_SignalTF = PERIOD_M15;
input ENUM_TIMEFRAMES     ST_GER_HigherTF = PERIOD_M15;
input int                 ST_GER_MAPeriod = 65;
input ENUM_MA_METHOD      ST_GER_MAMethod = MODE_LWMA;
input ENUM_APPLIED_PRICE  ST_GER_AppliedPrice = PRICE_OPEN;
input int                 ST_GER_HTFBarsToScan = 1200;
input double              ST_GER_LineTouchTolerance = 100.0;
input double              ST_GER_BreakBuffer = 80.0;
input ulong               ST_GER_MagicNumber = 26042502;
input bool                ST_GER_DrawTrendline = true;

input group "=== RSI Secret Sauce XAUUSD ==="
input string RSS_Symbol = "XAUUSD";
input int    RSS_MagicNumber = 789012;
input int    RSS_Slippage = 10;
input ENUM_TIMEFRAMES RSS_Timeframe = PERIOD_M30;
input int    RSS_RSIPeriod = 16;
input double RSS_RSIOverbought = 72.5;
input double RSS_RSIOversold = 32.5;
input int    RSS_RSILookback = 60;
input int    RSS_PeakBars = 2;
input double RSS_StopLossATR = 2.75;
input double RSS_TakeProfitATR = 5.0;
input int    RSS_ATRPeriod = 14;
input bool   RSS_UseSwingStopLoss = false;
input int    RSS_SwingLookback = 30;
input int    RSS_MaxPositions = 1;
input int    RSS_MinBarsBetweenTrades = 7;

input group "=== USDJPY Buster (Asian range breakout) ==="
input string              UB_Symbol = "USDJPY";
input int                 UB_RangeStartHour = 3;
input int                 UB_RangeEndHour = 6;
input int                 UB_CloseHour = 18;
input ENUM_TIMEFRAMES     UB_RangeTF = PERIOD_M20;
input int                 UB_MinRangePoints = 15;
input double              UB_OrderBufferPoints = 4.75;
input bool                UB_FirstTradeOnly = false;
input bool                UB_AllowLong = true;
input bool                UB_AllowShort = true;
input bool                UB_UseTakeProfit = false;
input double              UB_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   UB_RiskMode = UB_RISK_FIXED_LOTS;
input double              UB_FixedRiskMoney = 250.0;
input double              UB_RiskPercent = 0.1;
input double              UB_FixedLots = 0.01;
input int                 UB_MagicNumber = 927002;
input int                 UB_Slippage = 20;
input int                 UB_MaxSpreadPoints = 20;
input bool                UB_DrawRange = false;
input bool                UB_DebugLog = false;

input group "=== XAU Bear Trend (short-only hedge) ==="
input string              XBT_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES     XBT_RegimeTF = PERIOD_D1;
input ENUM_TIMEFRAMES     XBT_EntryTF = PERIOD_H1;
input int                 XBT_RegimeEmaPeriod = 100;
input int                 XBT_RsiPeriod = 14;
input double              XBT_RsiArmLevel = 54.0;
input double              XBT_RsiTriggerLevel = 50.0;
input int                 XBT_AtrPeriod = 14;
input double              XBT_SlAtrMult = 0.45;
input double              XBT_TpAtrMult = 2.5;
input bool                XBT_UseTrailing = true;
input double              XBT_TrailAtrMult = 1.5;
input ulong               XBT_MagicNumber = 928101;
input int                 XBT_Slippage = 20;
input int                 XBT_MaxSpreadPoints = 50;

input group "=== XAU Momentum Breakdown (short-only hedge) ==="
input string              XMB_Symbol = "XAUUSD";
input ENUM_TIMEFRAMES     XMB_RegimeTF = PERIOD_D1;
input ENUM_TIMEFRAMES     XMB_EntryTF = PERIOD_H4;
input int                 XMB_RegimeEmaPeriod = 100;
input int                 XMB_BbPeriod = 20;
input double              XMB_BbDeviation = 2.0;
input int                 XMB_AtrPeriod = 14;
input double              XMB_SlAtrMult = 0.4;
input double              XMB_TpAtrMult = 2.8;
input bool                XMB_UseTrailing = true;
input double              XMB_TrailAtrMult = 1.4;
input ulong               XMB_MagicNumber = 928102;
input int                 XMB_Slippage = 20;
input int                 XMB_MaxSpreadPoints = 50;

input group "=== RSI Reversal Asian GBPUSD ==="
input string RRA_GBPUSD_Symbol = "GBPUSD";
input int    RRA_GBPUSD_RSIPeriod = 32;
input double RRA_GBPUSD_OverboughtLevel = 80;
input double RRA_GBPUSD_OversoldLevel = 37;
input int    RRA_GBPUSD_TakeProfitPips = 225;
input int    RRA_GBPUSD_StopLossPips = 45;
input double RRA_GBPUSD_MaxLotSize = 0.2;
input int    RRA_GBPUSD_MaxSpread = 1800;
input int    RRA_GBPUSD_MaxDuration = 480;
input bool   RRA_GBPUSD_UseStopLoss = false;
input bool   RRA_GBPUSD_UseTakeProfit = false;
input bool   RRA_GBPUSD_UseRSIExit = true;
input double RRA_GBPUSD_RSIExitLevel = 43;
input bool   RRA_GBPUSD_CloseOutsideSession = true;
input ENUM_TIMEFRAMES RRA_GBPUSD_TimeFrame = PERIOD_M15;
input int    RRA_GBPUSD_MagicNumber = 30003;
input int    RRA_GBPUSD_Slippage = 3;

input group "=== GER40 Buster (European session range breakout) ==="
input string              GB_Symbol = "GER40";
input int                 GB_RangeStartHour = 8;
input int                 GB_RangeEndHour = 10;
input int                 GB_CloseHour = 20;
input ENUM_TIMEFRAMES     GB_RangeTF = PERIOD_M15;
input int                 GB_MinRangePoints = 80;
input double              GB_OrderBufferPoints = 12.0;
input bool                GB_FirstTradeOnly = false;
input bool                GB_AllowLong = true;
input bool                GB_AllowShort = true;
input bool                GB_UseTakeProfit = false;
input double              GB_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   GB_RiskMode = UB_RISK_FIXED_LOTS;
input double              GB_FixedRiskMoney = 250.0;
input double              GB_RiskPercent = 0.1;
input double              GB_FixedLots = 0.01;
input int                 GB_MagicNumber = 927102;
input int                 GB_Slippage = 30;
input int                 GB_MaxSpreadPoints = 120;
input bool                GB_DrawRange = false;
input bool                GB_DebugLog = false;

input group "=== RSI Reversal Asian USDCHF ==="
input string RRA_USDCHF_Symbol = "USDCHF";
input int    RRA_USDCHF_RSIPeriod = 30;
input double RRA_USDCHF_OverboughtLevel = 72;
input double RRA_USDCHF_OversoldLevel = 22;
input int    RRA_USDCHF_TakeProfitPips = 200;
input int    RRA_USDCHF_StopLossPips = 40;
input double RRA_USDCHF_MaxLotSize = 0.2;
input int    RRA_USDCHF_MaxSpread = 1200;
input int    RRA_USDCHF_MaxDuration = 420;
input bool   RRA_USDCHF_UseStopLoss = false;
input bool   RRA_USDCHF_UseTakeProfit = false;
input bool   RRA_USDCHF_UseRSIExit = true;
input double RRA_USDCHF_RSIExitLevel = 50;
input bool   RRA_USDCHF_CloseOutsideSession = true;
input ENUM_TIMEFRAMES RRA_USDCHF_TimeFrame = PERIOD_M15;
input int    RRA_USDCHF_MagicNumber = 30004;
input int    RRA_USDCHF_Slippage = 3;

input group "=== RSI Reversal Asian NZDUSD ==="
input string RRA_NZDUSD_Symbol = "NZDUSD";
input int    RRA_NZDUSD_RSIPeriod = 28;
input double RRA_NZDUSD_OverboughtLevel = 66;
input double RRA_NZDUSD_OversoldLevel = 28;
input int    RRA_NZDUSD_TakeProfitPips = 200;
input int    RRA_NZDUSD_StopLossPips = 40;
input double RRA_NZDUSD_MaxLotSize = 0.2;
input int    RRA_NZDUSD_MaxSpread = 1200;
input int    RRA_NZDUSD_MaxDuration = 400;
input bool   RRA_NZDUSD_UseStopLoss = false;
input bool   RRA_NZDUSD_UseTakeProfit = false;
input bool   RRA_NZDUSD_UseRSIExit = true;
input double RRA_NZDUSD_RSIExitLevel = 50;
input bool   RRA_NZDUSD_CloseOutsideSession = true;
input ENUM_TIMEFRAMES RRA_NZDUSD_TimeFrame = PERIOD_M15;
input int    RRA_NZDUSD_MagicNumber = 30005;
input int    RRA_NZDUSD_Slippage = 3;

input group "=== NAS100 Buster (US cash open range) ==="
input string              NB_Symbol = "NAS100";
input int                 NB_RangeStartHour = 14;
input int                 NB_RangeEndHour = 16;
input int                 NB_CloseHour = 21;
input ENUM_TIMEFRAMES     NB_RangeTF = PERIOD_M15;
input int                 NB_MinRangePoints = 120;
input double              NB_OrderBufferPoints = 18.0;
input bool                NB_FirstTradeOnly = false;
input bool                NB_AllowLong = true;
input bool                NB_AllowShort = true;
input bool                NB_UseTakeProfit = false;
input double              NB_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   NB_RiskMode = UB_RISK_FIXED_LOTS;
input double              NB_FixedRiskMoney = 250.0;
input double              NB_RiskPercent = 0.1;
input double              NB_FixedLots = 0.01;
input int                 NB_MagicNumber = 927103;
input int                 NB_Slippage = 40;
input int                 NB_MaxSpreadPoints = 200;
input bool                NB_DrawRange = false;
input bool                NB_DebugLog = false;

input group "=== US500 Buster (US cash open range) ==="
input string              U5B_Symbol = "US500";
input int                 U5B_RangeStartHour = 14;
input int                 U5B_RangeEndHour = 16;
input int                 U5B_CloseHour = 21;
input ENUM_TIMEFRAMES     U5B_RangeTF = PERIOD_M15;
input int                 U5B_MinRangePoints = 80;
input double              U5B_OrderBufferPoints = 12.0;
input bool                U5B_FirstTradeOnly = false;
input bool                U5B_AllowLong = true;
input bool                U5B_AllowShort = true;
input bool                U5B_UseTakeProfit = false;
input double              U5B_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   U5B_RiskMode = UB_RISK_FIXED_LOTS;
input double              U5B_FixedRiskMoney = 250.0;
input double              U5B_RiskPercent = 0.1;
input double              U5B_FixedLots = 0.01;
input int                 U5B_MagicNumber = 927104;
input int                 U5B_Slippage = 35;
input int                 U5B_MaxSpreadPoints = 150;
input bool                U5B_DrawRange = false;
input bool                U5B_DebugLog = false;

input group "=== US30 Buster (US cash open range) ==="
input string              U30B_Symbol = "US30";
input int                 U30B_RangeStartHour = 14;
input int                 U30B_RangeEndHour = 16;
input int                 U30B_CloseHour = 21;
input ENUM_TIMEFRAMES     U30B_RangeTF = PERIOD_M15;
input int                 U30B_MinRangePoints = 150;
input double              U30B_OrderBufferPoints = 22.0;
input bool                U30B_FirstTradeOnly = false;
input bool                U30B_AllowLong = true;
input bool                U30B_AllowShort = true;
input bool                U30B_UseTakeProfit = false;
input double              U30B_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   U30B_RiskMode = UB_RISK_FIXED_LOTS;
input double              U30B_FixedRiskMoney = 250.0;
input double              U30B_RiskPercent = 0.1;
input double              U30B_FixedLots = 0.01;
input int                 U30B_MagicNumber = 927105;
input int                 U30B_Slippage = 45;
input int                 U30B_MaxSpreadPoints = 250;
input bool                U30B_DrawRange = false;
input bool                U30B_DebugLog = false;

input group "=== UK100 Buster (London open range) ==="
input string              UKB_Symbol = "UK100";
input int                 UKB_RangeStartHour = 8;
input int                 UKB_RangeEndHour = 10;
input int                 UKB_CloseHour = 20;
input ENUM_TIMEFRAMES     UKB_RangeTF = PERIOD_M15;
input int                 UKB_MinRangePoints = 60;
input double              UKB_OrderBufferPoints = 10.0;
input bool                UKB_FirstTradeOnly = false;
input bool                UKB_AllowLong = true;
input bool                UKB_AllowShort = true;
input bool                UKB_UseTakeProfit = false;
input double              UKB_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   UKB_RiskMode = UB_RISK_FIXED_LOTS;
input double              UKB_FixedRiskMoney = 250.0;
input double              UKB_RiskPercent = 0.1;
input double              UKB_FixedLots = 0.01;
input int                 UKB_MagicNumber = 927106;
input int                 UKB_Slippage = 35;
input int                 UKB_MaxSpreadPoints = 180;
input bool                UKB_DrawRange = false;
input bool                UKB_DebugLog = false;

input group "=== XAGUSD Buster (London silver range) ==="
input string              XGB_Symbol = "XAGUSD";
input int                 XGB_RangeStartHour = 8;
input int                 XGB_RangeEndHour = 10;
input int                 XGB_CloseHour = 20;
input ENUM_TIMEFRAMES     XGB_RangeTF = PERIOD_M15;
input int                 XGB_MinRangePoints = 25;
input double              XGB_OrderBufferPoints = 4.0;
input bool                XGB_FirstTradeOnly = false;
input bool                XGB_AllowLong = true;
input bool                XGB_AllowShort = true;
input bool                XGB_UseTakeProfit = false;
input double              XGB_TakeProfitPoints = 0.0;
input ENUM_UB_RISK_MODE   XGB_RiskMode = UB_RISK_FIXED_LOTS;
input double              XGB_FixedRiskMoney = 250.0;
input double              XGB_RiskPercent = 0.1;
input double              XGB_FixedLots = 0.01;
input int                 XGB_MagicNumber = 927107;
input int                 XGB_Slippage = 25;
input int                 XGB_MaxSpreadPoints = 80;
input bool                XGB_DrawRange = false;
input bool                XGB_DebugLog = false;

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
   g_Pos_RS_ADBE = United_ScaledLot(LOT_RS_ADBE);
   g_Pos_RS_BTCUSD = United_ScaledLot(LOT_RS_BTCUSD);
   g_Pos_RS_NVDA = United_ScaledLot(LOT_RS_NVDA);
   g_Pos_RS_TSLA = United_ScaledLot(LOT_RS_TSLA);
   g_Pos_RS_XAUUSD = United_ScaledLot(LOT_RS_XAUUSD);
   g_Pos_RS_MU = United_ScaledLot(LOT_RS_MU);
   g_Pos_RRA_EURUSD = United_ScaledLot(LOT_RRA_EURUSD);
   g_Pos_RRA_AUDUSD = United_ScaledLot(LOT_RRA_AUDUSD);
   g_Pos_SE = United_ScaledLot(LOT_SE_SuperEMA);
   g_Pos_RCO = United_ScaledLot(LOT_RCO_RSIConsolidation);
   g_Pos_ST_BTCUSD = United_ScaledLot(LOT_ST_BTCUSD);
   g_Pos_ST_XAUUSD = United_ScaledLot(LOT_ST_XAUUSD);
   g_Pos_ST_GER40 = United_ScaledLot(LOT_ST_GER40);
   g_RSS_LotSize = United_ScaledLot(LOT_RSS_SecretSauce);
   g_Pos_UB_USDJPY = United_ScaledLot(LOT_UB_USDJPY);
   g_Pos_XBT_XAUUSD = United_ScaledLot(LOT_XBT_XAUUSD);
   g_Pos_XMB_XAUUSD = United_ScaledLot(LOT_XMB_XAUUSD);
   g_Pos_RRA_GBPUSD = United_ScaledLot(LOT_RRA_GBPUSD);
   g_Pos_GB_GER40 = United_ScaledLot(LOT_GB_GER40);
   g_Pos_RS_NAS100 = United_ScaledLot(LOT_RS_NAS100);
   g_Pos_RS_US500 = United_ScaledLot(LOT_RS_US500);
   g_Pos_RRA_USDCHF = United_ScaledLot(LOT_RRA_USDCHF);
   g_Pos_RRA_NZDUSD = United_ScaledLot(LOT_RRA_NZDUSD);
   g_Pos_NB_NAS100 = United_ScaledLot(LOT_NB_NAS100);
   g_Pos_U5B_US500 = United_ScaledLot(LOT_U5B_US500);
   g_Pos_RS_US30 = United_ScaledLot(LOT_RS_US30);
   g_Pos_RS_XAGUSD = United_ScaledLot(LOT_RS_XAGUSD);
   g_Pos_RS_EURJPY = United_ScaledLot(LOT_RS_EURJPY);
   g_Pos_RS_GBPJPY = United_ScaledLot(LOT_RS_GBPJPY);
   g_Pos_U30B_US30 = United_ScaledLot(LOT_U30B_US30);
   g_Pos_UKB_UK100 = United_ScaledLot(LOT_UKB_UK100);
   g_Pos_XGB_XAGUSD = United_ScaledLot(LOT_XGB_XAGUSD);
   g_Pos_RS_F = United_ScaledLot(LOT_RS_F);
   g_Pos_RS_SOFI = United_ScaledLot(LOT_RS_SOFI);
   g_Pos_RS_SNAP = United_ScaledLot(LOT_RS_SNAP);
   g_Pos_RS_WBD = United_ScaledLot(LOT_RS_WBD);
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
   datetime es_last_sl_adjust_success_time;
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
RSIScalpingData rsADBEData;
RSIScalpingData rsBTCUSDData;
RSIScalpingData rsNVDAData;
RSIScalpingData rsTSLAData;
RSIScalpingData rsXAUUSDData;
RSIScalpingData rsMUData;
RSIScalpingData rsNAS100Data;
RSIScalpingData rsUS500Data;
RSIScalpingData rsUS30Data;
RSIScalpingData rsXAGUSDData;
RSIScalpingData rsEURJPYData;
RSIScalpingData rsGBPJPYData;
RSIScalpingData rsFData;
RSIScalpingData rsSOFIData;
RSIScalpingData rsSNAPData;
RSIScalpingData rsWBDData;
SuperEMAData seData;
RSIConsolidationData rcoData;
SimpleTrendlineData stBTCData;
SimpleTrendlineData stXAUData;
SimpleTrendlineData stGERData;
RSISecretSauceOrcData rssData;

//+------------------------------------------------------------------+
//| Global Variables - RSI Reversal Asian                            |
//+------------------------------------------------------------------+
RSIReversalAsianData rraEURUSDData;
RSIReversalAsianData rraAUDUSDData;
RSIReversalAsianData rraGBPUSDData;
RSIReversalAsianData rraUSDCHFData;
RSIReversalAsianData rraNZDUSDData;
USDJPYBusterData ubData;
USDJPYBusterData gbData;
USDJPYBusterData nbData;
USDJPYBusterData u5bData;
USDJPYBusterData u30bData;
USDJPYBusterData ukbData;
USDJPYBusterData xgbData;
XAUBearTrendData xbtData;
XAUMomentumBreakdownData xmbData;
CTrade g_gapTrade;

void United_GapGuardSetup()
{
   GapGuardConfig cfg;
   cfg.enable = GAP_Enable;
   cfg.closeBeforeSessionEnd = GAP_CloseBeforeSessionEnd;
   cfg.minutesBeforeClose = GAP_MinutesBeforeClose;
   cfg.closeBeforeWeekend = GAP_CloseBeforeWeekend;
   cfg.fridayCloseHour = GAP_FridayCloseHour;
   cfg.closeOnBarGapThroughSL = GAP_CloseOnBarGapThroughSL;
   cfg.minGapPoints = GAP_MinGapPoints;
   cfg.equityDailyFlatHour = GAP_EquityDailyFlatHour;
   GapGuard_Init(cfg);

   if(EnableDarvasBox) { GapGuard_RegisterMagic((ulong)DB_MagicNumber); GapGuard_RegisterSymbol(DB_Symbol); }
   if(EnableEMASlopeDistance) { GapGuard_RegisterMagic((ulong)ES_MagicNumber); GapGuard_RegisterSymbol(ES_Symbol); }
   if(EnableRSICrossOverReversal) { GapGuard_RegisterMagic((ulong)RC_MagicNumber); GapGuard_RegisterSymbol(RC_Symbol); }
   if(EnableRSIMidPointHijack)
   {
      GapGuard_RegisterMagic((ulong)RM_InpMagicNumberRSIFollow);
      GapGuard_RegisterMagic((ulong)RM_InpMagicNumberRSIReverse);
      GapGuard_RegisterMagic((ulong)RM_InpMagicNumberEMACross);
      GapGuard_RegisterSymbol(RM_Symbol);
   }
   if(EnableRSIScalpingAPPL) { GapGuard_RegisterMagic((ulong)RS_APPL_MagicNumber); GapGuard_RegisterSymbol(RS_APPL_Symbol); }
   if(EnableRSIScalpingADBE) { GapGuard_RegisterMagic((ulong)RS_ADBE_MagicNumber); GapGuard_RegisterSymbol(RS_ADBE_Symbol); }
   if(EnableRSIScalpingBTCUSD) { GapGuard_RegisterMagic((ulong)RS_BTCUSD_MagicNumber); GapGuard_RegisterSymbol(RS_BTCUSD_Symbol); }
   if(EnableRSIScalpingNVDA) { GapGuard_RegisterMagic((ulong)RS_NVDA_MagicNumber); GapGuard_RegisterSymbol(RS_NVDA_Symbol); }
   if(EnableRSIScalpingTSLA) { GapGuard_RegisterMagic((ulong)RS_TSLA_MagicNumber); GapGuard_RegisterSymbol(RS_TSLA_Symbol); }
   if(EnableRSIScalpingXAUUSD) { GapGuard_RegisterMagic((ulong)RS_XAUUSD_MagicNumber); GapGuard_RegisterSymbol(RS_XAUUSD_Symbol); }
   if(EnableRSIScalpingMU) { GapGuard_RegisterMagic((ulong)RS_MU_MagicNumber); GapGuard_RegisterSymbol(RS_MU_Symbol); }
   if(EnableRSISecretSauce) { GapGuard_RegisterMagic((ulong)RSS_MagicNumber); GapGuard_RegisterSymbol(RSS_Symbol); }
   if(EnableSuperEMA) { GapGuard_RegisterMagic((ulong)SE_MagicNumber); GapGuard_RegisterSymbol(SE_Symbol); }
   if(EnableRSIConsolidation) { GapGuard_RegisterMagic(RCO_MagicNumber); GapGuard_RegisterSymbol(RCO_Symbol); }
   if(EnableRSIReversalAsianEURUSD) { GapGuard_RegisterMagic((ulong)RRA_EURUSD_MagicNumber); GapGuard_RegisterSymbol(RRA_EURUSD_Symbol); }
   if(EnableRSIReversalAsianAUDUSD) { GapGuard_RegisterMagic((ulong)RRA_AUDUSD_MagicNumber); GapGuard_RegisterSymbol(RRA_AUDUSD_Symbol); }
   if(EnableSimpleTrendlineBTCUSD) { GapGuard_RegisterMagic(ST_BTC_MagicNumber); GapGuard_RegisterSymbol(ST_BTC_Symbol); }
   if(EnableSimpleTrendlineXAUUSD) { GapGuard_RegisterMagic(ST_XAU_MagicNumber); GapGuard_RegisterSymbol(ST_XAU_Symbol); }
   if(EnableSimpleTrendlineGER40) { GapGuard_RegisterMagic(ST_GER_MagicNumber); GapGuard_RegisterSymbol(ST_GER_Symbol); }
   if(EnableUSDJPYBuster) { GapGuard_RegisterMagic((ulong)UB_MagicNumber); GapGuard_RegisterSymbol(UB_Symbol); }
   if(EnableXAUBearTrend) { GapGuard_RegisterMagic(XBT_MagicNumber); GapGuard_RegisterSymbol(XBT_Symbol); }
   if(EnableXAUMomentumBreakdown) { GapGuard_RegisterMagic(XMB_MagicNumber); GapGuard_RegisterSymbol(XMB_Symbol); }
   if(EnableRSIReversalAsianGBPUSD) { GapGuard_RegisterMagic((ulong)RRA_GBPUSD_MagicNumber); GapGuard_RegisterSymbol(RRA_GBPUSD_Symbol); }
   if(EnableGER40Buster) { GapGuard_RegisterMagic((ulong)GB_MagicNumber); GapGuard_RegisterSymbol(GB_Symbol); }
   if(EnableRSIScalpingNAS100) { GapGuard_RegisterMagic((ulong)RS_NAS100_MagicNumber); GapGuard_RegisterSymbol(RS_NAS100_Symbol); }
   if(EnableRSIScalpingUS500) { GapGuard_RegisterMagic((ulong)RS_US500_MagicNumber); GapGuard_RegisterSymbol(RS_US500_Symbol); }
   if(EnableRSIReversalAsianUSDCHF) { GapGuard_RegisterMagic((ulong)RRA_USDCHF_MagicNumber); GapGuard_RegisterSymbol(RRA_USDCHF_Symbol); }
   if(EnableRSIReversalAsianNZDUSD) { GapGuard_RegisterMagic((ulong)RRA_NZDUSD_MagicNumber); GapGuard_RegisterSymbol(RRA_NZDUSD_Symbol); }
   if(EnableNAS100Buster) { GapGuard_RegisterMagic((ulong)NB_MagicNumber); GapGuard_RegisterSymbol(NB_Symbol); }
   if(EnableUS500Buster) { GapGuard_RegisterMagic((ulong)U5B_MagicNumber); GapGuard_RegisterSymbol(U5B_Symbol); }
   if(EnableRSIScalpingUS30) { GapGuard_RegisterMagic((ulong)RS_US30_MagicNumber); GapGuard_RegisterSymbol(RS_US30_Symbol); }
   if(EnableRSIScalpingXAGUSD) { GapGuard_RegisterMagic((ulong)RS_XAGUSD_MagicNumber); GapGuard_RegisterSymbol(RS_XAGUSD_Symbol); }
   if(EnableRSIScalpingEURJPY) { GapGuard_RegisterMagic((ulong)RS_EURJPY_MagicNumber); GapGuard_RegisterSymbol(RS_EURJPY_Symbol); }
   if(EnableRSIScalpingGBPJPY) { GapGuard_RegisterMagic((ulong)RS_GBPJPY_MagicNumber); GapGuard_RegisterSymbol(RS_GBPJPY_Symbol); }
   if(EnableUS30Buster) { GapGuard_RegisterMagic((ulong)U30B_MagicNumber); GapGuard_RegisterSymbol(U30B_Symbol); }
   if(EnableUK100Buster) { GapGuard_RegisterMagic((ulong)UKB_MagicNumber); GapGuard_RegisterSymbol(UKB_Symbol); }
   if(EnableXAGUSDBuster) { GapGuard_RegisterMagic((ulong)XGB_MagicNumber); GapGuard_RegisterSymbol(XGB_Symbol); }
   if(EnableRSIScalpingF) { GapGuard_RegisterMagic((ulong)RS_F_MagicNumber); GapGuard_RegisterSymbol(RS_F_Symbol); }
   if(EnableRSIScalpingSOFI) { GapGuard_RegisterMagic((ulong)RS_SOFI_MagicNumber); GapGuard_RegisterSymbol(RS_SOFI_Symbol); }
   if(EnableRSIScalpingSNAP) { GapGuard_RegisterMagic((ulong)RS_SNAP_MagicNumber); GapGuard_RegisterSymbol(RS_SNAP_Symbol); }
   if(EnableRSIScalpingWBD) { GapGuard_RegisterMagic((ulong)RS_WBD_MagicNumber); GapGuard_RegisterSymbol(RS_WBD_Symbol); }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int initResult = INIT_SUCCEEDED;
   
   United_RefreshScaledLots();
   United_GapGuardSetup();
   
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

   if(EnableRSIScalpingADBE)
      InitRSIScalping(rsADBEData, RS_ADBE_Symbol, RS_ADBE_TimeFrame, RS_ADBE_RSI_Period, RS_ADBE_RSI_Applied_Price, RS_ADBE_MagicNumber, RS_ADBE_Slippage);
   
   if(EnableRSIScalpingBTCUSD)
      InitRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price, RS_BTCUSD_MagicNumber, RS_BTCUSD_Slippage);
   
   if(EnableRSIScalpingNVDA)
      InitRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price, RS_NVDA_MagicNumber, RS_NVDA_Slippage);
   
   if(EnableRSIScalpingTSLA)
      InitRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price, RS_TSLA_MagicNumber, RS_TSLA_Slippage);
   
   if(EnableRSIScalpingXAUUSD)
      InitRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price, RS_XAUUSD_MagicNumber, RS_XAUUSD_Slippage);
   if(EnableRSIScalpingMU)
      InitRSIScalping(rsMUData, RS_MU_Symbol, RS_MU_TimeFrame, RS_MU_RSI_Period, RS_MU_RSI_Applied_Price, RS_MU_MagicNumber, RS_MU_Slippage);

   if(EnableRSIScalpingNAS100)
      InitRSIScalping(rsNAS100Data, RS_NAS100_Symbol, RS_NAS100_TimeFrame, RS_NAS100_RSI_Period, RS_NAS100_RSI_Applied_Price, RS_NAS100_MagicNumber, RS_NAS100_Slippage);

   if(EnableRSIScalpingUS500)
      InitRSIScalping(rsUS500Data, RS_US500_Symbol, RS_US500_TimeFrame, RS_US500_RSI_Period, RS_US500_RSI_Applied_Price, RS_US500_MagicNumber, RS_US500_Slippage);

   if(EnableRSIScalpingUS30)
      InitRSIScalping(rsUS30Data, RS_US30_Symbol, RS_US30_TimeFrame, RS_US30_RSI_Period, RS_US30_RSI_Applied_Price, RS_US30_MagicNumber, RS_US30_Slippage);

   if(EnableRSIScalpingXAGUSD)
      InitRSIScalping(rsXAGUSDData, RS_XAGUSD_Symbol, RS_XAGUSD_TimeFrame, RS_XAGUSD_RSI_Period, RS_XAGUSD_RSI_Applied_Price, RS_XAGUSD_MagicNumber, RS_XAGUSD_Slippage);

   if(EnableRSIScalpingEURJPY)
      InitRSIScalping(rsEURJPYData, RS_EURJPY_Symbol, RS_EURJPY_TimeFrame, RS_EURJPY_RSI_Period, RS_EURJPY_RSI_Applied_Price, RS_EURJPY_MagicNumber, RS_EURJPY_Slippage);

   if(EnableRSIScalpingGBPJPY)
      InitRSIScalping(rsGBPJPYData, RS_GBPJPY_Symbol, RS_GBPJPY_TimeFrame, RS_GBPJPY_RSI_Period, RS_GBPJPY_RSI_Applied_Price, RS_GBPJPY_MagicNumber, RS_GBPJPY_Slippage);

   if(EnableRSIScalpingF)
      InitRSIScalping(rsFData, RS_F_Symbol, RS_F_TimeFrame, RS_F_RSI_Period, RS_F_RSI_Applied_Price, RS_F_MagicNumber, RS_F_Slippage);
   if(EnableRSIScalpingSOFI)
      InitRSIScalping(rsSOFIData, RS_SOFI_Symbol, RS_SOFI_TimeFrame, RS_SOFI_RSI_Period, RS_SOFI_RSI_Applied_Price, RS_SOFI_MagicNumber, RS_SOFI_Slippage);
   if(EnableRSIScalpingSNAP)
      InitRSIScalping(rsSNAPData, RS_SNAP_Symbol, RS_SNAP_TimeFrame, RS_SNAP_RSI_Period, RS_SNAP_RSI_Applied_Price, RS_SNAP_MagicNumber, RS_SNAP_Slippage);
   if(EnableRSIScalpingWBD)
      InitRSIScalping(rsWBDData, RS_WBD_Symbol, RS_WBD_TimeFrame, RS_WBD_RSI_Period, RS_WBD_RSI_Applied_Price, RS_WBD_MagicNumber, RS_WBD_Slippage);

   if(EnableRSISecretSauce)
      if(!InitRSISecretSauce(rssData, RSS_Symbol))
         Print("Warning: RSI Secret Sauce failed to initialize for symbol '", RSS_Symbol, "'");

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

   if(EnableSimpleTrendlineGER40)
      if(!InitSimpleTrendline(stGERData, ST_GER_Symbol, ST_GER_SignalTF, ST_GER_HigherTF, ST_GER_MAPeriod,
                              ST_GER_MAMethod, ST_GER_AppliedPrice, ST_GER_HTFBarsToScan,
                              ST_GER_LineTouchTolerance, ST_GER_BreakBuffer, ST_GER_MagicNumber, ST_GER_DrawTrendline))
         Print("Warning: SimpleTrendlineGER40 failed to initialize for symbol '", ST_GER_Symbol, "'");

   if(EnableUSDJPYBuster)
      if(!InitUSDJPYBuster(ubData, UB_Symbol,
                            UB_RangeStartHour, UB_RangeEndHour, UB_CloseHour, UB_RangeTF,
                            UB_MinRangePoints, UB_OrderBufferPoints,
                            UB_FirstTradeOnly, UB_AllowLong, UB_AllowShort,
                            UB_UseTakeProfit, UB_TakeProfitPoints,
                            UB_RiskMode, UB_FixedRiskMoney, UB_RiskPercent, UB_FixedLots,
                            UB_MagicNumber, UB_Slippage, UB_MaxSpreadPoints, UB_DrawRange, UB_DebugLog))
         Print("Warning: USDJPYBuster failed to initialize for symbol '", UB_Symbol, "'");

   if(EnableXAUBearTrend)
      if(!InitXAUBearTrend(xbtData, XBT_Symbol, XBT_RegimeTF, XBT_EntryTF,
                           XBT_RegimeEmaPeriod, XBT_RsiPeriod, XBT_RsiArmLevel, XBT_RsiTriggerLevel,
                           XBT_AtrPeriod, XBT_SlAtrMult, XBT_TpAtrMult,
                           XBT_UseTrailing, XBT_TrailAtrMult,
                           XBT_MagicNumber, XBT_Slippage, XBT_MaxSpreadPoints))
         Print("Warning: XAUBearTrend failed to initialize for symbol '", XBT_Symbol, "'");

   if(EnableXAUMomentumBreakdown)
      if(!InitXAUMomentumBreakdown(xmbData, XMB_Symbol, XMB_RegimeTF, XMB_EntryTF,
                                   XMB_RegimeEmaPeriod, XMB_BbPeriod, XMB_BbDeviation, XMB_AtrPeriod,
                                   XMB_SlAtrMult, XMB_TpAtrMult, XMB_UseTrailing, XMB_TrailAtrMult,
                                   XMB_MagicNumber, XMB_Slippage, XMB_MaxSpreadPoints))
         Print("Warning: XAUMomentumBreakdown failed to initialize for symbol '", XMB_Symbol, "'");

   if(EnableRSIReversalAsianGBPUSD)
      if(!InitRSIReversalAsian(rraGBPUSDData, RRA_GBPUSD_Symbol, RRA_GBPUSD_RSIPeriod, RRA_GBPUSD_OverboughtLevel, RRA_GBPUSD_OversoldLevel,
                               RRA_GBPUSD_TakeProfitPips, RRA_GBPUSD_StopLossPips, LOT_RRA_GBPUSD,
                               RRA_GBPUSD_MaxSpread, RRA_GBPUSD_MaxDuration, RRA_GBPUSD_UseStopLoss,
                               RRA_GBPUSD_UseTakeProfit, RRA_GBPUSD_UseRSIExit, RRA_GBPUSD_RSIExitLevel,
                               RRA_GBPUSD_CloseOutsideSession, RRA_GBPUSD_TimeFrame, RRA_GBPUSD_MagicNumber, RRA_GBPUSD_Slippage))
         Print("Warning: RSIReversalAsianGBPUSD strategy failed to initialize for symbol '", RRA_GBPUSD_Symbol, "'");

   if(EnableGER40Buster)
      if(!InitUSDJPYBuster(gbData, GB_Symbol,
                            GB_RangeStartHour, GB_RangeEndHour, GB_CloseHour, GB_RangeTF,
                            GB_MinRangePoints, GB_OrderBufferPoints,
                            GB_FirstTradeOnly, GB_AllowLong, GB_AllowShort,
                            GB_UseTakeProfit, GB_TakeProfitPoints,
                            GB_RiskMode, GB_FixedRiskMoney, GB_RiskPercent, GB_FixedLots,
                            GB_MagicNumber, GB_Slippage, GB_MaxSpreadPoints, GB_DrawRange, GB_DebugLog))
         Print("Warning: GER40Buster failed to initialize for symbol '", GB_Symbol, "'");

   if(EnableRSIReversalAsianUSDCHF)
      if(!InitRSIReversalAsian(rraUSDCHFData, RRA_USDCHF_Symbol, RRA_USDCHF_RSIPeriod, RRA_USDCHF_OverboughtLevel, RRA_USDCHF_OversoldLevel,
                               RRA_USDCHF_TakeProfitPips, RRA_USDCHF_StopLossPips, LOT_RRA_USDCHF,
                               RRA_USDCHF_MaxSpread, RRA_USDCHF_MaxDuration, RRA_USDCHF_UseStopLoss,
                               RRA_USDCHF_UseTakeProfit, RRA_USDCHF_UseRSIExit, RRA_USDCHF_RSIExitLevel,
                               RRA_USDCHF_CloseOutsideSession, RRA_USDCHF_TimeFrame, RRA_USDCHF_MagicNumber, RRA_USDCHF_Slippage))
         Print("Warning: RSIReversalAsianUSDCHF strategy failed to initialize for symbol '", RRA_USDCHF_Symbol, "'");

   if(EnableRSIReversalAsianNZDUSD)
      if(!InitRSIReversalAsian(rraNZDUSDData, RRA_NZDUSD_Symbol, RRA_NZDUSD_RSIPeriod, RRA_NZDUSD_OverboughtLevel, RRA_NZDUSD_OversoldLevel,
                               RRA_NZDUSD_TakeProfitPips, RRA_NZDUSD_StopLossPips, LOT_RRA_NZDUSD,
                               RRA_NZDUSD_MaxSpread, RRA_NZDUSD_MaxDuration, RRA_NZDUSD_UseStopLoss,
                               RRA_NZDUSD_UseTakeProfit, RRA_NZDUSD_UseRSIExit, RRA_NZDUSD_RSIExitLevel,
                               RRA_NZDUSD_CloseOutsideSession, RRA_NZDUSD_TimeFrame, RRA_NZDUSD_MagicNumber, RRA_NZDUSD_Slippage))
         Print("Warning: RSIReversalAsianNZDUSD strategy failed to initialize for symbol '", RRA_NZDUSD_Symbol, "'");

   if(EnableNAS100Buster)
      if(!InitUSDJPYBuster(nbData, NB_Symbol,
                            NB_RangeStartHour, NB_RangeEndHour, NB_CloseHour, NB_RangeTF,
                            NB_MinRangePoints, NB_OrderBufferPoints,
                            NB_FirstTradeOnly, NB_AllowLong, NB_AllowShort,
                            NB_UseTakeProfit, NB_TakeProfitPoints,
                            NB_RiskMode, NB_FixedRiskMoney, NB_RiskPercent, NB_FixedLots,
                            NB_MagicNumber, NB_Slippage, NB_MaxSpreadPoints, NB_DrawRange, NB_DebugLog))
         Print("Warning: NAS100Buster failed to initialize for symbol '", NB_Symbol, "'");

   if(EnableUS500Buster)
      if(!InitUSDJPYBuster(u5bData, U5B_Symbol,
                            U5B_RangeStartHour, U5B_RangeEndHour, U5B_CloseHour, U5B_RangeTF,
                            U5B_MinRangePoints, U5B_OrderBufferPoints,
                            U5B_FirstTradeOnly, U5B_AllowLong, U5B_AllowShort,
                            U5B_UseTakeProfit, U5B_TakeProfitPoints,
                            U5B_RiskMode, U5B_FixedRiskMoney, U5B_RiskPercent, U5B_FixedLots,
                            U5B_MagicNumber, U5B_Slippage, U5B_MaxSpreadPoints, U5B_DrawRange, U5B_DebugLog))
         Print("Warning: US500Buster failed to initialize for symbol '", U5B_Symbol, "'");

   if(EnableUS30Buster)
      if(!InitUSDJPYBuster(u30bData, U30B_Symbol,
                            U30B_RangeStartHour, U30B_RangeEndHour, U30B_CloseHour, U30B_RangeTF,
                            U30B_MinRangePoints, U30B_OrderBufferPoints,
                            U30B_FirstTradeOnly, U30B_AllowLong, U30B_AllowShort,
                            U30B_UseTakeProfit, U30B_TakeProfitPoints,
                            U30B_RiskMode, U30B_FixedRiskMoney, U30B_RiskPercent, U30B_FixedLots,
                            U30B_MagicNumber, U30B_Slippage, U30B_MaxSpreadPoints, U30B_DrawRange, U30B_DebugLog))
         Print("Warning: US30Buster failed to initialize for symbol '", U30B_Symbol, "'");

   if(EnableUK100Buster)
      if(!InitUSDJPYBuster(ukbData, UKB_Symbol,
                            UKB_RangeStartHour, UKB_RangeEndHour, UKB_CloseHour, UKB_RangeTF,
                            UKB_MinRangePoints, UKB_OrderBufferPoints,
                            UKB_FirstTradeOnly, UKB_AllowLong, UKB_AllowShort,
                            UKB_UseTakeProfit, UKB_TakeProfitPoints,
                            UKB_RiskMode, UKB_FixedRiskMoney, UKB_RiskPercent, UKB_FixedLots,
                            UKB_MagicNumber, UKB_Slippage, UKB_MaxSpreadPoints, UKB_DrawRange, UKB_DebugLog))
         Print("Warning: UK100Buster failed to initialize for symbol '", UKB_Symbol, "'");

   if(EnableXAGUSDBuster)
      if(!InitUSDJPYBuster(xgbData, XGB_Symbol,
                            XGB_RangeStartHour, XGB_RangeEndHour, XGB_CloseHour, XGB_RangeTF,
                            XGB_MinRangePoints, XGB_OrderBufferPoints,
                            XGB_FirstTradeOnly, XGB_AllowLong, XGB_AllowShort,
                            XGB_UseTakeProfit, XGB_TakeProfitPoints,
                            XGB_RiskMode, XGB_FixedRiskMoney, XGB_RiskPercent, XGB_FixedLots,
                            XGB_MagicNumber, XGB_Slippage, XGB_MaxSpreadPoints, XGB_DrawRange, XGB_DebugLog))
         Print("Warning: XAGUSDBuster failed to initialize for symbol '", XGB_Symbol, "'");

   rsAPPLData.closeUnprofitableOnNewSignal = RS_APPL_CloseUnprofitableOnNewSignal;
   rsADBEData.closeUnprofitableOnNewSignal = RS_ADBE_CloseUnprofitableOnNewSignal;
   rsBTCUSDData.closeUnprofitableOnNewSignal = RS_BTCUSD_CloseUnprofitableOnNewSignal;
   rsNVDAData.closeUnprofitableOnNewSignal = RS_NVDA_CloseUnprofitableOnNewSignal;
   rsTSLAData.closeUnprofitableOnNewSignal = RS_TSLA_CloseUnprofitableOnNewSignal;
   rsXAUUSDData.closeUnprofitableOnNewSignal = RS_XAUUSD_CloseUnprofitableOnNewSignal;
   rsMUData.closeUnprofitableOnNewSignal = RS_MU_CloseUnprofitableOnNewSignal;
   rsNAS100Data.closeUnprofitableOnNewSignal = RS_NAS100_CloseUnprofitableOnNewSignal;
   rsUS500Data.closeUnprofitableOnNewSignal = RS_US500_CloseUnprofitableOnNewSignal;
   rsUS30Data.closeUnprofitableOnNewSignal = RS_US30_CloseUnprofitableOnNewSignal;
   rsXAGUSDData.closeUnprofitableOnNewSignal = RS_XAGUSD_CloseUnprofitableOnNewSignal;
   rsEURJPYData.closeUnprofitableOnNewSignal = RS_EURJPY_CloseUnprofitableOnNewSignal;
   rsGBPJPYData.closeUnprofitableOnNewSignal = RS_GBPJPY_CloseUnprofitableOnNewSignal;
   rsFData.closeUnprofitableOnNewSignal = RS_F_CloseUnprofitableOnNewSignal;
   rsSOFIData.closeUnprofitableOnNewSignal = RS_SOFI_CloseUnprofitableOnNewSignal;
   rsSNAPData.closeUnprofitableOnNewSignal = RS_SNAP_CloseUnprofitableOnNewSignal;
   rsWBDData.closeUnprofitableOnNewSignal = RS_WBD_CloseUnprofitableOnNewSignal;
   rraEURUSDData.closeUnprofitableOnNewSignal = RRA_EURUSD_CloseUnprofitableOnNewSignal;
   rraAUDUSDData.closeUnprofitableOnNewSignal = RRA_AUDUSD_CloseUnprofitableOnNewSignal;
   seData.closeUnprofitableOnNewSignal = SE_CloseUnprofitableOnNewSignal;
   rcoData.closeUnprofitableOnNewSignal = RCO_CloseUnprofitableOnNewSignal;
   stBTCData.closeUnprofitableOnNewSignal = ST_BTC_CloseUnprofitableOnNewSignal;
   stXAUData.closeUnprofitableOnNewSignal = ST_XAU_CloseUnprofitableOnNewSignal;
   stGERData.closeUnprofitableOnNewSignal = ST_GER_CloseUnprofitableOnNewSignal;
   rssData.closeUnprofitableOnNewSignal = RSS_CloseUnprofitableOnNewSignal;
   ubData.closeUnprofitableOnNewSignal = UB_CloseUnprofitableOnNewSignal;
   xbtData.closeUnprofitableOnNewSignal = XBT_CloseUnprofitableOnNewSignal;
   xmbData.closeUnprofitableOnNewSignal = XMB_CloseUnprofitableOnNewSignal;
   rraGBPUSDData.closeUnprofitableOnNewSignal = RRA_GBPUSD_CloseUnprofitableOnNewSignal;
   gbData.closeUnprofitableOnNewSignal = GB_CloseUnprofitableOnNewSignal;
   rraUSDCHFData.closeUnprofitableOnNewSignal = RRA_USDCHF_CloseUnprofitableOnNewSignal;
   rraNZDUSDData.closeUnprofitableOnNewSignal = RRA_NZDUSD_CloseUnprofitableOnNewSignal;
   nbData.closeUnprofitableOnNewSignal = NB_CloseUnprofitableOnNewSignal;
   u5bData.closeUnprofitableOnNewSignal = U5B_CloseUnprofitableOnNewSignal;
   u30bData.closeUnprofitableOnNewSignal = U30B_CloseUnprofitableOnNewSignal;
   ukbData.closeUnprofitableOnNewSignal = UKB_CloseUnprofitableOnNewSignal;
   xgbData.closeUnprofitableOnNewSignal = XGB_CloseUnprofitableOnNewSignal;
   
   Print("United EA initialized. Active strategies: ", 
         (EnableDarvasBox ? "DarvasBox " : ""),
         (EnableEMASlopeDistance ? "EMASlope " : ""),
         (EnableRSICrossOverReversal ? "RSICrossOver " : ""),
         (EnableRSIMidPointHijack ? "RSIMidPoint " : ""),
         (EnableRSIScalpingAPPL ? "RSIScalpingAPPL " : ""),
         (EnableRSIScalpingADBE ? "RSIScalpingADBE " : ""),
         (EnableRSIScalpingBTCUSD ? "RSIScalpingBTCUSD " : ""),
         (EnableRSIScalpingNVDA ? "RSIScalpingNVDA " : ""),
         (EnableRSIScalpingTSLA ? "RSIScalpingTSLA " : ""),
         (EnableRSIScalpingXAUUSD ? "RSIScalpingXAUUSD " : ""),
         (EnableRSIScalpingMU ? "RSIScalpingMU " : ""),
         (EnableRSISecretSauce ? "RSISecretSauce " : ""),
         (EnableSuperEMA ? "SuperEMA " : ""),
         (EnableRSIConsolidation ? "RSIConsolidation " : ""),
         (EnableRSIReversalAsianEURUSD ? "RSIReversalAsianEURUSD " : ""),
         (EnableRSIReversalAsianAUDUSD ? "RSIReversalAsianAUDUSD " : ""),
         (EnableSimpleTrendlineBTCUSD ? "SimpleTrendlineBTCUSD " : ""),
         (EnableSimpleTrendlineXAUUSD ? "SimpleTrendlineXAUUSD " : ""),
         (EnableSimpleTrendlineGER40 ? "SimpleTrendlineGER40 " : ""),
         (EnableUSDJPYBuster ? "USDJPYBuster " : ""),
         (EnableXAUBearTrend ? "XAUBearTrend " : ""),
         (EnableXAUMomentumBreakdown ? "XAUMomentumBreakdown " : ""),
         (EnableRSIReversalAsianGBPUSD ? "RSIReversalAsianGBPUSD " : ""),
         (EnableGER40Buster ? "GER40Buster " : ""),
         (EnableRSIScalpingNAS100 ? "RSIScalpingNAS100 " : ""),
         (EnableRSIScalpingUS500 ? "RSIScalpingUS500 " : ""),
         (EnableRSIReversalAsianUSDCHF ? "RSIReversalAsianUSDCHF " : ""),
         (EnableRSIReversalAsianNZDUSD ? "RSIReversalAsianNZDUSD " : ""),
         (EnableNAS100Buster ? "NAS100Buster " : ""),
         (EnableUS500Buster ? "US500Buster " : ""),
         (EnableRSIScalpingUS30 ? "RSIScalpingUS30 " : ""),
         (EnableRSIScalpingXAGUSD ? "RSIScalpingXAGUSD " : ""),
         (EnableRSIScalpingEURJPY ? "RSIScalpingEURJPY " : ""),
         (EnableRSIScalpingGBPJPY ? "RSIScalpingGBPJPY " : ""),
         (EnableUS30Buster ? "US30Buster " : ""),
         (EnableUK100Buster ? "UK100Buster " : ""),
         (EnableXAGUSDBuster ? "XAGUSDBuster " : ""),
         (EnableRSIScalpingF ? "RSIScalpingF " : ""),
         (EnableRSIScalpingSOFI ? "RSIScalpingSOFI " : ""),
         (EnableRSIScalpingSNAP ? "RSIScalpingSNAP " : ""),
         (EnableRSIScalpingWBD ? "RSIScalpingWBD " : ""));
   
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

   if(EnableRSIScalpingADBE)
      DeinitRSIScalping(rsADBEData);
   
   if(EnableRSIScalpingBTCUSD)
      DeinitRSIScalping(rsBTCUSDData);
   
   if(EnableRSIScalpingNVDA)
      DeinitRSIScalping(rsNVDAData);
   
   if(EnableRSIScalpingTSLA)
      DeinitRSIScalping(rsTSLAData);
   
   if(EnableRSIScalpingXAUUSD)
      DeinitRSIScalping(rsXAUUSDData);
   if(EnableRSIScalpingMU)
      DeinitRSIScalping(rsMUData);
   if(EnableRSIScalpingNAS100)
      DeinitRSIScalping(rsNAS100Data);
   if(EnableRSIScalpingUS500)
      DeinitRSIScalping(rsUS500Data);
   if(EnableRSIScalpingUS30)
      DeinitRSIScalping(rsUS30Data);
   if(EnableRSIScalpingXAGUSD)
      DeinitRSIScalping(rsXAGUSDData);
   if(EnableRSIScalpingEURJPY)
      DeinitRSIScalping(rsEURJPYData);
   if(EnableRSIScalpingGBPJPY)
      DeinitRSIScalping(rsGBPJPYData);
   if(EnableRSIScalpingF)
      DeinitRSIScalping(rsFData);
   if(EnableRSIScalpingSOFI)
      DeinitRSIScalping(rsSOFIData);
   if(EnableRSIScalpingSNAP)
      DeinitRSIScalping(rsSNAPData);
   if(EnableRSIScalpingWBD)
      DeinitRSIScalping(rsWBDData);

   if(EnableRSISecretSauce)
      DeinitRSISecretSauce(rssData);

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
   if(EnableSimpleTrendlineGER40)
      DeinitSimpleTrendline(stGERData);

   if(EnableUSDJPYBuster)
      DeinitUSDJPYBuster(ubData);

   if(EnableXAUBearTrend)
      DeinitXAUBearTrend(xbtData);

   if(EnableXAUMomentumBreakdown)
      DeinitXAUMomentumBreakdown(xmbData);

   if(EnableRSIReversalAsianGBPUSD)
      DeinitRSIReversalAsian(rraGBPUSDData);

   if(EnableGER40Buster)
      DeinitUSDJPYBuster(gbData);

   if(EnableRSIReversalAsianUSDCHF)
      DeinitRSIReversalAsian(rraUSDCHFData);

   if(EnableRSIReversalAsianNZDUSD)
      DeinitRSIReversalAsian(rraNZDUSDData);

   if(EnableNAS100Buster)
      DeinitUSDJPYBuster(nbData);

   if(EnableUS500Buster)
      DeinitUSDJPYBuster(u5bData);

   if(EnableUS30Buster)
      DeinitUSDJPYBuster(u30bData);

   if(EnableUK100Buster)
      DeinitUSDJPYBuster(ukbData);

   if(EnableXAGUSDBuster)
      DeinitUSDJPYBuster(xgbData);
   
   Print("United EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   United_RefreshScaledLots();
   United_ProcessGapGuard(g_gapTrade);

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
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_APPL_UseTrailingStop, RS_APPL_TrailDistancePoints, RS_APPL_TrailActivationPoints);

   if(EnableRSIScalpingADBE)
      ProcessRSIScalping(rsADBEData, RS_ADBE_Symbol, RS_ADBE_TimeFrame, RS_ADBE_RSI_Period, RS_ADBE_RSI_Applied_Price,
                        RS_ADBE_RSI_Overbought, RS_ADBE_RSI_Oversold, RS_ADBE_RSI_Target_Buy, RS_ADBE_RSI_Target_Sell,
                        RS_ADBE_BarsToWait, g_Pos_RS_ADBE, RS_ADBE_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_ADBE_UseTrailingStop, RS_ADBE_TrailDistancePoints, RS_ADBE_TrailActivationPoints);
   
   if(EnableRSIScalpingBTCUSD)
      ProcessRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price,
                        RS_BTCUSD_RSI_Overbought, RS_BTCUSD_RSI_Oversold, RS_BTCUSD_RSI_Target_Buy, RS_BTCUSD_RSI_Target_Sell,
                        RS_BTCUSD_BarsToWait, g_Pos_RS_BTCUSD, RS_BTCUSD_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_BTCUSD_UseTrailingStop, RS_BTCUSD_TrailDistancePoints, RS_BTCUSD_TrailActivationPoints);
   
   if(EnableRSIScalpingNVDA)
      ProcessRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price,
                        RS_NVDA_RSI_Overbought, RS_NVDA_RSI_Oversold, RS_NVDA_RSI_Target_Buy, RS_NVDA_RSI_Target_Sell,
                        RS_NVDA_BarsToWait, g_Pos_RS_NVDA, RS_NVDA_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_NVDA_UseTrailingStop, RS_NVDA_TrailDistancePoints, RS_NVDA_TrailActivationPoints);
   
   if(EnableRSIScalpingTSLA)
      ProcessRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price,
                        RS_TSLA_RSI_Overbought, RS_TSLA_RSI_Oversold, RS_TSLA_RSI_Target_Buy, RS_TSLA_RSI_Target_Sell,
                        RS_TSLA_BarsToWait, g_Pos_RS_TSLA, RS_TSLA_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_TSLA_UseTrailingStop, RS_TSLA_TrailDistancePoints, RS_TSLA_TrailActivationPoints);
   
   if(EnableRSIScalpingXAUUSD)
      ProcessRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price,
                        RS_XAUUSD_RSI_Overbought, RS_XAUUSD_RSI_Oversold, RS_XAUUSD_RSI_Target_Buy, RS_XAUUSD_RSI_Target_Sell,
                        RS_XAUUSD_BarsToWait, g_Pos_RS_XAUUSD, RS_XAUUSD_MagicNumber,
                        RS_UseReversalEscape, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_XAUUSD_UseTrailingStop, RS_XAUUSD_TrailDistancePoints, RS_XAUUSD_TrailActivationPoints);
   if(EnableRSIScalpingMU)
      ProcessRSIScalping(rsMUData, RS_MU_Symbol, RS_MU_TimeFrame, RS_MU_RSI_Period, RS_MU_RSI_Applied_Price,
                        RS_MU_RSI_Overbought, RS_MU_RSI_Oversold, RS_MU_RSI_Target_Buy, RS_MU_RSI_Target_Sell,
                        RS_MU_BarsToWait, g_Pos_RS_MU, RS_MU_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        false, 0.0, 0.0);

   if(EnableRSIScalpingNAS100)
      ProcessRSIScalping(rsNAS100Data, RS_NAS100_Symbol, RS_NAS100_TimeFrame, RS_NAS100_RSI_Period, RS_NAS100_RSI_Applied_Price,
                        RS_NAS100_RSI_Overbought, RS_NAS100_RSI_Oversold, RS_NAS100_RSI_Target_Buy, RS_NAS100_RSI_Target_Sell,
                        RS_NAS100_BarsToWait, g_Pos_RS_NAS100, RS_NAS100_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_NAS100_UseTrailingStop, RS_NAS100_TrailDistancePoints, RS_NAS100_TrailActivationPoints);

   if(EnableRSIScalpingUS500)
      ProcessRSIScalping(rsUS500Data, RS_US500_Symbol, RS_US500_TimeFrame, RS_US500_RSI_Period, RS_US500_RSI_Applied_Price,
                        RS_US500_RSI_Overbought, RS_US500_RSI_Oversold, RS_US500_RSI_Target_Buy, RS_US500_RSI_Target_Sell,
                        RS_US500_BarsToWait, g_Pos_RS_US500, RS_US500_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_US500_UseTrailingStop, RS_US500_TrailDistancePoints, RS_US500_TrailActivationPoints);

   if(EnableRSIScalpingUS30)
      ProcessRSIScalping(rsUS30Data, RS_US30_Symbol, RS_US30_TimeFrame, RS_US30_RSI_Period, RS_US30_RSI_Applied_Price,
                        RS_US30_RSI_Overbought, RS_US30_RSI_Oversold, RS_US30_RSI_Target_Buy, RS_US30_RSI_Target_Sell,
                        RS_US30_BarsToWait, g_Pos_RS_US30, RS_US30_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_US30_UseTrailingStop, RS_US30_TrailDistancePoints, RS_US30_TrailActivationPoints);

   if(EnableRSIScalpingXAGUSD)
      ProcessRSIScalping(rsXAGUSDData, RS_XAGUSD_Symbol, RS_XAGUSD_TimeFrame, RS_XAGUSD_RSI_Period, RS_XAGUSD_RSI_Applied_Price,
                        RS_XAGUSD_RSI_Overbought, RS_XAGUSD_RSI_Oversold, RS_XAGUSD_RSI_Target_Buy, RS_XAGUSD_RSI_Target_Sell,
                        RS_XAGUSD_BarsToWait, g_Pos_RS_XAGUSD, RS_XAGUSD_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_XAGUSD_UseTrailingStop, RS_XAGUSD_TrailDistancePoints, RS_XAGUSD_TrailActivationPoints);

   if(EnableRSIScalpingEURJPY)
      ProcessRSIScalping(rsEURJPYData, RS_EURJPY_Symbol, RS_EURJPY_TimeFrame, RS_EURJPY_RSI_Period, RS_EURJPY_RSI_Applied_Price,
                        RS_EURJPY_RSI_Overbought, RS_EURJPY_RSI_Oversold, RS_EURJPY_RSI_Target_Buy, RS_EURJPY_RSI_Target_Sell,
                        RS_EURJPY_BarsToWait, g_Pos_RS_EURJPY, RS_EURJPY_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_EURJPY_UseTrailingStop, RS_EURJPY_TrailDistancePoints, RS_EURJPY_TrailActivationPoints);

   if(EnableRSIScalpingGBPJPY)
      ProcessRSIScalping(rsGBPJPYData, RS_GBPJPY_Symbol, RS_GBPJPY_TimeFrame, RS_GBPJPY_RSI_Period, RS_GBPJPY_RSI_Applied_Price,
                        RS_GBPJPY_RSI_Overbought, RS_GBPJPY_RSI_Oversold, RS_GBPJPY_RSI_Target_Buy, RS_GBPJPY_RSI_Target_Sell,
                        RS_GBPJPY_BarsToWait, g_Pos_RS_GBPJPY, RS_GBPJPY_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_GBPJPY_UseTrailingStop, RS_GBPJPY_TrailDistancePoints, RS_GBPJPY_TrailActivationPoints);

   if(EnableRSIScalpingF)
      ProcessRSIScalping(rsFData, RS_F_Symbol, RS_F_TimeFrame, RS_F_RSI_Period, RS_F_RSI_Applied_Price,
                        RS_F_RSI_Overbought, RS_F_RSI_Oversold, RS_F_RSI_Target_Buy, RS_F_RSI_Target_Sell,
                        RS_F_BarsToWait, g_Pos_RS_F, RS_F_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_F_UseTrailingStop, RS_F_TrailDistancePoints, RS_F_TrailActivationPoints);
   if(EnableRSIScalpingSOFI)
      ProcessRSIScalping(rsSOFIData, RS_SOFI_Symbol, RS_SOFI_TimeFrame, RS_SOFI_RSI_Period, RS_SOFI_RSI_Applied_Price,
                        RS_SOFI_RSI_Overbought, RS_SOFI_RSI_Oversold, RS_SOFI_RSI_Target_Buy, RS_SOFI_RSI_Target_Sell,
                        RS_SOFI_BarsToWait, g_Pos_RS_SOFI, RS_SOFI_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_SOFI_UseTrailingStop, RS_SOFI_TrailDistancePoints, RS_SOFI_TrailActivationPoints);
   if(EnableRSIScalpingSNAP)
      ProcessRSIScalping(rsSNAPData, RS_SNAP_Symbol, RS_SNAP_TimeFrame, RS_SNAP_RSI_Period, RS_SNAP_RSI_Applied_Price,
                        RS_SNAP_RSI_Overbought, RS_SNAP_RSI_Oversold, RS_SNAP_RSI_Target_Buy, RS_SNAP_RSI_Target_Sell,
                        RS_SNAP_BarsToWait, g_Pos_RS_SNAP, RS_SNAP_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_SNAP_UseTrailingStop, RS_SNAP_TrailDistancePoints, RS_SNAP_TrailActivationPoints);
   if(EnableRSIScalpingWBD)
      ProcessRSIScalping(rsWBDData, RS_WBD_Symbol, RS_WBD_TimeFrame, RS_WBD_RSI_Period, RS_WBD_RSI_Applied_Price,
                        RS_WBD_RSI_Overbought, RS_WBD_RSI_Oversold, RS_WBD_RSI_Target_Buy, RS_WBD_RSI_Target_Sell,
                        RS_WBD_BarsToWait, g_Pos_RS_WBD, RS_WBD_MagicNumber,
                        false, RS_ReversalATRPeriod, RS_ReversalAdverseAtrMult, RS_ReversalSignsRequired,
                        RS_ReversalRsiVelocity, RS_ReversalBodyAtrMult,
                        RS_WBD_UseTrailingStop, RS_WBD_TrailDistancePoints, RS_WBD_TrailActivationPoints);

   if(EnableRSISecretSauce)
      ProcessRSISecretSauce(rssData, g_RSS_LotSize);
   
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
   if(EnableSimpleTrendlineGER40)
      ProcessSimpleTrendline(stGERData, g_Pos_ST_GER40);

   if(EnableUSDJPYBuster)
      ProcessUSDJPYBuster(ubData, g_Pos_UB_USDJPY, United_BalanceScaleFactor());

   if(EnableXAUBearTrend)
      ProcessXAUBearTrend(xbtData, g_Pos_XBT_XAUUSD);

   if(EnableXAUMomentumBreakdown)
      ProcessXAUMomentumBreakdown(xmbData, g_Pos_XMB_XAUUSD);

   if(EnableRSIReversalAsianGBPUSD)
      ProcessRSIReversalAsian(rraGBPUSDData, g_Pos_RRA_GBPUSD);

   if(EnableGER40Buster)
      ProcessUSDJPYBuster(gbData, g_Pos_GB_GER40, United_BalanceScaleFactor());

   if(EnableRSIReversalAsianUSDCHF)
      ProcessRSIReversalAsian(rraUSDCHFData, g_Pos_RRA_USDCHF);

   if(EnableRSIReversalAsianNZDUSD)
      ProcessRSIReversalAsian(rraNZDUSDData, g_Pos_RRA_NZDUSD);

   if(EnableNAS100Buster)
      ProcessUSDJPYBuster(nbData, g_Pos_NB_NAS100, United_BalanceScaleFactor());

   if(EnableUS500Buster)
      ProcessUSDJPYBuster(u5bData, g_Pos_U5B_US500, United_BalanceScaleFactor());

   if(EnableUS30Buster)
      ProcessUSDJPYBuster(u30bData, g_Pos_U30B_US30, United_BalanceScaleFactor());

   if(EnableUK100Buster)
      ProcessUSDJPYBuster(ukbData, g_Pos_UKB_UK100, United_BalanceScaleFactor());

   if(EnableXAGUSDBuster)
      ProcessUSDJPYBuster(xgbData, g_Pos_XGB_XAGUSD, United_BalanceScaleFactor());
}

//+------------------------------------------------------------------+
