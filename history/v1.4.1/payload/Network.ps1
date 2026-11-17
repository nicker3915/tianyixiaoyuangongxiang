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
    if($Settings.ConnectionKind -eq '有线' -or !$Settings.ExpectedNetworkName){return $true}
    $profiles=@(Get-NetConnectionProfile -InterfaceIndex $Adapter.ifIndex -ErrorAction SilentlyContinue)
    return [bool]($profiles | Where-Object { [string]$_.Name -ceq [string]$Settings.ExpectedNetworkName })
}

# Reads capability for the selected upstream only; never starts or stops tethering.
function Get-SharingCapability($Candidate) {
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
        [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
        $profiles=@([Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles())
        $matching=@($profiles | Where-Object {
            $_.NetworkAdapter -and ([guid]$_.NetworkAdapter.NetworkAdapterId) -eq ([guid]$Candidate.Id) -and
            (!$Candidate.NetworkName -or [string]$_.ProfileName -ceq [string]$Candidate.NetworkName)
        })
        if(!$matching.Count){return [pscustomobject]@{Known=$false;Capability='Unknown';Reason='Windows 未返回所选连接的热点配置。'}}
        $capability=[string][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapabilityFromConnectionProfile($matching[0])
        if(!$capability -or $capability -eq 'Unknown'){return [pscustomobject]@{Known=$false;Capability='Unknown';Reason='Windows 未能确认所选连接的热点能力。'}}
        [pscustomobject]@{Known=$true;Capability=$capability;Reason=''}
    }catch{[pscustomobject]@{Known=$false;Capability='Unknown';Reason='无法读取热点能力，请以开启共享和手机联网实测为准。'}}
}

function Test-SharingDiagnostics([ValidateSet('有线','Wi-Fi')][string]$Kind='有线',[string]$AdapterId='') {
    $diag=[ordered]@{Kind=$Kind;Available=$false;StatusType='Warning';Summary='';Details='';Candidates=@();Capability='Unknown';InternetVerified=$false}
    try {
        $physical=@(Get-NetAdapter -Physical -ErrorAction Stop)
        $wireless=@($physical | Where-Object {$_.InterfaceType -eq 71 -and $_.Status -in @('Up','Disconnected')})
        if(!$wireless.Count){$diag.StatusType='Error';$diag.Summary='没有可用无线网卡，暂时不能向手机发射热点。';$diag.Details='即使电脑用网线接入，发射移动热点也需要无线网卡及驱动。';return [pscustomobject]$diag}
        $candidates=@(Get-CampusCandidates | Where-Object {$_.ConnectionKind -eq $Kind -and (!$AdapterId -or $_.Id -eq $AdapterId)})
        $diag.Candidates=$candidates
        if(!$candidates.Count){
            $diag.Summary=if($Kind -eq '有线'){'未识别到具有 IPv4 和网关的网线连接。'}else{'未识别到已连接且具有 IPv4 和网关的 Wi-Fi。'}
            $diag.Details=if($Kind -eq '有线'){'请插好校园网线，等待获得地址，再点击检测网络。'}else{'请先在 Windows 中连接校园 Wi-Fi，等待获得地址，再检测。'}
            return [pscustomobject]$diag
        }
        $capabilities=@($candidates | ForEach-Object {Get-SharingCapability $_})
        $enabled=@($capabilities | Where-Object {$_.Known -and $_.Capability -eq 'Enabled'})
        $unknown=@($capabilities | Where-Object {!$_.Known})
        $diag.Details=if($candidates.Count -eq 1){$candidates[0].Label+'；尚未验证校园认证和手机联网。'}else{'识别到 '+$candidates.Count+' 个候选连接，请在账号界面选择实际校园连接。尚未验证认证和手机联网。'}
        if($enabled.Count){
            $diag.Available=$true;$diag.StatusType='Success';$diag.Capability='Enabled';$diag.Summary='基础条件已识别；Windows 报告可使用移动热点。'
        }elseif($unknown.Count){
            $diag.Available=$true;$diag.StatusType='Warning';$diag.Summary='已识别接入连接，热点能力仍待实测。'
            $diag.Details+=' Wi-Fi 接入与发射热点并用取决于驱动和硬件。'
        }else{
            $diag.StatusType='Error';$diag.Capability=[string]$capabilities[0].Capability;$diag.Summary='Windows 报告该连接暂不支持移动热点。'
            $diag.Details+=' 返回状态：'+$diag.Capability+'。请在系统移动热点设置检查。'
        }
    }catch{$diag.StatusType='Error';$diag.Summary='未能完成网络检测，请检查系统网络服务后重试。';$diag.Details='没有修改连接、路由、热点或账号设置。'}
    [pscustomobject]$diag
}
