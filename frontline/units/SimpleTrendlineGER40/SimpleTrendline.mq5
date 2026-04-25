#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpHigherTF           = PERIOD_M15;  // Higher timeframe for MA/cross points
input int             InpMAPeriod           = 65;          // MA period
input ENUM_MA_METHOD  InpMAMethod           = MODE_LWMA;   // MA method
input ENUM_APPLIED_PRICE InpAppliedPrice    = PRICE_OPEN;  // MA applied price
input int             InpHTFBarsToScan      = 1200;        // HTF bars to scan for crossings
input double          InpLineTouchTolerance = 100;         // Pullback touch tolerance (points)
input double          InpBreakBuffer        = 80;          // Break confirmation buffer (points)
input double          InpLots               = 0.10;        // Position size
input long            InpMagic              = 26042501;    // Magic number
input bool            InpDrawTrendline      = true;        // Draw detected trendline

CTrade trade;

int      g_maHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;
string   g_lineName = "SimpleTrendline_Basis";

struct TrendlineModel
{
   datetime t1;
   datetime t2;
   datetime t3;
   double   p1;
   double   p2;
   double   p3;
   double   a;
   double   b;
   bool     valid;
};

bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0)
      return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

int FindRecentCrossPoints(datetime &times[], double &prices[])
{
   ArrayResize(times, 0);
   ArrayResize(prices, 0);

   if(g_maHandle == INVALID_HANDLE)
      return 0;

   int needBars = MathMax(InpHTFBarsToScan, InpMAPeriod + 20);
   MqlRates rates[];
   double maBuf[];

   int copiedRates = CopyRates(_Symbol, InpHigherTF, 0, needBars, rates);
   int copiedMa    = CopyBuffer(g_maHandle, 0, 0, needBars, maBuf);
   if(copiedRates <= 5 || copiedMa <= 5)
      return 0;

   int bars = MathMin(copiedRates, copiedMa);
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(maBuf, true);

   for(int i = 2; i < bars - 1; i++)
   {
      double d0 = rates[i].close - maBuf[i];
      double d1 = rates[i + 1].close - maBuf[i + 1];
      if(d0 == 0.0 || d1 == 0.0 || (d0 * d1 < 0.0))
      {
         int n = ArraySize(times);
         ArrayResize(times, n + 1);
         ArrayResize(prices, n + 1);
         times[n]  = rates[i].time;
         prices[n] = rates[i].close;
         if(ArraySize(times) >= 3)
            break;
      }
   }

   return ArraySize(times);
}

bool BuildTrendlineFrom3Points(TrendlineModel &m)
{
   m.valid = false;
   datetime ts[];
   double   ps[];
   int n = FindRecentCrossPoints(ts, ps);
   if(n < 3)
      return false;

   // We collected from recent to older in series order.
   // Re-map as oldest -> newest to stabilize slope direction.
   datetime tOld[3];
   double   pOld[3];
   for(int i = 0; i < 3; i++)
   {
      tOld[i] = ts[2 - i];
      pOld[i] = ps[2 - i];
   }

   long t0 = (long)tOld[0];
   double x1 = 0.0;
   double x2 = (double)((long)tOld[1] - t0);
   double x3 = (double)((long)tOld[2] - t0);
   double y1 = pOld[0];
   double y2 = pOld[1];
   double y3 = pOld[2];

   double sx  = x1 + x2 + x3;
   double sy  = y1 + y2 + y3;
   double sxx = x1 * x1 + x2 * x2 + x3 * x3;
   double sxy = x1 * y1 + x2 * y2 + x3 * y3;

   double den = 3.0 * sxx - sx * sx;
   if(MathAbs(den) < 1e-10)
      return false;

   m.a = (3.0 * sxy - sx * sy) / den;
   m.b = (sy - m.a * sx) / 3.0;

   m.t1 = tOld[0];
   m.t2 = tOld[1];
   m.t3 = tOld[2];
   m.p1 = pOld[0];
   m.p2 = pOld[1];
   m.p3 = pOld[2];
   m.valid = true;
   return true;
}

double TrendlinePriceAtTime(const TrendlineModel &m, datetime t)
{
   if(!m.valid)
      return 0.0;
   double x = (double)((long)t - (long)m.t1);
   return m.a * x + m.b;
}

void DrawTrendline(const TrendlineModel &m)
{
   if(!InpDrawTrendline || !m.valid)
      return;

   datetime tStart = m.t1;
   datetime tEnd   = iTime(_Symbol, _Period, 0);
   if(tEnd <= tStart)
      tEnd = m.t3 + PeriodSeconds(_Period) * 20;

   double pStart = TrendlinePriceAtTime(m, tStart);
   double pEnd   = TrendlinePriceAtTime(m, tEnd);

   if(ObjectFind(0, g_lineName) < 0)
      ObjectCreate(0, g_lineName, OBJ_TREND, 0, tStart, pStart, tEnd, pEnd);
   else
   {
      ObjectMove(0, g_lineName, 0, tStart, pStart);
      ObjectMove(0, g_lineName, 1, tEnd, pEnd);
   }

   ObjectSetInteger(0, g_lineName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, g_lineName, OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, g_lineName, OBJPROP_WIDTH, 2);
}

bool GetCurrentPosition(long &type, double &volume)
{
   if(!PositionSelect(_Symbol))
      return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   type   = PositionGetInteger(POSITION_TYPE);
   volume = PositionGetDouble(POSITION_VOLUME);
   return true;
}

void TryExitOnBreak(const TrendlineModel &m)
{
   long posType;
   double vol;
   if(!GetCurrentPosition(posType, vol))
      return;

   double close1 = iClose(_Symbol, _Period, 1);
   datetime t1   = iTime(_Symbol, _Period, 1);
   double line1  = TrendlinePriceAtTime(m, t1);
   double buf    = InpBreakBuffer * _Point;

   bool closePos = false;
   if(posType == POSITION_TYPE_BUY && close1 < (line1 - buf))
      closePos = true;
   if(posType == POSITION_TYPE_SELL && close1 > (line1 + buf))
      closePos = true;

   if(closePos)
      trade.PositionClose(_Symbol);
}

void TryPullbackEntry(const TrendlineModel &m)
{
   long posType;
   double vol;
   if(GetCurrentPosition(posType, vol))
      return;

   MqlRates bars1[], bars2[];
   if(CopyRates(_Symbol, _Period, 1, 1, bars1) != 1)
      return;
   if(CopyRates(_Symbol, _Period, 2, 1, bars2) != 1)
      return;
   if(ArraySize(bars1) < 1 || ArraySize(bars2) < 1)
      return;

   MqlRates b1 = bars1[0];
   MqlRates b2 = bars2[0];

   double line1 = TrendlinePriceAtTime(m, b1.time);
   double tol   = InpLineTouchTolerance * _Point;

   bool upTrend   = (m.a > 0.0);
   bool downTrend = (m.a < 0.0);

   if(upTrend)
   {
      bool touched = (b1.low <= (line1 + tol));
      bool reclaim = (b1.close > line1);
      bool bullish = (b1.close > b1.open);
      bool stillHealthy = (b2.close >= TrendlinePriceAtTime(m, b2.time) - tol);
      if(touched && reclaim && bullish && stillHealthy)
      {
         trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, "Pullback buy");
      }
   }
   else if(downTrend)
   {
      bool touched = (b1.high >= (line1 - tol));
      bool reject  = (b1.close < line1);
      bool bearish = (b1.close < b1.open);
      bool stillWeak = (b2.close <= TrendlinePriceAtTime(m, b2.time) + tol);
      if(touched && reject && bearish && stillWeak)
      {
         trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, "Pullback sell");
      }
   }
}

int OnInit()
{
   g_maHandle = iMA(_Symbol, InpHigherTF, InpMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   if(g_maHandle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   g_lastBarTime = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   if(ObjectFind(0, g_lineName) >= 0)
      ObjectDelete(0, g_lineName);
}

void OnTick()
{
   if(!IsNewBar())
      return;

   TrendlineModel m;
   if(!BuildTrendlineFrom3Points(m))
      return;

   DrawTrendline(m);
   TryExitOnBreak(m);
   TryPullbackEntry(m);
}
