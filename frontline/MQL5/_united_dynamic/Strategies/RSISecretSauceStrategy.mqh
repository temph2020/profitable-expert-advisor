//+------------------------------------------------------------------+
//|                                    RSISecretSauceStrategy.mqh   |
//| RSI Secret Sauce: leave 70/30 zone, re-enter, peak/bottom entry |
//+------------------------------------------------------------------+

struct RSISecretSauceData
{
   string symbol;
   bool isInitialized;
   CTrade trade;
   CPositionInfo positionInfo;
   int rsiHandle;
   int atrHandle;
   double rsiBuffer[];
   double atrBuffer[];
   double highBuffer[];
   double lowBuffer[];
   bool rsiWasOverbought;
   bool rsiWasOversold;
   bool rsiBackInRange;
   datetime lastRSIExitTime;
   datetime lastRSIReentryTime;
   datetime lastTradeTime;
   datetime lastBarTime;
   ENUM_TIMEFRAMES timeframe;
   int rsiPeriod;
   double rsiOverbought;
   double rsiOversold;
   int rsiLookback;
   int peakBars;
   bool requireDivergence;
   double stopLossATR;
   double takeProfitATR;
   int atrPeriod;
   bool useSwingStopLoss;
   int swingLookback;
   int maxPositions;
   int minBarsBetweenTrades;
   int magicNumber;
   int slippage;
};

bool RSS_UpdateIndicators(RSISecretSauceData& d);
void RSS_UpdateRSIState(RSISecretSauceData& d);
bool RSS_CanOpenNewPosition(RSISecretSauceData& d);
void RSS_CheckEntrySignals(RSISecretSauceData& d, const double lotSize);
bool RSS_IsRSIPeak(RSISecretSauceData& d);
bool RSS_IsRSIBottom(RSISecretSauceData& d);
void RSS_OpenPosition(RSISecretSauceData& d, ENUM_POSITION_TYPE type, const double lotSize);
bool RSS_CalculateStops(RSISecretSauceData& d, double price, ENUM_POSITION_TYPE type, double& sl, double& tp);
double RSS_GetSwingStopLoss(RSISecretSauceData& d, ENUM_POSITION_TYPE type);

bool InitRSISecretSauce(RSISecretSauceData& d,
                        const string symbol,
                        const ENUM_TIMEFRAMES timeframe,
                        const int rsiPeriod,
                        const double rsiOverbought,
                        const double rsiOversold,
                        const int rsiLookback,
                        const int peakBars,
                        const bool requireDivergence,
                        const double stopLossATR,
                        const double takeProfitATR,
                        const int atrPeriod,
                        const bool useSwingStopLoss,
                        const int swingLookback,
                        const int maxPositions,
                        const int minBarsBetweenTrades,
                        const int magicNumber,
                        const int slippage)
{
   d.symbol = symbol;
   if(StringLen(d.symbol) == 0)
      d.symbol = _Symbol;
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

   if(!SymbolSelect(d.symbol, true))
   {
      Print("RSISecretSauce: Symbol '", d.symbol, "' not available in Market Watch.");
      return false;
   }

   d.timeframe = timeframe;
   d.rsiPeriod = rsiPeriod;
   d.rsiOverbought = rsiOverbought;
   d.rsiOversold = rsiOversold;
   d.rsiLookback = rsiLookback;
   d.peakBars = peakBars;
   d.requireDivergence = requireDivergence;
   d.stopLossATR = stopLossATR;
   d.takeProfitATR = takeProfitATR;
   d.atrPeriod = atrPeriod;
   d.useSwingStopLoss = useSwingStopLoss;
   d.swingLookback = swingLookback;
   d.maxPositions = maxPositions;
   d.minBarsBetweenTrades = minBarsBetweenTrades;
   d.magicNumber = magicNumber;
   d.slippage = slippage;

   Sleep(100);
   int retry = 0;
   while(retry < 5 && d.rsiHandle == INVALID_HANDLE)
   {
      d.rsiHandle = iRSI(d.symbol, d.timeframe, d.rsiPeriod, PRICE_CLOSE);
      if(d.rsiHandle == INVALID_HANDLE)
      {
         if(GetLastError() == 4805 && retry < 4)
         {
            Sleep(1000);
            retry++;
            continue;
         }
         Print("RSISecretSauce: Failed to create RSI for '", d.symbol, "'");
         return false;
      }
   }

   retry = 0;
   while(retry < 5 && d.atrHandle == INVALID_HANDLE)
   {
      d.atrHandle = iATR(d.symbol, d.timeframe, d.atrPeriod);
      if(d.atrHandle == INVALID_HANDLE)
      {
         if(GetLastError() == 4805 && retry < 4)
         {
            Sleep(1000);
            retry++;
            continue;
         }
         Print("RSISecretSauce: Failed to create ATR for '", d.symbol, "'");
         IndicatorRelease(d.rsiHandle);
         d.rsiHandle = INVALID_HANDLE;
         return false;
      }
   }

   ArraySetAsSeries(d.rsiBuffer, true);
   ArraySetAsSeries(d.atrBuffer, true);
   ArraySetAsSeries(d.highBuffer, true);
   ArraySetAsSeries(d.lowBuffer, true);

   d.trade.SetExpertMagicNumber(d.magicNumber);
   d.trade.SetDeviationInPoints(d.slippage);
   d.trade.SetTypeFilling(ORDER_FILLING_FOK);

   d.isInitialized = true;
   Print("RSISecretSauce: Initialized for '", d.symbol, "' TF=", EnumToString(d.timeframe));
   return true;
}

void DeinitRSISecretSauce(RSISecretSauceData& d)
{
   if(d.rsiHandle != INVALID_HANDLE)
      IndicatorRelease(d.rsiHandle);
   if(d.atrHandle != INVALID_HANDLE)
      IndicatorRelease(d.atrHandle);
   d.rsiHandle = INVALID_HANDLE;
   d.atrHandle = INVALID_HANDLE;
   d.isInitialized = false;
}

bool RSS_UpdateIndicators(RSISecretSauceData& d)
{
   int rsiBarsNeeded = d.rsiLookback + 5;
   if(CopyBuffer(d.rsiHandle, 0, 0, rsiBarsNeeded, d.rsiBuffer) < rsiBarsNeeded)
      return false;
   if(CopyBuffer(d.atrHandle, 0, 0, 2, d.atrBuffer) < 2)
      return false;
   if(CopyHigh(d.symbol, d.timeframe, 0, d.swingLookback + 5, d.highBuffer) < d.swingLookback + 5)
      return false;
   if(CopyLow(d.symbol, d.timeframe, 0, d.swingLookback + 5, d.lowBuffer) < d.swingLookback + 5)
      return false;
   return true;
}

void RSS_UpdateRSIState(RSISecretSauceData& d)
{
   double rsiCurrent = d.rsiBuffer[0];
   double rsiPrev = d.rsiBuffer[1];

   if(rsiPrev >= d.rsiOverbought && rsiCurrent < d.rsiOverbought)
   {
      d.rsiWasOverbought = true;
      d.rsiBackInRange = true;
      d.lastRSIExitTime = TimeCurrent();
      d.lastRSIReentryTime = TimeCurrent();
   }

   if(rsiPrev <= d.rsiOversold && rsiCurrent > d.rsiOversold)
   {
      d.rsiWasOversold = true;
      d.rsiBackInRange = true;
      d.lastRSIExitTime = TimeCurrent();
      d.lastRSIReentryTime = TimeCurrent();
   }

   if(rsiCurrent >= d.rsiOverbought)
   {
      d.rsiWasOverbought = false;
      d.rsiBackInRange = false;
   }

   if(rsiCurrent <= d.rsiOversold)
   {
      d.rsiWasOversold = false;
      d.rsiBackInRange = false;
   }
}

bool RSS_CanOpenNewPosition(RSISecretSauceData& d)
{
   int positionCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(d.positionInfo.SelectByIndex(i))
      {
         if(d.positionInfo.Symbol() == d.symbol && d.positionInfo.Magic() == d.magicNumber)
            positionCount++;
      }
   }

   if(positionCount >= d.maxPositions)
      return false;

   if(d.lastTradeTime > 0)
   {
      int barsSince = Bars(d.symbol, d.timeframe, d.lastTradeTime, TimeCurrent());
      if(barsSince < d.minBarsBetweenTrades)
         return false;
   }

   return true;
}

bool RSS_IsRSIPeak(RSISecretSauceData& d)
{
   if(ArraySize(d.rsiBuffer) < d.peakBars + 2)
      return false;

   double currentRSI = d.rsiBuffer[0];
   bool isPeak = true;

   for(int i = 1; i <= d.peakBars; i++)
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

bool RSS_IsRSIBottom(RSISecretSauceData& d)
{
   if(ArraySize(d.rsiBuffer) < d.peakBars + 2)
      return false;

   double currentRSI = d.rsiBuffer[0];
   bool isBottom = true;

   for(int i = 1; i <= d.peakBars; i++)
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

void RSS_CheckEntrySignals(RSISecretSauceData& d, const double lotSize)
{
   if(d.rsiWasOverbought && d.rsiBackInRange)
   {
      if(d.rsiBuffer[0] < d.rsiOverbought)
      {
         if(RSS_IsRSIPeak(d))
            RSS_OpenPosition(d, POSITION_TYPE_BUY, lotSize);
      }
   }

   if(d.rsiWasOversold && d.rsiBackInRange)
   {
      if(d.rsiBuffer[0] > d.rsiOversold)
      {
         if(RSS_IsRSIBottom(d))
            RSS_OpenPosition(d, POSITION_TYPE_SELL, lotSize);
      }
   }
}

bool RSS_CalculateStops(RSISecretSauceData& d, double price, ENUM_POSITION_TYPE type, double& sl, double& tp)
{
   double atrValue = d.atrBuffer[0];
   if(atrValue <= 0)
      atrValue = price * 0.01;

   double slDistance = atrValue * d.stopLossATR;
   double tpDistance = atrValue * d.takeProfitATR;

   int digits = (int)SymbolInfoInteger(d.symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(d.symbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(d.symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = MathMax(stopsLevel * point, point * 10);

   if(d.useSwingStopLoss)
   {
      double swingStop = RSS_GetSwingStopLoss(d, type);
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

double RSS_GetSwingStopLoss(RSISecretSauceData& d, ENUM_POSITION_TYPE type)
{
   if(type == POSITION_TYPE_BUY)
   {
      double lowestLow = d.lowBuffer[0];
      for(int i = 1; i < d.swingLookback && i < ArraySize(d.lowBuffer); i++)
      {
         if(d.lowBuffer[i] < lowestLow)
            lowestLow = d.lowBuffer[i];
      }
      return lowestLow;
   }

   double highestHigh = d.highBuffer[0];
   for(int i = 1; i < d.swingLookback && i < ArraySize(d.highBuffer); i++)
   {
      if(d.highBuffer[i] > highestHigh)
         highestHigh = d.highBuffer[i];
   }
   return highestHigh;
}

void RSS_OpenPosition(RSISecretSauceData& d, ENUM_POSITION_TYPE type, const double lotSize)
{
   double price = (type == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(d.symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(d.symbol, SYMBOL_BID);

   if(price <= 0)
      return;

   double sl = 0.0, tp = 0.0;
   if(!RSS_CalculateStops(d, price, type, sl, tp))
      return;

   string comment = "RSI_Secret_" + (type == POSITION_TYPE_BUY ? "LONG" : "SHORT");

   bool result = false;
   if(type == POSITION_TYPE_BUY)
      result = d.trade.Buy(lotSize, d.symbol, 0, sl, tp, comment);
   else
      result = d.trade.Sell(lotSize, d.symbol, 0, sl, tp, comment);

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

void ProcessRSISecretSauce(RSISecretSauceData& d, const double lotSize)
{
   if(!d.isInitialized)
      return;

   int requiredBars = MathMax(d.rsiLookback, d.swingLookback) + 10;
   if(Bars(d.symbol, d.timeframe) < requiredBars)
      return;

   datetime currentBarTime = iTime(d.symbol, d.timeframe, 0);
   if(currentBarTime == d.lastBarTime)
      return;

   d.lastBarTime = currentBarTime;

   if(!RSS_UpdateIndicators(d))
      return;

   RSS_UpdateRSIState(d);

   if(RSS_CanOpenNewPosition(d))
      RSS_CheckEntrySignals(d, lotSize);
}
