# Notifier.ps1
# Runs in the gaming account (installed by Install-Notifier.ps1). Two jobs:
#   1. A small status badge in the top-right corner: time used and time left
#      while a game runs, a dimmer "time left" when idle, a red countdown during
#      the save-your-game grace period, and the reason when locked. A second
#      line counts down to the daily reset. Ctrl+Alt+S hides and shows it.
#   2. A warning banner at each point in config.json (default 30/15/5/1 minutes
#      left), one when the grace period starts, and one when the lock kicks in.
# It only reads the files the SYSTEM watcher writes. Stopping it costs you the
# badge and the warnings, nothing else: the lock does not depend on it.
#
# -DataDir is for testing against a copy of the data folder.

param(
    [string]$DataDir = 'C:\ProgramData\GameLock'
)

$ShowBadgeWhen = 'always'    # 'always', 'playing' = only while a game runs, or 'off'
$StaleAfterSeconds = 60      # badge warns if the watcher has not written for this long

$StateFile     = Join-Path $DataDir 'state.json'
$ConfigFile    = Join-Path $DataDir 'config.json'
$OverlayScript = Join-Path $PSScriptRoot 'Show-Overlay.ps1'
$LocalDir      = Join-Path $env:LOCALAPPDATA 'GameLock'
$ShownFile     = Join-Path $LocalDir 'shown.json'

if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir | Out-Null }

# Errors go to a small log file, since this runs with no window.
$LogFile = Join-Path $LocalDir 'notifier.log'
function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date).ToString('s'), $Message)
    } catch {}
}
trap { Write-Log "FATAL: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; continue }
Write-Log 'Notifier started'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class QuietBadge : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    const int HOTKEY_ID = 0x5A11;
    public bool HiddenByUser = false;
    public QuietBadge() {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        UpdateStyles();
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            // WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000008 | 0x00000020 | 0x00000080 | 0x08000000;
            return cp;
        }
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RegisterHotKey(this.Handle, HOTKEY_ID, 0x0002 | 0x0001, (uint)'S');   // Ctrl+Alt+S
    }
    protected override void OnHandleDestroyed(EventArgs e) {
        UnregisterHotKey(this.Handle, HOTKEY_ID);
        base.OnHandleDestroyed(e);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && (int)m.WParam == HOTKEY_ID) {
            HiddenByUser = !HiddenByUser;
            if (HiddenByUser) this.Hide(); else this.Show();
            return;
        }
        base.WndProc(ref m);
    }
}
'@

function Read-Json([string]$Path) {
    try { return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Load-Shown([string]$Day) {
    $s = Read-Json $ShownFile
    if ($s -and $s.day -eq $Day) { return @{ day = $Day; shown = @($s.shown | Where-Object { $null -ne $_ }) } }
    return @{ day = $Day; shown = @() }
}

function Save-Shown($Shown) { $Shown | ConvertTo-Json | Set-Content -Path $ShownFile -Encoding UTF8 }

function Show-Warning([string]$Text, [int]$Seconds = 8) {
    Start-Process conhost.exe -WindowStyle Hidden -ArgumentList @(
        '--headless', 'powershell.exe', '-NoProfile', '-sta', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$OverlayScript`"", '-Text', "`"$Text`"", '-Seconds', $Seconds
    )
}

function Format-Clock([int]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Get-GraceLeft($State) {
    if (-not $State.graceUntilUtc) { return -1 }
    try { return [int]([DateTime]::Parse($State.graceUntilUtc).ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds } catch { return -1 }
}

function Get-StateAge($State) {
    if (-not $State -or -not $State.updatedUtc) { return 999999 }
    try { return [int]([DateTime]::UtcNow - [DateTime]::Parse($State.updatedUtc).ToUniversalTime()).TotalSeconds } catch { return 999999 }
}

function Get-LockText($State) {
    switch ("$($State.lockReason)") {
        'window' { if ($State.windowText) { return "Gaming hours: $($State.windowText)" } else { return 'Outside gaming hours' } }
        'manual' { return 'Locked by admin for today' }
        default  { return 'Games locked for today' }
    }
}

# --- corner badge -----------------------------------------------------------
$Red   = [System.Drawing.Color]::FromArgb(255, 110, 110)
$Amber = [System.Drawing.Color]::FromArgb(255, 200, 90)
$White = [System.Drawing.Color]::White

# Palette (matches the admin panel)
$Bg     = [System.Drawing.Color]::FromArgb(10, 18, 34)
$Track  = [System.Drawing.Color]::FromArgb(17, 29, 50)
$Accent = [System.Drawing.Color]::FromArgb(79, 195, 247)
$Text   = [System.Drawing.Color]::FromArgb(230, 238, 248)
$Muted  = [System.Drawing.Color]::FromArgb(143, 163, 191)
$White  = $Text
$Red    = [System.Drawing.Color]::FromArgb(242, 95, 92)
$Amber  = [System.Drawing.Color]::FromArgb(255, 200, 87)
$Green  = [System.Drawing.Color]::FromArgb(55, 214, 122)

$badge = New-Object QuietBadge
$badge.FormBorderStyle = 'None'
$badge.TopMost = $true
$badge.StartPosition = 'Manual'
$badge.ShowInTaskbar = $false
$badge.BackColor = $Bg
$badge.Opacity = 0.94
$badge.Width = 300; $badge.Height = 64

# Pill shape, glowing border, controller icon, progress line. Striped red when locked.
$script:badgeFraction = 1.0
$script:badgeEdge = $Accent
$script:badgeLocked = $false
$script:badgeDot = $null          # colour of the status dot at the right, or $null
function Get-PillPath([int]$Inset) {
    $r = 14; $w = $badge.Width - 1 - $Inset*2; $h = $badge.Height - 1 - $Inset*2; $x = $Inset; $y = $Inset
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $y, $r*2, $r*2, 180, 90); $path.AddArc($x+$w-$r*2, $y, $r*2, $r*2, 270, 90)
    $path.AddArc($x+$w-$r*2, $y+$h-$r*2, $r*2, $r*2, 0, 90); $path.AddArc($x, $y+$h-$r*2, $r*2, $r*2, 90, 90)
    $path.CloseFigure(); return $path
}
function Set-BadgeRegion { $badge.Region = New-Object System.Drawing.Region((Get-PillPath 0)) }
$badge.Add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'
    $edge = $script:badgeEdge
    # soft glow: three widening translucent strokes inside the pill
    foreach ($i in 3,2,1) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb((18 * $i), $edge), (1 + $i*2))
        $g.DrawPath($pen, (Get-PillPath 1))
    }
    $g.DrawPath((New-Object System.Drawing.Pen($edge, 1.6)), (Get-PillPath 1))
    # icon disc with controller glyph
    $disc = New-Object System.Drawing.Rectangle(10, 12, 40, 40)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, $edge))), $disc)
    $g.DrawEllipse((New-Object System.Drawing.Pen($edge, 1.5)), $disc)
    $font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 16)
    $gflags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    [System.Windows.Forms.TextRenderer]::DrawText($g, [string][char]0xE7FC, $font, $disc, $Text, $gflags)
    # progress line
    $x0 = 62; $x1 = $badge.Width - 20; $yb = $badge.Height - 13
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($Track)), $x0, $yb, ($x1 - $x0), 5)
    $pw = [int](($x1 - $x0) * [Math]::Min(1.0, [Math]::Max(0.0, $script:badgeFraction)))
    if ($pw -gt 0) {
        $rect = New-Object System.Drawing.Rectangle($x0, $yb, $pw, 5)
        if ($script:badgeLocked) {
            $hb = New-Object System.Drawing.Drawing2D.HatchBrush('WideUpwardDiagonal', $Red, [System.Drawing.Color]::FromArgb(120, 40, 40))
            $g.FillRectangle($hb, $rect)
        } else {
            $g.FillRectangle((New-Object System.Drawing.SolidBrush($edge)), $rect)
        }
    }
    # status dot
    if ($script:badgeDot) {
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, $script:badgeDot))), ($badge.Width - 30), 15, 16, 16)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($script:badgeDot)), ($badge.Width - 27), 18, 10, 10)
    }
    # text (drawn here rather than with Label controls, so there is nothing to flicker)
    $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    [System.Windows.Forms.TextRenderer]::DrawText($g, $script:badgeText, $FontMain, (New-Object System.Drawing.Rectangle(60, 8, 200, 24)), $script:badgeTextColor, $flags)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $script:badgeSub, $FontSub, (New-Object System.Drawing.Rectangle(60, 30, 220, 18)), $Muted, $flags)
})

$script:badgeText = ''; $script:badgeSub = ''; $script:badgeTextColor = $Text
$FontMain = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$FontSub  = New-Object System.Drawing.Font('Segoe UI', 8.5)
Set-BadgeRegion

# Time until the next daily reset, in the zone recorded with the reset hour.
function Get-ResetText($Config) {
    if (-not $Config -or $null -eq $Config.resetHourLocal) { return '' }
    $now = $null
    if ($Config.timeZoneId) {
        try { $now = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById([string]$Config.timeZoneId)) } catch {}
    }
    if ($null -eq $now) { $now = [DateTime]::UtcNow.AddHours([double]$Config.resetHourLocal - [double]$Config.resetHourUtc) }
    $next = $now.Date.AddHours([double]$Config.resetHourLocal)
    if ($next -le $now) { $next = $next.AddDays(1) }
    $span = $next - $now
    return ('Resets in {0}:{1:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
}

function Move-BadgeToCorner {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $wa.Right - $badge.Width - 12; $y = $wa.Top + 12
    if ($badge.Left -ne $x -or $badge.Top -ne $y) { $badge.Location = New-Object System.Drawing.Point($x, $y) }
}

$script:badgeSig = ''
function Set-Badge([string]$Text, $Color, [double]$Opacity, [string]$Sub, [double]$Fraction = -1) {
    $edge = if ($Color -eq $Text) { $Accent } else { $Color }
    $frac = if ($Fraction -ge 0) { [Math]::Round($Fraction, 3) } else { $script:badgeFraction }
    $dotName = if ($script:badgeDot) { $script:badgeDot.ToArgb() } else { 0 }
    $sig = "$Text|$Sub|$($Color.ToArgb())|$Opacity|$frac|$dotName"
    if ($sig -ne $script:badgeSig) {
        $script:badgeSig = $sig
        $script:badgeText = $Text; $script:badgeSub = $Sub; $script:badgeTextColor = $Color
        $script:badgeEdge = $edge
        $script:badgeLocked = ($Color -eq $Red)
        $script:badgeFraction = $frac
        if ($badge.Opacity -ne $Opacity) { $badge.Opacity = $Opacity }
        $badge.Invalidate()
    }
    Move-BadgeToCorner
    if (-not $badge.Visible -and -not $badge.HiddenByUser) { $badge.Show() }
}

function Update-Badge($State, $Config) {
    if ($ShowBadgeWhen -eq 'off' -or $badge.HiddenByUser) { if ($badge.Visible) { $badge.Hide() }; return }

    if ((Get-StateAge $State) -gt $StaleAfterSeconds) {
        Set-Badge 'Limiter not running!' $Red 0.95 'Watcher has stopped writing state' 1
        return
    }

    $wanted = ($ShowBadgeWhen -eq 'always') -or [bool]$State.playing -or [bool]$State.locked
    if (-not $wanted) { if ($badge.Visible) { $badge.Hide() }; return }

    $sub = Get-ResetText $Config
    $script:badgeDot = if ($State.playing -and -not $State.locked) { $Green } elseif ($State.locked) { $Red } else { $null }
    $graceLeft = Get-GraceLeft $State
    if ($State.locked -and $graceLeft -ge 0) {
        Set-Badge "SAVE NOW - closing in $graceLeft s" $Red 0.97 (Get-LockText $State) ($graceLeft / [Math]::Max(1, [int]$Config.graceSeconds))
        return
    }
    if ($State.locked) {
        Set-Badge (Get-LockText $State) $Red 0.94 $sub 1
        return
    }

    $used = [int]$State.seconds
    $left = [int]$State.limitSeconds - $used
    $color = if ($left -le 300) { $Red } elseif ($left -le 900) { $Amber } else { $White }
    $frac = if ([int]$State.limitSeconds -gt 0) { $left / [int]$State.limitSeconds } else { 0 }
    if ($State.playing) {
        Set-Badge "$(Format-Clock $left) left" $color 0.92 "$(Format-Clock $used) played   |   $sub" $frac
    } else {
        $hint = if ($State.windowText) { "$sub   |   hours $($State.windowText)" } else { $sub }
        Set-Badge "$(Format-Clock $left) left today" $color 0.85 $hint $frac
    }
}

# --- warning banners ---------------------------------------------------------
function Update-Warnings($Config, $State) {
    if (-not $Config -or -not $State -or -not $State.day) { return }
    $shown = Load-Shown $State.day

    if ($State.locked) {
        $graceLeft = Get-GraceLeft $State
        if ($graceLeft -ge 0) {
            $key = "grace-$($State.lockReason)"
            if ($shown.shown -notcontains $key) {
                Show-Warning "Time's up - save your game, closing in $graceLeft seconds" 10
                $shown.shown += $key
                Save-Shown $shown
            }
            return
        }
        $key = "lock-$($State.lockReason)"
        if ($shown.shown -notcontains $key) {
            $text = switch ("$($State.lockReason)") {
                'window' { "Outside gaming hours ($($State.windowText)) - games are closed" }
                'manual' { 'Locked by admin - games are closed for today' }
                default  { "Time's up - games are closed for today" }
            }
            Show-Warning $text
            $shown.shown += $key
            Save-Shown $shown
        }
        return
    }

    # Unlocked again (extra time granted, window opened): let lock banners fire again later.
    $locks = @($shown.shown | Where-Object { "$_" -like 'lock-*' -or "$_" -like 'grace-*' })
    if ($locks.Count -gt 0) { $shown.shown = @($shown.shown | Where-Object { $locks -notcontains $_ }); Save-Shown $shown }

    $remaining = [int]$State.limitSeconds - [int]$State.seconds
    foreach ($m in ($Config.warnings | Sort-Object -Descending)) {
        $m = [int]$m
        if ($remaining -le ($m * 60) -and $remaining -gt 0 -and ($shown.shown -notcontains $m)) {
            $unit = if ($m -eq 1) { 'minute' } else { 'minutes' }
            Show-Warning "$m $unit of game time left today"
            $shown.shown += $m
            Save-Shown $shown
        }
    }
}

# --- main loop (WinForms timer so the badge has a message pump) ---------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    try {
        $config = Read-Json $ConfigFile
        $state  = Read-Json $StateFile
        Update-Badge $state $config
        Update-Warnings $config $state
    } catch { Write-Log "tick: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
})
$timer.Start()
# Create the window handle now so the hotkey registers even before the first Show().
[void]$badge.Handle
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
