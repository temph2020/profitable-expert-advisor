//+------------------------------------------------------------------+
//| USDCHF Playbook — six behavioral rules (momentum, traps, zones)   |
//+------------------------------------------------------------------+
#property copyright "lab/USDCHF"
#property version   "1.20"
#property strict

#include <Trade/Trade.mqh>

input group "=== Symbol / TF ==="
input ENUM_TIMEFRAMES Timeframe         = PERIOD_M15;
input ENUM_TIMEFRAMES HtfTimeframe      = PERIOD_H4;
input ENUM_TIMEFRAMES DailyTimeframe    = PERIOD_D1;
input int             MagicNumber       = 20260625;

input group "=== Daily swing bias (rule 6) ==="
input bool            UseDailyBias      = true;
input int             DailyEmaPeriod    = 50;

input group "=== HTF zones (rule 3) ==="
input int             HtfZoneBars       = 20;
input double          MinBreakBodyRatio = 0.55;

input group "=== Double trap (rule 2) ==="
input bool            UseDoubleTrap     = true;

input group "=== Session (rules 1 & 4) ==="
input int             NyChaosStartHour  = 12;
input int             NyChaosEndHour    = 15;
input int             MomentumStartHour = 15;
input int             MomentumEndHour   = 2;

input group "=== LTF entry ==="
input int             LtfFastEma        = 8;
input int             LtfSlowEma        = 21;
input int             EntryMode         = 1;  // 0=h4 break 1=mixed 2=trap 3=LTF momentum
input bool            AllowLtfPullback  = true;
input bool            AllowEmaCross       = true;
input double          MinEmaGapPips       = 0.5;

input group "=== Risk ==="
input double          LotSize           = 0.10;
input int             AtrPeriod         = 14;
input double          AtrSlMult         = 1.8;
input double          AtrTpMult         = 4.0;
input bool            UseTrailing       = true;
input double          TrailAtrMult      = 1.2;
input int             MaxBarsInTrade    = 96;
input bool            ExtendHoldMomentum = true;
input int             CooldownBars      = 1;
input int             MaxSpreadPips     = 8;

input group "=== News compression (rule 5) ==="
input bool            UseCompressionFilter = true;
input double          CompressAtrRatio  = 0.70;
input int             CompressLookback  = 48;
input bool            UseMomentumWindow = true;

input group "=== Combo modules (组合逻辑) ==="
input int             ComboMode           = 0;   // 0=任一触发 1=主信号+确认 2=评分达标
input int             MinComboScore       = 2;   // ComboMode=2 时最少几分
input bool            AllowRsiPullback    = true;
input int             RsiPeriod           = 14;
input double          RsiBuyZone          = 42.0;
input double          RsiSellZone         = 58.0;
input bool            AllowMacdMomentum   = true;
input int             MacdFast            = 12;
input int             MacdSlow            = 26;
input int             MacdSignal          = 9;
input bool            AllowInsideBarBreak = true;
input bool            AllowAsianBreakout  = true;
input int             AsianStartHour      = 0;
input int             AsianEndHour        = 8;
input double          AsianBreakBufferPips = 1.0;
input bool            UseH1TrendFilter    = true;
input int             H1EmaPeriod         = 50;
input bool            UseAdxFilter        = false;
input int             AdxPeriod           = 14;
input double          AdxMin              = 20.0;

CTrade   g_trade;
int      g_fastHandle = INVALID_HANDLE;
int      g_slowHandle = INVALID_HANDLE;
int      g_atrHandle  = INVALID_HANDLE;
int      g_dailyEma   = INVALID_HANDLE;
int      g_rsiHandle  = INVALID_HANDLE;
int      g_macdHandle = INVALID_HANDLE;
int      g_adxHandle  = INVALID_HANDLE;
int      g_h1EmaHandle = INVALID_HANDLE;
datetime g_lastBar    = 0;
int      g_lastEntryBar = -100000;
int      g_bars       = 0;
double   g_trail      = 0.0;

double PipSize()
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (d == 3 || d == 5) ? pt * 10.0 : pt;
}

int SpreadPips()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 9999;
   return (int)MathRound((ask - bid) / PipSize());
}

bool HourInRange(const int h, const int start, const int end)
{
   if(start == end) return true;
   if(start < end) return (h >= start && h < end);
   return (h >= start || h < end);
}

bool InMomentumWindow()
{
   MqlDateTime ts; TimeToStruct(TimeCurrent(), ts);
   return HourInRange(ts.hour, MomentumStartHour, MomentumEndHour);
}

bool InNyChaos()
{
   MqlDateTime ts; TimeToStruct(TimeCurrent(), ts);
   return HourInRange(ts.hour, NyChaosStartHour, NyChaosEndHour);
}

bool SessionOk()
{
   if(InNyChaos()) return false;
   if(!UseMomentumWindow) return true;
   return InMomentumWindow();
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, Timeframe, 0);
   if(t <= 0 || t == g_lastBar) return false;
   g_lastBar = t;
   g_bars++;
   return true;
}

bool Copy1(const int h, const int sh, const int buf, double &v)
{
   double b[1];
   if(CopyBuffer(h, buf, sh, 1, b) <= 0) return false;
   v = b[0]; return true;
}

int TfShift(const ENUM_TIMEFRAMES tf, const int ltf_sh)
{
   datetime t = iTime(_Symbol, Timeframe, ltf_sh);
   if(t <= 0) return -1;
   return iBarShift(_Symbol, tf, t, true);
}

double BodyRatio(const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(_Symbol, tf, sh);
   double h = iHigh(_Symbol, tf, sh);
   double l = iLow(_Symbol, tf, sh);
   double c = iClose(_Symbol, tf, sh);
   double rng = h - l;
   if(rng <= 0) return 0;
   return MathAbs(c - o) / rng;
}

bool HtfZoneAt(const int hsh, double &resistance, double &support)
{
   if(hsh < 0) return false;
   resistance = -1e100;
   support = 1e100;
   for(int i = hsh + 1; i <= hsh + HtfZoneBars; i++)
   {
      double hi = iHigh(_Symbol, HtfTimeframe, i);
      double lo = iLow(_Symbol, HtfTimeframe, i);
      if(hi > resistance) resistance = hi;
      if(lo < support) support = lo;
   }
   return (resistance > -1e50 && support < 1e50);
}

int DailyBias(const int ltf_sh)
{
   if(!UseDailyBias) return 0;
   int dsh = TfShift(DailyTimeframe, ltf_sh);
   if(dsh < 0) return 0;
   double ema, close;
   if(!Copy1(g_dailyEma, dsh, 0, ema)) return 0;
   close = iClose(_Symbol, DailyTimeframe, dsh);
   if(close > ema) return 1;
   if(close < ema) return -1;
   return 0;
}

bool HtfBullBreak(const int ltf_sh)
{
   int hsh = TfShift(HtfTimeframe, ltf_sh);
   if(hsh < 0) return false;
   double res, sup;
   if(!HtfZoneAt(hsh + 1, res, sup)) return false;
   double c = iClose(_Symbol, HtfTimeframe, hsh);
   return (c > res && BodyRatio(HtfTimeframe, hsh) >= MinBreakBodyRatio);
}

bool HtfBearBreak(const int ltf_sh)
{
   int hsh = TfShift(HtfTimeframe, ltf_sh);
   if(hsh < 0) return false;
   double res, sup;
   if(!HtfZoneAt(hsh + 1, res, sup)) return false;
   double c = iClose(_Symbol, HtfTimeframe, hsh);
   return (c < sup && BodyRatio(HtfTimeframe, hsh) >= MinBreakBodyRatio);
}

bool BullTrap(const int ltf_sh)
{
   if(!UseDoubleTrap) return false;
   int hsh = TfShift(HtfTimeframe, ltf_sh);
   if(hsh < 0) return false;
   double res, sup;
   if(!HtfZoneAt(hsh + 2, res, sup)) return false;
   double hi = iHigh(_Symbol, HtfTimeframe, hsh + 1);
   double cl = iClose(_Symbol, HtfTimeframe, hsh + 1);
   return (hi > res && cl < res);
}

bool BearTrap(const int ltf_sh)
{
   if(!UseDoubleTrap) return false;
   int hsh = TfShift(HtfTimeframe, ltf_sh);
   if(hsh < 0) return false;
   double res, sup;
   if(!HtfZoneAt(hsh + 2, res, sup)) return false;
   double lo = iLow(_Symbol, HtfTimeframe, hsh + 1);
   double cl = iClose(_Symbol, HtfTimeframe, hsh + 1);
   return (lo < sup && cl > sup);
}

bool CompressionOk(const int sh)
{
   if(!UseCompressionFilter || !InNyChaos()) return true;
   double atrNow, atrSum = 0;
   if(!Copy1(g_atrHandle, sh, 0, atrNow)) return true;
   int n = MathMin(CompressLookback, 200);
   for(int i = sh; i < sh + n; i++)
   {
      double a;
      if(!Copy1(g_atrHandle, i, 0, a)) continue;
      atrSum += a;
   }
   double avg = atrSum / MathMax(n, 1);
   if(avg <= 0) return true;
   return (atrNow / avg >= CompressAtrRatio);
}

bool PullbackLong(const int sh)
{
   double f, s, close, low;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   close = iClose(_Symbol, Timeframe, sh);
   low   = iLow(_Symbol, Timeframe, sh);
   return (f > s && low <= f && close > f);
}

bool PullbackShort(const int sh)
{
   double f, s, close, high;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   close = iClose(_Symbol, Timeframe, sh);
   high  = iHigh(_Symbol, Timeframe, sh);
   return (f < s && high >= f && close < f);
}

bool ReclaimLong(const int sh)
{
   int hsh = TfShift(HtfTimeframe, sh);
   if(hsh < 0) return false;
   double res, sup, f;
   if(!HtfZoneAt(hsh + 1, res, sup)) return false;
   if(!Copy1(g_fastHandle, sh, 0, f)) return false;
   double c = iClose(_Symbol, Timeframe, sh);
   return (BullTrap(sh) && c > res && c > f);
}

bool ReclaimShort(const int sh)
{
   int hsh = TfShift(HtfTimeframe, sh);
   if(hsh < 0) return false;
   double res, sup, f;
   if(!HtfZoneAt(hsh + 1, res, sup)) return false;
   if(!Copy1(g_fastHandle, sh, 0, f)) return false;
   double c = iClose(_Symbol, Timeframe, sh);
   return (BearTrap(sh) && c < sup && c < f);
}

bool HasOurPosition()
{
   return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == MagicNumber;
}

void CloseOur(const string reason)
{
   if(!HasOurPosition()) return;
   if(g_trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET)))
      Print("[USDCHF Playbook] close ", reason);
   g_trail = 0;
}

bool TryOpen(const bool isLong)
{
   if(HasOurPosition()) return false;
   if(OneTradeBlocked()) return false;
   g_trade.SetExpertMagicNumber(MagicNumber);
   bool ok = isLong ? g_trade.Buy(LotSize, _Symbol) : g_trade.Sell(LotSize, _Symbol);
   if(ok)
   {
      g_lastEntryBar = g_bars;
      g_trail = 0;
      Print("[USDCHF Playbook] ", isLong ? "BUY" : "SELL");
   }
   return ok;
}

bool OneTradeBlocked()
{
   if(MaxSpreadPips > 0 && SpreadPips() > MaxSpreadPips) return true;
   if(g_bars - g_lastEntryBar < CooldownBars) return true;
   return false;
}

bool EmaGapOk(const int sh)
{
   if(MinEmaGapPips <= 0) return true;
   double f, s;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   return (MathAbs(f - s) / PipSize() >= MinEmaGapPips);
}

bool TrendLong(const int sh)
{
   double f, s;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   return (f > s);
}

bool TrendShort(const int sh)
{
   double f, s;
   if(!Copy1(g_fastHandle, sh, 0, f) || !Copy1(g_slowHandle, sh, 0, s)) return false;
   return (f < s);
}

bool EmaCrossLong(const int sh)
{
   double f1, f2, s1, s2;
   if(!Copy1(g_fastHandle, sh, 0, f1) || !Copy1(g_fastHandle, sh + 1, 0, f2)) return false;
   if(!Copy1(g_slowHandle, sh, 0, s1) || !Copy1(g_slowHandle, sh + 1, 0, s2)) return false;
   return (f2 <= s2 && f1 > s1);
}

bool EmaCrossShort(const int sh)
{
   double f1, f2, s1, s2;
   if(!Copy1(g_fastHandle, sh, 0, f1) || !Copy1(g_fastHandle, sh + 1, 0, f2)) return false;
   if(!Copy1(g_slowHandle, sh, 0, s1) || !Copy1(g_slowHandle, sh + 1, 0, s2)) return false;
   return (f2 >= s2 && f1 < s1);
}

bool LtfMomentumLong(const int sh)
{
   if(!EmaGapOk(sh)) return false;
   bool pb = AllowLtfPullback && PullbackLong(sh) && TrendLong(sh);
   bool x  = AllowEmaCross && EmaCrossLong(sh);
   return (pb || x);
}

bool LtfMomentumShort(const int sh)
{
   if(!EmaGapOk(sh)) return false;
   bool pb = AllowLtfPullback && PullbackShort(sh) && TrendShort(sh);
   bool x  = AllowEmaCross && EmaCrossShort(sh);
   return (pb || x);
}

bool H1TrendLong(const int sh)
{
   if(!UseH1TrendFilter) return true;
   int h1sh = TfShift(PERIOD_H1, sh);
   if(h1sh < 0) return false;
   double ema, close;
   if(!Copy1(g_h1EmaHandle, h1sh, 0, ema)) return false;
   close = iClose(_Symbol, PERIOD_H1, h1sh);
   return (close > ema);
}

bool H1TrendShort(const int sh)
{
   if(!UseH1TrendFilter) return true;
   int h1sh = TfShift(PERIOD_H1, sh);
   if(h1sh < 0) return false;
   double ema, close;
   if(!Copy1(g_h1EmaHandle, h1sh, 0, ema)) return false;
   close = iClose(_Symbol, PERIOD_H1, h1sh);
   return (close < ema);
}

bool AdxOk(const int sh)
{
   if(!UseAdxFilter) return true;
   double adx;
   if(!Copy1(g_adxHandle, sh, 0, adx)) return false;
   return (adx >= AdxMin);
}

bool RsiPullbackLong(const int sh)
{
   if(!AllowRsiPullback) return false;
   double r1, r2;
   if(!Copy1(g_rsiHandle, sh, 0, r1) || !Copy1(g_rsiHandle, sh + 1, 0, r2)) return false;
   return (r2 <= RsiBuyZone && r1 > RsiBuyZone && TrendLong(sh));
}

bool RsiPullbackShort(const int sh)
{
   if(!AllowRsiPullback) return false;
   double r1, r2;
   if(!Copy1(g_rsiHandle, sh, 0, r1) || !Copy1(g_rsiHandle, sh + 1, 0, r2)) return false;
   return (r2 >= RsiSellZone && r1 < RsiSellZone && TrendShort(sh));
}

bool MacdMomentumLong(const int sh)
{
   if(!AllowMacdMomentum) return false;
   double h1, h2;
   if(!Copy1(g_macdHandle, sh, 2, h1) || !Copy1(g_macdHandle, sh + 1, 2, h2)) return false;
   return (h1 > h2 && h1 > 0);
}

bool MacdMomentumShort(const int sh)
{
   if(!AllowMacdMomentum) return false;
   double h1, h2;
   if(!Copy1(g_macdHandle, sh, 2, h1) || !Copy1(g_macdHandle, sh + 1, 2, h2)) return false;
   return (h1 < h2 && h1 < 0);
}

bool InsideBarBreakLong(const int sh)
{
   if(!AllowInsideBarBreak) return false;
   double hiM = iHigh(_Symbol, Timeframe, sh + 1);
   double loM = iLow(_Symbol, Timeframe, sh + 1);
   double hiI = iHigh(_Symbol, Timeframe, sh);
   double loI = iLow(_Symbol, Timeframe, sh);
   double cI  = iClose(_Symbol, Timeframe, sh);
   if(hiI >= hiM || loI <= loM) return false;
   return (cI > hiM && TrendLong(sh));
}

bool InsideBarBreakShort(const int sh)
{
   if(!AllowInsideBarBreak) return false;
   double hiM = iHigh(_Symbol, Timeframe, sh + 1);
   double loM = iLow(_Symbol, Timeframe, sh + 1);
   double hiI = iHigh(_Symbol, Timeframe, sh);
   double loI = iLow(_Symbol, Timeframe, sh);
   double cI  = iClose(_Symbol, Timeframe, sh);
   if(hiI >= hiM || loI <= loM) return false;
   return (cI < loM && TrendShort(sh));
}

bool AsianRange(const int sh, double &aHigh, double &aLow)
{
   aHigh = -1e100;
   aLow = 1e100;
   datetime barTime = iTime(_Symbol, Timeframe, sh);
   if(barTime <= 0) return false;
   MqlDateTime ts; TimeToStruct(barTime, ts);
   if(!HourInRange(ts.hour, AsianEndHour, AsianEndHour + 12)) return false;

   for(int i = sh; i < sh + 96; i++)
   {
      datetime t = iTime(_Symbol, Timeframe, i);
      if(t <= 0) break;
      MqlDateTime bt; TimeToStruct(t, bt);
      if(!HourInRange(bt.hour, AsianStartHour, AsianEndHour)) continue;
      double hi = iHigh(_Symbol, Timeframe, i);
      double lo = iLow(_Symbol, Timeframe, i);
      if(hi > aHigh) aHigh = hi;
      if(lo < aLow) aLow = lo;
   }
   return (aHigh > -1e50 && aLow < 1e50 && aHigh > aLow);
}

bool AsianBreakoutLong(const int sh)
{
   if(!AllowAsianBreakout) return false;
   double aHi, aLo;
   if(!AsianRange(sh, aHi, aLo)) return false;
   double buf = AsianBreakBufferPips * PipSize();
   double c = iClose(_Symbol, Timeframe, sh);
   return (c > aHi + buf && TrendLong(sh));
}

bool AsianBreakoutShort(const int sh)
{
   if(!AllowAsianBreakout) return false;
   double aHi, aLo;
   if(!AsianRange(sh, aHi, aLo)) return false;
   double buf = AsianBreakBufferPips * PipSize();
   double c = iClose(_Symbol, Timeframe, sh);
   return (c < aLo - buf && TrendShort(sh));
}

bool PrimaryLong(const int sh)
{
   if(EntryMode == 0) return HtfBullBreak(sh);
   if(EntryMode == 2) return ReclaimLong(sh);
   if(EntryMode == 3) return LtfMomentumLong(sh);
   return (HtfBullBreak(sh) || ReclaimLong(sh) || LtfMomentumLong(sh) || PullbackLong(sh));
}

bool PrimaryShort(const int sh)
{
   if(EntryMode == 0) return HtfBearBreak(sh);
   if(EntryMode == 2) return ReclaimShort(sh);
   if(EntryMode == 3) return LtfMomentumShort(sh);
   return (HtfBearBreak(sh) || ReclaimShort(sh) || LtfMomentumShort(sh) || PullbackShort(sh));
}

bool ConfirmLong(const int sh)
{
   return (RsiPullbackLong(sh) || MacdMomentumLong(sh) || InsideBarBreakLong(sh) || AsianBreakoutLong(sh));
}

bool ConfirmShort(const int sh)
{
   return (RsiPullbackShort(sh) || MacdMomentumShort(sh) || InsideBarBreakShort(sh) || AsianBreakoutShort(sh));
}

int ScoreLong(const int sh)
{
   int sc = 0;
   if(HtfBullBreak(sh)) sc++;
   if(ReclaimLong(sh)) sc++;
   if(LtfMomentumLong(sh)) sc++;
   if(PullbackLong(sh) && TrendLong(sh)) sc++;
   if(RsiPullbackLong(sh)) sc++;
   if(MacdMomentumLong(sh)) sc++;
   if(InsideBarBreakLong(sh)) sc++;
   if(AsianBreakoutLong(sh)) sc++;
   return sc;
}

int ScoreShort(const int sh)
{
   int sc = 0;
   if(HtfBearBreak(sh)) sc++;
   if(ReclaimShort(sh)) sc++;
   if(LtfMomentumShort(sh)) sc++;
   if(PullbackShort(sh) && TrendShort(sh)) sc++;
   if(RsiPullbackShort(sh)) sc++;
   if(MacdMomentumShort(sh)) sc++;
   if(InsideBarBreakShort(sh)) sc++;
   if(AsianBreakoutShort(sh)) sc++;
   return sc;
}

bool ComboLong(const int sh)
{
   if(ComboMode == 1) return (PrimaryLong(sh) && ConfirmLong(sh));
   if(ComboMode == 2) return (ScoreLong(sh) >= MinComboScore);
   return (PrimaryLong(sh) || ConfirmLong(sh) || LtfMomentumLong(sh));
}

bool ComboShort(const int sh)
{
   if(ComboMode == 1) return (PrimaryShort(sh) && ConfirmShort(sh));
   if(ComboMode == 2) return (ScoreShort(sh) >= MinComboScore);
   return (PrimaryShort(sh) || ConfirmShort(sh) || LtfMomentumShort(sh));
}

bool BuySignal(const int sh)
{
   if(!SessionOk() || !CompressionOk(sh)) return false;
   if(!H1TrendLong(sh) || !AdxOk(sh)) return false;
   int bias = DailyBias(sh);
   if(UseDailyBias && bias < 0) return false;
   return ComboLong(sh);
}

bool SellSignal(const int sh)
{
   if(!SessionOk() || !CompressionOk(sh)) return false;
   if(!H1TrendShort(sh) || !AdxOk(sh)) return false;
   int bias = DailyBias(sh);
   if(UseDailyBias && bias > 0) return false;
   return ComboShort(sh);
}

void ManagePosition(const int sh)
{
   if(!HasOurPosition()) return;
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   int barsHeld = iBarShift(_Symbol, Timeframe, openTime);
   int maxBars = MaxBarsInTrade;
   if(ExtendHoldMomentum && InMomentumWindow()) maxBars = (int)(maxBars * 1.5);

   if(maxBars > 0 && barsHeld >= maxBars)
   {
      CloseOur("max_bars");
      return;
   }

   double atr;
   if(!Copy1(g_atrHandle, sh, 0, atr) || atr <= 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
   {
      double sl = entry - atr * AtrSlMult;
      double tp = entry + atr * AtrTpMult;
      double effSl = sl;
      if(UseTrailing)
      {
         double candidate = bid - atr * TrailAtrMult;
         if(candidate > entry)
         {
            if(g_trail <= 0 || candidate > g_trail) g_trail = candidate;
            effSl = MathMax(sl, g_trail);
         }
      }
      if(bid <= effSl) { CloseOur("sl_trail"); return; }
      if(bid >= tp) { CloseOur("tp"); return; }
   }
   else
   {
      double sl = entry + atr * AtrSlMult;
      double tp = entry - atr * AtrTpMult;
      double effSl = sl;
      if(UseTrailing)
      {
         double candidate = ask + atr * TrailAtrMult;
         if(candidate < entry)
         {
            if(g_trail <= 0 || candidate < g_trail) g_trail = candidate;
            effSl = MathMin(sl, g_trail);
         }
      }
      if(ask >= effSl) { CloseOur("sl_trail"); return; }
      if(ask <= tp) { CloseOur("tp"); return; }
   }
}

int OnInit()
{
   g_fastHandle = iMA(_Symbol, Timeframe, LtfFastEma, 0, MODE_EMA, PRICE_CLOSE);
   g_slowHandle = iMA(_Symbol, Timeframe, LtfSlowEma, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle  = iATR(_Symbol, Timeframe, AtrPeriod);
   g_dailyEma   = iMA(_Symbol, DailyTimeframe, DailyEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle  = iRSI(_Symbol, Timeframe, RsiPeriod, PRICE_CLOSE);
   g_macdHandle = iMACD(_Symbol, Timeframe, MacdFast, MacdSlow, MacdSignal, PRICE_CLOSE);
   g_adxHandle  = iADX(_Symbol, Timeframe, AdxPeriod);
   g_h1EmaHandle = iMA(_Symbol, PERIOD_H1, H1EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE || g_dailyEma == INVALID_HANDLE ||
      g_rsiHandle == INVALID_HANDLE || g_macdHandle == INVALID_HANDLE ||
      g_adxHandle == INVALID_HANDLE || g_h1EmaHandle == INVALID_HANDLE)
      return INIT_FAILED;
   g_trade.SetExpertMagicNumber(MagicNumber);
   Print("[USDCHF Playbook v1.20] combo modules on ", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastHandle != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
   if(g_slowHandle != INVALID_HANDLE) IndicatorRelease(g_slowHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_dailyEma != INVALID_HANDLE) IndicatorRelease(g_dailyEma);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_macdHandle != INVALID_HANDLE) IndicatorRelease(g_macdHandle);
   if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_h1EmaHandle != INVALID_HANDLE) IndicatorRelease(g_h1EmaHandle);
}

void OnTick()
{
   if(!IsNewBar()) return;
   const int sh = 1;
   ManagePosition(sh);
   if(HasOurPosition()) return;
   if(BuySignal(sh)) TryOpen(true);
   else if(SellSignal(sh)) TryOpen(false);
}
