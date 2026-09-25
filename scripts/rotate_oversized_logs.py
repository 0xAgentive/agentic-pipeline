import os
from pathlib import Path

logs_dir = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\logs")
for log_file in logs_dir.glob("*.log"):
    try:
        size = log_file.stat().st_size
        if size > 3 * 1024 * 1024:  # > 3 MB
            print(f"Rotating {log_file.name} ({size / (1024*1024):.2f} MB)...")
            old_file = log_file.with_name(log_file.name + ".old")
            try:
                # Read last 256 KB
                with open(log_file, "rb") as f:
                    if size > 256 * 1024:
                        f.seek(size - 256 * 1024)
                    tail = f.read()
                # Overwrite old file
                with open(old_file, "wb") as f_old:
                    f_old.write(tail)
                # Truncate active log
                with open(log_file, "wb") as f_curr:
                    f_curr.write(tail[-32768:])  # keep last 32 KB
                print(f"Rotated {log_file.name} successfully.")
            except Exception as e:
                print(f"Failed rotating {log_file.name}: {e}")
    except Exception as e:
        print(f"Error checking {log_file}: {e}")
