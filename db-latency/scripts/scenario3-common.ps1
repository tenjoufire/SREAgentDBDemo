$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Get-ScriptPath {
    param([string[]]$Segments)

    $path = $PSScriptRoot
    foreach ($segment in $Segments) {
        $path = Join-Path $path $segment
    }

    return $path
}

function Assert-SqlCmdInstalled {
    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        Write-Verbose "sqlcmd は必須ではありません。アクセストークン接続で初期化を継続します。"
    }
}

function Get-SqlAccessToken {
    return az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
}

function Invoke-SqlBatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlServerName,

        [Parameter(Mandatory = $true)]
        [string]$SqlDatabaseName,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$QueryText
    )

    $connection = [System.Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString = "Server=tcp:$SqlServerName,1433;Initial Catalog=$SqlDatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $connection.AccessToken = $AccessToken
    $connection.Open()

    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $QueryText
        $command.CommandTimeout = 180
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlFileWithAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlServerName,

        [Parameter(Mandatory = $true)]
        [string]$SqlDatabaseName,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $scriptContent = Get-Content -Path $FilePath -Raw
    $batches = [regex]::Split($scriptContent, '(?im)^\s*GO\s*$(?:\r?\n)?') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($batch in $batches) {
        Invoke-SqlBatch -SqlServerName $SqlServerName -SqlDatabaseName $SqlDatabaseName -AccessToken $AccessToken -QueryText $batch
    }
}

function Get-ContainerAppEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvName
    )

    return az containerapp show `
        --resource-group $ResourceGroupName `
        --name $AppName `
        --query "properties.template.containers[0].env[?name=='$EnvName'].value | [0]" `
        -o tsv
}

function Get-ApplicationBaseUrl {
    $fqdn = az containerapp show `
        --resource-group $ResourceGroupName `
        --name $AppName `
        --query "properties.configuration.ingress.fqdn" -o tsv

    return "https://$fqdn"
}

function Get-BlockingSessionStatePath {
    return Join-Path $env:TEMP 'scenario3-sql-blocking-session.json'
}

function Resolve-SqlConnectionTarget {
    if (-not $script:SqlServerName) {
        $script:SqlServerName = Get-ContainerAppEnvValue -EnvName 'SQL_SERVER'
    }

    if (-not $script:SqlDatabaseName) {
        $script:SqlDatabaseName = Get-ContainerAppEnvValue -EnvName 'SQL_DATABASE'
    }
}

function Ensure-ClientSqlFirewallAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlServerName
    )

    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org')
    Write-Host "クライアント IP ($myIp) をファイアウォールに追加..."

    $serverNameOnly = $SqlServerName -replace '\.database\.windows\.net$', ''
    az sql server firewall-rule create `
        --resource-group $ResourceGroupName `
        --server $serverNameOnly `
        --name 'workshop-client' `
        --start-ip-address $myIp `
        --end-ip-address $myIp `
        --output none 2>$null
}

function Get-AverageLatency {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Items = @()
    )

    if (-not $Items -or $Items.Count -eq 0) {
        return 0
    }

    return [math]::Round(($Items | Measure-Object -Property latencyMs -Average).Average, 0)
}

function Initialize-Database {
    Write-Step '🗄️ Azure SQL Database を初期化（テーブル + シードデータ）'

    $sqlFile = Get-ScriptPath -Segments @('..', 'src', 'db', 'init.sql')
    Assert-SqlCmdInstalled
    Resolve-SqlConnectionTarget

    Write-Host "SQL Server: $SqlServerName"
    Write-Host "Database:   $SqlDatabaseName"

    Ensure-ClientSqlFirewallAccess -SqlServerName $SqlServerName

    $accessToken = Get-SqlAccessToken

    Write-Host 'init.sql を Microsoft Entra トークンで実行中...'
    Invoke-SqlFileWithAccessToken `
        -SqlServerName $SqlServerName `
        -SqlDatabaseName $SqlDatabaseName `
        -AccessToken $accessToken `
        -FilePath $sqlFile

    $grantQuery = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AppName')
BEGIN
    CREATE USER [$AppName] FROM EXTERNAL PROVIDER;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals rolePrincipal ON rolePrincipal.principal_id = drm.role_principal_id
    JOIN sys.database_principals memberPrincipal ON memberPrincipal.principal_id = drm.member_principal_id
    WHERE rolePrincipal.name = N'db_datareader' AND memberPrincipal.name = N'$AppName')
BEGIN
    ALTER ROLE db_datareader ADD MEMBER [$AppName];
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals rolePrincipal ON rolePrincipal.principal_id = drm.role_principal_id
    JOIN sys.database_principals memberPrincipal ON memberPrincipal.principal_id = drm.member_principal_id
    WHERE rolePrincipal.name = N'db_datawriter' AND memberPrincipal.name = N'$AppName')
BEGIN
    ALTER ROLE db_datawriter ADD MEMBER [$AppName];
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals rolePrincipal ON rolePrincipal.principal_id = drm.role_principal_id
    JOIN sys.database_principals memberPrincipal ON memberPrincipal.principal_id = drm.member_principal_id
    WHERE rolePrincipal.name = N'db_ddladmin' AND memberPrincipal.name = N'$AppName')
BEGIN
    ALTER ROLE db_ddladmin ADD MEMBER [$AppName];
END;
"@

    Write-Host 'App Service の Managed Identity に SQL 権限を付与中...'
    Invoke-SqlBatch `
        -SqlServerName $SqlServerName `
        -SqlDatabaseName $SqlDatabaseName `
        -AccessToken $accessToken `
        -QueryText $grantQuery

    Write-Host '✅ データベース初期化完了' -ForegroundColor Green
}

function Seed-Catalog {
    Write-Step '📦 Cosmos DB カタログをシード'

    $seedUrl = "$(Get-ApplicationBaseUrl)/api/catalog/seed?count=$CatalogItemCount"
    $result = Invoke-RestMethod -Uri $seedUrl -Method Post -TimeoutSec 120

    Write-Host "✅ Cosmos DB シード完了: $($result.seeded) 件" -ForegroundColor Green
}