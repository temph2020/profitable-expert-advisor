#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input group "=== Market ==="
input string          InpSymbol              = "BTCUSD";
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_M15;
input double          InpLots                = 0.01;
input int             InpSlippagePoints      = 30;
input int             InpMagic               = 930101;
input int             InpMaxPositions        = 6;
input bool            InpDebugLogs           = true;

input group "=== EMA Trend State ==="
input int             InpEmaPeriod           = 200;
input int             InpTrendLookbackBars   = 12;
input double          InpTrendMinPoints      = 120; // total EMA delta over lookback
input double          InpFlatMaxPoints       = 40;  // dead-flat band over lookback

input group "=== RSI Entries ==="
input int             InpRsiPeriod           = 14;
input double          InpRsiDipLevel         = 35.0; // buy dip in uptrend
input double          InpRsiSurgeLevel       = 65.0; // sell surge in downtrend
input bool            InpUseCrossSignal      = true; // true=cross, false=state-based

input group "=== Risk ==="
input bool            InpUseHardSLTP         = false;
input double          InpSLPoints            = 2500;
input double          InpTPPoints            = 4500;

enum TrendState
{
   TREND_FLAT = 0,
   TREND_UP   = 1,
   TREND_DOWN = -1
};

CTrade trade;
datetime g_lastBarTime = 0;

void DebugLog(const string msg)
{
   if(InpDebugLogs)
      Print("[EMARSIWarm] ", msg);
}

bool IsNewBar(const string symbol, ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t <= 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
}

double GetIndicatorValue(const int handle, const int bufferIdx, const int shift)
{
   if(handle == INVALID_HANDLE)
      return 0.0;
   double v[1];
   if(CopyBuffer(handle, bufferIdx, shift, 1, v) <= 0)
      return 0.0;
   return v[0];
}

double GetEma(const string symbol, ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   double val = GetIndicatorValue(h, 0, shift);
   if(h != INVALID_HANDLE)
      IndicatorRelease(h);
   return val;
}

double GetRsi(const string symbol, ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iRSI(symbol, tf, period, PRICE_CLOSE);
   double val = GetIndicatorValue(h, 0, shift);
   if(h != INVALID_HANDLE)
      IndicatorRelease(h);
   return val;
}

TrendState GetTrendState()
{
   double emaNow = GetEma(InpSymbol, InpTimeframe, InpEmaPeriod, 1);
   double emaPast = GetEma(InpSymbol, InpTimeframe, InpEmaPeriod, 1 + InpTrendLookbackBars);
   if(emaNow == 0.0 || emaPast == 0.0)
      return TREND_FLAT;

   double deltaPts = (emaNow - emaPast) / _Point;
   if(MathAbs(deltaPts) <= InpFlatMaxPoints)
      return TREND_FLAT;
   if(deltaPts >= InpTrendMinPoints)
      return TREND_UP;
   if(deltaPts <= -InpTrendMinPoints)
      return TREND_DOWN;
   return TREND_FLAT;
}

int CountPositionsByMagic(const string symbol, const int magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (int)PositionGetInteger(POSITION_MAGIC) == magic)
         count++;
   }
   return count;
}

string TrendStateToString(const TrendState s)
{
   if(s == TREND_UP) return "UP";
   if(s == TREND_DOWN) return "DOWN";
   return "FLAT";
}

void CloseAllByMagic(const string symbol, const int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol &&
         (int)PositionGetInteger(POSITION_MAGIC) == magic)
         trade.PositionClose(t);
   }
}

void ComputeSLTP(const bool isBuy, const double entry, double &sl, double &tp)
{
   if(!InpUseHardSLTP)
   {
      sl = 0.0;
      tp = 0.0;
      return;
   }

   if(isBuy)
   {
      sl = entry - InpSLPoints * _Point;
      tp = entry + InpTPPoints * _Point;
   }
   else
   {
      sl = entry + InpSLPoints * _Point;
      tp = entry - InpTPPoints * _Point;
   }
}

bool BuySignal()
{
   double r1 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 1);
   double r2 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 2);
   if(r1 == 0.0 || r2 == 0.0)
      return false;

   if(InpUseCrossSignal)
      return (r2 > InpRsiDipLevel && r1 <= InpRsiDipLevel); // fresh dip
   return (r1 <= InpRsiDipLevel);
}

bool SellSignal()
{
   double r1 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 1);
   double r2 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 2);
   if(r1 == 0.0 || r2 == 0.0)
      return false;

   if(InpUseCrossSignal)
      return (r2 < InpRsiSurgeLevel && r1 >= InpRsiSurgeLevel); // fresh surge
   return (r1 >= InpRsiSurgeLevel);
}

void OnTick()
{
   if(_Symbol != InpSymbol)
   {
      static datetime lastMismatchLog = 0;
      datetime nowBar = iTime(_Symbol, PERIOD_M1, 0);
      if(nowBar != lastMismatchLog)
      {
         lastMismatchLog = nowBar;
         DebugLog(StringFormat("Skipped: chart symbol=%s but InpSymbol=%s. Attach EA to %s chart or set InpSymbol=%s.",
                               _Symbol, InpSymbol, InpSymbol, _Symbol));
      }
      return;
   }
   if(!IsNewBar(InpSymbol, InpTimeframe))
      return;

   TrendState state = GetTrendState();
   double rsi1 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 1);
   double rsi2 = GetRsi(InpSymbol, InpTimeframe, InpRsiPeriod, 2);
   int posCount = CountPositionsByMagic(InpSymbol, InpMagic);
   DebugLog(StringFormat("Bar=%s state=%s rsi1=%.2f rsi2=%.2f positions=%d",
                         TimeToString(iTime(InpSymbol, InpTimeframe, 1), TIME_DATE|TIME_MINUTES),
                         TrendStateToString(state), rsi1, rsi2, posCount));

   // Core idea: when EMA is "dead flat", flatten everything.
   if(state == TREND_FLAT)
   {
      DebugLog("Action: EMA flat -> closing all positions for this magic.");
      CloseAllByMagic(InpSymbol, InpMagic);
      return;
   }

   if(posCount >= InpMaxPositions)
   {
      DebugLog(StringFormat("Skipped: max positions reached (%d).", InpMaxPositions));
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
   {
      DebugLog("Skipped: SymbolInfoTick failed.");
      return;
   }

   double sl = 0.0, tp = 0.0;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(state == TREND_UP && BuySignal())
   {
      ComputeSLTP(true, tick.ask, sl, tp);
      if(trade.Buy(InpLots, InpSymbol, tick.ask, sl, tp, "EMAUp_RSIDip_Buy"))
         DebugLog(StringFormat("BUY opened lots=%.2f price=%.2f sl=%.2f tp=%.2f", InpLots, tick.ask, sl, tp));
      else
         DebugLog(StringFormat("BUY failed retcode=%d", trade.ResultRetcode()));
   }
   else if(state == TREND_DOWN && SellSignal())
   {
      ComputeSLTP(false, tick.bid, sl, tp);
      if(trade.Sell(InpLots, InpSymbol, tick.bid, sl, tp, "EMADown_RSISurge_Sell"))
         DebugLog(StringFormat("SELL opened lots=%.2f price=%.2f sl=%.2f tp=%.2f", InpLots, tick.bid, sl, tp));
      else
         DebugLog(StringFormat("SELL failed retcode=%d", trade.ResultRetcode()));
   }
   else
   {
      if(state == TREND_UP)
         DebugLog("No entry: UP trend but RSI dip condition not met.");
      else if(state == TREND_DOWN)
         DebugLog("No entry: DOWN trend but RSI surge condition not met.");
   }
}

