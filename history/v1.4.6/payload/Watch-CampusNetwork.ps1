param([switch]$CheckOnly, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')

# This watchdog checks process presence only. It never restarts a present
# process and never treats Internet, authentication or hotspot state as a crash.
function Get-RecoveryDecision {
    param($Snapshot)
    if (-not $Snapshot.InspectionKnown) { return 'unknown-inspection' }
    if ($Snapshot.Paused) { return 'paused' }
    if (-not $Snapshot.CampusMatched) { return 'not-at-campus' }
    if (-not $Snapshot.TaskEnabled) { return 'startup-disabled' }
    if ($Snapshot.TaskRunning) { return 'startup-running' }
    if ($Snapshot.OfficialUiPresent) { return 'official-client-present' }
    if ($Snapshot.UnknownSameNameCount -gt 0) { return 'unknown-process-path' }
    if ($Snapshot.ForeignSameNameCount -gt 0) { return 'other-client-present' }
    if ($Snapshot.ExactProcessCount -gt 0) { return 'healthy-process-present' }
    if ($Snapshot.ManagementListenerCount -gt 0) { return 'management-port-in-use' }
    if ($Snapshot.AttemptsLast30Minutes -ge 3) { return 'recovery-rate-limited' }
    if ($Snapshot.LastAttemptAgeSeconds -lt 60) { return 'recovery-cooldown' }
    return 'recover-absent-client'
}

function Invoke-OfflineSelfTest {
    $cases = @(
        @{ Name='healthy'; Change=@{ExactProcessCount=3}; Expected='healthy-process-present' },
        @{ Name='unknown-path'; Change=@{UnknownSameNameCount=1}; Expected='unknown-process-path' },
        @{ Name='outside-campus'; Change=@{CampusMatched=$false}; Expected='not-at-campus' },
        @{ Name='paused'; Change=@{Paused=$true}; Expected='paused' },
        @{ Name='main-running'; Change=@{TaskRunning=$true}; Expected='startup-running' },
        @{ Name='port-conflict'; Change=@{ManagementListenerCount=1}; Expected='management-port-in-use' },
        @{ Name='rate-limit'; Change=@{AttemptsLast30Minutes=3}; Expected='recovery-rate-limited' },
        @{ Name='absent-recover'; Change=@{}; Expected='recover-absent-client' },
        @{ Name='inspection-error'; Change=@{InspectionKnown=$false}; Expected='unknown-inspection' },
        @{ Name='main-disabled'; Change=@{TaskEnabled=$false}; Expected='startup-disabled' },
        @{ Name='official-ui'; Change=@{OfficialUiPresent=$true}; Expected='official-client-present' },
        @{ Name='foreign-client'; Change=@{ForeignSameNameCount=1}; Expected='other-client-present' },
        @{ Name='cooldown'; Change=@{LastAttemptAgeSeconds=10}; Expected='recovery-cooldown' }
    )
    $tests = @(foreach ($case in $cases) {
        $s = [pscustomobject]@{
            InspectionKnown=$true; Paused=$false; CampusMatched=$true
            TaskEnabled=$true; TaskRunning=$false; OfficialUiPresent=$false
            UnknownSameNameCount=0; ForeignSameNameCount=0; ExactProcessCount=0
            ManagementListenerCount=0; AttemptsLast30Minutes=0; LastAttemptAgeSeconds=1000000
        }
        foreach ($key in $case.Change.Keys) { $s.$key = $case.Change[$key] }
        $actual = Get-RecoveryDecision $s
        [pscustomobject]@{ Case=$case.Name; Passed=($actual -eq $case.Expected); Decision=$actual }
    })
    $failed = @($tests | Where-Object { -not $_.Passed })
    [pscustomobject]@{
        Mode='SelfTest'; Offline=$true; Passed=($failed.Count -eq 0)
        TestCount=$tests.Count; FailedCount=$failed.Count; Tests=$tests
    } | ConvertTo-Json -Depth 4 -Compress
    if ($failed.Count -gt 0) { exit 1 }
}
if ($SelfTest) { Invoke-OfflineSelfTest; exit 0 }

$statePath = Join-Path $PSScriptRoot 'watchdog-status.json'
$logPath = Join-Path $PSScriptRoot 'watchdog.log'
$pausedPath = Join-Path $PSScriptRoot 'watchdog-paused.flag'
$attemptTimes = @()
$previousState = $null
$historyReadComplete = $false
$sharedMutex = $null
$sharedHeld = $false
$watchMutex = $null
$watchHeld = $false
$result = [ordered]@{
    CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    Mode=$(if ($CheckOnly) { 'CheckOnly' } else { 'Watchdog' })
    Decision='unknown-inspection'; RecoveryRequested=$false
    Scope='process-presence-only'
}

function Read-AttemptHistory {
    $script:previousState = $null
    $script:attemptTimes = @()
    if (-not (Test-Path -LiteralPath $statePath -ErrorAction Stop)) { return }
    $script:previousState = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    foreach ($text in @($script:previousState.AttemptTimesUtc)) {
        if (-not $text) { continue }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$text, [ref]$parsed)) { throw 'Invalid watchdog attempt history' }
        if (($now - $parsed).TotalMinutes -lt 30) { $script:attemptTimes += $parsed.ToUniversalTime().ToString('o') }
    }
}

function Get-ReadinessSnapshot {
    $s = [pscustomobject]@{
        InspectionKnown=$true; Paused=$false; CampusMatched=$false
        TaskEnabled=$false; TaskRunning=$false; OfficialUiPresent=$false
        UnknownSameNameCount=0; ForeignSameNameCount=0; ExactProcessCount=0
        ManagementListenerCount=0; AttemptsLast30Minutes=$attemptTimes.Count
        LastAttemptAgeSeconds=1000000
    }
    try {
        $s.Paused = Test-Path -LiteralPath $pausedPath -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $settings.TaskName -TaskPath '\' -ErrorAction Stop
        $s.TaskEnabled = [bool]$task.Settings.Enabled
        $s.TaskRunning = ([string]$task.State -eq 'Running')
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { ([Guid]$_.InterfaceGuid) -eq [Guid]$settings.CampusAdapterGuid })
        if ($adapters.Count -gt 1) { throw 'Ambiguous campus adapter' }
        if ($adapters.Count -eq 1 -and [string]$adapters[0].Status -eq 'Up') {
            $adapter = $adapters[0]
            $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
            $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
            $matchingRoute = @($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -eq $settings.ExpectedGateway })
            $matchingIp = @($ips | Where-Object { (Test-CampusSubnet $_.IPAddress $settings.SubnetReference $settings.SubnetBits) -and [string]$_.AddressState -eq 'Preferred' })
            $s.CampusMatched = ($matchingRoute.Count -gt 0 -and $matchingIp.Count -gt 0 -and (Test-CampusProfile $adapter $settings))
        }
        $allProcesses = @(Get-Process -ErrorAction Stop)
        $s.OfficialUiPresent = @($allProcesses | Where-Object { $_.ProcessName -eq 'ESurfingClient' }).Count -gt 0
        $clientName = [IO.Path]::GetFileNameWithoutExtension([string]$settings.ClientPath)
        $expectedPath = [IO.Path]::GetFullPath([string]$settings.ClientPath)
        foreach ($process in @($allProcesses | Where-Object { $_.ProcessName -eq $clientName })) {
            try {
                $path = [string]$process.Path
                if (-not $path) { $s.UnknownSameNameCount++; continue }
                if ([string]::Equals([IO.Path]::GetFullPath($path), $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $s.ExactProcessCount++
                } else { $s.ForeignSameNameCount++ }
            } catch { $s.UnknownSameNameCount++ }
        }
        $s.ManagementListenerCount = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq [int]$settings.ManagementPort }).Count
        if ($attemptTimes.Count -gt 0) {
            $latest = @($attemptTimes | ForEach-Object { [DateTimeOffset]::Parse($_) } | Sort-Object -Descending)[0]
            $s.LastAttemptAgeSeconds = ([DateTimeOffset]::UtcNow - $latest).TotalSeconds
        }
    } catch {
        # Never classify an unreadable process path, task, adapter or port as absent.
        $s.InspectionKnown = $false
    }
    $s
}

function Add-SnapshotToResult {
    param($Snapshot)
    $result.InspectionKnown = [bool]$Snapshot.InspectionKnown
    $result.CampusMatched = [bool]$Snapshot.CampusMatched
    $result.Paused = [bool]$Snapshot.Paused
    $result.StartupTaskEnabled = [bool]$Snapshot.TaskEnabled
    $result.StartupTaskRunning = [bool]$Snapshot.TaskRunning
    $result.ExactProcessCount = [int]$Snapshot.ExactProcessCount
    $result.UnknownSameNameCount = [int]$Snapshot.UnknownSameNameCount
    $result.ForeignSameNameCount = [int]$Snapshot.ForeignSameNameCount
    $result.ManagementListenerCount = [int]$Snapshot.ManagementListenerCount
    $result.OfficialUiPresent = [bool]$Snapshot.OfficialUiPresent
    $result.AttemptsLast30Minutes = [int]$attemptTimes.Count
}

function Save-WatchdogResult {
    # The dedicated watchdog mutex protects this state from concurrent manual runs.
    $result.AttemptTimesUtc = @($attemptTimes)
    $result.CheckedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $temporary = $statePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $statePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    if (-not $previousState -or [string]$previousState.Decision -ne [string]$result.Decision) {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 65536) {
            Move-Item -LiteralPath $logPath -Destination (Join-Path $PSScriptRoot 'watchdog.previous.log') -Force
        }
        [IO.File]::AppendAllText($logPath, ('{0} [{1}] process-only; recovery-requested={2}' -f $result.CheckedAtUtc, $result.Decision, $result.RecoveryRequested) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
}

try {
    $settings = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings.TaskName -or -not $settings.ClientPath -or -not $settings.CampusAdapterGuid -or -not $settings.ExpectedGateway -or -not $settings.SubnetReference -or -not $settings.ManagementPort) {
        throw 'Incomplete watchdog settings'
    }
    $campusId = ([Guid]$settings.CampusAdapterGuid).ToString('N')
    if (-not $CheckOnly) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated watchdog required' }
        $watchMutex = New-Object Threading.Mutex($false, ('Global\CampusNetwork-Watchdog-' + $campusId))
        try { $watchHeld = $watchMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $watchHeld = $true }
        if (-not $watchHeld) {
            $result.Decision = 'watchdog-already-running'
            $result | ConvertTo-Json -Depth 5 -Compress
            exit 0
        }
    }
    $now = [DateTimeOffset]::UtcNow
    Read-AttemptHistory
    $historyReadComplete = $true
    $snapshot = Get-ReadinessSnapshot
    Add-SnapshotToResult $snapshot
    $result.Decision = Get-RecoveryDecision $snapshot
    if (-not $CheckOnly -and $result.Decision -eq 'recover-absent-client') {
        $sharedMutex = New-Object Threading.Mutex($false, ('Global\CampusNetwork-' + $campusId))
        try { $sharedHeld = $sharedMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $sharedHeld = $true }
        if (-not $sharedHeld) {
            $result.Decision = 'startup-workflow-busy'
        } else {
            Start-Sleep -Seconds 3
            $snapshot = Get-ReadinessSnapshot
            Add-SnapshotToResult $snapshot
            $result.Decision = Get-RecoveryDecision $snapshot
            if ($result.Decision -eq 'recover-absent-client') {
                # Reserve the attempt before invoking the task, so a watcher crash
                # cannot erase the recovery budget. Never hold its mutex at launch.
                $attemptTimes += [DateTimeOffset]::UtcNow.ToString('o')
                $result.AttemptsLast30Minutes = $attemptTimes.Count
                $result.Decision = 'recovery-reserved'
                Save-WatchdogResult
                $sharedMutex.ReleaseMutex()
                $sharedHeld = $false
                $snapshot = Get-ReadinessSnapshot
                Add-SnapshotToResult $snapshot
                $finalDecision = Get-RecoveryDecision $snapshot
                # The reservation itself reaches the limit on attempt three.
                # Use the pre-reservation budget for this final readiness check.
                $snapshot.AttemptsLast30Minutes = $attemptTimes.Count - 1
                $snapshot.LastAttemptAgeSeconds = 1000000
                $finalDecision = Get-RecoveryDecision $snapshot
                if ($finalDecision -eq 'recover-absent-client') {
                    Start-ScheduledTask -TaskName $settings.TaskName -TaskPath '\' -ErrorAction Stop
                    $result.RecoveryRequested = $true
                    $result.Decision = 'recovery-requested'
                } else { $result.Decision = 'recovery-cancelled-' + $finalDecision }
            }
        }
    }
    if (-not $CheckOnly) { Save-WatchdogResult }
} catch {
    $result.Decision = 'unknown-inspection'
    $result.ErrorType = $_.Exception.GetType().FullName
    # Do not log raw exceptions: they may quote arbitrary external configuration.
    if (-not $CheckOnly -and $watchHeld -and $historyReadComplete) {
        try { Save-WatchdogResult } catch { $result.StatusWriteFailed = $true }
    }
} finally {
    if ($sharedHeld -and $sharedMutex) { $sharedMutex.ReleaseMutex() }
    if ($sharedMutex) { $sharedMutex.Dispose() }
    if ($watchHeld -and $watchMutex) { $watchMutex.ReleaseMutex() }
    if ($watchMutex) { $watchMutex.Dispose() }
}
$result | ConvertTo-Json -Depth 5 -Compress