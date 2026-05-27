//+------------------------------------------------------------------+
//|                                              RSIConsolidation.mq5 |
//| Mean-reversion RSI for ranging markets; trend filters block runs |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Symbol (empty = chart symbol)
input group "=== Symbol & session ==="
input string InpSymbol = "";  

input group "=== Timeframe & bar logic ==="
input ENUM_TIMEFRAMES SignalTF = PERIOD_M15;
input bool      EntryOnNewBarOnly = true;

//--- Core: no trend / consolidation regime
input group "=== Regime: consolidation (anti-trend) ==="
input int       ADX_Period = 23;
input double    ADX_Max = 29.0;
input bool      UseATRRatioFilter = true;
input int       ATR_Period = 8;
input int       ATR_SMA_Period = 35;
input double    ATR_Ratio_Max = 1.36;
input bool      UseFlatEMAFilter = true;
input int       EMA_Fast = 13;
input int       EMA_Slow = 17;
input double    EMA_Separation_MaxPct = 0.26;

//--- RSI entries (fade extremes toward mean)
input group "=== RSI entries ==="
input int       RSI_Period = 8;
input ENUM_APPLIED_PRICE RSI_Price = PRICE_OPEN;
input double    RSI_Oversold = 22.0;
input double    RSI_Overbought = 63.0;

//--- Exits: mean target + hard ATR bracket
input group "=== Exits ==="
input bool      UseRSI_MeanExit = true;
input double    RSI_Exit_Long = 48.0;
input double    RSI_Exit_Short = 52.0;
input double    SL_ATR_Mult = 2.15;
input double    TP_ATR_Mult = 2.40;
input int       MaxBarsInTrade = 54;

input group "=== Risk & execution ==="
input double    Lots = 0.10;
input ulong     MagicNumber = 20250420;
input int       Slippage = 10;
input int       MaxSpreadPoints = 28;

CTrade trade;
string g_sym;

int h_rsi = INVALID_HANDLE;
int h_adx = INVALID_HANDLE;
int h_atr = INVALID_HANDLE;
int h_ema_fast = INVALID_HANDLE;
int h_ema_slow = INVALID_HANDLE;

datetime g_last_bar = 0;

bool PositionExistsByMagicSym(string sym, ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == (long)magic)
         return true;
   }
   return false;
}

ulong GetPositionTicketByMagicSym(string sym, ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == (long)magic)
         return t;
   }
   return 0;
}

bool SelectPositionTicketSymMagic(ulong ticket, string sym, ulong magic)
{
   if(!PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == (long)magic;
}

double NormalizeVolume(string sym, double vol)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step > 0.0)
      vol = MathFloor(vol / step) * step;
   if(vol < minLot) vol = minLot;
   if(vol > maxLot) vol = maxLot;
   return vol;
}

int CurrentSpreadPoints(string sym)
{
   long spread = 0;
   if(!SymbolInfoInteger(sym, SYMBOL_SPREAD, spread))
      return 999999;
   return (int)spread;
}

double MinStopsDistancePrice(string sym)
{
   long lvl = 0;
   if(!SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL, lvl))
      return 0;
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(pt <= 0)
      return 0;
   return (double)lvl * pt;
}

bool Copy1(int handle, double &v)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, 0, 1, b) < 1) return false;
   v = b[0];
   return true;
}

bool RSI_Buffers(double &cur, double &prev, double &twoAgo)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(h_rsi, 0, 0, 3, b) < 3) return false;
   cur = b[0];
   prev = b[1];
   twoAgo = b[2];
   return true;
}

bool Regime_IsConsolidation()
{
   double adx = 0;
   if(!Copy1(h_adx, adx))
      return false;
   if(adx >= ADX_Max)
      return false;

   if(UseATRRatioFilter)
   {
      double atrArr[], atrSma[];
      ArraySetAsSeries(atrArr, true);
      if(CopyBuffer(h_atr, 0, 0, ATR_SMA_Period + 1, atrArr) < ATR_SMA_Period + 1)
         return false;
      double sum = 0;
      for(int i = 1; i <= ATR_SMA_Period; i++)
         sum += atrArr[i];
      double smaAtr = sum / (double)ATR_SMA_Period;
      if(smaAtr <= 0.0)
         return false;
      double ratio = atrArr[0] / smaAtr;
      if(ratio > ATR_Ratio_Max)
         return false;
   }

   if(UseFlatEMAFilter)
   {
      double ef[], es[];
      ArraySetAsSeries(ef, true);
      ArraySetAsSeries(es, true);
      if(CopyBuffer(h_ema_fast, 0, 0, 1, ef) < 1) return false;
      if(CopyBuffer(h_ema_slow, 0, 0, 1, es) < 1) return false;
      double c = SymbolInfoDouble(g_sym, SYMBOL_BID);
      if(c <= 0) return false;
      double sep = MathAbs(ef[0] - es[0]) / c * 100.0;
      if(sep > EMA_Separation_MaxPct)
         return false;
   }

   return true;
}

bool Entry_BuyCross(double twoAgo, double prev)
{
   return (twoAgo <= RSI_Oversold && prev > RSI_Oversold);
}

bool Entry_SellCross(double twoAgo, double prev)
{
   return (twoAgo >= RSI_Overbought && prev < RSI_Overbought);
}

void TryCloseByRSI(ENUM_POSITION_TYPE typ, double rsi)
{
   ulong tk = GetPositionTicketByMagicSym(g_sym, MagicNumber);
   if(tk == 0 || !SelectPositionTicketSymMagic(tk, g_sym, MagicNumber))
      return;
   if(!UseRSI_MeanExit)
      return;
   if(typ == POSITION_TYPE_BUY && rsi >= RSI_Exit_Long)
      trade.PositionClose(tk);
   else if(typ == POSITION_TYPE_SELL && rsi <= RSI_Exit_Short)
      trade.PositionClose(tk);
}

void ManageOpenPosition(double rsi)
{
   ulong tk = GetPositionTicketByMagicSym(g_sym, MagicNumber);
   if(tk == 0 || !SelectPositionTicketSymMagic(tk, g_sym, MagicNumber))
      return;
   ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
   int barsAgo = iBarShift(g_sym, SignalTF, openT, false);
   if(barsAgo >= 0 && barsAgo >= MaxBarsInTrade)
   {
      trade.PositionClose(tk);
      return;
   }
   TryCloseByRSI(typ, rsi);
}

int OnInit()
{
   g_sym = InpSymbol;
   StringTrimLeft(g_sym);
   StringTrimRight(g_sym);
   if(StringLen(g_sym) == 0)
      g_sym = _Symbol;

   if(!SymbolSelect(g_sym, true))
   {
      Print("RSIConsolidation: SymbolSelect failed: ", g_sym);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   h_rsi = iRSI(g_sym, SignalTF, RSI_Period, RSI_Price);
   h_adx = iADX(g_sym, SignalTF, ADX_Period);
   h_atr = iATR(g_sym, SignalTF, ATR_Period);
   h_ema_fast = iMA(g_sym, SignalTF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_slow = iMA(g_sym, SignalTF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(h_rsi == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE
      || h_ema_fast == INVALID_HANDLE || h_ema_slow == INVALID_HANDLE)
   {
      Print("RSIConsolidation: indicator init failed");
      return INIT_FAILED;
   }

   Print("RSIConsolidation: symbol=", g_sym, " TF=", EnumToString(SignalTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(h_rsi != INVALID_HANDLE) IndicatorRelease(h_rsi);
   if(h_adx != INVALID_HANDLE) IndicatorRelease(h_adx);
   if(h_atr != INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_ema_fast != INVALID_HANDLE) IndicatorRelease(h_ema_fast);
   if(h_ema_slow != INVALID_HANDLE) IndicatorRelease(h_ema_slow);
}

bool EnoughHistory()
{
   int need = MathMax(RSI_Period + 3, MathMax(ADX_Period + 2, ATR_SMA_Period + 3));
   if(Bars(g_sym, SignalTF) < need)
      return false;
   return true;
}

void OnTick()
{
   if(!EnoughHistory())
      return;

   if(MaxSpreadPoints > 0 && CurrentSpreadPoints(g_sym) > MaxSpreadPoints)
      return;

   double rsi, rsiPrev, rsi2;
   if(!RSI_Buffers(rsi, rsiPrev, rsi2))
      return;

   datetime barTime = iTime(g_sym, SignalTF, 0);
   bool isNew = (barTime != g_last_bar);

   if(PositionExistsByMagicSym(g_sym, MagicNumber))
   {
      ManageOpenPosition(rsi);
      if(isNew)
         g_last_bar = barTime;
      return;
   }

   if(EntryOnNewBarOnly && !isNew)
      return;

   g_last_bar = barTime;

   if(!Regime_IsConsolidation())
      return;

   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   if(CopyBuffer(h_atr, 0, 0, 1, atrArr) < 1)
      return;
   double atr = atrArr[0];
   int dig = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);

   double slDist = atr * SL_ATR_Mult;
   double tpDist = atr * TP_ATR_Mult;
   double minD = MinStopsDistancePrice(g_sym);
   if(slDist < minD)
      slDist = minD;
   if(tpDist < minD)
      tpDist = minD;

   double vol = NormalizeVolume(g_sym, Lots);

   if(Entry_BuyCross(rsi2, rsiPrev))
   {
      double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      double sl = ask - slDist;
      double tp = ask + tpDist;
      sl = NormalizeDouble(sl, dig);
      tp = NormalizeDouble(tp, dig);
      trade.Buy(vol, g_sym, ask, sl, tp, "RSIConsolidation BUY");
   }
   else if(Entry_SellCross(rsi2, rsiPrev))
   {
      double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double sl = bid + slDist;
      double tp = bid - tpDist;
      sl = NormalizeDouble(sl, dig);
      tp = NormalizeDouble(tp, dig);
      trade.Sell(vol, g_sym, bid, sl, tp, "RSIConsolidation SELL");
   }
}

//+------------------------------------------------------------------+
