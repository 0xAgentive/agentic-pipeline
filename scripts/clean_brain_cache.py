import os
import json
import time
from pathlib import Path

BRAIN_DIR = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\brain"))
CONFIG_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\companion_bridge_config.json"))

# Protected conversation IDs that must NEVER be touched
PROTECTED_CONVERSATIONS = {
    "b181c7df-b538-4519-96c8-589605172fdb",  # Current supervisor session
}

if CONFIG_PATH.is_file():
    try:
        cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        for comp in cfg.get("browser", {}).get("companions", {}).values():
            cid = comp.get("antigravityConversationId")
            if cid:
                PROTECTED_CONVERSATIONS.add(cid)
    except Exception:
        pass

def clean_old_brain_conversations(days_threshold: int = 14):
    if not BRAIN_DIR.is_dir():
        print("Brain directory not found.")
        return 0, 0

    now = time.time()
    cutoff_time = now - (days_threshold * 86400)
    
    files_cleaned = 0
    bytes_reclaimed = 0

    for conv_dir in BRAIN_DIR.iterdir():
        if not conv_dir.is_dir() or conv_dir.name in PROTECTED_CONVERSATIONS:
            continue
        
        # Check folder last modification time
        try:
            mtime = conv_dir.stat().st_mtime
            if mtime > cutoff_time:
                continue  # Recent conversation, keep as is
        except Exception:
            continue

        # Prune temporary files in old conversations:
        # 1. Old screenshot PNGs (> 50 KB)
        for png in conv_dir.glob("*.png"):
            try:
                sz = png.stat().st_size
                if sz > 50 * 1024:
                    png.unlink()
                    files_cleaned += 1
                    bytes_reclaimed += sz
            except Exception:
                pass

        # 2. .user_uploaded directory
        user_up = conv_dir / ".user_uploaded"
        if user_up.is_dir():
            for f in user_up.iterdir():
                try:
                    if f.is_file():
                        sz = f.stat().st_size
                        f.unlink()
                        files_cleaned += 1
                        bytes_reclaimed += sz
                except Exception:
                    pass

        # 3. scratch directory
        scratch = conv_dir / "scratch"
        if scratch.is_dir():
            for f in scratch.iterdir():
                try:
                    if f.is_file():
                        sz = f.stat().st_size
                        f.unlink()
                        files_cleaned += 1
                        bytes_reclaimed += sz
                except Exception:
                    pass

        # 4. transcript_full.jsonl (leave compact transcript.jsonl intact!)
        full_trans = conv_dir / ".system_generated" / "logs" / "transcript_full.jsonl"
        if full_trans.is_file():
            try:
                sz = full_trans.stat().st_size
                if sz > 500 * 1024:  # > 500 KB
                    full_trans.unlink()
                    files_cleaned += 1
                    bytes_reclaimed += sz
            except Exception:
                pass

    return files_cleaned, bytes_reclaimed

def main():
    print(f"Cleaning brain cache for conversations older than 14 days (protected: {len(PROTECTED_CONVERSATIONS)})...")
    cleaned, bytes_rec = clean_old_brain_conversations(days_threshold=14)
    print(f"Cleaned {cleaned} files, reclaimed {bytes_rec / (1024*1024):.2f} MB.")

if __name__ == "__main__":
    main()
