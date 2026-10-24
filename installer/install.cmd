@echo off
rem Installs the Russian - QWERTY (Mac) keyboard layout. Double-click to run.
setlocal
set "NoDefaultCurrentDirectoryInExePath=1"
if not exist "%~dp0Install.ps1" (
    echo Install.ps1 was not found next to %~nx0. Extract the whole zip to a folder first.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
if %errorlevel% neq 0 (
    echo.
    echo Installation failed.
    pause
    exit /b 1
)
pause
