#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#ifndef AppSource
  #error AppSource must point to the Flutter Windows release directory
#endif

#ifndef CliSource
  #error CliSource must point to the compiled lc CLI executable
#endif

#ifndef OutputDir
  #define OutputDir "."
#endif

#define AppName "lc"
#define Publisher "cacube"
#define CliBinDir "{localappdata}\DevEnvironmentManager\bin"

[Setup]
AppId=com.cacube.lc
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#Publisher}
DefaultDirName={localappdata}\Programs\lc
DefaultGroupName=lc
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=lc-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\lc.exe
ChangesEnvironment=yes
CloseApplications=yes
RestartApplications=no
WizardStyle=modern

[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#CliSource}"; DestDir: "{#CliBinDir}"; DestName: "lc.exe"; Flags: ignoreversion

[Icons]
Name: "{group}\lc"; Filename: "{app}\lc.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\lc"; Filename: "{app}\lc.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\lc.exe"; Description: "Launch lc"; Flags: nowait postinstall skipifsilent

[Code]
const
  UserEnvironmentKey = 'Environment';
  UserPathValue = 'Path';

function TrimPathEntry(Value: String): String;
begin
  Result := Trim(Value);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
  while (Length(Result) > 3) and
        ((Result[Length(Result)] = '\') or (Result[Length(Result)] = '/')) do
    Delete(Result, Length(Result), 1);
  Result := Lowercase(Result);
end;

function PathContains(const PathValue, Entry: String): Boolean;
var
  Remaining: String;
  Separator: Integer;
  Candidate: String;
begin
  Result := False;
  Remaining := PathValue;
  repeat
    Separator := Pos(';', Remaining);
    if Separator = 0 then begin
      Candidate := Remaining;
      Remaining := '';
    end else begin
      Candidate := Copy(Remaining, 1, Separator - 1);
      Delete(Remaining, 1, Separator);
    end;
    if TrimPathEntry(Candidate) = TrimPathEntry(Entry) then begin
      Result := True;
      Exit;
    end;
  until Remaining = '';
end;

procedure AddCliToUserPath;
var
  ExistingPath: String;
  CliPath: String;
begin
  CliPath := ExpandConstant('{#CliBinDir}');
  if not RegQueryStringValue(HKCU, UserEnvironmentKey, UserPathValue,
    ExistingPath) then
    ExistingPath := '';
  if PathContains(ExistingPath, CliPath) then
    Exit;
  if (ExistingPath <> '') and (ExistingPath[Length(ExistingPath)] <> ';') then
    ExistingPath := ExistingPath + ';';
  if not RegWriteExpandStringValue(HKCU, UserEnvironmentKey, UserPathValue,
    ExistingPath + CliPath) then
    RaiseException('Unable to add lc to the current user PATH.');
end;

procedure RemoveCliFromUserPath;
var
  ExistingPath: String;
  Remaining: String;
  UpdatedPath: String;
  Separator: Integer;
  Candidate: String;
  CliPath: String;
begin
  if not RegQueryStringValue(HKCU, UserEnvironmentKey, UserPathValue,
    ExistingPath) then
    Exit;
  CliPath := ExpandConstant('{#CliBinDir}');
  Remaining := ExistingPath;
  UpdatedPath := '';
  repeat
    Separator := Pos(';', Remaining);
    if Separator = 0 then begin
      Candidate := Remaining;
      Remaining := '';
    end else begin
      Candidate := Copy(Remaining, 1, Separator - 1);
      Delete(Remaining, 1, Separator);
    end;
    if (Trim(Candidate) <> '') and
       (TrimPathEntry(Candidate) <> TrimPathEntry(CliPath)) then begin
      if UpdatedPath <> '' then
        UpdatedPath := UpdatedPath + ';';
      UpdatedPath := UpdatedPath + Candidate;
    end;
  until Remaining = '';
  if UpdatedPath <> ExistingPath then
    RegWriteExpandStringValue(HKCU, UserEnvironmentKey, UserPathValue,
      UpdatedPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    AddCliToUserPath;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveCliFromUserPath;
end;
