"""Build from a clean public client ZIP; only the explicitly listed assets are embedded."""
import hashlib, pathlib, subprocess, os, zipfile, shutil, sys, json
P=pathlib.Path(__file__).resolve().parent
S=P/'payload'
ST=P/'stage'
ST.mkdir(exist_ok=True)
A=P/'upstream.zip'
assert hashlib.sha256(A.read_bytes()).hexdigest()=='f9293d0ec1439c60690316d3d3e7821abf493c3a4c4066df23f0e63ba14d7f30'
files={}
def put(name,data):
    dest=ST/name
    dest.parent.mkdir(exist_ok=True,parents=True)
    dest.write_bytes(data)
    files[name]=hashlib.sha256(data).hexdigest()
exe='ESurfingClient-2.2.0-r4-windows-x86_64.exe'
with zipfile.ZipFile(A) as z:
    for n in z.namelist():
        if not n.endswith('/') and (n==exe or n.startswith('portal/')):
            assert '..' not in pathlib.PurePosixPath(n).parts
            put('Client/'+n,z.read(n))
assert files['Client/'+exe]=='714a8cc53c5e50a218932d0bdddf0e68570c5d9832b9b7830eac27dd85517dd7'
scripts=['Start-CampusNetwork.ps1','Watch-CampusNetwork.ps1','Campus-Recovery.ps1','Manage.ps1','Network.ps1','Lifecycle.ps1','Panel.ps1','Speed-Test.ps1','Device-SpeedServer.ps1','Check-Environment.ps1','Cleanup-Assistant.ps1','Cleanup.Core.ps1','Cleanup.Processes.ps1','Cleanup.Discovery.ps1','Clean-Conflicts.ps1']
for name in scripts:
    put(name,(S/name).read_text(encoding='utf-8-sig').encode('utf-8-sig'))
put('使用说明.txt',(P/'readme.txt').read_text(encoding='utf-8-sig').encode('utf-8-sig'))
put('app-identity.json',json.dumps({'ProductId':'GDPortalShare','Schema':1,'Version':'1.4.10'},ensure_ascii=False,separators=(',',':')).encode('utf-8'))
cleanup_name='校园网共享助手-清理与卸载.exe'
planned=set(files)|{'CampusQuietLauncher.exe','校园网共享助手.exe',cleanup_name,'cleanup-files.json','Clean-Conflicts.ps1','Check-Environment.ps1','CampusQuietLauncher.cs','免安装版使用说明.txt'}
put('cleanup-files.json',json.dumps(sorted(planned),ensure_ascii=False,indent=2).encode('utf-8-sig'))
(S/'cleanup-files.json').write_bytes((ST/'cleanup-files.json').read_bytes())
bundle_names=['Cleanup-Assistant.ps1','Cleanup.Core.ps1','Cleanup.Processes.ps1','Cleanup.Discovery.ps1','Lifecycle.ps1','Network.ps1','cleanup-files.json']
(P/'cleanup-bundle.sha256').write_text(''.join(files[n]+'  '+n+'\n' for n in bundle_names),encoding='utf-8')
iscc=os.environ.get('ISCC') or shutil.which('iscc') or str(pathlib.Path(os.environ['LOCALAPPDATA'])/'Programs/Antigravity IDE/resources/app/node_modules/innosetup/bin/ISCC.exe')
subprocess.run([iscc,'/Q',str(P/'cleanup.iss')],check=True,cwd=P)
put(cleanup_name,(P/'dist'/cleanup_name).read_bytes())
compiler=pathlib.Path(os.environ['SystemRoot'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
launcher=ST/'CampusQuietLauncher.exe'
subprocess.run([compiler,'/nologo','/target:winexe','/platform:x64','/reference:System.Windows.Forms.dll','/optimize+',f'/out:{launcher}',S/'CampusQuietLauncher.cs'],check=True)
files[launcher.name]=hashlib.sha256(launcher.read_bytes()).hexdigest()
put('校园网共享助手.exe',launcher.read_bytes())
rows=[]
for n in sorted(files):
    win=n.replace('/','\\')
    d=n.rpartition('/')[0].replace('/','\\')
    rows.append('Source: "stage\\'+win+'"; DestDir: "{app}'+ ('\\'+d if d else '')+'"; Flags: ignoreversion')
(P/'payload-files.iss').write_text('\n'.join(rows)+'\n',encoding='utf-8-sig')
(P/'payload.sha256').write_text(''.join(files[n]+'  '+n+'\n' for n in sorted(files)),encoding='utf-8')
checks=['procedure VerifyInstalledPayload;', 'begin']
for n in sorted(files):
    win=n.replace('/','\\').replace("'","''")
    checks.append("  VerifyPayloadFile('"+win+"', '"+files[n]+"');")
checks.append('end;')
(P/'payload-checks.iss').write_text('\n'.join(checks)+'\n',encoding='utf-8-sig')
subprocess.run([iscc,'/Q',str(P/'setup.iss')],check=True,cwd=P)
print('Embedded',len(files),'files.')

