"""
Buy-low / sell-high style labels for OHLCV bars (no fixed SL/TP in labels).

Optional context: frontline RSI strategies (Asian reversal, scalping, mid-50)
are encoded as *features* in features.py (crosses, velocity, session), not as
hard rules here — the network learns joint patterns with price/volume.

Classes (integer, matches EA):
  0 HOLD
  1 BUY          — forward upside vs ATR + local swing low
  2 SELL_SHORT   — forward downside vs ATR + local swing high
  3 CLOSE_LONG   — past-only: pullback from recent range high
  4 CLOSE_SHORT  — past-only: bounce from recent range low

CLOSE_* use only bars <= t (no future leak).
BUY/SELL use forward window [t+1, t+horizon] (supervised targets).
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def atr_series(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high, low, close = df["high"], df["low"], df["close"]
    tr = pd.concat(
        [
            high - low,
            (high - close.shift()).abs(),
            (low - close.shift()).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.rolling(period).mean()


def compute_action_labels(
    df: pd.DataFrame,
    *,
    horizon: int = 32,
    local_window: int = 24,
    pullback_window: int = 20,
    k_forward_atr: float = 0.75,
    local_pct: float = 0.28,
    pullback_mult: float = 0.55,
    trend_mult: float = 1.05,
) -> pd.Series:
    """
    Return a Series of int labels 0..4 aligned to df index.
    Last `horizon` rows → HOLD (no forward path for buy/sell scoring).
    """
    close = df["close"].values
    high = df["high"].values
    low = df["low"].values
    n = len(df)
    atr = atr_series(df, 14).values
    labels = np.zeros(n, dtype=np.int64)

    lw = local_window
    pw = pullback_window
    need = max(lw, pw) + 2

    for t in range(n):
        if t < need or t >= n - horizon:
            labels[t] = 0
            continue

        a = atr[t]
        if not np.isfinite(a) or a <= 0:
            a = close[t] * 1e-4

        sl = low[t + 1 : t + horizon + 1]
        sh = high[t + 1 : t + horizon + 1]
        fwd_max = float(np.max(sh))
        fwd_min = float(np.min(sl))
        up_move = (fwd_max - close[t]) / a
        down_move = (close[t] - fwd_min) / a

        loc_low = float(np.min(low[t - lw : t + 1]))
        loc_high = float(np.max(high[t - lw : t + 1]))
        rng = max(loc_high - loc_low, a * 0.15)
        near_low = (close[t] - loc_low) / rng <= local_pct
        near_high = (loc_high - close[t]) / rng <= local_pct

        buy_sig = near_low and (up_move >= k_forward_atr) and (up_move >= down_move * 0.85)
        sell_sig = near_high and (down_move >= k_forward_atr) and (down_move > up_move * 1.05)

        # Past window [t-pw, t]
        seg_h = high[t - pw : t + 1]
        seg_l = low[t - pw : t + 1]
        rh = float(np.max(seg_h))
        rl = float(np.min(seg_l))
        range_atr = (rh - rl) / a
        pull_from_high = (rh - close[t]) / a
        bounce_from_low = (close[t] - rl) / a

        exit_long = (
            range_atr >= trend_mult
            and pull_from_high >= pullback_mult
            and close[t] < close[t - 1]
        )
        exit_short = (
            range_atr >= trend_mult
            and bounce_from_low >= pullback_mult
            and close[t] > close[t - 1]
        )

        if exit_long and not buy_sig:
            labels[t] = 3
        elif exit_short and not sell_sig:
            labels[t] = 4
        elif buy_sig and not sell_sig:
            labels[t] = 1
        elif sell_sig and not buy_sig:
            labels[t] = 2
        elif buy_sig and sell_sig:
            labels[t] = 1 if up_move >= down_move else 2
        else:
            labels[t] = 0

    return pd.Series(labels, index=df.index, name="action_label")


def class_weights(y: np.ndarray, n_classes: int = 5) -> dict[int, float]:
    from sklearn.utils.class_weight import compute_class_weight

    y_int = y.astype(int)
    classes = np.arange(n_classes)
    cw = compute_class_weight("balanced", classes=classes, y=y_int)
    return {i: float(cw[i]) for i in range(n_classes)}
