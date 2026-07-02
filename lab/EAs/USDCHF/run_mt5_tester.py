"""
Launch MT5 Strategy Tester for USDCHF Playbook EA.

Usage:
  python run_mt5_tester.py backtest
  python run_mt5_tester.py optimize
  python run_mt5_tester.py backtest --visual
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import MetaTrader5 as mt5

LAB = Path(__file__).resolve().parent
EA_SRC = LAB.parent / "USDCHF.mq5"
DEFAULT_SET = LAB / "USDCHF_Playbook.set"
OPT_SET = LAB / "USDCHF_Genetic_Optimization.set"
OPT_HIGHFREQ_SET = LAB / "USDCHF_Genetic_HighFreq.set"
OPT_ULTRAFREQ_SET = LAB / "USDCHF_Genetic_UltraFreq.set"

LABELS = {
    "profit_factor": ("Profit Factor", "盈利因子"),
    "net_profit": ("Total Net Profit", "总净盈利"),
    "total_trades": ("Total Trades", "交易总计"),
    "sharpe": ("Sharpe Ratio", "夏普比率"),
    "equity_dd": ("Equity Drawdown Maximal", "最大回撤"),
}


def read_text(path: Path) -> str:
    text = path.read_text(encoding="utf-16", errors="ignore")
    if not text.strip():
        text = path.read_text(encoding="utf-8", errors="ignore")
    return text


def grab_metric(text: str, key: str) -> str | None:
    for label in LABELS[key]:
        for pat in (
            rf">{re.escape(label)}</td>\s*<td[^>]*>(?:<b>)?([^<]+)",
            rf">{re.escape(label)}:</td>\s*<td[^>]*>(?:<b>)?([^<]+)",
        ):
            m = re.search(pat, text, re.I)
            if m:
                return m.group(1).strip()
    return None


def parse_report(data: Path, report: str) -> dict:
    xml_path = data / f"{report}.xml"
    if xml_path.exists():
        text = xml_path.read_text(encoding="utf-8", errors="ignore")
        m = re.search(
            r"<Row>\s*<Cell[^>]*><Data[^>]*>Pass</Data>.*?</Row>\s*<Row>(.*?)</Row>",
            text,
            re.S,
        )
        if m:
            cells = re.findall(r'<Data ss:Type="(?:Number|String)">([^<]+)</Data>', m.group(1))
            if len(cells) >= 10:
                params = {}
                param_names = [
                    "UseDailyBias",
                    "DailyEmaPeriod",
                    "HtfZoneBars",
                    "MinBreakBodyRatio",
                    "UseDoubleTrap",
                    "NyChaosStartHour",
                    "NyChaosEndHour",
                    "MomentumStartHour",
                    "MomentumEndHour",
                    "UseMomentumWindow",
                    "LtfFastEma",
                    "LtfSlowEma",
                    "EntryMode",
                    "AllowLtfPullback",
                    "AllowEmaCross",
                    "MinEmaGapPips",
                    "AtrSlMult",
                    "AtrTpMult",
                    "UseTrailing",
                    "TrailAtrMult",
                    "MaxBarsInTrade",
                    "CooldownBars",
                    "MaxSpreadPips",
                    "UseCompressionFilter",
                    "CompressAtrRatio",
                ]
                for i, name in enumerate(param_names):
                    if i + 10 < len(cells):
                        params[name] = cells[i + 10]
                return {
                    "ready": True,
                    "report": str(xml_path),
                    "net_profit": float(cells[2]),
                    "profit_factor": float(cells[4]),
                    "sharpe": float(cells[6]),
                    "max_drawdown": f"{cells[8]}%",
                    "total_trades": int(float(cells[9])),
                    "optimized_params": params,
                }
    for path in sorted(data.glob(f"**/{report}*.htm*"), key=lambda p: p.stat().st_mtime, reverse=True):
        text = read_text(path)
        pf = grab_metric(text, "profit_factor")
        profit = grab_metric(text, "net_profit")
        trades = grab_metric(text, "total_trades")
        sharpe = grab_metric(text, "sharpe")
        dd = grab_metric(text, "equity_dd")
        if pf or profit or trades:
            return {
                "profit_factor": float(pf) if pf else None,
                "net_profit": _num(profit),
                "total_trades": int(float(trades)) if trades and trades[0].isdigit() else None,
                "sharpe": float(sharpe) if sharpe else None,
                "max_drawdown": dd,
                "report": str(path),
                "ready": True,
            }
    return {"ready": False}


def _num(s: str | None) -> float | None:
    if not s:
        return None
    s = s.replace(" ", "").replace(",", "")
    if s.endswith("%"):
        return float(s[:-1])
    return float(s)


def mt5_context() -> dict:
    if not mt5.initialize():
        raise RuntimeError(f"MT5 init failed: {mt5.last_error()}")
    info = mt5.terminal_info()
    acc = mt5.account_info()
    ctx = {
        "data": Path(info.data_path),
        "mt5_path": Path(info.path),
        "login": acc.login if acc else 0,
        "server": acc.server if acc else "",
    }
    mt5.shutdown()
    return ctx


def deploy_ea(data: Path, mt5_path: Path) -> Path:
    dst_dir = data / "MQL5" / "Experts" / "lab" / "USDCHF"
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / "USDCHF.mq5"
    shutil.copy2(EA_SRC, dst)
    log = dst_dir / "compile.log"
    subprocess.run(
        [str(mt5_path / "metaeditor64.exe"), f"/compile:{dst}", f"/log:{log}"],
        timeout=180,
        capture_output=True,
    )
    time.sleep(3)
    ex5 = dst_dir / "USDCHF.ex5"
    if not ex5.exists():
        tail = log.read_text(encoding="utf-8", errors="ignore")[-2000:] if log.exists() else ""
        raise RuntimeError(f"Compile failed:\n{dst}\n{tail}")
    pub = data / "MQL5" / "Experts" / "USDCHF.ex5"
    shutil.copy2(ex5, pub)
    return pub


def copy_set_to_tester(data: Path, set_path: Path, set_name: str) -> Path:
    profiles = data / "MQL5" / "Profiles" / "Tester"
    profiles.mkdir(parents=True, exist_ok=True)
    dst = profiles / set_name
    shutil.copy2(set_path, dst)
    return dst


def build_ini(**kw) -> str:
    return f"""[Common]
Login={kw['login']}
Server={kw['server']}
[Tester]
Expert=USDCHF.ex5
ExpertParameters={kw['set_name']}
Symbol={kw['symbol']}
Period={kw['period']}
Optimization={kw['optimization']}
Model=1
Dates=1
FromDate={kw['from_date']}
ToDate={kw['to_date']}
ForwardMode=0
Deposit={kw['deposit']}
Currency=USD
Leverage={kw['leverage']}
ExecutionMode=0
Report={kw['report']}
ReplaceReport=1
ShutdownTerminal=1
Visual={1 if kw['visual'] else 0}
"""


def run_tester(ctx: dict, **kw) -> dict:
    data: Path = ctx["data"]
    mt5_path: Path = ctx["mt5_path"]
    deploy_ea(data, mt5_path)
    copy_set_to_tester(data, kw["set_path"], kw["set_name"])
    ini_body = build_ini(
        login=ctx["login"],
        server=ctx["server"],
        set_name=kw["set_name"],
        report=kw["report"],
        symbol=kw["symbol"],
        period=kw["period"],
        from_date=kw["from_date"],
        to_date=kw["to_date"],
        deposit=kw["deposit"],
        leverage=kw["leverage"],
        optimization=2 if kw["mode"] == "optimize" else 0,
        visual=kw["visual"],
    )
    ini = data / f"{kw['report']}.ini"
    ini.write_text(ini_body, encoding="utf-8")
    for ext in (".htm", ".html"):
        p = data / f"{kw['report']}{ext}"
        if p.exists():
            p.unlink(missing_ok=True)

    subprocess.run(["taskkill", "/IM", "terminal64.exe", "/F"], capture_output=True)
    subprocess.run(["taskkill", "/IM", "metatester64.exe", "/F"], capture_output=True)
    time.sleep(4)

    print(f"Starting MT5 Strategy Tester ({kw['mode']}) …")
    print(f"  EA: USDCHF.ex5  Symbol: {kw['symbol']}  Period: {kw['period']}")
    print(f"  Set: {kw['set_name']}")
    print(f"  Range: {kw['from_date']} → {kw['to_date']}  Visual: {kw['visual']}")
    t0 = time.time()
    timeout = kw.get("timeout_sec", 7200 if kw["mode"] == "optimize" else 3600)
    subprocess.run([str(mt5_path / "terminal64.exe"), f"/config:{ini}"], timeout=timeout)
    metrics = parse_report(data, kw["report"])
    metrics["elapsed_sec"] = round(time.time() - t0, 1)
    metrics["mode"] = kw["mode"]
    metrics["symbol"] = kw["symbol"]
    metrics["period"] = kw["period"]
    metrics["set_file"] = str(kw["set_path"])
    return metrics


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["backtest", "optimize"])
    p.add_argument("--symbol", default="USDCHF")
    p.add_argument("--period", default="M15")
    p.add_argument("--from", dest="from_date", default="2022.01.01")
    p.add_argument("--to", dest="to_date", default="2026.01.01")
    p.add_argument("--deposit", type=float, default=10000)
    p.add_argument("--leverage", type=int, default=100)
    p.add_argument("--visual", action="store_true")
    p.add_argument("--high-freq", action="store_true", help="High-frequency genetic ranges")
    p.add_argument("--ultra-freq", action="store_true", help="Ultra-frequency genetic (~daily trades)")
    p.add_argument("--set", dest="set_file", default="", help="Custom .set path")
    args = p.parse_args()

    ctx = mt5_context()
    set_path = Path(args.set_file) if args.set_file else (
        OPT_ULTRAFREQ_SET if args.mode == "optimize" and args.ultra_freq else
        OPT_HIGHFREQ_SET if args.mode == "optimize" and args.high_freq else
        OPT_SET if args.mode == "optimize" else DEFAULT_SET
    )
    if not set_path.exists():
        set_path = DEFAULT_SET
    report = f"USDCHF_{args.symbol}_{args.mode}"
    metrics = run_tester(
        ctx,
        mode=args.mode,
        set_path=set_path,
        set_name=set_path.name,
        report=report,
        symbol=args.symbol,
        period=args.period,
        from_date=args.from_date,
        to_date=args.to_date,
        deposit=args.deposit,
        leverage=args.leverage,
        visual=args.visual,
    )
    out_json = LAB / "mt5_results.json"
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(metrics, f, indent=2)

    if metrics.get("ready"):
        print("\n=== MT5 Report ===")
        for k in ("net_profit", "profit_factor", "total_trades", "sharpe", "max_drawdown", "elapsed_sec"):
            if metrics.get(k) is not None:
                print(f"  {k}: {metrics[k]}")
        print(f"  report: {metrics.get('report')}")
        print(f"  saved: {out_json}")
        if args.mode == "optimize" and metrics.get("optimized_params"):
            opt_set = LAB / "USDCHF_optimized.set"
            subprocess.run(
                [sys.executable, str(LAB / "parse_optimize_xml.py"), metrics["report"]],
                check=False,
            )
            if opt_set.exists():
                print(f"  optimized set: {opt_set}")
    else:
        print("Report not found — check MT5 Tester journal.")
        print(f"  ini/log hint: {ctx['data']}")


if __name__ == "__main__":
    main()
