# Process inspection is inert until called. Never export raw command lines.
function Initialize-CleanupProcessNative {
    if('GDPortalShareCleanup.ProcessNative' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace GDPortalShareCleanup {
    public static class ProcessNative {
        [DllImport("shell32.dll", SetLastError=true)] private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
        public static string[] Split(string value) {
            if (String.IsNullOrWhiteSpace(value) || value.Length > 32767) return new string[0];
            int count; IntPtr pointer = CommandLineToArgvW(value, out count);
            if (pointer == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer,i*IntPtr.Size)); return result; }
            finally { LocalFree(pointer); }
        }
    }
    public sealed class UiProcessHandle : IDisposable {
        [DllImport("kernel32.dll",SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool QueryFullProcessImageNameW(IntPtr handle,uint flags,StringBuilder path,ref int size);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetProcessTimes(IntPtr handle,out long created,out long exited,out long kernel,out long user);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool TerminateProcess(IntPtr handle,uint code);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        private IntPtr handle;
        public readonly string ImagePath;
        public readonly long StartTicks;
        public UiProcessHandle(int id) {
            handle=OpenProcess(0x00100000 | 0x00001000 | 0x00000001,false,id);
            if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                int length=32768; var path=new StringBuilder(length);
                if(!QueryFullProcessImageNameW(handle,0,path,ref length)) throw new Win32Exception(Marshal.GetLastWin32Error());
                long created,exited,kernel,user;
                if(!GetProcessTimes(handle,out created,out exited,out kernel,out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
                ImagePath=path.ToString();StartTicks=DateTime.FromFileTimeUtc(created).Ticks;
            } catch { Dispose();throw; }
        }
        public bool WaitForExit(int milliseconds) {
            uint state=WaitForSingleObject(handle,(uint)milliseconds);
            if(state==0xFFFFFFFF) throw new Win32Exception(Marshal.GetLastWin32Error());
            return state==0;
        }
        public void Terminate() {
            if(!TerminateProcess(handle,0) && !WaitForExit(0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if(!WaitForExit(5000)) throw new InvalidOperationException("UI process did not exit.");
        }
        public void Dispose() { if(handle!=IntPtr.Zero) {CloseHandle(handle);handle=IntPtr.Zero;} }
    }
}
'@ -ErrorAction Stop | Out-Null
}
function Split-CleanupWindowsCommandLine([string]$CommandLine) {
    Initialize-CleanupProcessNative
    return ,([GDPortalShareCleanup.ProcessNative]::Split($CommandLine))
}
function Get-CleanupUiProcessRows {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='校园网共享助手.exe' OR Name='CampusQuietLauncher.exe'" -ErrorAction Stop)
}
function Get-CleanupProcessIdentity([int]$ProcessId) {
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if(!$process -or !$process.Path){return $null}
    [pscustomobject]@{Id=$process.Id;Path=$process.Path;StartTicks=[string]$process.StartTime.ToUniversalTime().Ticks}
}
function Get-CleanupUiRole([string]$Root,[string]$ExecutablePath,[string[]]$Arguments) {
    if(!$Arguments -or !$Arguments.Count -or !(Test-CleanupSamePath $Arguments[0] $ExecutablePath)){return ''}
    $isWrapper=(Test-CleanupSamePath $ExecutablePath (Join-Path $Root '校园网共享助手.exe')) -or (Test-CleanupSamePath $ExecutablePath (Join-Path $Root 'CampusQuietLauncher.exe'))
    if($isWrapper){
        if($Arguments.Count -eq 1 -or ($Arguments.Count -eq 2 -and $Arguments[1] -cin @('panel','firstrun'))){return 'UiWrapper'}
        if($Arguments.Count -eq 2 -and $Arguments[1] -cin @('startup','watch')){return 'WorkflowWrapper'}
        return ''
    }
    $isPowerShell=$false
    foreach($path in @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),(Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'))){if(Test-CleanupSamePath $ExecutablePath $path){$isPowerShell=$true}}
    if(!$isPowerShell){return ''}
    $i=1
    while($i -lt $Arguments.Count){
        $arg=$Arguments[$i]
        if($arg -in @('-NoProfile','-NoLogo','-NonInteractive','-STA')){$i++;continue}
        if($arg -ieq '-WindowStyle'){
            if($i+1 -ge $Arguments.Count -or $Arguments[$i+1] -notin @('Hidden','Normal','Minimized','Maximized')){return ''}
            $i+=2;continue
        }
        if($arg -ieq '-ExecutionPolicy'){
            if($i+1 -ge $Arguments.Count -or $Arguments[$i+1] -notin @('Bypass','RemoteSigned','AllSigned','Restricted','Unrestricted','Undefined','Default')){return ''}
            $i+=2;continue
        }
        if($arg -ieq '-File'){
            if($i+1 -ge $Arguments.Count -or !(Test-CleanupSamePath $Arguments[$i+1] (Join-Path $Root 'Panel.ps1'))){return ''}
            if($Arguments.Count -eq $i+2 -or ($Arguments.Count -eq $i+3 -and $Arguments[$i+2] -ceq '-FirstRun')){return 'PanelPowerShell'}
            return ''
        }
        # Command/EncodedCommand aliases, unknown options and all trailing script
        # arguments other than literal -FirstRun are intentionally rejected.
        return ''
    }
    return ''
}
function Get-CleanupUiArgumentSignature([string[]]$Arguments) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return [Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]::Join([string][char]0,$Arguments))))}finally{$hash.Dispose()}
}
function Get-CleanupUiProcessSnapshot([string]$Root) {
    $verified=@();$unverified=@()
    foreach($row in @(Get-CleanupUiProcessRows)){
        $path=[string]$row.ExecutablePath
        if(!$path){continue}
        $isWrapper=(Test-CleanupSamePath $path (Join-Path $Root '校园网共享助手.exe')) -or (Test-CleanupSamePath $path (Join-Path $Root 'CampusQuietLauncher.exe'))
        $parsedArguments=Split-CleanupWindowsCommandLine ([string]$row.CommandLine)
        $role=Get-CleanupUiRole $Root $path $parsedArguments
        if($role -eq 'WorkflowWrapper'){continue}
        if(!$role){if($isWrapper){$unverified+=[pscustomobject]@{Id=[int]$row.ProcessId;Path=$path}};continue}
        $identity=Get-CleanupProcessIdentity ([int]$row.ProcessId)
        if(!$identity -or !(Test-CleanupSamePath $identity.Path $path)){continue}
        if($row.CreationDate){
            $created=if($row.CreationDate -is [datetime]){$row.CreationDate.ToUniversalTime()}else{[Management.ManagementDateTimeConverter]::ToDateTime([string]$row.CreationDate).ToUniversalTime()}
            # WMI DMTF carries microseconds; System.Diagnostics/handles carry 100ns.
            if([Math]::Abs([long]$identity.StartTicks-$created.Ticks) -ge 10){continue}
        }
        $verified+=[pscustomobject]@{Id=[int]$identity.Id;Path=[string]$identity.Path;StartTicks=[string]$identity.StartTicks;ParentId=[int]$row.ParentProcessId;Role=$role;ArgumentSignature=(Get-CleanupUiArgumentSignature $parsedArguments)}
    }
    [pscustomobject]@{Processes=$verified;Unverified=$unverified}
}
function Open-CleanupUiHandle([int]$ProcessId) {
    Initialize-CleanupProcessNative
    New-Object GDPortalShareCleanup.UiProcessHandle($ProcessId)
}
function Stop-CleanupUiProcesses([string]$Root,$Processes) {
    $null=Assert-CleanupRoot $Root
    $closed=@()
    foreach($proof in @($Processes|Sort-Object @{Expression={if($_.Role -eq 'PanelPowerShell'){0}else{1}}},Id)){
        $current=@((Get-CleanupUiProcessSnapshot $Root).Processes|Where-Object {$_.Id -eq $proof.Id -and $_.Role -eq $proof.Role -and $_.StartTicks -ceq $proof.StartTicks -and $_.ParentId -eq $proof.ParentId -and $_.ArgumentSignature -ceq $proof.ArgumentSignature -and (Test-CleanupSamePath $_.Path $proof.Path)})
        if(!$current.Count){continue}
        $handle=$null
        try{
            $handle=Open-CleanupUiHandle $proof.Id
            if(!(Test-CleanupSamePath $handle.ImagePath $proof.Path) -or [string]$handle.StartTicks -cne [string]$proof.StartTicks){continue}
            if($handle.WaitForExit($(if($proof.Role -eq 'UiWrapper'){1500}else{0}))){continue}
            # Requery parameters immediately before terminating the already-opened
            # handle. The handle prevents PID reuse from targeting a new process.
            $fresh=@((Get-CleanupUiProcessSnapshot $Root).Processes|Where-Object {$_.Id -eq $proof.Id -and $_.Role -eq $proof.Role -and $_.StartTicks -ceq $proof.StartTicks -and $_.ParentId -eq $proof.ParentId -and $_.ArgumentSignature -ceq $proof.ArgumentSignature -and (Test-CleanupSamePath $_.Path $proof.Path)})
            if(!$fresh.Count){continue}
            $handle.Terminate();$closed+=[int]$proof.Id
        }finally{if($handle){$handle.Dispose()}}
    }
    return ,$closed
}
