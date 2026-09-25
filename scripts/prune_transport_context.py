import os
import shutil
from pathlib import Path

CONTEXT_DIR = Path(os.path.expandvars(r"%USERPROFILE%\.agentic-pipeline\action-bridge\transport\context"))

def prune_transport_context(keep_count: int = 5):
    if not CONTEXT_DIR.is_dir():
        print("Transport context dir not found.")
        return 0, 0

    entries = [d for d in CONTEXT_DIR.iterdir() if d.is_dir()]
    if len(entries) <= keep_count:
        print(f"Transport context entries ({len(entries)}) <= keep_count ({keep_count}). Nothing to prune.")
        return 0, 0

    entries.sort(key=lambda d: d.stat().st_mtime, reverse=True)
    to_delete = entries[keep_count:]

    deleted_count = 0
    reclaimed_bytes = 0
    for d in to_delete:
        try:
            for root, _, files in os.walk(d):
                for f in files:
                    try:
                        reclaimed_bytes += os.path.getsize(os.path.join(root, f))
                    except Exception:
                        pass
            shutil.rmtree(d, ignore_errors=True)
            deleted_count += 1
        except Exception as e:
            print(f"Error removing {d}: {e}")

    return deleted_count, reclaimed_bytes

def main():
    print(f"Scanning {CONTEXT_DIR}...")
    deleted, reclaimed = prune_transport_context(keep_count=5)
    print(f"Pruned {deleted} old turn context snapshots, reclaimed {reclaimed / (1024*1024):.2f} MB.")

if __name__ == "__main__":
    main()
