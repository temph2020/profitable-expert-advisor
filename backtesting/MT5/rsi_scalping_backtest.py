"""
Bar-based RSI scalping backtest — conservative fills, costs, no same-bar RSI lookahead.

Mirrors RsiScalpingRobot.mqh with:
- entries on bar open after RSI cross on prior closed bars
- exits evaluated on prior closed bar RSI
- trailing updated on bar close; stop checked against bar range
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from indicator_utils import calculate_rsi


@dataclass
class RsiScalpParams:
    rsi_period: int = 14
    rsi_overbought: float = 71.0
    rsi_oversold: float = 57.0
    rsi_target_buy: float = 80.0
    rsi_target_sell: float = 57.0
    bars_to_wait: int = 1
    use_trailing: bool = True
    trail_distance_pts: float = 71.0
    trail_activation_pts: float = 41.0
    lot_size: float = 0.1

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "RsiScalpParams":
        return cls(**{k: d[k] for k in cls.__dataclass_fields__ if k in d})


@dataclass
class CostModel:
    spread_points: float = 0.0
    slippage_points: float = 3.0
    commission_per_lot: float = 0.0

    @classmethod
    def from_symbol(cls, symbol: str, slippage_points: float = 3.0, commission_per_lot: float = 0.0) -> "CostModel":
        info = mt5.symbol_info(symbol)
        spread = float(info.spread) if info else 0.0
        return cls(spread_points=spread, slippage_points=slippage_points, commission_per_lot=commission_per_lot)


@dataclass
class BacktestResult:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    total_costs: float
    score: float
    params: RsiScalpParams
    gross_profit: float = 0.0
    gross_loss: float = 0.0


def _calc_profit(symbol: str, order_type: int, volume: float, open_price: float, close_price: float) -> float:
    p = mt5.order_calc_profit(order_type, symbol, volume, open_price, close_price)
    return float(p) if p is not None else 0.0


def _half_spread_price(point: float, spread_points: float) -> float:
    return (spread_points * point) / 2.0


def _fill_buy(open_price: float, point: float, costs: CostModel, entry: bool) -> float:
    slip = costs.slippage_points * point
    hs = _half_spread_price(point, costs.spread_points)
    return open_price + hs + slip if entry else open_price - hs - slip


def _fill_sell(open_price: float, point: float, costs: CostModel, entry: bool) -> float:
    slip = costs.slippage_points * point
    hs = _half_spread_price(point, costs.spread_points)
    return open_price - hs - slip if entry else open_price + hs + slip


def backtest_rsi_scalping(
    df: pd.DataFrame,
    symbol: str,
    params: RsiScalpParams,
    initial_balance: float = 10_000.0,
    point: float | None = None,
    costs: CostModel | None = None,
) -> BacktestResult:
    info = mt5.symbol_info(symbol)
    if point is None:
        point = float(info.point) if info else 0.01
    if costs is None:
        costs = CostModel.from_symbol(symbol)

    # RSI on close; decisions use index i-1 (last fully closed bar at bar i open)
    rsi_full = calculate_rsi(df["close"], params.rsi_period).to_numpy()
    times = df.index.to_numpy()
    opens = df["open"].to_numpy()
    highs = df["high"].to_numpy()
    lows = df["low"].to_numpy()
    closes = df["close"].to_numpy()

    balance = initial_balance
    peak = initial_balance
    max_dd = 0.0
    total_costs = 0.0

    position: dict[str, Any] | None = None
    rsi_against = False
    bars_against = 0

    gross_profit = 0.0
    gross_loss = 0.0
    wins = 0
    losses = 0
    trades = 0

    trail_dist = params.trail_distance_pts * point
    trail_act = (params.trail_activation_pts if params.trail_activation_pts > 0 else params.trail_distance_pts) * point

    def _update_dd() -> None:
        nonlocal peak, max_dd
        if balance > peak:
            peak = balance
        dd = (peak - balance) / peak if peak > 0 else 0.0
        if dd > max_dd:
            max_dd = dd

    def close_at(exit_mid: float) -> None:
        nonlocal balance, gross_profit, gross_loss, wins, losses, trades, position, total_costs
        if position is None:
            return
        order_type = mt5.ORDER_TYPE_BUY if position["type"] == "BUY" else mt5.ORDER_TYPE_SELL
        if position["type"] == "BUY":
            exit_price = _fill_buy(exit_mid, point, costs, entry=False)
        else:
            exit_price = _fill_sell(exit_mid, point, costs, entry=False)

        commission = costs.commission_per_lot * position["volume"] * 2.0
        profit = _calc_profit(symbol, order_type, position["volume"], position["open_price"], exit_price)
        profit -= commission
        total_costs += commission + (costs.slippage_points * point * position["volume"] * 100000 * 0.0)

        balance += profit
        trades += 1
        if profit >= 0:
            wins += 1
            gross_profit += profit
        else:
            losses += 1
            gross_loss += abs(profit)
        _update_dd()
        position = None

    def apply_trailing(bar_close: float, bar_high: float, bar_low: float) -> None:
        if position is None or not params.use_trailing or trail_dist <= 0:
            return
        if position["type"] == "BUY":
            bid = bar_close
            if bid - position["open_price"] <= trail_act:
                return
            new_sl = bid - trail_dist
            if new_sl > position.get("sl", 0.0):
                position["sl"] = new_sl
            if position.get("sl") and bar_low <= position["sl"]:
                close_at(position["sl"])
        else:
            ask = bar_close
            if position["open_price"] - ask <= trail_act:
                return
            new_sl = ask + trail_dist
            if position.get("sl", 0.0) == 0.0 or new_sl < position["sl"]:
                position["sl"] = new_sl
            if position.get("sl") and bar_high >= position["sl"]:
                close_at(position["sl"])

    start = max(params.rsi_period + 3, 3)
    for i in range(start, len(df)):
        # closed-bar RSI (no lookahead): signal bar is i-1
        rsi_sig = rsi_full[i - 1]
        rsi_prev = rsi_full[i - 2]
        rsi_two = rsi_full[i - 3]
        if np.isnan(rsi_sig) or np.isnan(rsi_prev) or np.isnan(rsi_two):
            continue

        if position is not None:
            apply_trailing(closes[i], highs[i], lows[i])
            if position is None:
                rsi_against = False
                bars_against = 0
                continue

            if position["type"] == "BUY":
                if rsi_sig < params.rsi_oversold:
                    if not rsi_against:
                        rsi_against = True
                        bars_against = 1
                    else:
                        bars_against += 1
                    if bars_against >= params.bars_to_wait:
                        close_at(opens[i])
                else:
                    if rsi_against:
                        rsi_against = False
                        bars_against = 0
                    if rsi_sig >= params.rsi_target_buy:
                        close_at(opens[i])
            else:
                if rsi_sig > params.rsi_overbought:
                    if not rsi_against:
                        rsi_against = True
                        bars_against = 1
                    else:
                        bars_against += 1
                    if bars_against >= params.bars_to_wait:
                        close_at(opens[i])
                else:
                    if rsi_against:
                        rsi_against = False
                        bars_against = 0
                    if rsi_sig <= params.rsi_target_sell:
                        close_at(opens[i])

            if position is not None:
                continue

        # entry at bar open[i] from RSI cross on bars i-2 / i-3
        if rsi_two <= params.rsi_oversold and rsi_prev > params.rsi_oversold:
            entry = _fill_buy(opens[i], point, costs, entry=True)
            position = {"type": "BUY", "volume": params.lot_size, "open_price": entry, "open_time": times[i], "sl": 0.0}
            rsi_against = False
            bars_against = 0
        elif rsi_two >= params.rsi_overbought and rsi_prev < params.rsi_overbought:
            entry = _fill_sell(opens[i], point, costs, entry=True)
            position = {"type": "SELL", "volume": params.lot_size, "open_price": entry, "open_time": times[i], "sl": 0.0}
            rsi_against = False
            bars_against = 0

    if position is not None:
        close_at(closes[-1])

    net_profit = balance - initial_balance
    win_rate = (wins / trades * 100.0) if trades else 0.0
    pf = (gross_profit / gross_loss) if gross_loss > 0 else (999.0 if gross_profit > 0 else 0.0)

    if trades < 20:
        score = net_profit - 10_000.0
    else:
        score = net_profit * (1.0 - min(max_dd, 0.5))

    return BacktestResult(
        net_profit=net_profit,
        total_trades=trades,
        win_rate=win_rate,
        profit_factor=pf,
        max_drawdown_pct=max_dd * 100.0,
        total_costs=total_costs,
        score=score,
        params=params,
        gross_profit=gross_profit,
        gross_loss=gross_loss,
    )


def resolve_symbol(requested: str) -> str:
    key = requested.split("|")[0].strip()
    if not key:
        return requested
    if mt5.symbol_info(key) is not None:
        mt5.symbol_select(key, True)
        return key
    for suffix in (".NAS", ".NYSE", ".NYS", ".US"):
        cand = key + suffix
        if mt5.symbol_info(cand) is not None:
            mt5.symbol_select(cand, True)
            return cand
    for sym in mt5.symbols_get() or []:
        name = sym.name
        if name.startswith(key + "."):
            mt5.symbol_select(name, True)
            return name
    return key


def load_rates(symbol: str, timeframe: int, start, end) -> pd.DataFrame:
    symbol = resolve_symbol(symbol)
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"Cannot select {symbol}: {mt5.last_error()}")
    rates = mt5.copy_rates_range(symbol, timeframe, start, end)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No rates for {symbol}: {mt5.last_error()}")
    out = pd.DataFrame(rates)
    out["time"] = pd.to_datetime(out["time"], unit="s")
    out.set_index("time", inplace=True)
    return out


def split_walk_forward(df: pd.DataFrame, train_ratio: float = 0.6) -> tuple[pd.DataFrame, pd.DataFrame]:
    cut = int(len(df) * train_ratio)
    if cut < 100 or len(df) - cut < 100:
        raise ValueError("Not enough bars for walk-forward split")
    return df.iloc[:cut].copy(), df.iloc[cut:].copy()
