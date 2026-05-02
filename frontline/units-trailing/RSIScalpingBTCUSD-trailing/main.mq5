//+------------------------------------------------------------------+
//|                                                  RSIScalping.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.01"

#include <Trade\Trade.mqh>
#include "../_united/MagicNumberHelpers.mqh"

//--- Input parameters
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1; // Timeframe for Analysis
input int                  RSI_Period = 14;           // RSI Period
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE; // RSI Applied Price
input double              RSI_Overbought = 90;        // RSI Overbought Level
input double              RSI_Oversold = 73;          // RSI Oversold Level
input double              RSI_Target_Buy = 88;         // RSI Target for Buy Exit
input double              RSI_Target_Sell = 48;        // RSI Target for Sell Exit
input int                 BarsToWait = 6;             // Bars to wait when RSI goes against position
input double              LotSize = 0.1;              // Lot Size
input int                 MagicNumber = 123459123;        // Magic Number
input int                 Slippage = 3;               // Slippage in points

input group "=== Reversal escape (intrabar, multi-signal) ==="
input bool   UseReversalEscape = true;       // run while in position every tick
input int    ReversalATRPeriod = 14;         // ATR lookback on signal timeframe
input double ReversalAdverseAtrMult = 5.25;  // close if price vs entry >= this * ATR
input int    ReversalSignsRequired = 2;      // how many independent signs must align
input double ReversalRsiVelocity = 16.0;     // RSI points drop (long) / rise (short) vs prior buffer
input double ReversalBodyAtrMult = 5.1;      // last closed bar body >= this * ATR counts as one sign

input group "=== Trailing stop ==="
input bool   UseTrailingStop = true;            // move SL behind bid/ask while in profit
input double TrailingStopDistancePoints = 120.0;  // SL distance from bid/ask (points)
input double TrailingActivationPoints = 0.0;      // min profit before trailing (0 = same as distance)

//--- Global variables
CTrade trade;
int rsi_handle;
double rsi_buffer[];
double rsi_prev, rsi_current, rsi_two_bars_ago;
bool position_open = false;
int position_ticket = 0;
ENUM_POSITION_TYPE current_position_type = POSITION_TYPE_BUY;
datetime last_bar_time = 0;
bool rsi_against_position = false;
int bars_against_count = 0;

void ResetPositionTracking();
void SyncTrackedPosition();
double ATRPriceOnTF(const int period);
int CountReversalEscapeSigns(const ENUM_POSITION_TYPE ptype, const double atr);
void TryReversalEscape();
void ApplyTrailingStop();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize RSI indicator
   rsi_handle = iRSI(_Symbol, TimeFrame, RSI_Period, RSI_Applied_Price);
   if(rsi_handle == INVALID_HANDLE)
   {
      return(INIT_FAILED);
   }
   
   // Initialize trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Allocate arrays
   ArraySetAsSeries(rsi_buffer, true);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if we have enough bars
   if(Bars(_Symbol, TimeFrame) < RSI_Period + 2)
   {
      return;
   }

   // Check if this is a new bar
   datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   bool is_new_bar = (current_bar_time != last_bar_time);
   bool in_position = position_open || PositionExistsByMagic(_Symbol, (ulong)MagicNumber);

   // While flat, process only on new bars. While in position, allow intrabar reversal escape checks.
   if(!in_position && !is_new_bar)
   {
      return;
   }

   // Update RSI values
   if(!UpdateRSI())
   {
      return;
   }

   if(in_position && UseReversalEscape)
   {
      TryReversalEscape();
   }

   if(in_position && UseTrailingStop)
      ApplyTrailingStop();

   if(!is_new_bar)
   {
      return;
   }

   last_bar_time = current_bar_time;

   // Keep local tracking aligned with actual terminal positions for this symbol/magic.
   SyncTrackedPosition();
   
   // Check for existing position
   CheckExistingPosition();
   
   // Check for new entry signals - only if no position exists for THIS EA (magic number) on THIS symbol
   if(!position_open && !PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
   {
      CheckEntrySignals();
   }
}

//+------------------------------------------------------------------+
//| Update RSI values                                                |
//+------------------------------------------------------------------+
bool UpdateRSI()
{
   if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_buffer) < 3)
   {
      return false;
   }
   
   rsi_current = rsi_buffer[0];  // Current bar
   rsi_prev = rsi_buffer[1];     // Previous bar
   rsi_two_bars_ago = rsi_buffer[2];  // Two bars ago
   
   return true;
}

//+------------------------------------------------------------------+
//| Wilder ATR in price units (signal timeframe)                    |
//+------------------------------------------------------------------+
double ATRPriceOnTF(const int period)
{
   if(period < 1)
      return 0.0;

   MqlRates rates[];
   const int need = period + 2;
   if(CopyRates(_Symbol, TimeFrame, 0, need, rates) < need)
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

//+------------------------------------------------------------------+
//| Independent adverse signs (need ReversalSignsRequired to exit)  |
//+------------------------------------------------------------------+
int CountReversalEscapeSigns(const ENUM_POSITION_TYPE ptype, const double atr)
{
   if(atr <= 0.0)
      return 0;

   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int signs = 0;

   if(ptype == POSITION_TYPE_BUY)
   {
      if(entry - bid >= ReversalAdverseAtrMult * atr)
         signs++;
      if(rsi_prev - rsi_current >= ReversalRsiVelocity)
         signs++;
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      if(ask - entry >= ReversalAdverseAtrMult * atr)
         signs++;
      if(rsi_current - rsi_prev >= ReversalRsiVelocity)
         signs++;
   }
   else
   {
      return 0;
   }

   MqlRates rates[];
   if(CopyRates(_Symbol, TimeFrame, 0, 4, rates) >= 4)
   {
      ArraySetAsSeries(rates, true);
      const double body = MathAbs(rates[1].close - rates[1].open);
      if(body >= ReversalBodyAtrMult * atr)
      {
         if(ptype == POSITION_TYPE_BUY && rates[1].close < rates[1].open)
            signs++;
         else if(ptype == POSITION_TYPE_SELL && rates[1].close > rates[1].open)
            signs++;
      }

      if(ptype == POSITION_TYPE_BUY)
      {
         if(rates[1].close < rates[2].close && rates[2].close < rates[3].close)
            signs++;
      }
      else
      {
         if(rates[1].close > rates[2].close && rates[2].close > rates[3].close)
            signs++;
      }
   }

   return signs;
}

//+------------------------------------------------------------------+
//| Cut losers fast on violent reversals (evaluated every tick)     |
//+------------------------------------------------------------------+
void TryReversalEscape()
{
   ulong live_ticket = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
   if(live_ticket == 0)
      return;
   if(!PositionSelectByTicketSymbolAndMagic(live_ticket, _Symbol, (ulong)MagicNumber))
      return;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double atr = ATRPriceOnTF(ReversalATRPeriod);
   if(atr <= 0.0)
      return;

   const int signs = CountReversalEscapeSigns(ptype, atr);
   if(signs < ReversalSignsRequired)
      return;

   ClosePosition();
   Print("RSIScalpingBTCUSD: reversal escape signs=", signs, " need=", ReversalSignsRequired,
         " ATR=", DoubleToString(atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

//+------------------------------------------------------------------+
//| Trail SL behind favorable price (every tick when enabled)       |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   if(TrailingStopDistancePoints <= 0.0)
      return;
   if(!PositionSelectByMagic(_Symbol, (ulong)MagicNumber))
      return;

   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double trail_dist = TrailingStopDistancePoints * point;
   const double activation_pts = (TrailingActivationPoints > 0.0)
      ? TrailingActivationPoints
      : TrailingStopDistancePoints;
   const double activation = activation_pts * point;
   const long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double min_dist = (double)stops_level * point;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double cur_sl = PositionGetDouble(POSITION_SL);
   const double cur_tp = PositionGetDouble(POSITION_TP);

   if(ptype == POSITION_TYPE_BUY)
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid - entry <= activation)
         return;

      double new_sl = NormalizeDouble(bid - trail_dist, digits);
      if(min_dist > 0.0 && bid - new_sl < min_dist)
         new_sl = NormalizeDouble(bid - min_dist, digits);

      if(new_sl >= bid || new_sl <= 0.0)
         return;
      if(cur_sl > 0.0 && new_sl <= cur_sl)
         return;

      ModifyPositionByMagic(trade, _Symbol, (ulong)MagicNumber, new_sl, cur_tp);
   }
   else if(ptype == POSITION_TYPE_SELL)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(entry - ask <= activation)
         return;

      double new_sl = NormalizeDouble(ask + trail_dist, digits);
      if(min_dist > 0.0 && new_sl - ask < min_dist)
         new_sl = NormalizeDouble(ask + min_dist, digits);

      if(new_sl <= ask || new_sl <= 0.0)
         return;
      if(cur_sl > 0.0 && new_sl >= cur_sl)
         return;

      ModifyPositionByMagic(trade, _Symbol, (ulong)MagicNumber, new_sl, cur_tp);
   }
}

//+------------------------------------------------------------------+
//| Reset local position tracking                                    |
//+------------------------------------------------------------------+
void ResetPositionTracking()
{
   position_open = false;
   position_ticket = 0;
   rsi_against_position = false;
   bars_against_count = 0;
}

//+------------------------------------------------------------------+
//| Sync local state with real position in terminal                  |
//+------------------------------------------------------------------+
void SyncTrackedPosition()
{
   ulong live_ticket = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
   if(live_ticket == 0)
   {
      ResetPositionTracking();
      return;
   }

   // If we were not tracking (or ticket changed), start tracking the live position.
   if(!position_open || position_ticket != (int)live_ticket)
   {
      if(PositionSelectByTicketSymbolAndMagic(live_ticket, _Symbol, (ulong)MagicNumber))
      {
         position_open = true;
         position_ticket = (int)live_ticket;
         current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         rsi_against_position = false;
         bars_against_count = 0;
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Check existing position for exit conditions                     |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(!position_open)
   {
      return;
   }
   
   // Check if position still exists with correct magic number AND symbol for THIS EA
   if(!PositionSelectByTicketSymbolAndMagic(position_ticket, _Symbol, (ulong)MagicNumber))
   {
      ResetPositionTracking();
      return;
   }
   
   // Exit conditions based on RSI target
   if(current_position_type == POSITION_TYPE_BUY)
   {
      // Check if RSI is against the position (below oversold)
      if(rsi_current < RSI_Oversold)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
         {
            bars_against_count++;
         }
         
         // Close position if RSI has been against for Y bars
         if(bars_against_count >= BarsToWait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         // RSI is no longer against the position, reset counter
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         
         // Exit long position when RSI reaches buy target
         if(rsi_current >= RSI_Target_Buy)
         {
            ClosePosition();
         }
      }
   }
   else if(current_position_type == POSITION_TYPE_SELL)
   {
      // Check if RSI is against the position (above overbought)
      if(rsi_current > RSI_Overbought)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
         {
            bars_against_count++;
         }
         
         // Close position if RSI has been against for Y bars
         if(bars_against_count >= BarsToWait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         // RSI is no longer against the position, reset counter
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         
         // Exit short position when RSI reaches sell target
         if(rsi_current <= RSI_Target_Sell)
         {
            ClosePosition();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check for entry signals                                          |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   // Buy signal: RSI crosses from oversold to above oversold (checking the actual crossover)
   if(rsi_two_bars_ago <= RSI_Oversold && rsi_prev > RSI_Oversold)
   {
      OpenBuyPosition();
   }
   
   // Sell signal: RSI crosses from overbought to below overbought (checking the actual crossover)
   if(rsi_two_bars_ago >= RSI_Overbought && rsi_prev < RSI_Overbought)
   {
      OpenSellPosition();
   }
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   // Verify no position exists for THIS EA (magic number) on THIS symbol before opening
   if(PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
   {
      return; // Position already exists for this EA
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI Scalping Buy"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0)
      {
         // Verify position was opened for THIS EA (magic number) on THIS symbol
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, (ulong)MagicNumber))
         {
            position_ticket = new_ticket;
            position_open = true;
            current_position_type = POSITION_TYPE_BUY;
         }
         else
         {
            Print("Error: Position opened but doesn't match EA magic number or symbol");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open sell position                                               |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   // Verify no position exists for THIS EA (magic number) on THIS symbol before opening
   if(PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
   {
      return; // Position already exists for this EA
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "RSI Scalping Sell"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0)
      {
         // Verify position was opened for THIS EA (magic number) on THIS symbol
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, (ulong)MagicNumber))
         {
            position_ticket = new_ticket;
            position_open = true;
            current_position_type = POSITION_TYPE_SELL;
         }
         else
         {
            Print("Error: Position opened but doesn't match EA magic number or symbol");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close current position                                           |
//+------------------------------------------------------------------+
void ClosePosition()
{
   bool position_exists_before_close = PositionExistsByMagic(_Symbol, (ulong)MagicNumber);
   if(!position_exists_before_close)
   {
      ResetPositionTracking();
      return;
   }

   // Close position using helper that verifies symbol AND magic number for THIS EA
   if(ClosePositionByMagic(trade, _Symbol, (ulong)MagicNumber))
   {
      ResetPositionTracking();
   }
   else
   {
      // Keep tracking when close fails (e.g. market closed); retry on next bar.
      if(!PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
      {
         ResetPositionTracking();
      }
   }
}
