$pw = ConvertTo-SecureString 'P@ssW0rd1234!' -AsPlainText -Force
$localCred = New-Object System.Management.Automation.PSCredential('.\Administrator', $pw)
$domainCred = New-Object System.Management.Automation.PSCredential('CONTOSO\Administrator', $pw)

foreach ($vm in @('vm-ad01','vm-app01','vm-sql01')) {
    Write-Host "=== $vm ==="
    foreach ($cred in @($domainCred, $localCred)) {
        try {
            Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
                $cs = Get-WmiObject Win32_ComputerSystem
                Write-Host "  ComputerName: $($cs.Name)"
                Write-Host "  Domain:       $($cs.Domain)"
                Write-Host "  PartOfDomain: $($cs.PartOfDomain)"
            } -ErrorAction Stop
            break
        } catch {
            continue
        }
    }
}
