@echo off
setlocal
cd /d "%~dp0"

set "SCRIPT=%~dp0MapleStory_GPU_Seletor.ps1"

if not exist "%SCRIPT%" (
    echo [ERROR] MapleStory_GPU_Seletor.ps1 was not found next to this CMD file.
    echo Expected: "%SCRIPT%"
    pause
    exit /b 2
)

where pwsh.exe >nul 2>&1
if "%errorlevel%"=="0" (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
    where powershell.exe >nul 2>&1
    if not "%errorlevel%"=="0" (
        echo [ERROR] PowerShell was not found.
        pause
        exit /b 3
    )
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)

set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo MapleStory GPU Seletor exited with code %RC%.
    pause
)

exit /b %RC%