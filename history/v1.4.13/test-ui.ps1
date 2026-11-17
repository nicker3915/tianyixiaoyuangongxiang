
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'payload\Manage.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'CredForm'},$true)
$code=$fn.Extent.Text.Replace('$f.StartPosition=''CenterScreen''','$f.StartPosition=''Manual'';$f.Location=New-Object Drawing.Point(-30000,-30000);$f.ShowInTaskbar=$false')
. ([scriptblock]::Create($code))
function Alert($message){$script:alert=$message}
function Test-SharingDiagnostics([string]$Kind,[string]$AdapterId){[pscustomobject]@{Available=$true;StatusType='Warning';Summary='热点能力待实测';Details='fixture'}}
$nets=@([pscustomobject]@{Label='校园以太网';Id='wired-test';ConnectionKind='有线'},[pscustomobject]@{Label='校园 Wi-Fi';Id='wifi-test';ConnectionKind='Wi-Fi'})
$script:step=0
$timer=New-Object Windows.Forms.Timer
$timer.Interval=150
$timer.Add_Tick({
    $f=[Windows.Forms.Application]::OpenForms|Select-Object -First 1
    if(!$f){return}
    $fields=@($f.Controls|Where-Object {$_ -is [Windows.Forms.TextBox]})
    $confirm=$f.Controls|Where-Object Text -eq '确认'
    if($script:step -eq 0){
        $confirm.PerformClick()
        if(!$script:alert){throw 'Empty input accepted'}
        $fields[0].Text='测试账户'
        $fields[1].Text='P"&\中文'
        if(!$fields[1].UseSystemPasswordChar){throw 'Password unmasked'}
        $toggle=$f.Controls|Where-Object Text -eq '显示密码'
        $toggle.Checked=$true
        if($fields[1].UseSystemPasswordChar){throw 'Toggle failed'}
        $toggle.Checked=$false
        $bitmap=New-Object Drawing.Bitmap($f.Width,$f.Height)
        $f.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$f.Width,$f.Height)))
        $bitmap.Save((Join-Path $PSScriptRoot 'account-preview.png'))
        $bitmap.Dispose()
        $script:step=1
        $confirm.PerformClick()
    }else{$timer.Stop();$f.DialogResult='Cancel'}
})
try{
    $timer.Start()
    $result=CredForm $nets $false 'Wi-Fi'
    if($result.User -cne '测试账户' -or $result.Pass -cne 'P"&\中文' -or $result.Net.Id -ne 'wifi-test'){throw 'Credential result mismatch'}
    $result=CredForm $nets $false 'Wi-Fi'
    if($result){throw 'Cancel returned credentials'}
    'PASS: kind-filtered form, blank validation, password mask/toggle, confirm special characters, cancellation.'
}finally{$timer.Stop();$timer.Dispose()}
