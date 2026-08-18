@echo off
rem Установка и снятие HD-текстур для Dead Air x64.
rem
rem Положите этот файл и hd_install.ps1 в корень установленной игры
rem (туда, где database и fsgame.ltx) и запустите.
rem
rem Набор приезжает четырьмя частями. Оборванная загрузка продолжается
rem с того места, где встала: запустите заново, докачается только остаток.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hd_install.ps1"
