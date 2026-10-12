; =====================================================================================================
;  RosaGuardShared.iss - Rosa Guard Interop Contract 1.1, section 11 (shared components) + section 3 (registration)
;
;  What it does for your installer:
;    * registers the app under HKLM\SOFTWARE\RosaGuard\Apps\<AppId> (+ SHA-256 of the exe/script, written post-install)
;    * installs the shared TabHost/SDK component side-by-side to %CommonProgramFiles%\RosaGuard\TabHost\<ver>
;      only if no compatible (same major, >= ver) version is installed already; manifest written last
;    * reference-counts it in HKLM\SOFTWARE\RosaGuard\Shared\TabHost\Refs (value <AppId> = <ver>)
;    * on uninstall removes the ref and deletes only versions no remaining app resolves to (in-use -> PendingDelete)
;    * creates C:\ProgramData\RosaGuard\shared (users-modify) for settings.json, never removed
;  Same algorithm and mutex (Global\RosaGuard.Shared.<Component>) as Install-/Uninstall-RosaGuardComponent in RosaGuard.psm1.
;
;  Usage (Inno Setup 6.3+, 64-bit install mode):
;      #define RG_AppId          "net"
;      #define RG_AppVersion     "1.0.0"
;      #define RG_DisplayName    "Rosa Net Guard"
;      #define RG_Capabilities   "gaming.detect{break}net.session"      ; optional, {break}-separated
;      #define RG_ProcessImage   "NetGuard.exe"                           ; relative to {app}; or:
;      #define RG_ScriptPath     "NetGuard.ps1"                           ; for powershell-hosted apps
;      #define RG_RunsElevated   "1"                                      ; optional, default 0
;      #define RG_TabHostVersion "1.1.2"
;      #define RG_TabHostSource  "..\..\RosaGuard-SDK"                    ; folder with RosaGuard.psd1/.psm1, bin, schemas, src
;      #include "RosaGuardShared.iss"
;  Nothing else to call: it defines CurStepChanged / CurUninstallStepChanged (or #define RG_NoAutoHooks and call
;  RosaGuard_CurStepChanged / RosaGuard_CurUninstallStepChanged from your own).
; =====================================================================================================

#ifndef RG_AppId
  #error Define RG_AppId before including RosaGuardShared.iss
#endif
#ifndef RG_AppVersion
  #error Define RG_AppVersion before including RosaGuardShared.iss
#endif
#ifndef RG_TabHostVersion
  #define RG_TabHostVersion "1.1.2"
#endif
#ifndef RG_DisplayName
  #define RG_DisplayName RG_AppId
#endif
#ifndef RG_Capabilities
  #define RG_Capabilities ""
#endif
#ifndef RG_RunsElevated
  #define RG_RunsElevated "0"
#endif
#define RG_Component "TabHost"

[Dirs]
Name: "{commonappdata}\RosaGuard\shared"; Permissions: users-modify; Flags: uninsneveruninstall

[Registry]
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; Flags: uninsdeletekey
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "Version"; ValueData: "{#RG_AppVersion}"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "ContractVersion"; ValueData: "1.1.2"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: dword; ValueName: "ContractMajor"; ValueData: "1"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "InstallDir"; ValueData: "{app}"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "DisplayName"; ValueData: "{#RG_DisplayName}"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: multisz; ValueName: "Capabilities"; ValueData: "{#RG_Capabilities}"
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: dword; ValueName: "RunsElevated"; ValueData: "{#RG_RunsElevated}"
#ifdef RG_ProcessImage
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "ProcessImage"; ValueData: "{app}\{#RG_ProcessImage}"
#endif
#ifdef RG_ScriptPath
Root: HKLM64; Subkey: "SOFTWARE\RosaGuard\Apps\{#RG_AppId}"; ValueType: string; ValueName: "ScriptPath"; ValueData: "{app}\{#RG_ScriptPath}"
#endif

#ifdef RG_TabHostSource
[Files]
; Staged under a per-app partial folder; renamed into place (or discarded) post-install. Inno never uninstalls these itself.
Source: "{#RG_TabHostSource}\RosaGuard.psd1"; DestDir: "{code:RG_StagingDir}"; Flags: ignoreversion uninsneveruninstall; Check: RG_NeedsCopy
Source: "{#RG_TabHostSource}\RosaGuard.psm1"; DestDir: "{code:RG_StagingDir}"; Flags: ignoreversion uninsneveruninstall; Check: RG_NeedsCopy
Source: "{#RG_TabHostSource}\bin\*"; DestDir: "{code:RG_StagingDir}\bin"; Flags: ignoreversion recursesubdirs uninsneveruninstall; Check: RG_NeedsCopy
Source: "{#RG_TabHostSource}\schemas\*"; DestDir: "{code:RG_StagingDir}\schemas"; Flags: ignoreversion recursesubdirs uninsneveruninstall; Check: RG_NeedsCopy
Source: "{#RG_TabHostSource}\src\*"; DestDir: "{code:RG_StagingDir}\src"; Flags: ignoreversion recursesubdirs uninsneveruninstall; Check: RG_NeedsCopy
#endif

[Code]
const
  RG_KEY = 'SOFTWARE\RosaGuard\Shared\{#RG_Component}';
  RG_APPKEY = 'SOFTWARE\RosaGuard\Apps\{#RG_AppId}';
var
  RG_NeedsCopyState: Integer; // 0 unknown, 1 yes, 2 no
  RG_Mutex: THandle;

function RG_CreateMutex(lpAttr: Longint; bInitialOwner: BOOL; lpName: String): THandle; external 'CreateMutexW@kernel32.dll stdcall';
function RG_WaitForSingleObject(h: THandle; ms: Cardinal): Cardinal; external 'WaitForSingleObject@kernel32.dll stdcall';
function RG_ReleaseMutex(h: THandle): BOOL; external 'ReleaseMutex@kernel32.dll stdcall';
function RG_CloseHandle(h: THandle): BOOL; external 'CloseHandle@kernel32.dll stdcall';

procedure RG_Lock;
begin
  RG_Mutex := RG_CreateMutex(0, False, 'Global\RosaGuard.Shared.{#RG_Component}');
  if RG_Mutex <> 0 then RG_WaitForSingleObject(RG_Mutex, 30000); // WAIT_ABANDONED (0x80) also means we own it
end;
procedure RG_Unlock;
begin
  if RG_Mutex <> 0 then begin RG_ReleaseMutex(RG_Mutex); RG_CloseHandle(RG_Mutex); RG_Mutex := 0; end;
end;

function RG_Root: String;
begin
  Result := ExpandConstant('{commoncf64}\RosaGuard\{#RG_Component}');
end;
function RG_StagingDir(Param: String): String;
begin
  Result := RG_Root + '\.{#RG_TabHostVersion}.partial-{#RG_AppId}';
end;

function RG_VerPart(var S: String): Integer;
var p: Integer;
begin
  p := Pos('.', S);
  if p = 0 then begin Result := StrToIntDef(S, -1); S := ''; end
  else begin Result := StrToIntDef(Copy(S, 1, p - 1), -1); Delete(S, 1, p); end;
end;
function RG_IsVersion(S: String): Boolean;
var i, n: Integer;
begin
  Result := (Length(S) > 0) and (Length(S) <= 32);
  n := 0;
  for i := 1 to Length(S) do
    if S[i] = '.' then n := n + 1
    else if (S[i] < '0') or (S[i] > '9') then Result := False;
  if (n < 1) or (n > 3) or (S[1] = '.') or (S[Length(S)] = '.') then Result := False;
end;
function RG_Major(S: String): Integer;
begin
  Result := RG_VerPart(S);
end;
function RG_CompareVer(A, B: String): Integer;
var i, x, y: Integer;
begin
  Result := 0;
  for i := 1 to 4 do begin
    x := RG_VerPart(A); y := RG_VerPart(B);
    if x < 0 then x := 0;
    if y < 0 then y := 0;
    if x < y then begin Result := -1; exit; end;
    if x > y then begin Result := 1; exit; end;
  end;
end;

{ Newest fully installed (manifest present) version with the same major and >= Required; '' if none. }
function RG_Resolve(Required: String): String;
var F: TFindRec; best: String;
begin
  best := '';
  if FindFirst(RG_Root + '\*', F) then
  try
    repeat
      if ((F.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and RG_IsVersion(F.Name)
         and FileExists(RG_Root + '\' + F.Name + '\rosaguard-component.json')
         and (RG_Major(F.Name) = RG_Major(Required)) and (RG_CompareVer(F.Name, Required) >= 0) then
        if (best = '') or (RG_CompareVer(F.Name, best) > 0) then best := F.Name;
    until not FindNext(F);
  finally
    FindClose(F);
  end;
  Result := best;
end;

function RG_NeedsCopy: Boolean;
begin
  if RG_NeedsCopyState = 0 then
    if RG_Resolve('{#RG_TabHostVersion}') = '' then RG_NeedsCopyState := 1 else RG_NeedsCopyState := 2;
  Result := RG_NeedsCopyState = 1;
end;

function RG_JsonEsc(S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

procedure RG_CollectFiles(Base, Rel: String; var Json: String; var First: Boolean);
var F: TFindRec; mask, r: String;
begin
  if Rel = '' then mask := AddBackslash(Base) + '*' else mask := AddBackslash(Base) + Rel + '\*';
  if FindFirst(mask, F) then
  try
    repeat
      if (F.Name <> '.') and (F.Name <> '..') then begin
        if Rel = '' then r := F.Name else r := Rel + '\' + F.Name;
        if (F.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          RG_CollectFiles(Base, r, Json, First)
        else if CompareText(r, 'rosaguard-component.json') <> 0 then begin
          if not First then Json := Json + ',';
          First := False;
          Json := Json + '{"path":"' + RG_JsonEsc(r) + '","sha256":"' + GetSHA256OfFile(AddBackslash(Base) + r) + '","size":' + IntToStr(F.SizeLow) + '}';
        end;
      end;
    until not FindNext(F);
  finally
    FindClose(F);
  end;
end;

procedure RG_UpdateRefCount;
var names: TArrayOfString;
begin
  if not RegGetValueNames(HKLM64, RG_KEY + '\Refs', names) then SetArrayLength(names, 0);
  if RegKeyExists(HKLM64, RG_KEY) then RegWriteDWordValue(HKLM64, RG_KEY, 'RefCount', GetArrayLength(names));
end;

procedure RG_InstallShared;
var staging, final, best, json: String; first: Boolean;
begin
  RG_Lock;
  try
    staging := RG_StagingDir('');
    if DirExists(staging) then begin
      best := RG_Resolve('{#RG_TabHostVersion}');
      if best = '' then begin
        final := RG_Root + '\{#RG_TabHostVersion}';
        if DirExists(final) then DelTree(final, True, True, True); // incomplete leftover (no manifest)
        json := ''; first := True;
        RG_CollectFiles(staging, '', json, first);
        SaveStringToFile(staging + '\rosaguard-component.json',
          '{"component":"{#RG_Component}","version":"{#RG_TabHostVersion}","installedBy":"{#RG_AppId}","installedUtc":"' +
          GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '","files":[' + json + ']}', False);
        if RenameFile(staging, final) then begin
          RegWriteStringValue(HKLM64, RG_KEY + '\Versions\{#RG_TabHostVersion}', 'Path', final);
          RegWriteStringValue(HKLM64, RG_KEY + '\Versions\{#RG_TabHostVersion}', 'InstalledBy', '{#RG_AppId}');
        end else Log('RosaGuard: could not move ' + staging + ' to ' + final);
      end else
        DelTree(staging, True, True, True); // a compatible version >= ours is already installed
    end;
    RegWriteStringValue(HKLM64, RG_KEY + '\Refs', '{#RG_AppId}', '{#RG_TabHostVersion}');
    RG_UpdateRefCount;
  finally
    RG_Unlock;
  end;
end;

procedure RG_Cleanup;
var refs, dirs: TArrayOfString; keep, names: TStringList; F: TFindRec; i: Integer; v, name, trash, pending: String;
begin
  keep := TStringList.Create; names := TStringList.Create;
  try
    if RegGetValueNames(HKLM64, RG_KEY + '\Refs', refs) then
      for i := 0 to GetArrayLength(refs) - 1 do
        if RegQueryStringValue(HKLM64, RG_KEY + '\Refs', refs[i], v) then begin
          v := RG_Resolve(v);
          if v <> '' then keep.Add(v);
        end;
    if FindFirst(RG_Root + '\*', F) then
    try
      repeat
        if ((F.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and (F.Name <> '.') and (F.Name <> '..') then names.Add(F.Name);
      until not FindNext(F);
    finally
      FindClose(F);
    end;
    pending := '';
    for i := 0 to names.Count - 1 do begin
      name := names[i];
      if keep.IndexOf(name) >= 0 then continue;
      if not (RG_IsVersion(name) or (Pos('.partial-', name) > 0) or (Pos('.delete-', name) > 0)) then continue; // not ours
      trash := name;
      if Pos('.delete-', name) = 0 then begin
        trash := '.' + name + '.delete-' + GetDateTimeString('hhnnsszzz', #0, #0);
        if not RenameFile(RG_Root + '\' + name, RG_Root + '\' + trash) then begin
          pending := pending + name + #0; continue; // files in use
        end;
      end;
      if DelTree(RG_Root + '\' + trash, True, True, True) then begin
        if RG_IsVersion(name) then RegDeleteKeyIncludingSubkeys(HKLM64, RG_KEY + '\Versions\' + name);
      end else pending := pending + name + #0;
    end;
    if RegKeyExists(HKLM64, RG_KEY) then begin
      if pending <> '' then RegWriteMultiStringValue(HKLM64, RG_KEY, 'PendingDelete', pending)
      else RegDeleteValue(HKLM64, RG_KEY, 'PendingDelete');
      if not RegGetValueNames(HKLM64, RG_KEY + '\Refs', dirs) then SetArrayLength(dirs, 0);
      if (GetArrayLength(dirs) = 0) and (pending = '') then begin
        RegDeleteKeyIncludingSubkeys(HKLM64, RG_KEY);
        RemoveDir(RG_Root);
      end;
    end;
  finally
    keep.Free; names.Free;
  end;
end;

procedure RG_UninstallShared;
begin
  RG_Lock;
  try
    RegDeleteValue(HKLM64, RG_KEY + '\Refs', '{#RG_AppId}');
    RG_UpdateRefCount;
    RG_Cleanup;
  finally
    RG_Unlock;
  end;
end;

procedure RG_WriteHashes;
begin
#ifdef RG_ProcessImage
  if FileExists(ExpandConstant('{app}\{#RG_ProcessImage}')) then
    RegWriteStringValue(HKLM64, RG_APPKEY, 'ProcessImageSha256', GetSHA256OfFile(ExpandConstant('{app}\{#RG_ProcessImage}')));
#endif
#ifdef RG_ScriptPath
  if FileExists(ExpandConstant('{app}\{#RG_ScriptPath}')) then
    RegWriteStringValue(HKLM64, RG_APPKEY, 'ScriptSha256', GetSHA256OfFile(ExpandConstant('{app}\{#RG_ScriptPath}')));
#endif
end;

procedure RosaGuard_CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    RG_WriteHashes;
#ifdef RG_TabHostSource
    RG_InstallShared;
#endif
  end;
end;

procedure RosaGuard_CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then RG_UninstallShared;
end;

#ifndef RG_NoAutoHooks
{ If your script already has CurStepChanged / CurUninstallStepChanged, #define RG_NoAutoHooks before the include
  and call RosaGuard_CurStepChanged(CurStep) / RosaGuard_CurUninstallStepChanged(CurUninstallStep) from yours. }
procedure CurStepChanged(CurStep: TSetupStep);
begin
  RosaGuard_CurStepChanged(CurStep);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  RosaGuard_CurUninstallStepChanged(CurUninstallStep);
end;
#endif
