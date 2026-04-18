# =============================================================================
# Install-SqlServer-ISO.ps1
# Run on Hyper-V host VM (NOT from remote PC):
#   Mount a host-side SQL Server ISO to a nested guest VM via virtual DVD drive,
#   then run the installer on the guest by PowerShell Direct.
#
# Prerequisites:
#   - Setup-NestedEnvironment.ps1 Phase 6 (domain join) completed
#   - vm-sql01 is running and domain-joined
#   - SQL Server ISO exists on the Hyper-V host (for example: F:\ISO\*.iso)
#
# Usage:
#   .\Install-SqlServer-ISO.ps1 -IsoPath 'F:\ISO\SQLServer2019-x64-ENU-Dev.iso'
#   .\Install-SqlServer-ISO.ps1 -IsoPath 'F:\ISO\SQLServer2022-x64-ENU-Dev.iso' -Force
#   .\Install-SqlServer-ISO.ps1 -IsoPath 'F:\ISO\SQLServer2025-x64-ENU-Dev.iso' -DisableSa -SqlAdminPassword 'Adm1nP@ss!'
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$IsoPath,

    [string]$VMName = 'vm-sql01',

    [string]$InstanceName = 'MSSQLSERVER',

    # Domain Administrator password (must match Setup-NestedEnvironment.ps1 / -NewPassword)
    [string]$AdminPassword = 'P@ssW0rd1234!',

    # SQL Server sa account password (defaults to AdminPassword if not specified)
    [string]$SqlSaPassword,

    # Disable sa and create a new sysadmin login (requires -SqlAdminPassword)
    [switch]$DisableSa,

    # New sysadmin login name (used only with -DisableSa)
    [string]$SqlAdminName = 'sqladmin',

    # Password for the new sysadmin login (required with -DisableSa)
    [string]$SqlAdminPassword,

    [string]$Collation = 'Japanese_CI_AS',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $scriptRoot 'logs'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$cfg = @{
    DomainNetBIOS  = 'CONTOSO'
    GuestTempPath  = 'C:\SQLInstall'
    TranscriptFile = Join-Path $logDir "Install-SqlServer-ISO-$runStamp.log"
}

$script:TranscriptStarted = $false
try {
    Start-Transcript -Path $cfg.TranscriptFile -Force | Out-Null
    $script:TranscriptStarted = $true
} catch {
    Write-Warning "Transcript logging could not be started: $($_.Exception.Message)"
}

try {
    if (-not $SqlSaPassword) { $SqlSaPassword = $AdminPassword }

    if ($DisableSa) {
        if (-not $SqlAdminPassword) {
            throw '-DisableSa requires -SqlAdminPassword to set the new admin login password.'
        }
    } else {
        if ($PSBoundParameters.ContainsKey('SqlAdminName') -or $PSBoundParameters.ContainsKey('SqlAdminPassword')) {
            Write-Warning '-SqlAdminName / -SqlAdminPassword are ignored without -DisableSa. sa remains enabled.'
        }
    }

    function Get-DomainCred {
        $secPwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new("$($cfg.DomainNetBIOS)\Administrator", $secPwd)
    }

    function Get-GuestSetupPath {
        param(
            [string]$TargetVM,
            [pscredential]$Credential,
            [int]$TimeoutSec = 120
        )

        Invoke-Command -VMName $TargetVM -Credential $Credential -ScriptBlock {
            param($TimeoutSec)

            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                $cdDrives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 5" -ErrorAction SilentlyContinue
                foreach ($drive in $cdDrives) {
                    $setupPath = "$($drive.DeviceID)\setup.exe"
                    if (Test-Path $setupPath) {
                        return $setupPath
                    }
                }
                Start-Sleep -Seconds 3
            }

            throw 'setup.exe not found on any guest CD/DVD drive.'
        } -ArgumentList $TimeoutSec
    }

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host '  Install-SqlServer-ISO.ps1 - Host ISO Mount Installer' -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  This script mounts a host ISO into the guest VM and installs SQL Server.' -ForegroundColor Gray
    Write-Host ''
    Write-Host "  ISO:         $IsoPath" -ForegroundColor Yellow
    Write-Host "  Target VM:   $VMName"
    Write-Host "  Instance:    $InstanceName"
    Write-Host "  Collation:   $Collation"
    Write-Host '  Passwords:   ********'
    Write-Host "  Transcript:  $($cfg.TranscriptFile)"
    Write-Host ''

    if (-not $Force) {
        $answer = Read-Host '  続行しますか? (y/N)'
        if ($answer -ne 'y') {
            Write-Host '  中断しました。' -ForegroundColor Yellow
            exit 0
        }
        Write-Host ''
    }

    # =============================================================================
    # Step 1: Verify guest VM is reachable
    # =============================================================================
    Write-Host '========================================='
    Write-Host '  Step 1: Verify guest VM connectivity'
    Write-Host '========================================='

    $cred = Get-DomainCred

    try {
        $hostname = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
            $env:COMPUTERNAME
        } -ErrorAction Stop
        Write-Host "  Connected to $VMName (hostname: $hostname)" -ForegroundColor Green
    } catch {
        throw "Cannot connect to $VMName via PowerShell Direct. Ensure the VM is running and domain-joined."
    }

    # =============================================================================
    # Step 2: Mount ISO from host to guest virtual DVD drive
    # =============================================================================
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 2: Mount ISO to guest DVD drive'
    Write-Host '========================================='

    $resolvedIsoPath = (Resolve-Path -Path $IsoPath).Path
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        throw "VM '$VMName' is not running. Start the VM first."
    }

    $dvdDrive = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dvdDrive) {
        Add-VMDvdDrive -VMName $VMName -Path $resolvedIsoPath | Out-Null
        Write-Host '  Added virtual DVD drive and mounted ISO.' -ForegroundColor Green
    } else {
        Set-VMDvdDrive -VMName $VMName `
            -ControllerNumber $dvdDrive.ControllerNumber `
            -ControllerLocation $dvdDrive.ControllerLocation `
            -Path $resolvedIsoPath | Out-Null
        Write-Host '  Mounted ISO to existing virtual DVD drive.' -ForegroundColor Green
    }

    $setupExePath = Get-GuestSetupPath -TargetVM $VMName -Credential $cred
    Write-Host "  Guest setup path: $setupExePath" -ForegroundColor Green

    # =============================================================================
    # Step 3: Install SQL Server (silent)
    # =============================================================================
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 3: Install SQL Server'
    Write-Host '========================================='
    Write-Host "  Running setup.exe on $VMName (this may take 10-30 minutes)..."

    $installResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        param($SetupExe, $InstanceName, $SaPassword, $Collation, $GuestTempPath)

        New-Item -Path $GuestTempPath -ItemType Directory -Force | Out-Null

        $existingService = if ($InstanceName -eq 'MSSQLSERVER') {
            Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
        } else {
            Get-Service -Name "MSSQL`$$InstanceName" -ErrorAction SilentlyContinue
        }

        if ($existingService) {
            Write-Host "    SQL Server instance '$InstanceName' already installed. Skipping." -ForegroundColor Yellow
            return @{ ExitCode = 0; Skipped = $true; LogPath = $null; Stdout = $null; Stderr = $null }
        }

        $setupArgs = @(
            '/Q',
            '/ACTION=Install',
            '/FEATURES=SQLEngine',
            "/INSTANCENAME=$InstanceName",
            '/SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"',
            '/AGTSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
            '/SQLSVCSTARTUPTYPE=Automatic',
            '/AGTSVCSTARTUPTYPE=Automatic',
            '/SECURITYMODE=SQL',
            "/SAPWD=$SaPassword",
            '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"',
            "/SQLCOLLATION=$Collation",
            '/TCPENABLED=1',
            '/NPENABLED=0',
            '/UpdateEnabled=False',
            '/IACCEPTSQLSERVERLICENSETERMS',
            '/SUPPRESSPRIVACYSTATEMENTNOTICE'
        )

        $stdout = Join-Path $GuestTempPath 'setup-stdout.log'
        $stderr = Join-Path $GuestTempPath 'setup-stderr.log'

        Write-Host '    Starting SQL Server setup...'
        $proc = Start-Process -FilePath $SetupExe -ArgumentList $setupArgs `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        $logPath = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Filter 'Setup Bootstrap' -Directory -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName

        return @{
            ExitCode = $proc.ExitCode
            Skipped  = $false
            LogPath  = $logPath
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } -ArgumentList $setupExePath, $InstanceName, $SqlSaPassword, $Collation, $cfg.GuestTempPath

    if ($installResult.Skipped) {
        Write-Host '  Installation skipped (already installed).' -ForegroundColor Yellow
    } elseif ($installResult.ExitCode -eq 0) {
        Write-Host '  SQL Server installed successfully.' -ForegroundColor Green
    } elseif ($installResult.ExitCode -eq 3010) {
        Write-Host '  SQL Server installed successfully (reboot required).' -ForegroundColor Yellow
    } else {
        Write-Host "  Setup exited with code: $($installResult.ExitCode)" -ForegroundColor Red
        if ($installResult.Stdout) {
            Write-Host "  Guest stdout: $($installResult.Stdout)" -ForegroundColor Red
        }
        if ($installResult.Stderr) {
            Write-Host "  Guest stderr: $($installResult.Stderr)" -ForegroundColor Red
        }
        if ($installResult.LogPath) {
            Write-Host "  Setup Bootstrap log: $($installResult.LogPath)" -ForegroundColor Red
        }
        throw "SQL Server installation failed (exit code $($installResult.ExitCode))."
    }

    # =============================================================================
    # Step 4: Post-install configuration (disable sa, create new sysadmin)
    # =============================================================================
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 4: Post-install configuration'
    Write-Host '========================================='

    if (-not $DisableSa) {
        Write-Host '  Skipped (-DisableSa not specified; sa remains enabled).' -ForegroundColor Gray
    } elseif ($installResult.Skipped) {
        Write-Host '  Skipped (installation was skipped).' -ForegroundColor Yellow
    } else {
        Write-Host "  Creating SQL login '$SqlAdminName' with sysadmin role..."

        Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
            param($SqlAdminName, $SqlAdminPassword)

            $createAdminSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SqlAdminName')
BEGIN
    CREATE LOGIN [$SqlAdminName] WITH PASSWORD = '$SqlAdminPassword', CHECK_POLICY = OFF;
END
ALTER SERVER ROLE [sysadmin] ADD MEMBER [$SqlAdminName];
"@

            sqlcmd -E -S "." -Q $createAdminSql
            if ($LASTEXITCODE -ne 0) { throw "Failed to create SQL login '$SqlAdminName'." }
            Write-Host "    Created login '$SqlAdminName' with sysadmin role." -ForegroundColor Green

            $disableSaSql = 'ALTER LOGIN [sa] DISABLE;'
            sqlcmd -E -S "." -Q $disableSaSql
            if ($LASTEXITCODE -ne 0) { throw 'Failed to disable sa login.' }
            Write-Host '    Disabled sa login.' -ForegroundColor Yellow
        } -ArgumentList $SqlAdminName, $SqlAdminPassword

        Write-Host "  [DONE] SQL admin '$SqlAdminName' created." -ForegroundColor Green
        Write-Host '  [DONE] sa account disabled.' -ForegroundColor Yellow
    }

    # =============================================================================
    # Step 5: Verify installation
    # =============================================================================
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 5: Verify installation'
    Write-Host '========================================='

    $verifyResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        param($InstanceName)

        $serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if (-not $svc) {
            return @{ Installed = $false }
        }

        if ($svc.Status -ne 'Running') {
            Start-Service -Name $serviceName
            Start-Sleep -Seconds 5
            $svc = Get-Service -Name $serviceName
        }

        $setupReg = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'MSSQL*' } |
            ForEach-Object {
                Get-ItemProperty -Path ($_.PSPath + '\Setup') -ErrorAction SilentlyContinue
            } |
            Select-Object -First 1

        return @{
            Installed   = $true
            ServiceName = $serviceName
            Status      = $svc.Status.ToString()
            Version     = if ($setupReg) { $setupReg.Version } else { 'Unknown' }
            Edition     = if ($setupReg) { $setupReg.Edition } else { 'Unknown' }
        }
    } -ArgumentList $InstanceName

    if ($verifyResult.Installed) {
        Write-Host "  [PASS] Service:  $($verifyResult.ServiceName) ($($verifyResult.Status))" -ForegroundColor Green
        Write-Host "  [PASS] Version:  $($verifyResult.Version)" -ForegroundColor Green
        Write-Host "  [PASS] Edition:  $($verifyResult.Edition)" -ForegroundColor Green
    } else {
        Write-Host '  [FAIL] SQL Server service not found.' -ForegroundColor Red
    }

    # =============================================================================
    # Step 6: Cleanup (eject ISO)
    # =============================================================================
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 6: Cleanup (eject ISO)'
    Write-Host '========================================='

    $dvdDrive = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dvdDrive) {
        Set-VMDvdDrive -VMName $VMName `
            -ControllerNumber $dvdDrive.ControllerNumber `
            -ControllerLocation $dvdDrive.ControllerLocation `
            -Path $null | Out-Null
        Write-Host '  ISO ejected from guest DVD drive.' -ForegroundColor Green
    }

    # =============================================================================
    # Summary
    # =============================================================================
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host '  Install-SqlServer-ISO.ps1 completed' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host ''
    Write-Host "  VM:        $VMName"
    Write-Host "  Instance:  $InstanceName"
    Write-Host "  ISO:       $resolvedIsoPath"
    if ($verifyResult.Installed) {
        Write-Host "  Version:   $($verifyResult.Version)"
        Write-Host "  Edition:   $($verifyResult.Edition)"
    }
    if ($DisableSa) {
        Write-Host "  SQL Admin: $SqlAdminName (sysadmin)"
        Write-Host '  sa:        Disabled' -ForegroundColor Yellow
    } else {
        Write-Host '  sa:        Enabled'
    }
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Gray
    Write-Host '    - Configure firewall: New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow' -ForegroundColor Gray
    Write-Host '    - Restore database or deploy application' -ForegroundColor Gray
    Write-Host ''
}
finally {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }
}
