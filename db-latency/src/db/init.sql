-- ============================================================================
-- シナリオ3: Azure SQL Database 初期化スクリプト
-- Orders テーブル + シードデータ + 意図的にインデックスなしカラムを含む
-- ============================================================================

-- テーブル作成
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders')
BEGIN
    CREATE TABLE Orders (
        Id            INT IDENTITY(1,1) PRIMARY KEY,
        CustomerName  NVARCHAR(200)   NOT NULL,
        ProductId     NVARCHAR(100)   NOT NULL,
        Quantity      INT             NOT NULL,
        TotalPrice    DECIMAL(18,2)   NOT NULL,
        CreatedAt     DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
        Status        NVARCHAR(50)    NOT NULL DEFAULT 'pending'
        -- 注意: CustomerName, Status にはインデックスを意図的に作成しない
        -- → SRE Agent がインデックス追加を提案することを期待
    );

    -- Id に対するクラスタードインデックスは PK で自動作成
    -- CreatedAt にのみ非クラスタードインデックスを作成
    CREATE NONCLUSTERED INDEX IX_Orders_CreatedAt ON Orders (CreatedAt DESC);
END
GO

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'OrderItems')
BEGIN
    CREATE TABLE OrderItems (
        Id            INT IDENTITY(1,1) PRIMARY KEY,
        OrderId       INT             NOT NULL,
        Sku           NVARCHAR(100)   NOT NULL,
        Quantity      INT             NOT NULL,
        LineTotal     DECIMAL(18,2)   NOT NULL,
        ItemStatus    NVARCHAR(50)    NOT NULL,
        CreatedAt     DATETIME2       NOT NULL DEFAULT GETUTCDATE()
        -- 注意: OrderId, ItemStatus にインデックスを作らない
        -- → 一覧画面での N+1 集計がスキャンを引き起こす
    );
END
GO

-- シードデータ（1000 件の注文）
DECLARE @i INT = 1;
DECLARE @customers TABLE (Name NVARCHAR(200));
INSERT INTO @customers VALUES
    (N'田中太郎'), (N'鈴木花子'), (N'佐藤一郎'), (N'山田美咲'),
    (N'高橋健二'), (N'伊藤直美'), (N'渡辺大輔'), (N'中村さくら'),
    (N'小林和也'), (N'加藤裕子');

DECLARE @products TABLE (ProductId NVARCHAR(100), Category NVARCHAR(50), Price DECIMAL(18,2));
INSERT INTO @products VALUES
    ('PROD-0001', 'electronics', 12800),
    ('PROD-0002', 'electronics', 34500),
    ('PROD-0003', 'apparel',     4980),
    ('PROD-0004', 'apparel',     8900),
    ('PROD-0005', 'food',        1200),
    ('PROD-0006', 'food',         890),
    ('PROD-0007', 'books',       2400),
    ('PROD-0008', 'books',       3600),
    ('PROD-0009', 'electronics', 67800),
    ('PROD-0010', 'apparel',     2980);

WHILE @i <= 1000
BEGIN
    INSERT INTO Orders (CustomerName, ProductId, Quantity, TotalPrice, CreatedAt, Status)
    SELECT TOP 1
        c.Name,
        p.ProductId,
        ABS(CHECKSUM(NEWID())) % 5 + 1,
        p.Price * (ABS(CHECKSUM(NEWID())) % 5 + 1),
        DATEADD(MINUTE, -@i * 3, GETUTCDATE()),
        CASE ABS(CHECKSUM(NEWID())) % 4
            WHEN 0 THEN 'pending'
            WHEN 1 THEN 'confirmed'
            WHEN 2 THEN 'shipped'
            ELSE 'delivered'
        END
    FROM @customers c
    CROSS JOIN @products p
    ORDER BY NEWID();

    SET @i = @i + 1;
END
GO

PRINT 'Database initialized with 1000 seed orders.';
GO

DECLARE @orderId INT = 1;
DECLARE @maxOrderId INT = (SELECT ISNULL(MAX(Id), 0) FROM Orders);

WHILE @orderId <= @maxOrderId
BEGIN
    IF NOT EXISTS (SELECT 1 FROM OrderItems WHERE OrderId = @orderId)
    BEGIN
        DECLARE @lineNo INT = 1;
        DECLARE @lineCount INT = (@orderId % 4) + 1;

        WHILE @lineNo <= @lineCount
        BEGIN
            INSERT INTO OrderItems (OrderId, Sku, Quantity, LineTotal, ItemStatus, CreatedAt)
            VALUES (
                @orderId,
                CONCAT('SKU-', RIGHT(CONCAT('0000', (@orderId + @lineNo) % 250), 4)),
                (@lineNo % 3) + 1,
                ((@orderId % 15) + 1) * ((@lineNo % 3) + 1) * 450,
                CASE (@lineNo + @orderId) % 4
                    WHEN 0 THEN 'pending'
                    WHEN 1 THEN 'allocated'
                    WHEN 2 THEN 'packed'
                    ELSE 'shipped'
                END,
                DATEADD(SECOND, @lineNo * 45, DATEADD(MINUTE, -@orderId * 3, GETUTCDATE()))
            );

            SET @lineNo = @lineNo + 1;
        END
    END

    SET @orderId = @orderId + 1;
END
GO

PRINT 'OrderItems initialized for seeded orders.';
GO
