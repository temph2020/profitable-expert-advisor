"""
XAUUSD M15 — ONNX action model (buy / sell short / close long / close short / hold).

Features: 24 dims — base 13 + RSI/frontline stack (see features.py, FRONTLINE_RSI_INTEGRATION.md).
Row order matches XAUUSD_M15_ActionEA.mq5 (row 0 = newest bar).
Data: MT5, 2008–2026 (limited by downloaded history).
"""

from __future__ import annotations

import json
import os
import pickle
import sys
from datetime import datetime, timedelta

import MetaTrader5 as mt5
import numpy as np
import pandas as pd
import tensorflow as tf
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import MinMaxScaler
from tensorflow import keras
from tensorflow.keras import layers
from tqdm import tqdm
import tf2onnx
import onnx

from labeling import class_weights, compute_action_labels
from features import NUM_FEATURES, prepare_features_full

NUM_CLASSES = 5
CLASS_NAMES = ["HOLD", "BUY", "SELL_SHORT", "CLOSE_LONG", "CLOSE_SHORT"]


def fetch_mt5_range(
    symbol: str,
    timeframe: int,
    start_date: datetime,
    end_date: datetime,
) -> pd.DataFrame:
    if not mt5.initialize():
        raise RuntimeError(f"MT5 init failed: {mt5.last_error()}")

    info = mt5.symbol_info(symbol)
    if info is None:
        mt5.shutdown()
        raise ValueError(f"Symbol {symbol} not found")
    if not info.visible and not mt5.symbol_select(symbol, True):
        mt5.shutdown()
        raise ValueError(f"Cannot select {symbol}")

    all_rows: list[dict] = []
    chunk_days = 30
    cur = start_date
    while cur < end_date:
        chunk_end = min(cur + timedelta(days=chunk_days), end_date)
        rates = mt5.copy_rates_range(symbol, timeframe, cur, chunk_end)
        if rates is not None and len(rates) > 1:
            for row in rates:
                all_rows.append({n: row[n] for n in rates.dtype.names})
        cur = chunk_end

    if not all_rows:
        mt5.shutdown()
        raise ValueError("No rates returned — download XAUUSD M15 in MT5 History Center")

    df = pd.DataFrame(all_rows)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df = df.set_index("time").sort_index()
    df = df[~df.index.duplicated(keep="first")]
    return df


def create_sequences(
    X: np.ndarray, y: np.ndarray, lookback: int
) -> tuple[np.ndarray, np.ndarray]:
    """
    Window ends at bar i (chronological). Rows: newest-first inside each window
    (matches MT5 series arrays in EA).
    """
    xs, ys = [], []
    for i in tqdm(range(lookback - 1, len(X)), desc="sequences"):
        window = X[i - lookback + 1 : i + 1].copy()
        window = window[::-1]  # newest bar first → same as EA matrix row 0
        xs.append(window)
        ys.append(y[i])
    return np.asarray(xs, dtype=np.float32), np.asarray(ys, dtype=np.int64)


def build_model(lookback: int, n_feat: int) -> keras.Model:
    inp = layers.Input(shape=(lookback, n_feat))
    x = layers.LSTM(96, return_sequences=True)(inp)
    x = layers.Dropout(0.25)(x)
    x = layers.LSTM(48)(x)
    x = layers.Dropout(0.25)(x)
    x = layers.Dense(32, activation="relu")(x)
    out = layers.Dense(NUM_CLASSES, activation="softmax", name="action_probs")(x)
    model = keras.Model(inp, out)
    model.compile(
        optimizer=keras.optimizers.Adam(1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def main() -> int:
    symbol = os.environ.get("XAU_SYMBOL", "XAUUSD")
    lookback = int(os.environ.get("XAU_LOOKBACK", "64"))
    epochs = int(os.environ.get("XAU_EPOCHS", "40"))
    batch_size = int(os.environ.get("XAU_BATCH", "64"))

    start_date = datetime(2008, 1, 1)
    end_date = datetime(2026, 12, 31)

    out_dir = os.path.join(os.path.dirname(__file__), "models")
    os.makedirs(out_dir, exist_ok=True)
    onnx_path = os.path.join(out_dir, f"{symbol}_M15_action.onnx")
    meta_path = os.path.join(out_dir, f"{symbol}_M15_action_meta.json")

    print("Fetching MT5 data …")
    try:
        raw = fetch_mt5_range(symbol, mt5.TIMEFRAME_M15, start_date, end_date)
    finally:
        mt5.shutdown()
    print(f"Bars: {len(raw)}  range: {raw.index[0]} → {raw.index[-1]}")

    feat = prepare_features_full(raw)
    labels_full = compute_action_labels(raw)
    labels = labels_full.loc[feat.index]

    y = labels.loc[feat.index].values.astype(np.int64)
    X_raw = feat.values.astype(np.float32)

    valid = np.isfinite(X_raw).all(axis=1) & (y >= 0) & (y < NUM_CLASSES)
    X_raw = X_raw[valid]
    y = y[valid]

    print("Label counts:", {CLASS_NAMES[i]: int((y == i).sum()) for i in range(NUM_CLASSES)})

    scaler = MinMaxScaler()
    Xn = scaler.fit_transform(X_raw).astype(np.float32)

    X_seq, y_seq = create_sequences(Xn, y, lookback)
    if len(X_seq) < 500:
        print("ERROR: Too few sequences — need more M15 history in MT5.")
        return 1

    X_train, X_val, y_train, y_val = train_test_split(
        X_seq, y_seq, test_size=0.15, shuffle=False
    )

    cw = class_weights(y_train, NUM_CLASSES)
    sample_w = np.array([cw[int(c)] for c in y_train], dtype=np.float32)

    model = build_model(lookback, NUM_FEATURES)
    model.summary()

    model.fit(
        X_train,
        y_train,
        sample_weight=sample_w,
        validation_data=(X_val, y_val),
        epochs=epochs,
        batch_size=batch_size,
        verbose=1,
        callbacks=[
            keras.callbacks.EarlyStopping(
                monitor="val_loss", patience=8, restore_best_weights=True
            ),
            keras.callbacks.ReduceLROnPlateau(
                monitor="val_loss", factor=0.5, patience=4, min_lr=1e-6
            ),
        ],
    )

    spec = (tf.TensorSpec((None, lookback, NUM_FEATURES), tf.float32, name="input"),)
    onnx_m, _ = tf2onnx.convert.from_keras(model, input_signature=spec, opset=13)
    onnx.save_model(onnx_m, onnx_path)

    with open(onnx_path.replace(".onnx", "_scaler.pkl"), "wb") as f:
        pickle.dump(scaler, f)

    meta = {
        "symbol": symbol,
        "timeframe": "M15",
        "lookback": lookback,
        "num_features": int(NUM_FEATURES),
        "feature_columns": feat.columns.tolist(),
        "num_classes": NUM_CLASSES,
        "class_names": CLASS_NAMES,
        "scaler_feature_min": scaler.data_min_.tolist(),
        "scaler_feature_max": scaler.data_max_.tolist(),
        "scaler_scale": scaler.scale_.tolist() if hasattr(scaler, "scale_") else None,
        "notes": "MinMax in EA; row0=newest. See FRONTLINE_RSI_INTEGRATION.md.",
    }
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"Saved: {onnx_path}")
    print(f"Meta:  {meta_path}")
    print("\n--- Paste into EA InpFeatMinStr / InpFeatMaxStr (comma-separated, %d floats each) ---" % NUM_FEATURES)
    print(",".join(f"{x:.8g}" for x in scaler.data_min_))
    print(",".join(f"{x:.8g}" for x in scaler.data_max_))
    return 0


if __name__ == "__main__":
    sys.exit(main())
