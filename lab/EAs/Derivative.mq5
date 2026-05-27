//+------------------------------------------------------------------+

//|                                                   Derivative.mq5 |

//|  EA: finite-difference d1–d3 of price + optional demo signals    |

//|  (Former indicator — attach as Expert Advisor on chart.)          |

//+------------------------------------------------------------------+

#property copyright "Lab"

#property link      ""

#property version   "3.00"

#property strict

#include <Trade/Trade.mqh>

#include <Canvas/Canvas.mqh>

#property description "DERIVATIVE_CALC EA v3 — derivatives + optional trades; canvas strip or legacy DerivativePlots."

#property description "Canvas mode draws d1/d2/d3 at bottom without indicators; legacy mode optional."

enum ENUM_DERIVATIVE_VIEW

{

   DERIVATIVE_ALL     = 0,

   DERIVATIVE_LEVEL_1 = 1,

   DERIVATIVE_LEVEL_2 = 2,

   DERIVATIVE_LEVEL_3 = 3

};

input group "=== Instrument ==="

input string               InpSymbol            = "";                  // blank = chart symbol

input group "=== Series ==="

input ENUM_TIMEFRAMES      InpSignalTF          = PERIOD_CURRENT;      // PERIOD_CURRENT = chart TF

input ENUM_APPLIED_PRICE   InpAppliedPrice      = PRICE_CLOSE;

input group "=== Layout (reporting focus) ==="

input ENUM_DERIVATIVE_VIEW InpWhichDerivative   = DERIVATIVE_ALL;    // Which values drive Comment / optional trade filter

input group "=== Calculus discretization ==="

input int                  InpDiffStep          = 1;

input bool                 InpNormalizePoints    = true;

input group "=== Smoothing ==="

input int                  InpSmoothPeriod       = 0;

input group "=== On-chart guide (labels on main window) ==="

input bool                 InpShowHelpPanel      = true;

input color                InpHelpTitleColor     = clrWhite;

input color                InpHelpBodyColor      = clrSilver;

input group "=== Display ==="

input bool                 InpShowComment        = true;               // Status line + d1/d2/d3 on chart

input int                  InpCommentThrottleMs  = 200;                // Min real-time ms between Comment() calls (0=off). Visual tester floods redraws without this.

input bool                 InpDebugTrace          = false;              // Experts/Journal: derivatives + attach diagnostics

input group "=== Canvas strip (EA draws d1/d2/d3 — no indicator .ex5) ==="

input bool                 InpUseCanvasPlots      = true;               // Three stacked strips at bottom (bitmap on main window)

input int                  InpCanvasPlotBars      = 320;                // Bars across width (series 0 = current)

input int                  InpCanvasPanelHeight   = 210;                // Total pixel height for three strips

input int                  InpCanvasBottomMargin  = 28;                 // From chart bottom (CORNER_LEFT_LOWER)

input int                  InpCanvasSideMargin    = 4;                  // Left/right inset

input int                  InpCanvasRedrawMs      = 350;                // Min ms between canvas rebuilds

input color                InpCanvasBgColor       = clrBlack;

input color                InpCanvasGridColor     = clrDimGray;

input group "=== Legacy: DerivativePlots indicator (optional) ==="

input bool                 InpAutoAttachDerivativePlots = false;      // Requires DerivativePlots.ex5 in Indicators

input bool                 InpAttachPlotsInTester      = false;      // Non-visual tester: set true if .ex5 present

input string               InpPlotsIndicatorPath      = "DerivativePlots"; // .ex5 basename in Indicators folder

input bool                 InpPlotsSeparateWindows    = false;      // Three iCustom instances + stacked subwindows

input bool                 InpPlotsUnifyYScale       = true;       // DerivativePlots InpUnifyPlotYScale

input group "=== Optional demo trading (off by default) ==="

input bool                 InpTradeEnabled       = false;

input double               InpLots               = 0.01;

input ulong                InpMagic               = 931001;

input int                  InpSlippagePoints     = 30;

input int                  InpAtrPeriod          = 14;

input double               InpSlAtrMult          = 2.0;

input double               InpTpAtrMult          = 3.0;

CTrade g_trade;

datetime g_lastBarTime = 0;

string   g_chartSymbol   = "";

bool     g_pendingDerivativePlotsAttach = false;

bool     g_derivativePlotsFailedToLoad   = false;

bool     g_derivPlotsAttachDone          = false;

uint     g_lastCommentWallMs             = 0;

CCanvas  g_deriv_canvas;

bool     g_deriv_canvas_created          = false;

uint     g_lastCanvasRedrawMs            = 0;

const string HELPER_FAMILY    = "DerivRead";

const string DERIV_CANVAS_OBJ = "DerivEA_CanvasStrip_v3";

void CommentThrottled(const string text)

{

   if(InpCommentThrottleMs <= 0)

   {

      Comment(text);

      return;

   }

   const uint now = GetTickCount();

   if(g_lastCommentWallMs != 0 && (now - g_lastCommentWallMs) < (uint)InpCommentThrottleMs)

      return;

   g_lastCommentWallMs = now;

   Comment(text);

}

string DerivativePlotsMissingHint()

{

   if(!g_derivativePlotsFailedToLoad || !InpAutoAttachDerivativePlots)

      return "";

   const string want = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Indicators\\" + InpPlotsIndicatorPath + ".ex5";

   return "\n--- DerivativePlots NOT loaded ---\nPlace compiled file:\n" + want +

          "\n(Navigator: Indicators -> right-click -> Open folder -> paste .mq5, Compile.)";

}

string HelpPrefix()

{

   return HELPER_FAMILY + "_EA_L" + IntegerToString((int)InpWhichDerivative) + "_";

}

void DeleteOurHelpObjects()

{

   const string px = HelpPrefix();

   ObjectDelete(0, px + "title");

   ObjectDelete(0, px + "body");

   ObjectDelete(0, px + "interp");

}

bool LabelCreateMain(const string name, const int corner, const int xd, const int yd,

                     const string text, const color clr, const int fontSize, const int anchor)

{

   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))

      return false;

   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);

   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xd);

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yd);

   ObjectSetString(0, name, OBJPROP_TEXT, text);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);

   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);

   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");

   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   return true;

}

void TryBuildHelpPanel()

{

   if(!InpShowHelpPanel)

   {

      DeleteOurHelpObjects();

      return;

   }

   const string px = HelpPrefix();

   ObjectDelete(0, px + "title");

   ObjectDelete(0, px + "body");

   ObjectDelete(0, px + "interp");

   const int x0 = 8;

   string title = "DERIVATIVE_CALC EA — readout\n";

   string body = "";

   string interp = "";

   if(InpWhichDerivative == DERIVATIVE_ALL)

   {

      body =

      "d1 = slope of price / step h  (velocity)\n"

      "d2 = change of d1 (acceleration)\n"

      "d3 = change of d2 (jerk)\n"

      "See Experts log + Comment line for numbers.";

      interp = "Optional demo trades use Which derivative + sign rules (inputs).";

   }

   else if(InpWhichDerivative == DERIVATIVE_LEVEL_1)

   {

      title = "EA focus: d1 only\n";

      body = "d1 > 0 : rising over h bars; < 0 falling; cross 0 : flip.";

      interp = "Demo buy bias if d1>0 & d2>0 when trade enabled.";

   }

   else if(InpWhichDerivative == DERIVATIVE_LEVEL_2)

   {

      title = "EA focus: d2 only\n";

      body = "d2 : momentum building (+) or fading (-) vs d1.";

      interp = "Use with price context.";

   }

   else

   {

      title = "EA focus: d3 only\n";

      body = "d3 : noisy; regime / climax hints.";

      interp = "Large |d3| → acceleration changing fast.";

   }

   if(!LabelCreateMain(px + "title", CORNER_LEFT_UPPER, x0, 20, title, InpHelpTitleColor, 10, ANCHOR_LEFT_UPPER))

      return;

   if(!LabelCreateMain(px + "body", CORNER_LEFT_UPPER, x0, 42, body, InpHelpBodyColor, 8, ANCHOR_LEFT_UPPER))

   {

      ObjectDelete(0, px + "title");

      return;

   }

   if(!LabelCreateMain(px + "interp", CORNER_LEFT_LOWER, x0, 8, interp, InpHelpBodyColor, 8, ANCHOR_LEFT_LOWER))

   {

      ObjectDelete(0, px + "title");

      ObjectDelete(0, px + "body");

      return;

   }

}

double AppliedFromRates(const MqlRates &r)

{

   switch(InpAppliedPrice)

   {

      case PRICE_OPEN:    return r.open;

      case PRICE_HIGH:    return r.high;

      case PRICE_LOW:     return r.low;

      case PRICE_CLOSE:   return r.close;

      case PRICE_MEDIAN:  return (r.high + r.low) * 0.5;

      case PRICE_TYPICAL: return (r.high + r.low + r.close) / 3.0;

      case PRICE_WEIGHTED:return (r.high + r.low + r.close + r.close) / 4.0;

      default:            return r.close;

   }

}

void SmoothPriceArray(const int total, const double &src[], double &dst[])

{

   ArrayResize(dst, total);

   const int p = InpSmoothPeriod;

   if(p <= 1)

   {

      ArrayCopy(dst, src);

      return;

   }

   const double alpha = 2.0 / (p + 1.0);

   const int oldest = total - 1;

   double ema = src[oldest];

   dst[oldest] = ema;

   for(int i = oldest - 1; i >= 0; i--)

   {

      ema = alpha * src[i] + (1.0 - alpha) * ema;

      dst[i] = ema;

   }

}

double SrcAt(const int i, const bool useSmooth, const double &smooth[], const double &raw[])

{

   return useSmooth ? smooth[i] : raw[i];

}

bool ComputeDerivatives(const string sym, const ENUM_TIMEFRAMES tf,

                        double &out_d1, double &out_d2, double &out_d3)

{

   out_d1 = out_d2 = out_d3 = 0.0;

   const int h = MathMax(InpDiffStep, 1);

   const int needBars = 50 + h * 6;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   const int n = CopyRates(sym, tf, 0, needBars, rates);

   if(n < h * 3 + 5)

      return false;

   double raw[];

   ArrayResize(raw, n);

   ArraySetAsSeries(raw, true);

   for(int i = 0; i < n; i++)

      raw[i] = AppliedFromRates(rates[i]);

   double smoothed[];

   SmoothPriceArray(n, raw, smoothed);

   const bool useSmooth = (InpSmoothPeriod > 1);

   const double scale = InpNormalizePoints ? SymbolInfoDouble(sym, SYMBOL_POINT) : 1.0;

   if(scale <= 0.0)

      return false;

   const int i = 1;

   if(i + h >= n)

      return false;

   const double d1_i = (SrcAt(i, useSmooth, smoothed, raw) - SrcAt(i + h, useSmooth, smoothed, raw)) / ((double)h * scale);

   if(i + 2 * h >= n)

   {

      out_d1 = d1_i;

      return true;

   }

   const double d1_ip = (SrcAt(i + h, useSmooth, smoothed, raw) - SrcAt(i + 2 * h, useSmooth, smoothed, raw)) / ((double)h * scale);

   const double d2_i = (d1_i - d1_ip) / ((double)h * scale);

   if(i + 3 * h >= n)

   {

      out_d1 = d1_i;

      out_d2 = d2_i;

      return true;

   }

   const double d1_ip2 = (SrcAt(i + 2 * h, useSmooth, smoothed, raw) - SrcAt(i + 3 * h, useSmooth, smoothed, raw)) / ((double)h * scale);

   const double d2_ip = (d1_ip - d1_ip2) / ((double)h * scale);

   const double d3_i = (d2_i - d2_ip) / ((double)h * scale);

   out_d1 = d1_i;

   out_d2 = d2_i;

   out_d3 = d3_i;

   return true;

}

double CanvasSeriesAt(const int row, const int si,

                      const double &d1[], const double &d2[], const double &d3[])

{

   if(row == 0)

      return d1[si];

   if(row == 1)

      return d2[si];

   return d3[si];

}

bool ComputeDerivativeSeries(const string sym, const ENUM_TIMEFRAMES tf,

                             const int plotBars,

                             double &d1[], double &d2[], double &d3[])

{

   const int h = MathMax(InpDiffStep, 1);

   const int need = plotBars + h * 4 + 10;

   MqlRates rates[];

   ArraySetAsSeries(rates, true);

   const int n = CopyRates(sym, tf, 0, need, rates);

   if(n < h * 3 + 5)

      return false;

   double raw[];

   ArrayResize(raw, n);

   ArraySetAsSeries(raw, true);

   for(int i = 0; i < n; i++)

      raw[i] = AppliedFromRates(rates[i]);

   double smoothed[];

   SmoothPriceArray(n, raw, smoothed);

   const bool useSmooth = (InpSmoothPeriod > 1);

   const double scale = InpNormalizePoints ? SymbolInfoDouble(sym, SYMBOL_POINT) : 1.0;

   if(scale <= 0.0)

      return false;

   ArrayResize(d1, plotBars);

   ArrayResize(d2, plotBars);

   ArrayResize(d3, plotBars);

   ArrayInitialize(d1, EMPTY_VALUE);

   ArrayInitialize(d2, EMPTY_VALUE);

   ArrayInitialize(d3, EMPTY_VALUE);

   const int d1Count = MathMin(plotBars, n - h);

   for(int si = 0; si < d1Count; si++)

      d1[si] = (SrcAt(si, useSmooth, smoothed, raw) - SrcAt(si + h, useSmooth, smoothed, raw)) / ((double)h * scale);

   for(int si = 0; si < plotBars; si++)

   {

      if(si + 2 * h >= n || si + h >= d1Count)

         break;

      d2[si] = (d1[si] - d1[si + h]) / ((double)h * scale);

   }

   for(int si = 0; si < plotBars; si++)

   {

      if(si + 3 * h >= n)

         break;

      if(si + h >= plotBars)

         break;

      if(d2[si] == EMPTY_VALUE || d2[si + h] == EMPTY_VALUE)

         continue;

      d3[si] = (d2[si] - d2[si + h]) / ((double)h * scale);

   }

   return true;

}

void UpdateDerivativeCanvasStrip()

{

   if(!InpUseCanvasPlots)

      return;

   ENUM_TIMEFRAMES tf = InpSignalTF;

   if(tf == PERIOD_CURRENT)

      tf = (ENUM_TIMEFRAMES)Period();

   double d1[], d2[], d3[];

   if(!ComputeDerivativeSeries(g_chartSymbol, tf, InpCanvasPlotBars, d1, d2, d3))

      return;

   const int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

   if(chartW < 80)

      return;

   const int panelW = MathMax(60, chartW - InpCanvasSideMargin * 2);

   const int panelH = MathMax(90, InpCanvasPanelHeight);

   const int x0 = InpCanvasSideMargin;

   const int y0 = InpCanvasBottomMargin;

   if(!g_deriv_canvas_created)

   {

      if(!g_deriv_canvas.CreateBitmapLabel(0, 0, DERIV_CANVAS_OBJ, x0, y0, panelW, panelH, COLOR_FORMAT_ARGB_NORMALIZE))

      {

         if(InpDebugTrace)

            Print("DERIVATIVE_CALC: canvas CreateBitmapLabel failed err=", GetLastError());

         return;

      }

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_CORNER, CORNER_LEFT_LOWER);

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_HIDDEN, true);

      g_deriv_canvas_created = true;

   }

   else

   {

      g_deriv_canvas.Resize(panelW, panelH);

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_XDISTANCE, x0);

      ObjectSetInteger(0, DERIV_CANVAS_OBJ, OBJPROP_YDISTANCE, y0);

   }

   g_deriv_canvas.Erase(ColorToARGB(InpCanvasBgColor, 255));

   const int rows = 3;

   const int rowH = MathMax(24, panelH / rows);

   const uint clrLines[3] = {

      ColorToARGB(clrDodgerBlue, 235),

      ColorToARGB(clrOrange, 235),

      ColorToARGB(clrMagenta, 235)

   };

   const string tags[3] = { "d1 velocity", "d2 acceleration", "d3 jerk" };

   const int nPts = MathMin(InpCanvasPlotBars, ArraySize(d1));

   if(nPts < 3)

   {

      g_deriv_canvas.Update();

      return;

   }

   for(int r = 0; r < rows; r++)

   {

      const int yBase = r * rowH;

      const int midY = yBase + rowH / 2;

      g_deriv_canvas.LineAA(0.0, (double)midY, (double)(panelW - 1), (double)midY, ColorToARGB(InpCanvasGridColor, 70));

      double vmin = DBL_MAX;

      double vmax = -DBL_MAX;

      for(int si = 0; si < nPts; si++)

      {

         const double v = CanvasSeriesAt(r, si, d1, d2, d3);

         if(v == EMPTY_VALUE || !MathIsValidNumber(v))

            continue;

         if(v < vmin)

            vmin = v;

         if(v > vmax)

            vmax = v;

      }

      if(vmin == DBL_MAX)

         continue;

      if(MathAbs(vmax - vmin) < 1e-15)

      {

         vmin -= 1.0;

         vmax += 1.0;

      }

      g_deriv_canvas.FontSet("Consolas", -90);

      g_deriv_canvas.TextOut(4, yBase + 2, tags[r], ColorToARGB(clrSilver, 220));

      const double denom = (double)MathMax(1, nPts - 1);

      for(int si = 0; si < nPts - 1; si++)

      {

         const double v0 = CanvasSeriesAt(r, si, d1, d2, d3);

         const double v1 = CanvasSeriesAt(r, si + 1, d1, d2, d3);

         if(v0 == EMPTY_VALUE || v1 == EMPTY_VALUE)

            continue;

         const double xf0 = (double)(panelW - 1) * (double)(nPts - 1 - si) / denom;

         const double xf1 = (double)(panelW - 1) * (double)(nPts - 2 - si) / denom;

         const double t0 = (v0 - vmin) / (vmax - vmin);

         const double t1 = (v1 - vmin) / (vmax - vmin);

         const int py0 = yBase + 3 + (int)((double)(rowH - 6) * (1.0 - t0));

         const int py1 = yBase + 3 + (int)((double)(rowH - 6) * (1.0 - t1));

         g_deriv_canvas.LineAA(xf0, (double)py0, xf1, (double)py1, clrLines[r]);

      }

   }

   g_deriv_canvas.Update();

   ChartRedraw(0);

}

bool HasOurPosition(const string sym)

{

   for(int i = PositionsTotal() - 1; i >= 0; i--)

   {

      const ulong t = PositionGetTicket(i);

      if(t == 0 || !PositionSelectByTicket(t))

         continue;

      if(PositionGetString(POSITION_SYMBOL) != sym)

         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)

         continue;

      return true;

   }

   return false;

}

double AtrPoints(const string sym, const ENUM_TIMEFRAMES tf)

{

   const int h = iATR(sym, tf, InpAtrPeriod);

   if(h == INVALID_HANDLE)

      return 0.0;

   double b[];

   ArraySetAsSeries(b, true);

   if(CopyBuffer(h, 0, 1, 1, b) != 1)

   {

      IndicatorRelease(h);

      return 0.0;

   }

   IndicatorRelease(h);

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);

   return (pt > 0.0 ? b[0] / pt : 0.0);

}

void RemoveDerivativePlotsIndicatorsFromChart()

{

   const int nw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

   for(int w = nw - 1; w >= 0; w--)

   {

      const int nc = ChartIndicatorsTotal(0, w);

      for(int k = nc - 1; k >= 0; k--)

      {

         const string nm = ChartIndicatorName(0, w, k);

         if(StringFind(nm, "DERIV_") >= 0 ||

            StringFind(nm, "DERIV_PLOTS") >= 0 ||

            StringFind(nm, InpPlotsIndicatorPath) >= 0 ||

            StringFind(nm, "DerivativePlots") >= 0)

            ChartIndicatorDelete(0, w, nm);

      }

   }

}

bool DerivativePlotsAlreadyOnChart()

{

   const int nw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

   for(int w = 0; w < nw; w++)

   {

      const int nc = ChartIndicatorsTotal(0, w);

      for(int k = 0; k < nc; k++)

      {

         const string nm = ChartIndicatorName(0, w, k);

         if(StringFind(nm, "DERIV_") >= 0 || StringFind(nm, "DERIV_PLOTS") >= 0 ||

            StringFind(nm, InpPlotsIndicatorPath) >= 0)

            return true;

      }

   }

   return false;

}

// Pass every DerivativePlots input (same order as .mq5) so each WhichDerivative gets its own handle.

int MakeDerivativePlotsHandle(const string sym, const ENUM_TIMEFRAMES tf,

                              const ENUM_DERIVATIVE_VIEW which, const bool unifyY)

{

   return iCustom(sym, tf, InpPlotsIndicatorPath,

                  InpAppliedPrice,

                  which,

                  unifyY,

                  InpDiffStep,

                  InpNormalizePoints,

                  InpSmoothPeriod,

                  true,

                  InpDebugTrace,

                  false);

}

bool AttachDerivativePlotsIndicator(const string sym, const ENUM_TIMEFRAMES tf)

{

   if(!InpAutoAttachDerivativePlots)

      return false;

   if(g_derivPlotsAttachDone)

      return true;

   const string wantPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Indicators\\" + InpPlotsIndicatorPath + ".ex5";

   // ChartIndicatorAdd(chart, subwindow, handle). Subwindow index: use ChartWindowsTotal() before each add

   // so new panes are appended below existing windows (ATR etc.). Fixed 1,2,3 collides with other indicators.

   const bool unifyPass = InpPlotsSeparateWindows ? false : InpPlotsUnifyYScale;

   if(InpPlotsSeparateWindows)

   {

      ResetLastError();

      const int ind1 = MakeDerivativePlotsHandle(sym, tf, DERIVATIVE_LEVEL_1, unifyPass);

      if(ind1 == INVALID_HANDLE)

      {

         g_derivativePlotsFailedToLoad = true;

         Print("DERIVATIVE_CALC: iCustom(", InpPlotsIndicatorPath, ", d1) failed err=", GetLastError(),

               ". Required:\n    ", wantPath);

         if(InpDebugTrace)

            PrintFormat("DERIVATIVE_CALC dbg iCustom d1 sym=%s tf=%s", sym, EnumToString(tf));

         return false;

      }

      ResetLastError();

      const int ind2 = MakeDerivativePlotsHandle(sym, tf, DERIVATIVE_LEVEL_2, unifyPass);

      if(ind2 == INVALID_HANDLE)

      {

         IndicatorRelease(ind1);

         g_derivativePlotsFailedToLoad = true;

         Print("DERIVATIVE_CALC: iCustom(", InpPlotsIndicatorPath, ", d2) failed err=", GetLastError(),

               ". Required:\n    ", wantPath);

         return false;

      }

      ResetLastError();

      const int ind3 = MakeDerivativePlotsHandle(sym, tf, DERIVATIVE_LEVEL_3, unifyPass);

      if(ind3 == INVALID_HANDLE)

      {

         IndicatorRelease(ind1);

         IndicatorRelease(ind2);

         g_derivativePlotsFailedToLoad = true;

         Print("DERIVATIVE_CALC: iCustom(", InpPlotsIndicatorPath, ", d3) failed err=", GetLastError(),

               ". Required:\n    ", wantPath);

         return false;

      }

      if(InpDebugTrace)

         PrintFormat("DERIVATIVE_CALC dbg triple iCustom handles ind1=%d ind2=%d ind3=%d (should differ)",

                     ind1, ind2, ind3);

      RemoveDerivativePlotsIndicatorsFromChart();

      int sw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

      ResetLastError();

      const bool ok1 = ChartIndicatorAdd(0, sw, ind1);

      const int err1 = GetLastError();

      sw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

      ResetLastError();

      const bool ok2 = ChartIndicatorAdd(0, sw, ind2);

      const int err2 = GetLastError();

      sw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

      ResetLastError();

      const bool ok3 = ChartIndicatorAdd(0, sw, ind3);

      const int err3 = GetLastError();

      IndicatorRelease(ind1);

      IndicatorRelease(ind2);

      IndicatorRelease(ind3);

      if(!ok1 || !ok2 || !ok3)

      {

         g_derivativePlotsFailedToLoad = true;

         Print("DERIVATIVE_CALC: ChartIndicatorAdd (3 panes) failed ok=", ok1, ",", ok2, ",", ok3,

               " err=", err1, ",", err2, ",", err3, ". File: ", wantPath);

         return false;

      }

      g_derivativePlotsFailedToLoad = false;

      g_derivPlotsAttachDone = true;

      ChartRedraw(0);

      Print("DERIVATIVE_CALC: DerivativePlots attached as three stacked subwindows (indices chosen from CHART_WINDOWS_TOTAL).");

      if(InpDebugTrace)

         PrintFormat("DERIVATIVE_CALC dbg triple attach OK sym=%s tf=%s", sym, EnumToString(tf));

      return true;

   }

   ResetLastError();

   const int ind = MakeDerivativePlotsHandle(sym, tf, InpWhichDerivative, unifyPass);

   if(ind == INVALID_HANDLE)

   {

      g_derivativePlotsFailedToLoad = true;

      Print("DERIVATIVE_CALC: iCustom(\"", InpPlotsIndicatorPath, "\") failed err=", GetLastError(),

            ". MT5 could not read the compiled indicator. Required file:\n    ", wantPath,

            "\nCopy lab\\\\EAs\\\\DerivativePlots.mq5 into that Indicators folder, open in MetaEditor, press Compile (F7).");

      if(InpDebugTrace)

         PrintFormat("DERIVATIVE_CALC dbg iCustom sym=%s tf=%s applied=%d which=%d unify=%s h=%d norm=%s sm=%d",

                     sym, EnumToString(tf), (int)InpAppliedPrice, (int)InpWhichDerivative,

                     InpPlotsUnifyYScale ? "on" : "off",

                     InpDiffStep, InpNormalizePoints ? "on" : "off", InpSmoothPeriod);

      return false;

   }

   RemoveDerivativePlotsIndicatorsFromChart();

   int sw = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);

   ResetLastError();

   const bool ok = ChartIndicatorAdd(0, sw, ind);

   const int errAfterAdd = GetLastError();

   IndicatorRelease(ind);

   if(!ok)

   {

      g_derivativePlotsFailedToLoad = true;

      Print("DERIVATIVE_CALC: ChartIndicatorAdd failed err=", errAfterAdd,

            ". Expected file present: ", wantPath);

      return false;

   }

   g_derivativePlotsFailedToLoad = false;

   g_derivPlotsAttachDone = true;

   ChartRedraw(0);

   Print("DERIVATIVE_CALC: subwindow indicator attached (inputs synced from EA).");

   if(InpDebugTrace)

      PrintFormat("DERIVATIVE_CALC dbg attach OK handle_was_valid ChartIndicatorAdd err=%d sym=%s tf=%s sw=%d",

                  errAfterAdd, sym, EnumToString(tf), sw);

   return true;

}

void TryDemoTrade(const string sym, const ENUM_TIMEFRAMES tf,

                  const double d1, const double d2, const double d3)

{

   if(!InpTradeEnabled || HasOurPosition(sym))

      return;

   bool wantBuy = false;

   bool wantSell = false;

   switch(InpWhichDerivative)

   {

      case DERIVATIVE_ALL:

      case DERIVATIVE_LEVEL_1:

         wantBuy = (d1 > 0.0 && d2 > 0.0);

         wantSell = (d1 < 0.0 && d2 < 0.0);

         break;

      case DERIVATIVE_LEVEL_2:

         wantBuy = (d2 > 0.0);

         wantSell = (d2 < 0.0);

         break;

      default:

         wantBuy = (d3 > 0.0);

         wantSell = (d3 < 0.0);

         break;

   }

   if(!wantBuy && !wantSell)

      return;

   MqlTick tick;

   if(!SymbolInfoTick(sym, tick))

      return;

   const double atrPts = AtrPoints(sym, tf);

   const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);

   const double slPts = MathMax(atrPts * InpSlAtrMult, 10.0);

   const double tpPts = MathMax(atrPts * InpTpAtrMult, 10.0);

   double sl = 0.0, tp = 0.0;

   if(wantBuy)

   {

      sl = tick.ask - slPts * pt;

      tp = tick.ask + tpPts * pt;

      g_trade.Buy(InpLots, sym, tick.ask, sl, tp, "DERIVATIVE_CALC demo");

   }

   else if(wantSell)

   {

      sl = tick.bid + slPts * pt;

      tp = tick.bid - tpPts * pt;

      g_trade.Sell(InpLots, sym, tick.bid, sl, tp, "DERIVATIVE_CALC demo");

   }

}

int OnInit()

{

   g_derivPlotsAttachDone = false;

   g_lastCommentWallMs = 0;

   g_chartSymbol = InpSymbol;

   StringTrimLeft(g_chartSymbol);

   StringTrimRight(g_chartSymbol);

   if(StringLen(g_chartSymbol) == 0)

      g_chartSymbol = _Symbol;

   if(!SymbolSelect(g_chartSymbol, true))

   {

      Print("DERIVATIVE_CALC EA: cannot select symbol ", g_chartSymbol);

      return INIT_FAILED;

   }

   g_trade.SetExpertMagicNumber((long)InpMagic);

   g_trade.SetDeviationInPoints(InpSlippagePoints);

   g_trade.SetTypeFillingBySymbol(g_chartSymbol);

   ENUM_TIMEFRAMES tf = InpSignalTF;

   if(tf == PERIOD_CURRENT)

      tf = (ENUM_TIMEFRAMES)Period();

   Print("DERIVATIVE_CALC EA started on ", g_chartSymbol, " ", EnumToString(tf),

         ". This is an Expert Advisor — not the Accelerator indicator.");

   if(InpDebugTrace)

      PrintFormat("DERIVATIVE_CALC dbg chart_TF=%s signal_TF=%s normalize=%s h=%d sm=%d tester=%s visual=%s",

                  EnumToString((ENUM_TIMEFRAMES)Period()), EnumToString(tf),

                  InpNormalizePoints ? "on" : "off", InpDiffStep, InpSmoothPeriod,

                  MQLInfoInteger(MQL_TESTER) ? "yes" : "no",

                  MQLInfoInteger(MQL_VISUAL_MODE) ? "yes" : "no");

   DeleteOurHelpObjects();

   TryBuildHelpPanel();

   // Do not call iCustom / ChartIndicatorAdd here — Strategy Tester treats failed indicator load in OnInit as a critical error.

   // Attachment runs on first OnTick instead (see g_pendingDerivativePlotsAttach).

   if(InpUseCanvasPlots)

   {

      RemoveDerivativePlotsIndicatorsFromChart();

      EventSetMillisecondTimer(120);

   }

   else

      EventKillTimer();

   if(InpAutoAttachDerivativePlots && !InpUseCanvasPlots)

   {

      RemoveDerivativePlotsIndicatorsFromChart();

      const bool in_tester = (MQLInfoInteger(MQL_TESTER) != 0);

      const bool visual    = (MQLInfoInteger(MQL_VISUAL_MODE) != 0);

      const bool skip_tester_attach = (in_tester && !visual && !InpAttachPlotsInTester);

      if(skip_tester_attach)

      {

         Print("DERIVATIVE_CALC: non-visual Strategy Tester - skipping DerivativePlots attach. ",

               "Use visual mode for subwindow plots, or set InpAttachPlotsInTester=true if DerivativePlots.ex5 is in MQL5\\Indicators\\.");

      }

      else

      {

         g_pendingDerivativePlotsAttach = true;

         Print("DERIVATIVE_CALC: DerivativePlots attach scheduled on first tick (OnInit cannot safely load custom indicators in tester).");

      }

   }

   return INIT_SUCCEEDED;

}

void OnDeinit(const int reason)

{

   EventKillTimer();

   if(g_deriv_canvas_created)

   {

      g_deriv_canvas.Destroy();

      g_deriv_canvas_created = false;

   }

   ObjectDelete(0, DERIV_CANVAS_OBJ);

   g_derivPlotsAttachDone = false;

   DeleteOurHelpObjects();

   Comment("");

}

void OnTimer()

{

   if(!InpUseCanvasPlots)

      return;

   const uint now = GetTickCount();

   if(InpCanvasRedrawMs > 0 && g_lastCanvasRedrawMs != 0 &&

      (now - g_lastCanvasRedrawMs) < (uint)InpCanvasRedrawMs)

      return;

   g_lastCanvasRedrawMs = now;

   UpdateDerivativeCanvasStrip();

}

void OnTick()

{

   ENUM_TIMEFRAMES tf = InpSignalTF;

   if(tf == PERIOD_CURRENT)

      tf = (ENUM_TIMEFRAMES)Period();

   if(g_pendingDerivativePlotsAttach && !InpUseCanvasPlots)

   {

      g_pendingDerivativePlotsAttach = false;

      AttachDerivativePlotsIndicator(g_chartSymbol, tf);

   }

   const datetime barOpen = iTime(g_chartSymbol, tf, 0);

   if(barOpen == 0)

      return;

   if(barOpen == g_lastBarTime)

      return;

   g_lastBarTime = barOpen;

   double d1 = 0.0, d2 = 0.0, d3 = 0.0;

   if(!ComputeDerivatives(g_chartSymbol, tf, d1, d2, d3))

   {

      if(InpDebugTrace)

         PrintFormat("DERIVATIVE_CALC dbg ComputeDerivatives FAILED sym=%s tf=%s bar=%s pt=%.12g",

                     g_chartSymbol, EnumToString(tf), TimeToString(barOpen, TIME_DATE | TIME_MINUTES),

                     SymbolInfoDouble(g_chartSymbol, SYMBOL_POINT));

      if(InpShowComment)

         CommentThrottled("DERIVATIVE_CALC: not enough bars yet on " + g_chartSymbol + " " + EnumToString(tf) +

                          DerivativePlotsMissingHint());

      return;

   }

   if(InpDebugTrace)

      PrintFormat("DERIVATIVE_CALC dbg bar=%s sym=%s chart_TF=%s signal_TF=%s | d1=%.8g d2=%.8g d3=%.8g | pt=%.12g norm=%s h=%d",

                  TimeToString(barOpen, TIME_DATE | TIME_MINUTES), g_chartSymbol,

                  EnumToString((ENUM_TIMEFRAMES)Period()), EnumToString(tf),

                  d1, d2, d3, SymbolInfoDouble(g_chartSymbol, SYMBOL_POINT),

                  InpNormalizePoints ? "on" : "off", InpDiffStep);

   if(InpShowComment)

   {

      string c = "DERIVATIVE_CALC EA | " + g_chartSymbol +

                 "\nChart TF: " + EnumToString((ENUM_TIMEFRAMES)Period()) +

                 "   Signal TF (inputs): " + EnumToString(tf) +

                 "\nd1=" + DoubleToString(d1, 4) + "  d2=" + DoubleToString(d2, 4) + "  d3=" + DoubleToString(d3, 4) +

                 "\n(InpWhichDerivative=" + IntegerToString((int)InpWhichDerivative) +

                 "  h=" + IntegerToString(InpDiffStep) + "  sm=" + IntegerToString(InpSmoothPeriod) + ")" +

                 (InpUseCanvasPlots

                  ? "\nPlots: EA canvas strip (bottom of chart)."

                  : ("\nPlots below: DerivativePlots indicator." + DerivativePlotsMissingHint()));

      CommentThrottled(c);

   }

   TryDemoTrade(g_chartSymbol, tf, d1, d2, d3);

}

//+------------------------------------------------------------------+

