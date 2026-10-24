@echo off
rem First-time install (asks for admin once). Double-click to run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
