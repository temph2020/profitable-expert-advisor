#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

input group "=== Common ==="
input string          InpSymbol                = "BTCUSD";
input ENUM_TIMEFRAMES InpTimeframe             = PERIOD_M15;
input int             InpSlippagePoints        = 30;
input int             InpPivotLookbackBars     = 120;
input int             InpMinSwingPoints        = 500;

input group "=== Robot 1: Fibonacci Retracement ==="
input bool            FR_Enabled               = true;
input int             FR_Magic                 = 920101;
input double          FR_Lots                  = 0.01;
input bool            FR_BuyAt618              = true;
input bool            FR_BuyAt500              = false;
input bool            FR_UseHardSLTP           = true;
input double          FR_SL_BufferPoints       = 400;
input double          FR_TP_BufferPoints       = 400;
input int             FR_MaxHoldingBars        = 96;    // time-stop safety
input bool            FR_CloseOnStructureBreak = true;  // close if recent swing low breaks

input group "=== Robot 2: Fibonacci Trend Extension ==="
input bool            FE_Enabled               = true;
input int             FE_Magic                 = 920202;
input double          FE_Lots                  = 0.01;
input bool            FE_UseHardSLTP           = true;
input double          FE_SL_BufferPoints       = 400;
input double          FE_ExtensionLevel        = 1.272; // Common values: 1.272 / 1.618
input int             FE_MinBarsBetweenTrades  = 6;
input double          FE_MinStopPoints         = 3000;
input int             FE_AtrPeriod             = 14;
input double          FE_MinStopAtrMult        = 1.2;
input double          FE_MinRR                 = 1.5;

CTrade trade;
datetime g_lastBarTime = 0;
datetime g_lastFEEntryTime = 0;
datetime g_lastFREntryTime = 0;

bool IsNewBar(const string symbol, ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t <= 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
}

bool GetLowestLow(const string symbol, ENUM_TIMEFRAMES tf, const int bars, int &idx, double &price)
{
   idx = iLowest(symbol, tf, MODE_LOW, bars, 1);
   if(idx < 0)
      return false;
   price = iLow(symbol, tf, idx);
   return (price > 0.0);
}

bool GetHighestHigh(const string symbol, ENUM_TIMEFRAMES tf, const int bars, int &idx, double &price)
{
   idx = iHighest(symbol, tf, MODE_HIGH, bars, 1);
   if(idx < 0)
      return false;
   price = iHigh(symbol, tf, idx);
   return (price > 0.0);
}

double GetAtrPrice(const string symbol, ENUM_TIMEFRAMES tf, const int period)
{
   int hAtr = iATR(symbol, tf, period);
   if(hAtr == INVALID_HANDLE)
      return 0.0;
   double b[1];
   if(CopyBuffer(hAtr, 0, 1, 1, b) <= 0)
   {
      IndicatorRelease(hAtr);
      return 0.0;
   }
   IndicatorRelease(hAtr);
   return b[0];
}

bool PositionExistsByMagic(const string symbol, const int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (int)PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

bool GetPositionByMagic(const string symbol, const int magic, ulong &ticket, ENUM_POSITION_TYPE &posType, datetime &openTime)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (int)PositionGetInteger(POSITION_MAGIC) == magic)
      {
         ticket = t;
         posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         openTime = (datetime)PositionGetInteger(POSITION_TIME);
         return true;
      }
   }
   return false;
}

double NormalizePrice(const string symbol, const double price)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

bool ValidateAndAdjustStops(const bool isBuy, double &sl, double &tp)
{
   if(sl == 0.0 && tp == 0.0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;

   int stopsLevelPts = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevelPts = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevelPts, freezeLevelPts) * _Point + 2.0 * _Point;

   if(isBuy)
   {
      if(sl > 0.0 && sl >= tick.bid - minDist)
         sl = tick.bid - minDist;
      if(tp > 0.0 && tp <= tick.ask + minDist)
         tp = tick.ask + minDist;
      if(sl > 0.0 && sl >= tick.bid)
         return false;
      if(tp > 0.0 && tp <= tick.ask)
         return false;
   }
   else
   {
      if(sl > 0.0 && sl <= tick.ask + minDist)
         sl = tick.ask + minDist;
      if(tp > 0.0 && tp >= tick.bid - minDist)
         tp = tick.bid - minDist;
      if(sl > 0.0 && sl <= tick.ask)
         return false;
      if(tp > 0.0 && tp >= tick.bid)
         return false;
   }

   if(sl > 0.0)
      sl = NormalizePrice(InpSymbol, sl);
   if(tp > 0.0)
      tp = NormalizePrice(InpSymbol, tp);
   return true;
}

bool OpenBuy(const int magic, const double lots, const string comment, const double sl, const double tp)
{
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   double useSL = sl, useTP = tp;
   if(!ValidateAndAdjustStops(true, useSL, useTP))
      return false;
   trade.SetExpertMagicNumber(magic);
   bool ok = trade.Buy(lots, InpSymbol, tick.ask, useSL, useTP, comment);
   if(ok && magic == FR_Magic)
      g_lastFREntryTime = iTime(InpSymbol, InpTimeframe, 0);
   if(ok && magic == FE_Magic)
      g_lastFEEntryTime = iTime(InpSymbol, InpTimeframe, 0);
   return ok;
}

bool OpenSell(const int magic, const double lots, const string comment, const double sl, const double tp)
{
   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return false;
   double useSL = sl, useTP = tp;
   if(!ValidateAndAdjustStops(false, useSL, useTP))
      return false;
   trade.SetExpertMagicNumber(magic);
   bool ok = trade.Sell(lots, InpSymbol, tick.bid, useSL, useTP, comment);
   if(ok && magic == FE_Magic)
      g_lastFEEntryTime = iTime(InpSymbol, InpTimeframe, 0);
   return ok;
}

void RunFibonacciRetracement()
{
   if(!FR_Enabled)
      return;
   if(PositionExistsByMagic(InpSymbol, FR_Magic))
      return;

   int idxLow = -1, idxHigh = -1;
   double swingLow = 0.0, swingHigh = 0.0;
   if(!GetLowestLow(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxLow, swingLow))
      return;
   if(!GetHighestHigh(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxHigh, swingHigh))
      return;

   double rangePts = (swingHigh - swingLow) / _Point;
   if(rangePts < InpMinSwingPoints)
      return;

   // Uptrend retracement model: low appears before high.
   bool upSwing = (idxLow > idxHigh);
   if(!upSwing)
      return;

   double fib50 = swingHigh - (swingHigh - swingLow) * 0.500;
   double fib61 = swingHigh - (swingHigh - swingLow) * 0.618;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   double sl = 0.0, tp = 0.0;
   if(FR_UseHardSLTP)
   {
      // Positional levels: SL below swing low, TP near prior swing high breakout.
      sl = swingLow - FR_SL_BufferPoints * _Point;
      tp = swingHigh + FR_TP_BufferPoints * _Point;
   }

   if(FR_BuyAt618 && tick.ask <= fib61)
      OpenBuy(FR_Magic, FR_Lots, "FiboRetrace-61.8 Buy", sl, tp);
   else if(FR_BuyAt500 && tick.ask <= fib50)
      OpenBuy(FR_Magic, FR_Lots, "FiboRetrace-50.0 Buy", sl, tp);
}

void ManageFibonacciRetracementExit()
{
   if(!FR_Enabled)
      return;

   ulong ticket = 0;
   ENUM_POSITION_TYPE posType = WRONG_VALUE;
   datetime openTime = 0;
   if(!GetPositionByMagic(InpSymbol, FR_Magic, ticket, posType, openTime))
      return;

   int tfSec = PeriodSeconds(InpTimeframe);
   if(tfSec <= 0)
      tfSec = 60;
   int barsHeld = (int)((iTime(InpSymbol, InpTimeframe, 0) - openTime) / tfSec);

   // 1) Time stop: force close stale retracement trades.
   if(FR_MaxHoldingBars > 0 && barsHeld >= FR_MaxHoldingBars)
   {
      trade.PositionClose(ticket);
      return;
   }

   // 2) Structure invalidation: if latest swing violates the trade idea, exit.
   if(FR_CloseOnStructureBreak)
   {
      int idxLow = -1, idxHigh = -1;
      double swingLow = 0.0, swingHigh = 0.0;
      if(GetLowestLow(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxLow, swingLow) &&
         GetHighestHigh(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxHigh, swingHigh))
      {
         MqlTick tick;
         if(SymbolInfoTick(InpSymbol, tick))
         {
            double invalidateBuffer = FR_SL_BufferPoints * _Point;
            if(posType == POSITION_TYPE_BUY && tick.bid < (swingLow - invalidateBuffer))
               trade.PositionClose(ticket);
            else if(posType == POSITION_TYPE_SELL && tick.ask > (swingHigh + invalidateBuffer))
               trade.PositionClose(ticket);
         }
      }
   }
}

void RunFibonacciExtension()
{
   if(!FE_Enabled)
      return;
   if(PositionExistsByMagic(InpSymbol, FE_Magic))
      return;
   if(g_lastFEEntryTime > 0)
   {
      int tfSec = PeriodSeconds(InpTimeframe);
      if(tfSec > 0)
      {
         int barsSince = (int)((iTime(InpSymbol, InpTimeframe, 0) - g_lastFEEntryTime) / tfSec);
         if(barsSince < FE_MinBarsBetweenTrades)
            return;
      }
   }

   int idxLow = -1, idxHigh = -1;
   double swingLow = 0.0, swingHigh = 0.0;
   if(!GetLowestLow(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxLow, swingLow))
      return;
   if(!GetHighestHigh(InpSymbol, InpTimeframe, InpPivotLookbackBars, idxHigh, swingHigh))
      return;

   double rangePts = (swingHigh - swingLow) / _Point;
   if(rangePts < InpMinSwingPoints)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
      return;

   // Continuation breakout model:
   // - If up swing (low before high), buy above swing high and target extension.
   // - If down swing (high before low), sell below swing low and target extension.
   bool upSwing = (idxLow > idxHigh);

   if(upSwing && tick.ask > swingHigh)
   {
      double sl = 0.0, tp = 0.0;
      if(FE_UseHardSLTP)
      {
         sl = swingHigh - FE_SL_BufferPoints * _Point;
         double extTP = swingLow + (swingHigh - swingLow) * FE_ExtensionLevel;
         double atr = GetAtrPrice(InpSymbol, InpTimeframe, FE_AtrPeriod);
         double minRisk = MathMax(FE_MinStopPoints * _Point, atr * FE_MinStopAtrMult);
         double risk = tick.ask - sl;
         if(risk < minRisk)
            return; // Skip fragile entries with overly tight stop.
         double rrTP = tick.ask + risk * FE_MinRR;
         tp = MathMax(extTP, rrTP);
      }
      OpenBuy(FE_Magic, FE_Lots, "FiboExtension Buy", sl, tp);
   }
   else if(!upSwing && tick.bid < swingLow)
   {
      double sl = 0.0, tp = 0.0;
      if(FE_UseHardSLTP)
      {
         sl = swingLow + FE_SL_BufferPoints * _Point;
         double extTP = swingHigh - (swingHigh - swingLow) * FE_ExtensionLevel;
         double atr = GetAtrPrice(InpSymbol, InpTimeframe, FE_AtrPeriod);
         double minRisk = MathMax(FE_MinStopPoints * _Point, atr * FE_MinStopAtrMult);
         double risk = sl - tick.bid;
         if(risk < minRisk)
            return; // Skip fragile entries with overly tight stop.
         double rrTP = tick.bid - risk * FE_MinRR;
         tp = MathMin(extTP, rrTP);
      }
      OpenSell(FE_Magic, FE_Lots, "FiboExtension Sell", sl, tp);
   }
}

int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
      return(INIT_FAILED);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(_Symbol != InpSymbol)
      return;
   if(!IsNewBar(InpSymbol, InpTimeframe))
      return;

   ManageFibonacciRetracementExit();
   RunFibonacciRetracement();
   RunFibonacciExtension();
}
