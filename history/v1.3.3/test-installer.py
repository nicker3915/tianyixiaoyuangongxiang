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
run_section = '[Run]\nFilename: "' + str(probe) + '"; Parameters: """' + str(CASE / 'run-marker.txt') + '"""; Check: IsPayloadVerified; Flags: postinstall runhidden waituntilterminated\n'
text = re.sub(r'\[Run\].*?(?=\[UninstallDelete\])', lambda _: run_section, text, flags=re.S)
# Deliberate corruption occurs only in this fixture, after extraction and before
# the unchanged production verification routine.
text = text.replace('    VerifyInstalledPayload;', "    if FileExists(ExpandConstant('{src}\\corrupt-test.flag')) then\n      SaveStringToFile(ExpandConstant('{app}\\Network.ps1'), 'fixture corruption', False);\n    VerifyInstalledPayload;")
(CASE / 'fixture.iss').write_text(text, encoding='utf-8-sig')
result = run([ISCC, '/Q', CASE / 'fixture.iss'])
if result.returncode:
    raise RuntimeError(result.stdout + result.stderr)

def install(label):
    return run([CASE / 'fixture.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(CASE / (label + '.log'))])

manifest = {}
for line in (ROOT / 'payload.sha256').read_text(encoding='utf-8').splitlines():
    expected, name = line.split('  ', 1)
    manifest[name] = expected

check(install('fresh').returncode == 0, 'fresh install succeeds')
check(all(hashlib.sha256((APP / name).read_bytes()).hexdigest() == expected for name, expected in manifest.items()), 'all 34 installed files match final manifest')
check((CASE / 'run-marker.txt').exists(), 'verified installation executes permitted Run action')
(CASE / 'run-marker.txt').unlink()

# A stopped/broken install can be repaired even without a pause marker, after the user has stopped sharing and exited the application.
(APP / 'settings.json').write_text('{"fixture":true}', encoding='utf-8')
(APP / 'original-startup.json').write_text('{"fixtureBaseline":true}', encoding='utf-8')
settings = (APP / 'settings.json').read_bytes()
backup = (APP / 'original-startup.json').read_bytes()
(APP / 'Panel.ps1').write_text('broken panel fixture', encoding='utf-8')
check(install('repair').returncode == 0, 'repair does not depend on the old pause marker')
check((APP / 'settings.json').read_bytes() == settings and (APP / 'original-startup.json').read_bytes() == backup, 'repair preserves account settings and recovery baseline')
check(hashlib.sha256((APP / 'Panel.ps1').read_bytes()).hexdigest() == manifest['Panel.ps1'], 'repair restores damaged panel')

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
kernel.CreateMutexW.restype = ctypes.c_void_p
kernel.CloseHandle.argtypes = [ctypes.c_void_p]
mutex = kernel.CreateMutexW(None, False, 'Local\\GDPortalShare-Panel')
try:
    check(bool(mutex), 'fixture panel mutex created')
    check(install('busy-panel').returncode != 0, 'upgrade refuses an open panel')
finally:
    kernel.CloseHandle(mutex)

mutex = kernel.CreateMutexW(None, False, 'Global\\GDPortalShare-Operation')
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
shell_probe.write_text(r'''$ErrorActionPreference='Stop'
$app=Join-Path $PSScriptRoot 'Installed App'
$shell=New-Object -ComObject WScript.Shell
foreach($folder in @('Desktop','Start Menu')){
 $link=Join-Path (Join-Path $PSScriptRoot $folder) '校园网共享助手.lnk'
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
result = run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', shell_probe])
check(result.returncode == 0, 'desktop and Start menu targets resolve correctly and the installed main executable launches')
panel.write_bytes(panel_bytes)

# Keep the production uninstall callback and its failure gating, but replace its
# network-affecting Manage implementation with an isolated result fixture.
(APP / 'original-startup.json').unlink()
(APP / 'Manage.ps1').write_text("param([string]$Mode); if(Test-Path (Join-Path $PSScriptRoot 'restore-fail.flag')){exit 9}; exit 0", encoding='utf-8-sig')
(APP / 'restore-fail.flag').write_text('test', encoding='ascii')
def uninstall(label):
    return run([APP / 'unins000.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(CASE / (label + '.log'))])
result = uninstall('uninstall-failure')
check(result.returncode != 0, 'failed recovery aborts uninstall')
check((APP / '校园网共享助手.exe').exists() and (APP / 'settings.json').read_bytes() == settings and (APP / 'unins000.exe').exists(), 'failed uninstall retains program settings and retry entry')
(APP / 'restore-fail.flag').unlink()
result = uninstall('uninstall-retry')
check(result.returncode == 0 and not (APP / '校园网共享助手.exe').exists() and not (APP / 'settings.json').exists(), 'successful retry removes the program and managed configuration')

report = {'case': str(CASE), 'passed': checks, 'networkActions': 'none; production recovery replaced by a fixture for uninstall'}
(CASE / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
(ROOT / 'validation/latest-installer.txt').write_text(str(CASE), encoding='utf-8')
print('PASS: isolated installer acceptance complete', flush=True)
