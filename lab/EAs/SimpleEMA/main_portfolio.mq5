//+------------------------------------------------------------------+
//| SimpleEMA v5 Portfolio — multi-symbol trend-leg engine             |
//+------------------------------------------------------------------+
#property copyright "lab/SimpleEMA"
#property version   "5.10"
#property strict

#include <Trade/Trade.mqh>

input group "=== Portfolio ==="
input string          SymbolList       = "EURUSD,GBPUSD,USDJPY,USDCHF,USDCAD,AUDUSD,NZDUSD,EURGBP,EURJPY,GBPJPY,EURAUD,EURNZD,AUDJPY,CADJPY,CHFJPY,GBPAUD,GBPCAD,AUDNZD,XAUUSD,XAGUSD";
input ENUM_TIMEFRAMES Timeframe        = PERIOD_M15;
input int             MagicNumber      = 20260620;

input group "=== EMA / entry ==="
input int             FastEmaPeriod    = 11;
input int             SlowEmaPeriod    = 34;
input int             TrendLegBars     = 56;
input double          MinEmaGapPips    = 1.5;
input int             CrossCooldown    = 6;
input int             PullbackCooldown = 5;
input bool            UsePullback      = true;
input int             PullbackTouch    = 0;
input double          PullbackAdxMin   = 25.0;
input double          PullbackMinGapPips = 2.9;
input int             MaxPullbacksPerLeg = 1;

input group "=== Risk ==="
input double          LotSize          = 0.05;
input int             AtrPeriod        = 14;
input double          AtrSlMult        = 2.54;
input double          AtrTpMult        = 4.84;
input int             MaxBarsInTrade   = 80;

input group "=== Filters ==="
input int             HtfEmaPeriod     = 100;
input bool            UseHtfFilter     = true;
input bool            UseAdxFilter     = false;
input int             AdxPeriod        = 14;
input double          AdxMin           = 18.0;

input group "=== Session ==="
input int             SessionStartHour = 8;
input int             SessionEndHour   = 22;
input int             MaxSpreadPips    = 12;
input bool            OneTradePerSymbol = true;

#define MAX_SYMS 24

struct SymCtx
{
   string   name;
   int      fastHandle;
   int      slowHandle;
   int      atrHandle;
   int      adxHandle;
   int      htfHandle;
   datetime lastBar;
   int      lastCrossBar;
   int      lastPbBar;
   int      legPbCount;
   int      activeLeg;
   int      lastBullCrossBar;
   int      lastBearCrossBar;
   int      magic;
};

CTrade   g_trade;
SymCtx   g_ctx[MAX_SYMS];
int      g_count = 0;

double PipSize(const string sym)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return (d == 3 || d == 5) ? pt * 10.0 : pt;
}

int SpreadPips(const string sym)
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 9999;
   return (int)MathRound((ask - bid) / PipSize(sym));
}

bool InSession()
{
   if(SessionStartHour <= 0 && SessionEndHour >= 24) return true;
   MqlDateTime ts; TimeToStruct(TimeCurrent(), ts);
   if(SessionStartHour < SessionEndHour)
      return (ts.hour >= SessionStartHour && ts.hour < SessionEndHour);
   return (ts.hour >= SessionStartHour || ts.hour < SessionEndHour);
}

bool Copy1(const int h, const int sh, const int buf, double &v)
{
   double b[1];
   if(CopyBuffer(h, buf, sh, 1, b) <= 0) return false;
   v = b[0]; return true;
}

bool HasOurPosition(const string sym, const int magic)
{
   return PositionSelect(sym) && PositionGetInteger(POSITION_MAGIC) == magic;
}

bool IsNewBar(SymCtx &c)
{
   datetime t = iTime(c.name, Timeframe, 0);
   if(t <= 0 || t == c.lastBar) return false;
   c.lastBar = t;
   return true;
}

bool BullCross(SymCtx &c, const int sh)
{
   double f1,f2,s1,s2;
   if(!Copy1(c.fastHandle, sh, 0, f1) || !Copy1(c.fastHandle, sh+1, 0, f2)) return false;
   if(!Copy1(c.slowHandle, sh, 0, s1) || !Copy1(c.slowHandle, sh+1, 0, s2)) return false;
   return (f2 <= s2 && f1 > s1);
}

bool BearCross(SymCtx &c, const int sh)
{
   double f1,f2,s1,s2;
   if(!Copy1(c.fastHandle, sh, 0, f1) || !Copy1(c.fastHandle, sh+1, 0, f2)) return false;
   if(!Copy1(c.slowHandle, sh, 0, s1) || !Copy1(c.slowHandle, sh+1, 0, s2)) return false;
   return (f2 >= s2 && f1 < s1);
}

bool BaseFiltersOk(SymCtx &c, const bool isLong, const int sh)
{
   double f,s,close,htf,adx;
   if(!Copy1(c.fastHandle, sh, 0, f) || !Copy1(c.slowHandle, sh, 0, s)) return false;
   close = iClose(c.name, Timeframe, sh);
   if(MathAbs(f - s) / PipSize(c.name) < MinEmaGapPips) return false;
   if(isLong && f <= s) return false;
   if(!isLong && f >= s) return false;
   if(UseHtfFilter)
   {
      if(!Copy1(c.htfHandle, sh, 0, htf)) return false;
      if(isLong && close <= htf) return false;
      if(!isLong && close >= htf) return false;
   }
   if(UseAdxFilter)
   {
      if(!Copy1(c.adxHandle, sh, 0, adx)) return false;
      if(adx < AdxMin) return false;
   }
   return true;
}

bool PullbackFiltersOk(SymCtx &c, const bool isLong, const int sh)
{
   double gapPips = PullbackMinGapPips > 0 ? PullbackMinGapPips : MinEmaGapPips;
   double f,s,adx;
   if(!Copy1(c.fastHandle, sh, 0, f) || !Copy1(c.slowHandle, sh, 0, s)) return false;
   if(MathAbs(f - s) / PipSize(c.name) < gapPips) return false;
   if(PullbackAdxMin > 0)
   {
      if(!Copy1(c.adxHandle, sh, 0, adx)) return false;
      if(adx < PullbackAdxMin) return false;
   }
   return BaseFiltersOk(c, isLong, sh);
}

bool PullbackLong(SymCtx &c, const int sh)
{
   double touch, close, low;
   if(PullbackTouch == 0) { if(!Copy1(c.fastHandle, sh, 0, touch)) return false; }
   else { if(!Copy1(c.slowHandle, sh, 0, touch)) return false; }
   close = iClose(c.name, Timeframe, sh);
   low   = iLow(c.name, Timeframe, sh);
   return (low <= touch && close > touch);
}

bool PullbackShort(SymCtx &c, const int sh)
{
   double touch, close, high;
   if(PullbackTouch == 0) { if(!Copy1(c.fastHandle, sh, 0, touch)) return false; }
   else { if(!Copy1(c.slowHandle, sh, 0, touch)) return false; }
   close = iClose(c.name, Timeframe, sh);
   high  = iHigh(c.name, Timeframe, sh);
   return (high >= touch && close < touch);
}

bool InLongLeg(SymCtx &c, const int barIndex)
{
   if(c.lastBullCrossBar < 0 || c.lastBullCrossBar <= c.lastBearCrossBar) return false;
   return (barIndex - c.lastBullCrossBar <= TrendLegBars);
}

bool InShortLeg(SymCtx &c, const int barIndex)
{
   if(c.lastBearCrossBar < 0 || c.lastBearCrossBar <= c.lastBullCrossBar) return false;
   return (barIndex - c.lastBearCrossBar <= TrendLegBars);
}

bool OpenTrade(SymCtx &c, const ENUM_ORDER_TYPE type, const double atr, const int barIndex, const bool isCross)
{
   if(OneTradePerSymbol && HasOurPosition(c.name, c.magic)) return false;
   if(MaxSpreadPips > 0 && SpreadPips(c.name) > MaxSpreadPips) return false;
   if(!InSession()) return false;
   if(atr <= 0) return false;
   if(isCross) { if(barIndex - c.lastCrossBar < CrossCooldown) return false; }
   else { if(barIndex - c.lastPbBar < PullbackCooldown) return false; }

   double slDist = atr * AtrSlMult;
   double tpDist = atr * AtrTpMult;
   double ask = SymbolInfoDouble(c.name, SYMBOL_ASK);
   double bid = SymbolInfoDouble(c.name, SYMBOL_BID);
   g_trade.SetExpertMagicNumber(c.magic);
   g_trade.SetDeviationInPoints(20);

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = g_trade.Buy(LotSize, c.name, ask, ask - slDist, ask + tpDist, "SimpleEMA pf BUY");
   else
      ok = g_trade.Sell(LotSize, c.name, bid, bid + slDist, bid - tpDist, "SimpleEMA pf SELL");

   if(ok)
   {
      if(isCross) c.lastCrossBar = barIndex;
      else c.lastPbBar = barIndex;
   }
   return ok;
}

void ManagePosition(SymCtx &c)
{
   if(!HasOurPosition(c.name, c.magic)) return;
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int barsHeld = iBarShift(c.name, Timeframe, openTime, true);
   if(MaxBarsInTrade > 0 && barsHeld >= MaxBarsInTrade)
   {
      g_trade.SetExpertMagicNumber(c.magic);
      g_trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET));
   }
}

void ProcessSymbol(SymCtx &c)
{
   ManagePosition(c);
   if(!IsNewBar(c)) return;

   int barIndex = iBars(c.name, Timeframe);
   double atr1;
   if(!Copy1(c.atrHandle, 1, 0, atr1)) return;

   if(BullCross(c, 1)) { c.lastBullCrossBar = barIndex; c.activeLeg = 1; c.legPbCount = 0; }
   if(BearCross(c, 1)) { c.lastBearCrossBar = barIndex; c.activeLeg = -1; c.legPbCount = 0; }
   if(HasOurPosition(c.name, c.magic)) return;

   if(BullCross(c, 1) && BaseFiltersOk(c, true, 1))
      OpenTrade(c, ORDER_TYPE_BUY, atr1, barIndex, true);
   else if(BearCross(c, 1) && BaseFiltersOk(c, false, 1))
      OpenTrade(c, ORDER_TYPE_SELL, atr1, barIndex, true);
   else if(UsePullback && InLongLeg(c, barIndex) && c.activeLeg == 1 && c.legPbCount < MaxPullbacksPerLeg
           && !BullCross(c, 1) && PullbackLong(c, 1) && PullbackFiltersOk(c, true, 1))
   {
      if(OpenTrade(c, ORDER_TYPE_BUY, atr1, barIndex, false)) c.legPbCount++;
   }
   else if(UsePullback && InShortLeg(c, barIndex) && c.activeLeg == -1 && c.legPbCount < MaxPullbacksPerLeg
            && !BearCross(c, 1) && PullbackShort(c, 1) && PullbackFiltersOk(c, false, 1))
   {
      if(OpenTrade(c, ORDER_TYPE_SELL, atr1, barIndex, false)) c.legPbCount++;
   }
}

int ParseSymbols()
{
   string parts[];
   int n = StringSplit(SymbolList, ',', parts);
   g_count = 0;
   for(int i = 0; i < n && g_count < MAX_SYMS; i++)
   {
      string sym = parts[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) == 0) continue;
      if(!SymbolSelect(sym, true))
      {
         Print("[SimpleEMA pf] skip unavailable: ", sym);
         continue;
      }
      g_ctx[g_count].name = sym;
      g_ctx[g_count].magic = MagicNumber + g_count;
      g_ctx[g_count].lastBar = 0;
      g_ctx[g_count].lastCrossBar = -100000;
      g_ctx[g_count].lastPbBar = -100000;
      g_ctx[g_count].legPbCount = 0;
      g_ctx[g_count].activeLeg = 0;
      g_ctx[g_count].lastBullCrossBar = -100000;
      g_ctx[g_count].lastBearCrossBar = -100000;
      g_count++;
   }
   return g_count;
}

int OnInit()
{
   if(FastEmaPeriod >= SlowEmaPeriod) return INIT_PARAMETERS_INCORRECT;
   if(ParseSymbols() <= 0) return INIT_FAILED;

   for(int i = 0; i < g_count; i++)
   {
      string sym = g_ctx[i].name;
      g_ctx[i].fastHandle = iMA(sym, Timeframe, FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_ctx[i].slowHandle = iMA(sym, Timeframe, SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_ctx[i].atrHandle  = iATR(sym, Timeframe, AtrPeriod);
      g_ctx[i].adxHandle  = iADX(sym, Timeframe, AdxPeriod);
      g_ctx[i].htfHandle  = iMA(sym, PERIOD_H4, HtfEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_ctx[i].fastHandle == INVALID_HANDLE || g_ctx[i].slowHandle == INVALID_HANDLE || g_ctx[i].atrHandle == INVALID_HANDLE)
         return INIT_FAILED;
   }
   Print("[SimpleEMA pf] loaded ", g_count, " symbols");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < g_count; i++)
   {
      if(g_ctx[i].fastHandle != INVALID_HANDLE) IndicatorRelease(g_ctx[i].fastHandle);
      if(g_ctx[i].slowHandle != INVALID_HANDLE) IndicatorRelease(g_ctx[i].slowHandle);
      if(g_ctx[i].atrHandle  != INVALID_HANDLE) IndicatorRelease(g_ctx[i].atrHandle);
      if(g_ctx[i].adxHandle  != INVALID_HANDLE) IndicatorRelease(g_ctx[i].adxHandle);
      if(g_ctx[i].htfHandle  != INVALID_HANDLE) IndicatorRelease(g_ctx[i].htfHandle);
   }
}

void OnTick()
{
   for(int i = 0; i < g_count; i++)
      ProcessSymbol(g_ctx[i]);
}
