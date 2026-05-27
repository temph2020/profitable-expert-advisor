# Self-coding agent (MQL5 + MT5 + Ollama, long-running)

This is a **local, long-running loop** that calls **Ollama** on your machine, lets the model **read/write allowed paths** in this repo (including MQL5 under `frontline/` and `lab/`), **fetch documentation** over HTTP, and optionally run the **Python MT5 backtest harness** in `backtesting/MT5/`. It keeps a **journal** and a small **evolution** memory so each iteration can build on the last.

It does **not** embed inside MetaTrader as an EA. For **Strategy Tester** on `.mq5` files, MT5’s terminal still has to compile and run tests; this agent automates the **Python** side and file edits. MQL5 compile verification can be added later via MetaEditor CLI if you want strict compile checks.

## What “indefinite” means here

`main.py` runs until you press **Ctrl+C** (or the process is stopped by your supervisor). For true daemon operation, run it under **Windows Task Scheduler**, **NSSM**, **systemd**, or a container restart policy.

Set `loop.max_iterations` to `0` in `config.yaml` for unlimited iterations (default in `config.example.yaml`).

## Requirements

- **Python 3.10+**
- **Ollama** running locally (`ollama serve`) with a model pulled (see `ollama list`; `config.example.yaml` defaults to `qwen2.5-coder:7b`).
- Optional: **MetaTrader 5** installed and logged in for `run_backtest` / `MetaTrader5` Python package (see `backtesting/MT5/README.md`)

## Quick start

```powershell
cd d:\profitable-expert-advisor\self-coding-agent
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
copy config.example.yaml config.yaml
# Edit config.yaml: set ollama.model, mission, allowed_path_prefixes if needed
python main.py
```

### CLI overrides (good for smoke tests)

```powershell
python main.py --max-iterations 2 --model qwen2.5-coder:7b --no-mt5-backtest --sleep-seconds 0
```

### Automated smoke tests (no Ollama)

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

On first failure to connect to Ollama, the loop backs off and retries (see `loop.consecutive_error_limit`).

## Configuration

- **`config.yaml`**: optional; if missing, `config.example.yaml` is used as defaults.
- **`workspace_root`**: default `..` resolves to the **repository root** (parent of `self-coding-agent/`).
- **`allowed_path_prefixes`**: hard sandbox for `read_file` / `write_file` / `list_dir`. Tighten this in production.
- **`mt5_backtest`**: toggles subprocess calls to `backtesting/MT5/run_backtest.py`.
- **`cursor.open_in_cursor_after_write`**: if `true`, tries `cursor <file>` on each write (requires `cursor` on PATH).

## Cursor integration

- **This script is not the Cursor IDE.** It complements Cursor: you can leave it running while you work in Cursor on the same repo.
- **Programmatic Cursor agents** (outside this repo) use the Cursor TypeScript SDK; see the Cursor SDK skill in your environment if you want CI/agents that call Cursor Cloud APIs with credentials.
- **Practical hybrid workflow:** run this agent for breadth (many small iterations, local model cost = $0); use Cursor for focused refactors, reviews, and hard problems.

## Self-evolve / self-improve (what is implemented)

- **`state/journal.jsonl`**: one JSON record per iteration (reflection, actions, errors).
- **`state/evolution.json`**: stores recent backtest stdout/stderr tails when `run_backtest` runs, so later prompts include a short “what happened last time” hint.

This is **deliberately minimal**: you can extend `agent/memory.py` to track numeric metrics, Pareto fronts, or mutation of parameters.

## Safety notes

- The model can only touch paths under **`allowed_path_prefixes`**.
- There is **no arbitrary shell** tool; only `run_backtest` and `run_python` with an allowlisted script path under the repo.
- **`fetch_url`** is HTTP(S) only; responses are size-capped.

## Ollama API

The client uses `POST /api/chat` with `stream: false`. Compatible with current Ollama HTTP API.

## Troubleshooting

- **`json.JSONDecodeError`**: the agent now prints a truncated copy of the model output to the console. Try a coder-tuned model, lower `temperature`, or raise `num_ctx` in `ollama.options`.
- **MT5 backtest fails**: run `python backtesting/MT5/test_setup.py` from repo root with MT5 open; see `backtesting/MT5/QUICKSTART.md`. On Windows, avoid Unicode symbols in console scripts (this repo’s `test_setup.py` uses ASCII markers like `[OK]`).
