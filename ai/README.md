# AI / Machine Learning

ONNX-based price-action models for MetaTrader 5.

## Projects

| Directory | Symbol / TF | Notes |
|-----------|-------------|-------|
| [`xauusd_h1/`](xauusd_h1/) | XAUUSD H1 | Action classification EA |
| [`xauusd_m15/`](xauusd_m15/) | XAUUSD M15 | Shorter horizon |
| [`eurusd1h/`](eurusd1h/) | EURUSD H1 | |
| [`eurusd1min/`](eurusd1min/) | EURUSD M15 model | |
| [`btcusd1min/`](btcusd1min/) | BTCUSD M1 | |
| [`rsi-divergence/`](rsi-divergence/) | Divergence detector + EA |
| [`dummy/`](dummy/) | XAUUSD sandbox | Full train → ONNX → backtest walkthrough |

## Quick start (sandbox)

```bash
cd ai/dummy
pip install -r requirements.txt
python train_onnx_model.py
python quick_backtest.py
```

Trained artifacts (`models/*.onnx`, `*.pkl`) are **gitignored** — generate locally after clone.

## MQL5 integration

Each project includes an `.mq5` EA that loads ONNX via `#resource` or file path. See per-folder `README.md` and `MT5_SETUP.md` (dummy).

## Requirements

- Python 3.10+
- `MetaTrader5`, `onnxruntime`, `scikit-learn`, `pandas`, `numpy`
- Local MT5 terminal with history for your symbol
