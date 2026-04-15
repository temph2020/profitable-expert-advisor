//+------------------------------------------------------------------+
//|                                   RSIScalpingXAUUSD_Trailing.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.06"

#include <Trade\Trade.mqh>
#include "../_united/MagicNumberHelpers.mqh"

//--- Input parameters
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1; // Timeframe for Analysis
input int                  RSI_Period = 14;           // RSI Period
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE; // RSI Applied Price
input double              RSI_Overbought = 71;        // RSI Overbought Level
input double              RSI_Oversold = 57;          // RSI Oversold Level
input double              RSI_Target_Buy = 80;         // RSI Target for Buy Exit
input double              RSI_Target_Sell = 57;        // RSI Target for Sell Exit
input int                 BarsToWait = 4;             // Bars to wait when RSI goes against position
input bool                UseRSI_StopLoss = true;     // Close on RSI stop (separate timeframe below)
input ENUM_TIMEFRAMES      RSI_StopLoss_TimeFrame = PERIOD_H1; // RSI timeframe for stop-loss only
input double              RSI_StopLoss_BuyBelow = 30; // Close buy when stop-timeframe RSI drops below this
input double              RSI_StopLoss_SellAbove = 70; // Close sell when stop-timeframe RSI rises above this
input double              LotSize = 0.1;              // Lot Size
input int                 MagicNumber = 129102316;        // Magic Number (distinct from non-trailing EA)
input int                 Slippage = 3;               // Slippage in points

//--- Global variables
CTrade trade;
int rsi_handle;
int rsi_stoploss_handle = INVALID_HANDLE;
double rsi_buffer[];
double rsi_stoploss_buffer[];
double rsi_prev, rsi_current, rsi_two_bars_ago;
double rsi_stoploss_current = 0.0;
MqlTick   rsi_stoploss_last_tick;
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
   rsi_handle = iRSI(_Symbol, TimeFrame, RSI_Period, RSI_Applied_Price);
   if(rsi_handle == INVALID_HANDLE)
   {
      return(INIT_FAILED);
   }

   rsi_stoploss_handle = iRSI(_Symbol, RSI_StopLoss_TimeFrame, RSI_Period, RSI_Applied_Price);
   if(rsi_stoploss_handle == INVALID_HANDLE)
   {
      IndicatorRelease(rsi_handle);
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   ArraySetAsSeries(rsi_buffer, true);
   ArraySetAsSeries(rsi_stoploss_buffer, true);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
   if(rsi_stoploss_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_stoploss_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ResyncPositionFromMarket();

   const int min_bars = RSI_Period + 2;
   if(position_open)
   {
      if(UseRSI_StopLoss && Bars(_Symbol, RSI_StopLoss_TimeFrame) >= min_bars)
      {
         if(UpdateRSI_StopLoss())
            CheckRSIStopLossClose();
      }
   }

   if(Bars(_Symbol, TimeFrame) < min_bars)
   {
      return;
   }

   datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   if(current_bar_time == last_bar_time)
   {
      return;
   }

   last_bar_time = current_bar_time;

   if(!UpdateRSI())
   {
      return;
   }

   ResyncPositionFromMarket();

   CheckExistingPosition();

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

   rsi_current = rsi_buffer[0];
   rsi_prev = rsi_buffer[1];
   rsi_two_bars_ago = rsi_buffer[2];

   return true;
}

//+------------------------------------------------------------------+
//| Stop-loss RSI (RSI_StopLoss_TimeFrame)                           |
//| Uses latest MqlTick before CopyBuffer so RSI matches current quote. |
//+------------------------------------------------------------------+
bool UpdateRSI_StopLoss()
{
   if(rsi_stoploss_handle == INVALID_HANDLE)
      return false;
   if(!SymbolInfoTick(_Symbol, rsi_stoploss_last_tick))
      return false;

   int calc = BarsCalculated(rsi_stoploss_handle);
   if(calc <= 0)
      return false;

   if(CopyBuffer(rsi_stoploss_handle, 0, 0, 1, rsi_stoploss_buffer) < 1)
      return false;
   rsi_stoploss_current = rsi_stoploss_buffer[0];
   return true;
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
//| RSI-based stop: RSI_StopLoss_TimeFrame series (independent of TimeFrame) |
//+------------------------------------------------------------------+
void CheckRSIStopLossClose()
{
   if(!UseRSI_StopLoss || !position_open)
      return;

   if(!PositionSelectByTicketAndMagic(position_ticket, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }

   if(current_position_type == POSITION_TYPE_BUY)
   {
      if(rsi_stoploss_current < RSI_StopLoss_BuyBelow)
         ClosePosition();
   }
   else if(current_position_type == POSITION_TYPE_SELL)
   {
      if(rsi_stoploss_current > RSI_StopLoss_SellAbove)
         ClosePosition();
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

   if(!PositionSelectByTicketAndMagic(position_ticket, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }

   if(current_position_type == POSITION_TYPE_BUY)
   {
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

         if(bars_against_count >= BarsToWait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }

         if(rsi_current >= RSI_Target_Buy)
         {
            ClosePosition();
         }
      }
   }
   else if(current_position_type == POSITION_TYPE_SELL)
   {
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

         if(bars_against_count >= BarsToWait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }

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
   if(rsi_two_bars_ago <= RSI_Oversold && rsi_prev > RSI_Oversold)
      OpenBuyPosition();

   if(rsi_two_bars_ago >= RSI_Overbought && rsi_prev < RSI_Overbought)
      OpenSellPosition();
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI Scalping Buy"))
   {
      ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      if(t != 0)
         position_ticket = (int)t;
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
      ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      if(t != 0)
         position_ticket = (int)t;
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
