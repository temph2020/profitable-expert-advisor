//+------------------------------------------------------------------+
//| XAUBearTrendStrategy.mqh — XAUUSD bear-regime rally-fade shorts  |
//+------------------------------------------------------------------+
#ifndef XAU_BEAR_TREND_STRATEGY_MQH
#define XAU_BEAR_TREND_STRATEGY_MQH

struct XAUBearTrendData
{
   string           symbol;
   bool             isInitialized;
   CTrade           trade;
   ENUM_TIMEFRAMES  regimeTF;
   ENUM_TIMEFRAMES  entryTF;
   int              regimeEmaPeriod;
   int              rsiPeriod;
   double           rsiArmLevel;
   double           rsiTriggerLevel;
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
   int              h_rsi;
   int              h_atr;
   datetime         lastBarTime;
   bool             rsiArmed;
};

bool XBT_Copy1(const int handle, double &v)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, 0, 1, b) < 1)
      return false;
   v = b[0];
   return true;
}

bool XBT_RegimeBearish(XAUBearTrendData &d)
{
   double ema = 0.0;
   if(!XBT_Copy1(d.h_regimeEma, ema))
      return false;
   const double close1 = iClose(d.symbol, d.regimeTF, 1);
   return (close1 > 0.0 && ema > 0.0 && close1 < ema);
}

bool XBT_IsNewEntryBar(XAUBearTrendData &d)
{
   datetime t = iTime(d.symbol, d.entryTF, 0);
   if(t <= 0 || t == d.lastBarTime)
      return false;
   d.lastBarTime = t;
   return true;
}

bool InitXAUBearTrend(XAUBearTrendData &d,
                      const string symbol,
                      const ENUM_TIMEFRAMES regimeTF,
                      const ENUM_TIMEFRAMES entryTF,
                      const int regimeEmaPeriod,
                      const int rsiPeriod,
                      const double rsiArmLevel,
                      const double rsiTriggerLevel,
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
   d.rsiPeriod = rsiPeriod;
   d.rsiArmLevel = rsiArmLevel;
   d.rsiTriggerLevel = rsiTriggerLevel;
   d.atrPeriod = atrPeriod;
   d.slAtrMult = slAtrMult;
   d.tpAtrMult = tpAtrMult;
   d.useTrailing = useTrailing;
   d.trailAtrMult = trailAtrMult;
   d.magic = magic;
   d.slippage = slippage;
   d.maxSpreadPoints = maxSpreadPoints;
   d.lastBarTime = 0;
   d.rsiArmed = false;

   if(!SymbolSelect(symbol, true))
   {
      Print("XAUBearTrend: symbol not available: ", symbol);
      d.isInitialized = false;
      return false;
   }

   d.h_regimeEma = iMA(symbol, regimeTF, regimeEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   d.h_rsi = iRSI(symbol, entryTF, rsiPeriod, PRICE_CLOSE);
   d.h_atr = iATR(symbol, entryTF, atrPeriod);

   if(d.h_regimeEma == INVALID_HANDLE || d.h_rsi == INVALID_HANDLE || d.h_atr == INVALID_HANDLE)
   {
      Print("XAUBearTrend: indicator init failed for ", symbol);
      d.isInitialized = false;
      return false;
   }

   d.trade.SetExpertMagicNumber((long)magic);
   d.trade.SetDeviationInPoints(slippage);
   d.trade.SetTypeFillingBySymbol(symbol);
   d.isInitialized = true;
   return true;
}

void DeinitXAUBearTrend(XAUBearTrendData &d)
{
   if(d.h_regimeEma != INVALID_HANDLE) IndicatorRelease(d.h_regimeEma);
   if(d.h_rsi != INVALID_HANDLE) IndicatorRelease(d.h_rsi);
   if(d.h_atr != INVALID_HANDLE) IndicatorRelease(d.h_atr);
   d.isInitialized = false;
}

void XBT_ManageShort(XAUBearTrendData &d)
{
   if(!PositionSelectByMagic(d.symbol, d.magic))
      return;

   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      return;

   if(!XBT_RegimeBearish(d))
   {
      d.trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      d.rsiArmed = false;
      return;
   }

   double atr = 0.0;
   if(!XBT_Copy1(d.h_atr, atr) || atr <= 0.0)
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

void ProcessXAUBearTrend(XAUBearTrendData &d, const double lotSize)
{
   if(!d.isInitialized || lotSize <= 0.0)
      return;

   const long spread = SymbolInfoInteger(d.symbol, SYMBOL_SPREAD);
   if(spread > d.maxSpreadPoints)
      return;

   XBT_ManageShort(d);

   if(!XBT_IsNewEntryBar(d))
      return;

   if(!XBT_RegimeBearish(d))
   {
      d.rsiArmed = false;
      return;
   }

   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(d.h_rsi, 0, 1, 2, rsi) < 2)
      return;

   if(rsi[0] >= d.rsiArmLevel)
      d.rsiArmed = true;

   if(!d.rsiArmed || rsi[0] >= d.rsiTriggerLevel)
      return;

   if(PositionExistsByMagic(d.symbol, d.magic))
      return;

   if(!United_MayOpenNewEntry(d.symbol, d.magic, false, d.trade, d.closeUnprofitableOnNewSignal))
      return;

   double atr = 0.0;
   if(!XBT_Copy1(d.h_atr, atr) || atr <= 0.0)
      return;

   const double barHigh = iHigh(d.symbol, d.entryTF, 1);
   const double ask = SymbolInfoDouble(d.symbol, SYMBOL_ASK);
   const double sl = barHigh + atr * d.slAtrMult;
   const double tp = (d.tpAtrMult > 0.0 ? ask - atr * d.tpAtrMult : 0.0);
   const double lots = United_NormalizeVolume(d.symbol, lotSize);

   if(d.trade.Sell(lots, d.symbol, 0.0, sl, tp, "XBT rally fade"))
      d.rsiArmed = false;
}

#endif
