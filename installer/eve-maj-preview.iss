#define MyAppName "EVE-Maj Preview"
#define MyAppPublisher "mrmjstc"
#define MyAppURL "https://github.com/mrmjstc/eve-maj-preview"
#define MyAppExeName "eve-maj-preview.exe"
#define BinDir "..\zig-out\bin"
#define AppMutexName "Global\EVE-Maj-Preview-SingleInstance"
; The separate config.exe older versions shipped, which may still be open during an upgrade.
#define LegacyConfigMutexName "Global\EVE-Maj-Preview-ConfigDialog-SingleInstance"

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
; Detect the running app (and an old version's config dialog) via their
; single-instance mutexes and prompt to close them, and also let Setup
; auto-close anything still holding a lock on the files it's about to
; overwrite (Restart Manager).
AppMutex={#AppMutexName},{#LegacyConfigMutexName}
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=eve-maj-preview-v{#MyAppVersion}-setup
SetupIconFile=..\src\assets\icon.ico
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
Source: "..\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\{#MyAppName} Configuration"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--config"; WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyAppExeName}"; Parameters: "--config"; WorkingDir: "{app}"; Description: "Open the configuration window"; Flags: nowait postinstall skipifsilent unchecked

[InstallDelete]
; Older versions shipped the configuration window as a separate exe.
Type: files; Name: "{app}\config.exe"
; Older versions installed licenses next to the exe.
Type: files; Name: "{app}\LICENSE"
Type: files; Name: "{app}\WebView2Loader-LICENSE.txt"
Type: files; Name: "{app}\CascadiaCode-LICENSE.txt"
Type: files; Name: "{app}\webui-LICENSE.txt"
; Older versions used webui, which needed WebView2Loader.dll.
Type: files; Name: "{app}\WebView2Loader.dll"
Type: files; Name: "{app}\licenses\WebView2Loader-LICENSE.txt"
Type: files; Name: "{app}\licenses\webui-LICENSE.txt"
; Older versions drew the configuration window with webview and WebView2.
Type: files; Name: "{app}\licenses\webview-LICENSE.txt"
Type: files; Name: "{app}\licenses\WebView2-LICENSE.txt"

; Profiles, settings and logs are created next to the exe at runtime (see
; docs/BUILDING.md) and deliberately left in place on uninstall so a
; reinstall/upgrade doesn't wipe user configuration.
