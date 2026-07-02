from __future__ import annotations

from itertools import product

import pandas as pd

from .engine import EngineConfig, run_factor_engine, summary_metrics


def optimize_grid(
    df: pd.DataFrame,
    factor_expression: str,
    freqs: list[str],
    long_qs: list[float],
    short_qs: list[float],
    long_short_options: list[bool],
) -> pd.DataFrame:
    rows = []
    for freq, lq, sq, ls in product(freqs, long_qs, short_qs, long_short_options):
        cfg = EngineConfig(
            factor_expression=factor_expression,
            rebalance_frequency=freq,
            long_quantile=lq,
            short_quantile=sq,
            long_short=ls,
        )
        curve, _ = run_factor_engine(df, cfg)
        m = summary_metrics(curve)
        rows.append(
            {
                "rebalance_frequency": freq,
                "long_quantile": lq,
                "short_quantile": sq,
                "long_short": ls,
                **m,
            }
        )
    out = pd.DataFrame(rows)
    if out.empty:
        return out
    return out.sort_values(["sharpe", "cagr"], ascending=[False, False]).reset_index(drop=True)

