#!/usr/bin/env python3
"""Build frontline/cluster-SimpleEMA from portfolio_params.json + mt5_sets."""

from __future__ import annotations

import json
import shutil
from datetime import datetime
from pathlib import Path

LAB = Path(__file__).resolve().parent
ROOT = LAB.parents[2]
CLUSTER = ROOT / "frontline" / "cluster-SimpleEMA"
PARAMS = LAB / "portfolio_params.json"
SETS_SRC = LAB / "mt5_sets"
MAGIC_BASE = 930101


def fmt_bool(v: bool) -> str:
    return "true" if v else "false"


def describe_params(p: dict) -> str:
    pb = "pb" if p.get("use_pullback") else "cross"
    htf = p.get("htf_ema_period", 200) if p.get("use_htf_filter") else "off"
    return f"fast={p['fast_ema']} slow={p['slow_ema']} {pb} htf={htf}"


def gen_params_mqh(members: list[dict]) -> str:
    lines = [
        "// SimpleEMAParams.mqh — auto-generated; do not edit by hand",
        f"// Generated: {datetime.now().isoformat(timespec='seconds')}",
        "#ifndef SIMPLE_EMA_PARAMS_MQH",
        "#define SIMPLE_EMA_PARAMS_MQH",
        "",
        f"#define SE_SLOT_COUNT {len(members)}",
        "",
        "struct SESlotParams",
        "{",
        "   int    fastEma;",
        "   int    slowEma;",
        "   int    trendLegBars;",
        "   double minEmaGapPips;",
        "   int    crossCooldown;",
        "   int    pullbackCooldown;",
        "   bool   usePullback;",
        "   int    pullbackTouch;",
        "   double pullbackAdxMin;",
        "   double pullbackMinGapPips;",
        "   int    maxPullbacksPerLeg;",
        "   double lotSize;",
        "   int    atrPeriod;",
        "   double atrSlMult;",
        "   double atrTpMult;",
        "   int    maxBarsInTrade;",
        "   int    htfEmaPeriod;",
        "   bool   useHtfFilter;",
        "   bool   useAdxFilter;",
        "   int    adxPeriod;",
        "   double adxMin;",
        "   int    sessionStart;",
        "   int    sessionEnd;",
        "   int    maxSpreadPips;",
        "};",
        "",
        "struct SESlotConfig",
        "{",
        "   string       symbol;",
        "   int          magic;",
        "   bool         enabled;",
        "   SESlotParams p;",
        "};",
        "",
        "const SESlotConfig SE_SLOTS[SE_SLOT_COUNT] =",
        "{",
    ]
    for i, m in enumerate(members):
        p = m["params"]
        sym = m["symbol"]
        magic = MAGIC_BASE + i
        comma = "," if i < len(members) - 1 else ""
        lines.append(f"   // {sym} PF={m.get('mt5_metrics', {}).get('profit_factor', '-')} T={m.get('mt5_metrics', {}).get('total_trades', '-')}")
        lines.append("   {")
        lines.append(f'      "{sym}", {magic}, true,')
        lines.append("      {")
        lines.append(
            f"         {p['fast_ema']}, {p['slow_ema']}, {p['trend_leg_bars']}, "
            f"{p['min_ema_gap_pips']}, {p['cross_cooldown']}, {p['pullback_cooldown']}, "
            f"{fmt_bool(p['use_pullback'])}, {p['pullback_touch']}, "
            f"{p['pullback_adx_min']}, {p['pullback_min_gap_pips']}, {p['max_pullbacks_per_leg']}, "
            f"{p['lot_size']}, {p['atr_period']}, {p['atr_sl_mult']}, {p['atr_tp_mult']}, "
            f"{p['max_bars_in_trade']}, {p['htf_ema_period']}, "
            f"{fmt_bool(p['use_htf_filter'])}, {fmt_bool(p['use_adx_filter'])}, "
            f"{p['adx_period']}, {p['adx_min']}, {p['session_start']}, {p['session_end']}, "
            f"{int(p['max_spread_pips'])}"
        )
        lines.append(f"      }}")
        lines.append(f"   }}{comma}")
    lines.extend(["};", "", "#endif", ""])
    return "\n".join(lines)


def gen_magic_mqh(n: int) -> str:
    lines = [
        "// SimpleEMAMagic.mqh — fixed slot magics (cluster-SimpleEMA)",
        f"#define SE_MAGIC_BASE {MAGIC_BASE}",
        "",
        "const int SE_SLOT_MAGICS[SE_SLOT_COUNT] =",
        "{",
    ]
    for i in range(n):
        comma = "," if i < n - 1 else ""
        lines.append(f"   {MAGIC_BASE + i}{comma}  // slot {i + 1}")
    lines.extend(["};", ""])
    return "\n".join(lines)


def gen_manifest(members: list[dict], cfg: dict) -> dict:
    slots = []
    for i, m in enumerate(members):
        mt = m.get("mt5_metrics", {})
        slots.append(
            {
                "slot": i + 1,
                "symbol": m["symbol"],
                "magic": MAGIC_BASE + i,
                "enabled": True,
                "describe": describe_params(m["params"]),
                "pf": mt.get("profit_factor"),
                "trades": mt.get("total_trades"),
                "net_profit": mt.get("net_profit"),
                "set_file": f"sets/SimpleEMA_{m['symbol']}.set",
            }
        )
    return {
        "ea": "cluster-SimpleEMA",
        "timeframe": cfg.get("timeframe", "M15"),
        "magic_range": [MAGIC_BASE, MAGIC_BASE + len(members) - 1],
        "lot_per_symbol": cfg.get("lot_per_symbol", 0.05),
        "period": cfg.get("period", ["2020-01-01", "2026-01-01"]),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "source": "lab/EAs/SimpleEMA/portfolio_params.json",
        "portfolio_metrics": {
            "enabled_count": len(members),
            "total_trades": sum(mt.get("total_trades", 0) for mt in (m.get("mt5_metrics", {}) for m in members)),
            "net_profit": round(sum(mt.get("net_profit", 0) for mt in (m.get("mt5_metrics", {}) for m in members)), 2),
        },
        "slots": slots,
    }


def gen_readme(members: list[dict], manifest: dict) -> str:
    pf = manifest["portfolio_metrics"]
    syms = ", ".join(m["symbol"] for m in members[:8]) + ", …"
    return f"""# cluster-SimpleEMA

SimpleEMA v5 **35-symbol portfolio** — per-symbol MT5-optimized params (M15 trend-leg cross + pullback).

> Source of truth: MT5 Strategy Tester per-symbol runs. See `lab/EAs/SimpleEMA/best_run/mt5_results.json`.

## Performance (MT5 backtest 2020–2026)

| Metric | Value |
|--------|-------|
| Symbols | {pf['enabled_count']} |
| Total trades | {pf['total_trades']} |
| Net profit (sum) | ${pf['net_profit']:,.2f} |

## Deploy

1. Copy this folder to `MQL5/Experts/cluster-SimpleEMA/`
2. Compile `main.mq5` in MetaEditor
3. Attach to **any** chart (e.g. EURUSD M15) — EA trades all symbols in `manifest.json`
4. Ensure all symbols are visible in Market Watch

## Magic numbers

**{MAGIC_BASE}–{MAGIC_BASE + len(members) - 1}** — one magic per symbol slot. No overlap with `cluster-NZDUSD` (928101+) or `cluster-latest`.

Slot mapping: `manifest.json` / `SimpleEMAMagic.mqh`.

## Symbols ({len(members)})

{syms}

Full list in `manifest.json`.

## Per-symbol .set files

`sets/SimpleEMA_{{SYMBOL}}.set` — load in Strategy Tester to re-verify a single symbol with `lab/EAs/SimpleEMA/main.mq5`.

## Regenerate from lab

```powershell
cd lab/EAs/SimpleEMA
python sync_frontline_cluster.py
```

## Run alongside cluster-latest

Different magic range. Use separate chart or same account — magics do not collide.
"""


def gen_portfolio_set(members: list[dict]) -> str:
    sym_list = ",".join(m["symbol"] for m in members)
    return f"""; cluster-SimpleEMA — attach reference (params baked in EA)
Timeframe=16388
OneTradePerSymbol=true
; Symbols (informational — locked in SimpleEMAParams.mqh):
; {sym_list}
"""


def main() -> None:
    data = json.loads(PARAMS.read_text(encoding="utf-8"))
    members = [m for m in data["members"] if m.get("enabled") and "params" in m]
    if not members:
        raise SystemExit("No enabled members in portfolio_params.json")

    members.sort(key=lambda m: m["symbol"])
    CLUSTER.mkdir(parents=True, exist_ok=True)
    sets_dir = CLUSTER / "sets"
    sets_dir.mkdir(exist_ok=True)

    (CLUSTER / "SimpleEMAParams.mqh").write_text(gen_params_mqh(members), encoding="utf-8")
    (CLUSTER / "SimpleEMAMagic.mqh").write_text(gen_magic_mqh(len(members)), encoding="utf-8")

    manifest = gen_manifest(members, data.get("config", {}))
    (CLUSTER / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    (CLUSTER / "README.md").write_text(gen_readme(members, manifest), encoding="utf-8")
    (CLUSTER / "SimpleEMA_portfolio.set").write_text(gen_portfolio_set(members), encoding="utf-8")

    copied = 0
    for m in members:
        sym = m["symbol"]
        src = SETS_SRC / f"SimpleEMA_{sym}.set"
        dst = sets_dir / f"SimpleEMA_{sym}.set"
        if src.exists():
            shutil.copy2(src, dst)
            copied += 1

    helpers_src = ROOT / "frontline" / "cluster-latest" / "MagicNumberHelpers.mqh"
    if helpers_src.exists():
        shutil.copy2(helpers_src, CLUSTER / "MagicNumberHelpers.mqh")

    report_src = LAB / "best_run" / "MT5_portfolio_summary.png"
    reports_dir = CLUSTER / "reports"
    reports_dir.mkdir(exist_ok=True)
    if report_src.exists():
        shutil.copy2(report_src, reports_dir / "MT5_portfolio_summary.png")

    print(f"Built {CLUSTER}")
    print(f"  slots: {len(members)}")
    print(f"  sets copied: {copied}/{len(members)}")
    print(f"  magic: {MAGIC_BASE}..{MAGIC_BASE + len(members) - 1}")


if __name__ == "__main__":
    main()
