"""Package only whitelisted clean files and verify the final public artifacts."""
from pathlib import Path
import hashlib
import json
import re
import os
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
DEST = Path(os.environ['USERPROFILE']) / 'Desktop/校园网共享助手-1.4.5'
DEST.mkdir(exist_ok=True)
APP = '校园网共享助手-1.4.5-安装程序.exe'
CLEANER = '校园网共享助手-清理与卸载.exe'
for name in (APP, CLEANER):
    shutil.copyfile(ROOT / 'dist' / name, DEST / name)
shutil.copyfile(ROOT / 'readme.txt', DEST / '使用说明.txt')
shutil.copyfile(ROOT / 'stage/Client/portal/assets/LICENSE', DEST / '第三方许可证.txt')
shutil.copyfile(ROOT / 'panel-preview-1.4.5.png', DEST / '界面预览.png')
sha = lambda data: hashlib.sha256(data).hexdigest()
installer_report = json.loads((Path((ROOT / 'validation/latest-installer.txt').read_text(encoding='utf-8')) / 'report.json').read_text(encoding='utf-8'))
cleaner_report = json.loads((Path((ROOT / 'validation/latest-cleaner-installer.txt').read_text(encoding='utf-8')) / 'report.json').read_text(encoding='utf-8'))
verification=(ROOT / 'validation/final-checks.txt').read_text(encoding='utf-8-sig')
assert 'FINAL TESTS COMPLETE' in verification
assert 'authentication route conflicts are refused before mutation' in verification
cleanup_count=int(re.search(r'PASS: (\d+) cleanup assertions',verification).group(1))
discovery_count=int(re.search(r'PASS: (\d+) read-only discovery assertions',verification).group(1))

intro = '''校园网共享助手 1.4.5

首次使用：运行“校园网共享助手-1.4.5-安装程序.exe”。打开助手后，先选 Wi-Fi 或网线，点击“检测网络”，再填写账号并启动共享。手机请关闭移动数据后连接热点测试。选择网线时，网线仍是上网来源；Windows 热点仍须保持 Wi-Fi 无线电开启以发射信号。

旧版打不开、卸载失败或挡住新版：
1. 直接运行这个发布文件夹中的“校园网共享助手-清理与卸载.exe”，无需先找到或退出旧助手。
2. 工具自动查找安装记录、助手任务、进程路径和快捷方式，并列出旧版候选目录；核对要清理的那一项。也可点击“自动查找旧版”刷新。
3. 查看检查结果，确认后工具才关闭归属明确的旧面板、恢复并清理，可能短暂断网。即使旧 unins000.exe 损坏也无需运行它；恢复资料完整时工具会使用自己携带的恢复组件。
4. 清理成功后重新安装新版。安装向导也提供旧版清理入口。

正常使用新版时，可点击“一键清理与卸载”。它会在程序目录外运行，确认后可移除助手自身。仅打开清理工具、查看范围或取消，不会提前改动共享和配置。面板如已关闭可重新打开。

工具只删除确认属于助手的内容，未知文件会保留。恢复备份缺失或检查失败时，不会盲目清空网络；请保留原文件和提示供维护人员处理。无法重建已经删除的原恢复备份。

这一份安装包同时支持 Wi-Fi 和有线。普通使用者无需 Python、编译器或运行维护源码。需要 Windows 10 1809及以上/Windows 11、Intel/AMD 64位、兼容广东天翼认证及移动热点的网卡与驱动。

当前文件没有可信数字签名，Windows 安全策略仍可能提示或阻止运行。不要为安装关闭防护。具体检查结果见“验证报告.md”。

分享时发送“分享版.zip”或安装程序与独立清理 EXE。不要分享安装后的 Client、配置、日志、账号、会话或恢复备份。
'''
(DEST / '开始使用.txt').write_text(intro, encoding='utf-8-sig')
report = f'''# 校园网共享助手 1.4.5 验证报告

日期：2026-11-14。

## 新增与修复

- 主界面先明确选择 Wi-Fi / 网线，再运行只读检测；未完成前置确认不能直接保存账号或启动共享。
- 有线模式明确说明：Wi-Fi 无线电用于发射 Windows 热点；关闭 Windows Wi-Fi 开关会关闭热点，但不会把校园上游改成 Wi-Fi。
- 新建配置不再改变全局 IPv4 网卡跃点；旧版本写入的跃点仍能按其原恢复备份在停止或卸载时恢复。
- 认证专用路由先统一预检；发现 VPN、代理或其他工具已有不同路由时拒绝启动且不删除对方路由，避免部分网络流量被静默改道。
- 新增手动网络测速：最多约 25 秒、下载 8 MiB 加上传 2 MiB，绑定已选择的校园上游；显示电脑下载/上传速度、网关延迟/丢包、热点状态和测速期间热点流量，不自动运行或改网络设置。
- 检测识别所选上游的 IPv4、网关、无线发射端和 Windows 热点能力；无法确认时显示“待实测”，不把网卡已连接当作互联网或手机联网成功。
- 不再通过单选按钮重写已有网卡绑定和首次恢复备份；需要换网卡时先恢复清理，再重新设置。
- 独立清理工具新增“自动查找旧版”，从正式安装记录、明确的助手任务/进程路径、快捷方式和默认目录发现候选，无需用户先找到旧程序。确认前只读，确认后才关闭已复核路径、创建时间和参数的目标面板。
- 保留独立清理 EXE 和安装前清理入口，旧卸载器损坏也可使用可信的新恢复组件处理。主面板和开始菜单将清理工具复制到目录外运行，以便移除本体。
- 恢复失败或备份缺失保留现场；只清理归属明确的程序、任务、路由、快捷方式及卸载记录。未知文件保留，清理后的目录可重新安装。
- 移除旧版清理脚本按端口结束程序、重置所有网卡等宽泛操作。普通卸载也只清理明确命名的自有配置和日志。

## 本轮结果

| 检查 | 结果 |
| --- | --- |
| 主安装包内置文件 | 44 个文件逐项 SHA-256 匹配 |
| 独立清理工具内置文件 | 7 个可信组件逐项 SHA-256 匹配 |
| 旧版自动发现 | {discovery_count} 项只读断言通过，含登记路径缺失、卸载路径回退、多来源合并和无关程序排除 |
| 前置选择和网络检测 | Wi-Fi/有线筛选、所选上游查询、未知/不支持能力和无写操作测试通过 |
| 账号表单 | 类型过滤、空字段、密码显示/遮挡、特殊字符确认及取消通过 |
| 面板/托盘/卸载移交 | 47 项断言通过，含选择/检测不改配置备份，外部清理和常规卸载均不提前 Stop |
| 清理核心 | {cleanup_count} 项隔离断言通过：产品归属、先恢复后删、损坏卸载器、失败重试、缺备份拒绝、未知内容保留、根路径/链接保护及敏感配置报错脱敏 |
| 路由安全 | 隔离验证冲突路由会在启动前拒绝，且不新增、不删除外部路由；匹配路由复用，无冲突时仅记录助手自己的 /32 路由 |
| 测速安全 | 隔离验证测速仅由用户点击触发，下载限时 12 秒/8 MiB、上传限时 12 秒/2 MiB、绑定所选上游，且不调用网卡、路由、DNS、热点、认证或任务修改命令 |
| 主安装器实际隔离执行 | {len(installer_report['passed'])} 项通过：新装、覆盖修复、旧残留阻止盲目接管、清理后重装、损坏拦截、卸载失败保留与重试、未知用户 JSON/log 保留 |
| 独立清理向导实际隔离执行 | {len(cleaner_report['passed'])} 项通过：未配置假目录的坏卸载器清理、本体文件移除、未知内容保留、缺备份拒绝、系统目录拒绝 |
| 后台等待与守护 | 编译入口、互斥、后台进程存活时等待返回、13 项守护决策及原恢复模拟通过 |

测试只使用工程内的虚构目录、账号与模拟恢复；没有清理当前用户的真实旧版、停止现有校园认证或修改真实网络。独立向导夹具隔离管理员边界，并仅处理未配置假目录；实际已配置网络的恢复由核心模拟测试验证，仍需在目标电脑授权实测。

用户此前已反馈另一台电脑 Wi-Fi 共享及本机有线共享可用。1.4.5 的完整安装、校园认证、手机关闭移动数据后的联网、真实重启和完整清理后官方登录，本轮未重新实测，不能由离线结果推定全部通过。

## 分发与 Windows 防护

独立清理工具能处理仍有可验证恢复资料的旧安装。若原配置和备份都已被删除但仍有任务，工具不能重建原值，会停止并提示维护，而不会猜测恢复。

最终发布目录（包括 EXE 与 ZIP）使用本机 Windows Defender 自定义扫描，结果未发现威胁。扫描不改变实时保护、排除项、SmartScreen、智能应用控制或系统策略。此结果不保证其他设备或未来病毒库都放行。

当前安装器、自有启动器及清理工具仍未取得可信数字签名。正常管理员授权提示仍会出现，SmartScreen/智能应用控制也可能提示或阻止。可信签名和正常分发信誉需要另行建立。

参考：[Microsoft SmartScreen 开发者说明](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)。

## 指纹

安装包 SHA-256：`{sha((DEST / APP).read_bytes())}`

清理工具 SHA-256：`{sha((DEST / CLEANER).read_bytes())}`

其他文件指纹见同目录 SHA256.txt。分享包内两个 EXE 与独立文件完全一致，源码包仅含明确清单中的干净文件。
'''
(DEST / '验证报告.md').write_text(report, encoding='utf-8-sig')

top = ['build.py','setup.iss','cleanup.iss','payload-files.iss','payload-checks.iss','payload.sha256','cleanup-bundle.sha256','upstream.zip','readme.txt','verify-binary.py','维护说明.md','package-release.py','test-offline.ps1','test-network-selection.ps1','test-lifecycle.ps1','test-ui.ps1','test-panel.ps1','test-entrypoints.ps1','test-recovery-wait.ps1','test-cleanup.ps1','test-discovery.ps1','test-routing-safety.ps1','test-speed.ps1','test-installer.py','test-cleaner-installer.py']
sources = {n:(ROOT/n).read_bytes() for n in top}
for p in (ROOT / 'payload').iterdir():
    if p.is_file() and (p.suffix in ('.ps1','.cs') or p.name == 'cleanup-files.json'):
        sources['payload/'+p.name] = p.read_bytes()
for row in (ROOT / 'payload.sha256').read_text(encoding='utf-8').splitlines():
    expected,name = row.split('  ',1); data=(ROOT/'stage'/name).read_bytes(); assert sha(data)==expected
    sources['stage/'+name]=data
assert not any(Path(n).name in ('settings.json','original-startup.json','ESurfingClient.json') or n.endswith('.log') for n in sources)
sources['SOURCE-SHA256.txt']=''.join(sha(data)+'  '+name+'\n' for name,data in sorted(sources.items())).encode('utf-8')
maintenance=DEST/'校园网共享助手-1.4.5-维护源码.zip'
with zipfile.ZipFile(maintenance,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name,data in sorted(sources.items()):z.writestr('维护源码/'+name,data)
share_names=[APP,CLEANER,'开始使用.txt','使用说明.txt','第三方许可证.txt','验证报告.md','界面预览.png']
share=DEST/'校园网共享助手-1.4.5-分享版.zip'
with zipfile.ZipFile(share,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for name in share_names:z.write(DEST/name,'校园网共享助手-1.4.5/'+name)
    z.writestr('校园网共享助手-1.4.5/SHA256.txt',''.join(sha((DEST/n).read_bytes())+'  '+n+'\n' for n in share_names).encode('utf-8'))
with zipfile.ZipFile(share) as z:
    for name in (APP,CLEANER):assert z.read('校园网共享助手-1.4.5/'+name)==(DEST/name).read_bytes()
with zipfile.ZipFile(maintenance) as z:
    for name,data in sources.items():assert z.read('维护源码/'+name)==data

platform=Path(os.environ['ProgramData'])/'Microsoft/Windows Defender/Platform'
scanner=next(p/'MpCmdRun.exe' for p in sorted(platform.glob('4.*'),reverse=True) if (p/'MpCmdRun.exe').exists())
scan=subprocess.run([str(scanner),'-Scan','-ScanType','3','-File',str(DEST),'-DisableRemediation'],capture_output=True,timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
output=(scan.stdout+scan.stderr).decode('utf-8',errors='replace')
print(output.strip(),flush=True)
if scan.returncode or 'no threats' not in output.lower():raise RuntimeError('Investigate final Defender result before distributing')
(ROOT/'validation/final-defender-scan.txt').write_text(output,encoding='utf-8')
(DEST/'SHA256.txt').write_text(''.join(sha(p.read_bytes())+'  '+p.name+'\n' for p in sorted(DEST.iterdir()) if p.is_file() and p.name!='SHA256.txt'),encoding='utf-8')
print(json.dumps({'release':str(DEST),'installerBytes':(DEST/APP).stat().st_size,'cleanerBytes':(DEST/CLEANER).stat().st_size,'sourceFiles':len(sources)},ensure_ascii=False))
