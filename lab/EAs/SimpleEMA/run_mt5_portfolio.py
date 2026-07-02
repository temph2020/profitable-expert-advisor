#!/usr/bin/env python3
"""
Run MT5 Strategy Tester for each enabled portfolio symbol (source of truth).

Each symbol: main.mq5 + per-symbol .set from portfolio_params.json.
Aggregates HTML report metrics into best_run/mt5_results.json.

Usage:
  python run_mt5_portfolio.py
  python run_mt5_portfolio.py --only EURUSD,XAUUSD
  python run_mt5_portfolio.py --from 2020.01.01 --to 2026.01.01
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

LAB = Path(__file__).resolve().parent
ROOT = LAB.parents[2]  # repo root: .../profitable-expert-advisor
sys.path.insert(0, str(LAB))

from run_mt5_tester import mt5_context, run_tester  # noqa: E402


def write_member_set(params: dict, path: Path) -> None:
    """Write MT5 .set from portfolio_params member dict (no Python backtest imports)."""
    p = params
    lines = [
        "; SimpleEMA v5 — per-symbol MT5 set",
        "Timeframe=16388",
        f"FastEmaPeriod={p['fast_ema']}",
        f"SlowEmaPeriod={p['slow_ema']}",
        f"TrendLegBars={p['trend_leg_bars']}",
        f"MinEmaGapPips={p['min_ema_gap_pips']}",
        f"CrossCooldown={p['cross_cooldown']}",
        f"PullbackCooldown={p['pullback_cooldown']}",
        f"UsePullback={'true' if p['use_pullback'] else 'false'}",
        f"PullbackTouch={p['pullback_touch']}",
        f"PullbackAdxMin={p['pullback_adx_min']}",
        f"PullbackMinGapPips={p['pullback_min_gap_pips']}",
        f"MaxPullbacksPerLeg={p['max_pullbacks_per_leg']}",
        f"AtrPeriod={p['atr_period']}",
        f"AtrSlMult={p['atr_sl_mult']}",
        f"AtrTpMult={p['atr_tp_mult']}",
        f"MaxBarsInTrade={p['max_bars_in_trade']}",
        f"HtfEmaPeriod={p['htf_ema_period']}",
        f"UseHtfFilter={'true' if p['use_htf_filter'] else 'false'}",
        f"UseAdxFilter={'true' if p['use_adx_filter'] else 'false'}",
        f"AdxPeriod={p['adx_period']}",
        f"AdxMin={p['adx_min']}",
        f"SessionStartHour={p['session_start']}",
        f"SessionEndHour={p['session_end']}",
        f"MaxSpreadPips={p['max_spread_pips']}",
        f"LotSize={p['lot_size']}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")

SETS_DIR = LAB / "mt5_sets"
OUT_DIR = LAB / "best_run" / "mt5_reports"
RESULTS_JSON = LAB / "best_run" / "mt5_results.json"


def load_members(params_path: Path, only: set[str] | None, enabled_only: bool = False) -> tuple[list[dict], dict]:
    data = json.loads(params_path.read_text(encoding="utf-8"))
    members = [m for m in data.get("members", []) if "params" in m]
    if enabled_only:
        members = [m for m in members if m.get("enabled")]
    if only:
        only_up = {s.upper() for s in only}
        members = [m for m in members if m["symbol"].upper() in only_up or m.get("requested", "").upper() in only_up]
    return members, data.get("config", {})


def tester_symbol(sym: str) -> str:
    """Use broker symbol as stored in portfolio_params."""
    return sym.split(".")[0] if "." not in sym else sym


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", type=Path, default=LAB / "portfolio_params.json")
    ap.add_argument("--only", default="", help="comma-separated symbols, e.g. EURUSD,XAUUSD")
    ap.add_argument("--enabled-only", action="store_true", help="test only MT5-enabled symbols")
    ap.add_argument("--from", dest="from_date", default="2020.01.01")
    ap.add_argument("--to", dest="to_date", default="2026.01.01")
    ap.add_argument("--period", default="M15", choices=["M15", "M30", "H1", "H4"])
    ap.add_argument("--deposit", type=float, default=10000)
    ap.add_argument("--leverage", type=int, default=100)
    args = ap.parse_args()

    only = {s.strip() for s in args.only.split(",") if s.strip()} or None
    members, cfg = load_members(args.params, only, enabled_only=args.enabled_only)
    if not members:
        raise SystemExit("No enabled members in portfolio_params.json")

    SETS_DIR.mkdir(exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (LAB / "best_run").mkdir(exist_ok=True)

    ctx = mt5_context()
    rows: list[dict] = []
    t0 = time.time()

    print(f"MT5 portfolio backtest: {len(members)} symbols  {args.from_date} -> {args.to_date}  {args.period}")
    print("(Each symbol = separate MT5 Strategy Tester run with its own .set)\n")

    for i, m in enumerate(members, 1):
        sym = m["symbol"]
        test_sym = tester_symbol(sym)
        set_name = f"SimpleEMA_{test_sym}.set"
        set_path = SETS_DIR / set_name
        write_member_set(m["params"], set_path)

        report = f"SimpleEMA_pf_{test_sym}"
        print(f"[{i}/{len(members)}] {test_sym} ...")
        try:
            metrics = run_tester(
                ctx,
                mode="backtest",
                set_path=set_path,
                set_name=set_name,
                report=report,
                symbol=test_sym,
                period=args.period,
                from_date=args.from_date,
                to_date=args.to_date,
                deposit=args.deposit,
                leverage=args.leverage,
                visual=False,
                timeout_sec=7200,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL {test_sym}: {exc}")
            rows.append({"symbol": sym, "ready": False, "error": str(exc)})
            continue

        if metrics.get("ready") and metrics.get("report"):
            src = Path(metrics["report"])
            dst = OUT_DIR / src.name
            shutil.copy2(src, dst)
            metrics["report_local"] = str(dst)

        row = {
            "symbol": sym,
            "test_symbol": test_sym,
            "ready": metrics.get("ready", False),
            "net_profit": metrics.get("net_profit"),
            "total_trades": metrics.get("total_trades"),
            "profit_factor": metrics.get("profit_factor"),
            "sharpe": metrics.get("sharpe"),
            "max_drawdown": metrics.get("max_drawdown"),
            "elapsed_sec": metrics.get("elapsed_sec"),
            "report": metrics.get("report_local") or metrics.get("report"),
            "set_file": str(set_path),
        }
        rows.append(row)
        if row["ready"]:
            print(
                f"  OK net={row['net_profit']} trades={row['total_trades']} "
                f"PF={row['profit_factor']}  ({row['elapsed_sec']}s)"
            )
        else:
            print(f"  NO REPORT for {test_sym}")

    ok = [r for r in rows if r.get("ready")]
    total_trades = sum(r.get("total_trades") or 0 for r in ok)
    total_net = sum(r.get("net_profit") or 0 for r in ok)
    gp = sum(r.get("net_profit") or 0 for r in ok if (r.get("net_profit") or 0) > 0)
    gl = abs(sum(r.get("net_profit") or 0 for r in ok if (r.get("net_profit") or 0) < 0))

    payload = {
        "source": "mt5_strategy_tester",
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "period": {"from": args.from_date, "to": args.to_date, "timeframe": args.period},
        "deposit_per_symbol": args.deposit,
        "note": "Sum of independent MT5 single-symbol runs. NOT Python simulation.",
        "portfolio": {
            "symbols_tested": len(ok),
            "symbols_failed": len(rows) - len(ok),
            "total_trades": total_trades,
            "net_profit_sum": round(total_net, 2),
            "profit_factor_approx": round(gp / gl, 2) if gl > 0 else None,
        },
        "per_symbol": rows,
    }
    RESULTS_JSON.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"\n=== MT5 Portfolio (aggregated) ===")
    print(f"  symbols OK: {len(ok)}/{len(rows)}")
    print(f"  total_trades: {total_trades}")
    print(f"  net_profit (sum): ${total_net:,.2f}")
    print(f"  saved: {RESULTS_JSON}")
    print(f"  HTML reports: {OUT_DIR}")
    print(f"  elapsed: {time.time() - t0:.0f}s")
    print("\nNext: python generate_mt5_portfolio_report.py")


if __name__ == "__main__":
    main()
