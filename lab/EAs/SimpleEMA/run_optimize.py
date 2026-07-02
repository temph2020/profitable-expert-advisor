"""
Fast vectorized optimizer for SimpleEMA v2 (crossover + pullback entries).

Target: net_profit > 0, trades >= min_trades (default 2000).

Usage:
  python run_optimize.py --trials 5000 --min-trades 2000
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402
from indicator_utils import calculate_adx, calculate_atr, calculate_ema  # noqa: E402
from run_backtest import pip_size  # noqa: E402

TF_MAP = {"M15": mt5.TIMEFRAME_M15, "M5": mt5.TIMEFRAME_M5}


@dataclass
class Params:
    fast_ema: int = 8
    slow_ema: int = 34
    entry_mode: int = 1
    min_ema_gap_pips: float = 0.0
    cooldown_bars: int = 4
    use_atr_stops: bool = True
    atr_period: int = 14
    atr_sl_mult: float = 2.0
    atr_tp_mult: float = 4.0
    stop_loss_pips: float = 20.0
    take_profit_pips: float = 40.0
    exit_on_cross: bool = False
    max_bars_in_trade: int = 96
    use_trailing: bool = True
    trail_atr_mult: float = 1.2
    use_adx_filter: bool = True
    adx_period: int = 14
    adx_min: float = 18.0
    use_htf_filter: bool = True
    htf_ema_period: int = 100
    session_start: int = 7
    session_end: int = 21
    max_spread_pips: float = 8.0
    lot_size: float = 0.10
    initial_balance: float = 10_000.0


@dataclass
class SimResult:
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe: float
    trades: list[dict]


@dataclass
class MarketData:
    df: pd.DataFrame
    close: np.ndarray
    open_: np.ndarray
    high: np.ndarray
    low: np.ndarray
    hours: np.ndarray
    fast: dict[int, np.ndarray]
    slow: dict[int, np.ndarray]
    atr: dict[int, np.ndarray]
    adx: dict[int, np.ndarray]
    htf: dict[int, np.ndarray]


def load_market(df: pd.DataFrame) -> MarketData:
    close_s = df["close"]
    h4 = close_s.resample("4h").last().dropna()
    fast = {p: calculate_ema(close_s, p).to_numpy() for p in range(5, 13)}
    slow = {p: calculate_ema(close_s, p).to_numpy() for p in range(20, 61, 2)}
    atr = {p: calculate_atr(df, p).to_numpy() for p in (10, 14, 20)}
    adx = {p: calculate_adx(df, p).to_numpy() for p in (10, 14, 20)}
    htf = {p: calculate_ema(h4, p).reindex(df.index, method="ffill").to_numpy() for p in (50, 100, 200)}
    return MarketData(
        df=df,
        close=close_s.to_numpy(),
        open_=df["open"].to_numpy(),
        high=df["high"].to_numpy(),
        low=df["low"].to_numpy(),
        hours=df.index.hour.to_numpy(),
        fast=fast,
        slow=slow,
        atr=atr,
        adx=adx,
        htf=htf,
    )


def make_signals(md: MarketData, p: Params, pip: float) -> dict[str, np.ndarray]:
    fast, slow = md.fast[p.fast_ema], md.slow[p.slow_ema]
    close, high, low = md.close, md.high, md.low
    f1, f2 = np.roll(fast, 1), np.roll(fast, 2)
    s1, s2 = np.roll(slow, 1), np.roll(slow, 2)
    c1, h1, l1 = np.roll(close, 1), np.roll(high, 1), np.roll(low, 1)

    bull_cross = (f2 <= s2) & (f1 > s1)
    bear_cross = (f2 >= s2) & (f1 < s1)
    bull_pb = (f1 > s1) & (l1 <= f1) & (c1 > f1)
    bear_pb = (f1 < s1) & (h1 >= f1) & (c1 < f1)

    if p.entry_mode == 0:
        buy_raw, sell_raw = bull_cross, bear_cross
    elif p.entry_mode == 2:
        buy_raw, sell_raw = bull_pb, bear_pb
    else:
        buy_raw = bull_cross | bull_pb
        sell_raw = bear_cross | bear_pb

    gap_ok = np.abs(f1 - s1) / pip >= p.min_ema_gap_pips
    sess = (md.hours >= p.session_start) & (md.hours < p.session_end)
    adx_arr = md.adx[p.adx_period]
    adx_ok = adx_arr >= p.adx_min if p.use_adx_filter else np.ones(len(close), dtype=bool)
    htf_arr = md.htf[p.htf_ema_period]
    if p.use_htf_filter:
        htf_bull = close > htf_arr
        htf_bear = close < htf_arr
    else:
        htf_bull = htf_bear = np.ones(len(close), dtype=bool)

    buy_sig = buy_raw & gap_ok & sess & adx_ok & htf_bull
    sell_sig = sell_raw & gap_ok & sess & adx_ok & htf_bear
    buy_sig[: p.slow_ema + 3] = False
    sell_sig[: p.slow_ema + 3] = False

    return {
        "open": md.open_,
        "high": md.high,
        "low": md.low,
        "close": md.close,
        "atr": md.atr[p.atr_period],
        "bull_cross": bull_cross,
        "bear_cross": bear_cross,
        "buy_sig": buy_sig,
        "sell_sig": sell_sig,
    }


def simulate(md: MarketData, symbol: str, p: Params, costs: CostModel, pip: float, point: float) -> SimResult:
    sig = make_signals(md, p, pip)
    opn, high, low, close = sig["open"], sig["high"], sig["low"], sig["close"]
    atr = sig["atr"]
    bull_cross, bear_cross = sig["bull_cross"], sig["bear_cross"]
    buy_sig, sell_sig = sig["buy_sig"], sig["sell_sig"]

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
    trail = 0.0
    last_entry_i = -10_000

    def calc_profit(entry_px: float, exit_px: float, s: str) -> float:
        ot = mt5.ORDER_TYPE_BUY if s == "BUY" else mt5.ORDER_TYPE_SELL
        pr = mt5.order_calc_profit(ot, symbol, p.lot_size, entry_px, exit_px)
        return float(pr) - commission if pr is not None else -commission

    warm = max(p.slow_ema + 5, 30)
    for i in range(warm, len(md.df)):
        atr1 = float(atr[i - 1]) if not np.isnan(atr[i - 1]) else 0.0
        mid = float(opn[i])

        if side is not None:
            bars_held = i - entry_i
            closed = False
            if p.max_bars_in_trade > 0 and bars_held >= p.max_bars_in_trade:
                exit_px = mid - half if side == "BUY" else mid + half
                profit = calc_profit(entry, exit_px, side)
                balance += profit
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "max_bars"})
                closed = True
            elif p.exit_on_cross and side == "BUY" and bear_cross[i]:
                profit = calc_profit(entry, mid - half, side)
                balance += profit
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "bear_cross"})
                closed = True
            elif p.exit_on_cross and side == "SELL" and bull_cross[i]:
                profit = calc_profit(entry, mid + half, side)
                balance += profit
                trades.append({"side": side, "open_i": entry_i, "close_i": i, "profit": profit, "exit_reason": "bull_cross"})
                closed = True
            elif side == "BUY":
                if p.use_atr_stops and atr1 > 0:
                    sl_px = entry - atr1 * p.atr_sl_mult
                    tp_px = entry + atr1 * p.atr_tp_mult
                else:
                    sl_px = entry - p.stop_loss_pips * pip
                    tp_px = entry + p.take_profit_pips * pip
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
                if p.use_atr_stops and atr1 > 0:
                    sl_px = entry + atr1 * p.atr_sl_mult
                    tp_px = entry - atr1 * p.atr_tp_mult
                else:
                    sl_px = entry + p.stop_loss_pips * pip
                    tp_px = entry - p.take_profit_pips * pip
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

        if side is None:
            spread_pips = spread_px / pip if pip > 0 else 0
            if not (p.max_spread_pips > 0 and spread_pips > p.max_spread_pips) and i - last_entry_i >= p.cooldown_bars:
                if buy_sig[i]:
                    side, entry, entry_i, trail, last_entry_i = "BUY", mid + half, i, 0.0, i
                elif sell_sig[i]:
                    side, entry, entry_i, trail, last_entry_i = "SELL", mid - half, i, 0.0, i

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


def sample(rng: random.Random, high_freq: bool = False) -> Params:
    fast = rng.randint(5, 12)
    if high_freq:
        return Params(
            fast_ema=fast,
            slow_ema=rng.choice([p for p in range(max(fast + 6, 20), 41, 2)]),
            entry_mode=rng.choice([1, 1, 1, 2]),
            min_ema_gap_pips=round(rng.uniform(0, 1.5), 1),
            cooldown_bars=rng.choice([2, 2, 3, 4]),
            atr_period=rng.choice([10, 14, 20]),
            atr_sl_mult=round(rng.uniform(1.8, 3.2), 2),
            atr_tp_mult=round(rng.uniform(4.0, 9.0), 2),
            exit_on_cross=False,
            max_bars_in_trade=rng.choice([64, 96, 128]),
            use_trailing=False,
            use_adx_filter=rng.choice([False, False, True]),
            adx_min=round(rng.uniform(15, 28), 1),
            use_htf_filter=rng.choice([False, False, True]),
            htf_ema_period=rng.choice([50, 100, 200]),
            session_start=rng.choice([0, 6, 7]),
            session_end=rng.choice([21, 22, 24]),
            max_spread_pips=rng.choice([8, 10]),
        )
    return Params(
        fast_ema=fast,
        slow_ema=rng.choice([p for p in range(max(fast + 8, 20), 61, 2)]),
        entry_mode=rng.choice([0, 1, 1, 1, 2]),
        min_ema_gap_pips=round(rng.uniform(0, 3), 1),
        cooldown_bars=rng.choice([2, 4, 6, 8]),
        atr_period=rng.choice([10, 14, 20]),
        atr_sl_mult=round(rng.uniform(1.5, 3.5), 2),
        atr_tp_mult=round(rng.uniform(3.0, 8.0), 2),
        exit_on_cross=rng.choice([False, False, True]),
        max_bars_in_trade=rng.choice([48, 64, 96, 128, 0]),
        use_trailing=rng.choice([True, True, False]),
        trail_atr_mult=round(rng.uniform(0.8, 2.0), 2),
        use_adx_filter=rng.choice([True, False]),
        adx_min=round(rng.uniform(15, 30), 1),
        use_htf_filter=rng.choice([True, False]),
        htf_ema_period=rng.choice([50, 100, 200]),
        session_start=rng.choice([6, 7, 8]),
        session_end=rng.choice([20, 21, 22]),
        max_spread_pips=rng.choice([6, 8, 10]),
    )


def write_set(p: Params, path: Path) -> None:
    path.write_text(
        "\n".join(
            [
                "; SimpleEMA v2 optimized",
                "Timeframe=16388",
                f"FastEmaPeriod={p.fast_ema}",
                f"SlowEmaPeriod={p.slow_ema}",
                f"EntryMode={p.entry_mode}",
                f"MinEmaGapPips={p.min_ema_gap_pips}",
                f"CooldownBars={p.cooldown_bars}",
                f"UseAtrStops={'true' if p.use_atr_stops else 'false'}",
                f"AtrPeriod={p.atr_period}",
                f"AtrSlMult={p.atr_sl_mult}",
                f"AtrTpMult={p.atr_tp_mult}",
                f"ExitOnCross={'true' if p.exit_on_cross else 'false'}",
                f"MaxBarsInTrade={p.max_bars_in_trade}",
                f"UseTrailing={'true' if p.use_trailing else 'false'}",
                f"TrailAtrMult={p.trail_atr_mult}",
                f"UseAdxFilter={'true' if p.use_adx_filter else 'false'}",
                f"AdxPeriod={p.adx_period}",
                f"AdxMin={p.adx_min}",
                f"UseHtfFilter={'true' if p.use_htf_filter else 'false'}",
                f"HtfEmaPeriod={p.htf_ema_period}",
                f"SessionStartHour={p.session_start}",
                f"SessionEndHour={p.session_end}",
                f"MaxSpreadPips={p.max_spread_pips}",
                f"LotSize={p.lot_size}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="EURUSD")
    ap.add_argument("--timeframe", default="M15")
    ap.add_argument("--start", default="2020-01-01")
    ap.add_argument("--end", default="2026-01-01")
    ap.add_argument("--trials", type=int, default=5000)
    ap.add_argument("--min-trades", type=int, default=2000)
    ap.add_argument("--max-trades", type=int, default=3500)
    ap.add_argument("--profile", choices=["profit", "high-freq", "balanced"], default="balanced",
                    help="profit=max net; high-freq=2k-3.5k trades; balanced=net>0 with most trades")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    out = Path(__file__).resolve().parent
    rng = random.Random(args.seed)

    if not mt5.initialize():
        raise SystemExit("MT5 init failed")
    try:
        sym = resolve_symbol(args.symbol)
        df = load_bars(sym, TF_MAP[args.timeframe], datetime.fromisoformat(args.start), datetime.fromisoformat(args.end))
        costs = CostModel.for_symbol(sym)
        pip = pip_size(sym)
        point = float(mt5.symbol_info(sym).point)
        print(f"{sym} {args.timeframe} bars={len(df)} trials={args.trials} min_trades={args.min_trades}", flush=True)
        print("Precomputing market data ...", flush=True)
        md = load_market(df)

        best: SimResult | None = None
        best_p: Params | None = None
        target: tuple[SimResult, Params] | None = None
        rows = []

        hi_freq: tuple[SimResult, Params] | None = None
        balanced: tuple[SimResult, Params] | None = None

        for n in range(1, args.trials + 1):
            p = sample(rng, high_freq=(args.profile == "high-freq"))
            r = simulate(md, sym, p, costs, pip, point)
            rows.append({"trial": n, "net": r.net_profit, "trades": r.total_trades, "pf": r.profit_factor, **asdict(p)})

            if best is None or r.net_profit > best.net_profit:
                best, best_p = r, p

            if args.min_trades <= r.total_trades <= args.max_trades and r.net_profit > 0 and r.profit_factor >= 1.05:
                if target is None or r.net_profit > target[0].net_profit:
                    target = (r, p)
                    print(
                        f"  HIT {n}: net=${r.net_profit:,.0f} trades={r.total_trades} "
                        f"PF={r.profit_factor:.2f} WR={r.win_rate:.1f}%",
                        flush=True,
                    )

            if args.min_trades <= r.total_trades <= args.max_trades:
                if hi_freq is None or r.net_profit > hi_freq[0].net_profit:
                    hi_freq = (r, p)

            if r.net_profit > 0 and r.profit_factor >= 1.02:
                if balanced is None or r.total_trades > balanced[0].total_trades or (
                    r.total_trades == balanced[0].total_trades and r.net_profit > balanced[0].net_profit
                ):
                    balanced = (r, p)

            if n % 1000 == 0:
                b = balanced or hi_freq or (best, best_p)
                print(
                    f"  ... {n}/{args.trials} profile={args.profile} "
                    f"best_net=${best.net_profit:,.0f} t={best.total_trades} hit={'yes' if target else 'no'}",
                    flush=True,
                )

        pd.DataFrame(rows).sort_values("net", ascending=False).to_csv(out / "optimize_trials.csv", index=False)

        if args.profile == "profit":
            final_r, final_p = target if target else (best, best_p)
        elif args.profile == "high-freq":
            final_r, final_p = hi_freq if hi_freq else (best, best_p)
        else:
            final_r, final_p = balanced if balanced else (target if target else (best, best_p))
        assert final_r and final_p

        with open(out / "best_params.json", "w", encoding="utf-8") as f:
            json.dump({"target_met": target is not None, "params": asdict(final_p), "metrics": asdict(final_r)}, f, indent=2)
        write_set(final_p, out / "SimpleEMA_optimized.set")

        (out / "best_run").mkdir(exist_ok=True)
        trows = [
            {
                "side": t["side"],
                "open_time": df.index[t["open_i"]],
                "close_time": df.index[t["close_i"]],
                "profit": t["profit"],
                "exit_reason": t["exit_reason"],
            }
            for t in final_r.trades
        ]
        pd.DataFrame(trows).to_csv(out / "best_run" / "trades.csv", index=False)

        print(
            f"\n{'TARGET MET' if target else 'BEST EFFORT'}: net=${final_r.net_profit:,.2f} "
            f"trades={final_r.total_trades} PF={final_r.profit_factor:.2f} WR={final_r.win_rate:.1f}% "
            f"MaxDD={final_r.max_drawdown_pct:.1f}%",
            flush=True,
        )
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
