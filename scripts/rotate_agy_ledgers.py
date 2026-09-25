#!/usr/bin/env python3
"""
rotate_agy_ledgers.py - Rotates heavy .ndjson ledger files in .agy directories.
Keeps recent 500 lines for fast reading while archiving older lines compressed.
"""

import os
import gzip
import time
from pathlib import Path

MAX_BYTES = 500_000  # 500 KB threshold
KEEP_LINES = 500

def rotate_ndjson(filepath: Path) -> bool:
    if not filepath.is_file():
        return False
    size = filepath.stat().st_size
    if size <= MAX_BYTES:
        return False

    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

        if len(lines) <= KEEP_LINES:
            return False

        old_lines = lines[:-KEEP_LINES]
        keep_lines = lines[-KEEP_LINES:]

        archive_dir = filepath.parent / "archive" / "ndjson"
        archive_dir.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y%m%d_%H%M%S")
        archive_file = archive_dir / f"{filepath.stem}_{ts}.ndjson.gz"

        with gzip.open(archive_file, "wt", encoding="utf-8") as gf:
            gf.writelines(old_lines)

        temp_file = filepath.with_suffix(".tmp")
        with open(temp_file, "w", encoding="utf-8") as f:
            f.writelines(keep_lines)
        temp_file.replace(filepath)

        new_size = filepath.stat().st_size
        print(f"Rotated {filepath.name}: {size / 1024:.1f} KB -> {new_size / 1024:.1f} KB (archived {len(old_lines)} lines to {archive_file.name})")
        return True
    except Exception as e:
        print(f"Failed to rotate {filepath}: {e}")
        return False

def main():
    projects = [
        Path(r"C:\Users\Администратор\Documents\antigravity\H10 Athlete Cardio Lab\.agy"),
        Path(r"C:\Users\Администратор\Documents\antigravity\Huawei Health export\.agy")
    ]
    total_rotated = 0
    for agy_dir in projects:
        if not agy_dir.is_dir():
            continue
        for p in agy_dir.glob("*.ndjson"):
            if rotate_ndjson(p):
                total_rotated += 1
    print(f"Rotation complete. {total_rotated} files rotated.")

if __name__ == "__main__":
    main()
