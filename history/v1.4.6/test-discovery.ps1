$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'payload\Cleanup.Core.ps1')
. (Join-Path $PSScriptRoot 'payload\Cleanup.Discovery.ps1')
$testRoot=Join-Path $PSScriptRoot ('validation\discovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:checks=0
function Assert($ok,[string]$message){if(!$ok){throw $message};$script:checks++}
function New-ProductDirectory([string]$Name){
    $path=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'app-identity.json'),'{"ProductId":"GDPortalShare","Schema":1}',[Text.UTF8Encoding]::new($true))
    return $path
}
$script:registrations=@();$script:tasks=@();$script:processes=@();$script:shortcuts=@();$script:defaults=@()
function Get-DiscoveryRegistrationRecords{$script:registrations}
function Get-DiscoveryTaskRecords{$script:tasks}
function Get-DiscoveryProcessRecords{$script:processes}
function Get-DiscoveryShortcutRecords{$script:shortcuts}
function Get-DiscoveryDefaultRoots{$script:defaults}
# Any accidental network mutation, task change, process termination or directory
# enumeration beyond exact identities must fail the test immediately.
function Set-NetIPInterface{throw 'Discovery attempted network mutation'}
function Remove-NetRoute{throw 'Discovery attempted route removal'}
function Disable-ScheduledTask{throw 'Discovery attempted task mutation'}
function Unregister-ScheduledTask{throw 'Discovery attempted task removal'}
function Stop-Process{throw 'Discovery attempted process termination'}
function Start-Process{throw 'Discovery attempted process launch'}
function Remove-Item{throw 'Discovery attempted deletion'}
function Get-ChildItem{throw 'Discovery attempted directory scanning'}

$root=New-ProductDirectory 'Installed App'
$script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$root;UninstallString=''})
$script:defaults=@($root)
$before=[IO.File]::ReadAllBytes((Join-Path $root 'app-identity.json'))
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 1 -and $found[0].Registered -and $found[0].Exists) 'Registered default installation was not found automatically'
Assert ($found[0].Sources.Count -eq 2) 'Default and registry sources were not merged'
Assert ($found[0].TargetRoot -ceq $root) 'Discovery changed the actual installation path'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'app-identity.json'))) -ceq [Convert]::ToBase64String($before)) 'Discovery changed the product identity'

# Missing InstallLocation falls back to parsing only a known uninstaller name;
# the command itself is never executed.
$fallback=New-ProductDirectory 'Old App With Spaces'
$script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry32';DisplayName='校园网共享助手 1.1.1';InstallLocation='';UninstallString=('"'+(Join-Path $fallback 'unins000.exe')+'" /SILENT')})
$script:defaults=@()
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 1 -and $found[0].TargetRoot -eq $fallback -and $found[0].Registered) 'UninstallString fallback failed'
Assert ($null -eq (Get-DiscoveryUninstallRoot 'cmd.exe /c C:\somewhere\unins000.exe')) 'An arbitrary uninstall command was accepted'
Assert ($null -eq (Get-DiscoveryUninstallRoot 'C:\fake\different.exe /uninstall')) 'Another uninstaller basename was accepted'
Assert ((Get-DiscoveryUninstallRoot ((Join-Path $fallback 'unins000.exe')+' /SILENT')) -eq $fallback) 'Unquoted legitimate uninstall path was not parsed'

# The same directory found through exact tasks, process paths and shortcuts must
# be listed only once. No credential or process command-line is read.
$script:registrations=@()
$script:tasks=@([pscustomobject]@{TaskName='GDPortalShare-Logon';Execute=(Join-Path $root 'CampusQuietLauncher.exe');Arguments='startup'},[pscustomobject]@{TaskName='GDPortalShare-Logon-Watchdog';Execute=(Join-Path $root 'CampusQuietLauncher.exe');Arguments='watch'})
$script:processes=@([pscustomobject]@{ProcessName='校园网共享助手';Path=(Join-Path $root '校园网共享助手.exe')},[pscustomobject]@{ProcessName='ESurfingClient-2.2.0-r4-windows-x86_64';Path=(Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe')})
$script:shortcuts=@([pscustomobject]@{Name='校园网共享助手.lnk';TargetPath=(Join-Path $root '校园网共享助手.exe')})
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 1 -and $found[0].Sources.Count -eq 3) 'Task/process/shortcut candidates were not deduplicated'
Assert (!$found[0].Registered -and $found[0].Label -like '已找到助手目录*') 'Non-registry evidence was mislabeled'
Assert ($found[0].PSObject.Properties.Name -notcontains 'CommandLine') 'Discovery exposed command-line contents'

# Preserve a registered but missing directory so residual records are visible.
$missing=Join-Path $testRoot 'Missing App'
$script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$missing;UninstallString=''})
$script:tasks=@();$script:processes=@();$script:shortcuts=@()
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 1 -and !$found[0].Exists -and $found[0].Registered) 'Missing registered directory was hidden'
Assert ($found[0].Label -like '目录已不存在*') 'Missing directory was claimed to exist'

# A similar process name or wrong registration brand must not recommend a
# foreign directory, and task names/arguments are checked independently.
$foreign=Join-Path $testRoot 'Other Product';[void][IO.Directory]::CreateDirectory($foreign)
[IO.File]::WriteAllText((Join-Path $foreign '校园网共享助手.exe'),'not a product executable')
$script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='Another product';InstallLocation=$foreign;UninstallString=''},[pscustomobject]@{Name='OtherApp_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$foreign;UninstallString=''})
$script:tasks=@([pscustomobject]@{TaskName='OtherTask';Execute=(Join-Path $root 'CampusQuietLauncher.exe');Arguments='startup'},[pscustomobject]@{TaskName='GDPortalShare-Logon';Execute=(Join-Path $root 'CampusQuietLauncher.exe');Arguments='something-else'})
$script:processes=@([pscustomobject]@{ProcessName='校园网共享助手';Path=(Join-Path $foreign '校园网共享助手.exe')},[pscustomobject]@{ProcessName='Unrelated';Path=(Join-Path $root '校园网共享助手.exe')})
$script:shortcuts=@([pscustomobject]@{Name='校园网共享助手.lnk';TargetPath=(Join-Path $foreign '校园网共享助手.exe')})
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 0) 'A foreign branded or merely same-named app was recommended'

# Protected directories and reparse points are rejected before identity reads.
$script:registrations=@()
foreach($protected in @('C:\',$env:USERPROFILE,(Join-Path $env:ProgramData 'CampusNetwork-Autostart'),(Join-Path ${env:ProgramFiles(x86)} 'Chinatelecom_GDPortal'))){
    $script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$protected;UninstallString=''})
    $script:tasks=@();$script:processes=@();$script:shortcuts=@()
    Assert (@(Get-AssistantInstallCandidates).Count -eq 0) ('Protected directory was suggested: '+$protected)
}
$link=Join-Path $testRoot 'Linked Product'
New-Item -ItemType Junction -Path $link -Target $root -ErrorAction Stop | Out-Null
$script:registrations=@([pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$link;UninstallString=''})
Assert (@(Get-AssistantInstallCandidates).Count -eq 0) 'A linked product directory was suggested'

$script:registrations=@();$script:tasks=@();$script:processes=@();$script:shortcuts=@();$script:defaults=@($foreign)
$found=@(Get-AssistantInstallCandidates)
Assert ($found.Count -eq 1 -and $found[0].Label -like '默认目录，待核对*') 'Unverified default directory was falsely confirmed as product ownership'

[IO.File]::WriteAllText((Join-Path $testRoot 'result.txt'),('PASS '+$script:checks),[Text.UTF8Encoding]::new($false))
'PASS: '+$script:checks+' read-only discovery assertions; registry fallback, source merging, missing directories, protected paths and foreign-app exclusion.'
