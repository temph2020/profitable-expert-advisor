# XAUUSD M15 — ONNX action model (buy / sell / close)

## What it does

- Pulls **XAUUSD** (**M15**) from **MetaTrader 5** (2008–2026 requested; actual range depends on History Center).
- **24 features**: 13 legacy OHLC/EMA/ATR/volume + **11 RSI / session** features aligned with **frontline** strategies (crosses, velocity, RSI7/21, Asian window). See **`FRONTLINE_RSI_INTEGRATION.md`**.
- Labels: **buy-low / sell-high** (forward window) + **close-long / close-short** (past-only). RSI enters as **inputs**, not as hard-coded label rules.
- Trains **LSTM → softmax(5)**: `HOLD`, `BUY`, `SELL_SHORT`, `CLOSE_LONG`, `CLOSE_SHORT`.
- Exports **`models/XAUUSD_M15_action.onnx`** + scaler + **`XAUUSD_M15_action_meta.json`** (includes `feature_columns`).
- **EA**: **SL=0, TP=0**; **InpMaxAdverseATR**; **InpSessionHourOffset** should match training `SESSION_HOUR_OFFSET` for Asian flag.

This is research tooling — not investment advice. Past labels do not guarantee live performance.

## Setup

1. MT5 installed, logged in, **XAUUSD** visible; download **M15** history (Tools → History Center or chart scroll).
2. Python 3.10+:

```bash
cd ai/xauusd_m15
pip install -r requirements.txt
python main.py
```

Optional env: `XAU_SYMBOL`, `XAU_LOOKBACK` (default 64), `XAU_EPOCHS`, `XAU_BATCH`, `SESSION_HOUR_OFFSET` (Asian session hour alignment vs server time).

3. Copy `models/XAUUSD_M15_action.onnx` to **`MQL5/Files/`** (same path as `#resource` in the EA).
4. Open `XAUUSD_M15_ActionEA.mq5` in MetaEditor; compile.
5. Paste two lines from training stdout into **InpFeatMinStr** and **InpFeatMaxStr** (comma-separated **24** floats each).

## ONNX I/O

- Input: `[1, lookback, 24]` float32, **row 0 = newest bar**.
- Output: `[1, 5]` softmax probabilities.

## Files

| File | Role |
|------|------|
| `main.py` | Fetch, features, labels, train, ONNX + meta |
| `features.py` | 24-dim pipeline + Wilder RSI |
| `FRONTLINE_RSI_INTEGRATION.md` | frontline 策略 → 特征对照 |
| `labeling.py` | `compute_action_labels` |
| `risk_controls.py` | Adverse ATR helper for Python backtests |
| `XAUUSD_M15_ActionEA.mq5` | Live inference + trading skeleton |

## Tuning labels

Edit parameters in `labeling.compute_action_labels()` (`horizon`, `k_forward_atr`, `pullback_mult`, etc.) and retrain.
