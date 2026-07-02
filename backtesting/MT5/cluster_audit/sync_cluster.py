"""
Build cluster-latest SuperEA audit params from sequential JSON reports.

Usage:
  python -m cluster_audit.sync_cluster
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

from cluster_audit.scoring import DEFAULT_TRADES_PER_DAY, acceptance, period_days, trades_per_day
from cluster_audit.strategy_registry import PERIODS, STRATEGIES

REPORTS = Path(__file__).parent / "reports" / "sequential"
OUT_MQH = Path(__file__).resolve().parents[3] / "frontline" / "cluster-latest" / "SuperEA_AuditParams.mqh"
OUT_JSON = Path(__file__).parent / "reports" / "cluster_manifest.json"

RSI_SCALP_IDS = [
    "rsi_scalp_appl_unit", "rsi_scalp_appl_trail", "rsi_scalp_adbe_trail",
    "rsi_scalp_btc_unit", "rsi_scalp_btc_trail", "rsi_scalp_mu",
    "rsi_scalp_nvda_unit", "rsi_scalp_nvda_trail", "rsi_scalp_nvda_trail_v2",
    "rsi_scalp_tsla_unit", "rsi_scalp_tsla_trail", "rsi_scalp_xau_trail",
]
RSI_INDEX = {sid: i for i, sid in enumerate(RSI_SCALP_IDS)}

MAGIC_MAP = {s["id"]: 401000 + i for i, s in enumerate(STRATEGIES, 1)}


def load_report(sid: str) -> dict | None:
    p = REPORTS / f"{sid}_2021-2026.json"
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def spec_defaults(sid: str) -> dict:
    for s in STRATEGIES:
        if s["id"] == sid:
            return dict(s["defaults"])
    return {}


def evaluate_report(r: dict, days: int) -> tuple[bool, list[str]]:
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
    if r.get("passed") is True:
        ok, issues = acceptance(rep, days, DEFAULT_TRADES_PER_DAY)
        if ok:
            return True, []
    return acceptance(rep, days, DEFAULT_TRADES_PER_DAY)


def _lit_bool(v) -> str:
    return "true" if v else "false"


def emit_darvas(params: dict, ok: bool) -> list[str]:
    d = {**spec_defaults("darvas_xau"), **params}
    return [
        "static void SE_AuditDarvas(DarvasBoxConfig &c)",
        "{",
        f"   c.box_period = {int(d['box_period'])};",
        f"   c.box_deviation = {float(d['box_deviation'])};",
        f"   c.ma_period = {int(d['ma_period'])};",
        f"   c.trend_threshold = {float(d['trend_threshold'])};",
        f"   c.stop_loss_pts = {float(d['stop_loss_pts'])};",
        f"   c.take_profit_pts = {float(d['take_profit_pts'])};",
        "   c.box_timeframe = PERIOD_M15;",
        "   c.trend_timeframe = PERIOD_M15;",
        "   c.use_close_breakout = true;",
        "   c.require_volume_ma = false;",
        "}",
        f"static bool SE_AuditDarvasEnabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def emit_ema_slope(fn: str, params: dict, ok: bool) -> list[str]:
    d = params
    lines = [f"static void SE_Audit{fn}(EmaSlopeConfig &c)", "{"]
    for key, cast in [
        ("ema_period", int), ("price_threshold_pips", float), ("slope_threshold_pips", float),
        ("monitor_timeout_sec", int), ("trailing_stop_pips", float),
        ("max_trades_per_crossover", int), ("profit_check_bars", int),
        ("weekly_adx_period", int), ("weekly_adx_min", float), ("weekly_adx_bar_shift", int),
    ]:
        if key in d:
            lines.append(f"   c.{key} = {cast(d[key])};")
    if "use_trailing_stop" in d:
        lines.append(f"   c.use_trailing_stop = {_lit_bool(d['use_trailing_stop'])};")
    lines += ["}", f"static bool SE_Audit{fn}Enabled() {{ return {_lit_bool(ok)}; }}", ""]
    return lines


def emit_mean_rev(params: dict, ok: bool) -> list[str]:
    d = {**spec_defaults("mean_rev_btc"), **params}
    return [
        "static void SE_AuditMeanRev(MeanReversionConfig &c)",
        "{",
        f"   c.ema_period = {int(d.get('ema_period', 250))};",
        f"   c.min_ema_distance_pts = {float(d.get('min_ema_distance_pts', 3650))};",
        f"   c.rsi_period = {int(d.get('rsi_period', 28))};",
        f"   c.rsi_oversold = {float(d.get('rsi_oversold', 40))};",
        f"   c.rsi_overbought = {float(d.get('rsi_overbought', 83))};",
        f"   c.adx_period = {int(d.get('adx_period', 14))};",
        f"   c.adx_max_for_entry = {float(d.get('adx_max_for_entry', 17))};",
        f"   c.adx_escape = {float(d.get('adx_escape', 34))};",
        f"   c.use_rsi_cross = {_lit_bool(d.get('use_rsi_cross', True))};",
        f"   c.use_hard_sltp = {_lit_bool(d.get('use_hard_sltp', False))};",
        f"   c.sl_points = {float(d.get('sl_points', 1300))};",
        f"   c.tp_points = {float(d.get('tp_points', 13400))};",
        "}",
        f"static bool SE_AuditMeanRevEnabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def emit_rsi_cross(params: dict, ok: bool) -> list[str]:
    d = {**spec_defaults("rsi_cross_xau"), **params}
    return [
        "static void SE_AuditRsiCross(RsiCrossOverConfig &c)",
        "{",
        f"   c.rsi_period = {int(d.get('rsi_period', 19))};",
        f"   c.overbought_level = {float(d.get('overbought_level', 93))};",
        f"   c.oversold_level = {float(d.get('oversold_level', 22))};",
        f"   c.ema_period = {int(d.get('ema_period', 140))};",
        f"   c.ema_slope_threshold = {float(d.get('ema_slope_threshold', 105))};",
        f"   c.ema_distance_threshold = {float(d.get('ema_distance_threshold', 165))};",
        f"   c.exit_buy_rsi = {float(d.get('exit_buy_rsi', 86))};",
        f"   c.exit_sell_rsi = {float(d.get('exit_sell_rsi', 10))};",
        f"   c.trailing_stop_pts = {float(d.get('trailing_stop_pts', 295))};",
        f"   c.cooldown_seconds = {int(d.get('cooldown_seconds', 209))};",
        "}",
        f"static bool SE_AuditRsiCrossEnabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def emit_rsi_asian(fn: str, params: dict, ok: bool) -> list[str]:
    d = params
    return [
        f"static void SE_Audit{fn}(RsiAsianConfig &c)",
        "{",
        f"   c.rsi_period = {int(d.get('rsi_period', 28))};",
        f"   c.overbought_level = {float(d.get('overbought_level', 60))};",
        f"   c.oversold_level = {float(d.get('oversold_level', 8))};",
        f"   c.asian_session_start = {int(d.get('asian_session_start', 0))};",
        f"   c.asian_session_end = {int(d.get('asian_session_end', 8))};",
        f"   c.use_rsi_exit = {_lit_bool(d.get('use_rsi_exit', True))};",
        f"   c.rsi_exit_level = {float(d.get('rsi_exit_level', 55))};",
        "}",
        f"static bool SE_Audit{fn}Enabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def emit_rsi_secret(params: dict, ok: bool) -> list[str]:
    d = {**spec_defaults("rsi_secret_xau"), **params}
    return [
        "static void SE_AuditRsiSecret(RsiSecretSauceConfig &c)",
        "{",
        f"   c.rsi_period = {int(d.get('rsi_period', 16))};",
        f"   c.rsi_overbought = {float(d.get('rsi_overbought', 72.5))};",
        f"   c.rsi_oversold = {float(d.get('rsi_oversold', 32.5))};",
        f"   c.stop_loss_atr = {float(d.get('stop_loss_atr', 2.75))};",
        f"   c.take_profit_atr = {float(d.get('take_profit_atr', 5.0))};",
        f"   c.min_bars_between_trades = {int(d.get('min_bars_between_trades', 7))};",
        "}",
        f"static bool SE_AuditRsiSecretEnabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def emit_rsi_scalp(idx: int, sid: str, params: dict, ok: bool) -> list[str]:
    d = {**spec_defaults(sid), **params}
    return [
        f"static void SE_AuditRsi{idx}(RsiScalpConfig &c)",
        "{",
        f"   c.rsi_period = {int(d.get('rsi_period', 14))};",
        f"   c.rsi_overbought = {float(d.get('rsi_overbought', 70))};",
        f"   c.rsi_oversold = {float(d.get('rsi_oversold', 30))};",
        f"   c.rsi_target_buy = {float(d.get('rsi_target_buy', 80))};",
        f"   c.rsi_target_sell = {float(d.get('rsi_target_sell', 50))};",
        f"   c.bars_to_wait = {int(d.get('bars_to_wait', 5))};",
        f"   c.use_trailing = {_lit_bool(d.get('use_trailing', False))};",
        f"   c.trail_distance_pts = {float(d.get('trail_distance_pts', 0))};",
        f"   c.trail_activation_pts = {float(d.get('trail_activation_pts', 0))};",
        "}",
        f"static bool SE_AuditRsi{idx}Enabled() {{ return {_lit_bool(ok)}; }}",
        "",
    ]


def stub_enabled(name: str, ok: bool = False) -> list[str]:
    return [f"static bool SE_Audit{name}Enabled() {{ return {_lit_bool(ok)}; }}", ""]


def main() -> None:
    start, end = PERIODS["2021-2026"]
    days = period_days(start, end)
    manifest: dict = {
        "generated": datetime.now().isoformat(),
        "period_days": days,
        "trades_per_day_target": DEFAULT_TRADES_PER_DAY,
        "strategies": {},
    }

    reports: dict[str, dict] = {}
    status: dict[str, bool] = {}
    params_map: dict[str, dict] = {}

    for spec in STRATEGIES:
        sid = spec["id"]
        r = load_report(sid)
        if not r:
            manifest["strategies"][sid] = {"status": "no_report", "passed": False}
            status[sid] = False
            params_map[sid] = spec_defaults(sid)
            continue
        reports[sid] = r
        params = r.get("optimized_params") or r.get("optimized", {}).get("params", spec_defaults(sid))
        params_map[sid] = params
        ok, issues = evaluate_report(r, days)
        o = r.get("optimized", {})
        tpd = trades_per_day(
            type("R", (), {"total_trades": int(o.get("total_trades", 0))})(),
            days,
        )
        status[sid] = ok
        manifest["strategies"][sid] = {
            "passed": ok,
            "magic": MAGIC_MAP.get(sid),
            "trades": o.get("total_trades"),
            "trades_per_day": round(tpd, 3),
            "net_profit": o.get("net_profit"),
            "sharpe": o.get("sharpe"),
            "profit_factor": o.get("profit_factor"),
            "issues": issues,
            "params": params,
        }

    lines = [
        "//+------------------------------------------------------------------+",
        "//| SuperEA_AuditParams.mqh - optimized params from cluster audit     |",
        f"//| Generated: {datetime.now().isoformat()}",
        "//+------------------------------------------------------------------+",
        "#ifndef SUPER_EA_AUDIT_PARAMS_MQH",
        "#define SUPER_EA_AUDIT_PARAMS_MQH",
        "",
    ]

    lines += [f"// darvas_xau: {'PASS' if status.get('darvas_xau') else 'DISABLED'}"]
    lines += emit_darvas(params_map.get("darvas_xau", {}), status.get("darvas_xau", False))

    lines += [f"// ema_slope_unit: {'PASS' if status.get('ema_slope_unit') else 'DISABLED'}"]
    lines += emit_ema_slope("EmaUnit", params_map.get("ema_slope_unit", {}), status.get("ema_slope_unit", False))

    lines += [f"// ema_slope_trail: {'PASS' if status.get('ema_slope_trail') else 'DISABLED'}"]
    lines += emit_ema_slope("EmaTrail", params_map.get("ema_slope_trail", {}), status.get("ema_slope_trail", False))

    lines += [f"// mean_rev_btc: {'PASS' if status.get('mean_rev_btc') else 'DISABLED'}"]
    lines += emit_mean_rev(params_map.get("mean_rev_btc", {}), status.get("mean_rev_btc", False))

    lines += [f"// rsi_cross_xau: {'PASS' if status.get('rsi_cross_xau') else 'DISABLED'}"]
    lines += emit_rsi_cross(params_map.get("rsi_cross_xau", {}), status.get("rsi_cross_xau", False))

    for sid, fn in [
        ("rsi_asian_eur", "RsiAsianEur"),
        ("rsi_asian_aud", "RsiAsianAud"),
        ("rsi_asian_gbp", "RsiAsianGbp"),
    ]:
        lines += [f"// {sid}: {'PASS' if status.get(sid) else 'DISABLED'}"]
        lines += emit_rsi_asian(fn, params_map.get(sid, {}), status.get(sid, False))

    lines += [f"// rsi_secret_xau: {'PASS' if status.get('rsi_secret_xau') else 'DISABLED'}"]
    lines += emit_rsi_secret(params_map.get("rsi_secret_xau", {}), status.get("rsi_secret_xau", False))

    for sid in RSI_SCALP_IDS:
        idx = RSI_INDEX[sid]
        lines += [f"// {sid}: {'PASS' if status.get(sid) else 'DISABLED'}"]
        lines += emit_rsi_scalp(idx, sid, params_map.get(sid, {}), status.get(sid, False))

    lines += ["#endif", ""]
    OUT_MQH.parent.mkdir(parents=True, exist_ok=True)
    OUT_MQH.write_text("\n".join(lines), encoding="utf-8")
    OUT_JSON.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    passed = [k for k, v in status.items() if v]
    print(f"Wrote {OUT_MQH}")
    print(f"Wrote {OUT_JSON}")
    print(f"Passed {len(passed)}/{len(STRATEGIES)}: {', '.join(passed) if passed else '(none)'}")


if __name__ == "__main__":
    main()
