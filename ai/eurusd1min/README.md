# EURUSD 15-Minute ONNX Model Training

This directory contains the training script for a EURUSD price prediction model using 15-minute timeframe data from 1990 to 2026 using MetaTrader 5 as the data source.

## Requirements

```bash
pip install MetaTrader5 tensorflow scikit-learn pandas numpy tf2onnx onnx tqdm
```

## Usage

1. **Make sure MetaTrader 5 is running and logged in**
2. **Ensure EURUSD symbol is available in your broker**
3. **Make sure you have historical data downloaded in MT5** (Tools → History Center → Download)

4. **Run the training script:**
```bash
cd ai/eurusd1min
python main.py
```

## Configuration

The script is configured with:
- **Symbol**: EURUSD
- **Timeframe**: M15 (15 minutes)
- **Lookback**: 60 bars (15 hours of history)
- **Date Range**: 1990-01-01 to 2026-01-01
- **Model Architecture**: LSTM with 3 layers (128, 64, 32 units)
- **Epochs**: 50 (with early stopping)
- **Batch Size**: 64

## Data Fetching

- The script fetches data in **1-month chunks** to manage memory
- 15-minute data is more likely to be available for longer historical periods than 1-minute data
- The script automatically skips chunks with only 1 bar (invalid/placeholder data)
- Progress is shown for each chunk
- Make sure you have sufficient historical data in MT5

## Output

The script will create:
- `models/EURUSD_M15_model.onnx` - The trained ONNX model
- `models/EURUSD_M15_model_scaler.pkl` - The MinMaxScaler used for normalization

## Model Features

The model uses 13 features:
1. Open
2. High
3. Low
4. Close
5. Tick Volume
6. RSI (14 period)
7. EMA 20
8. EMA 50
9. ATR (14 period)
10. Price Change (percentage)
11. High/Low Ratio
12. Volume MA (20 period)
13. Volume Ratio

## Model Output

The model predicts the **price change percentage** for the next bar (15 minutes ahead).

## Notes

- Training on 36 years of 15-minute data will take significant time and memory
- The script fetches data in 1-month chunks to manage memory
- Chunks with only 1 bar are automatically skipped (invalid/placeholder data)
- Early stopping and learning rate reduction are enabled to prevent overfitting
- The model uses dropout (0.3) for regularization
- 15-minute data is more manageable than 1-minute data for long historical periods

## Using the Model in MQL5

### Expert Advisor

An Expert Advisor (`EURUSD_M15_EA.mq5`) is provided in this directory. It uses the trained ONNX model for automated trading.

**Setup:**
1. Copy `EURUSD_M15_model.onnx` to `MQL5/Files/` directory
2. Compile `EURUSD_M15_EA.mq5` in MetaEditor
3. The model will be embedded as a resource during compilation
4. Attach the EA to a EURUSD chart with M15 timeframe

**Features:**
- Embedded ONNX model (no file path issues)
- Dynamic SL/TP based on prediction, confidence, and ATR
- Configurable prediction threshold and confidence filter
- Automatic position management

**Input Parameters:**
- `InpLookback`: 60 bars (15 hours of history)
- `InpUsePredictedSLTP`: Use dynamic SL/TP based on prediction
- `InpPredictionThreshold`: Minimum prediction change to trade (default: 0.00005 = 0.005%)
- `InpMinConfidence`: Minimum confidence to trade (default: 0.1 = 10%)
