//+------------------------------------------------------------------+
//|                                  RSICrossOverReversalStrategy.mqh |
//+------------------------------------------------------------------+

void WeekDays_Init()
{
   rcData.WeekDays[0] = RC_Sunday;
   rcData.WeekDays[1] = RC_Monday;
   rcData.WeekDays[2] = RC_Tuesday;
   rcData.WeekDays[3] = RC_Wednesday;
   rcData.WeekDays[4] = RC_Thursday;
   rcData.WeekDays[5] = RC_Friday;
   rcData.WeekDays[6] = RC_Saturday;
}

bool WeekDays_Check(datetime aTime)
{
   MqlDateTime stm;
   TimeToStruct(aTime, stm);
   return(rcData.WeekDays[stm.day_of_week]);
}

bool RC_HourInWindow(const int h, const int beginRaw, const int endRaw)
{
   const int b = beginRaw % 24;
   const int e = endRaw % 24;
   if(b == e)
      return false;
   if(b < e)
      return (h >= b && h < e);
   return (h >= b || h < e);
}

bool RC_TradingHoursAllow(const int currentHour)
{
   return RC_HourInWindow(currentHour, RC_tradingHourOneBegin, RC_tradingHourOneEnd)
       || RC_HourInWindow(currentHour, RC_tradingHourTwoBegin, RC_tradingHourTwoEnd);
}

int TimeHour(datetime when = 0)
{
   if(when == 0) when = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(when, dt);
   return dt.hour;
}

double RC_NormalizeLot(const string sym, const double lots)
{
   const double mn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double mx = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   double v = MathMax(lots, mn);
   v = MathMin(v, mx);
   return NormalizeDouble(MathFloor(v / step + 0.5) * step, 2);
}

// Threshold <= 0 disables that leg (optimizer must not treat 0 as "always strong").
bool RC_IsTrendStrong(const double emaSlope, const double priceToEmaDistance)
{
   if(!RC_UseTrendStrengthFilter)
      return false;
   const bool slopeStrong = (RC_emaSlopeThreshold > 0.0)
      && (MathAbs(emaSlope) > RC_emaSlopeThreshold);
   const bool distanceStrong = (RC_emaDistanceThreshold > 0.0)
      && (MathAbs(priceToEmaDistance) > RC_emaDistanceThreshold);
   return slopeStrong || distanceStrong;
}

bool InitRSICrossOverReversal(string symbol)
{
   WeekDays_Init();
   
   rcData.symbol = symbol;
   rcData.previousRSIDef = 0;
   rcData.lastTradeTime = 0;
   rcData.bartime = 0;
   rcData.lastBarTime = 0;
   
   // Check if symbol exists
   if(!SymbolSelect(symbol, true))
   {
      Print("RSICrossOverReversal: Symbol '", symbol, "' not available in Market Watch. Please add it to Market Watch or check symbol name.");
      return false;
   }
   
   Sleep(100); // Wait for symbol to be ready
   
   rcData.rsiHandle = iRSI(symbol, RC_TimeFrame1, RC_rsiPeriod, PRICE_CLOSE);
   if(rcData.rsiHandle == INVALID_HANDLE)
   {
      Print("RSICrossOverReversal: Error creating RSI handle for '", symbol, "'");
      return false;
   }
   
   rcData.emaHandle = iMA(symbol, RC_TimeFrame2, RC_emaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(rcData.emaHandle == INVALID_HANDLE)
   {
      Print("RSICrossOverReversal: Error creating EMA handle for '", symbol, "'");
      return false;
   }
   
   rcData.trade.SetExpertMagicNumber(RC_MagicNumber);
   rcData.trade.SetDeviationInPoints(RC_slippage);
   rcData.trade.SetTypeFillingBySymbol(symbol);
   rcData.isInitialized = true;
   Print("RSICrossOverReversal: Successfully initialized for symbol '", symbol, "'");
   return true;
}

void DeinitRSICrossOverReversal()
{
   if(rcData.rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rcData.rsiHandle);
   if(rcData.emaHandle != INVALID_HANDLE)
      IndicatorRelease(rcData.emaHandle);
}

void Close_Position_MN(ulong magicNumber)
{
   ClosePositionByMagic(rcData.trade, rcData.symbol, (int)magicNumber);
}

void ApplyTrailingStop()
{
   if(!PositionSelectByMagic(rcData.symbol, RC_MagicNumber))
      return;
   
   ulong PositionTicket = PositionGetInteger(POSITION_TICKET);
   ENUM_POSITION_TYPE trade_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   string symbol = rcData.symbol;
   
   double POINT = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int DIGIT = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(trade_type == POSITION_TYPE_BUY)
   {
      double Bid = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_BID), DIGIT);
      
      if(Bid - PositionGetDouble(POSITION_PRICE_OPEN) > NormalizeDouble(POINT * RC_TrailingStop, DIGIT))
      {
         if(PositionGetDouble(POSITION_SL) < NormalizeDouble(Bid - POINT * RC_TrailingStop, DIGIT))
         {
            ModifyPositionByMagic(rcData.trade, symbol, RC_MagicNumber,
                                 NormalizeDouble(Bid - POINT * RC_TrailingStop, DIGIT),
                                 PositionGetDouble(POSITION_TP));
         }
      }
   }
   else if(trade_type == POSITION_TYPE_SELL)
   {
      double Ask = NormalizeDouble(SymbolInfoDouble(symbol, SYMBOL_ASK), DIGIT);
      
      if((PositionGetDouble(POSITION_PRICE_OPEN) - Ask) > NormalizeDouble(POINT * RC_TrailingStop, DIGIT))
      {
         if((PositionGetDouble(POSITION_SL) > NormalizeDouble(Ask + POINT * RC_TrailingStop, DIGIT)) ||
            (PositionGetDouble(POSITION_SL) == 0))
         {
            ModifyPositionByMagic(rcData.trade, symbol, RC_MagicNumber,
                                NormalizeDouble(Ask + POINT * RC_TrailingStop, DIGIT),
                                PositionGetDouble(POSITION_TP));
         }
      }
   }
}

void ProcessRSICrossOverReversal(string symbol)
{
   // Skip if not initialized (symbol not available)
   if(!rcData.isInitialized)
      return;
      
   rcData.symbol = symbol; // Update symbol in case it changed
   const datetime barTime = iTime(rcData.symbol, RC_BarTimeFrame, 0);
   if(barTime == 0)
      return;
   if(rcData.bartime == barTime)
      return;
   rcData.bartime = barTime;
   
   double rsi[];
   if(CopyBuffer(rcData.rsiHandle, 0, 0, 2, rsi) <= 0)
      return;
   
   double ema[];
   if(CopyBuffer(rcData.emaHandle, 0, 0, 2, ema) <= 0)
      return;
   
   datetime currentTime = TimeCurrent();
   int currentHour = TimeHour(TimeCurrent());
   
   if(!WeekDays_Check(TimeTradeServer()))
   {
      Close_Position_MN(RC_MagicNumber);
      return;
   }
   
   if(!RC_TradingHoursAllow(currentHour))
   {
      Close_Position_MN(RC_MagicNumber);
      return;
   }
   
   bool hasPosition = PositionExistsByMagic(rcData.symbol, RC_MagicNumber);
   
   double currentRSI = rsi[0];
   double previousRSI = rsi[1];
   
   if(rcData.previousRSIDef == 0)
   {
      rcData.previousRSIDef = currentRSI;
      return;
   }
   
   double currentEMA = ema[0];
   double previousEMA = ema[1];
   
   double emaSlope = (currentEMA - previousEMA) * 100;
   const double closeCurr = iClose(rcData.symbol, RC_TimeFrame1, 0);
   double priceToEmaDistance = (closeCurr - currentEMA) * 10;
   
   bool isBuyPosition = false;
   bool isSellPosition = false;
   if(hasPosition)
   {
      if(PositionSelectByMagic(rcData.symbol, RC_MagicNumber))
      {
         ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(positionType == POSITION_TYPE_BUY)
            isBuyPosition = true;
         else if(positionType == POSITION_TYPE_SELL)
            isSellPosition = true;
      }
   }
   
   ApplyTrailingStop();
   
   bool cooldownPassed = (currentTime - rcData.lastTradeTime) >= RC_cooldownSeconds;
   const bool isTrendStrong = RC_IsTrendStrong(emaSlope, priceToEmaDistance);
   
   if(isBuyPosition && currentRSI > RC_exitBuyRSI)
   {
      Close_Position_MN(RC_MagicNumber);
      rcData.lastTradeTime = currentTime;
   }
   
   if(isSellPosition && currentRSI < RC_exitSellRSI)
   {
      Close_Position_MN(RC_MagicNumber);
      rcData.lastTradeTime = currentTime;
   }
   
   if(isTrendStrong)
   {
      Close_Position_MN(RC_MagicNumber);
      rcData.lastTradeTime = currentTime;
   }

   hasPosition = PositionExistsByMagic(rcData.symbol, RC_MagicNumber);
   isBuyPosition = false;
   isSellPosition = false;
   if(hasPosition && PositionSelectByMagic(rcData.symbol, RC_MagicNumber))
   {
      const ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(positionType == POSITION_TYPE_BUY)
         isBuyPosition = true;
      else if(positionType == POSITION_TYPE_SELL)
         isSellPosition = true;
   }

   const double lots = RC_NormalizeLot(rcData.symbol, g_RC_LotSize);
   if(lots > 0.0 && !isTrendStrong && cooldownPassed
      && United_PrepareEntrySlot(rcData.trade, rcData.symbol, RC_MagicNumber, RC_CloseUnprofitableOnNewSignal))
   {
      if(currentRSI < RC_overboughtLevel - RC_entryRSISellSpread
         && rcData.previousRSIDef >= RC_overboughtLevel
         && !isSellPosition)
      {
         rcData.trade.SetExpertMagicNumber(RC_MagicNumber);
         if(rcData.trade.Sell(lots, rcData.symbol, 0.0, 0.0, 0.0, "Sell Order"))
            rcData.lastTradeTime = currentTime;
      }
      else if(currentRSI > RC_oversoldLevel + RC_entryRSIBuySpread
         && rcData.previousRSIDef <= RC_oversoldLevel
         && !isBuyPosition)
      {
         rcData.trade.SetExpertMagicNumber(RC_MagicNumber);
         if(rcData.trade.Buy(lots, rcData.symbol, 0.0, 0.0, 0.0, "Buy Order"))
            rcData.lastTradeTime = currentTime;
      }
   }
   
   rcData.previousRSIDef = currentRSI;
}

//+------------------------------------------------------------------+
