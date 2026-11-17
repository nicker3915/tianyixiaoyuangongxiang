param(
    [string]$TargetRoot,
    [ValidateSet('Preview','Remove')][string]$Mode='Preview',
    [string]$ResultPath,
    [string]$SummaryPath,
    [switch]$UserConfirmed
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.Core.ps1')
if($MyInvocation.InvocationName -eq '.'){return}
foreach($path in @($ResultPath,$SummaryPath)){
    if(!$path){continue}
    $full=[IO.Path]::GetFullPath($path)
    if($TargetRoot -and ((Test-CleanupSamePath $full $TargetRoot) -or $full.StartsWith(([IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase))){throw '清理结果必须保存在目标目录之外。'}
    Assert-CleanupNoReparse $full
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $probe=$full+'.'+[guid]::NewGuid().ToString('N')+'.probe'
    try{
        [IO.File]::WriteAllText($probe,'write-probe')
        if([IO.File]::Exists($full)){$handle=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$handle.Dispose()}
    }finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
}
$result=Invoke-AssistantCleanup -TargetRoot $TargetRoot -BundleRoot $PSScriptRoot -Mode $Mode -UserConfirmed:$UserConfirmed
if($ResultPath){[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if($SummaryPath){[IO.File]::WriteAllText($SummaryPath,[string]$result.Summary,[Text.UTF8Encoding]::new($true))}
if($Mode -eq 'Preview'){if($result.CanRemove){exit 0}else{exit 2}}
if($result.Success){exit 0}else{exit 1}
