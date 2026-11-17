param(
    [string]$TargetRoot,
    [ValidateSet('Preview','Remove','Discover')][string]$Mode='Preview',
    [string]$ResultPath,
    [string]$SummaryPath,
    [string]$CandidatesPath,
    [switch]$UserConfirmed
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')
. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.Core.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.Processes.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.Discovery.ps1')
if($MyInvocation.InvocationName -eq '.'){return}
foreach($path in @($ResultPath,$SummaryPath,$CandidatesPath)){
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
if($Mode -eq 'Discover'){
    try {
        $candidates=@(Get-AssistantInstallCandidates)
        $summary=if($candidates.Count){'已找到 '+$candidates.Count+' 个旧版候选位置。请选择要处理的那一项；下一步会核对归属和恢复资料。'}else{'未找到可确认的安装位置。可检查默认目录，或使用“浏览”选择旧文件夹；无需先打开旧助手。'}
        $result=[ordered]@{Success=$true;Candidates=$candidates;Summary=$summary}
        if($ResultPath){[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
        if($SummaryPath){[IO.File]::WriteAllText($SummaryPath,$summary,[Text.UTF8Encoding]::new($false))}
        if($CandidatesPath){[IO.File]::WriteAllLines($CandidatesPath,[string[]]@($candidates|ForEach-Object {$_.TargetRoot}),[Text.UTF8Encoding]::new($false))}
        exit 0
    }catch{
        if($SummaryPath){[IO.File]::WriteAllText($SummaryPath,'自动查找暂未完成，可使用浏览选择旧目录后继续检查。',[Text.UTF8Encoding]::new($false))}
        exit 1
    }
}
$result=Invoke-AssistantCleanup -TargetRoot $TargetRoot -BundleRoot $PSScriptRoot -Mode $Mode -UserConfirmed:$UserConfirmed
if($ResultPath){[IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
if($SummaryPath){[IO.File]::WriteAllText($SummaryPath,[string]$result.Summary,[Text.UTF8Encoding]::new($true))}
if($Mode -eq 'Preview'){if($result.CanRemove){exit 0}else{exit 2}}
if($result.Success){exit 0}else{exit 1}
