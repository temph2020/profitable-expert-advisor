//+------------------------------------------------------------------+
//|                                          TimeSelectiveEMA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "EMA Crossover EA for EURUSD with Trading Hours Filter"
#property description "Minimizes loss by trading only during optimal hours"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "Timeframe Settings"
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15;           // Trading Timeframe

input group "EMA Settings"
input int    InpFastEMA = 12;                              // Fast EMA Period
input int    InpSlowEMA = 26;                              // Slow EMA Period

input group "Trading Hours (Server Time)"
input int    InpStartHour = 8;                             // Trading Start Hour (0-23)
input int    InpEndHour = 18;                              // Trading End Hour (0-23)
input bool   InpUseTimeFilter = true;                      // Use Trading Hours Filter

input group "Risk Management"
input double InpLotSize = 0.01;                            // Lot Size
input int    InpMagicNumber = 789012;                      // Magic Number
input int    InpSlippage = 3;                              // Slippage (points)
input bool   InpUseRecrossExit = true;                     // Use EMA Recross as Exit (No SL/TP)

input group "Loss Minimization"
input bool   InpUseMaxDailyLoss = true;                    // Use Max Daily Loss
input double InpMaxDailyLoss = 50.0;                       // Max Daily Loss (USD)

//--- Global variables
CTrade trade;
int fast_ema_handle;
int slow_ema_handle;
datetime last_bar_time = 0;
double daily_profit = 0.0;
datetime last_daily_reset = 0;
double last_profit = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Check symbol
    if(_Symbol != "EURUSD" && _Symbol != "EURUSD#")
    {
        Alert("This EA is designed for EURUSD only. Current symbol: ", _Symbol);
        return(INIT_FAILED);
    }
    
    // Set trade parameters
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    // Create EMA indicators on specified timeframe
    fast_ema_handle = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
    slow_ema_handle = iMA(_Symbol, InpTimeframe, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
    
    if(fast_ema_handle == INVALID_HANDLE || slow_ema_handle == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create EMA indicators");
        return(INIT_FAILED);
    }
    
    // Initialize daily tracking
    last_daily_reset = TimeCurrent();
    daily_profit = 0.0;
    
    Print("TimeSelectiveEMA EA initialized for ", _Symbol);
    Print("Timeframe: ", EnumToString(InpTimeframe));
    Print("Trading Hours: ", InpStartHour, ":00 - ", InpEndHour, ":00 (Server Time)");
    Print("EMA Crossover: Fast=", InpFastEMA, " Slow=", InpSlowEMA);
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release indicators
    if(fast_ema_handle != INVALID_HANDLE)
        IndicatorRelease(fast_ema_handle);
    if(slow_ema_handle != INVALID_HANDLE)
        IndicatorRelease(slow_ema_handle);
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
    
    // Reset daily profit and consecutive losses at midnight
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    MqlDateTime last_dt;
    TimeToStruct(last_daily_reset, last_dt);
    
    // Check if new day (day, month, or year changed)
    bool is_new_day = (dt.day != last_dt.day || dt.month != last_dt.month || dt.year != last_dt.year);
    
    if(is_new_day)
    {
        // New day - reset daily profit
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
    
    // Get EMA values
    double fast_ema[], slow_ema[];
    ArraySetAsSeries(fast_ema, true);
    ArraySetAsSeries(slow_ema, true);
    
    if(CopyBuffer(fast_ema_handle, 0, 0, 3, fast_ema) < 3 ||
       CopyBuffer(slow_ema_handle, 0, 0, 3, slow_ema) < 3)
    {
        Print("ERROR: Failed to copy EMA buffers");
        return;
    }
    
    // Check for crossover signals
    bool bullish_cross = false;
    bool bearish_cross = false;
    
    // Bullish: Fast EMA crosses above Slow EMA
    if(fast_ema[1] > slow_ema[1] && fast_ema[2] <= slow_ema[2])
    {
        bullish_cross = true;
    }
    
    // Bearish: Fast EMA crosses below Slow EMA
    if(fast_ema[1] < slow_ema[1] && fast_ema[2] >= slow_ema[2])
    {
        bearish_cross = true;
    }
    
    // Check existing position
    if(PositionSelect(_Symbol))
    {
        // Check for recross (opposite signal) - this is the exit signal
        long position_type = PositionGetInteger(POSITION_TYPE);
        if(InpUseRecrossExit)
        {
            if(position_type == POSITION_TYPE_BUY && bearish_cross)
            {
                // Close long position on bearish recross (Fast EMA crosses below Slow EMA)
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed due to bearish recross (Fast EMA crossed below Slow EMA)");
                }
            }
            else if(position_type == POSITION_TYPE_SELL && bullish_cross)
            {
                // Close short position on bullish recross (Fast EMA crosses above Slow EMA)
                if(trade.PositionClose(_Symbol))
                {
                    Print("Position closed due to bullish recross (Fast EMA crossed above Slow EMA)");
                }
            }
        }
        
        // Manage existing position (trailing stop, break-even if enabled)
        ManagePosition();
    }
    else
    {
        // No position - check for new entry
        if(bullish_cross)
        {
            OpenBuyPosition();
        }
        else if(bearish_cross)
        {
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
    
    // No SL/TP - exit only on EMA recross
    if(trade.Buy(InpLotSize, _Symbol, price, 0, 0, "EMA Crossover Buy"))
    {
        Print("Buy order opened at ", price, " (Exit on bearish recross)");
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
    
    // No SL/TP - exit only on EMA recross
    if(trade.Sell(InpLotSize, _Symbol, price, 0, 0, "EMA Crossover Sell"))
    {
        Print("Sell order opened at ", price, " (Exit on bullish recross)");
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
    
    // Position management: Only track profit/loss
    // Exit is handled by EMA recross signal in OnTick()
}

//+------------------------------------------------------------------+
//| Apply trailing stop (disabled - using recross exit only)         |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
    // Trailing stop disabled - using EMA recross as exit signal only
    // This function kept for compatibility but does nothing
    return;
}

//+------------------------------------------------------------------+
//| Move stop loss to break-even (disabled - using recross exit only)|
//+------------------------------------------------------------------+
void MoveToBreakEven()
{
    // Break-even disabled - using EMA recross as exit signal only
    // This function kept for compatibility but does nothing
    return;
}

//+------------------------------------------------------------------+
//| Trade transaction event handler                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Track daily profit only (consecutive losses feature removed)
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        if(HistoryDealSelect(trans.deal))
        {
            long deal_type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            if(deal_type == DEAL_TYPE_BALANCE || deal_type == DEAL_TYPE_COMMISSION)
                return;
            
            // Check if deal is from current day
            datetime deal_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
            MqlDateTime deal_dt, current_dt;
            TimeToStruct(deal_time, deal_dt);
            TimeToStruct(TimeCurrent(), current_dt);
            
            // Only process deals from current day
            bool is_current_day = (deal_dt.day == current_dt.day && 
                                  deal_dt.month == current_dt.month && 
                                  deal_dt.year == current_dt.year);
            
            if(is_current_day)
            {
                double deal_profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                // Daily profit is tracked in ManagePosition()
            }
        }
    }
}
