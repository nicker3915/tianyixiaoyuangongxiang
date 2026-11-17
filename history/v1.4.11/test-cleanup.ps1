$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'payload\Network.ps1')
. (Join-Path $PSScriptRoot 'payload\Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'payload\Cleanup.Core.ps1')
. (Join-Path $PSScriptRoot 'payload\Cleanup.Processes.ps1')
$testRoot=Join-Path $PSScriptRoot ('validation\cleanup-'+[guid]::NewGuid().ToString('N'))
$bundle=Join-Path $testRoot 'trusted-bundle';[void][IO.Directory]::CreateDirectory($bundle)
[IO.File]::WriteAllText((Join-Path $bundle 'cleanup-files.json'),'["Panel.ps1","Manage.ps1","Network.ps1","Lifecycle.ps1","校园网共享助手.exe","CampusQuietLauncher.exe","Client/ESurfingClient-2.2.0-r4-windows-x86_64.exe"]',[Text.UTF8Encoding]::new($true))
$script:checks=0;$script:events=@();$script:registrations=@();$script:tasks=@{};$script:processes=@();$script:uiRows=@();$script:reuseOnOpenId=0;$script:shortcuts=@();$script:failRecovery=$false;$script:legacyVerified=$false
function Assert($value,[string]$message){if(!$value){throw $message};$script:checks++}
function Put-Json([string]$Path,$Value){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
function Get-CleanupRegistrationRecords{$script:registrations}
function Remove-CleanupRegistrationRecord($Record,[string]$Root){
    Assert ($Record.Name -eq 'GDPortalShare-20261104_is1' -and (Test-CleanupSamePath $Record.InstallLocation $Root)) 'Foreign registration reached removal'
    $script:events+='registry';$script:registrations=@($script:registrations|Where-Object {$_ -ne $Record})
}
function Get-CleanupShortcuts([string]$Root){@($script:shortcuts|Where-Object {Test-CleanupSamePath $_.OwnerRoot $Root})}
function Remove-CleanupShortcut($Shortcut,[string]$Root){Assert (Test-CleanupSamePath $Shortcut.OwnerRoot $Root) 'Foreign shortcut reached removal';$script:events+='shortcut';$script:shortcuts=@($script:shortcuts|Where-Object {$_ -ne $Shortcut})}
function Test-CleanupAdministrator{$true}
function Test-CleanupLegacyExecutable([string]$Root){$script:legacyVerified}
function Get-ScheduledTask($TaskName,$TaskPath){if($script:tasks.ContainsKey($TaskName)){$script:tasks[$TaskName]}}
function Get-Process($Name,$Id){if($PSBoundParameters.ContainsKey('Id')){@($script:processes|Where-Object Id -eq $Id)}else{@($script:processes|Where-Object ProcessName -eq $Name)}}
function Get-CleanupUiProcessRows{$script:uiRows}
function Open-CleanupUiHandle([int]$ProcessId){
    $process=$script:processes|Where-Object Id -eq $ProcessId|Select-Object -First 1
    if($script:reuseOnOpenId -eq $ProcessId){$process.StartTime=$process.StartTime.AddSeconds(1);$script:reuseOnOpenId=0}
    $handle=[pscustomobject]@{Id=$ProcessId;ImagePath=$process.Path;StartTicks=[string]$process.StartTime.ToUniversalTime().Ticks}
    $handle|Add-Member ScriptMethod WaitForExit {param($Milliseconds);return !@($script:processes|Where-Object Id -eq $this.Id).Count}
    $handle|Add-Member ScriptMethod Terminate {$script:events+=('ui-close:'+$this.Id);$script:processes=@($script:processes|Where-Object Id -ne $this.Id);$script:uiRows=@($script:uiRows|Where-Object ProcessId -ne $this.Id)}
    $handle|Add-Member ScriptMethod Dispose {}
    return $handle
}
function Disable-ScheduledTask($InputObject){$script:events+='disable';$InputObject.State='Disabled'}
function Stop-ScheduledTask($TaskName,$TaskPath){$script:events+='task-stop'}
function Unregister-ScheduledTask($TaskName,$TaskPath,[switch]$Confirm){$script:events+='unregister';$script:tasks.Remove($TaskName)}
function Enter-LifecycleNetwork($Context){New-Object Threading.Mutex($true,('Local\CleanupTest-'+[guid]::NewGuid().ToString('N')))}
function Stop-AssistantHotspot($Context){$script:events+='hotspot'}
function Stop-LifecycleProcesses($Context){foreach($p in @(Get-LifecycleProcesses $Context)){$script:events+=('process:'+ $p.Id);$script:processes=@($script:processes|Where-Object Id -ne $p.Id)}}
function Restore-LifecycleNetwork($Context){$script:events+='network'}
function Restore-LifecycleOfficial($Context){if($script:failRecovery){throw 'TEST: recovery failure'};$script:events+='official'}
function Stop-AssistantLifecycle([string]$Root,[switch]$Uninstall){
    $context=Get-LifecycleContext $Root;$tasks=@(Get-LifecycleTasks $context)
    [IO.File]::WriteAllText((Join-Path $Root 'watchdog-paused.flag'),'test-paused')
    foreach($task in $tasks){Disable-ScheduledTask $task}
    Stop-AssistantHotspot $context;Stop-LifecycleProcesses $context;Restore-LifecycleNetwork $context;Restore-LifecycleOfficial $context
    if($Uninstall){foreach($task in $tasks){Unregister-ScheduledTask $task.TaskName '\' -Confirm:$false}}
}
function New-Fixture([string]$Name,[switch]$Configured,[switch]$BackupOnly,[switch]$Unknown){
    $root=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory((Join-Path $root 'Client'))
    Put-Json (Join-Path $root 'app-identity.json') @{ProductId='GDPortalShare';Schema=1}
    foreach($n in @('Panel.ps1','Manage.ps1','校园网共享助手.exe','CampusQuietLauncher.exe','unins000.exe','unins000.dat')){[IO.File]::WriteAllText((Join-Path $root $n),'fixture')}
    [IO.File]::WriteAllText((Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'),'fixture')
    if($Unknown){[IO.File]::WriteAllText((Join-Path $root '我的文档.txt'),'must remain',[Text.UTF8Encoding]::new($true))}
    if($Configured -or $BackupOnly){
        $id=[guid]::NewGuid().ToString()
        Put-Json (Join-Path $root 'original-startup.json') @{Adapter=$id;Gateway='192.0.2.1';RunExists=$false;ServiceAuto=$false;AutoMetric='Enabled';Metric=25}
        if($Configured){Put-Json (Join-Path $root 'settings.json') @{TaskName='GDPortalShare-Logon';CampusAdapterGuid=$id;ExpectedGateway='192.0.2.1';ClientPath=(Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe');CampusMetric=10;ExecutableSha256='714A8CC53C5E50A218932D0BDDDF0E68570C5D9832B9B7830EAC27DD85517DD7'}}
    }
    return $root
}
function Set-OwnTasks([string]$Root){
    foreach($pair in @(@('GDPortalShare-Logon','startup'),@('GDPortalShare-Logon-Watchdog','watch'))){$script:tasks[$pair[0]]=[pscustomobject]@{TaskName=$pair[0];State='Ready';Actions=@([pscustomobject]@{Execute=(Join-Path $Root 'CampusQuietLauncher.exe');Arguments=$pair[1]})}}
}
function Reset-FixtureState{$script:events=@();$script:registrations=@();$script:tasks=@{};$script:processes=@();$script:uiRows=@();$script:reuseOnOpenId=0;$script:shortcuts=@();$script:failRecovery=$false;$script:legacyVerified=$false}
function Add-UiFixtureProcess([int]$Id,[string]$Path,[string]$CommandLine,[int]$ParentId=0){
    $created=[DateTime]::Now
    $script:processes+=[pscustomobject]@{Id=$Id;ProcessName=[IO.Path]::GetFileNameWithoutExtension($Path);Path=$Path;StartTime=$created}
    $script:uiRows+=[pscustomobject]@{ProcessId=$Id;ParentProcessId=$ParentId;ExecutablePath=$Path;CommandLine=$CommandLine;CreationDate=$created}
}

# Preview is inert and produces a compact, reviewable plan.
$root=New-Fixture 'preview' -Configured -Unknown;Set-OwnTasks $root
$before=(Get-FileHash -LiteralPath (Join-Path $root 'settings.json')).Hash
$result=Invoke-AssistantCleanup $root $bundle Preview
Assert ($result.Success -and $result.CanRemove -and $result.RecoveryRequired) ('Valid configured preview rejected: '+$result.Error)
Assert ($script:events.Count -eq 0 -and $script:tasks.Count -eq 2) 'Preview mutated task or recovery state'
Assert ((Get-FileHash -LiteralPath (Join-Path $root 'settings.json')).Hash -eq $before) 'Preview rewrote settings'
Assert ($result.UnknownFiles -contains '我的文档.txt') 'Unknown file not identified for retention'
Assert (($result.Summary -split [Environment]::NewLine).Count -le 10) 'Summary too long for wizard'

# Broken uninstaller is irrelevant: trusted external lifecycle runs first, then
# only identified files and records are removed. Foreign port owners are never queried.
Reset-FixtureState;$root=New-Fixture 'broken-uninstaller' -Configured -Unknown;Set-OwnTasks $root
$ownPath=Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
$foreignPath=Join-Path $testRoot 'other\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
$script:processes=@([pscustomobject]@{Id=71;ProcessName='ESurfingClient-2.2.0-r4-windows-x86_64';Path=$ownPath;StartTime=[DateTime]::Now},[pscustomobject]@{Id=72;ProcessName='ESurfingClient-2.2.0-r4-windows-x86_64';Path=$foreignPath;StartTime=[DateTime]::Now})
$script:registrations=@([pscustomobject]@{Hive='LocalMachine';View='Registry64';Name='GDPortalShare-20261104_is1';InstallLocation=$root;DisplayName='校园网共享助手'},[pscustomobject]@{Hive='LocalMachine';View='Registry32';Name='GDPortalShare-20261104_is1';InstallLocation=(Join-Path $testRoot 'foreign-app');DisplayName='校园网共享助手'})
$script:shortcuts=@([pscustomobject]@{Path=(Join-Path $testRoot 'owned.lnk');OwnerRoot=$root},[pscustomobject]@{Path=(Join-Path $testRoot 'foreign.lnk');OwnerRoot=(Join-Path $testRoot 'other')})
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert $result.Success ('Broken-uninstaller cleanup failed: '+$result.Error)
Assert ($script:events -contains 'official' -and !$script:tasks.Count) 'Official restore or owned task removal was not performed'
Assert ($script:processes.Count -eq 1 -and $script:processes[0].Id -eq 72) 'Foreign same-name process was removed'
Assert ($script:registrations.Count -eq 1 -and $script:registrations[0].View -eq 'Registry32') 'Foreign installation record was removed'
Assert ($script:shortcuts.Count -eq 1 -and $script:shortcuts[0].Path -like '*foreign.lnk') 'Foreign shortcut was removed'
Assert (Test-Path -LiteralPath (Join-Path $root '我的文档.txt')) 'Unknown user file was removed'
Assert (!(Test-Path -LiteralPath (Join-Path $root 'settings.json')) -and !(Test-Path -LiteralPath (Join-Path $root 'unins000.exe'))) 'Managed configuration or damaged uninstaller remains'
Assert ([IO.File]::ReadAllText((Join-Path $root '.gdportalshare-cleaned')) -ceq 'GDPortalShare-20261104-cleaned-v1') 'Cleaned marker missing or has unexpected data'
$again=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert $again.Success 'Repeated cleanup with preserved unknown data failed'

# Missing backup and failed recovery retain the retryable installation.
Reset-FixtureState;$root=New-Fixture 'credential-temporaries' -Unknown
foreach($name in @('ESurfingClient.json.new','ESurfingClient.json.pending.new','ESurfingClient.json.1.logout')){[IO.File]::WriteAllText((Join-Path $root ('Client\'+$name)),'fictional account data')}
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and !(Test-Path (Join-Path $root 'Client\ESurfingClient.json.1.logout')) -and !(Test-Path (Join-Path $root 'Client\ESurfingClient.json.new')) -and !(Test-Path (Join-Path $root 'Client\ESurfingClient.json.pending.new'))) 'Known temporary credential files were retained'
Assert (Test-Path (Join-Path $root '我的文档.txt')) 'Credential cleanup removed an unrelated user file'

Reset-FixtureState;$root=New-Fixture 'missing-backup' -Configured
[IO.File]::Delete((Join-Path $root 'original-startup.json'))
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and !$script:events.Count) 'Missing backup permitted changes'
Assert ((Test-Path (Join-Path $root 'settings.json')) -and (Test-Path (Join-Path $root 'Panel.ps1'))) 'Missing-backup failure deleted files'
Reset-FixtureState;$root=New-Fixture 'failed-recovery' -Configured;Set-OwnTasks $root;$script:failRecovery=$true
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and $result.Stage -eq 'recovery') 'Recovery failure incorrectly reported success'
Assert ((Test-Path (Join-Path $root 'settings.json')) -and (Test-Path (Join-Path $root 'original-startup.json')) -and (Test-Path (Join-Path $root 'unins000.exe'))) 'Recovery failure deleted retry data'
$script:failRecovery=$false;$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and !(Test-Path -LiteralPath $root)) 'Retry after recovery failure did not fully remove known-only folder'

# A backup without settings must be restored, never treated as unconfigured.
Reset-FixtureState;$root=New-Fixture 'malformed-private-config' -Configured
[IO.File]::WriteAllText((Join-Path $root 'settings.json'),'{"username":"FAKE-SENSITIVE",')
$result=Invoke-AssistantCleanup $root $bundle Preview
Assert (!$result.CanRemove -and $result.Summary -notmatch 'FAKE-SENSITIVE' -and (Test-Path (Join-Path $root 'settings.json'))) 'Malformed configuration leaked private contents or was removed'

Reset-FixtureState;$root=New-Fixture 'backup-only' -BackupOnly;Set-OwnTasks $root
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and $script:events -contains 'official' -and !$script:tasks.Count) 'Backup-only partial install was not restored safely'
Reset-FixtureState;$root=New-Fixture 'unconfigured';Set-OwnTasks $root
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and $script:tasks.Count -eq 2 -and (Test-Path (Join-Path $root 'Panel.ps1'))) 'Unconfigured directory with orphan tasks was deleted'

# Product proof, confirmation and external worker placement are required.
Reset-FixtureState;$root=New-Fixture 'unknown-product';[IO.File]::Delete((Join-Path $root 'app-identity.json'))
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and (Test-Path (Join-Path $root 'Panel.ps1'))) 'Unrecognized folder was deleted'
Reset-FixtureState;$root=New-Fixture 'unconfirmed'
$result=Invoke-AssistantCleanup $root $bundle Remove
Assert (!$result.Success -and !$script:events.Count -and (Test-Path -LiteralPath $root)) 'Removal ran without user confirmation'
$result=Invoke-AssistantCleanup $root $root Remove -UserConfirmed
Assert (!$result.Success -and (Test-Path -LiteralPath $root)) 'Self cleanup ran from inside the target'
Reset-FixtureState;$root=New-Fixture 'self-root'
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and !(Test-Path -LiteralPath $root)) 'External worker could not clean its own former app directory'
Reset-FixtureState;$root=New-Fixture 'unknown-empty-folder'
[void][IO.Directory]::CreateDirectory((Join-Path $root '我的空文件夹'))
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and (Test-Path (Join-Path $root '我的空文件夹')) -and $result.PreservedFiles -contains '我的空文件夹\') 'Unknown empty folder was removed or not reported'

# Exact path guard, linked contents and target-specific UI process takeover.
foreach($bad in @('C:\',[IO.Path]::GetDirectoryName($env:USERPROFILE),$env:USERPROFILE,$env:ProgramFiles,(Join-Path $env:ProgramData 'CampusNetwork-Autostart'),(Join-Path ${env:ProgramFiles(x86)} 'Chinatelecom_GDPortal'))){
    $result=Invoke-AssistantCleanup $bad $bundle Remove -UserConfirmed
    Assert (!$result.Success) ('Protected root accepted: '+$bad)
}
Reset-FixtureState;$root=New-Fixture 'open-panel'
$native=Join-Path $root '校园网共享助手.exe';$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$panel=Join-Path $root 'Panel.ps1'
Add-UiFixtureProcess 81 $native ('"'+$native+'"')
Add-UiFixtureProcess 82 $ps ('"'+$ps+'" -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$panel+'" -FirstRun') 81
$result=Invoke-AssistantCleanup $root $bundle Preview
Assert ($result.CanRemove -and $result.OpenApplicationCount -eq 2 -and !$script:events.Count -and $script:processes.Count -eq 2) 'Preview did not offer confirmed takeover without stopping processes'
Assert (($result.UiProcesses|ConvertTo-Json -Depth 5) -notmatch 'CommandLine|ArgumentSignature|-ExecutionPolicy') 'UI process report leaked raw command parameters'
$foreignNative=Join-Path $testRoot 'other\校园网共享助手.exe'
Add-UiFixtureProcess 83 $foreignNative ('"'+$foreignNative+'" panel')
Add-UiFixtureProcess 84 $ps ('"'+$ps+'" -NoProfile -File "'+(Join-Path $testRoot 'other\Panel.ps1')+'"') 83
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and $result.ClosedApplicationCount -eq 2) ('Confirmed UI takeover failed: '+$result.Error)
Assert (($script:events|Where-Object {$_ -like 'ui-close:*'}) -join ',' -eq 'ui-close:82,ui-close:81') 'UI takeover did not close the exact Panel child before its wrapper'
Assert ($script:processes.Count -eq 2 -and @($script:processes|Where-Object {$_.Id -in @(83,84)}).Count -eq 2) 'Another installation UI was stopped'
Reset-FixtureState;$root=New-Fixture 'foreign-panel'
$foreignNative=Join-Path $testRoot 'other\校园网共享助手.exe'
Add-UiFixtureProcess 85 $foreignNative ('"'+$foreignNative+'"')
$result=Invoke-AssistantCleanup $root $bundle Preview
Assert $result.CanRemove 'Another installation panel incorrectly blocked selected target'

# Exact argv handling rejects fake -File text, extra script arguments, encoded
# commands, non-system PowerShell images and non-UI workflow wrapper modes.
Reset-FixtureState;$root=New-Fixture 'forged-ui';$native=Join-Path $root 'CampusQuietLauncher.exe';$panel=Join-Path $root 'Panel.ps1'
foreach($command in @(
    ('"'+$ps+'" -Command "Write-Host ''FAKE-SENSITIVE''; & '''+$panel+'''"'),
    ('"'+$ps+'" -EncodedCommand RkFLRQ== -File "'+$panel+'"'),
    ('"'+$ps+'" -c "& '''+$panel+'''"'),
    ('"'+$ps+'" -File "'+$panel+'" -FirstRun -Unknown'),
    ('"'+$ps+'" -File "'+(Join-Path $testRoot 'other\Panel.ps1')+'"')
)){
    Add-UiFixtureProcess (100+$script:uiRows.Count) $ps $command
}
$fakePS=Join-Path $testRoot 'unrelated\powershell.exe'
Add-UiFixtureProcess 110 $fakePS ('"'+$fakePS+'" -File "'+$panel+'"')
Add-UiFixtureProcess 111 $native ('"'+$native+'" startup')
Add-UiFixtureProcess 112 $native ('"'+$native+'" watch')
$snapshot=Get-CleanupUiProcessSnapshot $root
Assert (!$snapshot.Processes.Count -and !$snapshot.Unverified.Count) 'Non-UI or forged PowerShell command became a UI target'
$closed=Stop-CleanupUiProcesses $root $snapshot.Processes
Assert (!$closed.Count -and !$script:events.Count -and $script:processes.Count -eq 8) 'Non-UI process was terminated'
Add-UiFixtureProcess 113 $native ('"'+$native+'" -File "'+$panel+'"')
$result=Invoke-AssistantCleanup $root $bundle Preview
Assert (!$result.CanRemove -and !$script:events.Count -and $script:processes.Count -eq 9 -and $result.Summary -notmatch 'FAKE-SENSITIVE') 'Unverified target wrapper was closed or leaked command line'

# A reused PID or changed parameters must not be killed by a stale proof.
Reset-FixtureState;$root=New-Fixture 'reused-pid';$native=Join-Path $root '校园网共享助手.exe'
Add-UiFixtureProcess 121 $native ('"'+$native+'" panel')
$snapshot=Get-CleanupUiProcessSnapshot $root
$script:reuseOnOpenId=121
$closed=Stop-CleanupUiProcesses $root $snapshot.Processes
Assert (!$closed.Count -and !$script:events.Count -and $script:processes.Count -eq 1) 'Handle-time PID reuse was terminated'
Reset-FixtureState;$root=New-Fixture 'changed-ui-arguments';$native=Join-Path $root '校园网共享助手.exe'
Add-UiFixtureProcess 122 $native ('"'+$native+'" panel')
$snapshot=Get-CleanupUiProcessSnapshot $root
$script:uiRows[0].CommandLine='"'+$native+'" startup'
$closed=Stop-CleanupUiProcesses $root $snapshot.Processes
Assert (!$closed.Count -and !$script:events.Count -and $script:processes.Count -eq 1) 'Changed wrapper arguments were terminated'

# Closing the hidden UI still cannot bypass restoration failure or consent.
Reset-FixtureState;$root=New-Fixture 'running-ui-unconfirmed' -Configured;$native=Join-Path $root '校园网共享助手.exe'
Add-UiFixtureProcess 130 $native ('"'+$native+'"')
$result=Invoke-AssistantCleanup $root $bundle Remove
Assert (!$result.Success -and $script:processes.Count -eq 1 -and !$script:events.Count) 'UI was closed without confirmation'
$script:failRecovery=$true
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and $result.Stage -eq 'recovery' -and !$script:processes.Count -and (Test-Path (Join-Path $root 'settings.json')) -and (Test-Path (Join-Path $root 'original-startup.json')) -and (Test-Path (Join-Path $root 'Panel.ps1'))) 'Recovery failure after UI takeover deleted retry files'
Reset-FixtureState;$root=New-Fixture 'junction';$outside=Join-Path $testRoot 'outside';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'keep')
$junction=Join-Path $root 'linked'
New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop | Out-Null
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and (Test-Path (Join-Path $outside 'keep.txt')) -and (Test-Path (Join-Path $root 'Panel.ps1'))) 'Linked target was traversed or partially deleted'

# Absent targets still remove only exact stale shortcut/registry ownership.
Reset-FixtureState;$root=Join-Path $testRoot 'already-absent'
$script:shortcuts=@([pscustomobject]@{Path=(Join-Path $testRoot 'absent-owned.lnk');OwnerRoot=$root})
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and $result.AlreadyAbsent -and !$script:shortcuts.Count) 'Absent target shortcut was not cleaned'
Assert ($script:events -notcontains 'network' -and $script:events -notcontains 'official') 'Absent target modified network settings'
Set-OwnTasks $root
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert (!$result.Success -and !$result.CanRemove -and $script:tasks.Count -eq 2) 'Absent target with live owned tasks claimed complete cleanup'
Reset-FixtureState;$root=New-Fixture 'foreign-task-unconfigured';Set-OwnTasks (Join-Path $testRoot 'other-live-install')
$result=Invoke-AssistantCleanup $root $bundle Remove -UserConfirmed
Assert ($result.Success -and $script:tasks.Count -eq 2) 'Foreign installation tasks blocked or were removed from unconfigured target'

[IO.File]::WriteAllText((Join-Path $testRoot 'result.txt'),('PASS '+$script:checks),[Text.UTF8Encoding]::new($false))
'PASS: '+$script:checks+' cleanup assertions; preview, guarded ownership, broken uninstall, restoration retry, unknown retention, backup-only, self-removal and path/link refusal.'
