; Per-user installer for the unpackaged, self-contained WinUI build.
; This intentionally leaves %LocalAppData%\Teams Recorder\Sessions untouched on
; uninstall, so recordings and recoverable session evidence are never deleted.

#ifndef SourceDir
  #define SourceDir "..\out\publish\setup-win-x64"
#endif

#ifndef OutputDir
  #define OutputDir "..\out\installer"
#endif

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "Teams Recorder"
#define AppPublisher "Teams Recorder"
#define AppExeName "Recorder.WinUI.exe"

[Setup]
AppId={{1D2649F2-B7C8-4E24-BE9E-E0EFC53EF7F7}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=TeamsRecorderSetup-{#AppVersion}-win-x64
SetupIconFile=..\src\Recorder.WinUI\Assets\AppIcon.ico
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "autostart"; Description: "Start Teams Recorder when I sign in to Windows"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Deliberately use HKCU: this is a per-user installer and must neither require
; elevation nor create startup entries for other Windows accounts.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Teams Recorder"; ValueData: """{app}\{#AppExeName}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[Code]
const
  AutoStartKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AutoStartValue = 'Teams Recorder';

procedure RemoveAutoStart();
begin
  RegDeleteValue(HKCU, AutoStartKey, AutoStartValue);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { An upgrade does not run the old uninstaller.  Remove a previously enabled
    entry if the user clears the optional task during this installation. }
  if (CurStep = ssPostInstall) and (not WizardIsTaskSelected('autostart')) then
    RemoveAutoStart();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { Only our named HKCU Run value is removed; recordings and other user data
    under LocalAppData remain untouched. }
  if CurUninstallStep = usUninstall then
    RemoveAutoStart();
end;
