"""Constrained param search — trades must stay >= baseline. Run once then delete."""
from __future__ import annotations

import importlib.util
import json
import random
import sys
from dataclasses import fields, replace
from datetime import datetime
from pathlib import Path

import MetaTrader5 as mt5

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backtesting" / "MT5"))
from cluster_audit.backtest_core import CostModel, load_bars, resolve_symbol  # noqa: E402

UNITS = Path(__file__).resolve().parent
TRIALS = 250
START, END = "2021-01-01", "2026-01-01"

SEARCH: dict[str, dict] = {
  "RSIReversalAsianAUDUSD": {
    "symbol": "AUDUSD", "tf": mt5.TIMEFRAME_M15, "min_trades": 351,
    "ranges": {"rsi_period": (20, 40, 2), "overbought_level": (60, 85, 5),
               "oversold_level": (15, 45, 5), "rsi_exit_level": (40, 58, 3)},
  },
  "RSIReversalAsianGBPUSD": {
    "symbol": "GBPUSD", "tf": mt5.TIMEFRAME_M15, "min_trades": 326,
    "ranges": {"rsi_period": (24, 40, 2), "overbought_level": (70, 90, 5),
               "oversold_level": (20, 45, 5), "rsi_exit_level": (38, 55, 3)},
  },
  "RSIReversalAsianEURUSD": {
    "symbol": "EURUSD", "tf": mt5.TIMEFRAME_M15, "min_trades": 506,
    "ranges": {"rsi_period": (20, 40, 2), "overbought_level": (55, 75, 5),
               "oversold_level": (5, 25, 3), "rsi_exit_level": (45, 60, 5)},
  },
  "RSIScalpingBTCUSD": {
    "symbol": "BTCUSD", "tf": mt5.TIMEFRAME_H1, "min_trades": 437,
    "ranges": {"rsi_period": (8, 20, 2), "rsi_overbought": (45, 75, 5),
               "rsi_oversold": (20, 45, 3), "rsi_target_buy": (55, 85, 5),
               "rsi_target_sell": (30, 55, 5), "bars_to_wait": (3, 10, 1)},
  },
  "RSIScalpingAPPL": {
    "symbol": "AAPL", "tf": mt5.TIMEFRAME_M10, "min_trades": 458,
    "ranges": {"rsi_period": (10, 22, 2), "rsi_overbought": (75, 95, 5),
               "rsi_oversold": (20, 45, 3), "rsi_target_buy": (80, 98, 4),
               "rsi_target_sell": (20, 50, 4), "bars_to_wait": (4, 12, 1)},
  },
  "RSIScalpingMU": {
    "symbol": "MU", "tf": mt5.TIMEFRAME_M20, "min_trades": 307,
    "ranges": {"rsi_period": (14, 26, 2), "rsi_overbought": (40, 70, 4),
               "rsi_oversold": (20, 45, 3), "rsi_target_buy": (75, 98, 4),
               "rsi_target_sell": (40, 70, 4), "bars_to_wait": (4, 12, 1)},
  },
  "EMASlopeDistanceCocktailXAUUSD": {
    "symbol": "XAUUSD", "tf": mt5.TIMEFRAME_H1, "min_trades": 75,
    "ranges": {"ema_period": (60, 100, 5), "price_threshold_pips": (250, 450, 25),
               "slope_threshold_pips": (15, 35, 2.5), "max_loss_atr": (1.2, 2.5, 0.2),
               "profit_check_bars": (24, 60, 6)},
  },
  "RSICrossOverReversalXAUUSD": {
    "symbol": "XAUUSD", "tf": mt5.TIMEFRAME_M12, "min_trades": 17,
    "ranges": {"overbought_level": (80, 95, 5), "oversold_level": (15, 35, 5),
               "ema_distance_threshold": (80, 400, 25), "trailing_stop_pts": (200, 400, 25)},
  },
  "RSI_secret_sauce_XAUUSD": {
    "symbol": "XAUUSD", "tf": mt5.TIMEFRAME_M30, "min_trades": 834,
    "ranges": {"rsi_overbought": (68, 85, 2.5), "rsi_oversold": (30, 50, 2.5),
               "stop_loss_atr": (2.0, 3.5, 0.25), "take_profit_atr": (4.0, 6.5, 0.5)},
  },
}


def _load_module(folder: Path):
  import runpy
  return runpy.run_path(str(folder / "run_backtest.py"))


def _sample(ranges: dict) -> dict:
  out = {}
  for k, (lo, hi, step) in ranges.items():
    n = int((hi - lo) / step)
    out[k] = lo + random.randint(0, max(0, n)) * step
  return out


def _patch_params_file(folder: Path, updates: dict) -> None:
  text = (folder / "run_backtest.py").read_text(encoding="utf-8")
  for k, v in updates.items():
    if isinstance(v, bool):
      rep = "True" if v else "False"
    elif isinstance(v, int):
      rep = str(v)
    else:
      rep = str(float(v)) if isinstance(v, float) else repr(v)
    import re
    text, n = re.subn(rf"^(\s*{k}: .* = ).*$", rf"\g<1>{rep}", text, count=1, flags=re.M)
    if n == 0:
      print(f"  warn: could not patch {k}")
  (folder / "run_backtest.py").write_text(text, encoding="utf-8")


def optimize_folder(name: str, cfg: dict) -> None:
  folder = UNITS / name
  mod = _load_module(folder)
  make_params = mod["make_params"]
  run_backtest = mod["run_backtest"]
  sym = resolve_symbol(cfg["symbol"])
  start, end = datetime.fromisoformat(START), datetime.fromisoformat(END)
  df = load_bars(sym, cfg["tf"], start, end)
  costs = CostModel.for_symbol(sym)
  period = f"{START}_{END}"
  base_p = make_params(10_000.0)
  base_r = run_backtest(df, sym, base_p, costs, period)
  min_trades = cfg.get("min_trades", base_r.total_trades)
  best_p, best_r = base_p, base_r
  print(f"\n{name}: baseline net={base_r.net_profit:.2f} trades={base_r.total_trades} (min={min_trades})")

  flds = {f.name for f in fields(base_p)}
  for _ in range(TRIALS):
    samp = _sample(cfg["ranges"])
    trial_p = replace(base_p, **{k: v for k, v in samp.items() if k in flds})
    r = run_backtest(df, sym, trial_p, costs, period)
    if r.total_trades < min_trades:
      continue
    if r.net_profit > best_r.net_profit:
      best_p, best_r = trial_p, r

  if best_r.net_profit > base_r.net_profit:
    updates = {f.name: getattr(best_p, f.name) for f in fields(best_p)
               if f.name in cfg["ranges"] and f.name != "initial_balance"}
    _patch_params_file(folder, updates)
    print(f"  IMPROVED net={best_r.net_profit:.2f} trades={best_r.total_trades} params={updates}")
  else:
    print(f"  kept baseline net={base_r.net_profit:.2f} trades={base_r.total_trades}")


def main() -> None:
  if not mt5.initialize():
    raise SystemExit("MT5 init failed")
  try:
    for name, cfg in SEARCH.items():
      optimize_folder(name, cfg)
  finally:
    mt5.shutdown()


if __name__ == "__main__":
  main()
