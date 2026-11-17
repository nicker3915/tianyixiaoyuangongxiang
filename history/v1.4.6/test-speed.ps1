$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot 'stage'
function Assert($ok,$message){if(!$ok){throw $message}}
$scriptPath=Join-Path $base 'Speed-Test.ps1'
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) ('Speed-Test syntax: '+$errors[0].Message)
$text=[IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8)
foreach($forbidden in @('Set-NetIPInterface','Set-NetRoute','New-NetRoute','Remove-NetRoute','Enable-NetAdapter','Disable-NetAdapter','Start-ScheduledTask','Stop-ScheduledTask','Set-Service','Restart-NetAdapter')){
    Assert ($text -notmatch [regex]::Escape($forbidden)) ('Speed test must not call '+$forbidden)
}
Assert ($text -match "'--max-time' '12'") 'speed test time limit missing'
Assert ($text -match "'--max-filesize' '8388608'") 'speed test byte limit missing'
Assert ($text -match '''--interface'' \$Upstream\.Ip') 'speed test must bind to selected upstream'
Assert ($text -match 'New-Object byte\[\] 2097152') 'upload byte limit missing'
Assert ($text -match "'--data-binary'") 'upload must use a bounded generated sample'
$self=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode SelfTest
$result=$self|ConvertFrom-Json
Assert ($result.Passed -and $result.TestCount -eq 2) 'speed self-test failed'
'PASS: speed-test syntax, bounded manual download, selected-adapter binding, no network mutation and self-test.'
