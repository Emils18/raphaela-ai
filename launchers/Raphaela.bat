@echo off
title Raphaela Boot

echo.
echo   Starting Raphaela...
echo.

REM --- Ollama ---
tasklist /FI "IMAGENAME eq ollama.exe" 2>NUL | find /I "ollama.exe" >NUL
if errorlevel 1 (
    echo   - Waking up Ollama...
    start "" /B ollama serve
    timeout /t 5 /nobreak >NUL
) else (
    echo   - Ollama already awake.
)

REM --- Backend (in its own minimized window so it survives) ---
netstat -an | find ":8000" | find "LISTENING" >NUL
if errorlevel 1 (
    echo   - Starting backend...
    start "Raphaela Backend" /MIN cmd /c "cd /d C:\PersonalAI\backend && venv\Scripts\python.exe run.py > backend.log 2>&1"
) else (
    echo   - Backend already running.
)

REM --- Wait ~25s for Whisper + Ollama to warm up ---
echo   - Warming up...
timeout /t 25 /nobreak >NUL
echo   - Ready.

REM --- UI ---
echo   - Opening Raphaela...
start "" "C:\PersonalAI\frontend\build\windows\x64\runner\Release\frontend.exe"

timeout /t 2 /nobreak >NUL
exit