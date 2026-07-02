#!/usr/bin/env python3
"""
Per-symbol MT5 preset sweep (Strategy Tester = source of truth).

Tests curated high-frequency v5 presets per symbol, picks best by
profit + trade-count score, writes portfolio_params.json + mt5_sets/.

Usage:
  python run_mt5_preset_sweep.py
  python run_mt5_preset_sweep.py --only EURUSD,XAGUSD,XAUUSD
  python run_mt5_preset_sweep.py --config portfolio_symbols_expanded.json
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict, replace
from datetime import datetime
from pathlib import Path

LAB = Path(__file__).resolve().parent
sys.path.insert(0, str(LAB))

from run_mt5_portfolio import write_member_set  # noqa: E402
from run_mt5_tester import mt5_context, run_tester  # noqa: E402
from run_portfolio_v5 import load_portfolio_config  # noqa: E402
from strategy_v5 import V5Params  # noqa: E402

OUT_PATH = LAB / "portfolio_params.json"
SETS_DIR = LAB / "mt5_sets"
SWEEP_LOG = LAB / "best_run" / "mt5_preset_sweep.json"


def is_metal(name: str) -> bool:
    b = name.upper().split(".")[0]
    return b.startswith("XAU") or b.startswith("XAG") or b.startswith("XPT") or b.startswith("XPD")


def is_oil(name: str) -> bool:
    b = name.upper()
    return "XTI" in b or "XBR" in b or "OIL" in b


def is_index(name: str) -> bool:
    b = name.upper().split(".")[0]
    return b in {"US500", "NAS100", "US30", "GER40", "UK100", "JPN225", "SPX500", "USTEC"}


def is_crypto(name: str) -> bool:
    b = name.upper().split(".")[0]
    return b.startswith("BTC") or b.startswith("ETH")


def presets_for_symbol(name: str, lot: float, spread_cap: float) -> list[V5Params]:
    base = [
        V5Params(fast_ema=8, slow_ema=30, cross_cooldown=2, htf_ema_period=100, use_pullback=False),
        V5Params(fast_ema=9, slow_ema=34, cross_cooldown=2, htf_ema_period=100, use_pullback=False),
        V5Params(fast_ema=10, slow_ema=36, cross_cooldown=2, use_htf_filter=False, use_pullback=False),
        V5Params(fast_ema=7, slow_ema=28, cross_cooldown=2, htf_ema_period=100, use_pullback=False),
        V5Params(
            fast_ema=8, slow_ema=30, cross_cooldown=2, use_pullback=True,
            pullback_cooldown=2, trend_leg_bars=48,
        ),
        V5Params(
            fast_ema=10, slow_ema=36, cross_cooldown=3, use_pullback=True,
            max_pullbacks_per_leg=2,
        ),
        V5Params(
            fast_ema=11, slow_ema=40, cross_cooldown=4, use_pullback=True,
            pullback_adx_min=18,
        ),
        V5Params(fast_ema=10, slow_ema=46, cross_cooldown=4, htf_ema_period=200, use_pullback=False),
        V5Params(
            fast_ema=8, slow_ema=30, cross_cooldown=2, session_start=0, session_end=24,
            use_htf_filter=False, use_pullback=False,
        ),
        V5Params(
            fast_ema=9, slow_ema=34, cross_cooldown=3, use_pullback=True,
            pullback_touch=1, pullback_adx_min=20,
        ),
        V5Params(
            fast_ema=10, slow_ema=40, cross_cooldown=3, use_adx_filter=True,
            adx_min=15, use_pullback=False,
        ),
        V5Params(
            fast_ema=8, slow_ema=36, cross_cooldown=2, use_pullback=True,
            max_pullbacks_per_leg=2, trend_leg_bars=64,
        ),
        V5Params(fast_ema=8, slow_ema=26, cross_cooldown=2, use_htf_filter=False, use_pullback=False),
        V5Params(fast_ema=9, slow_ema=30, cross_cooldown=2, use_pullback=True, max_pullbacks_per_leg=2),
        # ultra high-frequency (more trades)
        V5Params(fast_ema=7, slow_ema=24, cross_cooldown=2, use_htf_filter=False, use_pullback=False),
        V5Params(fast_ema=8, slow_ema=26, cross_cooldown=2, session_start=0, session_end=24, use_htf_filter=False, use_pullback=False),
        V5Params(fast_ema=7, slow_ema=22, cross_cooldown=2, use_pullback=True, max_pullbacks_per_leg=2, trend_leg_bars=72),
        V5Params(fast_ema=9, slow_ema=28, cross_cooldown=2, use_htf_filter=False, use_pullback=True, pullback_cooldown=2),
    ]
    out: list[V5Params] = []
    for p0 in base:
        p = replace(p0, lot_size=lot, max_spread_pips=spread_cap)
        if is_metal(name):
            p = replace(p, atr_sl_mult=2.5, atr_tp_mult=5.0, min_ema_gap_pips=1.0)
        elif is_oil(name):
            p = replace(p, atr_sl_mult=2.2, atr_tp_mult=4.5, max_spread_pips=max(spread_cap, 25.0))
        elif is_index(name) or is_crypto(name):
            p = replace(p, atr_sl_mult=2.0, atr_tp_mult=4.0, min_ema_gap_pips=2.0)
        elif "JPY" in name.upper() or "CNH" in name.upper():
            p = replace(p, max_spread_pips=max(spread_cap, 12.0))
        out.append(p)
    return out


def score_mt5(net: float | None, trades: int | None, pf: float | None) -> float:
    net = net or 0.0
    trades = trades or 0
    pf = pf or 0.0
    if net > 0 and pf >= 1.0:
        return net + trades * 10.0
    if net > 0 and pf >= 0.95:
        return net + trades * 4.0
    return net + trades * 0.15


def sweep_symbol(
    ctx: dict,
    sym: str,
    spread_cap: float,
    lot: float,
    from_date: str,
    to_date: str,
    period: str,
    deposit: float,
    leverage: int,
) -> dict:
    test_sym = sym.split(".")[0]
    presets = presets_for_symbol(sym, lot, spread_cap)
    trials: list[dict] = []
    best: dict | None = None
    best_score = -1e18

    for i, p in enumerate(presets, 1):
        set_name = f"SimpleEMA_sweep_{test_sym}_{i}.set"
        set_path = SETS_DIR / set_name
        write_member_set(asdict(p), set_path)
        report = f"SimpleEMA_sweep_{test_sym}_{i}"
        try:
            m = run_tester(
                ctx,
                mode="backtest",
                set_path=set_path,
                set_name=set_name,
                report=report,
                symbol=test_sym,
                period=period,
                from_date=from_date,
                to_date=to_date,
                deposit=deposit,
                leverage=leverage,
                visual=False,
                timeout_sec=7200,
            )
        except Exception as exc:  # noqa: BLE001
            trials.append({"preset": i, "error": str(exc)})
            continue

        if not m.get("ready"):
            trials.append({"preset": i, "ready": False})
            continue

        sc = score_mt5(m.get("net_profit"), m.get("total_trades"), m.get("profit_factor"))
        row = {
            "preset": i,
            "net_profit": m.get("net_profit"),
            "total_trades": m.get("total_trades"),
            "profit_factor": m.get("profit_factor"),
            "score": round(sc, 2),
            "params": asdict(p),
        }
        trials.append(row)
        if sc > best_score:
            best_score = sc
            best = row

    if not best:
        raise RuntimeError(f"no MT5 results for {sym}")

    pf = best.get("profit_factor") or 0
    net = best.get("net_profit") or 0
    trades = best.get("total_trades") or 0
    enabled = net > 0 and pf >= 1.0 and trades >= 8
    flag = "OK" if enabled else "--"
    print(
        f"  [{flag}] {test_sym}: preset #{best['preset']} "
        f"net=${net:,.0f} t={trades} PF={pf:.2f} score={best_score:,.0f}"
    )
    return {
        "requested": sym,
        "symbol": sym,
        "enabled": enabled,
        "max_spread_pips": spread_cap,
        "params": best["params"],
        "mt5_metrics": {
            "net_profit": net,
            "total_trades": trades,
            "profit_factor": pf,
            "preset_id": best["preset"],
            "score": best_score,
        },
        "sweep_trials": trials,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", type=Path, default=LAB / "portfolio_symbols_expanded.json")
    ap.add_argument("--only", default="", help="comma-separated symbols")
    ap.add_argument("--from", dest="from_date", default="2020.01.01")
    ap.add_argument("--to", dest="to_date", default="2026.01.01")
    ap.add_argument("--period", default="M15", choices=["M15", "M30", "H1"])
    ap.add_argument("--deposit", type=float, default=10000)
    ap.add_argument("--leverage", type=int, default=100)
    args = ap.parse_args()

    cfg = load_portfolio_config(args.config)
    only = {s.strip().upper() for s in args.only.split(",") if s.strip()} or None
    lot = cfg.get("lot_per_symbol", 0.05)

    SETS_DIR.mkdir(exist_ok=True)
    (LAB / "best_run").mkdir(exist_ok=True)

    entries = cfg["symbols"]
    if only:
        entries = [e for e in entries if e["name"].upper() in only]

    ctx = mt5_context()
    members: list[dict] = []
    existing_by_sym: dict[str, dict] = {}
    if args.only and OUT_PATH.exists():
        prev = json.loads(OUT_PATH.read_text(encoding="utf-8"))
        existing_by_sym = {m["symbol"]: m for m in prev.get("members", []) if "symbol" in m}

    t0 = time.time()
    print(f"MT5 preset sweep: {len(entries)} symbols x ~14 presets  {args.from_date} -> {args.to_date}\n")

    for i, entry in enumerate(entries, 1):
        sym = entry["name"]
        print(f"[{i}/{len(entries)}] {sym}")
        try:
            members.append(
                sweep_symbol(
                    ctx,
                    sym,
                    entry.get("max_spread_pips", 8.0),
                    lot,
                    args.from_date,
                    args.to_date,
                    args.period,
                    args.deposit,
                    args.leverage,
                )
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL {sym}: {exc}")
            members.append({"requested": sym, "symbol": sym, "enabled": False, "error": str(exc)})

    if args.only and existing_by_sym:
        for m in members:
            existing_by_sym[m["symbol"]] = m
        members = list(existing_by_sym.values())
        members.sort(key=lambda x: x.get("symbol", ""))

    enabled = [m for m in members if m.get("enabled")]
    en_trades = sum(m["mt5_metrics"]["total_trades"] for m in enabled)
    en_net = sum(m["mt5_metrics"]["net_profit"] for m in enabled)

    payload = {
        "version": 5,
        "mode": "mt5_preset_sweep",
        "optimized_at": datetime.now().isoformat(timespec="seconds"),
        "config": cfg,
        "selection_source": "mt5_strategy_tester",
        "members": members,
        "mt5_enabled_count": len(enabled),
        "mt5_enabled_trades": en_trades,
        "mt5_enabled_net": round(en_net, 2),
    }
    OUT_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    SWEEP_LOG.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"\n=== MT5 Preset Sweep Done ({time.time() - t0:.0f}s) ===")
    print(f"  enabled: {len(enabled)}/{len(members)}")
    print(f"  MT5 trades (enabled): {en_trades}")
    print(f"  MT5 net (enabled): ${en_net:,.2f}")
    print(f"  2000+ target: {'YES' if en_trades >= 2000 else 'NO'}")
    print(f"  saved: {OUT_PATH}")
    print("\nNext:")
    print("  python sync_portfolio_from_mt5.py --min-pf 1.0 --min-trades 8")
    print("  python run_mt5_portfolio.py --enabled-only --from 2020.01.01 --to 2026.01.01")
    print("  python generate_mt5_portfolio_report.py")


if __name__ == "__main__":
    main()
