//+------------------------------------------------------------------+
//|                                         RSI_SecretSauce_XAUUSD.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.01"
#property description "RSI Secret Sauce Strategy: Wait for RSI to leave 70/30 zone, then enter when it comes back in"
#property description "Based on momentum flip concept - not traditional overbought/oversold"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Input Parameters
input group "=== Trading Settings ==="
input string InpSymbol = "XAUUSD";                    // Default gold; same numbers as secret_sauce.set (that file uses BTCUSD as symbol)
input double InpLotSize = 0.1;                        // Lot Size (Profiles/Tester/secret_sauce.set)
input int InpMagicNumber = 789012;                   // Magic Number
input int InpSlippage = 10;                           // Slippage in points
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M30;      // Trading Timeframe (set value 30 = M30)

input group "=== RSI Settings ==="
input int InpRSIPeriod = 16;                          // RSI Period
input double InpRSIOverbought = 72.5;                // RSI Overbought Level
input double InpRSIOversold = 32.5;                  // RSI Oversold Level
input int InpRSILookback = 60;                       // RSI Lookback for Peak/Bottom Detection

input group "=== Entry Logic ==="
input int InpPeakBars = 2;                            // Bars to confirm peak/bottom
input bool InpRequireDivergence = false;              // Require divergence confirmation (optional)

input group "=== Risk Management ==="
input double InpStopLossATR = 2.75;                  // Stop Loss (ATR multiples)
input double InpTakeProfitATR = 5.0;                  // Take Profit (ATR multiples)
input int InpATRPeriod = 14;                         // ATR Period
input bool InpUseSwingStopLoss = false;               // Use previous swing high/low for stop loss
input int InpSwingLookback = 30;                      // Bars to look back for swing points

input group "=== Position Management ==="
input int InpMaxPositions = 1;                        // Max Simultaneous Positions
input int InpMinBarsBetweenTrades = 7;                // Min Bars Between Trades

//--- Global Variables
CTrade trade;
CPositionInfo positionInfo;

string actualSymbol;
int rsiHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;

double rsiBuffer[];
double atrBuffer[];
double highBuffer[];
double lowBuffer[];

// RSI state tracking
bool rsiWasOverbought = false;    // RSI was above 70
bool rsiWasOversold = false;      // RSI was below 30
bool rsiBackInRange = false;       // RSI came back into range
datetime lastRSIExitTime = 0;      // When RSI left the range
datetime lastRSIReentryTime = 0;   // When RSI came back in

// Trade tracking
datetime lastTradeTime = 0;
int barsSinceLastTrade = 0;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Determine actual symbol
   if(InpSymbol == "" || InpSymbol == NULL)
      actualSymbol = _Symbol;
   else
      actualSymbol = InpSymbol;
   
   // Check if symbol exists
   if(!SymbolInfoInteger(actualSymbol, SYMBOL_SELECT))
   {
      Print("Error: Symbol ", actualSymbol, " not found. Using chart symbol.");
      actualSymbol = _Symbol;
   }
   
   // Initialize RSI indicator
   rsiHandle = iRSI(actualSymbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Error creating RSI indicator");
      return INIT_FAILED;
   }
   ArraySetAsSeries(rsiBuffer, true);
   
   // Initialize ATR indicator
   atrHandle = iATR(actualSymbol, InpTimeframe, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Error creating ATR indicator");
      return INIT_FAILED;
   }
   ArraySetAsSeries(atrBuffer, true);
   
   // Initialize price buffers
   ArraySetAsSeries(highBuffer, true);
   ArraySetAsSeries(lowBuffer, true);
   
   // Set trade parameters
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   Print("=== RSI Secret Sauce Strategy Initialized ===");
   Print("Symbol: ", actualSymbol);
   Print("Timeframe: ", EnumToString(InpTimeframe));
   Print("RSI Period: ", InpRSIPeriod, " | Overbought: ", InpRSIOverbought, " | Oversold: ", InpRSIOversold);
   Print("Stop Loss: ", InpStopLossATR, "x ATR | Take Profit: ", InpTakeProfitATR, "x ATR");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   
   Print("Expert Advisor deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if we have enough bars
   int requiredBars = MathMax(InpRSILookback, InpSwingLookback) + 10;
   if(Bars(actualSymbol, InpTimeframe) < requiredBars)
      return;
   
   // Check if this is a new bar (wait for candle close)
   datetime currentBarTime = iTime(actualSymbol, InpTimeframe, 0);
   if(currentBarTime == lastBarTime)
      return; // Still the same bar, don't process
   
   lastBarTime = currentBarTime;
   
   // Update indicators
   if(!UpdateIndicators())
      return;
   
   // Update RSI state tracking
   UpdateRSIState();
   
   // Check existing positions
   CheckExistingPositions();
   
   // Check for entry signals
   if(CanOpenNewPosition())
   {
      CheckEntrySignals();
   }
}

//+------------------------------------------------------------------+
//| Update indicator values                                          |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   // Update RSI (need enough bars for lookback)
   int rsiBarsNeeded = InpRSILookback + 5;
   if(CopyBuffer(rsiHandle, 0, 0, rsiBarsNeeded, rsiBuffer) < rsiBarsNeeded)
      return false;
   
   // Update ATR
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuffer) < 2)
      return false;
   
   // Update price buffers for swing detection
   if(CopyHigh(actualSymbol, InpTimeframe, 0, InpSwingLookback + 5, highBuffer) < InpSwingLookback + 5)
      return false;
   if(CopyLow(actualSymbol, InpTimeframe, 0, InpSwingLookback + 5, lowBuffer) < InpSwingLookback + 5)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Update RSI state tracking                                        |
//+------------------------------------------------------------------+
void UpdateRSIState()
{
   double rsiCurrent = rsiBuffer[0];
   double rsiPrev = rsiBuffer[1];
   
   // Check if RSI left overbought zone (was above 70, now below 70)
   if(rsiPrev >= InpRSIOverbought && rsiCurrent < InpRSIOverbought)
   {
      rsiWasOverbought = true;
      rsiBackInRange = true;
      lastRSIExitTime = TimeCurrent();
      lastRSIReentryTime = TimeCurrent();
      Print(TimeToString(TimeCurrent()), " - RSI left overbought zone (", rsiPrev, " -> ", rsiCurrent, ")");
   }
   
   // Check if RSI left oversold zone (was below 30, now above 30)
   if(rsiPrev <= InpRSIOversold && rsiCurrent > InpRSIOversold)
   {
      rsiWasOversold = true;
      rsiBackInRange = true;
      lastRSIExitTime = TimeCurrent();
      lastRSIReentryTime = TimeCurrent();
      Print(TimeToString(TimeCurrent()), " - RSI left oversold zone (", rsiPrev, " -> ", rsiCurrent, ")");
   }
   
   // Reset flags if RSI goes back to extreme
   if(rsiCurrent >= InpRSIOverbought)
   {
      rsiWasOverbought = false;
      rsiBackInRange = false;
   }
   
   if(rsiCurrent <= InpRSIOversold)
   {
      rsiWasOversold = false;
      rsiBackInRange = false;
   }
}

//+------------------------------------------------------------------+
//| Check if we can open a new position                              |
//+------------------------------------------------------------------+
bool CanOpenNewPosition()
{
   // Check max positions
   int positionCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == actualSymbol && positionInfo.Magic() == InpMagicNumber)
            positionCount++;
      }
   }
   
   if(positionCount >= InpMaxPositions)
      return false;
   
   // Check minimum bars between trades
   if(lastTradeTime > 0)
   {
      int barsSince = Bars(actualSymbol, InpTimeframe, lastTradeTime, TimeCurrent());
      if(barsSince < InpMinBarsBetweenTrades)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check for entry signals                                          |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   // LONG Entry: RSI was overbought (>70), came back in range, now look for peak
   if(rsiWasOverbought && rsiBackInRange)
   {
      // Check if RSI is back in normal range (below 70)
      if(rsiBuffer[0] < InpRSIOverbought)
      {
         // Look for a peak in RSI after re-entry
         if(IsRSIPeak())
         {
            Print(TimeToString(TimeCurrent()), " - LONG Signal: RSI peak detected after leaving overbought zone");
            OpenPosition(POSITION_TYPE_BUY);
         }
      }
   }
   
   // SHORT Entry: RSI was oversold (<30), came back in range, now look for bottom
   if(rsiWasOversold && rsiBackInRange)
   {
      // Check if RSI is back in normal range (above 30)
      if(rsiBuffer[0] > InpRSIOversold)
      {
         // Look for a bottom in RSI after re-entry
         if(IsRSIBottom())
         {
            Print(TimeToString(TimeCurrent()), " - SHORT Signal: RSI bottom detected after leaving oversold zone");
            OpenPosition(POSITION_TYPE_SELL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if RSI is forming a peak (for LONG entry)                 |
//+------------------------------------------------------------------+
bool IsRSIPeak()
{
   // We need at least InpPeakBars + 1 bars to confirm a peak
   if(ArraySize(rsiBuffer) < InpPeakBars + 2)
      return false;
   
   // Check if current RSI is higher than previous bars (forming a peak)
   double currentRSI = rsiBuffer[0];
   bool isPeak = true;
   
   // Check if current is higher than the next few bars
   for(int i = 1; i <= InpPeakBars; i++)
   {
      if(rsiBuffer[i] >= currentRSI)
      {
         isPeak = false;
         break;
      }
   }
   
   // Also check if previous bar was lower (confirming upward movement before peak)
   if(rsiBuffer[1] >= currentRSI)
      isPeak = false;
   
   return isPeak;
}

//+------------------------------------------------------------------+
//| Check if RSI is forming a bottom (for SHORT entry)               |
//+------------------------------------------------------------------+
bool IsRSIBottom()
{
   // We need at least InpPeakBars + 1 bars to confirm a bottom
   if(ArraySize(rsiBuffer) < InpPeakBars + 2)
      return false;
   
   // Check if current RSI is lower than previous bars (forming a bottom)
   double currentRSI = rsiBuffer[0];
   bool isBottom = true;
   
   // Check if current is lower than the next few bars
   for(int i = 1; i <= InpPeakBars; i++)
   {
      if(rsiBuffer[i] <= currentRSI)
      {
         isBottom = false;
         break;
      }
   }
   
   // Also check if previous bar was higher (confirming downward movement before bottom)
   if(rsiBuffer[1] <= currentRSI)
      isBottom = false;
   
   return isBottom;
}

//+------------------------------------------------------------------+
//| Open position                                                    |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_POSITION_TYPE type)
{
   double price = (type == POSITION_TYPE_BUY) ? 
                  SymbolInfoDouble(actualSymbol, SYMBOL_ASK) : 
                  SymbolInfoDouble(actualSymbol, SYMBOL_BID);
   
   if(price <= 0)
      return;
   
   // Calculate stop loss and take profit
   double sl = 0.0, tp = 0.0;
   if(!CalculateStops(price, type, sl, tp))
   {
      Print("Error: Failed to calculate stops");
      return;
   }
   
   string comment = "RSI_Secret_" + (type == POSITION_TYPE_BUY ? "LONG" : "SHORT");
   
   bool result = false;
   if(type == POSITION_TYPE_BUY)
      result = trade.Buy(InpLotSize, actualSymbol, 0, sl, tp, comment);
   else
      result = trade.Sell(InpLotSize, actualSymbol, 0, sl, tp, comment);
   
   if(result)
   {
      lastTradeTime = TimeCurrent();
      ulong ticket = trade.ResultOrder();
      Print(TimeToString(TimeCurrent()), " - Position opened: ", comment, " Ticket: ", ticket, 
            " Price: ", price, " SL: ", sl, " TP: ", tp);
      
      // Reset RSI state after opening position
      if(type == POSITION_TYPE_BUY)
         rsiWasOverbought = false;
      else
         rsiWasOversold = false;
      rsiBackInRange = false;
   }
   else
   {
      Print("Failed to open position: ", comment, " Error: ", 
            trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Calculate stop loss and take profit                              |
//+------------------------------------------------------------------+
bool CalculateStops(double price, ENUM_POSITION_TYPE type, double &sl, double &tp)
{
   double atrValue = atrBuffer[0];
   if(atrValue <= 0)
      atrValue = price * 0.01; // Fallback: 1% of price
   
   double slDistance = atrValue * InpStopLossATR;
   double tpDistance = atrValue * InpTakeProfitATR;
   
   int digits = (int)SymbolInfoInteger(actualSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(actualSymbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(actualSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = MathMax(stopsLevel * point, point * 10);
   
   // Use swing-based stop loss if enabled
   if(InpUseSwingStopLoss)
   {
      double swingStop = GetSwingStopLoss(price, type);
      if(swingStop > 0)
      {
         if(type == POSITION_TYPE_BUY)
         {
            if(swingStop < price && (price - swingStop) > minStopDistance)
               slDistance = price - swingStop;
         }
         else
         {
            if(swingStop > price && (swingStop - price) > minStopDistance)
               slDistance = swingStop - price;
         }
      }
   }
   
   // Ensure minimum distance
   if(slDistance < minStopDistance)
      slDistance = minStopDistance;
   if(tpDistance < minStopDistance)
      tpDistance = minStopDistance;
   
   if(type == POSITION_TYPE_BUY)
   {
      sl = NormalizeDouble(price - slDistance, digits);
      tp = NormalizeDouble(price + tpDistance, digits);
   }
   else
   {
      sl = NormalizeDouble(price + slDistance, digits);
      tp = NormalizeDouble(price - tpDistance, digits);
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Get swing-based stop loss (previous swing high/low)              |
//+------------------------------------------------------------------+
double GetSwingStopLoss(double currentPrice, ENUM_POSITION_TYPE type)
{
   // For LONG: find previous swing low
   // For SHORT: find previous swing high
   
   if(type == POSITION_TYPE_BUY)
   {
      // Find the lowest low in the lookback period
      double lowestLow = lowBuffer[0];
      for(int i = 1; i < InpSwingLookback && i < ArraySize(lowBuffer); i++)
      {
         if(lowBuffer[i] < lowestLow)
            lowestLow = lowBuffer[i];
      }
      return lowestLow;
   }
   else
   {
      // Find the highest high in the lookback period
      double highestHigh = highBuffer[0];
      for(int i = 1; i < InpSwingLookback && i < ArraySize(highBuffer); i++)
      {
         if(highBuffer[i] > highestHigh)
            highestHigh = highBuffer[i];
      }
      return highestHigh;
   }
}

//+------------------------------------------------------------------+
//| Check existing positions                                         |
//+------------------------------------------------------------------+
void CheckExistingPositions()
{
   // Position management can be added here if needed
   // For now, positions are managed by TP/SL
}

//+------------------------------------------------------------------+
