//+------------------------------------------------------------------+
//| UnitedProfitPanel.mqh — chart object P&L by strategy / magic     |
//| One OBJ_LABEL per line (MT5 often ignores \n in a single label). |
//| Include only after all United EA `input` declarations.         |
//+------------------------------------------------------------------+
#ifndef UNITED_PROFIT_PANEL_MQH
#define UNITED_PROFIT_PANEL_MQH

#define UNITED_PNL_MAX_LINES 48

struct UnitedPnLRow
{
   string name;
   long   magic;
};

UnitedPnLRow g_unitedPnLRows[];
int         g_unitedPnLRowCount = 0;
int         g_unitedPnL_visibleLineCount = 0;

string UnitedPnL_Obj(const string suffix) { return "UnitedPnL_" + suffix; }

long UnitedPnL_ChartId() { return ChartID(); }

string UnitedPnL_LineObjName(const int idx) { return UnitedPnL_Obj("L") + IntegerToString(idx); }

datetime UnitedPnL_StartOfYear(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.mon = 1;
   dt.day = 1;
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

datetime UnitedPnL_StartOfMonth(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.day = 1;
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

int UnitedPnL_FindRowIndex(const long magic)
{
   for(int r = 0; r < g_unitedPnLRowCount; r++)
   {
      if(g_unitedPnLRows[r].magic == magic)
         return r;
   }
   return -1;
}

bool UnitedPnL_ScanDealsOnce(double &yearPl[], double &monthPl[], const datetime y0, const datetime m0, const datetime now)
{
   const int R = g_unitedPnLRowCount;
   ArrayResize(yearPl, R);
   ArrayResize(monthPl, R);
   for(int j = 0; j < R; j++)
   {
      yearPl[j] = 0.0;
      monthPl[j] = 0.0;
   }

   if(R <= 0 || y0 >= now)
      return true;

   datetime to = now;
   if(to <= y0)
      to = y0 + 1;

   if(!HistorySelect(y0, to))
      return false;

   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      const long mg = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      const int idx = UnitedPnL_FindRowIndex(mg);
      if(idx < 0)
         continue;

      const datetime dt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      const double p = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      yearPl[idx] += p;
      if(dt >= m0)
         monthPl[idx] += p;
   }
   return true;
}

double UnitedPnL_SumFloatingForMagic(const long magic)
{
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      sum += PositionGetDouble(POSITION_PROFIT);
      sum += PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}

void UnitedPnL_CollectRows()
{
   g_unitedPnLRowCount = 0;
   ArrayResize(g_unitedPnLRows, 24);

   if(EnableDarvasBox)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "DarvasBox";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)DB_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableEMASlopeDistance)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "EMASlope";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)ES_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSICrossOverReversal)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RSICrossOver";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RC_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIMidPointHijack)
   {
      if(RM_InpEnableRSIFollow)
      {
         g_unitedPnLRows[g_unitedPnLRowCount].name = "RM_RSIFollow";
         g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RM_InpMagicNumberRSIFollow;
         g_unitedPnLRowCount++;
      }
      if(RM_InpEnableRSIReverse)
      {
         g_unitedPnLRows[g_unitedPnLRowCount].name = "RM_RSIRev";
         g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RM_InpMagicNumberRSIReverse;
         g_unitedPnLRowCount++;
      }
      if(RM_InpEnableEMACross)
      {
         g_unitedPnLRows[g_unitedPnLRowCount].name = "RM_EMACross";
         g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RM_InpMagicNumberEMACross;
         g_unitedPnLRowCount++;
      }
   }
   if(EnableRSIScalpingAPPL)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RS_Scalp_AAPL";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RS_APPL_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIScalpingBTCUSD)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RS_Scalp_BTC";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RS_BTCUSD_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIScalpingNVDA)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RS_Scalp_NVDA";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RS_NVDA_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIScalpingTSLA)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RS_Scalp_TSLA";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RS_TSLA_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIScalpingXAUUSD)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RS_Scalp_XAU";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RS_XAUUSD_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIReversalEURUSD)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RRA_EURUSD";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RRA_EURUSD_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSIReversalAUDUSD)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "RRA_AUDUSD";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RRA_AUDUSD_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableRSISecretSauceXAUUSD)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "SecretSauce";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)RSS_XAUUSD_MagicNumber;
      g_unitedPnLRowCount++;
   }
   if(EnableSuperEMA)
   {
      g_unitedPnLRows[g_unitedPnLRowCount].name = "SuperEMA";
      g_unitedPnLRows[g_unitedPnLRowCount].magic = (long)SE_MagicNumber;
      g_unitedPnLRowCount++;
   }

   ArrayResize(g_unitedPnLRows, MathMax(g_unitedPnLRowCount, 1));
}

void UnitedPnL_EnsureObjects()
{
   const long ch = UnitedPnL_ChartId();
   const string bg = UnitedPnL_Obj("BG");
   if(ObjectFind(ch, bg) < 0)
   {
      if(!ObjectCreate(ch, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      {
         Print("UnitedPnL: BG ObjectCreate failed, err=", GetLastError());
         return;
      }
      ObjectSetInteger(ch, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(ch, bg, OBJPROP_COLOR, C'90,90,90');
      ObjectSetInteger(ch, bg, OBJPROP_BGCOLOR, C'25,25,30');
      ObjectSetInteger(ch, bg, OBJPROP_WIDTH, 1);
      ObjectSetInteger(ch, bg, OBJPROP_BACK, false);
      ObjectSetInteger(ch, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ch, bg, OBJPROP_HIDDEN, false);
      ObjectSetInteger(ch, bg, OBJPROP_ZORDER, 0);
   }

   for(int i = 0; i < UNITED_PNL_MAX_LINES; i++)
   {
      const string nm = UnitedPnL_LineObjName(i);
      if(ObjectFind(ch, nm) >= 0)
         continue;
      if(!ObjectCreate(ch, nm, OBJ_LABEL, 0, 0, 0))
      {
         Print("UnitedPnL: line ", i, " ObjectCreate failed, err=", GetLastError());
         continue;
      }
      ObjectSetString(ch, nm, OBJPROP_FONT, "Arial");
      ObjectSetInteger(ch, nm, OBJPROP_FONTSIZE, UnitedPanel_FontSize);
      ObjectSetInteger(ch, nm, OBJPROP_BACK, false);
      ObjectSetInteger(ch, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(ch, nm, OBJPROP_HIDDEN, false);
      ObjectSetInteger(ch, nm, OBJPROP_ZORDER, 2);
   }
}

void UnitedPnL_ApplyGeometry()
{
   if(!UnitedPanel_Enable)
      return;
   const long ch = UnitedPnL_ChartId();
   const string bg = UnitedPnL_Obj("BG");
   if(ObjectFind(ch, bg) < 0)
      return;

   const int lineH = UnitedPanel_FontSize + 5;
   const int vis = MathMax(g_unitedPnL_visibleLineCount, 6);
   const int h = UnitedPanel_YMargin * 2 + lineH * vis;

   const ENUM_BASE_CORNER corner = (ENUM_BASE_CORNER)UnitedPanel_Corner;
   ObjectSetInteger(ch, bg, OBJPROP_CORNER, corner);
   ObjectSetInteger(ch, bg, OBJPROP_XDISTANCE, UnitedPanel_X);
   ObjectSetInteger(ch, bg, OBJPROP_YDISTANCE, UnitedPanel_Y);
   ObjectSetInteger(ch, bg, OBJPROP_XSIZE, UnitedPanel_Width);
   ObjectSetInteger(ch, bg, OBJPROP_YSIZE, MathMax(h, 80));

   const int baseX = UnitedPanel_X + UnitedPanel_XMargin;
   const int baseY = UnitedPanel_Y + UnitedPanel_YMargin;
   for(int i = 0; i < UNITED_PNL_MAX_LINES; i++)
   {
      const string nm = UnitedPnL_LineObjName(i);
      if(ObjectFind(ch, nm) < 0)
         continue;
      ObjectSetInteger(ch, nm, OBJPROP_CORNER, corner);
      ObjectSetInteger(ch, nm, OBJPROP_XDISTANCE, baseX);
      ObjectSetInteger(ch, nm, OBJPROP_YDISTANCE, baseY + i * lineH);
      ObjectSetInteger(ch, nm, OBJPROP_FONTSIZE, UnitedPanel_FontSize);
   }
}

void UnitedPnL_RefreshText()
{
   const long ch = UnitedPnL_ChartId();
   const string bg = UnitedPnL_Obj("BG");
   if(ObjectFind(ch, bg) < 0)
      return;

   UnitedPnL_CollectRows();

   const datetime now = TimeCurrent();
   const datetime y0 = UnitedPnL_StartOfYear(now);
   const datetime m0 = UnitedPnL_StartOfMonth(now);
   const string cur = AccountInfoString(ACCOUNT_CURRENCY);

   double yearPl[];
   double monthPl[];
   const bool histOk = UnitedPnL_ScanDealsOnce(yearPl, monthPl, y0, m0, now);
   const string histNote = histOk ? "" : " [hist fail: Toolbox>History]";

   double sumY = 0.0, sumM = 0.0, sumF = 0.0;

   string lines[];
   int n = 0;
   ArrayResize(lines, UNITED_PNL_MAX_LINES);

   lines[n++] = "United EA  " + cur + histNote;
   lines[n++] = UnitedPanel_ShowFloating
                ? "Y/M = closed deals | F = open P/L+swap"
                : "Y/M = closed deal P/L+swap+comm";
   lines[n++] = "----------------------------------";

   for(int r = 0; r < g_unitedPnLRowCount; r++)
   {
      const long mg = g_unitedPnLRows[r].magic;
      double yv = 0.0, mv = 0.0;
      if(histOk && r < ArraySize(yearPl))
         yv = yearPl[r];
      if(histOk && r < ArraySize(monthPl))
         mv = monthPl[r];
      const double fv = UnitedPanel_ShowFloating ? UnitedPnL_SumFloatingForMagic(mg) : 0.0;
      sumY += yv;
      sumM += mv;
      sumF += fv;
   }

   string tot = "TOTAL  Y:" + DoubleToString(sumY, 2) + "  M:" + DoubleToString(sumM, 2);
   if(UnitedPanel_ShowFloating)
      tot += "  F:" + DoubleToString(sumF, 2);
   lines[n++] = tot;
   lines[n++] = "----------------------------------";

   if(g_unitedPnLRowCount == 0)
      lines[n++] = "(no strategies enabled)";
   else
   {
      for(int r = 0; r < g_unitedPnLRowCount; r++)
      {
         if(n >= UNITED_PNL_MAX_LINES - 1)
            break;
         const long mg = g_unitedPnLRows[r].magic;
         double yv = 0.0, mv = 0.0;
         if(histOk && r < ArraySize(yearPl))
            yv = yearPl[r];
         if(histOk && r < ArraySize(monthPl))
            mv = monthPl[r];
         const double fv = UnitedPanel_ShowFloating ? UnitedPnL_SumFloatingForMagic(mg) : 0.0;

         lines[n++] = g_unitedPnLRows[r].name + " [" + IntegerToString((int)mg) + "]";
         string row2 = "  Y:" + DoubleToString(yv, 2) + "  M:" + DoubleToString(mv, 2);
         if(UnitedPanel_ShowFloating)
            row2 += "  F:" + DoubleToString(fv, 2);
         lines[n++] = row2;
      }
   }

   g_unitedPnL_visibleLineCount = n;

   color c = clrSilver;
   if(sumM > 0.0001)
      c = clrPaleGreen;
   else if(sumM < -0.0001)
      c = clrTomato;

   for(int i = 0; i < UNITED_PNL_MAX_LINES; i++)
   {
      const string nm = UnitedPnL_LineObjName(i);
      if(ObjectFind(ch, nm) < 0)
         continue;
      if(i < n)
      {
         ObjectSetString(ch, nm, OBJPROP_TEXT, lines[i]);
         ObjectSetInteger(ch, nm, OBJPROP_COLOR, c);
      }
      else
      {
         ObjectSetString(ch, nm, OBJPROP_TEXT, "");
      }
   }

   UnitedPnL_ApplyGeometry();
   ChartRedraw(ch);
}

void UnitedProfitPanelInit()
{
   if(!UnitedPanel_Enable)
      return;
   UnitedPnL_EnsureObjects();
   UnitedPnL_CollectRows();
   g_unitedPnL_visibleLineCount = 6;
   UnitedPnL_ApplyGeometry();
   UnitedPnL_RefreshText();
}

void UnitedProfitPanelDeinit()
{
   ObjectsDeleteAll(UnitedPnL_ChartId(), "UnitedPnL_");
}

void UnitedProfitPanelRefresh()
{
   if(!UnitedPanel_Enable)
      return;
   UnitedPnL_RefreshText();
}

void UnitedProfitPanelOnChartEvent(const int id)
{
   if(!UnitedPanel_Enable)
      return;
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      UnitedPnL_CollectRows();
      UnitedPnL_ApplyGeometry();
      ChartRedraw(UnitedPnL_ChartId());
   }
}

#endif
