from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .expressions import compile_expression


@dataclass
class EngineConfig:
    factor_expression: str
    rebalance_frequency: str = "M"  # D/W/M/Q
    long_quantile: float = 0.2
    short_quantile: float = 0.2
    long_short: bool = True


def run_factor_engine(df: pd.DataFrame, cfg: EngineConfig) -> tuple[pd.DataFrame, pd.DataFrame]:
    data = df.copy()
    data = data.sort_values(["date", "asset"]).reset_index(drop=True)
    data["ret_1d"] = data.groupby("asset")["close"].pct_change().fillna(0.0)

    expr = compile_expression(cfg.factor_expression)
    data["score"] = expr.eval(data).replace([np.inf, -np.inf], np.nan)

    rebalance_key = data["date"].dt.to_period(cfg.rebalance_frequency).astype(str)
    data["rebalance_key"] = rebalance_key

    weights = []
    for _, bucket in data.groupby("rebalance_key"):
        last_day = bucket["date"].max()
        snap = bucket[bucket["date"] == last_day].copy()
        snap = snap.dropna(subset=["score"])
        if snap.empty:
            continue

        q_long = snap["score"].quantile(1.0 - cfg.long_quantile)
        longs = snap[snap["score"] >= q_long][["asset"]].copy()
        longs["w"] = 1.0 / max(len(longs), 1)

        if cfg.long_short and cfg.short_quantile > 0:
            q_short = snap["score"].quantile(cfg.short_quantile)
            shorts = snap[snap["score"] <= q_short][["asset"]].copy()
            shorts["w"] = -1.0 / max(len(shorts), 1)
            snap_w = pd.concat([longs, shorts], ignore_index=True)
        else:
            snap_w = longs

        snap_w["effective_date"] = last_day
        weights.append(snap_w)

    if not weights:
        empty = pd.DataFrame(columns=["date", "portfolio_ret", "equity"])
        return empty, data

    wdf = pd.concat(weights, ignore_index=True)
    data = data.merge(wdf, how="left", left_on=["date", "asset"], right_on=["effective_date", "asset"])
    data["w"] = data.groupby("asset")["w"].ffill().fillna(0.0)
    data["contrib"] = data["w"] * data["ret_1d"]

    daily = data.groupby("date", as_index=False)["contrib"].sum().rename(columns={"contrib": "portfolio_ret"})
    daily["equity"] = (1.0 + daily["portfolio_ret"]).cumprod()
    return daily, data


def summary_metrics(equity_curve: pd.DataFrame) -> dict:
    if equity_curve.empty:
        return {"cagr": 0.0, "sharpe": 0.0, "max_dd": 0.0, "total_return": 0.0}

    rets = equity_curve["portfolio_ret"]
    total_return = equity_curve["equity"].iloc[-1] - 1.0

    n = len(rets)
    ann = 252
    cagr = (equity_curve["equity"].iloc[-1] ** (ann / max(n, 1))) - 1.0
    vol = rets.std(ddof=0) * np.sqrt(ann)
    sharpe = (rets.mean() * ann) / vol if vol > 1e-12 else 0.0

    rolling_max = equity_curve["equity"].cummax()
    dd = equity_curve["equity"] / rolling_max - 1.0
    max_dd = dd.min()

    return {
        "cagr": float(cagr),
        "sharpe": float(sharpe),
        "max_dd": float(max_dd),
        "total_return": float(total_return),
    }

