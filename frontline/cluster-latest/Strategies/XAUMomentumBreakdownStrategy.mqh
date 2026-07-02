//+------------------------------------------------------------------+
//| XAUMomentumBreakdownStrategy.mqh — XAUUSD BB upper fade in bear   |
//+------------------------------------------------------------------+
#ifndef XAU_MOMENTUM_BREAKDOWN_STRATEGY_MQH
#define XAU_MOMENTUM_BREAKDOWN_STRATEGY_MQH

struct XAUMomentumBreakdownData
{
   string           symbol;
   bool             isInitialized;
   CTrade           trade;
   ENUM_TIMEFRAMES  regimeTF;
   ENUM_TIMEFRAMES  entryTF;
   int              regimeEmaPeriod;
   int              bbPeriod;
   double           bbDeviation;
   int              atrPeriod;
   double           slAtrMult;
   double           tpAtrMult;
   bool             useTrailing;
   double           trailAtrMult;
   ulong            magic;
   int              slippage;
   int              maxSpreadPoints;
   bool             closeUnprofitableOnNewSignal;
   int              h_regimeEma;
   int              h_bb;
   int              h_atr;
   datetime         lastBarTime;
};

bool XMB_Copy1(const int handle, const int buf, double &v)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, buf, 0, 1, b) < 1)
      return false;
   v = b[0];
   return true;
}

bool XMB_RegimeBearish(XAUMomentumBreakdownData &d)
{
   double ema = 0.0;
   if(!XMB_Copy1(d.h_regimeEma, 0, ema))
      return false;
   const double close1 = iClose(d.symbol, d.regimeTF, 1);
   return (close1 > 0.0 && ema > 0.0 && close1 < ema);
}

bool XMB_IsNewEntryBar(XAUMomentumBreakdownData &d)
{
   datetime t = iTime(d.symbol, d.entryTF, 0);
   if(t <= 0 || t == d.lastBarTime)
      return false;
   d.lastBarTime = t;
   return true;
}

bool InitXAUMomentumBreakdown(XAUMomentumBreakdownData &d,
                              const string symbol,
                              const ENUM_TIMEFRAMES regimeTF,
                              const ENUM_TIMEFRAMES entryTF,
                              const int regimeEmaPeriod,
                              const int bbPeriod,
                              const double bbDeviation,
                              const int atrPeriod,
                              const double slAtrMult,
                              const double tpAtrMult,
                              const bool useTrailing,
                              const double trailAtrMult,
                              const ulong magic,
                              const int slippage,
                              const int maxSpreadPoints)
{
   d.symbol = symbol;
   d.regimeTF = regimeTF;
   d.entryTF = entryTF;
   d.regimeEmaPeriod = regimeEmaPeriod;
   d.bbPeriod = bbPeriod;
   d.bbDeviation = bbDeviation;
   d.atrPeriod = atrPeriod;
   d.slAtrMult = slAtrMult;
   d.tpAtrMult = tpAtrMult;
   d.useTrailing = useTrailing;
   d.trailAtrMult = trailAtrMult;
   d.magic = magic;
   d.slippage = slippage;
   d.maxSpreadPoints = maxSpreadPoints;
   d.lastBarTime = 0;

   if(!SymbolSelect(symbol, true))
   {
      Print("XAUMomentumBreakdown: symbol not available: ", symbol);
      d.isInitialized = false;
      return false;
   }

   d.h_regimeEma = iMA(symbol, regimeTF, regimeEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   d.h_bb = iBands(symbol, entryTF, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
   d.h_atr = iATR(symbol, entryTF, atrPeriod);

   if(d.h_regimeEma == INVALID_HANDLE || d.h_bb == INVALID_HANDLE || d.h_atr == INVALID_HANDLE)
   {
      Print("XAUMomentumBreakdown: indicator init failed for ", symbol);
      d.isInitialized = false;
      return false;
   }

   d.trade.SetExpertMagicNumber((long)magic);
   d.trade.SetDeviationInPoints(slippage);
   d.trade.SetTypeFillingBySymbol(symbol);
   d.isInitialized = true;
   return true;
}

void DeinitXAUMomentumBreakdown(XAUMomentumBreakdownData &d)
{
   if(d.h_regimeEma != INVALID_HANDLE) IndicatorRelease(d.h_regimeEma);
   if(d.h_bb != INVALID_HANDLE) IndicatorRelease(d.h_bb);
   if(d.h_atr != INVALID_HANDLE) IndicatorRelease(d.h_atr);
   d.isInitialized = false;
}

void XMB_ManageShort(XAUMomentumBreakdownData &d)
{
   if(!PositionSelectByMagic(d.symbol, d.magic))
      return;

   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      return;

   if(!XMB_RegimeBearish(d))
   {
      d.trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      return;
   }

   double atr = 0.0;
   if(!XMB_Copy1(d.h_atr, 0, atr) || atr <= 0.0)
      return;

   const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   const double bid = SymbolInfoDouble(d.symbol, SYMBOL_BID);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);

   if(d.useTrailing)
   {
      const double trail = bid + atr * d.trailAtrMult;
      if(sl <= 0.0 || trail < sl)
         sl = trail;
   }

   if(tp <= 0.0 && d.tpAtrMult > 0.0)
      tp = entry - atr * d.tpAtrMult;

   if(sl > 0.0 || tp > 0.0)
      d.trade.PositionModify(PositionGetInteger(POSITION_TICKET), sl, tp);
}

void ProcessXAUMomentumBreakdown(XAUMomentumBreakdownData &d, const double lotSize)
{
   if(!d.isInitialized || lotSize <= 0.0)
      return;

   const long spread = SymbolInfoInteger(d.symbol, SYMBOL_SPREAD);
   if(spread > d.maxSpreadPoints)
      return;

   XMB_ManageShort(d);

   if(!XMB_IsNewEntryBar(d))
      return;

   if(PositionExistsByMagic(d.symbol, d.magic))
      return;

   if(!XMB_RegimeBearish(d))
      return;

   double upper = 0.0, middle = 0.0;
   if(!XMB_Copy1(d.h_bb, 1, upper) || !XMB_Copy1(d.h_bb, 0, middle))
      return;

   const double high1 = iHigh(d.symbol, d.entryTF, 1);
   const double close1 = iClose(d.symbol, d.entryTF, 1);
   if(high1 < upper || close1 >= upper)
      return;

   if(!United_MayOpenNewEntry(d.symbol, d.magic, false, d.trade, d.closeUnprofitableOnNewSignal))
      return;

   double atr = 0.0;
   if(!XMB_Copy1(d.h_atr, 0, atr) || atr <= 0.0)
      return;

   const double ask = SymbolInfoDouble(d.symbol, SYMBOL_ASK);
   const double sl = high1 + atr * d.slAtrMult;
   const double tp = (d.tpAtrMult > 0.0 ? ask - atr * d.tpAtrMult : middle);
   const double lots = United_NormalizeVolume(d.symbol, lotSize);

   d.trade.Sell(lots, d.symbol, 0.0, sl, tp, "XMB BB fade");
}

#endif
