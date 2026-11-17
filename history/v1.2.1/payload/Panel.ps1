param([switch]$FirstRun, [string]$PreviewPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root = $PSScriptRoot
$powerShell = Join-Path $PSHOME 'powershell.exe'
$form = New-Object Windows.Forms.Form
$form.Text = '校园网共享助手'
$form.ClientSize = New-Object Drawing.Size(560,450)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.BackColor = [Drawing.Color]::FromArgb(246,248,252)
function Label($text,$x,$y,$width,$height) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $text
    $control.SetBounds($x,$y,$width,$height)
    $form.Controls.Add($control)
    return $control
}
function Button($text,$x,$y,$width,$action) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $text
    $control.SetBounds($x,$y,$width,38)
    $control.FlatStyle = 'Flat'
    $control.BackColor = [Drawing.Color]::White
    $control.Add_Click($action)
    $form.Controls.Add($control)
    return $control
}
$title = Label '校园网，分享给手机' 24 22 510 34
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI',17,[Drawing.FontStyle]::Bold)
$subtitle = Label '填写自己的校园账号，确认后按提示完成设置。' 26 66 510 28
$status = Label '尚未设置' 26 109 508 36
$status.Font = New-Object Drawing.Font('Microsoft YaHei UI',13,[Drawing.FontStyle]::Bold)
$detail = Label '点击下方「填写账号」，选择校园 Wi-Fi 或有线连接。' 26 151 508 82
$script:child = $null
$script:operation = ''
$script:operationStarted = $null
function Launch-Action($scriptName,$arguments,$operationName) {
    if($script:child){return}
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $powerShell
        $info.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $root $scriptName) + '" ' + $arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $script:operationStarted = [DateTimeOffset]::Now
        $script:child = [Diagnostics.Process]::Start($info)
        foreach($button in @($accountButton,$repairButton,$pauseButton,$resumeButton,$uninstallButton)){$button.Enabled=$false}
        $script:operation = $operationName
        $status.Text = $operationName
        $detail.Text = '请完成弹出的设置窗口或 Windows 管理员授权。'
    } catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'操作未完成')
    }
}
$accountButton = Button '填写账号' 26 246 244 {
    $mode = if(Test-Path (Join-Path $root 'settings.json')){'ResetPassword'}else{'Configure'}
    Launch-Action 'Manage.ps1' ('-Mode '+$mode) '设置校园账号'
}
$accountButton.BackColor = [Drawing.Color]::FromArgb(30,95,210)
$accountButton.ForeColor = [Drawing.Color]::White
$hotspotButton = Button '查看热点名称和密码' 286 246 248 {
    Start-Process 'ms-settings:network-mobilehotspot'
}
$repairButton = Button '启动 / 安全修复' 26 296 158 {
    Launch-Action 'Campus-Recovery.ps1' '-Mode Repair' '正在请求启动'
}
$pauseButton = Button '暂停自动运行' 201 296 158 {
    Launch-Action 'Campus-Recovery.ps1' '-Mode Pause' '正在暂停自动运行'
}
$resumeButton = Button '恢复自动运行' 376 296 158 {
    Launch-Action 'Campus-Recovery.ps1' '-Mode Resume' '正在恢复自动运行'
}
$uninstallButton = Button '卸载并恢复官方软件' 26 346 244 {
    try {
        if($script:child){return}
        Start-Process -FilePath (Join-Path $root 'unins000.exe') -WorkingDirectory $env:TEMP
        $form.Close()
    } catch {[void][Windows.Forms.MessageBox]::Show('请到 Windows「已安装的应用」卸载校园网共享助手。','卸载')}
}
$folderButton = Button '安装文件夹' 286 346 120 {Start-Process -FilePath $root}
$helpButton = Button '使用说明' 414 346 120 {Start-Process -FilePath (Join-Path $root '使用说明.txt')}
$foot = Label '首次保存后需手动重启。手机连接热点后，请关闭移动数据测试网页。' 26 403 510 36
$foot.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
function Refresh-Panel {
    if($script:child){
        if(!$script:child.HasExited){return}
        $code = $script:child.ExitCode
        $script:child.Dispose()
        $script:child = $null
        $accountButton.Enabled=$true
        $uninstallButton.Enabled=$true
        if($script:operation -ne '设置校园账号'){
            $message = if($code -eq 0){'请求已完成，请查看下方状态。'}else{'操作未完成，请检查管理员授权或稍后重试。'}
            $resultPath = Join-Path $root 'recovery-last-result.json'
            try {
                $result = Get-Content -Raw -Encoding UTF8 $resultPath | ConvertFrom-Json
                if([DateTimeOffset]::Parse($result.Time) -ge $script:operationStarted){$message=$result.Message}
            } catch {}
            [void][Windows.Forms.MessageBox]::Show($message,'校园网共享助手')
        }
    }
    $configured = Test-Path (Join-Path $root 'settings.json')
    $accountButton.Text = if($configured){'修改校园账号'}else{'填写账号'}
    foreach($button in @($repairButton,$pauseButton,$resumeButton)){$button.Enabled=$configured}
    if(Test-Path (Join-Path $root 'uninstall-in-progress.flag')){
        $status.Text='卸载恢复尚未完成'
        $detail.Text='请再次点击「卸载并恢复官方软件」。程序和备份已保留。'
        foreach($button in @($accountButton,$repairButton,$pauseButton,$resumeButton)){$button.Enabled=$false}
        return
    }
    if(!$configured){
        $status.Text='尚未设置'
        $detail.Text='点击「填写账号」，输入校园账号和密码，再点「确认」。'
        return
    }
    if(Test-Path (Join-Path $root 'watchdog-paused.flag')){
        $status.Text='自动运行已暂停'
        $detail.Text='点击「恢复自动运行」可重新启用。卸载后请重启，再用官方客户端登录。'
        return
    }
    if(Test-Path (Join-Path $root 'Client\ESurfingClient.json.pending')){
        $status.Text='新账号已保存，等待重启'
        $detail.Text='请手动重启电脑，让新账号设置生效。'
        return
    }
    try {
        $last = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'last-status.json') | ConvertFrom-Json
        $status.Text = switch($last.Result){
            'ready' {'最近一次启动完成'}
            'existing-hotspot-check-upstream' {'请核对热点共享来源'}
            'needs-attention' {'启动需要处理'}
            'not-at-campus' {'等待所选校园网络连接'}
            'pending' {'正在启动共享'}
            default {'设置已保存，等待首次重启'}
        }
        $detail.Text = switch($last.Stage){
            'waiting-for-campus' {'请连接已设置的校园 Wi-Fi 或网线，等待分配地址。'}
            'waiting-for-authentication' {'正在认证校园账号，请稍候。'}
            'verifying-campus-internet' {'正在检查校园网访问情况。'}
            'starting-hotspot' {'正在开启 Windows 移动热点。'}
            'failed' {'检查校园账号及连接。Wi-Fi 共享还需要网卡与驱动支持同时接收和发出热点。'}
            default {'打开热点设置查看名称和密码，再用手机连接并打开新网页。'}
        }
        if($last.Result -eq 'existing-hotspot-check-upstream'){$detail.Text='在热点设置中确认共享来源为设置时选择的校园连接，然后用手机测试网页。'}
        if($last.CompletedAt){$detail.Text += [Environment]::NewLine+'上次完成 '+([DateTimeOffset]::Parse($last.CompletedAt).ToLocalTime().ToString('MM-dd HH:mm'))}
    } catch {$status.Text='状态暂时不可用';$detail.Text='稍候将自动刷新。也可点击「启动 / 安全修复」。'}
}
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({Refresh-Panel})
$form.Add_FormClosing({
    param($sender,$event)
    if($script:child -and !$script:child.HasExited){
        $event.Cancel=$true
        [void][Windows.Forms.MessageBox]::Show('请完成或取消正在进行的设置，再关闭助手。','操作进行中')
    }
})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose()})
if($PreviewPath){
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location = New-Object Drawing.Point(-30000,-30000)
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save($PreviewPath)
    $bitmap.Dispose()
    $form.Dispose()
    exit
}
Refresh-Panel
$form.Add_Shown({
    $timer.Start()
    if($FirstRun -and !(Test-Path (Join-Path $root 'settings.json'))){$accountButton.PerformClick()}
})
[void]$form.ShowDialog()
$form.Dispose()

