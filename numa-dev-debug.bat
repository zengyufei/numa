@echo off
setlocal
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%scripts\numa-dev-debug.ps1"
if not exist "%SCRIPT%" (
  echo Missing debug script: "%SCRIPT%"
  pause
  exit /b 1
)

net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%ROOT%' -Verb RunAs"
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -WorkingDirectory '%ROOT%' -Verb RunAs"
  )
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
echo.
echo Debug script exited with code %CODE%.
echo Press any key to close this window.
pause >nul
exit /b %CODE%
