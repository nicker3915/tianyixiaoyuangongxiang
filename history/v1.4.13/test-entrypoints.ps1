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

# Reproduce the real startup lifetime: PowerShell exits, but its authentication
# descendant retains standard handles and keeps running. The old async readers
# must reproduce the hang; the shipping launcher must exit while the worker lives.
$lifetimeRoot=Join-Path $root ('worker-lifetime-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lifetimeRoot)
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payload\CampusQuietLauncher.cs'))
$oldSource=$source.Replace('WindowStyle = ProcessWindowStyle.Hidden', 'WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true, RedirectStandardError = true').Replace('child.WaitForExit();', 'child.BeginOutputReadLine(); child.BeginErrorReadLine(); child.WaitForExit();')
$workerSource=@'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
internal static class Worker {
    public static void Main(string[] args) {
        Thread.Sleep(45000);
    }
}
'@
$workerSourcePath=Join-Path $lifetimeRoot 'Worker.cs'
[IO.File]::WriteAllText($workerSourcePath,$workerSource)
$workerExe=Join-Path $lifetimeRoot 'Worker.exe'
& $csc /nologo /target:exe ('/out:'+$workerExe) $workerSourcePath
if($LASTEXITCODE -ne 0){throw 'Worker compilation failed'}
foreach($kind in @('old','fixed')){
    $caseRoot=Join-Path $lifetimeRoot $kind
    [void][IO.Directory]::CreateDirectory($caseRoot)
    $caseSource=Join-Path $caseRoot 'Launcher.cs'
    [IO.File]::WriteAllText($caseSource,$(if($kind -eq 'old'){$oldSource}else{$source}),[Text.UTF8Encoding]::new($true))
    $caseExe=Join-Path $caseRoot 'Launcher.exe'
    & $csc /nologo /target:winexe /reference:System.Windows.Forms.dll ('/out:'+$caseExe) $caseSource
    if($LASTEXITCODE -ne 0){throw 'Launcher lifetime compilation failed'}
    $fixture=@'
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=Join-Path (Split-Path $PSScriptRoot -Parent) 'Worker.exe'
$info.Arguments='"'+(Join-Path $PSScriptRoot 'worker.pid')+'"'
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$worker=[Diagnostics.Process]::Start($info)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'worker.pid'),[string]$worker.Id)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'script.pid'),[string]$PID)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'script-completed.txt'),'completed')
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $caseRoot 'Start-CampusNetwork.ps1'),$fixture,[Text.UTF8Encoding]::new($true))
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$caseExe
    $info.Arguments='startup'
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    $worker=$null
    try {
        $exited=$process.WaitForExit(10000)
        if(!(Test-Path (Join-Path $caseRoot 'script-completed.txt'))){throw 'Fixture did not complete'}
        $scriptPid=[int][IO.File]::ReadAllText((Join-Path $caseRoot 'script.pid'))
        if(Get-Process -Id $scriptPid -ErrorAction SilentlyContinue){throw 'Fixture PowerShell is unexpectedly still running'}
        $workerPid=[int][IO.File]::ReadAllText((Join-Path $caseRoot 'worker.pid'))
        $worker=Get-Process -Id $workerPid -ErrorAction Stop
        if($worker.Path -ne $workerExe){throw 'Unexpected lifetime worker path'}
        if($kind -eq 'old' -and $exited){throw 'Old redirected launcher did not reproduce the lifetime hang'}
        if($kind -eq 'fixed' -and (!$exited -or $process.ExitCode -ne 0)){throw 'Fixed launcher did not exit successfully while descendant remained alive'}
    } finally {
        if(!$process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}
        $process.Dispose()
        if(!$worker -and (Test-Path (Join-Path $caseRoot 'worker.pid'))){$worker=Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $caseRoot 'worker.pid'))) -ErrorAction SilentlyContinue}
        if($worker -and !$worker.HasExited -and $worker.Path -eq $workerExe){$worker.Kill();[void]$worker.WaitForExit(5000)}
        if($worker){$worker.Dispose()}
    }
}
'PASS: compiled GUI launcher routes; operation lock; old launcher hangs on inherited pipes and fixed launcher exits with worker alive.'

