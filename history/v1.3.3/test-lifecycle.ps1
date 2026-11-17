$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'payload\Lifecycle.ps1')
$testRoot=Join-Path $PSScriptRoot ('validation\lifecycle-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($ok,$message){if(!$ok){throw $message}}
$adapter=[guid]::NewGuid()
$cfg=@{TaskName='GDPortalShare-Logon';ClientPath=(Join-Path $testRoot 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe');CampusAdapterGuid=$adapter.ToString();ExpectedGateway='192.0.2.1';CampusMetric=10}
$backup=@{Adapter=$adapter.ToString();Gateway='192.0.2.1';RunExists=$false;ServiceAuto=$false}
Write-LifecycleJson (Join-Path $testRoot 'settings.json') $cfg
Write-LifecycleJson (Join-Path $testRoot 'original-startup.json') $backup
$before=(Get-FileHash (Join-Path $testRoot 'original-startup.json')).Hash
Set-AssistantState $testRoot 'running' 'test'
Set-AssistantState $testRoot 'stopping' 'test'
Assert ((Read-LifecycleJson (Join-Path $testRoot 'assistant-state.json')).State -eq 'stopping') 'Atomic rewrite failed'
$script:events=@();$script:hotspot='On';$script:owned=$true;$script:official=$false
function Get-LifecycleTasks($Context){@([pscustomobject]@{TaskName='GDPortalShare-Logon'},[pscustomobject]@{TaskName='GDPortalShare-Logon-Watchdog'})}
function Disable-ScheduledTask($InputObject){$script:events+='disable'}
function Enable-ScheduledTask($InputObject){$script:events+='enable'}
function Stop-ScheduledTask($TaskName,$TaskPath){$script:events+='task-stop'}
function Unregister-ScheduledTask($TaskName,$TaskPath,[switch]$Confirm){$script:events+='unregister'}
function Get-LifecycleHotspotOwnership($Context){$script:owned}
$script:publicIds=@($adapter.ToString());$script:activeIds=@($adapter.ToString());$script:complete=$true
function Get-LifecycleHotspot($Context){[pscustomobject]@{State=$script:hotspot;PublicAdapterIds=$script:publicIds;ManagerAdapterId=$adapter.ToString();ActiveAdapterIds=$script:activeIds;ProfilesComplete=$script:complete}}
function Stop-LifecycleNativeHotspot($Snapshot){$script:events+='hotspot-stop';$script:hotspot='Off'}
function Stop-LifecycleProcesses($Context){$script:events+='process-stop'}
function Restore-LifecycleNetwork($Context){$script:events+='network-restore'}
function Restore-LifecycleOfficial($Context){$script:events+='official-restore'}
function Get-ConfiguredCampusCandidates($Settings){[pscustomobject]@{Id=$adapter}}
function Get-Process($Name){if($script:official){[pscustomobject]@{Id=42}}}
Stop-AssistantLifecycle $testRoot
Assert ((Read-LifecycleJson (Join-Path $testRoot 'assistant-state.json')).State -eq 'stopped') 'Stop state missing'
Assert (Test-Path (Join-Path $testRoot 'watchdog-paused.flag')) 'Stop did not stay paused'
Assert ([array]::IndexOf($script:events,'hotspot-stop') -lt [array]::IndexOf($script:events,'process-stop')) 'Auth killed before hotspot stop'
Assert ($script:events -notcontains 'unregister') 'Stop removed tasks'
Stop-AssistantLifecycle $testRoot
Assert ((Get-FileHash (Join-Path $testRoot 'original-startup.json')).Hash -eq $before) 'Stop overwrote baseline'
Assert (Test-Path (Join-Path $testRoot 'settings.json')) 'Stop removed settings'
$script:events=@();$script:hotspot='On';$script:owned=$false
$failed=$false;try{Stop-AssistantLifecycle $testRoot}catch{$failed=$true}
Assert $failed 'Foreign hotspot was not rejected'
Assert ($script:events -notcontains 'hotspot-stop' -and $script:events -notcontains 'process-stop') 'Unknown hotspot was changed'
Assert ((Read-LifecycleJson (Join-Path $testRoot 'assistant-state.json')).State -eq 'needs-attention') 'Failure was reported as success'
$script:owned=$true;$script:publicIds=@();$script:events=@();$script:activeIds+=([guid]::NewGuid().ToString())
Stop-AssistantLifecycle $testRoot
Assert ($script:events -contains 'hotspot-stop') 'Modern owned hotspot without legacy ICS was not stopped'
foreach($case in @('foreign-public','unowned-modern','incomplete')){
    $script:hotspot='On';$script:events=@();$script:publicIds=@();$script:activeIds=@($adapter.ToString());$script:complete=$true
    switch($case){
        'foreign-public' {$script:publicIds=@([guid]::NewGuid().ToString())}
        'unowned-modern' {$script:owned=$false}
        'incomplete' {$script:complete=$false}
    }
    $failed=$false;try{Stop-AssistantLifecycle $testRoot}catch{$failed=$true}
    Assert ($failed -and $script:events -notcontains 'hotspot-stop') ('Ambiguous hotspot was stopped: '+$case)
    $script:owned=$true
}
$script:publicIds=@($adapter.ToString());$script:activeIds=@($adapter.ToString());$script:complete=$true
$script:official=$true;$script:events=@();$failed=$false
try{Resume-AssistantLifecycle $testRoot}catch{$failed=$true}
Assert ($failed -and !$script:events.Count) 'Official conflict mutated tasks'
$script:official=$false;$script:hotspot='Off';$script:owned=$true
Resume-AssistantLifecycle $testRoot
Assert (!(Test-Path (Join-Path $testRoot 'watchdog-paused.flag'))) 'Resume retained pause marker'
Assert ((Read-LifecycleJson (Join-Path $testRoot 'assistant-state.json')).State -eq 'start-requested') 'Resume state missing'
Assert (@($script:events|Where-Object {$_ -eq 'enable'}).Count -eq 2) 'Resume failed to enable tasks'
Stop-AssistantLifecycle $testRoot -Uninstall
Assert (@($script:events|Where-Object {$_ -eq 'unregister'}).Count -eq 2) 'Uninstall did not remove own tasks'
'PASS: lifecycle atomic state, stop ordering, repeat stop, preserved baseline, foreign hotspot refusal, official conflict, resume and uninstall.'
