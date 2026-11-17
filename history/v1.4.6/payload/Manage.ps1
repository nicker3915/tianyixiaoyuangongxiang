param([ValidateSet('Configure','Uninstall','ResetPassword')][string]$Mode='Configure', [ValidateSet('','有线','Wi-Fi')][string]$PreferredKind='')
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
function Test-LegacyMetricManaged {
    $path=Join-Path $root 'settings.json'
    if(!(Test-Path -LiteralPath $path)){return $false}
    try{$cfg=Read-Json $path}catch{return $false}
    $names=@($cfg.PSObject.Properties.Name)
    if($names -contains 'MetricPolicy'){return ([string]$cfg.MetricPolicy -eq 'legacy-force-10')}
    return ($names -contains 'CampusMetric')
}
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
        if((Test-LegacyMetricManaged) -and $m -and [string]$m.AutomaticMetric -eq 'Disabled' -and $m.InterfaceMetric -eq 10){
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
function CredForm($nets,$reset,[string]$PreferredKind='') {
    $choices=@($nets | Where-Object {!$PreferredKind -or $_.ConnectionKind -eq $PreferredKind})
    $f=New-Object Windows.Forms.Form
    $f.Text='校园网共享助手 · '+$(if($reset){'修改已绑定账号'}else{'确认连接与账号'})
    $f.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $f.ClientSize=New-Object Drawing.Size(560,410)
    $f.StartPosition='CenterScreen';$f.FormBorderStyle='FixedDialog';$f.MaximizeBox=$false;$f.AutoScaleMode='Dpi'
    function Field($c,$x,$y,$w,$h){$c.SetBounds($x,$y,$w,$h);[void]$f.Controls.Add($c)}
    function Caption($s,$x,$y,$w,$h){$l=New-Object Windows.Forms.Label;$l.Text=$s;Field $l $x $y $w $h;return $l}
    $kindText=if($PreferredKind){$PreferredKind}else{'所选校园连接'}
    $null=Caption ('接入方式：'+$kindText+' · 请选择实际校园连接') 20 16 520 27
    $null=Caption '确认后保存账号；开始认证与共享还需点击主窗口的“启动共享”。' 20 46 520 42
    $null=Caption '上网连接' 20 99 90 24
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';Field $combo 110 94 430 30
    foreach($net in $choices){[void]$combo.Items.Add($net.Label)}
    $diagnostic=Caption '' 20 135 520 62
    $diagnostic.ForeColor=[Drawing.Color]::FromArgb(133,77,14)
    function Update-CredDiagnostic {
        if($combo.SelectedIndex -lt 0){$diagnostic.Text='没有符合所选接入方式的连接。请取消后重新检测。';return}
        $net=$choices[$combo.SelectedIndex]
        if(Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue){
            $d=Test-SharingDiagnostics -Kind $net.ConnectionKind -AdapterId $net.Id
            $diagnostic.Text=$d.Summary+[Environment]::NewLine+$d.Details
            $diagnostic.ForeColor=if($d.StatusType -eq 'Error'){[Drawing.Color]::FromArgb(160,55,38)}else{[Drawing.Color]::FromArgb(85,98,118)}
        }else{$diagnostic.Text='热点能力尚未检测，请以实际认证与手机联网为准。'}
    }
    $combo.Add_SelectedIndexChanged({Update-CredDiagnostic})
    if($choices.Count){$combo.SelectedIndex=0}else{Update-CredDiagnostic}
    $null=Caption '校园账号' 20 213 90 24
    $u=New-Object Windows.Forms.TextBox;Field $u 110 208 430 30
    $null=Caption '校园密码' 20 257 90 24
    $pw=New-Object Windows.Forms.TextBox;$pw.UseSystemPasswordChar=$true;Field $pw 110 252 430 30
    $showPassword=New-Object Windows.Forms.CheckBox;$showPassword.Text='显示密码';Field $showPassword 110 287 180 26
    $showPassword.Add_CheckedChanged({$pw.UseSystemPasswordChar=-not $showPassword.Checked})
    $null=Caption '凭据保存在本机受限目录。取消不会写入账号、网络绑定或恢复备份。' 20 321 520 34
    $ok=New-Object Windows.Forms.Button;$ok.Text='确认';Field $ok 332 365 98 34
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.DialogResult='Cancel';Field $cancel 442 365 98 34
    $ok.Add_Click({
        if(!$u.Text.Trim() -or !$pw.Text.Length){Alert '请填写账号和密码。';return}
        if($combo.SelectedIndex -lt 0){Alert '没有符合所选接入方式的校园连接，请取消后重新检测。';return}
        $net=$choices[$combo.SelectedIndex]
        if(Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue){
            $d=Test-SharingDiagnostics -Kind $net.ConnectionKind -AdapterId $net.Id
            if(!$d.Available){Alert ($d.Summary+[Environment]::NewLine+$d.Details);return}
        }
        $f.DialogResult='OK'
    })
    $f.AcceptButton=$ok;$f.CancelButton=$cancel
    try{if($f.ShowDialog() -eq 'OK'){return @{User=$u.Text;Pass=$pw.Text;Net=$choices[$combo.SelectedIndex]}}}finally{$pw.Clear();$f.Dispose()}
}
$operationLock=$null
try{
    if(!([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $prefArg=if($PreferredKind){' -PreferredKind "'+$PreferredKind+'"'}else{''}
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
    if((Test-Path (Join-Path $env:ProgramData 'CampusNetwork-Autostart\installation-marker.json')) -or (Get-ScheduledTask -TaskName 'CampusNetwork-AutoConnect' -ea SilentlyContinue)){throw '检测到旧版校园网自动任务，已保留现有连接。请勿在旧版电脑上重复设置。'}
    $nets=@(Get-CampusCandidates | Where-Object {!$PreferredKind -or $_.ConnectionKind -eq $PreferredKind})
    if(!$nets.Count){throw '未找到可用上网连接。请先连接校园 Wi-Fi 或插好网线，等待获得地址后重新填写账号。'}
    $cfgPath=Join-Path $root 'settings.json'
    if($Mode -eq 'ResetPassword'){
       if(!(Test-Path $cfgPath)){throw '请先完成首次设置。'}
       $cfg=Read-Json $cfgPath
       if($PreferredKind -and $cfg.ConnectionKind -and $PreferredKind -ne $cfg.ConnectionKind){throw '所选方式与已有绑定不同。请先正常停止并清理卸载，再重新设置；原恢复备份已保留。'}
       $nets=@(Get-ConfiguredCampusCandidates $cfg)
       if(!$nets.Count){throw '请接回首次设置时选择的校园网络；更换网卡、Wi-Fi 或网段请卸载恢复后重新设置。'}
       $entry=CredForm $nets $true $PreferredKind;if(!$entry){exit 0}
       if(!@(Get-ConfiguredCampusCandidates $cfg | Where-Object {$_.Id -eq $entry.Net.Id}).Count){throw '网络连接刚刚改变，请接回已设置的校园网络后重新修改账号。'}
       Save ($account+'.pending') (New-AccountConfig $entry.User $entry.Pass $cfg.ManagementPort)
       Alert '已保存新账号。请先停止助手，再点击启动共享，让新账号生效。';exit 0
    }
    if(Test-Path $journal){throw '本机已有设置或上次设置未完成。修改密码请用「更新账号」；重新配置请先卸载。'}
    if(@(Get-OwnTasks).Count){throw '发现同名计划任务，已保留原样。'}
    if(!(Get-NetAdapter -Physical | Where-Object {$_.InterfaceType -eq 71})){throw '没有检测到无线网卡。Windows 移动热点需要可用的 Wi-Fi 网卡及驱动。'}
    if(!(Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe'))){throw '缺少系统 curl.exe，请使用较新的 Windows 10 或 Windows 11。'}
    $entry=CredForm $nets $false $PreferredKind;if(!$entry){exit 0}
    $net=@(Get-CampusCandidates|Where-Object {$_.Id -eq $entry.Net.Id -and $_.Gateway -eq $entry.Net.Gateway -and $_.Ip -eq $entry.Net.Ip -and $_.NetworkName -ceq $entry.Net.NetworkName})|Select-Object -First 1
    if(!$net){throw '网络连接刚刚改变，请重新打开首次设置。'}
    $b=Snapshot $net
    $used=@(Get-NetTCPConnection -State Listen|Select-Object -Expand LocalPort)
    $port=18888..18918|Where-Object {$_ -notin $used}|Select-Object -First 1
    if(!$port){throw '本机管理端口已占用，请稍后再试。'}
    $cfg=[ordered]@{TaskName=$task;UserSid=$sid;ClientPath=$exe;ExecutableSha256='714A8CC53C5E50A218932D0BDDDF0E68570C5D9832B9B7830EAC27DD85517DD7';CampusAdapterGuid=$net.Id;ConnectionKind=$net.ConnectionKind;ExpectedNetworkName=$net.NetworkName;ExpectedGateway=$net.Gateway;SubnetReference=$net.Ip;SubnetBits=$net.Bits;ManagementPort=$port;MetricPolicy='preserve-system';AuthRoutePolicy='refuse-conflict';AuthTargets=@('183.61.185.93','125.88.255.53','202.69.4.32','220.181.104.183','125.88.59.131','61.140.12.23','14.146.227.141','121.8.177.212','8.8.8.8');HttpsProbeUrls=@('https://www.baidu.com/','https://www.qq.com/')}
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

