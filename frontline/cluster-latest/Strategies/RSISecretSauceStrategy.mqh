//+------------------------------------------------------------------+
//|                               RSISecretSauceStrategy.mqh        |
//| Cluster-0 orchestrator: RSI leave extreme then peak/bottom entry |
//+------------------------------------------------------------------+
#ifndef RSI_SECRET_SAUCE_STRATEGY_MQH
#define RSI_SECRET_SAUCE_STRATEGY_MQH

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

struct RSISecretSauceOrcData
{
   string              actualSymbol;
   bool                isInitialized;
   CTrade              trade;
   CPositionInfo       positionInfo;
   int                 rsiHandle;
   int                 atrHandle;
   double              rsiBuffer[];
   double              atrBuffer[];
   double              highBuffer[];
   double              lowBuffer[];
   bool                rsiWasOverbought;
   bool                rsiWasOversold;
   bool                rsiBackInRange;
   datetime            lastRSIExitTime;
   datetime            lastRSIReentryTime;
   datetime            lastTradeTime;
   datetime            lastBarTime;
};

bool RSS_UpdateIndicators(RSISecretSauceOrcData &d)
{
   int rsiBarsNeeded = RSS_RSILookback + 5;
   if(CopyBuffer(d.rsiHandle, 0, 0, rsiBarsNeeded, d.rsiBuffer) < rsiBarsNeeded)
      return false;
   if(CopyBuffer(d.atrHandle, 0, 0, 2, d.atrBuffer) < 2)
      return false;
   if(CopyHigh(d.actualSymbol, RSS_Timeframe, 0, RSS_SwingLookback + 5, d.highBuffer) < RSS_SwingLookback + 5)
      return false;
   if(CopyLow(d.actualSymbol, RSS_Timeframe, 0, RSS_SwingLookback + 5, d.lowBuffer) < RSS_SwingLookback + 5)
      return false;
   return true;
}

void RSS_UpdateRSIState(RSISecretSauceOrcData &d)
{
   double rsiCurrent = d.rsiBuffer[0];
   double rsiPrev = d.rsiBuffer[1];

   if(rsiPrev >= RSS_RSIOverbought && rsiCurrent < RSS_RSIOverbought)
   {
      d.rsiWasOverbought = true;
      d.rsiBackInRange = true;
      d.lastRSIExitTime = TimeCurrent();
      d.lastRSIReentryTime = TimeCurrent();
   }

   if(rsiPrev <= RSS_RSIOversold && rsiCurrent > RSS_RSIOversold)
   {
      d.rsiWasOversold = true;
      d.rsiBackInRange = true;
      d.lastRSIExitTime = TimeCurrent();
      d.lastRSIReentryTime = TimeCurrent();
   }

   if(rsiCurrent >= RSS_RSIOverbought)
   {
      d.rsiWasOverbought = false;
      d.rsiBackInRange = false;
   }

   if(rsiCurrent <= RSS_RSIOversold)
   {
      d.rsiWasOversold = false;
      d.rsiBackInRange = false;
   }
}

bool RSS_IsRSIPeak(RSISecretSauceOrcData &d)
{
   if(ArraySize(d.rsiBuffer) < RSS_PeakBars + 2)
      return false;
   double currentRSI = d.rsiBuffer[0];
   bool isPeak = true;
   for(int i = 1; i <= RSS_PeakBars; i++)
   {
      if(d.rsiBuffer[i] >= currentRSI)
      {
         isPeak = false;
         break;
      }
   }
   if(d.rsiBuffer[1] >= currentRSI)
      isPeak = false;
   return isPeak;
}

bool RSS_IsRSIBottom(RSISecretSauceOrcData &d)
{
   if(ArraySize(d.rsiBuffer) < RSS_PeakBars + 2)
      return false;
   double currentRSI = d.rsiBuffer[0];
   bool isBottom = true;
   for(int i = 1; i <= RSS_PeakBars; i++)
   {
      if(d.rsiBuffer[i] <= currentRSI)
      {
         isBottom = false;
         break;
      }
   }
   if(d.rsiBuffer[1] <= currentRSI)
      isBottom = false;
   return isBottom;
}

double RSS_GetSwingStopLoss(RSISecretSauceOrcData &d, double currentPrice, ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)
   {
      double lowestLow = d.lowBuffer[0];
      for(int i = 1; i < RSS_SwingLookback && i < ArraySize(d.lowBuffer); i++)
      {
         if(d.lowBuffer[i] < lowestLow)
            lowestLow = d.lowBuffer[i];
      }
      return lowestLow;
   }
   double highestHigh = d.highBuffer[0];
   for(int i = 1; i < RSS_SwingLookback && i < ArraySize(d.highBuffer); i++)
   {
      if(d.highBuffer[i] > highestHigh)
         highestHigh = d.highBuffer[i];
   }
   return highestHigh;
}

bool RSS_CalculateStops(RSISecretSauceOrcData &d, double price, ENUM_POSITION_TYPE type, double &sl, double &tp)
{
   double atrValue = d.atrBuffer[0];
   if(atrValue <= 0)
      atrValue = price * 0.01;

   double slDistance = atrValue * RSS_StopLossATR;
   double tpDistance = atrValue * RSS_TakeProfitATR;

   int digits = (int)SymbolInfoInteger(d.actualSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(d.actualSymbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(d.actualSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = MathMax(stopsLevel * point, point * 10);

   if(RSS_UseSwingStopLoss)
   {
      double swingStop = RSS_GetSwingStopLoss(d, price, type);
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

bool RSS_CanOpenNewPosition(RSISecretSauceOrcData &d)
{
   int positionCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(d.positionInfo.SelectByIndex(i))
      {
         if(d.positionInfo.Symbol() == d.actualSymbol && d.positionInfo.Magic() == RSS_MagicNumber)
            positionCount++;
      }
   }
   if(positionCount >= RSS_MaxPositions)
      return false;

   if(d.lastTradeTime > 0)
   {
      int barsSince = Bars(d.actualSymbol, RSS_Timeframe, d.lastTradeTime, TimeCurrent());
      if(barsSince < RSS_MinBarsBetweenTrades)
         return false;
   }
   return true;
}

void RSS_OpenPosition(RSISecretSauceOrcData &d, ENUM_POSITION_TYPE type, const double lotSize)
{
   double price = (type == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(d.actualSymbol, SYMBOL_ASK) :
                  SymbolInfoDouble(d.actualSymbol, SYMBOL_BID);

   if(price <= 0)
      return;

   double sl = 0.0, tp = 0.0;
   if(!RSS_CalculateStops(d, price, type, sl, tp))
      return;

   string comment = "RSI_Secret_" + (type == POSITION_TYPE_BUY ? "LONG" : "SHORT");

   bool result = false;
   if(type == POSITION_TYPE_BUY)
      result = d.trade.Buy(lotSize, d.actualSymbol, 0, sl, tp, comment);
   else
      result = d.trade.Sell(lotSize, d.actualSymbol, 0, sl, tp, comment);

   if(result)
   {
      d.lastTradeTime = TimeCurrent();
      if(type == POSITION_TYPE_BUY)
         d.rsiWasOverbought = false;
      else
         d.rsiWasOversold = false;
      d.rsiBackInRange = false;
   }
}

void RSS_CheckEntrySignals(RSISecretSauceOrcData &d, const double lotSize)
{
   if(d.rsiWasOverbought && d.rsiBackInRange)
   {
      if(d.rsiBuffer[0] < RSS_RSIOverbought && RSS_IsRSIPeak(d))
         RSS_OpenPosition(d, POSITION_TYPE_BUY, lotSize);
   }

   if(d.rsiWasOversold && d.rsiBackInRange)
   {
      if(d.rsiBuffer[0] > RSS_RSIOversold && RSS_IsRSIBottom(d))
         RSS_OpenPosition(d, POSITION_TYPE_SELL, lotSize);
   }
}

bool InitRSISecretSauce(RSISecretSauceOrcData &d, const string symbol)
{
   d.isInitialized = false;
   d.rsiHandle = INVALID_HANDLE;
   d.atrHandle = INVALID_HANDLE;
   d.rsiWasOverbought = false;
   d.rsiWasOversold = false;
   d.rsiBackInRange = false;
   d.lastRSIExitTime = 0;
   d.lastRSIReentryTime = 0;
   d.lastTradeTime = 0;
   d.lastBarTime = 0;
   d.actualSymbol = symbol;
   StringTrimLeft(d.actualSymbol);
   StringTrimRight(d.actualSymbol);
   if(StringLen(d.actualSymbol) == 0)
      d.actualSymbol = _Symbol;

   if(!SymbolSelect(d.actualSymbol, true))
   {
      Print("RSISecretSauce: symbol not available '", d.actualSymbol, "'");
      return false;
   }

   d.rsiHandle = iRSI(d.actualSymbol, RSS_Timeframe, RSS_RSIPeriod, PRICE_CLOSE);
   d.atrHandle = iATR(d.actualSymbol, RSS_Timeframe, RSS_ATRPeriod);
   if(d.rsiHandle == INVALID_HANDLE || d.atrHandle == INVALID_HANDLE)
      return false;

   ArraySetAsSeries(d.rsiBuffer, true);
   ArraySetAsSeries(d.atrBuffer, true);
   ArraySetAsSeries(d.highBuffer, true);
   ArraySetAsSeries(d.lowBuffer, true);

   d.trade.SetExpertMagicNumber(RSS_MagicNumber);
   d.trade.SetDeviationInPoints(RSS_Slippage);
   d.trade.SetTypeFilling(ORDER_FILLING_FOK);

   d.isInitialized = true;
   return true;
}

void DeinitRSISecretSauce(RSISecretSauceOrcData &d)
{
   if(d.rsiHandle != INVALID_HANDLE)
      IndicatorRelease(d.rsiHandle);
   if(d.atrHandle != INVALID_HANDLE)
      IndicatorRelease(d.atrHandle);
   d.rsiHandle = INVALID_HANDLE;
   d.atrHandle = INVALID_HANDLE;
   d.isInitialized = false;
}

void ProcessRSISecretSauce(RSISecretSauceOrcData &d, const double lotSize)
{
   if(!d.isInitialized)
      return;

   int requiredBars = MathMax(RSS_RSILookback, RSS_SwingLookback) + 10;
   if(Bars(d.actualSymbol, RSS_Timeframe) < requiredBars)
      return;

   datetime currentBarTime = iTime(d.actualSymbol, RSS_Timeframe, 0);
   if(currentBarTime == d.lastBarTime)
      return;

   d.lastBarTime = currentBarTime;

   if(!RSS_UpdateIndicators(d))
      return;

   RSS_UpdateRSIState(d);

   if(RSS_CanOpenNewPosition(d))
      RSS_CheckEntrySignals(d, lotSize);
}

#endif
