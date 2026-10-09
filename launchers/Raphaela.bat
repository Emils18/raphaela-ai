@echo off
title Raphaela Boot

echo.
echo   Starting Raphaela...
echo.

tasklist /FI "IMAGENAME eq ollama.exe" 2>NUL | find /I "ollama.exe" >NUL
if errorlevel 1 (
    echo   - Waking up Ollama...
    start "" /B ollama serve
    timeout /t 5 /nobreak >NUL
) else (
    echo   - Ollama already running.
)

netstat -an | find ":8000" | find "LISTENING" >NUL
if errorlevel 1 (
    echo   - Starting Raphaela backend...
    cd /d C:\PersonalAI\backend
    start "" /B venv\Scripts\pythonw.exe run.py
    timeout /t 6 /nobreak >NUL
) else (
    echo   - Backend already running.
)

echo   - Launching Raphaela UI...
start "" "C:\PersonalAI\frontend\build\windows\x64\runner\Release\frontend.exe"

timeout /t 2 /nobreak >NUL
exit