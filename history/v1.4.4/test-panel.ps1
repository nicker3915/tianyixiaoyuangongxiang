$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run this test with Windows PowerShell -STA'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:fixtureDir=Join-Path $PSScriptRoot ('validation\panel-behavior-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:fixtureDir)
$script:checks=0
function Assert($condition,[string]$message){if(!$condition){throw $message};$script:checks++}
function Fixture-Json([string]$name,$data){
    [IO.File]::WriteAllText((Join-Path $script:fixtureDir $name),($data|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
}
function Read-Calls{
    $p=Join-Path $script:fixtureDir 'calls.txt'
    if(Test-Path -LiteralPath $p){return @(Get-Content -LiteralPath $p)}
    return @()
}
function Set-Outcome([bool]$success,[int]$delay=650){Fixture-Json 'outcome.json' @{Success=$success;Delay=$delay}}
function Wait-Action{
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while($script:child -and !$script:child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30;[Windows.Forms.Application]::DoEvents()}
    if($script:child -and !$script:child.HasExited){throw 'Fixture operation timed out'}
    Refresh-Panel
    [Windows.Forms.Application]::DoEvents()
}
Fixture-Json 'settings.json' @{ExpectedNetworkName='TEST-CAMPUS';ConnectionKind='Wi-Fi';CampusAdapterGuid='wifi-test';ManagementPort=18899}
Fixture-Json 'original-startup.json' @{Adapter='wifi-test';Baseline='never-overwrite'}
Fixture-Json 'assistant-state.json' @{State='running'}
Fixture-Json 'last-status.json' @{Result='ready';Stage='finished';CompletedAt=[DateTimeOffset]::Now.ToString('o')}
$fakeRecovery=@'
param([string]$Mode)
$ErrorActionPreference='Stop'
$outcome=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'outcome.json') -Raw|ConvertFrom-Json
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'),$Mode+[Environment]::NewLine)
Start-Sleep -Milliseconds ([int]$outcome.Delay)
$state=if(!$outcome.Success){'needs-attention'}elseif($Mode -eq 'Stop'){'stopped'}else{'running'}
$message=if($outcome.Success){'TEST: operation completed'}else{'TEST: stop failed; retry remains available'}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'assistant-state.json'),(@{State=$state;Message=$message}|ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'recovery-last-result.json'),(@{Time=[DateTimeOffset]::Now.ToString('o');Mode=$Mode;Success=[bool]$outcome.Success;Message=$message}|ConvertTo-Json))
if(!$outcome.Success){exit 1}
exit 0
'@
[IO.File]::WriteAllText((Join-Path $script:fixtureDir 'Campus-Recovery.ps1'),$fakeRecovery,[Text.UTF8Encoding]::new($true))
$fakeNetwork=@'
function Test-SharingDiagnostics([string]$Kind,[string]$AdapterId){
 [pscustomobject]@{Kind=$Kind;Available=$true;StatusType='Warning';Summary='热点能力仍待实测';Details='TEST readonly diagnostic';Capability='Unknown';Candidates=@([pscustomobject]@{Id=$(if($Kind -eq 'Wi-Fi'){'wifi-test'}else{'wired-test'});ConnectionKind=$Kind})}
}
'@
[IO.File]::WriteAllText((Join-Path $script:fixtureDir 'Network.ps1'),$fakeNetwork,[Text.UTF8Encoding]::new($true))
$source=Join-Path $PSScriptRoot 'payload\Panel.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Panel parser failure'
# Load the production form, controls, functions and event handlers, but never run
# its app entry loop, single-instance mutex, first-run flow or preview exit.
$parts=foreach($statement in $ast.EndBlock.Statements){
    $text=$statement.Extent.Text
    if($statement -is [Management.Automation.Language.IfStatementAst] -and ($text -match '^if\(!?\$PreviewPath\)')){continue}
    if($text -match '^\$form\.Add_Shown\('){continue}
    if($statement -is [Management.Automation.Language.TryStatementAst] -and $text -match '\$form\.ShowDialog\(\)'){continue}
    $text.Replace('$root=$PSScriptRoot','$root=$script:fixtureDir').Replace('$tray.Visible=(!$PreviewPath)','$tray.Visible=$false')
}
$PreviewPath=$null
. ([scriptblock]::Create(($parts -join [Environment]::NewLine)))
$script:testChoice=[Windows.Forms.DialogResult]::Cancel
function Ask-Close{return $script:testChoice}
function Show-Panel{$form.Show();$form.WindowState='Normal'}
$form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-30000,-30000)
$form.Show();[Windows.Forms.Application]::DoEvents()
try{
    Assert ($notice.Text -notmatch 'System\.Windows\.Forms') 'Notice contains a control type instead of user text'
    Assert ($network.Text -match 'TEST-CAMPUS') 'Bound network is not shown'

    $initialSettings=(Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'settings.json')).Hash
    $initialBackup=(Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'original-startup.json')).Hash
    Assert (!$startButton.Enabled -and !$accountButton.Enabled) 'Actions allowed before explicit detection'
    Start-Sharing
    Assert (@(Read-Calls).Count -eq 0 -and $null -eq $script:child) 'Unconfirmed mode started sharing'
    $rbWired.Checked=$true
    Assert ((Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'settings.json')).Hash -eq $initialSettings) 'Radio selection rewrote network binding'
    Assert ((Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'original-startup.json')).Hash -eq $initialBackup) 'Radio selection rewrote original recovery baseline'
    $checkButton.PerformClick()
    Assert (!$startButton.Enabled -and !$accountButton.Enabled) 'A different selected mode changed the bound configuration'
    $rbWifi.Checked=$true;$checkButton.PerformClick()
    Assert ($startButton.Enabled -and $accountButton.Enabled) 'Detected configured mode did not enable actions'
    Assert ($modeStatus.Text -match '待实测' -and $modeStatus.Text -notmatch '热点就绪|已连通') 'Unknown hotspot capability was reported as verified ready'
    Assert ((Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'settings.json')).Hash -eq $initialSettings -and (Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'original-startup.json')).Hash -eq $initialBackup) 'Read-only detection changed configuration'

    # The real button event must dispatch Stop, not the old Pause mode.
    Set-Outcome $true 1000
    $stopButton.PerformClick()
    Assert ($null -ne $script:child) 'Stop did not start its worker'
    Assert (!$stopButton.Enabled -and !$startButton.Enabled -and !$stopItem.Enabled) 'Busy controls allowed a second mutation'
    $firstPid=$script:child.Id
    $startButton.PerformClick();Start-Sharing
    Assert ($script:child.Id -eq $firstPid) 'A duplicate operation replaced the current worker'
    Wait-Action
    $calls=@(Read-Calls)
    Assert ($calls.Count -eq 1 -and $calls[0] -eq 'Stop') 'Stop button dispatched the wrong operation or duplicate work'
    Assert (!$form.IsDisposed -and $form.Visible) 'A regular Stop unexpectedly closed the panel'
    Assert ($status.Text -match '已停止' -and !$stopButton.Enabled) 'Stopped state did not update controls'

    # A preflight refusal does not change lifecycle state; it must still be
    # prominent and persist across refreshes, then clear after a newer stop.
    $stoppedAt=[DateTimeOffset]::Now
    Fixture-Json 'assistant-state.json' @{State='stopped';UpdatedAt=$stoppedAt.ToString('o')}
    Fixture-Json 'recovery-last-result.json' @{Mode='Resume';Success=$false;Time=$stoppedAt.AddSeconds(1).ToString('o');Message='TEST: exit official client first'}
    Refresh-Panel
    Assert ($status.Text -match '未启动' -and $detail.Text -eq 'TEST: exit official client first') 'Refused start was hidden by stopped state'
    Assert ($startButton.Enabled -and !$stopButton.Enabled) 'Refused start changed the stopped action controls'
    $script:operationNotice='';Refresh-Panel
    Assert ($detail.Text -eq 'TEST: exit official client first') 'Refusal was lost on panel refresh'
    Fixture-Json 'assistant-state.json' @{State='stopped';UpdatedAt=$stoppedAt.AddSeconds(2).ToString('o')}
    Refresh-Panel
    Assert ($status.Text -match '已停止') 'Old refusal overrode a newer successful stop'

    # Starting again must use Resume, which re-applies managed ownership.
    Set-Outcome $true
    $startButton.PerformClick();Wait-Action
    $calls=@(Read-Calls)
    Assert ($calls.Count -eq 2 -and $calls[1] -eq 'Resume') 'Start button did not dispatch Resume'
    Assert ($stopButton.Enabled) 'Resume completion did not make Stop available'

    # Closing with Cancel must leave both the UI and network operation untouched.
    $script:testChoice=[Windows.Forms.DialogResult]::Cancel
    $form.Close();[Windows.Forms.Application]::DoEvents()
    Assert (!$form.IsDisposed -and $form.Visible) 'Cancel exit closed or hid the window'
    Assert (@(Read-Calls).Count -eq 2 -and $null -eq $script:child) 'Cancel exit launched a recovery operation'

    # Keep-sharing hides the window without dispatching Stop, then the tray Show
    # event must bring the same instance back.
    $script:testChoice=[Windows.Forms.DialogResult]::No
    $form.Close();[Windows.Forms.Application]::DoEvents()
    Assert (!$form.IsDisposed -and !$form.Visible) 'Keep-sharing did not hide the existing window'
    Assert (@(Read-Calls).Count -eq 2) 'Keep-sharing unexpectedly dispatched Stop'
    $showItem.PerformClick();[Windows.Forms.Application]::DoEvents()
    Assert ($form.Visible) 'Tray Show did not restore the window'
    $hideButton.PerformClick();Assert (!$form.Visible) 'Hide-to-tray button did not hide the window'
    $showItem.PerformClick()

    # A failed Stop requested during exit must keep the UI usable and retain the
    # backend message, rather than silently exiting while sharing may remain.
    Set-Outcome $false
    $script:testChoice=[Windows.Forms.DialogResult]::Yes
    $form.Close();Wait-Action
    Assert (!$form.IsDisposed -and $form.Visible) 'Stop failure closed the window'
    Assert (!$script:closeAfterStop -and !$script:allowClose) 'Stop failure left stale exit flags'
    Assert ($stopButton.Enabled -and $notice.Text -match 'TEST: stop failed') 'Stop failure did not leave a visible retry path'

    # Tray Stop uses the same backend action; tray Start uses Resume.
    Set-Outcome $true
    $stopItem.PerformClick();Wait-Action
    Assert ($status.Text -match '已停止') 'Tray Stop did not stop'
    $startItem.PerformClick();Wait-Action
    Assert ($stopItem.Enabled) 'Tray Start did not restore Stop availability'
    $calls=@(Read-Calls)
    Assert (($calls -join ',') -eq 'Stop,Resume,Stop,Stop,Resume') 'Tray or failed-exit action routing changed'

    # The native cleaner starts outside the target and asks separately before
    # restoring or deleting. Stub only the external process boundary here.
    [IO.File]::WriteAllText((Join-Path $script:fixtureDir '校园网共享助手-清理与卸载.exe'),'fixture')
    $script:cleanupCall=$null;$script:cleanupHandedOff=$false
    function Start-CleanupProcess([string]$Path,[string]$Target){$script:cleanupCall=@{Path=$Path;Target=$Target}}
    function Complete-CleanupHandoff{$script:cleanupHandedOff=$true}
    $cleanButton.PerformClick()
    Assert ($script:cleanupCall -and $script:cleanupCall.Target -eq $script:fixtureDir -and $script:cleanupHandedOff) 'Cleaner button did not pass the exact current target'
    Assert ($script:cleanupCall.Path.StartsWith([IO.Path]::GetTempPath()) -and !$script:cleanupCall.Path.StartsWith($script:fixtureDir)) 'Cleaner was not copied outside the deletion target'
    Assert ((Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'original-startup.json')).Hash -eq $initialBackup) 'Cleaner handoff modified recovery before external confirmation'
    Assert (@(Read-Calls).Count -eq 5) 'Cleaner handoff stopped sharing before external confirmation'
    [IO.File]::Delete($script:cleanupCall.Path)
    [IO.Directory]::Delete([IO.Path]::GetDirectoryName($script:cleanupCall.Path),$false)

    # Normal uninstall also releases the UI only after its process starts.
    # Its confirmation may still be cancelled: no Stop or restoration is sent.
    [IO.File]::WriteAllText((Join-Path $script:fixtureDir 'unins000.exe'),'fixture')
    $script:regularCall=$null;$script:regularHandedOff=$false;$script:regularFail=$true
    function Start-RegularUninstallProcess([string]$Path){if($script:regularFail){throw 'TEST: UAC cancelled'};$script:regularCall=$Path}
    function Complete-RegularUninstallHandoff{$script:regularHandedOff=$true}
    $uninstallButton.PerformClick()
    Assert (!$script:regularHandedOff -and !$form.IsDisposed -and $form.Visible) 'Failed or cancelled regular uninstall closed the panel'
    Assert ($notice.Text -match '一键清理与卸载' -and !$script:allowClose) 'Failed regular uninstall omitted the recovery tool or left an exit flag'
    $script:regularFail=$false
    $uninstallButton.PerformClick()
    Assert ($script:regularHandedOff -and $script:regularCall -eq (Join-Path $script:fixtureDir 'unins000.exe')) 'Regular uninstall did not hand off to the exact native uninstaller'
    Assert (@(Read-Calls).Count -eq 5) 'Regular uninstall stopped sharing before native confirmation'
    Assert ((Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'settings.json')).Hash -eq $initialSettings -and (Get-FileHash -LiteralPath (Join-Path $script:fixtureDir 'original-startup.json')).Hash -eq $initialBackup) 'Regular uninstall handoff changed configuration, port or recovery backup'

    # Only a successful stopped backend result may complete Stop-and-exit.
    $script:testChoice=[Windows.Forms.DialogResult]::Yes
    $form.Close();Wait-Action
    Assert ($form.IsDisposed) 'Successful Stop-and-exit did not close the panel'
    Assert ((Read-State 'assistant-state.json').State -eq 'stopped') 'UI exited without a stopped backend state'
    Assert (@(Read-Calls).Count -eq 6) 'Unexpected recovery invocation count'
    Write-Output ('PASS: panel isolated behavior; '+$script:checks+' assertions; Stop/Resume, duplicate prevention, cancel, tray, stop failure and successful exit.')
}finally{
    if($script:child){if(!$script:child.HasExited){$script:child.Kill();[void]$script:child.WaitForExit(3000)};$script:child.Dispose();$script:child=$null}
    $script:allowClose=$true
    if(!$form.IsDisposed){$form.Close();$form.Dispose()}
    $tray.Visible=$false;$tray.Dispose();$menu.Dispose()
}
