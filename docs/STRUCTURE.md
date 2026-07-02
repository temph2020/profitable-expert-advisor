# Repository Structure

This monorepo groups **production EAs**, **research tooling**, and **ML experiments** for MetaTrader 5.

## Core (start here)

| Path | Purpose |
|------|---------|
| [`frontline/cluster-latest/`](../frontline/cluster-latest/) | **United cluster EA** — multi-strategy orchestrator (`main.mq5`), shared `Strategies/`, default `123.set` |
| [`frontline/units/`](../frontline/units/) | Standalone per-symbol EAs (baseline implementations) |
| [`backtesting/MT5/`](../backtesting/MT5/) | Python MT5 backtesting + `cluster_audit/` pipeline |
| [`ai/`](../ai/) | ONNX / LSTM training and MQL5 inference examples |

## Frontline variants

Same strategies, different deployment modes:

| Path | Variant |
|------|---------|
| `frontline/units-trailing/` | Trailing-stop parameter sets |
| `frontline/units-sharpshooter/` | Tighter entry / sharpshooter tuning |
| `frontline/units_economic_calendar/` | Calendar/session filters |
| `frontline/united_template/` | Template for building united multi-robot EAs |
| `frontline/cluster-NZDUSD/` | NZDUSD-only gene-combo cluster (R&D) |
| `frontline/cluster-SimpleEMA/` | SimpleEMA v5 35-symbol MT5 portfolio (per-symbol params) |
| `frontline/tradingview/` | Pine Script ports |

## Research & archive

| Path | Purpose |
|------|---------|
| [`back-pedal/`](../back-pedal/) | Archived / experimental MQL5 strategies |
| [`lab/`](../lab/) | Scratch EAs, indicators, one-off experiments |
| [`paper/`](../paper/) | Research write-up + simulation notebooks |
| [`strategy-tester/`](../strategy-tester/) | Factor / signal testing utilities |

## Optional modules

| Path | Purpose |
|------|---------|
| [`polymarket/`](../polymarket/) | Prediction-market research scaffold (needs API keys) |
| [`self-coding-agent/`](../self-coding-agent/) | Local Ollama coding loop (dev tooling) |

## What is NOT committed

See root [`.gitignore`](../.gitignore). In short:

- MT5 account numbers, broker reports, local paths
- `*.ex5`, `ReportTester*.html`, `trades.csv`, audit JSON dumps
- Trained model binaries (`*.onnx`, `*.pkl`) — regenerate from each `ai/*/README.md`
- LaTeX build artifacts and debug logs

## Recommended workflow

1. Edit EAs under `frontline/cluster-latest/` or `frontline/units/<Strategy>/`
2. Backtest with `backtesting/MT5/` or MT5 Strategy Tester + `.set` files
3. Run cluster audits: `python -m cluster_audit.run_close_signal_audit` (outputs stay local)
4. Copy compiled EA to your **local** `MQL5/Experts/` — never commit credentials
