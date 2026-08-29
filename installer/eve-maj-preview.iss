#define MyAppName "EVE-Maj Preview"
#define MyAppPublisher "mrmjstc"
#define MyAppURL "https://github.com/mrmjstc/eve-maj-preview"
#define MyAppExeName "eve-maj-preview.exe"
#define MyConfigExeName "config.exe"
#define BinDir "..\zig-out\bin"

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

[Setup]
AppId={{250B696E-4677-48C1-B75B-F8B810155B6D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Always installs per-user under AppData, never the UAC-protected Program
; Files, since the app reads/writes profiles, settings, and its log next to
; the exe.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=eve-maj-preview-v{#MyAppVersion}-setup
SetupIconFile=..\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BinDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\{#MyConfigExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\icon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\WebView2Loader.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\WebView2Loader-LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\{#MyAppName} Configuration"; Filename: "{app}\{#MyConfigExeName}"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyConfigExeName}"; WorkingDir: "{app}"; Description: "Open the configuration dialog"; Flags: nowait postinstall skipifsilent unchecked

; Profiles, settings and logs are created next to the exe at runtime (see
; docs/BUILDING.md) and deliberately left in place on uninstall so a
; reinstall/upgrade doesn't wipe user configuration.
