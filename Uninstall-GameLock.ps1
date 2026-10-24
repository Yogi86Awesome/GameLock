# Uninstall-GameLock.ps1
# Removes the SYSTEM watcher task and C:\ProgramData\GameLock.
# Right-click > Run with PowerShell (elevates itself).
# The notifier is per-user; remove it with Uninstall-Notifier.ps1 from the gaming account.

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Wait
    exit
}

foreach ($t in @('GameLock', 'SteamLimiter', 'SteamLimiterLogon', 'SteamLimiterWatchdog')) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { ($_.CommandLine -like '*GameLock.ps1*' -or $_.CommandLine -like '*SteamLimiter.ps1*') -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$InstallDir = 'C:\ProgramData\GameLock'
if (Test-Path $InstallDir) {
    Set-Location $env:SystemRoot   # in case this script is running from inside the folder
    Remove-Item -Path $InstallDir -Recurse -Force
}
Write-Host 'GameLock removed.' -ForegroundColor Green
Read-Host 'Press Enter to close' | Out-Null
