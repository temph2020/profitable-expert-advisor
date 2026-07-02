"""
SimpleEMA v5 — trend-leg pullback engine.

Core idea:
  - Cross entries use the proven v2-style filter stack (HTF + session + gap).
  - Pullback entries only inside an active trend leg (bars since last same-dir cross).
  - Avoids chop without stacking ADX-rising / chop-count on every signal.
"""

from __future__ import annotations

from dataclasses import dataclass

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from indicator_utils import calculate_adx, calculate_atr, calculate_ema  # noqa: E402


@dataclass
class V5Params:
    fast_ema: int = 10
    slow_ema: int = 46
    trend_leg_bars: int = 48
    min_ema_gap_pips: float = 1.5
    cross_cooldown: int = 8
    pullback_cooldown: int = 3
    use_pullback: bool = True
    pullback_touch: int = 0  # 0=fast EMA, 1=slow EMA
    pullback_adx_min: float = 0.0  # 0 = same as cross (no extra)
    pullback_min_gap_pips: float = 0.0  # 0 = use min_ema_gap_pips
    max_pullbacks_per_leg: int = 1
    atr_period: int = 20
    atr_sl_mult: float = 2.71
    atr_tp_mult: float = 6.36
    max_bars_in_trade: int = 64
    htf_ema_period: int = 200
    use_htf_filter: bool = True
    use_adx_filter: bool = False
    adx_period: int = 14
    adx_min: float = 18.0
    session_start: int = 8
    session_end: int = 22
    max_spread_pips: float = 6.0
    lot_size: float = 0.10
    initial_balance: float = 10_000.0


@dataclass
class V5Market:
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
    htf: np.ndarray


@dataclass
class V5Result:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe: float
    trades: list[dict]


@dataclass
class V5Cache:
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
    htf: dict[int, np.ndarray]


def load_v5_cache(df: pd.DataFrame) -> V5Cache:
    close_s = df["close"]
    h4 = close_s.resample("4h").last().dropna()
    return V5Cache(
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
        htf={p: calculate_ema(h4, p).reindex(df.index, method="ffill").to_numpy() for p in (50, 100, 200)},
    )


def market_from_cache(cache: V5Cache, p: V5Params) -> V5Market:
    return V5Market(
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
        htf=cache.htf[p.htf_ema_period],
    )


def _session_ok(hours: np.ndarray, start: int, end: int) -> np.ndarray:
    if start <= 0 and end >= 24:
        return np.ones(len(hours), dtype=bool)
    if start < end:
        return (hours >= start) & (hours < end)
    return (hours >= start) | (hours < end)


def _last_cross_bar(cross: np.ndarray) -> np.ndarray:
    idx = np.arange(len(cross), dtype=np.float64)
    marked = np.where(cross, idx, np.nan)
    return pd.Series(marked).ffill().to_numpy()


def _trend_legs(bull_cross: np.ndarray, bear_cross: np.ndarray, leg_bars: int) -> tuple[np.ndarray, np.ndarray]:
    idx = np.arange(len(bull_cross), dtype=np.int32)
    bull_bar = _last_cross_bar(bull_cross)
    bear_bar = _last_cross_bar(bear_cross)
    bull_ok = ~np.isnan(bull_bar)
    bear_ok = ~np.isnan(bear_bar)
    since_bull = idx - bull_bar
    since_bear = idx - bear_bar

    long_leg = bull_ok & (since_bull <= leg_bars) & (~bear_ok | (bull_bar > bear_bar))
    short_leg = bear_ok & (since_bear <= leg_bars) & (~bull_ok | (bear_bar > bull_bar))
    return long_leg, short_leg


def build_v5_signals(md: V5Market, p: V5Params, pip: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Returns buy_cross, buy_pullback, sell_cross, sell_pullback as separate arrays."""
    n = len(md.close)
    f1 = np.roll(md.fast, 1)
    s1 = np.roll(md.slow, 1)
    f2 = np.roll(md.fast, 2)
    s2 = np.roll(md.slow, 2)
    c1 = np.roll(md.close, 1)
    h1 = np.roll(md.high, 1)
    l1 = np.roll(md.low, 1)
    htf1 = np.roll(md.htf, 1)
    adx1 = np.roll(md.adx, 1)

    bull_cross = (f2 <= s2) & (f1 > s1)
    bear_cross = (f2 >= s2) & (f1 < s1)
    long_leg, short_leg = _trend_legs(bull_cross, bear_cross, p.trend_leg_bars)

    gap_ok = np.abs(f1 - s1) / pip >= p.min_ema_gap_pips
    sess = _session_ok(np.roll(md.hours, 1), p.session_start, p.session_end)
    adx_ok = (adx1 >= p.adx_min) if p.use_adx_filter else np.ones(n, dtype=bool)

    if p.use_htf_filter:
        htf_long = c1 > htf1
        htf_short = c1 < htf1
    else:
        htf_long = htf_short = np.ones(n, dtype=bool)

    base_long = gap_ok & sess & adx_ok & htf_long & (f1 > s1)
    base_short = gap_ok & sess & adx_ok & htf_short & (f1 < s1)

    cross_buy = bull_cross & base_long
    cross_sell = bear_cross & base_short

    touch = f1 if p.pullback_touch == 0 else s1
    pb_buy = np.zeros(n, dtype=bool)
    pb_sell = np.zeros(n, dtype=bool)
    if p.use_pullback:
        pb_gap = p.pullback_min_gap_pips if p.pullback_min_gap_pips > 0 else p.min_ema_gap_pips
        pb_gap_ok = np.abs(f1 - s1) / pip >= pb_gap
        pb_adx_min = p.pullback_adx_min if p.pullback_adx_min > 0 else (p.adx_min if p.use_adx_filter else 0)
        pb_adx_ok = (adx1 >= pb_adx_min) if pb_adx_min > 0 else np.ones(n, dtype=bool)
        pb_base_long = pb_gap_ok & pb_adx_ok & sess & htf_long & (f1 > s1)
        pb_base_short = pb_gap_ok & pb_adx_ok & sess & htf_short & (f1 < s1)
        pb_buy = long_leg & pb_base_long & (l1 <= touch) & (c1 > touch) & ~bull_cross
        pb_sell = short_leg & pb_base_short & (h1 >= touch) & (c1 < touch) & ~bear_cross

    warm = max(p.slow_ema + 5, 30)
    for arr in (cross_buy, cross_sell, pb_buy, pb_sell):
        arr[:warm] = False

    return cross_buy, pb_buy, cross_sell, pb_sell


def simulate_v5(md: V5Market, symbol: str, p: V5Params, costs, pip: float, point: float) -> V5Result:
    cross_buy, pb_buy, cross_sell, pb_sell = build_v5_signals(md, p, pip)
    opn, high, low, close, atr = md.open_, md.high, md.low, md.close, md.atr

    spread_px = costs.spread_points * point
    slip = costs.slippage_points * point
    half = spread_px / 2.0 + slip
    commission = costs.commission_per_lot * p.lot_size * 2.0

    balance = p.initial_balance
    equity = [balance]
    trades: list[dict] = []
    side = None
    entry = 0.0
    entry_i = 0
    sl_px = 0.0
    tp_px = 0.0
    last_cross_i = -10_000
    last_pb_i = -10_000
    leg_pb_count = 0
    active_leg = 0  # 1=long, -1=short

    def calc_profit(entry_px: float, exit_px: float, s: str) -> float:
        ot = mt5.ORDER_TYPE_BUY if s == "BUY" else mt5.ORDER_TYPE_SELL
        pr = mt5.order_calc_profit(ot, symbol, p.lot_size, entry_px, exit_px)
        return float(pr) - commission if pr is not None else -commission

    warm = max(p.slow_ema + 5, 30)
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
            elif side == "BUY":
                if low[i] <= sl_px:
                    pr = calc_profit(entry, sl_px - half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "sl"})
                    closed = True
                elif high[i] >= tp_px:
                    pr = calc_profit(entry, tp_px - half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp"})
                    closed = True
            elif side == "SELL":
                if high[i] >= sl_px:
                    pr = calc_profit(entry, sl_px + half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "sl"})
                    closed = True
                elif low[i] <= tp_px:
                    pr = calc_profit(entry, tp_px + half, side)
                    balance += pr
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": pr, "exit_reason": "tp"})
                    closed = True

            if closed:
                side = None

        # track trend leg for pullback cap
        if cross_buy[i]:
            active_leg = 1
            leg_pb_count = 0
        elif cross_sell[i]:
            active_leg = -1
            leg_pb_count = 0

        if side is None:
            spread_pips = spread_px / pip if pip > 0 else 0
            if p.max_spread_pips <= 0 or spread_pips <= p.max_spread_pips:
                entered = False
                if cross_buy[i] and atr1 > 0 and i - last_cross_i >= p.cross_cooldown:
                    side = "BUY"
                    entry = mid + half
                    entry_i = i
                    sl_px = entry - atr1 * p.atr_sl_mult
                    tp_px = entry + atr1 * p.atr_tp_mult
                    last_cross_i = i
                    entered = True
                elif cross_sell[i] and atr1 > 0 and i - last_cross_i >= p.cross_cooldown:
                    side = "SELL"
                    entry = mid - half
                    entry_i = i
                    sl_px = entry + atr1 * p.atr_sl_mult
                    tp_px = entry - atr1 * p.atr_tp_mult
                    last_cross_i = i
                    entered = True
                elif p.use_pullback and pb_buy[i] and atr1 > 0 and i - last_pb_i >= p.pullback_cooldown:
                    if active_leg == 1 and leg_pb_count < p.max_pullbacks_per_leg:
                        side = "BUY"
                        entry = mid + half
                        entry_i = i
                        sl_px = entry - atr1 * p.atr_sl_mult
                        tp_px = entry + atr1 * p.atr_tp_mult
                        last_pb_i = i
                        leg_pb_count += 1
                        entered = True
                elif p.use_pullback and pb_sell[i] and atr1 > 0 and i - last_pb_i >= p.pullback_cooldown:
                    if active_leg == -1 and leg_pb_count < p.max_pullbacks_per_leg:
                        side = "SELL"
                        entry = mid - half
                        entry_i = i
                        sl_px = entry + atr1 * p.atr_sl_mult
                        tp_px = entry - atr1 * p.atr_tp_mult
                        last_pb_i = i
                        leg_pb_count += 1
                        entered = True
                _ = entered

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
    return V5Result(net, len(trades), wr, pf, dd, sharpe, trades)


def sample_v5(rng) -> V5Params:
    return V5Params(
        fast_ema=rng.randint(8, 12),
        slow_ema=rng.choice([p for p in range(38, 53, 2)]),
        trend_leg_bars=rng.choice([32, 40, 48, 56, 64, 72]),
        min_ema_gap_pips=round(rng.uniform(0.5, 2.5), 1),
        cross_cooldown=rng.choice([6, 7, 8, 9, 10]),
        pullback_cooldown=rng.choice([2, 3, 4, 5]),
        use_pullback=rng.choice([True, False]),
        pullback_touch=rng.choice([0, 1]),
        pullback_adx_min=rng.choice([0.0, 20.0, 22.0, 25.0]),
        pullback_min_gap_pips=rng.choice([0.0, 1.5, 2.0, 2.5]),
        max_pullbacks_per_leg=rng.choice([1, 1, 2]),
        atr_period=rng.choice([14, 20]),
        atr_sl_mult=round(rng.uniform(2.0, 3.2), 2),
        atr_tp_mult=round(rng.uniform(4.5, 7.5), 2),
        max_bars_in_trade=rng.choice([48, 64, 80, 96]),
        htf_ema_period=rng.choice([100, 200]),
        use_htf_filter=rng.choice([True, True, False]),
        use_adx_filter=rng.choice([False, False, True]),
        adx_min=round(rng.uniform(16, 24), 1),
        session_start=rng.choice([7, 8]),
        session_end=rng.choice([21, 22]),
        max_spread_pips=rng.choice([6, 8]),
    )


def write_v5_set(p: V5Params, path) -> None:
    lines = [
        "; SimpleEMA v5 — trend-leg cross + pullback",
        "Timeframe=16388",
        f"FastEmaPeriod={p.fast_ema}",
        f"SlowEmaPeriod={p.slow_ema}",
        f"TrendLegBars={p.trend_leg_bars}",
        f"MinEmaGapPips={p.min_ema_gap_pips}",
        f"CrossCooldown={p.cross_cooldown}",
        f"PullbackCooldown={p.pullback_cooldown}",
        f"UsePullback={'true' if p.use_pullback else 'false'}",
        f"PullbackTouch={p.pullback_touch}",
        f"PullbackAdxMin={p.pullback_adx_min}",
        f"PullbackMinGapPips={p.pullback_min_gap_pips}",
        f"MaxPullbacksPerLeg={p.max_pullbacks_per_leg}",
        f"AtrPeriod={p.atr_period}",
        f"AtrSlMult={p.atr_sl_mult}",
        f"AtrTpMult={p.atr_tp_mult}",
        f"MaxBarsInTrade={p.max_bars_in_trade}",
        f"HtfEmaPeriod={p.htf_ema_period}",
        f"UseHtfFilter={'true' if p.use_htf_filter else 'false'}",
        f"UseAdxFilter={'true' if p.use_adx_filter else 'false'}",
        f"AdxPeriod={p.adx_period}",
        f"AdxMin={p.adx_min}",
        f"SessionStartHour={p.session_start}",
        f"SessionEndHour={p.session_end}",
        f"MaxSpreadPips={p.max_spread_pips}",
        f"LotSize={p.lot_size}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
