"""Margin helpers — uses MT5 order_calc_margin for realistic portfolio sizing."""

from __future__ import annotations

import MetaTrader5 as mt5


def calc_margin(symbol: str, side: str, volume: float, price: float) -> float:
    ot = mt5.ORDER_TYPE_BUY if side == "BUY" else mt5.ORDER_TYPE_SELL
    m = mt5.order_calc_margin(ot, symbol, volume, price)
    return float(m) if m is not None and m > 0 else 0.0


def max_lot_for_margin(
    symbol: str,
    side: str,
    price: float,
    free_margin: float,
    leverage: int = 0,
) -> float:
    """Binary search max lot that fits in free_margin (with 5% buffer)."""
    info = mt5.symbol_info(symbol)
    if info is None or free_margin <= 0:
        return 0.0
    vmin = float(info.volume_min)
    vmax = float(info.volume_max)
    step = float(info.volume_step) or vmin
    budget = free_margin * 0.95
    lo, hi = vmin, vmax
    best = 0.0
    for _ in range(24):
        mid = (lo + hi) / 2
        m = calc_margin(symbol, side, mid, price)
        if m <= budget:
            best = mid
            lo = mid
        else:
            hi = mid
    if step > 0 and best > 0:
        best = max(vmin, (int(best / step)) * step)
    return best


def normalize_volume(symbol: str, volume: float) -> float:
    info = mt5.symbol_info(symbol)
    if info is None:
        return volume
    vmin = float(info.volume_min)
    vmax = float(info.volume_max)
    step = float(info.volume_step) or vmin
    if step > 0:
        volume = (int(volume / step)) * step
    return max(vmin, min(vmax, volume))
