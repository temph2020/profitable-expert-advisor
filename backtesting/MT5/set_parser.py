"""Parse MetaTrader 5 .set optimization files."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class SetParam:
    name: str
    value: Any
    start: Any
    step: Any
    stop: Any
    optimize: bool


def _cast(raw: str) -> Any:
    low = raw.strip().lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if "." in raw:
        try:
            return float(raw)
        except ValueError:
            return raw
    try:
        return int(raw)
    except ValueError:
        return raw


def parse_set_file(path: str | Path) -> dict[str, SetParam]:
    params: dict[str, SetParam] = {}
    for line in Path(path).read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if "=" not in line:
            continue
        name, rest = line.split("=", 1)
        parts = rest.split("||")
        if len(parts) < 5:
            continue
        value, start, step, stop, opt = parts[0], parts[1], parts[2], parts[3], parts[4]
        params[name] = SetParam(
            name=name,
            value=_cast(value),
            start=_cast(start),
            step=_cast(step),
            stop=_cast(stop),
            optimize=opt.strip().upper() == "Y",
        )
    return params
