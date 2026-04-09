//+------------------------------------------------------------------+
//|                                      RSIReversalAsianStrategy.mqh |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| RSI Reversal Asian Strategy Data Structure                       |
//+------------------------------------------------------------------+
struct RSIReversalAsianData {
   string symbol;
   bool isInitialized;
   int rsiHandle;
   CTrade trade;
   bool isPositionOpen;
   double positionOpenPrice;
   datetime positionOpenTime;
   ENUM_POSITION_TYPE lastPositionType;
   bool sessionCloseAttempted;
   
   // RSI crossover variables
   double rsiCurrent;
   double rsiPrevious;
   double rsiPrevious2;
   bool rsiCrossedOverbought;
   bool rsiCrossedOversold;
   bool rsiCrossedExitLevel;
   
   // Strategy parameters
   int RSIPeriod;
   double OverboughtLevel;
   double OversoldLevel;
   int TakeProfitPips;
   int StopLossPips;
   double MaxLotSize;
   int MaxSpread;
   int MaxDuration;
   bool UseStopLoss;
   bool UseTakeProfit;
   bool UseRSIExit;
   double RSIExitLevel;
   bool CloseOutsideSession;
   ENUM_TIMEFRAMES TimeFrame;
   int MagicNumber;
   int Slippage;
   double point;
};

// Session times (UTC)
const int AsianSessionStart = 0;    // 00:00 UTC
const int AsianSessionEnd = 8;      // 08:00 UTC

//+------------------------------------------------------------------+
//| Check if current time is in Asian session                        |
//+------------------------------------------------------------------+
bool IsAsianSession()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(currentTime, timeStruct);
   
   return (timeStruct.hour >= AsianSessionStart && timeStruct.hour < AsianSessionEnd);
}

//+------------------------------------------------------------------+
//| Check if trading is allowed for symbol                            |
//+------------------------------------------------------------------+
bool IsTradingAllowed(RSIReversalAsianData& data)
{
   // Check if market is open
   long tradeMode = SymbolInfoInteger(data.symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL)
   {
      return false;
   }
   
   // Check if we have enough money
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) <= 0)
   {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check RSI crossover conditions                                    |
//+------------------------------------------------------------------+
void CheckRSICrossover(RSIReversalAsianData& data)
{
   // Reset crossover flags
   data.rsiCrossedOverbought = false;
   data.rsiCrossedOversold = false;
   data.rsiCrossedExitLevel = false;
   
   // Check for overbought crossover (RSI crosses above overbought level)
   if(data.rsiPrevious < data.OverboughtLevel && data.rsiCurrent >= data.OverboughtLevel)
   {
      data.rsiCrossedOverbought = true;
   }
   
   // Check for oversold crossover (RSI crosses below oversold level)
   if(data.rsiPrevious > data.OversoldLevel && data.rsiCurrent <= data.OversoldLevel)
   {
      data.rsiCrossedOversold = true;
   }
   
   // Check for exit level crossover
   if(data.rsiPrevious < data.RSIExitLevel && data.rsiCurrent >= data.RSIExitLevel)
   {
      data.rsiCrossedExitLevel = true;
   }
   else if(data.rsiPrevious > data.RSIExitLevel && data.rsiCurrent <= data.RSIExitLevel)
   {
      data.rsiCrossedExitLevel = true;
   }
}

//+------------------------------------------------------------------+
//| Close all trades for the symbol                                    |
//+------------------------------------------------------------------+
bool CloseAllTrades(RSIReversalAsianData& data, string reason = "")
{
   bool allClosed = true;
   int totalPositions = PositionsTotal();
   
   if(totalPositions == 0)
      return true;
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == data.symbol)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == (ulong)data.MagicNumber)
            {
               // Try to close position with retry logic
               int retryCount = 0;
               bool positionClosed = false;
               
               while(retryCount < 3 && !positionClosed)
               {
                  if(data.trade.PositionClose(ticket))
                  {
                     data.isPositionOpen = false;
                     positionClosed = true;
                  }
                  else
                  {
                     int error = GetLastError();
                     
                     // If error is 4756 (Trade disabled), wait longer before retry
                     if(error == 4756)
                     {
                        Sleep(5000); // Wait 5 seconds before retry
                        retryCount++;
                     }
                     else
                     {
                        // For other errors, break the loop
                        break;
                     }
                  }
               }
               
               if(!positionClosed)
               {
                  allClosed = false;
               }
            }
         }
      }
   }
   
   return allClosed;
}

//+------------------------------------------------------------------+
//| Initialize RSI Reversal Asian Strategy                            |
//+------------------------------------------------------------------+
bool InitRSIReversalAsian(RSIReversalAsianData& data, string symbol, 
                         int RSIPeriod, double OverboughtLevel, double OversoldLevel,
                         int TakeProfitPips, int StopLossPips, double MaxLotSize,
                         int MaxSpread, int MaxDuration, bool UseStopLoss,
                         bool UseTakeProfit, bool UseRSIExit, double RSIExitLevel,
                         bool CloseOutsideSession, ENUM_TIMEFRAMES TimeFrame,
                         int MagicNumber, int Slippage)
{
   data.symbol = symbol;
   data.isInitialized = false;
   
   // Check if symbol exists
   if(!SymbolSelect(symbol, true))
   {
      Print("RSIReversalAsian: Symbol '", symbol, "' not available in Market Watch. Please add it to Market Watch or check symbol name.");
      return false;
   }
   
   // Wait a bit for symbol to be ready
   Sleep(100);
   
   // Get symbol point
   data.point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   // Store parameters
   data.RSIPeriod = RSIPeriod;
   data.OverboughtLevel = OverboughtLevel;
   data.OversoldLevel = OversoldLevel;
   data.TakeProfitPips = TakeProfitPips;
   data.StopLossPips = StopLossPips;
   data.MaxLotSize = MaxLotSize;
   data.MaxSpread = MaxSpread;
   data.MaxDuration = MaxDuration;
   data.UseStopLoss = UseStopLoss;
   data.UseTakeProfit = UseTakeProfit;
   data.UseRSIExit = UseRSIExit;
   data.RSIExitLevel = RSIExitLevel;
   data.CloseOutsideSession = CloseOutsideSession;
   data.TimeFrame = TimeFrame;
   data.MagicNumber = MagicNumber;
   data.Slippage = Slippage;
   
   // Initialize RSI indicator with retry logic (for insufficient history in backtesting)
   data.rsiHandle = INVALID_HANDLE;
   int retryCount = 0;
   int maxRetries = 5;
   
   while(retryCount < maxRetries && data.rsiHandle == INVALID_HANDLE)
   {
      data.rsiHandle = iRSI(symbol, TimeFrame, RSIPeriod, PRICE_CLOSE);
      
      if(data.rsiHandle == INVALID_HANDLE)
      {
         int error = GetLastError();
         
         // Error 4805 = insufficient history - wait longer and retry
         if(error == 4805 && retryCount < maxRetries - 1)
         {
            Sleep(1000); // Wait 1 second for history to load
            retryCount++;
            continue;
         }
         
         Print("RSIReversalAsian: Error creating RSI indicator for '", symbol, "' - Error: ", error, " (", error == 4805 ? "Insufficient history data" : "Unknown", ")");
         return false;
      }
   }
   
   if(data.rsiHandle == INVALID_HANDLE)
   {
      Print("RSIReversalAsian: Failed to create RSI indicator for '", symbol, "' after ", maxRetries, " retries");
      return false;
   }
   
   // Wait a bit for the indicator to be ready
   Sleep(100);
   
   // Initialize RSI values with retry logic
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   retryCount = 0;
   bool rsiInitialized = false;
   
   while(retryCount < 10 && !rsiInitialized)
   {
      int copied = CopyBuffer(data.rsiHandle, 0, 0, 3, rsi);
      if(copied >= 3)
      {
         data.rsiCurrent = rsi[0];
         data.rsiPrevious = rsi[1];
         data.rsiPrevious2 = rsi[2];
         rsiInitialized = true;
      }
      else
      {
         retryCount++;
         Sleep(100);
      }
   }
   
   if(!rsiInitialized)
   {
      // Don't fail initialization, just set default values
      data.rsiCurrent = 50.0;
      data.rsiPrevious = 50.0;
      data.rsiPrevious2 = 50.0;
   }
   
   // Set trade parameters
   data.trade.SetExpertMagicNumber(MagicNumber);
   data.trade.SetDeviationInPoints(Slippage);
   data.trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Initialize state
   data.isPositionOpen = false;
   data.positionOpenPrice = 0;
   data.positionOpenTime = 0;
   data.lastPositionType = POSITION_TYPE_BUY;
   data.sessionCloseAttempted = false;
   data.rsiCrossedOverbought = false;
   data.rsiCrossedOversold = false;
   data.rsiCrossedExitLevel = false;
   
   data.isInitialized = true;
   
   Print("RSIReversalAsian: Successfully initialized for symbol '", symbol, "'");
   return true;
}

//+------------------------------------------------------------------+
//| Deinitialize RSI Reversal Asian Strategy                         |
//+------------------------------------------------------------------+
void DeinitRSIReversalAsian(RSIReversalAsianData& data)
{
   if(data.rsiHandle != INVALID_HANDLE)
      IndicatorRelease(data.rsiHandle);
}

//+------------------------------------------------------------------+
//| Process RSI Reversal Asian Strategy                               |
//+------------------------------------------------------------------+
void ProcessRSIReversalAsian(RSIReversalAsianData& data, double lotSize)
{
   if(!data.isInitialized)
      return;
   
   // Check if trading is allowed
   if(!IsTradingAllowed(data))
   {
      return;
   }
   
   // Check if we're in Asian session
   if(!IsAsianSession())
   {
      // Close all positions if outside Asian session and CloseOutsideSession is true
      if(data.CloseOutsideSession && !data.sessionCloseAttempted)
      {
         CloseAllTrades(data, "Outside Asian session");
         data.sessionCloseAttempted = true;
      }
      return;
   }
   else
   {
      // Reset the session close attempt flag when we enter Asian session
      data.sessionCloseAttempted = false;
   }
   
   // Get current spread
   double spread = SymbolInfoDouble(data.symbol, SYMBOL_ASK) - SymbolInfoDouble(data.symbol, SYMBOL_BID);
   int spreadInPips = (int)(spread / data.point);
   
   // Check if spread is too high
   if(spreadInPips > data.MaxSpread)
   {
      return;
   }
   
   // Get RSI values from bar data
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   int copied = CopyBuffer(data.rsiHandle, 0, 0, 3, rsi);
   if(copied < 3)
   {
      return;
   }
   
   // Update RSI values
   data.rsiPrevious2 = data.rsiPrevious;
   data.rsiPrevious = data.rsiCurrent;
   data.rsiCurrent = rsi[0];
   
   // Validate RSI values
   if(data.rsiCurrent == 0 || data.rsiPrevious == 0)
   {
      return;
   }
   
   // Check for RSI crossovers
   CheckRSICrossover(data);
   
   // Get current prices
   double currentBid = SymbolInfoDouble(data.symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(data.symbol, SYMBOL_ASK);
   
   // Check for open position
   bool hasOpenPosition = PositionExistsByMagic(data.symbol, (ulong)data.MagicNumber);
   
   if(hasOpenPosition)
   {
      // Get position details
      ulong ticket = GetPositionTicketByMagic(data.symbol, (ulong)data.MagicNumber);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         
         // Check for RSI exit if enabled
         if(data.UseRSIExit && data.rsiCrossedExitLevel)
         {
            bool shouldExit = false;
            
            // For long positions, exit when RSI crosses above exit level
            if(posType == POSITION_TYPE_BUY && data.rsiCurrent >= data.RSIExitLevel && data.rsiPrevious < data.RSIExitLevel)
            {
               shouldExit = true;
            }
            // For short positions, exit when RSI crosses below exit level
            else if(posType == POSITION_TYPE_SELL && data.rsiCurrent <= data.RSIExitLevel && data.rsiPrevious > data.RSIExitLevel)
            {
               shouldExit = true;
            }
            
            if(shouldExit)
            {
               CloseAllTrades(data, "RSI Exit Crossover");
               return;
            }
         }
         
         // Check for timeout
         if(TimeCurrent() - openTime > data.MaxDuration * 3600)
         {
            CloseAllTrades(data, "Timeout");
            return;
         }
      }
   }
   
   // If no position is open, look for entry signals based on RSI crossover
   if(!hasOpenPosition)
   {
      // Place buy order if RSI crosses below oversold level (oversold crossover)
      if(data.rsiCrossedOversold)
      {
         double sl = data.UseStopLoss ? currentBid - data.StopLossPips * data.point : 0;
         double tp = data.UseTakeProfit ? currentBid + data.TakeProfitPips * data.point : 0;
         
         if(data.UseStopLoss && sl >= currentBid)
            return;
         if(data.UseTakeProfit && tp <= currentBid)
            return;
         
         // Set trade parameters
         data.trade.SetDeviationInPoints(data.Slippage);
         data.trade.SetTypeFilling(ORDER_FILLING_IOC);
         data.trade.SetExpertMagicNumber(data.MagicNumber);
         
         // Use dynamic lot size
         double tradeLotSize = lotSize > 0 ? lotSize : data.MaxLotSize;
         
         // Place buy order using CTrade
         if(data.trade.Buy(tradeLotSize, data.symbol, currentAsk, sl, tp, "RSI Oversold Crossover Buy"))
         {
            data.isPositionOpen = true;
            data.positionOpenPrice = currentAsk;
            data.positionOpenTime = TimeCurrent();
            data.lastPositionType = POSITION_TYPE_BUY;
         }
      }
      // Place sell order if RSI crosses above overbought level (overbought crossover)
      else if(data.rsiCrossedOverbought)
      {
         double sl = data.UseStopLoss ? currentAsk + data.StopLossPips * data.point : 0;
         double tp = data.UseTakeProfit ? currentAsk - data.TakeProfitPips * data.point : 0;
         
         if(data.UseStopLoss && sl <= currentAsk)
            return;
         if(data.UseTakeProfit && tp >= currentAsk)
            return;
         
         // Set trade parameters
         data.trade.SetDeviationInPoints(data.Slippage);
         data.trade.SetTypeFilling(ORDER_FILLING_IOC);
         data.trade.SetExpertMagicNumber(data.MagicNumber);
         
         // Use dynamic lot size
         double tradeLotSize = lotSize > 0 ? lotSize : data.MaxLotSize;
         
         // Place sell order using CTrade
         if(data.trade.Sell(tradeLotSize, data.symbol, currentBid, sl, tp, "RSI Overbought Crossover Sell"))
         {
            data.isPositionOpen = true;
            data.positionOpenPrice = currentBid;
            data.positionOpenTime = TimeCurrent();
            data.lastPositionType = POSITION_TYPE_SELL;
         }
      }
   }
}
