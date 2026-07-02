//+------------------------------------------------------------------+
//|                                          MagicNumberHelpers.mqh |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
bool PositionSelectByMagic(string symbol, ulong magic_number)
{
   if(!PositionSelect(symbol))
      return false;

   if(PositionGetInteger(POSITION_MAGIC) != magic_number)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetTicket(i) > 0)
         {
            if(PositionGetString(POSITION_SYMBOL) == symbol &&
               PositionGetInteger(POSITION_MAGIC) == magic_number)
            {
               return true;
            }
         }
      }
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
bool PositionSelectByTicketSymbolAndMagic(ulong ticket, string symbol, ulong magic_number)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   return (PositionGetString(POSITION_SYMBOL) == symbol &&
           PositionGetInteger(POSITION_MAGIC) == magic_number);
}

//+------------------------------------------------------------------+
bool PositionExistsByMagic(string symbol, ulong magic_number)
{
   return PositionSelectByMagic(symbol, magic_number);
}

//+------------------------------------------------------------------+
bool ClosePositionByMagic(CTrade &trade_obj, string symbol, ulong magic_number)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == magic_number)
         {
            return trade_obj.PositionClose(ticket);
         }
      }
   }
   return false;
}
