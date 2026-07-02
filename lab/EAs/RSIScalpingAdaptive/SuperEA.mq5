//+------------------------------------------------------------------+
//|                                              RSIScalpingSuper.mq5 |
//|  Multi-symbol RSI Scalping portfolio (H1, MT5-optimized params)  |
//+------------------------------------------------------------------+
#property copyright "Frontline"
#property version   "1.00"
#property description "RSI Scalping Super EA — EURUSD GBPUSD USDJPY AUDUSD USDCHF USDCAD NZDUSD EURJPY XAUUSD"

#include <Trade\Trade.mqh>
#include "MagicNumberHelpers.mqh"
#include "RSIScalpingSuperParams.mqh"

input group "=== Portfolio ==="
input double          LotMultiplier      = 1.0;
input bool            ScaleLotsToDeposit = true;
input double          ReferenceDeposit   = 10000.0;
input int             Slippage           = 3;
input int             MaxOpenPositions   = 9;

input group "=== Slot toggles ==="
input bool Enable_EURUSD = true;
input bool Enable_GBPUSD = true;
input bool Enable_USDJPY = true;
input bool Enable_AUDUSD = true;
input bool Enable_USDCHF = true;
input bool Enable_USDCAD = true;
input bool Enable_NZDUSD = true;
input bool Enable_EURJPY = true;
input bool Enable_XAUUSD = true;

#define RS_TF PERIOD_H1

struct RSSymCtx
{
   string       name;
   RSSlotParams p;
   int          magic;
   bool         enabled;
   int          rsiHandle;
   datetime     lastBar;
   bool         posOpen;
   ulong        posTicket;
   ENUM_POSITION_TYPE posType;
   bool         rsiAgainst;
   int          barsAgainst;
};

CTrade   g_trade;
RSSymCtx g_ctx[RS_SUPER_SLOT_COUNT];
int      g_count = 0;

//+------------------------------------------------------------------+
bool SlotEnabled(const int idx)
{
   switch(idx)
   {
      case 0: return Enable_EURUSD;
      case 1: return Enable_GBPUSD;
      case 2: return Enable_USDJPY;
      case 3: return Enable_AUDUSD;
      case 4: return Enable_USDCHF;
      case 5: return Enable_USDCAD;
      case 6: return Enable_NZDUSD;
      case 7: return Enable_EURJPY;
      case 8: return Enable_XAUUSD;
   }
   return true;
}

//+------------------------------------------------------------------+
double CalcLot(const string sym, const double baseLot)
{
   double lot = baseLot * LotMultiplier;
   if(ScaleLotsToDeposit && ReferenceDeposit > 0)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      lot *= bal / ReferenceDeposit;
   }
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step > 0)
      lot = MathFloor(lot / step) * step;
   if(lot < minL) lot = minL;
   if(lot > maxL) lot = maxL;
   return lot;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(mg >= (ulong)RS_SUPER_MAGIC_BASE && mg < (ulong)(RS_SUPER_MAGIC_BASE + RS_SUPER_SLOT_COUNT + 1))
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
bool UpdateRsi(RSSymCtx &c, double &cur, double &prev, double &two)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(c.rsiHandle, 0, 0, 3, buf) < 3)
      return false;
   cur = buf[0];
   prev = buf[1];
   two = buf[2];
   return true;
}

//+------------------------------------------------------------------+
void SyncPosition(RSSymCtx &c)
{
   if(!PositionExistsByMagic(c.name, c.magic))
   {
      c.posOpen = false;
      c.posTicket = 0;
      c.rsiAgainst = false;
      c.barsAgainst = 0;
      return;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != c.name) continue;
      if(PositionGetInteger(POSITION_MAGIC) != c.magic) continue;
      c.posTicket = t;
      c.posOpen = true;
      c.posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return;
   }
}

//+------------------------------------------------------------------+
void CloseSlot(RSSymCtx &c)
{
   g_trade.SetExpertMagicNumber(c.magic);
   ClosePositionByMagic(g_trade, c.name, c.magic);
   c.posOpen = false;
   c.posTicket = 0;
   c.rsiAgainst = false;
   c.barsAgainst = 0;
}

//+------------------------------------------------------------------+
void OpenBuy(RSSymCtx &c)
{
   if(CountOurPositions() >= MaxOpenPositions) return;
   if(PositionExistsByMagic(c.name, c.magic)) return;
   g_trade.SetExpertMagicNumber(c.magic);
   double ask = SymbolInfoDouble(c.name, SYMBOL_ASK);
   double lot = CalcLot(c.name, c.p.lotSize);
   if(g_trade.Buy(lot, c.name, ask, 0, 0, "RS Super Buy"))
   {
      ulong t = g_trade.ResultOrder();
      if(t > 0 && PositionSelectByTicketSymbolAndMagic(t, c.name, c.magic))
      {
         c.posTicket = t;
         c.posOpen = true;
         c.posType = POSITION_TYPE_BUY;
         c.rsiAgainst = false;
         c.barsAgainst = 0;
      }
   }
}

//+------------------------------------------------------------------+
void OpenSell(RSSymCtx &c)
{
   if(CountOurPositions() >= MaxOpenPositions) return;
   if(PositionExistsByMagic(c.name, c.magic)) return;
   g_trade.SetExpertMagicNumber(c.magic);
   double bid = SymbolInfoDouble(c.name, SYMBOL_BID);
   double lot = CalcLot(c.name, c.p.lotSize);
   if(g_trade.Sell(lot, c.name, bid, 0, 0, "RS Super Sell"))
   {
      ulong t = g_trade.ResultOrder();
      if(t > 0 && PositionSelectByTicketSymbolAndMagic(t, c.name, c.magic))
      {
         c.posTicket = t;
         c.posOpen = true;
         c.posType = POSITION_TYPE_SELL;
         c.rsiAgainst = false;
         c.barsAgainst = 0;
      }
   }
}

//+------------------------------------------------------------------+
void ManageExit(RSSymCtx &c, const double cur)
{
   if(!c.posOpen)
      SyncPosition(c);
   if(!c.posOpen) return;

   if(!PositionSelectByTicketSymbolAndMagic(c.posTicket, c.name, c.magic))
   {
      c.posOpen = false;
      c.posTicket = 0;
      return;
   }

   if(c.posType == POSITION_TYPE_BUY)
   {
      if(cur < c.p.rsiOversold)
      {
         if(!c.rsiAgainst) { c.rsiAgainst = true; c.barsAgainst = 1; }
         else c.barsAgainst++;
         if(c.barsAgainst >= c.p.barsToWait) { CloseSlot(c); return; }
      }
      else
      {
         c.rsiAgainst = false;
         c.barsAgainst = 0;
         if(cur >= c.p.rsiTargetBuy) CloseSlot(c);
      }
   }
   else
   {
      if(cur > c.p.rsiOverbought)
      {
         if(!c.rsiAgainst) { c.rsiAgainst = true; c.barsAgainst = 1; }
         else c.barsAgainst++;
         if(c.barsAgainst >= c.p.barsToWait) { CloseSlot(c); return; }
      }
      else
      {
         c.rsiAgainst = false;
         c.barsAgainst = 0;
         if(cur <= c.p.rsiTargetSell) CloseSlot(c);
      }
   }
}

//+------------------------------------------------------------------+
void CheckEntry(RSSymCtx &c, const double prev, const double two)
{
   if(c.posOpen || PositionExistsByMagic(c.name, c.magic)) return;
   if(two <= c.p.rsiOversold && prev > c.p.rsiOversold)
      OpenBuy(c);
   if(two >= c.p.rsiOverbought && prev < c.p.rsiOverbought)
      OpenSell(c);
}

//+------------------------------------------------------------------+
void ProcessSlot(RSSymCtx &c)
{
   if(!c.enabled) return;
   if(!SymbolSelect(c.name, true)) return;
   if(Bars(c.name, RS_TF) < c.p.rsiPeriod + 2) return;

   datetime bt = iTime(c.name, RS_TF, 0);
   if(bt <= 0 || bt == c.lastBar) return;
   c.lastBar = bt;

   double cur, prev, two;
   if(!UpdateRsi(c, cur, prev, two)) return;

   ManageExit(c, cur);
   if(!c.posOpen)
      CheckEntry(c, prev, two);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_count = 0;

   for(int i = 0; i < RS_SUPER_SLOT_COUNT; i++)
   {
      const RSSlotConfig cfg = RS_SUPER_SLOTS[i];
      RSSymCtx c;
      c.name = cfg.symbol;
      c.p = cfg.p;
      c.magic = cfg.magic;
      c.enabled = cfg.enabled && SlotEnabled(i);
      c.rsiHandle = INVALID_HANDLE;
      c.lastBar = 0;
      c.posOpen = false;
      c.posTicket = 0;
      c.rsiAgainst = false;
      c.barsAgainst = 0;

      if(c.enabled)
      {
         SymbolSelect(c.name, true);
         c.rsiHandle = iRSI(c.name, RS_TF, c.p.rsiPeriod, PRICE_CLOSE);
         if(c.rsiHandle == INVALID_HANDLE)
         {
            Print("Failed RSI handle for ", c.name);
            c.enabled = false;
         }
         SyncPosition(c);
      }
      g_ctx[g_count] = c;
      g_count++;
   }

   Print("RSIScalpingSuper initialized slots=", g_count);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   for(int i = 0; i < g_count; i++)
      if(g_ctx[i].rsiHandle != INVALID_HANDLE)
         IndicatorRelease(g_ctx[i].rsiHandle);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   string status = "RSIScalpingSuper\n";
   for(int i = 0; i < g_count; i++)
   {
      ProcessSlot(g_ctx[i]);
      if(g_ctx[i].enabled)
         status += StringFormat("%s %s | ", g_ctx[i].name, g_ctx[i].posOpen ? "IN" : "--");
   }
   Comment(status);
}
