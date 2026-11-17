[Setup]
AppId=GDPortalShare-20261104
AppName=校园网共享助手
AppVersion=1.3.2
DefaultDirName={autopf}\GDPortalShare
DefaultGroupName=校园网共享助手
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
UsePreviousGroup=no
AllowNoIcons=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
OutputDir=dist
OutputBaseFilename=校园网共享助手-1.3.2-WiFi与有线版-x64
UninstallDisplayName=校园网共享助手
CloseApplications=no
RestartApplications=no
SetupLogging=no
[LangOptions]
LanguageName=简体中文
LanguageID=$0804
DialogFontName=Microsoft YaHei UI
[Messages]
SetupWindowTitle=%1 安装向导
SetupAppTitle=安装
UninstallAppFullTitle=卸载 %1
WelcomeLabel1=安装 [name]
WelcomeLabel2=将校园 Wi-Fi 或有线网通过这台电脑共享给手机。%n%n先连接校园 Wi-Fi 或网线，准备好支持移动热点的无线网卡，以及你自己的广东天翼校园账号。%n%n安装文件后，将打开首次设置。保存设置才会登记登录任务，并接管已识别的官方开机项。保存后可点击“启动共享”；停止时可切回官方客户端。
ButtonNext=下一步(&N) >
ButtonBack=< 上一步(&B)
ButtonInstall=安装(&I)
ButtonCancel=取消
ButtonFinish=完成(&F)
ClickNext=点击「下一步」继续。
WizardReady=准备安装
ReadyLabel1=即将安装 [name]。
ReadyLabel2a=点击「安装」继续。
ReadyLabel2b=点击「安装」继续。
ReadyMemoDir=安装位置：
ReadyMemoGroup=开始菜单：
WizardInstalling=正在安装
InstallingLabel=正在将 [name] 安装到你的电脑。
StatusExtractFiles=正在复制文件…
StatusCreateIcons=正在创建开始菜单入口…
FinishedHeadingLabel=安装文件已就绪
FinishedLabelNoIcons=已安装 [name]。请打开开始菜单里的「校园网共享助手」。
FinishedLabel=已安装 [name]。点击「完成」后填写你自己的校园账号。
ClickFinish=点击「完成」退出安装向导。
ConfirmUninstall=卸载 %1 会停止本助手认证并恢复之前的官方启动设置，可能短暂断网。%n%n确定继续？
UninstalledAll=%1 已卸载。请手动重启电脑，再使用原来的方式登录校园网。
[Files]
#include "payload-files.iss"
[Icons]
Name: "{group}\校园网共享助手"; Filename: "{app}\校园网共享助手.exe"; WorkingDir: "{app}"
Name: "{commondesktop}\校园网共享助手"; Filename: "{app}\校园网共享助手.exe"; WorkingDir: "{app}"
Name: "{group}\打开安装文件夹"; Filename: "{win}\explorer.exe"; Parameters: """{app}"""
Name: "{group}\使用说明"; Filename: "{app}\使用说明.txt"
[Run]
Filename: "{app}\校园网共享助手.exe"; WorkingDir: "{app}"; Parameters: "firstrun"; Description: "打开校园网共享助手"; Flags: postinstall runasoriginaluser nowait skipifsilent runhidden
[UninstallDelete]
Type: files; Name: "{app}\*.json"
Type: files; Name: "{app}\*.log"
Type: files; Name: "{app}\*.flag"
Type: files; Name: "{app}\*.tmp"
Type: files; Name: "{app}\*.new"
Type: files; Name: "{app}\Client\ESurfingClient.json*"
Type: filesandordirs; Name: "{app}\Client\logs"
Type: dirifempty; Name: "{app}\Client"
Type: dirifempty; Name: "{app}"
[Code]
procedure InitializeWizard;
begin
  CreateOutputMsgPage(wpWelcome, '程序安装位置', '安装完成后可在这里找到主程序',
    ExpandConstant('程序文件夹：{autopf}\GDPortalShare') + #13#10#13#10 +
    '主程序：校园网共享助手.exe' + #13#10#13#10 +
    '桌面快捷方式会指向这份程序。开始菜单中的“打开安装文件夹”可直接查看文件。' + #13#10#13#10 +
    '已有本助手的正式安装时，此次会修复程序与快捷方式，保留账号和恢复备份。');
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := ExpandConstant(
      '主程序已安装到：{app}\校园网共享助手.exe') + #13#10#13#10 +
      '可双击主程序或桌面快捷方式打开。开始菜单也提供“打开安装文件夹”。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    if not FileExists(ExpandConstant('{app}\校园网共享助手.exe')) or
       not FileExists(ExpandConstant('{app}\Panel.ps1')) or
       not FileExists(ExpandConstant('{app}\Manage.ps1')) or
       not FileExists(ExpandConstant('{app}\Client\ESurfingClient-2.2.0-r4-windows-x86_64.exe')) then
      RaiseException('安装文件不完整，请查看系统保护历史后重试安装。');
  end;
end;

function IsOwnedInstallation: Boolean;
var oldPath: String;
begin
  Result := RegQueryStringValue(HKLM64,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\GDPortalShare-20261104_is1',
    'InstallLocation', oldPath) and
    (CompareText(RemoveBackslashUnlessRoot(oldPath),
      RemoveBackslashUnlessRoot(ExpandConstant('{autopf}\GDPortalShare'))) = 0);
end;

function InitializeSetup: Boolean;
begin
  Result := not DirExists(ExpandConstant('{autopf}\GDPortalShare')) or IsOwnedInstallation;
  if not Result and not WizardSilent then
    MsgBox('安装目录已经存在，但未找到匹配的正式安装记录。请保留目录并联系维护人员核对。', mbInformation, MB_OK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if CompareText(ExpandConstant('{app}'), ExpandConstant('{autopf}\GDPortalShare')) <> 0 then
    Result := '仅允许安装到指定的受保护目录。';
end;

function InitializeUninstall: Boolean;
begin
  Result := not (UninstallSilent and FileExists(ExpandConstant('{app}\original-startup.json')));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var rc: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Manage.ps1') + '" -Mode Uninstall', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, rc) then
      RaiseException('无法启动恢复程序，安装文件已保留。请重试卸载。');
    if rc <> 0 then
      RaiseException('恢复尚未完成，安装文件和备份已保留。请稍后重试卸载。');
  end;
end;
