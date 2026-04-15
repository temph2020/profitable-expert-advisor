//+------------------------------------------------------------------+
//|                                                     rsi-scalping.mq5 |
//| Lab EA: EMA 9/21 + Stochastic RSI — M1 scalping rules (tutorial)   |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- inputs: indicator tuning (video defaults)
input ENUM_TIMEFRAMES InpTf              = PERIOD_M1; // Chart / signal timeframe
input int             InpEmaFast         = 9;         // EMA fast (short-term)
input int             InpEmaSlow         = 21;        // EMA slow (trend)
input int             InpRsiLen          = 14;       // RSI length (Stoch RSI core)
input int             InpStochLen        = 14;        // Stochastic lookback on RSI
input int             InpStochK          = 4;         // Stoch RSI %K smoothing
input int             InpStochD          = 7;         // Stoch RSI %D smoothing
input double          InpObLevel        = 80.0;     // Overbought line
input double          InpOsLevel         = 20.0;      // Oversold line
//--- filters
input bool            InpUseMidZoneFilter = true;     // Skip if K,D in 40–60 (indecision)
input int             InpMinBarsSinceCross = 10;      // Min bars between EMA crosses
input bool            InpUseHtfFilter     = false;     // Align with higher TF EMAs
input ENUM_TIMEFRAMES InpHtf              = PERIOD_M5; // Higher timeframe
input double          InpMinEmaSepPts    = 0.0;      // Min |EMA9-EMA21| in points (0=off)
//--- risk
input double          InpLots             = 0.01;
input int             InpSlBufferPts     = 20;       // Extra SL beyond last 2-bar extreme
input double          InpTpRiskMultiple   = 1.75;    // TP = risk * this (1.5–2.0 typical)
input bool            InpExitOnEma9Break  = true;     // Close long if close < EMA9 (vice versa shorts)
input bool            InpExitOnStochZone  = true;     // Close long at Stoch RSI ≥ OB; short at ≤ OS
//--- session
input ulong           InpMagic            = 20260412;
input int             InpSlippagePts      = 30;

CTrade g_trade;

int    g_hEmaFast = INVALID_HANDLE;
int    g_hEmaSlow = INVALID_HANDLE;
int    g_hRsi     = INVALID_HANDLE;
int    g_hEmaFastHtf = INVALID_HANDLE;
int    g_hEmaSlowHtf = INVALID_HANDLE;

double g_emaFast[];
double g_emaSlow[];
double g_rsi[];
double g_stochK[];
double g_stochD[];
double g_emaFastHtf[];
double g_emaSlowHtf[];

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   SetTradeFillingBySymbol();

   g_hEmaFast = iMA(_Symbol, InpTf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, InpTf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRsi     = iRSI(_Symbol, InpTf, InpRsiLen, PRICE_CLOSE);
   if(InpUseHtfFilter)
   {
      g_hEmaFastHtf = iMA(_Symbol, InpHtf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_hEmaSlowHtf = iMA(_Symbol, InpHtf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   }

   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE || g_hRsi == INVALID_HANDLE)
      return INIT_FAILED;
   if(InpUseHtfFilter && (g_hEmaFastHtf == INVALID_HANDLE || g_hEmaSlowHtf == INVALID_HANDLE))
      return INIT_FAILED;

   ArraySetAsSeries(g_emaFast, true);
   ArraySetAsSeries(g_emaSlow, true);
   ArraySetAsSeries(g_rsi, true);
   ArraySetAsSeries(g_stochK, true);
   ArraySetAsSeries(g_stochD, true);
   ArraySetAsSeries(g_emaFastHtf, true);
   ArraySetAsSeries(g_emaSlowHtf, true);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEmaFast != INVALID_HANDLE) IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow);
   if(g_hRsi != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   if(g_hEmaFastHtf != INVALID_HANDLE) IndicatorRelease(g_hEmaFastHtf);
   if(g_hEmaSlowHtf != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowHtf);
}

//+------------------------------------------------------------------+
void OnTick()
{
   static datetime last_bar = 0;
   datetime t = iTime(_Symbol, InpTf, 0);
   if(t == last_bar)
   {
      // Still manage exits on tick if you use break-even / trailing — here bar-based only
      return;
   }
   last_bar = t;

   const int need = 400;
   if(CopyBuffer(g_hEmaFast, 0, 0, need, g_emaFast) < need) return;
   if(CopyBuffer(g_hEmaSlow, 0, 0, need, g_emaSlow) < need) return;
   if(CopyBuffer(g_hRsi, 0, 0, need + InpStochLen + InpStochK + InpStochD + 5, g_rsi) < need) return;

   if(!ComputeStochRsi(g_rsi, InpStochLen, InpStochK, InpStochD, g_stochK, g_stochD, need))
      return;

   if(InpUseHtfFilter)
   {
      if(CopyBuffer(g_hEmaFastHtf, 0, 0, 3, g_emaFastHtf) < 3) return;
      if(CopyBuffer(g_hEmaSlowHtf, 0, 0, 3, g_emaSlowHtf) < 3) return;
   }

   // bar 1 = last closed candle (tutorial: trade after confirmation candle closes)
   const int c = 1;
   const int p = 2;

   if(PositionExistsForMagic())
   {
      ManageOpenPosition(c, p);
      return;
   }

   if(!PassesFlatEmaFilter(c))
      return;

   // Long: EMA9 crosses EMA21 up at bar 1 close; Stoch RSI K,D leave oversold with bullish K/D cross
   const bool bull_cross = (g_emaFast[p] < g_emaSlow[p] && g_emaFast[c] > g_emaSlow[c]);
   const bool bear_cross = (g_emaFast[p] > g_emaSlow[p] && g_emaFast[c] < g_emaSlow[c]);

   if(!bull_cross && !bear_cross)
      return;

   if(InpUseHtfFilter)
   {
      if(bull_cross && !(g_emaFastHtf[c] > g_emaSlowHtf[c]))
         return;
      if(bear_cross && !(g_emaFastHtf[c] < g_emaSlowHtf[c]))
         return;
   }

   if(!MinBarsSincePreviousCrossOk())
      return;

   const bool stoch_long_ok =
      (g_stochK[p] < InpOsLevel && g_stochD[p] < InpOsLevel) &&
      (g_stochK[c] > g_stochD[c] && g_stochK[p] <= g_stochD[p]) &&
      (g_stochK[c] > InpOsLevel * 0.9); // "left" oversold — allow ~18 if OS=20

   const bool stoch_short_ok =
      (g_stochK[p] > InpObLevel && g_stochD[p] > InpObLevel) &&
      (g_stochK[c] < g_stochD[c] && g_stochK[p] >= g_stochD[p]) &&
      (g_stochK[c] < InpObLevel * 1.05);

   if(InpUseMidZoneFilter)
   {
      if(g_stochK[c] > 40.0 && g_stochK[c] < 60.0 && g_stochD[c] > 40.0 && g_stochD[c] < 60.0)
         return;
   }

   if(bull_cross && stoch_long_ok)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double low12 = MathMin(iLow(_Symbol, InpTf, c), iLow(_Symbol, InpTf, p));
      double sl = low12 - InpSlBufferPts * pt;
      sl = NormalizeDouble(sl, dg);
      if(sl >= ask - pt)
         sl = ask - 10 * pt;
      double risk = ask - sl;
      if(risk <= 0) return;
      double tp = ask + risk * InpTpRiskMultiple;
      tp = NormalizeDouble(tp, dg);
      g_trade.Buy(InpLots, _Symbol, ask, sl, tp, "EMA+StochRSI long");
      return;
   }

   if(bear_cross && stoch_short_ok)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double hi12 = MathMax(iHigh(_Symbol, InpTf, c), iHigh(_Symbol, InpTf, p));
      double sl = hi12 + InpSlBufferPts * pt;
      sl = NormalizeDouble(sl, dg);
      if(sl <= bid + pt)
         sl = bid + 10 * pt;
      double risk = sl - bid;
      if(risk <= 0) return;
      double tp = bid - risk * InpTpRiskMultiple;
      tp = NormalizeDouble(tp, dg);
      g_trade.Sell(InpLots, _Symbol, bid, sl, tp, "EMA+StochRSI short");
   }
}

//+------------------------------------------------------------------+
bool ComputeStochRsi(const double &rsi[], const int stoch_len, const int k_len, const int d_len,
                     double &out_k[], double &out_d[], const int out_count)
{
   int rsi_count = ArraySize(rsi);
   static double raw[];
   ArrayResize(raw, rsi_count);
   ArraySetAsSeries(raw, true);

   for(int i = 0; i < rsi_count; i++)
   {
      if(i + stoch_len > rsi_count)
      {
         raw[i] = 50.0;
         continue;
      }
      double lo = rsi[i];
      double hi = rsi[i];
      for(int j = 0; j < stoch_len; j++)
      {
         double v = rsi[i + j];
         if(v < lo) lo = v;
         if(v > hi) hi = v;
      }
      if(hi == lo)
         raw[i] = 50.0;
      else
         raw[i] = (rsi[i] - lo) / (hi - lo) * 100.0;
   }

   ArrayResize(out_k, out_count);
   ArrayResize(out_d, out_count);
   ArraySetAsSeries(out_k, true);
   ArraySetAsSeries(out_d, true);

   static double k_unsm[];
   ArrayResize(k_unsm, rsi_count);
   ArraySetAsSeries(k_unsm, true);

   for(int i = 0; i < rsi_count; i++)
   {
      if(i + k_len > rsi_count)
      {
         k_unsm[i] = raw[i];
         continue;
      }
      double s = 0.0;
      for(int j = 0; j < k_len; j++)
         s += raw[i + j];
      k_unsm[i] = s / (double)k_len;
   }

   for(int i = 0; i < out_count; i++)
   {
      if(i + d_len > rsi_count)
      {
         out_k[i] = k_unsm[i];
         out_d[i] = k_unsm[i];
         continue;
      }
      double sk = 0.0;
      for(int j = 0; j < d_len; j++)
         sk += k_unsm[i + j];
      out_d[i] = sk / (double)d_len;
      out_k[i] = k_unsm[i];
   }
   return true;
}

//+------------------------------------------------------------------+
bool PassesFlatEmaFilter(const int c)
{
   if(InpMinEmaSepPts <= 0.0)
      return true;
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sep = MathAbs(g_emaFast[c] - g_emaSlow[c]) / pt;
   return (sep >= InpMinEmaSepPts);
}

//+------------------------------------------------------------------+
bool MinBarsSincePreviousCrossOk()
{
   if(InpMinBarsSinceCross <= 0)
      return true;
   // Cross under test completed on bar 1 (index c=1): between shift 2 and 1.
   // Earliest earlier cross: between i+1 and i for i >= 3.
   for(int i = 3; i < 300; i++)
   {
      const bool cu = (g_emaFast[i + 1] < g_emaSlow[i + 1] && g_emaFast[i] > g_emaSlow[i]);
      const bool cd = (g_emaFast[i + 1] > g_emaSlow[i + 1] && g_emaFast[i] < g_emaSlow[i]);
      if(cu || cd)
         return (i - 1 >= InpMinBarsSinceCross);
   }
   return true;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
void ManageOpenPosition(const int c, const int p)
{
   if(!PositionSelectBySymbolForMagic())
      return;
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   long type = PositionGetInteger(POSITION_TYPE);
   double k1 = g_stochK[c];
   double d1 = g_stochD[c];

   if(InpExitOnEma9Break)
   {
      double close1 = iClose(_Symbol, InpTf, c);
      if(type == POSITION_TYPE_BUY && close1 < g_emaFast[c])
      {
         g_trade.PositionClose(ticket);
         return;
      }
      if(type == POSITION_TYPE_SELL && close1 > g_emaFast[c])
      {
         g_trade.PositionClose(ticket);
         return;
      }
   }

   if(InpExitOnStochZone)
   {
      if(type == POSITION_TYPE_BUY && k1 >= InpObLevel && d1 >= InpObLevel * 0.95)
      {
         g_trade.PositionClose(ticket);
         return;
      }
      if(type == POSITION_TYPE_SELL && k1 <= InpOsLevel && d1 <= InpOsLevel * 1.05)
      {
         g_trade.PositionClose(ticket);
         return;
      }
   }
}

//+------------------------------------------------------------------+
bool PositionSelectBySymbolForMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
