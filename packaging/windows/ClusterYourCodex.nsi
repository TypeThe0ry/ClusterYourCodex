Unicode true

!include "LogicLib.nsh"
!include "MUI2.nsh"

!ifndef CYC_PACKAGE_ROOT
  !error "CYC_PACKAGE_ROOT is required"
!endif
!ifndef CYC_OUTPUT
  !error "CYC_OUTPUT is required"
!endif
!ifndef CYC_MAX_PACKAGE_RELATIVE_PATH
  !error "CYC_MAX_PACKAGE_RELATIVE_PATH is required"
!endif
!if ${CYC_MAX_PACKAGE_RELATIVE_PATH} > 190
  !error "CYC_MAX_PACKAGE_RELATIVE_PATH exceeds the supported 190-character limit"
!endif
!ifdef CYC_REQUIRE_SIGNATURE
  !define CYC_SIGNATURE_ARGUMENT "-RequirePackageSignature"
!else
  !define CYC_SIGNATURE_ARGUMENT ""
!endif

!define CYC_EXIT_SHORT_STAGING 90
!define CYC_EXIT_EXTRACTION 91
!define CYC_EXIT_LIFECYCLE_LAUNCH 92
!define CYC_EXIT_CLEANUP 93

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

Var CycMappedDrive
Var CycLogicalDriveMask
Var CycMappingCreated
Var CycMappingOwned
Var CycSentinelName
Var CycSentinelToken
Var CycSentinelReady
Var CycPrimaryExit
Var CycCleanupExit

!macro CYC_RECORD_CLEANUP_FAILURE
  StrCmp $CycCleanupExit "0" 0 +2
  StrCpy $CycCleanupExit ${CYC_EXIT_CLEANUP}
!macroend

; A candidate is considered ours only after subst.exe returns success and the
; sentinel written through the original $PLUGINSDIR is readable with the same
; contents through the short drive. A failed candidate is never detached.
!macro CYC_TRY_SUBST_DRIVE LETTER MASK
  StrCmp $CycMappingCreated "0" 0 cyc_try_${LETTER}_done
  IntOp $0 $CycLogicalDriveMask & ${MASK}
  StrCmp $0 "0" 0 cyc_try_${LETTER}_done
  StrCpy $CycMappedDrive "${LETTER}:"
  nsExec::ExecToStack '"$SYSDIR\subst.exe" "$CycMappedDrive" "$PLUGINSDIR"'
  Pop $1
  Pop $2
  StrCmp $1 "0" 0 cyc_try_${LETTER}_failed
  StrCpy $CycMappingCreated "1"
  Call CycVerifyMappingOwnership
  Goto cyc_try_${LETTER}_done
cyc_try_${LETTER}_failed:
  StrCpy $CycMappedDrive ""
cyc_try_${LETTER}_done:
!macroend

Function CycVerifyMappingOwnership
  StrCpy $CycMappingOwned "0"
  StrCmp $CycMappingCreated "1" 0 cyc_verify_mapping_done
  StrCmp $CycMappedDrive "" cyc_verify_mapping_done
  ClearErrors
  FileOpen $0 "$CycMappedDrive\$CycSentinelName" r
  IfErrors cyc_verify_mapping_done
  FileRead $0 $1
  FileClose $0
  StrCmp $1 $CycSentinelToken 0 cyc_verify_mapping_done
  StrCpy $CycMappingOwned "1"
cyc_verify_mapping_done:
FunctionEnd

Function CycPrepareShortStaging
  StrCpy $CycMappedDrive ""
  StrCpy $CycMappingCreated "0"
  StrCpy $CycMappingOwned "0"
  StrCpy $CycSentinelReady "0"
  StrCpy $CycSentinelName ".cyc-subst-owner"
  StrCpy $CycSentinelToken "ClusterYourCodex|${CYC_MAX_PACKAGE_RELATIVE_PATH}|$PLUGINSDIR"

  ClearErrors
  FileOpen $0 "$PLUGINSDIR\$CycSentinelName" w
  IfErrors cyc_prepare_short_staging_done
  ClearErrors
  FileWrite $0 "$CycSentinelToken"
  IfErrors cyc_prepare_short_staging_close
  StrCpy $CycSentinelReady "1"
cyc_prepare_short_staging_close:
  FileClose $0
  StrCmp $CycSentinelReady "1" 0 cyc_prepare_short_staging_done

  System::Call 'kernel32::GetLogicalDrives() i .r0'
  StrCpy $CycLogicalDriveMask $0
  !insertmacro CYC_TRY_SUBST_DRIVE Z 0x02000000
  !insertmacro CYC_TRY_SUBST_DRIVE Y 0x01000000
  !insertmacro CYC_TRY_SUBST_DRIVE X 0x00800000
  !insertmacro CYC_TRY_SUBST_DRIVE W 0x00400000
  !insertmacro CYC_TRY_SUBST_DRIVE V 0x00200000
  !insertmacro CYC_TRY_SUBST_DRIVE U 0x00100000
  !insertmacro CYC_TRY_SUBST_DRIVE T 0x00080000
  !insertmacro CYC_TRY_SUBST_DRIVE S 0x00040000
  !insertmacro CYC_TRY_SUBST_DRIVE R 0x00020000
  !insertmacro CYC_TRY_SUBST_DRIVE Q 0x00010000
cyc_prepare_short_staging_done:
FunctionEnd

; Cleanup is deliberately idempotent. It leaves the mapped drive before doing
; anything else, proves ownership again with the sentinel, removes the deep
; package through the short alias, and only then detaches a mapping it still
; owns. The sentinel remains present until subst /D succeeds so .onGUIEnd can
; safely retry a transient detach failure without touching a user mapping.
Function CycCleanupShortStaging
  StrCpy $CycCleanupExit "0"
  ; .onGUIEnd can run before the install section initialized $PLUGINSDIR.
  ; With neither a mapping nor a sentinel there is nothing safe to clean.
  StrCmp $CycMappingCreated "1" cyc_cleanup_begin
  StrCmp $CycSentinelReady "1" cyc_cleanup_begin
  Goto cyc_cleanup_done
cyc_cleanup_begin:
  ClearErrors
  SetOutPath "$PLUGINSDIR"
  IfErrors cyc_cleanup_outdir_failed cyc_cleanup_outdir_ready
cyc_cleanup_outdir_failed:
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
cyc_cleanup_outdir_ready:

  StrCmp $CycMappingCreated "1" cyc_cleanup_verify_mapping cyc_cleanup_unmapped
cyc_cleanup_verify_mapping:
  Call CycVerifyMappingOwnership
  StrCmp $CycMappingOwned "1" cyc_cleanup_remove_package
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
  Goto cyc_cleanup_done

cyc_cleanup_remove_package:
  ClearErrors
  RMDir /r "$CycMappedDrive\p"
  IfErrors cyc_cleanup_package_failed cyc_cleanup_reverify_mapping
cyc_cleanup_package_failed:
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
  ; Keep the verified mapping and sentinel so .onGUIEnd can retry the
  ; short-path deletion. Detaching here would strand a deep package beneath
  ; $PLUGINSDIR and defeat the long-path-safe cleanup path.
  Goto cyc_cleanup_done

cyc_cleanup_reverify_mapping:
  ; RMDir must have removed the package root, not merely returned without an
  ; error. Fail closed and retain the mapping when anything remains.
  IfFileExists "$CycMappedDrive\p" cyc_cleanup_package_failed
  ; Re-read the sentinel immediately before subst /D. If the drive was
  ; replaced or redirected after extraction, fail closed and leave it alone.
  Call CycVerifyMappingOwnership
  StrCmp $CycMappingOwned "1" cyc_cleanup_detach_mapping
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
  Goto cyc_cleanup_done

cyc_cleanup_detach_mapping:
  nsExec::ExecToStack '"$SYSDIR\subst.exe" "$CycMappedDrive" /D'
  Pop $0
  Pop $1
  StrCmp $0 "0" cyc_cleanup_detached
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
  Goto cyc_cleanup_done

cyc_cleanup_detached:
  StrCpy $CycMappingCreated "0"
  StrCpy $CycMappingOwned "0"
  StrCpy $CycMappedDrive ""

cyc_cleanup_unmapped:
  StrCmp $CycSentinelReady "1" 0 cyc_cleanup_done
  IfFileExists "$PLUGINSDIR\$CycSentinelName" 0 cyc_cleanup_sentinel_deleted
  ClearErrors
  Delete "$PLUGINSDIR\$CycSentinelName"
  IfErrors cyc_cleanup_sentinel_failed cyc_cleanup_sentinel_deleted
cyc_cleanup_sentinel_failed:
  !insertmacro CYC_RECORD_CLEANUP_FAILURE
  Goto cyc_cleanup_done
cyc_cleanup_sentinel_deleted:
  StrCpy $CycSentinelReady "0"

cyc_cleanup_done:
FunctionEnd

Function .onGUIEnd
  ; Best-effort backstop for GUI cancellation and transient cleanup failures.
  Call CycCleanupShortStaging
FunctionEnd

Section "Install"
  StrCpy $CycPrimaryExit "0"
  StrCpy $CycCleanupExit "0"
  StrCpy $CycMappingCreated "0"
  StrCpy $CycMappingOwned "0"
  StrCpy $CycSentinelReady "0"

  InitPluginsDir
  Call CycPrepareShortStaging
  StrCmp $CycMappingOwned "1" cyc_short_staging_ready
  DetailPrint "Unable to create a verified short-path package staging drive."
  StrCpy $CycPrimaryExit ${CYC_EXIT_SHORT_STAGING}
  Goto cyc_install_finalize

cyc_short_staging_ready:
  ClearErrors
  SetOutPath "$CycMappedDrive\p"
  IfErrors cyc_package_extraction_failed
  ClearErrors
  File /r "${CYC_PACKAGE_ROOT}\*.*"
  IfErrors cyc_package_extraction_failed cyc_package_extraction_complete

cyc_package_extraction_failed:
  DetailPrint "ClusterYourCodex package extraction failed."
  StrCpy $CycPrimaryExit ${CYC_EXIT_EXTRACTION}
  Goto cyc_install_finalize

cyc_package_extraction_complete:
  DetailPrint "Validating package for the initiating user; only the firewall step will request UAC..."
  ClearErrors
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$CycMappedDrive\p\Invoke-ClusterYourCodexLifecycle.ps1" -Action Install -BundleRoot "$CycMappedDrive\p\payload" -PackageRoot "$CycMappedDrive\p" -PackageManifest "$CycMappedDrive\p\preview-manifest.json" -PackageExecutable "$EXEPATH" ${CYC_SIGNATURE_ARGUMENT} -NoLaunch' $0
  IfErrors cyc_lifecycle_launch_failed cyc_lifecycle_finished

cyc_lifecycle_launch_failed:
  DetailPrint "ClusterYourCodex lifecycle process could not be launched."
  StrCpy $CycPrimaryExit ${CYC_EXIT_LIFECYCLE_LAUNCH}
  Goto cyc_install_finalize

cyc_lifecycle_finished:
  StrCpy $CycPrimaryExit $0
  StrCmp $CycPrimaryExit "0" cyc_install_finalize
  DetailPrint "ClusterYourCodex bootstrap failed with exit code $CycPrimaryExit."

cyc_install_finalize:
  Call CycCleanupShortStaging
  StrCmp $CycPrimaryExit "0" cyc_check_cleanup
  ; Keep the first extraction/lifecycle error even if cleanup also failed.
  StrCpy $0 $CycPrimaryExit
  SetErrorLevel $0
  MessageBox MB_OK|MB_ICONSTOP "ClusterYourCodex installation failed (exit $0). Existing installation state was rolled back." /SD IDOK
  Quit

cyc_check_cleanup:
  StrCmp $CycCleanupExit "0" cyc_install_complete
  StrCpy $0 $CycCleanupExit
  SetErrorLevel $0
  MessageBox MB_OK|MB_ICONSTOP "ClusterYourCodex installation completed, but secure temporary-drive cleanup failed (exit $0)." /SD IDOK
  Quit

cyc_install_complete:
  DetailPrint "ClusterYourCodex installation completed."
  IfSilent silent_complete
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\ClusterYourCodex.exe"'
silent_complete:
SectionEnd
