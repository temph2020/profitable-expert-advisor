//+------------------------------------------------------------------+
//|                                      RSIMidPointHijackStrategy.mqh |
//+------------------------------------------------------------------+

double RM_NormalizedLot(const string sym)
{
   return United_NormalizeVolume(sym, g_RM_LotSize);
}

bool IsNewBar(string symbol)
{
   datetime time[];
   if(CopyTime(symbol, RM_InpTimeframe, 0, 1, time) > 0)
   {
      if(time[0] != rmData.lastBarTime)
      {
         rmData.lastBarTime = time[0];
         return true;
      }
   }
   return false;
}

bool IsWithinTradingHours(int startHour, int endHour)
{
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   if(startHour <= endHour)
      return (currentTime.hour >= startHour && currentTime.hour < endHour);
   else
      return (currentTime.hour >= startHour || currentTime.hour < endHour);
}

bool HasPosition(string symbol, int magic)
{
   return PositionExistsByMagic(symbol, magic);
}

bool HasProfitablePosition(int excludeMagic)
{
   bool hasProfitable = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(rmData.positionInfo.SelectByIndex(i))
      {
         if(rmData.positionInfo.Magic() != excludeMagic)
         {
            double profit = rmData.positionInfo.Profit();
            if(profit > RM_InpLockProfitThreshold * _Point)
            {
               hasProfitable = true;
               if(RM_InpCloseOppositeTrades)
               {
                  if((excludeMagic == RM_InpMagicNumberRSIFollow && rmData.positionInfo.Magic() == RM_InpMagicNumberRSIReverse) ||
                     (excludeMagic == RM_InpMagicNumberRSIReverse && rmData.positionInfo.Magic() == RM_InpMagicNumberRSIFollow) ||
                     (excludeMagic == RM_InpMagicNumberEMACross && (rmData.positionInfo.Magic() == RM_InpMagicNumberRSIReverse || rmData.positionInfo.Magic() == RM_InpMagicNumberRSIFollow)) ||
                     ((excludeMagic == RM_InpMagicNumberRSIFollow || excludeMagic == RM_InpMagicNumberRSIReverse) && rmData.positionInfo.Magic() == RM_InpMagicNumberEMACross))
                  {
                     ClosePosition(rmData.symbol, (int)rmData.positionInfo.Magic());
                  }
               }
            }
         }
      }
   }
   return hasProfitable;
}

bool IsRSIReverseInCooldown(string symbol)
{
   if(RM_InpRSIReverseCooldownBars <= 0)
      return false;
      
   if(!rmData.rsiReverseInCooldown)
      return false;
      
   datetime time[];
   if(CopyTime(symbol, RM_InpTimeframe, 0, 1, time) > 0)
   {
      datetime currentBarTime = time[0];
      datetime cooldownEndTime = rmData.rsiReverseLastCloseTime + RM_InpRSIReverseCooldownBars * PeriodSeconds(RM_InpTimeframe);
      
      if(currentBarTime >= cooldownEndTime)
      {
         rmData.rsiReverseInCooldown = false;
         return false;
      }
   }
   
   return true;
}

void CheckRSIFollowStrategy(string symbol)
{
   if(!IsWithinTradingHours(RM_InpRSIFollowStartHour, RM_InpRSIFollowEndHour))
   {
      if(RM_InpRSIFollowCloseOutsideHours)
      {
         if(HasPosition(symbol, RM_InpMagicNumberRSIFollow))
            ClosePosition(symbol, RM_InpMagicNumberRSIFollow);
      }
      return;
   }
   
   if(RM_InpEnableStrategyLock && HasProfitablePosition(RM_InpMagicNumberRSIFollow))
      return;
   
   if(rmData.lastBarRSI > RM_InpRSIOverbought)
      rmData.rsiOverbought = true;
   else if(rmData.lastBarRSI < RM_InpRSIOversold)
      rmData.rsiOversold = true;
   
   if(rmData.rsiOverbought && rmData.lastBarRSI < RM_InpRSIExitLevel)
   {
      if(!HasPosition(symbol, RM_InpMagicNumberRSIFollow))
      {
         rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberRSIFollow);
         const double vol = RM_NormalizedLot(symbol);
         if(vol > 0.0)
            rmData.trade.Sell(vol, symbol, 0, 0, 0, "RSI Follow");
      }
      rmData.rsiOverbought = false;
   }
   else if(rmData.rsiOversold && rmData.lastBarRSI > RM_InpRSIExitLevel)
   {
      if(!HasPosition(symbol, RM_InpMagicNumberRSIFollow))
      {
         rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberRSIFollow);
         const double vol = RM_NormalizedLot(symbol);
         if(vol > 0.0)
            rmData.trade.Buy(vol, symbol, 0, 0, 0, "RSI Follow");
      }
      rmData.rsiOversold = false;
   }
}

void CheckRSIReverseStrategy(string symbol)
{
   if(!IsWithinTradingHours(RM_InpRSIReverseStartHour, RM_InpRSIReverseEndHour))
   {
      if(RM_InpRSIReverseCloseOutsideHours)
      {
         if(HasPosition(symbol, RM_InpMagicNumberRSIReverse))
            ClosePosition(symbol, RM_InpMagicNumberRSIReverse);
      }
      return;
   }
   
   if(RM_InpEnableStrategyLock && HasProfitablePosition(RM_InpMagicNumberRSIReverse))
      return;
      
   if(IsRSIReverseInCooldown(symbol))
      return;
   
   if(rmData.lastBarRSIReverse > RM_InpRSIReverseOverbought)
      rmData.rsiReverseOverbought = true;
   else if(rmData.lastBarRSIReverse < RM_InpRSIReverseOversold)
      rmData.rsiReverseOversold = true;
   
   if(rmData.rsiReverseOverbought && rmData.lastBarRSIReverse < RM_InpRSIReverseCrossLevel)
   {
      if(!HasPosition(symbol, RM_InpMagicNumberRSIReverse))
      {
         rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberRSIReverse);
         const double vol = RM_NormalizedLot(symbol);
         if(vol > 0.0)
            rmData.trade.Sell(vol, symbol, 0, 0, 0, "RSI Reverse");
      }
      rmData.rsiReverseOverbought = false;
   }
   else if(rmData.rsiReverseOversold && rmData.lastBarRSIReverse > RM_InpRSIReverseCrossLevel)
   {
      if(!HasPosition(symbol, RM_InpMagicNumberRSIReverse))
      {
         rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberRSIReverse);
         const double vol = RM_NormalizedLot(symbol);
         if(vol > 0.0)
            rmData.trade.Buy(vol, symbol, 0, 0, 0, "RSI Reverse");
      }
      rmData.rsiReverseOversold = false;
   }
}

void CheckEMACrossStrategy(string symbol)
{
   if(!IsWithinTradingHours(RM_InpEMACrossStartHour, RM_InpEMACrossEndHour))
   {
      if(RM_InpEMACrossCloseOutsideHours)
      {
         if(HasPosition(symbol, RM_InpMagicNumberEMACross))
            ClosePosition(symbol, RM_InpMagicNumberEMACross);
      }
      return;
   }
   
   if(RM_InpEnableStrategyLock && HasProfitablePosition(RM_InpMagicNumberEMACross))
      return;
   
   if(rmData.lastBarEMAPrev < rmData.lastBarClosePrev && rmData.lastBarEMA > rmData.lastBarClose)
   {
      rmData.emaCrossBuySignal = true;
      rmData.emaCrossSellSignal = false;
      rmData.emaCrossSignalBar = 0;
   }
   else if(rmData.lastBarEMAPrev > rmData.lastBarClosePrev && rmData.lastBarEMA < rmData.lastBarClose)
   {
      rmData.emaCrossSellSignal = true;
      rmData.emaCrossBuySignal = false;
      rmData.emaCrossSignalBar = 0;
   }
   
   if(RM_InpUseEMADistanceEntry)
   {
      if(rmData.emaCrossBuySignal)
      {
         bool distanceConditionMet = true;
         double emaHistory[], closeHistory[];
         ArraySetAsSeries(emaHistory, true);
         ArraySetAsSeries(closeHistory, true);
         
         if(CopyBuffer(rmData.emaHandle, 0, 0, RM_InpEMADistancePeriod, emaHistory) > 0 &&
            CopyClose(symbol, RM_InpTimeframe, 0, RM_InpEMADistancePeriod, closeHistory) > 0)
         {
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            for(int i = 0; i < RM_InpEMADistancePeriod; i++)
            {
               double distance = (closeHistory[i] - emaHistory[i]) / point;
               if(distance < RM_InpEMADistancePips)
               {
                  distanceConditionMet = false;
                  break;
               }
            }
            
            if(distanceConditionMet && !HasPosition(symbol, RM_InpMagicNumberEMACross))
            {
               rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberEMACross);
               const double vol = RM_NormalizedLot(symbol);
               if(vol > 0.0)
                  rmData.trade.Buy(vol, symbol, 0, 0, 0, "EMA Cross Distance");
               rmData.emaCrossBuySignal = false;
            }
         }
      }
      else if(rmData.emaCrossSellSignal)
      {
         bool distanceConditionMet = true;
         double emaHistory[], closeHistory[];
         ArraySetAsSeries(emaHistory, true);
         ArraySetAsSeries(closeHistory, true);
         
         if(CopyBuffer(rmData.emaHandle, 0, 0, RM_InpEMADistancePeriod, emaHistory) > 0 &&
            CopyClose(symbol, RM_InpTimeframe, 0, RM_InpEMADistancePeriod, closeHistory) > 0)
         {
            double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
            for(int i = 0; i < RM_InpEMADistancePeriod; i++)
            {
               double distance = (emaHistory[i] - closeHistory[i]) / point;
               if(distance < RM_InpEMADistancePips)
               {
                  distanceConditionMet = false;
                  break;
               }
            }
            
            if(distanceConditionMet && !HasPosition(symbol, RM_InpMagicNumberEMACross))
            {
               rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberEMACross);
               const double vol = RM_NormalizedLot(symbol);
               if(vol > 0.0)
                  rmData.trade.Sell(vol, symbol, 0, 0, 0, "EMA Cross Distance");
               rmData.emaCrossSellSignal = false;
            }
         }
      }
   }
   else
   {
      if(rmData.lastBarEMAPrev < rmData.lastBarClosePrev && rmData.lastBarEMA > rmData.lastBarClose)
      {
         if(!HasPosition(symbol, RM_InpMagicNumberEMACross))
         {
            rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberEMACross);
            const double vol = RM_NormalizedLot(symbol);
            if(vol > 0.0)
               rmData.trade.Buy(vol, symbol, 0, 0, 0, "EMA Cross");
         }
      }
      else if(rmData.lastBarEMAPrev > rmData.lastBarClosePrev && rmData.lastBarEMA < rmData.lastBarClose)
      {
         if(!HasPosition(symbol, RM_InpMagicNumberEMACross))
         {
            rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberEMACross);
            const double vol = RM_NormalizedLot(symbol);
            if(vol > 0.0)
               rmData.trade.Sell(vol, symbol, 0, 0, 0, "EMA Cross");
         }
      }
   }
   
   if(rmData.emaCrossBuySignal || rmData.emaCrossSellSignal)
   {
      rmData.emaCrossSignalBar++;
      if(rmData.emaCrossSignalBar > RM_InpEMADistancePeriod * 2)
      {
         rmData.emaCrossBuySignal = false;
         rmData.emaCrossSellSignal = false;
      }
   }
}

void CheckExitConditions(string symbol)
{
   if(RM_InpEnableRSIFollow)
   {
      if(HasPosition(symbol, RM_InpMagicNumberRSIFollow))
      {
         if(PositionSelectByMagic(symbol, RM_InpMagicNumberRSIFollow))
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if((posType == POSITION_TYPE_BUY && rmData.lastBarRSI < RM_InpRSIExitLevel) ||
               (posType == POSITION_TYPE_SELL && rmData.lastBarRSI > RM_InpRSIExitLevel))
            {
               ClosePosition(symbol, RM_InpMagicNumberRSIFollow);
            }
         }
      }
   }
   
   if(RM_InpEnableRSIReverse)
   {
      if(HasPosition(symbol, RM_InpMagicNumberRSIReverse))
      {
         if(PositionSelectByMagic(symbol, RM_InpMagicNumberRSIReverse))
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if((posType == POSITION_TYPE_BUY && rmData.lastBarRSIReverse < RM_InpRSIReverseExitLevel) ||
               (posType == POSITION_TYPE_SELL && rmData.lastBarRSIReverse > RM_InpRSIReverseExitLevel))
            {
               ClosePosition(symbol, RM_InpMagicNumberRSIReverse);
            }
         }
      }
   }
   
   if(RM_InpEnableEMACross)
   {
      if(HasPosition(symbol, RM_InpMagicNumberEMACross))
      {
         if(PositionSelectByMagic(symbol, RM_InpMagicNumberEMACross))
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if((posType == POSITION_TYPE_BUY && rmData.lastBarEMA > rmData.lastBarClose) ||
               (posType == POSITION_TYPE_SELL && rmData.lastBarEMA < rmData.lastBarClose))
            {
               ClosePosition(symbol, RM_InpMagicNumberEMACross);
            }
         }
      }
   }
}

void ClosePosition(string symbol, int magic)
{
   if(!PositionExistsByMagic(symbol, magic))
      return;
   
   ulong ticket = GetPositionTicketByMagic(symbol, magic);
   if(ticket == 0)
      return;
   
   if(magic == RM_InpMagicNumberRSIReverse)
   {
      if(PositionSelectByTicketSymbolAndMagic(ticket, symbol, magic))
      {
         datetime time[];
         if(CopyTime(symbol, RM_InpTimeframe, 0, 1, time) > 0)
         {
            rmData.rsiReverseLastCloseTime = time[0];
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(!RM_InpRSIReverseCooldownOnLoss || profit < 0)
            {
               rmData.rsiReverseInCooldown = true;
            }
         }
      }
   }
   
   ClosePositionByMagic(rmData.trade, symbol, magic);
}

bool InitRSIMidPointHijack(string symbol)
{
   rmData.symbol = symbol;
   rmData.rsiOverbought = false;
   rmData.rsiOversold = false;
   rmData.rsiReverseOverbought = false;
   rmData.rsiReverseOversold = false;
   rmData.emaCrossBuySignal = false;
   rmData.emaCrossSellSignal = false;
   rmData.emaCrossSignalBar = 0;
   rmData.rsiReverseInCooldown = false;
   rmData.lastBarRSI = 0;
   rmData.lastBarRSIReverse = 0;
   rmData.lastBarEMA = 0;
   rmData.lastBarClose = 0;
   rmData.lastBarEMAPrev = 0;
   rmData.lastBarClosePrev = 0;
   
   // Check if symbol exists
   if(!SymbolSelect(symbol, true))
   {
      Print("RSIMidPointHijack: Symbol '", symbol, "' not available in Market Watch. Please add it to Market Watch or check symbol name.");
      return false;
   }
   
   Sleep(100); // Wait for symbol to be ready
   
   rmData.rsiHandle = iRSI(symbol, RM_InpTimeframe, RM_InpRSIPeriod, PRICE_CLOSE);
   rmData.rsiReverseHandle = iRSI(symbol, RM_InpTimeframe, RM_InpRSIReversePeriod, PRICE_CLOSE);
   rmData.emaHandle = iMA(symbol, RM_InpTimeframe, RM_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(rmData.rsiHandle == INVALID_HANDLE || rmData.rsiReverseHandle == INVALID_HANDLE || rmData.emaHandle == INVALID_HANDLE)
   {
      Print("RSIMidPointHijack: Error creating indicators for '", symbol, "'");
      return false;
   }
   
   rmData.trade.SetExpertMagicNumber(RM_InpMagicNumberRSIFollow);
   rmData.trade.SetMarginMode();
   rmData.trade.SetTypeFillingBySymbol(symbol);
   rmData.trade.SetDeviationInPoints(10);
   
   datetime time[];
   if(CopyTime(symbol, RM_InpTimeframe, 0, 1, time) > 0)
      rmData.lastBarTime = time[0];
   
   rmData.isInitialized = true;
   Print("RSIMidPointHijack: Successfully initialized for symbol '", symbol, "'");
   return true;
}

void DeinitRSIMidPointHijack()
{
   if(rmData.rsiHandle != INVALID_HANDLE) IndicatorRelease(rmData.rsiHandle);
   if(rmData.rsiReverseHandle != INVALID_HANDLE) IndicatorRelease(rmData.rsiReverseHandle);
   if(rmData.emaHandle != INVALID_HANDLE) IndicatorRelease(rmData.emaHandle);
}

void ProcessRSIMidPointHijack(string symbol)
{
   // Skip if not initialized (symbol not available)
   if(!rmData.isInitialized)
      return;
      
   rmData.symbol = symbol; // Update symbol in case it changed
   if(!IsNewBar(rmData.symbol))
      return;
      
   double rsi[], rsiReverse[], ema[], close[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(rsiReverse, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(close, true);
   
   rmData.lastBarEMAPrev = rmData.lastBarEMA;
   rmData.lastBarClosePrev = rmData.lastBarClose;
   
   if(CopyBuffer(rmData.rsiHandle, 0, 0, 1, rsi) > 0)
      rmData.lastBarRSI = rsi[0];
      
   if(CopyBuffer(rmData.rsiReverseHandle, 0, 0, 1, rsiReverse) > 0)
      rmData.lastBarRSIReverse = rsiReverse[0];
      
   if(CopyBuffer(rmData.emaHandle, 0, 0, 1, ema) > 0)
      rmData.lastBarEMA = ema[0];
      
   if(CopyClose(rmData.symbol, RM_InpTimeframe, 0, 1, close) > 0)
      rmData.lastBarClose = close[0];
      
   if(RM_InpEnableRSIFollow)
      CheckRSIFollowStrategy(rmData.symbol);
   if(RM_InpEnableRSIReverse)
      CheckRSIReverseStrategy(rmData.symbol);
   if(RM_InpEnableEMACross)
      CheckEMACrossStrategy(rmData.symbol);
   
   CheckExitConditions(rmData.symbol);
}

//+------------------------------------------------------------------+
