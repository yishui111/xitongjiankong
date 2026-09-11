@echo off
cd /d "%~dp0"
set PY=%LOCALAPPDATA%\Programs\Python\Python310\sysmon_py.exe
if not exist "%PY%" set PY=python

rem 已在运行则直接打开页面
powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort 18123 -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if %errorlevel% equ 0 (
    echo 监控服务已在运行，直接打开页面...
    start "" http://127.0.0.1:18123/
    goto :startwatch
)

echo 正在启动系统监控（最小化窗口，关掉那个窗口即停止服务）...
start "sysmonitor" /min "%PY%" server.py --port 18123
ping -n 4 127.0.0.1 >nul

powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort 18123 -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if %errorlevel% neq 0 (
    echo.
    echo 启动失败！常见原因：
    echo   1. 内存不足（任务管理器看一下还有多少可用）
    echo   2. Python 环境异常
    echo 窗口保持打开，请截图反馈。
    pause
    exit /b 1
)

start "" http://127.0.0.1:18123/
echo 已启动，页面已在浏览器打开。

:startwatch
rem ---- watchdog 守护：每60秒巡检回收 D:\xm 闲置测试进程 ----
if exist "%~dp0watchdog_disabled.flag" del /q "%~dp0watchdog_disabled.flag"
powershell -NoProfile -Command "try { $s = Get-Content '%~dp0watchdog_status.json' -Raw | ConvertFrom-Json; if ($s.loop_pid -and (Get-Process -Id $s.loop_pid -ErrorAction SilentlyContinue)) { exit 0 } else { exit 1 } } catch { exit 1 }"
if %errorlevel% equ 0 (
    echo watchdog 守护已在运行，跳过重复启动。
    ping -n 2 127.0.0.1 >nul
    exit /b 0
)
powershell -NoProfile -Command "Start-Process powershell -WindowStyle Minimized -WorkingDirectory '%~dp0' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0watchdog.ps1','-Loop'"
echo watchdog 守护已启动（每60秒巡检+回收，动作记录见 watchdog.log）。
ping -n 2 127.0.0.1 >nul
