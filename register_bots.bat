@echo off
chcp 65001 > nul
title TradingBot 4000 - Registro de Bots
cd /d "%~dp0"
python register_bots.py
