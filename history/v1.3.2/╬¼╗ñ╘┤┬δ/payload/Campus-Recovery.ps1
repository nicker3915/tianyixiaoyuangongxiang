param(
 [ValidateSet('Status','Repair','Hotspot','Force','Pause','Resume','Stop')][string]$Mode='Status',
 [switch]$Interactive,
 [switch]$DryRun
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
$root=$PSScriptRoot
$resultPath=Join-Path $root 'recovery-last-result.json'
$pausePath=Join-Path $root 'watchdog-paused.flag'
if(!(Test-Path -LiteralPath (Join-Path $root 'settings.json'))){Write-Host '请先从开始菜单完成首次设置。';if($Interactive){[void](Read-Host '按回车关闭')};exit 1}
$settings=[IO.File]::ReadAllText((Join-Path $root 'settings.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
$watchName=$settings.TaskName+'-Watchdog'
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Show-Result($item) {
 Write-Host ''
 Write-Host $item.Message -ForegroundColor Cyan
 if($item.Details){$item.Details | ConvertTo-Json -Depth 5 | Write-Host}
 if($Interactive){[void](Read-Host '按回车关闭')}
}
if(-not $isAdmin -and $Mode -ne 'Status'){
 try {
  $argsText='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode '+$Mode
  if($DryRun){$argsText+=' -DryRun'}
  $began=[DateTimeOffset]::Now
  $process=Start-Process -FilePath $powerShell -Verb RunAs -WindowStyle Hidden -ArgumentList $argsText -PassThru
  # Wait only for recovery itself, not the official client it launches.
  $process.WaitForExit()
  $item=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
  if($item.Mode -ne $Mode -or [DateTimeOffset]::Parse($item.Time) -lt $began.AddSeconds(-2)){throw 'No fresh recovery result'}
  Show-Result $item
  exit $process.ExitCode
 } catch {
  Show-Result ([pscustomobject]@{Message='操作未完成。若取消了管理员授权，请重新打开对应入口。';Details=$null})
  exit 1
 }
}
$result=[ordered]@{Time=[DateTimeOffset]::Now.ToString('o');Mode=$Mode;Success=$false;Message='';Details=$null}
$operationLock=$null
$lock=$null;$lockHeld=$false;$ownPauseToken=$null;$requestStartup=$false;$exitCode=0
function Api([string]$path,[switch]$Post) {
 $temp=Join-Path $root ('recovery-api-'+[Guid]::NewGuid().ToString('N')+'.tmp')
 try {
  $argsList=@('--noproxy','*','--silent','--max-time','5','--output',$temp)
  if($Post){$argsList+=@('--request','POST')}
  $argsList+=('http://127.0.0.1:'+$settings.ManagementPort+$path)
  & (Join-Path $env:SystemRoot 'System32\curl.exe') @argsList
  if($LASTEXITCODE -ne 0){throw 'ManagementApiUnavailable'}
  [IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8) | ConvertFrom-Json
 } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function Campus {
 $adapter=Get-NetAdapter | Where-Object {([Guid]$_.InterfaceGuid) -eq [Guid]$settings.CampusAdapterGuid} | Select-Object -First 1
 if(-not $adapter -or $adapter.Status -ne 'Up' -or !(Test-CampusProfile $adapter $settings)){return $null}
 $ip=Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {(Test-CampusSubnet $_.IPAddress $settings.SubnetReference $settings.SubnetBits) -and [string]$_.AddressState -eq 'Preferred'} | Select-Object -First 1
 $route=Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $settings.ExpectedGateway} | Select-Object -First 1
 if($ip -and $route){return [pscustomobject]@{Ip=$ip.IPAddress;Index=$adapter.ifIndex}}
 $null
}
function Managed-Processes {
 $items=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($settings.ClientPath)) -ErrorAction SilentlyContinue)
 foreach($item in $items){
  if(-not $item.Path){throw 'ProcessIdentityUnknown'}
  if([string]::Equals([IO.Path]::GetFullPath($item.Path),[IO.Path]::GetFullPath($settings.ClientPath),[StringComparison]::OrdinalIgnoreCase)){
   [pscustomobject]@{Id=$item.Id;StartTicks=[string]$item.StartTime.Ticks;Path=$item.Path}
  }
 }
}
function Check-Owner($members) {
 $ids=@($members | ForEach-Object {$_.Id})
 foreach($listener in @(Get-NetTCPConnection -LocalPort $settings.ManagementPort -State Listen -ErrorAction SilentlyContinue)){
  if($listener.OwningProcess -notin $ids){throw 'ManagementPortOwnedByAnotherProcess'}
 }
}
function Lock-Network {
 $script:lock=New-Object Threading.Mutex($false,('Global\CampusNetwork-'+([Guid]$settings.CampusAdapterGuid).ToString('N')))
 try {$script:lockHeld=$script:lock.WaitOne(10000)} catch [Threading.AbandonedMutexException] {$script:lockHeld=$true}
 if(-not $script:lockHeld){throw 'StartupOrAnotherRepairIsRunning'}
}
function Native-State {
 [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
 [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
 $profile=[Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() | Where-Object {[string]$_.NetworkAdapter.NetworkAdapterId -eq ([Guid]$settings.CampusAdapterGuid).ToString()} | Select-Object -First 1
 if(-not $profile){throw 'CampusProfileMissing'}
 $manager=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
 [pscustomobject]@{State=[string]$manager.TetheringOperationalState;Clients=[int]$manager.ClientCount}
}
function Request-Hotspot([string]$action) {
 $wait=[Diagnostics.Stopwatch]::StartNew()
 do {
  $state=Api '/api/hotspot/status'
  if(-not $state.busy){break}
  Start-Sleep -Seconds 1
 } while($wait.Elapsed.TotalSeconds -lt 35)
 if($state.busy){throw 'HotspotControllerBusy'}
 Api ('/api/hotspot/'+$action+'?adapter='+([Guid]$settings.CampusAdapterGuid).ToString()) -Post
}
function Wait-Hotspot([string]$expected) {
 $timer=[Diagnostics.Stopwatch]::StartNew()
 do {
  Start-Sleep -Seconds 1
  $apiState=Api '/api/hotspot/status'
  $native=Native-State
  if($native.State -eq $expected -and -not $apiState.busy){return}
 } while($timer.Elapsed.TotalSeconds -lt 35)
 throw ('HotspotStateTimeout-'+$expected)
}
try {
 if($Mode -ne 'Status' -and !$DryRun){
  $operationLock=Enter-AssistantOperation
  if(Test-Path (Join-Path $root 'uninstall-in-progress.flag')){throw '请先完成卸载恢复。'}
 }
 if($DryRun -and $Mode -notin @('Status','Force','Hotspot')){
  $result.Message='仅预览，不改变任务、认证或网络设置。'
  $result.Details=@{WouldInvokeMode=$Mode}
 } elseif($Mode -eq 'Status'){
  $task=Get-ScheduledTask -TaskName $settings.TaskName -ErrorAction SilentlyContinue
  $watch=Get-ScheduledTask -TaskName $watchName -ErrorAction SilentlyContinue
  $startup=[IO.File]::ReadAllText((Join-Path $root 'last-status.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
  $auth=$null
  try {$auth=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$settings.ManagementPort+'/api/status/auth') -TimeoutSec 4} catch {}
  $hotspot=$null
  try {$hotspot=Native-State} catch {}
  $result.Details=[ordered]@{AutoStartEnabled=[bool]$task.Settings.Enabled;WatchdogEnabled=[bool]$watch.Settings.Enabled;Paused=(Test-Path -LiteralPath $pausePath);LastStartup=$startup.Result;LastStartupTime=$startup.CompletedAt;LastStage=$startup.Stage;LastError=$startup.Error;AuthReported=[bool]$auth.status;Hotspot=$hotspot}
  if(Test-Path -LiteralPath (Join-Path $root 'watchdog-status.json')){$result.Details.Watchdog=[IO.File]::ReadAllText((Join-Path $root 'watchdog-status.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json}
  $result.Message='这是当前自动任务、认证进程与热点状态。认证状态正常不代表手机一定能上网。'
 } elseif($Mode -eq 'Stop'){
  Stop-AssistantLifecycle $root
  Start-OfficialClient $root
  $result.Message='助手已停止，热点和独立认证已关闭，官方启动设置已恢复。请在官方客户端登录；下次使用可点击启动共享。'
 } elseif($Mode -eq 'Pause'){
  Lock-Network
  [IO.File]::WriteAllText($pausePath,'user-paused',[Text.UTF8Encoding]::new($false))
  Disable-ScheduledTask -TaskName $watchName -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName $settings.TaskName | Out-Null
  $result.Message='已暂停开机自动认证与崩溃守护。当前连接不会被停止。需要恢复时打开“恢复自动运行”。'
 } elseif($Mode -eq 'Resume'){
  Resume-AssistantLifecycle $root
  $requestStartup=$true
  $result.Message='已请求启动共享。请等待认证和热点开启，再用手机测试。'
 } else {
  if(-not (Campus)){throw 'CampusCableOrAddressNotReady'}
  $task=Get-ScheduledTask -TaskName $settings.TaskName
  if(-not $task.Settings.Enabled -or (Test-Path -LiteralPath $pausePath)){throw 'AutomaticModePaused-UseResumeFirst'}
  if($Mode -eq 'Repair'){
   $requestStartup=$true
   $result.Message='已请求安全修复：复用现有认证，不主动断开正常连接。最多等待数分钟，再打开“查看状态”。'
  } else {
   Lock-Network
   $lockedTask=Get-ScheduledTask -TaskName $settings.TaskName
   if(-not $lockedTask.Settings.Enabled -or (Test-Path -LiteralPath $pausePath)){throw 'AutomaticModePausedDuringRecovery'}
   $members=@(Managed-Processes)
   Check-Owner $members
   if($Mode -eq 'Hotspot'){
    if($DryRun){$result.Details=@{WouldRestartHotspot=$true;WouldStopAuthentication=$false};$result.Message='仅预览，不改网络。'}
    else {
     $auth=Api '/api/status/auth'
     if(-not $auth.status){throw 'AuthenticationNotReady-UseRepairFirst'}
     $id=([Guid]$settings.CampusAdapterGuid).ToString()
     try {
      $response=Request-Hotspot 'stop'
      if(-not $response.ok){throw 'HotspotStopRejected'}
      Wait-Hotspot 'Off'
     } finally {
      $response=Request-Hotspot 'start'
      if(-not $response.ok){throw 'HotspotStartRejected'}
     }
     Wait-Hotspot 'On'
     $result.Message='热点已重新开启。电脑认证未重启；请让手机重新连接并测试新网页。'
    }
   } else {
    if((Get-FileHash -LiteralPath $settings.ClientPath -Algorithm SHA256).Hash -ne $settings.ExecutableSha256){throw 'ClientFileChanged-DoNotRestartUnverifiedFile'}
    if($DryRun){$result.Details=@{WouldStopProcessIds=@($members.Id);WouldStartTask=$settings.TaskName};$result.Message='强制修复预览完成，没有停止任何程序。'}
    else {
     $lockedTask=Get-ScheduledTask -TaskName $settings.TaskName
     if(-not $lockedTask.Settings.Enabled -or (Test-Path -LiteralPath $pausePath)){throw 'AutomaticModePausedBeforeForce'}
     $ownPauseToken=[Guid]::NewGuid().ToString('N')
     $tokenFile=[IO.File]::Open($pausePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
     try {$tokenBytes=[Text.Encoding]::UTF8.GetBytes($ownPauseToken);$tokenFile.Write($tokenBytes,0,$tokenBytes.Length)} finally {$tokenFile.Dispose()}
     $parents=@(Get-CimInstance Win32_Process | Where-Object {$_.ProcessId -in @($members.Id)} | Select-Object ProcessId,ParentProcessId)
     $ordered=@($members | Sort-Object @{e={$entry=$_;$row=$parents | Where-Object {$_.ProcessId -eq $entry.Id};if($row.ParentProcessId -notin @($members.Id)){0}else{1}}})
     foreach($member in $ordered){
      $current=Get-Process -Id $member.Id -ErrorAction SilentlyContinue
      if($current -and $current.Path -and [string]$current.StartTime.Ticks -eq $member.StartTicks -and [string]::Equals($current.Path,$settings.ClientPath,[StringComparison]::OrdinalIgnoreCase)){
       Stop-Process -Id $current.Id -Force -ErrorAction SilentlyContinue
      }
     }
     Start-Sleep -Seconds 1
     if(@(Managed-Processes).Count){throw 'ManagedProcessesStillRunning'}
     $requestStartup=$true
     $result.Message='已停止已核实的第三方认证进程，并请求重新认证。电脑和手机会短暂断网；请等待数分钟后查看状态。'
    }
   }
  }
 }
 $result.Success=$true
} catch {
 $exitCode=1
 $result.Message='操作未完成。请检查校园 Wi-Fi 或网线、查看状态；若反复失败，可恢复官方启动后手动重启电脑。'
 $result.Details=@{Reason=$_.Exception.Message}
 if($Mode -in @('Stop','Resume')){$result.Message=$_.Exception.Message}
} finally {
 if($ownPauseToken -and (Test-Path -LiteralPath $pausePath)){
  if([IO.File]::ReadAllText($pausePath).Trim() -eq $ownPauseToken){Remove-Item -LiteralPath $pausePath -Force}
 }
 if($lockHeld -and $lock){$lock.ReleaseMutex()}
 if($lock){$lock.Dispose()}
 if($operationLock){$operationLock.ReleaseMutex();$operationLock.Dispose()}
}
if($requestStartup -and $result.Success){
 try {
  $task=Get-ScheduledTask -TaskName $settings.TaskName
  if(-not $task.Settings.Enabled -or (Test-Path -LiteralPath $pausePath)){throw 'PausedBeforeRecoveryStart'}
  if($task.State -ne 'Running'){Start-ScheduledTask -TaskName $settings.TaskName}
 } catch {
  $exitCode=1;$result.Success=$false;$result.Message='启动任务未能开始，请重试或切回官方客户端。';$result.Details=@{Reason=$_.Exception.Message}
  if($Mode -eq 'Resume'){
   $rollbackLock=$null
   try {
    $rollbackLock=Enter-AssistantOperation
    Stop-AssistantLifecycle $root
    $result.Message='启动任务未能开始，助手已停止并恢复官方设置。可使用官方客户端登录。'
   } catch {$result.Message='启动未完成，恢复也需要处理，请点击停止并切回官方重试。'}
   finally {if($rollbackLock){$rollbackLock.ReleaseMutex();$rollbackLock.Dispose()}}
  }
 }
}
if($isAdmin){[IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if($Interactive){Show-Result ([pscustomobject]$result)} else {$result | ConvertTo-Json -Depth 6}
exit $exitCode
