#!/usr/bin/env python3
"""
finalize_v432.py — Wrapper forwarding to finalize_v434.py
"""
import os
import sys
import subprocess

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
V434_SCRIPT = os.path.join(BASE_DIR, "install", "finalize_v434.py")

if __name__ == "__main__":
    res = subprocess.run([sys.executable, V434_SCRIPT] + sys.argv[1:], cwd=BASE_DIR)
    sys.exit(res.returncode)
