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

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
