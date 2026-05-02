//+------------------------------------------------------------------+
//|                                       double-top-bottom-catcher.mq5 |
//| Lab EA: Double top/bottom catcher with EMA distance + HTF trend    |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property version   "1.00"

#include <Trade\Trade.mqh>

input ENUM_TIMEFRAMES InpTf                   = PERIOD_M1;   // Signal timeframe
input ENUM_TIMEFRAMES InpHtf                  = PERIOD_M5;   // Higher timeframe
input bool            InpUseHtfFilter         = true;        // Require HTF trend alignment
input int             InpEmaFast              = 9;           // Fast EMA
input int             InpEmaSlow              = 21;          // Slow EMA

input int             InpPivotLeft            = 2;           // Pivot bars left
input int             InpPivotRight           = 2;           // Pivot bars right
input int             InpPatternLookbackBars  = 180;         // Search range for patterns
input int             InpMinPatternSeparation = 6;           // Min bars between tops/bottoms
input int             InpMaxPatternSeparation = 50;          // Max bars between tops/bottoms
input double          InpTopBottomTolPts      = 120;         // Max diff between top/top or bottom/bottom
input double          InpMinEmaPriceDistPts   = 80;          // Min stretch from EMA at 2nd touch
input int             InpPrevLevelLookback    = 120;         // Lookback to find previous support/resistance

input double          InpLots                 = 0.01;
input int             InpSlBufferPts          = 25;          // SL buffer beyond pattern extreme
input ulong           InpMagic                = 20260425;
input int             InpSlippagePts          = 30;

CTrade g_trade;

int g_hEmaFast    = INVALID_HANDLE;
int g_hEmaSlow    = INVALID_HANDLE;
int g_hEmaFastHtf = INVALID_HANDLE;
int g_hEmaSlowHtf = INVALID_HANDLE;

double g_emaFast[];
double g_emaSlow[];
double g_emaFastHtf[];
double g_emaSlowHtf[];

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   SetTradeFillingBySymbol();

   g_hEmaFast = iMA(_Symbol, InpTf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, InpTf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaFastHtf = iMA(_Symbol, InpHtf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlowHtf = iMA(_Symbol, InpHtf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE ||
      g_hEmaFastHtf == INVALID_HANDLE || g_hEmaSlowHtf == INVALID_HANDLE)
      return INIT_FAILED;

   ArraySetAsSeries(g_emaFast, true);
   ArraySetAsSeries(g_emaSlow, true);
   ArraySetAsSeries(g_emaFastHtf, true);
   ArraySetAsSeries(g_emaSlowHtf, true);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hEmaFast != INVALID_HANDLE)    IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE)    IndicatorRelease(g_hEmaSlow);
   if(g_hEmaFastHtf != INVALID_HANDLE) IndicatorRelease(g_hEmaFastHtf);
   if(g_hEmaSlowHtf != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowHtf);
}

void OnTick()
{
   static datetime lastBar = 0;
   datetime barTime = iTime(_Symbol, InpTf, 0);
   if(barTime == lastBar)
      return;
   lastBar = barTime;

   const int need = MathMax(260, InpPatternLookbackBars + InpPrevLevelLookback + 20);
   if(CopyBuffer(g_hEmaFast, 0, 0, need, g_emaFast) < need) return;
   if(CopyBuffer(g_hEmaSlow, 0, 0, need, g_emaSlow) < need) return;
   if(CopyBuffer(g_hEmaFastHtf, 0, 0, 5, g_emaFastHtf) < 5) return;
   if(CopyBuffer(g_hEmaSlowHtf, 0, 0, 5, g_emaSlowHtf) < 5) return;

   if(PositionExistsForMagic())
      return;

   TryEnterLongDoubleBottom();
   if(!PositionExistsForMagic())
      TryEnterShortDoubleTop();
}

void TryEnterLongDoubleBottom()
{
   int firstBottom = -1;   // older
   int secondBottom = -1;  // newer
   double neckline = 0.0;
   double lowA = 0.0;
   double lowB = 0.0;

   if(!FindDoubleBottom(firstBottom, secondBottom, neckline, lowA, lowB))
      return;

   const int c = 1;
   double close1 = iClose(_Symbol, InpTf, c);
   if(close1 <= neckline)
      return; // wait for neckline break confirmation

   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stretched = g_emaFast[secondBottom] - lowB;
   if(stretched < InpMinEmaPriceDistPts * pt)
      return; // no enough EMA/price displacement for reversal

   if(close1 <= g_emaFast[c])
      return; // keep confirmation strict: close above EMA fast

   if(InpUseHtfFilter && !(g_emaFastHtf[c] > g_emaSlowHtf[c]))
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = MathMin(lowA, lowB) - InpSlBufferPts * pt;
   double tp = FindPreviousResistance(firstBottom);
   if(tp <= ask + pt)
      return;
   if(sl >= ask - pt)
      return;

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   g_trade.Buy(InpLots, _Symbol, ask, sl, tp, "Double bottom");
}

void TryEnterShortDoubleTop()
{
   int firstTop = -1;   // older
   int secondTop = -1;  // newer
   double neckline = 0.0;
   double hiA = 0.0;
   double hiB = 0.0;

   if(!FindDoubleTop(firstTop, secondTop, neckline, hiA, hiB))
      return;

   const int c = 1;
   double close1 = iClose(_Symbol, InpTf, c);
   if(close1 >= neckline)
      return; // wait for neckline break confirmation

   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stretched = hiB - g_emaFast[secondTop];
   if(stretched < InpMinEmaPriceDistPts * pt)
      return; // no enough EMA/price displacement for reversal

   if(close1 >= g_emaFast[c])
      return; // keep confirmation strict: close below EMA fast

   if(InpUseHtfFilter && !(g_emaFastHtf[c] < g_emaSlowHtf[c]))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = MathMax(hiA, hiB) + InpSlBufferPts * pt;
   double tp = FindPreviousSupport(firstTop);
   if(tp >= bid - pt)
      return;
   if(sl <= bid + pt)
      return;

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   g_trade.Sell(InpLots, _Symbol, bid, sl, tp, "Double top");
}

bool FindDoubleBottom(int &firstBottom, int &secondBottom, double &neckline, double &lowA, double &lowB)
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int minShift = InpPivotRight + 1;
   int maxShift = MathMin(InpPatternLookbackBars, Bars(_Symbol, InpTf) - InpPivotLeft - 2);
   if(maxShift <= minShift + InpPivotLeft + InpPivotRight + 2)
      return false;

   for(int newer = minShift; newer <= maxShift; newer++)
   {
      if(!IsPivotLow(newer))
         continue;
      for(int older = newer + InpMinPatternSeparation; older <= maxShift; older++)
      {
         int sep = older - newer;
         if(sep > InpMaxPatternSeparation)
            break;
         if(!IsPivotLow(older))
            continue;

         double lNew = iLow(_Symbol, InpTf, newer);
         double lOld = iLow(_Symbol, InpTf, older);
         if(MathAbs(lNew - lOld) > InpTopBottomTolPts * pt)
            continue;

         double neck = HighestHighBetween(newer, older);
         if(neck <= 0.0)
            continue;

         firstBottom = older;
         secondBottom = newer;
         lowA = lOld;
         lowB = lNew;
         neckline = neck;
         return true;
      }
   }
   return false;
}

bool FindDoubleTop(int &firstTop, int &secondTop, double &neckline, double &hiA, double &hiB)
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int minShift = InpPivotRight + 1;
   int maxShift = MathMin(InpPatternLookbackBars, Bars(_Symbol, InpTf) - InpPivotLeft - 2);
   if(maxShift <= minShift + InpPivotLeft + InpPivotRight + 2)
      return false;

   for(int newer = minShift; newer <= maxShift; newer++)
   {
      if(!IsPivotHigh(newer))
         continue;
      for(int older = newer + InpMinPatternSeparation; older <= maxShift; older++)
      {
         int sep = older - newer;
         if(sep > InpMaxPatternSeparation)
            break;
         if(!IsPivotHigh(older))
            continue;

         double hNew = iHigh(_Symbol, InpTf, newer);
         double hOld = iHigh(_Symbol, InpTf, older);
         if(MathAbs(hNew - hOld) > InpTopBottomTolPts * pt)
            continue;

         double neck = LowestLowBetween(newer, older);
         if(neck <= 0.0)
            continue;

         firstTop = older;
         secondTop = newer;
         hiA = hOld;
         hiB = hNew;
         neckline = neck;
         return true;
      }
   }
   return false;
}

bool IsPivotLow(const int shift)
{
   double v = iLow(_Symbol, InpTf, shift);
   for(int i = 1; i <= InpPivotLeft; i++)
      if(iLow(_Symbol, InpTf, shift + i) <= v) return false;
   for(int i = 1; i <= InpPivotRight; i++)
      if(iLow(_Symbol, InpTf, shift - i) < v) return false;
   return true;
}

bool IsPivotHigh(const int shift)
{
   double v = iHigh(_Symbol, InpTf, shift);
   for(int i = 1; i <= InpPivotLeft; i++)
      if(iHigh(_Symbol, InpTf, shift + i) >= v) return false;
   for(int i = 1; i <= InpPivotRight; i++)
      if(iHigh(_Symbol, InpTf, shift - i) > v) return false;
   return true;
}

double HighestHighBetween(const int shiftA, const int shiftB)
{
   int from = MathMin(shiftA, shiftB);
   int to = MathMax(shiftA, shiftB);
   double v = -DBL_MAX;
   for(int i = from; i <= to; i++)
      v = MathMax(v, iHigh(_Symbol, InpTf, i));
   return v;
}

double LowestLowBetween(const int shiftA, const int shiftB)
{
   int from = MathMin(shiftA, shiftB);
   int to = MathMax(shiftA, shiftB);
   double v = DBL_MAX;
   for(int i = from; i <= to; i++)
      v = MathMin(v, iLow(_Symbol, InpTf, i));
   return v;
}

double FindPreviousResistance(const int firstBottomShift)
{
   int start = firstBottomShift + 1;
   int end = firstBottomShift + InpPrevLevelLookback;
   int bars = Bars(_Symbol, InpTf);
   end = MathMin(end, bars - 2);
   if(start > end)
      return 0.0;

   double r = -DBL_MAX;
   for(int i = start; i <= end; i++)
      r = MathMax(r, iHigh(_Symbol, InpTf, i));
   return r;
}

double FindPreviousSupport(const int firstTopShift)
{
   int start = firstTopShift + 1;
   int end = firstTopShift + InpPrevLevelLookback;
   int bars = Bars(_Symbol, InpTf);
   end = MathMin(end, bars - 2);
   if(start > end)
      return 0.0;

   double s = DBL_MAX;
   for(int i = start; i <= end; i++)
      s = MathMin(s, iLow(_Symbol, InpTf, i));
   return s;
}

bool PositionExistsForMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
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
