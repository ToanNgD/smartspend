@echo off
chcp 65001 >nul
title SmartSpend server
cd /d "%~dp0server"
echo Dang khoi dong server SmartSpend... (dong cua so nay = tat server)
dart run bin/server.dart
pause
