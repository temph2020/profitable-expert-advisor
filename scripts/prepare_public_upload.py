#!/usr/bin/env python3
"""Pre-upload checks: scan for secrets and list ignored artifact types."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PATTERNS = [
    (r"C:\\Users\\[^\\<]+", "Windows user path"),
    (r"/Users/[^/\s]+", "macOS user path"),
    (r"D0E8209F[A-F0-9]{24}", "MT5 terminal data hash"),
    (r"ReportTester-\d{6,}\.html", "MT5 account id in report name"),
    (r"(?i)(api[_-]?key|private[_-]?key|password)\s*=\s*\S+", "credential assignment"),
    (r"(?i)POLYMARKET_PRIVATE_KEY=\S+", "Polymarket private key"),
]

SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__"}
SKIP_SUFFIXES = {".pdf", ".png", ".jpg", ".jpeg", ".ex5", ".onnx", ".pkl", ".htm", ".html", ".log"}
SKIP_PATH_PARTS = (
    "cluster_audit/reports/",
    "optimization_results/",
    "lab/EAs/SimpleEMA/best_run/",
)
SKIP_FILES = {
    "SECURITY.md",
    "CONTRIBUTING.md",
    ".env.example",
    "polymarket/.env.example",
    "polymarket/README.md",
    "scripts/prepare_public_upload.py",
}


def iter_files() -> list[Path]:
    out: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        rel = path.relative_to(ROOT).as_posix()
        if rel in SKIP_FILES:
            continue
        if any(part in rel for part in SKIP_PATH_PARTS):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        out.append(path)
    return out


def scan() -> list[str]:
    hits: list[str] = []
    for path in iter_files():
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        rel = path.relative_to(ROOT)
        for pat, label in PATTERNS:
            for m in re.finditer(pat, text):
                hits.append(f"{rel}: {label} → {m.group(0)[:80]}")
    return hits


def git_ignored(path: Path) -> bool:
    r = subprocess.run(
        ["git", "check-ignore", "-q", str(path)],
        cwd=ROOT,
        capture_output=True,
    )
    return r.returncode == 0


def main() -> int:
    print("=== Sensitive-data scan ===")
    hits = scan()
    if hits:
        print("FAIL — possible secrets (fix before upload):")
        for h in hits[:40]:
            print(" ", h)
        if len(hits) > 40:
            print(f"  ... and {len(hits) - 40} more")
        return 1
    print("OK — no known secret patterns in text sources.")

    print("\n=== Tracked files that should be gitignored ===")
    tracked_bad: list[str] = []
    r = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        capture_output=True,
        check=True,
    )
    for raw in r.stdout.split(b"\0"):
        if not raw:
            continue
        p = ROOT / raw.decode("utf-8", errors="replace")
        if p.suffix.lower() in {".pdf", ".png", ".jpg", ".jpeg"} or p.name == "mt5_results.json":
            if git_ignored(p) or p.suffix.lower() in {".pdf", ".png", ".jpg", ".jpeg"}:
                tracked_bad.append(str(p.relative_to(ROOT)))

    if tracked_bad:
        print("Remove from git index (files stay on disk):")
        for t in tracked_bad[:30]:
            print(" ", t)
        print("\n  git rm -r --cached <paths above>")
        return 2
    print("OK — no PDF/image/mt5_results.json tracked.")

    print("\nReady to push source-only repo.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
