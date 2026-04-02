// ============================================================================
// シナリオ3 サンプルアプリ: 注文 + 商品カタログ API (ASP.NET Core / .NET 10)
// Azure SQL (注文データ) + Cosmos DB (商品カタログ) の 2 層構成
// 注文系 API では意図的に常時スロークエリを発生させる
// ============================================================================

using System.Data;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Cosmos;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

// --- Application Insights ---
var aiConnStr = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
if (!string.IsNullOrEmpty(aiConnStr))
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor(o =>
    {
        o.ConnectionString = aiConnStr;
    });
}

// --- Azure SQL ---
var sqlConnStr = BuildSqlConnectionString(builder.Configuration);
builder.Services.AddScoped<SqlConnection>(_ => new SqlConnection(sqlConnStr));

// --- Cosmos DB ---
var cosmosEndpoint = builder.Configuration["COSMOS_ENDPOINT"];
var cosmosKey = builder.Configuration["COSMOS_KEY"];
var cosmosDatabase = builder.Configuration["COSMOS_DATABASE"] ?? "productcatalog";
var cosmosContainer = builder.Configuration["COSMOS_CONTAINER"] ?? "products";
var useManagedIdentityForCosmos = string.Equals(builder.Configuration["COSMOS_USE_MANAGED_IDENTITY"], "true", StringComparison.OrdinalIgnoreCase);

if (!string.IsNullOrEmpty(cosmosEndpoint))
{
    CosmosClient cosmosClient;
    var cosmosClientOptions = new CosmosClientOptions
    {
        ApplicationName = "SRE-Demo-Scenario3",
        SerializerOptions = new CosmosSerializationOptions
        {
            PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase,
        },
    };

    if (useManagedIdentityForCosmos || string.IsNullOrEmpty(cosmosKey))
    {
        cosmosClient = new CosmosClient(cosmosEndpoint, new DefaultAzureCredential(), cosmosClientOptions);
    }
    else
    {
        cosmosClient = new CosmosClient(cosmosEndpoint, cosmosKey, cosmosClientOptions);
    }

    builder.Services.AddSingleton(cosmosClient);
}

var app = builder.Build();

const string orderLatencyProfile = "always-heavy";
var validOrderStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
{
    "pending",
    "confirmed",
    "allocated",
    "packed",
    "shipped",
    "delivered",
    "cancelled",
};

// ---------------------------------------------------------------------------
// ヘルスチェック
// ---------------------------------------------------------------------------
app.MapGet("/api/health", () => Results.Ok(new
{
    status = "healthy",
    orderLatencyProfile,
    timestamp = DateTime.UtcNow,
}));

// ---------------------------------------------------------------------------
// 注文一覧 (Azure SQL)
// ---------------------------------------------------------------------------
app.MapGet("/api/orders", async ([FromServices] SqlConnection db) =>
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    await db.OpenAsync();

    var sql = """
      SELECT TOP 100 Id, CustomerName, ProductId, Quantity, TotalPrice,
             CreatedAt, Status
      FROM Orders
      ORDER BY CreatedAt DESC
      """;

    using var cmd = new SqlCommand(sql, db);
    cmd.CommandTimeout = 30;

    var orders = new List<OrderSummaryRow>();
    using var reader = await cmd.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
        orders.Add(new OrderSummaryRow(
            reader.GetInt32(0),
            reader.GetString(1),
            reader.GetString(2),
            reader.GetInt32(3),
            reader.GetDecimal(4),
            reader.GetDateTime(5),
            reader.GetString(6)));
    }

    await reader.CloseAsync();

    var enrichedOrders = new List<object>();
    foreach (var order in orders)
    {
        var itemSummary = await LoadOrderItemSummaryAsync(db, order.Id);
        enrichedOrders.Add(new
        {
            id = order.Id,
            customerName = order.CustomerName,
            productId = order.ProductId,
            quantity = order.Quantity,
            totalPrice = order.TotalPrice,
            createdAt = order.CreatedAt,
            status = order.Status,
            lineItemCount = itemSummary.LineItemCount,
            itemsTotal = itemSummary.ItemsTotal,
            lastItemUpdatedAt = itemSummary.LastItemUpdatedAt,
        });
    }

    sw.Stop();
    return Results.Ok(new
    {
        orders = enrichedOrders,
        count = enrichedOrders.Count,
        queryTimeMs = sw.Elapsed.TotalMilliseconds,
        orderLatencyProfile,
    });
});

// ---------------------------------------------------------------------------
// 注文詳細 (Azure SQL)
// ---------------------------------------------------------------------------
app.MapGet("/api/orders/{id:int}", async (int id, [FromServices] SqlConnection db) =>
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    await db.OpenAsync();

        var sql = """
            SELECT Id, CustomerName, ProductId, Quantity, TotalPrice, CreatedAt, Status
            FROM Orders
            WHERE Id = @Id
            """;

    using var cmd = new SqlCommand(sql, db);
    cmd.Parameters.AddWithValue("@Id", id);

    using var reader = await cmd.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
    {
        sw.Stop();
        return Results.NotFound(new { error = "Order not found" });
    }

    var order = new
    {
        id = reader.GetInt32(0),
        customerName = reader.GetString(1),
        productId = reader.GetString(2),
        quantity = reader.GetInt32(3),
        totalPrice = reader.GetDecimal(4),
        createdAt = reader.GetDateTime(5),
        status = reader.GetString(6),
    };

    await reader.CloseAsync();

    var itemSummary = await LoadOrderItemSummaryAsync(db, id);

    sw.Stop();
    return Results.Ok(new
    {
        order = new
        {
            order.id,
            order.customerName,
            order.productId,
            order.quantity,
            order.totalPrice,
            order.createdAt,
            order.status,
            lineItemCount = itemSummary.LineItemCount,
            itemsTotal = itemSummary.ItemsTotal,
            lastItemUpdatedAt = itemSummary.LastItemUpdatedAt,
        },
        queryTimeMs = sw.Elapsed.TotalMilliseconds,
        orderLatencyProfile,
    });
});

// ---------------------------------------------------------------------------
// 商品カタログ (Cosmos DB)
// ---------------------------------------------------------------------------
app.MapGet("/api/catalog", async ([FromServices] CosmosClient cosmos) =>
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var container = cosmos.GetContainer(cosmosDatabase, cosmosContainer);

    var query = new QueryDefinition("SELECT * FROM c ORDER BY c.name OFFSET 0 LIMIT 50");
    var results = new List<dynamic>();

    using var feed = container.GetItemQueryIterator<dynamic>(query);
    while (feed.HasMoreResults)
    {
        var response = await feed.ReadNextAsync();
        results.AddRange(response);
    }

    sw.Stop();
    return Results.Ok(new
    {
        products = results,
        count = results.Count,
        queryTimeMs = sw.Elapsed.TotalMilliseconds,
        source = "CosmosDB",
    });
});

// ---------------------------------------------------------------------------
// 商品検索 (Cosmos DB)
// ---------------------------------------------------------------------------
app.MapGet("/api/catalog/search", async (string? q, [FromServices] CosmosClient cosmos) =>
{
    q ??= "";
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var container = cosmos.GetContainer(cosmosDatabase, cosmosContainer);

    var query = new QueryDefinition(
        "SELECT * FROM c WHERE CONTAINS(LOWER(c.name), @q) OR CONTAINS(LOWER(c.category), @q)")
        .WithParameter("@q", q.ToLower());

    var results = new List<dynamic>();
    using var feed = container.GetItemQueryIterator<dynamic>(query);
    while (feed.HasMoreResults)
    {
        var response = await feed.ReadNextAsync();
        results.AddRange(response);
    }

    sw.Stop();
    return Results.Ok(new
    {
        products = results,
        count = results.Count,
        queryTimeMs = sw.Elapsed.TotalMilliseconds,
        source = "CosmosDB",
    });
});

// ---------------------------------------------------------------------------
// カタログシード (Cosmos DB)
// ---------------------------------------------------------------------------
app.MapPost("/api/catalog/seed", async ([FromQuery] int? count, [FromServices] CosmosClient cosmos) =>
{
    var container = cosmos.GetContainer(cosmosDatabase, cosmosContainer);
    var itemsToSeed = Math.Clamp(count ?? 50, 1, 200);
    var categories = new[] { "electronics", "apparel", "food", "books" };
    var seeded = 0;

    for (var i = 1; i <= itemsToSeed; i++)
    {
        var category = categories[(i - 1) % categories.Length];
        var item = new
        {
            id = $"PROD-{i:0000}",
            name = $"Demo Product {i:0000}",
            category,
            price = 500 + (i * 137 % 15000),
            inventory = 10 + (i % 90),
            updatedAt = DateTime.UtcNow,
        };

        await container.UpsertItemAsync(item, new PartitionKey(category));
        seeded++;
    }

    return Results.Ok(new { seeded, database = cosmosDatabase, container = cosmosContainer });
});

// ---------------------------------------------------------------------------
// 注文作成 (Azure SQL + Cosmos DB の依存関係を作る)
// ---------------------------------------------------------------------------
app.MapPost("/api/orders", async ([FromBody] CreateOrderRequest req, [FromServices] SqlConnection db, [FromServices] CosmosClient cosmos) =>
{
    // 1. Cosmos DB で商品を確認
    var container = cosmos.GetContainer(cosmosDatabase, cosmosContainer);
    try
    {
        await container.ReadItemAsync<dynamic>(req.ProductId, new PartitionKey(req.Category));
    }
    catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
    {
        return Results.NotFound(new { error = "Product not found in catalog" });
    }

    // 2. Azure SQL に注文を挿入
    await db.OpenAsync();
    var sql = """
        INSERT INTO Orders (CustomerName, ProductId, Quantity, TotalPrice, CreatedAt, Status)
        OUTPUT INSERTED.Id
        VALUES (@Customer, @ProductId, @Qty, @Total, @CreatedAt, 'pending')
        """;

    using var cmd = new SqlCommand(sql, db);
    cmd.Parameters.AddWithValue("@Customer", req.CustomerName);
    cmd.Parameters.AddWithValue("@ProductId", req.ProductId);
    cmd.Parameters.AddWithValue("@Qty", req.Quantity);
    cmd.Parameters.AddWithValue("@Total", req.TotalPrice);
    cmd.Parameters.AddWithValue("@CreatedAt", DateTime.UtcNow);

    var orderId = (int)(await cmd.ExecuteScalarAsync())!;

    return Results.Created($"/api/orders/{orderId}", new
    {
        orderId,
        customerName = req.CustomerName,
        productId = req.ProductId,
        quantity = req.Quantity,
        totalPrice = req.TotalPrice,
        status = "pending",
    });
});

// ---------------------------------------------------------------------------
// 注文ステータス更新 (Azure SQL)
// SQL blocking シナリオではこの更新がブロックされる
// ---------------------------------------------------------------------------
app.MapPatch("/api/orders/{id:int}/status", async (int id, [FromBody] UpdateOrderStatusRequest req, [FromServices] SqlConnection db) =>
{
    if (string.IsNullOrWhiteSpace(req.Status))
    {
        return Results.BadRequest(new { error = "Status is required" });
    }

    var normalizedStatus = req.Status.Trim().ToLowerInvariant();
    if (!validOrderStatuses.Contains(normalizedStatus))
    {
        return Results.BadRequest(new
        {
            error = "Unsupported status",
            supportedStatuses = validOrderStatuses.OrderBy(status => status).ToArray(),
        });
    }

    var sw = System.Diagnostics.Stopwatch.StartNew();
    await db.OpenAsync();

    const string sql = """
        UPDATE Orders
        SET Status = @Status
        WHERE Id = @Id
        """;

    using var cmd = new SqlCommand(sql, db);
    cmd.CommandTimeout = 60;
    cmd.Parameters.AddWithValue("@Id", id);
    cmd.Parameters.AddWithValue("@Status", normalizedStatus);

    var rowsAffected = await cmd.ExecuteNonQueryAsync();

    sw.Stop();

    if (rowsAffected == 0)
    {
        return Results.NotFound(new { error = "Order not found" });
    }

    return Results.Ok(new
    {
        orderId = id,
        status = normalizedStatus,
        rowsAffected,
        queryTimeMs = sw.Elapsed.TotalMilliseconds,
    });
});

// ---------------------------------------------------------------------------
// ルートパス
// ---------------------------------------------------------------------------
app.MapGet("/", () => Results.Ok(new
{
    service = "SRE Demo - Order & Catalog API (.NET 10)",
    orderLatencyProfile,
    endpoints = new[]
    {
        "GET  /api/health",
        "GET  /api/orders",
        "GET  /api/orders/{id}",
        "POST /api/orders",
        "PATCH /api/orders/{id}/status",
        "GET  /api/catalog",
        "GET  /api/catalog/search?q=keyword",
    },
}));

app.Run();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static string BuildSqlConnectionString(IConfiguration config)
{
    var managedIdentityConnectionString = config["AZURE_SQL_CONNECTIONSTRING"];
    if (!string.IsNullOrWhiteSpace(managedIdentityConnectionString))
    {
        return managedIdentityConnectionString;
    }

    var server = config["SQL_SERVER"] ?? "localhost";
    var database = config["SQL_DATABASE"] ?? "sre-s3-db";
    var user = config["SQL_USER"] ?? "sqladmin";
    var password = config["SQL_PASSWORD"] ?? "";

    return $"Server=tcp:{server},1433;Initial Catalog={database};User ID={user};Password={password};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;";
}

static async Task<OrderItemSummary> LoadOrderItemSummaryAsync(SqlConnection db, int orderId)
{
    var sql = """
        DECLARE @NormalizedOrderIdText NVARCHAR(20) = RIGHT(REPLICATE('0', 20) + @OrderIdText, 20);

        SELECT
                (
                    SELECT COUNT(*)
                    FROM OrderItems oiCount
                    WHERE RIGHT(REPLICATE('0', 20) + CAST(oiCount.OrderId AS NVARCHAR(20)), 20) = @NormalizedOrderIdText
                        AND LOWER(LTRIM(RTRIM(oiCount.ItemStatus))) <> 'cancelled'
                ) AS LineItemCount,
                ISNULL((
                    SELECT SUM(CASE WHEN oiQuantity.Quantity > 0 THEN oiQuantity.Quantity ELSE 0 END)
                    FROM OrderItems oiQuantity
                    WHERE RIGHT(REPLICATE('0', 20) + CAST(oiQuantity.OrderId AS NVARCHAR(20)), 20) = @NormalizedOrderIdText
                        AND LOWER(LTRIM(RTRIM(oiQuantity.ItemStatus))) <> 'cancelled'
                ), 0) AS Units,
                ISNULL((
                    SELECT SUM(CASE WHEN oiTotal.LineTotal > 0 THEN oiTotal.LineTotal ELSE 0 END)
                    FROM OrderItems oiTotal
                    WHERE RIGHT(REPLICATE('0', 20) + CAST(oiTotal.OrderId AS NVARCHAR(20)), 20) = @NormalizedOrderIdText
                        AND LOWER(LTRIM(RTRIM(oiTotal.ItemStatus))) <> 'cancelled'
                ), 0) AS ItemsTotal,
                (
                    SELECT MAX(oiLast.CreatedAt)
                    FROM OrderItems oiLast
                    WHERE RIGHT(REPLICATE('0', 20) + CAST(oiLast.OrderId AS NVARCHAR(20)), 20) = @NormalizedOrderIdText
                        AND LOWER(LTRIM(RTRIM(oiLast.ItemStatus))) <> 'cancelled'
                ) AS LastItemUpdatedAt,
                (
                    SELECT SUM(
                        ABS(CHECKSUM(CONCAT(
                            oiNoise.Sku,
                            ':',
                            recentOrders.CustomerName,
                            ':',
                            LOWER(oiNoise.ItemStatus),
                            ':',
                            CAST(oiNoise.OrderId AS NVARCHAR(20)),
                            ':',
                            CONVERT(NVARCHAR(30), oiNoise.CreatedAt, 126)))) % 17)
                    FROM OrderItems oiNoise
                    CROSS JOIN (
                        SELECT TOP 25 Id, CustomerName
                        FROM Orders
                        ORDER BY CreatedAt DESC
                    ) recentOrders
                    WHERE LEN(oiNoise.Sku) > 0
                ) AS WastefulChecksum
        OPTION (RECOMPILE)
        """;

    using var cmd = new SqlCommand(sql, db);
    cmd.CommandTimeout = 60;
    cmd.Parameters.AddWithValue("@OrderIdText", orderId.ToString());

    using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SingleRow);
    await reader.ReadAsync();

    return new OrderItemSummary(
        reader.GetInt32(0),
        reader.GetInt32(1),
        reader.GetDecimal(2),
        reader.IsDBNull(3) ? null : reader.GetDateTime(3));
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------
record CreateOrderRequest(string CustomerName, string ProductId, string Category, int Quantity, decimal TotalPrice);

record UpdateOrderStatusRequest(string Status);

record OrderSummaryRow(int Id, string CustomerName, string ProductId, int Quantity, decimal TotalPrice, DateTime CreatedAt, string Status);

record OrderItemSummary(int LineItemCount, int Units, decimal ItemsTotal, DateTime? LastItemUpdatedAt);
