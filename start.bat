@echo off
chcp 65001 > nul
title MalditoBot Dashboard
cd /d "%~dp0"

echo.
echo  ============================================
echo    MalditoBot Dashboard - Iniciando...
echo  ============================================
echo.
echo  Instalando dependencias...
pip install -r requirements.txt -q
echo  Dependencias OK
echo.
python main.py
pause
