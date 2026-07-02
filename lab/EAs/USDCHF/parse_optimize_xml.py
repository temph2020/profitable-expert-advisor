"""Parse MT5 optimization XML and export best / high-trade sets."""
from __future__ import annotations

import re
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent

SET_DEFAULTS = {
    "UseDailyBias": "false",
    "DailyEmaPeriod": "50",
    "HtfZoneBars": "12",
    "MinBreakBodyRatio": "0.40",
    "UseDoubleTrap": "false",
    "NyChaosStartHour": "12",
    "NyChaosEndHour": "14",
    "MomentumStartHour": "8",
    "MomentumEndHour": "23",
    "UseMomentumWindow": "false",
    "LtfFastEma": "6",
    "LtfSlowEma": "18",
    "EntryMode": "3",
    "AllowLtfPullback": "true",
    "AllowEmaCross": "true",
    "MinEmaGapPips": "0.0",
    "AtrSlMult": "1.3",
    "AtrTpMult": "1.8",
    "UseTrailing": "true",
    "TrailAtrMult": "0.8",
    "MaxBarsInTrade": "20",
    "CooldownBars": "0",
    "MaxSpreadPips": "8",
    "UseCompressionFilter": "false",
    "CompressAtrRatio": "0.70",
}


def parse_xml(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    header = re.search(r"<Row>.*?Pass</Data>.*?</Row>", text, re.S)
    if not header:
        raise SystemExit("header not found")
    cols = re.findall(r'<Data ss:Type="String">([^<]+)</Data>', header.group(0))
    out: list[dict[str, str]] = []
    for row in re.findall(r"<Row>(.*?)</Row>", text, re.S)[1:]:
        cells = re.findall(r'<Data ss:Type="(?:Number|String)">([^<]+)</Data>', row)
        if len(cells) >= len(cols):
            out.append(dict(zip(cols, cells)))
    return cols, out


def row_to_set_params(row: dict[str, str]) -> dict[str, str]:
    merged = dict(SET_DEFAULTS)
    for k, v in row.items():
        if k in merged:
            merged[k] = v
    if "EntryMode" not in row:
        merged["EntryMode"] = "3"
    return merged


def write_set(path: Path, params: dict[str, str]) -> None:
    merged = {**SET_DEFAULTS, **params}
    lines = [
        "; USDCHF Playbook — MT5 genetic optimization export",
        "Timeframe=16388",
        "HtfTimeframe=16396",
        "DailyTimeframe=16408",
        "MagicNumber=20260625",
        "LotSize=0.10",
        "AtrPeriod=14",
        "ExtendHoldMomentum=false",
        "CompressLookback=48",
    ]
    for k in SET_DEFAULTS:
        lines.append(f"{k}={merged[k]}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    xml = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    if xml is None:
        xml = LAB.parent.parent.parent / ".." / "USDCHF_USDCHF_optimize.xml"
    if not xml.exists():
        import MetaTrader5 as mt5

        if not mt5.initialize():
            raise SystemExit("MT5 init failed")
        data = Path(mt5.terminal_info().data_path)
        mt5.shutdown()
        xml = data / "USDCHF_USDCHF_optimize.xml"
    if not xml.exists():
        raise SystemExit(f"missing {xml}")

    _, rows = parse_xml(xml)
    best_profit = max(rows, key=lambda r: float(r["Profit"]))
    best_balanced = None
    for r in rows:
        profit = float(r["Profit"])
        trades = int(float(r["Trades"]))
        pf = float(r["Profit Factor"])
        if profit > 0 and pf >= 1.05 and trades >= 80:
            sc = profit + trades * 15.0
            if best_balanced is None or sc > float(best_balanced["score"]):
                best_balanced = {**r, "score": str(sc)}

    out_profit = LAB / "USDCHF_optimized.set"
    write_set(out_profit, row_to_set_params(best_profit))
    print(f"Best profit: ${float(best_profit['Profit']):,.2f} trades={best_profit['Trades']} PF={best_profit['Profit Factor']}")
    print(f"Wrote {out_profit}")

    if best_balanced:
        out_bal = LAB / "USDCHF_optimized_balanced.set"
        write_set(out_bal, row_to_set_params(best_balanced))
        print(
            f"Best balanced: ${float(best_balanced['Profit']):,.2f} "
            f"trades={best_balanced['Trades']} PF={best_balanced['Profit Factor']}"
        )
        print(f"Wrote {out_bal}")


if __name__ == "__main__":
    main()
