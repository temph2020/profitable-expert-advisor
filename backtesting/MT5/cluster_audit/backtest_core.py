"""Shared backtest primitives — fills, costs, metrics, trade log."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import MetaTrader5 as mt5
import numpy as np
import pandas as pd


@dataclass
class CostModel:
    spread_points: float = 0.0
    slippage_points: float = 3.0
    commission_per_lot: float = 0.0

    @classmethod
    def for_symbol(cls, symbol: str, slippage: float = 3.0) -> "CostModel":
        info = mt5.symbol_info(symbol)
        spread = float(info.spread) if info else 0.0
        return cls(spread_points=spread, slippage_points=slippage)


@dataclass
class Trade:
    side: str
    open_time: Any
    close_time: Any
    open_price: float
    close_price: float
    volume: float
    profit: float
    bars_held: int = 0
    exit_reason: str = ""


@dataclass
class BacktestReport:
    strategy_id: str
    symbol: str
    timeframe: str
    period_label: str
    net_profit: float
    total_trades: int
    win_rate: float
    profit_factor: float
    sharpe: float
    max_drawdown_pct: float
    avg_win: float
    avg_loss: float
    worst_trades: list[dict]
    losing_trades: list[dict]
    exit_reason_breakdown: dict[str, dict[str, float]]
    monthly_returns: dict[str, float]
    params: dict[str, Any] = field(default_factory=dict)
    gross_profit: float = 0.0
    gross_loss: float = 0.0
    trades_list: list[Trade] = field(default_factory=list, repr=False)
    equity_curve: pd.Series | None = field(default=None, repr=False)

    def to_dict(self) -> dict:
        return {
            "strategy_id": self.strategy_id,
            "symbol": self.symbol,
            "timeframe": self.timeframe,
            "period": self.period_label,
            "net_profit": self.net_profit,
            "total_trades": self.total_trades,
            "win_rate": self.win_rate,
            "profit_factor": self.profit_factor,
            "sharpe": self.sharpe,
            "max_drawdown_pct": self.max_drawdown_pct,
            "avg_win": self.avg_win,
            "avg_loss": self.avg_loss,
            "worst_trades": self.worst_trades,
            "losing_trades": self.losing_trades,
            "exit_reason_breakdown": self.exit_reason_breakdown,
            "monthly_returns": self.monthly_returns,
            "params": self.params,
        }


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
        if sym.name.startswith(key + "."):
            mt5.symbol_select(sym.name, True)
            return sym.name
    return key


def load_bars(symbol: str, tf: int, start, end, trace: bool = False) -> pd.DataFrame:
    requested = symbol
    symbol = resolve_symbol(symbol)
    if trace and symbol != requested:
        print(f"    [load_bars] resolved {requested} -> {symbol}", flush=True)
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"Cannot select {symbol}")
    rates = mt5.copy_rates_range(symbol, tf, start, end)
    if rates is None or len(rates) < 50:
        raise RuntimeError(f"No data for {symbol} ({mt5.last_error()})")
    if trace:
        print(f"    [load_bars] {symbol} got {len(rates)} bars", flush=True)
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df.set_index("time", inplace=True)
    return df


def calc_profit(symbol: str, side: str, volume: float, entry: float, exit_px: float) -> float:
    ot = mt5.ORDER_TYPE_BUY if side == "BUY" else mt5.ORDER_TYPE_SELL
    p = mt5.order_calc_profit(ot, symbol, volume, entry, exit_px)
    return float(p) if p is not None else 0.0


def _half_spread(point: float, spread_pts: float) -> float:
    return spread_pts * point / 2.0


def fill_price(mid: float, point: float, costs: CostModel, side: str, entry: bool) -> float:
    hs = _half_spread(point, costs.spread_points)
    slip = costs.slippage_points * point
    if side == "BUY":
        return mid + hs + slip if entry else mid - hs - slip
    return mid - hs - slip if entry else mid + hs + slip


@dataclass
class SimState:
    side: str | None = None
    entry: float = 0.0
    entry_i: int = 0
    entry_time: object = None
    sl: float = 0.0
    tp: float = 0.0
    bars_against: int = 0
    rsi_against: bool = False


def _bar_seconds(tf_label: str) -> int:
    mapping = {
        "M1": 60, "M5": 300, "M10": 600, "M12": 720, "M15": 900, "M20": 1200,
        "M30": 1800, "H1": 3600, "H2": 7200, "H4": 14400, "D1": 86400,
    }
    return mapping.get(tf_label.upper(), 3600)


def run_single_position(
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
    bar_seconds: int | None = None,
) -> BacktestReport:
    """Single-position bar loop with mark-to-market equity each bar."""
    bar_sec = bar_seconds or _bar_seconds(tf_label)
    trades: list[Trade] = []
    realized_pnl = 0.0
    equity: list[float] = [initial_balance]
    st = SimState()

    def close(i: int, mid: float, reason: str) -> None:
        nonlocal st, realized_pnl
        if st.side is None:
            return
        exit_px = fill_price(mid, point, costs, st.side, entry=False)
        commission = costs.commission_per_lot * lot * 2.0
        profit = calc_profit(symbol, st.side, lot, st.entry, exit_px) - commission
        held = max(1, int((df.index[i] - pd.Timestamp(st.entry_time)).total_seconds() / bar_sec))
        trades.append(
            Trade(
                side=st.side,
                open_time=st.entry_time,
                close_time=df.index[i],
                open_price=st.entry,
                close_price=exit_px,
                volume=lot,
                profit=profit,
                bars_held=held,
                exit_reason=reason,
            )
        )
        realized_pnl += profit
        st = SimState()

    def open_pos(i: int, side: str, mid: float) -> None:
        nonlocal st
        st.side = side
        st.entry = fill_price(mid, point, costs, side, entry=True)
        st.entry_i = i
        st.entry_time = df.index[i]

    for i in range(1, len(df)):
        on_bar(i, st, open_pos, close)
        bal = initial_balance + realized_pnl
        if st.side is not None:
            mark = float(df["close"].iloc[i - 1])
            bal += calc_profit(symbol, st.side, lot, st.entry, mark)
        equity.append(bal)

    if st.side is not None:
        close(len(df) - 1, float(df["close"].iloc[-1]), "eod")

    eq = pd.Series(equity[: len(df)], index=df.index[: len(equity)])
    report = build_report(strategy_id, symbol, tf_label, period_label, trades, eq, initial_balance, params)
    report.equity_curve = eq
    return report


def build_report(
    strategy_id: str,
    symbol: str,
    timeframe: str,
    period_label: str,
    trades: list[Trade],
    equity_curve: pd.Series,
    initial_balance: float,
    params: dict,
) -> BacktestReport:
    if not trades:
        return BacktestReport(
            strategy_id=strategy_id,
            symbol=symbol,
            timeframe=timeframe,
            period_label=period_label,
            net_profit=0.0,
            total_trades=0,
            win_rate=0.0,
            profit_factor=0.0,
            sharpe=0.0,
            max_drawdown_pct=0.0,
            avg_win=0.0,
            avg_loss=0.0,
            worst_trades=[],
            losing_trades=[],
            exit_reason_breakdown={},
            monthly_returns={},
            params=params,
        )

    profits = [t.profit for t in trades]
    wins = [p for p in profits if p >= 0]
    losses = [abs(p) for p in profits if p < 0]
    gp = sum(wins)
    gl = sum(losses)
    net = sum(profits)

    rets = equity_curve.pct_change().dropna()
    sharpe = 0.0
    if len(rets) > 10 and rets.std() > 0:
        bars_per_year = 252 * 24 if "H1" in timeframe else 252 * 24 * 6
        scale = np.sqrt(bars_per_year / max(len(rets), 1))
        sharpe = float(rets.mean() / rets.std() * scale)

    peak = equity_curve.cummax()
    dd = (peak - equity_curve) / peak.replace(0, np.nan)
    max_dd = float(dd.max()) if len(dd) else 0.0

    monthly = equity_curve.resample("ME").last().pct_change().dropna()
    monthly_dict = {str(k.date()): float(v) for k, v in monthly.items()}

    def trade_row(t: Trade) -> dict:
        return {
            "side": t.side,
            "open_time": str(t.open_time),
            "close_time": str(t.close_time),
            "open_price": t.open_price,
            "close_price": t.close_price,
            "profit": t.profit,
            "bars_held": t.bars_held,
            "exit_reason": t.exit_reason,
        }

    sorted_trades = sorted(trades, key=lambda t: t.profit)
    losers = [trade_row(t) for t in sorted_trades if t.profit < 0]
    breakdown: dict[str, dict[str, float]] = {}
    for t in trades:
        bucket = breakdown.setdefault(t.exit_reason or "?", {"count": 0, "pnl": 0.0, "wins": 0, "losses": 0})
        bucket["count"] += 1
        bucket["pnl"] += t.profit
        if t.profit >= 0:
            bucket["wins"] += 1
        else:
            bucket["losses"] += 1

    return BacktestReport(
        strategy_id=strategy_id,
        symbol=symbol,
        timeframe=timeframe,
        period_label=period_label,
        net_profit=net,
        total_trades=len(trades),
        win_rate=(len(wins) / len(trades) * 100.0) if trades else 0.0,
        profit_factor=(gp / gl) if gl > 0 else (999.0 if gp > 0 else 0.0),
        sharpe=sharpe,
        max_drawdown_pct=max_dd * 100.0,
        avg_win=(gp / len(wins)) if wins else 0.0,
        avg_loss=(gl / len(losses)) if losses else 0.0,
        worst_trades=[trade_row(t) for t in sorted_trades[:5]],
        losing_trades=losers[:30],
        exit_reason_breakdown=breakdown,
        monthly_returns=monthly_dict,
        params=params,
        gross_profit=gp,
        gross_loss=gl,
        trades_list=list(trades),
        equity_curve=equity_curve.copy(),
    )
