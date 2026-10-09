@echo off
start "Ollama" /min ollama serve
timeout /t 3 /nobreak >nul
cd /d C:\PersonalAI\backend
call venv\Scripts\activate
python run.py
