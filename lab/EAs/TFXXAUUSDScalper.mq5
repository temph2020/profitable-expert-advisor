//+------------------------------------------------------------------+
//|                                          TFXXAUUSDScalper.mq5    |
//|  Gold (XAUUSD) Donchian breakout scalper — momentum / range    |
//|  breakout style suited to impulse-or-consolidate dynamics.      |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property link      ""
#property version   "1.00"
#property description "Donchian channel breakout on XAUUSD; optional consolidation filter; percent-risk or fixed lots."

#include <Trade/Trade.mqh>

input group "=== Instrument ==="
input string              InpSymbol           = "XAUUSD";

input group "=== Session ==="
input ENUM_TIMEFRAMES     InpSignalTF         = PERIOD_M5;
input bool                InpUseSessionFilter = false;
input int                 InpSessionStartHour = 7;
input int                 InpSessionEndHour   = 22;

input group "=== Donchian breakout ==="
input int                 InpDonchianPeriod   = 20;       // Lookback for channel high/low (past bars exclude signal bar)
input bool                InpRequireFreshBreak = true;    // Close[2] inside prior upper/lower band (no churn)
input bool                InpTradeLong          = true;
input bool                InpTradeShort         = true;

input group "=== Consolidation filter (horizontal → breakout) ==="
input bool                InpUseNarrowChannelFilter = false;
input double              InpMaxChannelWidthAtrMult = 3.0; // Upper-Lower <= this * ATR(shift 2)

input group "=== Stops & targets (Nick-style RR) ==="
input int                 InpSlBufferPoints    = 30;       // Beyond opposite Donchian / structural low-high
input double              InpTpRiskReward      = 2.0;      // TP distance = RR * risk distance
input bool                InpUseMidStopFallback = false;  // Optional tighter SL at channel mid (more aggressive)

input group "=== Risk ==="
input bool                InpUsePercentRisk    = true;
input double              InpRiskPercent      = 1.0;      // % balance per trade (video example)
input double              InpFixedLots        = 0.10;
input int                 InpMagic             = 928001;
input int                 InpSlippagePoints    = 50;
input int                 InpMaxSpreadPoints  = 60;
input int                 InpMaxPositions     = 1;

input group "=== Indicators ==="
input int                 InpAtrPeriod        = 14;

CTrade g_trade;

int g_atr = INVALID_HANDLE;
datetime g_lastBar = 0;

string WorkSymbol()
{
   string s = InpSymbol;
   StringTrimLeft(s);
   StringTrimRight(s);
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
   const int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

double DonchianUpper(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shiftAnchor)
{
   if(period < 1)
      return 0.0;
   double mx = -DBL_MAX;
   for(int i = shiftAnchor + 1; i <= shiftAnchor + period; i++)
   {
      const double hi = iHigh(sym, tf, i);
      if(hi > mx)
         mx = hi;
   }
   return mx;
}

double DonchianLower(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shiftAnchor)
{
   if(period < 1)
      return 0.0;
   double mn = DBL_MAX;
   for(int i = shiftAnchor + 1; i <= shiftAnchor + period; i++)
   {
      const double lo = iLow(sym, tf, i);
      if(lo < mn)
         mn = lo;
   }
   return mn;
}

double AtrAt(const int shift)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(g_atr == INVALID_HANDLE || CopyBuffer(g_atr, 0, shift, 1, b) != 1)
      return 0.0;
   return b[0];
}

double NormalizeLots(const string sym, double lots)
{
   double mn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(st > 0.0)
      lots = MathFloor(lots / st) * st;
   if(lots < mn)
      lots = mn;
   if(lots > mx)
      lots = mx;
   return lots;
}

bool MoneyPerLotAtSl(const string sym, const ENUM_ORDER_TYPE type, const double openPrice, const double slPrice, double &lossPerLot)
{
   lossPerLot = 0.0;
   double p = 0.0;
   if(!OrderCalcProfit(type, sym, 1.0, openPrice, slPrice, p))
      return false;
   lossPerLot = MathAbs(p);
   return (lossPerLot > 0.0);
}

double LotsFromPercentRisk(const string sym, const ENUM_ORDER_TYPE type, const double openPrice, const double slPrice)
{
   double perLotLoss = 0.0;
   if(!MoneyPerLotAtSl(sym, type, openPrice, slPrice, perLotLoss))
      return InpFixedLots;

   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * (InpRiskPercent / 100.0);
   if(riskMoney <= 0.0 || perLotLoss <= 0.0)
      return NormalizeLots(sym, InpFixedLots);

   double lots = riskMoney / perLotLoss;
   return NormalizeLots(sym, lots);
}

bool SpreadOk(const string sym)
{
   const long sp = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   return ((double)sp <= (double)InpMaxSpreadPoints);
}

int CountMagicPositions(const string sym)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      n++;
   }
   return n;
}

void BuildStopsBuy(const string sym, const double entry, const double upperD1, const double lowerD1,
                   double &sl, double &tp)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const double buf = (double)InpSlBufferPoints * pt;
   double riskDist = entry - (lowerD1 - buf);
   sl = lowerD1 - buf;

   if(InpUseMidStopFallback)
   {
      const double mid = (upperD1 + lowerD1) * 0.5;
      const double distMid = entry - mid;
      if(distMid > 0 && distMid < riskDist)
      {
         sl = mid - buf;
         riskDist = entry - sl;
      }
   }

   const long lvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   const double minD = (double)lvl * pt;
   if(minD > 0.0 && entry - sl < minD)
      sl = entry - minD;

   riskDist = entry - sl;
   tp = entry + riskDist * InpTpRiskReward;

   if(minD > 0.0 && tp - entry < minD)
      tp = entry + minD;

   const int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
}

void BuildStopsSell(const string sym, const double entry, const double upperD1, const double lowerD1,
                    double &sl, double &tp)
{
   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   const double buf = (double)InpSlBufferPoints * pt;
   double riskDist = (upperD1 + buf) - entry;
   sl = upperD1 + buf;

   if(InpUseMidStopFallback)
   {
      const double mid = (upperD1 + lowerD1) * 0.5;
      const double distMid = mid - entry;
      if(distMid > 0 && distMid < riskDist)
      {
         sl = mid + buf;
         riskDist = sl - entry;
      }
   }

   const long lvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   const double minD = (double)lvl * pt;
   if(minD > 0.0 && sl - entry < minD)
      sl = entry + minD;

   riskDist = sl - entry;
   tp = entry - riskDist * InpTpRiskReward;

   if(minD > 0.0 && entry - tp < minD)
      tp = entry - minD;

   const int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);
}

bool NarrowChannelOk(const string sym, const ENUM_TIMEFRAMES tf, const int period)
{
   if(!InpUseNarrowChannelFilter)
      return true;
   const double up = DonchianUpper(sym, tf, period, 2);
   const double lo = DonchianLower(sym, tf, period, 2);
   const double atr = AtrAt(2);
   if(up <= 0 || lo <= 0 || atr <= 0)
      return false;
   const double width = up - lo;
   return (width <= atr * InpMaxChannelWidthAtrMult);
}

int OnInit()
{
   const string sym = WorkSymbol();
   if(!SymbolSelect(sym, true))
   {
      Print("TFXXAUUSDScalper: symbol not available: ", sym);
      return INIT_FAILED;
   }
   if(InpDonchianPeriod < 2)
   {
      Print("TFXXAUUSDScalper: InpDonchianPeriod must be >= 2");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(sym);

   g_atr = iATR(sym, InpSignalTF, InpAtrPeriod);
   if(g_atr == INVALID_HANDLE)
   {
      Print("TFXXAUUSDScalper: ATR init failed");
      return INIT_FAILED;
   }

   Print("TFXXAUUSDScalper: ", sym, " ", EnumToString(InpSignalTF),
         " Donchian=", InpDonchianPeriod, " RR=", InpTpRiskReward,
         " risk%=", (InpUsePercentRisk ? DoubleToString(InpRiskPercent, 2) : "off"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
   g_atr = INVALID_HANDLE;
}

void OnTick()
{
   const string sym = WorkSymbol();
   const datetime t0 = iTime(sym, InpSignalTF, 0);
   if(t0 == 0 || t0 == g_lastBar)
      return;
   g_lastBar = t0;

   if(!SessionOk() || !SpreadOk(sym))
      return;
   if(CountMagicPositions(sym) >= InpMaxPositions)
      return;

   const int p = InpDonchianPeriod;
   const double c1 = iClose(sym, InpSignalTF, 1);
   const double c2 = iClose(sym, InpSignalTF, 2);
   if(c1 <= 0.0 || c2 <= 0.0)
      return;

   const double up1 = DonchianUpper(sym, InpSignalTF, p, 1);
   const double lo1 = DonchianLower(sym, InpSignalTF, p, 1);
   const double up2 = DonchianUpper(sym, InpSignalTF, p, 2);
   const double lo2 = DonchianLower(sym, InpSignalTF, p, 2);

   if(up1 <= 0 || lo1 <= 0 || up2 <= 0 || lo2 <= 0)
      return;

   if(!NarrowChannelOk(sym, InpSignalTF, p))
      return;

   bool longSig = InpTradeLong && (c1 > up1);
   bool shortSig = InpTradeShort && (c1 < lo1);

   if(InpRequireFreshBreak)
   {
      longSig = longSig && (c2 <= up2);
      shortSig = shortSig && (c2 >= lo2);
   }

   if(!longSig && !shortSig)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;

   if(longSig && !shortSig)
   {
      double sl = 0.0, tp = 0.0;
      BuildStopsBuy(sym, tick.ask, up1, lo1, sl, tp);
      const double lots = InpUsePercentRisk ? LotsFromPercentRisk(sym, ORDER_TYPE_BUY, tick.ask, sl) : NormalizeLots(sym, InpFixedLots);
      if(!g_trade.Buy(lots, sym, tick.ask, sl, tp, "TFX Gold Donchian↑"))
         Print("Buy failed ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      return;
   }

   if(shortSig && !longSig)
   {
      double sl = 0.0, tp = 0.0;
      BuildStopsSell(sym, tick.bid, up1, lo1, sl, tp);
      const double lots = InpUsePercentRisk ? LotsFromPercentRisk(sym, ORDER_TYPE_SELL, tick.bid, sl) : NormalizeLots(sym, InpFixedLots);
      if(!g_trade.Sell(lots, sym, tick.bid, sl, tp, "TFX Gold Donchian↓"))
         Print("Sell failed ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      return;
   }

   // Bothtrue — rare; skip to avoid ambiguous execution
}

//+------------------------------------------------------------------+
