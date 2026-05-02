//+------------------------------------------------------------------+
//|                                      SimpleTrendlineStrategy.mqh |
//+------------------------------------------------------------------+
#ifndef SIMPLE_TRENDLINE_STRATEGY_MQH
#define SIMPLE_TRENDLINE_STRATEGY_MQH

struct SimpleTrendlineModel
{
   datetime t1;
   datetime t2;
   datetime t3;
   double   a;
   double   b;
   bool     valid;
};

struct SimpleTrendlineData
{
   string             symbol;
   bool               isInitialized;
   CTrade             trade;
   ENUM_TIMEFRAMES    signalTF;
   ENUM_TIMEFRAMES    higherTF;
   int                maPeriod;
   ENUM_MA_METHOD     maMethod;
   ENUM_APPLIED_PRICE appliedPrice;
   int                htfBarsToScan;
   double             touchTolerancePoints;
   double             breakBufferPoints;
   ulong              magic;
   bool               drawTrendline;
   int                maHandle;
   datetime           lastSignalBarTime;
   string             lineName;
};

double ST_NormalizeVolume(const string sym, double vol)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      vol = MathFloor(vol / step) * step;
   if(vol < minLot)
      vol = minLot;
   if(vol > maxLot)
      vol = maxLot;
   return vol;
}

bool ST_GetPosition(const string sym, const ulong magic, ENUM_POSITION_TYPE &type, double &volume)
{
   if(!PositionSelectByMagic(sym, magic))
      return false;
   type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   volume = PositionGetDouble(POSITION_VOLUME);
   return true;
}

int ST_FindRecentCrossPoints(SimpleTrendlineData &d, datetime &times[], double &prices[])
{
   ArrayResize(times, 0);
   ArrayResize(prices, 0);
   if(d.maHandle == INVALID_HANDLE)
      return 0;

   int needBars = MathMax(d.htfBarsToScan, d.maPeriod + 20);
   MqlRates rates[];
   double maBuf[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(maBuf, true);

   int copiedRates = CopyRates(d.symbol, d.higherTF, 0, needBars, rates);
   int copiedMa    = CopyBuffer(d.maHandle, 0, 0, needBars, maBuf);
   if(copiedRates <= 5 || copiedMa <= 5)
      return 0;

   int bars = MathMin(copiedRates, copiedMa);
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

bool ST_BuildTrendline(SimpleTrendlineData &d, SimpleTrendlineModel &m)
{
   m.valid = false;
   datetime ts[];
   double ps[];
   if(ST_FindRecentCrossPoints(d, ts, ps) < 3)
      return false;

   datetime tOld[3];
   double pOld[3];
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
   m.valid = true;
   return true;
}

double ST_LinePriceAt(const SimpleTrendlineModel &m, const datetime t)
{
   if(!m.valid)
      return 0.0;
   double x = (double)((long)t - (long)m.t1);
   return m.a * x + m.b;
}

void ST_DrawTrendline(SimpleTrendlineData &d, const SimpleTrendlineModel &m)
{
   if(!d.drawTrendline || !m.valid || d.symbol != _Symbol)
      return;

   datetime tStart = m.t1;
   datetime tEnd = iTime(d.symbol, d.signalTF, 0);
   if(tEnd <= tStart)
      tEnd = m.t3 + PeriodSeconds(d.signalTF) * 20;

   double pStart = ST_LinePriceAt(m, tStart);
   double pEnd   = ST_LinePriceAt(m, tEnd);

   if(ObjectFind(0, d.lineName) < 0)
      ObjectCreate(0, d.lineName, OBJ_TREND, 0, tStart, pStart, tEnd, pEnd);
   else
   {
      ObjectMove(0, d.lineName, 0, tStart, pStart);
      ObjectMove(0, d.lineName, 1, tEnd, pEnd);
   }

   ObjectSetInteger(0, d.lineName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, d.lineName, OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, d.lineName, OBJPROP_WIDTH, 2);
}

void ST_TryExitOnBreak(SimpleTrendlineData &d, const SimpleTrendlineModel &m)
{
   ENUM_POSITION_TYPE posType;
   double vol;
   if(!ST_GetPosition(d.symbol, d.magic, posType, vol))
      return;

   double close1 = iClose(d.symbol, d.signalTF, 1);
   datetime t1   = iTime(d.symbol, d.signalTF, 1);
   double line1  = ST_LinePriceAt(m, t1);
   double buf    = d.breakBufferPoints * SymbolInfoDouble(d.symbol, SYMBOL_POINT);

   bool closePos = false;
   if(posType == POSITION_TYPE_BUY && close1 < (line1 - buf))
      closePos = true;
   if(posType == POSITION_TYPE_SELL && close1 > (line1 + buf))
      closePos = true;

   if(closePos)
      ClosePositionByMagic(d.trade, d.symbol, d.magic);
}

void ST_TryPullbackEntry(SimpleTrendlineData &d, const SimpleTrendlineModel &m, const double lots)
{
   if(PositionExistsByMagic(d.symbol, d.magic))
      return;

   MqlRates b1[], b2[];
   ArraySetAsSeries(b1, true);
   ArraySetAsSeries(b2, true);
   if(CopyRates(d.symbol, d.signalTF, 1, 1, b1) != 1)
      return;
   if(CopyRates(d.symbol, d.signalTF, 2, 1, b2) != 1)
      return;
   if(ArraySize(b1) < 1 || ArraySize(b2) < 1)
      return;

   double line1 = ST_LinePriceAt(m, b1[0].time);
   double tol   = d.touchTolerancePoints * SymbolInfoDouble(d.symbol, SYMBOL_POINT);
   bool upTrend = (m.a > 0.0);
   bool downTrend = (m.a < 0.0);
   double vol = ST_NormalizeVolume(d.symbol, lots);

   if(upTrend)
   {
      bool touched = (b1[0].low <= (line1 + tol));
      bool reclaim = (b1[0].close > line1);
      bool bullish = (b1[0].close > b1[0].open);
      bool stillHealthy = (b2[0].close >= ST_LinePriceAt(m, b2[0].time) - tol);
      if(touched && reclaim && bullish && stillHealthy)
      {
         if(!d.trade.Buy(vol, d.symbol, 0.0, 0.0, 0.0, "SimpleTrendline BUY"))
            Print("SimpleTrendline BUY failed [", d.symbol, "] retcode=", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
      }
   }
   else if(downTrend)
   {
      bool touched = (b1[0].high >= (line1 - tol));
      bool reject = (b1[0].close < line1);
      bool bearish = (b1[0].close < b1[0].open);
      bool stillWeak = (b2[0].close <= ST_LinePriceAt(m, b2[0].time) + tol);
      if(touched && reject && bearish && stillWeak)
      {
         if(!d.trade.Sell(vol, d.symbol, 0.0, 0.0, 0.0, "SimpleTrendline SELL"))
            Print("SimpleTrendline SELL failed [", d.symbol, "] retcode=", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
      }
   }
}

bool InitSimpleTrendline(SimpleTrendlineData &d,
                         const string symbol,
                         const ENUM_TIMEFRAMES signalTF,
                         const ENUM_TIMEFRAMES higherTF,
                         const int maPeriod,
                         const ENUM_MA_METHOD maMethod,
                         const ENUM_APPLIED_PRICE appliedPrice,
                         const int htfBarsToScan,
                         const double touchTolerancePoints,
                         const double breakBufferPoints,
                         const ulong magic,
                         const bool drawTrendline)
{
   d.isInitialized = false;
   d.symbol = symbol;
   StringTrimLeft(d.symbol);
   StringTrimRight(d.symbol);
   if(StringLen(d.symbol) == 0)
      d.symbol = _Symbol;

   if(!SymbolSelect(d.symbol, true))
      return false;

   d.signalTF = signalTF;
   d.higherTF = higherTF;
   d.maPeriod = maPeriod;
   d.maMethod = maMethod;
   d.appliedPrice = appliedPrice;
   d.htfBarsToScan = htfBarsToScan;
   d.touchTolerancePoints = touchTolerancePoints;
   d.breakBufferPoints = breakBufferPoints;
   d.magic = magic;
   d.drawTrendline = drawTrendline;
   d.lastSignalBarTime = 0;
   d.lineName = "SimpleTrendline_" + d.symbol + "_" + IntegerToString((int)d.magic);

   d.trade.SetExpertMagicNumber((long)d.magic);
   d.trade.SetTypeFillingBySymbol(d.symbol);
   d.trade.SetDeviationInPoints(20);

   d.maHandle = iMA(d.symbol, d.higherTF, d.maPeriod, 0, d.maMethod, d.appliedPrice);
   if(d.maHandle == INVALID_HANDLE)
      return false;

   d.isInitialized = true;
   return true;
}

void DeinitSimpleTrendline(SimpleTrendlineData &d)
{
   if(d.maHandle != INVALID_HANDLE)
      IndicatorRelease(d.maHandle);
   d.maHandle = INVALID_HANDLE;
   if(ObjectFind(0, d.lineName) >= 0)
      ObjectDelete(0, d.lineName);
   d.isInitialized = false;
}

void ProcessSimpleTrendline(SimpleTrendlineData &d, const double lots)
{
   if(!d.isInitialized)
      return;

   datetime bar0 = iTime(d.symbol, d.signalTF, 0);
   if(bar0 == 0 || bar0 == d.lastSignalBarTime)
      return;
   d.lastSignalBarTime = bar0;

   SimpleTrendlineModel m;
   if(!ST_BuildTrendline(d, m))
      return;

   ST_DrawTrendline(d, m);
   ST_TryExitOnBreak(d, m);
   ST_TryPullbackEntry(d, m, lots);
}

#endif // SIMPLE_TRENDLINE_STRATEGY_MQH
