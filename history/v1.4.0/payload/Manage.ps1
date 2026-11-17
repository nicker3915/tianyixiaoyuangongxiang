param([ValidateSet('Configure','Uninstall','ResetPassword')][string]$Mode='Configure', [string]$PreferredKind='')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'Network.ps1')
. (Join-Path $root 'Lifecycle.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
function Alert($s){[void][Windows.Forms.MessageBox]::Show([string]$s,'校园网共享助手')}
function Save($path,$o){$tmp=$path+'.new';[IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $o -Depth 8),[Text.UTF8Encoding]::new($false));if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}}
function Read-Json($p){[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)|ConvertFrom-Json}
$task='GDPortalShare-Logon'
$launcher=Join-Path $root 'CampusQuietLauncher.exe'
$exe=Join-Path $root 'Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe'
$account=Join-Path $root 'Client\ESurfingClient.json'
$journal=Join-Path $root 'original-startup.json'
$runPath='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
$runName='Esurfing Client in Campus'
$svcKey='HKLM:\SYSTEM\CurrentControlSet\Services\ESurfingSvr'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$sid=$identity.User.Value
function Get-OwnTasks {
    foreach($name in @($task,($task+'-Watchdog'))){
        $t=Get-ScheduledTask -TaskPath '\' -TaskName $name -ea SilentlyContinue
        if($t){if(@($t.Actions).Count -ne 1 -or $t.Actions[0].Execute -ne $launcher){throw "发现同名但不属于本助手的任务：$name"};$t}
    }
}
function Snapshot($net) {
    $r=Get-Item -LiteralPath $runPath -ea SilentlyContinue
    $has=$r -and $r.GetValueNames() -contains $runName
    $v=if($has){$r.GetValue($runName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    if($has -and $v -notmatch '(?i)\\Chinatelecom_GDPortal\\AutoStart\.exe(?:"|\s|$)'){throw '官方自启动项的内容不符合此版本，已保留原样。'}
    $svc=Get-ItemProperty -LiteralPath $svcKey -ea SilentlyContinue
    if($svc -and $svc.ImagePath -notmatch '(?i)\\Chinatelecom_GDPortal\\ESurfingSvr\.exe(?:"|\s|$)'){throw '官方服务的路径不符合此版本，已保留原样。'}
    $m=Get-NetIPInterface -InterfaceIndex $net.Index -AddressFamily IPv4
    [ordered]@{RunExists=[bool]$has;RunValue=$v;RunKind=$(if($has){[string]$r.GetValueKind($runName)});ServiceAuto=($svc -and $svc.Start -eq 2);Delayed=$(if($svc){$svc.DelayedAutoStart});Adapter=$net.Id;Gateway=$net.Gateway;AutoMetric=[string]$m.AutomaticMetric;Metric=[int]$m.InterfaceMetric}
}
function Restore {
    $b=Read-Json $journal
    $tasks=@(Get-OwnTasks)
    $lock=New-Object Threading.Mutex($false,('Global\CampusNetwork-'+([guid]$b.Adapter).ToString('N')))
    $held=$false
    try {
    try {$held=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(!$held){throw '助手正在设置网络。请等几分钟后重试卸载。'}
    [IO.File]::WriteAllText((Join-Path $root 'watchdog-paused.flag'),'restore')

    foreach($t in $tasks){Disable-ScheduledTask -InputObject $t | Out-Null}
    if(@($tasks|Where-Object {(Get-ScheduledTask -TaskPath '\' -TaskName $_.TaskName).State -eq 'Running'}).Count){throw '启动或守护任务正在结束。请稍等一分钟再重试卸载。'}
    if($b.RunExists -and -not (Get-ItemProperty -LiteralPath $runPath -Name $runName -ea SilentlyContinue)){
        New-ItemProperty -LiteralPath $runPath -Name $runName -Value $b.RunValue -PropertyType $b.RunKind | Out-Null
    }
    if($b.ServiceAuto -and (Test-Path $svcKey) -and (Get-ItemProperty $svcKey).Start -in @(2,3)){
        $currentService=Get-ItemProperty $svcKey
        if($currentService.ImagePath -notmatch '(?i)\\Chinatelecom_GDPortal\\ESurfingSvr\.exe(?:"|\s|$)'){throw '官方服务路径已改变，请核对后再卸载。'}
        Set-Service ESurfingSvr -StartupType Automatic
        if($null -ne $b.Delayed){Set-ItemProperty -LiteralPath $svcKey -Name DelayedAutoStart -Value ([int]$b.Delayed)}
        elseif((Get-Item $svcKey).GetValueNames() -contains 'DelayedAutoStart'){Remove-ItemProperty -LiteralPath $svcKey -Name DelayedAutoStart}
    }
    $ad=Get-NetAdapter | Where-Object {([guid]$_.InterfaceGuid).ToString() -eq $b.Adapter} | Select-Object -First 1
    if($ad){
       $m=Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ea SilentlyContinue
       if($m -and [string]$m.AutomaticMetric -eq 'Disabled' -and $m.InterfaceMetric -eq 10){
          if($b.AutoMetric -eq 'Enabled'){Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -PolicyStore ActiveStore}
          else{Set-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -InterfaceMetric $b.Metric -PolicyStore ActiveStore}
       }
       $ledger=Join-Path $root 'managed-routes.json'
       if(Test-Path $ledger){foreach($r in @(Read-Json $ledger)){
         if($r.AdapterGuid -ne $b.Adapter -or $r.Gateway -ne $b.Gateway){continue}
         Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix $r.Prefix -PolicyStore ActiveStore -ea SilentlyContinue | Where-Object NextHop -eq $b.Gateway | Remove-NetRoute -Confirm:$false
       }}
    }
    foreach($t in $tasks){Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath '\' -Confirm:$false}
    foreach($p in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ea SilentlyContinue)){if($p.Path -eq $exe){$p.Kill();[void]$p.WaitForExit(5000)}}
    } finally {if($held){$lock.ReleaseMutex()};$lock.Dispose()}
}
function Register-Work($name,$mode,$delay,$repeat){
    $action=New-ScheduledTaskAction -Execute $launcher -Argument $mode -WorkingDirectory $root
    $tr=New-ScheduledTaskTrigger -AtLogOn -User $sid
    $tr.Delay=$delay
    if($repeat){$tr.Repetition=(New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition}
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $opts=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $tr -Principal $principal -Settings $opts | Out-Null
}
function CredForm($nets,$reset,[string]$PreferredKind=''){
    $f=New-Object Windows.Forms.Form
    $f.Text='校园网共享助手 · '+$(if($reset){'切换网络与账号'}else{'首次设置'})
    $f.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $f.ClientSize=New-Object Drawing.Size(560,430)
    $f.StartPosition='CenterScreen';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false;$f.AutoScaleMode='Dpi'
    function Field($c,$x,$y,$width,$height){$c.SetBounds($x,$y,$width,$height);[void]$f.Controls.Add($c)}
    function Caption($s,$x,$y,$width,$height){$l=New-Object Windows.Forms.Label;$l.Text=$s;Field $l $x $y $width $height}
    
    Caption '先选择接入方式（网线或 Wi-Fi），再填写自己的校园账号。' 20 14 520 24
    
    Caption '接入方式' 20 46 80 24
    $rbWired=New-Object Windows.Forms.RadioButton
    $rbWired.Text='网线连接 (以太网)'
    $rbWired.Cursor='Hand'
    Field $rbWired 110 44 160 28
    
    $rbWifi=New-Object Windows.Forms.RadioButton
    $rbWifi.Text='无线连接 (Wi-Fi)'
    $rbWifi.Cursor='Hand'
    Field $rbWifi 280 44 160 28

    $diagPanel=New-Object Windows.Forms.Panel
    $diagPanel.BorderStyle='FixedSingle'
    Field $diagPanel 20 78 520 58
    $diagTitle=New-Object Windows.Forms.Label
    $diagTitle.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5,[Drawing.FontStyle]::Bold)
    $diagTitle.SetBounds(8, 6, 502, 22)
    $diagPanel.Controls.Add($diagTitle)
    $diagDetail=New-Object Windows.Forms.Label
    $diagDetail.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $diagDetail.SetBounds(8, 30, 502, 22)
    $diagPanel.Controls.Add($diagDetail)

    Caption '上网连接' 20 148 80 24
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList'
    Field $combo 110 144 430 30

    Caption '校园账号' 20 188 80 24
    $u=New-Object Windows.Forms.TextBox
    Field $u 110 184 430 30

    Caption '校园密码' 20 228 80 24
    $pw=New-Object Windows.Forms.TextBox;$pw.UseSystemPasswordChar=$true
    Field $pw 110 224 430 30

    $showPassword=New-Object Windows.Forms.CheckBox;$showPassword.Text='显示密码'
    Field $showPassword 110 258 180 24
    $showPassword.Add_CheckedChanged({$pw.UseSystemPasswordChar=-not $showPassword.Checked})

    Caption '凭据仅保存在本机受限目录。首次保存后可启动共享；随时可停止并切回官方。' 20 288 520 42

    $btnRefresh=New-Object Windows.Forms.Button;$btnRefresh.Text='重新检测';$btnRefresh.Cursor='Hand'
    Field $btnRefresh 20 365 100 34

    $ok=New-Object Windows.Forms.Button;$ok.Text='确认';$ok.Cursor='Hand'
    Field $ok 335 365 95 34

    $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.DialogResult='Cancel';$cancel.Cursor='Hand'
    Field $cancel 445 365 95 34

    function Filter-Nets($allNets, [string]$targetKind) {
        return @($allNets | Where-Object { 
            if ($_.ConnectionKind) { $_.ConnectionKind -eq $targetKind }
            elseif ($targetKind -eq '有线') { $_.Label -notmatch '(?i)wi-?fi|wlan|无线' }
            else { $_.Label -match '(?i)wi-?fi|wlan|无线' }
        })
    }

    $script:currentFilteredNets=@()
    function Update-View {
        $kind = if ($rbWired.Checked) { '有线' } else { 'Wi-Fi' }
        $script:currentFilteredNets = @(Filter-Nets $nets $kind)
        $combo.Items.Clear()
        if ($script:currentFilteredNets.Count -gt 0) {
            foreach ($item in $script:currentFilteredNets) {
                [void]$combo.Items.Add($item.Label)
            }
            $combo.SelectedIndex = 0
            $combo.Enabled = $true
        } else {
            $msg = if ($kind -eq '有线') { '（当前未检测到已连通的有线网络）' } else { '（当前未检测到已连接的校园 Wi-Fi）' }
            [void]$combo.Items.Add($msg)
            $combo.SelectedIndex = 0
            $combo.Enabled = $false
        }
        
        $diag = if (Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue) {
            Test-SharingDiagnostics -Kind $kind
        } else {
            [pscustomobject]@{
                Available = $true
                StatusType = 'Success'
                Summary = '✔ 网络检测完成'
                Details = '网络连接状态正常'
            }
        }

        $diagTitle.Text = $diag.Summary
        $diagDetail.Text = $diag.Details
        if ($diag.StatusType -eq 'Success') {
            $diagPanel.BackColor = [Drawing.Color]::FromArgb(238, 250, 242)
            $diagPanel.ForeColor = [Drawing.Color]::FromArgb(22, 101, 52)
            $diagTitle.ForeColor = [Drawing.Color]::FromArgb(22, 101, 52)
            $diagDetail.ForeColor = [Drawing.Color]::FromArgb(21, 128, 61)
        } elseif ($diag.StatusType -eq 'Warning') {
            $diagPanel.BackColor = [Drawing.Color]::FromArgb(254, 252, 232)
            $diagPanel.ForeColor = [Drawing.Color]::FromArgb(133, 77, 14)
            $diagTitle.ForeColor = [Drawing.Color]::FromArgb(133, 77, 14)
            $diagDetail.ForeColor = [Drawing.Color]::FromArgb(161, 98, 7)
        } else {
            $diagPanel.BackColor = [Drawing.Color]::FromArgb(254, 242, 242)
            $diagPanel.ForeColor = [Drawing.Color]::FromArgb(153, 27, 27)
            $diagTitle.ForeColor = [Drawing.Color]::FromArgb(153, 27, 27)
            $diagDetail.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
        }
    }

    $btnRefresh.Add_Click({ Update-View })
    $rbWired.Add_CheckedChanged({ if ($rbWired.Checked) { Update-View } })
    $rbWifi.Add_CheckedChanged({ if ($rbWifi.Checked) { Update-View } })

    # 初始选中
    $hasWired = @(Filter-Nets $nets '有线').Count -gt 0
    $hasWifi = @(Filter-Nets $nets 'Wi-Fi').Count -gt 0
    if ($PreferredKind -eq '有线') {
        $rbWired.Checked = $true
    } elseif ($PreferredKind -eq 'Wi-Fi') {
        $rbWifi.Checked = $true
    } elseif ($hasWired) {
        $rbWired.Checked = $true
    } elseif ($hasWifi) {
        $rbWifi.Checked = $true
    } else {
        $rbWired.Checked = $true
    }
    Update-View

    $ok.Add_Click({
        if (!$u.Text.Trim() -or !$pw.Text.Length) {
            Alert '请填写账号和密码。'
            return
        }
        $kind = if ($rbWired.Checked) { '有线' } else { 'Wi-Fi' }
        if ($script:currentFilteredNets.Count -eq 0 -or $combo.SelectedIndex -lt 0) {
            $hint = if ($kind -eq '有线') {
                '当前未找到可用的网线连接。请先插好校园网线并确认网络已连接后再保存。'
            } else {
                '当前未找到可用的校园 Wi-Fi。请先在 Windows 右下角网络列表连接校园 Wi-Fi 后再保存。'
            }
            Alert $hint
            return
        }
        if (Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue) {
            $diag = Test-SharingDiagnostics -Kind $kind
            if (-not $diag.Available) {
                if ($diag.StatusType -eq 'Error' -and $diag.Summary -match '无线网卡') {
                    Alert ('无法开启共享：' + $diag.Summary + [Environment]::NewLine + [Environment]::NewLine + $diag.Details)
                    return
                }
            }
        }
        $f.DialogResult = 'OK'
    })

    $f.AcceptButton=$ok;$f.CancelButton=$cancel
    try {
        if ($f.ShowDialog() -eq 'OK') {
            $selectedNet = $script:currentFilteredNets[$combo.SelectedIndex]
            return @{ User = $u.Text; Pass = $pw.Text; Net = $selectedNet }
        }
    } finally {
        $pw.Clear()
        $f.Dispose()
    }
}
$operationLock=$null
try{
    if(!([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $prefArg = if ($PreferredKind) { ' -PreferredKind "' + $PreferredKind + '"' } else { '' }
        $ps=(Join-Path $PSHOME 'powershell.exe');$e=Start-Process $ps -Verb RunAs -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$PSCommandPath+'" -Mode '+$Mode+$prefArg) -PassThru -WindowStyle Hidden;$e.WaitForExit();exit $e.ExitCode
    }
    $operationLock=Enter-AssistantOperation
    if(!(Test-Path -LiteralPath $PSCommandPath)){throw '程序已被卸载，请重新安装。'}
    $uninstallFlag=Join-Path $root 'uninstall-in-progress.flag'
    if($Mode -eq 'Uninstall'){
        if(!(Test-Path $journal) -and ((Test-Path (Join-Path $root 'settings.json')) -or @(Get-OwnTasks).Count)){
            throw '恢复备份缺失。请保留安装目录，修复备份后再卸载。'
        }
        [IO.File]::WriteAllText($uninstallFlag,'uninstall')
        if(Test-Path $journal){
            if(Test-Path (Join-Path $root 'settings.json')){Stop-AssistantLifecycle $root -Uninstall}else{Restore}
        }
        exit 0
    }
    if(Test-Path $uninstallFlag){throw '卸载恢复尚未完成，请再次执行卸载。'}
    $shells=@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$([Diagnostics.Process]::GetCurrentProcess().SessionId)")
    if(!@($shells|Where-Object {(Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid}).Count){throw '请使用自己的 Windows 管理员账户登录桌面后设置，不要输入另一个 Windows 用户的凭据代装。'}
    # 自动检索并清理旧版残留任务与冲突标记，确保新版能顺利配置运行
    if((Test-Path (Join-Path $env:ProgramData 'CampusNetwork-Autostart\installation-marker.json')) -or (Get-ScheduledTask -TaskName 'CampusNetwork-AutoConnect' -ea SilentlyContinue)){
        $cleaner = Join-Path $root 'Clean-Conflicts.ps1'
        if (Test-Path -LiteralPath $cleaner) {
            . $cleaner -Silent
        }
    }
    $nets=@(Get-CampusCandidates)
    if(!$nets.Count){throw '未找到可用上网连接。请先连接校园 Wi-Fi 或插好网线，等待获得地址后重新填写账号。'}
    $cfgPath=Join-Path $root 'settings.json'
    if($Mode -eq 'ResetPassword'){
       if(!(Test-Path $cfgPath)){throw '请先完成首次设置。'}
       $cfg=Read-Json $cfgPath
       $entry=CredForm $nets $true $PreferredKind;if(!$entry){exit 0}
       $net=@(Get-CampusCandidates|Where-Object {$_.Id -eq $entry.Net.Id -and $_.Gateway -eq $entry.Net.Gateway -and $_.Ip -eq $entry.Net.Ip -and $_.NetworkName -ceq $entry.Net.NetworkName})|Select-Object -First 1
       if(!$net){throw '网络连接刚刚改变，请重新打开设置。'}
       if($cfg.CampusAdapterGuid -ne $net.Id -or $cfg.ExpectedGateway -ne $net.Gateway){
           $oldAd = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {([guid]$_.InterfaceGuid).ToString() -eq $cfg.CampusAdapterGuid} | Select-Object -First 1
           if($oldAd){
               Set-NetIPInterface -InterfaceIndex $oldAd.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled -PolicyStore ActiveStore -ErrorAction SilentlyContinue
           }
           $ledger = Join-Path $root 'managed-routes.json'
           if (Test-Path -LiteralPath $ledger) {
               try {
                   $oldRoutes = @(Read-Json $ledger)
                   foreach ($r in $oldRoutes) {
                       Get-NetRoute -DestinationPrefix $r.Prefix -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Where-Object NextHop -eq $r.Gateway | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                   }
                   Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
               } catch { }
           }
           $b = Snapshot $net
           Save $journal $b
           $cfg.CampusAdapterGuid = $net.Id
           $cfg.ConnectionKind = $net.ConnectionKind
           $cfg.ExpectedNetworkName = if ($net.ConnectionKind -eq '有线') { '' } else { $net.NetworkName }
           $cfg.ExpectedGateway = $net.Gateway
           $cfg.SubnetReference = $net.Ip
           $cfg.SubnetBits = $net.Bits
           Save $cfgPath $cfg
       }
       Save ($account+'.pending') (New-AccountConfig $entry.User $entry.Pass $cfg.ManagementPort)
       Save $account (New-AccountConfig $entry.User $entry.Pass $cfg.ManagementPort)
       Alert ('设置已更新。当前接入方式为【' + $net.ConnectionKind + '连接】。请先停止助手，再点击启动共享，让新设置生效。');exit 0
    }
    if(Test-Path $journal){
        if (!(Test-Path (Join-Path $root 'settings.json'))) {
            Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
        } else {
            throw '本机已有设置。修改密码请用「切换网络与账号」；重新配置请先在面板点击「卸载恢复」。'
        }
    }
    if(@(Get-OwnTasks).Count){throw '发现同名计划任务，已保留原样。'}
    if(!(Get-NetAdapter -Physical | Where-Object {$_.InterfaceType -eq 71})){throw '未检测到电脑安装有无线网卡（Wi-Fi）。由于将网络共享给手机必须依赖电脑发射 Wi-Fi 热点，请为电脑插入无线网卡后再开启共享。'}
    if(!(Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe'))){throw '缺少系统 curl.exe，请使用较新的 Windows 10 或 Windows 11。'}
    $entry=CredForm $nets $false $PreferredKind;if(!$entry){exit 0}
    $net=@(Get-CampusCandidates|Where-Object {$_.Id -eq $entry.Net.Id -and $_.Gateway -eq $entry.Net.Gateway -and $_.Ip -eq $entry.Net.Ip -and $_.NetworkName -ceq $entry.Net.NetworkName})|Select-Object -First 1
    if(!$net){throw '网络连接刚刚改变，请重新打开首次设置。'}
    $b=Snapshot $net
    $used=@(Get-NetTCPConnection -State Listen|Select-Object -Expand LocalPort)
    $port=18888..18918|Where-Object {$_ -notin $used}|Select-Object -First 1
    if(!$port){throw '本机管理端口已占用，请稍后再试。'}
    $expectedNetName = if ($net.ConnectionKind -eq '有线') { '' } else { $net.NetworkName }
    $cfg=[ordered]@{TaskName=$task;UserSid=$sid;ClientPath=$exe;ExecutableSha256='714A8CC53C5E50A218932D0BDDDF0E68570C5D9832B9B7830EAC27DD85517DD7';CampusAdapterGuid=$net.Id;ConnectionKind=$net.ConnectionKind;ExpectedNetworkName=$expectedNetName;ExpectedGateway=$net.Gateway;SubnetReference=$net.Ip;SubnetBits=$net.Bits;ManagementPort=$port;CampusMetric=10;AuthTargets=@('183.61.185.93','125.88.255.53','202.69.4.32','220.181.104.183','125.88.59.131','61.140.12.23','14.146.227.141','121.8.177.212','8.8.8.8');HttpsProbeUrls=@('https://www.baidu.com/','https://www.qq.com/')}
    if((Get-FileHash -LiteralPath $exe).Hash -ne $cfg.ExecutableSha256){throw '认证程序校验失败。'}
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach($s in @('S-1-5-32-544','S-1-5-18',$sid)){
       $rights=if($s -eq $sid){'ReadAndExecute'}else{'FullControl'}
       $rule=New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$s),$rights,'ContainerInherit,ObjectInherit','None','Allow')
       $acl.AddAccessRule($rule)
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    Set-Acl -LiteralPath $root -AclObject $acl
    Save $journal $b
    try{
       $flag=Join-Path $root 'watchdog-paused.flag';if(Test-Path $flag){Remove-Item -LiteralPath $flag -Force}
       Save $account (New-AccountConfig $entry.User $entry.Pass $port)
       Save $cfgPath $cfg
       Save (Join-Path $root 'last-status.json') @{Result='等待首次登录启动';Stage='configured'}
       Set-AssistantState $root 'configured' '设置已保存，可退出官方客户端后点击启动共享。'
       Register-Work $task 'startup' 'PT15S' $false
       Register-Work ($task+'-Watchdog') 'watch' 'PT90S' $true
       if($b.ServiceAuto){Set-Service ESurfingSvr -StartupType Manual}
       if($b.RunExists){Remove-ItemProperty -LiteralPath $runPath -Name $runName}
    }catch{
        $reason=$_.Exception.Message;Restore
        foreach($path in @($account,$cfgPath,$journal)){if(Test-Path $path){Remove-Item -LiteralPath $path -Force}}
        throw $reason
    }
    Alert '首次设置已完成。请先退出官方天翼客户端，再点击「启动共享」。热点开启后，让手机关闭移动数据并连接热点测试网页。'
}catch{Alert $_.Exception.Message;exit 1}
finally {
    if($operationLock){$operationLock.ReleaseMutex();$operationLock.Dispose()}
}

