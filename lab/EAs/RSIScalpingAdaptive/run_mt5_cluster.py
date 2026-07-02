"""
Batch MT5 genetic optimization per symbol → regenerate RSIScalpingSuperParams.mqh

Usage:
  python run_mt5_cluster.py optimize --symbols EURUSD,GBPUSD,USDJPY
  python run_mt5_cluster.py optimize --all-forex
  python run_mt5_cluster.py backtest-portfolio
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

LAB = Path(__file__).resolve().parent
TESTER = LAB / "run_mt5_tester.py"
OPT_SET = LAB / "XAUUSD_Genetic_Optimization.set"
PARAMS_MQH = LAB / "RSIScalpingSuperParams.mqh"
MAGIC_MQH = LAB / "RSIScalpingSuperMagic.mqh"

FOREX_MAJORS = [
    "EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCHF", "USDCAD", "NZDUSD", "EURJPY", "XAUUSD"
]


def parse_best_from_xml(xml_path: Path) -> dict | None:
    if not xml_path.exists():
        return None
    ns = {"ss": "urn:schemas-microsoft-com:office:spreadsheet"}
    root = ET.parse(xml_path).getroot()
    rows = root.findall(".//ss:Worksheet/ss:Table/ss:Row", ns)
    if len(rows) < 2:
        return None
    headers = [c.find("ss:Data", ns).text for c in rows[0].findall("ss:Cell", ns)]
    best = None
    best_score = float("-inf")
    for row in rows[1:]:
        cells = [c.find("ss:Data", ns).text for c in row.findall("ss:Cell", ns)]
        if len(cells) < len(headers):
            continue
        d = dict(zip(headers, cells))
        try:
            profit = float(d.get("Profit", 0))
            pf = float(d.get("Profit Factor", 0))
            dd = float(d.get("Equity DD %", 100))
            sharpe = float(d.get("Sharpe Ratio", 0))
        except (TypeError, ValueError):
            continue
        if profit <= 0 or pf < 1.05 or dd > 20:
            continue
        score = profit * pf / max(dd, 1.0) + sharpe * 100
        if score > best_score:
            best_score = score
            best = {
                "profit": profit,
                "pf": pf,
                "dd": dd,
                "sharpe": sharpe,
                "trades": int(float(d.get("Trades", 0))),
                "rsi_period": int(float(d["RSI_Period"])),
                "rsi_overbought": float(d["RSI_Overbought"]),
                "rsi_oversold": float(d["RSI_Oversold"]),
                "rsi_target_buy": float(d["RSI_Target_Buy"]),
                "rsi_target_sell": float(d["RSI_Target_Sell"]),
                "bars_to_wait": int(float(d["BarsToWait"])),
            }
    return best


def run_optimize_symbol(symbol: str, from_date: str, to_date: str, timeout: int) -> dict | None:
    cmd = [
        sys.executable,
        str(TESTER),
        "optimize",
        "--symbol",
        symbol,
        "--from",
        from_date,
        "--to",
        to_date,
        "--set",
        str(OPT_SET),
        "--timeout",
        str(timeout),
    ]
    print(f"\n=== MT5 genetic optimize {symbol} ===")
    subprocess.run(cmd, check=False)
    import MetaTrader5 as mt5

    if not mt5.initialize():
        return None
    data = Path(mt5.terminal_info().data_path)
    mt5.shutdown()
    xml = data / f"RSIScalpingAdaptive_{symbol}_optimize.xml"
    return parse_best_from_xml(xml)


def write_params_mqh(results: dict[str, dict]) -> None:
    lines = [
        "// RSIScalpingSuperParams.mqh — auto-generated from MT5 genetic optimization",
        f"// Generated: {datetime.now().isoformat(timespec='seconds')}",
        "#ifndef RSI_SCALPING_SUPER_PARAMS_MQH",
        "#define RSI_SCALPING_SUPER_PARAMS_MQH",
        "",
        '#include "RSIScalpingSuperMagic.mqh"',
        "",
        f"#define RS_SUPER_SLOT_COUNT {len(results)}",
        "",
        "struct RSSlotParams",
        "{",
        "   int    rsiPeriod;",
        "   double rsiOverbought;",
        "   double rsiOversold;",
        "   double rsiTargetBuy;",
        "   double rsiTargetSell;",
        "   int    barsToWait;",
        "   double lotSize;",
        "};",
        "",
        "struct RSSlotConfig",
        "{",
        "   string       symbol;",
        "   int          magic;",
        "   bool         enabled;",
        "   RSSlotParams p;",
        "};",
        "",
        "const RSSlotConfig RS_SUPER_SLOTS[RS_SUPER_SLOT_COUNT] =",
        "{",
    ]
    for i, (sym, r) in enumerate(results.items(), start=1):
        comment = f"// {sym} MT5 genetic profit=${r['profit']:.0f} PF={r['pf']:.2f} DD={r['dd']:.1f}%"
        lines.append(f"   {comment}")
        lines.append(
            f'   {{ "{sym}", RS_SUPER_MAGIC_BASE + {i}, true,'
        )
        lines.append(
            f"     {{ {r['rsi_period']}, {r['rsi_overbought']:.1f}, {r['rsi_oversold']:.1f}, "
            f"{r['rsi_target_buy']:.1f}, {r['rsi_target_sell']:.1f}, {r['bars_to_wait']}, 0.10 }} }},"
        )
    lines += ["};", "", "#endif", ""]
    PARAMS_MQH.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {PARAMS_MQH}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["optimize", "backtest-portfolio"])
    p.add_argument("--symbols", default=",".join(FOREX_MAJORS))
    p.add_argument("--all-forex", action="store_true")
    p.add_argument("--from", dest="from_date", default="2004.01.01")
    p.add_argument("--to", dest="to_date", default="2026.01.01")
    p.add_argument("--timeout", type=int, default=7200)
    args = p.parse_args()

    syms = FOREX_MAJORS if args.all_forex else [s.strip() for s in args.symbols.split(",") if s.strip()]

    if args.mode == "optimize":
        results: dict[str, dict] = {}
        for sym in syms:
            best = run_optimize_symbol(sym, args.from_date, args.to_date, args.timeout)
            if best:
                results[sym] = best
                print(f"  {sym}: profit=${best['profit']:.0f} PF={best['pf']:.2f} DD={best['dd']:.1f}%")
            else:
                print(f"  {sym}: no stable candidate — skipped")
        if not results:
            raise SystemExit("No symbols passed optimization gates")
        if len(results) < len(syms):
            print(f"WARNING: only {len(results)}/{len(syms)} symbols optimized — merge manually into RSIScalpingSuperParams.mqh")
            return
        write_params_mqh(results)
    else:
        cmd = [
            sys.executable,
            str(LAB / "run_mt5_tester.py"),
            "backtest",
            "--symbol",
            "EURUSD",
            "--from",
            args.from_date,
            "--to",
            args.to_date,
            "--set",
            str(LAB / "SuperEA_portfolio.set"),
        ]
        # portfolio backtest uses SuperEA — extend run_mt5_tester for SuperEA
        print("Use MT5 Tester manually: Expert=RSIScalpingSuper.ex5 on EURUSD H1, load SuperEA_portfolio.set")


if __name__ == "__main__":
    main()
