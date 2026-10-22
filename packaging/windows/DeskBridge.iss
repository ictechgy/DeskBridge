; SPDX-License-Identifier: GPL-3.0-only
#ifndef AppVersion
  #define AppVersion "0.2.0-preview.9"
#endif
[Setup]
AppId={{7BB82A17-E531-4D04-A1FA-E8912E9E8E99}
AppName=DeskBridge Windows Setup
AppVersion={#AppVersion}
AppPublisher=DeskBridge contributors
DefaultDirName={autopf}\DeskBridge
DefaultGroupName=DeskBridge
OutputDir=..\..\dist\release
OutputBaseFilename=DeskBridge-{#AppVersion}-windows-x64-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
PrivilegesRequired=admin
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\Assets\Brand\AppIcon.ico
UninstallDisplayName=DeskBridge Windows Setup
DisableProgramGroupPage=yes
CloseApplications=no
[Files]
Source: "..\..\build\windows\DeskBridge-Windows.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Vendor\QRCodegen\NOTICE"; DestDir: "{app}"; DestName: "QRCodegen-LICENSE"; Flags: ignoreversion
Source: "..\..\Vendor\WindowsRuntime\NOTICE"; DestDir: "{app}"; DestName: "WindowsRuntime-NOTICE"; Flags: ignoreversion
Source: "..\..\host\windows\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\INSTALLATION.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Assets\Brand\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{group}\DeskBridge 설정"; Filename: "{app}\DeskBridge-Windows.exe"
Name: "{group}\DeskBridge 제거"; Filename: "{uninstallexe}"
[Run]
Filename: "{app}\DeskBridge-Windows.exe"; Description: "DeskBridge 설정 열기"; Flags: postinstall nowait skipifsilent runasoriginaluser
[Code]
function InitializeSetup(): Boolean;
begin
  Result := not IsARM64;
  if not Result then
    MsgBox('This preview supports Windows 11 x64 only.', mbError, MB_OK);
end;

function InitializeUninstall(): Boolean;
var
  ExitCode: Integer;
  BrokerArguments: String;
  Launched: Boolean;
begin
  { Metadata absence is not proof of inactivity. The broker always inventories fixed resources. }
  Result := False;
  ExitCode := -1;
  Launched := False;
  if (not UninstallSilent) and
     (MsgBox('파일 접속 상태를 확인하고 설정된 DeskBridge 파일 접속을 즉시 해제합니다. 이후 제거 확인을 취소해도 접속 해제는 유지됩니다. 상태를 확인할 수 없으면 제거를 중단합니다. 공유 파일과 Sunshine은 보존됩니다. 계속할까요?', mbConfirmation, MB_OKCANCEL) <> IDOK) then
    exit;
  BrokerArguments := '--elevated-operation DisableFiles';
  if UninstallSilent then
    BrokerArguments := BrokerArguments + ' --silent';
  Launched := Exec(ExpandConstant('{app}\DeskBridge-Windows.exe'), BrokerArguments,
    ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode);
  Result := Launched and (ExitCode = 0);
  if not Result then begin
    Log('DeskBridge access revocation/inactivity verification failed. Retaining helper and shared data for manual recovery.');
    if (not UninstallSilent) and ((not Launched) or (ExitCode <> 2)) then
      MsgBox('파일 접속 해제나 비활성 상태 확인을 완료하지 못했습니다. 도우미를 유지합니다. 관리자가 기존 SSH 설정과 남아 있는 DeskBridge 파일 접속을 확인한 뒤 제거하세요.', mbError, MB_OK);
  end;
end;
