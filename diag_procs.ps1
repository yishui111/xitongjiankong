# 临时诊断: 列出受监控盘符(D:\ E:\ G:\)下测试进程的启动时间、父进程、命令行
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$all = Get-CimInstance Win32_Process
$roots = @("D:\", "E:\", "G:\")
$rows = foreach ($p in $all) {
    $exe = "" + $p.ExecutablePath
    $cmd = "" + $p.CommandLine
    $isXm = $false
    foreach ($r in $roots) { if ($exe -like ($r + "*") -or $cmd -like ("*" + $r + "*")) { $isXm = $true; break } }
    if (-not $isXm) { continue }
    if ($exe -like "*xitongjiankong*" -or $cmd -like "*xitongjiankong*") { continue }
    $pp = $all | Where-Object { $_.ProcessId -eq $p.ParentProcessId } | Select-Object -First 1
    $parentDesc = "$($p.ParentProcessId) <dead>"
    if ($pp) { $parentDesc = "$($pp.ProcessId) $($pp.Name)" }
    $cmdShort = ($cmd -replace "\s+", " ")
    if ($cmdShort.Length -gt 160) { $cmdShort = $cmdShort.Substring(0, 160) + "..." }
    [PSCustomObject]@{
        Start  = $p.CreationDate.ToString("MM-dd HH:mm:ss")
        PID    = $p.ProcessId
        Name   = $p.Name
        Parent = $parentDesc
        RamMB  = [int]((Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).WorkingSet64 / 1MB)
        Cmd    = $cmdShort
    }
}
$rows | Sort-Object Start -Descending | Format-Table PID, Start, Name, Parent, RamMB -AutoSize | Out-String -Width 200
$rows | Sort-Object Start -Descending | ForEach-Object { "PID $($_.PID) [$($_.Name)] <- $($_.Parent)`n    $($_.Cmd)`n" }
