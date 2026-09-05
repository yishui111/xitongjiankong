# 供 server.py 调用：输出每个进程的显卡专用显存(MB)与 3D 引擎利用率(%)
# 输出格式：MEM|<pid>|<MB>  与  ENG|<pid>|<pct>
$ErrorActionPreference = "Stop"
$c = Get-Counter '\GPU Process Memory(*)\Dedicated Usage', '\GPU Engine(*engtype_3D)\Utilization Percentage'
foreach ($s in $c.CounterSamples) {
    if ($s.InstanceName -notmatch 'pid_(\d+)') { continue }
    $p = $Matches[1]
    if ($s.Path -match 'GPU Process Memory') {
        if ($s.CookedValue -gt 30MB) { "MEM|{0}|{1:F0}" -f $p, ($s.CookedValue / 1MB) }
    } else {
        "ENG|{0}|{1:F2}" -f $p, $s.CookedValue
    }
}
