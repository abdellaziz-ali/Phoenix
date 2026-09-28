@echo off
REM Phoenix - Windows Migration Kit launcher
REM Uses Windows PowerShell 5.1 (always present on a fresh Win11) in STA mode for WPF.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Phoenix.ps1"
if errorlevel 1 pause
endlocal
