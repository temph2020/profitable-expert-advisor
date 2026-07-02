"""Quick solo scan for low-margin stocks using NVDA-style RSI params."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cluster_audit.united_mt5_manifest import ALL_ENABLE_KEYS, HIGH_MARGIN_STOCK_ENABLES
from cluster_audit.united_mt5_runner import BASE_SET, deploy_united, mt5_context, patch_set, run_backtest
import cluster_audit.united_mt5_runner as runner

SYMBOLS = ("SNAP.NYS", "F.NYS", "SOFI.NAS", "PFE.NYS", "AAL.NAS", "NVDA.NAS", "BAC.NYS", "WBD.NAS")

NVDA_PARAMS = {
    "RS_F_Symbol": "",
    "RS_F_TimeFrame": 15,
    "RS_F_RSI_Period": 8,
    "RS_F_RSI_Overbought": 36,
    "RS_F_RSI_Oversold": 38,
    "RS_F_RSI_Target_Buy": 90,
    "RS_F_RSI_Target_Sell": 70,
    "RS_F_BarsToWait": 5,
    "LOT_RS_F": 10,
}


def main() -> None:
    ctx = mt5_context()
    deploy_united(ctx["data"], ctx["mt5_path"])
    print(f"{'symbol':14} {'trades':>6} {'PF':>6} {'net':>10}")
    for sym in SYMBOLS:
        o = {k: False for k in ALL_ENABLE_KEYS}
        o["EnableRSIScalpingF"] = True
        for k in HIGH_MARGIN_STOCK_ENABLES:
            o[k] = False
        o["GAP_Enable"] = False
        o.update(NVDA_PARAMS)
        o["RS_F_Symbol"] = sym
        body = patch_set(BASE_SET, o)
        report = f"scan_{sym.replace('.', '_')}"
        old = runner.TEST_SYMBOL
        runner.TEST_SYMBOL = sym
        m = run_backtest(
            ctx["data"], ctx["mt5_path"], ctx["login"], ctx["server"],
            body, f"{report}.set", report,
        )
        runner.TEST_SYMBOL = old
        print(
            f"{sym:14} {int(m.get('total_trades') or 0):6} "
            f"{float(m.get('profit_factor') or 0):6.2f} {float(m.get('net_profit') or 0):10.2f}"
        )


if __name__ == "__main__":
    main()
