$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot 'payload'
$scriptPath=Join-Path $base 'Device-SpeedServer.ps1'
function Assert($ok,$message){if(!$ok){throw $message}}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) ('Device-SpeedServer syntax: '+$errors[0].Message)
$text=[IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8)
foreach($forbidden in @('Set-NetIPInterface','Set-NetRoute','New-NetRoute','Remove-NetRoute','Enable-NetAdapter','Disable-NetAdapter','Start-ScheduledTask','Stop-ScheduledTask','Set-Service','Restart-NetAdapter')){
    Assert ($text -notmatch [regex]::Escape($forbidden)) ('Device speed test must not call '+$forbidden)
}
Assert ($text -match 'RemoteAddress \(\$hotspot.Address.\x27/\x27.\$hotspot.Prefix\)') 'Firewall rule is not restricted to hotspot subnet'
Assert ($text -match '-Profile Private') 'Firewall rule must be private-profile only'
Assert ($text -match 'New-Object byte\[\] 4194304') 'Download sample must be bounded to 4 MiB'
Assert ($text -match '1048576') 'Upload sample must be bounded to 1 MiB'
Assert ($text -match 'AddMinutes\(10\)') 'Device test expiry is missing'
Assert ($text -match 'Remove-NetFirewallRule') 'Firewall rule removal is missing'
Assert ($text -match 'Device-SpeedServer.ps1') 'Verified process stop guard is missing'
$self=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode SelfTest
$result=$self|ConvertFrom-Json
Assert ($result.Passed -and $result.TestCount -eq 3) 'device speed self-test failed'
'PASS: device-speed syntax, bounded local payloads, private hotspot firewall scope, expiry, cleanup and no network mutation.'
