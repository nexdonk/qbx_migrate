@echo off
title qbx_migrate panel
rem Starts the local control panel and opens it in your browser.
rem Keep this window open while you use the panel; close it to stop.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0panel\Panel.ps1" %*
if errorlevel 1 pause
