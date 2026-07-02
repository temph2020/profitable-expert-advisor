"""Python ports of SuperEA engines for cluster audit."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
import pandas as pd

from indicator_utils import calculate_adx, calculate_atr, calculate_dmi, calculate_ema, calculate_rsi

from .backtest_core import (
    BacktestReport,
    CostModel,
    Trade,
    build_report,
    calc_profit,
    fill_price,
)


@dataclass
class SimState:
    side: str | None = None
    entry: float = 0.0
    entry_i: int = 0
    entry_time: Any = None
    sl: float = 0.0
    tp: float = 0.0
    bars_against: int = 0
    rsi_against: bool = False


def _run_single_position(
    df: pd.DataFrame,
    symbol: str,
    point: float,
    costs: CostModel,
    lot: float,
    strategy_id: str,
    tf_label: str,
    period_label: str,
    params: dict,
    initial_balance: float,
    on_bar,
) -> BacktestReport:
    trades: list[Trade] = []
    equity = [initial_balance]
    st = SimState()

    def close(i: int, mid: float, reason: str) -> None:
        nonlocal st
        if st.side is None:
            return
        exit_px = fill_price(mid, point, costs, st.side, entry=False)
        commission = costs.commission_per_lot * lot * 2
        profit = calc_profit(symbol, st.side, lot, st.entry, exit_px) - commission
        trades.append(
            Trade(
                side=st.side,
                open_time=st.entry_time,
                close_time=df.index[i],
                open_price=st.entry,
                close_price=exit_px,
                volume=lot,
                profit=profit,
                bars_held=i - st.entry_i,
                exit_reason=reason,
            )
        )
        equity.append(equity[-1] + profit)
        st = SimState()

    def open_pos(i: int, side: str, mid: float) -> None:
        nonlocal st
        st.side = side
        st.entry = fill_price(mid, point, costs, side, entry=True)
        st.entry_i = i
        st.entry_time = df.index[i]
        st.sl = 0.0
        st.tp = 0.0
        st.bars_against = 0
        st.rsi_against = False

    for i in range(1, len(df)):
        mid = float(df["open"].iloc[i])
        on_bar(i, st, open_pos, close)
        if len(equity) == len(trades) + 1:
            equity.append(equity[-1])

    if st.side is not None:
        close(len(df) - 1, float(df["close"].iloc[-1]), "eod")

    eq = pd.Series(equity[: len(df)], index=df.index[: len(equity)])
    return build_report(strategy_id, symbol, tf_label, period_label, trades, eq, initial_balance, params)


# --- RSI Scalping ---
def backtest_rsi_scalp(
    df: pd.DataFrame,
    symbol: str,
    period_label: str,
    strategy_id: str,
    params: dict,
    lot: float = 0.1,
    costs: CostModel | None = None,
) -> BacktestReport:
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    rsi = calculate_rsi(df["close"], int(params["rsi_period"])).to_numpy()
    atr = calculate_atr(df, int(params.get("reversal_atr_period", 14))).to_numpy()
    trail_dist = params.get("trail_distance_pts", 0) * point
    trail_act = (params.get("trail_activation_pts") or params.get("trail_distance_pts", 0)) * point
    use_rsi_against = params.get("use_rsi_against_exit", True)
    max_adv_atr = float(params.get("max_adverse_atr", 0))

    def on_bar(i, st, open_pos, close):
        if i < 3 or np.isnan(rsi[i - 1]):
            return
        sig, prev, two = rsi[i - 1], rsi[i - 2], rsi[i - 3]
        mid = float(df["open"].iloc[i])
        hi, lo = float(df["high"].iloc[i]), float(df["low"].iloc[i])

        if st.side is not None and params.get("use_reversal_escape"):
            a = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
            if a > 0:
                adv_mult = float(params.get("reversal_adverse_atr_mult", 1.5))
                rsi_vel = float(params.get("reversal_rsi_velocity", 8.0))
                need = int(params.get("reversal_signs_required", 2))
                signs = 0
                if st.side == "BUY":
                    if st.entry - lo >= adv_mult * a:
                        signs += 1
                    if sig - prev >= rsi_vel:
                        signs += 1
                else:
                    if hi - st.entry >= adv_mult * a:
                        signs += 1
                    if sig - prev >= rsi_vel:
                        signs += 1
                if signs >= need:
                    close(i, mid, "reversal_escape")
                    return

        if st.side is not None and params.get("use_trailing") and trail_dist > 0:
            if st.side == "BUY":
                bid = float(df["close"].iloc[i])
                if bid - st.entry > trail_act:
                    nsl = bid - trail_dist
                    if nsl > st.sl:
                        st.sl = nsl
                if st.sl > 0 and lo <= st.sl:
                    close(i, st.sl, "trail")
                    return
            else:
                ask = float(df["close"].iloc[i])
                if st.entry - ask > trail_act:
                    nsl = ask + trail_dist
                    if st.sl == 0 or nsl < st.sl:
                        st.sl = nsl
                if st.sl > 0 and hi >= st.sl:
                    close(i, st.sl, "trail")
                    return

        if st.side is not None and max_adv_atr > 0:
            a = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
            if a > 0:
                if st.side == "BUY" and (st.entry - lo) / a >= max_adv_atr:
                    close(i, mid, "adverse_atr")
                    return
                if st.side == "SELL" and (hi - st.entry) / a >= max_adv_atr:
                    close(i, mid, "adverse_atr")
                    return

        if st.side == "BUY":
            if use_rsi_against and sig < params["rsi_oversold"]:
                st.bars_against = st.bars_against + 1 if st.rsi_against else 1
                st.rsi_against = True
                if st.bars_against >= params["bars_to_wait"]:
                    close(i, mid, "rsi_against")
            else:
                st.rsi_against = False
                st.bars_against = 0
                if sig >= params["rsi_target_buy"]:
                    close(i, mid, "target")
        elif st.side == "SELL":
            if use_rsi_against and sig > params["rsi_overbought"]:
                st.bars_against = st.bars_against + 1 if st.rsi_against else 1
                st.rsi_against = True
                if st.bars_against >= params["bars_to_wait"]:
                    close(i, mid, "rsi_against")
            else:
                st.rsi_against = False
                st.bars_against = 0
                if sig <= params["rsi_target_sell"]:
                    close(i, mid, "target")
        else:
            if two <= params["rsi_oversold"] and prev > params["rsi_oversold"]:
                open_pos(i, "BUY", mid)
            elif two >= params["rsi_overbought"] and prev < params["rsi_overbought"]:
                min_depth = float(params.get("min_ob_depth", 0))
                if two < params["rsi_overbought"] + min_depth:
                    pass
                else:
                    skip_h = int(params.get("skip_short_hour_after", 24))
                    if df.index[i].hour < skip_h:
                        open_pos(i, "SELL", mid)

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, params.get("tf", "H1"),
        period_label, params, 10_000.0, on_bar,
    )


# --- RSI CrossOver ---
def _price_to_ema_pips(symbol: str, close: float, ema: float) -> float:
    info = __import__("MetaTrader5").symbol_info(symbol)
    if info is None:
        return abs(close - ema) * 10.0
    point = float(info.point)
    digits = int(info.digits)
    pip_mult = 10.0 if digits in (3, 5) else 1.0
    pip_size = point * pip_mult if point > 0 else point
    return abs(close - ema) / pip_size if pip_size > 0 else 0.0


def backtest_rsi_crossover(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    rsi = calculate_rsi(df["close"], int(params["rsi_period"])).to_numpy()
    ema = calculate_ema(df["close"], int(params["ema_period"])).to_numpy()
    trail = params.get("trailing_stop_pts", 0) * point
    prev_rsi_state = 0.0
    last_trade_i = -10_000
    cooldown_bars = max(1, int(params.get("cooldown_seconds", 300) / 3600))
    use_trend_filter = params.get("use_trend_strength_filter", True)

    weekday_ok = {
        0: params.get("sunday", False),
        1: params.get("monday", False),
        2: params.get("tuesday", True),
        3: params.get("wednesday", True),
        4: params.get("thursday", True),
        5: params.get("friday", False),
        6: params.get("saturday", False),
    }

    def hours_ok(ts) -> bool:
        h = ts.hour
        def in_win(begin: int, end: int) -> bool:
            b, e = begin % 24, end % 24
            if b == e:
                return False
            if b < e:
                return b <= h < e
            return h >= b or h < e
        return in_win(params.get("trading_hour_one_begin", 0), params.get("trading_hour_one_end", 22)) or in_win(
            params.get("trading_hour_two_begin", 6), params.get("trading_hour_two_end", 19)
        )

    def on_bar(i, st, open_pos, close):
        nonlocal prev_rsi_state, last_trade_i
        if i < 3 or np.isnan(rsi[i - 1]) or np.isnan(ema[i - 1]):
            return
        ts = df.index[i]
        if not weekday_ok.get(ts.weekday(), False) or not hours_ok(ts):
            if st.side:
                close(i, float(df["open"].iloc[i]), "hours")
            return

        cur = rsi[i - 1]
        if prev_rsi_state == 0.0:
            prev_rsi_state = cur
            return

        ema_slope = (ema[i - 1] - ema[i - 2]) * 100.0
        price_to_ema = abs((float(df["close"].iloc[i - 1]) - ema[i - 1]) * 10.0)
        slope_th = float(params.get("ema_slope_threshold", 100))
        dist_th = float(params.get("ema_distance_threshold", 100))
        trend_strong = use_trend_filter and (
            (slope_th > 0 and abs(ema_slope) > slope_th)
            or (dist_th > 0 and price_to_ema > dist_th)
        )

        mid = float(df["open"].iloc[i])
        if st.side == "BUY" and trail > 0:
            bid = float(df["close"].iloc[i])
            if bid - st.entry > trail:
                st.sl = max(st.sl, bid - trail)
            if st.sl > 0 and float(df["low"].iloc[i]) <= st.sl:
                close(i, st.sl, "trail")
                prev_rsi_state = cur
                return
        if st.side == "SELL" and trail > 0:
            ask = float(df["close"].iloc[i])
            if st.entry - ask > trail:
                st.sl = ask + trail if st.sl == 0 else min(st.sl, ask + trail)
            if st.sl > 0 and float(df["high"].iloc[i]) >= st.sl:
                close(i, st.sl, "trail")
                prev_rsi_state = cur
                return

        if st.side == "BUY" and cur > params.get("exit_buy_rsi", 80):
            close(i, mid, "exit_rsi")
        elif st.side == "SELL" and cur < params.get("exit_sell_rsi", 20):
            close(i, mid, "exit_rsi")
        elif trend_strong and st.side:
            close(i, mid, "trend_strong")
        elif not st.side and not trend_strong and i - last_trade_i >= cooldown_bars:
            ob = params.get("overbought_level", 70)
            os = params.get("oversold_level", 30)
            sell_spread = params.get("entry_rsi_sell_spread", 0)
            buy_spread = params.get("entry_rsi_buy_spread", 0)
            if prev_rsi_state >= ob and cur < ob - sell_spread:
                open_pos(i, "SELL", mid)
                last_trade_i = i
            elif prev_rsi_state <= os and cur > os + buy_spread:
                open_pos(i, "BUY", mid)
                last_trade_i = i
        prev_rsi_state = cur

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "H1", period_label, params, 10_000.0, on_bar,
    )


# --- RSI Asian ---
def backtest_rsi_asian(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    rsi = calculate_rsi(df["close"], int(params["rsi_period"])).to_numpy()
    sess_start = params.get("asian_session_start", 0)
    sess_end = params.get("asian_session_end", 8)

    def in_session(ts) -> bool:
        return sess_start <= ts.hour < sess_end

    def on_bar(i, st, open_pos, close):
        if i < 2 or np.isnan(rsi[i - 1]):
            return
        ts = df.index[i]
        prev, cur = rsi[i - 2], rsi[i - 1]
        mid = float(df["open"].iloc[i])

        if st.side and params.get("close_outside_session") and not in_session(ts):
            close(i, mid, "session")
            return
        if st.side and params.get("use_rsi_exit"):
            exit_lvl = params.get("rsi_exit_level", 55)
            if (prev < exit_lvl <= cur) or (prev > exit_lvl >= cur):
                close(i, mid, "rsi_exit")

        if not in_session(ts):
            return
        if st.side:
            return
        if prev < params["overbought_level"] <= cur:
            open_pos(i, "SELL", mid)
        elif prev > params["oversold_level"] >= cur:
            open_pos(i, "BUY", mid)

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "M15", period_label, params, 10_000.0, on_bar,
    )


# --- Mean Reversion ---
def backtest_mean_reversion(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    rsi = calculate_rsi(df["close"], int(params["rsi_period"])).to_numpy()
    ema = calculate_ema(df["close"], int(params["ema_period"])).to_numpy()
    adx = calculate_adx(df, int(params.get("adx_period", 14))).to_numpy()

    def on_bar(i, st, open_pos, close):
        if i < max(params["ema_period"], 20) + 2:
            return
        if np.isnan(rsi[i - 1]) or np.isnan(ema[i - 1]) or np.isnan(adx[i - 1]):
            return
        mid = float(df["open"].iloc[i])
        cls = float(df["close"].iloc[i - 1])
        dist_buy = (ema[i - 1] - cls) / point
        dist_sell = (cls - ema[i - 1]) / point
        adx_v = float(adx[i - 1])

        if st.side:
            adx_now = float(adx[i - 1]) if not np.isnan(adx[i - 1]) else 0.0
            if adx_now >= params.get("adx_escape", 30):
                close(i, mid, "adx_escape")
            elif params.get("use_hard_sltp"):
                if st.side == "BUY":
                    if cls <= st.entry - params.get("sl_points", 0) * point:
                        close(i, mid, "sl")
                    elif cls >= st.entry + params.get("tp_points", 0) * point:
                        close(i, mid, "tp")
                else:
                    if cls >= st.entry + params.get("sl_points", 0) * point:
                        close(i, mid, "sl")
                    elif cls <= st.entry - params.get("tp_points", 0) * point:
                        close(i, mid, "tp")
            return

        if adx_v <= 0 or adx_v >= params.get("adx_max_for_entry", 20):
            return
        use_cross = params.get("use_rsi_cross", True)
        if use_cross:
            buy_rsi = rsi[i - 2] > params["rsi_oversold"] >= rsi[i - 1]
            sell_rsi = rsi[i - 2] < params["rsi_overbought"] <= rsi[i - 1]
        else:
            buy_rsi = rsi[i - 1] <= params["rsi_oversold"]
            sell_rsi = rsi[i - 1] >= params["rsi_overbought"]
        if buy_rsi and dist_buy >= params.get("min_ema_distance_pts", 0):
            open_pos(i, "BUY", mid)
            if params.get("use_hard_sltp"):
                st.sl = st.entry - params.get("sl_points", 0) * point
                st.tp = st.entry + params.get("tp_points", 0) * point
        elif sell_rsi and dist_sell >= params.get("min_ema_distance_pts", 0):
            open_pos(i, "SELL", mid)
            if params.get("use_hard_sltp"):
                st.sl = st.entry + params.get("sl_points", 0) * point
                st.tp = st.entry - params.get("tp_points", 0) * point

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "M15", period_label, params, 10_000.0, on_bar,
    )


# --- EMA Slope (monitor + crossover state machine, matches MQL) ---
def _weekly_dmi_lookup(df: pd.DataFrame, period: int, bar_shift: int) -> tuple[pd.Series, pd.Series, pd.Series]:
    wdf = df.resample("W-FRI").agg({"high": "max", "low": "min", "close": "last"}).dropna()
    dmi = calculate_dmi(wdf, period)
    shift = max(0, bar_shift)
    adx = dmi["adx"].shift(shift).reindex(df.index, method="ffill")
    plus = dmi["plus_di"].shift(shift).reindex(df.index, method="ffill")
    minus = dmi["minus_di"].shift(shift).reindex(df.index, method="ffill")
    return adx, plus, minus


def backtest_ema_slope(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    ema_period = int(params["ema_period"])
    ema = calculate_ema(df["close"], ema_period).to_numpy()
    atr = calculate_atr(df, 14).to_numpy()
    closes = df["close"].to_numpy()
    opens = df["open"].to_numpy()
    highs = df["high"].to_numpy()
    lows = df["low"].to_numpy()
    times = df.index
    mult = 10.0 if ("XAU" in symbol or "BTC" in symbol) else 1.0

    w_adx, w_plus, w_minus = _weekly_dmi_lookup(
        df, int(params.get("weekly_adx_period", 28)), int(params.get("weekly_adx_bar_shift", 8))
    )

    price_trigger_active = False
    slope_trigger_active = False
    monitor_active = False
    monitor_start_i = -1
    trades_in_cross = 0
    last_close = 0.0
    last_ema = 0.0
    last_bar_time = None

    def weekly_ok(i: int, side: str) -> bool:
        if not params.get("use_weekly_adx_filter", True):
            return True
        adx_v = float(w_adx.iloc[i - 1]) if i > 0 else np.nan
        if np.isnan(adx_v) or adx_v < params.get("weekly_adx_min", 25):
            return False
        if not params.get("weekly_adx_use_direction", True):
            return True
        pdi = float(w_plus.iloc[i - 1])
        mdi = float(w_minus.iloc[i - 1])
        if side == "BUY":
            return pdi > mdi
        return mdi > pdi

    def on_bar(i, st, open_pos, close):
        nonlocal price_trigger_active, slope_trigger_active, monitor_active, monitor_start_i
        nonlocal trades_in_cross, last_close, last_ema, last_bar_time
        if i < ema_period + 3 or np.isnan(ema[i - 1]) or np.isnan(ema[i - 2]):
            return

        if params.get("use_bar_data", True):
            ts = times[i]
            if last_bar_time is not None and ts == last_bar_time:
                return
            last_bar_time = ts

        mid = float(opens[i])
        bar_close = float(closes[i - 1])
        ema_now = float(ema[i - 1])
        ema_prev = float(ema[i - 2])

        if last_close != 0.0:
            if (last_close <= last_ema and bar_close > ema_now) or (last_close >= last_ema and bar_close < ema_now):
                trades_in_cross = 0
        last_close, last_ema = bar_close, ema_now

        price_dist = abs(bar_close - ema_now) / point / mult
        if price_dist > params.get("price_threshold_pips", 100) and not price_trigger_active:
            price_trigger_active = True
        slope = (ema_now - ema_prev) / point / mult
        if abs(slope) > params.get("slope_threshold_pips", 20) and not slope_trigger_active:
            slope_trigger_active = True

        if price_trigger_active and slope_trigger_active and not monitor_active:
            monitor_active = True
            monitor_start_i = i

        tf_sec = 3600
        timeout_bars = int(params.get("monitor_timeout_sec", 340) / tf_sec)
        if monitor_active and monitor_start_i >= 0 and (i - monitor_start_i) > timeout_bars:
            monitor_active = False
            price_trigger_active = False
            slope_trigger_active = False

        if st.side:
            bars_open = i - st.entry_i
            bar_close_now = float(closes[i])
            a = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
            max_loss_atr = float(params.get("max_loss_atr", 2.0))
            if a > 0 and max_loss_atr > 0:
                if st.side == "BUY" and float(lows[i]) <= st.entry - max_loss_atr * a:
                    close(i, st.entry - max_loss_atr * a, "atr_sl")
                    return
                if st.side == "SELL" and float(highs[i]) >= st.entry + max_loss_atr * a:
                    close(i, st.entry + max_loss_atr * a, "atr_sl")
                    return

            trail_pips = params.get("trailing_stop_pips", 50)
            trail_px = trail_pips * point * mult
            bar_close_now = float(closes[i])
            in_profit = (bar_close_now > st.entry) if st.side == "BUY" else (st.entry > bar_close_now)
            use_trail = params.get("use_trailing_stop", False)
            trail_act = params.get("trailing_activation_pips", 0)
            trail_ready = in_profit if trail_act <= 0 else (
                (bar_close_now - st.entry) / point / mult >= trail_act
                if st.side == "BUY"
                else (st.entry - bar_close_now) / point / mult >= trail_act
            )
            if trail_pips > 0 and (use_trail or in_profit) and trail_ready:
                if st.side == "BUY":
                    st.sl = max(st.sl, bar_close_now - trail_px)
                    if st.sl > 0 and float(lows[i]) <= st.sl:
                        close(i, st.sl, "trail")
                        return
                else:
                    st.sl = bar_close_now + trail_px if st.sl <= 0 else min(st.sl, bar_close_now + trail_px)
                    if st.sl > 0 and float(highs[i]) >= st.sl:
                        close(i, st.sl, "trail")
                        return

            ema_exit = (st.side == "BUY" and bar_close_now < ema_now) or (
                st.side == "SELL" and bar_close_now > ema_now
            )
            unrealized = calc_profit(symbol, st.side, lot, st.entry, bar_close_now)
            if ema_exit and unrealized > 0:
                close(i, mid, "ema_cross")
                return

            if params.get("close_unprofitable_trades", True):
                check_bars = int(params.get("profit_check_bars", 78))
                if bars_open >= check_bars:
                    unrealized = calc_profit(symbol, st.side, lot, st.entry, bar_close_now)
                    if unrealized <= 0:
                        close(i, mid, "unprofitable")
                        return
            return

        if not monitor_active:
            return
        if trades_in_cross >= params.get("max_trades_per_crossover", 5):
            return

        if bar_close > ema_now and weekly_ok(i, "BUY"):
            open_pos(i, "BUY", mid)
            trades_in_cross += 1
            monitor_active = False
            price_trigger_active = False
            slope_trigger_active = False
        elif bar_close < ema_now and weekly_ok(i, "SELL"):
            open_pos(i, "SELL", mid)
            trades_in_cross += 1
            monitor_active = False
            price_trigger_active = False
            slope_trigger_active = False

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "H1", period_label, params, 10_000.0, on_bar,
    )


# --- Darvas Box (matches MQL: narrow box + breakout + trend strength) ---
def backtest_darvas(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    period = int(params.get("box_period", 165))
    box_dev = float(params.get("box_deviation", 30000))
    trend_thresh = float(params.get("trend_threshold", 4.94))
    ma_period = int(params.get("ma_period", 125))
    sl_pts = float(params.get("stop_loss_pts", 1665))
    tp_pts = float(params.get("take_profit_pts", 3685))
    vol_thresh = int(params.get("volume_threshold", 0))
    max_range = box_dev * point

    ma = calculate_ema(df["close"], ma_period).to_numpy()
    highs = df["high"].to_numpy()
    lows = df["low"].to_numpy()
    opens = df["open"].to_numpy()
    closes = df["close"].to_numpy()
    vols = df["tick_volume"].to_numpy() if "tick_volume" in df.columns else np.zeros(len(df))

    def on_bar(i, st, open_pos, close):
        if i < period + ma_period + 2:
            return
        window_hi = float(np.max(highs[i - period : i]))
        window_lo = float(np.min(lows[i - period : i]))
        if (window_hi - window_lo) > max_range:
            return

        mid = float(opens[i])
        bar_hi = float(highs[i])
        bar_lo = float(lows[i])
        ma_v = float(ma[i - 1])
        if np.isnan(ma_v):
            return

        if st.side:
            if st.side == "BUY":
                if st.sl > 0 and bar_lo <= st.sl:
                    close(i, st.sl, "sl")
                elif st.tp > 0 and bar_hi >= st.tp:
                    close(i, st.tp, "tp")
            else:
                if st.sl > 0 and bar_hi >= st.sl:
                    close(i, st.sl, "sl")
                elif st.tp > 0 and bar_lo <= st.tp:
                    close(i, st.tp, "tp")
            return

        if vols[i] <= vol_thresh:
            return
        prev_close = float(closes[i - 1])
        strength = abs(mid - ma_v) / point
        break_up = bar_hi > window_hi or prev_close > window_hi
        break_dn = bar_lo < window_lo or prev_close < window_lo

        if break_up and mid > ma_v and strength > trend_thresh:
            open_pos(i, "BUY", mid)
            st.sl = st.entry - sl_pts * point
            st.tp = st.entry + tp_pts * point
        elif break_dn and mid < ma_v and strength > trend_thresh:
            open_pos(i, "SELL", mid)
            st.sl = st.entry + sl_pts * point
            st.tp = st.entry - tp_pts * point

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "M15", period_label, params, 10_000.0, on_bar,
    )


# --- RSI Secret Sauce (simplified zone exit re-entry) ---
def backtest_rsi_secret(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    rsi = calculate_rsi(df["close"], int(params["rsi_period"])).to_numpy()
    atr = calculate_atr(df, int(params.get("atr_period", 14))).to_numpy()
    last_trade_i = -999

    def on_bar(i, st, open_pos, close):
        nonlocal last_trade_i
        if i < 30 or np.isnan(rsi[i - 1]) or np.isnan(atr[i - 1]):
            return
        mid = float(df["open"].iloc[i])
        cur, prev = rsi[i - 1], rsi[i - 2]
        a = atr[i - 1]

        if st.side:
            if st.side == "BUY":
                sl = st.entry - params.get("stop_loss_atr", 2) * a
                tp = st.entry + params.get("take_profit_atr", 4) * a
                if float(df["low"].iloc[i]) <= sl:
                    close(i, sl, "sl")
                elif float(df["high"].iloc[i]) >= tp:
                    close(i, tp, "tp")
            else:
                sl = st.entry + params.get("stop_loss_atr", 2) * a
                tp = st.entry - params.get("take_profit_atr", 4) * a
                if float(df["high"].iloc[i]) >= sl:
                    close(i, sl, "sl")
                elif float(df["low"].iloc[i]) <= tp:
                    close(i, tp, "tp")
            return

        if i - last_trade_i < params.get("min_bars_between_trades", 5):
            return
        ob, os = params["rsi_overbought"], params["rsi_oversold"]
        if prev > ob and cur <= ob:
            open_pos(i, "SELL", mid)
            last_trade_i = i
        elif prev < os and cur >= os:
            open_pos(i, "BUY", mid)
            last_trade_i = i

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "M30", period_label, params, 10_000.0, on_bar,
    )


# --- Simple Trendline (pullback to MA-derived trendline) ---
def backtest_simple_trendline(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.01
    costs = costs or CostModel.for_symbol(symbol)
    htf = params.get("higher_tf", "H4")
    htf_map = {"M10": "10min", "M15": "15min", "H1": "1h", "H4": "4h"}
    rule = htf_map.get(htf, "4h")
    hdf = df.resample(rule).agg({"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    ma_period = int(params.get("ma_period", 65))
    ma = calculate_ema(hdf["close"], ma_period).to_numpy()
    htimes = hdf.index.to_numpy()
    hcloses = hdf["close"].to_numpy()
    touch_tol = float(params.get("touch_tolerance_pts", 100)) * point
    break_buf = float(params.get("break_buffer_pts", 80)) * point

    def line_at(t_model, t_query):
        x = (t_query - t_model[0]).astype("timedelta64[s]").astype(float)
        return t_model[2] * x + t_model[3]

    def on_bar(i, st, open_pos, close):
        if i < 5:
            return
        ts = df.index[i]
        # find 3 most recent HTF MA crosses before ts
        hidx = int(np.searchsorted(htimes, ts, side="right")) - 1
        if hidx < ma_period + 5:
            return
        crosses_t, crosses_p = [], []
        for j in range(hidx, ma_period + 2, -1):
            if j >= len(ma) - 1:
                continue
            d0 = hcloses[j] - ma[j]
            d1 = hcloses[j + 1] - ma[j + 1]
            if d0 == 0 or d1 == 0 or d0 * d1 < 0:
                crosses_t.append(htimes[j])
                crosses_p.append(hcloses[j])
                if len(crosses_t) >= 3:
                    break
        if len(crosses_t) < 3:
            return
        t0 = crosses_t[2]
        xs = np.array([(t - t0).astype("timedelta64[s]").astype(float) for t in crosses_t[::-1]])
        ys = np.array(crosses_p[::-1])
        den = 3 * np.sum(xs ** 2) - np.sum(xs) ** 2
        if abs(den) < 1e-10:
            return
        a = (3 * np.sum(xs * ys) - np.sum(xs) * np.sum(ys)) / den
        b = (np.sum(ys) - a * np.sum(xs)) / 3
        model = (t0, crosses_t, a, b)
        t1 = df.index[i - 1]
        line1 = a * (t1 - t0).astype("timedelta64[s]").astype(float) + b
        mid = float(df["open"].iloc[i])
        hi = float(df["high"].iloc[i - 1])
        lo = float(df["low"].iloc[i - 1])
        cl1 = float(df["close"].iloc[i - 1])
        op1 = float(df["open"].iloc[i - 1])
        cl2 = float(df["close"].iloc[i - 2])
        t2 = df.index[i - 2]
        line2 = a * (t2 - t0).astype("timedelta64[s]").astype(float) + b

        if st.side == "BUY" and cl1 < line1 - break_buf:
            close(i, mid, "break")
            return
        if st.side == "SELL" and cl1 > line1 + break_buf:
            close(i, mid, "break")
            return

        if st.side:
            return
        if a > 0:
            if lo <= line1 + touch_tol and cl1 > line1 and cl1 > op1 and cl2 >= line2 - touch_tol:
                open_pos(i, "BUY", mid)
        elif a < 0:
            if hi >= line1 - touch_tol and cl1 < line1 and cl1 < op1 and cl2 <= line2 + touch_tol:
                open_pos(i, "SELL", mid)

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, params.get("signal_tf", "H1"),
        period_label, params, 10_000.0, on_bar,
    )


# --- USDJPY Asian range breakout (simplified market-fill) ---
def backtest_usdjpy_buster(df, symbol, period_label, strategy_id, params, lot=0.1, costs=None):
    info = __import__("MetaTrader5").symbol_info(symbol)
    point = float(info.point) if info else 0.001
    costs = costs or CostModel.for_symbol(symbol)
    r_start = int(params.get("range_start_hour", 3))
    r_end = int(params.get("range_end_hour", 6))
    close_h = int(params.get("close_hour", 18))
    min_rng = float(params.get("min_range_pts", 15))
    buf = float(params.get("order_buffer_pts", 4.75)) * point
    first_only = params.get("first_trade_only", False)

    day_state: dict = {}

    def on_bar(i, st, open_pos, close):
        ts = df.index[i]
        dk = ts.date().isoformat()
        h = ts.hour
        mid = float(df["open"].iloc[i])

        if st.side and h >= close_h:
            close(i, mid, "eod")
            return

        if dk not in day_state:
            day_state[dk] = {"hi": -np.inf, "lo": np.inf, "built": False, "trades": 0, "range_done": False}

        ds = day_state[dk]
        if r_start <= h < r_end:
            ds["hi"] = max(ds["hi"], float(df["high"].iloc[i]))
            ds["lo"] = min(ds["lo"], float(df["low"].iloc[i]))
            return

        if not ds["range_done"] and h >= r_end:
            ds["range_done"] = True
            if ds["hi"] > ds["lo"] and (ds["hi"] - ds["lo"]) / point >= min_rng:
                ds["built"] = True

        if not ds["built"] or st.side:
            return
        max_tr = 1 if first_only else 2
        if ds["trades"] >= max_tr:
            return

        hi = ds["hi"] + buf
        lo = ds["lo"] - buf
        bar_hi = float(df["high"].iloc[i])
        bar_lo = float(df["low"].iloc[i])

        if params.get("allow_long", True) and bar_hi >= hi:
            open_pos(i, "BUY", mid)
            st.sl = ds["lo"]
            ds["trades"] += 1
        elif params.get("allow_short", True) and bar_lo <= lo:
            open_pos(i, "SELL", mid)
            st.sl = ds["hi"]
            ds["trades"] += 1

        if st.side:
            if st.side == "BUY" and bar_lo <= st.sl:
                close(i, st.sl, "sl")
            elif st.side == "SELL" and bar_hi >= st.sl:
                close(i, st.sl, "sl")

    return _run_single_position(
        df, symbol, point, costs, lot, strategy_id, "M20", period_label, params, 10_000.0, on_bar,
    )


ENGINE_MAP = {
    "rsi_scalp": backtest_rsi_scalp,
    "rsi_crossover": backtest_rsi_crossover,
    "rsi_asian": backtest_rsi_asian,
    "mean_reversion": backtest_mean_reversion,
    "ema_slope": backtest_ema_slope,
    "darvas": backtest_darvas,
    "rsi_secret": backtest_rsi_secret,
    "simple_trendline": backtest_simple_trendline,
    "usdjpy_buster": backtest_usdjpy_buster,
}
