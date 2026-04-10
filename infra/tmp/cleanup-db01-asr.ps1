# DB01 ASR Cleanup Script
sc.exe delete svagents 2>&1
sc.exe delete "InMage Scout Application Service" 2>&1
sc.exe delete frsvc 2>&1

if (Test-Path 'C:\Program Files (x86)\Microsoft Azure Site Recovery.broken-20260409') {
    Remove-Item 'C:\Program Files (x86)\Microsoft Azure Site Recovery.broken-20260409' -Recurse -Force
    Write-Output 'Removed broken-20260409 folder'
}
if (Test-Path 'C:\Program Files (x86)\Microsoft Azure Site Recovery') {
    Remove-Item 'C:\Program Files (x86)\Microsoft Azure Site Recovery' -Recurse -Force
    Write-Output 'Removed ASR folder'
}

reg delete "HKLM\SOFTWARE\Wow6432Node\InMage Systems" /f 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Azure Site Recovery" /f 2>&1

Remove-Item C:\Temp\ASRExtract -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item C:\Temp\config.json -Force -ErrorAction SilentlyContinue
Remove-Item C:\Temp\db01-config-fresh.json -Force -ErrorAction SilentlyContinue

Remove-MpPreference -ExclusionPath 'C:\Program Files (x86)\Microsoft Azure Site Recovery' -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath 'C:\ProgramData\ASR' -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath 'C:\ProgramData\ASRLogs' -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath 'C:\ProgramData\ASRSetupLogs' -ErrorAction SilentlyContinue
Remove-MpPreference -ExclusionPath 'C:\ProgramData\Microsoft Azure Site Recovery' -ErrorAction SilentlyContinue

$hosts = Get-Content C:\Windows\System32\drivers\etc\hosts | Where-Object { $_ -notmatch 'REPL' }
Set-Content -Path C:\Windows\System32\drivers\etc\hosts -Value $hosts

Write-Output 'DB01 ASR cleanup complete'
