# watchdog.ps1 - 系统与显卡守护（垃圾回收机制）
#
# 用法:
#   单次检查+清理:  powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1
#   常驻守护循环:   powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1 -Loop
#
# 只针对 D:\xm 下的"测试遗留进程"(python/java/node 等)，监控工具自身与常用软件绝不清理:
#   规则1) 内存或显存超过触发阈值(param 区可调，当前 80%/85%)时，逐个结束"空闲"的
#          测试进程(单核CPU<2% 且 GPU<5%)，直到内存 < 目标阈值，显存占用大的优先
#   规则2) 测试进程持续空闲 >= 120 分钟，即使不超标也结束(防驻留)
#   规则3) 所有结束动作写入 watchdog.log，最新状态写入 watchdog_status.json 供巡查
#   原则: 绝不结束"正在干活"的进程(占CPU或占GPU的视为正在测试)，只回收闲着不用的

param(
    [switch]$Loop,
    [int]$IntervalSec = 60,
    [int]$MemActPercent = 80,
    [int]$MemTargetPercent = 82,
    [int]$VramActPercent = 85,
    [int]$IdleKillMinutes = 120,
    [double]$IdleCpuPercent = 2.0,
    [double]$IdleGpuPercent = 5.0
)

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$BaseDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile    = Join-Path $BaseDir "watchdog.log"
$StateFile  = Join-Path $BaseDir "watchdog_state.json"
$StatusFile = Join-Path $BaseDir "watchdog_status.json"
$FlagFile   = Join-Path $BaseDir "watchdog_disabled.flag"
$Counters   = Join-Path $BaseDir "gpu_counters.ps1"

$ProjectRoot  = "d:\xm\"
$SelfMarker   = "\xm\xitongjiankong\"
$Interpreters = @("python.exe", "pythonw.exe", "java.exe", "javaw.exe", "node.exe")

function Write-Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    try {
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 512KB) {
            Move-Item -Force $LogFile ($LogFile + ".old")
        }
    } catch {}
}

function Get-RamStatus {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalKB = [double]$os.TotalVisibleMemorySize
    $freeKB  = [double]$os.FreePhysicalMemory
    return @{
        UsedGB  = [math]::Round(($totalKB - $freeKB) / 1MB, 1)
        TotalGB = [math]::Round($totalKB / 1MB, 1)
        Percent = [math]::Round(100.0 * ($totalKB - $freeKB) / $totalKB, 1)
    }
}

function Get-GpuStatus {
    $out = & nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null
    if (-not $out) { return $null }
    $p = ($out | Select-Object -First 1) -split "\s*,\s*"
    if ($p.Count -lt 4) { return $null }
    return @{
        UsedMB   = [double]$p[0]
        TotalMB  = [double]$p[1]
        Percent  = [math]::Round(100.0 * [double]$p[0] / [math]::Max([double]$p[1], 1), 1)
        Util     = [double]$p[2]
        Temp     = [double]$p[3]
    }
}

function Get-GpuPerPid {
    # 复用 gpu_counters.ps1，输出 MEM|pid|MB 与 ENG|pid|pct
    # 注意: ENG 行几乎总是存在(全是0也算)，所以必须以"有没有 MEM 行"判断采样成败，
    # MEM 行只在有进程占用 >30MB 显存时才输出；偶发采不到就重试一次
    $vram = @{}; $eng = @{}
    $out = @()
    foreach ($attempt in 1..2) {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Counters 2>$null
        if (@($out | Where-Object { "$_" -match "^MEM\|" }).Count -gt 0) { break }
        Start-Sleep -Seconds 1
    }
    foreach ($line in @($out)) {
        $parts = ("$line").Trim() -split "\|"
        if ($parts.Count -ne 3) { continue }
        $procId = 0; $val = 0.0
        if (-not [int]::TryParse($parts[1], [ref]$procId)) { continue }
        if (-not [double]::TryParse($parts[2], [ref]$val)) { continue }
        if ($parts[0] -eq "MEM") { $vram[$procId] = $val }
        elseif ($parts[0] -eq "ENG") { $eng[$procId] = $eng[$procId] + $val }
    }
    return @{ Vram = $vram; Eng = $eng; MemData = ($vram.Count -gt 0) }
}

function Get-Candidates {
    # 测试遗留进程: 可执行文件位于 D:\xm 下(排除监控工具自身)，
    # 或解释器进程(python/java/node)的命令行引用了 D:\xm 下的脚本
    $result = @()
    foreach ($p in Get-CimInstance Win32_Process) {
        $exe = ""; if ($p.ExecutablePath) { $exe = $p.ExecutablePath.ToLower() }
        $cmd = ""; if ($p.CommandLine)    { $cmd = $p.CommandLine.ToLower() }
        $name = ($p.Name + "").ToLower()
        # 排除：知音主系统(duihuamoxing)的常驻服务（TTS/数字人/网关/WebUI）
        # 不是测试遗留，永不回收（2026-09-08，与 duihuamoxing 会话协商加入）
        if ($cmd -match "duihuamoxing") { continue }
        if ($exe -match "duihuamoxing") { continue }

        $byExe = $exe.StartsWith($ProjectRoot) -and -not $exe.StartsWith($SelfMarker)
        $byCmd = ($Interpreters -contains $name) -and $cmd.Contains("\xm\") -and -not $cmd.Contains($SelfMarker)
        if (-not ($byExe -or $byCmd)) { continue }
        $proj = ""
        if ($cmd -match "\\xm\\([^\\]+)") { $proj = $Matches[1] }
        elseif ($exe -match "\\xm\\([^\\]+)") { $proj = $Matches[1] }
        $result += [pscustomobject]@{
            # Pid 必须统一转 int：CIM 的 ProcessId 是 UInt32，而 gpu_counters 解析出的
            # 键是 Int32，哈希表按类型匹配，不转的话 VRAM/GPU 占用永远查不到
            Pid = [int]$p.ProcessId; Name = $p.Name; Exe = $p.ExecutablePath
            Cmd = $p.CommandLine; Project = $proj; Created = $p.CreationDate
        }
    }
    return $result
}

function Invoke-Cycle {
    $now = Get-Date
    $nowStr = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $report = New-Object System.Collections.Generic.List[string]
    $killed = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $ram = Get-RamStatus
    $gpu = Get-GpuStatus
    $gp  = Get-GpuPerPid
    $vramLine = "显存: N/A"
    if ($gpu) { $vramLine = "显存: {0}/{1} MB ({2}%)" -f $gpu.UsedMB, $gpu.TotalMB, $gpu.Percent }

    # --- 找出候选测试进程并采样 CPU ---
    $cands = Get-Candidates
    $cpu1 = @{}
    foreach ($c in $cands) {
        $proc = Get-Process -Id $c.Pid -ErrorAction SilentlyContinue
        if ($proc -and $proc.TotalProcessorTime) { $cpu1[$c.Pid] = $proc.TotalProcessorTime.TotalSeconds }
    }
    Start-Sleep -Seconds 2

    # --- 载入空闲追踪状态 ---
    $state = @{}
    try {
        $raw = Get-Content $StateFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
    } catch {}

    $tracked = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cands) {
        $proc = Get-Process -Id $c.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }   # 采样期间退出了
        $ramMB = [math]::Round($proc.WorkingSet64 / 1MB, 0)
        $vramMB = 0.0; if ($gp.Vram.ContainsKey($c.Pid)) { $vramMB = [math]::Round($gp.Vram[$c.Pid], 0) }
        $engPct = 0.0; if ($gp.Eng.ContainsKey($c.Pid))  { $engPct = [math]::Round($gp.Eng[$c.Pid], 1) }

        $cpuPct = 0.0
        if ($cpu1.ContainsKey($c.Pid) -and $proc.TotalProcessorTime) {
            $delta = $proc.TotalProcessorTime.TotalSeconds - $cpu1[$c.Pid]
            $cpuPct = [math]::Round($delta / 2.0 * 100.0, 1)
        }

        $key = [string]$c.Pid
        $createdStr = ""
        if ($c.Created) { $createdStr = $c.Created.ToString("yyyy-MM-dd HH:mm:ss") }
        $entry = $state[$key]
        if (-not $entry -or $entry.created -ne $createdStr -or $entry.exe -ne $c.Exe) {
            $entry = New-Object PSObject -Property @{ name = $c.Name; exe = $c.Exe; created = $createdStr; first_seen = $nowStr; last_active = $nowStr }
        }
        if ($cpuPct -gt $IdleCpuPercent -or $engPct -gt $IdleGpuPercent) { $entry.last_active = $nowStr }
        $state[$key] = $entry

        $idleMin = 0.0
        try { $idleMin = [math]::Round(($now - [datetime]::Parse($entry.last_active)).TotalMinutes, 0) } catch {}
        $tracked += [pscustomobject]@{
            Pid = $c.Pid; Name = $c.Name; Exe = $c.Exe; Project = $c.Project
            RamMB = $ramMB; VramMB = $vramMB; EngPct = $engPct; CpuPct = $cpuPct
            IdleMin = $idleMin; Key = $key; CreatedStr = $createdStr
        }
    }

    # 状态里已消失的 pid 顺手清掉，避免无限膨胀
    $aliveKeys = $tracked | ForEach-Object { $_.Key }
    $state = ($state.GetEnumerator() | Where-Object { $aliveKeys -contains $_.Key })
    $stateTable = @{}
    foreach ($kv in $state) { $stateTable[$kv.Key] = $kv.Value }

    $tracked = $tracked | Sort-Object -Property @{ Expression = "VramMB"; Descending = $true }, @{ Expression = "RamMB"; Descending = $true }

    $report += ("==== 系统守护检查 {0} ====" -f $nowStr)
    $report += ("内存: {0}/{1} GB ({2}%) | {3}" -f $ram.UsedGB, $ram.TotalGB, $ram.Percent, $vramLine)
    if ($gpu) { $report += ("GPU 利用率: {0}%  温度: {1}C" -f $gpu.Util, $gpu.Temp) }

    if ($tracked.Count -gt 0) {
        $report += ("测试进程 {0} 个:" -f $tracked.Count)
        foreach ($t in $tracked) {
            $report += ("  PID {0} [{1}] {2}  RAM {3}MB  VRAM {4}MB  CPU {5}%  GPU {6}%  空闲 {7} 分钟" -f `
                $t.Pid, $t.Project, $t.Name, $t.RamMB, $t.VramMB, $t.CpuPct, $t.EngPct, $t.IdleMin)
        }
    } else {
        $report += "测试进程: 无"
    }

    # --- 全局内存 Top3（供排查，不一定可清理） ---
    $tops = Get-Process | Where-Object { $_.Id -ne 0 -and $_.WorkingSet64 -gt 200MB } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 3
    if ($tops) {
        $report += ("全系统内存 Top3: " + (($tops | ForEach-Object { "{0}(PID {1}) {2}MB" -f $_.ProcessName, $_.Id, [math]::Round($_.WorkingSet64 / 1MB, 0) }) -join " | "))
    }

    # --- 决定清理 ---
    $breachMem = $ram.Percent -ge $MemActPercent
    $breachVram = $false; if ($gpu) { $breachVram = $gpu.Percent -ge $VramActPercent }

    function Kill-One([object]$t, [string]$reason) {
        taskkill /F /T /PID $t.Pid 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
        $gone = -not (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue)
        if ($gone) {
            $msg = "已结束 PID {0} [{1}] {2} — {3}, 释放 RAM {4}MB / VRAM {5}MB" -f $t.Pid, $t.Project, $t.Name, $reason, $t.RamMB, $t.VramMB
            $killed.Add($msg)
            Write-Log $msg
            $stateTable.Remove($t.Key)
        } else {
            $msg = "结束 PID {0} 失败(可能权限不足)" -f $t.Pid
            $warnings.Add($msg)
            Write-Log $msg
        }
    }

    if ($tracked.Count -gt 0) {
        # 规则2: 长时间空闲的先收
        foreach ($t in @($tracked | Where-Object { $_.IdleMin -ge $IdleKillMinutes })) {
            if ((Get-Process -Id $t.Pid -ErrorAction SilentlyContinue)) {
                Kill-One $t ("持续空闲 {0} 分钟(防驻留回收)" -f $t.IdleMin)
            }
        }

        # 规则1: 内存/显存超标时，继续收空闲进程直到达标
        if ($ram.Percent -ge $MemActPercent) {
            foreach ($t in @($tracked | Where-Object { $_.IdleMin -lt $IdleKillMinutes })) {
                $ram2 = Get-RamStatus
                if ($ram2.Percent -lt $MemTargetPercent) { break }
                if (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue) {
                    Kill-One $t ("内存 {0}% 超标, 回收空闲进程" -f $ram2.Percent)
                }
            }
            $ram = Get-RamStatus
            if ($ram.Percent -ge $MemActPercent) {
                $top1 = $tops | Select-Object -First 1
                $warnings += ("内存回收后仍 {0}%：最大占用为 {1}(PID {2}) {3}MB — 非测试遗留进程，未自动清理，请人工确认" -f `
                    $ram.Percent, $top1.ProcessName, $top1.Id, [math]::Round($top1.WorkingSet64 / 1MB, 0))
                Write-Log $warnings[-1]
            }
        }
        if ($gpu -and $gpu.Percent -ge $VramActPercent -and -not $gp.MemData) {
            $warnings += ("显存 {0}% 超标但未能采样到每进程显存数据，本轮无法定位/回收占用者，请人工排查" -f $gpu.Percent)
            Write-Log $warnings[-1]
        }
        if ($gpu -and $gpu.Percent -ge $VramActPercent) {
            foreach ($t in @($tracked | Where-Object { $_.IdleMin -lt $IdleKillMinutes -and $_.VramMB -ge 100 })) {
                $gpu2 = Get-GpuStatus
                if (-not $gpu2 -or $gpu2.Percent -lt $VramActPercent) { break }
                if (Get-Process -Id $t.Pid -ErrorAction SilentlyContinue) {
                    Kill-One $t ("显存 {0}% 超标, 回收空闲进程" -f $gpu2.Percent)
                }
            }
        }
    }

    # --- 落盘状态与输出 ---
    $stateTable | ConvertTo-Json -Depth 4 | Out-File $StateFile -Encoding utf8

    if ($killed.Count -gt 0) { $report += "清理动作:"; foreach ($k in $killed) { $report += ("  [OK] " + $k) } }
    else { $report += "清理动作: 本轮无需清理" }
    if ($warnings.Count -gt 0) { $report += "警告:"; foreach ($w in $warnings) { $report += ("  [!] " + $w) } }

    $gpuStatusOut = $null
    if ($gpu) {
        $gpuStatusOut = @{ used_mb = $gpu.UsedMB; total_mb = $gpu.TotalMB; percent = $gpu.Percent; util = $gpu.Util; temp = $gpu.Temp }
    }
    $status = [pscustomobject]@{
        time = $nowStr
        loop = [bool]$Loop
        loop_pid = $PID
        ram = @{ used_gb = $ram.UsedGB; total_gb = $ram.TotalGB; percent = $ram.Percent }
        gpu = $gpuStatusOut
        candidate_count = $tracked.Count
        killed = $killed
        warnings = $warnings
    }
    $status | ConvertTo-Json -Depth 5 | Out-File $StatusFile -Encoding utf8

    if ($Loop) {
        Write-Log ("巡检: 内存 {0}% 显存 {1}% 测试进程 {2} 个 结束 {3} 个" -f `
            $ram.Percent, $(if ($gpu) { $gpu.Percent } else { "N/A" }), $tracked.Count, $killed.Count)
    }
    return ,$report
}

# --- 常驻循环模式 ---
if ($Loop) {
    if (Test-Path $FlagFile) {
        Write-Output "检测到 watchdog_disabled.flag（用户已主动停止守护），不启动。退出。"
        exit 0
    }
    # 单实例: 上一次的 loop 进程还活着就不重复启动
    try {
        $prev = Get-Content $StatusFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($prev.loop -and $prev.loop_pid) {
            $alive = Get-Process -Id $prev.loop_pid -ErrorAction SilentlyContinue
            if ($alive -and $alive.ProcessName -match "powershell|pwsh") {
                Write-Output ("watchdog 已在运行 (PID {0})，本实例退出。" -f $prev.loop_pid)
                exit 0
            }
        }
    } catch {}
    Write-Log ("守护循环启动 (PID {0}, 每 {1}s 巡检一次)" -f $PID, $IntervalSec)
    while ($true) {
        try { Invoke-Cycle | Out-Null } catch { Write-Log ("巡检异常: " + $_.Exception.Message) }
        Start-Sleep -Seconds $IntervalSec
    }
    exit 0
}

# --- 单次模式: 打印报告 ---
Invoke-Cycle | ForEach-Object { $_ }
