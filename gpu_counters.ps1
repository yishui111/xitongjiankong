# 供 server.py / watchdog.ps1 调用：输出每个进程的显卡专用显存(MB)与引擎利用率(%)
# 引擎同时采集 3D 与 Cuda：AI 计算任务走 Cuda 引擎，只看 3D 会把计算任务误判为空闲
# 输出格式：MEM|<pid>|<MB>  与  ENG|<pid>|<pct>
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$c = Get-Counter '\GPU Process Memory(*)\Dedicated Usage', '\GPU Engine(*engtype_3D)\Utilization Percentage', '\GPU Engine(*engtype_Cuda)\Utilization Percentage'
foreach ($s in $c.CounterSamples) {
    if ($s.InstanceName -notmatch 'pid_(\d+)') { continue }
    $p = $Matches[1]
    if ($s.Path -match 'GPU Process Memory') {
        if ($s.CookedValue -gt 30MB) { "MEM|{0}|{1:F0}" -f $p, ($s.CookedValue / 1MB) }
    } else {
        "ENG|{0}|{1:F2}" -f $p, $s.CookedValue
    }
}
