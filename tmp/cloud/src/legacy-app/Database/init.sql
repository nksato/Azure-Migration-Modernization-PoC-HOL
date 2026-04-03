-- ============================================================
-- InventoryDB 初期化スクリプト
-- Spoke2/3/4 の Azure SQL Database にも適用可能
-- ============================================================

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'InventoryDB')
BEGIN
    CREATE DATABASE InventoryDB;
END
GO

USE InventoryDB;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[Products]') AND type in (N'U'))
BEGIN
    CREATE TABLE [dbo].[Products] (
        [Id]          INT            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        [Name]        NVARCHAR(200)  NOT NULL,
        [Description] NVARCHAR(MAX)  NULL,
        [Price]       DECIMAL(18,2)  NOT NULL DEFAULT 0,
        [Quantity]    INT            NOT NULL DEFAULT 0,
        [Category]    NVARCHAR(100)  NULL,
        [CreatedAt]   DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
        [UpdatedAt]   DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

-- サンプルデータ投入
IF NOT EXISTS (SELECT TOP 1 1 FROM [dbo].[Products])
BEGIN
    INSERT INTO [dbo].[Products] ([Name], [Description], [Price], [Quantity], [Category])
    VALUES
        (N'ノートPC - ThinkPad X1',   N'ビジネス向け 14インチ ノートPC',   198000, 25, N'PC'),
        (N'デスクトップPC - OptiPlex', N'オフィス向け デスクトップPC',       128000, 15, N'PC'),
        (N'モニター 27インチ 4K',      N'4K UHD 27インチ ディスプレイ',      52000, 40, N'周辺機器'),
        (N'ワイヤレスキーボード',       N'Bluetooth 日本語配列キーボード',     8500, 60, N'周辺機器'),
        (N'ワイヤレスマウス',           N'エルゴノミクス ワイヤレスマウス',     4200, 80, N'周辺機器'),
        (N'USB-C ドッキングステーション', N'4K デュアル出力対応 ドック',       25000, 30, N'周辺機器'),
        (N'LANケーブル Cat6 3m',       N'Cat6 UTP 3メートル',                 800,150, N'ネットワーク'),
        (N'無線LANルーター',            N'Wi-Fi 6 対応ルーター',             12000, 20, N'ネットワーク');
END
GO
