@echo off
rem Uninstall (keeps your rules; add -Purge to delete them). Double-click to run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
