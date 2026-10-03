@echo off
REM Script to run eve-maj-preview.exe with console output visible
REM Keeps console open after crash or exit

cd /d "%~dp0"

echo Starting EVE-Maj Preview...
echo.

REM Check if exe exists in current directory first (if running from bin folder)
if exist "eve-maj-preview.exe" (
    set "EXE_PATH=eve-maj-preview.exe"
) else if exist "zig-out\bin\eve-maj-preview.exe" (
    set "EXE_PATH=zig-out\bin\eve-maj-preview.exe"
) else (
    echo ERROR: eve-maj-preview.exe not found
    echo Please build the project first with 'zig build'
    echo.
    pause
    exit /b 1
)

echo Running: %EXE_PATH%
echo.

REM Run the exe
"%EXE_PATH%"

echo.
echo ----------------------------------------
if %ERRORLEVEL% EQU 0 (
    echo Program exited normally
) else (
    echo Program crashed or exited with error code: %ERRORLEVEL%
)
echo ----------------------------------------
echo.

pause
