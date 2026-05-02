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
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_M15; // Timeframe for Analysis
input int                  RSI_Period = 8;           // RSI Period
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE; // RSI Applied Price
input double              RSI_Overbought = 36;        // RSI Overbought Level
input double              RSI_Oversold = 38;          // RSI Oversold Level
input double              RSI_Target_Buy = 90;         // RSI Target for Buy Exit
input double              RSI_Target_Sell = 70;        // RSI Target for Sell Exit
input int                 BarsToWait = 11;             // Bars RSI against (after momentum confirmed)
input int                 BarsToWait_Early = 3;        // Bars RSI against before RSI confirms favorable move
input double              RSI_Confirm_Buy = 49;        // Buy: max RSI since entry must reach this once to confirm
input double              RSI_Confirm_Sell = 29;       // Sell: min RSI since entry must reach this once to confirm
input int                 MaxBars_Unconfirmed = 1;    // If still unconfirmed after this many bars, use fastest adverse exit (0=off)
input double              StopLoss_Points = 0;        // Hard SL distance in points (0 = none)
input double              LotSize = 20;              // Lot Size
input int                 MagicNumber = 12345;        // Magic Number
input int                 Slippage = 3;               // Slippage in points

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
// Escaper: cut losers fast until trade proves RSI moved in our favor
int     bars_in_trade = 0;
double  rsi_extreme_since_entry = 0;
bool    momentum_confirmed = false;
bool    close_retry_pending = false;

//+------------------------------------------------------------------+
//| Reset escaper state (call when flat or after close)               |
//+------------------------------------------------------------------+
void ResetEscaperState()
{
   bars_in_trade = 0;
   rsi_extreme_since_entry = 0;
   momentum_confirmed = false;
   rsi_against_position = false;
   bars_against_count = 0;
   close_retry_pending = false;
}

//+------------------------------------------------------------------+
//| EA lost sync vs broker: recover tracking / retry failed closes    |
//| (must run every tick — new-bar-only logic skips session reopen)    |
//+------------------------------------------------------------------+
void TryCloseRetryAndResync()
{
   if(!position_open && PositionExistsByMagic(_Symbol, MagicNumber))
   {
      ulong tix = GetPositionTicketByMagic(_Symbol, MagicNumber);
      position_ticket = (long)tix;
      position_open = true;
      if(PositionSelectByTicket(tix))
         current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ResetEscaperState();
      Print("RSIScalpingNVDA-Escaper: resynced open position from broker.");
   }

   if(!close_retry_pending || !position_open)
      return;

   ulong ticket_retry = GetPositionTicketByMagic(_Symbol, MagicNumber);
   if(ticket_retry == 0)
   {
      ResetEscaperState();
      position_open = false;
      position_ticket = 0;
      return;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return;

   if(trade.PositionClose(ticket_retry))
   {
      ResetEscaperState();
      position_open = false;
      position_ticket = 0;
   }
}

//+------------------------------------------------------------------+
//| Adverse bars required: tight until RSI shows favorable impulse    |
//+------------------------------------------------------------------+
int AdverseBarsRequired()
{
   int need = momentum_confirmed ? BarsToWait : BarsToWait_Early;
   if(MaxBars_Unconfirmed > 0 && !momentum_confirmed && bars_in_trade >= MaxBars_Unconfirmed)
      need = MathMin(need, 1);
   return need;
}

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
   TryCloseRetryAndResync();

   // Check if we have enough bars
   if(Bars(_Symbol, TimeFrame) < RSI_Period + 2)
   {
      return;
   }
      
   // Check if this is a new bar
   datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   if(current_bar_time == last_bar_time)
   {
      return;  // Still the same bar, don't process
   }
      
   last_bar_time = current_bar_time;
   
   // Update RSI values
   if(!UpdateRSI())
   {
      return;
   }
   
   // Check for existing position
   CheckExistingPosition();
   
   // Check for new entry signals - only if no position exists for THIS EA (magic number) on THIS symbol
   if(!position_open && !PositionExistsByMagic(_Symbol, MagicNumber))
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
//| Check existing position for exit conditions                     |
//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(!position_open)
   {
      return;
   }
   
   // Check if position still exists with correct magic number AND symbol for THIS EA
   if(!PositionSelectByTicketSymbolAndMagic(position_ticket, _Symbol, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      ResetEscaperState();
      return;
   }

   bars_in_trade++;
   if(current_position_type == POSITION_TYPE_BUY)
   {
      rsi_extreme_since_entry = MathMax(rsi_extreme_since_entry, rsi_current);
      momentum_confirmed = (rsi_extreme_since_entry >= RSI_Confirm_Buy);
   }
   else
   {
      rsi_extreme_since_entry = MathMin(rsi_extreme_since_entry, rsi_current);
      momentum_confirmed = (rsi_extreme_since_entry <= RSI_Confirm_Sell);
   }
   
   // Exit conditions based on RSI target
   if(current_position_type == POSITION_TYPE_BUY)
   {
      int adverse_need = AdverseBarsRequired();
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
         
         // Close faster before RSI confirms favorable impulse; full wait after confirmation
         if(bars_against_count >= adverse_need)
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
      int adverse_need = AdverseBarsRequired();
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
         
         if(bars_against_count >= adverse_need)
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
   if(PositionExistsByMagic(_Symbol, MagicNumber))
   {
      return; // Position already exists for this EA
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = 0;
   if(StopLoss_Points > 0)
   {
      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(ask - StopLoss_Points * pt, dig);
   }
   
   if(trade.Buy(LotSize, _Symbol, ask, sl, 0, "RSI Scalping Buy"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0)
      {
         // Verify position was opened for THIS EA (magic number) on THIS symbol
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, MagicNumber))
         {
            position_ticket = new_ticket;
            position_open = true;
            current_position_type = POSITION_TYPE_BUY;
            rsi_extreme_since_entry = rsi_current;
            momentum_confirmed = (rsi_current >= RSI_Confirm_Buy);
            rsi_against_position = false;
            bars_against_count = 0;
            bars_in_trade = 0;
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
   if(PositionExistsByMagic(_Symbol, MagicNumber))
   {
      return; // Position already exists for this EA
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0;
   if(StopLoss_Points > 0)
   {
      double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(bid + StopLoss_Points * pt, dig);
   }
   
   if(trade.Sell(LotSize, _Symbol, bid, sl, 0, "RSI Scalping Sell"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0)
      {
         // Verify position was opened for THIS EA (magic number) on THIS symbol
         if(PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, MagicNumber))
         {
            position_ticket = new_ticket;
            position_open = true;
            current_position_type = POSITION_TYPE_SELL;
            rsi_extreme_since_entry = rsi_current;
            momentum_confirmed = (rsi_current <= RSI_Confirm_Sell);
            rsi_against_position = false;
            bars_against_count = 0;
            bars_in_trade = 0;
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
   ulong ticket = GetPositionTicketByMagic(_Symbol, MagicNumber);
   if(ticket == 0)
   {
      position_open = false;
      position_ticket = 0;
      ResetEscaperState();
      return;
   }

   if(!trade.PositionClose(ticket))
   {
      uint rc = trade.ResultRetcode();
      close_retry_pending = true;
      PrintFormat("RSIScalpingNVDA-Escaper: close failed retcode=%u — keeping position, will retry when session allows.", rc);
      return;
   }

   position_open = false;
   position_ticket = 0;
   ResetEscaperState();
}
