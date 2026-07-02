"""
SimpleEMA v4 — regime-aware dual entry + partial take-profit.

Changes vs v3:
  1. Chop filter: skip when fast/slow crossed too often recently
  2. Trend quality: ADX rising + EMA gap scaled by ATR (not fixed pips)
  3. Dual entry: EMA cross OR deep pullback in established trend
  4. Partial TP: scale out at TP1, trail remainder toward TP2
"""

from __future__ import annotations

from dataclasses import dataclass

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from indicator_utils import calculate_adx, calculate_atr, calculate_dmi, calculate_ema  # noqa: E402


@dataclass
class V4Params:
    fast_ema: int = 10
    slow_ema: int = 42
    entry_mode: int = 1  # 0=cross, 1=cross+pullback, 2=pullback
    min_ema_gap_atr: float = 0.12
    chop_lookback: int = 24
    max_chop_crosses: int = 1
    pullback_swing_bars: int = 12
    pullback_min_depth_atr: float = 0.35
    adx_rising_bars: int = 3
    cooldown_bars: int = 5
    atr_period: int = 14
    atr_sl_mult: float = 2.2
    tp1_atr_mult: float = 1.8
    tp1_close_pct: float = 0.5
    tp2_atr_mult: float = 5.5
    max_bars_in_trade: int = 80
    htf_ema_period: int = 100
    adx_period: int = 14
    adx_min: float = 20.0
    adx_max: float = 45.0
    min_atr_pips: float = 3.0
    max_atr_pips: float = 24.0
    slope_lookback: int = 5
    require_bullish_bar: bool = True
    use_di_filter: bool = True
    use_partial_tp: bool = True
    use_trail_after_tp1: bool = True
    trail_atr_mult: float = 1.4
    be_offset_pips: float = 1.0
    session_start: int = 8
    session_end: int = 21
    max_spread_pips: float = 8.0
    lot_size: float = 0.10
    initial_balance: float = 10_000.0


@dataclass
class V4Market:
    df: pd.DataFrame
    open_: np.ndarray
    high: np.ndarray
    low: np.ndarray
    close: np.ndarray
    hours: np.ndarray
    fast: np.ndarray
    slow: np.ndarray
    atr: np.ndarray
    adx: np.ndarray
    plus_di: np.ndarray
    minus_di: np.ndarray
    htf: np.ndarray


@dataclass
class V4Result:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe: float
    trades: list[dict]


@dataclass
class V4Cache:
    df: pd.DataFrame
    open_: np.ndarray
    high: np.ndarray
    low: np.ndarray
    close: np.ndarray
    hours: np.ndarray
    fast: dict[int, np.ndarray]
    slow: dict[int, np.ndarray]
    atr: dict[int, np.ndarray]
    adx: dict[int, np.ndarray]
    plus_di: dict[int, np.ndarray]
    minus_di: dict[int, np.ndarray]
    htf: dict[int, np.ndarray]


def load_v4_cache(df: pd.DataFrame) -> V4Cache:
    close_s = df["close"]
    h4 = close_s.resample("4h").last().dropna()
    return V4Cache(
        df=df,
        open_=df["open"].to_numpy(),
        high=df["high"].to_numpy(),
        low=df["low"].to_numpy(),
        close=close_s.to_numpy(),
        hours=df.index.hour.to_numpy(),
        fast={p: calculate_ema(close_s, p).to_numpy() for p in range(6, 14)},
        slow={p: calculate_ema(close_s, p).to_numpy() for p in range(28, 55, 2)},
        atr={p: calculate_atr(df, p).to_numpy() for p in (10, 14, 20)},
        adx={p: calculate_adx(df, p).to_numpy() for p in (10, 14, 20)},
        plus_di={p: calculate_dmi(df, p)["plus_di"].to_numpy() for p in (10, 14, 20)},
        minus_di={p: calculate_dmi(df, p)["minus_di"].to_numpy() for p in (10, 14, 20)},
        htf={p: calculate_ema(h4, p).reindex(df.index, method="ffill").to_numpy() for p in (50, 100, 200)},
    )


def market_from_cache(cache: V4Cache, p: V4Params) -> V4Market:
    return V4Market(
        df=cache.df,
        open_=cache.open_,
        high=cache.high,
        low=cache.low,
        close=cache.close,
        hours=cache.hours,
        fast=cache.fast[p.fast_ema],
        slow=cache.slow[p.slow_ema],
        atr=cache.atr[p.atr_period],
        adx=cache.adx[p.adx_period],
        plus_di=cache.plus_di[p.adx_period],
        minus_di=cache.minus_di[p.adx_period],
        htf=cache.htf[p.htf_ema_period],
    )


def _session_ok(hours: np.ndarray, start: int, end: int) -> np.ndarray:
    if start <= 0 and end >= 24:
        return np.ones(len(hours), dtype=bool)
    if start < end:
        return (hours >= start) & (hours < end)
    return (hours >= start) | (hours < end)


def _rolling_cross_count(fast: np.ndarray, slow: np.ndarray, lookback: int) -> np.ndarray:
    n = len(fast)
    f1, f2 = np.roll(fast, 1), np.roll(fast, 2)
    s1, s2 = np.roll(slow, 1), np.roll(slow, 2)
    cross = ((f2 <= s2) & (f1 > s1)) | ((f2 >= s2) & (f1 < s1))
    out = np.zeros(n, dtype=np.int32)
    for i in range(lookback, n):
        out[i] = int(np.sum(cross[i - lookback + 1 : i + 1]))
    return out


def _rolling_max(arr: np.ndarray, window: int) -> np.ndarray:
    s = pd.Series(arr)
    return s.shift(1).rolling(window, min_periods=1).max().to_numpy()


def _rolling_min(arr: np.ndarray, window: int) -> np.ndarray:
    s = pd.Series(arr)
    return s.shift(1).rolling(window, min_periods=1).min().to_numpy()


def build_v4_signals(md: V4Market, p: V4Params, pip: float) -> tuple[np.ndarray, np.ndarray]:
    n = len(md.close)
    lb = max(p.slope_lookback, 1)
    rb = max(p.adx_rising_bars, 1)

    f1 = np.roll(md.fast, 1)
    s1 = np.roll(md.slow, 1)
    f2 = np.roll(md.fast, 2)
    s2 = np.roll(md.slow, 2)
    c1 = np.roll(md.close, 1)
    o1 = np.roll(md.open_, 1)
    h1 = np.roll(md.high, 1)
    l1 = np.roll(md.low, 1)
    htf1 = np.roll(md.htf, 1)
    adx1 = np.roll(md.adx, 1)
    adx_rb = np.roll(md.adx, 1 + rb)
    pdi1 = np.roll(md.plus_di, 1)
    mdi1 = np.roll(md.minus_di, 1)
    atr1 = np.roll(md.atr, 1)
    slow_old = np.roll(md.slow, lb)

    atr_pips = atr1 / pip
    atr_ok = (atr_pips >= p.min_atr_pips) & (atr_pips <= p.max_atr_pips)
    adx_ok = (adx1 >= p.adx_min) & (adx1 <= p.adx_max)
    adx_rising = adx1 > adx_rb
    sess = _session_ok(np.roll(md.hours, 1), p.session_start, p.session_end)
    chop = _rolling_cross_count(md.fast, md.slow, p.chop_lookback)
    chop_ok = chop <= p.max_chop_crosses

    gap_ok = np.abs(f1 - s1) >= atr1 * p.min_ema_gap_atr
    bull_bar = (c1 > o1) if p.require_bullish_bar else np.ones(n, dtype=bool)
    bear_bar = (c1 < o1) if p.require_bullish_bar else np.ones(n, dtype=bool)
    di_long = (pdi1 > mdi1) if p.use_di_filter else np.ones(n, dtype=bool)
    di_short = (mdi1 > pdi1) if p.use_di_filter else np.ones(n, dtype=bool)

    slow_up = s1 > slow_old
    slow_dn = s1 < slow_old
    long_regime = (f1 > s1) & (c1 > htf1) & (c1 > s1) & slow_up
    short_regime = (f1 < s1) & (c1 < htf1) & (c1 < s1) & slow_dn
    regime = long_regime | short_regime

    base = regime & gap_ok & atr_ok & adx_ok & adx_rising & sess & chop_ok

    bull_cross = (f2 <= s2) & (f1 > s1)
    bear_cross = (f2 >= s2) & (f1 < s1)

    swing_hi = _rolling_max(md.high, p.pullback_swing_bars)
    swing_lo = _rolling_min(md.low, p.pullback_swing_bars)
    depth_long = (swing_hi - l1) >= atr1 * p.pullback_min_depth_atr
    depth_short = (h1 - swing_lo) >= atr1 * p.pullback_min_depth_atr

    pb_long = long_regime & (l1 <= f1) & (c1 > f1) & depth_long & bull_bar
    pb_short = short_regime & (h1 >= f1) & (c1 < f1) & depth_short & bear_bar

    if p.entry_mode == 0:
        buy_raw, sell_raw = bull_cross, bear_cross
    elif p.entry_mode == 2:
        buy_raw, sell_raw = pb_long, pb_short
    else:
        buy_raw = bull_cross | pb_long
        sell_raw = bear_cross | pb_short

    buy = buy_raw & base & di_long
    sell = sell_raw & base & di_short

    warm = max(p.slow_ema + lb + p.chop_lookback + 5, 40)
    buy[:warm] = False
    sell[:warm] = False
    return buy, sell


def simulate_v4(md: V4Market, symbol: str, p: V4Params, costs, pip: float, point: float) -> V4Result:
    buy_sig, sell_sig = build_v4_signals(md, p, pip)
    opn, high, low, close, atr = md.open_, md.high, md.low, md.close, md.atr

    spread_px = costs.spread_points * point
    slip = costs.slippage_points * point
    half = spread_px / 2.0 + slip
    commission = costs.commission_per_lot * p.lot_size * 2.0
    be_off = p.be_offset_pips * pip

    balance = p.initial_balance
    equity = [balance]
    trades: list[dict] = []
    side = None
    entry = 0.0
    entry_i = 0
    sl_px = 0.0
    tp_px = 0.0
    tp1_px = 0.0
    lot_frac = 1.0
    tp1_done = False
    trail = 0.0
    last_entry_i = -10_000

    def calc_profit(entry_px: float, exit_px: float, s: str, frac: float = 1.0) -> float:
        lot = p.lot_size * frac
        ot = mt5.ORDER_TYPE_BUY if s == "BUY" else mt5.ORDER_TYPE_SELL
        pr = mt5.order_calc_profit(ot, symbol, lot, entry_px, exit_px)
        comm = costs.commission_per_lot * lot * 2.0
        return float(pr) - comm if pr is not None else -comm

    warm = max(p.slow_ema + p.chop_lookback + 10, 40)
    for i in range(warm, len(md.df)):
        atr1 = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
        mid = float(opn[i])

        if side is not None:
            closed = False
            bars_held = i - entry_i

            if p.max_bars_in_trade > 0 and bars_held >= p.max_bars_in_trade:
                xp = mid - half if side == "BUY" else mid + half
                pr = calc_profit(entry, xp, side, lot_frac)
                balance += pr
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "max_bars"})
                closed = True

            if not closed and side == "BUY":
                if p.use_partial_tp and not tp1_done and high[i] >= tp1_px:
                    pr1 = calc_profit(entry, tp1_px - half, side, p.tp1_close_pct)
                    balance += pr1
                    tp1_done = True
                    lot_frac = 1.0 - p.tp1_close_pct
                    sl_px = max(sl_px, entry + be_off)
                    tp_px = entry + atr1 * p.tp2_atr_mult if atr1 > 0 else tp_px

                if tp1_done and p.use_trail_after_tp1 and atr1 > 0:
                    cand = high[i] - atr1 * p.trail_atr_mult
                    if cand > entry:
                        trail = max(trail, cand) if trail > 0 else cand
                        sl_px = max(sl_px, trail)

                eff_sl = sl_px
                if low[i] <= eff_sl:
                    reason = "trail" if trail > 0 and eff_sl > entry + be_off else ("be" if tp1_done else "sl")
                    pr = calc_profit(entry, eff_sl - half, side, lot_frac)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": reason})
                    closed = True
                elif high[i] >= tp_px:
                    pr = calc_profit(entry, tp_px - half, side, lot_frac)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp2" if tp1_done else "tp"})
                    closed = True

            elif not closed and side == "SELL":
                if p.use_partial_tp and not tp1_done and low[i] <= tp1_px:
                    pr1 = calc_profit(entry, tp1_px + half, side, p.tp1_close_pct)
                    balance += pr1
                    tp1_done = True
                    lot_frac = 1.0 - p.tp1_close_pct
                    sl_px = min(sl_px, entry - be_off)
                    tp_px = entry - atr1 * p.tp2_atr_mult if atr1 > 0 else tp_px

                if tp1_done and p.use_trail_after_tp1 and atr1 > 0:
                    cand = low[i] + atr1 * p.trail_atr_mult
                    if cand < entry:
                        trail = min(trail, cand) if trail > 0 else cand
                        sl_px = min(sl_px, trail)

                eff_sl = sl_px
                if high[i] >= eff_sl:
                    reason = "trail" if trail > 0 and eff_sl < entry - be_off else ("be" if tp1_done else "sl")
                    pr = calc_profit(entry, eff_sl + half, side, lot_frac)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": reason})
                    closed = True
                elif low[i] <= tp_px:
                    pr = calc_profit(entry, tp_px + half, side, lot_frac)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp2" if tp1_done else "tp"})
                    closed = True

            if closed:
                side = None
                tp1_done = False
                lot_frac = 1.0
                trail = 0.0

        if side is None:
            spread_pips = spread_px / pip if pip > 0 else 0
            if (p.max_spread_pips <= 0 or spread_pips <= p.max_spread_pips) and i - last_entry_i >= p.cooldown_bars:
                if buy_sig[i] and atr1 > 0:
                    side = "BUY"
                    entry = mid + half
                    entry_i = i
                    sl_px = entry - atr1 * p.atr_sl_mult
                    tp1_px = entry + atr1 * p.tp1_atr_mult
                    tp_px = entry + atr1 * (p.tp2_atr_mult if p.use_partial_tp else p.tp1_atr_mult)
                    tp1_done = False
                    lot_frac = 1.0
                    trail = 0.0
                    last_entry_i = i
                elif sell_sig[i] and atr1 > 0:
                    side = "SELL"
                    entry = mid - half
                    entry_i = i
                    sl_px = entry + atr1 * p.atr_sl_mult
                    tp1_px = entry - atr1 * p.tp1_atr_mult
                    tp_px = entry - atr1 * (p.tp2_atr_mult if p.use_partial_tp else p.tp1_atr_mult)
                    tp1_done = False
                    lot_frac = 1.0
                    trail = 0.0
                    last_entry_i = i

        mark = balance
        if side == "BUY":
            mark += calc_profit(entry, float(close[i - 1]), side, lot_frac) + costs.commission_per_lot * p.lot_size * lot_frac * 2.0
        elif side == "SELL":
            mark += calc_profit(entry, float(close[i - 1]), side, lot_frac) + costs.commission_per_lot * p.lot_size * lot_frac * 2.0
        equity.append(mark)

    if side is not None:
        pr = calc_profit(entry, float(close[-1]), side, lot_frac)
        balance += pr
        trades.append({"side": side, "open_i": entry_i, "close_i": len(md.df) - 1, "profit": pr, "exit_reason": "eod"})

    eq = pd.Series(equity[: len(md.df)], index=md.df.index[: len(equity)])
    net = balance - p.initial_balance
    wins = [t["profit"] for t in trades if t["profit"] > 0]
    losses = [t["profit"] for t in trades if t["profit"] <= 0]
    gp = sum(wins) if wins else 0.0
    gl = abs(sum(losses)) if losses else 0.0
    pf = gp / gl if gl > 0 else 0.0
    wr = 100.0 * len(wins) / len(trades) if trades else 0.0
    dd = abs(float(((eq - eq.cummax()) / eq.cummax() * 100).min())) if len(eq) else 0.0
    rets = eq.pct_change().dropna()
    sharpe = float(rets.mean() / rets.std() * np.sqrt(252 * 24 * 4)) if len(rets) > 1 and rets.std() > 0 else 0.0
    return V4Result(net, len(trades), wr, pf, dd, sharpe, trades)


def sample_v4(rng) -> V4Params:
    return V4Params(
        fast_ema=rng.randint(7, 13),
        slow_ema=rng.choice([p for p in range(30, 53, 2)]),
        entry_mode=rng.choice([0, 1, 1, 1]),
        min_ema_gap_atr=round(rng.uniform(0.08, 0.25), 2),
        chop_lookback=rng.choice([16, 20, 24, 32]),
        max_chop_crosses=rng.choice([0, 1, 1, 2]),
        pullback_swing_bars=rng.choice([8, 12, 16]),
        pullback_min_depth_atr=round(rng.uniform(0.2, 0.6), 2),
        adx_rising_bars=rng.choice([2, 3, 4, 5]),
        cooldown_bars=rng.choice([3, 4, 5, 6, 8]),
        atr_period=rng.choice([10, 14, 20]),
        atr_sl_mult=round(rng.uniform(1.8, 2.8), 2),
        tp1_atr_mult=round(rng.uniform(1.4, 2.2), 2),
        tp1_close_pct=rng.choice([0.4, 0.5, 0.5, 0.6]),
        tp2_atr_mult=round(rng.uniform(4.5, 7.0), 2),
        max_bars_in_trade=rng.choice([64, 80, 96]),
        htf_ema_period=rng.choice([50, 100, 200]),
        adx_min=round(rng.uniform(18, 26), 1),
        adx_max=round(rng.uniform(38, 50), 1),
        min_atr_pips=round(rng.uniform(2.0, 5.0), 1),
        max_atr_pips=round(rng.uniform(18, 28), 1),
        slope_lookback=rng.choice([4, 5, 6]),
        require_bullish_bar=rng.choice([True, True, False]),
        use_di_filter=rng.choice([True, True, False]),
        use_partial_tp=rng.choice([True, True, False]),
        use_trail_after_tp1=rng.choice([True, True, False]),
        trail_atr_mult=round(rng.uniform(1.1, 1.8), 2),
        session_start=rng.choice([7, 8]),
        session_end=rng.choice([20, 21, 22]),
        max_spread_pips=rng.choice([6, 8]),
    )


def write_v4_set(p: V4Params, path) -> None:
    lines = [
        "; SimpleEMA v4 — regime dual entry + partial TP",
        "Timeframe=16388",
        f"FastEmaPeriod={p.fast_ema}",
        f"SlowEmaPeriod={p.slow_ema}",
        f"EntryMode={p.entry_mode}",
        f"MinEmaGapAtr={p.min_ema_gap_atr}",
        f"ChopLookback={p.chop_lookback}",
        f"MaxChopCrosses={p.max_chop_crosses}",
        f"PullbackSwingBars={p.pullback_swing_bars}",
        f"PullbackMinDepthAtr={p.pullback_min_depth_atr}",
        f"AdxRisingBars={p.adx_rising_bars}",
        f"CooldownBars={p.cooldown_bars}",
        f"AtrPeriod={p.atr_period}",
        f"AtrSlMult={p.atr_sl_mult}",
        f"Tp1AtrMult={p.tp1_atr_mult}",
        f"Tp1ClosePct={p.tp1_close_pct}",
        f"Tp2AtrMult={p.tp2_atr_mult}",
        f"MaxBarsInTrade={p.max_bars_in_trade}",
        f"HtfEmaPeriod={p.htf_ema_period}",
        f"AdxPeriod={p.adx_period}",
        f"AdxMin={p.adx_min}",
        f"AdxMax={p.adx_max}",
        f"MinAtrPips={p.min_atr_pips}",
        f"MaxAtrPips={p.max_atr_pips}",
        f"SlopeLookback={p.slope_lookback}",
        f"RequireBullishBar={'true' if p.require_bullish_bar else 'false'}",
        f"UseDiFilter={'true' if p.use_di_filter else 'false'}",
        f"UsePartialTp={'true' if p.use_partial_tp else 'false'}",
        f"UseTrailAfterTp1={'true' if p.use_trail_after_tp1 else 'false'}",
        f"TrailAtrMult={p.trail_atr_mult}",
        f"BeOffsetPips={p.be_offset_pips}",
        f"SessionStartHour={p.session_start}",
        f"SessionEndHour={p.session_end}",
        f"MaxSpreadPips={p.max_spread_pips}",
        f"LotSize={p.lot_size}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
