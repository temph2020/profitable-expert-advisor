"""
Sync United EA audit results into main.mq5 defaults and generate .set file.

Usage:
  python -m cluster_audit.sync_united
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

from cluster_audit.scoring import DEFAULT_TRADES_PER_DAY, acceptance, period_days, trades_per_day
from cluster_audit.united_registry import PERIODS, UNITED_STRATEGIES

REPORTS = Path(__file__).parent / "reports" / "united_sequential"
MAIN_MQ5 = Path(__file__).resolve().parents[3] / "frontline" / "cluster-latest" / "main.mq5"
OUT_SET = Path(__file__).resolve().parents[3] / "frontline" / "cluster-latest" / "UnitedEA_Optimized.set"
OUT_JSON = REPORTS / "united_manifest.json"

# main.mq5 input name -> (strategy_id, param_key in optimized JSON)
PARAM_PATCHES: dict[str, tuple[str, str]] = {
    "DB_BoxPeriod": ("united_darvas", "box_period"),
    "DB_BoxDeviation": ("united_darvas", "box_deviation"),
    "DB_StopLoss": ("united_darvas", "stop_loss_pts"),
    "DB_TakeProfit": ("united_darvas", "take_profit_pts"),
    "DB_MA_Period": ("united_darvas", "ma_period"),
    "DB_TrendThreshold": ("united_darvas", "trend_threshold"),
    "RC_overboughtLevel": ("united_rsi_cross", "overbought_level"),
    "RC_oversoldLevel": ("united_rsi_cross", "oversold_level"),
    "RC_emaSlopeThreshold": ("united_rsi_cross", "ema_slope_threshold"),
    "RC_emaDistanceThreshold": ("united_rsi_cross", "ema_distance_threshold"),
    "RS_APPL_RSI_Period": ("united_rsi_scalp_appl", "rsi_period"),
    "RS_APPL_RSI_Overbought": ("united_rsi_scalp_appl", "rsi_overbought"),
    "RS_APPL_RSI_Oversold": ("united_rsi_scalp_appl", "rsi_oversold"),
    "RS_APPL_RSI_Target_Buy": ("united_rsi_scalp_appl", "rsi_target_buy"),
    "RS_APPL_RSI_Target_Sell": ("united_rsi_scalp_appl", "rsi_target_sell"),
    "RS_APPL_BarsToWait": ("united_rsi_scalp_appl", "bars_to_wait"),
    "RS_APPL_TrailDistancePoints": ("united_rsi_scalp_appl", "trail_distance_pts"),
    "RS_APPL_TrailActivationPoints": ("united_rsi_scalp_appl", "trail_activation_pts"),
    "RS_BTCUSD_RSI_Period": ("united_rsi_scalp_btc", "rsi_period"),
    "RS_BTCUSD_TrailDistancePoints": ("united_rsi_scalp_btc", "trail_distance_pts"),
    "RS_XAUUSD_RSI_Period": ("united_rsi_scalp_xau", "rsi_period"),
    "RS_XAUUSD_TrailDistancePoints": ("united_rsi_scalp_xau", "trail_distance_pts"),
    "RRA_EURUSD_OverboughtLevel": ("united_rsi_asian_eur", "overbought_level"),
    "RRA_EURUSD_OversoldLevel": ("united_rsi_asian_eur", "oversold_level"),
    "RSS_RSIOverbought": ("united_rsi_secret", "rsi_overbought"),
    "RSS_RSIOversold": ("united_rsi_secret", "rsi_oversold"),
    "UB_MinRangePoints": ("united_usdjpy", "min_range_pts"),
    "UB_OrderBufferPoints": ("united_usdjpy", "order_buffer_pts"),
}

ENABLE_PATCHES: dict[str, str] = {s["enable_key"]: s["id"] for s in UNITED_STRATEGIES}


def load_report(sid: str) -> dict | None:
    p = REPORTS / f"{sid}_2021-2026.json"
    if not p.exists():
        # fallback cluster audit darvas
        alt = Path(__file__).parent / "reports" / "sequential" / "darvas_xau_2021-2026.json"
        if sid == "united_darvas" and alt.exists():
            r = json.loads(alt.read_text(encoding="utf-8"))
            r["id"] = sid
            return r
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def evaluate(r: dict, days: int) -> tuple[bool, list[str]]:
    from cluster_audit.backtest_core import BacktestReport

    o = r.get("optimized", {})
    rep = BacktestReport(
        strategy_id=r["id"],
        symbol=r.get("symbol", ""),
        timeframe=r.get("timeframe", "H1"),
        period_label="2021-2026",
        net_profit=float(o.get("net_profit", 0)),
        total_trades=int(o.get("total_trades", 0)),
        win_rate=float(o.get("win_rate", 0)),
        profit_factor=float(o.get("profit_factor", 0)),
        sharpe=float(o.get("sharpe", 0)),
        max_drawdown_pct=float(o.get("max_drawdown_pct", 0)),
        avg_win=float(o.get("avg_win", 0)),
        avg_loss=float(o.get("avg_loss", 0)),
        worst_trades=o.get("worst_trades", []),
        losing_trades=o.get("losing_trades", []),
        exit_reason_breakdown=o.get("exit_reason_breakdown", {}),
        monthly_returns=o.get("monthly_returns", {}),
        params=o.get("params", {}),
    )
    return acceptance(rep, days, DEFAULT_TRADES_PER_DAY)


def patch_main_mqh(text: str, manifest: dict) -> str:
    params_by_sid = {k: v.get("params", {}) for k, v in manifest["strategies"].items()}

    for input_name, (sid, pkey) in PARAM_PATCHES.items():
        params = params_by_sid.get(sid, {})
        if pkey not in params:
            continue
        val = params[pkey]
        if isinstance(val, bool):
            lit = "true" if val else "false"
        elif isinstance(val, float):
            lit = str(val) if "." in str(val) else f"{val}.0"
        else:
            lit = str(val)
        text, n = re.subn(
            rf"(^input\s+\w+\s+{re.escape(input_name)}\s*=\s*)[^;]+;",
            rf"\g<1>{lit};",
            text,
            count=1,
            flags=re.MULTILINE,
        )
        if n:
            print(f"  patched {input_name}={lit}")

    for enable_key, sid in ENABLE_PATCHES.items():
        info = manifest["strategies"].get(sid, {})
        if info.get("status") == "no_report" or "passed" not in info:
            continue
        if not info.get("passed"):
            continue  # keep main.mq5 enable flags; only auto-enable winners
        lit = "true"
        text, n = re.subn(
            rf"(^input bool {re.escape(enable_key)}\s*=\s*)[^;]+;",
            rf"\g<1>{lit};",
            text,
            count=1,
            flags=re.MULTILINE,
        )
        if n:
            print(f"  enable {enable_key}={lit}")

    return text


def write_set_file(manifest: dict) -> None:
    lines = [
        "; UnitedEA_Optimized.set — generated from united sequential audit",
        f"; {datetime.now().isoformat()}",
        "",
    ]
    for spec in UNITED_STRATEGIES:
        sid = spec["id"]
        info = manifest["strategies"].get(sid, {})
        passed = info.get("passed", False)
        lines.append(f"; {sid}: {'PASS' if passed else 'DISABLED'}")
        lines.append(f"{spec['enable_key']}={'true' if passed else 'false'}")
        lines.append(f"{spec['lot_key']}={spec['lot']}")
        for k, v in info.get("params", {}).items():
            lines.append(f"; {k}={v}")
        lines.append("")
    OUT_SET.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    start, end = PERIODS["2021-2026"]
    days = period_days(start, end)
    manifest: dict = {
        "generated": datetime.now().isoformat(),
        "period_days": days,
        "strategies": {},
    }

    for spec in UNITED_STRATEGIES:
        sid = spec["id"]
        r = load_report(sid)
        if not r:
            manifest["strategies"][sid] = {"passed": False, "status": "no_report"}
            continue
        params = r.get("optimized_params") or r.get("optimized", {}).get("params", {})
        ok, issues = evaluate(r, days)
        o = r.get("optimized", {})
        manifest["strategies"][sid] = {
            "passed": ok,
            "enable_key": spec["enable_key"],
            "lot_key": spec["lot_key"],
            "lot": spec["lot"],
            "trades": o.get("total_trades"),
            "trades_per_day": round(trades_per_day(
                type("R", (), {"total_trades": int(o.get("total_trades", 0))})(), days), 3),
            "net_profit": o.get("net_profit"),
            "profit_factor": o.get("profit_factor"),
            "sharpe": o.get("sharpe"),
            "issues": issues,
            "params": params,
        }

    if MAIN_MQ5.exists():
        text = MAIN_MQ5.read_text(encoding="utf-8")
        print(f"Patching {MAIN_MQ5}")
        text = patch_main_mqh(text, manifest)
        MAIN_MQ5.write_text(text, encoding="utf-8")

    REPORTS.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    write_set_file(manifest)
    passed = [k for k, v in manifest["strategies"].items() if v.get("passed")]
    print(f"Wrote {OUT_JSON}")
    print(f"Wrote {OUT_SET}")
    print(f"Passed {len(passed)}/{len(UNITED_STRATEGIES)}: {', '.join(passed) if passed else '(none)'}")


if __name__ == "__main__":
    main()
