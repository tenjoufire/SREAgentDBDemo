#!/usr/bin/env pwsh
# ============================================================================
# シナリオ3: スロークエリ シミュレーション スクリプト
# 注文系 API が常時 slow query を含む前提で、読み取り系トラフィックの遅延を再現する
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter()]
    [ValidateSet('init-db', 'seed-catalog', 'generate-traffic', 'full-demo')]
    [string]$Action = 'full-demo',

    [Parameter()]
    [int]$RequestCount = 200,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxConcurrency = 1,

    [Parameter()]
    [string]$SqlServerName,

    [Parameter()]
    [string]$SqlDatabaseName,

    [Parameter()]
    [string]$SqlAdminUser = 'sqladmin',

    [Parameter()]
    [string]$SqlAdminPassword,

    [Parameter()]
    [int]$CatalogItemCount = 50
)

. (Join-Path $PSScriptRoot 'scenario3-common.ps1')

function Generate-Traffic {
    $modeLabel = if ($MaxConcurrency -gt 1) { "並列 $MaxConcurrency" } else { '直列' }
    Write-Step "🔥 トラフィック生成（$RequestCount リクエスト / $modeLabel）"

    $baseUrl = Get-ApplicationBaseUrl
    $endpoints = @(
        '/api/orders',
        '/api/orders/1',
        '/api/orders/50',
        '/api/catalog',
        '/api/catalog/search?q=electronics',
        '/api/orders',
        '/api/orders/100'
    )

    Write-Host "ターゲット: $baseUrl"
    if ($MaxConcurrency -gt 1) {
        Write-Host "実行モード: 並列 ${MaxConcurrency}" -ForegroundColor Gray
    }

    $results = if ($MaxConcurrency -gt 1) {
        1..$RequestCount | ForEach-Object -ThrottleLimit $MaxConcurrency -Parallel {
            $index = $_ - 1
            $localBaseUrl = $using:baseUrl
            $localEndpoints = $using:endpoints
            $endpoint = $localEndpoints[$index % $localEndpoints.Count]
            $requestUrl = "$localBaseUrl$endpoint"
            $isSql = $endpoint -like '/api/orders*'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $response = Invoke-WebRequest -Uri $requestUrl -Method Get -UseBasicParsing -TimeoutSec 60
                $sw.Stop()

                [pscustomobject]@{
                    Endpoint = $endpoint
                    LatencyMs = [int]$sw.ElapsedMilliseconds
                    StatusCode = [int]$response.StatusCode
                    IsSql = $isSql
                    Error = $null
                }
            }
            catch {
                $sw.Stop()
                $statusCode = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                [pscustomobject]@{
                    Endpoint = $endpoint
                    LatencyMs = [int]$sw.ElapsedMilliseconds
                    StatusCode = $statusCode
                    IsSql = $isSql
                    Error = $_.Exception.Message
                }
            }
        }
    }
    else {
        $serialResults = [System.Collections.Generic.List[object]]::new()

        for ($i = 0; $i -lt $RequestCount; $i++) {
            $endpoint = $endpoints[$i % $endpoints.Count]
            $requestUrl = "$baseUrl$endpoint"
            $isSql = $endpoint -like '/api/orders*'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $response = Invoke-WebRequest -Uri $requestUrl -Method Get -UseBasicParsing -TimeoutSec 60
                $sw.Stop()

                $serialResults.Add([pscustomobject]@{
                    Endpoint = $endpoint
                    LatencyMs = [int]$sw.ElapsedMilliseconds
                    StatusCode = [int]$response.StatusCode
                    IsSql = $isSql
                    Error = $null
                })
            }
            catch {
                $sw.Stop()
                $statusCode = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                $serialResults.Add([pscustomobject]@{
                    Endpoint = $endpoint
                    LatencyMs = [int]$sw.ElapsedMilliseconds
                    StatusCode = $statusCode
                    IsSql = $isSql
                    Error = $_.Exception.Message
                })
            }

            if ($i % 20 -eq 0) {
                $currentResults = @($serialResults)
                $currentSql = @($currentResults | Where-Object { $_.IsSql })
                $currentCosmos = @($currentResults | Where-Object { -not $_.IsSql })
                $currentErrors = @($currentResults | Where-Object { $_.StatusCode -eq 0 -or $_.StatusCode -ge 500 })
                $currentSlow = @($currentResults | Where-Object { $_.StatusCode -gt 0 -and $_.StatusCode -lt 500 -and $_.LatencyMs -gt 3000 })
                $sqlAvg = if ($currentSql.Count -gt 0) { [math]::Round((($currentSql | Measure-Object -Property LatencyMs -Average).Average)) } else { 0 }
                $cosmosAvg = if ($currentCosmos.Count -gt 0) { [math]::Round((($currentCosmos | Measure-Object -Property LatencyMs -Average).Average)) } else { 0 }
                Write-Host "  📊 [$($i + 1)/$RequestCount] SQL avg=${sqlAvg}ms | Cosmos avg=${cosmosAvg}ms | Slow=$($currentSlow.Count) Err=$($currentErrors.Count)" -ForegroundColor Gray
            }

            Start-Sleep -Milliseconds 200
        }

        $serialResults
    }

    $results = @($results)
    $errorResults = @($results | Where-Object { $_.StatusCode -eq 0 -or $_.StatusCode -ge 500 })
    $slowResults = @($results | Where-Object { $_.StatusCode -gt 0 -and $_.StatusCode -lt 500 -and $_.LatencyMs -gt 3000 })
    $successResults = @($results | Where-Object { $_.StatusCode -gt 0 -and $_.StatusCode -lt 500 -and $_.LatencyMs -le 3000 })
    $sqlResults = @($results | Where-Object { $_.IsSql })
    $cosmosResults = @($results | Where-Object { -not $_.IsSql })

    $sqlAvgFinal = if ($sqlResults.Count -gt 0) { [math]::Round((($sqlResults | Measure-Object -Property LatencyMs -Average).Average)) } else { 0 }
    $cosmosAvgFinal = if ($cosmosResults.Count -gt 0) { [math]::Round((($cosmosResults | Measure-Object -Property LatencyMs -Average).Average)) } else { 0 }

    Write-Host "`n--- トラフィック生成結果 ---" -ForegroundColor Yellow
    Write-Host "  成功: $($successResults.Count)"
    Write-Host "  スロー (>3s): $($slowResults.Count)"
    Write-Host "  エラー: $($errorResults.Count)"
    Write-Host "  SQL 平均応答: ${sqlAvgFinal}ms ($($sqlResults.Count) 件)"
    Write-Host "  Cosmos DB 平均応答: ${cosmosAvgFinal}ms ($($cosmosResults.Count) 件)"

    if ($sqlAvgFinal -gt $cosmosAvgFinal * 3) {
        Write-Host "`n  💡 SQL の応答時間が Cosmos DB の 3 倍以上 → DB 層が原因の可能性大" -ForegroundColor Cyan
    }
}

function Run-FullDemo {
    Write-Step '🎬 フルデモシーケンス開始'

    Write-Host 'Phase 1: データベース初期化' -ForegroundColor White
    Initialize-Database

    Write-Host "`nPhase 2: Cosmos DB カタログをシード" -ForegroundColor White
    Seed-Catalog

    Write-Host "`nPhase 3: 常時スロークエリ構成でウォームアップ トラフィックを生成" -ForegroundColor White
    $script:RequestCount = 50
    Generate-Traffic

    Write-Host "`n⏳ 30 秒待機（メトリクスの反映を待つ）..." -ForegroundColor Gray
    Start-Sleep -Seconds 30

    Write-Host "`nPhase 4: 調査用の追加トラフィックを生成" -ForegroundColor White
    $script:RequestCount = 200
    Generate-Traffic

    Write-Host "`n" -NoNewline
    Write-Step '🚨 ここで SRE Agent の画面を確認してください'
    Write-Host 'SRE Agent が以下を検出するはずです:' -ForegroundColor Yellow
    Write-Host '  1. アプリの応答時間が急激に悪化' -ForegroundColor Yellow
    Write-Host '  2. Application Insights の依存関係追跡で SQL が遅い' -ForegroundColor Yellow
    Write-Host '  3. Azure SQL の CPU percentage が 80% 超過' -ForegroundColor Yellow
    Write-Host '  4. Cosmos DB 側は正常 → 根本原因は SQL 層' -ForegroundColor Yellow
    Write-Host '  5. 提案:' -ForegroundColor Yellow
    Write-Host '     - 一時回避: vCore のスケールアップ、一覧アクセスの抑制、キャッシュ' -ForegroundColor Yellow
    Write-Host '     - 恒久対策: N+1 集計の除去、インデックス追加、アプリの再デプロイ' -ForegroundColor Yellow
}

switch ($Action) {
    'init-db'          { Initialize-Database }
    'seed-catalog'     { Seed-Catalog }
    'generate-traffic' { Generate-Traffic }
    'full-demo'        { Run-FullDemo }
}
