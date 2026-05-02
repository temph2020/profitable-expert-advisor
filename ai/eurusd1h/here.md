# EURUSD H1 — ONNX action model (full MT5 history)

Same methodology as `ai/yt/train_article_split.py`:

- **24 features** + **5 softmax classes** (`ai/xauusd_h1/features.py`, `labeling.py`).
- **MinMaxScaler** is fit on **every** valid feature row MT5 returns (no 2010–2020 cut).
- **Training sequences**: all but a **chronological tail** (default **12%**) used only for `val_loss` / EarlyStopping (does not remove data from the scaler).
- Optional **KMeans** on forward-return fingerprints + class-balanced `sample_weight` on the train split.

## Run

```bash
cd ai/eurusd1h
pip install -r requirements.txt
python main.py
```

Requires MetaTrader 5 with **EURUSD H1** history downloaded (Tools → History Center).

## Environment overrides

| Variable        | Default   | Meaning                                      |
|-----------------|-----------|----------------------------------------------|
| `EUR_SYMBOL`    | `EURUSD`  | MT5 symbol                                   |
| `EUR_LOOKBACK`  | `48`      | Sequence length                              |
| `EUR_EPOCHS`    | `40`      | Max epochs                                   |
| `EUR_BATCH`     | `64`      | Batch size                                   |
| `EUR_CLUSTERS`  | `12`      | KMeans clusters (`0` = off)                  |
| `EUR_VAL_FRAC`  | `0.12`    | Fraction of sequences at **end** for val   |

## Outputs

- `models/EURUSD_H1_action.onnx`
- `models/EURUSD_H1_action_meta.json`
- `models/EURUSD_H1_action_scaler.pkl`

Deploy like `ai/yt/US500_H1_ArticleEA.mq5`: embed ONNX, set `InpLookback`, paste `scaler_feature_min` / `max` from the meta JSON into the EA inputs.
