//+------------------------------------------------------------------+
//| SimpleEMA v5 — trend-leg cross + pullback                          |
//+------------------------------------------------------------------+
#property copyright "lab/SimpleEMA"
#property version   "5.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Symbol / TF ==="
input ENUM_TIMEFRAMES Timeframe      = PERIOD_M15;
input int             MagicNumber    = 20260620;

input group "=== EMA / entry ==="
input int             FastEmaPeriod  = 11;
input int             SlowEmaPeriod  = 34;
input int             TrendLegBars   = 56;
input double          MinEmaGapPips  = 1.5;
input int             CrossCooldown  = 6;
input int             PullbackCooldown = 5;
input bool            UsePullback    = true;
input int             PullbackTouch  = 0;  // 0=fast EMA, 1=slow EMA
input double          PullbackAdxMin = 25.0;
input double          PullbackMinGapPips = 2.9;
input int             MaxPullbacksPerLeg = 1;

input group "=== Risk ==="
input double          LotSize        = 0.10;
input int             AtrPeriod      = 14;
input double          AtrSlMult      = 2.54;
input double          AtrTpMult      = 4.84;
input int             MaxBarsInTrade = 80;

input group "=== Filters ==="
input int             HtfEmaPeriod   = 100;
input bool            UseHtfFilter   = true;
input bool            UseAdxFilter   = false;
input int             AdxPeriod      = 14;
input double          AdxMin         = 18.0;

input group "=== Session ==="
input int             SessionStartHour = 8;
input int             SessionEndHour   = 22;
input int             MaxSpreadPips  = 6;
input bool            OneTradeOnly   = true;

CTrade   g_trade;
int      g_fastHandle = INVALID_HANDLE;
int      g_slowHandle = INVALID_HANDLE;
int      g_atrHandle  = INVALID_HANDLE;
int      g_adxHandle  = INVALID_HANDLE;
int      g_htfHandle  = INVALID_HANDLE;
datetime g_lastBar    = 0;
int      g_lastCrossBar = -100000;
int      g_lastPbBar  = -100000;
int      g_legPbCount = 0;
int      g_activeLeg  = 0;
int      g_lastBullCrossBar = -100000;
int      g_lastBearCrossBar = -100000;

double PipSize()
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (d == 3 || d == 5) ? pt * 10.0 : pt;
}

int SpreadPips()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 9999;
   return (int)MathRound((ask - bid) / PipSize());
}

bool InSession()
{
   if(SessionStartHour <= 0 && SessionEndHour >= 24) return true;
   MqlDateTime ts; TimeToStruct(TimeCurrent(), ts);
   if(SessionStartHour < SessionEndHour)
      return (ts.hour >= SessionStartHour && ts.hour < SessionEndHour);
   return (ts.hour >= SessionStartHour || ts.hour < SessionEndHour);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, Timeframe, 0);
   if(t <= 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
}

bool Copy1(const int h, const int sh, const int buf, double &v)
{
   double b[1];
   if(CopyBuffer(h, buf, sh, 1, b) <= 0) return false;
   v = b[0]; return true;
}

bool HasOurPosition()
{
   return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber;
}

void CloseOur(const string reason)
{
   if(!HasOurPosition()) return;
   if(g_trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET)))
      Print("[SimpleEMA v5] close ", reason);
}

bool BullCross(const int sh)
{
   double f1,f2,s1,s2;
   if(!Copy1(g_fastHandle, sh, 0, f1) || !Copy1(g_fastHandle, sh+1, 0, f2)) return false;
   if(!Copy1(g_slowHandle, sh, 0, s1) || !Copy1(g_slowHandle, sh+1, 0, s2)) return false;
   return (f2 <= s2 && f1 > s1);
}

bool BearCross(const int sh)
{
   double f1,f2,s1,s2;
   if(!Copy1(g_fastHandle, sh, 0, f1) || !Copy1(g_fastHandle, sh+1, 0, f2)) return false;
   if(!Copy1(g_slowHandle, sh, 0, s1) || !Copy1(g_slowHandle, sh+1, 0, s2)) return false;
   return (f2 >= s2 && f1 < s1);
}

bool InLongLeg(const int barIndex)
{
   if(g_lastBullCrossBar < 0 || g_lastBullCrossBar <= g_lastBearCrossBar) return false;
   return (barIndex - g_lastBullCrossBar <= TrendLegBars);
}

bool InShortLeg(const int barIndex)
{
   if(g_lastBearCrossBar < 0 || g_lastBearCrossBar <= g_lastBullCrossBar) return false;
   return (barIndex - g_lastBearCrossBar <= TrendLegBars);
}

bool PullbackFiltersOk(const bool isLong, const int sh)
{
   double gapPips = PullbackMinGapPips > 0 ? PullbackMinGapPips : MinEmaGapPips;
   double f,s,adx;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   if(MathAbs(f - s) / PipSize() < gapPips) return false;
   if(PullbackAdxMin > 0)
   {
      if(!Copy1(g_adxHandle, sh, 0, adx)) return false;
      if(adx < PullbackAdxMin) return false;
   }
   return BaseFiltersOk(isLong, sh, 0);
}

bool BaseFiltersOk(const bool isLong, const int sh, const double atrPips)
{
   double f,s,close,htf,adx;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   close = iClose(_Symbol, Timeframe, sh);
   if(MathAbs(f - s) / PipSize() < MinEmaGapPips) return false;
   if(isLong && f <= s) return false;
   if(!isLong && f >= s) return false;

   if(UseHtfFilter)
   {
      if(!Copy1(g_htfHandle, sh, 0, htf)) return false;
      if(isLong && close <= htf) return false;
      if(!isLong && close >= htf) return false;
   }
   if(UseAdxFilter)
   {
      if(!Copy1(g_adxHandle, sh, 0, adx)) return false;
      if(adx < AdxMin) return false;
   }
   return true;
}

bool PullbackLong(const int sh)
{
   double touch, close, low;
   if(PullbackTouch == 0)
   {
      if(!Copy1(g_fastHandle, sh, 0, touch)) return false;
   }
   else
   {
      if(!Copy1(g_slowHandle, sh, 0, touch)) return false;
   }
   close = iClose(_Symbol, Timeframe, sh);
   low   = iLow(_Symbol, Timeframe, sh);
   return (low <= touch && close > touch);
}

bool PullbackShort(const int sh)
{
   double touch, close, high;
   if(PullbackTouch == 0)
   {
      if(!Copy1(g_fastHandle, sh, 0, touch)) return false;
   }
   else
   {
      if(!Copy1(g_slowHandle, sh, 0, touch)) return false;
   }
   close = iClose(_Symbol, Timeframe, sh);
   high  = iHigh(_Symbol, Timeframe, sh);
   return (high >= touch && close < touch);
}

bool OpenTrade(const ENUM_ORDER_TYPE type, const double atr, const int barIndex, const bool isCross)
{
   if(OneTradeOnly && HasOurPosition()) return false;
   if(MaxSpreadPips > 0 && SpreadPips() > MaxSpreadPips) return false;
   if(!InSession()) return false;
   if(atr <= 0) return false;

   if(isCross)
   {
      if(barIndex - g_lastCrossBar < CrossCooldown) return false;
   }
   else
   {
      if(barIndex - g_lastPbBar < PullbackCooldown) return false;
   }

   double slDist = atr * AtrSlMult;
   double tpDist = atr * AtrTpMult;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(20);

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = g_trade.Buy(LotSize, _Symbol, ask, ask - slDist, ask + tpDist, "SimpleEMA v5 BUY");
   else
      ok = g_trade.Sell(LotSize, _Symbol, bid, bid + slDist, bid - tpDist, "SimpleEMA v5 SELL");

   if(ok)
   {
      if(isCross) g_lastCrossBar = barIndex;
      else g_lastPbBar = barIndex;
   }
   return ok;
}

void ManagePosition()
{
   if(!HasOurPosition()) return;
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int barsHeld = iBarShift(_Symbol, Timeframe, openTime, true);
   if(MaxBarsInTrade > 0 && barsHeld >= MaxBarsInTrade)
      CloseOur("max_bars");
}

int OnInit()
{
   if(FastEmaPeriod >= SlowEmaPeriod) return INIT_PARAMETERS_INCORRECT;
   g_fastHandle = iMA(_Symbol, Timeframe, FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowHandle = iMA(_Symbol, Timeframe, SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle  = iATR(_Symbol, Timeframe, AtrPeriod);
   g_adxHandle  = iADX(_Symbol, Timeframe, AdxPeriod);
   g_htfHandle  = iMA(_Symbol, PERIOD_H4, HtfEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   g_trade.SetExpertMagicNumber(MagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
   if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);
   if(g_atrHandle  != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_adxHandle  != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_htfHandle  != INVALID_HANDLE) IndicatorRelease(g_htfHandle);
}

void OnTick()
{
   ManagePosition();
   if(!IsNewBar()) return;

   int barIndex = iBars(_Symbol, Timeframe);
   double atr1;
   if(!Copy1(g_atrHandle, 1, 0, atr1)) return;
   double atrPips = atr1 / PipSize();

   if(BullCross(1))
   {
      g_lastBullCrossBar = barIndex;
      g_activeLeg = 1;
      g_legPbCount = 0;
   }
   if(BearCross(1))
   {
      g_lastBearCrossBar = barIndex;
      g_activeLeg = -1;
      g_legPbCount = 0;
   }

   if(HasOurPosition()) return;

   if(BullCross(1) && BaseFiltersOk(true, 1, atrPips))
      OpenTrade(ORDER_TYPE_BUY, atr1, barIndex, true);
   else if(BearCross(1) && BaseFiltersOk(false, 1, atrPips))
      OpenTrade(ORDER_TYPE_SELL, atr1, barIndex, true);
   else if(UsePullback && InLongLeg(barIndex) && g_activeLeg == 1 && g_legPbCount < MaxPullbacksPerLeg
           && !BullCross(1) && PullbackLong(1) && PullbackFiltersOk(true, 1))
   {
      if(OpenTrade(ORDER_TYPE_BUY, atr1, barIndex, false))
         g_legPbCount++;
   }
   else if(UsePullback && InShortLeg(barIndex) && g_activeLeg == -1 && g_legPbCount < MaxPullbacksPerLeg
            && !BearCross(1) && PullbackShort(1) && PullbackFiltersOk(false, 1))
   {
      if(OpenTrade(ORDER_TYPE_SELL, atr1, barIndex, false))
         g_legPbCount++;
   }
}
