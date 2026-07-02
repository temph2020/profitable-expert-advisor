from __future__ import annotations

import pandas as pd
import streamlit as st

from factor_tester.data import load_prices_csv
from factor_tester.engine import EngineConfig, run_factor_engine, summary_metrics
from factor_tester.optimize import optimize_grid

st.set_page_config(page_title="Factor Strategy Tester", layout="wide")
st.title("Factor Strategy Tester")
st.caption("MT5-style workflow for factor investing with custom expressions")

with st.sidebar:
    st.header("Inputs")
    uploaded = st.file_uploader("Upload prices/factors CSV", type=["csv"])
    expr = st.text_area(
        "Factor expression",
        value="(z(momentum_12m) + z(quality) - z(volatility_20d)) / 3",
        height=110,
    )
    freq = st.selectbox("Rebalance", ["D", "W", "M", "Q"], index=2)
    long_q = st.slider("Long quantile", 0.05, 0.50, 0.20, 0.05)
    long_short = st.checkbox("Long-short", value=True)
    short_q = st.slider("Short quantile", 0.05, 0.50, 0.20, 0.05, disabled=not long_short)
    run_btn = st.button("Run Single Test", type="primary", use_container_width=True)

    st.divider()
    st.subheader("Optimization")
    freq_grid = st.multiselect("Freq grid", ["D", "W", "M", "Q"], default=["W", "M"])
    long_grid = st.text_input("Long quantiles", value="0.1,0.2,0.3")
    short_grid = st.text_input("Short quantiles", value="0.1,0.2")
    ls_grid = st.multiselect("Long-short options", [True, False], default=[True])
    opt_btn = st.button("Run Optimization", use_container_width=True)

if uploaded is None:
    st.info("Upload a CSV to start. Required columns: `date`, `asset`, `close` + factor columns.")
    st.stop()

try:
    df = load_prices_csv(uploaded)
except Exception as e:
    st.error(f"Failed to load CSV: {e}")
    st.stop()

st.write("### Data Preview")
st.dataframe(df.head(20), use_container_width=True)

col1, col2, col3, col4 = st.columns(4)

if run_btn:
    try:
        cfg = EngineConfig(
            factor_expression=expr,
            rebalance_frequency=freq,
            long_quantile=float(long_q),
            short_quantile=float(short_q if long_short else 0.0),
            long_short=bool(long_short),
        )
        curve, detail = run_factor_engine(df, cfg)
        m = summary_metrics(curve)

        col1.metric("CAGR", f"{m['cagr']:.2%}")
        col2.metric("Sharpe", f"{m['sharpe']:.2f}")
        col3.metric("Max Drawdown", f"{m['max_dd']:.2%}")
        col4.metric("Total Return", f"{m['total_return']:.2%}")

        st.write("### Equity Curve")
        st.line_chart(curve.set_index("date")["equity"])

        st.write("### Daily Returns")
        st.line_chart(curve.set_index("date")["portfolio_ret"])

        st.write("### Engine Detail (tail)")
        st.dataframe(detail.tail(50), use_container_width=True)
    except Exception as e:
        st.error(f"Backtest failed: {e}")

if opt_btn:
    try:
        lq = [float(x.strip()) for x in long_grid.split(",") if x.strip()]
        sq = [float(x.strip()) for x in short_grid.split(",") if x.strip()]
        results = optimize_grid(
            df=df,
            factor_expression=expr,
            freqs=freq_grid or ["M"],
            long_qs=lq or [0.2],
            short_qs=sq or [0.2],
            long_short_options=ls_grid or [True],
        )
        st.write("### Optimization Results")
        st.dataframe(results, use_container_width=True)
    except Exception as e:
        st.error(f"Optimization failed: {e}")

