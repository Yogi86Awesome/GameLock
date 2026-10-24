# Install-Notifier.ps1
# Run from the gaming account (no admin needed). Copies the notifier into
# %LOCALAPPDATA%\GameLock and registers it to start at logon, so you can
# delete the download folder afterwards.

param([switch]$NoPause)
$ErrorActionPreference = 'Stop'

$LocalDir = Join-Path $env:LOCALAPPDATA 'GameLock'
Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'SteamLimiter') -Recurse -Force -ErrorAction SilentlyContinue   # older name
if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir | Out-Null }
foreach ($f in @('Notifier.ps1', 'Show-Overlay.ps1')) {
    Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination $LocalDir -Force
}

# Stop a previous copy, if any.
foreach ($t in 'GameLockNotifier', 'SteamLimiterNotifier') { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Notifier.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# conhost --headless gives the script a console with no window at all, so there
# is nothing on screen to close by accident (closing it would kill the badge).
$Action = New-ScheduledTaskAction -Execute 'conhost.exe' `
    -Argument "--headless powershell.exe -NoProfile -sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LocalDir\Notifier.ps1`""
$Trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden

Register-ScheduledTask -TaskName 'GameLockNotifier' -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
Start-ScheduledTask -TaskName 'GameLockNotifier'

Write-Host "Notifier installed in $LocalDir. Warning banners will appear at the points set in config.json." -ForegroundColor Green
if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
