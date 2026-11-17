$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot 'validation\launcher'
[void][IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'stage\校园网共享助手.exe') -Destination $root -Force
$fakeScript = 'param([switch]$FirstRun); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "received.txt"), [string]$FirstRun)'
[IO.File]::WriteAllText((Join-Path $root 'Panel.ps1'), $fakeScript)
foreach($mode in @('','panel','firstrun')){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $root '校园网共享助手.exe'
    $info.Arguments=$mode
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    if(!$process.WaitForExit(15000)){$process.Kill();throw 'Launcher timed out'}
    if($process.ExitCode -ne 0){throw 'Launcher failed'}
    $process.Dispose()
    $actual=[IO.File]::ReadAllText((Join-Path $root 'received.txt'))
    if($actual -ne [string]($mode -eq 'firstrun')){throw 'Wrong first-run argument'}
}
. (Join-Path $PSScriptRoot 'stage\Network.ps1')
$lock=Enter-AssistantOperation
try {
    $source=Join-Path $PSScriptRoot 'stage\Network.ps1'
    $probe=Join-Path $root 'probe.ps1'
    [IO.File]::WriteAllText($probe, ('. '''+$source.Replace("'","''")+''' ; try {$lock=Enter-AssistantOperation;$lock.ReleaseMutex();$lock.Dispose();exit 0}catch{exit 71}'), [Text.UTF8Encoding]::new($true))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $PSHOME 'powershell.exe'
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$probe+'"'
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    if(!$process.WaitForExit(15000)){$process.Kill();throw 'Lock check timed out'}
    if($process.ExitCode -ne 71){throw 'Concurrent mutation was accepted'}
    $process.Dispose()
}finally{$lock.ReleaseMutex();$lock.Dispose()}
'PASS: compiled GUI launcher panel/first-run routes; cross-process operation lock.'

