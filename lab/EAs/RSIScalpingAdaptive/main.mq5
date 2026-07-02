//+------------------------------------------------------------------+
//|                                    RSIScalpingAdaptiveXAUUSD.mq5 |
//|  RSI Scalping with monthly walk-forward parameter adaptation     |
//|  Backtests prior calendar month on each new month, applies best  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property description "XAUUSD RSI Scalping — monthly walk-forward adaptive params"

#include <Trade\Trade.mqh>
#include "MagicNumberHelpers.mqh"
#include "RSIScalpingAdaptiveOptimizer.mqh"

//--- Fallback defaults (XAUUSD 123.set baseline)
input group "=== Fallback / seed parameters ==="
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1;
input int                  RSI_Period = 17;
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE;
input double               RSI_Overbought = 6.0;
input double               RSI_Oversold = 74.0;
input double               RSI_Target_Buy = 79.0;
input double               RSI_Target_Sell = 24.0;
input int                  BarsToWait = 12;

input group "=== Execution ==="
input double               LotSize = 0.1;
input int                  MagicNumber = 129102315;
input int                  Slippage = 3;

input group "=== Adaptive walk-forward ==="
input bool                 EnableAdaptive = true;
input int                  OptimizationCheckSeconds = 3600; // Timer interval for new-month check
input int                  MinTradesForSelection = 8;
input int                  MaxCombinations = 600;
input double               BacktestInitialBalance = 10000.0;
input double               ScoreWeightSharpe = 0.35;
input double               ScoreWeightNetProfit = 0.25;
input double               ScoreWeightProfitFactor = 0.15;
input double               ScoreWeightMaxDD = 0.10;

input group "=== XAUUSD search ranges ==="
input int                  Search_RSI_Period_Min = 12;
input int                  Search_RSI_Period_Max = 18;
input int                  Search_RSI_Period_Step = 2;
input double               Search_RSI_Overbought_Min = 65.0;
input double               Search_RSI_Overbought_Max = 77.0;
input double               Search_RSI_Overbought_Step = 3.0;
input double               Search_RSI_Oversold_Min = 50.0;
input double               Search_RSI_Oversold_Max = 63.0;
input double               Search_RSI_Oversold_Step = 3.0;
input double               Search_RSI_Target_Buy_Min = 75.0;
input double               Search_RSI_Target_Buy_Max = 86.0;
input double               Search_RSI_Target_Buy_Step = 3.0;
input double               Search_RSI_Target_Sell_Min = 50.0;
input double               Search_RSI_Target_Sell_Max = 63.0;
input double               Search_RSI_Target_Sell_Step = 3.0;
input int                  Search_BarsToWait_Min = 1;
input int                  Search_BarsToWait_Max = 4;
input int                  Search_BarsToWait_Step = 1;

CTrade trade;
CRSIAdaptiveOptimizer g_optimizer;

int rsi_handle = INVALID_HANDLE;
double rsi_buffer[];
double rsi_prev, rsi_current, rsi_two_bars_ago;

bool position_open = false;
ulong position_ticket = 0;
ENUM_POSITION_TYPE current_position_type = POSITION_TYPE_BUY;
datetime last_bar_time = 0;
bool rsi_against_position = false;
int bars_against_count = 0;

RSIAdaptiveParams g_active;
RSIAdaptiveMetrics g_last_metrics;
int g_applied_month_key = 0;
bool g_optimization_done = false;
bool g_optimizing = false;
string g_status_line = "";

//+------------------------------------------------------------------+
void SyncOpenPosition()
{
   if(!PositionExistsByMagic(_Symbol, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      position_ticket = ticket;
      position_open = true;
      current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return;
   }
}

//+------------------------------------------------------------------+
bool IsStrategyTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

//+------------------------------------------------------------------+
RSIAdaptiveParams BuildFallbackParams()
{
   RSIAdaptiveParams p;
   p.timeframe = TimeFrame;
   p.rsi_period = RSI_Period;
   p.rsi_overbought = RSI_Overbought;
   p.rsi_oversold = RSI_Oversold;
   p.rsi_target_buy = RSI_Target_Buy;
   p.rsi_target_sell = RSI_Target_Sell;
   p.bars_to_wait = BarsToWait;
   return p;
}

//+------------------------------------------------------------------+
RSIAdaptiveSearchConfig BuildSearchConfig()
{
   RSIAdaptiveSearchConfig cfg;
   cfg.timeframe = TimeFrame;
   cfg.rsi_period_min = Search_RSI_Period_Min;
   cfg.rsi_period_max = Search_RSI_Period_Max;
   cfg.rsi_period_step = MathMax(1, Search_RSI_Period_Step);
   cfg.rsi_overbought_min = Search_RSI_Overbought_Min;
   cfg.rsi_overbought_max = Search_RSI_Overbought_Max;
   cfg.rsi_overbought_step = Search_RSI_Overbought_Step;
   cfg.rsi_oversold_min = Search_RSI_Oversold_Min;
   cfg.rsi_oversold_max = Search_RSI_Oversold_Max;
   cfg.rsi_oversold_step = Search_RSI_Oversold_Step;
   cfg.rsi_target_buy_min = Search_RSI_Target_Buy_Min;
   cfg.rsi_target_buy_max = Search_RSI_Target_Buy_Max;
   cfg.rsi_target_buy_step = Search_RSI_Target_Buy_Step;
   cfg.rsi_target_sell_min = Search_RSI_Target_Sell_Min;
   cfg.rsi_target_sell_max = Search_RSI_Target_Sell_Max;
   cfg.rsi_target_sell_step = Search_RSI_Target_Sell_Step;
   cfg.bars_to_wait_min = Search_BarsToWait_Min;
   cfg.bars_to_wait_max = Search_BarsToWait_Max;
   cfg.bars_to_wait_step = MathMax(1, Search_BarsToWait_Step);
   cfg.min_trades = MinTradesForSelection;
   cfg.lot_size = LotSize;
   cfg.initial_balance = BacktestInitialBalance;
   cfg.slippage_points = Slippage;
   cfg.weight_sharpe = ScoreWeightSharpe;
   cfg.weight_net_profit = ScoreWeightNetProfit;
   cfg.weight_profit_factor = ScoreWeightProfitFactor;
   cfg.weight_max_dd = ScoreWeightMaxDD;
   cfg.max_combinations = MaxCombinations;
   return cfg;
}

//+------------------------------------------------------------------+
bool RecreateRsiHandle()
{
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);

   rsi_handle = iRSI(_Symbol, g_active.timeframe, g_active.rsi_period, RSI_Applied_Price);
   if(rsi_handle == INVALID_HANDLE)
   {
      Print("ERROR: failed to create RSI handle for ", g_active.ToString());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void UpdateStatusComment()
{
   g_status_line = StringFormat(
      "RSI Adaptive XAUUSD | month=%d | %s\n"
      "BT: net=$%.0f sharpe=%.2f PF=%.2f trades=%d DD=%.1f%% | combos=%d",
      g_applied_month_key,
      g_active.ToString(),
      g_last_metrics.net_profit,
      g_last_metrics.sharpe,
      g_last_metrics.profit_factor,
      g_last_metrics.total_trades,
      g_last_metrics.max_drawdown_pct,
      g_optimizer.CombosTested()
   );
   Comment(g_status_line);
}

//+------------------------------------------------------------------+
bool RunMonthlyOptimization(const string reason)
{
   if(g_optimizing)
      return true;

   g_optimizing = true;
   RSIAdaptiveParams fallback = BuildFallbackParams();
   RSIAdaptiveSearchConfig cfg = BuildSearchConfig();

   datetime opt_start, opt_end;
   CRSIAdaptiveOptimizer::PreviousCalendarMonth(TimeCurrent(), opt_start, opt_end);

   PrintFormat("[Adaptive] %s — optimizing on prior month (%s to %s)",
               reason,
               TimeToString(opt_start, TIME_DATE),
               TimeToString(opt_end, TIME_DATE));

   RSIAdaptiveParams best;
   RSIAdaptiveMetrics best_metrics;
   const bool ok = g_optimizer.Optimize(_Symbol, opt_start, opt_end, fallback, cfg, best, best_metrics);

   if(ok)
   {
      g_active = best;
      g_last_metrics = best_metrics;
   }
   else
   {
      Print("[Adaptive] Optimization found no valid combo — keeping fallback params");
      g_active = fallback;
      g_last_metrics = best_metrics;
   }

   g_applied_month_key = CRSIAdaptiveOptimizer::MonthKey(TimeCurrent());
   g_optimization_done = true;

   if(!RecreateRsiHandle())
   {
      g_optimizing = false;
      return false;
   }

   last_bar_time = 0;
   g_optimizing = false;
   UpdateStatusComment();
   return true;
}

//+------------------------------------------------------------------+
void CheckMonthlyOptimizationSchedule(const string reason)
{
   if(!EnableAdaptive || IsStrategyTester())
      return;

   const int month_key = CRSIAdaptiveOptimizer::MonthKey(TimeCurrent());
   if(!g_optimization_done || month_key != g_applied_month_key)
      RunMonthlyOptimization(reason);
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   ArraySetAsSeries(rsi_buffer, true);

   g_active = BuildFallbackParams();
   if(!RecreateRsiHandle())
      return INIT_FAILED;

   EventSetTimer(OptimizationCheckSeconds);

   // Strategy Tester / Optimization: use Inputs directly — no walk-forward grid search
   if(IsStrategyTester() || !EnableAdaptive)
   {
      g_active = BuildFallbackParams();
      g_optimization_done = true;
      g_applied_month_key = CRSIAdaptiveOptimizer::MonthKey(TimeCurrent());
      if(!RecreateRsiHandle())
         return INIT_FAILED;
      UpdateStatusComment();
      SyncOpenPosition();
      return INIT_SUCCEEDED;
   }

   if(!RunMonthlyOptimization("OnInit"))
      return INIT_FAILED;

   SyncOpenPosition();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   CheckMonthlyOptimizationSchedule("OnTimer");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Bars(_Symbol, g_active.timeframe) < g_active.rsi_period + 2)
      return;

   datetime current_bar_time = iTime(_Symbol, g_active.timeframe, 0);
   if(current_bar_time == last_bar_time)
      return;

   last_bar_time = current_bar_time;

   if(!UpdateRSI())
      return;

   CheckExistingPosition();

   if(!position_open && !PositionExistsByMagic(_Symbol, MagicNumber))
      CheckEntrySignals();

   UpdateStatusComment();
}

//+------------------------------------------------------------------+
bool UpdateRSI()
{
   if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_buffer) < 3)
      return false;

   rsi_current = rsi_buffer[0];
   rsi_prev = rsi_buffer[1];
   rsi_two_bars_ago = rsi_buffer[2];
   return true;
}

//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(!position_open)
      SyncOpenPosition();

   if(!position_open)
      return;

   if(!PositionSelectByTicketSymbolAndMagic(position_ticket, _Symbol, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }

   if(current_position_type == POSITION_TYPE_BUY)
   {
      if(rsi_current < g_active.rsi_oversold)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
            bars_against_count++;

         if(bars_against_count >= g_active.bars_to_wait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         if(rsi_current >= g_active.rsi_target_buy)
            ClosePosition();
      }
   }
   else if(current_position_type == POSITION_TYPE_SELL)
   {
      if(rsi_current > g_active.rsi_overbought)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
            bars_against_count++;

         if(bars_against_count >= g_active.bars_to_wait)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         if(rsi_current <= g_active.rsi_target_sell)
            ClosePosition();
      }
   }
}

//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   if(rsi_two_bars_ago <= g_active.rsi_oversold && rsi_prev > g_active.rsi_oversold)
      OpenBuyPosition();

   if(rsi_two_bars_ago >= g_active.rsi_overbought && rsi_prev < g_active.rsi_overbought)
      OpenSellPosition();
}

//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   if(PositionExistsByMagic(_Symbol, MagicNumber))
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI Adaptive Buy"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0 && PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, MagicNumber))
      {
         position_ticket = new_ticket;
         position_open = true;
         current_position_type = POSITION_TYPE_BUY;
      }
   }
}

//+------------------------------------------------------------------+
void OpenSellPosition()
{
   if(PositionExistsByMagic(_Symbol, MagicNumber))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "RSI Adaptive Sell"))
   {
      ulong new_ticket = trade.ResultOrder();
      if(new_ticket > 0 && PositionSelectByTicketSymbolAndMagic(new_ticket, _Symbol, MagicNumber))
      {
         position_ticket = new_ticket;
         position_open = true;
         current_position_type = POSITION_TYPE_SELL;
      }
   }
}

//+------------------------------------------------------------------+
void ClosePosition()
{
   if(ClosePositionByMagic(trade, _Symbol, MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
   }
   else
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
   }
}
