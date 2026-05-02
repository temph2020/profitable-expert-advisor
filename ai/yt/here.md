# ENKS / clustering article — notes → training in this repo

Summary of the methodology described in the article (MQL5 / ENKS trader clusters):

- Models are trained in **Python**, then converted to **ENKS** for the MetaTrader include/bot stack. This repository does **not** ship an ENKS encoder; training here exports **ONNX + JSON meta + scaler** like `ai/xauusd_h1/`. Convert ENKS with the author’s tool or workflow from the article.
- **Clustering** (article: Cayley / trade matching): use **forward-return fingerprints** per bar and **KMeans** on the in-sample window only, then optional **per-cluster balancing** of sample weights during training (see `train_article_split.py`).
- **Windows**: train **2010-01-01 → 2019-12-31**; out-of-sample / forward **2020-01-01 → 2024-12-31**. Scaler is fit **only** on the train window (no leakage).
- **Capital / Capodon-style US H1**: default symbol `US500` on **H1**; override with `YT_SYMBOL`. The article notes models can be attached on other timeframes; EA SL/TP and filters are tuned separately.
- **Includes (`tendq`, etc.)**: not present in this repo; wire your ONNX EA to the exported `*_meta.json` and scaler like the existing XAUUSD H1 action EA.

## Run training

From `ai/yt` (MetaTrader 5 must be installed and history available for the symbol):

```bash
pip install -r requirements.txt
python train_article_split.py
```

Environment overrides:

| Variable       | Default        | Meaning                          |
|----------------|----------------|----------------------------------|
| `YT_SYMBOL`    | `US500`        | MT5 symbol                       |
| `YT_LOOKBACK`  | `48`           | Sequence length (bars)         |
| `YT_EPOCHS`    | `40`           | Max epochs                     |
| `YT_BATCH`     | `64`           | Batch size                     |
| `YT_CLUSTERS`  | `12`           | KMeans clusters (0 = disable)  |

Outputs: `ai/yt/models/<SYMBOL>_H1_article_split.onnx`, scaler `.pkl`, `*_meta.json`.
