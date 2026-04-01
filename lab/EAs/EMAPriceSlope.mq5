//+------------------------------------------------------------------+
//|                                            EMAPriceSlope.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Expert Advisor using EMA Slope for intelligent trend trading"
#property description "Trades based on EMA momentum, slope strength, and price confirmation"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "Timeframe Settings"
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15;           // Trading Timeframe

input group "EMA Settings"
input int    InpEMAPeriod = 20;                            // EMA Period
input int    InpSlopeBars = 3;                             // Slope Calculation Bars (lookback for slope)

input group "Slope Trading Logic"
input double InpMinSlopeStrength = 0.0001;                // Minimum Slope Strength (0.01% per bar)
input bool   InpUseSlopeAcceleration = true;                // Require slope acceleration (increasing momentum)
input double InpMinAcceleration = 0.00005;                 // Minimum Acceleration Threshold
input bool   InpUsePriceConfirmation = true;                // Require price above/below EMA for confirmation
input double InpPriceDistanceMultiplier = 0.5;             // Price distance from EMA (ATR multiplier)

input group "Entry Filters"
input bool   InpUseVolatilityFilter = true;                // Use ATR volatility filter
input double InpMinATR = 0.0002;                           // Minimum ATR for trading (filter low volatility)
input double InpMaxATR = 0.01;                             // Maximum ATR for trading (filter high volatility)
input bool   InpUseRSIFilter = false;                       // Use RSI filter
input int    InpRSIPeriod = 14;                            // RSI Period
input double InpRSIOverbought = 70;                        // RSI Overbought (avoid longs)
input double InpRSIOversold = 30;                          // RSI Oversold (avoid shorts)

input group "Trading Hours (Server Time)"
input int    InpStartHour = 8;                             // Trading Start Hour (0-23)
input int    InpEndHour = 18;                              // Trading End Hour (0-23)
input bool   InpUseTimeFilter = true;                      // Use Trading Hours Filter

input group "Risk Management"
input double InpLotSize = 0.01;                            // Lot Size
input int    InpStopLoss = 50;                             // Stop Loss (pips) - 0 = no SL
input int    InpTakeProfit = 100;                          // Take Profit (pips) - 0 = no TP
input bool   InpUseTrailingStop = true;                    // Use Trailing Stop
input int    InpTrailingStop = 30;                         // Trailing Stop (pips)
input int    InpTrailingStep = 5;                          // Trailing Step (pips)
input int    InpMagicNumber = 890123;                      // Magic Number
input int    InpSlippage = 3;                              // Slippage (points)

input group "Exit Strategy"
input bool   InpUseSlopeReversalExit = true;                // Exit on slope reversal
input double InpSlopeReversalThreshold = -0.00005;         // Slope reversal threshold (negative slope for long exit)
input bool   InpUseEMAExit = false;                        // Exit when price crosses EMA

input group "Loss Minimization"
input bool   InpUseMaxDailyLoss = true;                    // Use Max Daily Loss
input double InpMaxDailyLoss = 50.0;                       // Max Daily Loss (USD)

//--- Global variables
CTrade trade;
int ema_handle;
int atr_handle;
int rsi_handle;
datetime last_bar_time = 0;
double daily_profit = 0.0;
datetime last_daily_reset = 0;
double last_profit = 0.0;
double last_slope = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Set trade parameters
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    // Create indicators
    ema_handle = iMA(_Symbol, InpTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    
    if(InpUseVolatilityFilter)
    {
        atr_handle = iATR(_Symbol, InpTimeframe, 14);
        if(atr_handle == INVALID_HANDLE)
        {
            Print("ERROR: Failed to create ATR indicator");
            return(INIT_FAILED);
        }
    }
    
    if(InpUseRSIFilter)
    {
        rsi_handle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
        if(rsi_handle == INVALID_HANDLE)
        {
            Print("ERROR: Failed to create RSI indicator");
            return(INIT_FAILED);
        }
    }
    
    if(ema_handle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create EMA indicator");
        return(INIT_FAILED);
    }
    
    // Initialize daily tracking
    last_daily_reset = TimeCurrent();
    daily_profit = 0.0;
    
    Print("EMAPriceSlope EA initialized for ", _Symbol);
    Print("Timeframe: ", EnumToString(InpTimeframe));
    Print("EMA Period: ", InpEMAPeriod, " Slope Bars: ", InpSlopeBars);
    Print("Min Slope Strength: ", InpMinSlopeStrength);
    Print("Trading Hours: ", InpStartHour, ":00 - ", InpEndHour, ":00");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release indicators
    if(ema_handle != INVALID_HANDLE)
        IndicatorRelease(ema_handle);
    if(atr_handle != INVALID_HANDLE)
        IndicatorRelease(atr_handle);
    if(rsi_handle != INVALID_HANDLE)
        IndicatorRelease(rsi_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if new bar on the specified timeframe
    datetime current_bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(current_bar_time == last_bar_time)
    {
        // Still same bar - only manage existing positions
        ManagePosition();
        return;
    }
    last_bar_time = current_bar_time;
    
    // Reset daily profit at midnight
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    MqlDateTime last_dt;
    TimeToStruct(last_daily_reset, last_dt);
    bool is_new_day = (dt.day != last_dt.day || dt.month != last_dt.month || dt.year != last_dt.year);
    
    if(is_new_day)
    {
        daily_profit = 0.0;
        last_daily_reset = TimeCurrent();
        Print("Daily reset: New trading day started. Daily profit reset to 0.");
    }
    
    // Check daily loss limit
    if(InpUseMaxDailyLoss && daily_profit <= -InpMaxDailyLoss)
    {
        Print("Daily loss limit reached: ", daily_profit, " USD. Trading stopped for today.");
        return;
    }
    
    // Check trading hours
    if(InpUseTimeFilter && !IsWithinTradingHours())
    {
        return; // Outside trading hours
    }
    
    // Get EMA values for slope calculation
    double ema[];
    ArraySetAsSeries(ema, true);
    
    // Need enough bars for slope calculation
    int bars_needed = InpSlopeBars + 5;
    if(CopyBuffer(ema_handle, 0, 0, bars_needed, ema) < bars_needed)
    {
        Print("ERROR: Failed to copy EMA buffer");
        return;
    }
    
    // Calculate EMA slope (rate of change)
    double current_ema = ema[0];
    double previous_ema = ema[InpSlopeBars];
    double slope = (current_ema - previous_ema) / previous_ema; // Percentage change
    
    // Calculate slope acceleration (change in slope)
    double previous_slope = last_slope;
    double acceleration = 0.0;
    if(previous_slope != 0.0)
    {
        acceleration = slope - previous_slope;
    }
    last_slope = slope;
    
    // Get current price
    double current_price = iClose(_Symbol, InpTimeframe, 0);
    double price_distance_from_ema = MathAbs(current_price - current_ema) / current_ema;
    
    // Get ATR for volatility filter
    double atr_value = 0.0;
    if(InpUseVolatilityFilter)
    {
        double atr_array[];
        ArraySetAsSeries(atr_array, true);
        if(CopyBuffer(atr_handle, 0, 0, 1, atr_array) > 0)
        {
            atr_value = atr_array[0];
        }
    }
    
    // Get RSI for filter
    double rsi_value = 50.0;
    if(InpUseRSIFilter)
    {
        double rsi_array[];
        ArraySetAsSeries(rsi_array, true);
        if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_array) > 0)
        {
            rsi_value = rsi_array[0];
        }
    }
    
    // Check existing position
    if(PositionSelect(_Symbol))
    {
        ManagePosition();
        
        // Check exit conditions
        long position_type = PositionGetInteger(POSITION_TYPE);
        
        // Exit on slope reversal
        if(InpUseSlopeReversalExit)
        {
            if(position_type == POSITION_TYPE_BUY && slope < InpSlopeReversalThreshold)
            {
                // Long position: exit on negative slope reversal
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed: Slope reversal (slope=", slope, ")");
                }
                return;
            }
            else if(position_type == POSITION_TYPE_SELL && slope > -InpSlopeReversalThreshold)
            {
                // Short position: exit on positive slope reversal
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed: Slope reversal (slope=", slope, ")");
                }
                return;
            }
        }
        
        // Exit when price crosses EMA (if enabled)
        if(InpUseEMAExit)
        {
            double prev_price = iClose(_Symbol, InpTimeframe, 1);
            if(position_type == POSITION_TYPE_BUY && current_price < current_ema && prev_price >= ema[1])
            {
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed: Price crossed below EMA");
                }
                return;
            }
            else if(position_type == POSITION_TYPE_SELL && current_price > current_ema && prev_price <= ema[1])
            {
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed: Price crossed above EMA");
                }
                return;
            }
        }
    }
    else
    {
        // No position - check for entry signals
        
        // Volatility filter
        if(InpUseVolatilityFilter && atr_value > 0)
        {
            if(atr_value < InpMinATR || atr_value > InpMaxATR)
            {
                return; // Volatility out of range
            }
        }
        
        // RSI filter
        if(InpUseRSIFilter)
        {
            if(rsi_value > InpRSIOverbought || rsi_value < InpRSIOversold)
            {
                return; // RSI in extreme zone
            }
        }
        
        // BUY Signal: Positive slope with strength
        bool buy_signal = false;
        if(slope > InpMinSlopeStrength)
        {
            // Check acceleration (if enabled)
            if(InpUseSlopeAcceleration)
            {
                if(acceleration > InpMinAcceleration)
                {
                    buy_signal = true;
                }
            }
            else
            {
                buy_signal = true;
            }
            
            // Price confirmation (if enabled)
            if(buy_signal && InpUsePriceConfirmation)
            {
                double min_distance = atr_value * InpPriceDistanceMultiplier / current_price;
                if(price_distance_from_ema < min_distance || current_price < current_ema)
                {
                    buy_signal = false; // Price too close to EMA or below EMA
                }
            }
            
            // RSI filter for buy
            if(buy_signal && InpUseRSIFilter && rsi_value > InpRSIOverbought)
            {
                buy_signal = false;
            }
        }
        
        // SELL Signal: Negative slope with strength
        bool sell_signal = false;
        if(slope < -InpMinSlopeStrength)
        {
            // Check acceleration (if enabled)
            if(InpUseSlopeAcceleration)
            {
                if(acceleration < -InpMinAcceleration)
                {
                    sell_signal = true;
                }
            }
            else
            {
                sell_signal = true;
            }
            
            // Price confirmation (if enabled)
            if(sell_signal && InpUsePriceConfirmation)
            {
                double min_distance = atr_value * InpPriceDistanceMultiplier / current_price;
                if(price_distance_from_ema < min_distance || current_price > current_ema)
                {
                    sell_signal = false; // Price too close to EMA or above EMA
                }
            }
            
            // RSI filter for sell
            if(sell_signal && InpUseRSIFilter && rsi_value < InpRSIOversold)
            {
                sell_signal = false;
            }
        }
        
        // Execute trades
        if(buy_signal)
        {
            Print("BUY Signal: Slope=", slope, " Acceleration=", acceleration, " Price=", current_price);
            OpenBuyPosition();
        }
        else if(sell_signal)
        {
            Print("SELL Signal: Slope=", slope, " Acceleration=", acceleration, " Price=", current_price);
            OpenSellPosition();
        }
    }
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int current_hour = dt.hour;
    
    // Handle case where end hour is before start hour (overnight)
    if(InpEndHour < InpStartHour)
    {
        return (current_hour >= InpStartHour || current_hour < InpEndHour);
    }
    else
    {
        return (current_hour >= InpStartHour && current_hour < InpEndHour);
    }
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = 0.0;
    double tp = 0.0;
    
    if(InpStopLoss > 0)
    {
        sl = price - InpStopLoss * _Point * 10;
    }
    if(InpTakeProfit > 0)
    {
        tp = price + InpTakeProfit * _Point * 10;
    }
    
    // Validate stops
    int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double min_stop = stop_level * point;
    
    if(sl > 0 && (price - sl) < min_stop)
        sl = price - min_stop;
    if(tp > 0 && (tp - price) < min_stop)
        tp = price + min_stop;
    
    if(trade.Buy(InpLotSize, _Symbol, price, sl, tp, "EMA Slope Buy"))
    {
        Print("Buy order opened at ", price, " SL: ", sl, " TP: ", tp);
    }
    else
    {
        Print("Failed to open buy order: ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Open sell position                                               |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0.0;
    double tp = 0.0;
    
    if(InpStopLoss > 0)
    {
        sl = price + InpStopLoss * _Point * 10;
    }
    if(InpTakeProfit > 0)
    {
        tp = price - InpTakeProfit * _Point * 10;
    }
    
    // Validate stops
    int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double min_stop = stop_level * point;
    
    if(sl > 0 && (sl - price) < min_stop)
        sl = price + min_stop;
    if(tp > 0 && (price - tp) < min_stop)
        tp = price - min_stop;
    
    if(trade.Sell(InpLotSize, _Symbol, price, sl, tp, "EMA Slope Sell"))
    {
        Print("Sell order opened at ", price, " SL: ", sl, " TP: ", tp);
    }
    else
    {
        Print("Failed to open sell order: ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Manage existing position                                          |
//+------------------------------------------------------------------+
void ManagePosition()
{
    if(!PositionSelect(_Symbol))
        return;
    
    // Update daily profit
    double current_profit = PositionGetDouble(POSITION_PROFIT);
    if(current_profit != last_profit)
    {
        daily_profit += (current_profit - last_profit);
        last_profit = current_profit;
    }
    
    // Apply trailing stop
    if(InpUseTrailingStop && InpTrailingStop > 0)
    {
        ApplyTrailingStop();
    }
}

//+------------------------------------------------------------------+
//| Apply trailing stop                                               |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
    if(!PositionSelect(_Symbol))
        return;
    
    double position_sl = PositionGetDouble(POSITION_SL);
    double position_tp = PositionGetDouble(POSITION_TP);
    long position_type = PositionGetInteger(POSITION_TYPE);
    double current_price = (position_type == POSITION_TYPE_BUY) ? 
                          SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                          SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    double trailing_distance = InpTrailingStop * _Point * 10;
    double new_sl = 0;
    
    if(position_type == POSITION_TYPE_BUY)
    {
        new_sl = current_price - trailing_distance;
        if(new_sl > position_sl && new_sl < current_price)
        {
            // Check trailing step
            if(position_sl == 0 || (new_sl - position_sl) >= InpTrailingStep * _Point * 10)
            {
                if(trade.PositionModify(_Symbol, new_sl, position_tp))
                {
                    Print("Trailing stop updated: New SL=", new_sl);
                }
            }
        }
    }
    else if(position_type == POSITION_TYPE_SELL)
    {
        new_sl = current_price + trailing_distance;
        if((position_sl == 0 || new_sl < position_sl) && new_sl > current_price)
        {
            // Check trailing step
            if(position_sl == 0 || (position_sl - new_sl) >= InpTrailingStep * _Point * 10)
            {
                if(trade.PositionModify(_Symbol, new_sl, position_tp))
                {
                    Print("Trailing stop updated: New SL=", new_sl);
                }
            }
        }
    }
}
