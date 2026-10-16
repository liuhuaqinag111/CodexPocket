@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\windows\service.ps1" -Action status
set "RESULT=%ERRORLEVEL%"
pause
exit /b %RESULT%
