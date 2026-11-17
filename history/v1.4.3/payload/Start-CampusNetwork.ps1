param([int]$WaitForNetworkSeconds = 300, [int]$WaitForAuthSeconds = 180)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
$settings = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$statusPath = Join-Path $PSScriptRoot 'last-status.json'
$logPath = Join-Path $PSScriptRoot 'startup.log'
$ledgerPath = Join-Path $PSScriptRoot 'managed-routes.json'
$curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
$status = [ordered]@{ StartedAt = (Get-Date).ToString('o'); Stage = 'starting'; Result = 'pending'; ProcessId = $PID }
$routeLedger = @()
$mutex = $null
$mutexHeld = $false
$exitCode = 0
$bootEvent = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-General';Id=12} -MaxEvents 1 -ErrorAction SilentlyContinue
$currentBootMarker = [string]$bootEvent.RecordId
$legacyAllowed = ([bool]$settings.LegacyBootMarker -and $settings.LegacyBootMarker -eq $currentBootMarker)

function Assert-StartupAllowed {
    if((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'watchdog-paused.flag')) -or (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'uninstall-in-progress.flag'))){throw [OperationCanceledException]::new('用户已请求停止共享。')}
}
function Save-Status {
    [IO.File]::WriteAllText($statusPath, ($status | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
}
function Write-Stage([string]$stage, [string]$message) {
    if($stage -notin @('failed','cancelled')){Assert-StartupAllowed}
    $status.Stage = $stage
    Save-Status
    [IO.File]::AppendAllText($logPath, ('{0} [{1}] {2}' -f (Get-Date).ToString('o'), $stage, $message) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
function Get-CampusNetwork {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { ([Guid]$_.InterfaceGuid) -eq [Guid]$settings.CampusAdapterGuid } | Select-Object -First 1
    if (-not $adapter -or $adapter.Status -ne 'Up' -or !(Test-CampusProfile $adapter $settings)) { return $null }
    $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $settings.ExpectedGateway } | Select-Object -First 1
    $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { (Test-CampusSubnet $_.IPAddress $settings.SubnetReference $settings.SubnetBits) -and [string]$_.AddressState -eq 'Preferred' } | Select-Object -First 1
    if (-not $route -or -not $ip) { return $null }
    [pscustomobject]@{ InterfaceIndex = [int]$adapter.ifIndex; Name = $adapter.Name; Ip = $ip.IPAddress; Gateway = $route.NextHop }
}
function Try-Api([string]$path, [switch]$Post) {
    $responsePath = Join-Path $PSScriptRoot ('api-response-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $arguments = @('--noproxy', '*', '--silent', '--max-time', '4', '--output', $responsePath)
        if ($Post) { Assert-StartupAllowed; $arguments += @('--request', 'POST') }
        $arguments += ('http://127.0.0.1:' + $settings.ManagementPort + $path)
        & $curlExe @arguments
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $responsePath)) { return $null }
        $text = [IO.File]::ReadAllText($responsePath, [Text.Encoding]::UTF8)
        if (-not $text) { return $null }
        $text | ConvertFrom-Json
    } catch { return $null } finally { if (Test-Path -LiteralPath $responsePath) { Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue } }
}
function Test-ClientProcess($process) {
    if (-not $process -or -not $process.Path) { return $false }
    if ([string]::Equals([IO.Path]::GetFullPath($process.Path), [IO.Path]::GetFullPath($settings.ClientPath), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($legacyAllowed -and $settings.LegacyClientPath -and [string]::Equals([IO.Path]::GetFullPath($process.Path), [IO.Path]::GetFullPath($settings.LegacyClientPath), [StringComparison]::OrdinalIgnoreCase)) {
        $record = $settings.LegacyProcesses | Where-Object { $_.Id -eq $process.Id -and $_.StartTicks -eq [string]$process.StartTime.Ticks } | Select-Object -First 1
        return [bool]$record
    }
    $false
}
function Test-ManagementOwner {
    $listener = Get-NetTCPConnection -LocalPort $settings.ManagementPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) { return $true }
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    Test-ClientProcess $owner
}
function Add-AuthRoute([string]$target) {
    Assert-StartupAllowed
    $prefix = $target + '/32'
    $existing = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue)
    $conflicts = @($existing | Where-Object { $_.InterfaceIndex -ne $network.InterfaceIndex -or $_.NextHop -ne $network.Gateway })
    if ($conflicts.Count -gt 0) {
        throw ('发现其他网络工具正在使用认证专用路由 '+$prefix+'。为避免扰动原有连接，助手没有删除该路由，也没有启动共享。请先停止或调整冲突的 VPN、代理或网络工具后重试。')
    }
    if ($existing.Count -eq 0) {
        New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $network.InterfaceIndex -NextHop $network.Gateway -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
        $script:routeLedger += [pscustomobject]@{ Prefix = $prefix; AdapterGuid = $settings.CampusAdapterGuid; Gateway = $network.Gateway }
        $script:routeLedger = @($script:routeLedger | Sort-Object Prefix,AdapterGuid,Gateway -Unique)
        [IO.File]::WriteAllText($ledgerPath, (ConvertTo-Json -InputObject @($script:routeLedger) -Depth 4), [Text.UTF8Encoding]::new($false))
    }
}
function Assert-AuthRoutesUncontended {
    foreach($target in @($settings.AuthTargets)){
        $prefix=$target+'/32'
        $existing=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue)
        $conflicts=@($existing | Where-Object { $_.InterfaceIndex -ne $network.InterfaceIndex -or $_.NextHop -ne $network.Gateway })
        if($conflicts.Count){
            throw ('发现其他网络工具正在使用认证专用路由 '+$prefix+'。为避免启动到一半才改变网络，助手没有添加任何认证路由或启动共享。请先停止或调整冲突的 VPN、代理或网络工具后重试。')
        }
    }
}
function Test-CampusHttps {
    foreach ($address in $settings.HttpsProbeUrls) {
        $added = $false
        $prefix = $null
        try {
            $uri = [Uri]$address
            $ip = [Net.Dns]::GetHostAddresses($uri.DnsSafeHost) | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
            if (-not $ip) { continue }
            $prefix = $ip.IPAddressToString + '/32'
            $existing = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue)
            if ($existing | Where-Object { $_.InterfaceIndex -ne $network.InterfaceIndex -or $_.NextHop -ne $network.Gateway }) { continue }
            if ($existing.Count -eq 0) {
                New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $network.InterfaceIndex -NextHop $network.Gateway -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
                $added = $true
            }
            $text = & $curlExe --interface $network.Ip --noproxy '*' --silent --max-time 6 --resolve ($uri.DnsSafeHost + ':443:' + $ip.IPAddressToString) --output NUL --write-out '%{http_code};%{local_ip}' $uri.AbsoluteUri
            if ($LASTEXITCODE -eq 0 -and $text -eq ('200;' + $network.Ip)) { return [pscustomobject]@{ Url = $uri.AbsoluteUri; SourceIp = $network.Ip; HttpStatus = 200 } }
        } catch {
            # A second independent HTTPS endpoint is tried before reporting failure.
        } finally {
            if ($added) { Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -InterfaceIndex $network.InterfaceIndex -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $network.Gateway } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }
        }
    }
    $null
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this workflow through its registered scheduled task.' }
    $mutex = New-Object Threading.Mutex($false, ('Global\CampusNetwork-' + ([Guid]$settings.CampusAdapterGuid).ToString('N')))
    try { $mutexHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexHeld = $true }
    if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'uninstall-in-progress.flag')) -or -not $mutexHeld -or (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'watchdog-paused.flag'))) { exit 0 }
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 131072) { Move-Item -LiteralPath $logPath -Destination (Join-Path $PSScriptRoot 'startup.previous.log') -Force }
    if (Test-Path -LiteralPath $ledgerPath) { $routeLedger = @([IO.File]::ReadAllText($ledgerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
    Write-Stage 'waiting-for-campus' 'Waiting for the configured campus adapter, IPv4 address and gateway.'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-StartupAllowed
        $network = Get-CampusNetwork
        if ($network) { break }
        Start-Sleep -Seconds 5
    } while ($timer.Elapsed.TotalSeconds -lt $WaitForNetworkSeconds)
    if (-not $network) {
        $status.Result = 'not-at-campus'
        Write-Stage 'finished' 'No matching campus connection; no authentication or sharing was started.'
    } else {
        $status.Campus = $network
        $status.LegacySessionReuseAllowed = $legacyAllowed
        if (-not (Test-Path -LiteralPath $settings.ClientPath)) { throw 'The configured client executable is missing.' }
        if ((Get-FileHash -LiteralPath $settings.ClientPath -Algorithm SHA256).Hash -ne $settings.ExecutableSha256) { throw 'Client executable changed; verify the update before enabling startup again.' }
        $sameName = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($settings.ClientPath)) -ea SilentlyContinue)
        if (@($sameName | Where-Object { -not (Test-ClientProcess $_) }).Count) { throw 'Another authentication client is open. Close it first.' }
        $pending = Join-Path (Split-Path -LiteralPath $settings.ClientPath) 'ESurfingClient.json.pending'
        if (-not $sameName.Count -and (Test-Path -LiteralPath $pending)){
            $dest=Join-Path (Split-Path -LiteralPath $settings.ClientPath) 'ESurfingClient.json'
            [IO.File]::Replace($pending,$dest,[System.Management.Automation.Language.NullString]::Value)
        }
        $clientSettings = [IO.File]::ReadAllText((Join-Path (Split-Path -LiteralPath $settings.ClientPath) 'ESurfingClient.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $clientSettings.enabled) { throw 'Authentication is disabled in the client settings.' }
        if ($clientSettings.web_external_acc) { throw 'The management page must remain localhost-only.' }
        if (-not (Test-ManagementOwner)) { throw 'The management port belongs to another program.' }
        $auth = Try-Api '/api/status/auth'
        $running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($settings.ClientPath)) -ErrorAction SilentlyContinue | Where-Object { Test-ClientProcess $_ })
        if (-not $running.Count -and (Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue)) { throw 'Official client is open; leave it disconnected before starting independent authentication.' }
        Write-Stage 'campus-routing' 'Pinning authentication traffic to the selected campus connection.'
        Assert-AuthRoutesUncontended
        foreach ($target in $settings.AuthTargets) { Add-AuthRoute $target }
        if (-not $running.Count) {
            Assert-StartupAllowed
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $settings.ClientPath
            $info.WorkingDirectory = Split-Path -LiteralPath $settings.ClientPath
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.EnvironmentVariables['NO_PROXY'] = '*'
            $process = [Diagnostics.Process]::Start($info)
            $status.ClientStartedPid = $process.Id
            $status.ClientReused = $false
        } else { $status.ClientReused = $true; $status.ExistingClientPids = @($running.Id) }
        Write-Stage 'waiting-for-authentication' 'Waiting for the independent authentication process.'
        $timer.Restart()
        do {
            Assert-StartupAllowed
            if (-not (Test-ManagementOwner)) { throw 'Management port ownership changed.' }
            $auth = Try-Api '/api/status/auth'
            if ($auth -and $auth.status -and $auth.reachable) { break }
            Start-Sleep -Seconds 3
        } while ($timer.Elapsed.TotalSeconds -lt $WaitForAuthSeconds)
        if (-not $auth -or -not $auth.status -or -not $auth.reachable) { throw 'Independent authentication did not become ready; check the client log.' }
        $status.AuthBootId = $auth.bootId
        Write-Stage 'verifying-campus-internet' 'Verifying HTTPS through the campus source address.'
        $verified = $null
        for ($attempt = 0; $attempt -lt 3 -and -not $verified; $attempt++) {
            $verified = Test-CampusHttps
            if (-not $verified) { Start-Sleep -Seconds 5 }
        }
        if (-not $verified) { throw 'Campus HTTPS verification failed; hotspot was not started.' }
        $status.InternetVerification = $verified
        # Do not rewrite the computer-wide interface metric.  The selected
        # source is already pinned only for the authentication destinations;
        # changing a global default-route priority can disrupt VPNs, proxies
        # and a later Wi-Fi/ethernet transition.
        $status.CampusIpv4Metric = 'unchanged'
        $status.MetricPolicy = 'preserve-system'
        Write-Stage 'starting-hotspot' 'Selecting the selected campus connection as the hotspot upstream.'
        $id = ([Guid]$settings.CampusAdapterGuid).ToString()
        $timer.Restart()
        do {
            Assert-StartupAllowed
            $hotspot = Try-Api '/api/hotspot/status'
            $selected = $hotspot.adapters | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($selected -and -not $hotspot.busy) { break }
            Start-Sleep -Seconds 1
        } while ($timer.Elapsed.TotalSeconds -lt 30)
        if (-not $selected) {
            $hint = if ($settings.ConnectionKind -eq '有线') {
                'Windows 移动热点未找到此网线连接，请确认无线网卡已开启且处于可用状态。'
            } else {
                'Windows 未找到所选连接的热点功能，请在系统移动热点设置中检查网卡及驱动。'
            }
            throw $hint
        }
        if ($selected.capability -and $selected.capability -ne 'Enabled') {
            $hint = if ($settings.ConnectionKind -eq '有线') {
                ('此有线连接的移动热点不可用（' + $selected.capability + '）。将网线共享给手机需要电脑的 Wi-Fi 无线网卡正常开启并支持移动热点功能。')
            } else {
                ('此 Wi-Fi 连接的移动热点不可用（' + $selected.capability + '）。请在 Windows 移动热点设置中检查无线网卡及驱动是否支持同时连接 Wi-Fi 和共享热点。')
            }
            throw $hint
        }
        if ($selected.state -eq 'On') {
            $status.HotspotReused = $true
            $status.HotspotUpstreamVerification = $(if ($legacyAllowed -and $settings.KnownCurrentHotspotCampus) { 'verified-during-installation-session' } else { 'existing-hotspot-upstream-not-reset' })
        } else {
            $response = Try-Api ('/api/hotspot/start?adapter=' + $id) -Post
            if (-not $response -or -not $response.ok) { throw 'Windows rejected the hotspot start request.' }
            Set-AssistantHotspotOwner $PSScriptRoot $settings
            $status.HotspotReused = $false
            $status.HotspotUpstreamVerification = 'started-on-configured-campus-adapter'
        }
        $timer.Restart()
        do {
            Assert-StartupAllowed
            $hotspot = Try-Api '/api/hotspot/status'
            $selected = $hotspot.adapters | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($selected.state -eq 'On' -and -not $hotspot.busy) { break }
            Start-Sleep -Seconds 1
        } while ($timer.Elapsed.TotalSeconds -lt 35)
        if ($selected.state -ne 'On' -or $hotspot.busy) { throw 'Hotspot did not reach the On state.' }
        $status.HotspotState = 'On'
        $status.AfterHotspotVerification = Test-CampusHttps
        if (-not $status.AfterHotspotVerification) { throw 'Hotspot is on but campus HTTPS needs attention.' }
        $status.Result = if ($status.HotspotReused) { 'existing-hotspot-check-upstream' } else { 'ready' }
        $status.CompletedAt = (Get-Date).ToString('o')
        Write-Stage 'finished' 'Campus authentication and hotspot are ready.'
        Set-AssistantState $PSScriptRoot 'running' '校园认证和热点已就绪，请以手机实际联网为准。'
    }
} catch {
    $exitCode = 1
    $status.Result = 'needs-attention'
    $status.Error = $_.Exception.Message
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'watchdog-paused.flag')){
        $exitCode=0;$status.Result='cancelled'
        try{Write-Stage 'cancelled' 'Startup cancelled by stop request.'}catch{}
    }else{
        try { Write-Stage 'failed' $status.Error; Set-AssistantState $PSScriptRoot 'needs-attention' '认证或热点未完成，请检查校园连接或账号。' } catch {}
    }
} finally {
    if ($mutexHeld -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode
