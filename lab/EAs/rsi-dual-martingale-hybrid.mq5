//+------------------------------------------------------------------+
//|                                  rsi-dual-martingale-hybrid.mq5  |
//| Two robots: RSI reversal martingale + RSI midpoint trend helper  |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- core
input ENUM_TIMEFRAMES InpTf                 = PERIOD_M5;
input int             InpRsiLen             = 14;
input double          InpRsiOverbought      = 70.0;
input double          InpRsiOversold        = 30.0;
input double          InpRsiMid             = 50.0;

//--- money
input double          InpBaseLot            = 0.01;
input int             InpSlippagePts        = 30;
input ulong           InpMagicBase          = 2026042501;

//--- robot A: RSI reversal martingale
input bool            InpEnableReversalMartingale = true;
input double          InpMartingaleMult            = 1.7;
input int             InpMartingaleStepPts         = 300;
input int             InpMartingaleMaxLevels       = 6;

//--- robot B: reverse martingale trend follow (RSI cross midpoint)
input bool            InpEnableTrendReverseMartingale = true;
input double          InpTrendPyramidMult             = 1.5;
input int             InpTrendPyramidStepPts          = 250;
input int             InpTrendMaxLevels               = 5;

//--- rescue / coordination
input bool            InpEnableRescue               = true;
input double          InpTroubleLossMoney           = -8.0;  // martingale basket in trouble below this
input double          InpRescueLotMult              = 2.0;   // base lot multiplier for rescue trade
input int             InpRescueCooldownBars         = 3;

CTrade g_trade;
int    g_hRsi = INVALID_HANDLE;
double g_rsi[];

datetime g_lastBar = 0;
int      g_lastRescueBarIndex = -1000000;

enum RobotDirection
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

// Magic map:
// base + 1 : reversal martingale basket
// base + 2 : trend reverse-martingale basket
// base + 3 : rescue positions
ulong MagicRev()    { return InpMagicBase + 1; }
ulong MagicTrend()  { return InpMagicBase + 2; }
ulong MagicRescue() { return InpMagicBase + 3; }

int OnInit()
{
   g_trade.SetDeviationInPoints(InpSlippagePts);
   SetTradeFillingBySymbol();

   g_hRsi = iRSI(_Symbol, InpTf, InpRsiLen, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE)
      return INIT_FAILED;

   ArraySetAsSeries(g_rsi, true);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hRsi != INVALID_HANDLE)
      IndicatorRelease(g_hRsi);
}

void OnTick()
{
   if(CopyBuffer(g_hRsi, 0, 0, 10, g_rsi) < 10)
      return;

   // Rescue management can run every tick.
   ManageRescueCoordination();

   datetime t = iTime(_Symbol, InpTf, 0);
   if(t == g_lastBar)
      return;
   g_lastBar = t;

   if(InpEnableReversalMartingale)
      RunReversalMartingale();

   if(InpEnableTrendReverseMartingale)
      RunTrendReverseMartingale();
}

void RunReversalMartingale()
{
   ulong magic = MagicRev();
   int count = BasketCountByMagic(magic);
   double rsi1 = g_rsi[1];

   // No fixed TP/SL: close reversal basket when mean-reversion reaches RSI midpoint.
   RobotDirection dir = BasketDirectionByMagic(magic);
   if(count > 0 &&
      ((dir == DIR_BUY && rsi1 >= InpRsiMid) ||
       (dir == DIR_SELL && rsi1 <= InpRsiMid)))
   {
      CloseBasketByMagic(magic);
      return;
   }

   double rsi2 = g_rsi[2];

   if(count == 0)
   {
      if(rsi2 < InpRsiOversold && rsi1 > InpRsiOversold)
      {
         OpenMarketByDirection(magic, DIR_BUY, NormalizeVolume(InpBaseLot), "REV start");
         return;
      }
      if(rsi2 > InpRsiOverbought && rsi1 < InpRsiOverbought)
      {
         OpenMarketByDirection(magic, DIR_SELL, NormalizeVolume(InpBaseLot), "REV start");
         return;
      }
      return;
   }

   if(dir == DIR_NONE || count >= InpMartingaleMaxLevels)
      return;

   double lastEntry = LastEntryPriceByMagic(magic);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   bool adverseEnough = false;
   if(dir == DIR_BUY)
      adverseEnough = (lastEntry - bid) >= (InpMartingaleStepPts * pt);
   else if(dir == DIR_SELL)
      adverseEnough = (ask - lastEntry) >= (InpMartingaleStepPts * pt);

   if(!adverseEnough)
      return;

   double lot = NormalizeVolume(InpBaseLot * MathPow(InpMartingaleMult, count));
   OpenMarketByDirection(magic, dir, lot, "REV scale");
}

void RunTrendReverseMartingale()
{
   ulong magic = MagicTrend();
   int count = BasketCountByMagic(magic);
   RobotDirection dir = BasketDirectionByMagic(magic);
   double basketProfit = BasketProfitByMagic(magic);
   double rsi1 = g_rsi[1];
   double rsi2 = g_rsi[2];

   // No fixed TP/SL: close trend basket when RSI crosses back through midpoint.
   if(count > 0 &&
      ((dir == DIR_BUY && rsi2 > InpRsiMid && rsi1 < InpRsiMid) ||
       (dir == DIR_SELL && rsi2 < InpRsiMid && rsi1 > InpRsiMid)))
   {
      CloseBasketByMagic(magic);
      return;
   }

   if(count == 0)
   {
      if(rsi2 < InpRsiMid && rsi1 > InpRsiMid)
      {
         OpenMarketByDirection(magic, DIR_BUY, NormalizeVolume(InpBaseLot), "TREND cross");
         return;
      }
      if(rsi2 > InpRsiMid && rsi1 < InpRsiMid)
      {
         OpenMarketByDirection(magic, DIR_SELL, NormalizeVolume(InpBaseLot), "TREND cross");
         return;
      }
      return;
   }

   if(dir == DIR_NONE || count >= InpTrendMaxLevels)
      return;
   if(basketProfit <= 0.0)
      return; // reverse martingale: only add into winners

   double lastEntry = LastEntryPriceByMagic(magic);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   bool favorableEnough = false;
   if(dir == DIR_BUY)
      favorableEnough = (bid - lastEntry) >= (InpTrendPyramidStepPts * pt);
   else if(dir == DIR_SELL)
      favorableEnough = (lastEntry - ask) >= (InpTrendPyramidStepPts * pt);

   if(!favorableEnough)
      return;

   double lot = NormalizeVolume(InpBaseLot * MathPow(InpTrendPyramidMult, count));
   OpenMarketByDirection(magic, dir, lot, "TREND add");
}

void ManageRescueCoordination()
{
   if(!InpEnableRescue)
      return;

   ulong mRev = MagicRev();
   ulong mRes = MagicRescue();

   double revProfit = BasketProfitByMagic(mRev);
   int revCount = BasketCountByMagic(mRev);

   if(revCount == 0)
   {
      CloseBasketByMagic(mRes);
      return;
   }

   // Phase 1: no fixed rescue TP/SL; close rescue on RSI midpoint recross against rescue direction.
   RobotDirection rescueDir = BasketDirectionByMagic(mRes);
   if(BasketCountByMagic(mRes) > 0 &&
      ((rescueDir == DIR_BUY && g_rsi[2] > InpRsiMid && g_rsi[1] < InpRsiMid) ||
       (rescueDir == DIR_SELL && g_rsi[2] < InpRsiMid && g_rsi[1] > InpRsiMid)))
   {
      ulong worstTicket = WorstTicketByMagic(mRev);
      CloseBasketByMagic(mRes);
      if(worstTicket != 0)
         g_trade.PositionClose(worstTicket);
      return;
   }

   // Phase 2: if martingale basket is in trouble, launch one trend-aligned rescue trade.
   if(revProfit > InpTroubleLossMoney)
      return;

   if(BasketCountByMagic(mRes) > 0)
      return;

   int barsNow = iBars(_Symbol, InpTf);
   if((barsNow - g_lastRescueBarIndex) < InpRescueCooldownBars)
      return;

   RobotDirection helperDir = (g_rsi[1] >= InpRsiMid ? DIR_BUY : DIR_SELL);

   // avoid adding rescue in same direction as losing reversal basket when RSI trend disagrees
   RobotDirection revDir = BasketDirectionByMagic(mRev);
   if(revDir == helperDir)
      helperDir = (helperDir == DIR_BUY ? DIR_SELL : DIR_BUY);

   double lot = NormalizeVolume(InpBaseLot * InpRescueLotMult);
   if(OpenMarketByDirection(mRes, helperDir, lot, "RESCUE"))
      g_lastRescueBarIndex = barsNow;
}

bool OpenMarketByDirection(const ulong magic, const RobotDirection dir, const double lot, const string comment)
{
   if(dir == DIR_NONE || lot <= 0.0)
      return false;

   g_trade.SetExpertMagicNumber(magic);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(dir == DIR_BUY)
      return g_trade.Buy(lot, _Symbol, ask, 0.0, 0.0, comment);
   return g_trade.Sell(lot, _Symbol, bid, 0.0, 0.0, comment);
}

int BasketCountByMagic(const ulong magic)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      n++;
   }
   return n;
}

double BasketProfitByMagic(const ulong magic)
{
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      sum += PositionGetDouble(POSITION_PROFIT);
   }
   return sum;
}

RobotDirection BasketDirectionByMagic(const ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      return (type == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
   }
   return DIR_NONE;
}

double LastEntryPriceByMagic(const ulong magic)
{
   datetime newest = 0;
   double price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= newest)
      {
         newest = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return price;
}

ulong WorstTicketByMagic(const ulong magic)
{
   double worstProfit = DBL_MAX;
   ulong worstTicket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      double p = PositionGetDouble(POSITION_PROFIT);
      if(p < worstProfit)
      {
         worstProfit = p;
         worstTicket = ticket;
      }
   }
   return worstTicket;
}

void CloseBasketByMagic(const ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      g_trade.PositionClose(ticket);
   }
}

double NormalizeVolume(const double volRaw)
{
   double vMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vStep <= 0.0)
      vStep = 0.01;

   double v = MathMax(vMin, MathMin(vMax, volRaw));
   v = MathFloor(v / vStep) * vStep;
   int vd = 2;
   if(vStep < 0.01) vd = 3;
   if(vStep < 0.001) vd = 4;
   return NormalizeDouble(v, vd);
}

void SetTradeFillingBySymbol()
{
   long mask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mask & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((mask & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}
