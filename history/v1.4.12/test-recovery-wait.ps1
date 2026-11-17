$ErrorActionPreference='Stop'
$testRoot=Join-Path $PSScriptRoot ('validation\recovery-wait-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$src=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payload\Campus-Recovery.ps1'))
$match=[regex]::Match($src,'(?m)^  \$process=Start-Process[^\r\n]+\r?\n(?:  #[^\r\n]+\r?\n)?  \$process.WaitForExit\(\)')
if(!$match.Success){throw 'Recovery wait implementation not found'}
# The production UAC boundary is outside this noninteractive fixture. Launch
# locally without a shell or redirected pipes so only wait semantics are tested.
$fixed=$match.Value.Replace(' -Verb RunAs','').Replace(' -WindowStyle Hidden',' -NoNewWindow')
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$worker=Join-Path $testRoot 'Worker.exe'
[IO.File]::WriteAllText((Join-Path $testRoot 'Worker.cs'),'class Worker { static void Main() { System.Threading.Thread.Sleep(40000); } }')
& $csc /nologo /target:winexe ('/out:'+$worker) (Join-Path $testRoot 'Worker.cs')
if($LASTEXITCODE -ne 0){throw 'Compilation failed'}
$child=@'
$p=Start-Process -FilePath (Join-Path $PSScriptRoot 'Worker.exe') -NoNewWindow -PassThru
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'worker.pid'),[string]$p.Id)
exit 0
'@
[IO.File]::WriteAllText((Join-Path $testRoot 'child.ps1'),$child)
foreach($kind in @('old','fixed')){
  $prefix=@'
$powerShell=Join-Path $PSHOME 'powershell.exe'
$argsText='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'child.ps1')+'"'
'@
  $wait=if($kind -eq 'old'){'$process=Start-Process -FilePath $powerShell -NoNewWindow -ArgumentList $argsText -Wait -PassThru'}else{$fixed}
  $wrapper=Join-Path $testRoot ($kind+'.ps1')
  [IO.File]::WriteAllText($wrapper,($prefix+[Environment]::NewLine+$wait+[Environment]::NewLine+'exit $process.ExitCode'))
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=Join-Path $PSHOME 'powershell.exe'
  $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$wrapper+'"'
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $p=[Diagnostics.Process]::Start($info)
  $w=$null
  try{
    $readyBy=[DateTime]::UtcNow.AddSeconds(30)
    $pidPath=Join-Path $testRoot 'worker.pid'
    while(!(Test-Path -LiteralPath $pidPath) -and !$p.HasExited -and [DateTime]::UtcNow -lt $readyBy){Start-Sleep -Milliseconds 100}
    if(!(Test-Path -LiteralPath $pidPath)){throw 'Fixture worker did not start within 30 seconds'}
    $exited=$p.WaitForExit(7000)
    $w=Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $testRoot 'worker.pid')))
    if($w.Path -ne $worker){throw 'Worker identity mismatch'}
    if($kind -eq 'old' -and $exited){throw 'Old wait did not reproduce the child-tree hang'}
    if($kind -eq 'fixed' -and (!$exited -or $p.ExitCode -ne 0)){throw 'Fixed wait failed while descendant was alive'}
  }finally{
    if(!$p.HasExited){$p.Kill()};$p.Dispose()
    if($w -and $w.Path -eq $worker -and !$w.HasExited){$w.Kill()};if($w){$w.Dispose()}
    $pidPath=Join-Path $testRoot 'worker.pid';if(Test-Path -LiteralPath $pidPath){[IO.File]::Delete($pidPath)}
  }
}
'PASS: old recovery waits for launched client; production fixed wait returns while client remains alive.'
