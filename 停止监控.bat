@echo off
cd /d "%~dp0"
set FOUND=
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":18123" ^| findstr "LISTENING"') do (
    set FOUND=1
    echo 结束监控进程 PID %%a ...
    taskkill /F /PID %%a >nul 2>&1
)
if not defined FOUND echo 没有发现正在运行的监控服务。
if defined FOUND echo 监控服务已停止。

rem 停止 watchdog 守护并写禁用标记（防止定时巡查自动重启；下次启动监控会自动恢复）
type nul > "%~dp0watchdog_disabled.flag"
powershell -NoProfile -Command "try { $s = Get-Content '%~dp0watchdog_status.json' -Raw | ConvertFrom-Json; if ($s.loop_pid) { Stop-Process -Id $s.loop_pid -Force -ErrorAction SilentlyContinue } } catch {}"
echo watchdog 守护已停止（已写 watchdog_disabled.flag）。
pause
