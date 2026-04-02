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
    Write-Step "🔥 トラフィック生成（$RequestCount リクエスト）"

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

    $totalSuccess = 0
    $totalSlow = 0
    $totalError = 0
    $sqlTotalMs = 0
    $cosmosTotalMs = 0
    $sqlCount = 0
    $cosmosCount = 0

    Write-Host "ターゲット: $baseUrl"

    for ($i = 0; $i -lt $RequestCount; $i++) {
        $endpoint = $endpoints[$i % $endpoints.Count]
        $requestUrl = "$baseUrl$endpoint"
        $isSql = $endpoint -like '/api/orders*'

        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-WebRequest -Uri $requestUrl -Method Get -UseBasicParsing -TimeoutSec 60
            $sw.Stop()
            $latency = $sw.ElapsedMilliseconds

            if ($isSql) {
                $sqlTotalMs += $latency
                $sqlCount++
            }
            else {
                $cosmosTotalMs += $latency
                $cosmosCount++
            }

            if ($response.StatusCode -ge 500) {
                $totalError++
                Write-Host "  ❌ [$($response.StatusCode)] $endpoint (${latency}ms)" -ForegroundColor Red
            }
            elseif ($latency -gt 3000) {
                $totalSlow++
                Write-Host "  ⚠️  [SLOW ${latency}ms] $endpoint" -ForegroundColor Yellow
            }
            else {
                $totalSuccess++
            }

            if ($i % 20 -eq 0) {
                $sqlAvg = if ($sqlCount -gt 0) { [math]::Round($sqlTotalMs / $sqlCount) } else { 0 }
                $cosmosAvg = if ($cosmosCount -gt 0) { [math]::Round($cosmosTotalMs / $cosmosCount) } else { 0 }
                Write-Host "  📊 [$($i + 1)/$RequestCount] SQL avg=${sqlAvg}ms | Cosmos avg=${cosmosAvg}ms | Slow=$totalSlow Err=$totalError" -ForegroundColor Gray
            }
        }
        catch {
            $totalError++
        }

        Start-Sleep -Milliseconds 200
    }

    $sqlAvgFinal = if ($sqlCount -gt 0) { [math]::Round($sqlTotalMs / $sqlCount) } else { 0 }
    $cosmosAvgFinal = if ($cosmosCount -gt 0) { [math]::Round($cosmosTotalMs / $cosmosCount) } else { 0 }

    Write-Host "`n--- トラフィック生成結果 ---" -ForegroundColor Yellow
    Write-Host "  成功: $totalSuccess"
    Write-Host "  スロー (>3s): $totalSlow"
    Write-Host "  エラー: $totalError"
    Write-Host "  SQL 平均応答: ${sqlAvgFinal}ms ($sqlCount 件)"
    Write-Host "  Cosmos DB 平均応答: ${cosmosAvgFinal}ms ($cosmosCount 件)"

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
