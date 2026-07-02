//+------------------------------------------------------------------+
//|                              RSIScalpingAdaptiveOptimizer.mqh    |
//| Walk-forward: backtest prior month, pick best params for next   |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
struct RSIAdaptiveParams
{
   ENUM_TIMEFRAMES timeframe;
   int             rsi_period;
   double          rsi_overbought;
   double          rsi_oversold;
   double          rsi_target_buy;
   double          rsi_target_sell;
   int             bars_to_wait;

   bool IsValid() const
   {
      return (rsi_target_buy > rsi_oversold &&
              rsi_target_sell < rsi_overbought &&
              rsi_period >= 2 &&
              bars_to_wait >= 1);
   }

   string ToString() const
   {
      return StringFormat(
         "TF=%s RSI=%d OB=%.1f OS=%.1f TB=%.1f TS=%.1f Wait=%d",
         EnumToString(timeframe),
         rsi_period,
         rsi_overbought,
         rsi_oversold,
         rsi_target_buy,
         rsi_target_sell,
         bars_to_wait
      );
   }
};

//+------------------------------------------------------------------+
struct RSIAdaptiveMetrics
{
   double net_profit;
   int    total_trades;
   double win_rate;
   double profit_factor;
   double sharpe;
   double max_drawdown_pct;
   double score;
};

//+------------------------------------------------------------------+
struct RSIAdaptiveSearchConfig
{
   ENUM_TIMEFRAMES timeframe;
   int    rsi_period_min;
   int    rsi_period_max;
   int    rsi_period_step;
   double rsi_overbought_min;
   double rsi_overbought_max;
   double rsi_overbought_step;
   double rsi_oversold_min;
   double rsi_oversold_max;
   double rsi_oversold_step;
   double rsi_target_buy_min;
   double rsi_target_buy_max;
   double rsi_target_buy_step;
   double rsi_target_sell_min;
   double rsi_target_sell_max;
   double rsi_target_sell_step;
   int    bars_to_wait_min;
   int    bars_to_wait_max;
   int    bars_to_wait_step;
   int    min_trades;
   double lot_size;
   double initial_balance;
   int    slippage_points;
   double weight_sharpe;
   double weight_net_profit;
   double weight_profit_factor;
   double weight_max_dd;
   int    max_combinations;
};

//+------------------------------------------------------------------+
class CRSIAdaptiveOptimizer
{
private:
   string   m_symbol;
   datetime m_opt_start;
   datetime m_opt_end;
   int      m_combos_tested;

   double FillBuy(const double mid, const double point, const double half_spread, const int slippage_pts) const
   {
      return mid + half_spread + slippage_pts * point;
   }

   double FillSell(const double mid, const double point, const double half_spread, const int slippage_pts) const
   {
      return mid - half_spread - slippage_pts * point;
   }

   double CalcTradeProfit(const ENUM_ORDER_TYPE order_type,
                          const double volume,
                          const double entry,
                          const double exit_px) const
   {
      double profit = 0.0;
      if(!OrderCalcProfit(order_type, m_symbol, volume, entry, exit_px, profit))
         return 0.0;
      return profit;
   }

   int BarsPerYear(const ENUM_TIMEFRAMES tf) const
   {
      switch(tf)
      {
         case PERIOD_M1:  return 252 * 24 * 60;
         case PERIOD_M5:  return 252 * 24 * 12;
         case PERIOD_M15: return 252 * 24 * 4;
         case PERIOD_M30: return 252 * 24 * 2;
         case PERIOD_H1:  return 252 * 24;
         case PERIOD_H4:  return 252 * 6;
         case PERIOD_D1:  return 252;
         default:         return 252 * 24;
      }
   }

   double ComputeSharpe(const double &equity[], const int count, const ENUM_TIMEFRAMES tf) const
   {
      if(count < 12)
         return 0.0;

      double sum = 0.0;
      double sum_sq = 0.0;
      int n = 0;

      for(int i = 1; i < count; i++)
      {
         if(equity[i - 1] <= 0.0)
            continue;
         double r = (equity[i] - equity[i - 1]) / equity[i - 1];
         sum += r;
         sum_sq += r * r;
         n++;
      }

      if(n < 10)
         return 0.0;

      double mean = sum / n;
      double var = sum_sq / n - mean * mean;
      if(var <= 0.0)
         return 0.0;

      double std = MathSqrt(var);
      double scale = MathSqrt((double)BarsPerYear(tf) / (double)n);
      return mean / std * scale;
   }

   double ComputeScore(const RSIAdaptiveMetrics &m, const RSIAdaptiveSearchConfig &cfg) const
   {
      if(m.total_trades < cfg.min_trades || m.net_profit <= 0.0 || m.profit_factor < 1.05)
         return -1.0e12;

      double pf = MathMin(m.profit_factor, 4.0) / 4.0;
      return m.sharpe * cfg.weight_sharpe
           + (m.net_profit / 2000.0) * cfg.weight_net_profit
           + pf * cfg.weight_profit_factor
           - m.max_drawdown_pct * cfg.weight_max_dd;
   }

   bool BacktestParams(const RSIAdaptiveParams &params,
                       const RSIAdaptiveSearchConfig &cfg,
                       RSIAdaptiveMetrics &out) const
   {
      out.net_profit = 0.0;
      out.total_trades = 0;
      out.win_rate = 0.0;
      out.profit_factor = 0.0;
      out.sharpe = 0.0;
      out.max_drawdown_pct = 0.0;
      out.score = -1.0e12;

      if(!params.IsValid())
         return false;

      int bt_rsi_handle = iRSI(m_symbol, params.timeframe, params.rsi_period, PRICE_CLOSE);
      if(bt_rsi_handle == INVALID_HANDLE)
         return false;

      int end_shift = iBarShift(m_symbol, params.timeframe, m_opt_end, false);
      int start_shift = iBarShift(m_symbol, params.timeframe, m_opt_start, false);
      if(end_shift < 0)
         end_shift = 0;
      if(start_shift < 0)
      {
         IndicatorRelease(bt_rsi_handle);
         return false;
      }

      int bars_count = start_shift - end_shift + 1;
      if(bars_count < params.rsi_period + 5)
      {
         IndicatorRelease(bt_rsi_handle);
         return false;
      }

      double rsi[];
      double opens[];
      datetime times[];
      ArraySetAsSeries(rsi, false);
      ArraySetAsSeries(opens, false);
      ArraySetAsSeries(times, false);

      // Copy from oldest bar (start_shift): buffer[0]=oldest, buffer[n-1]=newest
      if(CopyBuffer(bt_rsi_handle, 0, start_shift, bars_count, rsi) < bars_count ||
         CopyOpen(m_symbol, params.timeframe, start_shift, bars_count, opens) < bars_count ||
         CopyTime(m_symbol, params.timeframe, start_shift, bars_count, times) < bars_count)
      {
         IndicatorRelease(bt_rsi_handle);
         return false;
      }

      IndicatorRelease(bt_rsi_handle);

      const double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      const long spread_pts = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      const double half_spread = spread_pts * point / 2.0;

      bool has_position = false;
      ENUM_ORDER_TYPE pos_type = ORDER_TYPE_BUY;
      double entry_px = 0.0;
      bool rsi_against = false;
      int bars_against = 0;

      double balance = cfg.initial_balance;
      double peak = balance;
      double max_dd_pct = 0.0;
      double gross_profit = 0.0;
      double gross_loss = 0.0;
      int wins = 0;

      double equity[];
      ArrayResize(equity, bars_count);
      int equity_count = 0;

      // Chronological loop: index 0 = oldest bar in window (matches Python run_backtest.py)
      for(int i = params.rsi_period + 2; i < bars_count; i++)
      {
         const double sig = rsi[i - 1];
         const double prev = rsi[i - 2];
         const double two = rsi[i - 3];
         const double mid = opens[i];

         if(has_position)
         {
            if(pos_type == ORDER_TYPE_BUY)
            {
               if(sig < params.rsi_oversold)
               {
                  if(!rsi_against)
                  {
                     rsi_against = true;
                     bars_against = 1;
                  }
                  else
                     bars_against++;

                  if(bars_against >= params.bars_to_wait)
                  {
                     const double exit_px = FillSell(mid, point, half_spread, cfg.slippage_points);
                     const double pnl = CalcTradeProfit(ORDER_TYPE_BUY, cfg.lot_size, entry_px, exit_px);
                     balance += pnl;
                     out.total_trades++;
                     if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
                     has_position = false;
                     rsi_against = false;
                     bars_against = 0;
                  }
               }
               else
               {
                  rsi_against = false;
                  bars_against = 0;
                  if(sig >= params.rsi_target_buy)
                  {
                     const double exit_px = FillSell(mid, point, half_spread, cfg.slippage_points);
                     const double pnl = CalcTradeProfit(ORDER_TYPE_BUY, cfg.lot_size, entry_px, exit_px);
                     balance += pnl;
                     out.total_trades++;
                     if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
                     has_position = false;
                  }
               }
            }
            else
            {
               if(sig > params.rsi_overbought)
               {
                  if(!rsi_against)
                  {
                     rsi_against = true;
                     bars_against = 1;
                  }
                  else
                     bars_against++;

                  if(bars_against >= params.bars_to_wait)
                  {
                     const double exit_px = FillBuy(mid, point, half_spread, cfg.slippage_points);
                     const double pnl = CalcTradeProfit(ORDER_TYPE_SELL, cfg.lot_size, entry_px, exit_px);
                     balance += pnl;
                     out.total_trades++;
                     if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
                     has_position = false;
                     rsi_against = false;
                     bars_against = 0;
                  }
               }
               else
               {
                  rsi_against = false;
                  bars_against = 0;
                  if(sig <= params.rsi_target_sell)
                  {
                     const double exit_px = FillBuy(mid, point, half_spread, cfg.slippage_points);
                     const double pnl = CalcTradeProfit(ORDER_TYPE_SELL, cfg.lot_size, entry_px, exit_px);
                     balance += pnl;
                     out.total_trades++;
                     if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
                     has_position = false;
                  }
               }
            }
         }

         if(!has_position)
         {
            if(two <= params.rsi_oversold && prev > params.rsi_oversold)
            {
               entry_px = FillBuy(mid, point, half_spread, cfg.slippage_points);
               pos_type = ORDER_TYPE_BUY;
               has_position = true;
               rsi_against = false;
               bars_against = 0;
            }
            else if(two >= params.rsi_overbought && prev < params.rsi_overbought)
            {
               entry_px = FillSell(mid, point, half_spread, cfg.slippage_points);
               pos_type = ORDER_TYPE_SELL;
               has_position = true;
               rsi_against = false;
               bars_against = 0;
            }
         }

         double mark = balance;
         if(has_position)
         {
            const double mark_mid = opens[i];
            if(pos_type == ORDER_TYPE_BUY)
               mark += CalcTradeProfit(ORDER_TYPE_BUY, cfg.lot_size, entry_px, FillSell(mark_mid, point, half_spread, 0));
            else
               mark += CalcTradeProfit(ORDER_TYPE_SELL, cfg.lot_size, entry_px, FillBuy(mark_mid, point, half_spread, 0));
         }

         if(equity_count < bars_count)
            equity[equity_count++] = mark;

         if(mark > peak)
            peak = mark;
         if(peak > 0.0)
         {
            const double dd = (peak - mark) / peak * 100.0;
            if(dd > max_dd_pct)
               max_dd_pct = dd;
         }
      }

      if(has_position)
      {
         const double mid = opens[bars_count - 1];
         if(pos_type == ORDER_TYPE_BUY)
         {
            const double exit_px = FillSell(mid, point, half_spread, cfg.slippage_points);
            const double pnl = CalcTradeProfit(ORDER_TYPE_BUY, cfg.lot_size, entry_px, exit_px);
            balance += pnl;
            out.total_trades++;
            if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
         }
         else
         {
            const double exit_px = FillBuy(mid, point, half_spread, cfg.slippage_points);
            const double pnl = CalcTradeProfit(ORDER_TYPE_SELL, cfg.lot_size, entry_px, exit_px);
            balance += pnl;
            out.total_trades++;
            if(pnl >= 0.0) { gross_profit += pnl; wins++; } else gross_loss += MathAbs(pnl);
         }
      }

      out.net_profit = balance - cfg.initial_balance;
      out.max_drawdown_pct = max_dd_pct;
      out.win_rate = (out.total_trades > 0) ? (100.0 * wins / out.total_trades) : 0.0;
      out.profit_factor = (gross_loss > 0.0) ? (gross_profit / gross_loss) : (gross_profit > 0.0 ? 999.0 : 0.0);
      out.sharpe = ComputeSharpe(equity, equity_count, params.timeframe);
      out.score = ComputeScore(out, cfg);
      return true;
   }

public:
   CRSIAdaptiveOptimizer() : m_combos_tested(0) {}

   static void PreviousCalendarMonth(const datetime now, datetime &month_start, datetime &month_end)
   {
      MqlDateTime dt;
      TimeToStruct(now, dt);
      datetime this_month_start = StringToTime(StringFormat("%04d.%02d.01 00:00", dt.year, dt.mon));
      month_end = this_month_start - 1;

      TimeToStruct(month_end, dt);
      month_start = StringToTime(StringFormat("%04d.%02d.01 00:00", dt.year, dt.mon));
   }

   static int MonthKey(const datetime t)
   {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return dt.year * 100 + dt.mon;
   }

   bool Optimize(const string symbol,
                 const datetime opt_start,
                 const datetime opt_end,
                 const RSIAdaptiveParams &fallback,
                 const RSIAdaptiveSearchConfig &cfg,
                 RSIAdaptiveParams &best_out,
                 RSIAdaptiveMetrics &best_metrics_out)
   {
      m_symbol = symbol;
      m_opt_start = opt_start;
      m_opt_end = opt_end;
      m_combos_tested = 0;

      best_out = fallback;
      best_metrics_out.net_profit = 0.0;
      best_metrics_out.total_trades = 0;
      best_metrics_out.win_rate = 0.0;
      best_metrics_out.profit_factor = 0.0;
      best_metrics_out.sharpe = 0.0;
      best_metrics_out.max_drawdown_pct = 0.0;
      best_metrics_out.score = -1.0e12;

      RSIAdaptiveMetrics fallback_metrics;
      if(BacktestParams(fallback, cfg, fallback_metrics))
      {
         if(fallback_metrics.score > best_metrics_out.score)
         {
            best_out = fallback;
            best_metrics_out = fallback_metrics;
         }
         m_combos_tested++;
      }

      bool stop_search = false;
      for(int rp = cfg.rsi_period_min; rp <= cfg.rsi_period_max && !stop_search; rp += cfg.rsi_period_step)
      {
         for(double ob = cfg.rsi_overbought_min; ob <= cfg.rsi_overbought_max + 0.001 && !stop_search; ob += cfg.rsi_overbought_step)
         {
            for(double os = cfg.rsi_oversold_min; os <= cfg.rsi_oversold_max + 0.001 && !stop_search; os += cfg.rsi_oversold_step)
            {
               for(double tb = cfg.rsi_target_buy_min; tb <= cfg.rsi_target_buy_max + 0.001 && !stop_search; tb += cfg.rsi_target_buy_step)
               {
                  for(double ts = cfg.rsi_target_sell_min; ts <= cfg.rsi_target_sell_max + 0.001 && !stop_search; ts += cfg.rsi_target_sell_step)
                  {
                     for(int bw = cfg.bars_to_wait_min; bw <= cfg.bars_to_wait_max && !stop_search; bw += cfg.bars_to_wait_step)
                     {
                        if(m_combos_tested >= cfg.max_combinations)
                        {
                           stop_search = true;
                           break;
                        }

                        RSIAdaptiveParams p;
                        p.timeframe = cfg.timeframe;
                        p.rsi_period = rp;
                        p.rsi_overbought = ob;
                        p.rsi_oversold = os;
                        p.rsi_target_buy = tb;
                        p.rsi_target_sell = ts;
                        p.bars_to_wait = bw;

                        if(!p.IsValid())
                           continue;

                        RSIAdaptiveMetrics m;
                        if(!BacktestParams(p, cfg, m))
                           continue;

                        m_combos_tested++;
                        if(m.score > best_metrics_out.score)
                        {
                           best_out = p;
                           best_metrics_out = m;
                        }
                     }
                  }
               }
            }
         }
      }

      PrintFormat("[Adaptive] %s tested %d combos | window %s -> %s",
                  symbol,
                  m_combos_tested,
                  TimeToString(opt_start, TIME_DATE),
                  TimeToString(opt_end, TIME_DATE));
      PrintFormat("[Adaptive] Best score=%.4f net=$%.2f sharpe=%.2f PF=%.2f trades=%d DD=%.2f%% | %s",
                  best_metrics_out.score,
                  best_metrics_out.net_profit,
                  best_metrics_out.sharpe,
                  best_metrics_out.profit_factor,
                  best_metrics_out.total_trades,
                  best_metrics_out.max_drawdown_pct,
                  best_out.ToString());

      return (best_metrics_out.score > -1.0e11);
   }

   int CombosTested() const { return m_combos_tested; }
};
