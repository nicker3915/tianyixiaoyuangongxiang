param([ValidateSet('有线','Wi-Fi')][string]$Kind='有线',[string]$AdapterId='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Network.ps1')
Test-SharingDiagnostics -Kind $Kind -AdapterId $AdapterId | ConvertTo-Json -Depth 6
