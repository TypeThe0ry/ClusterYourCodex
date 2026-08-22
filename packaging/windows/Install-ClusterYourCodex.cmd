@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CYC_PREVIEW_ROOT=%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CYC_PREVIEW_ROOT%bootstrap.ps1" -Action Install -BundleRoot "%CYC_PREVIEW_ROOT%payload"
set "CYC_EXIT_CODE=%ERRORLEVEL%"
if not "%CYC_EXIT_CODE%"=="0" (
  echo.
  echo ClusterYourCodex installation failed with exit code %CYC_EXIT_CODE%.
  echo No controller token or worker credential was printed or passed on this command line.
  pause
  exit /b %CYC_EXIT_CODE%
)

echo ClusterYourCodex installed for the current user.
start "" "%LOCALAPPDATA%\Programs\ClusterYourCodex\ClusterYourCodex.exe"
exit /b 0
