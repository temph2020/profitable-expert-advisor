//+------------------------------------------------------------------+
//|                                       XAUUSD_H1_ActionEA.mq5   |
//|  ONNX softmax [5]: HOLD, BUY, SELL_SHORT, CLOSE_LONG, CLOSE_SHORT |
//|  24 features: base 13 + RSI/frontline (see ../xauusd_m15 doc)    |
//|  Train: ai/xauusd_h1/main.py → XAUUSD_H1_action.onnx             |
//|  Exits: model CLOSE_* + optional InpTakeProfitATR; adverse ATR   |
//+------------------------------------------------------------------+
#property copyright "Profitable EA Project"
#property version   "1.00"

#include <Trade\Trade.mqh>

#resource "XAUUSD_H1_action.onnx" as uchar ExtModel[]

#define FEAT_COUNT 24

input group "Model"
input int    InpLookback = 48;
// 0 = legacy: p(BUY)>=InpProbBuy etc.; 1 = directional beats HOLD (5-class softmax)
input int    InpEntryMode = 1;
input double InpProbBuy = 0.18;
input double InpProbSell = 0.18;
input double InpMinBeatHold = 0.0;
input int    InpExitMode = 2;
input double InpProbCloseL = 0.18;
input double InpProbCloseS = 0.18;
input double InpMinCloseBeatHold = 0.0;

input group "Session (match Python SESSION_HOUR_OFFSET)"
input int    InpSessionHourOffset = 0;

input group "Scaler: paste 24 floats each from python main.py"
input string InpFeatMinStr = "";
input string InpFeatMaxStr = "";

input group "Risk"
input double InpLotSize = 0.01;
input int    InpMagic = 902016;
input int    InpSlippage = 30;
input double InpMaxAdverseATR = 2.0;
input double InpTakeProfitATR = 0.0;

double g_feat_min[FEAT_COUNT];
double g_feat_max[FEAT_COUNT];

CTrade trade;
long g_onnx = INVALID_HANDLE;
datetime g_last_bar = 0;

void InitDefaultScalerBounds()
{
   double def_min[FEAT_COUNT] = {
      0,0,0,0,0,0,-0.05,-0.05,0,-0.02,1.0,0,0.1,
      0,0,-1,-0.2,-0.2,0,0,0,0,0,0
   };
   double def_max[FEAT_COUNT] = {
      5000,5000,5000,5000,1,1,0.05,0.05,0.05,0.02,1.02,1,5.0,
      1,1,1,0.2,0.2,1,1,1,1,1,1
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
      Print("Loaded InpFeatMinStr (24)");
   if(StringLen(InpFeatMaxStr) > 0 && ParseFeatCsv(InpFeatMaxStr, g_feat_max))
      Print("Loaded InpFeatMaxStr (24)");

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
   if(InpTakeProfitATR <= 0.0) return false;
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
   if(InpExitMode == 1)
      return (p3 > p0 + InpMinCloseBeatHold && p3 > p1);
   return (p3 > p0 + InpMinCloseBeatHold);
}

bool ModelCloseShort(const double p0, const double p2, const double p4)
{
   if(InpExitMode == 0)
      return (p4 >= InpProbCloseS);
   if(InpExitMode == 1)
      return (p4 > p0 + InpMinCloseBeatHold && p4 > p2);
   return (p4 > p0 + InpMinCloseBeatHold);
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

   matrixf Min;
   if(!PrepareMatrix(Min))
   {
      Print("PrepareMatrix failed");
      return;
   }

   vectorf out;
   out.Resize(5);
   if(!OnnxRun(g_onnx, ONNX_NO_CONVERSION, Min, out))
   {
      Print("OnnxRun failed ", GetLastError());
      return;
   }

   double p0 = out[0], p1 = out[1], p2 = out[2], p3 = out[3], p4 = out[4];
   Print("ONNX H1 HOLD=", p0, " BUY=", p1, " SELL=", p2, " CL=", p3, " CS=", p4);

   if(!PositionSelect(_Symbol))
   {
      if(InpEntryMode == 1)
      {
         double dir = MathMax(p1, p2);
         if(dir <= p0 + InpMinBeatHold)
            return;
         if(p1 >= p2 && p1 > p0 + InpMinBeatHold)
            trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "AI H1 BUY");
         else if(p2 > p1 && p2 > p0 + InpMinBeatHold)
            trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "AI H1 SELL");
      }
      else
      {
         if(p1 >= InpProbBuy && p1 >= p2)
            trade.Buy(InpLotSize, _Symbol, 0, 0, 0, "AI H1 BUY");
         else if(p2 >= InpProbSell && p2 > p1)
            trade.Sell(InpLotSize, _Symbol, 0, 0, 0, "AI H1 SELL");
      }
      return;
   }

   long typ = (long)PositionGetInteger(POSITION_TYPE);
   double opn = PositionGetDouble(POSITION_PRICE_OPEN);
   if(AdverseExit(typ, opn))
   {
      trade.PositionClose(_Symbol);
      return;
   }
   if(ProfitExit(typ, opn))
   {
      trade.PositionClose(_Symbol);
      return;
   }
   if(typ == POSITION_TYPE_BUY && ModelCloseLong(p0, p1, p3))
      trade.PositionClose(_Symbol);
   else if(typ == POSITION_TYPE_SELL && ModelCloseShort(p0, p2, p4))
      trade.PositionClose(_Symbol);
}
