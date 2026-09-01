::Build the OHPM-publishable HAR (@ylong-rs/ohrs-ability) on top of pack.bat.
::
:: Runs the normal dev pack first (aggregated `ability.har` for local file:
:: consumption), then stamps the publish identity ONLY onto the generated
:: files inside `package/` — the canonical source in `native_ability/` keeps
:: the upstream identity, so nothing has to be reverted after publishing.
:: Result: `ohrs-ability-<version>.har` next to `ability.har`.
::
:: Same invocation caveat as pack.bat: run it through cmd.exe. Direct git
:: bash / PowerShell runs can silently eat the first 2 chars of every .bat
:: line and fake success.
set SCRIPT_DIR=%~dp0

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%pack-publish.ps1" "%SCRIPT_DIR%"
if errorlevel 1 (
  echo [pack-publish] failed 1>&2
  exit /b 1
)
