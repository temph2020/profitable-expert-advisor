//+------------------------------------------------------------------+
//|                                                    TFXNZDUSD.mq5 |
//|  NZDUSD: HTF directional bias + intraday bearish→bullish shift   |
//|  Mirrors a reactive workflow: higher TFs for bias (D1/W1),       |
//|  lower TFs (H4–M15) for confirmation — long bias / pullback /    |
//|  reclaim entry. Not predictive; signals on closed bars.            |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property link      ""
#property version   "1.01"
#property description "NZDUSD long-bias EA: D1/W1 trend filter, intraday EMA cross after pullback streak, ATR risk."

#include <Trade/Trade.mqh>

input group "=== Symbol ==="
input string              InpSymbol            = "NZDUSD";     // Spot FX symbol (broker-specific)

input group "=== Timeframes (thesis) ==="
input ENUM_TIMEFRAMES     InpBiasTF            = PERIOD_D1;    // Directional bias (monthly/weekly/daily idea → D1 default)
input ENUM_TIMEFRAMES     InpHigherBiasTF      = PERIOD_W1;    // Optional second bias filter
input ENUM_TIMEFRAMES     InpSignalTF          = PERIOD_H4;    // Intraday environment shift (H4 or lower)

input group "=== HTF bias (long-only, reactive) ==="
input bool                InpUseWeeklyBias      = true;        // Require W1 close > W1 EMA
input int                 InpBiasEmaPeriod      = 50;          // EMA period on bias TFs
input bool                InpAllowCounterBias   = false;       // If false, skip longs when D1 close < D1 EMA

input group "=== Intraday shift (bearish → bullish) ==="
input int                 InpFastEma            = 8;
input int                 InpSlowEma            = 21;
input int                 InpMinBearishBars     = 3;           // Min consecutive bars with fast EMA < slow before cross-up
input bool                InpRequireBullBody    = true;        // Bullish closed candle on cross bar

input group "=== Risk ==="
input double              InpLots               = 0.10;
input int                 InpMagic              = 926001;
input int                 InpSlippagePoints     = 20;
input int                 InpMaxSpreadPoints    = 40;
input bool                InpUseAtrStops        = true;
input int                 InpAtrPeriod          = 14;
input double              InpSlAtrMult          = 1.5;
input double              InpTpAtrMult          = 2.5;
input double              InpMinStopPoints      = 50;
input int                 InpMaxPositions       = 1;

input group "=== Session (optional) ==="
input bool                InpUseSessionFilter   = false;
input int                 InpSessionStartHour   = 7;          // Server hour start
input int                 InpSessionEndHour     = 20;           // Server hour end (exclusive if cross midnight handled below)

CTrade g_trade;

int g_atrSig        = INVALID_HANDLE;
int g_emaBiasD1     = INVALID_HANDLE;
int g_emaBiasW1     = INVALID_HANDLE;
int g_emaFastSig    = INVALID_HANDLE;
int g_emaSlowSig    = INVALID_HANDLE;

/// Effective TFs after sanity check (genetic optimizers often pass invalid ENUM integers).
ENUM_TIMEFRAMES g_effBiasTF       = PERIOD_D1;
ENUM_TIMEFRAMES g_effHigherBiasTF = PERIOD_W1;
ENUM_TIMEFRAMES g_effSignalTF     = PERIOD_H4;

datetime g_lastSignalBar = 0;

// Maps garbage timeframe integers from optimization to nearest supported standard period.
ENUM_TIMEFRAMES NearestStandardTf(const ENUM_TIMEFRAMES raw)
{
   if(PeriodSeconds(raw) > 0)
      return raw;

   const ENUM_TIMEFRAMES cand[] =
   {
      PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1
   };
   const long r = (long)raw;
   ENUM_TIMEFRAMES best = PERIOD_H4;
   long bestDist = -1;
   for(int i = 0; i < ArraySize(cand); i++)
   {
      if(PeriodSeconds(cand[i]) <= 0)
         continue;
      const long diff = r - (long)cand[i];
      const long d = (diff >= 0 ? diff : -diff);
      if(bestDist < 0 || d < bestDist)
      {
         bestDist = d;
         best = cand[i];
      }
   }
   return best;
}

string WorkSymbol()
{
   string s = InpSymbol;
   StringTrimLeft(s);
   StringTrimRight(s);
   // .set files sometimes concatenate optimization payload into string inputs (e.g. "NZDUSD||0||...")
   const int bar = StringFind(s, "|");
   if(bar >= 0)
      s = StringSubstr(s, 0, bar);
   StringTrimRight(s);
   return (StringLen(s) > 0 ? s : _Symbol);
}

bool SessionOk()
{
   if(!InpUseSessionFilter)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

double Buf1(const int handle, const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return 0.0;
   return b[0];
}

bool CopyClose(const string sym, const ENUM_TIMEFRAMES tf, const int shift, double &out)
{
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(sym, tf, shift, 1, c) != 1)
      return false;
   out = c[0];
   return true;
}

bool HtfLongBias(const string sym)
{
   double cD1 = 0.0, eD1 = 0.0;
   if(!CopyClose(sym, g_effBiasTF, 1, cD1))
      return false;
   eD1 = Buf1(g_emaBiasD1, 1);
   if(eD1 <= 0.0)
      return false;
   if(!InpAllowCounterBias && cD1 <= eD1)
      return false;

   if(InpUseWeeklyBias)
   {
      double cW1 = 0.0, eW1 = 0.0;
      if(!CopyClose(sym, g_effHigherBiasTF, 1, cW1))
         return false;
      eW1 = Buf1(g_emaBiasW1, 1);
      if(eW1 <= 0.0)
         return false;
      if(cW1 <= eW1)
         return false;
   }
   return true;
}

int CountConsecutiveBearishEma(const string sym, const int fromShift, const int maxLookback)
{
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   int need = maxLookback + fromShift;
   if(CopyBuffer(g_emaFastSig, 0, 0, need, f) < need)
      return 0;
   if(CopyBuffer(g_emaSlowSig, 0, 0, need, s) < need)
      return 0;

   int n = 0;
   for(int i = fromShift; i < fromShift + maxLookback; i++)
   {
      if(f[i] <= s[i])
         n++;
      else
         break;
   }
   return n;
}

bool BullishCrossOnLastClosedBar(const string sym)
{
   double f1 = Buf1(g_emaFastSig, 1);
   double s1 = Buf1(g_emaSlowSig, 1);
   double f2 = Buf1(g_emaFastSig, 2);
   double s2 = Buf1(g_emaSlowSig, 2);
   if(f1 <= 0.0 || s1 <= 0.0 || f2 <= 0.0 || s2 <= 0.0)
      return false;

   bool crossedUp = (f1 > s1 && f2 <= s2);
   if(!crossedUp)
      return false;

   int bearStreak = CountConsecutiveBearishEma(sym, 2, 32);
   if(bearStreak < InpMinBearishBars)
      return false;

   if(InpRequireBullBody)
   {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(sym, g_effSignalTF, 1, 1, r) != 1)
         return false;
      if(r[0].close <= r[0].open)
         return false;
   }
   return true;
}

double NormalizeVolumeLots(const string sym, double lots)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      lots = MathFloor(lots / step) * step;
   if(lots < minLot)
      lots = minLot;
   if(lots > maxLot)
      lots = maxLot;
   return lots;
}

int CountOurPositions(const string sym)
{
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      total++;
   }
   return total;
}

bool SpreadOk(const string sym)
{
   long spreadPts = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   return ((double)spreadPts <= (double)InpMaxSpreadPoints);
}

void ComputeStopsBuy(const string sym, const double entry, double &sl, double &tp)
{
   double ptsSl = InpMinStopPoints;
   double ptsTp = InpMinStopPoints * 2.0;
   if(InpUseAtrStops && g_atrSig != INVALID_HANDLE)
   {
      double atr = Buf1(g_atrSig, 1);
      if(atr > 0.0)
      {
         double atrPts = atr / SymbolInfoDouble(sym, SYMBOL_POINT);
         ptsSl = MathMax(atrPts * InpSlAtrMult, InpMinStopPoints);
         ptsTp = MathMax(atrPts * InpTpAtrMult, InpMinStopPoints);
      }
   }
   double p = SymbolInfoDouble(sym, SYMBOL_POINT);
   sl = entry - ptsSl * p;
   tp = entry + ptsTp * p;

   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopsLevel * p;
   if(minDist > 0.0)
   {
      if(entry - sl < minDist)
         sl = entry - minDist;
      if(tp - entry < minDist)
         tp = entry + minDist;
   }
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
}

int OnInit()
{
   string sym = WorkSymbol();
   if(!SymbolSelect(sym, true))
   {
      Print("TFXNZDUSD: symbol not available: ", sym);
      return INIT_FAILED;
   }

   g_effBiasTF = NearestStandardTf(InpBiasTF);
   g_effHigherBiasTF = NearestStandardTf(InpHigherBiasTF);
   g_effSignalTF = NearestStandardTf(InpSignalTF);
   if(g_effBiasTF != InpBiasTF || g_effHigherBiasTF != InpHigherBiasTF || g_effSignalTF != InpSignalTF)
      Print("TFXNZDUSD: resolved TFs — bias ", EnumToString(g_effBiasTF), " (in ", (long)InpBiasTF, ")",
            " W1 ", EnumToString(g_effHigherBiasTF), " (in ", (long)InpHigherBiasTF, ")",
            " signal ", EnumToString(g_effSignalTF), " (in ", (long)InpSignalTF, ")");

   if(InpBiasEmaPeriod < 1 || InpFastEma < 1 || InpSlowEma < 1 || InpAtrPeriod < 1)
   {
      Print("TFXNZDUSD: EMA/ATR period must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(sym);

   g_emaBiasD1 = iMA(sym, g_effBiasTF, InpBiasEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaBiasW1 = iMA(sym, g_effHigherBiasTF, InpBiasEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaFastSig = iMA(sym, g_effSignalTF, InpFastEma, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowSig = iMA(sym, g_effSignalTF, InpSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   g_atrSig = iATR(sym, g_effSignalTF, InpAtrPeriod);

   if(g_emaBiasD1 == INVALID_HANDLE || g_emaFastSig == INVALID_HANDLE || g_emaSlowSig == INVALID_HANDLE ||
      g_atrSig == INVALID_HANDLE)
   {
      Print("TFXNZDUSD: indicator init failed — check InpBiasTF/InpHigherBiasTF/InpSignalTF & symbol history");
      return INIT_FAILED;
   }
   if(InpUseWeeklyBias && g_emaBiasW1 == INVALID_HANDLE)
   {
      Print("TFXNZDUSD: W1 bias handle failed");
      return INIT_FAILED;
   }

   Print("TFXNZDUSD: ", sym, " eff TFs: bias=", EnumToString(g_effBiasTF), " higher=", EnumToString(g_effHigherBiasTF),
         " signal=", EnumToString(g_effSignalTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaBiasD1 != INVALID_HANDLE)   IndicatorRelease(g_emaBiasD1);
   if(g_emaBiasW1 != INVALID_HANDLE)   IndicatorRelease(g_emaBiasW1);
   if(g_emaFastSig != INVALID_HANDLE)  IndicatorRelease(g_emaFastSig);
   if(g_emaSlowSig != INVALID_HANDLE)  IndicatorRelease(g_emaSlowSig);
   if(g_atrSig != INVALID_HANDLE)      IndicatorRelease(g_atrSig);
}

void OnTick()
{
   string sym = WorkSymbol();
   datetime barOpen = iTime(sym, g_effSignalTF, 0);
   if(barOpen == 0)
      return;
   if(barOpen == g_lastSignalBar)
      return;

   datetime prevBar = iTime(sym, g_effSignalTF, 1);
   if(prevBar == 0)
      return;

   g_lastSignalBar = barOpen;

   if(!SessionOk())
      return;
   if(!SpreadOk(sym))
      return;

   if(CountOurPositions(sym) >= InpMaxPositions)
      return;

   if(!HtfLongBias(sym))
      return;

   if(!BullishCrossOnLastClosedBar(sym))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;

   double lots = NormalizeVolumeLots(sym, InpLots);
   double sl = 0.0, tp = 0.0;
   ComputeStopsBuy(sym, tick.ask, sl, tp);

   if(!g_trade.Buy(lots, sym, tick.ask, sl, tp, "TFX NZDUSD shift"))
      Print("TFXNZDUSD Buy failed ret=", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
