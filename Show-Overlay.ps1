# Show-Overlay.ps1
# Shows a topmost banner for a few seconds without stealing focus from the game
# (no activation, click-through), then exits. Launched by Notifier.ps1 with -sta.

param(
    [string]$Text = '',
    [int]$Seconds = 8
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# A form that never takes focus and lets clicks pass through.
Add-Type -ReferencedAssemblies System.Windows.Forms -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Windows.Forms;
public class QuietForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            // WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000008 | 0x00000020 | 0x00000080 | 0x08000000;
            return cp;
        }
    }
}
'@

$form = New-Object QuietForm
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.Opacity = 0.94
$form.ShowInTaskbar = $false

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Width  = 560
$form.Height = 120
$form.Left   = [int](($screen.Width - $form.Width) / 2)
$form.Top    = 40

$label = New-Object System.Windows.Forms.Label
$label.Text = $Text
$label.ForeColor = [System.Drawing.Color]::White
$label.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$label.TextAlign = 'MiddleCenter'
$label.Dock = 'Fill'
$form.Controls.Add($label)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $Seconds * 1000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
