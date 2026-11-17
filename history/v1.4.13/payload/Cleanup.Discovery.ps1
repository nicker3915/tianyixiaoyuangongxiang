# Read-only candidate discovery. Finding a path never authorizes its removal;
# the cleanup preview must still validate ownership and recovery information.
function Get-DiscoveryRegistrationRecords {
    $name='GDPortalShare-20261104_is1'
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)){
        $base=$null;$key=$null
        try {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $key=$base.OpenSubKey(('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$name),$false)
            if($key){
                [pscustomobject]@{Name=$name;Hive='LocalMachine';View=[string]$view;DisplayName=[string]$key.GetValue('DisplayName','');InstallLocation=[string]$key.GetValue('InstallLocation','');UninstallString=[string]$key.GetValue('UninstallString','')}
            }
        }catch{
            # Other discovery sources remain useful when a registry view is not readable.
        }finally{if($key){$key.Dispose()};if($base){$base.Dispose()}}
    }
}

function Get-DiscoveryTaskRecords {
    foreach($pair in @(@('GDPortalShare-Logon','startup'),@('GDPortalShare-Logon-Watchdog','watch'))){
        try {
            $task=Get-ScheduledTask -TaskName $pair[0] -TaskPath '\' -ErrorAction SilentlyContinue
            if(!$task -or @($task.Actions).Count -ne 1){continue}
            $action=$task.Actions[0]
            [pscustomobject]@{TaskName=$pair[0];Execute=[string]$action.Execute;Arguments=[string]$action.Arguments}
        }catch{}
    }
}

function Get-DiscoveryProcessRecords {
    foreach($name in @('校园网共享助手','CampusQuietLauncher','ESurfingClient-2.2.0-r4-windows-x86_64')){
        foreach($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)){
            try {
                if($process.Path){[pscustomobject]@{ProcessName=$name;Path=[string]$process.Path}}
            }catch{}
        }
    }
}

function Get-DiscoveryShortcutRecords {
    $locations=@([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('CommonDesktopDirectory'),(Join-Path ([Environment]::GetFolderPath('Programs')) '校园网共享助手'),(Join-Path ([Environment]::GetFolderPath('CommonPrograms')) '校园网共享助手'))|Select-Object -Unique
    $shell=$null
    foreach($location in $locations){
        if(!$location -or !(Test-Path -LiteralPath $location -PathType Container)){continue}
        foreach($name in @('校园网共享助手.lnk','卸载校园网共享助手.lnk','一键清理与卸载.lnk')){
            $path=Join-Path $location $name
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
            try {
                Assert-CleanupNoReparse $path
                if(!$shell){$shell=New-Object -ComObject WScript.Shell}
                $link=$shell.CreateShortcut($path)
                [pscustomobject]@{Name=$name;TargetPath=[string]$link.TargetPath}
            }catch{}
        }
    }
}

function Get-DiscoveryDefaultRoots {
    foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)})){
        if($base){Join-Path $base 'GDPortalShare'}
    }
}

function Get-DiscoveryUninstallRoot([string]$Command) {
    if([string]::IsNullOrWhiteSpace($Command) -or $Command -match '[\r\n\x00]'){return $null}
    $text=[Environment]::ExpandEnvironmentVariables($Command.Trim())
    $match=if($text.StartsWith('"')){
        [regex]::Match($text,'^(?i)"(?<exe>[A-Za-z]:[^"\r\n]*[\\/]unins000\.exe)"(?:\s|$)')
    }else{
        [regex]::Match($text,'^(?i)(?<exe>[A-Za-z]:[^"\r\n]*?[\\/]unins000\.exe)(?:\s|$)')
    }
    if(!$match.Success){return $null}
    [IO.Path]::GetDirectoryName($match.Groups['exe'].Value)
}

function Get-DiscoveryExecutableRoot([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return $null}
    try {
        $full=Get-CleanupFullPath $Path
        $name=[IO.Path]::GetFileName($full)
        if($name -in @('校园网共享助手.exe','CampusQuietLauncher.exe','unins000.exe','校园网共享助手-清理与卸载.exe')){return [IO.Path]::GetDirectoryName($full)}
        if($name -ieq 'ESurfingClient-2.2.0-r4-windows-x86_64.exe'){
            $client=[IO.Path]::GetDirectoryName($full)
            if([IO.Path]::GetFileName($client) -ieq 'Client'){return [IO.Path]::GetDirectoryName($client)}
        }
    }catch{}
    return $null
}

function Test-DiscoveryProductEvidence([string]$Root) {
    # Read only the public product marker or PE metadata, never account files.
    $identity=Join-Path $Root 'app-identity.json'
    if(Test-Path -LiteralPath $identity -PathType Leaf){
        try {
            Assert-CleanupNoReparse $identity
            $marker=[IO.File]::ReadAllText($identity,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
            if($marker.ProductId -eq 'GDPortalShare' -and [int]$marker.Schema -eq 1){return $true}
        }catch{}
    }
    foreach($name in @('校园网共享助手.exe','CampusQuietLauncher.exe')){
        $file=Join-Path $Root $name
        if(!(Test-Path -LiteralPath $file -PathType Leaf)){continue}
        try {
            Assert-CleanupNoReparse $file
            $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($file)
            if($info.ProductName -eq '校园网共享助手' -or $info.FileDescription -eq '校园网共享助手'){return $true}
        }catch{}
    }
    return $false
}

function Add-DiscoveryCandidate($Map,[string]$Root,[string]$Source,[bool]$Registered=$false,[switch]$RequireEvidence) {
    if(!$Root){return}
    try {$safe=Assert-CleanupRoot $Root}catch{return}
    $exists=Test-Path -LiteralPath $safe -PathType Container
    $evidence=if($exists){Test-DiscoveryProductEvidence $safe}else{$false}
    # A similarly named executable in an unrelated existing folder is not a
    # recommendation. Missing roots can still represent identifiable residuals.
    if($RequireEvidence -and $exists -and !$evidence -and !$Registered){return}
    $key=$safe.ToUpperInvariant()
    if(!$Map.ContainsKey($key)){
        $Map[$key]=[pscustomobject]@{TargetRoot=$safe;Sources=(New-Object 'Collections.Generic.List[string]');Exists=[bool]$exists;Registered=$false;ProductEvidence=[bool]$evidence;Label=''}
    }
    $item=$Map[$key]
    if(!$item.Sources.Contains($Source)){$item.Sources.Add($Source)}
    $item.Registered=[bool]($item.Registered -or $Registered)
    $item.ProductEvidence=[bool]($item.ProductEvidence -or $evidence)
}

function Get-AssistantInstallCandidates {
    if(!(Get-Command Assert-CleanupRoot -ErrorAction SilentlyContinue)){throw '缺少清理路径检查组件，请重新获取完整清理工具。'}
    $map=@{}
    foreach($record in @(Get-DiscoveryRegistrationRecords)){
        if($record.Name -ne 'GDPortalShare-20261104_is1' -or $record.Hive -ne 'LocalMachine' -or [string]$record.DisplayName -notlike '校园网共享助手*'){continue}
        $root=[string]$record.InstallLocation
        if([string]::IsNullOrWhiteSpace($root)){$root=Get-DiscoveryUninstallRoot ([string]$record.UninstallString)}
        $view=if($record.View -eq 'Registry64'){'64 位'}else{'32 位'}
        Add-DiscoveryCandidate $map $root ('安装记录（'+$view+'）') $true
    }
    foreach($record in @(Get-DiscoveryTaskRecords)){
        $expected=switch([string]$record.TaskName){'GDPortalShare-Logon' {'startup'} 'GDPortalShare-Logon-Watchdog' {'watch'} default {''}}
        if(!$expected -or [string]$record.Arguments -ne $expected -or [IO.Path]::GetFileName([string]$record.Execute) -ine 'CampusQuietLauncher.exe'){continue}
        Add-DiscoveryCandidate $map (Get-DiscoveryExecutableRoot ([string]$record.Execute)) '助手自动任务' $false -RequireEvidence
    }
    foreach($record in @(Get-DiscoveryProcessRecords)){
        if([string]$record.ProcessName -notin @('校园网共享助手','CampusQuietLauncher','ESurfingClient-2.2.0-r4-windows-x86_64')){continue}
        if([IO.Path]::GetFileNameWithoutExtension([string]$record.Path) -ine [string]$record.ProcessName){continue}
        Add-DiscoveryCandidate $map (Get-DiscoveryExecutableRoot ([string]$record.Path)) '助手运行路径' $false -RequireEvidence
    }
    foreach($record in @(Get-DiscoveryShortcutRecords)){
        if([string]$record.Name -notin @('校园网共享助手.lnk','卸载校园网共享助手.lnk','一键清理与卸载.lnk')){continue}
        Add-DiscoveryCandidate $map (Get-DiscoveryExecutableRoot ([string]$record.TargetPath)) '助手快捷方式' $false -RequireEvidence
    }
    foreach($root in @(Get-DiscoveryDefaultRoots)){
        if(Test-Path -LiteralPath $root -PathType Container){Add-DiscoveryCandidate $map $root '默认安装目录'}
    }
    $items=foreach($item in $map.Values){
        $state=if(!$item.Exists){'目录已不存在，检查残留'}elseif($item.Registered){'已找到安装记录'}elseif($item.ProductEvidence){'已找到助手目录'}else{'默认目录，待核对'}
        [pscustomobject]@{TargetRoot=$item.TargetRoot;Sources=[string[]]$item.Sources.ToArray();Exists=$item.Exists;Registered=$item.Registered;Label=($state+' · '+$item.TargetRoot)}
    }
    $items | Sort-Object @{Expression={if($_.Registered){0}else{1}}},@{Expression={if($_.Exists){0}else{1}}},TargetRoot
}
