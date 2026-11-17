import hashlib,json,shutil,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
for record in (root/'versions').glob('*.json'):
    r=json.loads(record.read_text(encoding='utf-8'))
    for a in r['assets']:
        source=Path(a['path']);dest=root/'installers'/record.stem/('CampusNetworkShare-'+r['version']+'.exe')
        if dest.exists():continue
        if hashlib.sha256(source.read_bytes()).hexdigest()!=a['sha256']:raise RuntimeError('Asset changed: '+str(source))
        dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,dest)
latest=Path.home()/'Desktop/校园网共享助手-1.4.12/校园网共享助手-清理与卸载.exe'
if latest.exists():shutil.copyfile(latest,root/'installers/v1.4.12/CampusNetworkShare-Cleanup.exe')
print('Verified installers copied',flush=True)
