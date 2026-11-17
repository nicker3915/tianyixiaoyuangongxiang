param([switch]$FirstRun,[string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root=$PSScriptRoot;$powerShell=Join-Path $PSHOME 'powershell.exe'
$script:child=$null;$script:operation='';$script:operationStarted=$null
$script:closeAfterStop=$false;$script:allowClose=$false;$script:lastState='unconfigured';$script:operationNotice=''
$script:selectedKind='';$script:modeConfirmed=$false;$script:diagnostics=$null;$script:syncingMode=$false
$script:deviceSlots=@{};$script:nextDeviceSlot=1
$panelLock=$null
if(!$PreviewPath){
    $created=$false;$panelLock=New-Object Threading.Mutex($true,'Local\GDPortalShare-Panel',[ref]$created)
    if(!$created){[void][Windows.Forms.MessageBox]::Show('助手已经打开。请在任务栏或右下角托盘中打开面板。','校园网共享助手');$panelLock.Dispose();exit 0}
}
$networkModule=Join-Path $root 'Network.ps1'
if(Test-Path -LiteralPath $networkModule){. $networkModule}
$form=New-Object Windows.Forms.Form
$form.Text='校园网共享助手 1.4.10';$form.ClientSize=New-Object Drawing.Size(700,930);$form.MinimumSize=New-Object Drawing.Size(716,480)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='Sizable';$form.MaximizeBox=$true;$form.AutoScaleMode='Dpi'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$form.BackColor=[Drawing.Color]::FromArgb(245,247,251);$form.Icon=[Drawing.SystemIcons]::Application
function Label($text,$x,$y,$w,$h){$c=New-Object Windows.Forms.Label;$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$form.Controls.Add($c);return $c}
function Button($text,$x,$y,$w,$h,$action){
    $c=New-Object Windows.Forms.Button;$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$c.FlatStyle='Flat'
    $c.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(210,217,229);$c.BackColor=[Drawing.Color]::White;$c.Cursor='Hand';$c.Add_Click($action);$form.Controls.Add($c);return $c
}
function Set-Anchor($Control,[Windows.Forms.AnchorStyles]$Value){$Control.Anchor=$Value}
function Read-State($name){$p=Join-Path $root $name;if(Test-Path -LiteralPath $p){try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json}catch{}};return $null}
function Show-Panel{$form.Show();$form.WindowState='Normal';$form.Activate()}
function Launch-Action($file,$arguments,$label){
    if($script:child){Show-Panel;return}
    try{
        $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$powerShell
        $info.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $root $file)+'" '+$arguments
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden'
        $script:operationStarted=[DateTimeOffset]::Now;$script:operation=$label;$script:operationNotice='';$script:child=[Diagnostics.Process]::Start($info);Refresh-Panel
    }catch{$script:closeAfterStop=$false;[void][Windows.Forms.MessageBox]::Show('无法开始操作，请重试。'+[Environment]::NewLine+$_.Exception.Message,'校园网共享助手')}
}
function Select-NetworkKind([string]$Kind){
    if($script:syncingMode){return}
    $script:selectedKind=$Kind;$script:modeConfirmed=$false;$script:diagnostics=$null
    $modeStatus.Text='已选择 '+$Kind+'。请点击“检测网络”确认基础条件。'
    $modeStatus.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
    $cfg=Read-State 'settings.json'
    if($cfg -and $cfg.ConnectionKind -and $cfg.ConnectionKind -ne $Kind){$script:operationNotice='此电脑已有另一种连接的绑定。请先正常停止并清理卸载，再选择新连接设置；原备份不会被覆盖。'}else{$script:operationNotice=''}
    Refresh-Panel
}
function Confirm-NetworkSelection {
    if(!$script:selectedKind){$modeStatus.Text='请先选择 Wi-Fi 或网线连接。';return}
    $script:modeConfirmed=$true;$script:operationNotice=''
    $cfg=Read-State 'settings.json'
    $adapterId=if($cfg -and $cfg.ConnectionKind -eq $script:selectedKind){[string]$cfg.CampusAdapterGuid}else{''}
    if(Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue){$script:diagnostics=Test-SharingDiagnostics -Kind $script:selectedKind -AdapterId $adapterId}else{$script:diagnostics=[pscustomobject]@{Available=$false;StatusType='Warning';Summary='网络检测组件不可用，请修复安装。';Details='';Candidates=@()}}
    $modeStatus.Text=$script:diagnostics.Summary+[Environment]::NewLine+$script:diagnostics.Details
    $modeStatus.ForeColor=switch($script:diagnostics.StatusType){'Success' {[Drawing.Color]::FromArgb(22,101,52)} 'Error' {[Drawing.Color]::FromArgb(160,55,38)} default {[Drawing.Color]::FromArgb(133,77,14)}}
    Refresh-Panel
}
function Test-SelectionReady {
    return [bool]($script:modeConfirmed -and $script:selectedKind -and $script:diagnostics -and $script:diagnostics.Available)
}
function Test-SelectionMatchesConfig($Config){
    if(!$Config){return $true}
    $kind=if($Config.ConnectionKind){[string]$Config.ConnectionKind}else{'有线'}
    if($kind -ne $script:selectedKind){return $false}
    return [bool](@($script:diagnostics.Candidates | Where-Object {$_.Id -eq $Config.CampusAdapterGuid}).Count)
}
function Request-AccountSettings {
    if(!(Test-SelectionReady)){$script:operationNotice='请先完成步骤 1：选择接入方式并点击“检测网络”。';Refresh-Panel;return}
    $cfg=Read-State 'settings.json'
    if($cfg -and !(Test-SelectionMatchesConfig $cfg)){$script:operationNotice='所选连接与已有绑定不同。请先停止并清理卸载，再重新设置。原恢复备份会保留到恢复成功。';Refresh-Panel;return}
    $mode=if($cfg){'ResetPassword'}else{'Configure'}
    Launch-Action 'Manage.ps1' ('-Mode '+$mode+' -PreferredKind "'+$script:selectedKind+'"') '设置校园账号'
}
function Start-Sharing {
    if($script:child){return}
    if(!(Test-SelectionReady)){$script:operationNotice='请先选择接入方式并点击“检测网络”，再启动共享。';Refresh-Panel;return}
    $cfg=Read-State 'settings.json'
    if(!$cfg){Request-AccountSettings;return}
    if(!(Test-SelectionMatchesConfig $cfg)){$script:operationNotice='所选方式或网络与已有绑定不同，请正常停止并清理卸载后重新设置。';Refresh-Panel;return}
    Launch-Action 'Campus-Recovery.ps1' '-Mode Resume' '正在启动共享'
}
function Stop-Sharing{if(Test-Path (Join-Path $root 'settings.json')){Launch-Action 'Campus-Recovery.ps1' '-Mode Stop' '正在停止并恢复官方'}}
function Start-SpeedTest {
    if($script:child){return}
    if(!(Test-Path (Join-Path $root 'settings.json'))){$script:operationNotice='请先完成校园账号和连接设置，再测速。';Refresh-Panel;return}
    Launch-Action 'Speed-Test.ps1' '-Mode Test' '正在测速（最多约 25 秒、10 MB）'
}
function Start-DeviceSpeedTest {
    if($script:child){return}
    if(!(Test-Path (Join-Path $root 'settings.json'))){$script:operationNotice='请先完成校园账号和连接设置，再开启手机测速。';Refresh-Panel;return}
    try {
        $scriptPath=Join-Path $root 'Device-SpeedServer.ps1'
        if(!(Test-Path -LiteralPath $scriptPath)){throw '手机测速组件缺失，请修复安装。'}
        $arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$scriptPath+'" -Mode Start'
        Start-Process -FilePath $powerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
        $script:operationNotice='正在开启仅热点私网内的手机测速，请完成管理员授权。'
    } catch {$script:operationNotice='手机测速未开启：'+$_.Exception.Message}
    Refresh-Panel
}
function Get-SpeedSummary {
    $result=Read-State 'speed-test.json'
    if(!$result){return '尚未测速。测速只检查电脑上游；手机实际体验仍以关闭移动数据后的访问结果为准。'}
    if(!$result.Success){return '上次测速未完成：'+[string]$result.Error}
    $latency=$result.Latency
    $download=$result.Download
    $hotspot=$result.Hotspot
    $speed=if($download){([string]$download.Mbps+' Mbps')}else{'仅延迟检测'}
    $clients=if($null -ne $hotspot.Clients){[string]$hotspot.Clients+' 台'}else{'系统未提供'}
    '电脑上游下载：'+$speed+' · 延迟 '+[string]$latency.AverageMs+' ms · 丢包 '+[string]$latency.LossPercent+'%；热点：'+[string]$hotspot.State+' · 已连 '+$clients
}
function Update-SpeedValues {
    $result=Read-State 'speed-test.json'
    if(!$result -or !$result.Success){
        $downloadValue.Text='下载  —';$uploadValue.Text='上传  —';return
    }
    $downloadValue.Text='下载  '+$(if($result.Download){[string]$result.Download.Mbps+' Mbps'}else{'未完成'})
    $uploadValue.Text='上传  '+$(if($result.Upload -and $null -ne $result.Upload.Mbps){[string]$result.Upload.Mbps+' Mbps'}else{'未完成'})
}
function Get-DeviceSpeedSummary {
    $state=Read-State 'device-speed.json'
    if(!$state){return '未开启。开启后把显示的地址输入已连热点的手机浏览器。'}
    if($state.State -eq 'failed'){return '未开启：'+[string]$state.Message}
    if($state.State -ne 'running'){return [string]$state.Message}
    $items=@($state.Devices)
    if(!$items.Count){return '地址：'+[string]$state.Url+[Environment]::NewLine+'请在已连热点的手机浏览器打开；10 分钟后自动结束。'}
    $lines=@($items | Sort-Object UpdatedAt -Descending | Select-Object -First 2 | ForEach-Object {$_.Name+'：↓ '+$_.DownloadMbps+' / ↑ '+$_.UploadMbps+' Mbps'})
    return ($lines -join [Environment]::NewLine)
}
function Get-HotspotClients {
    $connectedMacs=@();$authoritative=$false
    try {
        $cfg=Read-State 'settings.json'
        [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
        [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
        $profile=[Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() | Where-Object {$_.NetworkAdapter -and ([guid]$_.NetworkAdapter.NetworkAdapterId -eq [guid]$cfg.CampusAdapterGuid)} | Select-Object -First 1
        if($profile){
            $manager=[Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
            $connectedMacs=@($manager.GetTetheringClients() | ForEach-Object {([string]$_.MacAddress).Replace(':','-').ToUpperInvariant()})
            $authoritative=$true
        }
    } catch {}
    # Read-only ARP/neighbor information from the Wi-Fi Direct hotspot adapter.
    # Windows does not expose a reliable friendly device name, so the stable MAC
    # address is retained internally and the UI assigns “设备 1 / 设备 2”.
    $rows=@()
    try {
        $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-Fi Direct'})
        foreach($adapter in $adapters){
            $local=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.AddressState -eq 'Preferred'} | ForEach-Object IPAddress)
            $neighbors=@(Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                $_.State -notin @('Unreachable','Incomplete') -and $_.IPAddress -notin $local -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notmatch '^(224|239|255)\.' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-){5}00$' -and $_.LinkLayerAddress -notmatch '^(01-00-5E|33-33|FF-FF-FF-FF-FF-FF)$'
            })
            foreach($neighbor in $neighbors){
                $mac=([string]$neighbor.LinkLayerAddress).ToUpperInvariant()
                if($authoritative -and $mac -notin $connectedMacs){continue}
                $rows+=[pscustomobject]@{Key=$mac;Ip=[string]$neighbor.IPAddress;Mac=$mac}
            }
        }
    } catch {}
    foreach($mac in $connectedMacs){if($mac -notin @($rows.Mac)){$rows+=[pscustomobject]@{Key=$mac;Ip='等待分配地址';Mac=$mac}}}
    $script:deviceDiscoveryVerified=$authoritative
    return @($rows | Group-Object Key | ForEach-Object {$_.Group | Select-Object -First 1} | Sort-Object Ip)
}
function Update-DeviceRows {
    if(!$deviceList){return}
    $state=Read-State 'device-speed.json';$reports=if($state){@($state.Devices)}else{@()}
    $clients=Get-HotspotClients
    $deviceList.BeginUpdate();$deviceList.Items.Clear()
    foreach($client in $clients){
        if(!$script:deviceSlots.ContainsKey($client.Key)){$script:deviceSlots[$client.Key]=$script:nextDeviceSlot;$script:nextDeviceSlot++}
        $report=@($reports | Where-Object {$_.Ip -eq $client.Ip} | Sort-Object UpdatedAt -Descending | Select-Object -First 1)
        $download='等待测速';$upload='等待测速';$stateText=if($script:deviceDiscoveryVerified){'已连接'}else{'缓存待确认'}
        if($report.Count){
            if($null -ne $report[0].DownloadMbps){$download=[string]$report[0].DownloadMbps+' Mbps'}
            if($null -ne $report[0].UploadMbps){$upload=[string]$report[0].UploadMbps+' Mbps'}
            $stateText='已测速'
        }
        $item=New-Object Windows.Forms.ListViewItem ('设备 '+$script:deviceSlots[$client.Key])
        [void]$item.SubItems.Add($client.Ip+' · '+$client.Mac)
        [void]$item.SubItems.Add($download);[void]$item.SubItems.Add($upload);[void]$item.SubItems.Add($stateText)
        [void]$deviceList.Items.Add($item)
    }
    if(!$clients.Count){
        $item=New-Object Windows.Forms.ListViewItem '暂无已识别设备';[void]$item.SubItems.Add('请先让手机/平板连接电脑热点');[void]$item.SubItems.Add('—');[void]$item.SubItems.Add('—');[void]$item.SubItems.Add('等待连接');[void]$deviceList.Items.Add($item)
    }
    $deviceList.EndUpdate()
}
function Start-CleanupProcess([string]$Path,[string]$Target){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Path;$info.Arguments='/TARGET="'+$Target+'"';$info.UseShellExecute=$true
    $process=[Diagnostics.Process]::Start($info)
    if(!$process){throw '清理工具未启动。'}
    $process.Dispose()
}
function Complete-CleanupHandoff{$script:allowClose=$true;$form.Close()}
function Start-RegularUninstallProcess([string]$Path){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Path;$info.WorkingDirectory=[IO.Path]::GetTempPath();$info.UseShellExecute=$true
    $process=[Diagnostics.Process]::Start($info)
    if(!$process){throw '卸载器未启动。'}
    $process.Dispose()
}
function Complete-RegularUninstallHandoff{$script:allowClose=$true;$form.Close()}
function Open-RegularUninstall {
    if($script:child){return}
    try {
        $uninstaller=Join-Path $root 'unins000.exe'
        if(!(Test-Path -LiteralPath $uninstaller)){throw '卸载器缺失。'}
        Start-RegularUninstallProcess $uninstaller
        # The native uninstaller owns confirmation and restoration. Release this
        # panel and its launcher without changing the connection before consent.
        Complete-RegularUninstallHandoff
    }catch{$script:operationNotice='旧卸载器未能启动或授权被取消。可使用“一键清理与卸载”恢复；当前连接未由此操作改变。';Refresh-Panel}
}
function Open-AssistantCleanup {
    if($script:child){return}
    try {
        $source=Join-Path $root '校园网共享助手-清理与卸载.exe'
        if(!(Test-Path -LiteralPath $source)){throw '缺少独立清理工具。请使用新版安装包旁的同名 EXE；即使旧版无法打开，也能独立运行。'}
        $handoff=Join-Path ([IO.Path]::GetTempPath()) ('GDPortalShare-Cleanup-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($handoff)
        $tool=Join-Path $handoff '校园网共享助手-清理与卸载.exe'
        [IO.File]::Copy($source,$tool,$false)
        Start-CleanupProcess $tool $root
        # The external tool asks for confirmation before changing networking.
        # Closing this panel releases its executable so the tool can remove it.
        Complete-CleanupHandoff
    }catch{$script:operationNotice=$_.Exception.Message;Refresh-Panel}
}
$title=Label '校园网，分享给手机' 28 22 560 36;$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',19,[Drawing.FontStyle]::Bold)
$version=Label '1.4.10' 605 33 65 24;$version.TextAlign='MiddleRight';$version.ForeColor=[Drawing.Color]::DimGray
$subtitle=Label '先确认接入方式，再检测、填写账号并开启共享。' 30 67 640 28;$subtitle.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$stepOne=Label '1  选择电脑如何接入校园网' 30 111 640 28;$stepOne.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
$rbWifi=New-Object Windows.Forms.RadioButton;$rbWifi.Text='Wi-Fi 连接';$rbWifi.SetBounds(34,150,155,30);$rbWifi.Cursor='Hand';$form.Controls.Add($rbWifi)
$rbWired=New-Object Windows.Forms.RadioButton;$rbWired.Text='网线连接（有线）';$rbWired.SetBounds(205,150,195,30);$rbWired.Cursor='Hand';$form.Controls.Add($rbWired)
$checkButton=Button '检测网络' 500 144 170 38 {Confirm-NetworkSelection}
$modeStatus=Label '请选择 Wi-Fi 或网线，然后检测。检测不会修改账号、网络或热点。' 30 193 640 65;$modeStatus.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$modeStatus.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$stepTwo=Label '2  确认账号并开启共享' 30 270 640 28;$stepTwo.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
$accountButton=Button '填写校园账号' 30 307 204 42 {Request-AccountSettings}
$startButton=Button '启动共享' 248 307 204 42 {Start-Sharing};$startButton.BackColor=[Drawing.Color]::FromArgb(30,95,210);$startButton.ForeColor=[Drawing.Color]::White
$stopButton=Button '停止并切回官方' 466 307 204 42 {Stop-Sharing};$stopButton.ForeColor=[Drawing.Color]::FromArgb(160,55,38)
$status=Label '尚未设置校园账号' 30 370 640 31;$status.Font=New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
$network=Label '尚未保存校园连接。' 30 408 640 25;$network.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$network.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$detail=Label '首次使用请从上方步骤 1 开始。' 30 441 640 48;$detail.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$notice=Label '' 30 492 640 34;$notice.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$notice.ForeColor=[Drawing.Color]::FromArgb(133,77,14)
$deviceBox=New-Object Windows.Forms.GroupBox;$deviceBox.Text='已连接热点的设备';$deviceBox.SetBounds(30,530,640,176);$deviceBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold);$form.Controls.Add($deviceBox)
$deviceList=New-Object Windows.Forms.ListView;$deviceList.SetBounds(13,24,614,104);$deviceList.View='Details';$deviceList.FullRowSelect=$true;$deviceList.GridLines=$true;$deviceList.HeaderStyle='Nonclickable';$deviceList.Font=New-Object Drawing.Font('Microsoft YaHei UI',8);[void]$deviceList.Columns.Add('设备',82);[void]$deviceList.Columns.Add('识别信息（IP / MAC）',210);[void]$deviceList.Columns.Add('下载',105);[void]$deviceList.Columns.Add('上传',105);[void]$deviceList.Columns.Add('状态',90);$deviceBox.Controls.Add($deviceList)
$deviceInfo=New-Object Windows.Forms.Label;$deviceInfo.Text='自动识别已连热点的设备；每台设备打开测速地址一次后显示其独立结果。';$deviceInfo.SetBounds(14,134,420,24);$deviceInfo.Font=New-Object Drawing.Font('Microsoft YaHei UI',8);$deviceInfo.ForeColor=[Drawing.Color]::FromArgb(85,98,118);$deviceBox.Controls.Add($deviceInfo)
$deviceButton=New-Object Windows.Forms.Button;$deviceButton.Text='开启设备测速';$deviceButton.SetBounds(476,132,150,27);$deviceButton.Cursor='Hand';$deviceButton.Add_Click({Start-DeviceSpeedTest});$deviceBox.Controls.Add($deviceButton)
$speedBox=New-Object Windows.Forms.GroupBox;$speedBox.Text='本电脑网络速度（校园网上游）';$speedBox.SetBounds(30,720,640,96);$speedBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold);$form.Controls.Add($speedBox)
$downloadValue=New-Object Windows.Forms.Label;$downloadValue.Text='下载  —';$downloadValue.SetBounds(16,27,285,24);$downloadValue.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold);$downloadValue.ForeColor=[Drawing.Color]::FromArgb(28,93,191);$speedBox.Controls.Add($downloadValue)
$uploadValue=New-Object Windows.Forms.Label;$uploadValue.Text='上传  —';$uploadValue.SetBounds(325,27,285,24);$uploadValue.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold);$uploadValue.ForeColor=[Drawing.Color]::FromArgb(22,118,81);$speedBox.Controls.Add($uploadValue)
$speedInfo=New-Object Windows.Forms.Label;$speedInfo.Text='未测速';$speedInfo.SetBounds(16,57,600,22);$speedInfo.Font=New-Object Drawing.Font('Microsoft YaHei UI',8);$speedInfo.ForeColor=[Drawing.Color]::FromArgb(85,98,118);$speedBox.Controls.Add($speedInfo)
$speedButton=Button '测速本电脑（约 25 秒）' 30 832 190 34 {Start-SpeedTest}
$hotspotButton=Button '查看热点名称和密码' 235 832 190 34 {Start-Process 'ms-settings:network-mobilehotspot'}
$cleanButton=Button '一键清理与卸载' 440 832 150 34 {Open-AssistantCleanup};$cleanButton.ForeColor=[Drawing.Color]::FromArgb(160,55,38)
$uninstallButton=Button '常规卸载' 600 832 70 34 {Open-RegularUninstall}
$folderButton=Button '安装文件夹' 30 882 145 32 {Start-Process -FilePath $root}
$helpButton=Button '使用说明' 190 882 145 32 {Start-Process -FilePath (Join-Path $root '使用说明.txt')}
$hideButton=Button '收起到托盘' 350 882 145 32 {$form.Hide()}
$exitButton=Button '退出…' 510 882 160 32 {$form.Close()}
Set-Anchor $version ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right)
foreach($control in @($subtitle,$stepOne,$modeStatus,$stepTwo,$status,$network,$detail,$notice,$deviceBox,$speedBox)){Set-Anchor $control ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right)}
Set-Anchor $checkButton ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right)
Set-Anchor $deviceList ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right)
Set-Anchor $deviceInfo ([Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Bottom)
Set-Anchor $deviceButton ([Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom)
Set-Anchor $uploadValue ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right)
Set-Anchor $speedInfo ([Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right)
foreach($control in @($speedButton,$hotspotButton,$cleanButton,$uninstallButton,$folderButton,$helpButton,$hideButton,$exitButton)){Set-Anchor $control ([Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Top)}
$form.AutoScroll=$true
$form.AutoScrollMinSize=New-Object Drawing.Size(680,930)
$available=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Height=[math]::Min($form.Height,[math]::Max(480,$available.Height-40))
$form.Add_Resize({
    if($deviceList -and !$deviceList.IsDisposed){$deviceList.Columns[1].Width=[math]::Max(210,$deviceList.ClientSize.Width-386)}
})
$rbWifi.Add_CheckedChanged({if($rbWifi.Checked){Select-NetworkKind 'Wi-Fi'}})
$rbWired.Add_CheckedChanged({if($rbWired.Checked){Select-NetworkKind '有线'}})
$cfg=Read-State 'settings.json'
if($cfg){$script:syncingMode=$true;$script:selectedKind=if($cfg.ConnectionKind){[string]$cfg.ConnectionKind}else{'有线'};if($script:selectedKind -eq 'Wi-Fi'){$rbWifi.Checked=$true}else{$rbWired.Checked=$true};$script:syncingMode=$false;$modeStatus.Text='已显示保存的接入方式。请点击“检测网络”，确认当前基础条件。'}
$tray=New-Object Windows.Forms.NotifyIcon;$tray.Icon=$form.Icon;$tray.Text='校园网共享助手';$tray.Visible=(!$PreviewPath)
$menu=New-Object Windows.Forms.ContextMenuStrip
$showItem=$menu.Items.Add('打开面板');$showItem.Add_Click({Show-Panel})
$startItem=$menu.Items.Add('启动共享');$startItem.Add_Click({Start-Sharing})
$stopItem=$menu.Items.Add('停止并切回官方');$stopItem.Add_Click({Stop-Sharing})
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem=$menu.Items.Add('退出…');$exitItem.Add_Click({Show-Panel;$form.Close()})
$tray.ContextMenuStrip=$menu;$tray.Add_DoubleClick({Show-Panel})
function Refresh-Panel {
    if($script:child -and $script:child.HasExited){
        $code=$script:child.ExitCode;$script:child.Dispose();$script:child=$null
        if($script:operation -eq '网络测速'){
            $speed=Read-State 'speed-test.json'
            $script:operationNotice=if($speed -and $speed.Success){'测速完成。电脑上游结果不等于手机实际联网结果。'}elseif($speed){'测速未完成：'+[string]$speed.Error}else{'测速未完成，请稍后重试。'}
        } elseif($script:operation -ne '设置校园账号'){
            $r=Read-State 'recovery-last-result.json';$script:operationNotice=if($code -eq 0){'操作已完成。'}else{'操作未完成，请检查管理员授权并重试。'}
            if($r -and $r.Time -and [DateTimeOffset]::Parse($r.Time) -ge $script:operationStarted.AddSeconds(-2)){$script:operationNotice=[string]$r.Message}
            if($script:closeAfterStop){$script:closeAfterStop=$false;$s=Read-State 'assistant-state.json';if($code -eq 0 -and $s.State -eq 'stopped'){$script:allowClose=$true;$form.Close();return};Show-Panel}
        }
    }
    $cfg=Read-State 'settings.json';$configured=($null -ne $cfg);$busy=($null -ne $script:child)
    foreach($b in @($cleanButton,$uninstallButton,$stopButton,$checkButton,$rbWifi,$rbWired,$stopItem)){$b.Enabled=(!$busy)}
    $stopButton.Enabled=($configured -and !$busy);$stopItem.Enabled=$stopButton.Enabled
    $ready=Test-SelectionReady
    $matching=if($configured -and $ready){Test-SelectionMatchesConfig $cfg}else{!$configured}
    $startButton.Enabled=(!$busy -and $ready -and $matching);$startItem.Enabled=$startButton.Enabled
    $startButton.BackColor=if($startButton.Enabled){[Drawing.Color]::FromArgb(30,95,210)}else{[Drawing.Color]::FromArgb(222,229,239)}
    $startButton.ForeColor=if($startButton.Enabled){[Drawing.Color]::White}else{[Drawing.Color]::FromArgb(85,98,118)}
    $accountButton.Enabled=(!$busy -and $ready -and $matching)
    $speedButton.Enabled=($configured -and !$busy)
    $deviceButton.Enabled=($configured -and !$busy)
    $speedInfo.Text=Get-SpeedSummary
    $deviceInfo.Text=Get-DeviceSpeedSummary
    Update-SpeedValues
    Update-DeviceRows
    $accountButton.Text=if($configured){'修改校园账号'}else{'填写校园账号'}
    $notice.Text=if($script:operationNotice){$script:operationNotice}else{'手机连接热点后请关闭移动数据，再访问新网页确认共享是否成功。'}
    $status.ForeColor=[Drawing.Color]::FromArgb(33,48,70)
    if($busy){$status.Text=$script:operation;$detail.Text='请完成可能出现的管理员授权。操作结果会显示在这里。';return}
    if(!$configured){$script:lastState='unconfigured';$status.Text='尚未设置校园账号';$network.Text='尚未保存校园连接。';$detail.Text='从步骤 1 开始。检测和选择接入方式不会写入配置。';return}
    $network.Text=if($cfg.ExpectedNetworkName){'已绑定：'+$cfg.ExpectedNetworkName+' · '+$cfg.ConnectionKind}else{'已绑定：校园有线连接'}
    $s=Read-State 'assistant-state.json';$script:lastState=[string]$s.State
    if(Test-Path (Join-Path $root 'uninstall-in-progress.flag')){
        $status.Text='卸载恢复尚未完成';$detail.Text='程序和恢复备份已保留，可使用“一键清理与卸载”继续恢复。'
        foreach($b in @($startButton,$accountButton,$startItem)){$b.Enabled=$false};return
    }
    if($s.State -eq 'stopped'){
        $status.Text='助手已停止 · 可使用官方客户端';$detail.Text='助手热点、认证与自动运行已停止；账号和恢复备份仍保留。';$stopButton.Enabled=$false;$stopItem.Enabled=$false
        $attempt=Read-State 'recovery-last-result.json';$attemptAt=[DateTimeOffset]::MinValue;$stateAt=[DateTimeOffset]::MinValue
        if($attempt -and $attempt.Mode -eq 'Resume' -and $attempt.Success -eq $false -and [DateTimeOffset]::TryParse([string]$attempt.Time,[ref]$attemptAt) -and [DateTimeOffset]::TryParse([string]$s.UpdatedAt,[ref]$stateAt) -and $attemptAt -ge $stateAt){$status.Text='共享未启动';$status.ForeColor=[Drawing.Color]::FromArgb(160,55,38);$detail.Text=[string]$attempt.Message;$notice.Text='助手仍处于停止状态，处理提示后重新启动。'}
        $tray.Text='校园网共享助手 · '+$status.Text;return
    }
    if($s.State -eq 'start-requested'){$status.Text='正在请求启动共享';$detail.Text='正在启动认证和热点，需要中止时可点击“停止并切回官方”。';return}
    if($s.State -eq 'stopping'){$status.Text='正在停止并恢复官方';$detail.Text='正在关闭共享并恢复网络设置，请稍候。';return}
    if($s.State -eq 'needs-attention'){$status.Text='操作需要处理';$detail.Text=if($s.Message){[string]$s.Message}else{'请按提示重试停止或启动。'};return}
    if(Test-Path (Join-Path $root 'watchdog-paused.flag')){$status.Text='自动运行已暂停';$detail.Text='点击停止可完整恢复；准备好网络后可启动共享。';return}
    if(Test-Path (Join-Path $root 'Client\ESurfingClient.json.pending')){$status.Text='新账号已保存';$detail.Text='请先停止助手，再启动共享使新账号生效。';return}
    $last=Read-State 'last-status.json'
    $status.Text=switch($last.Result){'ready' {'最近一次共享启动完成'} 'existing-hotspot-check-upstream' {'请核对热点共享来源'} 'needs-attention' {'启动需要处理'} 'not-at-campus' {'等待已绑定的校园网络'} 'pending' {'正在启动共享'} default {'账号已保存，可以启动共享'}}
    $detail.Text=switch($last.Stage){'waiting-for-campus' {'请连接已绑定的校园 Wi-Fi 或网线。'} 'waiting-for-authentication' {'正在认证校园账号，请稍候。'} 'verifying-campus-internet' {'正在验证校园连接能否访问网页。'} 'starting-hotspot' {'正在开启 Windows 移动热点。'} 'failed' {'请检查官方客户端是否退出、账号和校园连接是否正确。'} default {'以手机关闭移动数据后实际打开新网页为准。'}}
    if($last.Result -eq 'ready'){$status.ForeColor=[Drawing.Color]::FromArgb(22,118,81)}
    if($last.Result -eq 'existing-hotspot-check-upstream'){$detail.Text='Windows 已有热点，请在系统设置确认共享来源为已绑定的校园连接。'}
    if($last.CompletedAt){$detail.Text+=[Environment]::NewLine+'最近检查：'+([DateTimeOffset]::Parse($last.CompletedAt).ToLocalTime().ToString('MM-dd HH:mm'))}
    $tray.Text=('校园网共享助手 · '+$status.Text)
}
function Ask-Close{
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='退出校园网共享助手';$dialog.ClientSize=New-Object Drawing.Size(460,205)
    $dialog.Font=$form.Font;$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MinimizeBox=$false;$dialog.MaximizeBox=$false
    $text=New-Object Windows.Forms.Label;$text.Text='退出前，要停止共享并切回官方客户端吗？';$text.SetBounds(22,24,420,50);$dialog.Controls.Add($text)
    $stop=New-Object Windows.Forms.Button;$stop.Text='停止并退出';$stop.SetBounds(22,90,194,40);$stop.DialogResult='Yes';$dialog.Controls.Add($stop)
    $hide=New-Object Windows.Forms.Button;$hide.Text='保持共享，收起窗口';$hide.SetBounds(230,90,208,40);$hide.DialogResult='No';$dialog.Controls.Add($hide)
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.SetBounds(338,150,100,32);$cancel.DialogResult='Cancel';$dialog.Controls.Add($cancel);$dialog.CancelButton=$cancel
    $choice=$dialog.ShowDialog($form);$dialog.Dispose();return $choice
}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=1500;$timer.Add_Tick({Refresh-Panel})
$form.Add_FormClosing({
    param($sender,$e)
    if($script:allowClose -or $PreviewPath -or $e.CloseReason -eq 'WindowsShutDown'){return}
    if($script:child){$e.Cancel=$true;[void][Windows.Forms.MessageBox]::Show('请完成或取消当前操作，再退出助手。','操作进行中');return}
    Refresh-Panel;if($script:lastState -in @('stopped','unconfigured')){return};$e.Cancel=$true
    switch(Ask-Close){'Yes' {$script:closeAfterStop=$true;Stop-Sharing} 'No' {$form.Hide()}}
})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();$tray.Visible=$false;$tray.Dispose();$menu.Dispose()})
Refresh-Panel
if($PreviewPath){
    $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-30000,-30000)
    $form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath);$bitmap.Dispose();$form.Dispose();exit 0
}
$form.Add_Shown({$timer.Start();if($FirstRun){$checkButton.Focus()}})
try{[void]$form.ShowDialog()}finally{$form.Dispose();if($panelLock){$panelLock.ReleaseMutex();$panelLock.Dispose()}}
