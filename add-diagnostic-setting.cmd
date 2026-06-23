@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM  add-diagnostic-setting.cmd
REM
REM  给指定 Azure 资源添加 Diagnostic Setting（仅 RequestResponse 日志，不做 archive retention）。
REM  两个目标:
REM    (1) Storage Account（归档，禁用 Shared Key，仅 Entra ID 鉴权）
REM    (2) Log Analytics workspace
REM  存储账户/工作区都会先检查是否存在，不存在则新建。
REM  存储账户会配置生命周期规则，诊断日志（insights-logs-* 容器）在修改 RETENTION_DAYS 天后自动删除。
REM  资源组(RESOURCE_GROUP)与区域(LOCATION)根据资源名称自动获取。
REM  幂等：可重复执行。
REM
REM  说明: 诊断设置写入存储账户由 Azure 平台的受信任 Microsoft 服务完成，
REM        不需要在存储账户 IAM 上为 Azure Monitor 配置任何 RBAC 角色，禁用 Shared Key 也照常工作。
REM        （已通过真实环境 mcaps8d59a29a335d797a 验证：shared key 禁用、无 Monitor 角色，归档仍正常。）
REM
REM  用法:
REM    add-diagnostic-setting.cmd <STORAGE_ACCOUNT> <WORKSPACE_NAME>
REM
REM  参数:
REM    STORAGE_ACCOUNT     (必填) 存储账户名（全局唯一，3-24位小写字母数字）
REM    WORKSPACE_NAME      (必填) Log Analytics workspace 名称
REM
REM  依赖：Azure CLI (az)，并已执行 `az login`。
REM ============================================================================

REM ============================== 固定配置（按需修改） =========================
set "RESOURCE_NAME=admin-3283-resource"
set "DIAG_NAME=requestresponse-diag"
set "LOG_CATEGORY=RequestResponse"
set "RETENTION_DAYS=90"
REM ============================================================================

REM ============================== 命令行参数 ==================================
set "STORAGE_ACCOUNT=%~1"
set "WORKSPACE_NAME=%~2"
REM RESOURCE_GROUP 与 LOCATION 由步骤 [1] 根据资源名称自动解析
set "RESOURCE_GROUP="
set "LOCATION="

if "%STORAGE_ACCOUNT%"=="" goto :usage
if "%WORKSPACE_NAME%"=="" goto :usage
goto :start

:usage
echo.
echo 用法: %~nx0 ^<STORAGE_ACCOUNT^> ^<WORKSPACE_NAME^>
echo.
echo   STORAGE_ACCOUNT     (必填) 存储账户名（全局唯一，3-24位小写字母数字）
echo   WORKSPACE_NAME      (必填) Log Analytics workspace 名称
echo.
echo   （资源组与区域根据资源名称 %RESOURCE_NAME% 自动获取）
echo.
echo 示例: %~nx0 mydiagstore001 mydiag-workspace
exit /b 2

:start
echo.
echo === [0/5] 检查 Azure CLI 登录状态 ===
call az account show >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未登录 Azure，请先执行: az login
    exit /b 1
)

REM --------------------------------------------------------------------------
echo.
echo === [1/5] 根据资源名称解析 ID / 资源组 / 区域: %RESOURCE_NAME% ===
set "RESOURCE_COUNT=0"
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "length(@)" -o tsv 2^>nul') do set "RESOURCE_COUNT=%%i"
if "%RESOURCE_COUNT%"=="0" (
    echo [ERROR] 找不到资源 %RESOURCE_NAME%，请确认名称及当前订阅。
    exit /b 1
)
if not "%RESOURCE_COUNT%"=="1" (
    echo [ERROR] 发现 %RESOURCE_COUNT% 个同名资源 "%RESOURCE_NAME%"，无法确定目标。
    echo         请改用完整 Resource ID，或在订阅中消除重名。匹配到的资源如下：
    az resource list --name "%RESOURCE_NAME%" --query "[].{name:name, type:type, resourceGroup:resourceGroup, location:location}" -o table
    exit /b 1
)
set "RESOURCE_ID="
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].id" -o tsv 2^>nul') do set "RESOURCE_ID=%%i"
if "%RESOURCE_ID%"=="" (
    echo [ERROR] 无法解析资源 ID。
    exit /b 1
)
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].resourceGroup" -o tsv 2^>nul') do set "RESOURCE_GROUP=%%i"
for /f "delims=" %%i in ('az resource list --name "%RESOURCE_NAME%" --query "[0].location" -o tsv 2^>nul') do set "LOCATION=%%i"
if "%RESOURCE_GROUP%"=="" (
    echo [ERROR] 无法解析资源所属的资源组。
    exit /b 1
)
if "%LOCATION%"=="" (
    echo [ERROR] 无法解析资源所属的区域。
    exit /b 1
)
echo     RESOURCE_ID    = %RESOURCE_ID%
echo     RESOURCE_GROUP = %RESOURCE_GROUP%
echo     LOCATION       = %LOCATION%

REM --------------------------------------------------------------------------
echo.
echo === [2/5] 检查 Storage Account 是否存在（不存在则创建，禁用 Shared Key） ===
call az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" >nul 2>&1
if errorlevel 1 (
    echo     不存在，正在创建 Storage Account: %STORAGE_ACCOUNT% ...
    call az storage account create ^
        --name "%STORAGE_ACCOUNT%" ^
        --resource-group "%RESOURCE_GROUP%" ^
        --location "%LOCATION%" ^
        --sku Standard_LRS ^
        --kind StorageV2 ^
        --min-tls-version TLS1_2 ^
        --allow-blob-public-access false ^
        --allow-shared-key-access false 1>nul
    if errorlevel 1 (
        echo [ERROR] 创建 Storage Account 失败。
        exit /b 1
    )
    echo     已创建（Shared Key 已禁用）。
) else (
    echo     已存在。检查 Shared Key 是否已禁用 ...
    set "SHARED_KEY_ENABLED="
    for /f "delims=" %%i in ('az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --query "allowSharedKeyAccess" -o tsv') do set "SHARED_KEY_ENABLED=%%i"
    if /i "!SHARED_KEY_ENABLED!"=="true" (
        echo     当前允许 Shared Key，正在禁用 ...
        call az storage account update --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --allow-shared-key-access false 1>nul
        if errorlevel 1 (
            echo [ERROR] 禁用 Shared Key 失败。
            exit /b 1
        )
        echo     已禁用 Shared Key。
    ) else (
        echo     Shared Key 已是禁用状态。
    )
)

set "STORAGE_ID="
for /f "delims=" %%i in ('az storage account show --name "%STORAGE_ACCOUNT%" --resource-group "%RESOURCE_GROUP%" --query id -o tsv') do set "STORAGE_ID=%%i"
if "%STORAGE_ID%"=="" (
    echo [ERROR] 无法获取 Storage Account ID。
    exit /b 1
)
echo     STORAGE_ID = %STORAGE_ID%

REM --------------------------------------------------------------------------
echo.
echo === [2b/5] 配置存储账户生命周期规则（诊断日志 %RETENTION_DAYS% 天后删除） ===
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
    echo [ERROR] 配置生命周期规则失败。
    del "%POLICY_FILE%" >nul 2>&1
    exit /b 1
)
del "%POLICY_FILE%" >nul 2>&1
echo     已配置: insights-logs-* 容器中的 blob，修改 %RETENTION_DAYS% 天后自动删除。

REM --------------------------------------------------------------------------
echo.
echo === [3/5] 检查 Log Analytics workspace 是否存在（不存在则创建） ===
call az monitor log-analytics workspace show --resource-group "%RESOURCE_GROUP%" --workspace-name "%WORKSPACE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo     不存在，正在创建 workspace: %WORKSPACE_NAME% ...
    call az monitor log-analytics workspace create ^
        --resource-group "%RESOURCE_GROUP%" ^
        --workspace-name "%WORKSPACE_NAME%" ^
        --location "%LOCATION%" 1>nul
    if errorlevel 1 (
        echo [ERROR] 创建 Log Analytics workspace 失败。
        exit /b 1
    )
    echo     已创建。
) else (
    echo     已存在，跳过创建。
)

set "WORKSPACE_ID="
for /f "delims=" %%i in ('az monitor log-analytics workspace show --resource-group "%RESOURCE_GROUP%" --workspace-name "%WORKSPACE_NAME%" --query id -o tsv') do set "WORKSPACE_ID=%%i"
if "%WORKSPACE_ID%"=="" (
    echo [ERROR] 无法获取 Log Analytics workspace ID。
    exit /b 1
)
echo     WORKSPACE_ID = %WORKSPACE_ID%

REM --------------------------------------------------------------------------
echo.
echo === [4/5] 生成诊断设置日志配置（仅 %LOG_CATEGORY%，不带 retention/archive） ===
set "LOGS_FILE=%TEMP%\diag-logs-%RANDOM%.json"
> "%LOGS_FILE%" echo [{ "category": "%LOG_CATEGORY%", "enabled": true }]
echo     LOGS_FILE = %LOGS_FILE%
type "%LOGS_FILE%"

REM --------------------------------------------------------------------------
echo.
echo === [5/5] 创建/更新 Diagnostic Setting: %DIAG_NAME% ===
call az monitor diagnostic-settings show --name "%DIAG_NAME%" --resource "%RESOURCE_ID%" >nul 2>&1
if errorlevel 1 (
    echo     不存在，正在创建 ...
) else (
    echo     已存在，将更新（重新创建）...
    call az monitor diagnostic-settings delete --name "%DIAG_NAME%" --resource "%RESOURCE_ID%" 1>nul 2>&1
)

call az monitor diagnostic-settings create ^
    --name "%DIAG_NAME%" ^
    --resource "%RESOURCE_ID%" ^
    --storage-account "%STORAGE_ID%" ^
    --workspace "%WORKSPACE_ID%" ^
    --logs @"%LOGS_FILE%" 1>nul
if errorlevel 1 (
    echo [ERROR] 创建 Diagnostic Setting 失败。请确认资源类型支持 "%LOG_CATEGORY%" 日志类别。
    del "%LOGS_FILE%" >nul 2>&1
    exit /b 1
)

del "%LOGS_FILE%" >nul 2>&1
echo.
echo === 完成: 已为 %RESOURCE_NAME% 配置 Diagnostic Setting ===
echo     %LOG_CATEGORY% -^> Storage: %STORAGE_ACCOUNT%（Shared Key 禁用, %RETENTION_DAYS% 天后删除） + Log Analytics: %WORKSPACE_NAME%
endlocal
exit /b 0
