@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  add-diagnostic-setting.cmd
REM
REM  Add a Diagnostic Setting to an Azure resource (RequestResponse logs only,
REM  no archive retention on the setting itself). Two destinations:
REM    (1) Storage Account (archive; Shared Key disabled, Entra ID auth only)
REM    (2) Log Analytics workspace
REM  Both the storage account and the workspace are checked first and created
REM  if missing. The storage account gets a lifecycle rule so diagnostic logs
REM  (insights-logs-* containers) are auto-deleted after RETENTION_DAYS days.
REM  Resource group (RESOURCE_GROUP) and region (LOCATION) are resolved
REM  automatically from the resource name. Idempotent: safe to re-run.
REM
REM  Note: writing diagnostic logs to the storage account is performed by
REM        trusted Microsoft services on the Azure platform, so no RBAC role
REM        for Azure Monitor is required on the storage account IAM and
REM        archiving still works with Shared Key disabled.
REM
REM  IMPORTANT: This file is intentionally ASCII-only (English). cmd.exe cannot
REM        reliably parse batch files that contain non-ASCII (e.g. Chinese)
REM        text - UTF-8 misaligns multi-byte sequences and GBK trailing bytes
REM        collide with special characters (\ | < > ^ &), both of which make
REM        the parser eat characters. Keeping this script ASCII-only lets it
REM        run correctly on any Windows locale / code page.
REM
REM  Usage:
REM    add-diagnostic-setting.cmd <RESOURCE_NAME>
REM
REM  Parameters:
REM    RESOURCE_NAME       (required) Target Azure resource name
REM                        (resource group and region are auto-resolved)
REM
REM  Set the storage account and Log Analytics workspace names in the
REM  "Configurable settings" block at the top of this script.
REM
REM  Requires: Azure CLI (az) and a prior `az login`.
REM ============================================================================

REM ============================== Configurable settings =======================
REM STORAGE_ACCOUNT empty = auto-derive a globally-unique name (diag + short
REM   resource name + hash of RESOURCE_ID). Same resource -> same name (idempotent);
REM   different resources never collide. Set a fixed name here if you prefer.
set "STORAGE_ACCOUNT="
REM WORKSPACE_NAME empty = auto-derive a dedicated workspace name (one per
REM   resource, easy to manage, idempotent). Set a fixed name here to share one
REM   workspace across multiple resources.
set "WORKSPACE_NAME="
set "DIAG_NAME=requestresponse-diag"
set "LOG_CATEGORY=RequestResponse"
set "RETENTION_DAYS=90"
REM ============================================================================

REM ============================== Command-line arguments ======================
set "RESOURCE_NAME=%~1"
REM RESOURCE_GROUP and LOCATION are resolved in step [1] from the resource name
set "RESOURCE_GROUP="
set "LOCATION="

if "%RESOURCE_NAME%"=="" goto :usage
goto :start

:usage
echo.
echo Usage: %~nx0 ^<RESOURCE_NAME^>
echo.
echo   RESOURCE_NAME       (required) Target Azure resource name
echo                       (resource group and region are auto-resolved)
echo.
echo   Storage account / workspace: when left empty in the header block, names
echo            are auto-derived per resource (idempotent, one set each). Set a
echo            fixed / shared name via STORAGE_ACCOUNT / WORKSPACE_NAME.
echo.
echo Example: %~nx0 admin-3283-resource
exit /b 2

:start
echo.
echo === [0/5] Checking Azure CLI login state ===
call az account show >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Not logged in to Azure. Run: az login
    exit /b 1
)

REM --------------------------------------------------------------------------
echo.
echo === [0b/5] Ensuring required resource providers are registered ===
REM Log Analytics needs Microsoft.OperationalInsights, diagnostic settings need
REM Microsoft.Insights, and the storage account needs Microsoft.Storage. If a
REM provider is not registered, creating the workspace fails with errors like
REM "Resource provider 'Microsoft.OperationalInsights' ... is not registered".
call :ensure_provider Microsoft.Storage
call :ensure_provider Microsoft.OperationalInsights
call :ensure_provider Microsoft.Insights

REM --------------------------------------------------------------------------
echo.
echo === [1/5] Resolving ID / resource group / region for: %RESOURCE_NAME% ===
set "RESOURCE_COUNT=0"
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "length(@)" -o tsv 2^>nul') do set "RESOURCE_COUNT=%%i"
if "%RESOURCE_COUNT%"=="0" (
    echo [ERROR] Resource %RESOURCE_NAME% not found. Check the name and current subscription.
    exit /b 1
)
if not "%RESOURCE_COUNT%"=="1" (
    echo [ERROR] Found %RESOURCE_COUNT% resources named "%RESOURCE_NAME%"; target is ambiguous.
    echo         Use the full Resource ID, or remove the name collision. Matches:
    az resource list --name "%RESOURCE_NAME%" --query "[].{name:name, type:type, resourceGroup:resourceGroup, location:location}" -o table
    exit /b 1
)
set "RESOURCE_ID="
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].id" -o tsv 2^>nul') do set "RESOURCE_ID=%%i"
if "%RESOURCE_ID%"=="" (
    echo [ERROR] Could not resolve the resource ID.
    exit /b 1
)
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].resourceGroup" -o tsv 2^>nul') do set "RESOURCE_GROUP=%%i"
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].location" -o tsv 2^>nul') do set "LOCATION=%%i"
if "%RESOURCE_GROUP%"=="" (
    echo [ERROR] Could not resolve the resource group.
    exit /b 1
)
if "%LOCATION%"=="" (
    echo [ERROR] Could not resolve the resource region.
    exit /b 1
)
echo     RESOURCE_ID    = %RESOURCE_ID%
echo     RESOURCE_GROUP = %RESOURCE_GROUP%
echo     LOCATION       = %LOCATION%

REM Auto-derive a globally-unique storage account name bound to the resource
REM (used when STORAGE_ACCOUNT is empty; idempotent).
if "%STORAGE_ACCOUNT%"=="" (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "$n=(\"%RESOURCE_NAME%\").ToLower() -replace '[^a-z0-9]',''; if($n.Length -gt 12){$n=$n.Substring(0,12)}; $h=[BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(\"%RESOURCE_ID%\"))).Replace('-','').ToLower().Substring(0,8); 'diag'+$n+$h"') do set "STORAGE_ACCOUNT=%%i"
    if "!STORAGE_ACCOUNT!"=="" (
        echo [ERROR] Failed to auto-generate a storage account name.
        goto :fail
    )
    echo     STORAGE_ACCOUNT = !STORAGE_ACCOUNT! ^(auto-derived / globally unique^)
) else (
    echo     STORAGE_ACCOUNT = %STORAGE_ACCOUNT% ^(from config^)
)

REM Auto-derive a workspace name bound to the resource (used when WORKSPACE_NAME
REM is empty; one per resource, idempotent).
if "%WORKSPACE_NAME%"=="" (
    for /f "delims=" %%i in ('powershell -NoProfile -Command "$n=(\"%RESOURCE_NAME%\").ToLower() -replace '[^a-z0-9-]','-'; $n=$n.Trim('-'); if($n.Length -gt 30){$n=$n.Substring(0,30).Trim('-')}; $h=[BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(\"%RESOURCE_ID%\"))).Replace('-','').ToLower().Substring(0,6); $n+'-diag-'+$h"') do set "WORKSPACE_NAME=%%i"
    if "!WORKSPACE_NAME!"=="" (
        echo [ERROR] Failed to auto-generate a workspace name.
        goto :fail
    )
    echo     WORKSPACE_NAME  = !WORKSPACE_NAME! ^(auto-derived / per resource^)
) else (
    echo     WORKSPACE_NAME  = %WORKSPACE_NAME% ^(from config^)
)

REM --------------------------------------------------------------------------
echo.
echo === [2/5] Ensuring Storage Account exists (create if missing, Shared Key disabled) ===
call az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" >nul 2>&1
if errorlevel 1 (
    echo     Not found. Creating Storage Account: %STORAGE_ACCOUNT% ...
    call az storage account create ^
        --name "%STORAGE_ACCOUNT%" ^
        --resource-group "%RESOURCE_GROUP%" ^
        --location "%LOCATION%" ^
        --sku Standard_LRS ^
        --kind StorageV2 ^
        --min-tls-version TLS1_2 ^
        --allow-blob-public-access false ^
        --allow-shared-key-access false 1>nul
    if errorlevel 1 goto :fail_storage
    echo     Created ^(Shared Key disabled^).
) else (
    echo     Exists. Checking whether Shared Key is disabled ...
    set "SHARED_KEY_ENABLED="
    for /f "delims=" %%i in ('az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --query "allowSharedKeyAccess" -o tsv') do set "SHARED_KEY_ENABLED=%%i"
    if /i "!SHARED_KEY_ENABLED!"=="true" (
        echo     Shared Key currently allowed; disabling ...
        call az storage account update --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --allow-shared-key-access false 1>nul
        if errorlevel 1 (
            echo [ERROR] Failed to disable Shared Key.
            goto :fail
        )
        echo     Shared Key disabled.
    ) else (
        echo     Shared Key already disabled.
    )
)

set "STORAGE_ID="
for /f "delims=" %%i in ('az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --query id -o tsv') do set "STORAGE_ID=%%i"
if "%STORAGE_ID%"=="" (
    echo [ERROR] Could not get the Storage Account ID.
    exit /b 1
)
echo     STORAGE_ID = %STORAGE_ID%

REM --------------------------------------------------------------------------
echo.
echo === [2b/5] Configuring storage lifecycle rule (delete diagnostic logs after %RETENTION_DAYS% days) ===
set "POLICY_FILE=%TEMP%\lifecycle-policy-%RANDOM%.json"
(
echo {
echo   "rules": [
echo     {
echo       "enabled": true,
echo       "name": "delete-diagnostic-logs-after-%RETENTION_DAYS%d",
echo       "type": "Lifecycle",
echo       "definition": {
echo         "filters": {
echo           "blobTypes": [ "blockBlob", "appendBlob" ],
echo           "prefixMatch": [ "insights-logs-" ]
echo         },
echo         "actions": {
echo           "baseBlob": {
echo             "delete": { "daysAfterModificationGreaterThan": %RETENTION_DAYS% }
echo           }
echo         }
echo       }
echo     }
echo   ]
echo }
) > "%POLICY_FILE%"

call az storage account management-policy create ^
    --account-name "%STORAGE_ACCOUNT%" ^
    --resource-group "%RESOURCE_GROUP%" ^
    --policy @"%POLICY_FILE%" 1>nul
if errorlevel 1 (
    echo [ERROR] Failed to configure the lifecycle rule.
    del "%POLICY_FILE%" >nul 2>&1
    exit /b 1
)
del "%POLICY_FILE%" >nul 2>&1
echo     Configured: blobs in insights-logs-* containers auto-delete %RETENTION_DAYS% days after modification.

REM --------------------------------------------------------------------------
echo.
echo === [3/5] Resolve / reuse / create Log Analytics workspace: %WORKSPACE_NAME% ===
set "WORKSPACE_ID="
set "WS_COUNT=0"
for /f "delims=" %%i in ('az monitor log-analytics workspace list --query "length([?name=='%WORKSPACE_NAME%'])" -o tsv 2^>nul') do set "WS_COUNT=%%i"
if "%WS_COUNT%"=="0" (
    echo     Not present in subscription; creating in %RESOURCE_GROUP% / %LOCATION% ...
    call az monitor log-analytics workspace create ^
        --resource-group "%RESOURCE_GROUP%" ^
        --workspace-name "%WORKSPACE_NAME%" ^
        --location "%LOCATION%" 1>nul
    if errorlevel 1 (
        echo [ERROR] Failed to create the Log Analytics workspace.
        goto :fail
    )
    for /f "delims=" %%i in ('az monitor log-analytics workspace show --resource-group "%RESOURCE_GROUP%" --workspace-name "%WORKSPACE_NAME%" --query id -o tsv') do set "WORKSPACE_ID=%%i"
    echo     Created.
) else if "%WS_COUNT%"=="1" (
    for /f "delims=" %%i in ('az monitor log-analytics workspace list --query "[?name=='%WORKSPACE_NAME%'].id | [0]" -o tsv 2^>nul') do set "WORKSPACE_ID=%%i"
    echo     Exists; reusing ^(idempotent; or shared across resources if a fixed name was set^).
) else (
    echo [ERROR] Found %WS_COUNT% workspaces named "%WORKSPACE_NAME%"; target is ambiguous.
    az monitor log-analytics workspace list --query "[?name=='%WORKSPACE_NAME%'].{name:name, resourceGroup:resourceGroup, location:location}" -o table
    goto :fail
)
if "%WORKSPACE_ID%"=="" (
    echo [ERROR] Could not get the Log Analytics workspace ID.
    goto :fail
)
echo     WORKSPACE_ID = %WORKSPACE_ID%

REM --------------------------------------------------------------------------
echo.
echo === [4/5] Building diagnostic-setting log config (only %LOG_CATEGORY%, no retention/archive) ===
set "LOGS_FILE=%TEMP%\diag-logs-%RANDOM%.json"
> "%LOGS_FILE%" echo [{ "category": "%LOG_CATEGORY%", "enabled": true }]
echo     LOGS_FILE = %LOGS_FILE%
type "%LOGS_FILE%"

REM --------------------------------------------------------------------------
echo.
echo === [5/5] Creating/updating Diagnostic Setting: %DIAG_NAME% ===
call az monitor diagnostic-settings show --name "%DIAG_NAME%" --resource "%RESOURCE_ID%" >nul 2>&1
if errorlevel 1 (
    echo     Not present; creating ...
) else (
    echo     Exists; updating ^(recreate^) ...
    call az monitor diagnostic-settings delete --name "%DIAG_NAME%" --resource "%RESOURCE_ID%" 1>nul 2>&1
)

call az monitor diagnostic-settings create ^
    --name "%DIAG_NAME%" ^
    --resource "%RESOURCE_ID%" ^
    --storage-account "%STORAGE_ID%" ^
    --workspace "%WORKSPACE_ID%" ^
    --logs @"%LOGS_FILE%" 1>nul
if errorlevel 1 (
    echo [ERROR] Failed to create the Diagnostic Setting. Confirm the resource type supports "%LOG_CATEGORY%" logs.
    del "%LOGS_FILE%" >nul 2>&1
    exit /b 1
)

del "%LOGS_FILE%" >nul 2>&1
echo.
echo === Done: Diagnostic Setting configured for %RESOURCE_NAME% ===
echo     %LOG_CATEGORY% -^> Storage: %STORAGE_ACCOUNT% ^(Shared Key disabled, delete after %RETENTION_DAYS% days^) + Log Analytics: %WORKSPACE_NAME%
endlocal
exit /b 0

REM ============================================================================
REM  Subroutine: ensure a resource provider is registered.
REM    %1 = provider namespace (e.g. Microsoft.OperationalInsights)
REM  Registers the provider if needed and waits (up to ~150s) until Registered.
REM ============================================================================
:ensure_provider
set "_PROV=%~1"
set "_STATE="
for /f "delims=" %%i in ('az provider show --namespace "%_PROV%" --query registrationState -o tsv 2^>nul') do set "_STATE=%%i"
if /i "!_STATE!"=="Registered" (
    echo     %_PROV% : Registered
    goto :eof
)
echo     %_PROV% : !_STATE! -^> registering, please wait ...
call az provider register --namespace "%_PROV%" 1>nul 2>&1
set /a _TRIES=0
:ensure_provider_wait
set "_STATE="
for /f "delims=" %%i in ('az provider show --namespace "%_PROV%" --query registrationState -o tsv 2^>nul') do set "_STATE=%%i"
if /i "!_STATE!"=="Registered" (
    echo     %_PROV% : Registered
    goto :eof
)
set /a _TRIES+=1
if !_TRIES! geq 30 (
    echo [WARN] %_PROV% still "!_STATE!" after waiting; continuing anyway.
    goto :eof
)
REM portable ~5s sleep ^(ping avoids timeout's stdin-redirection issues^)
ping -n 6 127.0.0.1 >nul 2>&1
goto :ensure_provider_wait

:fail_storage
echo [ERROR] Failed to create the Storage Account.
echo         The storage account name is globally unique and diagnostic archiving
echo         requires the storage account to be in the same region as resource
echo         "%RESOURCE_NAME%" ^(%LOCATION%^). Set STORAGE_ACCOUNT in the header to an
echo         unused name in %LOCATION% and retry.
goto :fail

:fail
endlocal
exit /b 1
