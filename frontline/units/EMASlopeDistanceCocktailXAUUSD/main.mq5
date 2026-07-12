//+------------------------------------------------------------------+
//|                                                 EMACrossOver.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#include <Trade\Trade.mqh>
#include "../_united/MagicNumberHelpers.mqh"
//--- Input Parameters — synced with Desktop 123.set (2026.05.13)
input int    EMA_Period = 85;           // EMA Period
input double PriceThreshold = 350.0;       // Price Movement Threshold in Pips
input double SlopeThreshold = 22.5;     // EMA Slope Threshold in Pips
input int    MonitoringTimeout = 340;   // Monitoring Time in Seconds
input double TrailingStop = 74.0;        // Trailing Stop in Pips
input double LotSize = 0.07;             // Trading Volume
input int    MagicNumber = 135790;        // Magic Number for Trades
input bool   UseSpreadAdjustment = true; // Use Spread Adjustment
input ENUM_TIMEFRAMES Timeframe = PERIOD_H1; // Timeframe for Analysis
input bool   UseBarData = true;          // Use Bar Data instead of Tick Data
input int    MaxTradesPerCrossover = 48;  // Maximum Trades per Crossover Event
input int    ProfitCheckBars = 78;       // Bars until Profit Check
input bool   CloseUnprofitableTrades = true; // Close Unprofitable Trades after X Bars
input bool   UseWeeklyADXFilter = true;  // Enable W1 ADX Trend Filter
input int    WeeklyADXPeriod = 28;       // ADX Period on W1
input double WeeklyADXMin = 25.0;        // Minimum ADX for Trend Release
input int    WeeklyADXBarShift = 8;      // 1=last closed W1 candle
input bool   WeeklyADXUseDirection = true; // Check +DI/-DI Direction

//--- Global Variables
int ema_handle;                          // EMA Indicator Handle
double ema_array[];                      // Array for EMA
datetime last_monitoring_time;           // Time of Last Monitoring
bool monitoring_active = false;          // Monitoring Status
bool price_trigger_active = false;       // Price Trigger Status
bool slope_trigger_active = false;       // Slope Trigger Status
int ticket = 0;                          // Trade Ticket
CTrade trade;                            // CTrade Object
int trades_in_current_crossover = 0;     // Number of Trades in Current Crossover
bool crossover_detected = false;          // Crossover Detected
datetime trade_open_time = 0;            // Time of Trade Opening

//+------------------------------------------------------------------+
//| Weekly ADX trend filter                                          |
//+------------------------------------------------------------------+
bool IsWeeklyADXTrendFavorable(ENUM_ORDER_TYPE order_type)
{
   if(!UseWeeklyADXFilter)
      return true;

   int adxShift = WeeklyADXBarShift;
   if(adxShift < 0)
      adxShift = 0;

   int adx_handle = iADX(_Symbol, PERIOD_W1, WeeklyADXPeriod);
   if(adx_handle == INVALID_HANDLE)
   {
      Print("TRACE: Weekly ADX Handle invalid - Filter blocks Entry");
      return false;
   }

   double adx_buf[], plus_di_buf[], minus_di_buf[];
   ArraySetAsSeries(adx_buf, true);
   ArraySetAsSeries(plus_di_buf, true);
   ArraySetAsSeries(minus_di_buf, true);

   bool ok_adx = (CopyBuffer(adx_handle, 0, adxShift, 1, adx_buf) > 0);
   bool ok_plus = (CopyBuffer(adx_handle, 1, adxShift, 1, plus_di_buf) > 0);
   bool ok_minus = (CopyBuffer(adx_handle, 2, adxShift, 1, minus_di_buf) > 0);
   IndicatorRelease(adx_handle);

   if(!ok_adx || !ok_plus || !ok_minus)
   {
      Print("TRACE: Weekly ADX Data not available - Filter blocks Entry");
      return false;
   }

   double adx_value = adx_buf[0];
   double plus_di = plus_di_buf[0];
   double minus_di = minus_di_buf[0];

   bool strength_ok = (adx_value >= WeeklyADXMin);
   bool direction_ok = true;
   if(WeeklyADXUseDirection)
   {
      if(order_type == ORDER_TYPE_BUY)
         direction_ok = (plus_di > minus_di);
      else
         direction_ok = (minus_di > plus_di);
   }

   Print("TRACE: Weekly ADX Filter | ADX=", DoubleToString(adx_value, 2),
         " +DI=", DoubleToString(plus_di, 2),
         " -DI=", DoubleToString(minus_di, 2),
         " strength_ok=", strength_ok,
         " direction_ok=", direction_ok);

   return (strength_ok && direction_ok);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Configure CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Create EMA indicator handle
   ema_handle = iMA(_Symbol, Timeframe, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(ema_handle == INVALID_HANDLE)
   {
      Print("Error creating EMA Indicator");
      return(INIT_FAILED);
   }
   
   //--- Initialize arrays
   ArraySetAsSeries(ema_array, true);
   
   //--- Fill arrays with current values
   CalculateEMA();
   
   Print("EMA EA initialized - Period: ", EMA_Period, " Timeframe: ", EnumToString(Timeframe), " Handle: ", ema_handle);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Release indicator handle
   if(ema_handle != INVALID_HANDLE)
   {
      IndicatorRelease(ema_handle);
   }
   
   Print("EA terminated - Reason: ", reason);
}
   
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Use bar data or tick data
   if(UseBarData)
   {
      //--- Execute only on new bars
      static datetime last_bar_time = 0;
      datetime current_bar_time = iTime(_Symbol, Timeframe, 0);
      
      if(current_bar_time == last_bar_time)
      {
         return; // No new bar, do nothing
      }
      
      last_bar_time = current_bar_time;
   }
   
   //--- Calculate EMA values
   CalculateEMA();
   
   //--- Debug: Output current values
   if(ArraySize(ema_array) > 0)
   {
      double current_close = iClose(_Symbol, Timeframe, 0);
      double current_ema = ema_array[0];
      double previous_ema = ema_array[1];
      double price_distance = MathAbs(current_close - current_ema) / _Point;
      double slope = (current_ema - previous_ema) / _Point;
      
      if(UseBarData)
      {
         Print("=== DEBUG INFO (New Bar) ===");
         Print("Bar Time: ", TimeToString(iTime(_Symbol, Timeframe, 0)));
      }
      else
      {
         Print("=== DEBUG INFO (Tick) ===");
      }
      
      Print("Current Close: ", current_close);
      Print("EMA: ", current_ema);
      Print("Price Distance: ", price_distance, " Pips");
      Print("EMA Slope: ", slope, " Pips");
      Print("Difference Close-EMA: ", current_close - current_ema);
      Print("Price Trigger: ", price_trigger_active, " Slope Trigger: ", slope_trigger_active);
      Print("Monitoring Active: ", monitoring_active);
      Print("Position Open: ", PositionExistsByMagic(_Symbol, MagicNumber));
      Print("Trades in Current Crossover: ", trades_in_current_crossover, "/", MaxTradesPerCrossover);
      Print("==================");
   }
   
   //--- Check monitoring
   if(monitoring_active)
   {
      if(UseBarData)
      {
         // Bar-based monitoring time
         int bars_since_monitoring = iBarShift(_Symbol, Timeframe, last_monitoring_time);
         int timeout_bars = (int)(MonitoringTimeout / PeriodSeconds(Timeframe));
         
         if(bars_since_monitoring > timeout_bars)
         {
            monitoring_active = false;
            price_trigger_active = false;
            slope_trigger_active = false;
            Print("Monitoring Stopped - Bar-based Timeout (", bars_since_monitoring, " Bars)");
         }
      }
      else
      {
         // Tick-based monitoring time
         if(TimeCurrent() - last_monitoring_time > MonitoringTimeout)
         {
            monitoring_active = false;
            price_trigger_active = false;
            slope_trigger_active = false;
            Print("Monitoring Stopped - Tick-based Timeout");
         }
      }
   }
   
   //--- Check trigger conditions
   CheckTriggers();
   
   //--- Trade Management
   ManageTrades();
}

//+------------------------------------------------------------------+
//| EMA Calculation                                                 |
//+------------------------------------------------------------------+
void CalculateEMA()
{
   //--- Copy EMA values from indicator
   int copied = CopyBuffer(ema_handle, 0, 0, 3, ema_array);
   
   if(copied <= 0)
   {
      Print("TRACE: Error copying EMA Values - Copied: ", copied);
      return;
   }
   
   Print("TRACE: EMA Values copied: ", copied, " Bars");
   Print("TRACE: EMA [0]: ", ema_array[0], " [1]: ", ema_array[1], " [2]: ", ema_array[2]);
}

//+------------------------------------------------------------------+
//| Check trigger conditions                                        |
//+------------------------------------------------------------------+
void CheckTriggers()
{
   if(ArraySize(ema_array) < 2)
   {
      Print("TRACE: Array too small - Size: ", ArraySize(ema_array));
      return;
   }
   
   //--- Current values
   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double current_close = iClose(_Symbol, Timeframe, 0);
   double pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   
   //--- EMA values in variables
   double current_ema = ema_array[0];
   double previous_ema = ema_array[1];
   
   //--- EMA Crossover Detection
   // Check if price crosses EMA
   static double last_close = 0;
   static double last_ema = 0;
   
   if(last_close != 0 && last_ema != 0)
   {
      bool crossover_bullish = (last_close <= last_ema) && (current_close > current_ema);
      bool crossover_bearish = (last_close >= last_ema) && (current_close < current_ema);
      
      //--- New crossover event detected
      if(crossover_bullish || crossover_bearish)
      {
         trades_in_current_crossover = 0; // Reset trade counter
         Print("TRACE: EMA Crossover detected - ", (crossover_bullish ? "BULLISH" : "BEARISH"), " - Trade counter reset");
         Print("TRACE: Before: Close=", last_close, " EMA=", last_ema, " Now: Close=", current_close, " EMA=", current_ema);
      }
   }
   
   //--- Save current values for next comparison
   last_close = current_close;
   last_ema = current_ema;
   
   //--- Check price action to EMA
   double price_distance = MathAbs(current_close - current_ema) / _Point / pips_multiplier;
   
   Print("TRACE: Price Distance: ", price_distance, " Pips (Threshold: ", PriceThreshold, ")");
   Print("TRACE: Close: ", current_close, " EMA: ", current_ema);
   Print("TRACE: Trades in Current Crossover: ", trades_in_current_crossover, "/", MaxTradesPerCrossover);
   
   if(price_distance > PriceThreshold && !price_trigger_active)
   {
      price_trigger_active = true;
      Print("TRACE: Price Trigger Activated: ", price_distance, " Pips");
   }
   
   //--- Check EMA slope
   double slope = (current_ema - previous_ema) / _Point / pips_multiplier;
   
   Print("TRACE: EMA Slope: ", slope, " Pips (Threshold: ", SlopeThreshold, ")");
   
   if(MathAbs(slope) > SlopeThreshold && !slope_trigger_active)
   {
      slope_trigger_active = true;
      Print("TRACE: Slope Trigger Activated: ", slope, " Pips");
   }
   
   //--- Start monitoring when both triggers are active
   if(price_trigger_active && slope_trigger_active && !monitoring_active)
   {
      monitoring_active = true;
      
      if(UseBarData)
      {
         last_monitoring_time = iTime(_Symbol, Timeframe, 0); // Current bar time
         Print("TRACE: Monitoring Started - Both Triggers Active (Bar: ", TimeToString(last_monitoring_time), ")");
      }
      else
      {
         last_monitoring_time = TimeCurrent(); // Current tick time
         Print("TRACE: Monitoring Started - Both Triggers Active (Tick)");
      }
   }
   
   //--- Place trade when monitoring active and price above/below EMA
   if(monitoring_active)
   {
      bool bullish_signal = current_close > current_ema;
      bool bearish_signal = current_close < current_ema;
      
      Print("TRACE: Signal Check - Bullish: ", bullish_signal, " Bearish: ", bearish_signal);
      Print("TRACE: Close: ", current_close, " EMA: ", current_ema);
      Print("TRACE: Difference: ", current_close - current_ema);
      
      //--- Check trade limit
      if(trades_in_current_crossover >= MaxTradesPerCrossover)
      {
         Print("TRACE: Trade Limit Reached (", MaxTradesPerCrossover, ") - No New Trade");
         return;
      }
      
      if(bullish_signal && !PositionExistsByMagic(_Symbol, MagicNumber))
      {
         if(!IsWeeklyADXTrendFavorable(ORDER_TYPE_BUY))
         {
            Print("TRACE: Weekly ADX Blocks BUY Entry");
            return;
         }
         Print("TRACE: Attempting to Place BUY Trade (Trade #", trades_in_current_crossover + 1, ")");
         if(PlaceTrade(ORDER_TYPE_BUY))
         {
            trades_in_current_crossover++;
         }
      }
      else if(bearish_signal && !PositionExistsByMagic(_Symbol, MagicNumber))
      {
         if(!IsWeeklyADXTrendFavorable(ORDER_TYPE_SELL))
         {
            Print("TRACE: Weekly ADX Blocks SELL Entry");
            return;
         }
         Print("TRACE: Attempting to Place SELL Trade (Trade #", trades_in_current_crossover + 1, ")");
         if(PlaceTrade(ORDER_TYPE_SELL))
         {
            trades_in_current_crossover++;
         }
      }
      else if(PositionExistsByMagic(_Symbol, MagicNumber))
      {
         Print("TRACE: Position Already Open - No New Trade");
      }
   }
}

//+------------------------------------------------------------------+
//| Place trade                                                     |
//+------------------------------------------------------------------+
bool PlaceTrade(ENUM_ORDER_TYPE order_type)
{
   Print("TRACE: Attempting to Place Trade - Type: ", (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL");
   Print("TRACE: Lot: ", LotSize);
   
   bool success = false;
   
   if(order_type == ORDER_TYPE_BUY)
   {
      success = trade.Buy(LotSize, _Symbol, 0, 0, 0, "EMA Crossover Trade");
   }
   else
   {
      success = trade.Sell(LotSize, _Symbol, 0, 0, 0, "EMA Crossover Trade");
   }
   
   if(success)
   {
      ticket = (int)trade.ResultOrder();
      Print("TRACE: Trade Successfully Placed: ", (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL", " Ticket: ", ticket);
      
      //--- Save trade opening time
      trade_open_time = iTime(_Symbol, Timeframe, 0);
      Print("TRACE: Trade Opening Time: ", TimeToString(trade_open_time));
      
      //--- Reset monitoring
      monitoring_active = false;
      price_trigger_active = false;
      slope_trigger_active = false;
      
      return true;
   }
   else
   {
      Print("TRACE: Error Placing Trade - Retcode: ", trade.ResultRetcode());
      Print("TRACE: Error Description: ", trade.ResultRetcodeDescription());
      
      return false;
   }
}

//+------------------------------------------------------------------+
//| Manage trades                                                   |
//+------------------------------------------------------------------+
void ManageTrades()
{
   if(!PositionSelectByMagic(_Symbol, MagicNumber))
      return;
   
   double position_profit = PositionGetDouble(POSITION_PROFIT);
   double position_open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
   ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   double pips_multiplier = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
   double trailing_stop_pips = TrailingStop;
   
   //--- Trailing Stop - only when position is in profit
   if(position_profit > 0) // Only apply trailing stop when in profit
   {
      if(position_type == POSITION_TYPE_BUY)
      {
         double new_stop_loss = current_price - (trailing_stop_pips * _Point * pips_multiplier);
         double current_stop_loss = PositionGetDouble(POSITION_SL);
         
         // Only move stop loss if new stop is higher than current stop
         if(new_stop_loss > current_stop_loss)
         {
            ModifyStopLoss(new_stop_loss);
         }
      }
      else if(position_type == POSITION_TYPE_SELL)
      {
         double new_stop_loss = current_price + (trailing_stop_pips * _Point * pips_multiplier);
         double current_stop_loss = PositionGetDouble(POSITION_SL);
         
         // Only move stop loss if new stop is lower than current stop
         if(new_stop_loss < current_stop_loss || current_stop_loss == 0)
         {
            ModifyStopLoss(new_stop_loss);
         }
      }
   }
   
   //--- Exit when price below/above EMA
   if(ArraySize(ema_array) >= 1)
   {
      double current_close = iClose(_Symbol, Timeframe, 0);
      double current_ema = ema_array[0];
      bool exit_bullish = (position_type == POSITION_TYPE_SELL && current_close > current_ema);
      bool exit_bearish = (position_type == POSITION_TYPE_BUY && current_close < current_ema);
      
      if(exit_bullish || exit_bearish)
      {
         Print("TRACE: Exit Signal - Close: ", current_close, " EMA: ", current_ema);
         ClosePosition("EMA Crossover Exit");
         
         Print("TRACE: Position Closed - Trade Counter Remains at ", trades_in_current_crossover);
      }
   }
   
   //--- Profit check after X bars
   if(CloseUnprofitableTrades && trade_open_time != 0 && PositionExistsByMagic(_Symbol, MagicNumber))
   {
      Print("TRACE: Profit Check Activated - CloseUnprofitableTrades: ", CloseUnprofitableTrades);
      CheckProfitAfterBars();
   }
   else if(!CloseUnprofitableTrades)
   {
      Print("TRACE: Profit Check Deactivated - CloseUnprofitableTrades: ", CloseUnprofitableTrades);
   }
}

//+------------------------------------------------------------------+
//| Profit check after X bars                                        |
//+------------------------------------------------------------------+
void CheckProfitAfterBars()
{
   if(!PositionSelectByMagic(_Symbol, MagicNumber))
   {
      return; // No position open
   }
   
   datetime current_bar_time = iTime(_Symbol, Timeframe, 0);
   int bars_since_trade_open = iBarShift(_Symbol, Timeframe, trade_open_time);
   
   Print("TRACE: Bars Since Trade Opening: ", bars_since_trade_open, "/", ProfitCheckBars);
   
   //--- Check if enough bars have passed
   if(bars_since_trade_open >= ProfitCheckBars)
   {
      double position_profit = PositionGetDouble(POSITION_PROFIT);
      double position_volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      Print("TRACE: Profit Check After ", ProfitCheckBars, " Bars");
      Print("TRACE: Position Profit: ", position_profit, " USD");
      
      //--- Close position if not in profit
      if(position_profit <= 0)
      {
         Print("TRACE: Position Not in Profit - Close Position");
         ClosePosition("Profit Check - Unprofitable");
         
         //--- Reset trade opening time
         trade_open_time = 0;
         Print("TRACE: Trade Opening Time Reset");
      }
      else
      {
         Print("TRACE: Position in Profit - Keep Position");
         //--- Reset to avoid further checks
         trade_open_time = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Modify Stop Loss                                                |
//+------------------------------------------------------------------+
void ModifyStopLoss(double new_stop_loss)
{
   Print("TRACE: Attempting to Modify Stop Loss to: ", new_stop_loss);
   
   bool success = ModifyPositionByMagic(trade, _Symbol, MagicNumber, new_stop_loss, PositionGetDouble(POSITION_TP));
   
   if(success)
   {
      Print("TRACE: Stop Loss Successfully Modified to: ", new_stop_loss);
   }
   else
   {
      Print("TRACE: Error Modifying Stop Loss - Retcode: ", trade.ResultRetcode());
      Print("TRACE: Error Description: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Close position                                                  |
//+------------------------------------------------------------------+
void ClosePosition(string reason = "Unknown")
{
   Print("TRACE: Attempting to Close Position - Reason: ", reason);
   
   bool success = ClosePositionByMagic(trade, _Symbol, MagicNumber);
   
   if(success)
   {
      Print("TRACE: Position Successfully Closed - Reason: ", reason);
   }
   else
   {
      Print("TRACE: Error Closing Position - Retcode: ", trade.ResultRetcode());
      Print("TRACE: Error Description: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
