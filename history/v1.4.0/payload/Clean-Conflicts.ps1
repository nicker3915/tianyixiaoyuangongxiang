param(
    [switch]$Interactive,
    [switch]$Silent
)

$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$resultFile = Join-Path $root 'clean-conflicts-result.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (!$isAdmin) {
    $ps = (Join-Path $PSHOME 'powershell.exe')
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Interactive) { $argList += ' -Interactive' }
    if ($Silent) { $argList += ' -Silent' }
    $p = Start-Process $ps -Verb RunAs -ArgumentList $argList -PassThru -WindowStyle $(if ($Interactive) { 'Normal' } else { 'Hidden' })
    $p.WaitForExit()
    exit $p.ExitCode
}

$summary = [ordered]@{
    Time = [DateTimeOffset]::Now.ToString('o')
    Success = $true
    KilledProcesses = @()
    RemovedTasks = @()
    FreedPorts = @()
    RemovedRoutes = @()
    CleanedFiles = @()
    Message = ''
}

# 1. 扫描并终止冲突或残留进程
$targetProcNames = @(
    'ESurfingClient-2.2.0-r4-windows-x86_64',
    'CampusQuietLauncher',
    'CampusNetwork-AutoConnect'
)
foreach ($procName in $targetProcNames) {
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            $pId = $p.Id
            $pPath = $p.Path
            $p.Kill()
            [void]$p.WaitForExit(3000)
            $summary.KilledProcesses += [pscustomobject]@{ Id = $pId; Name = $procName; Path = $pPath }
        } catch { }
    }
}

# 2. 扫描并终止占用特定管理端口 (8888, 18888-18918) 的非系统残留进程
$portsToCheck = @(8888) + (18888..18918)
$occupied = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in $portsToCheck })
foreach ($conn in $occupied) {
    try {
        $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -notmatch '(?i)system|svchost|idle') {
            $pId = $p.Id
            $pName = $p.ProcessName
            $p.Kill()
            [void]$p.WaitForExit(3000)
            $summary.FreedPorts += [pscustomobject]@{ Port = $conn.LocalPort; ProcessId = $pId; ProcessName = $pName }
        }
    } catch { }
}

# 3. 扫描并清理旧版和冲突的计划任务
$taskNames = @(
    'CampusNetwork-AutoConnect',
    'CampusNetwork-AutoConnect-Watchdog',
    'GDPortalShare-Logon',
    'GDPortalShare-Logon-Watchdog'
)
foreach ($tName in $taskNames) {
    $t = Get-ScheduledTask -TaskPath '\' -TaskName $tName -ErrorAction SilentlyContinue
    if ($t) {
        try {
            Disable-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue | Out-Null
            Unregister-ScheduledTask -InputObject $t -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $summary.RemovedTasks += $tName
        } catch { }
    }
}
# 检索所有指向 CampusQuietLauncher 或 CampusNetwork-Autostart 的其他计划任务
$allTasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue)
foreach ($t in $allTasks) {
    $acts = @($t.Actions)
    foreach ($a in $acts) {
        if ($a.Execute -match '(?i)CampusQuietLauncher|CampusNetwork-Autostart') {
            if ($t.TaskName -notin $summary.RemovedTasks) {
                try {
                    Disable-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue | Out-Null
                    Unregister-ScheduledTask -InputObject $t -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    $summary.RemovedTasks += $t.TaskName
                } catch { }
            }
        }
    }
}

# 4. 清理旧版 ProgramData 冲突标记和残留锁文件
$legacyDir = Join-Path $env:ProgramData 'CampusNetwork-Autostart'
if (Test-Path -LiteralPath $legacyDir) {
    $marker = Join-Path $legacyDir 'installation-marker.json'
    if (Test-Path -LiteralPath $marker) {
        try {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $summary.CleanedFiles += $marker
        } catch { }
    }
    $flags = Get-ChildItem -Path $legacyDir -Filter '*.flag' -ErrorAction SilentlyContinue
    foreach ($f in $flags) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            $summary.CleanedFiles += $f.FullName
        } catch { }
    }
}

# 清理当前目录临时锁与标志文件
$currentFlags = @(
    (Join-Path $root 'watchdog-paused.flag'),
    (Join-Path $root 'uninstall-in-progress.flag'),
    (Join-Path $root 'hotspot-owner.json')
)
foreach ($f in $currentFlags) {
    if (Test-Path -LiteralPath $f) {
        try {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            $summary.CleanedFiles += $f
        } catch { }
    }
}
$tmpFiles = Get-ChildItem -Path $root -Filter '*.tmp' -ErrorAction SilentlyContinue
foreach ($f in $tmpFiles) {
    try {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $summary.CleanedFiles += $f.FullName
    } catch { }
}

# 5. 清理残留的认证 IP /32 路由
$authTargets = @(
    '183.61.185.93','125.88.255.53','202.69.4.32','220.181.104.183',
    '125.88.59.131','61.140.12.23','14.146.227.141','121.8.177.212','8.8.8.8'
)
foreach ($ip in $authTargets) {
    $prefix = $ip + '/32'
    $routes = @(Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach ($rt in $routes) {
        try {
            Remove-NetRoute -DestinationPrefix $rt.DestinationPrefix -InterfaceIndex $rt.InterfaceIndex -NextHop $rt.NextHop -Confirm:$false -ErrorAction SilentlyContinue
            $summary.RemovedRoutes += [pscustomobject]@{ Prefix = $prefix; InterfaceIndex = $rt.InterfaceIndex; NextHop = $rt.NextHop }
        } catch { }
    }
}

# 6. 重置网络适配器 Metric 为自动
$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
foreach ($ad in $adapters) {
    try {
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    } catch { }
}

# 7. 重置可能卡死的移动热点
try {
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $profiles = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
    foreach ($prof in $profiles) {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($prof)
        if ($mgr -and $mgr.TetheringOperationalState -eq 'On') {
            $asyncOp = $mgr.StopTetheringAsync()
            $action = [System.WindowsRuntimeSystemExtensions]::AsTask($asyncOp)
            [void]$action.Wait(5000)
        }
    }
} catch { }

# 8. 恢复官方客户端自启动与服务配置（如存在）
$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\ESurfingSvr'
try {
    $svc = Get-ItemProperty -LiteralPath $svcKey -ErrorAction SilentlyContinue
    if ($svc -and (Get-Service ESurfingSvr -ErrorAction SilentlyContinue)) {
        Set-Service ESurfingSvr -StartupType Automatic -ErrorAction SilentlyContinue
    }
} catch { }

# 9. 生成总结消息
$msgParts = @()
if ($summary.KilledProcesses.Count -gt 0) {
    $msgParts += ("已结束 " + $summary.KilledProcesses.Count + " 个残留/冲突进程")
}
if ($summary.RemovedTasks.Count -gt 0) {
    $msgParts += ("已清理 " + $summary.RemovedTasks.Count + " 个旧版计划任务")
}
if ($summary.FreedPorts.Count -gt 0) {
    $msgParts += ("已释放 " + $summary.FreedPorts.Count + " 个占用端口")
}
if ($summary.RemovedRoutes.Count -gt 0) {
    $msgParts += ("已清理 " + $summary.RemovedRoutes.Count + " 条旧路由")
}
if ($summary.CleanedFiles.Count -gt 0) {
    $msgParts += ("已删除 " + $summary.CleanedFiles.Count + " 个残留标记与锁")
}

if ($msgParts.Count -eq 0) {
    $summary.Message = '未发现任何残留冲突程序或锁定，系统环境干净就绪！'
} else {
    $summary.Message = '清理完成：' + ($msgParts -join '，') + '。环境已恢复干净，可正常使用！'
}

# 写入结果文件供主面板读取
try {
    [IO.File]::WriteAllText($resultFile, (ConvertTo-Json -InputObject $summary -Depth 5), [Text.UTF8Encoding]::new($false))
} catch { }

if ($Interactive) {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "         校园网共享助手 · 冲突与残留清理结果       " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host $summary.Message -ForegroundColor Green
    Write-Host ""
    if ($summary.KilledProcesses.Count -gt 0) {
        Write-Host "【终止的进程】" -ForegroundColor Yellow
        $summary.KilledProcesses | ForEach-Object { Write-Host ("  - PID " + $_.Id + ": " + $_.Name + " (" + $_.Path + ")") }
    }
    if ($summary.RemovedTasks.Count -gt 0) {
        Write-Host "【清理的计划任务】" -ForegroundColor Yellow
        $summary.RemovedTasks | ForEach-Object { Write-Host ("  - " + $_) }
    }
    if ($summary.FreedPorts.Count -gt 0) {
        Write-Host "【释放的端口】" -ForegroundColor Yellow
        $summary.FreedPorts | ForEach-Object { Write-Host ("  - 端口: " + $_.Port + " (原进程: " + $_.ProcessName + " PID: " + $_.ProcessId + ")") }
    }
    if ($summary.RemovedRoutes.Count -gt 0) {
        Write-Host "【移除的残留路由】" -ForegroundColor Yellow
        $summary.RemovedRoutes | ForEach-Object { Write-Host ("  - 前缀: " + $_.Prefix + " 网关: " + $_.NextHop) }
    }
    Write-Host ""
    Write-Host "按回车键退出..." -ForegroundColor Gray
    try { [void][System.Console]::ReadLine() } catch { }
}

return $summary
