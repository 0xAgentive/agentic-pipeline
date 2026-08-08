@echo off
title Antigravity Companion Handoff Worker Launcher
echo ====================================================
echo Starting Antigravity Companion Handoff Worker Daemon
echo ====================================================
powershell -NoProfile -Command "Start-Process python -ArgumentList 'C:\Scripts\AntigravityProjects\companion-handoff\src\run_ag_handoff_worker.py' -WindowStyle Hidden"
echo Worker launched successfully in background mode!
timeout /t 3
