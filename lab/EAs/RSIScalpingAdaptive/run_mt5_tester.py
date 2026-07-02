"""
Launch MT5 Strategy Tester for RSIScalpingAdaptive (native backtest / genetic optimize).

Examples:
  python run_mt5_tester.py backtest
  python run_mt5_tester.py backtest --symbol XAUUSD --from 2004.01.01 --to 2026.01.01
  python run_mt5_tester.py optimize --symbol XAUUSD --from 2004.01.01 --to 2026.01.01
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import time
from pathlib import Path

import MetaTrader5 as mt5

LAB = Path(__file__).resolve().parent
EA_MAIN = LAB / "main.mq5"
EA_OPTIMIZER = LAB / "RSIScalpingAdaptiveOptimizer.mqh"
EA_HELPERS = LAB / "MagicNumberHelpers.mqh"
EA_SUPER = LAB / "SuperEA.mq5"
EA_SUPER_PARAMS = LAB / "RSIScalpingSuperParams.mqh"
EA_SUPER_MAGIC = LAB / "RSIScalpingSuperMagic.mqh"
DEFAULT_SET = LAB / "XAUUSD_Backtest.set"
SUPER_SET = LAB / "SuperEA_portfolio.set"
OPT_SET = LAB / "XAUUSD_Genetic_Optimization.set"
EA_FOLDER = "RSIScalpingAdaptive"
SUPER_EX5 = "RSIScalpingSuper"

LABELS = {
    "profit_factor": ("Profit Factor", "盈利因子"),
    "net_profit": ("Total Net Profit", "总净盈利"),
    "total_trades": ("Total Trades", "交易总计"),
    "sharpe": ("Sharpe Ratio", "夏普比率"),
    "equity_dd": ("Equity Drawdown Maximal", "最大回撤"),
    "recovery": ("Recovery Factor", "恢复因子"),
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
            cells = re.findall(r"<Data ss:Type=\"(?:Number|String)\">([^<]+)</Data>", m.group(1))
            if len(cells) >= 10:
                return {
                    "ready": True,
                    "report": str(xml_path),
                    "net_profit": float(cells[2]),
                    "profit_factor": float(cells[4]),
                    "sharpe": float(cells[6]),
                    "max_drawdown": f"{cells[8]}%",
                    "total_trades": int(float(cells[9])),
                    "RSI_Period": cells[10] if len(cells) > 10 else None,
                    "RSI_Overbought": cells[11] if len(cells) > 11 else None,
                    "RSI_Oversold": cells[12] if len(cells) > 12 else None,
                }
    for path in sorted(data.glob(f"**/{report}*.htm*"), key=lambda p: p.stat().st_mtime, reverse=True):
        text = read_text(path)
        pf = grab_metric(text, "profit_factor")
        profit = grab_metric(text, "net_profit")
        trades = grab_metric(text, "total_trades")
        sharpe = grab_metric(text, "sharpe")
        dd = grab_metric(text, "equity_dd")
        recovery = grab_metric(text, "recovery")
        if pf or profit or trades:
            return {
                "profit_factor": float(pf) if pf else None,
                "net_profit": _num(profit),
                "total_trades": int(float(trades)) if trades and trades[0].isdigit() else None,
                "sharpe": float(sharpe) if sharpe else None,
                "max_drawdown": dd,
                "recovery_factor": float(recovery) if recovery else None,
                "report": str(path),
                "ready": True,
            }
    for ext in (".htm", ".html"):
        p = data / f"{report}{ext}"
        if p.exists():
            text = read_text(p)
            pf = grab_metric(text, "profit_factor")
            if pf:
                return {"ready": True, "report": str(p), "profit_factor": float(pf)}
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


def deploy_ea(data: Path, mt5_path: Path, expert: str = "single") -> Path:
    dst_dir = data / "MQL5" / "Experts" / EA_FOLDER
    dst_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(EA_HELPERS, dst_dir / "MagicNumberHelpers.mqh")

    if expert == "super":
        shutil.copy2(EA_SUPER, dst_dir / "SuperEA.mq5")
        shutil.copy2(EA_SUPER_PARAMS, dst_dir / "RSIScalpingSuperParams.mqh")
        shutil.copy2(EA_SUPER_MAGIC, dst_dir / "RSIScalpingSuperMagic.mqh")
        dst = dst_dir / "SuperEA.mq5"
        log = dst_dir / "compile_super.log"
        subprocess.run(
            [str(mt5_path / "metaeditor64.exe"), f"/compile:{dst}", f"/log:{log}"],
            timeout=180,
            capture_output=True,
        )
        time.sleep(3)
        ex5 = dst_dir / "SuperEA.ex5"
        if not ex5.exists():
            tail = log.read_text(encoding="utf-8", errors="ignore")[-3000:] if log.exists() else ""
            raise RuntimeError(f"SuperEA compile failed:\n{tail}")
        pub = data / "MQL5" / "Experts" / f"{SUPER_EX5}.ex5"
        shutil.copy2(ex5, pub)
        return pub

    shutil.copy2(EA_MAIN, dst_dir / "main.mq5")
    shutil.copy2(EA_OPTIMIZER, dst_dir / "RSIScalpingAdaptiveOptimizer.mqh")

    dst = dst_dir / "main.mq5"
    log = dst_dir / "compile.log"
    subprocess.run(
        [str(mt5_path / "metaeditor64.exe"), f"/compile:{dst}", f"/log:{log}"],
        timeout=180,
        capture_output=True,
    )
    time.sleep(3)
    ex5 = dst_dir / "main.ex5"
    if not ex5.exists():
        tail = log.read_text(encoding="utf-8", errors="ignore")[-3000:] if log.exists() else ""
        raise RuntimeError(f"Compile failed — check MetaEditor:\n{dst}\n{tail}")
    pub = data / "MQL5" / "Experts" / f"{EA_FOLDER}.ex5"
    shutil.copy2(ex5, pub)
    return pub


def copy_set_to_tester(data: Path, set_path: Path, set_name: str) -> Path:
    profiles = data / "MQL5" / "Profiles" / "Tester"
    profiles.mkdir(parents=True, exist_ok=True)
    dst = profiles / set_name
    shutil.copy2(set_path, dst)
    return dst


def build_ini(
    *,
    set_name: str,
    report: str,
    login: int,
    server: str,
    symbol: str,
    period: str,
    from_date: str,
    to_date: str,
    deposit: float,
    leverage: int,
    optimization: int,
    expert: str,
    visual: bool,
) -> str:
    ex5_name = "RSIScalpingAdaptive\\SuperEA.ex5" if expert == "super" else f"{EA_FOLDER}.ex5"
    return f"""[Common]
Login={login}
Server={server}
[Tester]
Expert={ex5_name}
ExpertParameters={set_name}
Symbol={symbol}
Period={period}
Optimization={optimization}
Model=1
Dates=1
FromDate={from_date}
ToDate={to_date}
ForwardMode=0
Deposit={deposit}
Currency=USD
Leverage={leverage}
ExecutionMode=0
Report={report}
ReplaceReport=1
ShutdownTerminal=1
Visual={1 if visual else 0}
"""


def run_tester(
    ctx: dict,
    *,
    mode: str,
    set_path: Path,
    set_name: str,
    report: str,
    symbol: str,
    period: str,
    from_date: str,
    to_date: str,
    deposit: float,
    leverage: int,
    visual: bool,
    expert: str = "single",
    timeout_sec: int = 7200,
) -> dict:
    data: Path = ctx["data"]
    mt5_path: Path = ctx["mt5_path"]
    deploy_ea(data, mt5_path, expert)
    copy_set_to_tester(data, set_path, set_name)

    optimization = 2 if mode == "optimize" else 0
    ini_body = build_ini(
        set_name=set_name,
        report=report,
        login=ctx["login"],
        server=ctx["server"],
        symbol=symbol,
        period=period,
        from_date=from_date,
        to_date=to_date,
        deposit=deposit,
        leverage=leverage,
        optimization=optimization,
        expert=expert,
        visual=visual,
    )
    ini = data / f"{report}.ini"
    ini.write_text(ini_body, encoding="utf-8")
    for ext in (".htm", ".html"):
        p = data / f"{report}{ext}"
        if p.exists():
            p.unlink(missing_ok=True)

    subprocess.run(["taskkill", "/IM", "terminal64.exe", "/F"], capture_output=True)
    subprocess.run(["taskkill", "/IM", "metatester64.exe", "/F"], capture_output=True)
    time.sleep(4)

    print(f"Starting MT5 Strategy Tester ({mode}) …")
    print(f"  EA: {SUPER_EX5 if expert == 'super' else EA_FOLDER}.ex5  Symbol: {symbol}  Period: {period}")
    print(f"  Range: {from_date} → {to_date}  Visual: {visual}")
    t0 = time.time()
    subprocess.run([str(mt5_path / "terminal64.exe"), f"/config:{ini}"], timeout=timeout_sec)
    metrics = parse_report(data, report)
    metrics["elapsed_sec"] = round(time.time() - t0, 1)
    metrics["mode"] = mode
    return metrics


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="RSIScalpingAdaptive MT5 Strategy Tester")
    p.add_argument("mode", choices=["backtest", "optimize"])
    p.add_argument("--symbol", default="XAUUSD")
    p.add_argument("--period", default="H1", choices=["M15", "M30", "H1", "H4"])
    p.add_argument("--from", dest="from_date", default="2004.01.01")
    p.add_argument("--to", dest="to_date", default="2026.01.01")
    p.add_argument("--deposit", type=float, default=10000)
    p.add_argument("--leverage", type=int, default=100)
    p.add_argument("--visual", action="store_true")
    p.add_argument("--set", dest="set_file", default="")
    p.add_argument("--expert", choices=["single", "super"], default="single")
    p.add_argument("--timeout", type=int, default=7200)
    return p.parse_args()


def main() -> None:
    args = parse_args()
    ctx = mt5_context()
    if args.expert == "super":
        set_path = Path(args.set_file) if args.set_file else SUPER_SET
        report = f"{SUPER_EX5}_{args.mode}"
        symbol = args.symbol if args.symbol != "XAUUSD" or args.set_file else "EURUSD"
    else:
        set_path = Path(args.set_file) if args.set_file else (OPT_SET if args.mode == "optimize" else DEFAULT_SET)
        report = f"RSIScalpingAdaptive_{args.symbol}_{args.mode}"
        symbol = args.symbol

    set_name = set_path.name

    metrics = run_tester(
        ctx,
        mode=args.mode,
        set_path=set_path,
        set_name=set_name,
        report=report,
        symbol=symbol,
        period=args.period,
        from_date=args.from_date,
        to_date=args.to_date,
        deposit=args.deposit,
        leverage=args.leverage,
        visual=args.visual,
        expert=args.expert,
        timeout_sec=args.timeout,
    )

    if metrics.get("ready"):
        print("\n=== MT5 Strategy Tester Report ===")
        for k in ("net_profit", "profit_factor", "total_trades", "sharpe", "recovery_factor", "max_drawdown", "elapsed_sec"):
            if k in metrics and metrics[k] is not None:
                print(f"  {k}: {metrics[k]}")
        print(f"  report: {metrics.get('report')}")
    else:
        print("Report not found — open MT5 → View → Strategy Tester → Journal for errors.")


if __name__ == "__main__":
    main()
