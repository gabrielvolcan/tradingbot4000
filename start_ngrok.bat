@echo off
chcp 65001 > nul
title MalditoBot + ngrok
cd /d "%~dp0"

echo.
echo  ============================================================
echo    MalditoBot Dashboard - Acceso externo via ngrok
echo  ============================================================
echo.
echo  REQUISITO: ngrok instalado y configurado.
echo  Si no lo tienes:
echo    1. Ve a https://ngrok.com y crea cuenta gratis
echo    2. Descarga ngrok.exe y ponlo en esta carpeta
echo    3. Ejecuta: ngrok config add-authtoken TU_TOKEN
echo.

where ngrok >nul 2>&1
if %errorlevel% neq 0 (
    if exist ngrok.exe (
        set PATH=%PATH%;%~dp0
    ) else (
        echo  ERROR: ngrok no encontrado.
        echo  Coloca ngrok.exe en: %~dp0
        pause
        exit /b
    )
)

echo  Instalando dependencias Python...
pip install -r requirements.txt -q
echo.
echo  Iniciando servidor MalditoBot en segundo plano...
start "MalditoBot Server" /min python main.py

echo  Esperando inicio del servidor...
timeout /t 4 /nobreak > nul

echo.
echo  ============================================================
echo   Iniciando tunel ngrok...
echo   Busca la linea "Forwarding" - esa URL la compartes!
echo   Ejemplo: https://xxxx-xxxx.ngrok-free.app
echo  ============================================================
echo.
ngrok http 8000
