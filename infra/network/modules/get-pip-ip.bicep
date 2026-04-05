// ============================================================
// get-pip-ip.bicep
// 指定された Public IP Address の IP アドレスを取得する
// ============================================================

param pipName string

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' existing = {
  name: pipName
}

output ipAddress string = pip.properties.ipAddress
