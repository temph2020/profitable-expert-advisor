"""
Indicator calculation utilities for backtesting.

These functions calculate indicators directly from price data,
without requiring MT5 indicator handles.
"""

import numpy as np
import pandas as pd


def calculate_rsi(prices: pd.Series, period: int = 14) -> pd.Series:
    """Calculate RSI with Wilder smoothing (matches MT5 iRSI)."""
    delta = prices.diff()
    gain = delta.clip(lower=0)
    loss = (-delta).clip(lower=0)
    avg_gain = gain.ewm(alpha=1 / period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def calculate_ema(prices: pd.Series, period: int = 50) -> pd.Series:
    """Calculate EMA indicator."""
    return prices.ewm(span=period, adjust=False).mean()


def calculate_sma(prices: pd.Series, period: int = 50) -> pd.Series:
    """Calculate SMA indicator."""
    return prices.rolling(window=period).mean()


def calculate_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Calculate ATR with Wilder smoothing (matches MT5 iATR)."""
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False).mean()


def calculate_adx(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Calculate ADX indicator (Wilder smoothing)."""
    return calculate_dmi(df, period)["adx"]


def calculate_dmi(df: pd.DataFrame, period: int = 14) -> pd.DataFrame:
    """Calculate +DI, -DI, and ADX."""
    high = df["high"]
    low = df["low"]
    close = df["close"]
    up = high.diff()
    down = -low.diff()
    plus_dm = up.where((up > down) & (up > 0), 0.0)
    minus_dm = down.where((down > up) & (down > 0), 0.0)
    tr = pd.concat([high - low, (high - close.shift()).abs(), (low - close.shift()).abs()], axis=1).max(axis=1)
    atr = tr.ewm(alpha=1 / period, adjust=False).mean()
    plus_di = 100 * (plus_dm.ewm(alpha=1 / period, adjust=False).mean() / atr.replace(0, np.nan))
    minus_di = 100 * (minus_dm.ewm(alpha=1 / period, adjust=False).mean() / atr.replace(0, np.nan))
    dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    adx = dx.ewm(alpha=1 / period, adjust=False).mean()
    return pd.DataFrame({"plus_di": plus_di, "minus_di": minus_di, "adx": adx})


def calculate_macd(prices: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9) -> pd.DataFrame:
    """Calculate MACD indicator."""
    ema_fast = prices.ewm(span=fast, adjust=False).mean()
    ema_slow = prices.ewm(span=slow, adjust=False).mean()
    macd = ema_fast - ema_slow
    signal_line = macd.ewm(span=signal, adjust=False).mean()
    histogram = macd - signal_line
    
    return pd.DataFrame({
        'macd': macd,
        'signal': signal_line,
        'histogram': histogram
    })
