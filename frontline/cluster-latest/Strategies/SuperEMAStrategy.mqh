//+------------------------------------------------------------------+
//| SuperEMAStrategy.mqh — EMA + CCI + MACD (United EA module)       |
//+------------------------------------------------------------------+
#ifndef SUPER_EMA_STRATEGY_MQH
#define SUPER_EMA_STRATEGY_MQH

#include <Trade/Trade.mqh>

enum ENUM_SE_ENTRY_STYLE
{
   SE_ENTRY_CCIZERO_MACD = 0,
   SE_ENTRY_LAMBERT      = 1,
   SE_ENTRY_PULLBACK     = 2
};

struct SuperEMAData
{
   string                symbol;
   ENUM_TIMEFRAMES       tf;
   datetime              lastBarTime;
   CTrade                trade;
   bool                  isInitialized;
   int                   slippagePoints;
   int                   magic;
   int                   emaFast;
   int                   emaMid;
   int                   emaSlow;
   int                   emaTrendBars;
   int                   cciPeriod;
   double                cciOverbought;
   double                cciOversold;
   int                   pullbackCciLookback;
   int                   macdFast;
   int                   macdSlow;
   int                   macdSignal;
   ENUM_SE_ENTRY_STYLE   entryStyle;
   bool                  oneTradeOnly;
   bool                  useStructuralSL;
   double                slBufferPoints;
   bool                  exitOnTrendFlip;
   bool                  exitOnMacdFlip;
   bool                  exitOnCciZeroCross;
   int                   maxHoldingBars;
   bool                  exitBelowMidEma;
   bool                  debugLogs;
   bool                  closeUnprofitableOnNewSignal;
};

void SuperEMA_Log(SuperEMAData &d, const string s)
{
   if(d.debugLogs)
      Print("[SuperEMA] ", s);
}

double SuperEMA_Point(const SuperEMAData &d)
{
   double pt = SymbolInfoDouble(d.symbol, SYMBOL_POINT);
   return (pt > 0.0 ? pt : _Point);
}

bool SuperEMA_IsNewBar(SuperEMAData &d)
{
   datetime t = iTime(d.symbol, d.tf, 0);
   if(t <= 0 || t == d.lastBarTime)
      return false;
   d.lastBarTime = t;
   return true;
}

double SuperEMA_EmaAt(SuperEMAData &d, const int period, const int shift)
{
   int h = iMA(d.symbol, d.tf, period, 0, MODE_EMA, PRICE_CLOSE);
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

double SuperEMA_CciAt(SuperEMAData &d, const int shift)
{
   int h = iCCI(d.symbol, d.tf, d.cciPeriod, PRICE_TYPICAL);
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

bool SuperEMA_MacdHistAt(SuperEMAData &d, const int shift, double &hist)
{
   int h = iMACD(d.symbol, d.tf, d.macdFast, d.macdSlow, d.macdSignal, PRICE_CLOSE);
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

bool SuperEMA_TrendUp(SuperEMAData &d, const int sh)
{
   double c = iClose(d.symbol, d.tf, sh);
   double emaS = SuperEMA_EmaAt(d, d.emaSlow, sh);
   return (emaS > 0.0 && c > emaS);
}

bool SuperEMA_TrendDown(SuperEMAData &d, const int sh)
{
   double c = iClose(d.symbol, d.tf, sh);
   double emaS = SuperEMA_EmaAt(d, d.emaSlow, sh);
   return (emaS > 0.0 && c < emaS);
}

bool SuperEMA_CciCrossAboveZero(SuperEMAData &d)
{
   double c1 = SuperEMA_CciAt(d, 1);
   double c2 = SuperEMA_CciAt(d, 2);
   return (c2 <= 0.0 && c1 > 0.0);
}

bool SuperEMA_CciCrossBelowZero(SuperEMAData &d)
{
   double c1 = SuperEMA_CciAt(d, 1);
   double c2 = SuperEMA_CciAt(d, 2);
   return (c2 >= 0.0 && c1 < 0.0);
}

bool SuperEMA_CciCrossAbove100(SuperEMAData &d)
{
   double c1 = SuperEMA_CciAt(d, 1);
   double c2 = SuperEMA_CciAt(d, 2);
   return (c2 < d.cciOverbought && c1 > d.cciOverbought);
}

bool SuperEMA_CciCrossBelowMinus100(SuperEMAData &d)
{
   double c1 = SuperEMA_CciAt(d, 1);
   double c2 = SuperEMA_CciAt(d, 2);
   return (c2 > d.cciOversold && c1 < d.cciOversold);
}

bool SuperEMA_HadCciOversoldRecently(SuperEMAData &d)
{
   for(int i = 2; i <= d.pullbackCciLookback + 1; i++)
   {
      double v = SuperEMA_CciAt(d, i);
      if(v <= d.cciOversold)
         return true;
   }
   return false;
}

bool SuperEMA_HadCciOverboughtRecently(SuperEMAData &d)
{
   for(int i = 2; i <= d.pullbackCciLookback + 1; i++)
   {
      double v = SuperEMA_CciAt(d, i);
      if(v >= d.cciOverbought)
         return true;
   }
   return false;
}

bool SuperEMA_PullbackNearFastEmaLong(SuperEMAData &d)
{
   double emaF = SuperEMA_EmaAt(d, d.emaFast, 1);
   double lo = iLow(d.symbol, d.tf, 1);
   if(emaF <= 0.0)
      return false;
   const double pt = SuperEMA_Point(d);
   return (lo <= emaF + d.slBufferPoints * pt * 3.0);
}

bool SuperEMA_PullbackNearFastEmaShort(SuperEMAData &d)
{
   double emaF = SuperEMA_EmaAt(d, d.emaFast, 1);
   double hi = iHigh(d.symbol, d.tf, 1);
   if(emaF <= 0.0)
      return false;
   const double pt = SuperEMA_Point(d);
   return (hi >= emaF - d.slBufferPoints * pt * 3.0);
}

int SuperEMA_PositionsByMagic(SuperEMAData &d)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == d.symbol && (int)PositionGetInteger(POSITION_MAGIC) == d.magic)
         n++;
   }
   return n;
}

void SuperEMA_ComputeSLTP(SuperEMAData &d, const bool isBuy, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;
   if(!d.useStructuralSL)
      return;
   double emaM = SuperEMA_EmaAt(d, d.emaMid, d.emaTrendBars);
   double buf = d.slBufferPoints * SuperEMA_Point(d);
   if(isBuy)
      sl = emaM - buf;
   else
      sl = emaM + buf;
}

int SuperEMA_BarsSinceOpen(SuperEMAData &d, const datetime openTime)
{
   if(openTime <= 0)
      return 0;
   int sh = iBarShift(d.symbol, d.tf, openTime, false);
   if(sh < 0)
      return 999999;
   return sh;
}

void SuperEMA_CloseTicket(SuperEMAData &d, const ulong ticket, const string reason)
{
#ifdef UNITED_MARTINGALE_NO_SELF_CLOSE
   return;
#endif
   d.trade.SetExpertMagicNumber(d.magic);
   if(d.trade.PositionClose(ticket))
      SuperEMA_Log(d, "Close: " + reason);
}

void SuperEMA_ManageExits(SuperEMAData &d)
{
#ifdef UNITED_MARTINGALE_NO_SELF_CLOSE
   return;
#endif
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != d.symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != d.magic)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      double h1 = 0.0;
      if(!SuperEMA_MacdHistAt(d, 1, h1))
         continue;

      bool closeLong = false;
      bool closeShort = false;
      string reason = "";

      if(d.maxHoldingBars > 0)
      {
         int held = SuperEMA_BarsSinceOpen(d, openTime);
         if(held >= d.maxHoldingBars)
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
         if(d.exitOnTrendFlip && SuperEMA_TrendDown(d, d.emaTrendBars))
         {
            closeLong = true;
            reason = "trend flip (below slow EMA)";
         }
         if(d.exitOnMacdFlip && h1 < 0.0)
         {
            closeLong = true;
            reason = "MACD histogram < 0";
         }
         if(d.exitOnCciZeroCross && SuperEMA_CciCrossBelowZero(d))
         {
            closeLong = true;
            reason = "CCI crossed below zero";
         }
         if(d.exitBelowMidEma)
         {
            double c = iClose(d.symbol, d.tf, 1);
            double emaM = SuperEMA_EmaAt(d, d.emaMid, 1);
            if(emaM > 0.0 && c < emaM)
            {
               closeLong = true;
               reason = "close below mid EMA";
            }
         }
         if(closeLong)
            SuperEMA_CloseTicket(d, ticket, reason);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         if(d.exitOnTrendFlip && SuperEMA_TrendUp(d, d.emaTrendBars))
         {
            closeShort = true;
            reason = "trend flip (above slow EMA)";
         }
         if(d.exitOnMacdFlip && h1 > 0.0)
         {
            closeShort = true;
            reason = "MACD histogram > 0";
         }
         if(d.exitOnCciZeroCross && SuperEMA_CciCrossAboveZero(d))
         {
            closeShort = true;
            reason = "CCI crossed above zero";
         }
         if(d.exitBelowMidEma)
         {
            double c = iClose(d.symbol, d.tf, 1);
            double emaM = SuperEMA_EmaAt(d, d.emaMid, 1);
            if(emaM > 0.0 && c > emaM)
            {
               closeShort = true;
               reason = "close above mid EMA";
            }
         }
         if(closeShort)
            SuperEMA_CloseTicket(d, ticket, reason);
      }
   }
}

bool InitSuperEMA(SuperEMAData &d,
                    const string symbol,
                    const ENUM_TIMEFRAMES tf,
                    const int slippagePoints,
                    const int magic,
                    const int emaFast,
                    const int emaMid,
                    const int emaSlow,
                    const int emaTrendBars,
                    const int cciPeriod,
                    const double cciOverbought,
                    const double cciOversold,
                    const int pullbackCciLookback,
                    const int macdFast,
                    const int macdSlow,
                    const int macdSignal,
                    const ENUM_SE_ENTRY_STYLE entryStyle,
                    const bool oneTradeOnly,
                    const bool useStructuralSL,
                    const double slBufferPoints,
                    const bool exitOnTrendFlip,
                    const bool exitOnMacdFlip,
                    const bool exitOnCciZeroCross,
                    const int maxHoldingBars,
                    const bool exitBelowMidEma,
                    const bool debugLogs)
{
   d.symbol = symbol;
   if(StringLen(d.symbol) == 0)
      d.symbol = _Symbol;
   d.tf = tf;
   d.lastBarTime = 0;
   d.isInitialized = false;
   d.slippagePoints = slippagePoints;
   d.magic = magic;
   d.emaFast = emaFast;
   d.emaMid = emaMid;
   d.emaSlow = emaSlow;
   d.emaTrendBars = emaTrendBars;
   d.cciPeriod = cciPeriod;
   d.cciOverbought = cciOverbought;
   d.cciOversold = cciOversold;
   d.pullbackCciLookback = pullbackCciLookback;
   d.macdFast = macdFast;
   d.macdSlow = macdSlow;
   d.macdSignal = macdSignal;
   d.entryStyle = entryStyle;
   d.oneTradeOnly = oneTradeOnly;
   d.useStructuralSL = useStructuralSL;
   d.slBufferPoints = slBufferPoints;
   d.exitOnTrendFlip = exitOnTrendFlip;
   d.exitOnMacdFlip = exitOnMacdFlip;
   d.exitOnCciZeroCross = exitOnCciZeroCross;
   d.maxHoldingBars = maxHoldingBars;
   d.exitBelowMidEma = exitBelowMidEma;
   d.debugLogs = debugLogs;

   if(!SymbolSelect(d.symbol, true))
   {
      Print("SuperEMA: symbol not available: ", d.symbol);
      return false;
   }
   d.trade.SetExpertMagicNumber(d.magic);
   d.trade.SetDeviationInPoints(d.slippagePoints);
   d.isInitialized = true;
   return true;
}

void ProcessSuperEMA(SuperEMAData &d, const double lots)
{
   if(!d.isInitialized)
      return;

   if(!SuperEMA_IsNewBar(d))
      return;

   SuperEMA_ManageExits(d);

   // Same order as standalone SuperEMAXAUUSD: skip entry logic when flat is not allowed.
   if(d.oneTradeOnly && SuperEMA_PositionsByMagic(d) > 0 && !d.closeUnprofitableOnNewSignal)
      return;

   const int sh = d.emaTrendBars;
   double h1 = 0.0;
   if(!SuperEMA_MacdHistAt(d, 1, h1))
      return;

   bool up = SuperEMA_TrendUp(d, sh);
   bool dn = SuperEMA_TrendDown(d, sh);

   bool wantBuy = false;
   bool wantSell = false;

   switch(d.entryStyle)
   {
      case SE_ENTRY_CCIZERO_MACD:
         if(up && SuperEMA_CciCrossAboveZero(d) && h1 > 0.0)
            wantBuy = true;
         if(dn && SuperEMA_CciCrossBelowZero(d) && h1 < 0.0)
            wantSell = true;
         break;

      case SE_ENTRY_LAMBERT:
         if(up && SuperEMA_CciCrossAbove100(d) && h1 > 0.0)
            wantBuy = true;
         if(dn && SuperEMA_CciCrossBelowMinus100(d) && h1 < 0.0)
            wantSell = true;
         break;

      case SE_ENTRY_PULLBACK:
         if(up && SuperEMA_HadCciOversoldRecently(d) && SuperEMA_CciCrossAboveZero(d) && h1 > 0.0 && SuperEMA_PullbackNearFastEmaLong(d))
            wantBuy = true;
         if(dn && SuperEMA_HadCciOverboughtRecently(d) && SuperEMA_CciCrossBelowZero(d) && h1 < 0.0 && SuperEMA_PullbackNearFastEmaShort(d))
            wantSell = true;
         break;
   }

   if(!wantBuy && !wantSell)
      return;

   const double vol = United_NormalizeVolume(d.symbol, lots);
   if(vol <= 0.0)
   {
      SuperEMA_Log(d, "Skip entry: normalized volume <= 0");
      return;
   }

   if(!United_PrepareEntrySlot(d.trade, d.symbol, d.magic, d.closeUnprofitableOnNewSignal))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(d.symbol, tick))
      return;

   double sl = 0.0, tp = 0.0;

   if(wantBuy && !wantSell)
   {
#ifndef UNITED_MARTINGALE_NO_SELF_CLOSE
      SuperEMA_ComputeSLTP(d, true, sl, tp);
#endif
      if(d.trade.Buy(vol, d.symbol, tick.ask, sl, tp, "United SuperEMA long"))
         SuperEMA_Log(d, StringFormat("BUY ask=%.5f sl=%.5f", tick.ask, sl));
   }
   else if(wantSell && !wantBuy)
   {
#ifndef UNITED_MARTINGALE_NO_SELF_CLOSE
      SuperEMA_ComputeSLTP(d, false, sl, tp);
#endif
      if(d.trade.Sell(vol, d.symbol, tick.bid, sl, tp, "United SuperEMA short"))
         SuperEMA_Log(d, StringFormat("SELL bid=%.5f sl=%.5f", tick.bid, sl));
   }
}

void DeinitSuperEMA(SuperEMAData &d)
{
   d.isInitialized = false;
}

#endif // SUPER_EMA_STRATEGY_MQH
