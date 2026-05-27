//+------------------------------------------------------------------+
//|                                         CandleChartPattern.mq5   |
//|  Lab EA: candle patterns on signal TF + HTF confirmation.        |
//|  No SL/TP. Exit on opposite signal or adverse pattern.          |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property link      ""
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

input group "=== Market ==="
input string            InpSymbol              = "";              // empty = chart symbol
input double            InpLots                = 0.01;
input int               InpMagic               = 771001;
input int               InpSlippagePoints      = 30;
input int               InpMaxSpreadPoints     = 50;             // 0 = ignore

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES   InpSignalTF            = PERIOD_M15;      // patterns evaluated here (bar 1 = last closed)
input ENUM_TIMEFRAMES   InpConfirmTF           = PERIOD_H1;       // must be >= InpSignalTF for stable bias (not enforced)

input group "=== Patterns (signal TF, shift 1) ==="
input bool              InpUseEngulfing        = true;
input bool              InpUseHammerPin        = true;
input double            InpMinBodyPoints      = 5.0;             // min body size for engulfing (points)
input double            InpHammerWickRatio    = 2.0;             // shadow >= ratio * body for hammer/pin

input group "=== HTF confirmation ==="
input bool              InpRequireHtfCandleDir = true;            // HTF last closed bar same direction as trade idea
input bool              InpRequireHtfPattern   = false;           // if true, same pattern class must also print on HTF bar 1

input group "=== Behaviour ==="
input bool              InpOnlyOnePosition     = true;
input bool              InpCloseOnReverseSignal = true;          // close long if validated short setup appears (and vice versa)
input bool              InpCloseOnAdversePattern = true;         // close long on bearish engulf / bear pin on signal or HTF

CTrade g_trade;
string g_sym;
datetime g_lastSignalBarTime = 0;

ENUM_ORDER_TYPE_FILLING ResolveFilling(const string sym)
{
   const long mask = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mask & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((mask & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

bool SpreadOk(const string sym)
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   const double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0)
      return false;
   const double spreadPts = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID)) / point;
   return (spreadPts <= (double)InpMaxSpreadPoints);
}

bool IsNewSignalBar()
{
   const datetime t = iTime(g_sym, InpSignalTF, 0);
   if(t <= 0)
      return false;
   if(t == g_lastSignalBarTime)
      return false;
   g_lastSignalBarTime = t;
   return true;
}

double BodyPoints(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   const double o = iOpen(s, tf, sh);
   const double c = iClose(s, tf, sh);
   const double point = SymbolInfoDouble(s, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;
   return MathAbs(c - o) / point;
}

bool BullishEngulfing(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   if(!InpUseEngulfing)
      return false;
   const double o1 = iOpen(s, tf, sh);
   const double c1 = iClose(s, tf, sh);
   const double o2 = iOpen(s, tf, sh + 1);
   const double c2 = iClose(s, tf, sh + 1);
   if(c2 >= o2)
      return false;
   if(c1 <= o1)
      return false;
   if(BodyPoints(s, tf, sh) < InpMinBodyPoints || BodyPoints(s, tf, sh + 1) < InpMinBodyPoints)
      return false;
   return (o1 <= c2 && c1 >= o2);
}

bool BearishEngulfing(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   if(!InpUseEngulfing)
      return false;
   const double o1 = iOpen(s, tf, sh);
   const double c1 = iClose(s, tf, sh);
   const double o2 = iOpen(s, tf, sh + 1);
   const double c2 = iClose(s, tf, sh + 1);
   if(c2 <= o2)
      return false;
   if(c1 >= o1)
      return false;
   if(BodyPoints(s, tf, sh) < InpMinBodyPoints || BodyPoints(s, tf, sh + 1) < InpMinBodyPoints)
      return false;
   return (o1 >= c2 && c1 <= o2);
}

bool BullishHammer(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   if(!InpUseHammerPin)
      return false;
   const double o = iOpen(s, tf, sh);
   const double c = iClose(s, tf, sh);
   const double h = iHigh(s, tf, sh);
   const double l = iLow(s, tf, sh);
   const double body = MathAbs(c - o);
   const double lower = MathMin(o, c) - l;
   const double upper = h - MathMax(o, c);
   const double point = SymbolInfoDouble(s, SYMBOL_POINT);
   if(point <= 0.0 || body < point * 0.1)
      return false;
   return (lower >= InpHammerWickRatio * body && upper <= body);
}

bool BearishPinBar(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   if(!InpUseHammerPin)
      return false;
   const double o = iOpen(s, tf, sh);
   const double c = iClose(s, tf, sh);
   const double h = iHigh(s, tf, sh);
   const double l = iLow(s, tf, sh);
   const double body = MathAbs(c - o);
   const double lower = MathMin(o, c) - l;
   const double upper = h - MathMax(o, c);
   const double point = SymbolInfoDouble(s, SYMBOL_POINT);
   if(point <= 0.0 || body < point * 0.1)
      return false;
   return (upper >= InpHammerWickRatio * body && lower <= body);
}

bool BullishPatternBar(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   return BullishEngulfing(s, tf, sh) || BullishHammer(s, tf, sh);
}

bool BearishPatternBar(const string s, const ENUM_TIMEFRAMES tf, const int sh)
{
   return BearishEngulfing(s, tf, sh) || BearishPinBar(s, tf, sh);
}

bool HtfBullishClosedBar(const string s, const ENUM_TIMEFRAMES htf)
{
   return (iClose(s, htf, 1) > iOpen(s, htf, 1));
}

bool HtfBearishClosedBar(const string s, const ENUM_TIMEFRAMES htf)
{
   return (iClose(s, htf, 1) < iOpen(s, htf, 1));
}

bool ConfirmLong(const string s)
{
   if(!InpRequireHtfCandleDir && !InpRequireHtfPattern)
      return true;

   if(InpRequireHtfCandleDir && !HtfBullishClosedBar(s, InpConfirmTF))
      return false;

   if(InpRequireHtfPattern && !BullishPatternBar(s, InpConfirmTF, 1))
      return false;

   return true;
}

bool ConfirmShort(const string s)
{
   if(!InpRequireHtfCandleDir && !InpRequireHtfPattern)
      return true;

   if(InpRequireHtfCandleDir && !HtfBearishClosedBar(s, InpConfirmTF))
      return false;

   if(InpRequireHtfPattern && !BearishPatternBar(s, InpConfirmTF, 1))
      return false;

   return true;
}

bool ValidatedLongSetup(const string s)
{
   if(!BullishPatternBar(s, InpSignalTF, 1))
      return false;
   return ConfirmLong(s);
}

bool ValidatedShortSetup(const string s)
{
   if(!BearishPatternBar(s, InpSignalTF, 1))
      return false;
   return ConfirmShort(s);
}

bool HasOurPosition(const string s, const int magic, int &dir)
{
   dir = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != s)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      const long typ = PositionGetInteger(POSITION_TYPE);
      dir = (typ == POSITION_TYPE_BUY) ? 0 : 1;
      return true;
   }
   return false;
}

bool CloseOurPositions(const string s, const int magic)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != s)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(!g_trade.PositionClose(ticket))
         ok = false;
   }
   return ok;
}

int OnInit()
{
   g_sym = (StringLen(InpSymbol) == 0) ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_sym, true))
   {
      Print("SymbolSelect failed: ", g_sym);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(ResolveFilling(g_sym));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   if(!IsNewSignalBar())
      return;

   if(Bars(g_sym, InpSignalTF) < 5 || Bars(g_sym, InpConfirmTF) < 5)
      return;

   if(!SpreadOk(g_sym))
      return;

   const bool longSetup = ValidatedLongSetup(g_sym);
   const bool shortSetup = ValidatedShortSetup(g_sym);

   int dir = -1;
   bool has = HasOurPosition(g_sym, InpMagic, dir);

   if(has)
   {
      if(dir == 0)
      {
         bool adverse = false;
         if(InpCloseOnAdversePattern)
         {
            if(BearishPatternBar(g_sym, InpSignalTF, 1) || BearishPatternBar(g_sym, InpConfirmTF, 1))
               adverse = true;
         }
         const bool reverse = (InpCloseOnReverseSignal && shortSetup);
         if(adverse || reverse)
            CloseOurPositions(g_sym, InpMagic);
      }
      else if(dir == 1)
      {
         bool adverse = false;
         if(InpCloseOnAdversePattern)
         {
            if(BullishPatternBar(g_sym, InpSignalTF, 1) || BullishPatternBar(g_sym, InpConfirmTF, 1))
               adverse = true;
         }
         const bool reverse = (InpCloseOnReverseSignal && longSetup);
         if(adverse || reverse)
            CloseOurPositions(g_sym, InpMagic);
      }
   }

   has = HasOurPosition(g_sym, InpMagic, dir);

   if(InpOnlyOnePosition && has)
      return;

   if(longSetup && !shortSetup)
   {
      const double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      g_trade.Buy(InpLots, g_sym, ask, 0.0, 0.0, "CandlePattern long");
   }
   else if(shortSetup && !longSetup)
   {
      const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
      g_trade.Sell(InpLots, g_sym, bid, 0.0, 0.0, "CandlePattern short");
   }
}
