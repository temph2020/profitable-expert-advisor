# Security Policy

## Reporting a vulnerability

If you discover a security issue in this repository, please **open a private GitHub security advisory** or contact the maintainer directly. Do not open a public issue for exploit details.

## Sensitive data — do not commit

- MT5 / broker **login numbers**, passwords, investor passwords
- API keys (`POLYMARKET_*`, broker REST keys, etc.)
- Private keys, wallet seeds, `.env` files
- Strategy Tester HTML reports (`ReportTester-*.html`) — may embed account & broker metadata
- Local machine paths (`C:\Users\...`, terminal hash folders)

## Local-only configuration

| Component | Config |
|-----------|--------|
| Polymarket | Copy `polymarket/.env.example` → `.env` (gitignored) |
| Self-coding agent | Copy `self-coding-agent/config.example.yaml` → `config.yaml` |
| MT5 automation | Uses **your** running MT5 terminal via `MetaTrader5` Python package — set `MT5_TERMINAL_DATA_ID` in `.env` (see `.env.example`) |

## Before pushing to GitHub

```bash
git status
# Ensure no .env, ReportTester*.html, *.ex5, trades.csv, cluster_audit/reports/
```

Run a quick scan:

```bash
rg -i "password|private_key|api_key|C:\\\\Users\\\\[^<]|D0E8209F" --glob '!*.md' .
```

## Trading risk disclaimer

This software is for research and education. Live trading involves substantial risk of loss. The authors are not responsible for financial losses from use of this code.
