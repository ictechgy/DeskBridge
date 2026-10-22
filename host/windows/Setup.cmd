@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Setup-DeskBridge.ps1"
if errorlevel 1 (
  echo Setup could not start. Downloaded ZIP scripts may be blocked by Windows. For a trusted source ZIP, review Properties - Unblock before extracting. If your organization requires signed scripts, use an approved signed build or contact your administrator.
  pause
)
