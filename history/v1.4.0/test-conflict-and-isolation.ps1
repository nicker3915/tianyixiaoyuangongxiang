$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Assert($cond, [string]$msg) { if (!$cond) { throw $msg } }

# 1. 语法检查
$stage = Join-Path $PSScriptRoot 'stage'
$scripts = @('Clean-Conflicts.ps1', 'Manage.ps1', 'Network.ps1', 'Panel.ps1', 'Start-CampusNetwork.ps1', 'Campus-Recovery.ps1')
foreach ($s in $scripts) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $stage $s), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "Parser error in $s : $($errors[0].Message)"
}
Write-Output "PASS: Syntax parse for all updated scripts."

# 2. 验证 Network.ps1 中的 Test-CampusProfile 隔离
. (Join-Path $stage 'Network.ps1')
$ad = [pscustomobject]@{ ifIndex = 10 }
# 有线模式下：不管 ExpectedNetworkName 是空、null 还是任意值，必须全部返回 $true (完全隔离 Wi-Fi 检查)
Assert (Test-CampusProfile $ad ([pscustomobject]@{ ConnectionKind = '有线'; ExpectedNetworkName = '' })) "Wired profile failed with empty SSID"
Assert (Test-CampusProfile $ad ([pscustomobject]@{ ConnectionKind = '有线'; ExpectedNetworkName = 'WYUNET' })) "Wired profile failed with SSID set"

# 3. 验证 Panel.ps1 中的未配置状态下单选按钮可用性与清理按钮
$fixtureDir = Join-Path $PSScriptRoot ('validation\isolation-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureDir)
try {
    # 不创建 settings.json，模拟未配置状态
    $source = Join-Path $stage 'Panel.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    $parts = foreach ($statement in $ast.EndBlock.Statements) {
        $text = $statement.Extent.Text
        if ($statement -is [Management.Automation.Language.IfStatementAst] -and ($text -match '^if\(!?\$PreviewPath\)')) { continue }
        if ($text -match '^\$form\.Add_Shown\(') { continue }
        if ($statement -is [Management.Automation.Language.TryStatementAst] -and $text -match '\$form\.ShowDialog\(\)') { continue }
        $text.Replace('$root=$PSScriptRoot', ('$root=''' + $fixtureDir + '''')).Replace('$tray.Visible=(!$PreviewPath)', '$tray.Visible=$false')
    }
    $PreviewPath = $null
    . ([scriptblock]::Create(($parts -join [Environment]::NewLine)))

    $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-30000, -30000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()

    # 核心断言 1：未配置状态下，以太网和 Wi-Fi 按钮必须处于可用状态 (Enabled = True)
    Assert ($rbWired.Enabled) "Radio Wired must be enabled when unconfigured!"
    Assert ($rbWifi.Enabled) "Radio WiFi must be enabled when unconfigured!"

    # 核心断言 2：清理按钮必须存在且可用
    Assert ($cleanButton -ne $null) "Clean button must exist!"
    Assert ($cleanButton.Text -match '清理冲突') "Clean button text mismatch!"
    Assert ($cleanButton.Enabled) "Clean button must be enabled!"

    # 核心断言 3：点击单选框可以在未配置时自由切换选中的模式
    $rbWifi.PerformClick(); [Windows.Forms.Application]::DoEvents()
    Assert ($script:selectedKind -eq 'Wi-Fi') "Clicking Wi-Fi did not change selectedKind to Wi-Fi"
    $rbWired.PerformClick(); [Windows.Forms.Application]::DoEvents()
    Assert ($script:selectedKind -eq '有线') "Clicking Wired did not change selectedKind to 有线"

    Write-Output "PASS: Panel unconfigured radio button availability and Clean button presence verified."
} finally {
    if (!$form.IsDisposed) { $form.Close(); $form.Dispose() }
    if (Test-Path -LiteralPath $fixtureDir) { Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue }
}
