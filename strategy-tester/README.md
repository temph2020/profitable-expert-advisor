# Factor Strategy Tester (MT5-style workflow)

Python app scaffold that mirrors the **MT5 Strategy Tester flow** for **factor investing**:

- Single run backtest
- Parameter optimization (grid search)
- Inputs panel + report panel
- Custom factor expressions with safe operators
- Pluggable strategy engines

## Quick start

```bash
cd strategy-tester
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
streamlit run app.py
```

## Current capabilities

- Upload CSV with at least:
  - `date`
  - `asset`
  - `close`
  - feature columns (e.g. `pe`, `momentum_12m`, `quality`)
- Define factor score expression, e.g.:
  - `(z(momentum_12m) + z(quality) - z(volatility_20d)) / 3`
- Rebalance by period and choose top/bottom quantiles
- Long-only or long-short portfolio simulation
- Optimize selected parameters and rank by Sharpe/Return/Drawdown

## Expression language

Supported:

- Arithmetic: `+ - * / **`
- Comparisons: `> >= < <= == !=`
- Boolean: `and or not`
- Parentheses
- Functions:
  - `abs(x)`, `log(x)`, `sqrt(x)`
  - `z(x)` (cross-sectional z-score per date)
  - `rank(x)` (cross-sectional percentile rank per date)
  - `clip(x, lo, hi)`

The parser is AST-validated (no raw `eval`).

## Architecture

- `factor_tester/expressions.py`: safe expression compiler/evaluator
- `factor_tester/engine.py`: backtest engine API + default cross-sectional factor engine
- `factor_tester/optimize.py`: optimization runner
- `factor_tester/data.py`: CSV loading and validation
- `app.py`: Streamlit UI

## Next steps

- Walk-forward optimization
- Transaction costs/slippage model
- Multi-factor blend templates (value/size/momentum/quality/low-vol)
- Job queue / parallel optimization workers
