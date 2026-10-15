;  AdskDoctor.iss  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
;  -----------------------------------------------------------------
;  Build:
;    ISCC.exe /DVersion=1.2.3 /DPayloadDir=<dir> /DOutputDir=<dir> AdskDoctor.iss
;
;  Defaults (when built by Build-Release.ps1, the defines are passed in):
;    PayloadDir = the folder placed next to the .exe  (scripts + icon + logo)

#ifndef Version
  #define Version "1.2.3"
#endif
#ifndef PayloadDir
  #define PayloadDir ".."
#endif
#ifndef OutputDir
  #define OutputDir "..\releases"
#endif
#ifndef IconFile
  #define IconFile "..\unlock-logo.ico"
#endif
#ifndef LicenseFile
  #define LicenseFile "..\LICENSE"
#endif

#define MyAppName   "Autodesk Licensing Doctor"
#define MyPublisher "UNLOCK DIGITAL"
#define MyExe       "UNLOCK-DIGITAL-AdskDoctor.exe"
#define MyCopyright "Unlock Digital - By Eng. Eslam Ashraf"

[Setup]
AppId={{8F3A2C1E-7B4D-4E9A-9C2F-1D6B5A7E3F01}
AppName={#MyAppName}
AppVersion={#Version}
AppVerName={#MyAppName} {#Version}
AppPublisher={#MyPublisher}
AppCopyright={#MyCopyright}
VersionInfoCompany={#MyPublisher}
VersionInfoDescription={#MyAppName} - Setup
VersionInfoCopyright={#MyCopyright}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#Version}
VersionInfoVersion={#Version}
VersionInfoOriginalFileName=UNLOCK-DIGITAL-AdskDoctor-Setup-{#Version}.exe
DefaultDirName={autopf}\UNLOCK DIGITAL\AdskDoctor
DefaultGroupName=UNLOCK DIGITAL
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=UNLOCK-DIGITAL-AdskDoctor-Setup-{#Version}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\AdskDoctor.ico
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#LicenseFile}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyExe}"; IconFilename: "{app}\AdskDoctor.ico"; WorkingDir: "{app}"; Comment: "{#MyPublisher} - {#MyAppName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyExe}"; IconFilename: "{app}\AdskDoctor.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyExe}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; A scan writes report.html / report.json next to the application. Removing them
; lets Inno Setup delete the now-empty folder, so an uninstall leaves nothing
; behind. Anything else the user generated (backups\, exported reports) is kept
; on purpose - it is their data.
[UninstallDelete]
Type: files; Name: "{app}\report.html"
Type: files; Name: "{app}\report.json"
