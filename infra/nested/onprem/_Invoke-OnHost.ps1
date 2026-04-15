# =============================================================================
# _Invoke-OnHost.ps1
# Helper: Run a PowerShell script on the Hyper-V host via az vm run-command
# and display formatted output.
#
# Usage: dot-source from wrapper scripts
#   . "$PSScriptRoot\_Invoke-OnHost.ps1"
#   Invoke-OnHost -ScriptFile 'scripts\Setup-NestedNetwork.ps1' -StepName 'Setup Network'
# =============================================================================

$script:ResourceGroup = 'rg-onprem-nested'
$script:VmName = 'vm-onprem-nested-hv01'

function Invoke-OnHost {
    param(
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$ScriptFile,

        [Parameter(Mandatory, ParameterSetName = 'Inline')]
        [string]$InlineScript,

        [string]$StepName = '',
        [switch]$Async,
        [int]$TimeoutSeconds = 3600
    )

    $separator = '=' * 60
    Write-Host ""
    Write-Host $separator -ForegroundColor Cyan
    if ($StepName) { Write-Host "  $StepName" -ForegroundColor Cyan }
    Write-Host $separator -ForegroundColor Cyan

    if ($ScriptFile) {
        Write-Host "  Script : $ScriptFile" -ForegroundColor DarkGray
    } else {
        Write-Host "  Inline : $InlineScript" -ForegroundColor DarkGray
    }
    Write-Host "  Target : $($script:VmName) ($($script:ResourceGroup))" -ForegroundColor DarkGray
    Write-Host ""

    # --- Async execution (v2 API) ---
    if ($Async) {
        $cmdName = if ($StepName) { $StepName -replace '\s+', '' } else { 'RunCommand' }

        # Delete previous run command if exists
        az vm run-command delete `
            --resource-group $script:ResourceGroup `
            --vm-name $script:VmName `
            --name $cmdName `
            --yes 2>$null

        $createArgs = @(
            'vm', 'run-command', 'create',
            '--resource-group', $script:ResourceGroup,
            '--vm-name', $script:VmName,
            '--name', $cmdName,
            '--async-execution', 'true',
            '--timeout-in-seconds', $TimeoutSeconds,
            '--no-wait'
        )
        if ($ScriptFile) {
            $createArgs += '--script'
            $createArgs += "@$ScriptFile"
        } else {
            $createArgs += '--script'
            $createArgs += $InlineScript
        }

        & az @createArgs 2>&1 | Out-Null

        Write-Host "[ASYNC] Command submitted. Check status with:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  az vm run-command show ``" -ForegroundColor White
        Write-Host "      --resource-group $($script:ResourceGroup) ``" -ForegroundColor White
        Write-Host "      --vm-name $($script:VmName) ``" -ForegroundColor White
        Write-Host "      --name $cmdName ``" -ForegroundColor White
        Write-Host "      --instance-view ``" -ForegroundColor White
        Write-Host "      --query ""{state: instanceView.executionState, exit: instanceView.exitCode}"" ``" -ForegroundColor White
        Write-Host "      -o table" -ForegroundColor White
        Write-Host ""
        return $true
    }

    # --- Sync execution (v1 API) ---
    $invokeArgs = @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $script:ResourceGroup,
        '--name', $script:VmName,
        '--command-id', 'RunPowerShellScript'
    )
    if ($ScriptFile) {
        $invokeArgs += '--scripts'
        $invokeArgs += "@$ScriptFile"
    } else {
        $invokeArgs += '--scripts'
        $invokeArgs += $InlineScript
    }

    Write-Host "Executing..." -ForegroundColor DarkGray
    $rawOutput = & az @invokeArgs 2>&1 | Out-String

    # Parse JSON response
    try {
        $json = $rawOutput | ConvertFrom-Json
    }
    catch {
        Write-Host "[ERROR] Failed to parse response:" -ForegroundColor Red
        Write-Host $rawOutput
        return $false
    }

    $stdoutEntry = $json.value | Where-Object { $_.code -match 'StdOut' }
    $stderrEntry = $json.value | Where-Object { $_.code -match 'StdErr' }
    $stdout = $stdoutEntry.message
    $stderr = $stderrEntry.message
    $succeeded = $stdoutEntry.code -match 'succeeded'

    # Display output
    if ($stdout) {
        Write-Host $stdout
    }

    if ($stderr) {
        Write-Host ""
        Write-Host "--- Warnings / Errors ---" -ForegroundColor Yellow
        Write-Host $stderr -ForegroundColor Yellow
    }

    # Result
    Write-Host ""
    Write-Host $separator -ForegroundColor ($succeeded ? 'Green' : 'Red')
    if ($succeeded) {
        Write-Host "  [OK] $StepName" -ForegroundColor Green
    }
    else {
        Write-Host "  [FAILED] $StepName" -ForegroundColor Red
    }
    Write-Host $separator -ForegroundColor ($succeeded ? 'Green' : 'Red')
    Write-Host ""

    return $succeeded
}
