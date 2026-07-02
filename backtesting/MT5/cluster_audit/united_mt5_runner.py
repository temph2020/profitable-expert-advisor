"""MT5 Strategy Tester runner for United EA (cluster-latest/main.mq5)."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import MetaTrader5 as mt5

CLUSTER = Path(__file__).resolve().parents[3] / "frontline" / "cluster-latest"
BASE_SET = CLUSTER / "123.set"
DEPOSIT = 3000
LEVERAGE = 1000
FROM_DATE = "2023.07.01"
TO_DATE = "2026.06.01"
TEST_SYMBOL = "NAS100"
TEST_PERIOD = "H1"

LABELS = {
    "profit_factor": ("Profit Factor", "盈利因子"),
    "net_profit": ("Total Net Profit", "总净盈利"),
    "total_trades": ("Total Trades", "交易总计"),
    "sharpe": ("Sharpe Ratio", "夏普比率"),
    "equity_dd": ("Equity Drawdown Maximal", "最大回撤"),
    "margin_level": ("Minimal margin level", "最低保证金比例"),
}


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-16", "utf-16-le", "utf-8", "cp1252"):
        try:
            text = raw.decode(enc)
            if text.strip():
                return text
        except UnicodeError:
            continue
    return raw.decode("utf-8", errors="ignore")


def grab_metric(text: str, key: str) -> str | None:
    for label in LABELS[key]:
        for pat in (
            rf">{re.escape(label)}</td>\s*<td[^>]*>(?:<b>)?([^<]+)",
            rf">{re.escape(label)}:</td>\s*<td[^>]*>(?:<b>)?([^<]+)",
            rf">{re.escape(label)}</td>\s*<td[^>]*><b>([^<]+)",
        ):
            m = re.search(pat, text, re.I)
            if m:
                return m.group(1).strip()
    return None


def parse_report(data: Path, report: str) -> dict:
    candidates = [data / f"{report}{ext}" for ext in (".htm", ".html")]
    candidates += sorted(data.glob(f"**/{report}*.htm*"), key=lambda p: p.stat().st_mtime, reverse=True)
    seen: set[Path] = set()
    for path in candidates:
        if path in seen or not path.exists():
            continue
        seen.add(path)
        text = read_text(path)
        pf = grab_metric(text, "profit_factor")
        profit = grab_metric(text, "net_profit")
        trades = grab_metric(text, "total_trades")
        sharpe = grab_metric(text, "sharpe")
        dd = grab_metric(text, "equity_dd")
        ml = grab_metric(text, "margin_level")
        if pf or profit or trades:
            return {
                "profit_factor": float(pf) if pf else None,
                "net_profit": _num(profit),
                "total_trades": int(float(trades)) if trades and trades[0].isdigit() else _int(trades),
                "sharpe": float(sharpe) if sharpe else None,
                "max_drawdown": dd,
                "min_margin_level": ml,
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


def _int(s: str | None) -> int | None:
    if not s:
        return None
    try:
        return int(float(s.replace(" ", "").replace(",", "")))
    except ValueError:
        return None


KNOWN_TERMINALS = [
    Path(r"C:\Program Files\MetaTrader 5\terminal64.exe"),
]


def _terminal_data_dirs() -> list[Path]:
    root = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal"
    if not root.is_dir():
        return []
    return [p for p in root.iterdir() if p.is_dir() and (p / "origin.txt").exists()]


def _read_origin(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8", "utf-16", "utf-16-le", "cp1252"):
        try:
            return raw.decode(enc).strip()
        except UnicodeError:
            continue
    return raw.decode("utf-8", errors="ignore").strip()


def _load_dotenv() -> None:
    env_path = Path(__file__).resolve().parents[3] / ".env"
    if not env_path.is_file():
        return
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = val


_load_dotenv()
MT5_TERMINAL_DATA_ID = os.environ.get("MT5_TERMINAL_DATA_ID", "").strip()
# Back-compat alias for scripts that import PREFERRED_DATA_ID
PREFERRED_DATA_ID = MT5_TERMINAL_DATA_ID


def mt5_terminal_data_dir() -> Path | None:
    """MT5 data folder: MT5_TERMINAL_DATA_ID env, else first terminal with origin.txt."""
    root = Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal"
    if MT5_TERMINAL_DATA_ID:
        candidate = root / MT5_TERMINAL_DATA_ID
        if (candidate / "origin.txt").is_file():
            return candidate
    dirs = _terminal_data_dirs()
    return dirs[0] if dirs else None


def _resolve_terminal_exe() -> Path | None:
    env_exe = os.environ.get("MT5_TERMINAL_EXE", "").strip()
    if env_exe:
        exe = Path(env_exe)
        if exe.is_file():
            return exe
    data_dir = mt5_terminal_data_dir()
    if data_dir:
        origin = data_dir / "origin.txt"
        if origin.is_file():
            try:
                exe = Path(_read_origin(origin))
                if exe.is_file():
                    return exe
            except OSError:
                pass
    for data_dir in _terminal_data_dirs():
        origin = data_dir / "origin.txt"
        try:
            exe = Path(_read_origin(origin))
            if exe.is_file():
                return exe
        except OSError:
            continue
    for exe in KNOWN_TERMINALS:
        if exe.is_file():
            return exe
    return None


def mt5_context(*, retries: int = 6, wait_sec: float = 12.0) -> dict:
    terminal_exe = _resolve_terminal_exe()
    last_err = None
    for attempt in range(retries):
        if attempt:
            time.sleep(wait_sec)
        if attempt >= 1 and terminal_exe and terminal_exe.is_file():
            subprocess.run(["taskkill", "/IM", "terminal64.exe", "/F"], capture_output=True)
            time.sleep(3)
            subprocess.Popen([str(terminal_exe)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(20)
        mt5.shutdown()
        ok = mt5.initialize(path=str(terminal_exe)) if terminal_exe else mt5.initialize()
        if not ok:
            last_err = mt5.last_error()
            continue
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
    raise RuntimeError(f"MT5 init failed after {retries} tries: {last_err}")


def deploy_united(data: Path, mt5_path: Path) -> Path:
    dst = data / "MQL5" / "Experts" / "cluster-latest"
    dst.mkdir(parents=True, exist_ok=True)
    for name in ("main.mq5", "MagicNumberHelpers.mqh", "GapGuard.mqh"):
        shutil.copy2(CLUSTER / name, dst / name)
    strat_dst = dst / "Strategies"
    strat_dst.mkdir(exist_ok=True)
    for f in (CLUSTER / "Strategies").glob("*.mqh"):
        shutil.copy2(f, strat_dst / f.name)
    log = dst / "compile.log"
    subprocess.run(
        [str(mt5_path / "metaeditor64.exe"), f"/compile:{dst / 'main.mq5'}", f"/log:{log}"],
        timeout=180,
        capture_output=True,
    )
    time.sleep(3)
    ex5 = dst / "main.ex5"
    if not ex5.exists():
        tail = log.read_text(encoding="utf-8", errors="ignore")[-2000:] if log.exists() else ""
        raise RuntimeError(f"Compile failed: {log}\n{tail}")
    pub = data / "MQL5" / "Experts" / "main.ex5"
    shutil.copy2(ex5, pub)
    return pub


def patch_set(base: Path, overrides: dict[str, str | bool | int | float]) -> str:
    lines_out: list[str] = []
    seen: set[str] = set()
    for line in base.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line.strip() or line.strip().startswith(";") or "=" not in line:
            lines_out.append(line)
            continue
        name = line.split("=", 1)[0].strip()
        if name in overrides:
            val = overrides[name]
            if isinstance(val, bool):
                sval = "true" if val else "false"
            else:
                sval = str(val)
            lines_out.append(f"{name}={sval}")
            seen.add(name)
        else:
            lines_out.append(line)
    for k, v in overrides.items():
        if k not in seen:
            sval = "true" if v is True else "false" if v is False else str(v)
            lines_out.append(f"{k}={sval}")
    return "\n".join(lines_out) + "\n"


def patch_set_for_lot_genetic(
    base: Path,
    overrides: dict[str, str | bool | int | float],
    lot_key: str,
    start: float,
    step: float,
    stop: float,
    default: float | None = None,
) -> str:
    """Build .set with a single LOT_* genetic range; all other ||Y flags forced to N."""
    body = patch_set(base, overrides)
    val = default if default is not None else start
    genetic_line = f"{lot_key}={val}||{start}||{step}||{stop}||Y"
    lines_out: list[str] = []
    seen_lot = False
    for line in body.splitlines():
        if not line.strip() or line.strip().startswith(";") or "=" not in line:
            lines_out.append(line)
            continue
        name = line.split("=", 1)[0].strip()
        if name == lot_key:
            lines_out.append(genetic_line)
            seen_lot = True
        elif "||" in line:
            parts = line.split("||")
            if len(parts) >= 5:
                parts[4] = "N"
                lines_out.append("||".join(parts))
            else:
                lines_out.append(line)
        else:
            lines_out.append(line)
    if not seen_lot:
        lines_out.append(genetic_line)
    return "\n".join(lines_out) + "\n"


def parse_optimization_xml(data: Path, report: str, lot_key: str) -> dict:
    candidates = [data / f"{report}.xml", data / f"{report}.opt"]
    candidates += sorted(data.glob(f"**/{report}*.xml"), key=lambda p: p.stat().st_mtime, reverse=True)
    seen: set[Path] = set()
    xml_path: Path | None = None
    for p in candidates:
        if p in seen or not p.exists() or p.suffix.lower() != ".xml":
            continue
        seen.add(p)
        xml_path = p
        break
    if xml_path is None:
        return {"ready": False, "error": "xml_not_found"}

    text = read_text(xml_path)
    header = re.search(r"<Row>.*?Pass</Data>.*?</Row>", text, re.S)
    if not header:
        return {"ready": False, "error": "xml_header_missing", "report": str(xml_path)}

    cols = re.findall(r'<Data ss:Type="String">([^<]+)</Data>', header.group(0))
    rows: list[dict[str, str]] = []
    for row_xml in re.findall(r"<Row>(.*?)</Row>", text, re.S)[1:]:
        cells = re.findall(r'<Data ss:Type="(?:Number|String)">([^<]+)</Data>', row_xml)
        if len(cells) >= len(cols):
            rows.append(dict(zip(cols, cells)))

    if not rows:
        return {"ready": False, "error": "xml_no_rows", "report": str(xml_path)}

    best_row: dict[str, str] | None = None
    best_score = -1e18
    for row in rows:
        try:
            profit = float(row.get("Profit", 0))
            pf = float(row.get("Profit Factor", 0))
            sharpe = float(row.get("Sharpe Ratio", row.get("Sharpe", 0)))
            trades = int(float(row.get("Trades", 0)))
        except (ValueError, TypeError):
            continue
        if trades < 20 or pf < 1.0 or profit <= 0:
            score = -1e10 + profit
        else:
            score = sharpe * 2000.0 + profit / 500.0 + pf * 50.0
        if score > best_score:
            best_score = score
            best_row = row

    if best_row is None:
        best_row = max(rows, key=lambda r: float(r.get("Profit", 0)))

    lot_raw = best_row.get(lot_key)
    if lot_raw is None:
        for k, v in best_row.items():
            if k.replace(" ", "") == lot_key or lot_key in k:
                lot_raw = v
                break
    best_lot = float(lot_raw) if lot_raw is not None else None

    return {
        "ready": True,
        "report": str(xml_path),
        "best_lot": best_lot,
        "best_row": best_row,
        "best_score": best_score,
        "passes": len(rows),
        "profit": float(best_row.get("Profit", 0)),
        "profit_factor": float(best_row.get("Profit Factor", 0)),
        "sharpe": float(best_row.get("Sharpe Ratio", best_row.get("Sharpe", 0))),
        "trades": int(float(best_row.get("Trades", 0))),
    }


def run_genetic_lot_optimize(
    data: Path,
    mt5_path: Path,
    login: int,
    server: str,
    set_body: str,
    set_name: str,
    report: str,
    lot_key: str,
    *,
    test_symbol: str | None = None,
    optimization: int = 2,
    timeout_sec: int = 7200,
) -> dict:
    write_tester_set(data, set_name, set_body)
    ini = data / f"{report}.ini"
    ini.write_text(
        build_ini(set_name, report, login, server, symbol=test_symbol, optimization=optimization),
        encoding="utf-8",
    )
    for ext in (".htm", ".html", ".xml"):
        p = data / f"{report}{ext}"
        if p.exists():
            p.unlink(missing_ok=True)

    subprocess.run(["taskkill", "/IM", "terminal64.exe", "/F"], capture_output=True)
    subprocess.run(["taskkill", "/IM", "metatester64.exe", "/F"], capture_output=True)
    time.sleep(6)

    t0 = time.time()
    subprocess.run([str(mt5_path / "terminal64.exe"), f"/config:{ini}"], timeout=timeout_sec)
    elapsed = round(time.time() - t0, 1)

    opt = parse_optimization_xml(data, report, lot_key)
    opt["elapsed_sec"] = elapsed
    if not opt.get("ready"):
        metrics = parse_report(data, report)
        opt.update(metrics)
    return opt


def write_tester_set(data: Path, set_name: str, body: str) -> Path:
    profiles = data / "MQL5" / "Profiles" / "Tester"
    profiles.mkdir(parents=True, exist_ok=True)
    path = profiles / set_name
    path.write_text(body, encoding="utf-8")
    return path


def build_ini(
    set_name: str,
    report: str,
    login: int,
    server: str,
    *,
    symbol: str | None = None,
    optimization: int = 0,
) -> str:
    sym = symbol or TEST_SYMBOL
    return f"""[Common]
Login={login}
Server={server}
[Tester]
Expert=main.ex5
ExpertParameters={set_name}
Symbol={sym}
Period={TEST_PERIOD}
Optimization={optimization}
Model=1
Dates=1
FromDate={FROM_DATE}
ToDate={TO_DATE}
ForwardMode=0
Deposit={DEPOSIT}
Currency=USD
Leverage={LEVERAGE}
ExecutionMode=0
Report={report}
ReplaceReport=1
ShutdownTerminal=1
Visual=0
"""


def run_backtest(
    data: Path,
    mt5_path: Path,
    login: int,
    server: str,
    set_body: str,
    set_name: str,
    report: str,
    *,
    test_symbol: str | None = None,
    timeout_sec: int = 1800,
) -> dict:
    write_tester_set(data, set_name, set_body)
    ini = data / f"{report}.ini"
    ini.write_text(build_ini(set_name, report, login, server, symbol=test_symbol), encoding="utf-8")
    for ext in (".htm", ".html"):
        p = data / f"{report}{ext}"
        if p.exists():
            p.unlink(missing_ok=True)

    subprocess.run(["taskkill", "/IM", "terminal64.exe", "/F"], capture_output=True)
    subprocess.run(["taskkill", "/IM", "metatester64.exe", "/F"], capture_output=True)
    time.sleep(6)

    t0 = time.time()
    subprocess.run([str(mt5_path / "terminal64.exe"), f"/config:{ini}"], timeout=timeout_sec)
    metrics = parse_report(data, report)
    metrics["elapsed_sec"] = round(time.time() - t0, 1)
    return metrics
