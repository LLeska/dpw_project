@echo off
pushd "%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch-equations.ps1" %*
set "watchExitCode=%errorlevel%"
popd
pause
exit /b %watchExitCode%
