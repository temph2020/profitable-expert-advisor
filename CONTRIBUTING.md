# Contributing

## Scope

This repo focuses on MetaTrader 5 Expert Advisors, Python backtesting, and ONNX ML integration. Keep PRs focused on one area (e.g. one strategy or one audit script).

## Setup

1. Clone the repo
2. Install Python deps per subdirectory (`backtesting/MT5/requirements.txt`, `ai/*/requirements.txt`)
3. Use your **local** MT5 terminal for tester automation — no account credentials in code

## Code conventions

- **MQL5**: match existing `Strategies/*.mqh` patterns; magic numbers via `MagicNumberHelpers.mqh`
- **Python**: minimal dependencies; reuse `set_parser.py`, `cluster_audit/united_mt5_runner.py`
- **Sets**: name files descriptively; document non-obvious params in strategy README

## Do not submit

- `.env`, API keys, account logins
- `ReportTester*.html`, `trades.csv`, `*.ex5`
- PDF/PNG/JPG charts and brochures (`*.pdf`, `report.png`, `test-balance.jpg`, …)
- `mt5_results.json`, `mt5_reports/`, `lab/**/best_run/`
- Generated audit JSON under `cluster_audit/reports/`
- Unrelated personal projects or book manuscripts

Before first push, run:

```bash
python scripts/prepare_public_upload.py
```

## Pull requests

1. Describe strategy / audit change and test window used
2. Note whether results are from MT5 tester or Python replay
3. Confirm `git status` shows no ignored sensitive files staged

See [`docs/STRUCTURE.md`](docs/STRUCTURE.md) for layout.
