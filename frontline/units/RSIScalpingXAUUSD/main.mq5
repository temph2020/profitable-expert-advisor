//+------------------------------------------------------------------+
//|                                                  RSIScalping.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.02"

#include <Trade\Trade.mqh>
#include "../_united/MagicNumberHelpers.mqh"

//--- Input parameters
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1; // Timeframe for Analysis
input int                  RSI_Period = 14;           // RSI Period
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE; // RSI Applied Price
input double              RSI_Overbought = 71;        // RSI Overbought Level
input double              RSI_Oversold = 57;          // RSI Oversold Level
input bool                UseEntrySlopeFilter = false; // require RSI momentum on entry bars
input double              EntryMinSlopePerBar = 1.0;  // minimum RSI delta per bar for entry
input double              RSI_Target_Buy = 80;         // RSI Target for Buy Exit
input double              RSI_Target_Sell = 57;        // RSI Target for Sell Exit
input int                 BarsToWait = 4;             // Bars to wait when RSI goes against position
input double              LotSize = 0.1;              // Lot Size
input int                 MagicNumber = 129102315;        // Magic Number
input int                 Slippage = 3;               // Slippage in points

input group "=== Reversal escape (intrabar, multi-signal) ==="
input bool   UseReversalEscape = true;       // run while in position every tick
input int    ReversalATRPeriod = 14;         // ATR lookback on signal timeframe
input double ReversalAdverseAtrMult = 5.25; // close if price vs entry >= this * ATR
input int    ReversalSignsRequired = 2;    // how many independent signs must align
input double ReversalRsiVelocity = 16.0;   // RSI points drop (long) / rise (short) vs prior buffer
input double ReversalBodyAtrMult = 5.1;   // last closed bar body >= this * ATR counts as one sign

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
   if(Bars(_Symbol, TimeFrame) < RSI_Period + 2)
      return;

   const datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   const bool new_bar = (current_bar_time != last_bar_time);
   const bool in_pos = position_open || PositionExistsByMagic(_Symbol, (ulong)MagicNumber);

   if(!in_pos && !new_bar)
      return;

   if(!UpdateRSI())
      return;

   if(in_pos && UseReversalEscape)
      TryReversalEscape();

   if(!new_bar)
      return;

   last_bar_time = current_bar_time;

   ResyncPositionFromMarket();
   CheckExistingPosition();

   if(!position_open && !PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
      CheckEntrySignals();
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
//| Wilder ATR in price units (signal timeframe)                   |
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
//| Independent adverse signs (need ReversalSignsRequired to exit)   |
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
      return 0;

   MqlRates r[];
   if(CopyRates(_Symbol, TimeFrame, 0, 4, r) >= 4)
   {
      ArraySetAsSeries(r, true);
      const double body = MathAbs(r[1].close - r[1].open);
      if(body >= ReversalBodyAtrMult * atr)
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

//+------------------------------------------------------------------+
//| Cut losers fast on violent reversals (evaluated every tick)    |
//+------------------------------------------------------------------+
void TryReversalEscape()
{
   if(!PositionSelectByMagic(_Symbol, (ulong)MagicNumber))
      return;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double atr = ATRPriceOnTF(ReversalATRPeriod);
   if(atr <= 0.0)
      return;

   const int n = CountReversalEscapeSigns(ptype, atr);
   if(n < ReversalSignsRequired)
      return;

   ClosePosition();
   Print("RSIScalpingXAUUSD: reversal escape signs=", n, " need=", ReversalSignsRequired,
         " ATR=", DoubleToString(atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

void ResyncPositionFromMarket()
{
   if(position_open)
      return;
   ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
   if(t == 0 || !PositionSelectByTicket(t))
      return;
   position_ticket = (int)t;
   position_open = true;
   current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
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
   
   // Check if position still exists with correct magic number
   if(!PositionSelectByTicketAndMagic(position_ticket, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
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
   const double upSlope1 = rsi_prev - rsi_two_bars_ago; // older->prev
   const double upSlope2 = rsi_current - rsi_prev;       // prev->current
   const double dnSlope1 = rsi_two_bars_ago - rsi_prev;  // older->prev
   const double dnSlope2 = rsi_prev - rsi_current;       // prev->current
   const bool buySlopeOk = (!UseEntrySlopeFilter) || (upSlope1 >= EntryMinSlopePerBar && upSlope2 >= EntryMinSlopePerBar);
   const bool sellSlopeOk = (!UseEntrySlopeFilter) || (dnSlope1 >= EntryMinSlopePerBar && dnSlope2 >= EntryMinSlopePerBar);

   // Buy signal: RSI crosses from oversold to above oversold (checking the actual crossover)
   if(rsi_two_bars_ago <= RSI_Oversold && rsi_prev > RSI_Oversold && buySlopeOk)
   {
      OpenBuyPosition();
   }
   
   // Sell signal: RSI crosses from overbought to below overbought (checking the actual crossover)
   if(rsi_two_bars_ago >= RSI_Overbought && rsi_prev < RSI_Overbought && sellSlopeOk)
   {
      OpenSellPosition();
   }
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI Scalping Buy"))
   {
      position_ticket = trade.ResultOrder();
      position_open = true;
      current_position_type = POSITION_TYPE_BUY;
   }
}

//+------------------------------------------------------------------+
//| Open sell position                                               |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "RSI Scalping Sell"))
   {
      position_ticket = trade.ResultOrder();
      position_open = true;
      current_position_type = POSITION_TYPE_SELL;
   }
}

//+------------------------------------------------------------------+
//| Close current position                                           |
//+------------------------------------------------------------------+
void ClosePosition()
{
   if(ClosePositionByMagic(trade, _Symbol, (ulong)MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }
   if(!PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }
   Print("RSIScalpingXAUUSD: close failed (will retry on next bar). retcode=",
         trade.ResultRetcode(), " lastError=", GetLastError());
}
