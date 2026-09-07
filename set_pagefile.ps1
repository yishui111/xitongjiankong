# Elevate-required: enlarge pagefile on D: to initial 32GB / max 48GB
$log = 'D:\xm\xitongjiankong\pagefile_result.txt'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile = $false}
    }
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'D:*' }
    if ($pf) {
        Set-CimInstance -InputObject $pf -Property @{InitialSize = [UInt32]32768; MaximumSize = [UInt32]49152}
    } else {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name = 'D:\pagefile.sys'; InitialSize = [UInt32]32768; MaximumSize = [UInt32]49152} | Out-Null
    }
    $chk = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like 'D:*' }
    "OK $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($chk.Name)  initial=$($chk.InitialSize)MB  max=$($chk.MaximumSize)MB" | Out-File $log -Encoding utf8
} catch {
    "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($_.Exception.Message)" | Out-File $log -Encoding utf8
}
