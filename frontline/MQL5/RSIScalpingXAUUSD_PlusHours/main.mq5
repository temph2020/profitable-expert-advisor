//+------------------------------------------------------------------+
//|                                   RSIScalpingXAUUSD_PlusHours.mq5 |
//|  Same logic as RSIScalpingXAUUSD + trading session filter         |
//|  (server time), day-of-week filter, and optional close-all when   |
//|  outside allowed hours/days                                        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "../_united/MagicNumberHelpers.mqh"

input group "=== RSI (same as RSIScalpingXAUUSD) ==="
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1;
input int                  RSI_Period = 14;
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE;
input double               RSI_Overbought = 71;
input double               RSI_Oversold = 57;
input double               RSI_Target_Buy = 80;
input double               RSI_Target_Sell = 57;
input int                  BarsToWait = 4;
input double               LotSize = 0.1;
input int                  MagicNumber = 129102317;
input int                  Slippage = 3;

input group "=== Trading hours (broker server time) ==="
input bool                 InpUseTradingHours = true;
input int                  InpTradeHourStart = 8;
input int                  InpTradeHourEnd = 22;
input bool                 InpCloseOutsideTradingHours = true;

input group "=== Trading days (broker server time) ==="
input bool                 InpUseTradingDays = true;
input bool                 InpTradeMonday = true;
input bool                 InpTradeTuesday = true;
input bool                 InpTradeWednesday = true;
input bool                 InpTradeThursday = true;
input bool                 InpTradeFriday = true;
input bool                 InpTradeSaturday = true;
input bool                 InpTradeSunday = true;
input bool                 InpCloseOutsideTradingDays = true;

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

bool IsWithinTradingHours()
{
   if(!InpUseTradingHours)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int h = dt.hour;
   const int hs = MathMax(0, MathMin(23, InpTradeHourStart));
   const int he = MathMax(0, MathMin(23, InpTradeHourEnd));

   if(hs == he)
      return true;

   if(hs < he)
      return (h >= hs && h < he);

   return (h >= hs || h < he);
}

bool IsTradingDayAllowed()
{
   if(!InpUseTradingDays)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   switch(dt.day_of_week)
   {
      case 0: return InpTradeSunday;
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      case 6: return InpTradeSaturday;
   }
   return false;
}

int OnInit()
{
   rsi_handle = iRSI(_Symbol, TimeFrame, RSI_Period, RSI_Applied_Price);
   if(rsi_handle == INVALID_HANDLE)
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   ArraySetAsSeries(rsi_buffer, true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
}

void OnTick()
{
   if(Bars(_Symbol, TimeFrame) < RSI_Period + 2)
      return;

   datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   if(current_bar_time == last_bar_time)
      return;

   last_bar_time = current_bar_time;

   if(!UpdateRSI())
      return;

   ResyncPositionFromMarket();

   const bool inHours = IsWithinTradingHours();
   const bool inDays = IsTradingDayAllowed();
   const bool inSession = inHours && inDays;

   if(position_open && !inSession &&
      ((InpUseTradingHours && InpCloseOutsideTradingHours && !inHours) ||
       (InpUseTradingDays && InpCloseOutsideTradingDays && !inDays)))
   {
      ClosePosition();
      return;
   }

   CheckExistingPosition();

   if(!position_open && !PositionExistsByMagic(_Symbol, (ulong)MagicNumber) && inSession)
      CheckEntrySignals();
}

bool UpdateRSI()
{
   if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_buffer) < 3)
      return false;

   rsi_current = rsi_buffer[0];
   rsi_prev = rsi_buffer[1];
   rsi_two_bars_ago = rsi_buffer[2];
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

void CheckExistingPosition()
{
   if(!position_open)
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
      if(rsi_current < RSI_Oversold)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
            bars_against_count++;

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
            ClosePosition();
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
            bars_against_count++;

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
            ClosePosition();
      }
   }
}

void CheckEntrySignals()
{
   if(rsi_two_bars_ago <= RSI_Oversold && rsi_prev > RSI_Oversold)
      OpenBuyPosition();

   if(rsi_two_bars_ago >= RSI_Overbought && rsi_prev < RSI_Overbought)
      OpenSellPosition();
}

void OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   trade.SetExpertMagicNumber(MagicNumber);
   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI Scalping Hours Buy"))
   {
      ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      position_ticket = (int)t;
      position_open = (position_ticket != 0);
      current_position_type = POSITION_TYPE_BUY;
      rsi_against_position = false;
      bars_against_count = 0;
   }
}

void OpenSellPosition()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   trade.SetExpertMagicNumber(MagicNumber);
   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "RSI Scalping Hours Sell"))
   {
      ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      position_ticket = (int)t;
      position_open = (position_ticket != 0);
      current_position_type = POSITION_TYPE_SELL;
      rsi_against_position = false;
      bars_against_count = 0;
   }
}

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
   Print("RSIScalpingXAUUSD_PlusHours: close failed (will retry). retcode=",
         trade.ResultRetcode(), " lastError=", GetLastError());
}
