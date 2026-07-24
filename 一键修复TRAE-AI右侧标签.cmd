@chcp 65001 >nul
@title TRAE Codex + Claude 右侧标签修复
@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-trae-ai-panels.ps1"
@set EXITCODE=%ERRORLEVEL%
@echo.
@if %EXITCODE% EQU 0 (
  @echo 补丁及验证完成。请在 TRAE 中执行：开发人员: 重新加载窗口
) else (
  @echo 修复失败，错误代码：%EXITCODE%
)
@pause
@exit /b %EXITCODE%
