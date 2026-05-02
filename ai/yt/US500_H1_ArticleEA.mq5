//+------------------------------------------------------------------+
//|                                          US500_H1_ArticleEA.mq5 |
//|  ai/yt: article-split ONNX (train 2010–2019 / OOS 2020–2024)     |
//|  Train: python train_article_split.py → models/*.onnx          |
//|  Attach to US500 (or broker equivalent) H1 chart.                |
//+------------------------------------------------------------------+
#property copyright "Profitable EA Project"
#property version   "1.05"
#property description "Embedded US500 H1 article-split ONNX; scaler from US500_H1_article_split_meta.json"

#include <Trade\Trade.mqh>

#resource "models\\US500_H1_article_split.onnx" as uchar ExtModel[]

#define FEAT_COUNT 24
#define PRED_HIST_CAP 32
#define REL_EPS 1e-9

input group "Model"
input int    InpLookback = 48;
input int    InpEntryMode = 1;
input double InpProbBuy = 0.18;
input double InpProbSell = 0.18;
input double InpMinBeatHold = 0.0;
input int    InpExitMode = 1;              // 0=fixed prob; 1/2=close must beat HOLD and stay-in-trade (2 legacy; old 2 vs-HOLD-only removed)
input double InpProbCloseL = 0.18;
input double InpProbCloseS = 0.18;
input double InpMinCloseBeatHold = 0.0;
input int    InpMinBarsInTradeModelExit = 1; // min bars before model exit (0=off); pure mode uses 5-class winner
input bool   InpPureRelative = true;         // true: no prob cutoffs/edges — entry=trio strict winner, exit=5-class strict winner != side
input bool   InpUseCloseHeadExit = true;    // legacy only when InpPureRelative=false (CL/CS vs HOLD/stay; see InpExitMode)
input bool   InpUseDirFlipExit = true;     // legacy only when InpPureRelative=false (gap edges InpFlipExitEdge)
input double InpFlipExitEdge = 0.03;       // legacy dir-flip min gap (ignored when InpPureRelative)
input int    InpMinBarsAfterExit = 6;      // after any close, wait this many flat bars before a new entry (0=off)
input int    InpCooldownBarsAfterAdverse = 12; // extra flat-bar pause after adverse (ATR) stop; 0 = use only MinBarsAfterExit

input group "Decision (aggregate + sample, lowers trade churn)"
input int    InpSampleEveryNBars = 2;     // run ONNX / refresh history every N new bars (>=1)
input int    InpAggWindow = 4;            // rolling mean over last K samples (>=1)
input int    InpMinAggSamples = 2;        // need this many samples in window before new entries
input int    InpMinBarsBetweenEntries = 0; // after an open, wait this many flat bars before next entry (0=off)
input double InpMinDirEdge = 0.03;        // legacy entry mode 1 only (ignored when InpPureRelative)
input bool   InpRequireStayOverClose = true; // legacy entry (ignored when InpPureRelative)

input group "Session (match Python SESSION_HOUR_OFFSET)"
input int    InpSessionHourOffset = 0;

input group "Scaler override (empty = use built-in US500 train split)"
input string InpFeatMinStr = "";
input string InpFeatMaxStr = "";

input group "Risk"
input double InpLotSize = 0.01;
input int    InpMagic = 902503;
input int    InpSlippage = 30;

input group "Hard exits (fixed ATR in price — optional)"
input bool   InpUseAdverseAtrExit = false;  // stop by adverse move in ATR multiples (off = model-only risk)
input bool   InpUseProfitAtrExit = false;   // take-profit in ATR multiples (needs InpTakeProfitATR > 0)
input double InpMaxAdverseATR = 3.5;
input double InpTakeProfitATR = 0.0;

double g_feat_min[FEAT_COUNT];
double g_feat_max[FEAT_COUNT];

CTrade trade;
long g_onnx = INVALID_HANDLE;
datetime g_last_bar = 0;

double g_pred_hist[PRED_HIST_CAP][5];
int    g_pred_hist_len = 0;
double g_smooth[5] = {0.2, 0.2, 0.2, 0.2, 0.2};
ulong  g_bar_index = 0;
int    g_entry_cooldown_bars = 0;
int    g_agg_w = 4;
int    g_sample_n = 2;
int    g_min_agg_samples = 2;

void InitDefaultScalerBounds()
{
   // MinMax bounds from ai/yt/models/US500_H1_article_split_meta.json (train-only scaler)
   double def_min[FEAT_COUNT] = {
      1352.5,
      1352.5999755859375,
      1347.9000244140625,
      1352.0999755859375,
      0.0,
      0.04497450217604637,
      -0.030356179922819138,
      -0.04839427396655083,
      0.00028562467196024954,
      -0.047754231840372086,
      1.0,
      0.00017100000695791095,
      0.0,
      0.01168255414813757,
      0.0760856345295906,
      -0.49618232250213623,
      -1.6348180770874023,
      -1.731970191001892,
      0.000006116794793342706,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0
   };
   double def_max[FEAT_COUNT] = {
      3250.199951171875,
      3251.5,
      3249.5,
      3250.199951171875,
      26050000896.0,
      0.887104868888855,
      0.09538312256336212,
      0.10739167034626007,
      0.02898731827735901,
      0.036042287945747375,
      1.0754634141921997,
      6759499776.0,
      20.0,
      0.9637425541877747,
      0.8267387747764587,
      0.5573697686195374,
      1.2618913650512695,
      1.8784747123718262,
      0.9100509881973267,
      1.0,
      1.0,
      1.0,
      1.0,
      1.0
   };
   for(int i = 0; i < FEAT_COUNT; i++)
   {
      g_feat_min[i] = def_min[i];
      g_feat_max[i] = def_max[i];
   }
}

bool ParseFeatCsv(const string s, double &arr[])
{
   if(StringLen(s) < 3) return false;
   string parts[];
   int n = StringSplit(s, ',', parts);
   if(n != FEAT_COUNT) return false;
   for(int i = 0; i < FEAT_COUNT; i++)
      arr[i] = StringToDouble(parts[i]);
   return true;
}

int OnInit()
{
   InitDefaultScalerBounds();
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   if(StringLen(InpFeatMinStr) > 0 && ParseFeatCsv(InpFeatMinStr, g_feat_min))
      Print("US500 Article EA: loaded InpFeatMinStr (24)");
   if(StringLen(InpFeatMaxStr) > 0 && ParseFeatCsv(InpFeatMaxStr, g_feat_max))
      Print("US500 Article EA: loaded InpFeatMaxStr (24)");

   g_onnx = OnnxCreateFromBuffer(ExtModel, ONNX_DEBUG_LOGS);
   if(g_onnx == INVALID_HANDLE)
   {
      Print("OnnxCreateFromBuffer failed ", GetLastError());
      return INIT_FAILED;
   }

   const long inShape[] = {1, InpLookback, FEAT_COUNT};
   if(!OnnxSetInputShape(g_onnx, 0, inShape))
   {
      Print("OnnxSetInputShape failed ", GetLastError());
      OnnxRelease(g_onnx);
      return INIT_FAILED;
   }
   const long outShape[] = {1, 5};
   if(!OnnxSetOutputShape(g_onnx, 0, outShape))
   {
      Print("OnnxSetOutputShape failed ", GetLastError());
      OnnxRelease(g_onnx);
      return INIT_FAILED;
   }

   g_agg_w = MathMax(1, MathMin(InpAggWindow, PRED_HIST_CAP));
   g_sample_n = MathMax(1, InpSampleEveryNBars);
   g_min_agg_samples = MathMax(1, MathMin(InpMinAggSamples, g_agg_w));
   g_pred_hist_len = 0;
   g_bar_index = 0;
   g_entry_cooldown_bars = 0;
   for(int k = 0; k < 5; k++)
      g_smooth[k] = 0.2;

   const bool has_atr = InpUseAdverseAtrExit || (InpUseProfitAtrExit && InpTakeProfitATR > 0.0);
   const bool has_model_exit = InpPureRelative || InpUseCloseHeadExit || InpUseDirFlipExit;
   if(!has_atr && !has_model_exit)
      Print("US500_H1_ArticleEA: WARNING — no exit path enabled (enable InpPureRelative and/or legacy exits / ATR)");

   Print("US500_H1_ArticleEA: ONNX OK. Chart TF=", EnumToString(PERIOD_CURRENT), "; Lookback=", InpLookback,
         " sampleEvery=", g_sample_n, " aggWindow=", g_agg_w, " minAggSamples=", g_min_agg_samples,
         " pureRelative=", InpPureRelative,
         " entryCooldownBars=", InpMinBarsBetweenEntries, " minDirEdge=", InpMinDirEdge,
         " stayOverClose=", InpRequireStayOverClose,
         " exitMode=", InpExitMode, " minBarsInTradeModelExit=", InpMinBarsInTradeModelExit,
         " closeHeadExit=", InpUseCloseHeadExit, " dirFlipExit=", InpUseDirFlipExit, " flipExitEdge=", InpFlipExitEdge,
         " minBarsAfterExit=", InpMinBarsAfterExit, " cooldownAfterAdverse=", InpCooldownBarsAfterAdverse,
         " useAdverseATR=", InpUseAdverseAtrExit, " useProfitATR=", InpUseProfitAtrExit,
         " maxAdverseATR=", InpMaxAdverseATR, " takeProfitATR=", InpTakeProfitATR);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(g_onnx != INVALID_HANDLE) OnnxRelease(g_onnx);
}

double AtrNow()
{
   double b[];
   ArraySetAsSeries(b, true);
   int h = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(h == INVALID_HANDLE) return 0;
   if(CopyBuffer(h, 0, 0, 2, b) < 1) { IndicatorRelease(h); return 0; }
   double v = b[0];
   IndicatorRelease(h);
   return v;
}

bool AdverseExit(const long type, const double open_price)
{
   if(!InpUseAdverseAtrExit || InpMaxAdverseATR <= 0.0)
      return false;
   double atr = AtrNow();
   if(atr <= 0) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(type == POSITION_TYPE_BUY)
   {
      double adv = (open_price - bid) / atr;
      return adv >= InpMaxAdverseATR;
   }
   double adv = (ask - open_price) / atr;
   return adv >= InpMaxAdverseATR;
}

bool ProfitExit(const long type, const double open_price)
{
   if(!InpUseProfitAtrExit || InpTakeProfitATR <= 0.0)
      return false;
   double atr = AtrNow();
   if(atr <= 0.0) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(type == POSITION_TYPE_BUY)
      return (bid - open_price) >= InpTakeProfitATR * atr;
   return (open_price - ask) >= InpTakeProfitATR * atr;
}

bool ModelCloseLong(const double p0, const double p1, const double p3)
{
   if(InpExitMode == 0)
      return (p3 >= InpProbCloseL);
   // Modes 1/2 (and default): close-long must beat HOLD and stay-long (BUY). Old mode-2 "vs HOLD only" fired almost every bar on softmax.
   return (p3 > p0 + InpMinCloseBeatHold && p3 > p1);
}

bool ModelCloseShort(const double p0, const double p2, const double p4)
{
   if(InpExitMode == 0)
      return (p4 >= InpProbCloseS);
   return (p4 > p0 + InpMinCloseBeatHold && p4 > p2);
}

bool ModelDirFlipExitLong(const double p0, const double p1, const double p2)
{
   if(!InpUseDirFlipExit)
      return false;
   const double e = MathMax(0.0, InpFlipExitEdge);
   return (p2 > p1 + e && p2 > p0 + InpMinBeatHold);
}

bool ModelDirFlipExitShort(const double p0, const double p1, const double p2)
{
   if(!InpUseDirFlipExit)
      return false;
   const double e = MathMax(0.0, InpFlipExitEdge);
   return (p1 > p2 + e && p1 > p0 + InpMinBeatHold);
}

int TrioStrictWinner012(const double p0, const double p1, const double p2)
{
   if(p0 > p1 + REL_EPS && p0 > p2 + REL_EPS)
      return 0;
   if(p1 > p0 + REL_EPS && p1 > p2 + REL_EPS)
      return 1;
   if(p2 > p0 + REL_EPS && p2 > p1 + REL_EPS)
      return 2;
   return -1;
}

int FiveStrictWinner01234(const double p0, const double p1, const double p2, const double p3, const double p4)
{
   const double p[5] = {p0, p1, p2, p3, p4};
   int best = 0;
   for(int k = 1; k < 5; k++)
      if(p[k] > p[best])
         best = k;
   const double m = p[best];
   int cnt = 0;
   for(int k = 0; k < 5; k++)
      if(p[k] + REL_EPS >= m)
         cnt++;
   if(cnt != 1)
      return -1;
   return best;
}

int PositionBarsInTrade()
{
   if(!PositionSelect(_Symbol))
      return 0;
   const datetime tOpen = (datetime)PositionGetInteger(POSITION_TIME);
   const int sh = iBarShift(_Symbol, PERIOD_CURRENT, tOpen, false);
   if(sh < 0)
      return 9999;
   return sh + 1;
}

void ApplyExitCooldown(const bool adverse_stop)
{
   int b = MathMax(0, InpMinBarsAfterExit);
   if(adverse_stop)
      b = MathMax(b, MathMax(0, InpCooldownBarsAfterAdverse));
   if(b > 0)
      g_entry_cooldown_bars = MathMax(g_entry_cooldown_bars, b);
}

void PushPrediction(const double p0, const double p1, const double p2, const double p3, const double p4, const int maxKeep)
{
   for(int i = PRED_HIST_CAP - 1; i > 0; i--)
      for(int k = 0; k < 5; k++)
         g_pred_hist[i][k] = g_pred_hist[i - 1][k];
   g_pred_hist[0][0] = p0;
   g_pred_hist[0][1] = p1;
   g_pred_hist[0][2] = p2;
   g_pred_hist[0][3] = p3;
   g_pred_hist[0][4] = p4;
   int cap = MathMax(1, MathMin(maxKeep, PRED_HIST_CAP));
   g_pred_hist_len = MathMin(g_pred_hist_len + 1, cap);
}

void RecomputeSmooth(const int aggWindow)
{
   int w = MathMax(1, MathMin(aggWindow, PRED_HIST_CAP));
   int n = MathMin(w, g_pred_hist_len);
   if(n < 1)
      return;
   for(int k = 0; k < 5; k++)
   {
      double s = 0.0;
      for(int i = 0; i < n; i++)
         s += g_pred_hist[i][k];
      g_smooth[k] = s / (double)n;
   }
}

void ScaleFeatures(const float &raw[], float &out[])
{
   for(int f = 0; f < FEAT_COUNT; f++)
   {
      double den = g_feat_max[f] - g_feat_min[f];
      if(den < 1e-12) den = 1e-12;
      double x = (double)raw[f] - g_feat_min[f];
      out[f] = (float)MathMax(0.0, MathMin(1.0, x / den));
   }
}

bool PrepareMatrix(matrixf &M)
{
   int L = InpLookback;
   double open[], high[], low[], close[];
   long vol[];
   datetime bt[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(vol, true);
   ArraySetAsSeries(bt, true);

   int need = L + 55;
   if(CopyOpen(_Symbol, PERIOD_CURRENT, 0, need, open) < L) return false;
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, need, high) < L) return false;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, need, low) < L) return false;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, need, close) < L) return false;
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, need, vol) < L) return false;
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, need, bt) < L) return false;

   double rsi7[], rsi14[], rsi21[], ema20[], ema50[], atr[];
   ArraySetAsSeries(rsi7, true);
   ArraySetAsSeries(rsi14, true);
   ArraySetAsSeries(rsi21, true);
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   ArraySetAsSeries(atr, true);

   int h7 = iRSI(_Symbol, PERIOD_CURRENT, 7, PRICE_CLOSE);
   int h14 = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
   int h21 = iRSI(_Symbol, PERIOD_CURRENT, 21, PRICE_CLOSE);
   int hE20 = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
   int hE50 = iMA(_Symbol, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE);
   int hA = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(h7 == INVALID_HANDLE || h14 == INVALID_HANDLE || h21 == INVALID_HANDLE ||
      hE20 == INVALID_HANDLE || hE50 == INVALID_HANDLE || hA == INVALID_HANDLE)
      return false;

   if(CopyBuffer(h7, 0, 0, need, rsi7) < L ||
      CopyBuffer(h14, 0, 0, need, rsi14) < L ||
      CopyBuffer(h21, 0, 0, need, rsi21) < L ||
      CopyBuffer(hE20, 0, 0, need, ema20) < L ||
      CopyBuffer(hE50, 0, 0, need, ema50) < L ||
      CopyBuffer(hA, 0, 0, need, atr) < L)
   {
      IndicatorRelease(h7); IndicatorRelease(h14); IndicatorRelease(h21);
      IndicatorRelease(hE20); IndicatorRelease(hE50); IndicatorRelease(hA);
      return false;
   }
   IndicatorRelease(h7); IndicatorRelease(h14); IndicatorRelease(h21);
   IndicatorRelease(hE20); IndicatorRelease(hE50); IndicatorRelease(hA);

   M.Resize(L, FEAT_COUNT);
   const double RSI_OB = 70.0;
   const double RSI_OS = 30.0;

   for(int i = 0; i < L; i++)
   {
      double vma = 0;
      int cnt = 0;
      for(int k = i; k < i + 20 && k < ArraySize(vol); k++) { vma += (double)vol[k]; cnt++; }
      if(cnt < 1) cnt = 1;
      vma /= cnt;

      double r0 = rsi14[i];
      double r1 = (i + 1 < ArraySize(rsi14)) ? rsi14[i + 1] : r0;
      double r2 = (i + 2 < ArraySize(rsi14)) ? rsi14[i + 2] : r1;
      double rv7 = rsi7[i];
      double rv21 = rsi21[i];

      double spread = (r0 - rv7) / 50.0;
      if(spread > 1.0) spread = 1.0;
      if(spread < -1.0) spread = -1.0;
      double vel = (r0 - r1) / 25.0;
      double acc = ((r0 - r1) - (r1 - r2)) / 25.0;
      double dist_mid = MathAbs(r0 - 50.0) / 50.0;
      double c_ob = (r1 < RSI_OB && r0 >= RSI_OB) ? 1.0 : 0.0;
      double c_os = (r1 > RSI_OS && r0 <= RSI_OS) ? 1.0 : 0.0;
      double c50u = (r1 < 50.0 && r0 >= 50.0) ? 1.0 : 0.0;
      double c50d = (r1 > 50.0 && r0 <= 50.0) ? 1.0 : 0.0;

      MqlDateTime st;
      TimeToStruct(bt[i], st);
      int hr = (st.hour + InpSessionHourOffset) % 24;
      if(hr < 0) hr += 24;
      double asian = (hr >= 0 && hr < 8) ? 1.0 : 0.0;

      float raw[FEAT_COUNT];
      raw[0] = (float)open[i];
      raw[1] = (float)high[i];
      raw[2] = (float)low[i];
      raw[3] = (float)close[i];
      raw[4] = (float)((double)vol[i] / 1000000.0);
      raw[5] = (float)(r0 / 100.0);
      raw[6] = (float)((ema20[i] - close[i]) / close[i]);
      raw[7] = (float)((ema50[i] - close[i]) / close[i]);
      raw[8] = (float)(atr[i] / close[i]);
      double pc = (i < L - 1) ? (close[i] - close[i + 1]) / close[i + 1] : 0.0;
      raw[9] = (float)pc;
      raw[10] = (float)(high[i] / low[i]);
      raw[11] = (float)(vma / 1000000.0);
      raw[12] = (float)(vma > 0 ? (double)vol[i] / vma : 1.0);
      raw[13] = (float)(rv7 / 100.0);
      raw[14] = (float)(rv21 / 100.0);
      raw[15] = (float)spread;
      raw[16] = (float)vel;
      raw[17] = (float)acc;
      raw[18] = (float)dist_mid;
      raw[19] = (float)c_ob;
      raw[20] = (float)c_os;
      raw[21] = (float)c50u;
      raw[22] = (float)c50d;
      raw[23] = (float)asian;

      float sc[FEAT_COUNT];
      ScaleFeatures(raw, sc);
      for(int j = 0; j < FEAT_COUNT; j++)
         M[i][j] = sc[j];
   }
   return true;
}

void OnTick()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == g_last_bar) return;
   g_last_bar = t;

   const bool had_pos = PositionSelect(_Symbol);
   const bool flat = !had_pos;
   if(flat && g_entry_cooldown_bars > 0)
      g_entry_cooldown_bars--;

   g_bar_index++;
   const bool do_sample = (g_sample_n < 2) || ((g_bar_index % (ulong)g_sample_n) == 0);
   bool fresh_predict = false;

   if(do_sample)
   {
      matrixf Min;
      if(!PrepareMatrix(Min))
      {
         Print("US500 Article EA: PrepareMatrix failed");
         if(!had_pos)
            return;
      }
      else
      {
         vectorf out;
         out.Resize(5);
         if(!OnnxRun(g_onnx, ONNX_NO_CONVERSION, Min, out))
         {
            Print("OnnxRun failed ", GetLastError());
            if(!had_pos)
               return;
         }
         else
         {
            PushPrediction(out[0], out[1], out[2], out[3], out[4], g_agg_w);
            RecomputeSmooth(g_agg_w);
            fresh_predict = true;
            Print("US500 Article H1 raw HOLD=", out[0], " BUY=", out[1], " SELL=", out[2], " CL=", out[3], " CS=", out[4],
                  " | smooth HOLD=", g_smooth[0], " BUY=", g_smooth[1], " SELL=", g_smooth[2], " CL=", g_smooth[3], " CS=", g_smooth[4]);
         }
      }
   }

   const double p0 = g_smooth[0];
   const double p1 = g_smooth[1];
   const double p2 = g_smooth[2];
   const double p3 = g_smooth[3];
   const double p4 = g_smooth[4];

   if(flat)
   {
      if(!do_sample || !fresh_predict)
         return;
      if(g_pred_hist_len < g_min_agg_samples)
         return;
      if(g_entry_cooldown_bars > 0)
         return;

      if(InpEntryMode == 1)
      {
         if(InpPureRelative)
         {
            const int w3 = TrioStrictWinner012(p0, p1, p2);
            if(w3 == 1)
            {
               if(trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "US500 article BUY"))
                  g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
            }
            else if(w3 == 2)
            {
               if(trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "US500 article SELL"))
                  g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
            }
         }
         else
         {
            double dir = MathMax(p1, p2);
            if(dir <= p0 + InpMinBeatHold)
               return;
            const double edge = MathMax(0.0, InpMinDirEdge);
            const bool stay_ok_buy = (!InpRequireStayOverClose) || (p1 > p3);
            const bool stay_ok_sell = (!InpRequireStayOverClose) || (p2 > p4);
            if(p1 >= p2 && p1 > p0 + InpMinBeatHold && (p1 - p2) >= edge && stay_ok_buy)
            {
               if(trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "US500 article BUY"))
                  g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
            }
            else if(p2 > p1 && p2 > p0 + InpMinBeatHold && (p2 - p1) >= edge && stay_ok_sell)
            {
               if(trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "US500 article SELL"))
                  g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
            }
         }
      }
      else
      {
         if(p1 >= InpProbBuy && p1 >= p2)
         {
            if(trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "US500 article BUY"))
               g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
         }
         else if(p2 >= InpProbSell && p2 > p1)
         {
            if(trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "US500 article SELL"))
               g_entry_cooldown_bars = MathMax(0, InpMinBarsBetweenEntries);
         }
      }
      return;
   }

   long typ = (long)PositionGetInteger(POSITION_TYPE);
   double opn = PositionGetDouble(POSITION_PRICE_OPEN);
   if(AdverseExit(typ, opn))
   {
      if(trade.PositionClose(_Symbol))
         ApplyExitCooldown(true);
      return;
   }
   if(ProfitExit(typ, opn))
   {
      if(trade.PositionClose(_Symbol))
         ApplyExitCooldown(false);
      return;
   }

   const int bars_in = PositionBarsInTrade();
   const bool allow_model_exit = (InpMinBarsInTradeModelExit <= 0) || (bars_in >= InpMinBarsInTradeModelExit);
   if(allow_model_exit)
   {
      bool want_close = false;
      if(InpPureRelative)
      {
         const int w5 = FiveStrictWinner01234(p0, p1, p2, p3, p4);
         if(typ == POSITION_TYPE_BUY)
            want_close = (w5 != -1 && w5 != 1);
         else
            want_close = (w5 != -1 && w5 != 2);
      }
      else
      {
         if(typ == POSITION_TYPE_BUY)
         {
            const bool head = InpUseCloseHeadExit && ModelCloseLong(p0, p1, p3);
            const bool flip = ModelDirFlipExitLong(p0, p1, p2);
            want_close = (head || flip);
         }
         else
         {
            const bool head = InpUseCloseHeadExit && ModelCloseShort(p0, p2, p4);
            const bool flip = ModelDirFlipExitShort(p0, p1, p2);
            want_close = (head || flip);
         }
      }
      if(want_close)
      {
         if(trade.PositionClose(_Symbol))
            ApplyExitCooldown(false);
      }
   }
}
