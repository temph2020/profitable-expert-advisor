//+------------------------------------------------------------------+
//|                                                     GapGuard.mqh |
//| Gap-loss prevention: flat before session/weekend, gap-through-SL |
//+------------------------------------------------------------------+
#ifndef GAP_GUARD_MQH
#define GAP_GUARD_MQH

#include <Trade\Trade.mqh>

struct GapGuardConfig
{
   bool   enable;
   bool   closeBeforeSessionEnd;
   int    minutesBeforeClose;
   bool   closeBeforeWeekend;
   int    fridayCloseHour;
   bool   closeOnBarGapThroughSL;
   double minGapPoints;
   int    equityDailyFlatHour;
};

GapGuardConfig g_gapCfg;
ulong          g_gapMagics[];
string         g_gapSymbols[];
datetime       g_gapLastBarTime[];

//+------------------------------------------------------------------+
void GapGuard_Reset()
{
   ArrayResize(g_gapMagics, 0);
   ArrayResize(g_gapSymbols, 0);
   ArrayResize(g_gapLastBarTime, 0);
}

//+------------------------------------------------------------------+
void GapGuard_Init(const GapGuardConfig &cfg)
{
   g_gapCfg = cfg;
   GapGuard_Reset();
}

//+------------------------------------------------------------------+
void GapGuard_RegisterMagic(const ulong magic)
{
   const int n = ArraySize(g_gapMagics);
   for(int i = 0; i < n; i++)
   {
      if(g_gapMagics[i] == magic)
         return;
   }
   ArrayResize(g_gapMagics, n + 1);
   g_gapMagics[n] = magic;
}

//+------------------------------------------------------------------+
void GapGuard_RegisterSymbol(const string symbol)
{
   const int n = ArraySize(g_gapSymbols);
   for(int i = 0; i < n; i++)
   {
      if(g_gapSymbols[i] == symbol)
         return;
   }
   ArrayResize(g_gapSymbols, n + 1);
   g_gapSymbols[n] = symbol;
   ArrayResize(g_gapLastBarTime, n + 1);
   g_gapLastBarTime[n] = 0;
}

//+------------------------------------------------------------------+
int GapGuard_SymbolIndex(const string symbol)
{
   for(int i = 0; i < ArraySize(g_gapSymbols); i++)
   {
      if(g_gapSymbols[i] == symbol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
bool GapGuard_IsEAMagic(const ulong magic)
{
   for(int i = 0; i < ArraySize(g_gapMagics); i++)
   {
      if(g_gapMagics[i] == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool GapGuard_IsKnownEquityOrIndex(const string symbol)
{
   if(symbol == "AAPL" || symbol == "APPL" || symbol == "NVDA" || symbol == "TSLA"
      || symbol == "ADBE" || symbol == "MU" || symbol == "GER40" || symbol == "US500"
      || symbol == "NAS100" || symbol == "SPX500" || symbol == "UK100")
      return true;

   if(StringFind(symbol, "AAPL") == 0 || StringFind(symbol, "NVDA") == 0
      || StringFind(symbol, "TSLA") == 0 || StringFind(symbol, "ADBE") == 0
      || StringFind(symbol, ".NAS") > 0 || StringFind(symbol, ".NYS") > 0)
      return true;

   return false;
}

//+------------------------------------------------------------------+
bool GapGuard_SymbolHasSessionGaps(const string symbol)
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   datetime from = 0, to = 0;
   uint idx = 0;
   int totalSec = 0;

   while(SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)now.day_of_week, idx, from, to))
   {
      MqlDateTime f, t;
      TimeToStruct(from, f);
      TimeToStruct(to, t);
      const int fs = f.hour * 3600 + f.min * 60 + f.sec;
      const int ts = t.hour * 3600 + t.min * 60 + t.sec;
      if(ts > fs)
         totalSec += (ts - fs);
      idx++;
   }

   if(idx == 0)
      return GapGuard_IsKnownEquityOrIndex(symbol);

   return totalSec < 23 * 3600;
}

//+------------------------------------------------------------------+
bool GapGuard_IsNearSessionClose(const string symbol)
{
   if(!g_gapCfg.closeBeforeSessionEnd || g_gapCfg.minutesBeforeClose <= 0)
      return false;
   if(!GapGuard_SymbolHasSessionGaps(symbol))
      return false;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   const int nowSec = now.hour * 3600 + now.min * 60 + now.sec;

   datetime from = 0, to = 0;
   uint idx = 0;
   int lastEndSec = -1;

   while(SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)now.day_of_week, idx, from, to))
   {
      MqlDateTime tEnd;
      TimeToStruct(to, tEnd);
      const int endSec = tEnd.hour * 3600 + tEnd.min * 60 + tEnd.sec;
      if(endSec > lastEndSec)
         lastEndSec = endSec;
      idx++;
   }

   if(lastEndSec < 0)
   {
      if(GapGuard_IsKnownEquityOrIndex(symbol) && g_gapCfg.equityDailyFlatHour >= 0)
      {
         const int flatSec = g_gapCfg.equityDailyFlatHour * 3600;
         const int threshold = flatSec - g_gapCfg.minutesBeforeClose * 60;
         return (nowSec >= threshold && nowSec < flatSec);
      }
      return false;
   }

   const int threshold = lastEndSec - g_gapCfg.minutesBeforeClose * 60;
   return (nowSec >= threshold && nowSec < lastEndSec);
}

//+------------------------------------------------------------------+
bool GapGuard_IsWeekendRiskWindow()
{
   if(!g_gapCfg.closeBeforeWeekend)
      return false;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(now.day_of_week == 5 && now.hour >= g_gapCfg.fridayCloseHour)
      return true;
   if(now.day_of_week == 6 || now.day_of_week == 0)
      return true;

   return false;
}

//+------------------------------------------------------------------+
bool United_IsGapRiskWindow(const string symbol)
{
   if(!g_gapCfg.enable)
      return false;

   if(GapGuard_IsWeekendRiskWindow() && GapGuard_SymbolHasSessionGaps(symbol))
      return true;

   if(GapGuard_IsNearSessionClose(symbol))
      return true;

   return false;
}

//+------------------------------------------------------------------+
bool GapGuard_CloseEAPosition(CTrade &trade, const ulong ticket, const string reason)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   const string sym = PositionGetString(POSITION_SYMBOL);
   const ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

   if(!GapGuard_IsEAMagic(magic))
      return false;

   if(trade.PositionClose(ticket))
   {
      Print("GapGuard: closed ", sym, " ticket=", ticket, " reason=", reason);
      return true;
   }

   Print("GapGuard: failed to close ", sym, " ticket=", ticket,
         " retcode=", trade.ResultRetcode(), " reason=", reason);
   return false;
}

//+------------------------------------------------------------------+
void GapGuard_TrySessionFlat(CTrade &trade, const string symbol, const int symIdx)
{
   if(symIdx < 0)
      return;

   if(!United_IsGapRiskWindow(symbol))
      return;

   const string reason = GapGuard_IsWeekendRiskWindow() ? "weekend_flat" : "session_end_flat";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(!GapGuard_IsEAMagic((ulong)PositionGetInteger(POSITION_MAGIC)))
         continue;

      GapGuard_CloseEAPosition(trade, ticket, reason);
   }
}

//+------------------------------------------------------------------+
bool GapGuard_PositionGappedThroughSL(const string symbol, const ulong ticket)
{
   if(!g_gapCfg.closeOnBarGapThroughSL)
      return false;
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != symbol)
      return false;

   const double sl = PositionGetDouble(POSITION_SL);
   if(sl <= 0.0)
      return false;

   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   const double barOpen = iOpen(symbol, PERIOD_CURRENT, 0);
   const double prevClose = iClose(symbol, PERIOD_CURRENT, 1);
   if(barOpen <= 0.0 || prevClose <= 0.0)
      return false;

   const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double minGap = g_gapCfg.minGapPoints * point;

   if(ptype == POSITION_TYPE_BUY)
   {
      if(barOpen >= sl)
         return false;
      const double gap = prevClose - barOpen;
      if(gap < minGap)
         return false;
      return (prevClose > sl || barOpen < sl);
   }

   if(ptype == POSITION_TYPE_SELL)
   {
      if(barOpen <= sl)
         return false;
      const double gap = barOpen - prevClose;
      if(gap < minGap)
         return false;
      return (prevClose < sl || barOpen > sl);
   }

   return false;
}

//+------------------------------------------------------------------+
void GapGuard_TryGapThroughSL(CTrade &trade, const string symbol, const int symIdx)
{
   if(!g_gapCfg.closeOnBarGapThroughSL || symIdx < 0)
      return;

   const datetime barTime = iTime(symbol, PERIOD_CURRENT, 0);
   if(barTime == 0)
      return;
   if(g_gapLastBarTime[symIdx] == barTime)
      return;

   g_gapLastBarTime[symIdx] = barTime;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(!GapGuard_IsEAMagic((ulong)PositionGetInteger(POSITION_MAGIC)))
         continue;

      if(GapGuard_PositionGappedThroughSL(symbol, ticket))
         GapGuard_CloseEAPosition(trade, ticket, "gap_through_sl");
   }
}

//+------------------------------------------------------------------+
void United_ProcessGapGuard(CTrade &trade)
{
   if(!g_gapCfg.enable)
      return;

   for(int s = 0; s < ArraySize(g_gapSymbols); s++)
   {
      const string symbol = g_gapSymbols[s];
      if(!SymbolSelect(symbol, true))
         continue;

      GapGuard_TryGapThroughSL(trade, symbol, s);
      GapGuard_TrySessionFlat(trade, symbol, s);
   }
}

#endif // GAP_GUARD_MQH
