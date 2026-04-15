#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

input group "=== Market ==="
input string         InpSymbol            = "BTCUSD";
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M15;
input double         InpLots              = 0.01;
input int            InpSlippagePoints    = 30;
input int            InpMagic             = 910001;

input group "=== Signal ==="
input int            InpEmaPeriod         = 50;
input int            InpBodyMinPoints     = 100;   // Minimal candle body size

input group "=== Risk ==="
input bool           InpUseAtrStops       = true;
input int            InpAtrPeriod         = 14;
input double         InpSlAtrMult         = 1.8;
input double         InpTpAtrMult         = 3.0;
input double         InpFallbackSLPoints  = 2500;
input double         InpFallbackTPPoints  = 4500;

CTrade trade;
datetime g_lastBarTime = 0;

bool IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t <= 0)
      return false;

   if(t == g_lastBarTime)
      return false;

   g_lastBarTime = t;
   return true;
}

bool SelectOwnPosition(const string symbol, const int magic)
{
   if(!PositionSelect(symbol))
      return false;
   return (int)PositionGetInteger(POSITION_MAGIC) == magic;
}

double GetAtrPoints(const string symbol, const ENUM_TIMEFRAMES tf, const int period)
{
   int hAtr = iATR(symbol, tf, period);
   if(hAtr == INVALID_HANDLE)
      return 0.0;

   double atrBuff[1];
   if(CopyBuffer(hAtr, 0, 1, 1, atrBuff) <= 0)
   {
      IndicatorRelease(hAtr);
      return 0.0;
   }

   IndicatorRelease(hAtr);
   return atrBuff[0] / _Point;
}

double GetEmaValue(const string symbol, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int hEma = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(hEma == INVALID_HANDLE)
      return 0.0;

   double emaBuff[1];
   if(CopyBuffer(hEma, 0, shift, 1, emaBuff) <= 0)
   {
      IndicatorRelease(hEma);
      return 0.0;
   }

   IndicatorRelease(hEma);
   return emaBuff[0];
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
      sl = entry - slPts * _Point;
      tp = entry + tpPts * _Point;
   }
   else
   {
      sl = entry + slPts * _Point;
      tp = entry - tpPts * _Point;
   }
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

   if(!IsNewBar(InpSymbol, InpTimeframe))
      return;

   // Use closed candles (shift 1 and 2) to avoid intrabar repainting behavior.
   double o1 = iOpen(InpSymbol, InpTimeframe, 1);
   double c1 = iClose(InpSymbol, InpTimeframe, 1);
   double o2 = iOpen(InpSymbol, InpTimeframe, 2);
   double c2 = iClose(InpSymbol, InpTimeframe, 2);
   double e1 = GetEmaValue(InpSymbol, InpTimeframe, InpEmaPeriod, 1);
   double e2 = GetEmaValue(InpSymbol, InpTimeframe, InpEmaPeriod, 2);

   if(e1 == 0.0 || e2 == 0.0)
      return;

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
      trade.Buy(InpLots, InpSymbol, tick.ask, sl, tp, "Simple EMA PA Cross");
   }
   else if(shortSignal)
   {
      ComputeStops(false, tick.bid, sl, tp);
      trade.Sell(InpLots, InpSymbol, tick.bid, sl, tp, "Simple EMA PA Cross");
   }
}
