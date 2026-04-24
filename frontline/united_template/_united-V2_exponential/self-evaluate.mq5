//+------------------------------------------------------------------+
//|                                                    UnitedEA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Trend.mqh>
#include <Indicators\Volumes.mqh>
#include "MagicNumberHelpers.mqh"
#include "PerformanceEvaluator.mqh"

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
input bool EnableRSIScalpingMSFT = true;
input bool EnableRSIScalpingNVDA = true;
input bool EnableRSIScalpingTSLA = true;
input bool EnableRSIScalpingXAUUSD = true;

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
//| - MSFT: Microsoft stock                                           |
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

input group "=== RSI Scalping MSFT - Pepperstone US ==="
input string RS_MSFT_Symbol = "MSFT.US";  // Try: "MSFT.US", "NASDAQ:MSFT", or "MSFT"
input ENUM_TIMEFRAMES RS_MSFT_TimeFrame = PERIOD_H3;
input int    RS_MSFT_RSI_Period = 14;
input ENUM_APPLIED_PRICE RS_MSFT_RSI_Applied_Price = PRICE_CLOSE;
input double RS_MSFT_RSI_Overbought = 19;
input double RS_MSFT_RSI_Oversold = 50;
input double RS_MSFT_RSI_Target_Buy = 71;
input double RS_MSFT_RSI_Target_Sell = 70;
input int    RS_MSFT_BarsToWait = 1;
input double RS_MSFT_LotSize = 50;
input int    RS_MSFT_MagicNumber = 20002;
input int    RS_MSFT_Slippage = 3;

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
//| Global Variables - RSI Scalping                                  |
//+------------------------------------------------------------------+
struct RSIScalpingData {
   string symbol;
   bool isInitialized;
   CTrade trade;
   int rsi_handle;
   double rsi_buffer[];
   double rsi_prev;
   double rsi_current;
   double rsi_two_bars_ago;
   bool position_open;
   ulong position_ticket;
   ENUM_POSITION_TYPE current_position_type;
   datetime last_bar_time;
   bool rsi_against_position;
   int bars_against_count;
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
RSIScalpingData rsMSFTData;
RSIScalpingData rsNVDAData;
RSIScalpingData rsTSLAData;
RSIScalpingData rsXAUUSDData;

//+------------------------------------------------------------------+
//| Global Variables for Dynamic Lot Sizes                           |
//+------------------------------------------------------------------+
// All strategies start with minimum lot size for safety (will be adjusted by performance evaluator)
double g_DB_LotSize = 0.01;  // DarvasBox uses fixed lot size
double g_ES_LotSize = 0.01;  // EMA Slope Distance - start with minimum
double g_RC_LotSize = 0.01;  // RSI CrossOver Reversal - start with minimum
double g_RM_LotSize = 0.01;  // RSI MidPoint Hijack - start with minimum
double g_RS_APPL_LotSize = 5.0;  // Stock - start with stock minimum (5.0)
double g_RS_BTCUSD_LotSize = 0.01;  // Crypto - start with forex minimum (0.01)
double g_RS_MSFT_LotSize = 5.0;  // Stock - start with stock minimum (5.0)
double g_RS_NVDA_LotSize = 5.0;  // Stock - start with stock minimum (5.0)
double g_RS_TSLA_LotSize = 5.0;  // Stock - start with stock minimum (5.0)
double g_RS_XAUUSD_LotSize = 0.01;  // Forex - start with forex minimum (0.01)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int initResult = INIT_SUCCEEDED;
   
   // Initialize Performance Evaluator
   InitPerformanceTracking();
   
   // Initialize strategies - log warnings but don't fail entire EA if symbol unavailable
   if(EnableDarvasBox)
   {
      if(!InitDarvasBox(DB_Symbol))
         Print("Warning: DarvasBox strategy failed to initialize for symbol '", DB_Symbol, "'");
      else
         RegisterStrategy("DarvasBox", DB_MagicNumber, 0.01, DB_Symbol); // Fixed lot size
   }
   
   if(EnableEMASlopeDistance)
   {
      if(!InitEMASlopeDistance(ES_Symbol))
         Print("Warning: EMASlopeDistance strategy failed to initialize for symbol '", ES_Symbol, "'");
      else
      {
         RegisterStrategy("EMASlopeDistance", ES_MagicNumber, ES_LotGröße, ES_Symbol);
         // Start with minimum lot size (will be adjusted by performance evaluator)
         double minLot = GetMinLotSizeForSymbol(ES_Symbol);
         g_ES_LotSize = minLot;
      }
   }
   
   if(EnableRSICrossOverReversal)
   {
      if(!InitRSICrossOverReversal(RC_Symbol))
         Print("Warning: RSICrossOverReversal strategy failed to initialize for symbol '", RC_Symbol, "'");
      else
      {
         RegisterStrategy("RSICrossOverReversal", RC_MagicNumber, RC_lotSize, RC_Symbol);
         // Start with minimum lot size (will be adjusted by performance evaluator)
         double minLot = GetMinLotSizeForSymbol(RC_Symbol);
         g_RC_LotSize = minLot;
      }
   }
   
   if(EnableRSIMidPointHijack)
   {
      if(!InitRSIMidPointHijack(RM_Symbol))
         Print("Warning: RSIMidPointHijack strategy failed to initialize for symbol '", RM_Symbol, "'");
      else
      {
         RegisterStrategy("RSIMidPointHijack", RM_InpMagicNumberRSIFollow, RM_InpLotSize, RM_Symbol);
         RegisterStrategy("RSIMidPointHijack_Reverse", RM_InpMagicNumberRSIReverse, RM_InpLotSize, RM_Symbol);
         RegisterStrategy("RSIMidPointHijack_EMACross", RM_InpMagicNumberEMACross, RM_InpLotSize, RM_Symbol);
         // Start with minimum lot size (will be adjusted by performance evaluator)
         double minLot = GetMinLotSizeForSymbol(RM_Symbol);
         g_RM_LotSize = minLot;
      }
   }
   
   // Initialize RSI Scalping strategies - don't fail entire EA if symbol unavailable
   if(EnableRSIScalpingAPPL)
   {
      InitRSIScalping(rsAPPLData, RS_APPL_Symbol, RS_APPL_TimeFrame, RS_APPL_RSI_Period, RS_APPL_RSI_Applied_Price, RS_APPL_MagicNumber, RS_APPL_Slippage);
      RegisterStrategy("RSIScalpingAPPL", RS_APPL_MagicNumber, RS_APPL_LotSize, RS_APPL_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_APPL_Symbol);
      g_RS_APPL_LotSize = minLot;
   }
   
   if(EnableRSIScalpingBTCUSD)
   {
      InitRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price, RS_BTCUSD_MagicNumber, RS_BTCUSD_Slippage);
      RegisterStrategy("RSIScalpingBTCUSD", RS_BTCUSD_MagicNumber, RS_BTCUSD_LotSize, RS_BTCUSD_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_BTCUSD_Symbol);
      g_RS_BTCUSD_LotSize = minLot;
   }
   
   if(EnableRSIScalpingMSFT)
   {
      InitRSIScalping(rsMSFTData, RS_MSFT_Symbol, RS_MSFT_TimeFrame, RS_MSFT_RSI_Period, RS_MSFT_RSI_Applied_Price, RS_MSFT_MagicNumber, RS_MSFT_Slippage);
      RegisterStrategy("RSIScalpingMSFT", RS_MSFT_MagicNumber, RS_MSFT_LotSize, RS_MSFT_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_MSFT_Symbol);
      g_RS_MSFT_LotSize = minLot;
   }
   
   if(EnableRSIScalpingNVDA)
   {
      InitRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price, RS_NVDA_MagicNumber, RS_NVDA_Slippage);
      RegisterStrategy("RSIScalpingNVDA", RS_NVDA_MagicNumber, RS_NVDA_LotSize, RS_NVDA_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_NVDA_Symbol);
      g_RS_NVDA_LotSize = minLot;
   }
   
   if(EnableRSIScalpingTSLA)
   {
      InitRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price, RS_TSLA_MagicNumber, RS_TSLA_Slippage);
      RegisterStrategy("RSIScalpingTSLA", RS_TSLA_MagicNumber, RS_TSLA_LotSize, RS_TSLA_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_TSLA_Symbol);
      g_RS_TSLA_LotSize = minLot;
   }
   
   if(EnableRSIScalpingXAUUSD)
   {
      InitRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price, RS_XAUUSD_MagicNumber, RS_XAUUSD_Slippage);
      RegisterStrategy("RSIScalpingXAUUSD", RS_XAUUSD_MagicNumber, RS_XAUUSD_LotSize, RS_XAUUSD_Symbol);
      // Start with minimum lot size (will be adjusted by performance evaluator)
      double minLot = GetMinLotSizeForSymbol(RS_XAUUSD_Symbol);
      g_RS_XAUUSD_LotSize = minLot;
   }
   
   // Load adjusted lot sizes from performance evaluator
   if(PE_EnableAutoAdjustment)
   {
      double adjustedLot;
      adjustedLot = GetStrategyLotSize("EMASlopeDistance", ES_MagicNumber);
      if(adjustedLot > 0) g_ES_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSICrossOverReversal", RC_MagicNumber);
      if(adjustedLot > 0) g_RC_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIMidPointHijack", RM_InpMagicNumberRSIFollow);
      if(adjustedLot > 0) g_RM_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingAPPL", RS_APPL_MagicNumber);
      if(adjustedLot > 0) g_RS_APPL_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingBTCUSD", RS_BTCUSD_MagicNumber);
      if(adjustedLot > 0) g_RS_BTCUSD_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingMSFT", RS_MSFT_MagicNumber);
      if(adjustedLot > 0) g_RS_MSFT_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingNVDA", RS_NVDA_MagicNumber);
      if(adjustedLot > 0) g_RS_NVDA_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingTSLA", RS_TSLA_MagicNumber);
      if(adjustedLot > 0) g_RS_TSLA_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingXAUUSD", RS_XAUUSD_MagicNumber);
      if(adjustedLot > 0) g_RS_XAUUSD_LotSize = adjustedLot;
   }
   
   Print("United EA initialized. Active strategies: ", 
         (EnableDarvasBox ? "DarvasBox " : ""),
         (EnableEMASlopeDistance ? "EMASlope " : ""),
         (EnableRSICrossOverReversal ? "RSICrossOver " : ""),
         (EnableRSIMidPointHijack ? "RSIMidPoint " : ""),
         (EnableRSIScalpingAPPL ? "RSIScalpingAPPL " : ""),
         (EnableRSIScalpingBTCUSD ? "RSIScalpingBTCUSD " : ""),
         (EnableRSIScalpingMSFT ? "RSIScalpingMSFT " : ""),
         (EnableRSIScalpingNVDA ? "RSIScalpingNVDA " : ""),
         (EnableRSIScalpingTSLA ? "RSIScalpingTSLA " : ""),
         (EnableRSIScalpingXAUUSD ? "RSIScalpingXAUUSD " : ""));
   
   if(PE_EnableLogging)
      Print(GetPerformanceSummary());
   
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
   
   if(EnableRSIScalpingMSFT)
      DeinitRSIScalping(rsMSFTData);
   
   if(EnableRSIScalpingNVDA)
      DeinitRSIScalping(rsNVDAData);
   
   if(EnableRSIScalpingTSLA)
      DeinitRSIScalping(rsTSLAData);
   
   if(EnableRSIScalpingXAUUSD)
      DeinitRSIScalping(rsXAUUSDData);
   
   Print("United EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process performance evaluation (checks for quarter end and adjusts lot sizes)
   ProcessPerformanceEvaluation();
   
   // Update lot sizes from performance evaluator if auto-adjustment is enabled
   if(PE_EnableAutoAdjustment)
   {
      double adjustedLot;
      adjustedLot = GetStrategyLotSize("EMASlopeDistance", ES_MagicNumber);
      if(adjustedLot > 0) g_ES_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSICrossOverReversal", RC_MagicNumber);
      if(adjustedLot > 0) g_RC_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIMidPointHijack", RM_InpMagicNumberRSIFollow);
      if(adjustedLot > 0) g_RM_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingAPPL", RS_APPL_MagicNumber);
      if(adjustedLot > 0) g_RS_APPL_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingBTCUSD", RS_BTCUSD_MagicNumber);
      if(adjustedLot > 0) g_RS_BTCUSD_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingMSFT", RS_MSFT_MagicNumber);
      if(adjustedLot > 0) g_RS_MSFT_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingNVDA", RS_NVDA_MagicNumber);
      if(adjustedLot > 0) g_RS_NVDA_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingTSLA", RS_TSLA_MagicNumber);
      if(adjustedLot > 0) g_RS_TSLA_LotSize = adjustedLot;
      
      adjustedLot = GetStrategyLotSize("RSIScalpingXAUUSD", RS_XAUUSD_MagicNumber);
      if(adjustedLot > 0) g_RS_XAUUSD_LotSize = adjustedLot;
   }
   
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
                        RS_APPL_BarsToWait, g_RS_APPL_LotSize, RS_APPL_MagicNumber);
   
   if(EnableRSIScalpingBTCUSD)
      ProcessRSIScalping(rsBTCUSDData, RS_BTCUSD_Symbol, RS_BTCUSD_TimeFrame, RS_BTCUSD_RSI_Period, RS_BTCUSD_RSI_Applied_Price,
                        RS_BTCUSD_RSI_Overbought, RS_BTCUSD_RSI_Oversold, RS_BTCUSD_RSI_Target_Buy, RS_BTCUSD_RSI_Target_Sell,
                        RS_BTCUSD_BarsToWait, g_RS_BTCUSD_LotSize, RS_BTCUSD_MagicNumber);
   
   if(EnableRSIScalpingMSFT)
      ProcessRSIScalping(rsMSFTData, RS_MSFT_Symbol, RS_MSFT_TimeFrame, RS_MSFT_RSI_Period, RS_MSFT_RSI_Applied_Price,
                        RS_MSFT_RSI_Overbought, RS_MSFT_RSI_Oversold, RS_MSFT_RSI_Target_Buy, RS_MSFT_RSI_Target_Sell,
                        RS_MSFT_BarsToWait, g_RS_MSFT_LotSize, RS_MSFT_MagicNumber);
   
   if(EnableRSIScalpingNVDA)
      ProcessRSIScalping(rsNVDAData, RS_NVDA_Symbol, RS_NVDA_TimeFrame, RS_NVDA_RSI_Period, RS_NVDA_RSI_Applied_Price,
                        RS_NVDA_RSI_Overbought, RS_NVDA_RSI_Oversold, RS_NVDA_RSI_Target_Buy, RS_NVDA_RSI_Target_Sell,
                        RS_NVDA_BarsToWait, g_RS_NVDA_LotSize, RS_NVDA_MagicNumber);
   
   if(EnableRSIScalpingTSLA)
      ProcessRSIScalping(rsTSLAData, RS_TSLA_Symbol, RS_TSLA_TimeFrame, RS_TSLA_RSI_Period, RS_TSLA_RSI_Applied_Price,
                        RS_TSLA_RSI_Overbought, RS_TSLA_RSI_Oversold, RS_TSLA_RSI_Target_Buy, RS_TSLA_RSI_Target_Sell,
                        RS_TSLA_BarsToWait, g_RS_TSLA_LotSize, RS_TSLA_MagicNumber);
   
   if(EnableRSIScalpingXAUUSD)
      ProcessRSIScalping(rsXAUUSDData, RS_XAUUSD_Symbol, RS_XAUUSD_TimeFrame, RS_XAUUSD_RSI_Period, RS_XAUUSD_RSI_Applied_Price,
                        RS_XAUUSD_RSI_Overbought, RS_XAUUSD_RSI_Oversold, RS_XAUUSD_RSI_Target_Buy, RS_XAUUSD_RSI_Target_Sell,
                        RS_XAUUSD_BarsToWait, g_RS_XAUUSD_LotSize, RS_XAUUSD_MagicNumber);
}

//+------------------------------------------------------------------+
//| Include strategy implementations                                 |
//+------------------------------------------------------------------+
#include "Strategies/DarvasBoxStrategy.mqh"
#include "Strategies/EMASlopeDistanceStrategy.mqh"
#include "Strategies/RSICrossOverReversalStrategy.mqh"
#include "Strategies/RSIMidPointHijackStrategy.mqh"
#include "Strategies/RSIScalpingStrategy.mqh"

//+------------------------------------------------------------------+
