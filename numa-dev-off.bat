@echo off
setlocal
set "SCRIPT=%~dp0scripts\numa-dev-off.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0numa-dev-off.ps1"
net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -WorkingDirectory '%~dp0' -Verb RunAs"
  )
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
