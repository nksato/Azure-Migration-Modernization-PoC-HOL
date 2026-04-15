# 03 - Start all nested VMs
. "$PSScriptRoot\_Invoke-OnHost.ps1"
$result = Invoke-OnHost -InlineScript 'Start-VM vm-ad01, vm-app01, vm-sql01; Get-VM | Format-Table Name, State -AutoSize' `
    -StepName 'Start Nested VMs'

if ($result) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  [次のステップ] OOBE (初期セットアップ)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Bastion RDP でホスト VM に接続" -ForegroundColor White
    Write-Host "  2. Hyper-V マネージャーを開く" -ForegroundColor White
    Write-Host "  3. vm-ad01, vm-app01, vm-sql01 それぞれを右クリック → [接続]" -ForegroundColor White
    Write-Host "  4. 各 VM で Windows の初期セットアップ (OOBE) を完了" -ForegroundColor White
    Write-Host "  5. OOBE 完了後、04-Configure-IPs.ps1 を実行" -ForegroundColor White
    Write-Host ""
}
