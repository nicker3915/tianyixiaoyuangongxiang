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

for name in ('Cleanup-Assistant.ps1', 'Cleanup.Core.ps1', 'Lifecycle.ps1', 'Network.ps1', 'cleanup-files.json'):
    data = (ROOT / 'stage' / name).read_bytes()
    if name == 'Cleanup.Core.ps1':
        text = data.decode('utf-8-sig')
        start = text.index('function Test-CleanupAdministrator')
        end = text.index('\nfunction Restore-CleanupRecovery', start)
        text = text[:start] + 'function Test-CleanupAdministrator {return $true}\n' + text[end:]
        data = text.encode('utf-8-sig')
    (STAGE / name).write_bytes(data)

text = (ROOT / 'cleanup.iss').read_text(encoding='utf-8-sig')
text = text.replace('PrivilegesRequired=admin', 'PrivilegesRequired=lowest\nUseSetupLdr=no')
text = text.replace('Source: "stage\\', 'Source: "' + str(STAGE) + '\\')
text = re.sub(r'(?m)^OutputDir=.*$', lambda _: 'OutputDir=' + str(CASE), text)
text = re.sub(r'(?m)^OutputBaseFilename=.*$', 'OutputBaseFilename=fixture-cleaner', text)
text = re.sub(r'function InitializeSetup: Boolean;.*?\nend;', 'function InitializeSetup: Boolean;\nbegin\n  Result := True;\nend;', text, flags=re.S)
text += '''
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
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

def clean(target, label):
    return subprocess.run([str(CASE / 'fixture-cleaner.exe'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TARGET=' + str(target), '/LOG=' + str(CASE / (label + '.log'))],
                          cwd=CASE, env=ENV, capture_output=True, timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)

external = CASE / 'untouched.txt'
external.write_text('must remain', encoding='utf-8')
untouched_hash = hashlib.sha256(external.read_bytes()).hexdigest()
target = make_target('Broken Old App')
check(clean(target, 'broken-old').returncode == 0, 'standalone wizard cleans an unconfigured product with a broken uninstaller')
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

(CASE / 'report.json').write_text(json.dumps({'case': str(CASE), 'passed': checks, 'networkActions': 'none; targets contain no network configuration'}, ensure_ascii=False, indent=2), encoding='utf-8')
(ROOT / 'validation/latest-cleaner-installer.txt').write_text(str(CASE), encoding='utf-8')
print('PASS: independent recovery wizard acceptance complete', flush=True)
