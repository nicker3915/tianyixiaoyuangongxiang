function Test-CampusSubnet([string]$Address,[string]$Reference,[int]$Bits) {
    if($Bits -lt 1 -or $Bits -gt 32){return $false}
    try {$a=[Net.IPAddress]::Parse($Address).GetAddressBytes();$b=[Net.IPAddress]::Parse($Reference).GetAddressBytes()} catch {return $false}
    if($a.Length -ne 4 -or $b.Length -ne 4){return $false}
    for($i=0;$i -lt 4;$i++){
       $n=[Math]::Min(8,[Math]::Max(0,$Bits-8*$i))
       if((($a[$i] -bxor $b[$i]) -band ((255 -shl (8-$n)) -band 255)) -ne 0){return $false}
    }
    return $true
}
function Get-CampusCandidates {
    foreach($ad in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceType -in @(6,71)})){
        $kind=if($ad.InterfaceType -eq 71){'Wi-Fi'}else{'有线'}
        $networkName=''
        if($ad.InterfaceType -eq 71){
            $profile=Get-NetConnectionProfile -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
            if(!$profile -or !$profile.Name){continue}
            $networkName=[string]$profile.Name
        }
        $ips=@(Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ea SilentlyContinue | Where-Object {$_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'})
        $routes=@(Get-NetRoute -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ea SilentlyContinue | Sort-Object RouteMetric)
        foreach($rt in $routes){
            foreach($ip in $ips){
                if(!(Test-CampusSubnet $ip.IPAddress $rt.NextHop $ip.PrefixLength)){continue}
                [pscustomobject]@{Label=('{0} · {1} {2} · {3}' -f $kind,$ad.Name,$networkName,$ip.IPAddress);ConnectionKind=$kind;NetworkName=$networkName;Id=([guid]$ad.InterfaceGuid).ToString();Index=$ad.ifIndex;Ip=$ip.IPAddress;Bits=[int]$ip.PrefixLength;Gateway=$rt.NextHop}
            }
        }
    }
}
function New-AccountConfig([string]$Username,[string]$Password,[int]$Port){
    if([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrEmpty($Password)){throw '请输入自己的校园账号和密码。'}
    [ordered]@{enabled=$true;web_external_acc=$false;log_lv=2;log_dir='./';conn_timeout=10;op_timeout=15;web_port=$Port;accounts=@([ordered]@{username=$Username.Trim();password=$Password;channel='windows';mark='';time_windows=@()})}
}

function Get-ConfiguredCampusCandidates($Settings) {
    Get-CampusCandidates | Where-Object {
        $_.Id -eq $Settings.CampusAdapterGuid -and $_.Gateway -eq $Settings.ExpectedGateway -and
        (Test-CampusSubnet $_.Ip $Settings.SubnetReference $Settings.SubnetBits) -and
        (!$Settings.ExpectedNetworkName -or $_.NetworkName -ceq $Settings.ExpectedNetworkName)
    }
}



function Enter-AssistantOperation {
    $operation = New-Object Threading.Mutex($false, 'Global\GDPortalShare-Operation')
    $acquired = $false
    try {
        try { $acquired = $operation.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw '另一个设置、修复或卸载正在进行，请完成后再试。' }
        return $operation
    } catch {
        $operation.Dispose()
        throw
    }
}


function Test-CampusProfile($Adapter,$Settings) {
    if(!$Settings.ExpectedNetworkName){return $true}
    $profiles=@(Get-NetConnectionProfile -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue)
    return [bool]($profiles | Where-Object { [string]$_.Name -ceq [string]$Settings.ExpectedNetworkName })
}
