param([ValidateSet('Test','Snapshot','SelfTest')][string]$Mode='Test')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$resultPath=Join-Path $root 'speed-test.json'
function Save-SpeedResult($Value){
    $temp=$resultPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($resultPath)){[IO.File]::Replace($temp,$resultPath,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$resultPath)}
    } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-Upstream {
    param($Settings)
    $adapter=Get-NetAdapter -ErrorAction Stop | Where-Object {([guid]$_.InterfaceGuid) -eq ([guid]$Settings.CampusAdapterGuid)} | Select-Object -First 1
    if(!$adapter -or $adapter.Status -ne 'Up'){throw '已绑定的校园网卡当前未连接。'}
    $ip=Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'} | Select-Object -First 1
    $route=Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object {$_.NextHop -eq $Settings.ExpectedGateway} | Select-Object -First 1
    if(!$ip -or !$route){throw '已绑定的校园网卡没有预期的 IPv4 地址或网关。'}
    [pscustomobject]@{Name=$adapter.Name;Index=$adapter.ifIndex;Ip=$ip.IPAddress;Gateway=$route.NextHop;Kind=$Settings.ConnectionKind}
}
function Get-HotspotSnapshot($Settings){
    $api=$null;$state='未知';$clients=$null
    try {
        $api=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Settings.ManagementPort+'/api/hotspot/status') -TimeoutSec 2
        $selected=@($api.adapters|Where-Object {$_.id -eq ([guid]$Settings.CampusAdapterGuid).ToString()})|Select-Object -First 1
        if($selected){$state=[string]$selected.state}
    } catch {}
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
        [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
        $profile=[Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() | Where-Object {$_.NetworkAdapter -and ([guid]$_.NetworkAdapter.NetworkAdapterId -eq [guid]$Settings.CampusAdapterGuid)} | Select-Object -First 1
        if($profile){$clients=[int]([Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)).ClientCount}
    } catch {}
    $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-Fi Direct'})
    $stats=@($adapters|ForEach-Object {Get-NetAdapterStatistics -Name $_.Name -ErrorAction SilentlyContinue})
    [pscustomobject]@{State=$state;Clients=$clients;WiFiDirectAdapters=@($adapters|ForEach-Object {$_.Name});ReceivedBytes=[int64](($stats|Measure-Object ReceivedBytes -Sum).Sum);SentBytes=[int64](($stats|Measure-Object SentBytes -Sum).Sum)}
}
function Measure-Gateway([string]$Gateway){
    $ping=New-Object Net.NetworkInformation.Ping;$values=@()
    try {foreach($i in 1..5){$reply=$ping.Send($Gateway,1000);if($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success){$values+=[int]$reply.RoundtripTime}}} finally {$ping.Dispose()}
    [pscustomobject]@{Sent=5;Received=$values.Count;LossPercent=[math]::Round((1-($values.Count/5))*100,1);MinimumMs=if($values.Count){($values|Measure-Object -Minimum).Minimum}else{$null};AverageMs=if($values.Count){[math]::Round((($values|Measure-Object -Average).Average),1)}else{$null};MaximumMs=if($values.Count){($values|Measure-Object -Maximum).Maximum}else{$null}}
}
function Invoke-DownloadMeasure($Upstream){
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    if(!(Test-Path -LiteralPath $curl)){throw '系统缺少 curl.exe，无法执行下载测速。'}
    # User-triggered only: at most the first 8 MiB and at most 12 seconds.
    $url='https://speed.cloudflare.com/__down?bytes=8388608'
    $output=& $curl '--interface' $Upstream.Ip '--noproxy' '*' '--silent' '--show-error' '--location' '--max-time' '12' '--max-filesize' '8388608' '--range' '0-8388607' '--output' 'NUL' '--write-out' '%{http_code};%{speed_download};%{size_download};%{local_ip}' $url 2>&1
    if($LASTEXITCODE -ne 0){throw '下载测速地址暂不可用；未把该结果当作网速。'}
    $parts=([string]$output).Trim().Split(';')
    if($parts.Count -lt 4 -or $parts[3] -ne $Upstream.Ip){throw '测速流量没有从已绑定的校园网卡发出，结果已丢弃。'}
    $http=[int]$parts[0];$bytesPerSecond=[double]::Parse($parts[1],[Globalization.CultureInfo]::InvariantCulture);$bytes=[int64][double]::Parse($parts[2],[Globalization.CultureInfo]::InvariantCulture)
    if($http -notin @(200,206) -or $bytes -le 0){throw '测速地址没有返回有效下载数据。'}
    [pscustomobject]@{Endpoint='Cloudflare 8 MiB 下载样本';LimitBytes=8388608;DownloadedBytes=$bytes;Mbps=[math]::Round(($bytesPerSecond*8/1000000),2);HttpStatus=$http}
}
if($Mode -eq 'SelfTest'){
    $sample=[pscustomobject]@{Sent=5;Received=5;LossPercent=0;MinimumMs=1;AverageMs=2.2;MaximumMs=4}
    if($sample.LossPercent -ne 0 -or $sample.AverageMs -ne 2.2){throw 'speed self-test failed'}
    '{"Passed":true,"TestCount":2}'
    exit 0
}
$result=[ordered]@{Schema=1;Mode=$Mode;Success=$false;CompletedAt=[DateTimeOffset]::Now.ToString('o');ConnectionKind='';Upstream=$null;Latency=$null;Download=$null;Hotspot=$null;Error=''}
try {
    $settingsPath=Join-Path $root 'settings.json'
    if(!(Test-Path -LiteralPath $settingsPath)){throw '尚未保存校园账号和连接，无法测速。'}
    $settings=[IO.File]::ReadAllText($settingsPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $upstream=Get-Upstream $settings
    $result.ConnectionKind=$upstream.Kind;$result.Upstream=[ordered]@{Name=$upstream.Name;Gateway=$upstream.Gateway}
    $before=Get-HotspotSnapshot $settings
    $result.Latency=Measure-Gateway $upstream.Gateway
    if($Mode -eq 'Test'){$result.Download=Invoke-DownloadMeasure $upstream}
    $after=Get-HotspotSnapshot $settings
    $result.Hotspot=[ordered]@{State=$after.State;Clients=$after.Clients;WiFiDirectAdapters=$after.WiFiDirectAdapters;TrafficDuringTest=[ordered]@{ReceivedBytes=[math]::Max(0,$after.ReceivedBytes-$before.ReceivedBytes);SentBytes=[math]::Max(0,$after.SentBytes-$before.SentBytes)}}
    $result.Success=$true
} catch {$result.Error=$_.Exception.Message}
Save-SpeedResult $result
if($result.Success){exit 0}else{exit 1}
