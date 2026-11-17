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

function Test-SharingDiagnostics([string]$Kind = '有线') {
    $diag = [ordered]@{
        Kind = $Kind
        Available = $false
        StatusType = 'Warning'
        Summary = ''
        Details = ''
    }

    $wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -eq 71 })
    $ethAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -eq 6 })
    $activeEth = @($ethAdapters | Where-Object { $_.Status -eq 'Up' })
    $activeWifi = @($wifiAdapters | Where-Object { $_.Status -eq 'Up' })

    if ($Kind -eq '有线') {
        if ($ethAdapters.Count -eq 0) {
            $diag.StatusType = 'Error'
            $diag.Summary = '未检测到电脑有线网卡（以太网接口）。'
            $diag.Details = '请确认网卡驱动已安装。'
            return [pscustomobject]$diag
        }
        if ($activeEth.Count -eq 0) {
            $diag.StatusType = 'Warning'
            $diag.Summary = '网线未插好或未连通。'
            $diag.Details = '请插紧校园网线，确认以太网已启用并获得 IP。'
            return [pscustomobject]$diag
        }
        if ($wifiAdapters.Count -eq 0) {
            $diag.StatusType = 'Error'
            $diag.Summary = '电脑缺少无线网卡（Wi-Fi），无法发射热点给手机。'
            $diag.Details = '网线让电脑上网，但共享给手机需要无线网卡发射 Wi-Fi 热点。台式机请插入 USB 无线网卡。'
            return [pscustomobject]$diag
        }
        $wifiDisabled = @($wifiAdapters | Where-Object { $_.Status -eq 'Disabled' })
        if ($wifiDisabled.Count -eq $wifiAdapters.Count) {
            $diag.StatusType = 'Warning'
            $diag.Summary = '检测到无线网卡已被禁用。'
            $diag.Details = '请在 Windows 设置或“更改适配器选项”中启用 Wi-Fi，热点才能正常发射。'
            return [pscustomobject]$diag
        }
        $diag.Available = $true
        $diag.StatusType = 'Success'
        $diag.Summary = '✔ 网线共享就绪：支持通过移动热点将有线校园网共享给手机！'
        $diag.Details = ('电脑通过网线正常上网 (' + $activeEth[0].Name + ')，并由无线网卡 (' + $wifiAdapters[0].Name + ') 发射热点。')
        return [pscustomobject]$diag
    } else {
        if ($wifiAdapters.Count -eq 0) {
            $diag.StatusType = 'Error'
            $diag.Summary = '电脑未检测到无线网卡。'
            $diag.Details = '请安装无线网卡或驱动后再试。'
            return [pscustomobject]$diag
        }
        if ($activeWifi.Count -eq 0) {
            $diag.StatusType = 'Warning'
            $diag.Summary = '尚未连接校园 Wi-Fi 信号。'
            $diag.Details = '请先在 Windows 右下角网络列表连接校园 Wi-Fi，再填写账号。'
            return [pscustomobject]$diag
        }
        $diag.Available = $true
        $diag.StatusType = 'Success'
        $diag.Summary = '✔ 无线共享就绪：已连接校园 Wi-Fi，支持开启热点共享。'
        $diag.Details = ('电脑连接校园 Wi-Fi (' + $wifiAdapters[0].Name + ')，并同时发射热点供手机连接。')
        return [pscustomobject]$diag
    }
}

function Switch-CurrentNetworkMode([string]$Root, [string]$TargetKind) {
    $cfgPath = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return @{ Success = $false; Message = '尚未设置校园账号，请先填写账号。' } }
    $cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    
    $candidates = @(Get-CampusCandidates | Where-Object { $_.ConnectionKind -eq $TargetKind })
    if ($candidates.Count -eq 0) {
        $msg = if ($TargetKind -eq '有线') { '未检测到连通的网线，请插好网线获得 IP 后再切换。' } else { '未检测到连通的校园 Wi-Fi，请在系统右下角连接 Wi-Fi 后再切换。' }
        return @{ Success = $false; Message = $msg }
    }
    
    $net = $candidates[0]
    
    if ($cfg.CampusAdapterGuid -and $cfg.CampusAdapterGuid -ne $net.Id) {
        $oldAd = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { ([guid]$_.InterfaceGuid).ToString() -eq $cfg.CampusAdapterGuid } | Select-Object -First 1
        if ($oldAd) {
            Set-NetIPInterface -InterfaceIndex $oldAd.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        }
        $ledgerPath = Join-Path $Root 'managed-routes.json'
        if (Test-Path -LiteralPath $ledgerPath) {
            try {
                $routes = @([IO.File]::ReadAllText($ledgerPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
                foreach ($r in $routes) {
                    Get-NetRoute -DestinationPrefix $r.Prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object NextHop -eq $r.Gateway | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    $cfg.CampusAdapterGuid = $net.Id
    $cfg.ConnectionKind = $net.ConnectionKind
    $cfg.ExpectedNetworkName = if ($net.ConnectionKind -eq '有线') { '' } else { $net.NetworkName }
    $cfg.ExpectedGateway = $net.Gateway
    $cfg.SubnetReference = $net.Ip
    $cfg.SubnetBits = $net.Bits
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    
    $journalPath = Join-Path $Root 'original-startup.json'
    if (Test-Path -LiteralPath $journalPath) {
        try {
            $j = [IO.File]::ReadAllText($journalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $j.Adapter = $net.Id
            $j.Gateway = $net.Gateway
            [IO.File]::WriteAllText($journalPath, ($j | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    
    return @{
        Success = $true
        Message = ('已切换为【' + $TargetKind + '】: ' + $net.Label)
        Network = $net
    }
}
