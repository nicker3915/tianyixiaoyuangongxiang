"""Exercise the shipping Inno rules in a private, non-networked install fixture.

Only destinations/privileges/registration/Run action are isolated. Production
file list, hash checks, upgrade preflight, icons and uninstall callback remain.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent
CASE = ROOT / 'validation' / ('installer-' + uuid.uuid4().hex[:10])
CASE.mkdir(parents=True)
APP = CASE / 'Installed App'
PANEL_MUTEX = 'Local\\GDPortalShare-Fixture-' + CASE.name + '-Panel'
OPERATION_MUTEX = 'Global\\GDPortalShare-Fixture-' + CASE.name + '-Operation'
ENV = os.environ.copy()
(CASE / 'temp').mkdir()
ENV['TEMP'] = ENV['TMP'] = str(CASE / 'temp')
CSC = Path(os.environ['SystemRoot']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
ISCC = os.environ.get('ISCC') or str(Path(os.environ['LOCALAPPDATA']) / 'Programs/Antigravity IDE/resources/app/node_modules/innosetup/bin/ISCC.exe')
checks = []

def run(args, timeout=60):
    return subprocess.run([str(x) for x in args], cwd=CASE, env=ENV,
                          capture_output=True, timeout=timeout,
                          creationflags=subprocess.CREATE_NO_WINDOW)

def check(condition, label):
    if not condition:
        raise AssertionError(label)
    checks.append(label)
    print('PASS:', label, flush=True)

def compile_cs(name, body):
    source = CASE / (name + '.cs')
    source.write_text(body, encoding='utf-8-sig')
    exe = CASE / (name + '.exe')
    result = run([CSC, '/nologo', '/target:winexe', '/out:' + str(exe), source])
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return exe

probe = compile_cs('RunMarker', 'class P { static void Main(string[] a) { System.IO.File.AppendAllText(a[0], "run\\n"); } }')
text = (ROOT / 'setup.iss').read_text(encoding='utf-8-sig')
text = text.replace('Local\\GDPortalShare-Panel', PANEL_MUTEX).replace('Global\\GDPortalShare-Operation', OPERATION_MUTEX)
text = text.replace('{autopf}\\GDPortalShare', str(APP))
text = text.replace('PrivilegesRequired=admin', 'PrivilegesRequired=lowest\nCreateUninstallRegKey=no\nUseSetupLdr=no')
text = text.replace('UsePreviousAppDir=yes', 'UsePreviousAppDir=no')
text = re.sub(r'(?m)^OutputDir=.*$', 'OutputDir=' + str(CASE).replace('\\', '\\\\'), text)
text = re.sub(r'(?m)^OutputBaseFilename=.*$', 'OutputBaseFilename=fixture', text)
text = text.replace('{commondesktop}', str(CASE / 'Desktop')).replace('{group}', str(CASE / 'Start Menu'))
file_map = (ROOT / 'payload-files.iss').read_text(encoding='utf-8-sig').replace('Source: "stage\\', 'Source: "' + str(ROOT / 'stage') + '\\')
text = text.replace('#include "payload-files.iss"', file_map)
text = text.replace('#include "payload-checks.iss"', (ROOT / 'payload-checks.iss').read_text(encoding='utf-8-sig'))
text = re.sub(r'function InitializeSetup: Boolean;.*?\nend;', 'function InitializeSetup: Boolean;\nbegin\n  Result := True;\nend;', text, flags=re.S)
text = re.sub(r'function GetRegisteredInstallPath: String;.*?\nend;', lambda _: "function GetRegisteredInstallPath: String;\nbegin\n  Result := GetEnv('GDPORTAL_FIXTURE_REGISTERED_PATH');\nend;", text, flags=re.S)
run_section = '[Run]\nFilename: "' + str(probe) + '"; Parameters: """' + str(CASE / 'run-marker.txt') + '"""; Check: IsPayloadVerified; Flags: postinstall runhidden waituntilterminated\n'
text = re.sub(r'\[Run\].*?(?=\[UninstallDelete\])', lambda _: run_section, text, flags=re.S)
# Deliberate corruption occurs only in this fixture, after extraction and before
# the unchanged production verification routine.
text = text.replace('    VerifyInstalledPayload;', "    if FileExists(ExpandConstant('{src}\\corrupt-test.flag')) then\n      SaveStringToFile(ExpandConstant('{app}\\Network.ps1'), 'fixture corruption', False);\n    VerifyInstalledPayload;")
(CASE / 'fixture.iss').write_text(text, encoding='utf-8-sig')
result = run([ISCC, '/Q', CASE / 'fixture.iss'])
if result.returncode:
    raise RuntimeError(result.stdout + result.stderr)

def install(label, destination=None, tasks=None):
    args = [CASE / 'fixture.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(CASE / (label + '.log'))]
    if destination is not None:
        args.append('/DIR=' + str(destination))
    if tasks is not None:
        args.append('/TASKS=' + tasks)
    return run(args)

manifest = {}
for line in (ROOT / 'payload.sha256').read_text(encoding='utf-8').splitlines():
    expected, name = line.split('  ', 1)
    manifest[name] = expected

check(install('fresh').returncode == 0, 'fresh install succeeds')
check(all(hashlib.sha256((APP / name).read_bytes()).hexdigest() == expected for name, expected in manifest.items()), 'all '+str(len(manifest))+' installed files match final manifest')
check((CASE / 'run-marker.txt').exists(), 'verified installation executes permitted Run action')
(CASE / 'run-marker.txt').unlink()
ENV['GDPORTAL_FIXTURE_REGISTERED_PATH'] = str(APP)

# A stopped/broken install can be repaired even without a pause marker, after the user has stopped sharing and exited the application.
(APP / 'settings.json').write_text('{"fixture":true}', encoding='utf-8')
(APP / 'original-startup.json').write_text('{"fixtureBaseline":true}', encoding='utf-8')
settings = (APP / 'settings.json').read_bytes()
backup = (APP / 'original-startup.json').read_bytes()
(APP / 'Panel.ps1').write_text('broken panel fixture', encoding='utf-8')
check(install('repair', tasks='').returncode == 0, 'repair does not depend on the old pause marker')
check((CASE / 'Desktop/校园网共享助手.lnk').exists(), 'repair without desktop task preserves an existing desktop shortcut')
check((APP / 'settings.json').read_bytes() == settings and (APP / 'original-startup.json').read_bytes() == backup, 'repair preserves account settings and recovery baseline')
check(hashlib.sha256((APP / 'Panel.ps1').read_bytes()).hexdigest() == manifest['Panel.ps1'], 'repair restores damaged panel')
ENV.pop('GDPORTAL_FIXTURE_REGISTERED_PATH')
check(install('unregistered').returncode != 0, 'unregistered old directory requires cleanup instead of blind adoption')
(APP / '.gdportalshare-cleaned').write_text('GDPortalShare-20261104-cleaned-v1', encoding='ascii')
check(install('cleaned-directory').returncode == 0, 'successfully cleaned directory can be installed again')
check(not (APP / '.gdportalshare-cleaned').exists(), 'successful install clears the former cleanup marker')
ENV['GDPORTAL_FIXTURE_REGISTERED_PATH'] = str(APP)

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
kernel.CreateMutexW.restype = ctypes.c_void_p
kernel.CloseHandle.argtypes = [ctypes.c_void_p]
mutex = kernel.CreateMutexW(None, False, PANEL_MUTEX)
try:
    check(bool(mutex), 'fixture panel mutex created')
    check(install('busy-panel').returncode != 0, 'upgrade refuses an open panel')
finally:
    kernel.CloseHandle(mutex)

mutex = kernel.CreateMutexW(None, False, OPERATION_MUTEX)
try:
    check(bool(mutex), 'fixture operation mutex created')
    check(install('busy-operation').returncode != 0, 'upgrade refuses an active configuration or recovery operation')
finally:
    kernel.CloseHandle(mutex)

(CASE / 'run-marker.txt').unlink(missing_ok=True)
(CASE / 'corrupt-test.flag').write_text('test', encoding='ascii')
result = install('corrupt')
check(result.returncode != 0, 'integrity failure produces a nonzero installer exit')
check(not (CASE / 'run-marker.txt').exists(), 'integrity failure does not execute Run action')
check('Network.ps1' in (CASE / 'corrupt.log').read_text(encoding='utf-8-sig'), 'integrity failure identifies the broken component')
(CASE / 'corrupt-test.flag').unlink()
check(install('restore-after-corruption').returncode == 0, 'clean install recovers after integrity failure')

# Verify real .lnk targets and invoke the shipping launcher, with only Panel.ps1
# replaced by a harmless marker script in the isolated installation.
panel = APP / 'Panel.ps1'
panel_bytes = panel.read_bytes()
panel.write_text("param([switch]$FirstRun); [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'opened.txt'),'opened')", encoding='utf-8-sig')
shell_probe = CASE / 'links.ps1'
shell_probe.write_text(r'''param([string]$InstallDir,[switch]$SkipDesktop)
$ErrorActionPreference='Stop'
$app=$InstallDir
$shell=New-Object -ComObject WScript.Shell
foreach($folder in @('Desktop','Start Menu')){
 if($SkipDesktop -and $folder -eq 'Desktop'){continue}
 $link=Join-Path (Join-Path $PSScriptRoot $folder) '校园网共享助手.lnk'
 if(!(Test-Path -LiteralPath $link)){throw 'Expected shortcut was not created'}
 $shortcut=$shell.CreateShortcut($link)
 if($shortcut.TargetPath -ne (Join-Path $app '校园网共享助手.exe') -or $shortcut.Arguments -ne '' -or $shortcut.WorkingDirectory -ne $app){throw 'Shortcut target or working directory mismatch'}
 $marker=Join-Path $app 'opened.txt';if(Test-Path -LiteralPath $marker){[IO.File]::Delete($marker)}
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$shortcut.TargetPath;$info.Arguments=$shortcut.Arguments;$info.WorkingDirectory=$shortcut.WorkingDirectory
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $process=[Diagnostics.Process]::Start($info)
 if(!$process.WaitForExit(20000)){$process.Kill();throw 'Resolved shortcut target timed out'}
 try{if($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $marker)){throw 'Resolved shortcut target failed to open main executable'}}finally{$process.Dispose()}
}
''' ,encoding='utf-8-sig')
result = run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', shell_probe, '-InstallDir', APP])
check(result.returncode == 0, 'desktop and Start menu targets resolve correctly and the installed main executable launches')
panel.write_bytes(panel_bytes)

# Keep the production uninstall callback and its failure gating, but replace its
# network-affecting Manage implementation with an isolated result fixture.
(APP / 'original-startup.json').unlink()
(APP / 'Manage.ps1').write_text("param([string]$Mode); if(Test-Path (Join-Path $PSScriptRoot 'restore-fail.flag')){exit 9}; exit 0", encoding='utf-8-sig')
(APP / 'restore-fail.flag').write_text('test', encoding='ascii')
def uninstall(label, destination=APP):
    return run([destination / 'unins000.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(CASE / (label + '.log'))])
result = uninstall('uninstall-failure')
check(result.returncode != 0, 'failed recovery aborts uninstall')
check((APP / '校园网共享助手.exe').exists() and (APP / 'settings.json').read_bytes() == settings and (APP / 'unins000.exe').exists(), 'failed uninstall retains program settings and retry entry')
(APP / 'restore-fail.flag').unlink()
(APP / 'personal-notes.json').write_text('{"keep":true}', encoding='utf-8')
(APP / 'personal-notes.log').write_text('keep my notes', encoding='utf-8')
result = uninstall('uninstall-retry')
check(result.returncode == 0 and not (APP / '校园网共享助手.exe').exists() and not (APP / 'settings.json').exists(), 'successful retry removes the program and managed configuration')
check((APP / 'personal-notes.json').read_text(encoding='utf-8') == '{"keep":true}' and (APP / 'personal-notes.log').read_text(encoding='utf-8') == 'keep my notes', 'normal uninstall preserves unrelated user JSON and log files')
check(not (CASE / 'Desktop/校园网共享助手.lnk').exists(), 'successful uninstall removes its desktop shortcut')
ENV.pop('GDPORTAL_FIXTURE_REGISTERED_PATH')

# Exercise both task selections in a real folder containing Chinese and spaces.
custom = CASE / '自定义 安装目录'
check(install('custom-without-desktop', custom, tasks='').returncode == 0, 'custom Chinese and space path installs with desktop task unchecked')
check(not (CASE / 'Desktop/校园网共享助手.lnk').exists(), 'unchecked desktop option creates no desktop shortcut')
check(all(hashlib.sha256((custom / name).read_bytes()).hexdigest() == expected for name, expected in manifest.items()), 'all custom-directory files match the release manifest')

def check_custom_links(skip_desktop):
    custom_panel = custom / 'Panel.ps1'
    original = custom_panel.read_bytes()
    try:
        custom_panel.write_text("param([switch]$FirstRun); [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'opened.txt'),'opened')", encoding='utf-8-sig')
        args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', shell_probe, '-InstallDir', custom]
        if skip_desktop:
            args.append('-SkipDesktop')
        result = run(args)
        check(result.returncode == 0, 'custom-directory ' + ('Start menu' if skip_desktop else 'desktop and Start menu') + ' shortcuts point to and launch the installed executable')
    finally:
        custom_panel.write_bytes(original)

check_custom_links(True)
ENV['GDPORTAL_FIXTURE_REGISTERED_PATH'] = str(custom)
check(install('custom-enable-desktop', custom, tasks='desktopicon').returncode == 0, 'repair can enable the desktop shortcut in the registered custom directory')
check_custom_links(False)
other = CASE / 'Other Installation'
check(install('registered-other-directory', other).returncode != 0 and not other.exists(), 'registered install cannot silently migrate to a different directory')
ENV.pop('GDPORTAL_FIXTURE_REGISTERED_PATH')
official = CASE / 'Chinatelecom_GDPortal/assistant'
check(install('protected-official', official).returncode != 0 and not official.exists(), 'installer refuses a directory inside the official client')
ENV['GDPORTAL_FIXTURE_REGISTERED_PATH'] = str(custom)
(custom / 'Manage.ps1').write_text('param([string]$Mode); exit 0', encoding='utf-8-sig')
check(uninstall('custom-uninstall', custom).returncode == 0, 'custom-directory uninstall succeeds')
check(not (custom / '校园网共享助手.exe').exists() and not (CASE / 'Desktop/校园网共享助手.lnk').exists() and not (CASE / 'Start Menu/校园网共享助手.lnk').exists(), 'custom uninstall removes the program and both shortcut entries')

report = {'case': str(CASE), 'passed': checks, 'networkActions': 'none; production recovery replaced by a fixture for uninstall'}
(CASE / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
(ROOT / 'validation/latest-installer.txt').write_text(str(CASE), encoding='utf-8')
print('PASS: isolated installer acceptance complete', flush=True)
