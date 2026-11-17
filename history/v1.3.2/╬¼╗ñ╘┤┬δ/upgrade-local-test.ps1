param([Parameter(Mandatory=$true)][string]$Installer,[Parameter(Mandatory=$true)][string]$EvidenceDir,[string]$Version='1.3.0',[switch]$LeaveStopped)
$ErrorActionPreference='Stop'
$root='C:\Program Files\GDPortalShare'
$expectedLauncher=Join-Path $root 'CampusQuietLauncher.exe'
$tasks=@('GDPortalShare-Logon','GDPortalShare-Logon-Watchdog')
$flag=Join-Path $root 'watchdog-paused.flag'
$result=[ordered]@{StartedAt=(Get-Date).ToString('o');Result='pending'}
$resultPath=Join-Path $EvidenceDir '升级实测结果.json'
$held=$false
$lock=New-Object Threading.Mutex($false,'Global\GDPortalShare-Operation')
$changed=$false
$wasPaused=Test-Path -LiteralPath $flag
$enabled=@{}
try {
    if(!(Test-Path -LiteralPath $Installer)){throw 'Installer missing'}
    $installation=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GDPortalShare-20261104_is1'
    if($installation.InstallLocation.TrimEnd('\') -ne $root){throw 'Unexpected installation location'}
    try {$held=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(!$held){throw 'Finish or cancel the active account operation before upgrading'}
    $backupHash=(Get-FileHash (Join-Path $root 'original-startup.json')).Hash
    $settingsHash=(Get-FileHash (Join-Path $root 'settings.json')).Hash
    foreach($name in $tasks){
        $t=Get-ScheduledTask -TaskName $name -TaskPath '\'
        if(@($t.Actions).Count -ne 1 -or $t.Actions[0].Execute -ne $expectedLauncher){throw 'Unexpected task ownership'}
        $enabled[$name]=[bool]$t.Settings.Enabled
    }
    [IO.File]::WriteAllText($flag,'local-package-upgrade')
    $changed=$true
    foreach($name in $tasks){Disable-ScheduledTask -TaskName $name | Out-Null; Stop-ScheduledTask -TaskName $name}
    Start-Sleep -Seconds 2
    $ownedExecutables=@($expectedLauncher,(Join-Path $root '校园网共享助手.exe'),(Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'))
    foreach($p in @(Get-Process)){
        if($p.Path -and $ownedExecutables -contains $p.Path){Stop-Process -Id $p.Id -ErrorAction SilentlyContinue}
    }
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")){
        if($p.CommandLine -and $p.CommandLine.Contains('"'+(Join-Path $root 'Panel.ps1')+'"')){Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue}
    }
    $log=Join-Path $EvidenceDir ($Version+'安装实测.log')
    $install=Start-Process -FilePath $Installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="'+$log+'"')) -PassThru -Wait
    $result.InstallerExitCode=$install.ExitCode
    if($install.ExitCode -ne 0){throw 'Installer did not succeed'}
    $result.Version=(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GDPortalShare-20261104_is1').DisplayVersion
    if($result.Version -ne $Version){throw 'Installed version did not update'}
    $result.OriginalBackupPreserved=((Get-FileHash (Join-Path $root 'original-startup.json')).Hash -eq $backupHash)
    $result.SettingsPreserved=((Get-FileHash (Join-Path $root 'settings.json')).Hash -eq $settingsHash)
    if(!$result.OriginalBackupPreserved -or !$result.SettingsPreserved){throw 'Recovery baseline changed unexpectedly'}
    $result.Result='installed'
} catch {
    $result.Result='needs-attention'
    $result.Error=$_.Exception.Message
} finally {
    if($changed -and !$LeaveStopped){
        foreach($name in $tasks){if($enabled[$name]){Enable-ScheduledTask -TaskName $name | Out-Null}}
        if(!$wasPaused -and (Test-Path -LiteralPath $flag)){Remove-Item -LiteralPath $flag -Force}
    }
    if($held){$lock.ReleaseMutex()}
    $lock.Dispose()
    $result.CompletedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
if($changed -and !$LeaveStopped -and !$wasPaused -and $enabled['GDPortalShare-Logon']){Start-ScheduledTask -TaskName 'GDPortalShare-Logon'}
