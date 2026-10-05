@echo off
pushd "%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File ".\watch-equations.ps1" %*
popd
pause
