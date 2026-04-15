//+------------------------------------------------------------------+
//| AdaptiveMonthlyRegime.mqh                                       |
//| Streak unit (input): closed calendar MONTHS or closed DAYS      |
//| (server time). Losing streak -> optional CANARY (next full month |
//| or next full day at InpAdaptiveCanaryLotMult). Canary P/L > 0 -> |
//| full size; else HARD PAUSE. CanaryLotMult==0 -> hard pause, no   |
//| canary. Per-strat DD lot cap still uses last closed *month* P/L. |
//| Include after all `input` blocks.                                |
//+------------------------------------------------------------------+
#ifndef ADAPTIVE_MONTHLY_REGIME_MQH
#define ADAPTIVE_MONTHLY_REGIME_MQH

#define UNITED_ADAPTIVE_N 13
#define UNITED_AD_MAX_DAY_BUCKETS 400

#define UNITED_AD_DARVAS      0
#define UNITED_AD_ES          1
#define UNITED_AD_RC          2
#define UNITED_AD_RM          3
#define UNITED_AD_RS_APPL     4
#define UNITED_AD_RS_BTC      5
#define UNITED_AD_RS_NVDA     6
#define UNITED_AD_RS_TSLA     7
#define UNITED_AD_RS_XAU      8
#define UNITED_AD_RRA_EUR     9
#define UNITED_AD_RRA_AUD     10
#define UNITED_AD_RSS         11
#define UNITED_AD_SUPEREMA    12

bool     g_adHardPaused[UNITED_ADAPTIVE_N];
bool     g_adCanaryWaiting[UNITED_ADAPTIVE_N];
bool     g_adCanaryActive[UNITED_ADAPTIVE_N];
datetime g_adCanaryMonthStart[UNITED_ADAPTIVE_N];
datetime g_adCanaryMonthEnd[UNITED_ADAPTIVE_N];
datetime g_adHardPauseUntil[UNITED_ADAPTIVE_N];
datetime g_adPostCanaryCooldownUntil[UNITED_ADAPTIVE_N];

double   g_adLastClosedMonthPl[UNITED_ADAPTIVE_N];

datetime g_unitedAdaptiveLastUpdate = 0;

string UnitedAdaptive_StratName(const int s)
{
   const string names[] =
   {
      "DarvasBox", "EMASlope", "RSICrossOver", "RM_MidPoint",
      "RS_Scalp_AAPL", "RS_Scalp_BTC", "RS_Scalp_NVDA", "RS_Scalp_TSLA", "RS_Scalp_XAU",
      "RRA_EURUSD", "RRA_AUDUSD", "SecretSauce", "SuperEMA"
   };
   if(s >= 0 && s < UNITED_ADAPTIVE_N)
      return names[s];
   return "?";
}

void UnitedAdaptive_Init()
{
   for(int i = 0; i < UNITED_ADAPTIVE_N; i++)
   {
      g_adHardPaused[i] = false;
      g_adCanaryWaiting[i] = false;
      g_adCanaryActive[i] = false;
      g_adCanaryMonthStart[i] = 0;
      g_adCanaryMonthEnd[i] = 0;
      g_adHardPauseUntil[i] = 0;
      g_adPostCanaryCooldownUntil[i] = 0;
      g_adLastClosedMonthPl[i] = 0.0;
   }
   g_unitedAdaptiveLastUpdate = 0;
}

datetime UnitedAdaptive_MonthStartInt(const int y, const int m)
{
   MqlDateTime d;
   d.year = y;
   d.mon = m;
   d.day = 1;
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   return StructToTime(d);
}

void UnitedAdaptive_NextYm(int &y, int &m)
{
   m++;
   if(m > 12)
   {
      m = 1;
      y++;
   }
}

void UnitedAdaptive_ClosedMonthYm(const int offsetFromLastComplete, int &y, int &m)
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int ly = now.year;
   int lm = now.mon - 1;
   if(lm < 1)
   {
      lm = 12;
      ly--;
   }
   for(int i = 0; i < offsetFromLastComplete; i++)
   {
      lm--;
      if(lm < 1)
      {
         lm = 12;
         ly--;
      }
   }
   y = ly;
   m = lm;
}

// Start of calendar day: offset 0 = yesterday 00:00 (last fully closed day), 1 = day before, ...
datetime UnitedAdaptive_ClosedDayStart(const int offsetFromLastCompleteDay)
{
   MqlDateTime n;
   TimeToStruct(TimeCurrent(), n);
   n.hour = 0;
   n.min = 0;
   n.sec = 0;
   const datetime today0 = StructToTime(n);
   return today0 - (datetime)((offsetFromLastCompleteDay + 1) * 86400);
}

// Bucket index 0 = yesterday. -1 = today (incomplete) or invalid.
int UnitedAdaptive_ClosedDayOffsetFromDealTime(const datetime dt)
{
   MqlDateTime d, n;
   TimeToStruct(dt, d);
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   const datetime dealDay0 = StructToTime(d);
   TimeToStruct(TimeCurrent(), n);
   n.hour = 0;
   n.min = 0;
   n.sec = 0;
   const datetime today0 = StructToTime(n);
   const long deltaSec = (long)(today0 - dealDay0);
   if(deltaSec < 86400L)
      return -1;
   const int daysAgo = (int)(deltaSec / 86400L);
   return daysAgo - 1;
}

datetime UnitedAdaptive_AddMonthsWallClock(const datetime dt0, const int months)
{
   MqlDateTime t;
   TimeToStruct(dt0, t);
   for(int i = 0; i < months; i++)
   {
      t.mon++;
      if(t.mon > 12)
      {
         t.mon = 1;
         t.year++;
      }
   }
   return StructToTime(t);
}

bool UnitedAdaptive_RMDealMatches(const long mg)
{
   if(EnableRSIMidPointHijack)
   {
      if(RM_InpEnableRSIFollow && mg == (long)RM_InpMagicNumberRSIFollow)
         return true;
      if(RM_InpEnableRSIReverse && mg == (long)RM_InpMagicNumberRSIReverse)
         return true;
      if(RM_InpEnableEMACross && mg == (long)RM_InpMagicNumberEMACross)
         return true;
   }
   return false;
}

bool UnitedAdaptive_DealBelongsToStrat(const int s, const long mg)
{
   if(s == UNITED_AD_DARVAS)
      return EnableDarvasBox && mg == (long)DB_MagicNumber;
   if(s == UNITED_AD_ES)
      return EnableEMASlopeDistance && mg == (long)ES_MagicNumber;
   if(s == UNITED_AD_RC)
      return EnableRSICrossOverReversal && mg == (long)RC_MagicNumber;
   if(s == UNITED_AD_RM)
      return UnitedAdaptive_RMDealMatches(mg);
   if(s == UNITED_AD_RS_APPL)
      return EnableRSIScalpingAPPL && mg == (long)RS_APPL_MagicNumber;
   if(s == UNITED_AD_RS_BTC)
      return EnableRSIScalpingBTCUSD && mg == (long)RS_BTCUSD_MagicNumber;
   if(s == UNITED_AD_RS_NVDA)
      return EnableRSIScalpingNVDA && mg == (long)RS_NVDA_MagicNumber;
   if(s == UNITED_AD_RS_TSLA)
      return EnableRSIScalpingTSLA && mg == (long)RS_TSLA_MagicNumber;
   if(s == UNITED_AD_RS_XAU)
      return EnableRSIScalpingXAUUSD && mg == (long)RS_XAUUSD_MagicNumber;
   if(s == UNITED_AD_RRA_EUR)
      return EnableRSIReversalEURUSD && mg == (long)RRA_EURUSD_MagicNumber;
   if(s == UNITED_AD_RRA_AUD)
      return EnableRSIReversalAUDUSD && mg == (long)RRA_AUDUSD_MagicNumber;
   if(s == UNITED_AD_RSS)
      return EnableRSISecretSauceXAUUSD && mg == (long)RSS_XAUUSD_MagicNumber;
   if(s == UNITED_AD_SUPEREMA)
      return EnableSuperEMA && mg == (long)SE_MagicNumber;
   return false;
}

double UnitedAdaptive_SumStratDealsRange(const int s, const datetime from, const datetime to)
{
   if(from >= to)
      return 0.0;
   if(!HistorySelect(from, to))
      return 0.0;
   double sum = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      const long mg = (long)HistoryDealGetInteger(t, DEAL_MAGIC);
      if(!UnitedAdaptive_DealBelongsToStrat(s, mg))
         continue;
      sum += HistoryDealGetDouble(t, DEAL_PROFIT);
      sum += HistoryDealGetDouble(t, DEAL_SWAP);
      sum += HistoryDealGetDouble(t, DEAL_COMMISSION);
   }
   return sum;
}

void UnitedAdaptive_StartCanaryWait(const int s)
{
   if(InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY)
   {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      t.hour = 0;
      t.min = 0;
      t.sec = 0;
      const datetime today0 = StructToTime(t);
      g_adCanaryMonthStart[s] = today0 + 86400;
      g_adCanaryMonthEnd[s] = g_adCanaryMonthStart[s] + 86400;
      g_adCanaryWaiting[s] = true;
      g_adCanaryActive[s] = false;
      Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
            " -> CANARY WAIT until ", TimeToString(g_adCanaryMonthStart[s], TIME_DATE),
            " then 1 day at lot x ", DoubleToString(InpAdaptiveCanaryLotMult, 4));
      return;
   }
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.mon++;
   if(t.mon > 12)
   {
      t.mon = 1;
      t.year++;
   }
   t.day = 1;
   t.hour = 0;
   t.min = 0;
   t.sec = 0;
   g_adCanaryMonthStart[s] = StructToTime(t);
   int ey = t.year;
   int em = t.mon;
   UnitedAdaptive_NextYm(ey, em);
   g_adCanaryMonthEnd[s] = UnitedAdaptive_MonthStartInt(ey, em);
   g_adCanaryWaiting[s] = true;
   g_adCanaryActive[s] = false;
   Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
         " -> CANARY WAIT until ", TimeToString(g_adCanaryMonthStart[s], TIME_DATE),
         " then 1 month at lot x ", DoubleToString(InpAdaptiveCanaryLotMult, 4));
}

void UnitedAdaptive_TryExpireHardPauses()
{
   if(InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY)
   {
      if(InpAdaptiveHardRetryDays <= 0)
         return;
   }
   else if(InpAdaptiveHardRetryMonths <= 0)
      return;

   const datetime now = TimeCurrent();
   for(int s = 0; s < UNITED_ADAPTIVE_N; s++)
   {
      if(!g_adHardPaused[s])
         continue;
      if(g_adHardPauseUntil[s] > 0 && now >= g_adHardPauseUntil[s])
      {
         g_adHardPaused[s] = false;
         g_adHardPauseUntil[s] = 0;
         if(InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY)
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                  " hard pause RETRY (after ", InpAdaptiveHardRetryDays, " d)");
         else
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                  " hard pause RETRY (after ", InpAdaptiveHardRetryMonths, " mo)");
      }
   }
}

void UnitedAdaptive_ProcessCanaryTransitions()
{
   if(!InpAdaptiveEnable)
      return;

   UnitedAdaptive_TryExpireHardPauses();

   const datetime now = TimeCurrent();
   for(int s = 0; s < UNITED_ADAPTIVE_N; s++)
   {
      if(g_adCanaryWaiting[s] && !g_adCanaryActive[s] && now >= g_adCanaryMonthStart[s])
      {
         g_adCanaryWaiting[s] = false;
         g_adCanaryActive[s] = true;
         if(InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY)
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s), " CANARY ACTIVE (probation day)");
         else
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s), " CANARY ACTIVE (probation month)");
      }

      if(g_adCanaryActive[s] && now >= g_adCanaryMonthEnd[s])
      {
         const double pl = UnitedAdaptive_SumStratDealsRange(s, g_adCanaryMonthStart[s], g_adCanaryMonthEnd[s]);
         g_adCanaryActive[s] = false;
         g_adCanaryWaiting[s] = false;
         if(pl > 0.0)
         {
            if(InpAdaptivePostCanaryCooldownDays > 0)
               g_adPostCanaryCooldownUntil[s] = TimeCurrent() + InpAdaptivePostCanaryCooldownDays * 86400;
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                  " canary OK P/L=", DoubleToString(pl, 2), " -> full size");
         }
         else
         {
            g_adHardPaused[s] = true;
            if(InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY)
            {
               if(InpAdaptiveHardRetryDays > 0)
                  g_adHardPauseUntil[s] = now + (datetime)InpAdaptiveHardRetryDays * 86400;
               Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                     " canary FAIL P/L=", DoubleToString(pl, 2), " -> HARD PAUSE",
                     (InpAdaptiveHardRetryDays > 0 ? " (auto-retry later)" : ""));
            }
            else
            {
               if(InpAdaptiveHardRetryMonths > 0)
                  g_adHardPauseUntil[s] = UnitedAdaptive_AddMonthsWallClock(now, InpAdaptiveHardRetryMonths);
               Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                     " canary FAIL P/L=", DoubleToString(pl, 2), " -> HARD PAUSE",
                     (InpAdaptiveHardRetryMonths > 0 ? " (auto-retry later)" : ""));
            }
         }
      }
   }
}

bool UnitedAdaptive_StratLastMonthIsLosing(const int s)
{
   if(s < 0 || s >= UNITED_ADAPTIVE_N)
      return false;
   const double thr = MathMax(0.0, InpDdLotCapStratLossThreshold);
   return g_adLastClosedMonthPl[s] < -thr;
}

void UnitedAdaptive_RecomputeStreaks()
{
   const bool needMonthPlCap = InpDdLotCapEnable && InpDdLotCapPerStratEnable;
   const bool adaptMonth = InpAdaptiveEnable && InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_MONTH;
   const bool adaptDay = InpAdaptiveEnable && InpAdaptiveStreakUnit == ADAPTIVE_STREAK_BY_DAY;

   int nMonthOff = 0;
   int streakReqM = 1;
   if(adaptMonth)
   {
      streakReqM = MathMax(1, InpAdaptiveRedStreak);
      const int L = MathMax(InpAdaptiveLookbackMonths, streakReqM + 1);
      nMonthOff = MathMin(L, 63);
   }
   else if(needMonthPlCap)
      nMonthOff = 2;

   int nDayOff = 0;
   int streakReqD = 1;
   if(adaptDay)
   {
      streakReqD = MathMax(1, InpAdaptiveRedStreak);
      const int L = MathMax(InpAdaptiveLookbackDays, streakReqD + 1);
      nDayOff = MathMin(L, UNITED_AD_MAX_DAY_BUCKETS);
   }

   if(nMonthOff == 0 && nDayOff == 0)
      return;

   const datetime to = TimeCurrent() + 60;
   datetime from = to;
   if(nMonthOff > 0)
   {
      int oy = 0, om = 0;
      UnitedAdaptive_ClosedMonthYm(nMonthOff - 1, oy, om);
      const datetime mf = UnitedAdaptive_MonthStartInt(oy, om);
      if(mf < from)
         from = mf;
   }
   if(nDayOff > 0)
   {
      const datetime df = UnitedAdaptive_ClosedDayStart(nDayOff - 1);
      if(df < from)
         from = df;
   }

   if(from >= to || !HistorySelect(from, to))
      return;

   double monthBuck[UNITED_ADAPTIVE_N][64];
   double dayBuck[UNITED_ADAPTIVE_N][UNITED_AD_MAX_DAY_BUCKETS];
   for(int s = 0; s < UNITED_ADAPTIVE_N; s++)
   {
      for(int o = 0; o < 64; o++)
         monthBuck[s][o] = 0.0;
      for(int o = 0; o < UNITED_AD_MAX_DAY_BUCKETS; o++)
         dayBuck[s][o] = 0.0;
   }

   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;
      const long mg = (long)HistoryDealGetInteger(tk, DEAL_MAGIC);
      const datetime dt = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      const double pl = HistoryDealGetDouble(tk, DEAL_PROFIT)
                          + HistoryDealGetDouble(tk, DEAL_SWAP)
                          + HistoryDealGetDouble(tk, DEAL_COMMISSION);

      if(nMonthOff > 0)
      {
         for(int o = 0; o < nMonthOff; o++)
         {
            int y = 0, m = 0;
            UnitedAdaptive_ClosedMonthYm(o, y, m);
            const datetime ms = UnitedAdaptive_MonthStartInt(y, m);
            int ny = y, nm = m;
            UnitedAdaptive_NextYm(ny, nm);
            const datetime me = UnitedAdaptive_MonthStartInt(ny, nm);
            if(dt < ms || dt >= me)
               continue;

            if(EnableDarvasBox && mg == (long)DB_MagicNumber)
               monthBuck[UNITED_AD_DARVAS][o] += pl;
            if(EnableEMASlopeDistance && mg == (long)ES_MagicNumber)
               monthBuck[UNITED_AD_ES][o] += pl;
            if(EnableRSICrossOverReversal && mg == (long)RC_MagicNumber)
               monthBuck[UNITED_AD_RC][o] += pl;
            if(UnitedAdaptive_RMDealMatches(mg))
               monthBuck[UNITED_AD_RM][o] += pl;
            if(EnableRSIScalpingAPPL && mg == (long)RS_APPL_MagicNumber)
               monthBuck[UNITED_AD_RS_APPL][o] += pl;
            if(EnableRSIScalpingBTCUSD && mg == (long)RS_BTCUSD_MagicNumber)
               monthBuck[UNITED_AD_RS_BTC][o] += pl;
            if(EnableRSIScalpingNVDA && mg == (long)RS_NVDA_MagicNumber)
               monthBuck[UNITED_AD_RS_NVDA][o] += pl;
            if(EnableRSIScalpingTSLA && mg == (long)RS_TSLA_MagicNumber)
               monthBuck[UNITED_AD_RS_TSLA][o] += pl;
            if(EnableRSIScalpingXAUUSD && mg == (long)RS_XAUUSD_MagicNumber)
               monthBuck[UNITED_AD_RS_XAU][o] += pl;
            if(EnableRSIReversalEURUSD && mg == (long)RRA_EURUSD_MagicNumber)
               monthBuck[UNITED_AD_RRA_EUR][o] += pl;
            if(EnableRSIReversalAUDUSD && mg == (long)RRA_AUDUSD_MagicNumber)
               monthBuck[UNITED_AD_RRA_AUD][o] += pl;
            if(EnableRSISecretSauceXAUUSD && mg == (long)RSS_XAUUSD_MagicNumber)
               monthBuck[UNITED_AD_RSS][o] += pl;
            if(EnableSuperEMA && mg == (long)SE_MagicNumber)
               monthBuck[UNITED_AD_SUPEREMA][o] += pl;
            break;
         }
      }

      if(nDayOff > 0)
      {
         const int dOff = UnitedAdaptive_ClosedDayOffsetFromDealTime(dt);
         if(dOff >= 0 && dOff < nDayOff)
         {
            if(EnableDarvasBox && mg == (long)DB_MagicNumber)
               dayBuck[UNITED_AD_DARVAS][dOff] += pl;
            if(EnableEMASlopeDistance && mg == (long)ES_MagicNumber)
               dayBuck[UNITED_AD_ES][dOff] += pl;
            if(EnableRSICrossOverReversal && mg == (long)RC_MagicNumber)
               dayBuck[UNITED_AD_RC][dOff] += pl;
            if(UnitedAdaptive_RMDealMatches(mg))
               dayBuck[UNITED_AD_RM][dOff] += pl;
            if(EnableRSIScalpingAPPL && mg == (long)RS_APPL_MagicNumber)
               dayBuck[UNITED_AD_RS_APPL][dOff] += pl;
            if(EnableRSIScalpingBTCUSD && mg == (long)RS_BTCUSD_MagicNumber)
               dayBuck[UNITED_AD_RS_BTC][dOff] += pl;
            if(EnableRSIScalpingNVDA && mg == (long)RS_NVDA_MagicNumber)
               dayBuck[UNITED_AD_RS_NVDA][dOff] += pl;
            if(EnableRSIScalpingTSLA && mg == (long)RS_TSLA_MagicNumber)
               dayBuck[UNITED_AD_RS_TSLA][dOff] += pl;
            if(EnableRSIScalpingXAUUSD && mg == (long)RS_XAUUSD_MagicNumber)
               dayBuck[UNITED_AD_RS_XAU][dOff] += pl;
            if(EnableRSIReversalEURUSD && mg == (long)RRA_EURUSD_MagicNumber)
               dayBuck[UNITED_AD_RRA_EUR][dOff] += pl;
            if(EnableRSIReversalAUDUSD && mg == (long)RRA_AUDUSD_MagicNumber)
               dayBuck[UNITED_AD_RRA_AUD][dOff] += pl;
            if(EnableRSISecretSauceXAUUSD && mg == (long)RSS_XAUUSD_MagicNumber)
               dayBuck[UNITED_AD_RSS][dOff] += pl;
            if(EnableSuperEMA && mg == (long)SE_MagicNumber)
               dayBuck[UNITED_AD_SUPEREMA][dOff] += pl;
         }
      }
   }

   if(nMonthOff > 0)
   {
      for(int s = 0; s < UNITED_ADAPTIVE_N; s++)
         g_adLastClosedMonthPl[s] = monthBuck[s][0];
   }

   if(!InpAdaptiveEnable)
      return;

   const double thr = MathMax(0.0, InpAdaptiveRedThreshold);
   const bool useDay = adaptDay;
   const int streakReq = useDay ? streakReqD : streakReqM;
   const int nOff = useDay ? nDayOff : nMonthOff;

   for(int s = 0; s < UNITED_ADAPTIVE_N; s++)
   {
      if(g_adHardPaused[s])
         continue;
      if(g_adCanaryActive[s] || g_adCanaryWaiting[s])
      {
         int consecOk = 0;
         for(int o = 0; o < streakReq && o < nOff; o++)
         {
            const double bpl = useDay ? dayBuck[s][o] : monthBuck[s][o];
            if(bpl < -thr)
               consecOk++;
            else
               break;
         }
         const bool streakBad = (consecOk >= streakReq);
         if(!streakBad && g_adCanaryWaiting[s] && !g_adCanaryActive[s])
         {
            g_adCanaryWaiting[s] = false;
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s), " canary wait CANCELLED (streak cleared)");
         }
         continue;
      }

      int consec = 0;
      for(int o = 0; o < streakReq && o < nOff; o++)
      {
         const double bpl = useDay ? dayBuck[s][o] : monthBuck[s][o];
         if(bpl < -thr)
            consec++;
         else
            break;
      }
      const bool streakBad = (consec >= streakReq);
      if(!streakBad)
         continue;

      const bool prevHard = g_adHardPaused[s];
      if(InpAdaptiveCanaryLotMult > 0.0)
      {
         if(!g_adCanaryWaiting[s] && !g_adCanaryActive[s])
         {
            if(g_adPostCanaryCooldownUntil[s] > TimeCurrent())
               continue;
            UnitedAdaptive_StartCanaryWait(s);
         }
      }
      else
      {
         g_adHardPaused[s] = true;
         if(!prevHard && useDay && InpAdaptiveHardRetryDays > 0)
            g_adHardPauseUntil[s] = TimeCurrent() + (datetime)InpAdaptiveHardRetryDays * 86400;
         else if(!prevHard && !useDay && InpAdaptiveHardRetryMonths > 0)
            g_adHardPauseUntil[s] = UnitedAdaptive_AddMonthsWallClock(TimeCurrent(), InpAdaptiveHardRetryMonths);
         if(!prevHard)
            Print("AdaptiveRegime: ", UnitedAdaptive_StratName(s),
                  " HARD PAUSE (streak, canary disabled)");
      }
   }
}

void UnitedAdaptive_UpdateIfDue()
{
   if(!InpAdaptiveEnable && (!InpDdLotCapEnable || !InpDdLotCapPerStratEnable))
   {
      UnitedAdaptive_Init();
      return;
   }

   int everySec = 3600;
   if(InpAdaptiveEnable)
      everySec = MathMin(everySec, MathMax(60, InpAdaptiveUpdateSeconds));
   if(InpDdLotCapEnable && InpDdLotCapPerStratEnable)
      everySec = MathMin(everySec, MathMax(60, InpDdLotCapUpdateSeconds));

   if(g_unitedAdaptiveLastUpdate > 0 && (TimeCurrent() - g_unitedAdaptiveLastUpdate) < everySec)
      return;

   g_unitedAdaptiveLastUpdate = TimeCurrent();
   UnitedAdaptive_RecomputeStreaks();
}

double UnitedAdaptive_GetLotMult(const int stratId)
{
   if(stratId < 0 || stratId >= UNITED_ADAPTIVE_N)
      return 1.0;
   if(!InpAdaptiveEnable)
      return 1.0;
   if(g_adCanaryActive[stratId])
      return MathMax(0.0, InpAdaptiveCanaryLotMult);
   return 1.0;
}

bool UnitedAdaptive_StrategyActive(const int stratId)
{
   if(stratId < 0 || stratId >= UNITED_ADAPTIVE_N)
      return true;
   if(!InpAdaptiveEnable)
      return true;
   if(g_adHardPaused[stratId])
      return false;
   if(g_adCanaryWaiting[stratId] && !g_adCanaryActive[stratId])
      return false;
   return true;
}

#endif
