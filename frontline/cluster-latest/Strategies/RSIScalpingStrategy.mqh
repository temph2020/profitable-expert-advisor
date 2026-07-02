//+------------------------------------------------------------------+
//|                                          RSIScalpingStrategy.mqh |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| RSI Scalping Strategy Data Structure                             |
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
   bool closeUnprofitableOnNewSignal;
};

void ClosePosition(RSIScalpingData& data, int MagicNumber);

double RS_ATRPriceOnTF(const string symbol, const ENUM_TIMEFRAMES tf, const int period)
{
   if(period < 1)
      return 0.0;
   MqlRates rates[];
   const int need = period + 2;
   if(CopyRates(symbol, tf, 0, need, rates) < need)
      return 0.0;
   ArraySetAsSeries(rates, true);
   double sum = 0.0;
   for(int i = 1; i <= period; i++)
   {
      const double hl = rates[i].high - rates[i].low;
      const double hc = MathAbs(rates[i].high - rates[i + 1].close);
      const double lc = MathAbs(rates[i].low - rates[i + 1].close);
      sum += MathMax(hl, MathMax(hc, lc));
   }
   return sum / (double)period;
}

int RS_CountReversalEscapeSigns(RSIScalpingData& data, const ENUM_TIMEFRAMES tf,
                                const ENUM_POSITION_TYPE ptype, const double atr,
                                const double adverseAtrMult, const double rsiVelocity,
                                const double bodyAtrMult)
{
   if(atr <= 0.0)
      return 0;
   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double bid = SymbolInfoDouble(data.symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(data.symbol, SYMBOL_ASK);
   int signs = 0;

   if(ptype == POSITION_TYPE_BUY)
   {
      if(entry - bid >= adverseAtrMult * atr)
         signs++;
      if(data.rsi_prev - data.rsi_current >= rsiVelocity)
         signs++;
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      if(ask - entry >= adverseAtrMult * atr)
         signs++;
      if(data.rsi_current - data.rsi_prev >= rsiVelocity)
         signs++;
   }
   else
      return 0;

   MqlRates r[];
   if(CopyRates(data.symbol, tf, 0, 4, r) >= 4)
   {
      ArraySetAsSeries(r, true);
      const double body = MathAbs(r[1].close - r[1].open);
      if(body >= bodyAtrMult * atr)
      {
         if(ptype == POSITION_TYPE_BUY && r[1].close < r[1].open)
            signs++;
         else if(ptype == POSITION_TYPE_SELL && r[1].close > r[1].open)
            signs++;
      }
      if(ptype == POSITION_TYPE_BUY)
      {
         if(r[1].close < r[2].close && r[2].close < r[3].close)
            signs++;
      }
      else
      {
         if(r[1].close > r[2].close && r[2].close > r[3].close)
            signs++;
      }
   }
   return signs;
}

void RS_TryReversalEscape(RSIScalpingData& data, const ENUM_TIMEFRAMES tf, const int MagicNumber,
                          const int atrPeriod, const double adverseAtrMult, const int signsRequired,
                          const double rsiVelocity, const double bodyAtrMult)
{
   if(!PositionSelectByMagic(data.symbol, (ulong)MagicNumber))
      return;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double atr = RS_ATRPriceOnTF(data.symbol, tf, atrPeriod);
   if(atr <= 0.0)
      return;

   const int n = RS_CountReversalEscapeSigns(data, tf, ptype, atr, adverseAtrMult, rsiVelocity, bodyAtrMult);
   if(n < signsRequired)
      return;

   ClosePosition(data, MagicNumber);
   Print("RSIScalping: reversal escape symbol=", data.symbol, " signs=", n, " need=", signsRequired,
         " ATR=", DoubleToString(atr, (int)SymbolInfoInteger(data.symbol, SYMBOL_DIGITS)));
}

void RS_ApplyTrailingStop(RSIScalpingData& data, const int MagicNumber,
                          const bool useTrailingStop,
                          const double trailingStopDistancePoints,
                          const double trailingActivationPoints)
{
   if(!useTrailingStop || trailingStopDistancePoints <= 0.0)
      return;
   if(!PositionSelectByMagic(data.symbol, (ulong)MagicNumber))
      return;

   const double point = SymbolInfoDouble(data.symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   const int digits = (int)SymbolInfoInteger(data.symbol, SYMBOL_DIGITS);
   const double trail_dist = trailingStopDistancePoints * point;
   const double activation_pts = (trailingActivationPoints > 0.0)
      ? trailingActivationPoints
      : trailingStopDistancePoints;
   const double activation = activation_pts * point;
   const long stops_level = SymbolInfoInteger(data.symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double min_dist = (double)stops_level * point;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double cur_sl = PositionGetDouble(POSITION_SL);
   const double cur_tp = PositionGetDouble(POSITION_TP);

   if(ptype == POSITION_TYPE_BUY)
   {
      const double bid = SymbolInfoDouble(data.symbol, SYMBOL_BID);
      if(bid - entry <= activation)
         return;

      double new_sl = NormalizeDouble(bid - trail_dist, digits);
      if(min_dist > 0.0 && bid - new_sl < min_dist)
         new_sl = NormalizeDouble(bid - min_dist, digits);

      if(new_sl >= bid || new_sl <= 0.0)
         return;
      if(cur_sl > 0.0 && new_sl <= cur_sl)
         return;

      ModifyPositionByMagic(data.trade, data.symbol, (ulong)MagicNumber, new_sl, cur_tp);
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      const double ask = SymbolInfoDouble(data.symbol, SYMBOL_ASK);
      if(entry - ask <= activation)
         return;

      double new_sl = NormalizeDouble(ask + trail_dist, digits);
      if(min_dist > 0.0 && new_sl - ask < min_dist)
         new_sl = NormalizeDouble(ask + min_dist, digits);

      if(new_sl <= ask || new_sl <= 0.0)
         return;
      if(cur_sl > 0.0 && new_sl >= cur_sl)
         return;

      ModifyPositionByMagic(data.trade, data.symbol, (ulong)MagicNumber, new_sl, cur_tp);
   }
}

string ErrorDescription(int errorCode)
{
   switch(errorCode)
   {
      case 4801: return "Symbol not found";
      case 4802: return "Symbol not selected";
      case 4803: return "Symbol not visible";
      case 4804: return "Symbol not available";
      case 4805: return "Cannot load indicator - insufficient history data";
      default: return "Unknown error " + IntegerToString(errorCode);
   }
}

bool InitRSIScalping(RSIScalpingData& data, string symbol, ENUM_TIMEFRAMES TimeFrame, int RSI_Period, 
                     ENUM_APPLIED_PRICE RSI_Applied_Price, int MagicNumber, int Slippage)
{
   data.symbol = symbol;
   data.isInitialized = false;
   
   // Check if symbol exists
   if(!SymbolSelect(symbol, true))
   {
      Print("RSIScalping: Symbol '", symbol, "' not available in Market Watch. Please add it to Market Watch or check symbol name.");
      return false; // Return false but don't fail entire EA
   }
   
   // Wait a bit for symbol to be ready
   Sleep(100);
   
   // Try to create RSI indicator with retry logic (for insufficient history in backtesting)
   data.rsi_handle = INVALID_HANDLE;
   int retryCount = 0;
   int maxRetries = 5;
   
   while(retryCount < maxRetries && data.rsi_handle == INVALID_HANDLE)
   {
      data.rsi_handle = iRSI(symbol, TimeFrame, RSI_Period, RSI_Applied_Price);
      
      if(data.rsi_handle == INVALID_HANDLE)
      {
         int error = GetLastError();
         
         // Error 4805 = insufficient history - wait longer and retry
         if(error == 4805 && retryCount < maxRetries - 1)
         {
            Sleep(1000); // Wait 1 second for history to load
            retryCount++;
            continue;
         }
         
         Print("RSIScalping: Error creating RSI indicator for '", symbol, "' - Error: ", error, " (", ErrorDescription(error), ")");
         return false; // Return false but don't fail entire EA
      }
   }
   
   if(data.rsi_handle == INVALID_HANDLE)
   {
      Print("RSIScalping: Failed to create RSI indicator for '", symbol, "' after ", maxRetries, " retries");
      return false;
   }
   
   data.trade.SetExpertMagicNumber(MagicNumber);
   data.trade.SetDeviationInPoints(Slippage);
   data.trade.SetTypeFillingBySymbol(symbol);
   
   ArraySetAsSeries(data.rsi_buffer, true);
   data.position_open = false;
   data.position_ticket = 0;
   data.rsi_against_position = false;
   data.bars_against_count = 0;
   data.isInitialized = true;
   
   Print("RSIScalping: Successfully initialized for symbol '", symbol, "'");
   return true;
}

void DeinitRSIScalping(RSIScalpingData& data)
{
   if(data.rsi_handle != INVALID_HANDLE)
      IndicatorRelease(data.rsi_handle);
}

bool UpdateRSI(RSIScalpingData& data)
{
   if(CopyBuffer(data.rsi_handle, 0, 0, 3, data.rsi_buffer) < 3)
      return false;
   
   data.rsi_current = data.rsi_buffer[0];
   data.rsi_prev = data.rsi_buffer[1];
   data.rsi_two_bars_ago = data.rsi_buffer[2];
   
   return true;
}

void CheckExistingPosition(RSIScalpingData& data, ENUM_TIMEFRAMES TimeFrame, int MagicNumber,
                          double RSI_Oversold, double RSI_Overbought, double RSI_Target_Buy,
                          double RSI_Target_Sell, int BarsToWait)
{
   // Always check if position exists, even if tracking says it doesn't
   bool positionExists = PositionExistsByMagic(data.symbol, MagicNumber);
   
   if(!positionExists && data.position_open)
   {
      // Position was closed externally, reset tracking
      data.position_open = false;
      data.position_ticket = 0;
      data.rsi_against_position = false;
      data.bars_against_count = 0;
      return;
   }
   
   if(!positionExists)
      return;
   
   // Update tracking if we have a position but tracking was lost
   if(!data.position_open && positionExists)
   {
      ulong ticket = GetPositionTicketByMagic(data.symbol, MagicNumber);
      if(ticket > 0 && PositionSelectByTicketSymbolAndMagic(ticket, data.symbol, MagicNumber))
      {
         data.position_ticket = ticket;
         data.position_open = true;
         data.current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }
   
   // Verify our tracked position still exists
   if(data.position_open && data.position_ticket > 0)
   {
      if(!PositionSelectByTicketSymbolAndMagic(data.position_ticket, data.symbol, MagicNumber))
      {
         // Try to find the position again
         ulong ticket = GetPositionTicketByMagic(data.symbol, MagicNumber);
         if(ticket > 0 && PositionSelectByTicketSymbolAndMagic(ticket, data.symbol, MagicNumber))
         {
            data.position_ticket = ticket;
            data.current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         }
         else
         {
            // Position doesn't exist, reset tracking
            data.position_open = false;
            data.position_ticket = 0;
            data.rsi_against_position = false;
            data.bars_against_count = 0;
            return;
         }
      }
      else
      {
         // Update position type in case it changed (shouldn't happen, but be safe)
         data.current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }
   
   if(data.current_position_type == POSITION_TYPE_BUY)
   {
      if(data.rsi_current < RSI_Oversold)
      {
         if(!data.rsi_against_position)
         {
            data.rsi_against_position = true;
            data.bars_against_count = 1;
         }
         else
         {
            data.bars_against_count++;
         }
         
         if(data.bars_against_count >= BarsToWait)
         {
            ClosePosition(data, MagicNumber);
            return;
         }
      }
      else
      {
         if(data.rsi_against_position)
         {
            data.rsi_against_position = false;
            data.bars_against_count = 0;
         }
         
         if(data.rsi_current >= RSI_Target_Buy)
         {
            ClosePosition(data, MagicNumber);
         }
      }
   }
   else if(data.current_position_type == POSITION_TYPE_SELL)
   {
      if(data.rsi_current > RSI_Overbought)
      {
         if(!data.rsi_against_position)
         {
            data.rsi_against_position = true;
            data.bars_against_count = 1;
         }
         else
         {
            data.bars_against_count++;
         }
         
         if(data.bars_against_count >= BarsToWait)
         {
            ClosePosition(data, MagicNumber);
            return;
         }
      }
      else
      {
         if(data.rsi_against_position)
         {
            data.rsi_against_position = false;
            data.bars_against_count = 0;
         }
         
         if(data.rsi_current <= RSI_Target_Sell)
         {
            ClosePosition(data, MagicNumber);
         }
      }
   }
}

void CheckEntrySignals(RSIScalpingData& data, ENUM_TIMEFRAMES TimeFrame, int MagicNumber,
                      double RSI_Oversold, double RSI_Overbought, double LotSize)
{
   if(data.rsi_two_bars_ago <= RSI_Oversold && data.rsi_prev > RSI_Oversold)
   {
      OpenBuyPosition(data, MagicNumber, LotSize);
   }
   
   if(data.rsi_two_bars_ago >= RSI_Overbought && data.rsi_prev < RSI_Overbought)
   {
      OpenSellPosition(data, MagicNumber, LotSize);
   }
}

//+------------------------------------------------------------------+
//| Normalize Lot Size According to Symbol Properties                |
//+------------------------------------------------------------------+
double NormalizeLotSize(string symbol, double lotSize)
{
   return United_NormalizeVolume(symbol, lotSize);
}

void OpenBuyPosition(RSIScalpingData& data, int MagicNumber, double LotSize)
{
   if(!United_PrepareEntrySlot(data.trade, data.symbol, (ulong)MagicNumber, data.closeUnprofitableOnNewSignal))
      return;
   if(United_IsGapRiskWindow(data.symbol))
      return;

   data.position_open = false;
   data.position_ticket = 0;
   data.rsi_against_position = false;
   data.bars_against_count = 0;
   
   // Normalize lot size according to symbol properties
   double normalizedLot = NormalizeLotSize(data.symbol, LotSize);
   
   double ask = SymbolInfoDouble(data.symbol, SYMBOL_ASK);
   
   if(data.trade.Buy(normalizedLot, data.symbol, ask, 0, 0, "RSI Scalping Buy"))
   {
      ulong new_ticket = data.trade.ResultOrder();
      if(new_ticket > 0)
      {
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, data.symbol, MagicNumber))
         {
            data.position_ticket = new_ticket;
            data.position_open = true;
            data.current_position_type = POSITION_TYPE_BUY;
         }
      }
   }
}

void OpenSellPosition(RSIScalpingData& data, int MagicNumber, double LotSize)
{
   if(!United_PrepareEntrySlot(data.trade, data.symbol, (ulong)MagicNumber, data.closeUnprofitableOnNewSignal))
      return;
   if(United_IsGapRiskWindow(data.symbol))
      return;

   data.position_open = false;
   data.position_ticket = 0;
   data.rsi_against_position = false;
   data.bars_against_count = 0;
   
   // Normalize lot size according to symbol properties
   double normalizedLot = NormalizeLotSize(data.symbol, LotSize);
   
   double bid = SymbolInfoDouble(data.symbol, SYMBOL_BID);
   
   if(data.trade.Sell(normalizedLot, data.symbol, bid, 0, 0, "RSI Scalping Sell"))
   {
      ulong new_ticket = data.trade.ResultOrder();
      if(new_ticket > 0)
      {
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, data.symbol, MagicNumber))
         {
            data.position_ticket = new_ticket;
            data.position_open = true;
            data.current_position_type = POSITION_TYPE_SELL;
         }
      }
   }
}

void ClosePosition(RSIScalpingData& data, int MagicNumber)
{
   // First verify position still exists
   if(!PositionExistsByMagic(data.symbol, MagicNumber))
   {
      // Position doesn't exist, reset tracking
      data.position_open = false;
      data.position_ticket = 0;
      data.rsi_against_position = false;
      data.bars_against_count = 0;
      return;
   }
   
   // Try to close by ticket first (more reliable)
   bool closed = false;
   if(data.position_ticket > 0)
   {
      if(PositionSelectByTicket(data.position_ticket))
      {
         // Verify it's our position
         if(PositionGetString(POSITION_SYMBOL) == data.symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            closed = data.trade.PositionClose(data.position_ticket);
            if(!closed)
            {
               Print("RSIScalping: Failed to close position by ticket ", data.position_ticket, 
                     " - Error: ", data.trade.ResultRetcode(), " (", data.trade.ResultRetcodeDescription(), ")");
            }
         }
      }
   }
   
   // If ticket method failed, try magic number method
   if(!closed)
   {
      closed = ClosePositionByMagic(data.trade, data.symbol, MagicNumber);
      if(!closed)
      {
         Print("RSIScalping: Failed to close position by magic number for '", data.symbol, 
               "' - Error: ", data.trade.ResultRetcode(), " (", data.trade.ResultRetcodeDescription(), ")");
      }
   }
   
   // Verify position is actually closed
   if(closed)
   {
      // Wait a moment and verify
      Sleep(50);
      if(!PositionExistsByMagic(data.symbol, MagicNumber))
      {
         data.position_open = false;
         data.position_ticket = 0;
         data.rsi_against_position = false;
         data.bars_against_count = 0;
         Print("RSIScalping: Position successfully closed for '", data.symbol, "'");
      }
      else
      {
         Print("RSIScalping: Warning - Close returned success but position still exists for '", data.symbol, "'");
         // Try one more time
         Sleep(100);
         if(PositionExistsByMagic(data.symbol, MagicNumber))
         {
            ClosePositionByMagic(data.trade, data.symbol, MagicNumber);
         }
         // Reset tracking anyway to prevent getting stuck
         data.position_open = false;
         data.position_ticket = 0;
         data.rsi_against_position = false;
         data.bars_against_count = 0;
      }
   }
   else
   {
      // Close failed, but reset tracking to prevent getting stuck
      // The position might have been closed externally
      data.position_open = false;
      data.position_ticket = 0;
      data.rsi_against_position = false;
      data.bars_against_count = 0;
   }
}

void ProcessRSIScalping(RSIScalpingData& data, string symbol, ENUM_TIMEFRAMES TimeFrame, int RSI_Period,
                       ENUM_APPLIED_PRICE RSI_Applied_Price, double RSI_Overbought,
                       double RSI_Oversold, double RSI_Target_Buy, double RSI_Target_Sell,
                       int BarsToWait, double LotSize, int MagicNumber,
                       bool UseReversalEscape, int ReversalATRPeriod, double ReversalAdverseAtrMult,
                       int ReversalSignsRequired, double ReversalRsiVelocity, double ReversalBodyAtrMult,
                       bool UseTrailingStop, double TrailingStopDistancePoints, double TrailingActivationPoints)
{
   // Skip if not initialized (symbol not available)
   if(!data.isInitialized)
      return;
      
   data.symbol = symbol; // Update symbol in case it changed
   if(Bars(data.symbol, TimeFrame) < RSI_Period + 2)
      return;

   const datetime current_bar_time = iTime(data.symbol, TimeFrame, 0);
   const bool new_bar = (current_bar_time != data.last_bar_time);
   const bool in_pos = data.position_open || PositionExistsByMagic(data.symbol, MagicNumber);
   if(!in_pos && !new_bar)
      return;

   if(!UpdateRSI(data))
      return;

   if(in_pos && UseReversalEscape)
      RS_TryReversalEscape(data, TimeFrame, MagicNumber, ReversalATRPeriod, ReversalAdverseAtrMult,
                           ReversalSignsRequired, ReversalRsiVelocity, ReversalBodyAtrMult);

   if(in_pos)
      RS_ApplyTrailingStop(data, MagicNumber, UseTrailingStop,
                           TrailingStopDistancePoints, TrailingActivationPoints);

   if(!new_bar)
      return;

   data.last_bar_time = current_bar_time;

   CheckExistingPosition(data, TimeFrame, MagicNumber, RSI_Oversold, RSI_Overbought,
                        RSI_Target_Buy, RSI_Target_Sell, BarsToWait);
   
   if(!in_pos || data.closeUnprofitableOnNewSignal)
      CheckEntrySignals(data, TimeFrame, MagicNumber, RSI_Oversold, RSI_Overbought, LotSize);
}

//+------------------------------------------------------------------+
