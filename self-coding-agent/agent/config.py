from __future__ import annotations

import copy
from pathlib import Path
from typing import Any, Dict

import yaml

AGENT_DIR = Path(__file__).resolve().parent.parent


def _deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    out = copy.deepcopy(base)
    for k, v in override.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def default_config() -> Dict[str, Any]:
    example = AGENT_DIR / "config.example.yaml"
    if example.is_file():
        with example.open("r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    return {}


def load_config() -> Dict[str, Any]:
    path = AGENT_DIR / "config.yaml"
    base = default_config()
    if not path.is_file():
        return base
    with path.open("r", encoding="utf-8") as f:
        user = yaml.safe_load(f) or {}
    return _deep_merge(base, user)


def workspace_path(cfg: Dict[str, Any]) -> Path:
    rel = cfg.get("workspace_root", "..")
    return (AGENT_DIR / rel).resolve()
