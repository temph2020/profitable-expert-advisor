"""Timestamped trace logging for cluster audit runs."""

from __future__ import annotations

import sys
import time
from datetime import datetime


class TraceLog:
    def __init__(self, enabled: bool = True, trial_every: int = 10) -> None:
        self.enabled = enabled
        self.trial_every = max(1, trial_every)
        self._t0 = time.perf_counter()
        self._phase_t0 = self._t0

    def _ts(self) -> str:
        return datetime.now().strftime("%H:%M:%S")

    def _elapsed(self) -> str:
        return f"{time.perf_counter() - self._t0:.1f}s"

    def _phase_elapsed(self) -> str:
        return f"{time.perf_counter() - self._phase_t0:.1f}s"

    def _write(self, level: str, msg: str) -> None:
        if not self.enabled:
            return
        line = f"[{self._ts()} +{self._elapsed()}] [{level}] {msg}"
        print(line, flush=True)

    def phase_start(self, name: str) -> None:
        self._phase_t0 = time.perf_counter()
        self._write("PHASE", f">> {name}")

    def phase_end(self, name: str, detail: str = "") -> None:
        suffix = f" -- {detail}" if detail else ""
        self._write("PHASE", f"OK {name} ({self._phase_elapsed()}){suffix}")

    def info(self, msg: str) -> None:
        self._write("INFO", msg)

    def debug(self, msg: str) -> None:
        self._write("DEBUG", msg)

    def warn(self, msg: str) -> None:
        self._write("WARN", msg)

    def error(self, msg: str) -> None:
        self._write("ERROR", msg)

    def banner(self, msg: str) -> None:
        if not self.enabled:
            return
        bar = "=" * min(72, max(len(msg) + 4, 40))
        print(f"\n{bar}\n  {msg}\n{bar}", flush=True)

    def progress(self, current: int, total: int, label: str) -> None:
        pct = (100.0 * current / total) if total else 0.0
        self._write("PROGRESS", f"[{current}/{total} {pct:.0f}%] {label}")

    def trial(self, n: int, total: int, score: float, net: float, sharpe: float, improved: bool) -> None:
        if n % self.trial_every != 0 and n != total and not improved:
            return
        flag = " ** NEW BEST" if improved else ""
        score_s = "N/A" if score == float("-inf") else f"{score:.2f}"
        self._write(
            "TRIAL",
            f"{n}/{total} score={score_s} net=${net:.0f} sharpe={sharpe:.2f}{flag}",
        )

    def report_line(self, strategy_id: str, baseline: dict, optimized: dict, bars: int) -> None:
        b, o = baseline, optimized
        self._write(
            "RESULT",
            f"{strategy_id}: bars={bars} | "
            f"base net=${b['net_profit']:.0f} sh={b['sharpe']:.2f} trades={b['total_trades']} dd={b['max_drawdown_pct']:.1f}% | "
            f"opt net=${o['net_profit']:.0f} sh={o['sharpe']:.2f} trades={o['total_trades']} dd={o['max_drawdown_pct']:.1f}%",
        )
        if b.get("worst_trades"):
            w = b["worst_trades"][0]
            self.debug(
                f"  worst loss: ${w['profit']:.2f} {w['side']} {w['exit_reason']} "
                f"({w['open_time']} -> {w['close_time']})"
            )
