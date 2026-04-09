"""
Feature pipeline: base 13 (EA-compatible) + 11 RSI / session features from frontline experience.

Frontline mapping (see FRONTLINE_RSI_INTEGRATION.md):
  - RSIReversalAsianStrategy / RSICrossOverReversal: cross OB/OS, cross 50
  - RSIScalpingStrategy: RSI velocity (bounce from extreme uses 3-bar structure → vel/acc)
  - RSIMidPointHijack: distance from 50, RSI(7) vs RSI(14) spread
  - Asian session gate → binary feature (hour window; offset for server vs UTC)

RSI uses Wilder smoothing (ewm alpha=1/period) to align with MT5 iRSI.
"""

from __future__ import annotations

import os

import numpy as np
import pandas as pd

NUM_BASE_FEATURES = 13
NUM_RSI_EXTRA = 11
NUM_FEATURES = NUM_BASE_FEATURES + NUM_RSI_EXTRA  # 24

# Default thresholds aligned with common frontline inputs (Asian / scalping)
RSI_OVERBOUGHT = 70.0
RSI_OVERSOLD = 30.0


def wilder_rsi(close: pd.Series, period: int) -> np.ndarray:
    """Wilder RSI (matches MetaTrader iRSI closely)."""
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = (-delta).clip(lower=0.0)
    avg_g = gain.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()
    avg_l = loss.ewm(alpha=1.0 / period, min_periods=period, adjust=False).mean()
    rs = avg_g / avg_l.replace(0, np.nan)
    rsi = 100.0 - (100.0 / (1.0 + rs))
    return rsi.fillna(50.0).to_numpy(dtype=np.float64)


def prepare_features_full(
    df: pd.DataFrame,
    *,
    session_hour_offset: int | None = None,
) -> pd.DataFrame:
    """
    Build (N, 24) feature table, chronological index matching df.
    Drops first ~50 rows (warmup) like the original pipeline.
    """
    if session_hour_offset is None:
        session_hour_offset = int(os.environ.get("SESSION_HOUR_OFFSET", "0"))

    o = df["open"].to_numpy(dtype=np.float64)
    h = df["high"].to_numpy(dtype=np.float64)
    l = df["low"].to_numpy(dtype=np.float64)
    c = df["close"].astype(float)
    vol = df["tick_volume"].to_numpy(dtype=np.float64)
    n = len(df)
    idx = df.index

    rsi7 = wilder_rsi(c, 7)
    rsi14 = wilder_rsi(c, 14)
    rsi21 = wilder_rsi(c, 21)

    ema20 = c.ewm(span=20, adjust=False).mean().to_numpy()
    ema50 = c.ewm(span=50, adjust=False).mean().to_numpy()

    tr = np.maximum(
        h - l,
        np.maximum(np.abs(h - np.roll(c.to_numpy(), 1)), np.abs(l - np.roll(c.to_numpy(), 1))),
    )
    tr[0] = h[0] - l[0]
    atr = pd.Series(tr).rolling(14).mean().to_numpy()

    vol_ma = np.zeros(n)
    for j in range(n):
        s = 0.0
        cnt = 0
        for k in range(j, min(j + 20, n)):
            s += vol[k]
            cnt += 1
        vol_ma[j] = s / cnt if cnt else vol[j]

    pc_ea = np.zeros(n)
    cvals = c.to_numpy()
    for j in range(1, n):
        den = cvals[j - 1]
        pc_ea[j] = (cvals[j] - den) / den if den else 0.0

    hours = np.zeros(n, dtype=np.int32)
    for j in range(n):
        ts = idx[j]
        try:
            hts = int(ts.hour)
        except Exception:
            hts = 0
        hours[j] = (hts + session_hour_offset) % 24

    rows = []
    for j in range(n):
        r0 = rsi14[j]
        r1 = rsi14[j - 1] if j > 0 else r0
        r2 = rsi14[j - 2] if j > 1 else r1

        spread = np.clip((r0 - rsi7[j]) / 50.0, -1.0, 1.0)
        vel = (r0 - r1) / 25.0
        acc = ((r0 - r1) - (r1 - r2)) / 25.0
        dist_mid = abs(r0 - 50.0) / 50.0

        cross_ob = 1.0 if (r1 < RSI_OVERBOUGHT and r0 >= RSI_OVERBOUGHT) else 0.0
        cross_os = 1.0 if (r1 > RSI_OVERSOLD and r0 <= RSI_OVERSOLD) else 0.0
        cross_50_up = 1.0 if (r1 < 50.0 and r0 >= 50.0) else 0.0
        cross_50_dn = 1.0 if (r1 > 50.0 and r0 <= 50.0) else 0.0
        asian = 1.0 if (0 <= hours[j] < 8) else 0.0

        rows.append(
            [
                float(o[j]),
                float(h[j]),
                float(l[j]),
                float(cvals[j]),
                float(vol[j] / 1_000_000.0),
                float(rsi14[j] / 100.0),
                float((ema20[j] - cvals[j]) / cvals[j]) if cvals[j] else 0.0,
                float((ema50[j] - cvals[j]) / cvals[j]) if cvals[j] else 0.0,
                float(atr[j] / cvals[j]) if cvals[j] else 0.0,
                float(pc_ea[j]),
                float(h[j] / l[j]) if l[j] else 1.0,
                float(vol_ma[j] / 1_000_000.0),
                float(vol[j] / vol_ma[j]) if vol_ma[j] > 0 else 1.0,
                float(rsi7[j] / 100.0),
                float(rsi21[j] / 100.0),
                float(spread),
                float(vel),
                float(acc),
                float(dist_mid),
                float(cross_ob),
                float(cross_os),
                float(cross_50_up),
                float(cross_50_dn),
                float(asian),
            ]
        )

    cols = [
        "open",
        "high",
        "low",
        "close",
        "tick_volume",
        "rsi",
        "ema20_n",
        "ema50_n",
        "atr_n",
        "price_change",
        "high_low_ratio",
        "volume_ma",
        "volume_ratio",
        "rsi7_n",
        "rsi21_n",
        "rsi_fast_slow_spread",
        "rsi_velocity",
        "rsi_accel",
        "rsi_dist_mid_50",
        "rsi_cross_overbought",
        "rsi_cross_oversold",
        "rsi_cross_50_up",
        "rsi_cross_50_down",
        "session_asian_utc",
    ]

    out = pd.DataFrame(rows, index=idx, columns=cols)
    return out.iloc[50:].copy()
