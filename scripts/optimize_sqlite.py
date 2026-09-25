import sqlite3
import os
from pathlib import Path

db_path = Path(os.path.expandvars(r"%USERPROFILE%\.agentic-pipeline\action-bridge\transport.sqlite3"))
if db_path.is_file():
    print(f"Optimizing {db_path} (current size: {db_path.stat().st_size / (1024*1024):.2f} MB)...")
    conn = sqlite3.connect(str(db_path), timeout=10)
    cur = conn.cursor()
    
    mode = cur.execute("PRAGMA journal_mode=WAL;").fetchone()[0]
    print(f"journal_mode set to: {mode}")
    
    cur.execute("PRAGMA synchronous=NORMAL;")
    cur.execute("PRAGMA busy_timeout=5000;")
    print("synchronous set to NORMAL, busy_timeout set to 5000.")
    
    print("Running VACUUM...")
    cur.execute("VACUUM;")
    conn.close()
    
    print(f"Optimized size: {db_path.stat().st_size / (1024*1024):.2f} MB")
else:
    print(f"Database {db_path} not found.")
