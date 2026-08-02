#ifndef SourceDir
  #error SourceDir must be provided by scripts\build-release.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be provided by scripts\build-release.ps1
#endif
#ifndef AppVersion
  #define AppVersion "2.0.0"
#endif

[Setup]
AppId={{D03EF2BC-0D59-4DFA-8355-A5A6395AB9DB}
AppName=SSH Space
AppVersion={#AppVersion}
AppPublisher=SSH Space
DefaultDirName={localappdata}\Programs\SSH Space
DefaultGroupName=SSH Space
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=SSH-Space-{#AppVersion}-Setup
SetupIconFile={#SourceDir}\SshSpace.ico
UninstallDisplayIcon={app}\SSH Space.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
DisableProgramGroupPage=yes
VersionInfoVersion={#AppVersion}
VersionInfoProductName=SSH Space
VersionInfoDescription=SSH Space desktop SSH control plane

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\SSH Space"; Filename: "{app}\SSH Space.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SSH Space"; Filename: "{app}\SSH Space.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\SSH Space.exe"; Description: "Launch SSH Space"; Flags: nowait postinstall skipifsilent
