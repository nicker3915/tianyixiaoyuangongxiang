"""Create the clean 1.3.3 distribution and scan it without changing protection."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
RELEASE = Path(os.environ['USERPROFILE']) / 'Desktop/校园网共享助手-1.3.3-最终分发'
RELEASE.mkdir(exist_ok=True)
EXE = '校园网共享助手-1.3.3-安装程序.exe'
shutil.copyfile(ROOT / 'dist' / EXE, RELEASE / EXE)
shutil.copyfile(ROOT / 'stage/Client/portal/assets/LICENSE', RELEASE / '第三方许可证.txt')
digest = lambda data: hashlib.sha256(data).hexdigest()
exe_hash = digest((RELEASE / EXE).read_bytes())
status_query = "$d=Get-MpComputerStatus;$r=[ordered]@{};foreach($n in @('AMServiceEnabled','AntivirusEnabled','RealTimeProtectionEnabled','AntivirusSignatureVersion','SmartAppControlState')){$r[$n]=$d.CimInstanceProperties[$n].Value};$r|ConvertTo-Json -Compress"
status_result = subprocess.run(['powershell.exe', '-NoProfile', '-Command', status_query],
                               capture_output=True, timeout=30, check=True,
                               creationflags=subprocess.CREATE_NO_WINDOW)
status = json.loads(status_result.stdout.decode('utf-8-sig'))
fixture = json.loads((Path((ROOT / 'validation/latest-installer.txt').read_text(encoding='utf-8')) / 'report.json').read_text(encoding='utf-8'))

platforms = Path(os.environ['ProgramData']) / 'Microsoft/Windows Defender/Platform'
scanner = next(p / 'MpCmdRun.exe' for p in sorted(platforms.glob('4.*'), reverse=True) if (p / 'MpCmdRun.exe').exists())
def scan(target):
    result = subprocess.run([str(scanner), '-Scan', '-ScanType', '3', '-File', str(target), '-DisableRemediation'],
                            capture_output=True, timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    if result.returncode != 0 or 'no threats' not in output.lower():
        raise RuntimeError('Defender scan requires investigation: ' + output)
    print(output.strip(), flush=True)
    return output

scan(RELEASE / EXE)
report = f'''# 校园网共享助手 1.3.3 验证报告

检查日期：2026-11-13。此报告区分使用者反馈、当前版本的隔离检查以及未执行的实机项目。

## 结论

这一份 EXE 同时包含 Wi-Fi 和有线接入支持，可作为 Windows x64 独立安装包交付。普通使用者不需要安装 Python 或编译工具。适用前提是广东天翼认证兼容、无线网卡及驱动支持 Windows 移动热点、使用者能够允许必要的管理员授权，且目标电脑安全策略允许该程序运行。

使用者已反馈：另一台电脑通过校园 Wi-Fi 后能共享网络，本电脑通过网线后能共享网络。这是已有方案的实机证据；本次没有再次接管这台电脑的网络，也没有把两项反馈扩大成新版本所有目标电脑都已经实测。

## 本次优化

- 安装后逐项核对全部 34 个发行文件的 SHA-256。故意损坏组件的测试证明：安装器返回非零、不自动启动助手，并能指出损坏组件；重新安装可修复。
- 覆盖安装前检查助手窗口和设置/恢复操作的占用，提示先停止并退出。不会强行关闭校园认证。此检查不等于确认所有后台共享已停止，使用者仍需按说明先正常停止共享。
- 更新安装包、面板与主 EXE 的版本信息及卸载图标；保留正式安装标识、安装路径、账号和首次恢复备份。
- 更正更换连接方式的说明：「修改校园账号」不会改换网卡绑定；换连接需先正常卸载恢复再设置。
- 重新生成 UTF-8 中文文件名的分享和源码包，移除旧安装包、编译器安装文件、运行数据和机器专属配置。

## 当前版本检查结果

| 检查 | 结果及边界 |
| --- | --- |
| 收到的 EXE 与分享 ZIP 内 EXE | 字节完全一致 |
| 收到的 1.3.2 内置文件 | 与其 34 项构建清单匹配 |
| 1.3.3 内置文件 | 全部 34 项 SHA-256 匹配，无清单外数据 |
| 认证、凭据、网络及恢复逻辑 | 六个相关模块与收到的 1.3.2 标准化文本完全一致 |
| 脚本与守护决策 | 语法、13 项守护决策、CIDR、虚构凭据往返、任务/恢复模拟通过 |
| Wi-Fi / 有线选择 | 候选枚举、网络绑定、更新账号、启动与恢复匹配测试通过 |
| 表单 | 空字段、密码遮挡/显示、确认、特殊字符及取消通过 |
| 面板与托盘 | 30 项隔离行为断言通过，包含停止、恢复、拒绝重复操作、取消退出、失败保留与成功退出 |
| 启动器 | 默认入口、参数分发、跨进程互斥及后台进程存活时启动器退出通过 |
| 恢复等待 | 原树等待问题可复现，当前独立等待可返回；测试夹具隔离 UAC 和输出管道，真实 UAC 未在此轮重新验收 |
| 隔离安装 | {len(fixture['passed'])} 项检查通过：新装、覆盖修复、34 个文件完整、保留设置/备份、占用拦截、损坏拦截及重试 |
| 快捷方式 | 桌面和开始菜单的目标、参数及工作目录正确，解析后的目标 EXE 实际启动成功；不代表所有机器的 Explorer 或安全策略已经放行 |
| 隔离卸载 | 用无网络副作用的恢复替身验证：恢复失败不删除程序/设置/卸载入口，重试成功后完成删除 |

隔离安装将权限、目标目录、安装注册和自动启动动作放在私有测试环境，不修改真实校园认证、计划任务或网络。它不等于在本机真正卸载后登录官方软件。

## Windows 防护和签名

最终 EXE 已使用本机 Microsoft Defender 自定义扫描，返回码 0，未发现威胁。外层 ZIP 与维护源码 ZIP 在生成后也纳入最终目录扫描。扫描使用 `-DisableRemediation` 仅禁止本次自定义扫描自动处置文件，不关闭实时保护、不修改排除项或安全策略，压缩内容也参与扫描。

- 病毒库版本：{status['AntivirusSignatureVersion']}。
- 本次读取到实时保护启用：{status['RealTimeProtectionEnabled']}；防病毒启用：{status['AntivirusEnabled']}。
- 本机智能应用控制状态：{status['SmartAppControlState']}。没有在开启智能应用控制的干净电脑上测试放行。
- 安装包及自有主程序尚无可信数字签名，未提供可用的代码签名身份；SHA-256 校验不能替代发布者签名。
- 「未发现威胁」不等于 SmartScreen 信誉已建立，也不保证其他防护产品、未来病毒库或单位策略放行。正常管理员授权提示仍会出现。

微软说明，SmartScreen 同时考虑文件与发布者信誉，新文件即使已签名也可能提示；智能应用控制可能阻止缺乏信誉的未签名程序。减少此类拦截需要可信签名及正常分发信誉，不能承诺通过重新打包实现所有电脑零提示。

资料：

- [Microsoft SmartScreen 开发者说明](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)
- [Microsoft 误报提交入口](https://www.microsoft.com/en-us/wdsi/filesubmission)

## 尚未在本轮重新执行

- 新版在另一台电脑从安装、真实校园认证到手机关闭移动数据后联网的完整流程。
- 新版真实重启后的自动恢复。
- 新版真正卸载后，通过原官方客户端重新登录并访问网页。
- 不同学校、不同网卡和驱动、ARM，以及智能应用控制开启的电脑。

上述项目不得由离线或隔离结果推定通过。当前仍保留既有电脑的正常连接。

## 文件指纹

安装包：`{EXE}`

SHA-256：`{exe_hash}`

其余分发文件指纹见同目录 `SHA256.txt`。分享 ZIP 中的 EXE 与此独立 EXE 完全一致。维护源码不含已安装的账号、密码、会话、日志或恢复备份。
'''
(RELEASE / '验证报告.md').write_text(report, encoding='utf-8-sig')

top = ['build.py', 'setup.iss', 'payload-files.iss', 'payload-checks.iss', 'payload.sha256', 'readme.txt', 'upstream.zip', 'verify-binary.py', '维护说明.md',
       'test-offline.ps1', 'test-network-selection.ps1', 'test-lifecycle.ps1', 'test-ui.ps1', 'test-panel.ps1', 'test-entrypoints.ps1', 'test-recovery-wait.ps1', 'test-installer.py', 'package-release.py']
files = {name: (ROOT / name).read_bytes() for name in top}
for p in (ROOT / 'payload').iterdir():
    if p.is_file() and p.suffix in ('.ps1', '.cs'):
        files['payload/' + p.name] = p.read_bytes()
for line in (ROOT / 'payload.sha256').read_text(encoding='utf-8').splitlines():
    expected, name = line.split('  ', 1)
    data = (ROOT / 'stage' / name).read_bytes()
    assert digest(data) == expected
    files['stage/' + name] = data
assert not any(Path(n).name in ('settings.json', 'original-startup.json', 'ESurfingClient.json', 'ESurfingClient.json.pending') or n.endswith('.log') for n in files)
files['SOURCE-SHA256.txt'] = ''.join(digest(data) + '  ' + name + '\n' for name, data in sorted(files.items())).encode('utf-8')
maintenance = RELEASE / '校园网共享助手-1.3.3-维护源码.zip'
with zipfile.ZipFile(maintenance, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name, data in sorted(files.items()):
        z.writestr('维护源码/' + name, data)
with zipfile.ZipFile(maintenance) as z:
    assert all(z.read('维护源码/' + name) == data for name, data in files.items())

share_names = [EXE, '开始使用.txt', '第三方许可证.txt', '验证报告.md']
share = RELEASE / '校园网共享助手-1.3.3-分享版.zip'
with zipfile.ZipFile(share, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in share_names:
        z.write(RELEASE / name, '校园网共享助手-1.3.3/' + name)
    manifest = ''.join(digest((RELEASE / name).read_bytes()) + '  ' + name + '\n' for name in share_names)
    z.writestr('校园网共享助手-1.3.3/SHA256.txt', manifest.encode('utf-8'))
with zipfile.ZipFile(share) as z:
    assert z.read('校园网共享助手-1.3.3/' + EXE) == (RELEASE / EXE).read_bytes()
scan_result = scan(RELEASE)
(ROOT / 'validation/final-defender-scan.txt').write_text(scan_result, encoding='utf-8')
rows = [digest(p.read_bytes()) + '  ' + p.name for p in sorted(RELEASE.iterdir()) if p.is_file() and p.name != 'SHA256.txt']
(RELEASE / 'SHA256.txt').write_text('\n'.join(rows) + '\n', encoding='utf-8')
print(json.dumps({'release': str(RELEASE), 'installerBytes': (RELEASE / EXE).stat().st_size, 'installerSHA256': exe_hash, 'maintenanceFiles': len(files), 'checks': len(fixture['passed'])}, ensure_ascii=False))
