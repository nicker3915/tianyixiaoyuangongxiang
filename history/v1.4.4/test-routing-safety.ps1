$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot 'stage'
function Assert($ok,$message){if(!$ok){throw $message}}
$source=Join-Path $base 'Start-CampusNetwork.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
foreach($name in @('Add-AuthRoute','Assert-AuthRoutesUncontended')){
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(!$fn){throw 'Missing startup function: '+$name}
    . ([scriptblock]::Create($fn.Extent.Text))
}

$root=Join-Path $PSScriptRoot ('validation\\routing-safety-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$ledgerPath=Join-Path $root 'managed-routes.json'
$network=[pscustomobject]@{InterfaceIndex=501;Gateway='192.0.2.1'}
$settings=[pscustomobject]@{AuthTargets=@('198.51.100.7')}
$script:routes=@()
$script:newRouteCount=0
$script:removeRouteCalled=$false
$script:routeLedger=@()
function Assert-StartupAllowed {}
function Get-NetRoute {
    [CmdletBinding()]param([string]$AddressFamily,[string]$DestinationPrefix)
    @($script:routes | Where-Object {$_.DestinationPrefix -eq $DestinationPrefix})
}
function New-NetRoute {
    [CmdletBinding()]param([string]$DestinationPrefix,[int]$InterfaceIndex,[string]$NextHop,[int]$RouteMetric,[string]$PolicyStore)
    $script:newRouteCount++
    $script:routes+=([pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric})
}
function Remove-NetRoute {
    [CmdletBinding()]param()
    $script:removeRouteCalled=$true
    throw 'A foreign route must never be removed.'
}
try {
    # A route supplied by another interface/VPN must stop the workflow before
    # any route is added or removed.
    $script:routes=@([pscustomobject]@{DestinationPrefix='198.51.100.7/32';InterfaceIndex=777;NextHop='192.0.2.254';RouteMetric=1})
    $blocked=$false
    try{Assert-AuthRoutesUncontended}catch{$blocked=$true}
    Assert $blocked 'foreign authentication route was accepted'
    Assert ($script:newRouteCount -eq 0) 'preflight added a route despite a conflict'
    Assert (!$script:removeRouteCalled) 'preflight deleted a foreign route'

    # A matching pre-existing route is reused without duplication.
    $script:routes=@([pscustomobject]@{DestinationPrefix='198.51.100.7/32';InterfaceIndex=501;NextHop='192.0.2.1';RouteMetric=1})
    Assert-AuthRoutesUncontended
    Add-AuthRoute '198.51.100.7'
    Assert ($script:newRouteCount -eq 0 -and !$script:removeRouteCalled) 'matching route was changed'

    # With no route, the helper may create and ledger only its own /32.
    $script:routes=@();$script:routeLedger=@();$script:newRouteCount=0
    Assert-AuthRoutesUncontended
    Add-AuthRoute '198.51.100.7'
    Assert ($script:newRouteCount -eq 1 -and $script:routes.Count -eq 1) 'own route was not created'
    Assert ((Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json)[0].Prefix -eq '198.51.100.7/32') 'own route was not ledgered'
    Assert (!$script:removeRouteCalled) 'route helper deleted a route'
} finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
'PASS: authentication route conflicts are refused before mutation; matching and new assistant routes stay isolated.'
