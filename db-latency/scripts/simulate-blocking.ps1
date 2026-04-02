#!/usr/bin/env pwsh
# ============================================================================
# シナリオ3: SQL blocking シミュレーション スクリプト
# Azure SQL の長いトランザクションを使って更新待ちを再現する
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter()]
    [ValidateSet('init-db', 'seed-catalog', 'generate-write-traffic', 'start-blocking-session', 'stop-blocking-session', 'full-blocking-demo')]
    [string]$Action = 'full-blocking-demo',

    [Parameter()]
    [int]$RequestCount = 16,

    [Parameter()]
    [string]$SqlServerName,

    [Parameter()]
    [string]$SqlDatabaseName,

    [Parameter()]
    [string]$SqlAdminUser = 'sqladmin',

    [Parameter()]
    [string]$SqlAdminPassword,

    [Parameter()]
    [int]$CatalogItemCount = 50,

    [Parameter()]
    [int]$BlockingOrderId = 1,

    [Parameter()]
    [int]$HoldSeconds = 30,

    [Parameter()]
    [int]$MaxConcurrency = 8,

    [Parameter()]
    [int]$RequestTimeoutSeconds = 90
)

. (Join-Path $PSScriptRoot 'scenario3-common.ps1')

function Start-BlockingSession {
    Write-Step '🔒 SQL blocking セッションを開始'

    Resolve-SqlConnectionTarget

    Write-Host "SQL Server: $SqlServerName"
    Write-Host "Database:   $SqlDatabaseName"
    Write-Host "OrderId:    $BlockingOrderId"
    Write-Host "Hold:       $HoldSeconds sec"

    Ensure-ClientSqlFirewallAccess -SqlServerName $SqlServerName

    $statePath = Get-BlockingSessionStatePath
    if (Test-Path $statePath) {
        Remove-Item -Path $statePath -Force
    }

    $runnerPath = Join-Path $env:TEMP ("scenario3-sql-blocking-runner-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    $runnerContent = @'
param(
    [Parameter(Mandatory = $true)][string]$SqlServerName,
    [Parameter(Mandatory = $true)][string]$SqlDatabaseName,
    [Parameter(Mandatory = $true)][string]$AccessToken,
    [Parameter(Mandatory = $true)][int]$OrderId,
    [Parameter(Mandatory = $true)][int]$HoldSeconds,
    [Parameter(Mandatory = $true)][string]$StatePath
)

$ErrorActionPreference = 'Stop'
$connection = $null
$transaction = $null
$spid = $null

try {
    $connection = [System.Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString = "Server=tcp:$SqlServerName,1433;Initial Catalog=$SqlDatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $connection.AccessToken = $AccessToken
    $connection.Open()

    $spidCommand = $connection.CreateCommand()
    $spidCommand.CommandText = 'SELECT @@SPID;'
    $spid = [int]$spidCommand.ExecuteScalar()

    $transaction = $connection.BeginTransaction()

    $lockCommand = $connection.CreateCommand()
    $lockCommand.Transaction = $transaction
    $lockCommand.CommandText = @"
UPDATE Orders
SET Status = Status
WHERE Id = @OrderId;
"@
    [void]$lockCommand.Parameters.Add('@OrderId', [System.Data.SqlDbType]::Int)
    $lockCommand.Parameters['@OrderId'].Value = $OrderId

    $rowsAffected = $lockCommand.ExecuteNonQuery()
    if ($rowsAffected -eq 0) {
        throw "OrderId $OrderId was not found."
    }

    $metadata = [ordered]@{
        state = 'running'
        spid = $spid
        orderId = $OrderId
        holdSeconds = $HoldSeconds
        startedAt = (Get-Date).ToString('o')
        sqlServerName = $SqlServerName
        sqlDatabaseName = $SqlDatabaseName
    }
    $metadata | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8

    Start-Sleep -Seconds $HoldSeconds

    $transaction.Rollback()

    $metadata.state = 'completed'
    $metadata.endedAt = (Get-Date).ToString('o')
    $metadata | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
}
catch {
    $errorState = [ordered]@{
        state = 'error'
        orderId = $OrderId
        message = $_.Exception.Message
        endedAt = (Get-Date).ToString('o')
    }

    if ($spid) {
        $errorState.spid = $spid
    }

    $errorState | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    exit 1
}
finally {
    if ($transaction) {
        $transaction.Dispose()
    }

    if ($connection) {
        $connection.Dispose()
    }
}
'@

    Set-Content -Path $runnerPath -Value $runnerContent -Encoding UTF8

    $accessToken = Get-SqlAccessToken
    $process = Start-Process pwsh -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runnerPath,
        '-SqlServerName', $SqlServerName,
        '-SqlDatabaseName', $SqlDatabaseName,
        '-AccessToken', $accessToken,
        '-OrderId', $BlockingOrderId,
        '-HoldSeconds', $HoldSeconds,
        '-StatePath', $statePath
    ) -PassThru -WindowStyle Hidden

    $state = $null
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        if (Test-Path $statePath) {
            try {
                $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
                break
            }
            catch {
            }
        }

        Start-Sleep -Seconds 1
    }

    if (-not $state) {
        throw 'Blocking セッションの状態ファイルを取得できませんでした。ローカル blocker の起動に失敗した可能性があります。'
    }

    $state | Add-Member -NotePropertyName processId -NotePropertyValue $process.Id -Force
    $state | Add-Member -NotePropertyName runnerPath -NotePropertyValue $runnerPath -Force
    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

    if ($state.state -ne 'running') {
        throw "Blocking セッションの起動に失敗しました: $($state.message)"
    }

    Write-Host "✅ Blocking session started: SPID=$($state.spid), local process=$($process.Id)" -ForegroundColor Green
    Write-Host "停止するには: pwsh ./scripts/simulate-blocking.ps1 -ResourceGroupName $ResourceGroupName -AppName $AppName -Action stop-blocking-session" -ForegroundColor White
}

function Stop-BlockingSession {
    Write-Step '🛑 SQL blocking セッションを停止'

    $statePath = Get-BlockingSessionStatePath
    if (-not (Test-Path $statePath)) {
        Write-Host 'アクティブな blocking セッションは見つかりません。' -ForegroundColor Yellow
        return
    }

    $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($state.state -eq 'completed') {
        Write-Host 'blocking セッションは既に完了しています。' -ForegroundColor Green
        return
    }

    if ($state.processId) {
        $process = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $state.processId -Force -ErrorAction SilentlyContinue
            Write-Host "ローカル blocker プロセス $($state.processId) を停止しました。" -ForegroundColor Green
        }
    }

    if ($state.spid) {
        try {
            Resolve-SqlConnectionTarget
            Ensure-ClientSqlFirewallAccess -SqlServerName $SqlServerName

            $accessToken = Get-SqlAccessToken
            Invoke-SqlBatch -SqlServerName $SqlServerName -SqlDatabaseName $SqlDatabaseName -AccessToken $accessToken -QueryText "KILL $($state.spid);"

            Write-Host "SQL session $($state.spid) に KILL を送信しました。" -ForegroundColor Green
        }
        catch {
            Write-Host "SQL session の停止はローカルプロセス停止で完了した可能性があります: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    $state.state = 'stopped'
    $state.stoppedAt = (Get-Date).ToString('o')
    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

    if ($state.runnerPath -and (Test-Path $state.runnerPath)) {
        Remove-Item -Path $state.runnerPath -Force -ErrorAction SilentlyContinue
    }
}

function Generate-WriteTraffic {
    Write-Step "✍️ 更新トラフィック生成（$RequestCount リクエスト / concurrency $MaxConcurrency）"

    $baseUrl = Get-ApplicationBaseUrl
    $targetOrderIds = @($BlockingOrderId, $BlockingOrderId, $BlockingOrderId, 2, 3, $BlockingOrderId, 4, 5)
    $slowThresholdMs = 3000

    Write-Host "ターゲット: $baseUrl"
    Write-Host "注目する hot order: $BlockingOrderId"

    $results = 1..$RequestCount | ForEach-Object -Parallel {
        $orderIds = $using:targetOrderIds
        $requestTimeoutSeconds = $using:RequestTimeoutSeconds
        $baseUrl = $using:baseUrl

        $index = $_ - 1
        $orderId = $orderIds[$index % $orderIds.Count]
        $statusSequence = @('confirmed', 'packed', 'shipped', 'delivered')
        $nextStatus = $statusSequence[$index % $statusSequence.Count]
        $requestUrl = "$baseUrl/api/orders/$orderId/status"
        $requestBody = @{ status = $nextStatus } | ConvertTo-Json
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $response = Invoke-RestMethod `
                -Uri $requestUrl `
                -Method Patch `
                -ContentType 'application/json' `
                -Body $requestBody `
                -TimeoutSec $requestTimeoutSeconds

            $stopwatch.Stop()

            [pscustomobject]@{
                orderId = $orderId
                success = $true
                latencyMs = $stopwatch.ElapsedMilliseconds
                status = $nextStatus
                responseQueryTimeMs = [math]::Round($response.queryTimeMs, 2)
                error = $null
            }
        }
        catch {
            $stopwatch.Stop()

            [pscustomobject]@{
                orderId = $orderId
                success = $false
                latencyMs = $stopwatch.ElapsedMilliseconds
                status = $nextStatus
                responseQueryTimeMs = $null
                error = $_.Exception.Message
            }
        }
    } -ThrottleLimit $MaxConcurrency

    $successful = @($results | Where-Object success)
    $errors = @($results | Where-Object { -not $_.success })
    $slow = @($successful | Where-Object { $_.latencyMs -gt $slowThresholdMs })
    $blockedOrderResults = @($successful | Where-Object { $_.orderId -eq $BlockingOrderId })
    $otherOrderResults = @($successful | Where-Object { $_.orderId -ne $BlockingOrderId })

    Write-Host "`n--- 更新トラフィック結果 ---" -ForegroundColor Yellow
    Write-Host "  成功: $($successful.Count)"
    Write-Host "  スロー (>3s): $($slow.Count)"
    Write-Host "  エラー: $($errors.Count)"
    Write-Host "  Blocked order 平均応答: $(Get-AverageLatency -Items $blockedOrderResults)ms ($($blockedOrderResults.Count) 件)"
    Write-Host "  Other orders 平均応答: $(Get-AverageLatency -Items $otherOrderResults)ms ($($otherOrderResults.Count) 件)"

    if ($errors.Count -gt 0) {
        $sampleErrors = $errors | Select-Object -First 3
        foreach ($entry in $sampleErrors) {
            Write-Host "  ❌ Order $($entry.orderId): $($entry.error)" -ForegroundColor Red
        }
    }

    if ((Get-AverageLatency -Items $blockedOrderResults) -gt ((Get-AverageLatency -Items $otherOrderResults) + 1000)) {
        Write-Host "`n  💡 hot order の更新だけが著しく遅い → SQL blocking の可能性が高い" -ForegroundColor Cyan
    }
}

function Run-FullBlockingDemo {
    Write-Step '🔐 SQL blocking デモ開始'

    $originalRequestCount = $script:RequestCount

    try {
        Write-Host 'Phase 1: 更新 API のベースライン取得' -ForegroundColor White
        $script:RequestCount = 8
        Generate-WriteTraffic

        Write-Host "`nPhase 2: blocker を起動" -ForegroundColor White
        Start-BlockingSession
        Start-Sleep -Seconds 3

        Write-Host "`nPhase 3: blocker 中の更新トラフィック生成" -ForegroundColor White
        $script:RequestCount = 16
        Generate-WriteTraffic

        Write-Host "`n" -NoNewline
        Write-Step '🚨 ここで Application Insights / Azure SQL を確認してください'
        Write-Host '期待する観察ポイント:' -ForegroundColor Yellow
        Write-Host '  1. PATCH /api/orders/{id}/status だけが遅い' -ForegroundColor Yellow
        Write-Host '  2. /api/catalog は引き続き正常' -ForegroundColor Yellow
        Write-Host '  3. SQL dependency が長時間待機している' -ForegroundColor Yellow
        Write-Host '  4. CPU が高くなくても更新だけ詰まる' -ForegroundColor Yellow
        Write-Host '  5. 対策: 長いトランザクションの停止、更新対象の分散、更新バッチの見直し' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '調査後の復旧コマンド:' -ForegroundColor Cyan
        Write-Host "  pwsh ./scripts/simulate-blocking.ps1 -ResourceGroupName $ResourceGroupName -AppName $AppName -Action stop-blocking-session" -ForegroundColor White
    }
    finally {
        $script:RequestCount = $originalRequestCount
    }
}

switch ($Action) {
    'init-db'               { Initialize-Database }
    'seed-catalog'          { Seed-Catalog }
    'generate-write-traffic' { Generate-WriteTraffic }
    'start-blocking-session' { Start-BlockingSession }
    'stop-blocking-session' { Stop-BlockingSession }
    'full-blocking-demo'    { Run-FullBlockingDemo }
}