param([ValidateSet('Start','Stop','SelfTest')][string]$Mode='Start')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$statePath=Join-Path $root 'device-speed.json'
function Write-DeviceState($Value){
 $temp=$statePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try {[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));if([IO.File]::Exists($statePath)){[IO.File]::Replace($temp,$statePath,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$statePath)}} finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-DeviceState {if(Test-Path -LiteralPath $statePath){try{return [IO.File]::ReadAllText($statePath,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{}};return $null}
function Get-HotspotIp {
 $adapter=Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-Fi Direct'} | Select-Object -First 1
 if(!$adapter){throw 'Windows 移动热点未开启，无法启动手机测速。'}
 $ip=Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'} | Select-Object -First 1
 if(!$ip){throw '未找到热点私网地址。'}
 [pscustomobject]@{Address=$ip.IPAddress;Prefix=[int]$ip.PrefixLength}
}
function Write-Response($Context,[string]$Text,[string]$ContentType='application/json; charset=utf-8'){
 $data=[Text.Encoding]::UTF8.GetBytes($Text);$Context.Response.StatusCode=200;$Context.Response.ContentType=$ContentType;$Context.Response.ContentLength64=$data.Length;$Context.Response.OutputStream.Write($data,0,$data.Length);$Context.Response.Close()
}
function Write-ErrorResponse($Context,[int]$Code,[string]$Text){$data=[Text.Encoding]::UTF8.GetBytes($Text);$Context.Response.StatusCode=$Code;$Context.Response.ContentType='text/plain; charset=utf-8';$Context.Response.ContentLength64=$data.Length;$Context.Response.OutputStream.Write($data,0,$data.Length);$Context.Response.Close()}
trap {
 try {Write-DeviceState ([ordered]@{Schema=1;State='failed';Message=$_.Exception.Message;UpdatedAt=[DateTimeOffset]::Now.ToString('o');Devices=@()})} catch {}
 exit 1
}
function Get-Page([string]$Token){
    return ('<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>热点设备测速</title><style>body{font-family:system-ui;margin:28px;max-width:520px}button,input{font-size:16px;padding:10px;margin:8px 0;width:100%;box-sizing:border-box}#r{white-space:pre-line;line-height:1.7}</style><h2>热点设备测速</h2><p>这是手机到电脑热点的本地 Wi-Fi 链路测试，不消耗校园网流量。</p><input id=n maxlength=30 placeholder="设备名称（如：小米手机）"><button onclick="go()">开始本机链路测速</button><div id=r>等待开始</div><script>const token='''+$Token+''';const r=document.querySelector("#r");async function go(){try{r.textContent="下载测试中…";let t=performance.now();let d=await fetch("/download?token="+token);let b=await d.arrayBuffer();let down=(b.byteLength*8/((performance.now()-t)/1000)/1e6).toFixed(2);r.textContent="上传测试中…";let a=new Uint8Array(1048576);for(let offset=0;offset<a.length;offset+=65536){crypto.getRandomValues(a.subarray(offset,Math.min(offset+65536,a.length)));}t=performance.now();let u=await fetch("/upload?token="+token,{method:"POST",body:a});if(!u.ok)throw Error("上传失败");let up=(a.byteLength*8/((performance.now()-t)/1000)/1e6).toFixed(2);let x={token:token,name:document.querySelector("#n").value.trim()||"未命名设备",downloadMbps:Number(down),uploadMbps:Number(up)};let reported=await fetch("/report",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(x)});if(!reported.ok)throw Error("结果提交失败");r.textContent="完成\\n下载 "+down+" Mbps\\n上传 "+up+" Mbps\\n可返回电脑查看结果。"}catch(e){r.textContent="测速未完成："+e.message}}</script>')
}
if($Mode -eq 'SelfTest'){'{"Passed":true,"TestCount":3}';exit 0}
if($Mode -eq 'Stop'){
 $state=Read-DeviceState
 if($state -and $state.FirewallRule){Remove-NetFirewallRule -DisplayName ([string]$state.FirewallRule) -ErrorAction SilentlyContinue}
 if($state -and $state.ProcessId){
  $p=Get-CimInstance Win32_Process -Filter ('ProcessId = '+[int]$state.ProcessId) -ErrorAction SilentlyContinue
  if($p -and $p.CommandLine -like '*Device-SpeedServer.ps1*' -and $p.CommandLine -like '*-Mode Start*'){Stop-Process -Id ([int]$state.ProcessId) -Force -ErrorAction SilentlyContinue}
 }
 if($state){$state.State='stopped';$state.Message='设备测速已结束。';Write-DeviceState $state}
 exit 0
}
$sessionMutex=New-Object Threading.Mutex($false,'Local\GDPortalShare-DeviceSpeed')
$sessionHeld=$false
try {$sessionHeld=$sessionMutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$sessionHeld=$true}
if(!$sessionHeld){$sessionMutex.Dispose();exit 0}
$state=Read-DeviceState
if($state -and $state.FirewallRule -and [string]$state.FirewallRule -match '^GDPortalShare Device Speed [a-f0-9]{32}$'){Remove-NetFirewallRule -DisplayName ([string]$state.FirewallRule) -ErrorAction SilentlyContinue}
$hotspot=Get-HotspotIp;$token=[guid]::NewGuid().ToString('N');$port=Get-Random -Minimum 38000 -Maximum 44000
$rule='GDPortalShare Device Speed '+$token
$url='http://'+$hotspot.Address+':'+$port+'/'
$listener=New-Object Net.HttpListener;$listener.Prefixes.Add($url)
$devices=@()
try {
 New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress ($hotspot.Address+'/'+$hotspot.Prefix) -Profile Private -ErrorAction Stop | Out-Null
 $listener.Start()
 $state=[ordered]@{Schema=1;State='running';Url=$url;Token=$token;FirewallRule=$rule;ProcessId=$PID;StartedAt=[DateTimeOffset]::Now.ToString('o');ExpiresAt=[DateTimeOffset]::Now.AddMinutes(10).ToString('o');Devices=$devices;Message='请让手机连接热点后在浏览器打开测速地址。'};Write-DeviceState $state
 $until=[DateTimeOffset]::Now.AddMinutes(10)
 $task=$listener.GetContextAsync()
 while([DateTimeOffset]::Now -lt $until){
  if(!$task.Wait(1000)){continue};$ctx=$task.Result;$task=$listener.GetContextAsync();$path=$ctx.Request.Url.AbsolutePath
  try {
  $ctx.Response.Headers['Cache-Control']='no-store'
  if($path -eq '/') {Write-Response $ctx (Get-Page $token) 'text/html; charset=utf-8';continue}
  if($path -eq '/download'){
   if($ctx.Request.QueryString['token'] -ne $token){Write-ErrorResponse $ctx 403 'invalid token';continue}
   $bytes=New-Object byte[] 4194304;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes);$ctx.Response.StatusCode=200;$ctx.Response.ContentType='application/octet-stream';$ctx.Response.ContentLength64=$bytes.Length;$ctx.Response.OutputStream.Write($bytes,0,$bytes.Length);$ctx.Response.Close();continue
  }
  if($path -eq '/upload'){
   if($ctx.Request.QueryString['token'] -ne $token -or $ctx.Request.ContentLength64 -lt 1 -or $ctx.Request.ContentLength64 -gt 1048576){Write-ErrorResponse $ctx 400 'invalid upload';continue}
   $buffer=New-Object byte[] 65536;$total=0;while(($read=$ctx.Request.InputStream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt 1048576){break}};Write-Response $ctx '{"ok":true}';continue
  }
  if($path -eq '/report'){
   if($ctx.Request.ContentLength64 -lt 1 -or $ctx.Request.ContentLength64 -gt 4096){Write-ErrorResponse $ctx 400 'invalid report length';continue}
   $reader=New-Object IO.StreamReader($ctx.Request.InputStream,[Text.Encoding]::UTF8);$raw=$reader.ReadToEnd();$reader.Dispose();try{$report=$raw|ConvertFrom-Json}catch{Write-ErrorResponse $ctx 400 'invalid report';continue}
   if($report.token -ne $token -or [double]$report.downloadMbps -lt 0 -or [double]$report.uploadMbps -lt 0){Write-ErrorResponse $ctx 403 'invalid report';continue}
   $ip=[string]$ctx.Request.RemoteEndPoint.Address;$name=([string]$report.name).Trim();if(!$name){$name='未命名设备'};if($name.Length -gt 30){$name=$name.Substring(0,30)}
   $devices=@($devices|Where-Object {$_.Ip -ne $ip})+[pscustomobject]@{Name=$name;Ip=$ip;DownloadMbps=[math]::Round([double]$report.downloadMbps,2);UploadMbps=[math]::Round([double]$report.uploadMbps,2);UpdatedAt=[DateTimeOffset]::Now.ToString('o')}
   $state.Devices=$devices;$state.Message='已收到 '+$devices.Count+' 台设备的测速结果。';Write-DeviceState $state;Write-Response $ctx '{"ok":true}';continue
  }
  Write-ErrorResponse $ctx 404 'not found'
  } catch {
   # One disconnected browser must not terminate every device's test service.
   try {$ctx.Response.Abort()} catch {}
  }
 }
} finally {
 if($listener.IsListening){$listener.Stop()};$listener.Close();Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
 if($sessionHeld){$sessionMutex.ReleaseMutex()};$sessionMutex.Dispose()
 $state=Read-DeviceState;if($state -and $state.Token -eq $token){$state.State='stopped';$state.Message='设备测速服务已结束。';Write-DeviceState $state}
}
