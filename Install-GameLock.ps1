# Install-GameLock.ps1
# Installs the watcher as SYSTEM in C:\ProgramData\GameLock.
# Right-click > Run with PowerShell. It elevates itself (UAC prompt).
#
# Parameters (optional, all have defaults):
#   -LimitMinutes 120      daily allowance
#   -ResetHour 5           local hour at which the day rolls over (0-23)
#   -Warnings "30,15,5,1"  minutes-remaining warning points for the notifier
#   -ExtraProcesses "a,b"  extra exe names (no .exe) to treat as games

param(
    [int]$LimitMinutes = 120,
    [int]$ResetHour = 5,
    [string]$Warnings = '30,15,5,1',
    [string]$ExtraProcesses = ''
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -LimitMinutes $LimitMinutes -ResetHour $ResetHour -Warnings `"$Warnings`" -ExtraProcesses `"$ExtraProcesses`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
    exit
}

$InstallDir = 'C:\ProgramData\GameLock'
$TaskName   = 'GameLock'

$LogFile = Join-Path $env:TEMP 'GameLock-install.log'
Start-Transcript -Path $LogFile -Force | Out-Null
trap {
    Write-Host ''
    Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host "Log: $LogFile"
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

function Pause-Exit([int]$Code) { Read-Host 'Press Enter to close' | Out-Null; exit $Code }

# --- migrate an install made under the old name (Steam Limiter) -------------
$OldDir = 'C:\ProgramData\SteamLimiter'
if ((Test-Path $OldDir) -and -not (Test-Path $InstallDir)) {
    foreach ($t in @('SteamLimiter', 'SteamLimiterLogon', 'SteamLimiterWatchdog')) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*SteamLimiter.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $OldDir -Destination $InstallDir -Force
    Remove-Item -Path (Join-Path $InstallDir 'SteamLimiter.ps1'), (Join-Path $InstallDir 'Install-SteamLimiterAdmin.ps1'), (Join-Path $InstallDir 'Uninstall-SteamLimiterAdmin.ps1'), (Join-Path $InstallDir 'SteamLimiter.ico') -Force -ErrorAction SilentlyContinue
    Write-Host "Moved existing settings, password and history from $OldDir to $InstallDir."
}

# --- admin password (the person in charge of the limit types this) -----------
function Get-PasswordHash([string]$Plain, [byte[]]$Salt) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Plain, $Salt, 100000)
    try { return [Convert]::ToBase64String($kdf.GetBytes(32)) } finally { $kdf.Dispose() }
}
function Read-Plain([string]$Prompt) {
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
$SecretFile = Join-Path $InstallDir 'secret.json'
$secret = $null
if (Test-Path $SecretFile) {
    $keep = Read-Host 'An admin password is already set. Keep it? [Y/n]'
    if ($keep -notmatch '^[nN]') { $secret = Get-Content $SecretFile -Raw | ConvertFrom-Json }
}
$plain = ''
if (-not $secret) {
    Write-Host ''
    Write-Host 'Choose the admin password for the control panel. Hand the keyboard to the person' -ForegroundColor Cyan
    Write-Host 'who will approve extra time; the gamer should not know this password.' -ForegroundColor Cyan
}
while (-not $secret -and -not $plain) {
    $p1 = Read-Plain 'Admin password'
    $p2 = Read-Plain 'Repeat password'
    if ($p1.Length -lt 4) { Write-Host 'Use at least 4 characters.' -ForegroundColor Yellow; continue }
    if ($p1 -ne $p2)      { Write-Host 'Passwords do not match, try again.' -ForegroundColor Yellow; continue }
    $plain = $p1
}
if (-not $secret) {
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $secret = [ordered]@{ salt = [Convert]::ToBase64String($salt); hash = (Get-PasswordHash $plain $salt); iterations = 100000 }
}
$plain = $p1 = $p2 = $null

# --- stop anything from a previous install ---------------------------------
foreach ($t in @('GameLock', 'SteamLimiter', 'SteamLimiterLogon', 'SteamLimiterWatchdog')) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { ($_.CommandLine -like '*GameLock.ps1*' -or $_.CommandLine -like '*SteamLimiter.ps1*') -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- folder: owned by Administrators, everyone else read-only ---------------
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
# Take ownership first: an owner can always rewrite permissions, so the folder
# must not stay owned by whoever happened to create it.
& takeown.exe /F $InstallDir /A /R /D Y | Out-Null
# SIDs, not names, so this works on any language of Windows:
#   S-1-5-32-544 Administrators, S-1-5-18 SYSTEM, S-1-5-32-545 Users
& icacls.exe $InstallDir /inheritance:r /Q `
    /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }
# Files inside simply inherit from the folder (a recursive grant would put
# inherit-only entries on files, which grant nothing).
if (Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue) {
    & icacls.exe "$InstallDir\*" /reset /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls reset failed with exit code $LASTEXITCODE" }
}

foreach ($f in @('GameLock.ps1', 'Admin-Panel.ps1', 'Uninstall-GameLock.ps1', 'header.png', 'GameLock.ico')) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { continue }
    Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination $InstallDir -Force
}

# --- config -----------------------------------------------------------------
# Fresh install: defaults from the parameters. Reinstall: keep whatever the
# admin panel has saved and only add keys that are missing.
$ConfigPath   = Join-Path $InstallDir 'config.json'
$offsetHours  = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalHours
$resetHourUtc = (($ResetHour - $offsetHours) % 24 + 24) % 24
$defaults = [ordered]@{
    limitMinutes   = $LimitMinutes
    weekdayMinutes = $LimitMinutes
    weekendMinutes = $LimitMinutes
    weekdayFrom    = 0
    weekdayUntil   = 0
    weekendFrom    = 0
    weekendUntil   = 0
    graceSeconds   = 60
    resetHourLocal = $ResetHour
    resetHourUtc   = $resetHourUtc
    warnings       = @($Warnings -split ',' | ForEach-Object { [int]$_.Trim() } | Where-Object { $_ -gt 0 })
    extraProcesses = @($ExtraProcesses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$existing = $null
if (Test-Path $ConfigPath) { try { $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }
$config = [ordered]@{}
foreach ($k in $defaults.Keys) {
    $config[$k] = if ($existing -and $null -ne $existing.$k) { $existing.$k } else { $defaults[$k] }
}
# Keep list settings as real arrays (an empty one would otherwise round-trip as {}).
foreach ($k in @('warnings', 'extraProcesses')) { $config[$k] = @($config[$k] | Where-Object { "$_" -ne '' -and $_ -isnot [PSCustomObject] }) }
if ($existing) {
    # Older installs had one limit only; seed the per-day limits from it.
    if ($null -eq $existing.weekdayMinutes) { $config['weekdayMinutes'] = $config['limitMinutes'] }
    if ($null -eq $existing.weekendMinutes) { $config['weekendMinutes'] = $config['limitMinutes'] }
    Write-Host "Kept existing settings from config.json (weekday $($config['weekdayMinutes']) / weekend $($config['weekendMinutes']) min)."
}
$config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

# The password hash is readable only by SYSTEM and administrators.
$secret | ConvertTo-Json | Set-Content -Path $SecretFile -Encoding UTF8
& icacls.exe $SecretFile /inheritance:r /Q /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on secret.json with exit code $LASTEXITCODE" }

# --- desktop shortcut for the admin panel -----------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
if ($env:USERPROFILE -and (Test-Path (Join-Path $env:USERPROFILE 'Desktop'))) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
foreach ($oldLnk in 'Steam Limiter Admin.lnk', 'Steam Limiter.lnk') { Remove-Item -Path (Join-Path $desktop $oldLnk) -Force -ErrorAction SilentlyContinue }
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desktop 'GameLock.lnk'))
$lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments  = "-NoProfile -sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\Admin-Panel.ps1`""
$lnk.WorkingDirectory = $InstallDir
$lnk.IconLocation = if (Test-Path (Join-Path $InstallDir 'GameLock.ico')) { "$InstallDir\GameLock.ico,0" } else { "$env:SystemRoot\System32\imageres.dll,77" }
$lnk.Description = 'GameLock admin panel (password required)'
$lnk.Save()

# --- scheduled task under SYSTEM --------------------------------------------
$ScriptPath = Join-Path $InstallDir 'GameLock.ps1'
$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
$Triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650))
)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
$Principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers -Settings $Settings -Principal $Principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ''
Write-Host "Installed. Watcher runs as SYSTEM from $InstallDir" -ForegroundColor Green
Write-Host "  Allowance       : weekday $($config['weekdayMinutes']) / weekend $($config['weekendMinutes']) min, resets at $($config['resetHourLocal']):00 local"
Write-Host "  Admin panel     : 'GameLock' shortcut on the desktop ($desktop)"
Write-Host ''
$admins = @(Get-LocalGroupMember -Group Administrators | ForEach-Object { $_.Name })
Write-Host "Administrators on this PC: $($admins -join ', ')"
Write-Host 'Any administrator can undo this lock by elevating. For admin accounts it is friction, not a wall.'
Write-Host ''
Write-Host 'Next: run Install-Notifier.ps1 from the gaming account to get the on-screen warnings.'
Stop-Transcript | Out-Null
Pause-Exit 0
