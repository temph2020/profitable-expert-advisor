//+------------------------------------------------------------------+
//|                                          EURUSD_H1_ActionEA.mq5 |
//|  ai/eurusd1h/main.py — 24 features, 5-class softmax             |
//|  Classes: 0=HOLD 1=BUY 2=SELL_SHORT 3=CLOSE_LONG 4=CLOSE_SHORT   |
//|  Entry: strict trio winner among p0,p1,p2 only.                  |
//|  Exit: unique 5-class argmax != held side (1 long, 2 short).     |
//|  No SL / TP / ATR stops. Attach EURUSD H1.                        |
//+------------------------------------------------------------------+
#property copyright "Profitable EA Project"
#property version   "1.00"
#property description "EURUSD H1 action ONNX; ordinal entry/exit; no fixed SL/TP"

#include <Trade\Trade.mqh>

#resource "models\\EURUSD_H1_action.onnx" as uchar ExtModel[]

#define FEAT_COUNT 24
#define REL_EPS 1e-9

input group "Model"
input int    InpLookback = 48;
input int    InpSessionHourOffset = 0;
input string InpFeatMinStr = "";
input string InpFeatMaxStr = "";

input group "Timing"
input int    InpMinBarsInTrade = 1;   // model exit only after this many bars in position (0=off)

input group "Trade"
input double InpLotSize = 0.01;
input int    InpMagic = 902601;
input int    InpSlippage = 30;

double g_feat_min[FEAT_COUNT];
double g_feat_max[FEAT_COUNT];

CTrade trade;
long   g_onnx = INVALID_HANDLE;
datetime g_last_bar = 0;

void InitDefaultScalerFromMeta()
{
   // EURUSD_H1_action_meta.json scaler_feature_min / max (train fit)
   double def_min[FEAT_COUNT] = {
      0.9539399743080139,
      0.9559400081634521,
      0.9536200165748596,
      0.9538999795913696,
      9.999999974752427e-07,
      0.07019035518169403,
      -0.02143237181007862,
      -0.028110405430197716,
      0.0002704667276702821,
      -0.02017582766711712,
      1.0,
      0.0004555500054266304,
      0.0002461568801663816,
      0.022001149132847786,
      0.11231997609138489,
      -0.5339273810386658,
      -1.623793125152588,
      -1.837566614151001,
      6.83732741890708e-06,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0
   };
   double def_max[FEAT_COUNT] = {
      1.493149995803833,
      1.4938499927520752,
      1.4904999732971191,
      1.493190050125122,
      0.06699500232934952,
      0.9350273013114929,
      0.028008731082081795,
      0.03147505968809128,
      0.009249407798051834,
      0.01742853783071041,
      1.0232577323913574,
      0.02111775055527687,
      7.801275253295898,
      0.9864169955253601,
      0.8837512731552124,
      0.49708572030067444,
      1.8055412769317627,
      1.927569031715393,
      0.8700546026229858,
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
   if(StringSplit(s, ',', parts) != FEAT_COUNT) return false;
   for(int i = 0; i < FEAT_COUNT; i++)
      arr[i] = StringToDouble(parts[i]);
   return true;
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

      double spr = (r0 - rv7) / 50.0;
      if(spr > 1.0) spr = 1.0;
      if(spr < -1.0) spr = -1.0;
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
      raw[15] = (float)spr;
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

int TrioStrictWinner012(const double p0, const double p1, const double p2)
{
   if(p0 > p1 + REL_EPS && p0 > p2 + REL_EPS) return 0;
   if(p1 > p0 + REL_EPS && p1 > p2 + REL_EPS) return 1;
   if(p2 > p0 + REL_EPS && p2 > p1 + REL_EPS) return 2;
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

bool SelectOurPosition()
{
   if(!PositionSelect(_Symbol))
      return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   return true;
}

int PositionBarsInTrade()
{
   if(!SelectOurPosition())
      return 0;
   const datetime tOpen = (datetime)PositionGetInteger(POSITION_TIME);
   const int sh = iBarShift(_Symbol, PERIOD_CURRENT, tOpen, false);
   if(sh < 0)
      return 9999;
   return sh + 1;
}

int OnInit()
{
   InitDefaultScalerFromMeta();
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   if(StringLen(InpFeatMinStr) > 0 && ParseFeatCsv(InpFeatMinStr, g_feat_min))
      Print("EURUSD Action EA: loaded InpFeatMinStr");
   if(StringLen(InpFeatMaxStr) > 0 && ParseFeatCsv(InpFeatMaxStr, g_feat_max))
      Print("EURUSD Action EA: loaded InpFeatMaxStr");

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

   if(_Period != PERIOD_H1)
      Print("EURUSD_H1_ActionEA: chart period is ", EnumToString((ENUM_TIMEFRAMES)_Period),
            " — training is H1; mismatch may hurt.");

   Print("EURUSD_H1_ActionEA: ONNX OK. Ordinal entry/exit, no SL/TP. Lookback=", InpLookback);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   if(g_onnx != INVALID_HANDLE)
      OnnxRelease(g_onnx);
}

void OnTick()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == g_last_bar)
      return;
   g_last_bar = t;

   matrixf Min;
   if(!PrepareMatrix(Min))
   {
      Print("EURUSD Action EA: PrepareMatrix failed");
      return;
   }
   vectorf out;
   out.Resize(5);
   if(!OnnxRun(g_onnx, ONNX_NO_CONVERSION, Min, out))
   {
      Print("OnnxRun failed ", GetLastError());
      return;
   }

   const double p0 = out[0], p1 = out[1], p2 = out[2], p3 = out[3], p4 = out[4];

   if(!SelectOurPosition())
   {
      const int w3 = TrioStrictWinner012(p0, p1, p2);
      if(w3 == 1)
         trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "EURUSD act BUY");
      else if(w3 == 2)
         trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "EURUSD act SELL");
      return;
   }

   const bool allow = (InpMinBarsInTrade <= 0) || (PositionBarsInTrade() >= InpMinBarsInTrade);
   if(!allow)
      return;

   const int w5 = FiveStrictWinner01234(p0, p1, p2, p3, p4);
   const long typ = (long)PositionGetInteger(POSITION_TYPE);
   bool close_it = false;
   if(typ == POSITION_TYPE_BUY)
      close_it = (w5 != -1 && w5 != 1);
   else if(typ == POSITION_TYPE_SELL)
      close_it = (w5 != -1 && w5 != 2);

   if(close_it)
      trade.PositionClose(_Symbol);
}
