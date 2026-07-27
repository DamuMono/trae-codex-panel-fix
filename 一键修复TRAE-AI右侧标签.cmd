@echo off
"%SystemRoot%\System32\chcp.com" 65001 >nul
title TRAE AI Panel Fix
set "TRAE_EXE="
if defined TRAE_AI_FIX_EXE set "TRAE_EXE=%TRAE_AI_FIX_EXE%"
if exist "%~dp0Trae.exe" set "TRAE_EXE=%~dp0Trae.exe"
if exist "%~dp0Trae CN.exe" set "TRAE_EXE=%~dp0Trae CN.exe"
if not defined TRAE_EXE if exist "%~dp0..\Trae.exe" set "TRAE_EXE=%~dp0..\Trae.exe"
if not defined TRAE_EXE if exist "%~dp0..\Trae CN.exe" set "TRAE_EXE=%~dp0..\Trae CN.exe"
if not defined TRAE_EXE (
  echo TRAE was not found beside this tool or in its parent folder.
  set /p "TRAE_EXE=Paste the full path to Trae.exe or Trae CN.exe: "
)
set "TRAE_EXE=%TRAE_EXE:"=%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-trae-ai-panels.ps1" -TraeExe "%TRAE_EXE%" -ForceTraeRuntime
set "EXITCODE=%ERRORLEVEL%"
echo.
if %EXITCODE% EQU 0 (
  echo Fix completed. Restart TRAE or reload its window now.
) else (
  echo Fix failed. Exit code: %EXITCODE%
)
if defined TRAE_AI_FIX_NO_PAUSE exit /b %EXITCODE%
pause
exit /b %EXITCODE%
