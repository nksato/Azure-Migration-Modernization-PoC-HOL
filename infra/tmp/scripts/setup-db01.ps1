# ============================================================
# DB01 セットアップスクリプト
# SQL Server 構成 + InventoryDB 作成
# ※ Bicep デプロイ後、Bastion 経由で RDP 接続して実行
# ============================================================

$ErrorActionPreference = 'Stop'

# SQL Server サービスの起動確認
$sqlService = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
if ($sqlService -and $sqlService.Status -ne 'Running') {
    Start-Service -Name 'MSSQLSERVER'
    Start-Sleep -Seconds 10
}

# DNS 設定は VNet の dhcpOptions で一括設定済み（DC01: 10.0.1.4）

# InventoryDB 作成 + テーブル + サンプルデータ
$sqlScript = @"
-- InventoryDB が存在しない場合のみ作成
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'InventoryDB')
BEGIN
    CREATE DATABASE InventoryDB;
END
GO

USE InventoryDB;
GO

-- Products テーブル
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Products')
BEGIN
    CREATE TABLE Products (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Name NVARCHAR(200) NOT NULL,
        Description NVARCHAR(1000),
        Price DECIMAL(18,2) NOT NULL,
        Quantity INT NOT NULL DEFAULT 0,
        Category NVARCHAR(100),
        CreatedAt DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        UpdatedAt DATETIME2 NOT NULL DEFAULT GETUTCDATE()
    );
END
GO

-- サンプルデータ投入
IF NOT EXISTS (SELECT TOP 1 * FROM Products)
BEGIN
    INSERT INTO Products (Name, Description, Price, Quantity, Category) VALUES
    (N'ノートPC', N'15.6インチ ビジネスノートPC', 89800.00, 50, N'PC'),
    (N'モニター 27インチ', N'4K UHD ディスプレイ', 45000.00, 30, N'ディスプレイ'),
    (N'ワイヤレスマウス', N'Bluetooth 対応 ワイヤレスマウス', 3500.00, 200, N'周辺機器'),
    (N'USB-C ハブ', N'7ポート USB-C マルチポートアダプタ', 7800.00, 100, N'周辺機器'),
    (N'メカニカルキーボード', N'日本語配列 メカニカルキーボード', 12000.00, 80, N'周辺機器'),
    (N'Webカメラ', N'1080p HD ストリーミング Webカメラ', 6500.00, 150, N'周辺機器'),
    (N'外付けSSD 1TB', N'USB 3.2 ポータブル SSD', 15000.00, 60, N'ストレージ'),
    (N'LANケーブル Cat6', N'5m カテゴリ6 LANケーブル', 800.00, 500, N'ネットワーク');
END
GO
"@

# 一時ディレクトリ作成
New-Item -Path 'C:\temp' -ItemType Directory -Force -ErrorAction SilentlyContinue

# sqlcmd で SQL スクリプトを実行
$sqlScript | Out-File -FilePath 'C:\temp\init-db.sql' -Encoding utf8

# Mixed Mode 認証を有効化（PoC 用）
$regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer'
if (Test-Path $regPath) {
    Set-ItemProperty -Path $regPath -Name 'LoginMode' -Value 2
    Restart-Service -Name 'MSSQLSERVER' -Force
    Start-Sleep -Seconds 10
}

# sqlcmd実行
& sqlcmd -S localhost -i 'C:\temp\init-db.sql' -o 'C:\temp\init-db-result.log'

Write-Output 'DB01 setup completed. InventoryDB created with sample data.'
