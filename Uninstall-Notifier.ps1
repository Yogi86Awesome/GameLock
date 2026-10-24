# Uninstall-Notifier.ps1
# Run from the gaming account. Removes the warning banners only; the lock stays.
param([switch]$NoPause)

foreach ($t in 'GameLockNotifier', 'SteamLimiterNotifier') { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Notifier.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'GameLock') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Notifier removed.' -ForegroundColor Green
if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
