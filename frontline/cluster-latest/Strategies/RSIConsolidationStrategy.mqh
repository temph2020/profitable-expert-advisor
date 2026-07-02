//+------------------------------------------------------------------+
//|                                    RSIConsolidationStrategy.mqh |
//| Ported from cluster-0/RSIConsolidation/RSIConsolidation.mq5     |
//+------------------------------------------------------------------+
#ifndef RSI_CONSOLIDATION_STRATEGY_MQH
#define RSI_CONSOLIDATION_STRATEGY_MQH

struct RSIConsolidationData
{
   string                symbol;
   bool                  isInitialized;
   CTrade                trade;
   ENUM_TIMEFRAMES       signalTF;
   bool                  entryOnNewBarOnly;
   int                   adxPeriod;
   double                adxMax;
   bool                  useATRRatioFilter;
   int                   atrPeriod;
   int                   atrSmaPeriod;
   double                atrRatioMax;
   bool                  useFlatEMAFilter;
   int                   emaFast;
   int                   emaSlow;
   double                emaSeparationMaxPct;
   int                   rsiPeriod;
   ENUM_APPLIED_PRICE    rsiPrice;
   double                rsiOversold;
   double                rsiOverbought;
   bool                  useRSIMeanExit;
   double                rsiExitLong;
   double                rsiExitShort;
   double                slAtrMult;
   double                tpAtrMult;
   int                   maxBarsInTrade;
   ulong                 magic;
   int                   slippage;
   int                   maxSpreadPoints;
   bool                  closeUnprofitableOnNewSignal;
   int                   h_rsi;
   int                   h_adx;
   int                   h_atr;
   int                   h_ema_fast;
   int                   h_ema_slow;
   datetime              lastBar;
};

bool RCO_Copy1(const int handle, double &v)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, 0, 1, b) < 1)
      return false;
   v = b[0];
   return true;
}

bool RCO_RsiBuffers(RSIConsolidationData &d, double &cur, double &prev, double &twoAgo)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(d.h_rsi, 0, 0, 3, b) < 3)
      return false;
   cur = b[0];
   prev = b[1];
   twoAgo = b[2];
   return true;
}

double RCO_NormalizeVolume(const string sym, double vol)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      vol = MathFloor(vol / step) * step;
   if(vol < minLot)
      vol = minLot;
   if(vol > maxLot)
      vol = maxLot;
   return vol;
}

int RCO_CurrentSpreadPoints(const string sym)
{
   long spread = 0;
   if(!SymbolInfoInteger(sym, SYMBOL_SPREAD, spread))
      return 999999;
   return (int)spread;
}

double RCO_MinStopsDistancePrice(const string sym)
{
   long lvl = 0;
   if(!SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL, lvl))
      return 0;
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0)
      return 0;
   return (double)lvl * pt;
}

bool RCO_RegimeIsConsolidation(RSIConsolidationData &d)
{
   double adx = 0;
   if(!RCO_Copy1(d.h_adx, adx))
      return false;
   if(adx >= d.adxMax)
      return false;

   if(d.useATRRatioFilter)
   {
      double atrArr[];
      ArraySetAsSeries(atrArr, true);
      if(CopyBuffer(d.h_atr, 0, 0, d.atrSmaPeriod + 1, atrArr) < d.atrSmaPeriod + 1)
         return false;
      double sum = 0;
      for(int i = 1; i <= d.atrSmaPeriod; i++)
         sum += atrArr[i];
      double smaAtr = sum / (double)d.atrSmaPeriod;
      if(smaAtr <= 0.0)
         return false;
      double ratio = atrArr[0] / smaAtr;
      if(ratio > d.atrRatioMax)
         return false;
   }

   if(d.useFlatEMAFilter)
   {
      double ef[], es[];
      ArraySetAsSeries(ef, true);
      ArraySetAsSeries(es, true);
      if(CopyBuffer(d.h_ema_fast, 0, 0, 1, ef) < 1)
         return false;
      if(CopyBuffer(d.h_ema_slow, 0, 0, 1, es) < 1)
         return false;
      double c = SymbolInfoDouble(d.symbol, SYMBOL_BID);
      if(c <= 0)
         return false;
      double sep = MathAbs(ef[0] - es[0]) / c * 100.0;
      if(sep > d.emaSeparationMaxPct)
         return false;
   }

   return true;
}

bool RCO_EntryBuyCross(RSIConsolidationData &d, const double twoAgo, const double prev)
{
   return (twoAgo <= d.rsiOversold && prev > d.rsiOversold);
}

bool RCO_EntrySellCross(RSIConsolidationData &d, const double twoAgo, const double prev)
{
   return (twoAgo >= d.rsiOverbought && prev < d.rsiOverbought);
}

void RCO_TryCloseByRSI(RSIConsolidationData &d, const ENUM_POSITION_TYPE typ, const double rsi)
{
   ulong tk = GetPositionTicketByMagic(d.symbol, d.magic);
   if(tk == 0 || !PositionSelectByTicketSymbolAndMagic(tk, d.symbol, d.magic))
      return;
   if(!d.useRSIMeanExit)
      return;
   if(typ == POSITION_TYPE_BUY && rsi >= d.rsiExitLong)
      d.trade.PositionClose(tk);
   else if(typ == POSITION_TYPE_SELL && rsi <= d.rsiExitShort)
      d.trade.PositionClose(tk);
}

void RCO_ManageOpenPosition(RSIConsolidationData &d, const double rsi)
{
   ulong tk = GetPositionTicketByMagic(d.symbol, d.magic);
   if(tk == 0 || !PositionSelectByTicketSymbolAndMagic(tk, d.symbol, d.magic))
      return;
   ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
   int barsAgo = iBarShift(d.symbol, d.signalTF, openT, false);
   if(barsAgo >= 0 && barsAgo >= d.maxBarsInTrade)
   {
      d.trade.PositionClose(tk);
      return;
   }
   RCO_TryCloseByRSI(d, typ, rsi);
}

bool InitRSIConsolidation(RSIConsolidationData &d,
   const string inpSymbol,
   const ENUM_TIMEFRAMES signalTF,
   const bool entryOnNewBarOnly,
   const int adxPeriod,
   const double adxMax,
   const bool useATRRatioFilter,
   const int atrPeriod,
   const int atrSmaPeriod,
   const double atrRatioMax,
   const bool useFlatEMAFilter,
   const int emaFast,
   const int emaSlow,
   const double emaSeparationMaxPct,
   const int rsiPeriod,
   const ENUM_APPLIED_PRICE rsiPrice,
   const double rsiOversold,
   const double rsiOverbought,
   const bool useRSIMeanExit,
   const double rsiExitLong,
   const double rsiExitShort,
   const double slAtrMult,
   const double tpAtrMult,
   const int maxBarsInTrade,
   const ulong magic,
   const int slippage,
   const int maxSpreadPoints)
{
   d.isInitialized = false;
   d.symbol = inpSymbol;
   StringTrimLeft(d.symbol);
   StringTrimRight(d.symbol);
   if(StringLen(d.symbol) == 0)
      d.symbol = _Symbol;

   d.signalTF = signalTF;
   d.entryOnNewBarOnly = entryOnNewBarOnly;
   d.adxPeriod = adxPeriod;
   d.adxMax = adxMax;
   d.useATRRatioFilter = useATRRatioFilter;
   d.atrPeriod = atrPeriod;
   d.atrSmaPeriod = atrSmaPeriod;
   d.atrRatioMax = atrRatioMax;
   d.useFlatEMAFilter = useFlatEMAFilter;
   d.emaFast = emaFast;
   d.emaSlow = emaSlow;
   d.emaSeparationMaxPct = emaSeparationMaxPct;
   d.rsiPeriod = rsiPeriod;
   d.rsiPrice = rsiPrice;
   d.rsiOversold = rsiOversold;
   d.rsiOverbought = rsiOverbought;
   d.useRSIMeanExit = useRSIMeanExit;
   d.rsiExitLong = rsiExitLong;
   d.rsiExitShort = rsiExitShort;
   d.slAtrMult = slAtrMult;
   d.tpAtrMult = tpAtrMult;
   d.maxBarsInTrade = maxBarsInTrade;
   d.magic = magic;
   d.slippage = slippage;
   d.maxSpreadPoints = maxSpreadPoints;
   d.lastBar = 0;
   d.h_rsi = INVALID_HANDLE;
   d.h_adx = INVALID_HANDLE;
   d.h_atr = INVALID_HANDLE;
   d.h_ema_fast = INVALID_HANDLE;
   d.h_ema_slow = INVALID_HANDLE;
   d.isInitialized = false;

   if(!SymbolSelect(d.symbol, true))
   {
      Print("RSIConsolidation: SymbolSelect failed: ", d.symbol);
      return false;
   }

   d.trade.SetExpertMagicNumber((long)d.magic);
   d.trade.SetDeviationInPoints(d.slippage);
   d.trade.SetTypeFillingBySymbol(d.symbol);

   d.h_rsi = iRSI(d.symbol, d.signalTF, d.rsiPeriod, d.rsiPrice);
   d.h_adx = iADX(d.symbol, d.signalTF, d.adxPeriod);
   d.h_atr = iATR(d.symbol, d.signalTF, d.atrPeriod);
   d.h_ema_fast = iMA(d.symbol, d.signalTF, d.emaFast, 0, MODE_EMA, PRICE_CLOSE);
   d.h_ema_slow = iMA(d.symbol, d.signalTF, d.emaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(d.h_rsi == INVALID_HANDLE || d.h_adx == INVALID_HANDLE || d.h_atr == INVALID_HANDLE
      || d.h_ema_fast == INVALID_HANDLE || d.h_ema_slow == INVALID_HANDLE)
   {
      Print("RSIConsolidation: indicator init failed");
      DeinitRSIConsolidation(d);
      return false;
   }

   d.isInitialized = true;
   Print("RSIConsolidation: symbol=", d.symbol, " TF=", EnumToString(d.signalTF));
   return true;
}

void DeinitRSIConsolidation(RSIConsolidationData &d)
{
   if(d.h_rsi != INVALID_HANDLE)
      IndicatorRelease(d.h_rsi);
   if(d.h_adx != INVALID_HANDLE)
      IndicatorRelease(d.h_adx);
   if(d.h_atr != INVALID_HANDLE)
      IndicatorRelease(d.h_atr);
   if(d.h_ema_fast != INVALID_HANDLE)
      IndicatorRelease(d.h_ema_fast);
   if(d.h_ema_slow != INVALID_HANDLE)
      IndicatorRelease(d.h_ema_slow);
   d.h_rsi = INVALID_HANDLE;
   d.h_adx = INVALID_HANDLE;
   d.h_atr = INVALID_HANDLE;
   d.h_ema_fast = INVALID_HANDLE;
   d.h_ema_slow = INVALID_HANDLE;
   d.isInitialized = false;
}

bool RCO_EnoughHistory(RSIConsolidationData &d)
{
   int need = MathMax(d.rsiPeriod + 3, MathMax(d.adxPeriod + 2, d.atrSmaPeriod + 3));
   if(Bars(d.symbol, d.signalTF) < need)
      return false;
   return true;
}

void ProcessRSIConsolidation(RSIConsolidationData &d, const double lots)
{
   if(!d.isInitialized)
      return;

   if(!RCO_EnoughHistory(d))
      return;

   if(d.maxSpreadPoints > 0 && RCO_CurrentSpreadPoints(d.symbol) > d.maxSpreadPoints)
      return;

   double rsi, rsiPrev, rsi2;
   if(!RCO_RsiBuffers(d, rsi, rsiPrev, rsi2))
      return;

   datetime barTime = iTime(d.symbol, d.signalTF, 0);
   bool isNew = (barTime != d.lastBar);

   if(PositionExistsByMagic(d.symbol, d.magic))
   {
      RCO_ManageOpenPosition(d, rsi);
      if(isNew)
         d.lastBar = barTime;
      if(!d.closeUnprofitableOnNewSignal)
         return;
   }

   if(d.entryOnNewBarOnly && !isNew)
      return;

   d.lastBar = barTime;

   if(!RCO_RegimeIsConsolidation(d))
      return;

   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(d.h_atr, 0, 0, 1, atrArr) < 1)
      return;
   double atr = atrArr[0];
   int dig = (int)SymbolInfoInteger(d.symbol, SYMBOL_DIGITS);

   double slDist = atr * d.slAtrMult;
   double tpDist = atr * d.tpAtrMult;
   double minD = RCO_MinStopsDistancePrice(d.symbol);
   if(slDist < minD)
      slDist = minD;
   if(tpDist < minD)
      tpDist = minD;

   double vol = RCO_NormalizeVolume(d.symbol, lots);

   if(RCO_EntryBuyCross(d, rsi2, rsiPrev))
   {
      if(!United_MayOpenNewEntry(d.symbol, d.magic, true, d.trade, d.closeUnprofitableOnNewSignal))
         return;
      double ask = SymbolInfoDouble(d.symbol, SYMBOL_ASK);
      double sl = ask - slDist;
      double tp = ask + tpDist;
      sl = NormalizeDouble(sl, dig);
      tp = NormalizeDouble(tp, dig);
      if(!d.trade.Buy(vol, d.symbol, ask, sl, tp, "RSIConsolidation BUY"))
         Print("RSIConsolidation BUY failed | retcode=", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
   }
   else if(RCO_EntrySellCross(d, rsi2, rsiPrev))
   {
      if(!United_MayOpenNewEntry(d.symbol, d.magic, false, d.trade, d.closeUnprofitableOnNewSignal))
         return;
      double bid = SymbolInfoDouble(d.symbol, SYMBOL_BID);
      double sl = bid + slDist;
      double tp = bid - tpDist;
      sl = NormalizeDouble(sl, dig);
      tp = NormalizeDouble(tp, dig);
      if(!d.trade.Sell(vol, d.symbol, bid, sl, tp, "RSIConsolidation SELL"))
         Print("RSIConsolidation SELL failed | retcode=", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
   }
}

#endif // RSI_CONSOLIDATION_STRATEGY_MQH
