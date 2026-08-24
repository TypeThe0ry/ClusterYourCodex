Unicode true

!include "LogicLib.nsh"
!include "MUI2.nsh"

!ifndef CYC_PACKAGE_ROOT
  !error "CYC_PACKAGE_ROOT is required"
!endif
!ifndef CYC_OUTPUT
  !error "CYC_OUTPUT is required"
!endif
!ifdef CYC_REQUIRE_SIGNATURE
  !define CYC_SIGNATURE_ARGUMENT "-RequirePackageSignature"
!else
  !define CYC_SIGNATURE_ARGUMENT ""
!endif

Name "ClusterYourCodex"
OutFile "${CYC_OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\ClusterYourCodex"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
ShowInstDetails show
BrandingText "ClusterYourCodex"

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\cyc-package"
  File /r "${CYC_PACKAGE_ROOT}\*.*"

  DetailPrint "Validating package for the initiating user; only the firewall step will request UAC..."
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\cyc-package\Invoke-ClusterYourCodexLifecycle.ps1" -Action Install -BundleRoot "$PLUGINSDIR\cyc-package\payload" -PackageRoot "$PLUGINSDIR\cyc-package" -PackageManifest "$PLUGINSDIR\cyc-package\preview-manifest.json" -PackageExecutable "$EXEPATH" ${CYC_SIGNATURE_ARGUMENT} -NoLaunch' $0
  ${If} $0 != 0
    DetailPrint "ClusterYourCodex bootstrap failed with exit code $0."
    SetErrorLevel $0
    MessageBox MB_OK|MB_ICONSTOP "ClusterYourCodex installation failed (exit $0). Existing installation state was rolled back." /SD IDOK
    Quit
  ${EndIf}

  DetailPrint "ClusterYourCodex installation completed."
  IfSilent silent_complete
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\ClusterYourCodex.exe"'
silent_complete:
SectionEnd
