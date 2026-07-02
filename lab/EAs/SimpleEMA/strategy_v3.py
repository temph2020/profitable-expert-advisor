"""
SimpleEMA v3 — trend pullback engine (shared by main.mq5 mirror + optimizer).

Logic:
  1. H4 EMA defines bias (long above / short below)
  2. M15 slow EMA slope confirms trend
  3. Entry on fast-EMA pullback + optional bullish/bearish bar
  4. ADX + DI filter; ATR band skips chop / spikes
  5. Breakeven after BE trigger; optional ATR trail after BE
"""

from __future__ import annotations

from dataclasses import dataclass

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from indicator_utils import calculate_adx, calculate_atr, calculate_dmi, calculate_ema  # noqa: E402


@dataclass
class V3Params:
    fast_ema: int = 8
    slow_ema: int = 34
    min_ema_gap_pips: float = 1.0
    cooldown_bars: int = 4
    atr_period: int = 14
    atr_sl_mult: float = 2.0
    atr_tp_mult: float = 4.5
    max_bars_in_trade: int = 72
    htf_ema_period: int = 100
    adx_period: int = 14
    adx_min: float = 18.0
    adx_max: float = 42.0
    min_atr_pips: float = 4.0
    max_atr_pips: float = 22.0
    slope_lookback: int = 5
    require_bullish_bar: bool = True
    use_di_filter: bool = True
    use_breakeven: bool = True
    be_trigger_atr: float = 1.0
    be_offset_pips: float = 1.0
    use_trail_after_be: bool = True
    trail_atr_mult: float = 1.2
    session_start: int = 7
    session_end: int = 21
    max_spread_pips: float = 8.0
    lot_size: float = 0.10
    initial_balance: float = 10_000.0


@dataclass
class V3Market:
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
class V3Result:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe: float
    trades: list[dict]


@dataclass
class V3Cache:
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


def load_v3_cache(df: pd.DataFrame) -> V3Cache:
    close_s = df["close"]
    h4 = close_s.resample("4h").last().dropna()
    return V3Cache(
        df=df,
        open_=df["open"].to_numpy(),
        high=df["high"].to_numpy(),
        low=df["low"].to_numpy(),
        close=close_s.to_numpy(),
        hours=df.index.hour.to_numpy(),
        fast={p: calculate_ema(close_s, p).to_numpy() for p in range(6, 13)},
        slow={p: calculate_ema(close_s, p).to_numpy() for p in range(26, 53, 2)},
        atr={p: calculate_atr(df, p).to_numpy() for p in (10, 14, 20)},
        adx={p: calculate_adx(df, p).to_numpy() for p in (10, 14, 20)},
        plus_di={p: calculate_dmi(df, p)["plus_di"].to_numpy() for p in (10, 14, 20)},
        minus_di={p: calculate_dmi(df, p)["minus_di"].to_numpy() for p in (10, 14, 20)},
        htf={p: calculate_ema(h4, p).reindex(df.index, method="ffill").to_numpy() for p in (50, 100, 200)},
    )


def market_from_cache(cache: V3Cache, p: V3Params) -> V3Market:
    return V3Market(
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


def load_v3_market(df: pd.DataFrame, p: V3Params) -> V3Market:
    close_s = df["close"]
    h4 = close_s.resample("4h").last().dropna()
    dmi = calculate_dmi(df, p.adx_period)
    return V3Market(
        df=df,
        open_=df["open"].to_numpy(),
        high=df["high"].to_numpy(),
        low=df["low"].to_numpy(),
        close=close_s.to_numpy(),
        hours=df.index.hour.to_numpy(),
        fast=calculate_ema(close_s, p.fast_ema).to_numpy(),
        slow=calculate_ema(close_s, p.slow_ema).to_numpy(),
        atr=calculate_atr(df, p.atr_period).to_numpy(),
        adx=calculate_adx(df, p.adx_period).to_numpy(),
        plus_di=dmi["plus_di"].to_numpy(),
        minus_di=dmi["minus_di"].to_numpy(),
        htf=calculate_ema(h4, p.htf_ema_period).reindex(df.index, method="ffill").to_numpy(),
    )


def _session_ok(hours: np.ndarray, start: int, end: int) -> np.ndarray:
    if start <= 0 and end >= 24:
        return np.ones(len(hours), dtype=bool)
    if start < end:
        return (hours >= start) & (hours < end)
    return (hours >= start) | (hours < end)


def build_v3_signals(md: V3Market, p: V3Params, pip: float) -> tuple[np.ndarray, np.ndarray]:
    n = len(md.close)
    lb = max(p.slope_lookback, 1)
    slow_slope_up = md.slow > np.roll(md.slow, lb)
    slow_slope_dn = md.slow < np.roll(md.slow, lb)

    c1 = np.roll(md.close, 1)
    o1 = np.roll(md.open_, 1)
    h1 = np.roll(md.high, 1)
    l1 = np.roll(md.low, 1)
    f1 = np.roll(md.fast, 1)
    s1 = np.roll(md.slow, 1)
    htf1 = np.roll(md.htf, 1)
    adx1 = np.roll(md.adx, 1)
    pdi1 = np.roll(md.plus_di, 1)
    mdi1 = np.roll(md.minus_di, 1)
    atr1 = np.roll(md.atr, 1)

    atr_pips = atr1 / pip
    gap_ok = np.abs(f1 - s1) / pip >= p.min_ema_gap_pips
    atr_ok = (atr_pips >= p.min_atr_pips) & (atr_pips <= p.max_atr_pips)
    adx_ok = (adx1 >= p.adx_min) & (adx1 <= p.adx_max)
    sess = _session_ok(np.roll(md.hours, 1), p.session_start, p.session_end)

    bull_bar = (c1 > o1) if p.require_bullish_bar else np.ones(n, dtype=bool)
    bear_bar = (c1 < o1) if p.require_bullish_bar else np.ones(n, dtype=bool)

    di_long = (pdi1 > mdi1) if p.use_di_filter else np.ones(n, dtype=bool)
    di_short = (mdi1 > pdi1) if p.use_di_filter else np.ones(n, dtype=bool)

    long_trend = (f1 > s1) & (c1 > htf1) & slow_slope_up & (c1 > s1)
    short_trend = (f1 < s1) & (c1 < htf1) & slow_slope_dn & (c1 < s1)

    pullback_long = long_trend & (l1 <= f1) & (c1 > f1) & bull_bar
    pullback_short = short_trend & (h1 >= f1) & (c1 < f1) & bear_bar

    buy = pullback_long & gap_ok & atr_ok & adx_ok & sess & di_long
    sell = pullback_short & gap_ok & atr_ok & adx_ok & sess & di_short
    warm = max(p.slow_ema + lb + 3, 30)
    buy[:warm] = False
    sell[:warm] = False
    return buy, sell


def simulate_v3(md: V3Market, symbol: str, p: V3Params, costs, pip: float, point: float) -> V3Result:
    buy_sig, sell_sig = build_v3_signals(md, p, pip)
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
    trail = 0.0
    be_active = False
    last_entry_i = -10_000

    def calc_profit(entry_px: float, exit_px: float, s: str) -> float:
        ot = mt5.ORDER_TYPE_BUY if s == "BUY" else mt5.ORDER_TYPE_SELL
        pr = mt5.order_calc_profit(ot, symbol, p.lot_size, entry_px, exit_px)
        return float(pr) - commission if pr is not None else -commission

    warm = max(p.slow_ema + p.slope_lookback + 5, 30)
    for i in range(warm, len(md.df)):
        atr1 = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
        mid = float(opn[i])

        if side is not None:
            closed = False
            bars_held = i - entry_i

            if p.max_bars_in_trade > 0 and bars_held >= p.max_bars_in_trade:
                xp = mid - half if side == "BUY" else mid + half
                pr = calc_profit(entry, xp, side)
                balance += pr
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "max_bars"})
                closed = True

            if not closed and side == "BUY":
                if p.use_breakeven and not be_active and atr1 > 0 and high[i] >= entry + atr1 * p.be_trigger_atr:
                    be_active = True
                    sl_px = max(sl_px, entry + be_off)
                if be_active and p.use_trail_after_be and atr1 > 0:
                    cand = high[i] - atr1 * p.trail_atr_mult
                    if cand > entry:
                        trail = max(trail, cand) if trail > 0 else cand
                        sl_px = max(sl_px, trail)
                eff_sl = sl_px
                if low[i] <= eff_sl:
                    reason = "trail" if trail > 0 and eff_sl > entry + be_off else ("be" if be_active and eff_sl >= entry else "sl")
                    pr = calc_profit(entry, eff_sl - half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": reason})
                    closed = True
                elif high[i] >= tp_px:
                    pr = calc_profit(entry, tp_px - half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp"})
                    closed = True

            elif not closed and side == "SELL":
                if p.use_breakeven and not be_active and atr1 > 0 and low[i] <= entry - atr1 * p.be_trigger_atr:
                    be_active = True
                    sl_px = min(sl_px, entry - be_off)
                if be_active and p.use_trail_after_be and atr1 > 0:
                    cand = low[i] + atr1 * p.trail_atr_mult
                    if cand < entry:
                        trail = min(trail, cand) if trail > 0 else cand
                        sl_px = min(sl_px, trail)
                eff_sl = sl_px
                if high[i] >= eff_sl:
                    reason = "trail" if trail > 0 and eff_sl < entry - be_off else ("be" if be_active and eff_sl <= entry else "sl")
                    pr = calc_profit(entry, eff_sl + half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": reason})
                    closed = True
                elif low[i] <= tp_px:
                    pr = calc_profit(entry, tp_px + half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp"})
                    closed = True

            if closed:
                side = None
                be_active = False
                trail = 0.0

        if side is None:
            spread_pips = spread_px / pip if pip > 0 else 0
            if (p.max_spread_pips <= 0 or spread_pips <= p.max_spread_pips) and i - last_entry_i >= p.cooldown_bars:
                if buy_sig[i] and atr1 > 0:
                    side = "BUY"
                    entry = mid + half
                    entry_i = i
                    sl_px = entry - atr1 * p.atr_sl_mult
                    tp_px = entry + atr1 * p.atr_tp_mult
                    be_active = False
                    trail = 0.0
                    last_entry_i = i
                elif sell_sig[i] and atr1 > 0:
                    side = "SELL"
                    entry = mid - half
                    entry_i = i
                    sl_px = entry + atr1 * p.atr_sl_mult
                    tp_px = entry - atr1 * p.atr_tp_mult
                    be_active = False
                    trail = 0.0
                    last_entry_i = i

        mark = balance
        if side == "BUY":
            mark += calc_profit(entry, float(close[i - 1]), side) + commission
        elif side == "SELL":
            mark += calc_profit(entry, float(close[i - 1]), side) + commission
        equity.append(mark)

    if side is not None:
        pr = calc_profit(entry, float(close[-1]), side)
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
    return V3Result(net, len(trades), wr, pf, dd, sharpe, trades)


def sample_v3(rng) -> V3Params:
    return V3Params(
        fast_ema=rng.randint(6, 12),
        slow_ema=rng.choice([p for p in range(28, 51, 2)]),
        min_ema_gap_pips=round(rng.uniform(0.5, 3.0), 1),
        cooldown_bars=rng.choice([3, 4, 5, 6]),
        atr_period=rng.choice([10, 14, 20]),
        atr_sl_mult=round(rng.uniform(1.6, 2.8), 2),
        atr_tp_mult=round(rng.uniform(3.5, 6.5), 2),
        max_bars_in_trade=rng.choice([48, 72, 96]),
        htf_ema_period=rng.choice([50, 100, 200]),
        adx_min=round(rng.uniform(16, 24), 1),
        adx_max=round(rng.uniform(35, 50), 1),
        min_atr_pips=round(rng.uniform(2.0, 6.0), 1),
        max_atr_pips=round(rng.uniform(15, 30), 1),
        slope_lookback=rng.choice([4, 5, 6, 8]),
        require_bullish_bar=rng.choice([True, True, False]),
        use_di_filter=rng.choice([True, True, False]),
        use_breakeven=rng.choice([True, True, False]),
        be_trigger_atr=round(rng.uniform(0.8, 1.5), 2),
        use_trail_after_be=rng.choice([True, False]),
        trail_atr_mult=round(rng.uniform(1.0, 1.8), 2),
        session_start=rng.choice([6, 7, 8]),
        session_end=rng.choice([20, 21, 22]),
        max_spread_pips=rng.choice([6, 8]),
    )


def write_v3_set(p: V3Params, path) -> None:
    lines = [
        "; SimpleEMA v3 — trend pullback",
        "Timeframe=16388",
        f"FastEmaPeriod={p.fast_ema}",
        f"SlowEmaPeriod={p.slow_ema}",
        f"MinEmaGapPips={p.min_ema_gap_pips}",
        f"CooldownBars={p.cooldown_bars}",
        f"AtrPeriod={p.atr_period}",
        f"AtrSlMult={p.atr_sl_mult}",
        f"AtrTpMult={p.atr_tp_mult}",
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
        f"UseBreakeven={'true' if p.use_breakeven else 'false'}",
        f"BeTriggerAtr={p.be_trigger_atr}",
        f"BeOffsetPips={p.be_offset_pips}",
        f"UseTrailAfterBe={'true' if p.use_trail_after_be else 'false'}",
        f"TrailAtrMult={p.trail_atr_mult}",
        f"SessionStartHour={p.session_start}",
        f"SessionEndHour={p.session_end}",
        f"MaxSpreadPips={p.max_spread_pips}",
        f"LotSize={p.lot_size}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
