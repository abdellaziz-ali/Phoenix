@echo off
REM Phoenix - Windows Migration Kit launcher
REM Uses Windows PowerShell 5.1 (always present on a fresh Win11) in STA mode for WPF.
REM Extra arguments are forwarded, e.g.:  Phoenix.cmd -Headless -Dest D:\Backups -Preset Developer -Update
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Phoenix.ps1" %*
set "RC=%ERRORLEVEL%"
echo %* | find /i "-Headless" >nul && goto :end
if not "%RC%"=="0" pause
:end
endlocal & exit /b %RC%
