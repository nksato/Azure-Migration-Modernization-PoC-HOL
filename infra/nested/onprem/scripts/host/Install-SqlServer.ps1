# =============================================================================
# Install-SqlServer.ps1
# Run on Hyper-V host VM (NOT from remote PC):
#   Install SQL Server Developer Edition on a nested guest VM (vm-sql01).
#
# Two modes:
#   1. -Version  : Download bootstrapper and install (2019 / 2022)
#   2. -IsoPath  : Mount a pre-downloaded ISO and install (any version)
#
# Prerequisites:
#   - Setup-NestedEnvironment.ps1 Phase 6 (domain join) completed
#   - vm-sql01 is running and domain-joined
#   - For -IsoPath: ISO file accessible from host (e.g. F:\ISO\*.iso)
#
# Usage:
#   .\Install-SqlServer.ps1 -Version 2022
#   .\Install-SqlServer.ps1 -Version 2019
#   .\Install-SqlServer.ps1 -IsoPath 'F:\ISO\SQLServer2025-x64-ENU-Dev.iso'
#   .\Install-SqlServer.ps1 -Version 2022 -InstanceName 'SQL2022' -SqlSaPassword 'MyP@ss1'
#   .\Install-SqlServer.ps1 -Version 2022 -AdminPassword 'ChangedP@ss!'
#   .\Install-SqlServer.ps1 -Version 2022 -DisableSa -SqlAdminPassword 'Adm1nP@ss!'
#   .\Install-SqlServer.ps1 -Version 2022 -DisableSa -SqlAdminName 'dbadmin' -SqlAdminPassword 'Adm1nP@ss!'
#   .\Install-SqlServer.ps1 -Version 2022 -Force
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding(DefaultParameterSetName = 'Download')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Download')]
    [ValidateSet('2019', '2022')]
    [string]$Version,

    [Parameter(Mandatory, ParameterSetName = 'ISO')]
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

# =============================================================================
# Configuration
# =============================================================================
$cfg = @{
    DomainNetBIOS = 'CONTOSO'
    TempPath      = 'C:\SQLInstall'

    # Bootstrapper download URLs (Developer Edition)
    BootstrapperUrl = @{
        '2019' = 'https://go.microsoft.com/fwlink/?linkid=866662'
        '2022' = 'https://go.microsoft.com/fwlink/?linkid=2215158'
    }
}

if (-not $SqlSaPassword) { $SqlSaPassword = $AdminPassword }

# Parameter validation: -DisableSa requires -SqlAdminPassword
if ($DisableSa) {
    if (-not $SqlAdminPassword) {
        throw '-DisableSa requires -SqlAdminPassword to set the new admin login password.'
    }
} else {
    if ($PSBoundParameters.ContainsKey('SqlAdminName') -or $PSBoundParameters.ContainsKey('SqlAdminPassword')) {
        Write-Warning '-SqlAdminName / -SqlAdminPassword are ignored without -DisableSa. sa remains enabled.'
    }
}

# =============================================================================
# Pre-execution summary
# =============================================================================
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host '  Install-SqlServer.ps1 - SQL Server Developer Edition Installer' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host ''
Write-Host '  This script installs SQL Server Developer Edition on a guest VM.' -ForegroundColor Gray
Write-Host ''
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host '  [Mode 1] -Version (2019 / 2022)' -ForegroundColor White
Write-Host '    Developer Edition bootstrapper を Microsoft から自動ダウンロードし、' -ForegroundColor Gray
Write-Host '    サイレントインストールを実行します。' -ForegroundColor Gray
Write-Host ''
Write-Host '    例: .\Install-SqlServer.ps1 -Version 2022' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  [Mode 2] -IsoPath (任意のバージョン / エディション)' -ForegroundColor White
Write-Host '    Visual Studio Subscription 等で取得した ISO ファイルを指定します。' -ForegroundColor Gray
Write-Host '    ISO はホスト上のパスを指定してください (ゲスト VM へ自動転送します)。' -ForegroundColor Gray
Write-Host '    SQL Server 2025 等、ブートストラッパー非公開のバージョンはこちらを使用。' -ForegroundColor Gray
Write-Host ''
Write-Host '    例: .\Install-SqlServer.ps1 -IsoPath ''F:\ISO\SQLServer2025-Dev.iso''' -ForegroundColor DarkGray
Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

if ($PSCmdlet.ParameterSetName -eq 'Download') {
    Write-Host "  Mode:       Download (Bootstrapper)" -ForegroundColor Yellow
    Write-Host "  Version:    SQL Server $Version Developer Edition"
    Write-Host "  URL:        $($cfg.BootstrapperUrl[$Version])"
} else {
    Write-Host "  Mode:       ISO" -ForegroundColor Yellow
    Write-Host "  ISO:        $IsoPath"
}
Write-Host "  Target VM:  $VMName"
Write-Host "  Instance:   $InstanceName"
Write-Host "  Collation:  $Collation"
if ($DisableSa) {
    Write-Host "  sa account: Will be DISABLED after setup" -ForegroundColor Yellow
    Write-Host "  SQL Admin:  $SqlAdminName (new sysadmin login to create)"
} else {
    Write-Host "  sa account: Enabled (use -DisableSa to disable)"
}
Write-Host "  Passwords:  ********"
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
# Helper functions
# =============================================================================
function Get-DomainCred {
    $secPwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    [System.Management.Automation.PSCredential]::new("$($cfg.DomainNetBIOS)\Administrator", $secPwd)
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
# Step 2: Prepare installation media on guest
# =============================================================================
Write-Host ''
Write-Host '========================================='
Write-Host '  Step 2: Prepare installation media'
Write-Host '========================================='

if ($PSCmdlet.ParameterSetName -eq 'Download') {
    # --- Mode 1: Download bootstrapper on guest, then download media ---
    Write-Host "  Downloading SQL Server $Version bootstrapper on $VMName..."

    $setupExePath = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        param($TempPath, $Url, $Version)

        New-Item -Path $TempPath -ItemType Directory -Force | Out-Null
        $bootstrapper = "$TempPath\SQLServer${Version}-SSEI-Dev.exe"

        if (-not (Test-Path $bootstrapper)) {
            Write-Host "    Downloading bootstrapper..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $bootstrapper -UseBasicParsing
            Write-Host "    Downloaded: $bootstrapper"
        } else {
            Write-Host "    Bootstrapper already exists. Skipping download."
        }

        # Download media via bootstrapper
        $mediaPath = "$TempPath\Media"
        if (-not (Test-Path "$mediaPath\setup.exe")) {
            Write-Host "    Downloading SQL Server media (this may take 5-15 minutes)..."
            $proc = Start-Process -FilePath $bootstrapper -ArgumentList @(
                '/ACTION=Download',
                "/MEDIAPATH=$mediaPath",
                '/MEDIATYPE=Core',
                '/QUIET'
            ) -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                throw "Bootstrapper download failed with exit code $($proc.ExitCode)"
            }

            # Extract if downloaded as CAB/EXE package
            $mediaExe = Get-ChildItem -Path $mediaPath -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mediaExe) {
                Write-Host "    Extracting media..."
                $extractPath = "$TempPath\Extracted"
                $proc = Start-Process -FilePath $mediaExe.FullName -ArgumentList "/Q /X:$extractPath" -Wait -PassThru -NoNewWindow
                if (Test-Path "$extractPath\setup.exe") {
                    return "$extractPath\setup.exe"
                }
            }

            if (Test-Path "$mediaPath\setup.exe") {
                return "$mediaPath\setup.exe"
            }

            throw "setup.exe not found after download. Check $mediaPath"
        } else {
            Write-Host "    Media already downloaded."
            return "$mediaPath\setup.exe"
        }
    } -ArgumentList $cfg.TempPath, $cfg.BootstrapperUrl[$Version], $Version

    Write-Host "  Setup path: $setupExePath" -ForegroundColor Green

} else {
    # --- Mode 2: Copy ISO to guest and mount ---
    Write-Host "  Copying ISO to $VMName..."

    $isoFileName = [System.IO.Path]::GetFileName($IsoPath)
    $isoBytes = [System.IO.File]::ReadAllBytes($IsoPath)
    $isoSizeMB = [math]::Round($isoBytes.Length / 1MB, 1)
    Write-Host "    ISO size: $isoSizeMB MB"

    $setupExePath = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        param($TempPath, $IsoFileName, $IsoBytes)

        New-Item -Path $TempPath -ItemType Directory -Force | Out-Null
        $guestIsoPath = "$TempPath\$IsoFileName"

        if (-not (Test-Path $guestIsoPath)) {
            Write-Host "    Writing ISO to guest..."
            [System.IO.File]::WriteAllBytes($guestIsoPath, $IsoBytes)
            Write-Host "    Written: $guestIsoPath"
        } else {
            Write-Host "    ISO already exists on guest. Skipping copy."
        }

        # Mount ISO
        Write-Host "    Mounting ISO..."
        $mountResult = Mount-DiskImage -ImagePath $guestIsoPath -PassThru
        $driveLetter = ($mountResult | Get-Volume).DriveLetter
        if (-not $driveLetter) {
            throw "ISO mounted but no drive letter assigned."
        }

        $setupPath = "${driveLetter}:\setup.exe"
        if (-not (Test-Path $setupPath)) {
            throw "setup.exe not found at $setupPath"
        }

        Write-Host "    Mounted at ${driveLetter}:" -ForegroundColor Green
        return $setupPath
    } -ArgumentList $cfg.TempPath, $isoFileName, $isoBytes

    Write-Host "  Setup path: $setupExePath" -ForegroundColor Green
}

# =============================================================================
# Step 3: Install SQL Server (silent)
# =============================================================================
Write-Host ''
Write-Host '========================================='
Write-Host '  Step 3: Install SQL Server'
Write-Host '========================================='
Write-Host "  Running setup.exe on $VMName (this may take 10-30 minutes)..."

$installResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($SetupExe, $InstanceName, $SaPassword, $Collation)

    # Check if instance already exists
    $existingService = Get-Service -Name "MSSQL`$$InstanceName" -ErrorAction SilentlyContinue
    if ($InstanceName -eq 'MSSQLSERVER') {
        $existingService = Get-Service -Name 'MSSQLSERVER' -ErrorAction SilentlyContinue
    }
    if ($existingService) {
        Write-Host "    SQL Server instance '$InstanceName' already installed. Skipping." -ForegroundColor Yellow
        return @{ ExitCode = 0; Skipped = $true }
    }

    $setupArgs = @(
        '/ACTION=Install',
        '/FEATURES=SQLEngine',
        "/INSTANCENAME=$InstanceName",
        '/SECURITYMODE=SQL',
        "/SAPWD=$SaPassword",
        "/SQLCOLLATION=$Collation",
        '/SQLSVCSTARTUPTYPE=Automatic',
        '/AGTSVCSTARTUPTYPE=Automatic',
        '/SQLSYSADMINACCOUNTS=BUILTIN\Administrators',
        '/TCPENABLED=1',
        '/IACCEPTSQLSERVERLICENSETERMS',
        '/Q'
    )

    Write-Host "    Starting SQL Server setup..."
    $proc = Start-Process -FilePath $SetupExe -ArgumentList $setupArgs `
        -Wait -PassThru -NoNewWindow -RedirectStandardOutput 'C:\SQLInstall\setup-stdout.log'

    return @{ ExitCode = $proc.ExitCode; Skipped = $false }
} -ArgumentList $setupExePath, $InstanceName, $SqlSaPassword, $Collation

if ($installResult.Skipped) {
    Write-Host '  Installation skipped (already installed).' -ForegroundColor Yellow
} elseif ($installResult.ExitCode -eq 0) {
    Write-Host '  SQL Server installed successfully.' -ForegroundColor Green
} elseif ($installResult.ExitCode -eq 3010) {
    Write-Host '  SQL Server installed successfully (reboot required).' -ForegroundColor Yellow
} else {
    Write-Host "  Setup exited with code: $($installResult.ExitCode)" -ForegroundColor Red
    Write-Host '  Check logs on guest: C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log' -ForegroundColor Red
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

    $postConfigResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
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

        $disableSaSql = "ALTER LOGIN [sa] DISABLE;"
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

    # Ensure service is running
    if ($svc.Status -ne 'Running') {
        Start-Service -Name $serviceName
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $serviceName
    }

    # Get version via registry
    $regPath = if ($InstanceName -eq 'MSSQLSERVER') {
        'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\Setup'
    } else {
        "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*\Setup"
    }
    $setupReg = Get-Item -Path $regPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $version = if ($setupReg) {
        (Get-ItemProperty -Path $setupReg.PSPath -ErrorAction SilentlyContinue).Version
    } else { 'Unknown' }

    $edition = if ($setupReg) {
        (Get-ItemProperty -Path $setupReg.PSPath -ErrorAction SilentlyContinue).Edition
    } else { 'Unknown' }

    return @{
        Installed   = $true
        ServiceName = $serviceName
        Status      = $svc.Status.ToString()
        Version     = $version
        Edition     = $edition
    }
} -ArgumentList $InstanceName

if ($verifyResult.Installed) {
    Write-Host "  [PASS] Service:  $($verifyResult.ServiceName) ($($verifyResult.Status))" -ForegroundColor Green
    Write-Host "  [PASS] Version:  $($verifyResult.Version)" -ForegroundColor Green
    Write-Host "  [PASS] Edition:  $($verifyResult.Edition)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] SQL Server service not found." -ForegroundColor Red
}

# =============================================================================
# Step 6: Cleanup (ISO mode only - dismount)
# =============================================================================
if ($PSCmdlet.ParameterSetName -eq 'ISO') {
    Write-Host ''
    Write-Host '========================================='
    Write-Host '  Step 6: Cleanup (dismount ISO)'
    Write-Host '========================================='

    Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
        param($TempPath, $IsoFileName)
        $guestIsoPath = "$TempPath\$IsoFileName"
        if (Test-Path $guestIsoPath) {
            Dismount-DiskImage -ImagePath $guestIsoPath -ErrorAction SilentlyContinue
            Write-Host "    Dismounted: $guestIsoPath"
        }
    } -ArgumentList $cfg.TempPath, $isoFileName
}

# =============================================================================
# Summary
# =============================================================================
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host '  Install-SqlServer.ps1 completed' -ForegroundColor Green
Write-Host ('=' * 70) -ForegroundColor Green
Write-Host ''
Write-Host "  VM:        $VMName"
Write-Host "  Instance:  $InstanceName"
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
