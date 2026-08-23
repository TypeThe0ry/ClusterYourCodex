@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CYC_PREVIEW_ROOT=%~dp0"

rem Stay in the initiating desktop token. Only the coordinator's fixed
rem firewall helper requests elevation; HKCU/profile/tasks/files never do.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
  -File "%CYC_PREVIEW_ROOT%Invoke-ClusterYourCodexLifecycle.ps1" ^
  -Action Install ^
  -BundleRoot "%CYC_PREVIEW_ROOT%payload" ^
  -PackageRoot "%CYC_PREVIEW_ROOT%" ^
  -PackageManifest "%CYC_PREVIEW_ROOT%preview-manifest.json" ^
  -NoLaunch
set "CYC_EXIT_CODE=%ERRORLEVEL%"
if not "%CYC_EXIT_CODE%"=="0" (
  echo.
  echo ClusterYourCodex installation failed with exit code %CYC_EXIT_CODE%.
  echo The initiating user profile was preserved and the firewall transaction remains retryable.
  exit /b %CYC_EXIT_CODE%
)

echo ClusterYourCodex installed for the initiating user.
explorer.exe "%LOCALAPPDATA%\Programs\ClusterYourCodex\ClusterYourCodex.exe"
exit /b 0
