#property strict
#property version "1.00"
#property description "BTCUSD mean reversion: RSI extreme + EMA distance + low ADX; escape when ADX trends up."

#include <Trade/Trade.mqh>

input group "=== Market ==="
input string          InpSymbol              = "BTCUSD";
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_M20;
input double          InpLots                = 0.01;
input int             InpSlippagePoints      = 30;
input int             InpMagic               = 930201;
input int             InpMaxPositions        = 5;
input bool            InpDebugLogs           = false;

input group "=== EMA distance (mean reversion stretch) ==="
input int             InpEmaPeriod           = 250;
input double          InpMinEmaDistancePts   = 3650.0; // |close-EMA| in points; raise/lower for BTC broker digits

input group "=== RSI ==="
input int             InpRsiPeriod           = 28;
input double          InpRsiOversold        = 40.0;
input double          InpRsiOverbought      = 83.0;
input bool            InpUseRsiCross        = false; // true: require cross into zone on last bar

input group "=== ADX (trend filter + escape) ==="
input int             InpAdxPeriod           = 27;
input double          InpAdxMaxForEntry      = 17.0; // no new trades if ADX >= this (ranging bias)
input double          InpAdxEscape           = 34.0; // close all if ADX >= this (trend building)

input group "=== Price action (optional) ==="
input bool            InpRequireReversalBar  = false; // buy: bearish bar at signal; sell: bullish bar

input group "=== Risk ==="
input bool            InpUseHardSLTP         = false;
input double          InpSLPoints            = 1300;
input double          InpTPPoints            = 13400;

CTrade trade;
datetime g_lastBarTime = 0;

int g_hRsi  = INVALID_HANDLE;
int g_hEma  = INVALID_HANDLE;
int g_hAdx  = INVALID_HANDLE;

void DebugLog(const string msg)
{
   if(InpDebugLogs)
      Print("[MeanRevEMA_RSI_ADX] ", msg);
}

bool IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t <= 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
}

bool CopyOne(const int handle, const int buffer, const int shift, double &out)
{
   if(handle == INVALID_HANDLE)
      return false;
   double v[1];
   if(CopyBuffer(handle, buffer, shift, 1, v) != 1)
      return false;
   out = v[0];
   return true;
}

double GetAdx(const int shift)
{
   double v = 0.0;
   if(!CopyOne(g_hAdx, 0, shift, v))
      return 0.0;
   return v;
}

double GetRsi(const int shift)
{
   double v = 0.0;
   if(!CopyOne(g_hRsi, 0, shift, v))
      return 0.0;
   return v;
}

double GetEma(const int shift)
{
   double v = 0.0;
   if(!CopyOne(g_hEma, 0, shift, v))
      return 0.0;
   return v;
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

bool RsiOversoldSignal()
{
   double r1 = 0.0, r2 = 0.0;
   if(!CopyOne(g_hRsi, 0, 1, r1) || !CopyOne(g_hRsi, 0, 2, r2))
      return false;
   if(InpUseRsiCross)
      return (r2 > InpRsiOversold && r1 <= InpRsiOversold);
   return (r1 <= InpRsiOversold);
}

bool RsiOverboughtSignal()
{
   double r1 = 0.0, r2 = 0.0;
   if(!CopyOne(g_hRsi, 0, 1, r1) || !CopyOne(g_hRsi, 0, 2, r2))
      return false;
   if(InpUseRsiCross)
      return (r2 < InpRsiOverbought && r1 >= InpRsiOverbought);
   return (r1 >= InpRsiOverbought);
}

bool BarBearish(const int shift)
{
   double o = iOpen(InpSymbol, InpTimeframe, shift);
   double c = iClose(InpSymbol, InpTimeframe, shift);
   return (c < o);
}

bool BarBullish(const int shift)
{
   double o = iOpen(InpSymbol, InpTimeframe, shift);
   double c = iClose(InpSymbol, InpTimeframe, shift);
   return (c > o);
}

bool BuySetup()
{
   if(!RsiOversoldSignal())
      return false;

   double ema = GetEma(1);
   double cls = iClose(InpSymbol, InpTimeframe, 1);
   if(ema <= 0.0 || cls <= 0.0)
      return false;

   double distPts = (ema - cls) / _Point;
   if(distPts < InpMinEmaDistancePts)
      return false;

   if(InpRequireReversalBar && !BarBearish(1))
      return false;

   double adx = GetAdx(1);
   if(adx <= 0.0)
      return false;
   if(adx >= InpAdxMaxForEntry)
      return false;

   return true;
}

bool SellSetup()
{
   if(!RsiOverboughtSignal())
      return false;

   double ema = GetEma(1);
   double cls = iClose(InpSymbol, InpTimeframe, 1);
   if(ema <= 0.0 || cls <= 0.0)
      return false;

   double distPts = (cls - ema) / _Point;
   if(distPts < InpMinEmaDistancePts)
      return false;

   if(InpRequireReversalBar && !BarBullish(1))
      return false;

   double adx = GetAdx(1);
   if(adx <= 0.0)
      return false;
   if(adx >= InpAdxMaxForEntry)
      return false;

   return true;
}

int OnInit()
{
   if(StringLen(InpSymbol) == 0)
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: InpSymbol is empty.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRsiPeriod < 2 || InpEmaPeriod < 1 || InpAdxPeriod < 1)
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: invalid periods rsi=", InpRsiPeriod,
            " ema=", InpEmaPeriod, " adx=", InpAdxPeriod);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!SymbolSelect(InpSymbol, true))
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: SymbolSelect failed (symbol missing on this agent?): ", InpSymbol,
            " err=", GetLastError(),
            " — use Local agents only for broker-specific names, or set InpSymbol to a symbol the agent has.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_hRsi = iRSI(InpSymbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE)
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: iRSI failed sym=", InpSymbol, " tf=", (int)InpTimeframe,
            " period=", InpRsiPeriod, " err=", GetLastError());
      return INIT_FAILED;
   }
   g_hEma = iMA(InpSymbol, InpTimeframe, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hEma == INVALID_HANDLE)
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: iMA failed sym=", InpSymbol, " tf=", (int)InpTimeframe,
            " period=", InpEmaPeriod, " err=", GetLastError());
      IndicatorRelease(g_hRsi);
      g_hRsi = INVALID_HANDLE;
      return INIT_FAILED;
   }
   g_hAdx = iADX(InpSymbol, InpTimeframe, InpAdxPeriod);
   if(g_hAdx == INVALID_HANDLE)
   {
      Print("[MeanRevEMA_RSI_ADX] OnInit: iADX failed sym=", InpSymbol, " tf=", (int)InpTimeframe,
            " period=", InpAdxPeriod, " err=", GetLastError());
      IndicatorRelease(g_hRsi);
      IndicatorRelease(g_hEma);
      g_hRsi = g_hEma = INVALID_HANDLE;
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hRsi != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   if(g_hEma != INVALID_HANDLE) IndicatorRelease(g_hEma);
   if(g_hAdx != INVALID_HANDLE) IndicatorRelease(g_hAdx);
   g_hRsi = g_hEma = g_hAdx = INVALID_HANDLE;
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
         DebugLog(StringFormat("Skipped: chart symbol=%s but InpSymbol=%s.", _Symbol, InpSymbol));
      }
      return;
   }

   const int posCount = CountPositionsByMagic(InpSymbol, InpMagic);
   const double adxLive = GetAdx(0);

   if(posCount > 0 && adxLive > 0.0 && adxLive >= InpAdxEscape)
   {
      DebugLog(StringFormat("ADX escape: adx0=%.2f >= %.2f -> closing %d position(s).", adxLive, InpAdxEscape, posCount));
      CloseAllByMagic(InpSymbol, InpMagic);
      return;
   }

   if(!IsNewBar(InpSymbol, InpTimeframe))
      return;

   const double rsi1 = GetRsi(1);
   const double adx1 = GetAdx(1);
   const double ema1 = GetEma(1);
   const double c1 = iClose(InpSymbol, InpTimeframe, 1);
   DebugLog(StringFormat("Bar=%s rsi1=%.2f adx1=%.2f ema1=%.5f close1=%.5f positions=%d",
                         TimeToString(iTime(InpSymbol, InpTimeframe, 1), TIME_DATE | TIME_MINUTES),
                         rsi1, adx1, ema1, c1, posCount));

   if(posCount >= InpMaxPositions)
   {
      DebugLog(StringFormat("Skipped: max positions (%d).", InpMaxPositions));
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick))
   {
      DebugLog("Skipped: SymbolInfoTick failed.");
      return;
   }

   double sl = 0.0, tp = 0.0;

   if(BuySetup())
   {
      ComputeSLTP(true, tick.ask, sl, tp);
      if(trade.Buy(InpLots, InpSymbol, tick.ask, sl, tp, "MeanRev_RSI_OS_EMA"))
         DebugLog(StringFormat("BUY lots=%.2f ask=%.2f sl=%.2f tp=%.2f", InpLots, tick.ask, sl, tp));
      else
         DebugLog(StringFormat("BUY failed retcode=%d", trade.ResultRetcode()));
      return;
   }

   if(SellSetup())
   {
      ComputeSLTP(false, tick.bid, sl, tp);
      if(trade.Sell(InpLots, InpSymbol, tick.bid, sl, tp, "MeanRev_RSI_OB_EMA"))
         DebugLog(StringFormat("SELL lots=%.2f bid=%.2f sl=%.2f tp=%.2f", InpLots, tick.bid, sl, tp));
      else
         DebugLog(StringFormat("SELL failed retcode=%d", trade.ResultRetcode()));
      return;
   }

   DebugLog("No entry: RSI/EMA distance/ADX/bar filters not aligned.");
}
