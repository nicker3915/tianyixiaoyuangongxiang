[Setup]
AppId=GDPortalShare-20261104
AppName=校园网共享助手
AppVersion=1.4.11
VersionInfoVersion=1.4.11.0
VersionInfoProductName=校园网共享助手
VersionInfoDescription=校园网共享助手安装程序（Wi-Fi与有线统一版）
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
OutputBaseFilename=校园网共享助手-1.4.11-安装程序
UninstallDisplayName=校园网共享助手
UninstallDisplayIcon={app}\校园网共享助手.exe
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
Name: "{group}\一键清理与卸载"; Filename: "{app}\校园网共享助手.exe"; Parameters: "cleanup"; WorkingDir: "{app}"
[Run]
Filename: "{app}\校园网共享助手.exe"; WorkingDir: "{app}"; Parameters: "firstrun"; Description: "打开校园网共享助手"; Check: IsPayloadVerified; Flags: postinstall runasoriginaluser nowait skipifsilent runhidden
[UninstallDelete]
Type: files; Name: "{app}\settings.json*"
Type: files; Name: "{app}\original-startup.json*"
Type: files; Name: "{app}\managed-routes.json*"
Type: files; Name: "{app}\assistant-state.json*"
Type: files; Name: "{app}\last-status.json*"
Type: files; Name: "{app}\watchdog-status.json*"
Type: files; Name: "{app}\watchdog-history.json*"
Type: files; Name: "{app}\recovery-last-result.json*"
Type: files; Name: "{app}\hotspot-owner.json*"
Type: files; Name: "{app}\network-check.json*"
Type: files; Name: "{app}\environment-check.json*"
Type: files; Name: "{app}\clean-conflicts-result.json*"
Type: files; Name: "{app}\startup.log"
Type: files; Name: "{app}\startup.previous.log"
Type: files; Name: "{app}\launcher.log"
Type: files; Name: "{app}\watchdog-paused.flag"
Type: files; Name: "{app}\uninstall-in-progress.flag"
Type: files; Name: "{app}\recovery-api-*.tmp"
Type: files; Name: "{app}\startup-api-*.tmp"
Type: files; Name: "{app}\.gdportalshare-cleaned"
Type: files; Name: "{app}\Client\ESurfingClient.json*"
Type: filesandordirs; Name: "{app}\Client\logs"
Type: dirifempty; Name: "{app}\Client"
Type: dirifempty; Name: "{app}"
[Code]
var PayloadVerified: Boolean;
    RecoveryPage: TOutputMsgWizardPage;
    RecoveryButton: TNewButton;

procedure LaunchRecovery(Sender: TObject);
var Code: Integer;
begin
  ExtractTemporaryFile('校园网共享助手-清理与卸载.exe');
  if not Exec(ExpandConstant('{tmp}\校园网共享助手-清理与卸载.exe'),
    '',
    ExpandConstant('{tmp}'), SW_SHOWNORMAL, ewWaitUntilTerminated, Code) then
    MsgBox('无法打开清理工具。请使用发布目录中独立的“校园网共享助手-清理与卸载.exe”。', mbInformation, MB_OK);
end;

function IsPayloadVerified: Boolean;
begin
  Result := PayloadVerified;
end;

function GetCustomSetupExitCode: Integer;
begin
  if PayloadVerified then Result := 0 else Result := 20;
end;

procedure VerifyPayloadFile(Name, ExpectedHash: String);
var FilePath: String;
begin
  FilePath := ExpandConstant('{app}\') + Name;
  if not FileExists(FilePath) then
    RaiseException('安装组件缺失：' + Name + '。请查看安全软件的保护历史，并联系维护人员核对；不要关闭系统防护。');
  if CompareText(GetSHA256OfFile(FilePath), ExpectedHash) <> 0 then
    RaiseException('安装组件校验失败：' + Name + '。请使用完整的正式安装包重新安装。');
end;

#include "payload-checks.iss"

procedure InitializeWizard;
begin
  RecoveryPage := CreateOutputMsgPage(wpWelcome, '安装、修复与旧版清理',
    '旧版无法卸载时，可在安装前打开独立清理工具。',
    '首次安装请直接下一步。已有正常安装时，可以覆盖修复程序，保留账号和首次恢复备份。' + #13#10#13#10 +
    '如果旧版打不开、卸载器缺失或残留目录阻止安装，请先打开下方清理工具。它会检查归属和备份，确认后恢复设置并清理，再返回本向导安装。');
  RecoveryButton := TNewButton.Create(WizardForm);
  RecoveryButton.Parent := RecoveryPage.Surface;
  RecoveryButton.SetBounds(0, ScaleY(128), ScaleX(260), ScaleY(34));
  RecoveryButton.Caption := '旧版无法卸载？检查并清理';
  RecoveryButton.OnClick := @LaunchRecovery;
  CreateOutputMsgPage(wpWelcome, '程序安装位置', '安装完成后可在这里找到主程序',
    ExpandConstant('程序文件夹：{autopf}\GDPortalShare') + #13#10#13#10 +
    '主程序：校园网共享助手.exe' + #13#10#13#10 +
    '桌面快捷方式会指向这份程序。开始菜单中的“打开安装文件夹”可直接查看文件。' + #13#10#13#10 +
    '已有本助手的正式安装时，此次会修复程序与快捷方式，保留账号和恢复备份。');
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then begin
    if not PayloadVerified then begin
      WizardForm.FinishedHeadingLabel.Caption := '安装未通过完整性检查';
      WizardForm.FinishedLabel.Caption := '程序组件缺失或校验失败，安装器不会自动启动助手。请查看保护历史中的具体提示，并联系维护人员核对。';
      Exit;
    end;
    WizardForm.FinishedLabel.Caption := ExpandConstant(
      '主程序已安装到：{app}\校园网共享助手.exe') + #13#10#13#10 +
      '可双击主程序或桌面快捷方式打开。开始菜单也提供“打开安装文件夹”。';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    VerifyInstalledPayload;
    PayloadVerified := True;
    if FileExists(ExpandConstant('{app}\.gdportalshare-cleaned')) then
      DeleteFile(ExpandConstant('{app}\.gdportalshare-cleaned'));
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

function IsCleanedDirectory: Boolean;
var Text: AnsiString;
begin
  Result := LoadStringFromFile(ExpandConstant('{autopf}\GDPortalShare\.gdportalshare-cleaned'), Text) and
    (Text = 'GDPortalShare-20261104-cleaned-v1');
end;

function InitializeSetup: Boolean;
begin
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if CompareText(ExpandConstant('{app}'), ExpandConstant('{autopf}\GDPortalShare')) <> 0 then begin
    Result := '仅允许安装到指定的受保护目录。';
    Exit;
  end;
  if DirExists(ExpandConstant('{app}')) and not IsOwnedInstallation and not IsCleanedDirectory then begin
    Result := '安装目录存在，但正式安装记录不完整。请返回“安装、修复与旧版清理”页，打开独立清理工具检查并恢复后，再继续安装。';
    Exit;
  end;
  if CheckForMutexes('Local\GDPortalShare-Panel,Global\GDPortalShare-Operation') then
    Result := '请先完成当前操作，在助手中停止共享并完全退出窗口和托盘，再重试安装。';
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
