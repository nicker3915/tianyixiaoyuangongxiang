[Setup]
AppId=GDPortalShare-Cleanup-20261113
AppName=校园网共享助手清理工具
AppVersion=1.4.1
VersionInfoVersion=1.4.1.0
VersionInfoProductName=校园网共享助手清理工具
VersionInfoDescription=恢复校园网设置并移除已识别的助手版本
DefaultDirName={tmp}\GDPortalShare-Cleanup
CreateAppDir=no
CreateUninstallRegKey=no
Uninstallable=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17763
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir=dist
OutputBaseFilename=校园网共享助手-清理与卸载
SetupLogging=no
CloseApplications=no
RestartApplications=no

[LangOptions]
LanguageName=简体中文
LanguageID=$0804
DialogFontName=Microsoft YaHei UI

[Messages]
SetupWindowTitle=校园网共享助手 · 清理与卸载
SetupAppTitle=清理与卸载
WelcomeLabel1=清理旧版，恢复官方设置
WelcomeLabel2=旧版打不开或无法卸载时，可使用此工具。%n%n先检查目标目录及恢复资料，再由你确认是否清理。确认清理后会停止本助手共享，手机可能断网。%n%n恢复失败时会保留资料，便于处理后重试。
ButtonNext=下一步(&N) >
ButtonBack=< 上一步(&B)
ButtonInstall=确认清理并卸载(&I)
ButtonCancel=取消
ButtonFinish=完成(&F)
WizardReady=确认清理范围
ReadyLabel1=请确认目标目录和检查结果。
ReadyLabel2a=点击下方按钮后开始恢复和清理，可能短暂断网。
ReadyLabel2b=点击下方按钮后开始恢复和清理，可能短暂断网。
WizardInstalling=正在恢复并清理
InstallingLabel=正在处理已识别的助手版本，请稍候。
FinishedHeadingLabel=清理已完成
FinishedLabel=本助手的恢复和清理操作已完成。请通过原官方客户端登录；需要共享时可重新运行新版安装包。
FinishedLabelNoIcons=本助手的恢复和清理操作已完成。请通过原官方客户端登录；需要共享时可重新运行新版安装包。
ClickFinish=点击“完成”退出。

[Files]
Source: "stage\Cleanup-Assistant.ps1"; Flags: dontcopy
Source: "stage\Cleanup.Core.ps1"; Flags: dontcopy
Source: "stage\Lifecycle.ps1"; Flags: dontcopy
Source: "stage\Network.ps1"; Flags: dontcopy
Source: "stage\cleanup-files.json"; Flags: dontcopy

[Code]
var
  TargetPage: TInputDirWizardPage;
  ReviewPage: TOutputMsgWizardPage;
  PreviewSucceeded, RemovalSucceeded: Boolean;
  LastSummary: String;

function InitializeSetup: Boolean;
begin
  Result := not WizardSilent;
  if not Result then
    MsgBox('清理需要先查看范围并确认，请直接双击清理工具。', mbInformation, MB_OK);
end;

procedure InitializeWizard;
var Target: String;
begin
  ExtractTemporaryFile('Cleanup-Assistant.ps1');
  ExtractTemporaryFile('Cleanup.Core.ps1');
  ExtractTemporaryFile('Lifecycle.ps1');
  ExtractTemporaryFile('Network.ps1');
  ExtractTemporaryFile('cleanup-files.json');
  TargetPage := CreateInputDirPage(wpWelcome, '选择需要清理的助手目录',
    '安装版通常位于 Program Files\GDPortalShare；免安装版选择自己的程序文件夹。',
    '仅处理能够核实归属的助手文件和设置。请勿选择学校官方客户端目录。', False, '');
  TargetPage.Add('助手目录：');
  Target := ExpandConstant('{param:TARGET|}');
  if Target = '' then Target := ExpandConstant('{autopf}\GDPortalShare');
  TargetPage.Values[0] := Target;
  ReviewPage := CreateOutputMsgPage(TargetPage.ID, '核对清理范围',
    '本页只做检查；点击“确认清理并卸载”后才会停止共享。', '');
end;

function RunCleanup(Mode: String): Boolean;
var Code: Integer; Params, SummaryFile: String; Text: AnsiString;
begin
  SummaryFile := ExpandConstant('{tmp}\cleanup-summary.txt');
  LastSummary := '';
  if FileExists(SummaryFile) then DeleteFile(SummaryFile);
  Params := '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
    ExpandConstant('{tmp}\Cleanup-Assistant.ps1') + '" -Mode ' + Mode +
    ' -TargetRoot "' + RemoveBackslashUnlessRoot(TargetPage.Values[0]) +
    '" -ResultPath "' + ExpandConstant('{tmp}\cleanup-result.json') +
    '" -SummaryPath "' + SummaryFile + '"';
  if Mode = 'Remove' then Params := Params + ' -UserConfirmed';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Params, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, Code);
  if FileExists(SummaryFile) and LoadStringFromFile(SummaryFile, Text) then
    LastSummary := UTF8Decode(Text);
  if LastSummary = '' then
    LastSummary := '无法完成检查或恢复。请保留原目录和备份，联系维护人员核对。';
  Result := Result and (Code = 0);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = TargetPage.ID then begin
    if CompareText(RemoveBackslashUnlessRoot(ExpandConstant('{src}')),
      RemoveBackslashUnlessRoot(TargetPage.Values[0])) = 0 then begin
      MsgBox('请从主面板或开始菜单的“一键清理与卸载”打开，它会自动在目录外运行。旧程序打不开时，请先把此清理 EXE 复制到桌面，再运行并选择旧助手目录。', mbInformation, MB_OK);
      Result := False;
      Exit;
    end;
    if (Pos('"', TargetPage.Values[0]) > 0) or
       (Pos(#13, TargetPage.Values[0]) > 0) or (Pos(#10, TargetPage.Values[0]) > 0) then begin
      MsgBox('目录路径包含无效字符，请重新选择。', mbInformation, MB_OK);
      Result := False;
      Exit;
    end;
    WizardForm.NextButton.Enabled := False;
    try
      PreviewSucceeded := RunCleanup('Preview');
      ReviewPage.MsgLabel.Caption := LastSummary;
      if not PreviewSucceeded then begin
        MsgBox(LastSummary, mbInformation, MB_OK);
        Result := False;
      end;
    finally
      WizardForm.NextButton.Enabled := True;
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpReady then
    WizardForm.ReadyMemo.Text := '目标目录：' + TargetPage.Values[0] + #13#10#13#10 +
      LastSummary + #13#10#13#10 +
      '确认后停止本助手共享，先恢复备份的设置，再移除已识别文件。未识别文件会保留。';
  if (CurPageID = wpFinished) and RemovalSucceeded then
    WizardForm.FinishedLabel.Caption := LastSummary + #13#10#13#10 +
      '请用原官方客户端登录。需要共享时，可重新安装新版助手。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then begin
    if not PreviewSucceeded then RaiseException('请先完成清理范围检查。');
    RemovalSucceeded := RunCleanup('Remove');
    if not RemovalSucceeded then RaiseException(LastSummary);
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if RemovalSucceeded then Result := 0 else Result := 21;
end;
