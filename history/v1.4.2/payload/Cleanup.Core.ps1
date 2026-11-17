# Cleanup functions are inert when dot-sourced. No target-directory code is run.
$script:CleanupProductId = 'GDPortalShare'
$script:CleanupUninstallName = 'GDPortalShare-20261104_is1'
$script:CleanupCleanMarker = 'GDPortalShare-20261104-cleaned-v1'

function Get-CleanupFullPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]'){throw '请选择本机磁盘上的助手安装文件夹。'}
    if($Path.StartsWith('\\') -or $Path.Substring(2).Contains(':')){throw '不支持网络路径或特殊设备路径。'}
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    if([string]::Equals($full.TrimEnd('\','/'),$drive.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){return $drive}
    $full=$full.TrimEnd('\','/')
    foreach($part in $full.Substring(3).Split('\')){if($part -and ($part -ne $part.TrimEnd(' ','.'))){throw '目录名称包含不明确的尾部字符，请先核对路径。'}}
    return $full
}
function Test-CleanupSamePath([string]$Left,[string]$Right) {
    try{return [string]::Equals((Get-CleanupFullPath $Left),(Get-CleanupFullPath $Right),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}
function Assert-CleanupNoReparse([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '目录包含链接或挂载点，已停止清理，请联系维护人员核对。'}
        }
        $next=[IO.Path]::GetDirectoryName($current)
        if($next -eq $current){break};$current=$next
    }
}
function Assert-CleanupRoot([string]$Path) {
    $root=Get-CleanupFullPath $Path
    if($root.Length -le 3){throw '不能清理磁盘根目录。'}
    $protected=@($env:USERPROFILE,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:LOCALAPPDATA,$env:APPDATA,[Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('MyDocuments'))
    foreach($p in $protected){if($p -and ((Test-CleanupSamePath $root $p) -or [IO.Path]::GetFullPath($p).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))){throw '不能将系统或个人资料主目录及其上级目录作为清理目标。'}}
    foreach($p in @($env:WINDIR,(Join-Path $env:ProgramData 'CampusNetwork-Autostart'))){
        if($p -and ((Test-CleanupSamePath $root $p) -or $root.StartsWith(([IO.Path]::GetFullPath($p).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase))){throw '此目录属于系统或原有独立联网方案，不在本工具的清理范围内。'}
    }
    if($root -match '(?i)(?:^|\\)Chinatelecom_GDPortal(?:\\|$)'){throw '不能清理官方天翼客户端目录。'}
    Assert-CleanupNoReparse $root
    if((Test-Path -LiteralPath $root) -and !(Test-Path -LiteralPath $root -PathType Container)){throw '清理目标必须是文件夹。'}
    return $root
}
function Get-CleanupTree([string]$Root) {
    $files=New-Object Collections.Generic.List[string]
    $dirs=New-Object Collections.Generic.List[string]
    if(!(Test-Path -LiteralPath $Root)){return [pscustomobject]@{Files=@();Directories=@()}}
    $pending=New-Object Collections.Generic.Stack[string];$pending.Push($Root)
    while($pending.Count){
        $dir=$pending.Pop();Assert-CleanupNoReparse $dir;$dirs.Add($dir)
        foreach($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)){
            $path=[IO.Path]::GetFullPath($item.FullName)
            if(!$path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '发现目标目录以外的文件，已停止清理。'}
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw '目标中包含链接或挂载点，已停止清理，未遍历该链接。'}
            if($item.PSIsContainer){$pending.Push($path)}else{$files.Add($path)}
        }
    }
    [pscustomobject]@{Files=@($files.ToArray());Directories=@($dirs.ToArray())}
}
function Read-CleanupJson([string]$Path) {
    try {[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop}
    catch {throw ('无法读取或解析 '+[IO.Path]::GetFileName($Path)+'，已保留原文件，请核对配置和恢复备份。')}
}
function Get-CleanupRegistrationRecords {
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)){
        $base=$null;$key=$null
        try{
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $relative='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$script:CleanupUninstallName
            $key=$base.OpenSubKey($relative,$false)
            if($key){[pscustomobject]@{Hive='LocalMachine';View=[string]$view;Name=$script:CleanupUninstallName;RelativeKey=$relative;InstallLocation=[string]$key.GetValue('InstallLocation','');DisplayName=[string]$key.GetValue('DisplayName','')}}
        }finally{if($key){$key.Dispose()};if($base){$base.Dispose()}}
    }
}
function Get-CleanupRegistrations([string]$Root) {
    @(Get-CleanupRegistrationRecords | Where-Object {$_.Hive -eq 'LocalMachine' -and $_.Name -eq $script:CleanupUninstallName -and (Test-CleanupSamePath $_.InstallLocation $Root) -and $_.DisplayName -like '校园网共享助手*'})
}
function Remove-CleanupRegistrationRecord($Record,[string]$Root) {
    if($Record.Hive -ne 'LocalMachine' -or $Record.Name -ne $script:CleanupUninstallName){throw '卸载记录归属不匹配，已保留。'}
    $view=[Microsoft.Win32.RegistryView][Enum]::Parse([Microsoft.Win32.RegistryView],$Record.View)
    $base=$null;$key=$null
    try{
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        $relative='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$script:CleanupUninstallName
        $key=$base.OpenSubKey($relative,$false)
        if(!$key){return}
        if(!(Test-CleanupSamePath ([string]$key.GetValue('InstallLocation','')) $Root) -or [string]$key.GetValue('DisplayName','') -notlike '校园网共享助手*'){throw '卸载记录已改变，未删除。'}
        $key.Dispose();$key=$null
        $base.DeleteSubKeyTree($relative,$false)
    }finally{if($key){$key.Dispose()};if($base){$base.Dispose()}}
}
function Get-CleanupKnownNames([string]$BundleRoot) {
    $manifest=Join-Path $BundleRoot 'cleanup-files.json'
    if(!(Test-Path -LiteralPath $manifest)){throw '清理工具缺少可信文件清单，请重新获取完整清理工具。'}
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $manifestNames=Read-CleanupJson $manifest
    foreach($name in $manifestNames){
        if($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or [IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or $name -match '(^|[\\/])\.\.?([\\/]|$)'){throw '清理工具文件清单无效。'}
        [void]$names.Add($name.Replace('/','\'))
    }
    foreach($name in @('CampusQuietLauncher.exe','校园网共享助手.exe','CampusQuietLauncher.cs','Panel.ps1','Manage.ps1','Network.ps1','Lifecycle.ps1','Start-CampusNetwork.ps1','Watch-CampusNetwork.ps1','Campus-Recovery.ps1','Check-Environment.ps1','Clean-Conflicts.ps1','Cleanup-Assistant.ps1','Cleanup.Core.ps1','cleanup-files.json','app-identity.json','使用说明.txt','免安装版使用说明.txt','SHA256.txt','SOURCE-SHA256.txt','unins000.exe','unins000.dat','unins000.msg','settings.json','original-startup.json','managed-routes.json','assistant-state.json','last-status.json','watchdog-status.json','watchdog-history.json','recovery-last-result.json','network-check.json','environment-check.json','clean-conflicts-result.json','hotspot-owner.json','watchdog-paused.flag','uninstall-in-progress.flag','startup.log','startup.previous.log','launcher.log','Client\ESurfingClient.json','Client\ESurfingClient.json.pending','.gdportalshare-cleaned')){[void]$names.Add($name)}
    return ,$names
}
function Test-CleanupKnownRelative([string]$Relative,$KnownNames) {
    if($KnownNames.Contains($Relative)){return $true}
    if($Relative -in @('Client\ESurfingClient.json.new','Client\ESurfingClient.json.pending.new')){return $true}
    if($Relative -match '^(?i)Client\\ESurfingClient\.json\.[0-9]+\.logout$'){return $true}
    if($Relative -match '^(?i)(?:recovery-api|startup-api)-[0-9a-f]{32}\.tmp$'){return $true}
    if($Relative -match '^(?i)(?:settings|original-startup|managed-routes|assistant-state|last-status|watchdog-status|watchdog-history|recovery-last-result|hotspot-owner)\.json(?:\.[0-9a-f]{32}\.tmp|\.new)$'){return $true}
    if($Relative -match '^(?i)Client\\logs\\[^\\]+\.(?:log|txt)$'){return $true}
    return $false
}
function Get-CleanupKnownDirectories($KnownNames) {
    $dirs=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$dirs.Add('Client\logs')
    foreach($name in $KnownNames){
        $dir=[IO.Path]::GetDirectoryName($name)
        while($dir){[void]$dirs.Add($dir);$dir=[IO.Path]::GetDirectoryName($dir)}
    }
    return ,$dirs
}
function Get-CleanupUnknownItems($Tree,[string]$Root,$KnownNames) {
    foreach($file in $Tree.Files){$relative=$file.Substring($Root.Length+1);if(!(Test-CleanupKnownRelative $relative $KnownNames)){$relative}}
    $knownDirs=Get-CleanupKnownDirectories $KnownNames
    foreach($dir in $Tree.Directories){
        if(Test-CleanupSamePath $dir $Root){continue}
        $relative=$dir.Substring($Root.Length+1)
        if(!$knownDirs.Contains($relative)){$relative+'\'}
    }
}
function Test-CleanupLegacyExecutable([string]$Root) {
    foreach($name in @('校园网共享助手.exe','CampusQuietLauncher.exe')){
        $path=Join-Path $Root $name
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if($info.ProductName -eq '校园网共享助手' -or $info.FileDescription -eq '校园网共享助手'){return $true}
        }
    }
    return $false
}
function Get-CleanupApplicationProcesses([string]$Root) {
    (Get-CleanupUiProcessSnapshot $Root).Processes
}
function Get-CleanupResidualOwners([string]$Root) {
    $launcher=Join-Path $Root 'CampusQuietLauncher.exe';$client=Join-Path $Root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
    $ownedTasks=@();$ownedProcesses=@()
    foreach($name in @('GDPortalShare-Logon','GDPortalShare-Logon-Watchdog')){
        $task=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
        if(!$task){continue}
        $matches=@($task.Actions|Where-Object {Test-CleanupSamePath $_.Execute $launcher})
        if($matches.Count){$ownedTasks+=$task}
    }
    foreach($process in @(Get-Process -Name 'ESurfingClient-2.2.0-r4-windows-x86_64' -ErrorAction SilentlyContinue)){
        if($process.Path -and (Test-CleanupSamePath $process.Path $client)){$ownedProcesses+=$process}
    }
    [pscustomobject]@{Tasks=$ownedTasks;Processes=$ownedProcesses}
}
function Get-CleanupValidatedRecovery([string]$Root) {
    $cfgPath=Join-Path $Root 'settings.json';$backupPath=Join-Path $Root 'original-startup.json'
    $hasCfg=Test-Path -LiteralPath $cfgPath -PathType Leaf;$hasBackup=Test-Path -LiteralPath $backupPath -PathType Leaf
    if($hasCfg -and !$hasBackup){throw '恢复备份 original-startup.json 缺失，已保留程序与配置；请修复备份后重试。'}
    if(!$hasCfg -and !$hasBackup){
        $owners=Get-CleanupResidualOwners $Root
        if($owners.Tasks.Count -or $owners.Processes.Count){throw '此目录仍有本助手任务或认证进程，但恢复备份缺失，已保留文件。'}
        return [pscustomobject]@{Configured=$false;Required=$false;Context=$null;BackupOnly=$false}
    }
    $backup=Read-CleanupJson $backupPath
    if(!$backup.Adapter -or !$backup.Gateway -or $null -eq $backup.RunExists -or $null -eq $backup.ServiceAuto -or !$backup.AutoMetric -or $null -eq $backup.Metric){throw '恢复备份不完整，已保留文件；请由维护人员核对后再清理。'}
    $guid=[guid]$backup.Adapter
    $parsed=[Net.IPAddress]::Parse([string]$backup.Gateway)
    if($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw '恢复备份的网关格式不正确。'}
    if([string]$backup.AutoMetric -notin @('Enabled','Disabled') -or [int]$backup.Metric -lt 0){throw '恢复备份中的网卡优先级无效。'}
    if($backup.RunExists -and ([string]$backup.RunValue -notmatch '(?i)\\Chinatelecom_GDPortal\\AutoStart\.exe(?:"|\s|$)' -or [string]$backup.RunKind -notin @('String','ExpandString'))){throw '恢复备份中的官方启动项不符合此版本。'}
    if($hasCfg){
        try {$context=Get-LifecycleContext $Root}
        catch {throw '助手网络配置和恢复备份无法读取或不一致，已保留原文件，请核对后重试。'}
        if($context.Settings.ExecutableSha256 -and $context.Settings.ExecutableSha256 -ne '714A8CC53C5E50A218932D0BDDDF0E68570C5D9832B9B7830EAC27DD85517DD7'){throw '认证组件身份与此工具不匹配，已保留文件。'}
    }else{
        $client=Join-Path $Root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
        $cfg=[pscustomobject]@{TaskName='GDPortalShare-Logon';ClientPath=$client;CampusAdapterGuid=$guid.ToString();ExpectedGateway=[string]$backup.Gateway;ExpectedNetworkName='';CampusMetric=10}
        $context=[pscustomobject]@{Root=$Root;Settings=$cfg;Backup=$backup;Client=$client;Launcher=(Join-Path $Root 'CampusQuietLauncher.exe');Pause=(Join-Path $Root 'watchdog-paused.flag')}
    }
    # Resolve task/process ownership before any settings are changed.
    $null=@(Get-LifecycleTasks $context);$null=@(Get-LifecycleProcesses $context)
    [pscustomobject]@{Configured=[bool]$hasCfg;Required=$true;Context=$context;BackupOnly=(!$hasCfg)}
}
function Get-CleanupShortcuts([string]$Root) {
    $locations=@([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'),(Join-Path ([Environment]::GetFolderPath('Programs')) '校园网共享助手'),(Join-Path ([Environment]::GetFolderPath('CommonPrograms')) '校园网共享助手')) | Select-Object -Unique
    $shell=$null
    foreach($location in $locations){
        if(!$location -or !(Test-Path -LiteralPath $location)){continue}
        Assert-CleanupNoReparse $location
        foreach($name in @('校园网共享助手.lnk','打开安装文件夹.lnk','使用说明.lnk','卸载校园网共享助手.lnk','一键清理与卸载.lnk')){
            $path=Join-Path $location $name
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
            Assert-CleanupNoReparse $path
            if(!$shell){$shell=New-Object -ComObject WScript.Shell}
            $shortcut=$shell.CreateShortcut($path);$target=[string]$shortcut.TargetPath
            $owned=$false
            foreach($targetName in @('校园网共享助手.exe','CampusQuietLauncher.exe','使用说明.txt','unins000.exe','校园网共享助手-清理与卸载.exe')){if(Test-CleanupSamePath $target (Join-Path $Root $targetName)){$owned=$true}}
            if($target -and [IO.Path]::GetFileName($target) -ieq 'explorer.exe' -and (Test-CleanupSamePath ([string]$shortcut.Arguments).Trim('"') $Root)){$owned=$true}
            if($owned){[pscustomobject]@{Path=$path;Target=$target;Arguments=[string]$shortcut.Arguments}}
        }
    }
}
function New-CleanupResult([string]$Root) {
    [ordered]@{Success=$false;CanRemove=$false;AlreadyAbsent=$false;Target=$Root;Summary='';RecognizedBy='';Configured=$false;RecoveryRequired=$false;OpenApplicationCount=0;UiProcesses=@();ClosedApplicationCount=0;KnownFiles=@();UnknownFiles=@();RemovedFiles=@();PreservedFiles=@();Error='';Stage='inspection'}
}
function Get-AssistantCleanupPlan([string]$TargetRoot,[string]$BundleRoot) {
    $root=Assert-CleanupRoot $TargetRoot
    $result=New-CleanupResult $root
    $registrations=@(Get-CleanupRegistrations $root)
    $uiSnapshot=Get-CleanupUiProcessSnapshot $root
    if($uiSnapshot.Unverified.Count){throw '发现无法核实启动参数的目标助手进程，未结束该进程；请联系维护人员核对。'}
    $result.OpenApplicationCount=$uiSnapshot.Processes.Count
    $result.UiProcesses=@($uiSnapshot.Processes|Select-Object Id,Path,StartTicks,ParentId,Role)
    if(!(Test-Path -LiteralPath $root)){
        $owners=Get-CleanupResidualOwners $root
        if($owners.Tasks.Count -or $owners.Processes.Count){throw '程序目录及恢复备份已不存在，但仍有指向此目录的助手任务或认证进程。无法确认恢复原设置，已保留记录，请联系维护人员。'}
        if($uiSnapshot.Processes.Count -and !$registrations.Count){throw '目录已不存在，无法确认此界面进程的产品归属，未结束进程或更改设置。'}
        $shortcuts=@(Get-CleanupShortcuts $root)
        $result.Success=$true;$result.CanRemove=$true;$result.AlreadyAbsent=$true
        $result.RecognizedBy=if($registrations.Count){'匹配的本产品卸载记录'}else{'目标目录已不存在'}
        $result.Summary='目标：'+$root+[Environment]::NewLine+'目录已不存在；仅核对并清除仍指向此目录的本产品卸载记录和 '+$shortcuts.Count+' 个快捷方式。'+[Environment]::NewLine+'确认后关闭本目标界面进程：'+$uiSnapshot.Processes.Count+' 个。'
        return [pscustomobject]@{Result=$result;Root=$root;Registrations=$registrations;Tree=$null;Recovery=$null;Known=@();Unknown=@();Shortcuts=$shortcuts;UiSnapshot=$uiSnapshot}
    }
    $tree=Get-CleanupTree $root
    $names=Get-CleanupKnownNames $BundleRoot
    $recovery=Get-CleanupValidatedRecovery $root
    $recognition=''
    if($registrations.Count){$recognition='匹配的本产品正式安装记录'}
    $identityPath=Join-Path $root 'app-identity.json'
    if(!$recognition -and (Test-Path -LiteralPath $identityPath)){
        $identity=Read-CleanupJson $identityPath
        if($identity.ProductId -eq $script:CleanupProductId -and [int]$identity.Schema -eq 1){$recognition='本助手产品标识与清理工具内置文件清单'}
    }
    $marker=Join-Path $root '.gdportalshare-cleaned'
    if(!$recognition -and (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -ceq $script:CleanupCleanMarker){$recognition='此前已经恢复完成的本助手目录'}
    if(!$recognition -and $recovery.Configured -and (Test-CleanupLegacyExecutable $root)){$recognition='有效网络配置、原恢复备份及助手主程序版本信息'}
    if(!$recognition){throw '无法确认此目录属于校园网共享助手，已停止清理。请选择正式安装目录或本助手完整目录。'}
    $known=@()
    foreach($file in $tree.Files){$relative=$file.Substring($root.Length+1);if(Test-CleanupKnownRelative $relative $names){$known+=$file}}
    $unknown=@(Get-CleanupUnknownItems $tree $root $names)
    $shortcuts=@(Get-CleanupShortcuts $root)
    $result.Success=$true;$result.CanRemove=$true;$result.RecognizedBy=$recognition;$result.Configured=$recovery.Configured;$result.RecoveryRequired=$recovery.Required
    $result.KnownFiles=@($known|ForEach-Object {$_.Substring($root.Length+1)})
    $result.UnknownFiles=$unknown
    $result.PreservedFiles=$result.UnknownFiles
    $result.Summary='目标：'+$root+[Environment]::NewLine+'识别依据：'+$recognition+[Environment]::NewLine+'确认后关闭本目标界面进程：'+$uiSnapshot.Processes.Count+' 个。'+[Environment]::NewLine+'恢复设置：'+$(if($recovery.Required){'需要先停止本助手共享并恢复官方设置，可能短暂断网。'}else{'未发现已配置的网络设置。'})+[Environment]::NewLine+'预计删除：'+$known.Count+' 个已识别文件、'+$shortcuts.Count+' 个归属明确的快捷方式。'+[Environment]::NewLine+'保留未知文件或文件夹：'+$unknown.Count+' 项。'+[Environment]::NewLine+'取消将不修改任何设置。'
    [pscustomobject]@{Result=$result;Root=$root;Registrations=$registrations;Tree=$tree;Recovery=$recovery;Known=$known;Unknown=$unknown;Shortcuts=$shortcuts;UiSnapshot=$uiSnapshot}
}
function Test-CleanupAdministrator {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Restore-CleanupRecovery($Plan) {
    if(!$Plan.Recovery.Required){return}
    if(!$Plan.Recovery.BackupOnly){Stop-AssistantLifecycle $Plan.Root -Uninstall;return}
    $context=$Plan.Recovery.Context;$tasks=@(Get-LifecycleTasks $context);$lock=$null
    try{
        [IO.File]::WriteAllText($context.Pause,'cleanup-recovery',[Text.UTF8Encoding]::new($false))
        foreach($task in $tasks){Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null}
        $lock=Enter-LifecycleNetwork $context
        Stop-AssistantHotspot $context
        foreach($task in $tasks){Stop-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop}
        Stop-LifecycleProcesses $context
        Restore-LifecycleNetwork $context
        Restore-LifecycleOfficial $context
        foreach($task in $tasks){Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop}
    }finally{if($lock){$lock.ReleaseMutex();$lock.Dispose()}}
}
function Remove-CleanupKnownFile([string]$Root,[string]$Path) {
    $null=Assert-CleanupRoot $Root
    $full=[IO.Path]::GetFullPath($Path)
    if(!$full.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '拒绝删除目标目录之外的文件。'}
    Assert-CleanupNoReparse $full
    if(Test-Path -LiteralPath $full -PathType Leaf){Remove-Item -LiteralPath $full -Force -ErrorAction Stop}
}
function Remove-CleanupShortcut($Shortcut,[string]$Root) {
    $current=@(Get-CleanupShortcuts $Root|Where-Object {Test-CleanupSamePath $_.Path $Shortcut.Path})
    if(!$current.Count){return}
    Assert-CleanupNoReparse $Shortcut.Path
    Remove-Item -LiteralPath $Shortcut.Path -Force -ErrorAction Stop
}
function Remove-CleanupEmptyDirectories([string]$Root,$KnownNames) {
    $tree=Get-CleanupTree $Root
    $knownDirs=Get-CleanupKnownDirectories $KnownNames
    foreach($dir in @($tree.Directories | Sort-Object Length -Descending)){
        if(!(Test-CleanupSamePath $dir $Root) -and !$knownDirs.Contains($dir.Substring($Root.Length+1))){continue}
        Assert-CleanupNoReparse $dir
        if(!(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Select-Object -First 1)){[IO.Directory]::Delete($dir,$false)}
    }
}
function Invoke-AssistantCleanup([string]$TargetRoot,[string]$BundleRoot,[ValidateSet('Preview','Remove')][string]$Mode='Preview',[switch]$UserConfirmed) {
    $result=New-CleanupResult $TargetRoot;$lock=$null
    try{
        if($Mode -eq 'Remove'){
            if(!$UserConfirmed){throw '尚未确认清理。请在清理向导中核对目标并点击“清理并卸载”。'}
            if(!(Test-CleanupAdministrator)){throw '清理需要 Windows 管理员授权，请重新打开清理工具。'}
            $safeRoot=Assert-CleanupRoot $TargetRoot
            $bundle=[IO.Path]::GetFullPath($BundleRoot).TrimEnd('\')
            if((Test-CleanupSamePath $safeRoot $bundle) -or $bundle.StartsWith($safeRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw '清理工具必须在目标目录之外运行，请使用独立清理工具。'}
            $lock=Enter-AssistantOperation
        }
        $plan=Get-AssistantCleanupPlan $TargetRoot $BundleRoot;$result=$plan.Result
        if($Mode -eq 'Preview'){return [pscustomobject]$result}
        $result.Success=$false;$result.Stage='closing-ui'
        $closed=Stop-CleanupUiProcesses $plan.Root $plan.UiSnapshot.Processes
        $result.ClosedApplicationCount=@($closed).Count
        $afterUi=Get-CleanupUiProcessSnapshot $plan.Root
        if($afterUi.Processes.Count -or $afterUi.Unverified.Count){throw '目标助手界面仍在运行或其身份已改变，已保留配置与备份，请重新检查后重试。'}
        $result.Stage='recovery'
        Restore-CleanupRecovery $plan
        # Recheck the full tree after recovery and before any filesystem deletion.
        $fresh=Get-AssistantCleanupPlan $plan.Root $BundleRoot
        if($fresh.UiSnapshot.Processes.Count){throw '清理过程中助手界面重新打开，已保留配置与备份，请重试。'}
        $result.KnownFiles=$fresh.Result.KnownFiles;$result.UnknownFiles=$fresh.Result.UnknownFiles;$result.PreservedFiles=$fresh.Result.UnknownFiles
        $result.Stage='files'
        $critical=@('settings.json','original-startup.json','app-identity.json','.gdportalshare-cleaned')
        $deferred=@()
        foreach($file in $fresh.Known){
            $relative=$file.Substring($plan.Root.Length+1)
            if($relative -in $critical){$deferred+=$file;continue}
            Remove-CleanupKnownFile $plan.Root $file;$result.RemovedFiles+=,$relative
        }
        $result.Stage='shortcuts'
        foreach($shortcut in $fresh.Shortcuts){Remove-CleanupShortcut $shortcut $plan.Root}
        $result.Stage='registration'
        foreach($record in @(Get-CleanupRegistrations $plan.Root)){Remove-CleanupRegistrationRecord $record $plan.Root}
        $result.Stage='finalizing'
        foreach($file in $deferred){Remove-CleanupKnownFile $plan.Root $file;$result.RemovedFiles+=,$file.Substring($plan.Root.Length+1)}
        $names=Get-CleanupKnownNames $BundleRoot
        if(Test-Path -LiteralPath $plan.Root){Remove-CleanupEmptyDirectories $plan.Root $names}
        if(Test-Path -LiteralPath $plan.Root){
            $tree=Get-CleanupTree $plan.Root
            $remaining=@($tree.Files|Where-Object {Test-CleanupKnownRelative $_.Substring($plan.Root.Length+1) $names})
            if($remaining.Count){throw '仍有本助手文件未能清理，请关闭相关窗口后重试。'}
            [IO.File]::WriteAllText((Join-Path $plan.Root '.gdportalshare-cleaned'),$script:CleanupCleanMarker,[Text.UTF8Encoding]::new($false))
            $result.PreservedFiles=@(Get-CleanupUnknownItems $tree $plan.Root $names)
        }
        if(@(Get-CleanupRegistrations $plan.Root).Count){throw '本助手卸载记录仍存在，请重试清理。'}
        $result.Success=$true;$result.CanRemove=$true;$result.Stage='complete'
        $result.Summary='已完成本助手清理。请使用原官方客户端登录校园网。'+$(if($result.PreservedFiles.Count){[Environment]::NewLine+'已保留 '+$result.PreservedFiles.Count+' 项不属于清理范围的文件或文件夹；新版可识别此已清理目录。'}else{[Environment]::NewLine+'此目录的已识别程序、设置及卸载残留已清除。'})
    }catch{
        $result.Success=$false;$result.CanRemove=$false;$result.Error=$_.Exception.Message
        $result.Summary='清理尚未完成：'+$_.Exception.Message+[Environment]::NewLine+'未确认恢复成功时会保留配置与备份，请处理提示后重新运行独立清理工具。'
    }finally{if($lock){$lock.ReleaseMutex();$lock.Dispose()}}
    return [pscustomobject]$result
}
