//+------------------------------------------------------------------+
//|                                                 rsiDivergence.mq5 |
//| Lab EA: RSI divergence + EMA distance filter                      |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input group "=== Market ==="
input string          InpSymbol            = "";
input ENUM_TIMEFRAMES InpTf                = PERIOD_CURRENT;
input double          InpLots              = 0.01;
input ulong           InpMagic             = 202604231;
input int             InpSlippagePts     = 30;
input int             InpMaxPositions    = 1;
input bool            InpRequireFlat     = true; // no new entry while any position with this magic exists

input group "=== Indicators ==="
input int             InpRsiPeriod         = 14;
input int             InpEmaPeriod       = 200;

input group "=== Swing / divergence ==="
input int             InpPivotRadius     = 2;     // bars each side; pivot confirms after radius closes
input int             InpSwingLookback   = 80;   // search swings within [radius+1 .. lookback]
input int             InpMinPivotGap     = 3;    // min bars between the two swings used for a pair

input group "=== EMA distance (entry filter) ==="
input double          InpMinEmaDistPtsBuy  = 80.0;  // buy: (EMA - close) / _Point >= this on signal bar
input double          InpMinEmaDistPtsSell = 80.0;  // sell: (close - EMA) / _Point >= this

input group "=== Risk ==="
input bool            InpUseSLTP         = true;   // off = naked positions (can run years until margin stop)
input double          InpSLPts           = 500.0;  // points; tune per symbol (_Point)
input double          InpTPPts           = 1000.0;
input int             InpMaxHoldBars     = 0;      // 0=off; else close position after this many bars open (signal TF)

CTrade g_trade;
int    g_hRsi = INVALID_HANDLE;
int    g_hEma = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastBuyPivotNew  = 0;
datetime g_lastBuyPivotOld  = 0;
datetime g_lastSellPivotNew = 0;
datetime g_lastSellPivotOld = 0;

string WorkSymbol()
{
   if(StringLen(InpSymbol) > 0)
      return InpSymbol;
   return _Symbol;
}

ENUM_TIMEFRAMES WorkTf()
{
   if(InpTf == PERIOD_CURRENT)
      return (ENUM_TIMEFRAMES)_Period;
   return InpTf;
}

void SetFilling()
{
   const long fill = SymbolInfoInteger(WorkSymbol(), SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
}

bool CopyRsiEma(const int bars, double &rsi[], double &ema[])
{
   ArrayResize(rsi, bars);
   ArrayResize(ema, bars);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_hRsi, 0, 0, bars, rsi) < bars)
      return false;
   if(CopyBuffer(g_hEma, 0, 0, bars, ema) < bars)
      return false;
   return true;
}

bool IsSwingLow(const int s, const int r)
{
   if(s < r + 1)
      return false;
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   double lv = iLow(sym, tf, s);
   for(int k = -r; k <= r; k++)
   {
      if(k == 0)
         continue;
      if(iLow(sym, tf, s + k) <= lv)
         return false;
   }
   return true;
}

bool IsSwingHigh(const int s, const int r)
{
   if(s < r + 1)
      return false;
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   double hv = iHigh(sym, tf, s);
   for(int k = -r; k <= r; k++)
   {
      if(k == 0)
         continue;
      if(iHigh(sym, tf, s + k) >= hv)
         return false;
   }
   return true;
}

bool CollectSwingLows(int &outSwings[], const int r, const int lookback)
{
   ArrayResize(outSwings, 0);
   const int from = r + 1;
   if(lookback <= from)
      return false;
   for(int s = from; s <= lookback; s++)
   {
      if(!IsSwingLow(s, r))
         continue;
      int n = ArraySize(outSwings);
      ArrayResize(outSwings, n + 1);
      outSwings[n] = s;
   }
   return ArraySize(outSwings) >= 2;
}

bool CollectSwingHighs(int &outSwings[], const int r, const int lookback)
{
   ArrayResize(outSwings, 0);
   const int from = r + 1;
   if(lookback <= from)
      return false;
   for(int s = from; s <= lookback; s++)
   {
      if(!IsSwingHigh(s, r))
         continue;
      int n = ArraySize(outSwings);
      ArrayResize(outSwings, n + 1);
      outSwings[n] = s;
   }
   return ArraySize(outSwings) >= 2;
}

void SortSwingsAscending(int &sw[]) 
{
   int n = ArraySize(sw);
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(sw[i] > sw[j])
         {
            int t = sw[i];
            sw[i] = sw[j];
            sw[j] = t;
         }
}

bool BullishDivergence(const double &rsi[], const int r, const int lookback, int &sNew, int &sOld)
{
   int swings[];
   if(!CollectSwingLows(swings, r, lookback))
      return false;
   SortSwingsAscending(swings);
   const int n = ArraySize(swings);
   sNew = swings[0];
   sOld = swings[1];
   if(sOld - sNew < InpMinPivotGap)
      return false;
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   const double lowNew = iLow(sym, tf, sNew);
   const double lowOld = iLow(sym, tf, sOld);
   if(lowNew >= lowOld)
      return false;
   if(rsi[sNew] <= rsi[sOld])
      return false;
   return true;
}

bool BearishDivergence(const double &rsi[], const int r, const int lookback, int &sNew, int &sOld)
{
   int swings[];
   if(!CollectSwingHighs(swings, r, lookback))
      return false;
   SortSwingsAscending(swings);
   sNew = swings[0];
   sOld = swings[1];
   if(sOld - sNew < InpMinPivotGap)
      return false;
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   const double hiNew = iHigh(sym, tf, sNew);
   const double hiOld = iHigh(sym, tf, sOld);
   if(hiNew <= hiOld)
      return false;
   if(rsi[sNew] >= rsi[sOld])
      return false;
   return true;
}

bool EmaDistanceBuyOk(const double &ema[], const int barShift)
{
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   const double c = iClose(sym, tf, barShift);
   if(c <= 0.0 || ema[barShift] <= 0.0)
      return false;
   const double pts = (ema[barShift] - c) / _Point;
   return (pts >= InpMinEmaDistPtsBuy);
}

bool EmaDistanceSellOk(const double &ema[], const int barShift)
{
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   const double c = iClose(sym, tf, barShift);
   if(c <= 0.0 || ema[barShift] <= 0.0)
      return false;
   const double pts = (c - ema[barShift]) / _Point;
   return (pts >= InpMinEmaDistPtsSell);
}

int CountOurPositions()
{
   const string sym = WorkSymbol();
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      c++;
   }
   return c;
}

void ManageMaxHoldBars()
{
   if(InpMaxHoldBars <= 0)
      return;
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      const int sh = iBarShift(sym, tf, openTime);
      if(sh < 0)
         continue;
      if(sh >= InpMaxHoldBars)
         g_trade.PositionClose(ticket);
   }
}

void BuildSLTP(const bool isBuy, const double price, double &sl, double &tp)
{
   sl = tp = 0.0;
   if(!InpUseSLTP)
      return;
   if(isBuy)
   {
      sl = price - InpSLPts * _Point;
      tp = price + InpTPPts * _Point;
   }
   else
   {
      sl = price + InpSLPts * _Point;
      tp = price - InpTPPts * _Point;
   }
}

int OnInit()
{
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();
   if(!SymbolSelect(sym, true))
      Print("rsiDivergence: SymbolSelect note for ", sym);

   g_hRsi = iRSI(sym, tf, InpRsiPeriod, PRICE_CLOSE);
   g_hEma = iMA(sym, tf, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE || g_hEma == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   SetFilling();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hRsi != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   if(g_hEma != INVALID_HANDLE) IndicatorRelease(g_hEma);
}

void OnTick()
{
   const string sym = WorkSymbol();
   const ENUM_TIMEFRAMES tf = WorkTf();

   ManageMaxHoldBars();

   datetime t = iTime(sym, tf, 0);
   if(t == 0 || t == g_lastBar)
      return;
   g_lastBar = t;

   const int need = InpSwingLookback + InpPivotRadius + 5;
   double rsi[], ema[];
   if(!CopyRsiEma(need, rsi, ema))
      return;

   const int openN = CountOurPositions();
   if(openN >= InpMaxPositions)
      return;
   if(InpRequireFlat && openN > 0)
      return;

   const int r = MathMax(1, InpPivotRadius);
   const int lb = MathMax(r + 3, InpSwingLookback);

   int sNew = 0, sOld = 0;
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;

   if(BullishDivergence(rsi, r, lb, sNew, sOld) && EmaDistanceBuyOk(ema, 1))
   {
      const datetime tPivotNew = iTime(sym, tf, sNew);
      const datetime tPivotOld = iTime(sym, tf, sOld);
      if(tPivotNew == 0 || tPivotOld == 0)
         return;
      if(tPivotNew == g_lastBuyPivotNew && tPivotOld == g_lastBuyPivotOld)
         return;

      double sl, tp;
      BuildSLTP(true, tick.ask, sl, tp);
      if(g_trade.Buy(InpLots, sym, tick.ask, sl, tp, "RSI div+EMA buy"))
      {
         g_lastBuyPivotNew  = tPivotNew;
         g_lastBuyPivotOld  = tPivotOld;
         Print("Buy RSI div: swings ", sOld, "->", sNew, " pivots ", TimeToString(tPivotOld), " -> ", TimeToString(tPivotNew));
      }
      return;
   }

   if(BearishDivergence(rsi, r, lb, sNew, sOld) && EmaDistanceSellOk(ema, 1))
   {
      const datetime tPivotNew = iTime(sym, tf, sNew);
      const datetime tPivotOld = iTime(sym, tf, sOld);
      if(tPivotNew == 0 || tPivotOld == 0)
         return;
      if(tPivotNew == g_lastSellPivotNew && tPivotOld == g_lastSellPivotOld)
         return;

      double sl, tp;
      BuildSLTP(false, tick.bid, sl, tp);
      if(g_trade.Sell(InpLots, sym, tick.bid, sl, tp, "RSI div+EMA sell"))
      {
         g_lastSellPivotNew = tPivotNew;
         g_lastSellPivotOld = tPivotOld;
         Print("Sell RSI div: swings ", sOld, "->", sNew, " pivots ", TimeToString(tPivotOld), " -> ", TimeToString(tPivotNew));
      }
   }
}
