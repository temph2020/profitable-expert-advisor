//+------------------------------------------------------------------+
//|                                            EURUSD_M15_EA.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Expert Advisor using ONNX model for EURUSD 15-minute price prediction"
#property description "Based on: https://www.mql5.com/en/docs/onnx/onnx_test"

#include <Trade\Trade.mqh>

//--- Resource: Embed ONNX model in EA
// Based on: https://www.mql5.com/en/docs/onnx/onnx_test
// Path is relative to MQL5 directory (not starting with \\Files\\)
#resource "Files\\EURUSD_M15_model.onnx" as uchar ExtModel[]

//--- Input parameters
input group "ONNX Model Settings"
input string InpModelPath = "";  // ONNX Model Path (leave empty to use embedded resource)
input int    InpLookback = 60;                              // Lookback Period (bars = 15 hours)
input bool   InpUsePrediction = true;                        // Use Model Prediction

input group "Trading Settings"
input double InpLotSize = 0.01;                              // Lot Size
input int    InpMagicNumber = 123456;                        // Magic Number
input int    InpSlippage = 3;                                // Slippage (points)
input bool   InpUsePredictedSLTP = true;                      // Use Predicted SL/TP (based on prediction & volatility)
input int    InpStopLoss = 50;                               // Stop Loss (pips) - used if InpUsePredictedSLTP=false
input int    InpTakeProfit = 100;                            // Take Profit (pips) - used if InpUsePredictedSLTP=false
input double InpSLMultiplier = 1.5;                           // SL Multiplier (ATR-based, e.g., 1.5 = 1.5x ATR)
input double InpTPMultiplier = 2.0;                           // TP Multiplier (ATR-based, e.g., 2.0 = 2x ATR)
input double InpMinSLATR = 0.5;                              // Minimum SL (ATR multiplier)
input double InpMinTPATR = 1.0;                              // Minimum TP (ATR multiplier)

input group "Prediction Settings"
input double InpPredictionThreshold = 0.00005;               // Min Prediction Change (0.005% as decimal, e.g., 0.00005 = 0.005%)
input bool   InpUseConfidence = true;                         // Use Confidence Filter
input double InpMinConfidence = 0.1;                         // Minimum Confidence (0.1 = 10%)

//--- Global variables
CTrade trade;
long onnx_handle = INVALID_HANDLE;
datetime last_bar_time = 0;
double last_prediction = 0.0;
double last_confidence = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Set trade parameters
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    // Check symbol
    if(_Symbol != "EURUSD" && _Symbol != "EURUSD#")
    {
        Print("WARNING: This EA is designed for EURUSD. Current symbol: ", _Symbol);
    }
    
    // Check timeframe
    if(_Period != PERIOD_M15)
    {
        Print("WARNING: This EA is designed for M15 timeframe. Current timeframe: ", EnumToString(_Period));
    }
    
    // Load ONNX model
    // Based on: https://www.mql5.com/en/docs/onnx/onnx_test
    Print("Loading ONNX model from embedded resource...");
    
    // Create model from resource buffer
    onnx_handle = OnnxCreateFromBuffer(ExtModel, ONNX_DEBUG_LOGS);
    
    if(onnx_handle == INVALID_HANDLE)
    {
        int error = GetLastError();
        Print("ERROR: Failed to create ONNX model from resource. Error: ", error);
        Print("Make sure the model file exists at: MQL5\\Files\\EURUSD_M15_model.onnx");
        Print("Then recompile the EA to embed it as a resource.");
        return(INIT_FAILED);
    }
    
    // Set input shape - per MQL5 documentation
    const long ExtInputShape[] = {1, InpLookback, 13}; // batch=1, lookback bars, 13 features
    if(!OnnxSetInputShape(onnx_handle, 0, ExtInputShape))
    {
        Print("OnnxSetInputShape failed, error ", GetLastError());
        OnnxRelease(onnx_handle);
        return(INIT_FAILED);
    }
    
    // Set output shapes - per MQL5 documentation (multi-output: price_change, sl_atr, tp_atr)
    const long ExtOutputShape0[] = {1, 1}; // batch=1, price change output
    const long ExtOutputShape1[] = {1, 1}; // batch=1, SL (ATR) output
    const long ExtOutputShape2[] = {1, 1}; // batch=1, TP (ATR) output
    
    if(!OnnxSetOutputShape(onnx_handle, 0, ExtOutputShape0))
    {
        Print("OnnxSetOutputShape[0] failed, error ", GetLastError());
        OnnxRelease(onnx_handle);
        return(INIT_FAILED);
    }
    if(!OnnxSetOutputShape(onnx_handle, 1, ExtOutputShape1))
    {
        Print("OnnxSetOutputShape[1] failed, error ", GetLastError());
        OnnxRelease(onnx_handle);
        return(INIT_FAILED);
    }
    if(!OnnxSetOutputShape(onnx_handle, 2, ExtOutputShape2))
    {
        Print("OnnxSetOutputShape[2] failed, error ", GetLastError());
        OnnxRelease(onnx_handle);
        return(INIT_FAILED);
    }
    
    // Get model info
    long input_count = OnnxGetInputCount(onnx_handle);
    long output_count = OnnxGetOutputCount(onnx_handle);
    
    Print("ONNX Model loaded successfully");
    Print("  Inputs: ", input_count);
    Print("  Outputs: ", output_count);
    
    if(input_count > 0)
    {
        string input_name = OnnxGetInputName(onnx_handle, 0);
        Print("  Input name: ", input_name);
    }
    
    if(output_count > 0)
    {
        string output_name = OnnxGetOutputName(onnx_handle, 0);
        Print("  Output name: ", output_name);
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release ONNX model
    if(onnx_handle != INVALID_HANDLE)
    {
        OnnxRelease(onnx_handle);
        Print("ONNX model released");
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if new bar
    datetime current_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(current_bar_time == last_bar_time)
    {
        return; // Still the same bar
    }
    last_bar_time = current_bar_time;
    
    // Check if we should use prediction
    if(!InpUsePrediction)
    {
        return;
    }
    
    // Prepare input data
    float input_data[];
    if(!PrepareInputData(input_data))
    {
        Print("ERROR: Failed to prepare input data");
        return;
    }
    
    // Check if input data is valid
    if(ArraySize(input_data) != InpLookback * 13)
    {
        Print("ERROR: Input data size mismatch. Expected: ", InpLookback * 13, ", Got: ", ArraySize(input_data));
        return;
    }
    
    // Convert flat array to matrixf for OnnxRun
    // Shape: [lookback, features] = [60, 13] - batch dimension is added automatically
    matrixf input_matrix;
    input_matrix.Resize(InpLookback, 13);
    
    // Fill matrix from flat array
    int idx = 0;
    for(int i = 0; i < InpLookback; i++)
    {
        for(int j = 0; j < 13; j++)
        {
            if(idx >= ArraySize(input_data))
            {
                Print("ERROR: Index out of bounds when filling matrix. idx=", idx, ", array size=", ArraySize(input_data));
                return;
            }
            input_matrix[i][j] = input_data[idx++];
        }
    }
    
    // Verify matrix is not empty
    if(input_matrix.Rows() == 0 || input_matrix.Cols() == 0)
    {
        Print("ERROR: Input matrix is empty. Rows: ", input_matrix.Rows(), ", Cols: ", input_matrix.Cols());
        return;
    }
    
    // Run ONNX model - multi-output: price_change, sl_atr, tp_atr
    vectorf output_price_change(1);
    vectorf output_sl_atr(1);
    vectorf output_tp_atr(1);
    
    if(!RunONNXModel(input_matrix, output_price_change, output_sl_atr, output_tp_atr))
    {
        Print("ERROR: Failed to run ONNX model");
        return;
    }
    
    // Get predictions
    if(output_price_change.Size() == 0 || output_sl_atr.Size() == 0 || output_tp_atr.Size() == 0)
    {
        Print("ERROR: Empty output from ONNX model");
        return;
    }
    
    // Model outputs: [price_change_pct, sl_atr_multiple, tp_atr_multiple]
    double predicted_change_pct = output_price_change[0];
    double predicted_sl_atr = output_sl_atr[0];
    double predicted_tp_atr = output_tp_atr[0];
    
    // Ensure positive values for SL/TP
    predicted_sl_atr = MathMax(0.5, predicted_sl_atr);  // Minimum 0.5 ATR
    predicted_tp_atr = MathMax(1.0, predicted_tp_atr);  // Minimum 1.0 ATR
    
    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Check if prediction is percentage (between -1 and 1) or absolute price (old format)
    double price_change_pct;
    double predicted_price;
    
    if(MathAbs(predicted_change_pct) < 1.0)
    {
        // New format: percentage (e.g., -0.003 = -0.3%)
        price_change_pct = predicted_change_pct * 100.0; // Convert to percentage
        predicted_price = current_price * (1.0 + predicted_change_pct); // Calculate predicted price
    }
    else
    {
        // Old format: absolute price
        predicted_price = predicted_change_pct;
        double price_change = predicted_price - current_price;
        price_change_pct = (price_change / current_price) * 100.0;
    }
    
    // Calculate confidence (for percentage predictions: 0.001 = 0.1% = 10% confidence)
    double confidence;
    if(MathAbs(price_change_pct) < 1.0)
    {
        // It's a decimal percentage (e.g., 0.001 = 0.1%)
        confidence = MathMin(MathAbs(predicted_change_pct) / 0.01, 1.0); // 0.01 = 1% = 100% confidence
    }
    else
    {
        // It's already in percentage form
        confidence = MathMin(MathAbs(price_change_pct) / 1.0, 1.0);
    }
    
    last_prediction = predicted_price;
    last_confidence = confidence;
    
    // Calculate ATR for converting model's ATR multiples to actual price distances
    double atr_value = 0.0;
    double atr_array[];
    ArraySetAsSeries(atr_array, true);
    int atr_handle = iATR(_Symbol, PERIOD_CURRENT, 14);
    if(atr_handle != INVALID_HANDLE)
    {
        if(CopyBuffer(atr_handle, 0, 0, 1, atr_array) > 0)
        {
            atr_value = atr_array[0];
        }
        IndicatorRelease(atr_handle);
    }
    
    // Use model's predicted SL/TP (in ATR multiples) directly
    double predicted_sl = 0.0;
    double predicted_tp = 0.0;
    if(InpUsePredictedSLTP && atr_value > 0)
    {
        // Model predicts SL and TP in ATR multiples - convert to price distance
        predicted_sl = atr_value * predicted_sl_atr;
        predicted_tp = atr_value * predicted_tp_atr;
        
        // Ensure minimums from input parameters
        predicted_sl = MathMax(predicted_sl, atr_value * InpMinSLATR);
        predicted_tp = MathMax(predicted_tp, atr_value * InpMinTPATR);
        
        // Ensure TP is at least 1.5x SL for risk/reward
        if(predicted_tp < predicted_sl * 1.5)
        {
            predicted_tp = predicted_sl * 1.5;
        }
        
        // Get broker's stop level requirements
        int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        double min_stop_distance = stop_level * point;
        
        // Ensure SL/TP meet broker's minimum stop level
        if(predicted_sl < min_stop_distance)
        {
            predicted_sl = min_stop_distance;
        }
        if(predicted_tp < min_stop_distance)
        {
            predicted_tp = min_stop_distance;
        }
    }
    
    // Log prediction
    Print("Prediction: Current=", current_price, 
          " Predicted Change=", price_change_pct, "%",
          " Predicted Price=", predicted_price,
          " Confidence=", confidence,
          " ATR=", atr_value);
    if(InpUsePredictedSLTP && predicted_sl > 0 && predicted_tp > 0)
    {
        Print("  Model SL=", predicted_sl_atr, "x ATR (", predicted_sl, " points, ", predicted_sl/current_price*100, "%)",
              " Model TP=", predicted_tp_atr, "x ATR (", predicted_tp, " points, ", predicted_tp/current_price*100, "%)");
    }
    
    // Check if we should trade
    if(!InpUseConfidence || confidence >= InpMinConfidence)
    {
        // Check if prediction is significant
        // price_change_pct is in percentage (e.g., 5.72 = 5.72%)
        // InpPredictionThreshold is in decimal (e.g., 0.00005 = 0.005%)
        // Convert threshold to percentage for comparison
        double threshold_pct = InpPredictionThreshold * 100.0;
        double abs_change_pct = MathAbs(price_change_pct); // Already in percentage
        
        Print("Trade Check: Change=", price_change_pct, "% Threshold=", threshold_pct, "% Confidence=", confidence);
        
        if(abs_change_pct >= threshold_pct)
        {
            // Check existing position
            if(PositionSelect(_Symbol))
            {
                // Manage existing position
                ManagePosition(predicted_price, price_change_pct);
            }
            else
            {
                // Open new position based on prediction
                if(price_change_pct > threshold_pct)
                {
                    Print(">>> Opening BUY position: Change=", price_change_pct, "% Threshold=", threshold_pct, "%");
                    OpenBuyPosition(predicted_sl, predicted_tp);
                }
                else if(price_change_pct < -threshold_pct)
                {
                    Print(">>> Opening SELL position: Change=", price_change_pct, "% Threshold=", threshold_pct, "%");
                    OpenSellPosition(predicted_sl, predicted_tp);
                }
            }
        }
        else
        {
            Print("Prediction below threshold: Change=", price_change_pct, "% < Threshold=", threshold_pct, "%");
        }
    }
    else
    {
        Print("Confidence too low: ", confidence, " < ", InpMinConfidence);
    }
}

//+------------------------------------------------------------------+
//| Prepare input data for ONNX model                                |
//+------------------------------------------------------------------+
bool PrepareInputData(float &input_array[])
{
    int lookback = InpLookback;
    int features = 13; // OHLC(4) + volume(1) + RSI(1) + EMA20(1) + EMA50(1) + ATR(1) + price_change(1) + high_low_ratio(1) + volume_ma(1) + volume_ratio(1) = 13
    
    ArrayResize(input_array, lookback * features);
    ArrayInitialize(input_array, 0.0);
    
    // Get historical data
    double open[], high[], low[], close[];
    long volume[];  // CopyTickVolume requires long[] not double[]
    ArraySetAsSeries(open, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);
    ArraySetAsSeries(volume, true);
    
    int copied_open = CopyOpen(_Symbol, PERIOD_CURRENT, 0, lookback + 50, open);
    if(copied_open < lookback)
    {
        Print("ERROR: CopyOpen failed. Got ", copied_open, " bars, need ", lookback);
        return false;
    }
    int copied_high = CopyHigh(_Symbol, PERIOD_CURRENT, 0, lookback + 50, high);
    if(copied_high < lookback)
    {
        Print("ERROR: CopyHigh failed. Got ", copied_high, " bars, need ", lookback);
        return false;
    }
    int copied_low = CopyLow(_Symbol, PERIOD_CURRENT, 0, lookback + 50, low);
    if(copied_low < lookback)
    {
        Print("ERROR: CopyLow failed. Got ", copied_low, " bars, need ", lookback);
        return false;
    }
    int copied_close = CopyClose(_Symbol, PERIOD_CURRENT, 0, lookback + 50, close);
    if(copied_close < lookback)
    {
        Print("ERROR: CopyClose failed. Got ", copied_close, " bars, need ", lookback);
        return false;
    }
    int copied_volume = CopyTickVolume(_Symbol, PERIOD_CURRENT, 0, lookback + 50, volume);
    if(copied_volume < lookback)
    {
        Print("ERROR: CopyTickVolume failed. Got ", copied_volume, " bars, need ", lookback);
        return false;
    }
    
    // Calculate indicators
    double rsi[], ema20[], ema50[], atr[];
    ArraySetAsSeries(rsi, true);
    ArraySetAsSeries(ema20, true);
    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(atr, true);
    
    // Calculate RSI
    int rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
    if(rsi_handle == INVALID_HANDLE) return false;
    if(CopyBuffer(rsi_handle, 0, 0, lookback + 50, rsi) < lookback)
    {
        IndicatorRelease(rsi_handle);
        return false;
    }
    IndicatorRelease(rsi_handle);
    
    // Calculate EMAs
    int ema20_handle = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
    int ema50_handle = iMA(_Symbol, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE);
    if(ema20_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE) return false;
    
    if(CopyBuffer(ema20_handle, 0, 0, lookback + 50, ema20) < lookback ||
       CopyBuffer(ema50_handle, 0, 0, lookback + 50, ema50) < lookback)
    {
        IndicatorRelease(ema20_handle);
        IndicatorRelease(ema50_handle);
        return false;
    }
    IndicatorRelease(ema20_handle);
    IndicatorRelease(ema50_handle);
    
    // Calculate ATR
    int atr_handle = iATR(_Symbol, PERIOD_CURRENT, 14);
    if(atr_handle == INVALID_HANDLE) return false;
    if(CopyBuffer(atr_handle, 0, 0, lookback + 50, atr) < lookback)
    {
        IndicatorRelease(atr_handle);
        return false;
    }
    IndicatorRelease(atr_handle);
    
    // Calculate volume MA for normalization
    double volume_ma[];
    ArraySetAsSeries(volume_ma, true);
    ArrayResize(volume_ma, lookback);
    ArrayInitialize(volume_ma, 0.0);
    
    // Calculate volume MA (20-period rolling average)
    for(int j = 0; j < lookback; j++)
    {
        double sum = 0.0;
        int count = 0;
        for(int k = j; k < j + 20 && k < ArraySize(volume); k++)
        {
            sum += (double)volume[k];
            count++;
        }
        volume_ma[j] = count > 0 ? sum / count : (double)volume[j];
    }
    
    // Prepare features - MUST match Python training exactly (13 features)
    int idx = 0;
    for(int i = 0; i < lookback; i++)
    {
        // Feature 1-4: OHLC
        input_array[idx++] = (float)open[i];
        input_array[idx++] = (float)high[i];
        input_array[idx++] = (float)low[i];
        input_array[idx++] = (float)close[i];
        
        // Feature 5: Volume (normalized by 1,000,000)
        input_array[idx++] = (float)((double)volume[i] / 1000000.0);
        
        // Feature 6: RSI (normalized by 100)
        input_array[idx++] = (float)(rsi[i] / 100.0);
        
        // Feature 7: EMA20 normalized difference
        input_array[idx++] = (float)((ema20[i] - close[i]) / close[i]);
        
        // Feature 8: EMA50 normalized difference
        input_array[idx++] = (float)((ema50[i] - close[i]) / close[i]);
        
        // Feature 9: ATR normalized
        input_array[idx++] = (float)(atr[i] / close[i]);
        
        // Feature 10: Price change (percentage)
        double price_change = i > 0 ? (close[i] - close[i+1]) / close[i+1] : 0.0;
        input_array[idx++] = (float)price_change;
        
        // Feature 11: High/Low ratio
        input_array[idx++] = (float)(high[i] / low[i]);
        
        // Feature 12: Volume MA (normalized by 1,000,000)
        input_array[idx++] = (float)(volume_ma[i] / 1000000.0);
        
        // Feature 13: Volume ratio
        double vol_ratio = volume_ma[i] > 0 ? (double)volume[i] / volume_ma[i] : 1.0;
        input_array[idx++] = (float)vol_ratio;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Run ONNX model                                                   |
//+------------------------------------------------------------------+
bool RunONNXModel(matrixf &input_matrix, vectorf &output_price_change, vectorf &output_sl_atr, vectorf &output_tp_atr)
{
    if(onnx_handle == INVALID_HANDLE)
        return false;
    
    // For multi-output ONNX models in MQL5, OnnxRun expects all outputs as separate parameters
    // Function signature: OnnxRun(handle, flags, input, output1, output2, output3, ...)
    // This is 4 parameters total: handle, flags, input, and then all outputs
    
    if(!OnnxRun(onnx_handle, ONNX_DEBUG_LOGS | ONNX_NO_CONVERSION, input_matrix, 
                output_price_change, output_sl_atr, output_tp_atr))
    {
        Print("ERROR: Failed to run ONNX model. Error: ", GetLastError());
        Print("Model has ", OnnxGetOutputCount(onnx_handle), " outputs");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Open buy position                                                |
//+------------------------------------------------------------------+
void OpenBuyPosition(double predicted_sl = 0.0, double predicted_tp = 0.0)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = 0.0;
    double tp = 0.0;
    
    // Get broker's stop level requirements
    int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double min_stop_distance = stop_level * point;
    
    if(InpUsePredictedSLTP && predicted_sl > 0 && predicted_tp > 0)
    {
        // Use predicted SL/TP
        // For BUY: SL below entry, TP above entry
        sl = price - predicted_sl;
        tp = price + predicted_tp;
        
        // Validate stops meet broker requirements
        if(sl > 0 && (price - sl) < min_stop_distance)
        {
            sl = price - min_stop_distance;
        }
        if(tp > 0 && (tp - price) < min_stop_distance)
        {
            tp = price + min_stop_distance;
        }
        
        Print("Using predicted SL/TP: Entry=", price, " SL=", sl, " TP=", tp, " (SL distance: ", price - sl, ", TP distance: ", tp - price, ")");
    }
    else
    {
        // Use fixed SL/TP from input parameters
        sl = InpStopLoss > 0 ? price - InpStopLoss * _Point * 10 : 0;
        tp = InpTakeProfit > 0 ? price + InpTakeProfit * _Point * 10 : 0;
    }
    
    if(trade.Buy(InpLotSize, _Symbol, price, sl, tp, "ONNX Buy Signal"))
    {
        Print("Buy order opened. Ticket: ", trade.ResultOrder(), " Price: ", price, " SL: ", sl, " TP: ", tp);
    }
    else
    {
        Print("Failed to open buy order. Error: ", trade.ResultRetcodeDescription());
        Print("  Entry: ", price, " SL: ", sl, " TP: ", tp);
        Print("  Stop Level: ", stop_level, " Min Distance: ", min_stop_distance);
    }
}

//+------------------------------------------------------------------+
//| Open sell position                                               |
//+------------------------------------------------------------------+
void OpenSellPosition(double predicted_sl = 0.0, double predicted_tp = 0.0)
{
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0.0;
    double tp = 0.0;
    
    // Get broker's stop level requirements
    int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double min_stop_distance = stop_level * point;
    
    if(InpUsePredictedSLTP && predicted_sl > 0 && predicted_tp > 0)
    {
        // Use predicted SL/TP
        // For SELL: SL above entry, TP below entry
        sl = price + predicted_sl;
        tp = price - predicted_tp;
        
        // Validate stops meet broker requirements
        if(sl > 0 && (sl - price) < min_stop_distance)
        {
            sl = price + min_stop_distance;
        }
        if(tp > 0 && (price - tp) < min_stop_distance)
        {
            tp = price - min_stop_distance;
        }
        
        Print("Using predicted SL/TP: Entry=", price, " SL=", sl, " TP=", tp, " (SL distance: ", sl - price, ", TP distance: ", price - tp, ")");
    }
    else
    {
        // Use fixed SL/TP from input parameters
        sl = InpStopLoss > 0 ? price + InpStopLoss * _Point * 10 : 0;
        tp = InpTakeProfit > 0 ? price - InpTakeProfit * _Point * 10 : 0;
    }
    
    if(trade.Sell(InpLotSize, _Symbol, price, sl, tp, "ONNX Sell Signal"))
    {
        Print("Sell order opened. Ticket: ", trade.ResultOrder(), " Price: ", price, " SL: ", sl, " TP: ", tp);
    }
    else
    {
        Print("Failed to open sell order. Error: ", trade.ResultRetcodeDescription());
        Print("  Entry: ", price, " SL: ", sl, " TP: ", tp);
        Print("  Stop Level: ", stop_level, " Min Distance: ", min_stop_distance);
    }
}

//+------------------------------------------------------------------+
//| Manage existing position                                          |
//+------------------------------------------------------------------+
void ManagePosition(double predicted_price, double price_change_pct)
{
    if(!PositionSelect(_Symbol))
        return;
    
    // Simple position management - can be enhanced
    // For now, just log the position status
    double position_profit = PositionGetDouble(POSITION_PROFIT);
    Print("Position exists. Profit: ", position_profit, " Predicted change: ", price_change_pct, "%");
}
