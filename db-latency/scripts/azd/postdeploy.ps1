$ErrorActionPreference = 'Stop'

function Wait-ForContainerApp {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AppName,
        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $app = az containerapp show --resource-group $ResourceGroupName --name $AppName --query '{provisioningState:properties.provisioningState,fqdn:properties.configuration.ingress.fqdn,outbound:properties.outboundIpAddresses}' -o json | ConvertFrom-Json
        if ($app.provisioningState -eq 'Succeeded' -and $app.fqdn -and $app.outbound -and $app.outbound.Count -gt 0) {
            return $app
        }

        Start-Sleep -Seconds 10
    }

    throw 'Container App の準備完了を待機中にタイムアウトしました。'
}

function Invoke-HttpCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60
        }
        catch {
            Start-Sleep -Seconds 10
        }
    }

    throw "HTTP チェックがタイムアウトしました: $Uri"
}

$resourceGroupName = $env:AZURE_RESOURCE_GROUP_NAME
$appName = $env:AZURE_CONTAINER_APP_NAME
$cosmosAccountName = $env:AZURE_COSMOS_ACCOUNT_NAME
$appUrl = $env:AZURE_CONTAINER_APP_URL

if (-not $resourceGroupName -or -not $appName -or -not $cosmosAccountName -or -not $appUrl) {
    throw 'postdeploy に必要な azd 環境変数が不足しています。'
}

$app = Wait-ForContainerApp -ResourceGroupName $resourceGroupName -AppName $appName
$ipRangeFilter = ($app.outbound | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ','

if (-not $ipRangeFilter) {
    throw 'Container App の outbound IP を取得できませんでした。'
}

Write-Host "Cosmos DB のファイアウォールを Container App の outbound IP に更新します: $ipRangeFilter"
az cosmosdb update --name $cosmosAccountName --resource-group $resourceGroupName --public-network-access Enabled --ip-range-filter $ipRangeFilter --output none

Write-Host 'Azure SQL の初期化を実行します。'
pwsh ./scripts/simulate-slow-query.ps1 -ResourceGroupName $resourceGroupName -AppName $appName -Action init-db

Write-Host 'Cosmos DB のカタログデータをシードします。'
pwsh ./scripts/simulate-slow-query.ps1 -ResourceGroupName $resourceGroupName -AppName $appName -Action seed-catalog -CatalogItemCount 10

Write-Host 'アプリ疎通を確認します。'
$ordersResponse = Invoke-HttpCheck -Uri "$appUrl/api/orders"
$catalogResponse = Invoke-HttpCheck -Uri "$appUrl/api/catalog"

Write-Host "Orders API status: $($ordersResponse.StatusCode)"
Write-Host "Catalog API status: $($catalogResponse.StatusCode)"