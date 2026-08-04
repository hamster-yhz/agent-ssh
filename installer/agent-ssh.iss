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
AppName=agent-ssh
AppVersion={#AppVersion}
AppPublisher=agent-ssh
DefaultDirName={localappdata}\Programs\agent-ssh
DefaultGroupName=agent-ssh
UsePreviousAppDir=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=agent-ssh-{#AppVersion}-Setup
SetupIconFile={#SourceDir}\agent-ssh.ico
UninstallDisplayIcon={app}\agent-ssh.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=yes
DisableProgramGroupPage=yes
VersionInfoVersion={#AppVersion}
VersionInfoProductName=agent-ssh
VersionInfoDescription=agent-ssh desktop SSH control plane

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: checkedonce
Name: "codexskill"; Description: "Install the agent-ssh Skill for Codex"; GroupDescription: "Agent integration:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "keys\*,data\*,exports\*,backups\*"; Flags: ignoreversion recursesubdirs
Source: "{#SourceDir}\skills\agent-ssh\*"; DestDir: "{%USERPROFILE}\.codex\skills\agent-ssh"; Flags: ignoreversion recursesubdirs createallsubdirs; Tasks: codexskill

[UninstallDelete]
Type: files; Name: "{app}\.agent-ssh-installed"

[Icons]
Name: "{autoprograms}\agent-ssh"; Filename: "{app}\agent-ssh.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\agent-ssh"; Filename: "{app}\agent-ssh.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\agent-ssh.exe"; Description: "Launch agent-ssh"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    SaveStringToFile(ExpandConstant('{app}\.agent-ssh-installed'), 'installed', False);
end;
