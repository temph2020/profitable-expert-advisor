//+------------------------------------------------------------------+
//|                                       USDJPYBusterStrategy.mqh   |
//|  Ian-style USDJPY Asian range breakout for United EA cluster     |
//+------------------------------------------------------------------+
#ifndef USDJPY_BUSTER_STRATEGY_MQH
#define USDJPY_BUSTER_STRATEGY_MQH

enum ENUM_UB_RISK_MODE
{
   UB_RISK_FIXED_MONEY = 0,
   UB_RISK_PERCENT     = 1,
   UB_RISK_FIXED_LOTS  = 2
};

struct USDJPYBusterData
{
   string           symbol;
   bool             isInitialized;
   CTrade           trade;

   int              rangeStartHour;
   int              rangeEndHour;
   int              closeHour;
   ENUM_TIMEFRAMES  rangeTF;
   int              minRangePoints;
   double           orderBufferPoints;

   bool             firstTradeOnly;
   bool             allowLong;
   bool             allowShort;
   bool             useTakeProfit;
   double           takeProfitPoints;

   ENUM_UB_RISK_MODE riskMode;
   double           fixedRiskMoney;
   double           riskPercent;
   double           fixedLots;

   int              magic;
   int              slippage;
   int              maxSpreadPoints;
   bool             drawRange;
   bool             debugLog;
   bool             closeUnprofitableOnNewSignal;

   int              dayKey;
   double           rangeHigh;
   double           rangeLow;
   bool             rangeBuilt;
   bool             rangeSkipDay;
   bool             ordersPlaced;
   bool             dayClosed;
   bool             firstFillDone;
   int              entriesToday;
   int              lastPosCount;
};

//+------------------------------------------------------------------+
int UB_DayKey(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

datetime UB_DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

void UB_ResetDayState(USDJPYBusterData &d)
{
   d.rangeHigh = 0.0;
   d.rangeLow  = 0.0;
   d.rangeBuilt   = false;
   d.rangeSkipDay = false;
   d.ordersPlaced = false;
   d.dayClosed    = false;
   d.firstFillDone = false;
   d.entriesToday = 0;
   d.lastPosCount = 0;
}

void UB_Dbg(USDJPYBusterData &d, const string msg)
{
   if(d.debugLog)
      Print("USDJPYBuster: ", msg);
}

double UB_NormalizeLots(const string sym, double lots)
{
   const double mn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   const double mx = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   const double st = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(st > 0.0)
      lots = MathFloor(lots / st) * st;
   if(lots < mn)
      lots = mn;
   if(lots > mx)
      lots = mx;
   return lots;
}

double UB_NormalizePrice(const string sym, const double price)
{
   const int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return NormalizeDouble(price, dg);
}

double UB_MinStopDistance(const string sym)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const long lvl  = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax((double)lvl * pt, pt);
}

bool UB_SpreadOk(const USDJPYBusterData &d)
{
   return ((double)SymbolInfoInteger(d.symbol, SYMBOL_SPREAD) <= (double)d.maxSpreadPoints);
}

bool UB_MoneyPerLotAtSl(const string sym, const ENUM_ORDER_TYPE type,
                        const double openPrice, const double slPrice, double &lossPerLot)
{
   lossPerLot = 0.0;
   double p = 0.0;
   if(!OrderCalcProfit(type, sym, 1.0, openPrice, slPrice, p))
      return false;
   lossPerLot = MathAbs(p);
   return (lossPerLot > 0.0);
}

double UB_LotsForOrder(USDJPYBusterData &d, const ENUM_ORDER_TYPE type,
                       const double entry, const double sl, const double scaledFixedLots)
{
   if(d.riskMode == UB_RISK_FIXED_LOTS)
      return UB_NormalizeLots(d.symbol, scaledFixedLots);

   double perLotLoss = 0.0;
   if(!UB_MoneyPerLotAtSl(d.symbol, type, entry, sl, perLotLoss) || perLotLoss <= 0.0)
      return UB_NormalizeLots(d.symbol, scaledFixedLots);

   double riskMoney = d.fixedRiskMoney;
   if(d.riskMode == UB_RISK_PERCENT)
      riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (d.riskPercent / 100.0);

   if(riskMoney <= 0.0)
      return UB_NormalizeLots(d.symbol, scaledFixedLots);

   return UB_NormalizeLots(d.symbol, riskMoney / perLotLoss);
}

bool UB_BuildRange(USDJPYBusterData &d, const datetime serverNow, double &hi, double &lo)
{
   hi = -DBL_MAX;
   lo = DBL_MAX;

   const datetime day0   = UB_DayStart(serverNow);
   const datetime tStart = day0 + (datetime)d.rangeStartHour * 3600;
   const datetime tEnd   = day0 + (datetime)d.rangeEndHour * 3600;
   if(tEnd <= tStart)
      return false;

   MqlRates rates[];
   const int copied = CopyRates(d.symbol, d.rangeTF, tStart, tEnd, rates);
   if(copied <= 0)
      return false;

   for(int i = 0; i < copied; i++)
   {
      if(rates[i].time < tStart || rates[i].time >= tEnd)
         continue;
      hi = MathMax(hi, rates[i].high);
      lo = MathMin(lo, rates[i].low);
   }

   if(hi <= -DBL_MAX || lo >= DBL_MAX || hi <= lo)
      return false;

   const double pt = SymbolInfoDouble(d.symbol, SYMBOL_POINT);
   if((hi - lo) / pt < (double)d.minRangePoints)
      return false;

   hi = UB_NormalizePrice(d.symbol, hi);
   lo = UB_NormalizePrice(d.symbol, lo);
   return true;
}

bool UB_AdjustStopsForBroker(USDJPYBusterData &d, const ENUM_ORDER_TYPE type,
                             const double entry, double &sl, double &tp)
{
   const double minD = UB_MinStopDistance(d.symbol);
   if(minD <= 0.0)
      return true;

   if(type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_STOP)
   {
      if(entry - sl < minD)
         sl = entry - minD;
      if(d.useTakeProfit && tp > 0.0 && tp - entry < minD)
         tp = entry + minD;
   }
   else
   {
      if(sl - entry < minD)
         sl = entry + minD;
      if(d.useTakeProfit && tp > 0.0 && entry - tp < minD)
         tp = entry - minD;
   }
   sl = UB_NormalizePrice(d.symbol, sl);
   if(d.useTakeProfit)
      tp = UB_NormalizePrice(d.symbol, tp);
   return true;
}

bool UB_BuyStopValid(const string sym, const double buyStopPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return false;
   return (buyStopPrice > tick.ask + UB_MinStopDistance(sym));
}

bool UB_SellStopValid(const string sym, const double sellStopPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return false;
   return (sellStopPrice < tick.bid - UB_MinStopDistance(sym));
}

int UB_CountMagicPositions(USDJPYBusterData &d)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != d.symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != d.magic)
         continue;
      n++;
   }
   return n;
}

int UB_CountMagicPendings(USDJPYBusterData &d)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != d.symbol)
         continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != d.magic)
         continue;
      n++;
   }
   return n;
}

void UB_DeleteAllMagicPendings(USDJPYBusterData &d)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != d.symbol)
         continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != d.magic)
         continue;
      d.trade.OrderDelete(ticket);
   }
}

void UB_CloseAllMagicPositions(USDJPYBusterData &d)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != d.symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != d.magic)
         continue;
      d.trade.PositionClose(t);
   }
}

void UB_EndOfDayClose(USDJPYBusterData &d)
{
   UB_CloseAllMagicPositions(d);
   UB_DeleteAllMagicPendings(d);
   d.dayClosed = true;
   d.ordersPlaced = false;
}

int UB_MaxEntriesPerDay(const USDJPYBusterData &d)
{
   return (d.firstTradeOnly ? 1 : 2);
}

void UB_TrackEntries(USDJPYBusterData &d)
{
   const int pc = UB_CountMagicPositions(d);
   if(pc > d.lastPosCount)
      d.entriesToday += (pc - d.lastPosCount);
   d.lastPosCount = pc;

   if(d.entriesToday >= UB_MaxEntriesPerDay(d))
      UB_DeleteAllMagicPendings(d);
}

bool UB_PlaceBreakoutOrders(USDJPYBusterData &d, const double scaledFixedLots, const double riskScale)
{
   if(!UB_SpreadOk(d))
   {
      UB_Dbg(d, "spread too wide — retry later");
      return false;
   }

   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) <= 0.0)
   {
      UB_Dbg(d, "no free margin — skip placement");
      return false;
   }

   const double pt  = SymbolInfoDouble(d.symbol, SYMBOL_POINT);
   const double buf = d.orderBufferPoints * pt;

   const double buyPrice  = UB_NormalizePrice(d.symbol, d.rangeHigh + buf);
   const double sellPrice = UB_NormalizePrice(d.symbol, d.rangeLow - buf);
   const double buySl     = UB_NormalizePrice(d.symbol, d.rangeLow);
   const double sellSl    = UB_NormalizePrice(d.symbol, d.rangeHigh);

   double buyTp = 0.0, sellTp = 0.0;
   if(d.useTakeProfit && d.takeProfitPoints > 0.0)
   {
      buyTp  = UB_NormalizePrice(d.symbol, buyPrice + d.takeProfitPoints * pt);
      sellTp = UB_NormalizePrice(d.symbol, sellPrice - d.takeProfitPoints * pt);
   }

   double buySlAdj = buySl, sellSlAdj = sellSl;
   double buyTpAdj = buyTp, sellTpAdj = sellTp;
   UB_AdjustStopsForBroker(d, ORDER_TYPE_BUY_STOP, buyPrice, buySlAdj, buyTpAdj);
   UB_AdjustStopsForBroker(d, ORDER_TYPE_SELL_STOP, sellPrice, sellSlAdj, sellTpAdj);

   const double savedFixed = d.fixedRiskMoney;
   if(d.riskMode == UB_RISK_FIXED_MONEY && riskScale > 0.0)
      d.fixedRiskMoney = savedFixed * riskScale;

   int placed = 0;

   if(d.allowLong && UB_BuyStopValid(d.symbol, buyPrice))
   {
      const double lots = UB_LotsForOrder(d, ORDER_TYPE_BUY, buyPrice, buySlAdj, scaledFixedLots);
      if(d.trade.BuyStop(lots, buyPrice, d.symbol, buySlAdj, buyTpAdj, ORDER_TIME_DAY, 0, "UB range up"))
         placed++;
      else
         Print("USDJPYBuster BuyStop failed ", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
   }
   else if(d.allowLong)
      UB_Dbg(d, "buy stop skipped — price already at/above range high");

   if(d.allowShort && UB_SellStopValid(d.symbol, sellPrice))
   {
      const double lots = UB_LotsForOrder(d, ORDER_TYPE_SELL, sellPrice, sellSlAdj, scaledFixedLots);
      if(d.trade.SellStop(lots, sellPrice, d.symbol, sellSlAdj, sellTpAdj, ORDER_TIME_DAY, 0, "UB range dn"))
         placed++;
      else
         Print("USDJPYBuster SellStop failed ", d.trade.ResultRetcode(), " ", d.trade.ResultRetcodeDescription());
   }
   else if(d.allowShort)
      UB_Dbg(d, "sell stop skipped — price already at/below range low");

   d.fixedRiskMoney = savedFixed;
   return (placed > 0);
}

void UB_HandleFirstFillRule(USDJPYBusterData &d)
{
   if(!d.firstTradeOnly || d.firstFillDone)
      return;
   if(UB_CountMagicPositions(d) <= 0)
      return;
   UB_DeleteAllMagicPendings(d);
   d.firstFillDone = true;
}

//+------------------------------------------------------------------+
bool InitUSDJPYBuster(USDJPYBusterData &d,
                      const string symbol,
                      const int rangeStartHour,
                      const int rangeEndHour,
                      const int closeHour,
                      const ENUM_TIMEFRAMES rangeTF,
                      const int minRangePoints,
                      const double orderBufferPoints,
                      const bool firstTradeOnly,
                      const bool allowLong,
                      const bool allowShort,
                      const bool useTakeProfit,
                      const double takeProfitPoints,
                      const ENUM_UB_RISK_MODE riskMode,
                      const double fixedRiskMoney,
                      const double riskPercent,
                      const double fixedLots,
                      const int magic,
                      const int slippage,
                      const int maxSpreadPoints,
                      const bool drawRange,
                      const bool debugLog = false)
{
   d.symbol = symbol;
   d.rangeStartHour = rangeStartHour;
   d.rangeEndHour = rangeEndHour;
   d.closeHour = closeHour;
   d.rangeTF = rangeTF;
   d.minRangePoints = minRangePoints;
   d.orderBufferPoints = orderBufferPoints;
   d.firstTradeOnly = firstTradeOnly;
   d.allowLong = allowLong;
   d.allowShort = allowShort;
   d.useTakeProfit = useTakeProfit;
   d.takeProfitPoints = takeProfitPoints;
   d.riskMode = riskMode;
   d.fixedRiskMoney = fixedRiskMoney;
   d.riskPercent = riskPercent;
   d.fixedLots = fixedLots;
   d.magic = magic;
   d.slippage = slippage;
   d.maxSpreadPoints = maxSpreadPoints;
   d.drawRange = drawRange;
   d.debugLog = debugLog;

   if(!SymbolSelect(symbol, true))
   {
      Print("USDJPYBuster: symbol not available: ", symbol);
      d.isInitialized = false;
      return false;
   }

   if(rangeEndHour <= rangeStartHour)
   {
      Print("USDJPYBuster: rangeEndHour must be > rangeStartHour");
      d.isInitialized = false;
      return false;
   }

   d.trade.SetExpertMagicNumber(magic);
   d.trade.SetDeviationInPoints(slippage);
   d.trade.SetTypeFillingBySymbol(symbol);

   d.dayKey = UB_DayKey(TimeTradeServer());
   UB_ResetDayState(d);
   d.isInitialized = true;

   Print("USDJPYBuster: ", symbol,
         " range ", rangeStartHour, ":00–", rangeEndHour, ":00",
         " place@", rangeEndHour, ":00 close@", closeHour, ":00",
         " firstOnly=", (firstTradeOnly ? "Y" : "N"));
   return true;
}

void DeinitUSDJPYBuster(USDJPYBusterData &d)
{
   if(!d.isInitialized)
      return;
   d.isInitialized = false;
}

void ProcessUSDJPYBuster(USDJPYBusterData &d, const double scaledFixedLots, const double riskScale)
{
   if(!d.isInitialized)
      return;

   const datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   const int today = UB_DayKey(now);
   if(today != d.dayKey)
   {
      d.dayKey = today;
      UB_ResetDayState(d);
   }

   if(dt.hour >= d.closeHour && !d.dayClosed)
   {
      UB_EndOfDayClose(d);
      return;
   }

   if(d.dayClosed)
      return;

   UB_TrackEntries(d);
   UB_HandleFirstFillRule(d);

   if(d.entriesToday >= UB_MaxEntriesPerDay(d))
   {
      UB_DeleteAllMagicPendings(d);
      d.ordersPlaced = true;
      return;
   }

   if(dt.hour < d.rangeEndHour || dt.hour >= d.closeHour)
      return;

   if(d.ordersPlaced || d.rangeSkipDay)
      return;

   if(UB_CountMagicPendings(d) > 0)
   {
      d.ordersPlaced = true;
      return;
   }

   if(UB_CountMagicPositions(d) > 0)
   {
      if(!d.closeUnprofitableOnNewSignal
         || !United_PrepareEntrySlot(d.trade, d.symbol, (ulong)d.magic, d.closeUnprofitableOnNewSignal))
      {
         d.ordersPlaced = true;
         return;
      }
   }

   if(!d.rangeBuilt)
   {
      if(!UB_BuildRange(d, now, d.rangeHigh, d.rangeLow))
      {
         UB_Dbg(d, "range not ready or too narrow — retry until " + IntegerToString(d.closeHour) + ":00");
         return;
      }
      d.rangeBuilt = true;
   }

   if(UB_PlaceBreakoutOrders(d, scaledFixedLots, riskScale))
   {
      d.ordersPlaced = true;
      return;
   }

   if(!d.allowLong && !d.allowShort)
      d.rangeSkipDay = true;
}

#endif
