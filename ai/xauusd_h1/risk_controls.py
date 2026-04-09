"""
Dynamic adverse risk (conceptual mirror of EA InpMaxAdverseATR).
"""

from __future__ import annotations

import numpy as np


def adverse_hit_long(
    entry: float,
    low_path: np.ndarray,
    atr_path: np.ndarray,
    max_adverse_atr: float,
) -> int | None:
    for i in range(len(low_path)):
        atr = max(atr_path[i], entry * 1e-6)
        adv = (entry - low_path[i]) / atr
        if adv >= max_adverse_atr:
            return i
    return None
