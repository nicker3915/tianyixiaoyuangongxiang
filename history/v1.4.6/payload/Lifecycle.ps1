# Shared reversible lifecycle. No credentials are read by this module.
function Read-LifecycleJson([string]$Path) {
    [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json
}
function Write-LifecycleJson([string]$Path,$Value) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
    } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Set-AssistantState([string]$Root,[string]$State,[string]$Message) {
    Write-LifecycleJson (Join-Path $Root 'assistant-state.json') ([ordered]@{State=$State;Message=$Message;UpdatedAt=[DateTimeOffset]::Now.ToString('o')})
}
function Get-LifecycleContext([string]$Root) {
    $cfg=Read-LifecycleJson (Join-Path $Root 'settings.json')
    $backup=Read-LifecycleJson (Join-Path $Root 'original-startup.json')
    $client=Join-Path $Root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
    if($cfg.TaskName -ne 'GDPortalShare-Logon' -or ![string]::Equals([IO.Path]::GetFullPath($cfg.ClientPath),[IO.Path]::GetFullPath($client),[StringComparison]::OrdinalIgnoreCase)) {throw '助手配置的程序路径不匹配，已保留配置，请修复安装。'}
    if(([guid]$backup.Adapter) -ne ([guid]$cfg.CampusAdapterGuid) -or $backup.Gateway -ne $cfg.ExpectedGateway){throw '网络配置和恢复备份不匹配，已停止操作。'}
    [pscustomobject]@{Root=$Root;Settings=$cfg;Backup=$backup;Client=$client;Launcher=(Join-Path $Root 'CampusQuietLauncher.exe');Pause=(Join-Path $Root 'watchdog-paused.flag')}
}
function Get-LifecycleTasks($Context) {
    foreach($pair in @(@('GDPortalShare-Logon','startup'),@('GDPortalShare-Logon-Watchdog','watch'))){
        $task=Get-ScheduledTask -TaskName $pair[0] -TaskPath '\' -ErrorAction SilentlyContinue
        if($task){
            if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne $Context.Launcher -or $task.Actions[0].Arguments -ne $pair[1]){throw '发现同名但不属于本助手的任务，未修改。'}
            $task
        }
    }
}
function Get-LifecycleProcesses($Context) {
    foreach($p in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Context.Client)) -ErrorAction SilentlyContinue)){
        if(!$p.Path){throw '无法核实认证进程归属，请使用管理员授权后重试。'}
        if([string]::Equals([IO.Path]::GetFullPath($p.Path),[IO.Path]::GetFullPath($Context.Client),[StringComparison]::OrdinalIgnoreCase)){
            [pscustomobject]@{Id=$p.Id;StartTicks=[string]$p.StartTime.Ticks;Path=$p.Path}
        }
    }
}
function Stop-LifecycleProcesses($Context) {
    # Kill only path-and-creation-time verified members, never by name alone.
    for($attempt=0;$attempt -lt 3;$attempt++){
        $members=@(Get-LifecycleProcesses $Context)
        if(!$members.Count){return}
        $parents=@(Get-CimInstance Win32_Process | Where-Object {$_.ProcessId -in @($members.Id)})
        $ordered=@($members|Sort-Object @{e={$member=$_;$row=$parents|Where-Object ProcessId -eq $member.Id;if($row.ParentProcessId -notin @($members.Id)){0}else{1}}})
        foreach($member in $ordered){
            $current=Get-Process -Id $member.Id -ErrorAction SilentlyContinue
            if($current -and $current.Path -eq $Context.Client -and [string]$current.StartTime.Ticks -eq $member.StartTicks){Stop-Process -Id $current.Id -Force -ErrorAction Stop}
        }
        Start-Sleep -Milliseconds 200
    }
    if(@(Get-LifecycleProcesses $Context).Count){throw '认证进程尚未完全停止，请再次点击停止。'}
}
function Get-LifecycleBootTime { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() }
function Set-AssistantHotspotOwner([string]$Root,$Settings) {
    Write-LifecycleJson (Join-Path $Root 'hotspot-owner.json') ([ordered]@{Owned=$true;AdapterGuid=([guid]$Settings.CampusAdapterGuid).ToString();StartedAt=[DateTimeOffset]::Now.ToString('o');BootTime=(Get-LifecycleBootTime).ToString('o')})
}
function Get-LifecycleHotspotOwnership($Context) {
    $path=Join-Path $Context.Root 'hotspot-owner.json'
    $boot=Get-LifecycleBootTime
    if(Test-Path -LiteralPath $path){
        $owner=Read-LifecycleJson $path
        return [bool]($owner.Owned -and ([guid]$owner.AdapterGuid) -eq ([guid]$Context.Settings.CampusAdapterGuid) -and ([datetime]$owner.BootTime).ToUniversalTime() -eq $boot)
    }
    # Upgrade from 1.2.x: accept only a start we recorded in the current boot.
    $path=Join-Path $Context.Root 'last-status.json'
    if(!(Test-Path -LiteralPath $path)){return $false}
    $last=Read-LifecycleJson $path
    return [bool]($last.HotspotUpstreamVerification -eq 'started-on-configured-campus-adapter' -and !$last.HotspotReused -and $last.CompletedAt -and ([DateTimeOffset]::Parse($last.CompletedAt).UtcDateTime -ge $boot))
}
function Get-LifecycleHotspot($Context) {
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $profiles=@([Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles())
    $snapshots=@()
    $failed=$false
    foreach($group in @($profiles | Group-Object { [string]$_.NetworkAdapter.NetworkAdapterId })){
        $profile=$group.Group | Where-Object {$_.ProfileName -ceq $Context.Settings.ExpectedNetworkName} | Select-Object -First 1
        if(!$profile){$profile=$group.Group | Select-Object -First 1}
        try {
            $manager=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
            $snapshots+=[pscustomobject]@{State=[string]$manager.TetheringOperationalState;AdapterId=$group.Name;Manager=$manager}
        }catch{$failed=$true}
    }
    $active=@($snapshots | Where-Object {$_.State -ne 'Off'})
    if(!$active.Count -and !$failed){
        # No active tethering, including when the configured USB adapter was removed.
        return [pscustomobject]@{State='Off';PublicAdapterIds=@();Manager=$null}
    }
    if(!$active.Count){throw '无法确认热点是否关闭，请在 Windows 移动热点设置中检查后重试。'}
    $sharing=New-Object -ComObject HNetCfg.HNetShare
    $public=@()
    foreach($connection in $sharing.EnumEveryConnection){
        $configuration=$sharing.INetSharingConfigurationForINetConnection($connection)
        if($configuration.SharingEnabled -and [int]$configuration.SharingConnectionType -eq 0){$public+=([guid]$sharing.NetConnectionProps($connection).Guid).ToString()}
    }
    $selected=$active | Where-Object {$_.AdapterId -eq ([guid]$Context.Settings.CampusAdapterGuid).ToString()} | Select-Object -First 1
    if(!$selected){$selected=$active | Select-Object -First 1}
    [pscustomobject]@{State=$selected.State;PublicAdapterIds=$public;Manager=$selected.Manager;ManagerAdapterId=$selected.AdapterId;ActiveAdapterIds=@($active.AdapterId);ProfilesComplete=(!$failed)}
}
function Stop-LifecycleNativeHotspot($Snapshot) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $operation=$Snapshot.Manager.StopTetheringAsync()
    $resultType=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'} | Select-Object -First 1
    $task=$method.MakeGenericMethod($resultType).Invoke($null,@($operation))
    if(!$task.Wait(20000) -or [string]$task.Result.Status -ne 'Success'){throw 'Windows 尚未完成热点关闭，请稍后重试。'}
}
function Stop-AssistantHotspot($Context) {
    $snapshot=Get-LifecycleHotspot $Context
    if($snapshot.State -eq 'Off'){return}
    $owned=Get-LifecycleHotspotOwnership $Context
    $expected=([guid]$Context.Settings.CampusAdapterGuid).ToString()
    $publicIds=@($snapshot.PublicAdapterIds)
    $publicMatches=($publicIds.Count -eq 1 -and $publicIds[0] -eq $expected)
    # Modern mobile hotspots may have no legacy HNetShare public entry. In that
    # case use our current-boot creation record and the configured WinRT manager.
    # Windows reports the global On state through other profile managers too;
    # their count does not identify the actual upstream connection.
    # CreateFromConnectionProfile binds the manager to that public interface:
    # https://learn.microsoft.com/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.createfromconnectionprofile
    $nativeMatches=($publicIds.Count -eq 0 -and $snapshot.ProfilesComplete)
    if(!$owned -or $snapshot.ManagerAdapterId -ne $expected -or !($publicMatches -or $nativeMatches)){throw '当前热点的来源或归属无法确认。请在 Windows 移动热点设置中手动关闭热点，再点击停止。'}
    Stop-LifecycleNativeHotspot $snapshot
    if((Get-LifecycleHotspot $Context).State -ne 'Off'){throw '热点仍在运行，尚未完成停止。'}
    Write-LifecycleJson (Join-Path $Context.Root 'hotspot-owner.json') @{Owned=$false;AdapterGuid=$expected;UpdatedAt=[DateTimeOffset]::Now.ToString('o')}
}
function Stop-LifecycleDeviceSpeedServer([string]$Root) {
    $script=Join-Path $Root 'Device-SpeedServer.ps1'
    if(!(Test-Path -LiteralPath $script)){return}
    # This only removes the per-session hotspot-subnet firewall rule and the
    # verified device-test process. It does not change Wi-Fi, hotspot or routes.
    & $script -Mode Stop
}
function Restore-LifecycleOfficial($Context) {
    $b=$Context.Backup
    $runPath='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    $runName='Esurfing Client in Campus'
    $svcKey='HKLM:\SYSTEM\CurrentControlSet\Services\ESurfingSvr'
    if($b.RunExists){
        if($b.RunValue -notmatch '(?i)\\Chinatelecom_GDPortal\\AutoStart\.exe(?:"|\s|$)'){throw '备份中的官方启动路径不符合预期。'}
        $current=Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue
        if($current -and $current.$runName -ne $b.RunValue){throw '官方启动项已被其他程序修改，未覆盖。'}
        if(!$current){New-ItemProperty -LiteralPath $runPath -Name $runName -Value $b.RunValue -PropertyType $b.RunKind -ErrorAction Stop | Out-Null}
    }
    if($b.ServiceAuto -and (Test-Path -LiteralPath $svcKey)){
        $svc=Get-ItemProperty -LiteralPath $svcKey
        if($svc.ImagePath -notmatch '(?i)\\Chinatelecom_GDPortal\\ESurfingSvr\.exe(?:"|\s|$)' -or $svc.Start -notin @(2,3)){throw '官方服务设置已改变，未覆盖。'}
        Set-Service -Name ESurfingSvr -StartupType Automatic
        if($null -ne $b.Delayed){Set-ItemProperty -LiteralPath $svcKey -Name DelayedAutoStart -Value ([int]$b.Delayed)}
        elseif((Get-Item -LiteralPath $svcKey).GetValueNames() -contains 'DelayedAutoStart'){Remove-ItemProperty -LiteralPath $svcKey -Name DelayedAutoStart}
    }
}
function Test-LifecycleLegacyMetricRestore($Context) {
    $names=@($Context.Settings.PSObject.Properties.Name)
    if($names -contains 'MetricPolicy'){
        return ([string]$Context.Settings.MetricPolicy -eq 'legacy-force-10')
    }
    # Configurations created before MetricPolicy wrote CampusMetric=10, so their original metric must
    # still be restored during a stop or uninstall.  Newer configurations do
    # not set that property and leave the system metric untouched.
    return ($names -contains 'CampusMetric')
}
function Restore-LifecycleNetwork($Context) {
    $b=$Context.Backup
    $adapter=Get-NetAdapter | Where-Object {([guid]$_.InterfaceGuid) -eq ([guid]$b.Adapter)} | Select-Object -First 1
    if(!$adapter){return} # Removed adapters have no active-store routes or metric to restore.
    $metric=Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if((Test-LifecycleLegacyMetricRestore $Context) -and $metric -and [string]$metric.AutomaticMetric -eq 'Disabled' -and $metric.InterfaceMetric -eq $Context.Settings.CampusMetric){
        if($b.AutoMetric -eq 'Enabled'){Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -PolicyStore ActiveStore}
        else{Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -InterfaceMetric $b.Metric -PolicyStore ActiveStore}
    }
    $ledger=Join-Path $Context.Root 'managed-routes.json'
    if(Test-Path -LiteralPath $ledger){
        foreach($route in @(Read-LifecycleJson $ledger)){
            if($route.AdapterGuid -ne $b.Adapter -or $route.Gateway -ne $b.Gateway){continue}
            Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix $route.Prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $b.Gateway -and $_.RouteMetric -eq 1} | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        }
    }
}
function Enter-LifecycleNetwork($Context,[int]$WaitMilliseconds=35000) {
    $mutex=New-Object Threading.Mutex($false,('Global\CampusNetwork-'+([guid]$Context.Settings.CampusAdapterGuid).ToString('N')))
    try {
        try {$held=$mutex.WaitOne($WaitMilliseconds)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(!$held){throw '另一个网络操作正在结束，请稍后再试。'}
        return $mutex
    }catch{$mutex.Dispose();throw}
}
function Stop-AssistantLifecycle([string]$Root,[switch]$Uninstall) {
    $context=Get-LifecycleContext $Root
    $tasks=@(Get-LifecycleTasks $context)
    $networkLock=$null
    Set-AssistantState $Root 'stopping' '正在关闭共享并恢复官方设置。'
    try {
        # The marker is deliberately retained on failure: the watchdog must not undo a stop.
        [IO.File]::WriteAllText($context.Pause,'user-stopped',[Text.UTF8Encoding]::new($false))
        foreach($task in $tasks){Disable-ScheduledTask -InputObject $task | Out-Null}
        $networkLock=Enter-LifecycleNetwork $context
        Stop-LifecycleDeviceSpeedServer $context.Root
        Stop-AssistantHotspot $context
        # Stop task wrappers only after the workflow released the network lock.
        foreach($task in $tasks){Stop-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop}
        Stop-LifecycleProcesses $context
        Restore-LifecycleNetwork $context
        Restore-LifecycleOfficial $context
        if($Uninstall){foreach($task in $tasks){Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false}}
        Set-AssistantState $Root 'stopped' '助手已停止。请用官方客户端登录；账号和恢复备份仍保留。'
    } catch {
        Set-AssistantState $Root 'needs-attention' $_.Exception.Message
        throw
    } finally {if($networkLock){$networkLock.ReleaseMutex();$networkLock.Dispose()}}
}
function Start-OfficialClient([string]$Root) {
    $official=Join-Path ${env:ProgramFiles(x86)} 'Chinatelecom_GDPortal\AutoStart.exe'
    if(!(Test-Path -LiteralPath $official)){throw '助手已停止，但未找到官方客户端。请通过原来的快捷方式打开。'}
    if(!(Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue)){Start-Process -FilePath $official -WorkingDirectory (Split-Path -LiteralPath $official) | Out-Null}
}
function Resume-AssistantLifecycle([string]$Root) {
    $context=Get-LifecycleContext $Root
    if(Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue){throw '请先在官方天翼客户端断开并退出，再点击启动共享。'}
    $tasks=@(Get-LifecycleTasks $context)
    if($tasks.Count -ne 2){throw '自动运行任务缺失，请修复安装或重新设置。'}
    if(!(Get-ConfiguredCampusCandidates $context.Settings)){throw '请先连接已设置的校园 Wi-Fi 或网线，再启动共享。'}
    $networkLock=Enter-LifecycleNetwork $context 1000
    try {
        if(Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue){throw '官方客户端已打开，请先退出。'}
        $runPath='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        $runName='Esurfing Client in Campus'
        $svcKey='HKLM:\SYSTEM\CurrentControlSet\Services\ESurfingSvr'
        $b=$context.Backup
        if($b.RunExists){
            $current=Get-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction SilentlyContinue
            if($current -and $current.$runName -ne $b.RunValue){throw '官方启动项已被其他程序修改，未接管。'}
        }
        if($b.ServiceAuto){
            $svc=Get-ItemProperty -LiteralPath $svcKey
            if($svc.ImagePath -notmatch '(?i)\\Chinatelecom_GDPortal\\ESurfingSvr\.exe(?:"|\s|$)' -or $svc.Start -notin @(2,3)){throw '官方服务设置已改变，未接管。'}
        }
        # Preflight all conflicts above before changing the baseline-owned settings.
        try {
            if($b.ServiceAuto){Set-Service -Name ESurfingSvr -StartupType Manual}
            if($b.RunExists -and $current){Remove-ItemProperty -LiteralPath $runPath -Name $runName -ErrorAction Stop}
            foreach($task in $tasks){Enable-ScheduledTask -InputObject $task | Out-Null}
            Set-AssistantState $Root 'start-requested' '正在启动认证和热点，请稍候。'
            if(Test-Path -LiteralPath $context.Pause){Remove-Item -LiteralPath $context.Pause -Force}
        }catch{
            [IO.File]::WriteAllText($context.Pause,'resume-failed')
            foreach($task in $tasks){Disable-ScheduledTask -InputObject $task | Out-Null}
            Restore-LifecycleOfficial $context
            throw
        }
    }finally{$networkLock.ReleaseMutex();$networkLock.Dispose()}
}
