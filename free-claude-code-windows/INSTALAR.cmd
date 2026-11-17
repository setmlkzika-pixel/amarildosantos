@echo off
REM Executa o instalador do Free Claude Code (nao precisa ser administrador)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-FreeClaudeCode.ps1" %*
echo.
pause
