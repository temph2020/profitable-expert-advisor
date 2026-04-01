# BTCUSD 1-Minute ONNX Model Training

This directory contains the training script for a BTCUSD price prediction model using 1-minute timeframe data from 2017 to 2026.

## Requirements

```bash
pip install yfinance tensorflow scikit-learn pandas numpy tf2onnx onnx tqdm
```

## Usage

1. **Run the training script:**
```bash
cd ai/btcusd1min
python main.py
```

**Note:** yfinance 1-minute data is limited to the last 7 days. For longer historical training, the script will use the most recent available data.

## Configuration

The script is configured with:
- **Symbol**: BTCUSD
- **Timeframe**: M1 (1 minute)
- **Lookback**: 60 bars (60 minutes of history)
- **Date Range**: 2017-01-01 to 2026-01-01
- **Model Architecture**: LSTM with 3 layers (128, 64, 32 units)
- **Epochs**: 50 (with early stopping)
- **Batch Size**: 64

## Output

The script will create:
- `models/BTCUSD_M1_model.onnx` - The trained ONNX model
- `models/BTCUSD_M1_model_scaler.pkl` - The MinMaxScaler used for normalization

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

The model predicts the **price change percentage** for the next bar (1 minute ahead).

## Notes

- Training on 9 years of 1-minute data will take significant time and memory
- The script fetches data in 3-month chunks to manage memory
- Early stopping and learning rate reduction are enabled to prevent overfitting
- The model uses dropout (0.3) for regularization

## Using the Model in MQL5

After training, copy the ONNX model to your MT5 `MQL5/Files/` directory and use it in an Expert Advisor similar to the XAUUSD H1 EA.
