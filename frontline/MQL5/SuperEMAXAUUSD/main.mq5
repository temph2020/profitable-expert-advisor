//+------------------------------------------------------------------+
//| SuperEMA.mq5                                                    |
//| EMA + CCI + MACD histogram — trend filter, momentum confirmation |
//+------------------------------------------------------------------+
#property strict
#property version   "1.01"

#include <Trade/Trade.mqh>

enum ENUM_ENTRY_STYLE
{
   ENTRY_CCIZERO_MACD = 0,   // EMA trend + CCI crosses zero + MACD histogram agrees
   ENTRY_LAMBERT        = 1, // EMA trend + CCI crosses ±100 + MACD histogram agrees
   ENTRY_PULLBACK       = 2  // Uptrend: pullback to fast EMA + CCI was oversold + CCI crosses up through 0 + MACD > 0 (mirror for sells)
};

input group "=== Market ==="
input string          InpSymbol              = "";
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_M15;
input double          InpLots                = 0.01;
input int             InpSlippagePoints      = 55;
input int             InpMagic               = 940001;

input group "=== EMA (trend & structure) ==="
input int             InpEmaFast             = 40;
input int             InpEmaMid              = 180;
input int             InpEmaSlow             = 125;
input int             InpEmaTrendBars        = 3;      // closed bar shift for EMA reads

input group "=== CCI ==="
input int             InpCciPeriod           = 17;
input double          InpCciOverbought       = 80.0;
input double          InpCciOversold         = -140.0;
input int             InpPullbackCciLookback = 20;      // bars to check prior CCI oversold/overbought

input group "=== MACD (histogram = main - signal) ==="
input int             InpMacdFast            = 14;
input int             InpMacdSlow            = 38;
input int             InpMacdSignal        = 9;

input group "=== Strategy ==="
input ENUM_ENTRY_STYLE InpEntryStyle        = ENTRY_LAMBERT;
input bool             InpOneTradeOnly      = true;
input bool             InpUseStructuralSL   = false;
input double           InpSlBufferPoints      = 110;

input group "=== Exits (so trades do not run forever) ==="
input bool             InpExitOnTrendFlip   = false;   // close when price vs slow EMA flips against position
input bool             InpExitOnMacdFlip     = false;   // close when MACD histogram flips against position
input bool             InpExitOnCciZeroCross = true;  // long: CCI crosses below 0; short: CCI crosses above 0
input int              InpMaxHoldingBars    = 168;    // 0 = disabled (e.g. ~8 days M15)
input bool             InpExitBelowMidEma   = false;   // long: close if close < mid EMA (invalidation)

input group "=== Debug ==="
input bool             InpDebugLogs         = false;

CTrade trade;
datetime g_lastBarTime = 0;

string WorkSymbol()
{
   return (InpSymbol == "" || InpSymbol == NULL) ? _Symbol : InpSymbol;
}

void Log(const string s)
{
   if(InpDebugLogs)
      Print("[SuperEMA] ", s);
}

bool IsNewBar(const string sym, const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(sym, tf, 0);
   if(t <= 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
}

double EmaAt(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iMA(sym, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(h == INVALID_HANDLE)
      return 0.0;
   double b[1];
   if(CopyBuffer(h, 0, shift, 1, b) <= 0)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   IndicatorRelease(h);
   return b[0];
}

double CciAt(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iCCI(sym, tf, period, PRICE_TYPICAL);
   if(h == INVALID_HANDLE)
      return 0.0;
   double b[1];
   if(CopyBuffer(h, 0, shift, 1, b) <= 0)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   IndicatorRelease(h);
   return b[0];
}

bool MacdHistAt(const string sym, const ENUM_TIMEFRAMES tf, const int fast, const int slow, const int signal, const int shift, double &hist)
{
   int h = iMACD(sym, tf, fast, slow, signal, PRICE_CLOSE);
   if(h == INVALID_HANDLE)
      return false;
   double mainLine[1], sigLine[1];
   if(CopyBuffer(h, 0, shift, 1, mainLine) <= 0 || CopyBuffer(h, 1, shift, 1, sigLine) <= 0)
   {
      IndicatorRelease(h);
      return false;
   }
   IndicatorRelease(h);
   hist = mainLine[0] - sigLine[0];
   return true;
}

bool TrendUp(const string sym, const int sh)
{
   double c = iClose(sym, InpTimeframe, sh);
   double emaS = EmaAt(sym, InpTimeframe, InpEmaSlow, sh);
   return (emaS > 0.0 && c > emaS);
}

bool TrendDown(const string sym, const int sh)
{
   double c = iClose(sym, InpTimeframe, sh);
   double emaS = EmaAt(sym, InpTimeframe, InpEmaSlow, sh);
   return (emaS > 0.0 && c < emaS);
}

bool CciCrossAboveZero(const string sym)
{
   double c1 = CciAt(sym, InpTimeframe, InpCciPeriod, 1);
   double c2 = CciAt(sym, InpTimeframe, InpCciPeriod, 2);
   return (c2 <= 0.0 && c1 > 0.0);
}

bool CciCrossBelowZero(const string sym)
{
   double c1 = CciAt(sym, InpTimeframe, InpCciPeriod, 1);
   double c2 = CciAt(sym, InpTimeframe, InpCciPeriod, 2);
   return (c2 >= 0.0 && c1 < 0.0);
}

bool CciCrossAbove100(const string sym)
{
   double c1 = CciAt(sym, InpTimeframe, InpCciPeriod, 1);
   double c2 = CciAt(sym, InpTimeframe, InpCciPeriod, 2);
   return (c2 < InpCciOverbought && c1 > InpCciOverbought);
}

bool CciCrossBelowMinus100(const string sym)
{
   double c1 = CciAt(sym, InpTimeframe, InpCciPeriod, 1);
   double c2 = CciAt(sym, InpTimeframe, InpCciPeriod, 2);
   return (c2 > InpCciOversold && c1 < InpCciOversold);
}

bool HadCciOversoldRecently(const string sym)
{
   for(int i = 2; i <= InpPullbackCciLookback + 1; i++)
   {
      double v = CciAt(sym, InpTimeframe, InpCciPeriod, i);
      if(v <= InpCciOversold)
         return true;
   }
   return false;
}

bool HadCciOverboughtRecently(const string sym)
{
   for(int i = 2; i <= InpPullbackCciLookback + 1; i++)
   {
      double v = CciAt(sym, InpTimeframe, InpCciPeriod, i);
      if(v >= InpCciOverbought)
         return true;
   }
   return false;
}

bool PullbackNearFastEmaLong(const string sym)
{
   double emaF = EmaAt(sym, InpTimeframe, InpEmaFast, 1);
   double lo = iLow(sym, InpTimeframe, 1);
   if(emaF <= 0.0)
      return false;
   return (lo <= emaF + InpSlBufferPoints * _Point * 3.0);
}

bool PullbackNearFastEmaShort(const string sym)
{
   double emaF = EmaAt(sym, InpTimeframe, InpEmaFast, 1);
   double hi = iHigh(sym, InpTimeframe, 1);
   if(emaF <= 0.0)
      return false;
   return (hi >= emaF - InpSlBufferPoints * _Point * 3.0);
}

int PositionsByMagic(const string sym, const int magic)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && (int)PositionGetInteger(POSITION_MAGIC) == magic)
         n++;
   }
   return n;
}

void ComputeSLTP(const bool isBuy, const double entry, double &sl, double &tp)
{
   const string sym = WorkSymbol();
   sl = 0.0;
   tp = 0.0;
   if(!InpUseStructuralSL)
      return;
   double emaM = EmaAt(sym, InpTimeframe, InpEmaMid, InpEmaTrendBars);
   double buf = InpSlBufferPoints * _Point;
   if(isBuy)
      sl = emaM - buf;
   else
      sl = emaM + buf;
}

int BarsSinceOpen(const string sym, const datetime openTime)
{
   if(openTime <= 0)
      return 0;
   int sh = iBarShift(sym, InpTimeframe, openTime, false);
   if(sh < 0)
      return 999999;
   return sh;
}

void ClosePositionTicket(const ulong ticket, const string reason)
{
   trade.SetExpertMagicNumber(InpMagic);
   if(trade.PositionClose(ticket))
      Log("Close: " + reason);
}

void ManageSuperEMAExits(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      double h1 = 0.0;
      if(!MacdHistAt(sym, InpTimeframe, InpMacdFast, InpMacdSlow, InpMacdSignal, 1, h1))
         continue;

      bool closeLong = false;
      bool closeShort = false;
      string reason = "";

      if(InpMaxHoldingBars > 0)
      {
         int held = BarsSinceOpen(sym, openTime);
         if(held >= InpMaxHoldingBars)
         {
            if(ptype == POSITION_TYPE_BUY)
               closeLong = true;
            else
               closeShort = true;
            reason = "time stop (max bars)";
         }
      }

      if(ptype == POSITION_TYPE_BUY)
      {
         if(InpExitOnTrendFlip && TrendDown(sym, InpEmaTrendBars))
         {
            closeLong = true;
            reason = "trend flip (below slow EMA)";
         }
         if(InpExitOnMacdFlip && h1 < 0.0)
         {
            closeLong = true;
            reason = "MACD histogram < 0";
         }
         if(InpExitOnCciZeroCross && CciCrossBelowZero(sym))
         {
            closeLong = true;
            reason = "CCI crossed below zero";
         }
         if(InpExitBelowMidEma)
         {
            double c = iClose(sym, InpTimeframe, 1);
            double emaM = EmaAt(sym, InpTimeframe, InpEmaMid, 1);
            if(emaM > 0.0 && c < emaM)
            {
               closeLong = true;
               reason = "close below mid EMA";
            }
         }
         if(closeLong)
            ClosePositionTicket(ticket, reason);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         if(InpExitOnTrendFlip && TrendUp(sym, InpEmaTrendBars))
         {
            closeShort = true;
            reason = "trend flip (above slow EMA)";
         }
         if(InpExitOnMacdFlip && h1 > 0.0)
         {
            closeShort = true;
            reason = "MACD histogram > 0";
         }
         if(InpExitOnCciZeroCross && CciCrossAboveZero(sym))
         {
            closeShort = true;
            reason = "CCI crossed above zero";
         }
         if(InpExitBelowMidEma)
         {
            double c = iClose(sym, InpTimeframe, 1);
            double emaM = EmaAt(sym, InpTimeframe, InpEmaMid, 1);
            if(emaM > 0.0 && c > emaM)
            {
               closeShort = true;
               reason = "close above mid EMA";
            }
         }
         if(closeShort)
            ClosePositionTicket(ticket, reason);
      }
   }
}

int OnInit()
{
   string sym = WorkSymbol();
   if(!SymbolSelect(sym, true))
   {
      Print("SuperEMA: cannot select symbol ", sym);
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   string sym = WorkSymbol();
   if(_Symbol != sym)
   {
      static datetime lastLog = 0;
      datetime tb = iTime(_Symbol, PERIOD_M1, 0);
      if(tb != lastLog && InpDebugLogs)
      {
         lastLog = tb;
         Log("Chart symbol differs from WorkSymbol; attach to " + sym + " or set InpSymbol empty.");
      }
      return;
   }

   if(!IsNewBar(sym, InpTimeframe))
      return;

   // Exits must run every bar; do not skip when a position exists (otherwise trades never close with SL=0/TP=0).
   ManageSuperEMAExits(sym);

   if(InpOneTradeOnly && PositionsByMagic(sym, InpMagic) > 0)
      return;

   const int sh = InpEmaTrendBars;
   double h1 = 0.0, h2 = 0.0;
   if(!MacdHistAt(sym, InpTimeframe, InpMacdFast, InpMacdSlow, InpMacdSignal, 1, h1) ||
      !MacdHistAt(sym, InpTimeframe, InpMacdFast, InpMacdSlow, InpMacdSignal, 2, h2))
      return;

   bool up = TrendUp(sym, sh);
   bool dn = TrendDown(sym, sh);

   bool wantBuy = false;
   bool wantSell = false;

   switch(InpEntryStyle)
   {
      case ENTRY_CCIZERO_MACD:
         if(up && CciCrossAboveZero(sym) && h1 > 0.0)
            wantBuy = true;
         if(dn && CciCrossBelowZero(sym) && h1 < 0.0)
            wantSell = true;
         break;

      case ENTRY_LAMBERT:
         if(up && CciCrossAbove100(sym) && h1 > 0.0)
            wantBuy = true;
         if(dn && CciCrossBelowMinus100(sym) && h1 < 0.0)
            wantSell = true;
         break;

      case ENTRY_PULLBACK:
         if(up && HadCciOversoldRecently(sym) && CciCrossAboveZero(sym) && h1 > 0.0 && PullbackNearFastEmaLong(sym))
            wantBuy = true;
         if(dn && HadCciOverboughtRecently(sym) && CciCrossBelowZero(sym) && h1 < 0.0 && PullbackNearFastEmaShort(sym))
            wantSell = true;
         break;
   }

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;

   double sl = 0.0, tp = 0.0;

   if(wantBuy && !wantSell)
   {
      ComputeSLTP(true, tick.ask, sl, tp);
      if(trade.Buy(InpLots, sym, tick.ask, sl, tp, "SuperEMA long"))
         Log(StringFormat("BUY ask=%.5f sl=%.5f cci=%.2f macdHist=%.5f", tick.ask, sl,
                          CciAt(sym, InpTimeframe, InpCciPeriod, 1), h1));
   }
   else if(wantSell && !wantBuy)
   {
      ComputeSLTP(false, tick.bid, sl, tp);
      if(trade.Sell(InpLots, sym, tick.bid, sl, tp, "SuperEMA short"))
         Log(StringFormat("SELL bid=%.5f sl=%.5f cci=%.2f macdHist=%.5f", tick.bid, sl,
                          CciAt(sym, InpTimeframe, InpCciPeriod, 1), h1));
   }
}
