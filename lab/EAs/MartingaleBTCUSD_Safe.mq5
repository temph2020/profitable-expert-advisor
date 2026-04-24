//+------------------------------------------------------------------+
//|                                        MartingaleBTCUSD_Safe.mq5 |
//| Classic martingale: double lot after loss, reset after win (BTC) |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>

input group "=== Market ==="
input string          InpSymbol        = "BTCUSD";
input ENUM_TIMEFRAMES InpTf            = PERIOD_M15;
input ulong           InpMagic         = 202604241;
input int             InpSlippagePts = 50;

input group "=== Martingale (classic) ==="
input double          InpBaseLots     = 0.01;
input double          InpLotMultiplier = 2.0;   // traditional = 2.0
input int             InpMaxDoublings = 16;   // cap exponent (0..MaxDoublings); then lot stops growing

input group "=== Entry (RSI) ==="
input int             InpRsiPeriod     = 14;
input double          InpRsiBuyBelow   = 32.0;
input double          InpRsiSellAbove  = 68.0;

input group "=== SL / TP (optional) ==="
input bool            InpUseSLTP       = false;
input double          InpSLPts        = 4000.0;
input double          InpTPPts        = 3500.0;

CTrade g_trade;
int     g_hRsi = INVALID_HANDLE;
int     g_lossStreak = 0;
ulong   g_lastPosId = 0;

string WorkSym() { return InpSymbol; }
double SymPoint() { return SymbolInfoDouble(WorkSym(), SYMBOL_POINT); }

void SetFilling()
{
   const long fill = SymbolInfoInteger(WorkSym(), SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
}

double NetProfitForPositionId(const ulong posId)
{
   if(posId == 0)
      return 0.0;
   const datetime to = TimeCurrent();
   if(!HistorySelect(0, to))
      return 0.0;
   double sum = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != posId)
         continue;
      sum += HistoryDealGetDouble(deal, DEAL_PROFIT);
      sum += HistoryDealGetDouble(deal, DEAL_SWAP);
      sum += HistoryDealGetDouble(deal, DEAL_COMMISSION);
   }
   return sum;
}

int OurPositionCount()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != WorkSym())
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         c++;
   }
   return c;
}

double LotsNow()
{
   const int exp = MathMax(0, MathMin(g_lossStreak, InpMaxDoublings));
   double lot = InpBaseLots * MathPow(InpLotMultiplier, (double)exp);
   const double minLot = SymbolInfoDouble(WorkSym(), SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(WorkSym(), SYMBOL_VOLUME_MAX);
   const double stepLot = SymbolInfoDouble(WorkSym(), SYMBOL_VOLUME_STEP);
   if(stepLot > 0.0)
      lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;
   return NormalizeDouble(lot, 8);
}

bool CopyRsi1(double &rsi1)
{
   double buf[1];
   if(CopyBuffer(g_hRsi, 0, 1, 1, buf) != 1)
      return false;
   rsi1 = buf[0];
   return true;
}

void BuildSLTP(const bool isBuy, const double price, double &sl, double &tp)
{
   sl = tp = 0.0;
   if(!InpUseSLTP)
      return;
   const double pt = SymPoint();
   if(pt <= 0.0)
      return;
   if(isBuy)
   {
      sl = price - InpSLPts * pt;
      tp = price + InpTPPts * pt;
   }
   else
   {
      sl = price + InpSLPts * pt;
      tp = price - InpTPPts * pt;
   }
}

void OnClosedPosition()
{
   const double net = NetProfitForPositionId(g_lastPosId);
   if(net < 0.0)
      g_lossStreak++;
   else
      g_lossStreak = 0;
   Print("Martingale: closed net=", net, " lossStreak=", g_lossStreak, " next lot=", LotsNow());
   g_lastPosId = 0;
}

bool OurPositionOpenById(const ulong posId)
{
   if(posId == 0)
      return false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != WorkSym())
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == posId)
         return true;
   }
   return false;
}

void CaptureLastPositionId()
{
   Sleep(20);
   for(int k = 0; k < PositionsTotal(); k++)
   {
      const ulong t = PositionGetTicket(k);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != WorkSym())
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_lastPosId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      return;
   }
}

int OnInit()
{
   if(InpBaseLots <= 0.0 || InpLotMultiplier < 1.0 || InpMaxDoublings < 0)
      return INIT_PARAMETERS_INCORRECT;
   if(!SymbolSelect(WorkSym(), true))
      Print("Martingale: SymbolSelect note ", WorkSym());
   g_hRsi = iRSI(WorkSym(), InpTf, InpRsiPeriod, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE)
      return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   SetFilling();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hRsi != INVALID_HANDLE)
      IndicatorRelease(g_hRsi);
}

void OnTick()
{
   if(_Symbol != WorkSym())
      return;

   if(g_lastPosId != 0 && !OurPositionOpenById(g_lastPosId))
      OnClosedPosition();

   static datetime lastBar = 0;
   const datetime tb = iTime(WorkSym(), InpTf, 0);
   if(tb == 0 || tb == lastBar)
      return;
   lastBar = tb;

   if(OurPositionCount() > 0)
      return;

   double rsi1 = 0.0;
   if(!CopyRsi1(rsi1))
      return;

   const double lot = LotsNow();
   if(lot <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(WorkSym(), tick))
      return;

   double sl = 0.0, tp = 0.0;
   const bool wantBuy  = (rsi1 <= InpRsiBuyBelow);
   const bool wantSell = (rsi1 >= InpRsiSellAbove);

   if(wantBuy && !wantSell)
   {
      BuildSLTP(true, tick.ask, sl, tp);
      if(g_trade.Buy(lot, WorkSym(), tick.ask, sl, tp, "Martingale buy"))
         CaptureLastPositionId();
   }
   else if(wantSell && !wantBuy)
   {
      BuildSLTP(false, tick.bid, sl, tp);
      if(g_trade.Sell(lot, WorkSym(), tick.bid, sl, tp, "Martingale sell"))
         CaptureLastPositionId();
   }
}
