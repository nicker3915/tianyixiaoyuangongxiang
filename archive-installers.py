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
print('Verified installers copied',flush=True)
