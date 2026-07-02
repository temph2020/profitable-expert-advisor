"""
Analyze losing trades in market context — bars before/after, gaps between losses,
RSI/ATR/trend features. Trader-style narrative + param suggestions.

Usage:
  python -m cluster_audit.loss_context_analysis united_rsi_scalp_appl
  python -m cluster_audit.loss_context_analysis united_darvas
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.backtest_core import CostModel, Trade, load_bars, resolve_symbol
from cluster_audit.engines import ENGINE_MAP
from cluster_audit.united_registry import PERIODS, UNITED_STRATEGIES
from indicator_utils import calculate_atr, calculate_ema, calculate_rsi

OUT_DIR = Path(__file__).parent / "reports" / "loss_analysis"
CONTEXT_BARS = 12  # bars before entry + through hold


def find_spec(sid: str) -> dict:
    for s in UNITED_STRATEGIES:
        if s["id"] == sid:
            return s
    raise KeyError(sid)


def run_backtest(spec: dict, start: str, end: str) -> tuple[pd.DataFrame, list[Trade], dict]:
    from cluster_audit.strategy_registry import TF

    sym = resolve_symbol(spec["symbol"])
    tf_key = spec["tf"]
    engine = ENGINE_MAP[spec["engine"]]
    params = dict(spec["defaults"])
    df = load_bars(sym, TF[tf_key], datetime.fromisoformat(start), datetime.fromisoformat(end))
    report = engine(df, sym, "2021-2026", spec["id"], params, spec["lot"], CostModel.for_symbol(sym))
    return df, report.trades_list, params


def bar_features(df: pd.DataFrame, idx: int, rsi: np.ndarray, atr: np.ndarray, ema20: np.ndarray) -> dict:
    if idx < 1 or idx >= len(df):
        return {}
    o, h, l, c = df.iloc[idx][["open", "high", "low", "close"]]
    prev_c = float(df.iloc[idx - 1]["close"])
    body = abs(c - o)
    rng = h - l if h > l else 1e-9
    return {
        "rsi": float(rsi[idx - 1]) if not np.isnan(rsi[idx - 1]) else np.nan,
        "atr": float(atr[idx - 1]) if not np.isnan(atr[idx - 1]) else np.nan,
        "ema20": float(ema20[idx - 1]) if not np.isnan(ema20[idx - 1]) else np.nan,
        "close": float(c),
        "body_pct": float(body / rng),
        "bullish": float(c) > float(o),
        "ret_1": float((c - prev_c) / prev_c * 100) if prev_c else 0,
        "dist_ema_pct": float((c - ema20[idx - 1]) / ema20[idx - 1] * 100) if ema20[idx - 1] else 0,
    }


def trade_context(df: pd.DataFrame, t: Trade, rsi, atr, ema20) -> dict:
    open_i = df.index.get_indexer([pd.Timestamp(t.open_time)], method="nearest")[0]
    close_i = df.index.get_indexer([pd.Timestamp(t.close_time)], method="nearest")[0]
    pre_start = max(1, open_i - CONTEXT_BARS)
    pre_bars = []
    for i in range(pre_start, open_i):
        pre_bars.append(bar_features(df, i, rsi, atr, ema20))

    hold_bars = []
    for i in range(open_i, min(close_i + 1, len(df))):
        hold_bars.append(bar_features(df, i, rsi, atr, ema20))

    entry_f = bar_features(df, open_i, rsi, atr, ema20)
    exit_f = bar_features(df, close_i, rsi, atr, ema20)

    pre_rsi = [b["rsi"] for b in pre_bars if not np.isnan(b.get("rsi", np.nan))]
    hold_rsi = [b["rsi"] for b in hold_bars if not np.isnan(b.get("rsi", np.nan))]

    adverse_move = 0.0
    if t.side == "BUY" and hold_bars:
        adverse_move = float(t.open_price) - min(b["close"] for b in hold_bars)
    elif t.side == "SELL" and hold_bars:
        adverse_move = max(b["close"] for b in hold_bars) - float(t.open_price)

    return {
        "side": t.side,
        "exit_reason": t.exit_reason,
        "profit": t.profit,
        "bars_held": t.bars_held,
        "open_time": str(t.open_time),
        "close_time": str(t.close_time),
        "entry_rsi": entry_f.get("rsi"),
        "exit_rsi": exit_f.get("rsi"),
        "rsi_min_hold": min(hold_rsi) if hold_rsi else None,
        "rsi_max_hold": max(hold_rsi) if hold_rsi else None,
        "rsi_trend_pre": (pre_rsi[-1] - pre_rsi[0]) if len(pre_rsi) >= 2 else 0,
        "adverse_pts": adverse_move,
        "adverse_atr": adverse_move / entry_f["atr"] if entry_f.get("atr") else 0,
        "entry_hour": pd.Timestamp(t.open_time).hour,
        "entry_dist_ema_pct": entry_f.get("dist_ema_pct", 0),
        "pre_bullish_ratio": sum(1 for b in pre_bars if b.get("bullish")) / max(len(pre_bars), 1),
        "entry_body_pct": entry_f.get("body_pct", 0),
    }


def gap_analysis(losers: list[dict]) -> dict:
    if len(losers) < 2:
        return {}
    times = sorted(pd.Timestamp(t["close_time"]) for t in losers)
    gaps_h = [(times[i] - times[i - 1]).total_seconds() / 3600 for i in range(1, len(times))]
    return {
        "median_gap_hours": float(np.median(gaps_h)),
        "pct_gap_under_4h": float(sum(1 for g in gaps_h if g < 4) / len(gaps_h) * 100),
        "pct_gap_under_24h": float(sum(1 for g in gaps_h if g < 24) / len(gaps_h) * 100),
        "clustered": float(sum(1 for g in gaps_h if g < 2) / len(gaps_h) * 100),
    }


def trader_narrative(sid: str, engine: str, losers_ctx: list[dict], winners_ctx: list[dict], by_reason: dict) -> list[str]:
    notes: list[str] = []
    if not losers_ctx:
        return ["No losing trades to analyze."]

    top_reason = max(by_reason.items(), key=lambda x: x[1]["count"])[0]
    lr = [c for c in losers_ctx if c["exit_reason"] == top_reason]
    wr = winners_ctx

    if top_reason == "rsi_against":
        sell_l = [c for c in lr if c["side"] == "SELL"]
        buy_l = [c for c in lr if c["side"] == "BUY"]
        if sell_l:
            avg_adv = np.mean([c["adverse_atr"] for c in sell_l if c["adverse_atr"]])
            notes.append(
                f"SELL rsi_against ({len(sell_l)}): price ripped up avg {avg_adv:.1f} ATR after shorting "
                f"overbought fade — classic short squeeze / momentum continuation, not mean reversion."
            )
            late_h = sum(1 for c in sell_l if c["entry_hour"] >= 18) / len(sell_l) * 100
            if late_h > 30:
                notes.append(f"{late_h:.0f}% of losing shorts after 18:00 — avoid fading strength into close.")
        if buy_l:
            notes.append(
                f"BUY rsi_against ({len(buy_l)}): dipped deeper after oversold entry — "
                f"knife-catching; need deeper OS threshold or wait for RSI curl-up."
            )
        if wr:
            w_sell = [c for c in wr if c["side"] == "SELL"]
            if w_sell and sell_l:
                w_rsi = np.mean([c["entry_rsi"] for c in w_sell])
                l_rsi = np.mean([c["entry_rsi"] for c in sell_l])
                notes.append(f"Winning shorts entered RSI~{w_rsi:.0f} vs losers~{l_rsi:.0f} — losers entered too early in OB zone.")

    elif top_reason == "sl":
        notes.append("SL hits: stops inside noise — widen SL to 1.5-2x ATR or reduce lot.")
        avg_atr = np.mean([c["adverse_atr"] for c in lr if c.get("adverse_atr")])
        notes.append(f"Avg adverse move before SL = {avg_atr:.1f} ATR — box breakout often retests.")

    elif top_reason == "adverse_atr":
        notes.append("ATR stop hits: entries fighting trend — fade only when RSI extreme + session filter; widen stop or skip gap-down buys.")
        buy_l = [c for c in lr if c["side"] == "BUY"]
        if buy_l:
            late = sum(1 for c in buy_l if c["entry_hour"] >= 20) / len(buy_l) * 100
            if late > 25:
                notes.append(f"{late:.0f}% of stopped-out buys after 20:00 — overnight gap risk on equities.")
        sell_l = [c for c in lr if c["side"] == "SELL"]
        if sell_l:
            avg_adv = np.mean([c["adverse_atr"] for c in sell_l if c.get("adverse_atr")])
            notes.append(f"Short stops avg {avg_adv:.1f} ATR adverse — momentum continuation, not reversion.")

    elif top_reason == "trail":
        notes.append("Trail exits: winners cut early in chop — widen trail_distance or raise activation.")

    elif top_reason == "trend_strong":
        notes.append("trend_strong: exited into momentum — filter only blocks entries, don't force-close in profit.")

    gaps = gap_analysis(losers_ctx)
    if gaps.get("clustered", 0) > 25:
        notes.append(
            f"{gaps['clustered']:.0f}% of losses within 2h of prior loss — regime chop; "
            f"add cooldown after loss or skip when ATR expanding."
        )

    return notes


def suggest_params(engine: str, losers_ctx: list[dict], params: dict) -> dict:
    sug = {}
    if engine == "rsi_scalp":
        sell_l = [c for c in losers_ctx if c["side"] == "SELL" and c["exit_reason"] == "rsi_against"]
        if sell_l and np.mean([c["adverse_atr"] for c in sell_l]) > 1.5:
            sug["rsi_overbought"] = min(75, params.get("rsi_overbought", 70) + 5)
            sug["bars_to_wait"] = min(12, params.get("bars_to_wait", 5) + 3)
            sug["trail_distance_pts"] = params.get("trail_distance_pts", 50) * 1.4
            sug["skip_short_hour_after"] = 17
        buy_l = [c for c in losers_ctx if c["side"] == "BUY" and c["exit_reason"] == "rsi_against"]
        if buy_l:
            sug["rsi_oversold"] = max(20, params.get("rsi_oversold", 30) - 5)
    elif engine == "darvas":
        sug["stop_loss_pts"] = int(params.get("stop_loss_pts", 300) * 1.35)
        sug["require_retest"] = True
    return sug


def analyze(sid: str) -> dict:
    spec = find_spec(sid)
    start, end = PERIODS["2021-2026"]
    df, trades, params = run_backtest(spec, start, end)

    rsi = calculate_rsi(df["close"], int(params.get("rsi_period", 14))).to_numpy()
    atr = calculate_atr(df, 14).to_numpy()
    ema20 = calculate_ema(df["close"], 20).to_numpy()

    winners = [t for t in trades if t.profit >= 0]
    losers = [t for t in trades if t.profit < 0]

    losers_ctx = [trade_context(df, t, rsi, atr, ema20) for t in losers]
    winners_ctx = [trade_context(df, t, rsi, atr, ema20) for t in winners[:200]]

    by_reason: dict = {}
    for c in losers_ctx:
        r = c["exit_reason"]
        bucket = by_reason.setdefault(r, {"count": 0, "pnl": 0.0, "ctx": []})
        bucket["count"] += 1
        bucket["pnl"] += c["profit"]
        bucket["ctx"].append(c)

    narrative = trader_narrative(sid, spec["engine"], losers_ctx, winners_ctx, by_reason)
    suggestions = suggest_params(spec["engine"], losers_ctx, params)

    result = {
        "strategy_id": sid,
        "symbol": spec["symbol"],
        "engine": spec["engine"],
        "total_trades": len(trades),
        "losers": len(losers),
        "winners": len(winners),
        "loss_by_reason": {k: {"count": v["count"], "pnl": round(v["pnl"], 2)} for k, v in by_reason.items()},
        "gap_stats": gap_analysis(losers_ctx),
        "trader_notes": narrative,
        "suggested_param_tweaks": suggestions,
        "sample_losers": sorted(losers_ctx, key=lambda x: x["profit"])[:8],
    }
    return result


def main() -> None:
    sid = sys.argv[1] if len(sys.argv) > 1 else "united_rsi_scalp_appl"
    if not mt5.initialize():
        raise SystemExit(f"MT5 init failed: {mt5.last_error()}")
    try:
        result = analyze(sid)
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        path = OUT_DIR / f"{sid}_loss_context.json"
        path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(f"Wrote {path}\n")
        print(f"=== {sid} loss context ({result['losers']} losers / {result['total_trades']} trades) ===\n")
        for reason, stats in sorted(result["loss_by_reason"].items(), key=lambda x: x[1]["pnl"]):
            print(f"  {reason:14} count={stats['count']:4}  pnl=${stats['pnl']:,.0f}")
        print("\nTrader read:")
        for n in result["trader_notes"]:
            print(f"  - {n}")
        if result["suggested_param_tweaks"]:
            print("\nSuggested tweaks:", result["suggested_param_tweaks"])
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
