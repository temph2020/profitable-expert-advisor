#property strict
#property version   "1.10"

#include <Trade/Trade.mqh>

input group "=== Market ==="
input string          InpSymbol                 = "BTCUSD";
input ENUM_TIMEFRAMES InpTimeframe              = PERIOD_M15;
input double          InpLots                   = 0.01;
input int             InpSlippagePoints         = 30;
input int             InpMagic                  = 910011;

input group "=== Signal ==="
input int             InpEmaPeriod              = 50;
input int             InpBodyMinPoints          = 100;
input bool            InpUseAdxFilter           = true;
input int             InpAdxPeriod              = 14;
input double          InpAdxMin                 = 18.0;

input group "=== Session Filter (Server Hour) ==="
input bool            InpUseSessionFilter       = false;
input int             InpSessionStartHour       = 6;
input int             InpSessionEndHour         = 22;

input group "=== Risk ==="
input bool            InpUseAtrStops            = true;
input int             InpAtrPeriod              = 14;
input double          InpSlAtrMult              = 1.8;
input double          InpTpAtrMult              = 3.0;
input bool            InpUseHardSL              = true;
input bool            InpUseHardTP              = false;
input bool            InpUseTrailingStop        = true;
input double          InpTrailAtrMult           = 1.2;
input bool            InpUseBreakEven           = true;
input double          InpBreakEvenAtrTrigger    = 1.0;
input double          InpBreakEvenLockPoints    = 100;
input double          InpFallbackSLPoints       = 2500;
input double          InpFallbackTPPoints       = 4500;

CTrade trade;
datetime g_lastBarTime = 0;

bool IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t <= 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
}

bool IsInAllowedSession()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   if(!TimeToStruct(TimeCurrent(), dt))
      return true;
   int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);

   // Overnight window, e.g. 22 -> 6
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

bool SelectOwnPosition(const string symbol, const int magic)
{
   if(!PositionSelect(symbol))
      return false;
   return (int)PositionGetInteger(POSITION_MAGIC) == magic;
}

double GetIndicatorValue(const int handle, const int bufferIndex, const int shift)
{
   if(handle == INVALID_HANDLE)
      return 0.0;

   double buff[1];
   if(CopyBuffer(handle, bufferIndex, shift, 1, buff) <= 0)
      return 0.0;
   return buff[0];
}

double GetAtrPoints(const string symbol, const ENUM_TIMEFRAMES tf, const int period)
{
   int hAtr = iATR(symbol, tf, period);
   double atr = GetIndicatorValue(hAtr, 0, 1);
   if(hAtr != INVALID_HANDLE)
      IndicatorRelease(hAtr);
   if(atr <= 0.0)
      return 0.0;
   return atr / _Point;
}

double GetEmaValue(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int hEma = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   double ema = GetIndicatorValue(hEma, 0, shift);
   if(hEma != INVALID_HANDLE)
      IndicatorRelease(hEma);
   return ema;
}

double GetAdxValue(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int hAdx = iADX(symbol, tf, period);
   double adx = GetIndicatorValue(hAdx, 0, shift);
   if(hAdx != INVALID_HANDLE)
      IndicatorRelease(hAdx);
   return adx;
}

void ComputeStops(const bool isBuy, const double entry, double &sl, double &tp)
{
   double slPts = InpFallbackSLPoints;
   double tpPts = InpFallbackTPPoints;

   if(InpUseAtrStops)
   {
      double atrPts = GetAtrPoints(InpSymbol, InpTimeframe, InpAtrPeriod);
      if(atrPts > 0.0)
      {
         slPts = MathMax(atrPts * InpSlAtrMult, 100.0);
         tpPts = MathMax(atrPts * InpTpAtrMult, 100.0);
      }
   }

   if(isBuy)
   {
      sl = InpUseHardSL ? (entry - slPts * _Point) : 0.0;
      tp = InpUseHardTP ? (entry + tpPts * _Point) : 0.0;
   }
   else
   {
      sl = InpUseHardSL ? (entry + slPts * _Point) : 0.0;
      tp = InpUseHardTP ? (entry - tpPts * _Point) : 0.0;
   }
}

void ManageOpenPosition()
{
   if(!SelectOwnPosition(InpSymbol, InpMagic))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);

   double atrPts = GetAtrPoints(InpSymbol, InpTimeframe, InpAtrPeriod);
   if(atrPts <= 0.0)
      atrPts = InpFallbackSLPoints;

   double triggerPts = atrPts * InpBreakEvenAtrTrigger;
   double trailPts   = MathMax(atrPts * InpTrailAtrMult, 50.0);

   double newSL = curSL;
   bool needModify = false;

   if(posType == POSITION_TYPE_BUY)
   {
      double profitPts = (tick.bid - openPrice) / _Point;

      if(InpUseBreakEven && profitPts >= triggerPts)
      {
         double beSL = openPrice + InpBreakEvenLockPoints * _Point;
         if(newSL == 0.0 || beSL > newSL)
         {
            newSL = beSL;
            needModify = true;
         }
      }

      if(InpUseTrailingStop)
      {
         double trailSL = tick.bid - trailPts * _Point;
         if((newSL == 0.0 || trailSL > newSL) && trailSL < tick.bid)
         {
            newSL = trailSL;
            needModify = true;
         }
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double profitPts = (openPrice - tick.ask) / _Point;

      if(InpUseBreakEven && profitPts >= triggerPts)
      {
         double beSL = openPrice - InpBreakEvenLockPoints * _Point;
         if(newSL == 0.0 || beSL < newSL)
         {
            newSL = beSL;
            needModify = true;
         }
      }

      if(InpUseTrailingStop)
      {
         double trailSL = tick.ask + trailPts * _Point;
         if((newSL == 0.0 || trailSL < newSL) && trailSL > tick.ask)
         {
            newSL = trailSL;
            needModify = true;
         }
      }
   }

   if(needModify)
      trade.PositionModify(InpSymbol, newSL, curTP);
}

int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("Failed to select symbol: ", InpSymbol);
      return(INIT_FAILED);
   }

   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetExpertMagicNumber(InpMagic);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(_Symbol != InpSymbol)
      return;

   ManageOpenPosition();
   if(!IsInAllowedSession())
      return;
   if(!IsNewBar(InpSymbol, InpTimeframe))
      return;

   double o1 = iOpen(InpSymbol, InpTimeframe, 1);
   double c1 = iClose(InpSymbol, InpTimeframe, 1);
   double c2 = iClose(InpSymbol, InpTimeframe, 2);
   double e1 = GetEmaValue(InpSymbol, InpTimeframe, InpEmaPeriod, 1);
   double e2 = GetEmaValue(InpSymbol, InpTimeframe, InpEmaPeriod, 2);
   if(e1 == 0.0 || e2 == 0.0)
      return;

   if(InpUseAdxFilter)
   {
      double adx = GetAdxValue(InpSymbol, InpTimeframe, InpAdxPeriod, 1);
      if(adx < InpAdxMin)
         return;
   }

   bool bullishBody = (c1 > o1) && ((c1 - o1) / _Point >= InpBodyMinPoints);
   bool bearishBody = (o1 > c1) && ((o1 - c1) / _Point >= InpBodyMinPoints);
   bool crossedUp   = (c2 <= e2 && c1 > e1);
   bool crossedDown = (c2 >= e2 && c1 < e1);

   bool longSignal  = crossedUp && bullishBody;
   bool shortSignal = crossedDown && bearishBody;

   bool hasPos = SelectOwnPosition(InpSymbol, InpMagic);
   if(hasPos)
   {
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((posType == POSITION_TYPE_BUY && shortSignal) ||
         (posType == POSITION_TYPE_SELL && longSignal))
      {
         trade.PositionClose(InpSymbol);
         hasPos = false;
      }
   }

   if(hasPos)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   double sl = 0.0, tp = 0.0;
   if(longSignal)
   {
      ComputeStops(true, tick.ask, sl, tp);
      trade.Buy(InpLots, InpSymbol, tick.ask, sl, tp, "Simple EMA PA Cross V1");
   }
   else if(shortSignal)
   {
      ComputeStops(false, tick.bid, sl, tp);
      trade.Sell(InpLots, InpSymbol, tick.bid, sl, tp, "Simple EMA PA Cross V1");
   }
}

