# watchdog_keepalive.ps1 - 守护循环自愈任务（每5分钟由计划任务 WatchdogKeepAlive 调用）
# 职责: 发现 watchdog.ps1 -Loop 不在运行且未被用户主动停用(watchdog_disabled.flag)时, 重新拉起守护循环。
# 规则: 存在禁用标记时绝不启动; 已有循环在跑时不重复启动。
$ErrorActionPreference = "SilentlyContinue"
$BaseDir   = "D:\xm\xitongjiankong"
$FlagFile  = Join-Path $BaseDir "watchdog_disabled.flag"
$LogFile   = Join-Path $BaseDir "watchdog.log"

if (Test-Path $FlagFile) { exit 0 }

$loop = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'watchdog\.ps1' -and $_.CommandLine -match '-Loop' -and $_.ProcessId -ne $PID }
if ($loop) { exit 0 }

Start-Process powershell -WindowStyle Minimized -WorkingDirectory $BaseDir `
    -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $BaseDir 'watchdog.ps1'),'-Loop'
$line = "{0} [keepalive] 守护循环不在运行, 已自动重新拉起" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Add-Content -Path $LogFile -Value $line -Encoding UTF8
