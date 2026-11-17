$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'payload\Network.ps1')
function Assert($passed,$message){if(!$passed){throw $message}}
$script:profile='Campus WiFi'
$script:wirelessStatus='Up'
$ethernetId=[guid]::NewGuid()
$wifiId=[guid]::NewGuid()
function Get-NetAdapter {
    [pscustomobject]@{Name='Ethernet';InterfaceType=6;Status='Up';ifIndex=12;InterfaceGuid=$ethernetId}
    [pscustomobject]@{Name='Wi-Fi';InterfaceType=71;Status=$script:wirelessStatus;ifIndex=23;InterfaceGuid=$wifiId}
    [pscustomobject]@{Name='Tunnel';InterfaceType=131;Status='Up';ifIndex=32;InterfaceGuid=[guid]::NewGuid()}
}
function Get-NetIPAddress($InterfaceIndex) {
    [pscustomobject]@{IPAddress="192.0.$InterfaceIndex.20";PrefixLength=24;AddressState='Preferred'}
}
function Get-NetRoute($InterfaceIndex) {
    [pscustomobject]@{NextHop="192.0.$InterfaceIndex.1";RouteMetric=20}
}
function Get-NetConnectionProfile($InterfaceIndex) {
    if($InterfaceIndex -eq 23 -and $script:profile){[pscustomobject]@{Name=$script:profile}}
}
$candidates=@(Get-CampusCandidates)
Assert ($candidates.Count -eq 2) 'Expected Ethernet and Wi-Fi only'
$wifi=$candidates|Where-Object ConnectionKind -eq 'Wi-Fi'
Assert ($wifi.Id -eq $wifiId.ToString() -and $wifi.NetworkName -eq 'Campus WiFi') 'Wrong Wi-Fi identity'
$settings=[pscustomobject]@{ExpectedNetworkName='Campus WiFi'}
$adapter=[pscustomobject]@{ifIndex=23}
Assert (Test-CampusProfile $adapter $settings) 'Matching Wi-Fi rejected'
$script:profile='Other WiFi'
Assert (!(Test-CampusProfile $adapter $settings)) 'Different Wi-Fi accepted'
$script:profile=$null
Assert (!(Test-CampusProfile $adapter $settings)) 'Unknown Wi-Fi accepted'
Assert (@(Get-CampusCandidates).Count -eq 1) 'Unknown wireless network listed'
Assert (Test-CampusProfile $adapter ([pscustomobject]@{})) 'Existing wired configuration regressed'
$script:profile='Campus WiFi'
$script:wirelessStatus='Disconnected'
Assert (@(Get-CampusCandidates).Count -eq 1) 'Disconnected adapter listed'
'PASS: Ethernet/Wi-Fi selection, network-name binding, unknown/disconnected filtering, legacy config.'


$script:wirelessStatus='Up'
$script:profile='Campus WiFi'
$settings=[pscustomobject]@{CampusAdapterGuid=$wifiId.ToString();ExpectedNetworkName='Campus WiFi';ExpectedGateway='192.0.23.1';SubnetReference='192.0.23.20';SubnetBits=24}
Assert (@(Get-ConfiguredCampusCandidates $settings).Count -eq 1) 'Configured Wi-Fi unavailable for account update'
$script:profile='Other WiFi'
Assert (@(Get-ConfiguredCampusCandidates $settings).Count -eq 0) 'Account update accepted different Wi-Fi with the same gateway'
$script:profile='Campus WiFi'
$settings.SubnetReference='192.0.99.20'
Assert (@(Get-ConfiguredCampusCandidates $settings).Count -eq 0) 'Account update accepted different subnet'
$settings.SubnetReference='192.0.23.20'
$legacySettings=[pscustomobject]@{CampusAdapterGuid=$ethernetId.ToString();ExpectedGateway='192.0.12.1';SubnetReference='192.0.12.20';SubnetBits=24}
Assert (@(Get-ConfiguredCampusCandidates $legacySettings).Count -eq 1) 'Legacy wired account update regressed'
'PASS: account update matches configured network and rejects same-gateway Wi-Fi changes.'
foreach($item in @(@('Start-CampusNetwork.ps1','Get-CampusNetwork'),@('Campus-Recovery.ps1','Campus'))){
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot ('payload\'+$item[0])),[ref]$null,[ref]$null)
    $name=$item[1]
    $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text))
    Assert ([bool](& $name)) ('Wi-Fi rejected by '+$name)
    $script:profile='Other WiFi'
    Assert (!(& $name)) ('Wrong Wi-Fi allowed by '+$name)
    $script:profile='Campus WiFi'
}
'PASS: startup and recovery select Wi-Fi by its adapter ID and reject a different wireless network.'

# Capability is read from the explicitly selected upstream. These tests stub only
# the native query boundary and fail if diagnostics ever modify system settings.
$script:capability='Enabled';$script:queried=@()
function Get-SharingCapability($Candidate){
    $script:queried+=$Candidate.Id
    [pscustomobject]@{Known=($script:capability -ne 'Unknown');Capability=$script:capability;Reason='fixture'}
}
function Set-NetIPInterface{throw 'Diagnostics changed an interface'}
function Remove-NetRoute{throw 'Diagnostics removed a route'}
function Start-Process{throw 'Diagnostics started a process'}
function Stop-Process{throw 'Diagnostics stopped a process'}
function Set-Service{throw 'Diagnostics changed a service'}
function Register-ScheduledTask{throw 'Diagnostics registered a task'}
$d=Test-SharingDiagnostics -Kind 'Wi-Fi' -AdapterId $wifiId.ToString()
Assert ($d.Available -and $d.StatusType -eq 'Success' -and !$d.InternetVerified) 'Capability test claimed Internet verification or rejected enabled hardware'
Assert ($d.Candidates.Count -eq 1 -and $d.Candidates[0].Id -eq $wifiId.ToString() -and $script:queried.Count -eq 1 -and $script:queried[0] -eq $wifiId.ToString()) 'Wi-Fi diagnostic queried another upstream'
$script:queried=@()
$d=Test-SharingDiagnostics -Kind '有线'
Assert ($d.Candidates.Count -eq 1 -and $d.Candidates[0].Id -eq $ethernetId.ToString() -and $script:queried[0] -eq $ethernetId.ToString()) 'Wired diagnostic queried Wi-Fi instead of the selected upstream'
$script:capability='Unknown'
$d=Test-SharingDiagnostics -Kind 'Wi-Fi'
Assert ($d.Available -and $d.StatusType -eq 'Warning' -and $d.Summary -match '待实测') 'Unknown capability was presented as ready'
$script:capability='DisabledByHardwareLimitation'
$d=Test-SharingDiagnostics -Kind 'Wi-Fi'
Assert (!$d.Available -and $d.StatusType -eq 'Error') 'Known unsupported hardware was allowed'
$script:wirelessStatus='Disabled'
$d=Test-SharingDiagnostics -Kind '有线'
Assert (!$d.Available -and $d.StatusType -eq 'Error') 'Wired sharing was allowed without an available transmitter'
$script:wirelessStatus='Up';$script:capability='Enabled'
$d=Test-SharingDiagnostics -Kind 'Wi-Fi' -AdapterId $ethernetId.ToString()
Assert (!$d.Available -and !$d.Candidates.Count) 'A stale or mismatched configured adapter was treated as selected Wi-Fi'
Assert (!(Get-Command Switch-CurrentNetworkMode -ErrorAction SilentlyContinue)) 'Unsafe in-place network switching remains exposed'
'PASS: read-only selected-upstream diagnostics; known/unknown/unsupported capability; no Internet-success inference or in-place switching.'
