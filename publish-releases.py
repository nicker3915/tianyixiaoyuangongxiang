"""Publish the explicitly inventoried installer assets using GitHub CLI."""
import json,os,subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
root=Path(__file__).resolve().parent
gh=r'C:\Program Files\GitHub CLI\gh.exe'
repo='nicker3915/tianyixiaoyuangongxiang'
os.environ['HTTPS_PROXY']='http://127.0.0.1:29290'
def run(args):return subprocess.run([gh,*args],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=180)
records=sorted((root/'versions').glob('v*.json'),key=lambda p:tuple(map(int,p.stem[1:].split('.'))))
def publish(path):
    record=json.loads(path.read_text(encoding='utf-8'));tag='v'+record['version']
    notes='历史版本归档，导入自本地保留文件。归档时间不等于原始开发时间。\n\n'
    notes+='源码快照：'+('已保留，见 history/'+tag if record['sourceAvailable'] else '未找到，仅保留安装包和版本清单。')
    notes+='\n\n历史版本包含已知缺陷；真实校园网登录、手机联网与恢复官方软件仍需实机验收。\n\n安装包 SHA-256：\n'
    assets=[]
    for asset in record['assets']:
        if asset['name'] in [p.name for p in assets]:continue
        assets.append(Path(asset['path']));notes+='\n- '+asset['name']+': `'+asset['sha256']+'`'
    found=run(['release','view',tag,'--repo',repo])
    if found.returncode:
        result=run(['release','create',tag,'--repo',repo,'--verify-tag','--title','校园网共享助手 '+tag,'--notes',notes,*map(str,assets)])
    else:
        result=run(['release','upload',tag,'--repo',repo,'--clobber',*map(str,assets)]) if assets else found
    if result.returncode:raise RuntimeError(tag+': '+result.stderr)
    result=run(['release','edit',tag,'--repo',repo,'--draft=false'])
    if result.returncode:raise RuntimeError(tag+': '+result.stderr)
    print('Published '+tag+' ('+str(len(assets))+' installer assets)',flush=True)
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(publish,records))
