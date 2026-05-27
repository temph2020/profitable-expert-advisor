//+------------------------------------------------------------------+
//|                                           DerivativePlots.mq5    |
//|  Subwindow line plots for d1 / d2 / d3 — use with Derivative EA   |
//|  Compile into MQL5\\Indicators\\ (same name). EA can ChartIndicatorAdd.|
//+------------------------------------------------------------------+
#property copyright "Lab"
#property link      ""
#property version   "1.10"
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   3
#property description "Plots d1 d2 d3 below chart. Match inputs to Derivative EA."

#property indicator_label1  "d1 velocity"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  1

#property indicator_label2  "d2 acceleration"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1

#property indicator_label3  "d3 jerk"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrMagenta
#property indicator_width3  1

enum ENUM_DERIVATIVE_VIEW
{
   DERIVATIVE_ALL     = 0,
   DERIVATIVE_LEVEL_1 = 1,
   DERIVATIVE_LEVEL_2 = 2,
   DERIVATIVE_LEVEL_3 = 3
};

input group "=== Source ==="
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;

input group "=== Layout ==="
input ENUM_DERIVATIVE_VIEW InpWhichDerivative = DERIVATIVE_ALL; // Single-line modes clear other buffers to EMPTY_VALUE so Y-scale matches the visible line
input bool               InpUnifyPlotYScale    = true;   // Scale d2,d3 for comparable magnitude when normalized (shared subwindow)

input group "=== Calculus ==="
input int                InpDiffStep      = 1;
input bool               InpNormalizePoints = true;

input group "=== Smoothing ==="
input int                InpSmoothPeriod  = 0;

input group "=== Status ==="
input bool               InpShowValueBanner = true;   // Text label; short name is DERIV_ALL / DERIV_d1 / DERIV_d2 / DERIV_d3 for ChartWindowFind

input group "=== Debug (Experts / Journal) ==="
input bool               InpDebugTrace              = false;  // Print diagnostics to Experts tab
input bool               InpDebugLogEveryCalculate = false;  // Log every OnCalculate (very verbose)

double ExtD1[];
double ExtD2[];
double ExtD3[];

string g_deriv_chart_title = "DERIV_ALL";
string g_deriv_stat_obj    = "DerivPV_ALL";

void SetupDerivIdentity()
{
   switch(InpWhichDerivative)
   {
      case DERIVATIVE_ALL:
         g_deriv_chart_title = "DERIV_ALL";
         g_deriv_stat_obj = "DerivPV_ALL";
         break;
      case DERIVATIVE_LEVEL_1:
         g_deriv_chart_title = "DERIV_d1";
         g_deriv_stat_obj = "DerivPV_d1";
         break;
      case DERIVATIVE_LEVEL_2:
         g_deriv_chart_title = "DERIV_d2";
         g_deriv_stat_obj = "DerivPV_d2";
         break;
      default:
         g_deriv_chart_title = "DERIV_d3";
         g_deriv_stat_obj = "DerivPV_d3";
         break;
   }
}

// OnCalculate passes OHLC with index 0 = oldest bar (non-series). Do not ArraySetAsSeries() those arrays.

double AppliedPriceRowNs(const int pos, const double &open[], const double &high[],
                           const double &low[], const double &close[])
{
   switch(InpAppliedPrice)
   {
      case PRICE_OPEN:   return open[pos];
      case PRICE_HIGH:   return high[pos];
      case PRICE_LOW:    return low[pos];
      case PRICE_CLOSE:  return close[pos];
      case PRICE_MEDIAN: return (high[pos] + low[pos]) * 0.5;
      case PRICE_TYPICAL: return (high[pos] + low[pos] + close[pos]) / 3.0;
      case PRICE_WEIGHTED: return (high[pos] + low[pos] + close[pos] + close[pos]) / 4.0;
      default:           return close[pos];
   }
}

void SmoothPriceArrayNs(const int total, const double &src[], double &dst[])
{
   ArrayResize(dst, total);
   const int p = InpSmoothPeriod;
   if(p <= 1)
   {
      ArrayCopy(dst, src);
      return;
   }
   const double alpha = 2.0 / (p + 1.0);
   dst[0] = src[0];
   for(int pos = 1; pos < total; pos++)
      dst[pos] = alpha * src[pos] + (1.0 - alpha) * dst[pos - 1];
}

double SrcNs(const int pos, const bool useSmooth, const double &smooth[], const double &raw[])
{
   return useSmooth ? smooth[pos] : raw[pos];
}

double DerivativeScalePts()
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt <= 0.0 || !MathIsValidNumber(pt))
      pt = _Point;
   if(!InpNormalizePoints)
      return 1.0;
   if(pt <= 0.0)
      return 1.0;
   return pt;
}

void DerivPlotsTrace(const int rates_total, const int prev_calculated,
                     const int h, const int min_bars, const double scale, const bool useSmooth,
                     const double &close[], const double &WorkNs[], const datetime &time[])
{
   if(!InpDebugTrace)
      return;

   static int s_call = 0;
   s_call++;

   const int newest = rates_total - 1;
   const datetime barOpen = time[newest];

   static datetime s_prevBarOpen = 0;
   const bool isNewBarTime = (barOpen != s_prevBarOpen);
   if(isNewBarTime)
      s_prevBarOpen = barOpen;

   const bool fullRecalc = (prev_calculated == 0);

   if(InpDebugLogEveryCalculate)
   {
      PrintFormat("DERIV_PLOTS #%d prev_calc=%d rates=%d bar=%s | d1[0]=%.8g d2[0]=%.8g d3[0]=%.8g",
                  s_call, prev_calculated, rates_total, TimeToString(barOpen, TIME_DATE | TIME_MINUTES),
                  ExtD1[0], ExtD2[0], ExtD3[0]);
      return;
   }

   if(fullRecalc)
   {
      const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      const double rawStep = (newest >= h) ? (WorkNs[newest] - WorkNs[newest - h]) : 0.0;
      PrintFormat("DERIV_PLOTS FULL_CALC #%d sym=%s rates=%d prev_calc=%d h=%d min_need=%d smooth=%s which=%d",
                  s_call, _Symbol, rates_total, prev_calculated, h, min_bars,
                  useSmooth ? "on" : "off", (int)InpWhichDerivative);
      PrintFormat("  scale=%.12g normalize=%s SYPOINT=%.12g _Point=%.12g SYM_DIGITS=%d",
                  scale, InpNormalizePoints ? "on" : "off", pt, _Point,
                  (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      PrintFormat("  close[oldest]=%.8f close[newest]=%.8f rawStep(newest..newest-h)=%.8f",
                  close[0], close[newest], rawStep);
      PrintFormat("  series buf [0]=current bar: d1=%.8g d2=%.8g d3=%.8g (EMPTY_VALUE=%.8g)",
                  ExtD1[0], ExtD2[0], ExtD3[0], EMPTY_VALUE);
   }
   else if(isNewBarTime)
   {
      PrintFormat("DERIV_PLOTS BAR %s rates=%d prev_calc=%d | d1[0]=%.8g d2[0]=%.8g d3[0]=%.8g",
                  TimeToString(barOpen, TIME_DATE | TIME_MINUTES), rates_total, prev_calculated,
                  ExtD1[0], ExtD2[0], ExtD3[0]);
   }
}

string FormatPlotVal(const double v)
{
   if(v == EMPTY_VALUE || !MathIsValidNumber(v))
      return "—";
   return DoubleToString(v, 4);
}

void UpdateValueBanner(const int rates_total)
{
   if(!InpShowValueBanner || rates_total < 1)
      return;

   string txt = "";
   switch(InpWhichDerivative)
   {
      case DERIVATIVE_ALL:
         txt = StringFormat("d1=%s  d2=%s  d3=%s  (h=%d sm=%d%s)",
                            FormatPlotVal(ExtD1[0]), FormatPlotVal(ExtD2[0]), FormatPlotVal(ExtD3[0]),
                            InpDiffStep, InpSmoothPeriod, InpUnifyPlotYScale ? " unifyY" : "");
         break;
      case DERIVATIVE_LEVEL_1:
         txt = StringFormat("d1=%s", FormatPlotVal(ExtD1[0]));
         break;
      case DERIVATIVE_LEVEL_2:
         txt = StringFormat("d2=%s", FormatPlotVal(ExtD2[0]));
         break;
      default:
         txt = StringFormat("d3=%s", FormatPlotVal(ExtD3[0]));
         break;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, g_deriv_chart_title);

   const int sub = ChartWindowFind(0, g_deriv_chart_title);
   if(sub < 0)
      return;

   if(ObjectFind(0, g_deriv_stat_obj) < 0)
   {
      if(!ObjectCreate(0, g_deriv_stat_obj, OBJ_LABEL, sub, 0, 0))
         return;
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_XDISTANCE, 6);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_YDISTANCE, 16);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, g_deriv_stat_obj, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_deriv_stat_obj, OBJPROP_HIDDEN, true);
   }
   ObjectSetString(0, g_deriv_stat_obj, OBJPROP_TEXT, txt);
}

// Hide unused buffers from autoscale: DRAW_NONE plots can still skew separate-window limits if buffers hold numbers.
void MaskBuffersForDerivativeView()
{
   switch(InpWhichDerivative)
   {
      case DERIVATIVE_ALL:
         break;
      case DERIVATIVE_LEVEL_1:
         ArrayInitialize(ExtD2, EMPTY_VALUE);
         ArrayInitialize(ExtD3, EMPTY_VALUE);
         break;
      case DERIVATIVE_LEVEL_2:
         ArrayInitialize(ExtD1, EMPTY_VALUE);
         ArrayInitialize(ExtD3, EMPTY_VALUE);
         break;
      default:
         ArrayInitialize(ExtD1, EMPTY_VALUE);
         ArrayInitialize(ExtD2, EMPTY_VALUE);
         break;
   }
}

void ApplyDerivativeViewMode()
{
   switch(InpWhichDerivative)
   {
      case DERIVATIVE_ALL:
         PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(0, PLOT_LINE_COLOR, clrDodgerBlue);
         PlotIndexSetInteger(1, PLOT_LINE_COLOR, clrOrange);
         PlotIndexSetInteger(2, PLOT_LINE_COLOR, clrMagenta);
         PlotIndexSetInteger(0, PLOT_LINE_WIDTH, 2);
         PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 3);
         PlotIndexSetInteger(2, PLOT_LINE_WIDTH, 3);
         PlotIndexSetInteger(0, PLOT_LINE_STYLE, STYLE_SOLID);
         PlotIndexSetInteger(1, PLOT_LINE_STYLE, STYLE_SOLID);
         PlotIndexSetInteger(2, PLOT_LINE_STYLE, STYLE_SOLID);
         PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         break;
      case DERIVATIVE_LEVEL_1:
         PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(0, PLOT_LINE_COLOR, clrDodgerBlue);
         PlotIndexSetInteger(0, PLOT_LINE_WIDTH, 2);
         PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         break;
      case DERIVATIVE_LEVEL_2:
         PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(1, PLOT_LINE_COLOR, clrOrange);
         PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 3);
         PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         break;
      default:
         PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
         PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_LINE);
         PlotIndexSetInteger(2, PLOT_LINE_COLOR, clrMagenta);
         PlotIndexSetInteger(2, PLOT_LINE_WIDTH, 3);
         PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         break;
   }
}

int OnInit()
{
   SetIndexBuffer(0, ExtD1, INDICATOR_DATA);
   SetIndexBuffer(1, ExtD2, INDICATOR_DATA);
   SetIndexBuffer(2, ExtD3, INDICATOR_DATA);
   SetupDerivIdentity();
   ApplyDerivativeViewMode();
   IndicatorSetString(INDICATOR_SHORTNAME, g_deriv_chart_title);
   const int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   IndicatorSetInteger(INDICATOR_DIGITS, MathMax(6, dig));
   if(InpDebugTrace)
      PrintFormat("DERIV_PLOTS INIT sym=%s applied=%s h=%d sm=%d norm=%s dbg_every_calc=%s",
                  _Symbol, EnumToString(InpAppliedPrice), InpDiffStep, InpSmoothPeriod,
                  InpNormalizePoints ? "on" : "off", InpDebugLogEveryCalculate ? "on" : "off");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, g_deriv_stat_obj);
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   const int h = MathMax(InpDiffStep, 1);
   const int min_bars = 3 * h + 2;

   ApplyDerivativeViewMode();

   ArrayResize(ExtD1, rates_total);
   ArrayResize(ExtD2, rates_total);
   ArrayResize(ExtD3, rates_total);
   ArraySetAsSeries(ExtD1, true);
   ArraySetAsSeries(ExtD2, true);
   ArraySetAsSeries(ExtD3, true);
   ArrayInitialize(ExtD1, EMPTY_VALUE);
   ArrayInitialize(ExtD2, EMPTY_VALUE);
   ArrayInitialize(ExtD3, EMPTY_VALUE);

   if(rates_total < min_bars)
   {
      if(InpDebugTrace)
         PrintFormat("DERIV_PLOTS SHORT_HISTORY sym=%s rates=%d need=%d (3*h+2, h=%d) — buffers left EMPTY",
                     _Symbol, rates_total, min_bars, h);
      return rates_total;
   }

   double WorkNs[];
   ArrayResize(WorkNs, rates_total);
   for(int pos = 0; pos < rates_total; pos++)
      WorkNs[pos] = AppliedPriceRowNs(pos, open, high, low, close);

   static double SmoothNs[];
   SmoothPriceArrayNs(rates_total, WorkNs, SmoothNs);

   const bool useSmooth = (InpSmoothPeriod > 1);
   const double scale = DerivativeScalePts();

   // Bar index pos: 0 = oldest, rates_total-1 = newest. Map to series buffer si = rates_total - 1 - pos (0 = current bar).
   const double hs = (double)h * scale;
   const bool   unify = InpUnifyPlotYScale;

   for(int pos = h; pos < rates_total; pos++)
   {
      const double d1 = (SrcNs(pos, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      const int si = rates_total - 1 - pos;
      ExtD1[si] = d1;
   }

   for(int pos = 2 * h; pos < rates_total; pos++)
   {
      const double d1_pos = (SrcNs(pos, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      const double d1_pm = (SrcNs(pos - h, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - 2 * h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      double d2 = (d1_pos - d1_pm) / ((double)h * scale);
      if(unify)
         d2 *= hs;
      const int si = rates_total - 1 - pos;
      ExtD2[si] = d2;
   }

   for(int pos = 3 * h; pos < rates_total; pos++)
   {
      const double d1_pos = (SrcNs(pos, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      const double d1_pm = (SrcNs(pos - h, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - 2 * h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      const double d1_pm2 = (SrcNs(pos - 2 * h, useSmooth, SmoothNs, WorkNs) - SrcNs(pos - 3 * h, useSmooth, SmoothNs, WorkNs)) / ((double)h * scale);
      const double d2_pos = (d1_pos - d1_pm) / ((double)h * scale);
      const double d2_pm = (d1_pm - d1_pm2) / ((double)h * scale);
      double d3 = (d2_pos - d2_pm) / ((double)h * scale);
      if(unify)
         d3 *= hs * hs;
      const int si = rates_total - 1 - pos;
      ExtD3[si] = d3;
   }

   MaskBuffersForDerivativeView();

   DerivPlotsTrace(rates_total, prev_calculated, h, min_bars, scale, useSmooth, close, WorkNs, time);

   UpdateValueBanner(rates_total);

   return rates_total;
}

//+------------------------------------------------------------------+
