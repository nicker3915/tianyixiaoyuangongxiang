param([switch]$FirstRun,[string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root=$PSScriptRoot;$powerShell=Join-Path $PSHOME 'powershell.exe'
$script:child=$null;$script:operation='';$script:operationStarted=$null
$script:closeAfterStop=$false;$script:allowClose=$false;$script:lastState='unconfigured';$script:operationNotice=''
$panelLock=$null
if(!$PreviewPath){
    $created=$false;$panelLock=New-Object Threading.Mutex($true,'Local\GDPortalShare-Panel',[ref]$created)
    if(!$created){[void][Windows.Forms.MessageBox]::Show('助手已经打开。请在任务栏或右下角托盘中打开面板。','校园网共享助手');$panelLock.Dispose();exit 0}
}
$form=New-Object Windows.Forms.Form
$form.Text='校园网共享助手 1.4.0';$form.ClientSize=New-Object Drawing.Size(650,550)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.AutoScaleMode='Dpi'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$form.BackColor=[Drawing.Color]::FromArgb(245,247,251);$form.Icon=[Drawing.SystemIcons]::Application
function Label($text,$x,$y,$w,$h){$c=New-Object Windows.Forms.Label;$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$form.Controls.Add($c);return $c}
function Button($text,$x,$y,$w,$h,$action){
    $c=New-Object Windows.Forms.Button;$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$c.FlatStyle='Flat'
    $c.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(210,217,229);$c.BackColor=[Drawing.Color]::White;$c.Cursor='Hand';$c.Add_Click($action);$form.Controls.Add($c);return $c
}
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
function Start-Sharing{if(!(Test-Path (Join-Path $root 'settings.json'))){$accountButton.PerformClick();return};Launch-Action 'Campus-Recovery.ps1' '-Mode Resume' '正在启动共享'}
function Stop-Sharing{if(Test-Path (Join-Path $root 'settings.json')){Launch-Action 'Campus-Recovery.ps1' '-Mode Stop' '正在停止并恢复官方'}}
$title=Label '校园网，分享给手机' 28 24 520 36;$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',19,[Drawing.FontStyle]::Bold)
$version=Label '1.4.0' 556 34 65 24;$version.TextAlign='MiddleRight';$version.ForeColor=[Drawing.Color]::DimGray
$subtitle=Label '一键开始共享，也能随时停止并切回官方客户端。' 30 70 590 30;$subtitle.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$status=Label '尚未设置校园账号' 30 119 590 35;$status.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold)
$network=Label '先连接校园 Wi-Fi 或网线，再完成账号设置。' 30 159 590 28;$network.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$detail=Label '填写自己的校园账号后，即可启动共享。' 30 196 590 36

$netModule = Join-Path $root 'Network.ps1'
if (Test-Path -LiteralPath $netModule) { . $netModule }

$modeLabel=Label '接入方式：' 30 240 76 24
$modeLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
$modeLabel.ForeColor=[Drawing.Color]::FromArgb(85,98,118)

$rbWired=New-Object Windows.Forms.RadioButton
$rbWired.Text='网线连接 (以太网)'
$rbWired.SetBounds(110,238,135,26)
$rbWired.Cursor='Hand'
$rbWired.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
$form.Controls.Add($rbWired)

$rbWifi=New-Object Windows.Forms.RadioButton
$rbWifi.Text='无线连接 (Wi-Fi)'
$rbWifi.SetBounds(250,238,135,26)
$rbWifi.Cursor='Hand'
$rbWifi.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5)
$form.Controls.Add($rbWifi)

$modeStatus=Label '' 390 241 235 22
$modeStatus.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$modeStatus.ForeColor=[Drawing.Color]::FromArgb(40,120,50)

$script:syncingMode=$false
$script:selectedKind='有线'
$cfg=Read-State 'settings.json'
if($cfg -and $cfg.ConnectionKind){
    $script:selectedKind=$cfg.ConnectionKind
}else{
    $activeEth=@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {$_.InterfaceType -eq 6 -and $_.Status -eq 'Up'})
    if($activeEth.Count -gt 0){$script:selectedKind='有线'}else{$script:selectedKind='Wi-Fi'}
}
$script:syncingMode=$true
if($script:selectedKind -eq '有线'){$rbWired.Checked=$true}else{$rbWifi.Checked=$true}
$script:syncingMode=$false

function Update-ModeDiagnostics {
    $diag = if (Get-Command Test-SharingDiagnostics -ErrorAction SilentlyContinue) {
        Test-SharingDiagnostics -Kind $script:selectedKind
    } else {
        [pscustomobject]@{ Available = $true; StatusType = 'Success'; Summary = '网络检测就绪' }
    }
    if ($diag.StatusType -eq 'Success') {
        $modeStatus.Text = if ($script:selectedKind -eq '有线') { '✔ 网线已连通 · 热点就绪' } else { '✔ Wi-Fi 已连通 · 热点就绪' }
        $modeStatus.ForeColor = [Drawing.Color]::FromArgb(40, 120, 50)
    } elseif ($diag.StatusType -eq 'Warning') {
        $modeStatus.Text = $diag.Summary
        $modeStatus.ForeColor = [Drawing.Color]::FromArgb(180, 110, 20)
    } else {
        $modeStatus.Text = $diag.Summary
        $modeStatus.ForeColor = [Drawing.Color]::FromArgb(180, 50, 40)
    }
}
Update-ModeDiagnostics

$rbWired.Add_Click({
    if($script:syncingMode -or !$rbWired.Checked){return}
    $script:selectedKind='有线'
    if(Test-Path (Join-Path $root 'settings.json')){
        if(Get-Command Switch-CurrentNetworkMode -ErrorAction SilentlyContinue){
            $res=Switch-CurrentNetworkMode $root '有线'
            if($res.Success){
                $modeStatus.Text='✔ 已切换为网线接入'
                $modeStatus.ForeColor=[Drawing.Color]::FromArgb(40,120,50)
                Refresh-Panel
            }else{
                $modeStatus.Text=$res.Message
                $modeStatus.ForeColor=[Drawing.Color]::FromArgb(180,50,40)
                $script:syncingMode=$true;$rbWifi.Checked=$true;$script:selectedKind='Wi-Fi';$script:syncingMode=$false
            }
        }
    }else{
        Update-ModeDiagnostics
    }
})
$rbWifi.Add_Click({
    if($script:syncingMode -or !$rbWifi.Checked){return}
    $script:selectedKind='Wi-Fi'
    if(Test-Path (Join-Path $root 'settings.json')){
        if(Get-Command Switch-CurrentNetworkMode -ErrorAction SilentlyContinue){
            $res=Switch-CurrentNetworkMode $root 'Wi-Fi'
            if($res.Success){
                $modeStatus.Text='✔ 已切换为 Wi-Fi 接入'
                $modeStatus.ForeColor=[Drawing.Color]::FromArgb(40,120,50)
                Refresh-Panel
            }else{
                $modeStatus.Text=$res.Message
                $modeStatus.ForeColor=[Drawing.Color]::FromArgb(180,50,40)
                $script:syncingMode=$true;$rbWired.Checked=$true;$script:selectedKind='有线';$script:syncingMode=$false
            }
        }
    }else{
        Update-ModeDiagnostics
    }
})
$startButton=Button '启动共享' 30 282 284 50 {Start-Sharing};$startButton.BackColor=[Drawing.Color]::FromArgb(30,95,210);$startButton.ForeColor=[Drawing.Color]::White
$stopButton=Button '停止并切回官方' 330 282 290 50 {Stop-Sharing};$stopButton.ForeColor=[Drawing.Color]::FromArgb(160,55,38)

function Clean-LegacyConflicts {
    Launch-Action 'Clean-Conflicts.ps1' '-Silent' '正在检索并清理冲突与残留程序'
}

$accountButton=Button '填写校园账号' 30 349 184 40 {
    $mode=if(Test-Path (Join-Path $root 'settings.json')){'ResetPassword'}else{'Configure'}
    Launch-Action 'Manage.ps1' ('-Mode '+$mode+' -PreferredKind '+$script:selectedKind) '设置校园账号'
}
$hotspotButton=Button '查看热点名称和密码' 226 349 194 40 {Start-Process 'ms-settings:network-mobilehotspot'}
$cleanButton=Button '清理冲突与残留' 430 349 190 40 { Clean-LegacyConflicts }
$cleanButton.ForeColor=[Drawing.Color]::FromArgb(180,60,30)

$notice=Label '' 30 405 590 48;$notice.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$notice.ForeColor=[Drawing.Color]::FromArgb(85,98,118)
$folderButton=Button '安装文件夹' 30 475 110 34 {Start-Process -FilePath $root}
$helpButton=Button '使用说明' 150 475 110 34 {Start-Process -FilePath (Join-Path $root '使用说明.txt')}
$hideButton=Button '收起到托盘' 270 475 110 34 {$form.Hide()}
$uninstallButton=Button '卸载并恢复' 390 475 115 34 {if(!$script:child){try{Start-Process -FilePath (Join-Path $root 'unins000.exe') -WorkingDirectory $env:TEMP}catch{[void][Windows.Forms.MessageBox]::Show('请在 Windows“已安装的应用”中卸载校园网共享助手。','卸载')}}}
$exitButton=Button '退出…' 515 475 105 34 {$form.Close()}
$tray=New-Object Windows.Forms.NotifyIcon;$tray.Icon=$form.Icon;$tray.Text='校园网共享助手';$tray.Visible=(!$PreviewPath)
$menu=New-Object Windows.Forms.ContextMenuStrip
$showItem=$menu.Items.Add('打开面板');$showItem.Add_Click({Show-Panel})
$startItem=$menu.Items.Add('启动共享');$startItem.Add_Click({Start-Sharing})
$stopItem=$menu.Items.Add('停止并切回官方');$stopItem.Add_Click({Stop-Sharing})
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem=$menu.Items.Add('退出…');$exitItem.Add_Click({Show-Panel;$form.Close()})
$tray.ContextMenuStrip=$menu;$tray.Add_DoubleClick({Show-Panel})
function Refresh-Panel{
    if($script:child -and $script:child.HasExited){
        $code=$script:child.ExitCode;$script:child.Dispose();$script:child=$null
        if($script:operation -eq '正在检索并清理冲突与残留程序'){
            $cResult=Read-State 'clean-conflicts-result.json'
            $script:operationNotice=if($cResult -and $cResult.Message){[string]$cResult.Message}else{'已完成冲突与残留程序的检索清理。'}
        }elseif($script:operation -ne '设置校园账号'){
            $r=Read-State 'recovery-last-result.json';$script:operationNotice=if($code -eq 0){'操作已完成。'}else{'操作未完成，请检查管理员授权并重试。'}
            if($r -and $r.Time -and [DateTimeOffset]::Parse($r.Time) -ge $script:operationStarted.AddSeconds(-2)){$script:operationNotice=[string]$r.Message}
            if($script:closeAfterStop){$script:closeAfterStop=$false;$s=Read-State 'assistant-state.json';if($code -eq 0 -and $s.State -eq 'stopped'){$script:allowClose=$true;$form.Close();return};Show-Panel}
        }
    }
    $configured=Test-Path (Join-Path $root 'settings.json');$busy=($null -ne $script:child)
    foreach($b in @($startButton,$stopButton,$accountButton,$cleanButton,$uninstallButton,$startItem,$stopItem)){$b.Enabled=(!$busy)}
    $stopButton.Enabled=($configured -and !$busy);$stopItem.Enabled=$stopButton.Enabled
    $accountButton.Text=if($configured){'切换网络与账号'}else{'填写校园账号'}
    $notice.Text=if($script:operationNotice){$script:operationNotice}else{'停止会关闭本助手的热点与认证，并保留账号。手机测试请关闭移动数据。'}
    $status.ForeColor=[Drawing.Color]::FromArgb(33,48,70)
    $rbWired.Enabled=(!$busy);$rbWifi.Enabled=(!$busy)
    if($busy){$status.Text=$script:operation;$detail.Text='请完成可能出现的管理员授权。操作结果会显示在这里。';return}
    if(!$configured){
        $script:lastState='unconfigured';$status.Text='尚未设置校园账号';$network.Text='先在上方选择接入方式（网线或 Wi-Fi），再填写账号。';$detail.Text='选择接入方式并填写账号后，即可启动共享给手机。'
        Update-ModeDiagnostics
        return
    }
    $cfg=Read-State 'settings.json'
    if($null -ne $cfg){
        $script:syncingMode=$true
        if($cfg.ConnectionKind -eq '有线'){
            if(!$rbWired.Checked){$rbWired.Checked=$true}
        }else{
            if(!$rbWifi.Checked){$rbWifi.Checked=$true}
        }
        $script:syncingMode=$false
    }
    $network.Text=if($cfg.ExpectedNetworkName){'已绑定：'+$cfg.ExpectedNetworkName+'  ·  '+$cfg.ConnectionKind}elseif($cfg.ConnectionKind -eq '有线'){'已绑定：校园网线连接（以太网） · 热点由无线网卡发射'}else{'已绑定：校园网络连接'}
    $s=Read-State 'assistant-state.json';$script:lastState=[string]$s.State
    if(Test-Path (Join-Path $root 'uninstall-in-progress.flag')){
        $status.Text='卸载恢复尚未完成';$detail.Text='程序和恢复备份已保留，请再次点击“卸载并恢复”。'
        foreach($b in @($startButton,$stopButton,$accountButton,$startItem,$stopItem)){$b.Enabled=$false};return
    }
    if($s.State -eq 'stopped'){
        $status.Text='助手已停止 · 可使用官方客户端';$detail.Text='热点、助手认证与自动运行已停止。下次点击“启动共享”即可重新使用。';$stopButton.Enabled=$false;$stopItem.Enabled=$false
        # A refused Resume leaves the stopped state intact. Show its newer result
        # prominently, including after reopening the panel, without claiming it ran.
        $attempt=Read-State 'recovery-last-result.json'
        $attemptAt=[DateTimeOffset]::MinValue;$stateAt=[DateTimeOffset]::MinValue
        if($attempt -and $attempt.Mode -eq 'Resume' -and $attempt.Success -eq $false -and
            [DateTimeOffset]::TryParse([string]$attempt.Time,[ref]$attemptAt) -and
            [DateTimeOffset]::TryParse([string]$s.UpdatedAt,[ref]$stateAt) -and $attemptAt -ge $stateAt){
            $status.Text='共享未启动';$status.ForeColor=[Drawing.Color]::FromArgb(160,55,38)
            $detail.Text=[string]$attempt.Message;$notice.Text='助手仍处于停止状态。按上方提示处理后，再点击“启动共享”。'
        }
        $tray.Text='校园网共享助手 · '+$status.Text
        return
    }
    if($s.State -eq 'start-requested'){$status.Text='正在请求启动共享';$detail.Text='正在启动认证和热点，需要中止时可点击“停止并切回官方”。';return}
    if($s.State -eq 'stopping'){$status.Text='正在停止并恢复官方';$detail.Text='正在关闭共享并恢复网络设置，请稍候。';return}
    if($s.State -eq 'needs-attention'){$status.Text='操作需要处理';$detail.Text=if($s.Message){[string]$s.Message}else{'请查看操作提示，重试“停止并切回官方”或“启动共享”。'};return}
    if(Test-Path (Join-Path $root 'watchdog-paused.flag')){$status.Text='自动运行已暂停';$detail.Text='点击“停止并切回官方”可完整停止；点击“启动共享”可重新启用。';return}
    if(Test-Path (Join-Path $root 'Client\ESurfingClient.json.pending')){$status.Text='新账号已保存';$detail.Text='请先停止助手，再点击“启动共享”，让新账号生效。';return}
    $last=Read-State 'last-status.json'
    $status.Text=switch($last.Result){'ready' {'共享启动完成'} 'existing-hotspot-check-upstream' {'请核对热点共享来源'} 'needs-attention' {'启动需要处理'} 'not-at-campus' {'等待已绑定的校园网络'} 'pending' {'正在启动共享'} 'stopped' {'共享已停止'} default {'账号已保存，可以启动共享'}}
    $detail.Text=switch($last.Stage){
        'waiting-for-campus' {'请连接已绑定的校园 Wi-Fi 或网线。'}
        'waiting-for-authentication' {'正在认证校园账号，请稍候。需要中止时可点击“停止并切回官方”。'}
        'verifying-campus-internet' {'正在验证校园连接能否访问网页。'}
        'starting-hotspot' {'正在开启 Windows 移动热点。'}
        'failed' {'请先退出官方客户端，再启动共享；若仍失败，请核对账号和校园连接。'}
        default {'在热点设置中查看名称和密码，让手机连接后访问新网页。'}
    }
    if($last.Result -eq 'ready'){$status.ForeColor=[Drawing.Color]::FromArgb(22,118,81)}
    if($last.Result -eq 'existing-hotspot-check-upstream'){$detail.Text='Windows 已有热点，请在热点设置中确认共享来源为已绑定的校园连接。'}
    if($last.CompletedAt){$detail.Text+=[Environment]::NewLine+'最近完成检查：'+([DateTimeOffset]::Parse($last.CompletedAt).ToLocalTime().ToString('MM-dd HH:mm'))}
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
$form.Add_Shown({$timer.Start();if($FirstRun -and !(Test-Path (Join-Path $root 'settings.json'))){$accountButton.PerformClick()}})
try{[void]$form.ShowDialog()}finally{$form.Dispose();if($panelLock){$panelLock.ReleaseMutex();$panelLock.Dispose()}}
