@echo off
pushd "%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File ".\watch-equations-v9-safe.ps1" %*
popd
pause
