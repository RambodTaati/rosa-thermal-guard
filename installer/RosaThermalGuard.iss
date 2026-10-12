; Rosa Thermal Guard - Inno Setup script (build with build.ps1)
#define AppName "Rosa Thermal Guard"
#define AppVersion Trim(FileRead(FileOpen(AddBackslash(SourcePath) + "..\src\version.txt")))
#define AppPublisher "Rosa Thermal Guard contributors"

[Setup]
AppId={{7E3C2B9A-4F61-4C8E-9B0D-2A5F7C1E8D34}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\Rosa Thermal Guard
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=RosaThermalGuard-Setup-{#AppVersion}
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\app.ico
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=yes
UsePreviousLanguage=no
CloseApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "farsi"; MessagesFile: "languages\Farsi.isl"
Name: "arabic"; MessagesFile: "languages\Arabic.isl"
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"

[CustomMessages]
english.AutoStart=Start with Windows (recommended)
farsi.AutoStart=اجرا همراه با ویندوز (پیشنهادی)
arabic.AutoStart=التشغيل مع Windows (موصى به)
chinesesimp.AutoStart=随 Windows 启动（推荐）
english.LaunchNow=Start Rosa Thermal Guard now
farsi.LaunchNow=اجرای محافظ دمای رزا
arabic.LaunchNow=تشغيل Rosa Thermal Guard الآن
chinesesimp.LaunchNow=立即启动 Rosa 温控卫士
english.NoPawnIO=CPU temperatures need the PawnIO driver, which was not found. Open https://pawnio.eu to install it?
farsi.NoPawnIO=برای خواندن دمای پردازنده، درایور PawnIO لازم است و پیدا نشد. صفحهٔ https://pawnio.eu برای نصب باز شود؟
arabic.NoPawnIO=تتطلب قراءة حرارة المعالج برنامج التشغيل PawnIO وهو غير موجود. هل تريد فتح https://pawnio.eu لتثبيته؟
chinesesimp.NoPawnIO=读取 CPU 温度需要 PawnIO 驱动，但未找到。是否打开 https://pawnio.eu 进行安装？

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Dirs]
Name: "{commonappdata}\RosaThermalGuard"; Permissions: users-modify

[Files]
Source: "..\src\*"; DestDir: "{app}"; Excludes: "config.json"; Flags: ignoreversion recursesubdirs
; config.json is only written on a fresh install: upgrades (also silent auto-updates) keep the user's settings
Source: "..\src\config.json"; DestDir: "{app}"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "..\build\lib\*"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "..\assets\app.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Open.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"; IconFilename: "{app}\app.ico"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Open.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Install-Task.ps1"" -Autostart {code:AutoFlag} -Language {code:AppLang}"; Flags: runhidden waituntilterminated; StatusMsg: "Registering scheduled task..."
Filename: "{sys}\schtasks.exe"; Parameters: "/run /tn RosaThermalGuard"; Description: "{cm:LaunchNow}"; Flags: postinstall runhidden nowait

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Remove-Task.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{commonappdata}\RosaThermalGuard"

[Code]
function AutoFlag(Param: String): String;
begin
  if WizardIsTaskSelected('autostart') then Result := '1' else Result := '0';
end;

function AppLang(Param: String): String;
var L: String;
begin
  L := ActiveLanguage();
  { silent upgrade (auto-update): keep the language already configured }
  if WizardSilent() and FileExists(ExpandConstant('{app}\config.json')) then Result := 'keep'
  else if L = 'farsi' then Result := 'fa'
  else if L = 'arabic' then Result := 'ar'
  else if L = 'chinesesimp' then Result := 'zh-CN'
  else Result := 'en';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var RC: Integer; Script: String;
begin
  Result := '';
  { upgrade: stop the running copy so its files are not locked }
  Script := ExpandConstant('{app}\Remove-Task.ps1');
  if FileExists(Script) then
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + Script + '" -StopOnly', '', SW_HIDE, ewWaitUntilTerminated, RC);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var RC: Integer;
begin
  if (CurStep = ssPostInstall) and (not WizardSilent()) then
    if not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\PawnIO') then
      if MsgBox(CustomMessage('NoPawnIO'), mbConfirmation, MB_YESNO) = IDYES then
        ShellExec('open', 'https://pawnio.eu', '', '', SW_SHOWNORMAL, ewNoWait, RC);
end;
