"""
EURUSD H1 — same stack as ai/yt (24 features, 5-class softmax, optional KMeans weights).

MinMaxScaler is fit on **all** feature rows returned by MT5 (full downloaded history).
A chronological **tail** slice (default 12%% of sequences) is used only for val_loss /
EarlyStopping; all earlier sequences are used for training.
"""

from __future__ import annotations

import json
import os
import pickle
import sys
from datetime import datetime, timedelta
from pathlib import Path

import MetaTrader5 as mt5
import numpy as np
import pandas as pd
import tensorflow as tf
import tf2onnx
import onnx
from sklearn.cluster import KMeans
from sklearn.preprocessing import MinMaxScaler
from tensorflow import keras
from tensorflow.keras import layers
from tqdm import tqdm

_XH1 = Path(__file__).resolve().parent.parent / "xauusd_h1"
sys.path.insert(0, str(_XH1))
from features import NUM_FEATURES, prepare_features_full  # noqa: E402
from labeling import atr_series, class_weights, compute_action_labels  # noqa: E402

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
    chunk_days = 120
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
        raise ValueError("No rates returned — download EURUSD H1 in MT5 History Center")

    df = pd.DataFrame(all_rows)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df = df.set_index("time").sort_index()
    df = df[~df.index.duplicated(keep="first")]
    return df


def forward_return_fingerprints(
    df: pd.DataFrame,
    feat_index: pd.DatetimeIndex,
    horizons: tuple[int, ...] = (1, 2, 4, 8, 16),
) -> tuple[np.ndarray, np.ndarray]:
    close = df["close"].to_numpy(dtype=np.float64)
    atr = atr_series(df, 14).to_numpy(dtype=np.float64)
    pos = df.index.get_indexer(feat_index)
    n = len(feat_index)
    d = len(horizons)
    M = np.zeros((n, d), dtype=np.float64)
    valid = np.ones(n, dtype=bool)
    max_h = max(horizons)
    for j, i in enumerate(pos):
        if i < 0 or i + max_h >= len(close):
            valid[j] = False
            continue
        a = float(atr[i]) if np.isfinite(atr[i]) and atr[i] > 0 else close[i] * 1e-4
        for k, h in enumerate(horizons):
            if i + h >= len(close):
                valid[j] = False
                break
            M[j, k] = (close[i + h] - close[i]) / a
    return M, valid


def create_sequences(
    X: np.ndarray,
    y: np.ndarray,
    times: np.ndarray,
    lookback: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    xs, ys, t_end = [], [], []
    for i in tqdm(range(lookback - 1, len(X)), desc="sequences"):
        window = X[i - lookback + 1 : i + 1].copy()
        window = window[::-1]
        xs.append(window)
        ys.append(y[i])
        t_end.append(times[i])
    return (
        np.asarray(xs, dtype=np.float32),
        np.asarray(ys, dtype=np.int64),
        np.asarray(t_end),
    )


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
    symbol = os.environ.get("EUR_SYMBOL", "EURUSD")
    lookback = int(os.environ.get("EUR_LOOKBACK", "48"))
    epochs = int(os.environ.get("EUR_EPOCHS", "40"))
    batch_size = int(os.environ.get("EUR_BATCH", "64"))
    n_clusters = int(os.environ.get("EUR_CLUSTERS", "12"))
    val_frac = float(os.environ.get("EUR_VAL_FRAC", "0.12"))
    val_frac = min(max(val_frac, 0.05), 0.35)

    fetch_start = datetime(1990, 1, 1)
    fetch_end = datetime(2030, 12, 31)

    out_dir = Path(__file__).resolve().parent / "models"
    out_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = out_dir / f"{symbol}_H1_action.onnx"
    meta_path = out_dir / f"{symbol}_H1_action_meta.json"

    print(f"Symbol={symbol} H1 | fetch [{fetch_start.date()} .. {fetch_end.date()}]")
    print("Scaler: ALL bars | Val: chronological tail for early stopping only")
    print("Fetching MT5 …")
    try:
        raw = fetch_mt5_range(symbol, mt5.TIMEFRAME_H1, fetch_start, fetch_end)
    finally:
        mt5.shutdown()

    if len(raw) < 500:
        print("ERROR: Not enough H1 bars — check EURUSD history in MT5.")
        return 1

    print(f"Bars: {len(raw)}  range: {raw.index[0]} → {raw.index[-1]}")

    feat = prepare_features_full(raw)
    labels = compute_action_labels(raw).loc[feat.index]
    y = labels.values.astype(np.int64)
    X_raw = feat.values.astype(np.float32)
    times = feat.index.to_numpy()

    valid = np.isfinite(X_raw).all(axis=1) & (y >= 0) & (y < NUM_CLASSES)
    X_raw = X_raw[valid]
    y = y[valid]
    times = times[valid]

    scaler = MinMaxScaler()
    scaler.fit(X_raw)
    Xn = scaler.transform(X_raw).astype(np.float32)

    X_seq, y_seq, t_end = create_sequences(Xn, y, times, lookback)
    if len(X_seq) < 500:
        print("ERROR: Too few sequences.")
        return 1

    n_seq = len(X_seq)
    split_i = int(n_seq * (1.0 - val_frac))
    split_i = max(split_i, lookback + 100)
    split_i = min(split_i, n_seq - 200)
    train_m = np.zeros(n_seq, dtype=bool)
    train_m[:split_i] = True
    val_m = ~train_m

    X_train, y_train = X_seq[train_m], y_seq[train_m]
    X_val, y_val = X_seq[val_m], y_seq[val_m]
    print(
        f"Sequences train={len(X_train)} val_tail={len(X_val)} ({100*val_frac:.1f}%%) "
        f"lookback={lookback}"
    )

    cw = class_weights(y_train, NUM_CLASSES)
    tr_idx = np.flatnonzero(train_m)
    base_w = np.array([cw[int(y_seq[i])] for i in tr_idx], dtype=np.float32)
    sample_w = base_w.copy()

    if n_clusters > 1:
        fp, fp_ok = forward_return_fingerprints(raw, pd.DatetimeIndex(times))
        fp_seq = fp[lookback - 1 :]
        ok_seq = fp_ok[lookback - 1 :]
        fp_tr = fp_seq[tr_idx]
        ok_tr = ok_seq[tr_idx]
        fit_mask = ok_tr & np.isfinite(fp_tr).all(axis=1)
        if int(fit_mask.sum()) >= n_clusters * 5:
            km = KMeans(n_clusters=n_clusters, random_state=42, n_init=10)
            km.fit(fp_tr[fit_mask])
            labels_tr = np.full(len(tr_idx), -1, dtype=np.int32)
            labels_tr[fit_mask] = km.predict(fp_tr[fit_mask])
            counts = np.zeros(n_clusters, dtype=np.float64)
            for c in labels_tr:
                if 0 <= c < n_clusters:
                    counts[c] += 1.0
            counts = np.maximum(counts, 1.0)
            total_assigned = max(int((labels_tr >= 0).sum()), 1)
            w_cl = np.ones(len(tr_idx), dtype=np.float32)
            for j in range(len(tr_idx)):
                c = int(labels_tr[j])
                if c >= 0:
                    w_cl[j] = float(total_assigned / (n_clusters * counts[c]))
            sample_w = base_w * w_cl
            sample_w *= len(sample_w) / float(np.sum(sample_w))
            print(f"KMeans clusters={n_clusters} (train subset only)")
        else:
            print("Skipping KMeans: not enough valid fingerprints.")

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
                monitor="val_loss", patience=10, restore_best_weights=True
            ),
            keras.callbacks.ReduceLROnPlateau(
                monitor="val_loss", factor=0.5, patience=4, min_lr=1e-6
            ),
        ],
    )

    loss, acc = model.evaluate(X_val, y_val, verbose=0)
    print(f"Tail val_loss={loss:.4f} val_accuracy={acc:.4f}")

    spec = (tf.TensorSpec((None, lookback, NUM_FEATURES), tf.float32, name="input"),)
    onnx_m, _ = tf2onnx.convert.from_keras(model, input_signature=spec, opset=13)
    onnx.save_model(onnx_m, str(onnx_path))

    with open(str(onnx_path).replace(".onnx", "_scaler.pkl"), "wb") as f:
        pickle.dump(scaler, f)

    meta = {
        "symbol": symbol,
        "timeframe": "H1",
        "lookback": lookback,
        "num_features": int(NUM_FEATURES),
        "feature_columns": feat.columns.tolist(),
        "num_classes": NUM_CLASSES,
        "class_names": CLASS_NAMES,
        "mt5_bar_range": [str(raw.index[0]), str(raw.index[-1])],
        "scaler_fit_on": "all_valid_feature_rows_full_mt5_range",
        "validation_split": {
            "mode": "chronological_tail_fraction",
            "val_fraction": val_frac,
            "train_sequences": int(train_m.sum()),
            "val_sequences": int(val_m.sum()),
        },
        "clustering": (
            f"KMeans n={n_clusters} on forward returns (1,2,4,8,16); train-only fit"
            if n_clusters > 1
            else "disabled"
        ),
        "scaler_feature_min": scaler.data_min_.tolist(),
        "scaler_feature_max": scaler.data_max_.tolist(),
        "scaler_scale": scaler.scale_.tolist() if hasattr(scaler, "scale_") else None,
        "tail_val_accuracy": float(acc),
        "tail_val_loss": float(loss),
        "ea_note": "Copy ai/yt/US500_H1_ArticleEA.mq5 pattern: #resource ONNX + paste scaler from meta.",
    }
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"Saved: {onnx_path}")
    print(f"Meta:  {meta_path}")
    print(
        "\n--- Paste into EA InpFeatMinStr / InpFeatMaxStr (%d floats each) ---"
        % NUM_FEATURES
    )
    print(",".join(f"{x:.8g}" for x in scaler.data_min_))
    print(",".join(f"{x:.8g}" for x in scaler.data_max_))
    print(f"\nSet EA InpLookback = {lookback}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
