"""
USDCHF Playbook — six behavioral rules from month-long backtest study.

1. Momentum window: entries after NY chaos, hold through late-session momentum.
2. Double-trap: frequent fake breaks — wait for reclaim after second tap.
3. Respect zones: HTF (H4) close confirmation before LTF entry.
4. Avoid NY open chaos: skip high-volatility US open window.
5. News compression: skip tight ranges; trade post-breakout direction.
6. Daily swing bias: D1 EMA defines primary direction; wider targets.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from indicator_utils import calculate_atr, calculate_ema  # noqa: E402


STRATEGY_ID = "USDCHFPlaybook"


@dataclass
class PlaybookParams:
    # Daily swing bias (rule 6)
    daily_ema_period: int = 50
    use_daily_bias: bool = True

    # HTF zones (rule 3)
    htf_zone_bars: int = 20
    min_break_body_ratio: float = 0.55

    # Double trap (rule 2)
    use_double_trap: bool = True
    trap_lookback: int = 6

    # Session (rules 1 & 4) — server/broker hours
    ny_chaos_start: int = 12
    ny_chaos_end: int = 15
    momentum_start: int = 15
    momentum_end: int = 2  # wraps past midnight (hold until ~2am)

    # LTF structure
    ltf_fast_ema: int = 8
    ltf_slow_ema: int = 21
    entry_mode: int = 1  # 0=htf breakout, 1=+pullback, 2=trap reclaim

    # Risk / swing holds (rule 6)
    atr_period: int = 14
    atr_sl_mult: float = 1.8
    atr_tp_mult: float = 4.0
    use_trailing: bool = True
    trail_atr_mult: float = 1.2
    max_bars_in_trade: int = 96
    extend_hold_in_momentum: bool = True

    # News compression proxy (rule 5)
    use_compression_filter: bool = True
    compress_atr_ratio: float = 0.70
    compress_lookback: int = 48

    cooldown_bars: int = 4
    max_spread_pips: float = 8.0
    lot_size: float = 0.10
    initial_balance: float = 10_000.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class MarketPack:
    df: pd.DataFrame
    close: np.ndarray
    open_: np.ndarray
    high: np.ndarray
    low: np.ndarray
    hours: np.ndarray
    atr: np.ndarray
    atr_ma: np.ndarray
    daily_bias: np.ndarray  # +1 bull, -1 bear, 0 neutral
    h4_res: np.ndarray
    h4_sup: np.ndarray
    h4_bull_break: np.ndarray
    h4_bear_break: np.ndarray
    bull_trap: np.ndarray
    bear_trap: np.ndarray
    fast_ema: np.ndarray
    slow_ema: np.ndarray


def pip_size(symbol: str) -> float:
    info = mt5.symbol_info(symbol)
    if not info:
        return 0.0001
    pt = float(info.point)
    return pt * 10.0 if info.digits in (3, 5) else pt


def _hour_in_range(h: int, start: int, end: int) -> bool:
    if start == end:
        return True
    if start < end:
        return start <= h < end
    return h >= start or h < end


def in_momentum_window(hours: np.ndarray, p: PlaybookParams) -> np.ndarray:
    return np.array([_hour_in_range(int(h), p.momentum_start, p.momentum_end) for h in hours])


def in_ny_chaos(hours: np.ndarray, p: PlaybookParams) -> np.ndarray:
    return np.array([_hour_in_range(int(h), p.ny_chaos_start, p.ny_chaos_end) for h in hours])


def _body_ratio(o: float, h: float, l: float, c: float) -> float:
    rng = h - l
    if rng <= 0:
        return 0.0
    return abs(c - o) / rng


def build_market(df: pd.DataFrame, p: PlaybookParams) -> MarketPack:
    close_s = df["close"]
    d1 = close_s.resample("1D").last().dropna()
    d_ema = calculate_ema(d1, p.daily_ema_period)
    bias_s = pd.Series(0, index=d1.index, dtype=float)
    if p.use_daily_bias:
        bias_s = np.where(d1 > d_ema, 1.0, np.where(d1 < d_ema, -1.0, 0.0))
    daily_bias = pd.Series(bias_s, index=d1.index).reindex(df.index, method="ffill").fillna(0).to_numpy()

    h4 = df.resample("4h").agg({"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    h4_res = h4["high"].rolling(p.htf_zone_bars).max().shift(1)
    h4_sup = h4["low"].rolling(p.htf_zone_bars).min().shift(1)
    h4_res_i = h4_res.reindex(df.index, method="ffill").to_numpy()
    h4_sup_i = h4_sup.reindex(df.index, method="ffill").to_numpy()

    h4_o = h4["open"].reindex(df.index, method="ffill").to_numpy()
    h4_h = h4["high"].reindex(df.index, method="ffill").to_numpy()
    h4_l = h4["low"].reindex(df.index, method="ffill").to_numpy()
    h4_c = h4["close"].reindex(df.index, method="ffill").to_numpy()

    bull_body = np.array([_body_ratio(h4_o[i], h4_h[i], h4_l[i], h4_c[i]) for i in range(len(df))])
    h4_bull_break = (h4_c > h4_res_i) & (bull_body >= p.min_break_body_ratio)
    h4_bear_break = (h4_c < h4_sup_i) & (bull_body >= p.min_break_body_ratio)

    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    close = close_s.to_numpy()
    n = len(df)
    bull_trap = np.zeros(n, dtype=bool)
    bear_trap = np.zeros(n, dtype=bool)
    if p.use_double_trap:
        for i in range(2, n):
            # false break above resistance then close back under zone
            if high[i - 1] > h4_res_i[i - 2] and close[i - 1] < h4_res_i[i - 2]:
                bull_trap[i] = True
            if low[i - 1] < h4_sup_i[i - 2] and close[i - 1] > h4_sup_i[i - 2]:
                bear_trap[i] = True

    atr = calculate_atr(df, p.atr_period).to_numpy()
    atr_ma = pd.Series(atr).rolling(p.compress_lookback).mean().to_numpy()

    return MarketPack(
        df=df,
        close=close,
        open_=df["open"].to_numpy(),
        high=high,
        low=low,
        hours=df.index.hour.to_numpy(),
        atr=atr,
        atr_ma=atr_ma,
        daily_bias=daily_bias,
        h4_res=h4_res_i,
        h4_sup=h4_sup_i,
        h4_bull_break=h4_bull_break,
        h4_bear_break=h4_bear_break,
        bull_trap=bull_trap,
        bear_trap=bear_trap,
        fast_ema=calculate_ema(close_s, p.ltf_fast_ema).to_numpy(),
        slow_ema=calculate_ema(close_s, p.ltf_slow_ema).to_numpy(),
    )


def make_signals(md: MarketPack, p: PlaybookParams) -> dict[str, np.ndarray]:
    n = len(md.df)
    momentum = in_momentum_window(md.hours, p)
    chaos = in_ny_chaos(md.hours, p)
    session_ok = momentum & ~chaos

    compress_ok = np.ones(n, dtype=bool)
    if p.use_compression_filter:
        compress_ok = ~(
            (md.atr_ma > 0)
            & (md.atr / np.maximum(md.atr_ma, 1e-12) < p.compress_atr_ratio)
            & chaos
        )

    c1 = np.roll(md.close, 1)
    h1 = np.roll(md.high, 1)
    l1 = np.roll(md.low, 1)
    f1 = np.roll(md.fast_ema, 1)
    s1 = np.roll(md.slow_ema, 1)
    bull_pb = (f1 > s1) & (l1 <= f1) & (c1 > f1)
    bear_pb = (f1 < s1) & (h1 >= f1) & (c1 < f1)

    h4_bull = np.roll(md.h4_bull_break, 1)
    h4_bear = np.roll(md.h4_bear_break, 1)
    bias = md.daily_bias
    bias_bull = (bias >= 0) if p.use_daily_bias else np.ones(n, dtype=bool)
    bias_bear = (bias <= 0) if p.use_daily_bias else np.ones(n, dtype=bool)

    trap_bull = np.roll(md.bull_trap, 1)
    trap_bear = np.roll(md.bear_trap, 1)
    reclaim_bull = trap_bull & (c1 > md.h4_res) & (c1 > f1)
    reclaim_bear = trap_bear & (c1 < md.h4_sup) & (c1 < f1)

    if p.entry_mode == 0:
        buy_raw = h4_bull & bias_bull
        sell_raw = h4_bear & bias_bear
    elif p.entry_mode == 2:
        buy_raw = reclaim_bull & bias_bull
        sell_raw = reclaim_bear & bias_bear
    else:
        buy_raw = (h4_bull | (h4_bull & bull_pb) | reclaim_bull) & bias_bull
        sell_raw = (h4_bear | (h4_bear & bear_pb) | reclaim_bear) & bias_bear

    buy_sig = buy_raw & session_ok & compress_ok
    sell_sig = sell_raw & session_ok & compress_ok

    warm = max(p.htf_zone_bars * 16, p.daily_ema_period * 24, 80)
    buy_sig[:warm] = False
    sell_sig[:warm] = False
    return {
        "buy_sig": buy_sig,
        "sell_sig": sell_sig,
        "session_ok": session_ok,
        "momentum": momentum,
        "atr": md.atr,
    }


@dataclass
class SimResult:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe: float
    trades: list[dict]


def simulate(
    md: MarketPack,
    symbol: str,
    p: PlaybookParams,
    costs: Any,
    pip: float,
    point: float,
) -> SimResult:
    from cluster_audit.backtest_core import CostModel  # local import avoids cycle

    sig = make_signals(md, p)
    opn, high, low, close = md.open_, md.high, md.low, md.close
    atr = sig["atr"]
    momentum = sig["momentum"]
    buy_sig, sell_sig = sig["buy_sig"], sig["sell_sig"]

    spread_px = costs.spread_points * point
    slip = costs.slippage_points * point
    half = spread_px / 2.0 + slip
    commission = costs.commission_per_lot * p.lot_size * 2.0

    balance = p.initial_balance
    equity: list[float] = [balance]
    trades: list[dict] = []
    side = None
    entry = 0.0
    entry_i = 0
    trail = 0.0
    last_entry_i = -10_000

    def calc_profit(entry_px: float, exit_px: float, s: str) -> float:
        ot = mt5.ORDER_TYPE_BUY if s == "BUY" else mt5.ORDER_TYPE_SELL
        pr = mt5.order_calc_profit(ot, symbol, p.lot_size, entry_px, exit_px)
        return float(pr) - commission if pr is not None else -commission

    warm = max(p.htf_zone_bars * 16, 80)
    for i in range(warm, len(md.df)):
        atr1 = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
        mid = float(opn[i])

        if side is not None:
            bars_held = i - entry_i
            closed = False
            max_bars = p.max_bars_in_trade
            if p.extend_hold_in_momentum and momentum[i]:
                max_bars = int(max_bars * 1.5)
            if max_bars > 0 and bars_held >= max_bars:
                exit_px = mid - half if side == "BUY" else mid + half
                profit = calc_profit(entry, exit_px, side)
                balance += profit
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "max_bars"})
                closed = True
            elif side == "BUY":
                sl_px = entry - atr1 * p.atr_sl_mult if atr1 > 0 else entry - 20 * pip
                tp_px = entry + atr1 * p.atr_tp_mult if atr1 > 0 else entry + 40 * pip
                eff_sl = sl_px
                if p.use_trailing and atr1 > 0:
                    td = atr1 * p.trail_atr_mult
                    candidate = high[i] - td
                    if candidate > entry:
                        trail = max(trail, candidate) if trail > 0 else candidate
                        eff_sl = max(sl_px, trail)
                if low[i] <= eff_sl:
                    reason = "trail" if trail > sl_px and eff_sl > entry else "sl"
                    profit = calc_profit(entry, eff_sl - half, side)
                    balance += profit
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": reason})
                    closed = True
                elif high[i] >= tp_px:
                    profit = calc_profit(entry, tp_px - half, side)
                    balance += profit
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "tp"})
                    closed = True
            elif side == "SELL":
                sl_px = entry + atr1 * p.atr_sl_mult if atr1 > 0 else entry + 20 * pip
                tp_px = entry - atr1 * p.atr_tp_mult if atr1 > 0 else entry - 40 * pip
                eff_sl = sl_px
                if p.use_trailing and atr1 > 0:
                    td = atr1 * p.trail_atr_mult
                    candidate = low[i] + td
                    if candidate < entry:
                        trail = min(trail, candidate) if trail > 0 else candidate
                        eff_sl = min(sl_px, trail)
                if high[i] >= eff_sl:
                    reason = "trail" if trail > 0 and trail < sl_px and eff_sl < entry else "sl"
                    profit = calc_profit(entry, eff_sl + half, side)
                    balance += profit
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": reason})
                    closed = True
                elif low[i] <= tp_px:
                    profit = calc_profit(entry, tp_px + half, side)
                    balance += profit
                    trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "tp"})
                    closed = True
            if closed:
                side = None
                trail = 0.0

        if side is None:
            spread_pips = spread_px / pip if pip > 0 else 0
            if not (p.max_spread_pips > 0 and spread_pips > p.max_spread_pips) and i - last_entry_i >= p.cooldown_bars:
                if buy_sig[i]:
                    side, entry, entry_i, last_entry_i = "BUY", mid + half, i, i
                elif sell_sig[i]:
                    side, entry, entry_i, last_entry_i = "SELL", mid - half, i, i

        mark = balance
        if side == "BUY":
            mark += calc_profit(entry, float(close[i - 1]), side) + commission
        elif side == "SELL":
            mark += calc_profit(entry, float(close[i - 1]), side) + commission
        equity.append(mark)

    if side is not None:
        profit = calc_profit(entry, float(close[-1]), side)
        balance += profit
        trades.append({"side": side, "open_i": entry_i, "close_i": len(md.df) - 1, "profit": profit, "exit_reason": "eod"})

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
    return SimResult(net, len(trades), wr, pf, dd, sharpe, trades)
