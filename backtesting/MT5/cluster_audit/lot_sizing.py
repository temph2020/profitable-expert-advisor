"""
Lot sizing guidance for United EA combined portfolio.

Compares per-strategy risk at 123.set nominal lots and suggests relative weights.

Usage:
  python -m cluster_audit.lot_sizing
"""

from __future__ import annotations

import json
from pathlib import Path

from cluster_audit.united_registry import UNITED_STRATEGIES

REPORTS = Path(__file__).parent / "reports" / "united_sequential"
MANIFEST = REPORTS / "united_manifest.json"
OUT = REPORTS / "lot_sizing.json"
REF_BALANCE = 1000.0


def main() -> None:
    manifest = {}
    if MANIFEST.exists():
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    rows: list[dict] = []
    for spec in UNITED_STRATEGIES:
        sid = spec["id"]
        info = manifest.get("strategies", {}).get(sid, {})
        if not info.get("passed"):
            continue
        o_net = float(info.get("net_profit", 0))
        trades = int(info.get("trades", 1))
        dd = float(info.get("max_drawdown_pct", info.get("issues", [""])[0] if False else 5))
        lot = float(spec["lot"])
        per_trade = o_net / max(trades, 1)
        # risk proxy: lot * avg loss magnitude; use net/trades as PnL per trade signal
        rows.append({
            "id": sid,
            "symbol": spec["symbol"],
            "lot_123set": lot,
            "net_profit": o_net,
            "trades": trades,
            "pnl_per_trade": round(per_trade, 2),
            "max_dd_pct": dd,
        })

    if not rows:
        print("No passed strategies in manifest — run united sequential audit first.")
        return

    # Target: equal risk contribution via inverse DD weighting
    inv_dd = [1.0 / max(r.get("max_dd_pct", 5), 0.5) for r in rows]
    total_inv = sum(inv_dd)
    for i, r in enumerate(rows):
        weight = inv_dd[i] / total_inv
        r["risk_weight"] = round(weight, 4)
        r["suggested_lot_vs_darvas"] = round(weight / (inv_dd[0] / total_inv), 3) if rows else 1.0

    # Scale all lots so combined net at ref balance ~ sum of individuals / sqrt(N)
    import math
    n = len(rows)
    diversification = math.sqrt(n)
    base_lot = rows[0]["lot_123set"]
    for r in rows:
        r["suggested_lot_at_1k"] = round(base_lot * r["suggested_lot_vs_darvas"] / diversification, 4)

    result = {
        "reference_balance": REF_BALANCE,
        "passed_count": n,
        "diversification_factor": diversification,
        "note": "suggested_lot_at_1k scales 123.set lots by inverse-DD weight / sqrt(N)",
        "strategies": rows,
    }
    OUT.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"Wrote {OUT}")
    print(f"\nLot sizing for {n} passed strategies @ ${REF_BALANCE:,.0f} reference:\n")
    for r in rows:
        print(
            f"  {r['id']:28} lot={r['lot_123set']:8} -> suggested={r['suggested_lot_at_1k']:8} "
            f"(weight={r['risk_weight']:.2%}, pnl/trade=${r['pnl_per_trade']:.2f})"
        )


if __name__ == "__main__":
    main()
