$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot 'stage'
. (Join-Path $base 'Network.ps1')
function Assert($b,$msg){if(!$b){throw $msg}}
foreach($f in Get-ChildItem -LiteralPath $base -Filter '*.ps1'){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($f.Name+': '+$errors[0].Message)}
}
$watch=(& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'Watch-CampusNetwork.ps1') -SelfTest)|ConvertFrom-Json
Assert ($watch.Passed -and $watch.TestCount -eq 13) 'watchdog tests'
Assert (Test-CampusSubnet '172.16.17.254' '172.16.16.1' 23) 'subnet: DHCP within subnet'
Assert (!(Test-CampusSubnet '172.16.18.1' '172.16.16.1' 23)) 'subnet: outside'
Assert (!(Test-CampusSubnet '10.0.100.5' '10.0.10.9' 24)) 'subnet: textual prefix collision'
Assert (!(Test-CampusSubnet 'bad' '10.0.10.9' 24)) 'invalid'
$data=New-AccountConfig ' 测试号 ' 'Q"&\中文 #1' 18899
$cfg=$data|ConvertTo-Json -Depth 8|ConvertFrom-Json
Assert ($cfg.accounts[0].username -ceq '测试号' -and $cfg.accounts[0].password -ceq 'Q"&\中文 #1' -and $cfg.accounts[0].channel -eq 'windows' -and !$cfg.web_external_acc -and $cfg.web_port -eq 18899) 'account round trip'
try{$null=New-AccountConfig ' ' 'x' 18899;$bad=$true}catch{$bad=$false}
Assert (!$bad) 'empty user accepted'
Import-Module ScheduledTasks -ErrorAction Stop
Import-Module NetAdapter -ErrorAction Stop
Import-Module NetTCPIP -ErrorAction Stop
# Run the actual snapshot / restore / registration functions against fake services, registry and task objects.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $base 'Manage.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Register-Work','Save','Read-Json','Test-LegacyMetricManaged','Restore','Get-OwnTasks','Snapshot')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$startSource=[IO.File]::ReadAllText((Join-Path $base 'Start-CampusNetwork.ps1'),[Text.Encoding]::UTF8)
$startAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $base 'Start-CampusNetwork.ps1'),[ref]$null,[ref]$null)
$addRouteAst=$startAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-AuthRoute'},$true)
Assert ($startSource -notmatch 'Set-NetIPInterface') 'startup must not rewrite a global interface metric'
Assert ($startSource -match 'Assert-AuthRoutesUncontended') 'startup must preflight all route conflicts'
Assert ($addRouteAst -and $addRouteAst.Extent.Text -notmatch 'Remove-NetRoute') 'startup must not delete a foreign authentication route'
$manageSource=[IO.File]::ReadAllText((Join-Path $base 'Manage.ps1'),[Text.Encoding]::UTF8)
Assert ($manageSource -match "MetricPolicy='preserve-system'") 'new configurations must preserve system metrics'
$root=Join-Path ([IO.Path]::GetTempPath()) ('GDPortal-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$journal=Join-Path $root 'original-startup.json';$task='GDPortalShare-Logon';$launcher=Join-Path $root 'CampusQuietLauncher.exe'
$net=[pscustomobject]@{Index=503;Id=[guid]::NewGuid().ToString();Gateway='192.0.2.1'}
$exe=Join-Path $root 'fake.exe';$runPath='FakeRun:';$runName='Esurfing Client in Campus';$svcKey='FakeSvc:'
$script:taskMap=@{};$script:svc=2;$script:run='"C:\Program Files (x86)\Chinatelecom_GDPortal\AutoStart.exe"';$script:delayed=1
function Get-Item($LiteralPath){
    $o=[pscustomobject]@{}
    $o|Add-Member ScriptMethod GetValueNames {if($script:run){@('Esurfing Client in Campus')}else{@()}}
    $o|Add-Member ScriptMethod GetValue {$script:run}
    $o|Add-Member ScriptMethod GetValueKind {'String'}
    $o
}
function Get-ItemProperty($LiteralPath,$Name){if($LiteralPath -eq $svcKey){[pscustomobject]@{Start=$script:svc;DelayedAutoStart=$script:delayed;ImagePath='"C:\Program Files (x86)\Chinatelecom_GDPortal\ESurfingSvr.exe"'}}elseif($script:run){$script:run}}
function Set-Service($Name,$StartupType){if($StartupType -eq 'Automatic'){$script:svc=2}else{throw 'unexpected service change'}}
function Set-ItemProperty($LiteralPath,$Name,$Value){$script:delayed=$Value}
function New-ItemProperty($LiteralPath,$Name,$Value,$PropertyType){$script:run=$Value}
function Test-Path($LiteralPath){if($LiteralPath -eq $svcKey){return $true};return [IO.File]::Exists($LiteralPath)}
function Get-NetIPInterface { [pscustomobject]@{AutomaticMetric='Enabled';InterfaceMetric=25} }
function Get-NetAdapter { [pscustomobject]@{InterfaceGuid=[guid]$net.Id;ifIndex=503} }
function Get-Process { @() }
function Get-ScheduledTask($TaskName){if($script:taskMap.ContainsKey($TaskName)){$script:taskMap[$TaskName]}}
function Unregister-ScheduledTask($TaskName,$Confirm){$script:taskMap.Remove($TaskName)}
function Disable-ScheduledTask($InputObject){$InputObject.State='Disabled'}
function Register-ScheduledTask($TaskName,$Action,$Trigger,$Principal,$Settings,$TaskPath){
    Assert ($TaskPath -eq '\' -and [string]$Principal.RunLevel -eq 'Highest' -and $Principal.UserId -in @($sid,[Environment]::UserName,[Security.Principal.WindowsIdentity]::GetCurrent().Name)) 'registration principal'
    Assert ($Trigger.UserId -eq $sid -and $Trigger.Delay -match '^PT') 'logon trigger'
    if($TaskName -like '*Watchdog'){Assert ($Trigger.Repetition.Interval -eq 'PT1M') 'watch interval'}
    $script:taskMap[$TaskName]=[pscustomobject]@{TaskName=$TaskName;State='Ready';Actions=@($Action)}
}
try{
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $b=Snapshot $net;Assert ($b.RunExists -and $b.ServiceAuto -and $b.Delayed -eq 1) 'official startup backup incomplete'
    Save $journal $b;Save $journal $b
    if ((Get-Command Register-ScheduledTask).ModuleName) {throw 'Test isolation failed'}
    Register-Work $task 'startup' 'PT15S' $false
    Register-Work ($task+'-Watchdog') 'watch' 'PT90S' $true
    Assert ($script:taskMap.Count -eq 2) 'both tasks'
    $script:run=$null;$script:svc=3;$script:delayed=0
    Restore
    Assert ($script:run -ceq $b.RunValue -and $script:svc -eq 2 -and $script:delayed -eq 1 -and !$script:taskMap.Count) 'restore official settings and remove owned tasks'
    $script:run='"C:\Another.exe"'
    try{$null=Snapshot $net;$bad=$true}catch{$bad=$false}
    Assert (!$bad) 'unknown startup accepted'
    $script:taskMap[$task]=[pscustomobject]@{Actions=@([pscustomobject]@{Execute='foreign.exe'})}
    try{Restore;$bad=$true}catch{$bad=$false}
    Assert (!$bad -and $script:taskMap.Count -eq 1) 'foreign task touched'
}finally{if([IO.File]::Exists($journal)){[IO.File]::Delete($journal)};$flag=Join-Path $root 'watchdog-paused.flag';if([IO.File]::Exists($flag)){[IO.File]::Delete($flag)};[IO.Directory]::Delete($root,$false)}
'PASS: PowerShell syntax, 13 watchdog decisions, CIDR, credentials, scheduled trigger construction, startup backup/restore, conflicts.'

