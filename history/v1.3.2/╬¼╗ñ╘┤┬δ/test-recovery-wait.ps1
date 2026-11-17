$ErrorActionPreference='Stop'
$testRoot=Join-Path $PSScriptRoot ('validation\recovery-wait-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$src=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payload\Campus-Recovery.ps1'))
$match=[regex]::Match($src,'(?m)^  \$process=Start-Process[^\r\n]+\r?\n(?:  #[^\r\n]+\r?\n)?  \$process.WaitForExit\(\)')
if(!$match.Success){throw 'Recovery wait implementation not found'}
$fixed=$match.Value.Replace(' -Verb RunAs','')
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$worker=Join-Path $testRoot 'Worker.exe'
[IO.File]::WriteAllText((Join-Path $testRoot 'Worker.cs'),'class Worker { static void Main() { System.Threading.Thread.Sleep(40000); } }')
& $csc /nologo /target:winexe ('/out:'+$worker) (Join-Path $testRoot 'Worker.cs')
if($LASTEXITCODE -ne 0){throw 'Compilation failed'}
$child=@'
$p=Start-Process -FilePath (Join-Path $PSScriptRoot 'Worker.exe') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'worker.pid'),[string]$p.Id)
exit 0
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'child.ps1'),$child)
foreach($kind in @('old','fixed')){
  $prefix=@'
$powerShell=Join-Path $PSHOME 'powershell.exe'
$argsText='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'child.ps1')+'"'
'@
  $wait=if($kind -eq 'old'){'$process=Start-Process -FilePath $powerShell -WindowStyle Hidden -ArgumentList $argsText -Wait -PassThru'}else{$fixed}
  $wrapper=Join-Path $testRoot ($kind+'.ps1')
  [IO.File]::WriteAllText($wrapper,($prefix+[Environment]::NewLine+$wait+[Environment]::NewLine+'exit $process.ExitCode'))
  $p=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$wrapper+'"') -PassThru
  $w=$null
  try{
    $exited=$p.WaitForExit(7000)
    $w=Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $testRoot 'worker.pid')))
    if($w.Path -ne $worker){throw 'Worker identity mismatch'}
    if($kind -eq 'old' -and $exited){throw 'Old wait did not reproduce the child-tree hang'}
    if($kind -eq 'fixed' -and (!$exited -or $p.ExitCode -ne 0)){throw 'Fixed wait failed while descendant was alive'}
  }finally{
    if(!$p.HasExited){$p.Kill()};$p.Dispose()
    if($w -and $w.Path -eq $worker -and !$w.HasExited){$w.Kill()};if($w){$w.Dispose()}
  }
}
'PASS: old recovery waits for launched client; production fixed wait returns while client remains alive.'
