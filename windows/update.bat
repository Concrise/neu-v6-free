@echo off
rem Apply a newly generated config (no admin needed). Double-click to run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %*
