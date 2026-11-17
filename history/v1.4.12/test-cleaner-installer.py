"""Run the actual recovery wizard in a private, unconfigured fake installation.

Only the wizard interaction/admin boundary is isolated. No configured network is
created, and no real installed program, task, registry key or connection is used.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent
CASE = ROOT / 'validation' / ('cleaner-installer-' + uuid.uuid4().hex[:10])
CASE.mkdir(parents=True)
STAGE = CASE / 'input'
STAGE.mkdir()
(CASE / 'temp').mkdir()
ENV = os.environ.copy()
ENV['TEMP'] = ENV['TMP'] = str(CASE / 'temp')
ISCC = os.environ.get('ISCC') or str(Path(os.environ['LOCALAPPDATA']) / 'Programs/Antigravity IDE/resources/app/node_modules/innosetup/bin/ISCC.exe')
checks = []

def check(ok, message):
    if not ok:
        raise AssertionError(message)
    checks.append(message)
    print('PASS:', message, flush=True)

for name in ('Cleanup-Assistant.ps1', 'Cleanup.Core.ps1', 'Cleanup.Processes.ps1', 'Cleanup.Discovery.ps1', 'Lifecycle.ps1', 'Network.ps1', 'cleanup-files.json'):
    data = (ROOT / 'stage' / name).read_bytes()
    if name == 'Cleanup.Core.ps1':
        text = data.decode('utf-8-sig')
        start = text.index('function Test-CleanupAdministrator')
        end = text.index('\nfunction Restore-CleanupRecovery', start)
        text = text[:start] + 'function Test-CleanupAdministrator {return $true}\n' + text[end:]
        data = text.encode('utf-8-sig')
    if name == 'Cleanup.Discovery.ps1':
        text = data.decode('utf-8-sig') + '''
function Get-DiscoveryRegistrationRecords {
 [pscustomobject]@{Name='GDPortalShare-20261104_is1';Hive='LocalMachine';View='Registry64';DisplayName='校园网共享助手';InstallLocation=$env:GDPORTAL_CLEANER_FIXTURE_TARGET;UninstallString=''}
}
function Get-DiscoveryTaskRecords {}
function Get-DiscoveryProcessRecords {}
function Get-DiscoveryShortcutRecords {}
function Get-DiscoveryDefaultRoots {}
'''
        data = text.encode('utf-8-sig')
    (STAGE / name).write_bytes(data)

text = (ROOT / 'cleanup.iss').read_text(encoding='utf-8-sig')
text = text.replace('PrivilegesRequired=admin', 'PrivilegesRequired=lowest\nUseSetupLdr=no')
text = text.replace('Source: "stage\\', 'Source: "' + str(STAGE) + '\\')
text = re.sub(r'(?m)^OutputDir=.*$', lambda _: 'OutputDir=' + str(CASE), text)
text = re.sub(r'(?m)^OutputBaseFilename=.*$', 'OutputBaseFilename=fixture-cleaner', text)
text = re.sub(r'function InitializeSetup: Boolean;.*?\nend;', 'function InitializeSetup: Boolean;\nbegin\n  Result := True;\nend;', text, flags=re.S)
# Production rejects silent cleanup and has explicit user pages. The harness
# validates through PrepareToInstall; suppress interactive page guards entirely
# so a deliberate protected-path negative case cannot leak a desktop dialog.
text = re.sub(r'function NextButtonClick\(CurPageID: Integer\): Boolean;.*?(?=\nprocedure CurPageChanged)', 'function NextButtonClick(CurPageID: Integer): Boolean;\nbegin\n  Result := True;\nend;\n', text, flags=re.S)
text += '''
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  DiscoverOldInstallations(nil);
  if CandidateList.Items.Count <> 1 then begin
    Result := 'Fixture automatic discovery failed';
    Exit;
  end;
  PreviewSucceeded := RunCleanup('Preview');
  if not PreviewSucceeded then Result := LastSummary;
end;
'''
(CASE / 'fixture.iss').write_text(text, encoding='utf-8-sig')
result = subprocess.run([ISCC, '/Q', str(CASE / 'fixture.iss')], cwd=ROOT, env=ENV, capture_output=True, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)
if result.returncode:
    raise RuntimeError(result.stdout + result.stderr)

def make_target(name):
    target = CASE / name
    target.mkdir()
    (target / 'app-identity.json').write_text('{"ProductId":"GDPortalShare","Schema":1,"Version":"1.4.1"}', encoding='utf-8')
    (target / 'Panel.ps1').write_text('fictional, never executed', encoding='utf-8')
    (target / 'unins000.exe').write_bytes(b'damaged fake uninstaller')
    return target

def clean(target, label, automatic=False):
    args = [str(CASE / 'fixture-cleaner.exe'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(CASE / (label + '.log'))]
    if not automatic:
        args.append('/TARGET=' + str(target))
    env = ENV.copy()
    env['GDPORTAL_CLEANER_FIXTURE_TARGET'] = str(target)
    return subprocess.run(args, cwd=CASE, env=env, capture_output=True, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)

external = CASE / 'untouched.txt'
external.write_text('must remain', encoding='utf-8')
untouched_hash = hashlib.sha256(external.read_bytes()).hexdigest()
target = make_target('Broken Old App')
check(clean(target, 'broken-old', automatic=True).returncode == 0, 'wizard automatically discovers a lost installation and cleans its broken uninstaller')
check(not target.exists(), 'standalone wizard removes all recognized target files and the empty app directory')
check(hashlib.sha256(external.read_bytes()).hexdigest() == untouched_hash, 'standalone wizard leaves unrelated external files intact')

target = make_target('App With User File')
(target / 'my-notes.txt').write_text('keep my file', encoding='utf-8')
check(clean(target, 'user-file').returncode == 0, 'standalone wizard supports preserving unknown user files')
check((target / 'my-notes.txt').read_text(encoding='utf-8') == 'keep my file', 'unknown user file survives actual wizard execution')
check(not (target / 'Panel.ps1').exists() and not (target / 'unins000.exe').exists(), 'recognized program and damaged uninstaller are removed')
check((target / '.gdportalshare-cleaned').read_text(encoding='utf-8') == 'GDPortalShare-20261104-cleaned-v1', 'cleaned directory marker permits a later reinstall')

target = make_target('Missing Recovery')
(target / 'settings.json').write_text('{"fixture":true}', encoding='utf-8')
before = {p.name: p.read_bytes() for p in target.iterdir()}
check(clean(target, 'missing-backup').returncode != 0, 'wizard refuses cleanup when configured recovery data is missing')
check(all((target / n).read_bytes() == data for n, data in before.items()), 'refused cleanup preserves every existing target file')
check(clean(Path(os.environ['SystemRoot']), 'protected').returncode != 0, 'wizard rejects a protected operating-system target')

# A hidden old UI is not a prerequisite the user must locate and exit manually.
# Both workers below are harmless executables created only inside this fixture.
source=CASE/'HiddenUi.cs'
source.write_text('class P { static void Main() { System.Threading.Thread.Sleep(90000); } }',encoding='utf-8-sig')
worker=CASE/'HiddenUi.exe'
compiler=Path(os.environ['SystemRoot'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
compiled=subprocess.run([str(compiler),'/nologo','/target:winexe','/out:'+str(worker),str(source)],capture_output=True,timeout=30,creationflags=subprocess.CREATE_NO_WINDOW)
if compiled.returncode:raise RuntimeError(compiled.stdout+compiled.stderr)
target=make_target('Lost Hidden App')
foreign=make_target('Unrelated Running App')
for folder in (target,foreign):(folder/'校园网共享助手.exe').write_bytes(worker.read_bytes())
owned_process=subprocess.Popen([str(target/'校园网共享助手.exe')],cwd=CASE,creationflags=subprocess.CREATE_NO_WINDOW)
foreign_process=subprocess.Popen([str(foreign/'校园网共享助手.exe')],cwd=CASE,creationflags=subprocess.CREATE_NO_WINDOW)
try:
    check(clean(target,'hidden-old',automatic=True).returncode == 0,'automatically found hidden old UI is closed after confirmation without manual exit')
    owned_process.wait(timeout=5)
    check(not target.exists(),'former hidden application can remove its own installed files')
    check(foreign_process.poll() is None and (foreign/'校园网共享助手.exe').exists(),'same-name application in another directory remains running and untouched')
finally:
    for process in (owned_process,foreign_process):
        if process.poll() is None:process.terminate()
        process.wait(timeout=10)

(CASE / 'report.json').write_text(json.dumps({'case': str(CASE), 'passed': checks, 'networkActions': 'none; targets contain no network configuration'}, ensure_ascii=False, indent=2), encoding='utf-8')
(ROOT / 'validation/latest-cleaner-installer.txt').write_text(str(CASE), encoding='utf-8')
print('PASS: independent recovery wizard acceptance complete', flush=True)
