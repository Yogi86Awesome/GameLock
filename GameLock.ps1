# GameLock.ps1
# Daily playtime cap. Installed and run as SYSTEM by Install-GameLock.ps1.
#
# Every few seconds it:
#   * finds "game" processes: anything launched by a game launcher (Steam, Epic,
#     Battle.net, GOG) except the launchers' own helpers, anything running from a
#     game-library folder, any extra names from config.json, and anything it
#     already saw as a game (so a game outlives its launcher being closed)
#   * counts elapsed time only while at least one game is running
#   * decides whether play is allowed right now: budget left, inside the allowed
#     time window for this kind of day, and not locked by the admin
#   * when play is not allowed and a game is running, gives one grace period
#     (per day, per reason) so you can save, then kills the games and launcher
#
# Allowance for the day = weekday or weekend limit from config.json plus any
# extraMinutes for today in grants.json, which only an administrator can write
# (see Admin-Panel.ps1).
#
# Diagnostics (any user):  powershell -ExecutionPolicy Bypass -File GameLock.ps1 -Once
#   runs one check, prints what it sees, kills nothing, writes nothing.
# -DataDir points at a copy of the data folder for testing.

[CmdletBinding()]
param(
    [switch]$Once,
    [string]$DataDir = 'C:\ProgramData\GameLock'
)

$StateFile     = Join-Path $DataDir 'state.json'
$ConfigFile    = Join-Path $DataDir 'config.json'
$GrantFile     = Join-Path $DataDir 'grants.json'
$HistoryFile   = Join-Path $DataDir 'history.json'
$CheckInterval = 10   # seconds

# Launcher executables: their descendants count as games.
$LauncherNames = @('steam.exe', 'epicgameslauncher.exe', 'battle.net.exe', 'galaxyclient.exe')

# Processes launchers spawn that are not games.
$HelperNames = @(
    'steam.exe', 'steamwebhelper.exe', 'gameoverlayui.exe', 'steamerrorreporter.exe',
    'steamerrorreporter64.exe', 'steamservice.exe', 'steamsysinfo.exe',
    'epicgameslauncher.exe', 'epicwebhelper.exe', 'epiconlineservices.exe', 'epiconlineserviceshost.exe',
    'battle.net.exe', 'battle.net launcher.exe', 'agent.exe', 'blizzard error.exe',
    'galaxyclient.exe', 'galaxyclientservice.exe', 'galaxyclient helper.exe', 'galaxycommunication.exe',
    'conhost.exe', 'cmd.exe', 'explorer.exe', 'werfault.exe', 'dllhost.exe', 'crashpad_handler.exe'
)

# Game-library folders. A process whose path contains one of these is a game,
# unless it matches an exclusion (launcher folders that live inside them).
$LibraryPaths   = @('\steamapps\common\', '\Epic Games\', '\GOG Galaxy\Games\', '\GOG Games\')
$LibraryExclude = @('\Epic Games\Launcher\', '\Epic Games\Epic Online Services\')

function Read-Json([string]$Path, $Default) {
    if (Test-Path $Path) {
        try { return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
    return $Default
}

function Get-Config {
    $cfg = @{
        limitMinutes   = 120      # legacy single limit, used when the per-day ones are absent
        weekdayMinutes = $null
        weekendMinutes = $null
        resetHourLocal = 5
        resetHourUtc   = 3
        timeZoneId     = $null   # Windows time zone id recorded when the reset hour was saved
        warnings       = @(30, 15, 5, 1)
        extraProcesses = @()
        graceSeconds   = 60
        # Allowed hours, local time, 24 = midnight at the end of the day. Null = no restriction.
        weekdayFrom    = $null
        weekdayUntil   = $null
        weekendFrom    = $null
        weekendUntil   = $null
        days           = $null   # per-day: { Monday = { enabled, from, until }, ... }
    }
    $c = Read-Json $ConfigFile $null
    if ($c) {
        foreach ($k in @($cfg.Keys)) {
            if ($null -ne $c.$k) { $cfg[$k] = $c.$k }
        }
    }
    if ($null -eq $cfg.weekdayMinutes) { $cfg.weekdayMinutes = $cfg.limitMinutes }
    if ($null -eq $cfg.weekendMinutes) { $cfg.weekendMinutes = $cfg.limitMinutes }
    return $cfg
}

# "Local" time in the zone recorded when the reset hour was saved, so daylight
# saving is handled and changing the system time zone later changes nothing.
# Older configs only have a fixed offset; those fall back to it.
function Get-LocalNow($Config) {
    if ($Config.timeZoneId) {
        try { return [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById([string]$Config.timeZoneId)) } catch {}
    }
    $offset = [double]$Config.resetHourLocal - [double]$Config.resetHourUtc
    return [DateTime]::UtcNow.AddHours($offset)
}

# The "day" rolls over at the reset hour, not at midnight.
function Get-DayDate($Config) {
    return (Get-LocalNow $Config).AddHours(-[double]$Config.resetHourLocal).Date
}
function Get-DayKey($Config) { return (Get-DayDate $Config).ToString('yyyy-MM-dd') }

function Test-Weekend($Config) {
    $d = (Get-DayDate $Config).DayOfWeek
    return ($d -eq 'Saturday' -or $d -eq 'Sunday')
}

function Get-Grant([string]$Day) {
    $g = Read-Json $GrantFile $null
    if ($g -and $g.day -eq $Day) { return $g }
    return $null
}

# Allowed window for today as [from, until) in hours since the reset hour, so
# a window such as 18:00-02:00 on a day that resets at 05:00 works out naturally.
# Returns $null for no restriction, or @{ closed = $true } for a day with no gaming.
function Get-Window($Config) {
    $dayName = (Get-DayDate $Config).DayOfWeek.ToString()
    $from = $null; $until = $null
    $d = if ($Config.days) { $Config.days.$dayName } else { $null }
    if ($d) {
        if ($null -ne $d.enabled -and -not [bool]$d.enabled) { return @{ closed = $true; from = 0; until = 0 } }
        $from = $d.from; $until = $d.until
    } else {
        $weekend = Test-Weekend $Config
        $from  = if ($weekend) { $Config.weekendFrom }  else { $Config.weekdayFrom }
        $until = if ($weekend) { $Config.weekendUntil } else { $Config.weekdayUntil }
    }
    if ($null -eq $from -or $null -eq $until) { return $null }
    $from = [double]$from; $until = [double]$until
    if ($from -eq $until) { return $null }
    if ($from -eq 0 -and $until -eq 24) { return $null }
    $reset = [double]$Config.resetHourLocal
    $f = (($from  - $reset) % 24 + 24) % 24
    $u = (($until - $reset) % 24 + 24) % 24
    if ($u -le $f) { $u += 24 }
    return @{ from = $from; until = $until; relFrom = $f; relUntil = $u }
}

function Test-InWindow($Config, $Window) {
    if (-not $Window) { return $true }
    if ($Window.closed) { return $false }
    $now = Get-LocalNow $Config
    $rel = (($now.TimeOfDay.TotalHours - [double]$Config.resetHourLocal) % 24 + 24) % 24
    return ($rel -ge $Window.relFrom -and $rel -lt $Window.relUntil)
}

function Format-Hour([double]$H) {
    $H = $H % 24
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($H), [int](($H - [Math]::Floor($H)) * 60))
}

function Load-State([string]$Day) {
    $s = Read-Json $StateFile $null
    if ($s -and $s.day -eq $Day) {
        return @{
            day       = $Day
            seconds   = [int]$s.seconds
            tracked   = @($s.tracked | Where-Object { $_ })
            graceUsed = @($s.graceUsed | Where-Object { $_ })
            graceUntilUtc = $s.graceUntilUtc
            graceReason   = $s.graceReason
        }
    }
    return @{ day = $Day; seconds = 0; tracked = @(); graceUsed = @(); graceUntilUtc = $null; graceReason = $null }
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
}

# One entry per day, kept for 60 days, so the panel can show a history.
function Update-History($State, [int]$LimitMinutes, [int]$ExtraMinutes, [bool]$Locked) {
    $h = Read-Json $HistoryFile $null
    $days = @{}
    if ($h -and $h.days) {
        foreach ($p in $h.days.PSObject.Properties) { $days[$p.Name] = $p.Value }
    }
    $days[$State.day] = @{ minutes = [int][Math]::Round($State.seconds / 60); limit = $LimitMinutes; extra = $ExtraMinutes; locked = $Locked }
    $keep = @($days.Keys | Sort-Object -Descending | Select-Object -First 60)
    $out = [ordered]@{}
    foreach ($k in ($keep | Sort-Object)) { $out[$k] = $days[$k] }
    @{ days = $out } | ConvertTo-Json -Depth 4 | Set-Content -Path $HistoryFile -Encoding UTF8
}

function Get-GameProcesses($Config, $Tracked) {
    $all = Get-CimInstance Win32_Process -ErrorAction Stop |
        Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }

    # Roots: live launchers plus previously tracked games that are still alive
    # under the same name (guards against PID reuse).
    $rootIds = @{}
    foreach ($p in $all) { if ($LauncherNames -contains "$($p.Name)".ToLower()) { $rootIds[[int]$p.ProcessId] = $true } }
    foreach ($t in $Tracked) {
        $id = [int]$t.pid
        if ($byId.ContainsKey($id) -and "$($byId[$id].Name)".ToLower() -eq "$($t.name)".ToLower()) { $rootIds[$id] = $true }
    }

    $extra = @($Config.extraProcesses | ForEach-Object { "$_".ToLower() -replace '\.exe$', '' })

    # Pass 1: processes that are games in their own right.
    $games = @{}
    foreach ($p in $all) {
        $id   = [int]$p.ProcessId
        $name = "$($p.Name)".ToLower()
        if ($HelperNames -contains $name) { continue }
        $isGame = $false
        if ($rootIds.ContainsKey($id)) { $isGame = $true }
        if (-not $isGame -and $p.ExecutablePath) {
            $path = $p.ExecutablePath
            $inLib = $false
            foreach ($lp in $LibraryPaths) { if ($path -ilike "*$lp*") { $inLib = $true; break } }
            if ($inLib) { foreach ($ex in $LibraryExclude) { if ($path -ilike "*$ex*") { $inLib = $false; break } } }
            if ($inLib) { $isGame = $true }
        }
        if (-not $isGame -and $extra -contains ($name -replace '\.exe$', '')) { $isGame = $true }
        if ($isGame) { $games[$id] = $p }
    }

    # Pass 2: anything descended from a launcher or from a game found above. A
    # parent link only counts if the parent was created before the child,
    # otherwise the PID was reused.
    foreach ($p in $all) {
        $id   = [int]$p.ProcessId
        $name = "$($p.Name)".ToLower()
        if ($games.ContainsKey($id) -or $HelperNames -contains $name) { continue }
        $cur = $p; $hops = 0
        while ($cur -and $hops -lt 25) {
            $parId = [int]$cur.ParentProcessId
            if ($parId -eq 0 -or -not $byId.ContainsKey($parId)) { break }
            $par = $byId[$parId]
            if ($par.CreationDate -and $cur.CreationDate -and $par.CreationDate -gt $cur.CreationDate) { break }
            if ($rootIds.ContainsKey($parId) -or $games.ContainsKey($parId)) { $games[$id] = $p; break }
            $cur = $par; $hops++
        }
    }
    return @($games.Values)
}

function Stop-Quietly($Ids) {
    foreach ($id in $Ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

function Invoke-Tick([int]$ElapsedSeconds, [switch]$DryRun) {
    $config = Get-Config
    $day    = Get-DayKey $config
    $state  = Load-State $day
    $grant  = Get-Grant $day
    $extraMinutes = if ($grant) { [int]$grant.extraMinutes } else { 0 }
    $manualLock   = [bool]($grant -and $grant.lockToday)
    $baseMinutes  = if (Test-Weekend $config) { [int]$config.weekendMinutes } else { [int]$config.weekdayMinutes }
    $limitSeconds = ($baseMinutes + $extraMinutes) * 60
    $window   = Get-Window $config
    $inWindow = Test-InWindow $config $window

    $games   = @(Get-GameProcesses $config $state.tracked)
    $playing = $games.Count -gt 0

    if ($playing -and -not $DryRun) { $state.seconds += $ElapsedSeconds }

    # Why play is not allowed right now, if it is not.
    $reason = ''
    if ($manualLock)                            { $reason = 'manual' }
    elseif ($state.seconds -ge $limitSeconds)   { $reason = 'budget' }
    elseif (-not $inWindow)                     { $reason = 'window' }
    $locked = $reason -ne ''

    # Grace: the first time a reason bites while a game is running, give
    # graceSeconds to save. Each reason gets one grace per day.
    $now = [DateTime]::UtcNow
    $graceActive = $false
    if ($locked -and $playing) {
        if ($state.graceUntilUtc -and $state.graceReason -eq $reason) {
            $graceActive = ([DateTime]::Parse($state.graceUntilUtc).ToUniversalTime() -gt $now)
        }
        elseif ($state.graceUsed -notcontains $reason -and [int]$config.graceSeconds -gt 0) {
            $state.graceUntilUtc = $now.AddSeconds([int]$config.graceSeconds).ToString('o')
            $state.graceReason   = $reason
            $state.graceUsed     = @($state.graceUsed) + $reason
            $graceActive = $true
        }
    }
    if (-not $graceActive) { $state.graceUntilUtc = $null; $state.graceReason = $null }

    if ($locked -and -not $graceActive -and -not $DryRun) {
        Stop-Quietly ($games | ForEach-Object { $_.ProcessId })
        foreach ($ln in $LauncherNames) {
            Get-Process -Name ($ln -replace '\.exe$', '') -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    $state.tracked = if ($locked -and -not $graceActive) { @() } else {
        @($games | ForEach-Object { @{ pid = [int]$_.ProcessId; name = "$($_.Name)" } })
    }
    $state.limitSeconds = $limitSeconds
    $state.baseMinutes  = $baseMinutes
    $state.extraMinutes = $extraMinutes
    $state.locked       = $locked
    $state.lockReason   = $reason
    $state.playing      = $playing
    $state.inWindow     = $inWindow
    $state.windowText   = if ($window -and $window.closed) { 'no gaming today' } elseif ($window) { "$(Format-Hour $window.from)-$(Format-Hour $window.until)" } else { '' }
    $state.weekend      = Test-Weekend $config
    $state.updatedUtc   = $now.ToString('o')

    if ($DryRun) {
        Write-Host "Day key       : $day ($(if ($state.weekend) {'weekend'} else {'weekday'}), resets at $($config.resetHourLocal):00 local)"
        Write-Host "Used / limit  : $([int]($state.seconds/60)) / $([int]($limitSeconds/60)) minutes ($baseMinutes base + $extraMinutes extra)"
        Write-Host "Window        : $(if ($window) { $state.windowText + $(if ($inWindow) {' (inside)'} else {' (OUTSIDE)'}) } else { 'none' })"
        Write-Host "Locked        : $locked $(if ($reason) { "($reason)" })  grace active: $graceActive"
        Write-Host "Games running : $($games.Count)"
        foreach ($g in $games) { Write-Host ("   {0,-7} {1,-30} {2}" -f $g.ProcessId, $g.Name, $g.ExecutablePath) }
    } else {
        Save-State $state
        try { Update-History $state ($baseMinutes) $extraMinutes $locked } catch {}
    }
}

if ($Once) {
    Invoke-Tick -ElapsedSeconds 0 -DryRun
    exit 0
}

# Only one watcher per data folder (the task has several triggers).
$mutexName = 'Global\GameLockMutex'
if ($DataDir -ne 'C:\ProgramData\GameLock') { $mutexName += '-' + ($DataDir.GetHashCode().ToString('x')) }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) { exit 0 }

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

$last = [DateTime]::UtcNow
while ($true) {
    $now = [DateTime]::UtcNow
    # Real elapsed time, capped so a stalled machine never counts more than two intervals.
    $elapsed = [int][Math]::Min(($now - $last).TotalSeconds, $CheckInterval * 2)
    $last = $now
    try { Invoke-Tick -ElapsedSeconds $elapsed } catch {}
    Start-Sleep -Seconds $CheckInterval
}
