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
UsePreviousAppDir=yes
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
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\skills\agent-ssh\*"; DestDir: "{%USERPROFILE}\.codex\skills\agent-ssh"; Flags: ignoreversion recursesubdirs createallsubdirs; Tasks: codexskill

[InstallDelete]
Type: files; Name: "{app}\SSH Space.exe"
Type: files; Name: "{autoprograms}\SSH Space.lnk"
Type: files; Name: "{autodesktop}\SSH Space.lnk"

[Icons]
Name: "{autoprograms}\agent-ssh"; Filename: "{app}\agent-ssh.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\agent-ssh"; Filename: "{app}\agent-ssh.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\agent-ssh.exe"; Description: "Launch agent-ssh"; Flags: nowait postinstall skipifsilent

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  LegacySkill: String;
  BackupRoot: String;
  BackupPath: String;
begin
  Result := '';
  if not WizardIsTaskSelected('codexskill') then
    exit;

  LegacySkill := ExpandConstant('{%USERPROFILE}\.codex\skills\ssh-space');
  if not DirExists(LegacySkill) then
    exit;

  BackupRoot := ExpandConstant('{%USERPROFILE}\.codex\skill-backups');
  if not ForceDirectories(BackupRoot) then
  begin
    Result := 'Could not create the Codex Skill backup directory.';
    exit;
  end;

  BackupPath := BackupRoot + '\ssh-space_' + GetDateTimeString('yyyymmdd_hhnnss', '', '');
  if not RenameFile(LegacySkill, BackupPath) then
    Result := 'Could not archive the legacy Codex Skill. Close Codex and try again.';
end;
