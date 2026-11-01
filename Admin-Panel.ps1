# Admin-Panel.ps1
# Password-protected control panel for GameLock (WPF). Opened from the
# desktop shortcut the installer creates. Asks for one UAC "Yes" (the data
# folder is admin-only), then for the admin password chosen at install time.
#
# Dashboard: today's time, add/remove extra time, lock today, settings, the
# last 14 days as a chart, and the activity log. Settings / Activity / About
# pages show the same things with more room.
#
# -DataDir is for testing against a copy of the data folder; it skips elevation.

param(
    [string]$DataDir = '',
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'

if (-not $DataDir) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    if (-not $isAdmin) {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
    $DataDir = 'C:\ProgramData\GameLock'
}

$ConfigFile  = Join-Path $DataDir 'config.json'
$GrantFile   = Join-Path $DataDir 'grants.json'
$StateFile   = Join-Path $DataDir 'state.json'
$SecretFile  = Join-Path $DataDir 'secret.json'
$HistoryFile = Join-Path $DataDir 'history.json'
$GrantLog    = Join-Path $DataDir 'grants-log.json'
$HeaderArt   = Join-Path $PSScriptRoot 'header.png'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# --- data helpers -------------------------------------------------------------
function Read-Json([string]$Path) {
    try { return (Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}
function Write-Json([string]$Path, $Object) { $Object | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8 }
function Get-PasswordHash([string]$Plain, [byte[]]$Salt) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Plain, $Salt, 100000)
    try { return [Convert]::ToBase64String($kdf.GetBytes(32)) } finally { $kdf.Dispose() }
}
function New-SecretRecord([string]$Plain) {
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    return [ordered]@{ salt = [Convert]::ToBase64String($salt); hash = (Get-PasswordHash $Plain $salt); iterations = 100000 }
}
function Test-Password([string]$Plain) {
    $s = Read-Json $SecretFile
    if (-not $s) { return $false }
    return ((Get-PasswordHash $Plain ([Convert]::FromBase64String($s.salt))) -eq $s.hash)
}
function Get-LocalNow($Config) {
    if ($Config.timeZoneId) {
        try { return [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, [TimeZoneInfo]::FindSystemTimeZoneById([string]$Config.timeZoneId)) } catch {}
    }
    return [DateTime]::UtcNow.AddHours([double]$Config.resetHourLocal - [double]$Config.resetHourUtc)
}
function Get-DayKey($Config) {
    return (Get-LocalNow $Config).AddHours(-[double]$Config.resetHourLocal).ToString('yyyy-MM-dd')
}
function Add-GrantLog([string]$Action, [int]$Minutes) {
    $log = Read-Json $GrantLog
    $entries = @(); if ($log -and $log.entries) { $entries = @($log.entries) }
    $entries += [ordered]@{ at = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm'); action = $Action; minutes = $Minutes }
    if ($entries.Count -gt 200) { $entries = $entries[-200..-1] }
    Write-Json $GrantLog @{ entries = $entries }
}
function Format-Hour([double]$H) { return ('{0:00}:00' -f ([int]$H % 24)) }

# --- XAML ---------------------------------------------------------------------
# A numeric spinner: text box with up/down buttons. $Name gets Up/Down suffixes.
function Spin([string]$Name, [int]$Width = 90, [string]$Font = '15') {
@"
<Border Width="$Width" Height="36" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" VerticalAlignment="Center">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="26"/></Grid.ColumnDefinitions>
    <TextBox x:Name="$Name" Grid.Column="0" FontSize="$Font" FontWeight="SemiBold" Foreground="{StaticResource Text}" Background="Transparent" BorderThickness="0" VerticalContentAlignment="Center" Padding="8,0,0,0" CaretBrush="{StaticResource Accent}"/>
    <StackPanel Grid.Column="1">
      <RepeatButton x:Name="${Name}Up" Style="{StaticResource SpinBtn}" Content="&#xE70E;"/>
      <RepeatButton x:Name="${Name}Down" Style="{StaticResource SpinBtn}" Content="&#xE70D;"/>
    </StackPanel>
  </Grid>
</Border>
"@
}

function CardHeader([string]$Glyph, [string]$Title, [string]$RightName = '') {
    $right = if ($RightName) { "<TextBlock x:Name=`"$RightName`" Grid.Column=`"2`" Style=`"{StaticResource Muted}`" FontSize=`"13`" VerticalAlignment=`"Center`"/>" } else { '' }
@"
<Grid Margin="0,0,0,14">
  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Border Width="30" Height="30" CornerRadius="6" Background="#1A2C47" Margin="0,0,10,0"><TextBlock Text="$Glyph" Style="{StaticResource Glyph}" FontSize="16"/></Border>
  <TextBlock Grid.Column="1" Text="$Title" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
  $right
</Grid>
"@
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GameLock" Width="1360" Height="980" MinWidth="1200" MinHeight="860"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResizeWithGrip"
        Background="#0A1222" FontFamily="Segoe UI" Topmost="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#0A1222"/>
    <SolidColorBrush x:Key="Card" Color="#111D32"/>
    <SolidColorBrush x:Key="Card2" Color="#15243C"/>
    <SolidColorBrush x:Key="Field" Color="#0D1A2E"/>
    <SolidColorBrush x:Key="Line" Color="#24395A"/>
    <SolidColorBrush x:Key="Accent" Color="#4FC3F7"/>
    <SolidColorBrush x:Key="AccentDeep" Color="#1E88E5"/>
    <SolidColorBrush x:Key="Text" Color="#E6EEF8"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#8FA3BF"/>
    <SolidColorBrush x:Key="Green" Color="#37D67A"/>
    <SolidColorBrush x:Key="Red" Color="#F25F5C"/>
    <SolidColorBrush x:Key="Amber" Color="#FFC857"/>
    <DropShadowEffect x:Key="GlowBlue" Color="#4FC3F7" BlurRadius="18" ShadowDepth="0" Opacity="0.55"/>
    <DropShadowEffect x:Key="GlowRed" Color="#F25F5C" BlurRadius="18" ShadowDepth="0" Opacity="0.55"/>
    <DropShadowEffect x:Key="GlowGreen" Color="#37D67A" BlurRadius="14" ShadowDepth="0" Opacity="0.5"/>
    <LinearGradientBrush x:Key="BarBlue" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#7FDBFF" Offset="0"/><GradientStop Color="#1E88E5" Offset="1"/></LinearGradientBrush>
    <DrawingBrush x:Key="BarRedStripes" TileMode="Tile" Viewport="0,0,14,14" ViewportUnits="Absolute" Viewbox="0,0,14,14" ViewboxUnits="Absolute">
      <DrawingBrush.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="#C2383B"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,14,14"/></GeometryDrawing.Geometry></GeometryDrawing>
          <GeometryDrawing Brush="#F25F5C"><GeometryDrawing.Geometry><PathGeometry Figures="M0,14 L14,0 L14,6 L6,14 Z M0,0 L0,6 L6,0 Z"/></GeometryDrawing.Geometry></GeometryDrawing>
        </DrawingGroup>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20,16,20,18"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Card2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource AccentDeep}"/>
      <Setter Property="BorderBrush" Value="#4FC3F7"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Effect" Value="{StaticResource GlowBlue}"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#D7373F"/>
      <Setter Property="BorderBrush" Value="#F25F5C"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Effect" Value="{StaticResource GlowRed}"/>
    </Style>
    <Style x:Key="SpinBtn" TargetType="RepeatButton">
      <Setter Property="Height" Value="17"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border x:Name="b" Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A2C47"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Height" Value="56"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="10" Background="Transparent" BorderThickness="1" BorderBrush="Transparent" Padding="18,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="g" Text="{TemplateBinding Tag}" Style="{StaticResource Glyph}" FontSize="18" Foreground="{StaticResource MutedBrush}" Margin="0,0,14,0"/>
                <TextBlock x:Name="t" Text="{TemplateBinding Content}" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource AccentDeep}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="Effect" Value="{StaticResource GlowBlue}"/>
                <Setter TargetName="g" Property="Foreground" Value="White"/>
                <Setter TargetName="t" Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Foreground" Value="{StaticResource Text}"/><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Line}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="HourBox" TargetType="ComboBox">
      <Setter Property="Width" Value="118"/><Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="tb" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Focusable="False" ClickMode="Press">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="26"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="1" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger></ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,30,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" StaysOpen="False">
                <Border Background="{StaticResource Card2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="260" Margin="0,2,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border x:Name="b" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource AccentDeep}"/></Trigger>
                    <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DayCheck" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="b" Width="26" Height="26" CornerRadius="6" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1">
              <TextBlock x:Name="g" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource AccentDeep}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="g" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/><Setter Property="Height" Value="34"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Margin="2"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A2C47"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WinBtnClose" TargetType="Button" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Margin="2"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#D7373F"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="{StaticResource Line}" BorderThickness="1">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="104"/><RowDefinition/><RowDefinition Height="64"/></Grid.RowDefinitions>

    <!-- Header -->
    <Grid x:Name="Header" Grid.Row="0" Background="#0E1A2F">
      <Image x:Name="HeaderArt" Stretch="UniformToFill" HorizontalAlignment="Right" Opacity="0.9" Margin="0,0,120,0"/>
      <Rectangle><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0E1A2F" Offset="0"/><GradientStop Color="#0E1A2F" Offset="0.4"/><GradientStop Color="#000E1A2F" Offset="0.7"/></LinearGradientBrush></Rectangle.Fill></Rectangle>
      <Rectangle Height="2" VerticalAlignment="Bottom" Fill="{StaticResource Accent}" Opacity="0.7"/>
      <StackPanel Orientation="Horizontal" Margin="28,0,0,0" VerticalAlignment="Center">
        <Border Width="56" Height="56" CornerRadius="12" Background="{StaticResource AccentDeep}" BorderBrush="{StaticResource Accent}" BorderThickness="1" Margin="0,0,16,0" Effect="{StaticResource GlowBlue}">
          <TextBlock Text="&#xE7FC;" Style="{StaticResource Glyph}" FontSize="26" Foreground="White"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock FontSize="30" FontWeight="Bold"><Run Text="GAME" Foreground="White"/><Run Text="LOCK" Foreground="{StaticResource Accent}"/></TextBlock>
          <TextBlock Text="Admin console" Style="{StaticResource Muted}" FontSize="15" Margin="2,-4,0,0"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,4,6,0">
        <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Content="&#xE921;"/>
        <Button x:Name="BtnCloseX" Style="{StaticResource WinBtnClose}" Content="&#xE8BB;"/>
      </StackPanel>
      <TextBlock Text="v2" Style="{StaticResource Muted}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,18,10"/>
    </Grid>

    <!-- Body -->
    <Grid Grid.Row="1" Margin="16,16,16,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition/></Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource CardStyle}" Padding="10" Margin="0,0,16,0" VerticalAlignment="Stretch">
        <StackPanel>
          <RadioButton x:Name="NavDash" Style="{StaticResource Nav}" Content="Dashboard" Tag="&#xE80F;" IsChecked="True"/>
          <RadioButton x:Name="NavSettings" Style="{StaticResource Nav}" Content="Settings" Tag="&#xE713;"/>
          <RadioButton x:Name="NavActivity" Style="{StaticResource Nav}" Content="Activity" Tag="&#xE81C;"/>
          <RadioButton x:Name="NavAbout" Style="{StaticResource Nav}" Content="About" Tag="&#xE946;"/>
        </StackPanel>
      </Border>

      <Grid Grid.Column="1">
        <!-- Dashboard -->
        <Grid x:Name="PageDash">
          <Grid.ColumnDefinitions><ColumnDefinition Width="1.25*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Margin="0,0,16,0">
          <StackPanel>
            <!-- Today -->
            <Border Style="{StaticResource CardStyle}">
              <StackPanel>
                $(CardHeader '&#xE787;' 'Today' 'TodayDate')
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Margin="0,-6,0,0"><Run x:Name="BigNum" Text="0" FontSize="66" FontWeight="Bold" Foreground="{StaticResource Accent}"/><Run Text=" " FontSize="40"/><Run x:Name="BigUnit" Text="min left" FontSize="36" FontWeight="Bold" Foreground="White"/></TextBlock>
                    <TextBlock x:Name="UsedLine" Style="{StaticResource Muted}" FontSize="15" Margin="2,-2,0,0"/>
                  </StackPanel>
                  <Border x:Name="StatusPill" Grid.Column="1" CornerRadius="10" Padding="18,10" Background="#163A2A" BorderBrush="{StaticResource Green}" BorderThickness="1" VerticalAlignment="Top" Margin="12,6,0,0" Effect="{StaticResource GlowGreen}">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="StatusGlyph" Text="&#xE768;" Style="{StaticResource Glyph}" FontSize="18" Foreground="{StaticResource Green}" Margin="0,0,12,0"/>
                      <StackPanel>
                        <TextBlock x:Name="StatusTag" Text="OPEN" FontSize="16" FontWeight="Bold" Foreground="{StaticResource Green}"/>
                        <TextBlock x:Name="StatusSub" Text="" Style="{StaticResource Muted}" FontSize="12"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                </Grid>
                <Grid Margin="0,14,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border x:Name="BarOuter" Height="18" CornerRadius="9" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                    <Grid x:Name="BarTrack" Margin="2"><Border x:Name="BarFill" HorizontalAlignment="Left" CornerRadius="7" Width="0" Background="{StaticResource BarBlue}" Effect="{StaticResource GlowBlue}"/></Grid>
                  </Border>
                  <TextBlock x:Name="BarPct" Grid.Column="1" Text="0%" Foreground="{StaticResource Text}" FontSize="14" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <TextBlock x:Name="ResetGlyph" Text="&#xE823;" Style="{StaticResource Glyph}" FontSize="14" Foreground="{StaticResource MutedBrush}" Margin="0,0,8,0"/>
                  <TextBlock x:Name="ResetLine" Style="{StaticResource Muted}" FontSize="14"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <!-- Add time -->
            <Border Style="{StaticResource CardStyle}">
              <StackPanel>
                $(CardHeader '&#xE823;' 'Add Time (Today Only)')
                <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
                  $(Spin 'Extra' 150 '26')
                  <TextBlock Text="minutes" Style="{StaticResource Label}" FontSize="15" Margin="14,0,0,0"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="BtnAdd" Style="{StaticResource BtnPrimary}" Margin="0,0,12,0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE710;" Style="{StaticResource Glyph}" Foreground="White" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Add Time"/></StackPanel></Button>
                  <Button x:Name="BtnRemove" Style="{StaticResource Btn}" Margin="0,0,12,0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE738;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Remove Extra"/></StackPanel></Button>
                  <Button x:Name="BtnLock" Style="{StaticResource BtnDanger}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72E;" Style="{StaticResource Glyph}" Foreground="White" FontSize="14" Margin="0,0,10,0"/><TextBlock x:Name="BtnLockText" Text="Lock Today"/></StackPanel></Button>
                </StackPanel>
                <TextBlock Text="Extra time applies within seconds and is gone at the next reset." Style="{StaticResource Muted}" Margin="0,12,0,0"/>
              </StackPanel>
            </Border>

          </StackPanel>
          </ScrollViewer>

          <StackPanel Grid.Column="1">
            <!-- Chart -->
            <Border Style="{StaticResource CardStyle}">
              <StackPanel>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border Width="30" Height="30" CornerRadius="6" Background="#1A2C47" Margin="0,0,10,0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,7"><Rectangle Width="4" Height="8" Fill="{StaticResource Accent}" Margin="1,0"/><Rectangle Width="4" Height="14" Fill="{StaticResource Accent}" Margin="1,0"/><Rectangle Width="4" Height="11" Fill="{StaticResource Accent}" Margin="1,0"/></StackPanel>
                  </Border>
                  <TextBlock Grid.Column="1" Text="Playtime - Last 14 Days" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="ChartTotal" Grid.Column="2" Style="{StaticResource Muted}" FontSize="13" VerticalAlignment="Center"/>
                </Grid>
                <Canvas x:Name="Chart" Height="250" ClipToBounds="True"/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Ellipse Width="12" Height="12" Fill="{StaticResource Accent}" Margin="0,0,8,0" Effect="{StaticResource GlowBlue}"/><TextBlock Text="Playtime (minutes)" Style="{StaticResource Muted}" Margin="0,0,24,0"/>
                  <Ellipse Width="12" Height="12" Fill="{StaticResource Red}" Margin="0,0,8,0" Effect="{StaticResource GlowRed}"/><TextBlock Text="Limit reached / Locked" Style="{StaticResource Muted}" Margin="0,0,24,0"/>
                  <Rectangle Width="26" Height="2" Fill="{StaticResource MutedBrush}" StrokeDashArray="2,2" Stroke="{StaticResource MutedBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="LegendLimit" Text="Daily limit" Style="{StaticResource Muted}"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <!-- Activity -->
            <Border Style="{StaticResource CardStyle}" MinHeight="300">
              <DockPanel>
                <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border Width="30" Height="30" CornerRadius="6" Background="#1A2C47" Margin="0,0,10,0"><TextBlock Text="&#xE7C3;" Style="{StaticResource Glyph}" FontSize="16"/></Border>
                  <TextBlock Grid.Column="1" Text="Recent Activity" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                  <Button x:Name="BtnClearLog" Grid.Column="2" Style="{StaticResource Btn}" Height="34" FontSize="13"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" Style="{StaticResource Glyph}" FontSize="13" Margin="0,0,8,0"/><TextBlock Text="Clear Log"/></StackPanel></Button>
                </Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="300"><StackPanel x:Name="ActivityList"/></ScrollViewer>
              </DockPanel>
            </Border>
          </StackPanel>
        </Grid>

        <!-- Settings page -->
        <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <Border Style="{StaticResource CardStyle}">
            <StackPanel>
              <Grid Margin="0,0,0,14">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Border Width="30" Height="30" CornerRadius="6" Background="#1A2C47" Margin="0,0,10,0"><TextBlock Text="&#xE713;" Style="{StaticResource Glyph}" FontSize="16"/></Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                  <TextBlock Text="Settings" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                  <TextBlock Text="Configure daily limits, schedules, and other options." Style="{StaticResource Muted}"/>
                </StackPanel>
                <Button x:Name="BtnSave" Grid.Column="2" Style="{StaticResource BtnPrimary}" Height="40"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74E;" Style="{StaticResource Glyph}" Foreground="White" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Save Settings"/></StackPanel></Button>
              </Grid>
              <Border Background="{StaticResource Field}" CornerRadius="10" Padding="18,14" Margin="0,0,0,14">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel Margin="0,0,24,0">
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6"><TextBlock Text="&#xE823;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Daily limits" Style="{StaticResource Label}" FontWeight="SemiBold" FontSize="15"/></StackPanel>
                    <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap">Base daily playtime limits in minutes. Separate settings can be set for weekdays and weekends.</TextBlock>
                  </StackPanel>
                  <Grid Grid.Column="1" VerticalAlignment="Center">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="44"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Weekday limit (minutes)" Style="{StaticResource Label}" Margin="0,0,14,0"/>
                    <ContentControl Grid.Row="0" Grid.Column="1">$(Spin 'Weekday' 100)</ContentControl>
                    <TextBlock Grid.Row="1" Text="Weekend limit (minutes)" Style="{StaticResource Label}" Margin="0,0,14,0"/>
                    <ContentControl Grid.Row="1" Grid.Column="1">$(Spin 'Weekend' 100)</ContentControl>
                  </Grid>
                </Grid>
              </Border>
              <Border Background="{StaticResource Field}" CornerRadius="10" Padding="18,14" Margin="0,0,0,14">
                <StackPanel>
                  <Grid Margin="0,0,0,10">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,0,0,6"><TextBlock Text="&#xE787;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Gaming hours (per day)" Style="{StaticResource Label}" FontWeight="SemiBold" FontSize="15"/></StackPanel>
                      <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap">Set the allowed time window for each day. Time outside this window will be locked.</TextBlock>
                    </StackPanel>
                    <Button x:Name="BtnCopyWeek" Grid.Column="1" Style="{StaticResource Btn}" Height="38" FontSize="14" Margin="12,0,0,0" VerticalAlignment="Top"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Copy Weekday to All"/></StackPanel></Button>
                    <Button x:Name="BtnResetHours" Grid.Column="2" Style="{StaticResource Btn}" Height="38" FontSize="14" Margin="12,0,0,0" VerticalAlignment="Top"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE777;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Reset to Default"/></StackPanel></Button>
                  </Grid>
                  <Grid Height="20">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Canvas x:Name="BarHeader" Grid.Column="6" Height="20" Margin="12,0,8,0"/>
                    <ComboBox Grid.Column="2" Style="{StaticResource HourBox}" Visibility="Hidden"/><ComboBox Grid.Column="4" Style="{StaticResource HourBox}" Visibility="Hidden"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkMonday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Monday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromMonday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToMonday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurMonday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarMonday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkTuesday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Tuesday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromTuesday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToTuesday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurTuesday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarTuesday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkWednesday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Wednesday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromWednesday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToWednesday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurWednesday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarWednesday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkThursday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Thursday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromThursday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToThursday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurThursday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarThursday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkFriday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Friday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromFriday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToFriday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurFriday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarFriday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkSaturday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Saturday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromSaturday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToSaturday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurSaturday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarSaturday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                  <Grid Height="44">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="40"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="30"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <CheckBox x:Name="ChkSunday" Style="{StaticResource DayCheck}" VerticalAlignment="Center"/>
                    <TextBlock Grid.Column="1" Text="Sunday" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="FromSunday" Grid.Column="2" Style="{StaticResource HourBox}"/>
                    <TextBlock Grid.Column="3" Text="to" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ToSunday" Grid.Column="4" Style="{StaticResource HourBox}"/>
                    <TextBlock x:Name="DurSunday" Grid.Column="5" Style="{StaticResource Muted}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Canvas x:Name="BarSunday" Grid.Column="6" Height="22" VerticalAlignment="Center" Margin="12,0,8,0" Background="Transparent" Cursor="Hand"/>
                  </Grid>
                </StackPanel>
              </Border>
              <Border Background="{StaticResource Field}" CornerRadius="10" Padding="18,14" Margin="0,0,0,14">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel Margin="0,0,24,0">
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6"><TextBlock Text="&#xE72E;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Reset hour and grace period" Style="{StaticResource Label}" FontWeight="SemiBold" FontSize="15"/></StackPanel>
                    <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap">The day rolls over at the reset hour, so a late session does not get a fresh allowance at midnight.</TextBlock>
                  </StackPanel>
                  <Grid Grid.Column="1" VerticalAlignment="Center">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="44"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Day resets at (hour)" Style="{StaticResource Label}" Margin="0,0,14,0"/>
                    <ContentControl Grid.Row="0" Grid.Column="1">$(Spin 'Reset' 100)</ContentControl>
                    <TextBlock Grid.Row="1" Text="Grace period (seconds)" Style="{StaticResource Label}" Margin="0,0,14,0"/>
                    <ContentControl Grid.Row="1" Grid.Column="1">$(Spin 'Grace' 100)</ContentControl>
                  </Grid>
                </Grid>
              </Border>
              <Border Background="{StaticResource Field}" CornerRadius="10" Padding="18,14">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel Margin="0,0,24,0">
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,6"><TextBlock Text="&#xE8D7;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,8,0"/><TextBlock Text="Admin password" Style="{StaticResource Label}" FontWeight="SemiBold" FontSize="15"/></StackPanel>
                    <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap">The password that opens this panel. Keep it from the person being limited.</TextBlock>
                  </StackPanel>
                  <Grid Grid.Column="1" VerticalAlignment="Center">
                  </Grid>
                  <Button x:Name="BtnPass2" Grid.Column="1" Style="{StaticResource Btn}" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72E;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Change Password"/></StackPanel></Button>
                  <Grid Visibility="Collapsed">
                  </Grid>
                </Grid>
              </Border>
            </StackPanel>
          </Border>
        </StackPanel>
        </ScrollViewer>

        <!-- Activity page -->
        <Border x:Name="PageActivity" Style="{StaticResource CardStyle}" Visibility="Collapsed">
          <DockPanel>
            <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border Width="30" Height="30" CornerRadius="6" Background="#1A2C47" Margin="0,0,10,0"><TextBlock Text="&#xE81C;" Style="{StaticResource Glyph}" FontSize="16"/></Border>
              <TextBlock Grid.Column="1" Text="Activity" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
              <Button x:Name="BtnClearLog2" Grid.Column="2" Style="{StaticResource Btn}" Height="34" FontSize="13" Content="Clear Log"/>
            </Grid>
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="ActivityListFull"/></ScrollViewer>
          </DockPanel>
        </Border>

        <!-- About page -->
        <Border x:Name="PageAbout" Style="{StaticResource CardStyle}" Visibility="Collapsed" VerticalAlignment="Top">
          <StackPanel>
            $(CardHeader '&#xE946;' 'About')
            <TextBlock Style="{StaticResource Label}" FontSize="16" FontWeight="SemiBold">GameLock v2</TextBlock>
            <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,8,0,14">A daily playtime cap for Steam, Epic, Battle.net and GOG games. The watcher runs as SYSTEM and counts time only while a game is running. This panel is the only place allowances change, and it opens only with the admin password.</TextBlock>
            <TextBlock x:Name="AboutData" Style="{StaticResource Muted}" TextWrapping="Wrap"/>
            <TextBlock Style="{StaticResource Muted}" Margin="0,14,0,0">Badge hotkey: Ctrl+Alt+S hides and shows the on-screen badge.</TextBlock>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>

    <!-- Footer -->
    <Grid Grid.Row="2" Margin="16,0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="BtnPass" Style="{StaticResource Btn}" Height="40"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72E;" Style="{StaticResource Glyph}" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Change Password"/></StackPanel></Button>
        <TextBlock Text="Ctrl+Alt+S hides the on-screen badge" Style="{StaticResource Muted}" FontSize="14" VerticalAlignment="Center" Margin="20,0,0,0"/>
      </StackPanel>
      <Button x:Name="BtnClose" Style="{StaticResource Btn}" Height="40" HorizontalAlignment="Right" VerticalAlignment="Center" BorderBrush="{StaticResource Red}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE711;" Style="{StaticResource Glyph}" Foreground="{StaticResource Red}" FontSize="14" Margin="0,0,10,0"/><TextBlock Text="Close"/></StackPanel></Button>
    </Grid>
  </Grid>
  </Border>
</Window>
"@

# --- password dialog (WPF) ------------------------------------------------------
function Read-PasswordDialog([string]$Title, [string]$Prompt) {
    $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="420" Height="230" WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="NoResize"
        Background="#0A1222" FontFamily="Segoe UI" Topmost="True">
  <Border BorderBrush="#24395A" BorderThickness="1" Padding="24">
    <StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
        <Border Width="36" Height="36" CornerRadius="8" Background="#1E88E5" Margin="0,0,12,0"><TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <TextBlock FontSize="20" FontWeight="Bold" VerticalAlignment="Center"><Run Text="GAME" Foreground="White"/><Run Text="LOCK" Foreground="#4FC3F7"/></TextBlock>
      </StackPanel>
      <TextBlock Text="$Prompt" Foreground="#8FA3BF" FontSize="14" Margin="0,0,0,8"/>
      <Border Background="#0D1A2E" BorderBrush="#24395A" BorderThickness="1" CornerRadius="6">
        <PasswordBox x:Name="Pw" FontSize="16" Foreground="#E6EEF8" Background="Transparent" BorderThickness="0" Padding="10,8" CaretBrush="#4FC3F7"/>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="Ok" Content="Unlock" Width="100" Height="36" FontSize="14" FontWeight="SemiBold" Foreground="White" Background="#1E88E5" BorderBrush="#4FC3F7" IsDefault="True" Margin="0,0,10,0"/>
        <Button x:Name="Cancel" Content="Cancel" Width="90" Height="36" FontSize="14" Foreground="#E6EEF8" Background="#15243C" BorderBrush="#24395A" IsCancel="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Parse($dx)
    $pw = $w.FindName('Pw')
    $w.FindName('Ok').Add_Click({ $w.DialogResult = $true })
    $w.FindName('Cancel').Add_Click({ $w.DialogResult = $false })
    $w.Add_ContentRendered({ $pw.Focus() })
    if ($w.ShowDialog()) { return $pw.Password }
    return $null
}
function Show-Message([string]$Text, [string]$Title = 'GameLock') {
    [Windows.MessageBox]::Show($Text, $Title, 'OK', 'Information') | Out-Null
}

# --- preconditions ------------------------------------------------------------
if (-not (Test-Path $ConfigFile) -or -not (Test-Path $SecretFile)) {
    Show-Message "GameLock is not installed (missing files in $DataDir). Run Install-GameLock.ps1 first."
    exit 1
}

# --- login --------------------------------------------------------------------
$authenticated = $false
if ($Password) { $authenticated = Test-Password $Password }
$tries = 0
while (-not $authenticated -and $tries -lt 3) {
    $p = Read-PasswordDialog 'GameLock' 'Admin password'
    if ($null -eq $p) { exit 0 }
    $tries++
    if (Test-Password $p) { $authenticated = $true }
    else { Start-Sleep -Seconds 2; if ($tries -lt 3) { Show-Message 'Wrong password.' } }
}
if (-not $authenticated) { Show-Message 'Too many failed attempts.'; exit 1 }

# --- build window -------------------------------------------------------------
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in @('HeaderArt','Header','BtnMin','BtnCloseX','NavDash','NavSettings','NavActivity','NavAbout','PageDash','PageSettings','PageActivity','PageAbout',
    'TodayDate','BigNum','BigUnit','UsedLine','StatusPill','StatusGlyph','StatusTag','StatusSub','BarOuter','BarTrack','BarFill','BarPct','ResetGlyph','ResetLine',
    'Extra','ExtraUp','ExtraDown','BtnAdd','BtnRemove','BtnLock','BtnLockText','BtnSave',
    'Weekday','WeekdayUp','WeekdayDown','Weekend','WeekendUp','WeekendDown','WdFrom','WdFromUp','WdFromDown','WdUntil','WdUntilUp','WdUntilDown',
    'WeFrom','WeFromUp','WeFromDown','WeUntil','WeUntilUp','WeUntilDown','Reset','ResetUp','ResetDown','Grace','GraceUp','GraceDown',
    'Chart','ChartTotal','LegendLimit','ActivityList','ActivityListFull','BtnClearLog','BtnClearLog2','AboutData','BtnPass','BtnPass2','BtnClose','BarHeader','BtnCopyWeek','BtnResetHours','ChkMonday','FromMonday','ToMonday','DurMonday','BarMonday','ChkTuesday','FromTuesday','ToTuesday','DurTuesday','BarTuesday','ChkWednesday','FromWednesday','ToWednesday','DurWednesday','BarWednesday','ChkThursday','FromThursday','ToThursday','DurThursday','BarThursday','ChkFriday','FromFriday','ToFriday','DurFriday','BarFriday','ChkSaturday','FromSaturday','ToSaturday','DurSaturday','BarSaturday','ChkSunday','FromSunday','ToSunday','DurSunday','BarSunday')) {
    $ui[$n] = $win.FindName($n)
}

$Brush = @{
    Accent = $win.FindResource('Accent'); Red = $win.FindResource('Red'); Green = $win.FindResource('Green'); Amber = $win.FindResource('Amber')
    Muted = $win.FindResource('MutedBrush'); Text = $win.FindResource('Text'); Line = $win.FindResource('Line')
    BarBlue = $win.FindResource('BarBlue'); BarRed = $win.FindResource('BarRedStripes')
    GlowBlue = $win.FindResource('GlowBlue'); GlowRed = $win.FindResource('GlowRed'); GlowGreen = $win.FindResource('GlowGreen')
}

if (Test-Path $HeaderArt) {
    try {
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.UriSource = New-Object Uri($HeaderArt); $bi.CacheOption = 'OnLoad'; $bi.EndInit()
        $ui.HeaderArt.Source = $bi
    } catch {}
}

# window chrome
$ui.Header.Add_MouseLeftButtonDown({ if ($_.ButtonState -eq 'Pressed') { $win.DragMove() } })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnCloseX.Add_Click({ $win.Close() })
$ui.BtnClose.Add_Click({ $win.Close() })

# navigation
function Show-Page([string]$Name) {
    foreach ($p in 'PageDash','PageSettings','PageActivity','PageAbout') { $ui[$p].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
}
$ui.NavDash.Add_Checked({ Show-Page 'PageDash' })
$ui.NavSettings.Add_Checked({ Show-Page 'PageSettings'; try { $win.UpdateLayout(); Draw-BarHeader; foreach ($d in $DayNames) { Update-DayRow $d } } catch {} })
$ui.NavActivity.Add_Checked({ Show-Page 'PageActivity' })
$ui.NavAbout.Add_Checked({ Show-Page 'PageAbout' })

# spinners
$SpinSpec = @{
    Extra   = @{ min = 5; max = 600; step = 5 }
    Weekday = @{ min = 0; max = 1440; step = 15 }
    Weekend = @{ min = 0; max = 1440; step = 15 }
    Reset   = @{ min = 0; max = 23; step = 1 }
    Grace   = @{ min = 0; max = 300; step = 10 }
}
function Get-Spin([string]$Name) {
    $v = 0; [void][int]::TryParse($ui[$Name].Text, [ref]$v)
    $s = $SpinSpec[$Name]; return [Math]::Min($s.max, [Math]::Max($s.min, $v))
}
function Set-Spin([string]$Name, [int]$Value) { $ui[$Name].Text = "$Value" }
foreach ($name in $SpinSpec.Keys) {
    $ui["${name}Up"].Tag = $name;   $ui["${name}Up"].Add_Click({ $n = $this.Tag; Set-Spin $n ((Get-Spin $n) + $SpinSpec[$n].step) })
    $ui["${name}Down"].Tag = $name; $ui["${name}Down"].Add_Click({ $n = $this.Tag; Set-Spin $n ((Get-Spin $n) - $SpinSpec[$n].step) })
}
Set-Spin 'Extra' 60

# --- data to UI ---------------------------------------------------------------
function Update-Status {
    $config = Read-Json $ConfigFile
    if (-not $config) { $ui.UsedLine.Text = 'config.json unreadable'; return }
    $day   = Get-DayKey $config
    $state = Read-Json $StateFile
    $grant = Read-Json $GrantFile
    $extra = if ($grant -and $grant.day -eq $day) { [int]$grant.extraMinutes } else { 0 }
    $manual = [bool]($grant -and $grant.day -eq $day -and $grant.lockToday)
    $fresh = ($state -and $state.day -eq $day)
    $used  = if ($fresh) { [int]($state.seconds / 60) } else { 0 }
    $base  = if ($fresh -and $null -ne $state.baseMinutes) { [int]$state.baseMinutes } else { [int]$config.limitMinutes }
    $total = $base + $extra
    $left  = [Math]::Max(0, $total - $used)

    $ui.TodayDate.Text = [DateTime]::ParseExact($day, 'yyyy-MM-dd', $null).ToString('dddd, MMM d, yyyy')
    $ui.BigNum.Text  = "$left"
    $ui.UsedLine.Text = "$used of $total used   ($base base + $extra extra)"
    $pct = if ($total -gt 0) { [Math]::Min(100, [int][Math]::Round(100 * $used / $total)) } else { 100 }
    $ui.BarPct.Text = "$pct%"
    $trackW = $ui.BarTrack.ActualWidth; if ($trackW -le 0) { $trackW = 400 }
    $ui.BarFill.Width = [Math]::Max(0, $trackW * $pct / 100)

    $locked = ($fresh -and $state.locked)
    if ($locked) {
        $tag = 'LOCKED'; $sub = switch ("$($state.lockReason)") { 'window' { 'outside gaming hours' } 'manual' { 'locked by admin' } default { 'time used up' } }
        $col = $Brush.Red; $glyph = [char]0xE72E; $bg = '#3A1A1C'; $glow = $Brush.GlowRed
    } elseif ($fresh -and $state.playing) {
        $tag = 'PLAYING'; $sub = 'a game is running'; $col = $Brush.Green; $glyph = [char]0xE768; $bg = '#163A2A'; $glow = $Brush.GlowGreen
    } else {
        $tag = 'OPEN'; $sub = 'no game running'; $col = $Brush.Accent; $glyph = [char]0xE7C3; $bg = '#12304A'; $glow = $Brush.GlowBlue
    }
    $ui.StatusTag.Text = $tag; $ui.StatusSub.Text = $sub
    $ui.StatusTag.Foreground = $col; $ui.StatusGlyph.Foreground = $col; $ui.StatusGlyph.Text = "$glyph"
    $ui.StatusPill.BorderBrush = $col; $ui.StatusPill.Effect = $glow
    $ui.StatusPill.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($bg)
    if ($locked) {
        $ui.BarFill.Background = $Brush.BarRed; $ui.BarFill.Effect = $Brush.GlowRed; $ui.BarOuter.BorderBrush = $Brush.Red
    } else {
        $ui.BarFill.Background = if ($left -le 15) { $Brush.Amber } else { $Brush.BarBlue }
        $ui.BarFill.Effect = $Brush.GlowBlue; $ui.BarOuter.BorderBrush = $Brush.Line
    }

    $hours = if ($fresh -and $state.windowText) { "   |   gaming hours $($state.windowText)" } else { '' }
    $age = ''
    if ($state -and $state.updatedUtc) {
        try { $mins = [int]([DateTime]::UtcNow - [DateTime]::Parse($state.updatedUtc).ToUniversalTime()).TotalMinutes; if ($mins -gt 2) { $age = "   |   WATCHER STALE ($mins min)" } } catch {}
    }
    $ui.ResetLine.Text = "Resets at $(Format-Hour $config.resetHourLocal)$hours$age"
    $ui.ResetLine.Foreground = if ($age) { $Brush.Red } else { $Brush.Muted }
    $ui.ResetGlyph.Foreground = $ui.ResetLine.Foreground
    $ui.BtnLockText.Text = if ($manual) { 'Unlock Today' } else { 'Lock Today' }
}

function Add-ChartText($Canvas, [string]$Text, [double]$X, [double]$Y, [double]$W, $Brush, [string]$Align = 'Center', [double]$Size = 12) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = $Brush; $t.Width = $W; $t.TextAlignment = $Align
    [Windows.Controls.Canvas]::SetLeft($t, $X); [Windows.Controls.Canvas]::SetTop($t, $Y); $Canvas.Children.Add($t) | Out-Null
}

function Update-History {
    $h = Read-Json $HistoryFile
    $config = Read-Json $ConfigFile
    $today = [DateTime]::ParseExact((Get-DayKey $config), 'yyyy-MM-dd', $null)
    $days = @{}
    if ($h -and $h.days) { foreach ($p in $h.days.PSObject.Properties) { $days[$p.Name] = $p.Value } }
    $list = @()
    for ($i = 13; $i -ge 0; $i--) {
        $d = $today.AddDays(-$i); $e = $days[$d.ToString('yyyy-MM-dd')]
        $list += @{ date = $d; minutes = $(if ($e) { [int]$e.minutes } else { 0 }); limit = $(if ($e) { [int]$e.limit + [int]$e.extra } else { 0 }); locked = [bool]($e -and $e.locked) }
    }
    $c = $ui.Chart; $c.Children.Clear()
    $W = $c.ActualWidth; if ($W -le 0) { $W = 480 }; $H = $c.Height
    $left = 36; $right = 8; $top = 10; $bottom = 42
    $plotW = $W - $left - $right; $plotH = $H - $top - $bottom
    $limitNow = [int]$config.limitMinutes
    $maxVal = ($list | ForEach-Object { [Math]::Max($_.minutes, $_.limit) } | Measure-Object -Maximum).Maximum
    $maxVal = [Math]::Max(60, [Math]::Max($maxVal, $limitNow))
    $step = if ($maxVal -le 120) { 30 } elseif ($maxVal -le 240) { 60 } else { 120 }
    $axisMax = [Math]::Ceiling($maxVal / $step) * $step
    function Y([double]$v) { return $top + $plotH - ($plotH * $v / $axisMax) }

    for ($v = 0; $v -le $axisMax; $v += $step) {
        $y = Y $v
        $ln = New-Object Windows.Shapes.Line; $ln.X1 = $left; $ln.X2 = $W - $right; $ln.Y1 = $y; $ln.Y2 = $y
        $ln.Stroke = $Brush.Line; $ln.StrokeThickness = 1; $c.Children.Add($ln) | Out-Null
        Add-ChartText $c "$v" 0 ($y - 8) ($left - 8) $Brush.Muted 'Right' 11
    }
    if ($limitNow -gt 0) {
        $ly = Y $limitNow
        $ln = New-Object Windows.Shapes.Line; $ln.X1 = $left; $ln.X2 = $W - $right; $ln.Y1 = $ly; $ln.Y2 = $ly
        $ln.Stroke = $Brush.Muted; $ln.StrokeThickness = 1.5; $ln.StrokeDashArray = [Windows.Media.DoubleCollection]::new([double[]]@(4, 3)); $c.Children.Add($ln) | Out-Null
    }
    $n = $list.Count; $slot = $plotW / $n; $bw = [Math]::Max(6, $slot * 0.56)
    $total = 0
    for ($i = 0; $i -lt $n; $i++) {
        $d = $list[$i]; $total += $d.minutes
        $x = $left + $i * $slot + ($slot - $bw) / 2
        if ($d.minutes -gt 0) {
            $r = New-Object Windows.Shapes.Rectangle
            $r.Width = $bw; $r.Height = [Math]::Max(2, $plotH * $d.minutes / $axisMax); $r.RadiusX = 3; $r.RadiusY = 3
            $r.Fill = if ($d.locked) { $Brush.Red } else { $Brush.BarBlue }
            $r.Effect = if ($d.locked) { $Brush.GlowRed } else { $Brush.GlowBlue }
            [Windows.Controls.Canvas]::SetLeft($r, $x); [Windows.Controls.Canvas]::SetTop($r, (Y $d.minutes)); $c.Children.Add($r) | Out-Null
        }
        $lbl = $d.date.ToString('dd'); $col = if ($d.date.DayOfWeek -in 'Saturday','Sunday') { $Brush.Text } else { $Brush.Muted }
        Add-ChartText $c $lbl ($left + $i * $slot) ($top + $plotH + 6) $slot $col 'Center' 12
        if ($i -eq 0 -or $d.date.Day -eq 1) { Add-ChartText $c $d.date.ToString('MMM') ($left + $i * $slot) ($top + $plotH + 22) $slot $Brush.Muted 'Center' 11 }
    }
    $ui.ChartTotal.Text = ('Total: {0:0.0} hours' -f ($total / 60))
    $ui.LegendLimit.Text = "Limit $limitNow"
}

function New-ActivityRow($Entry) {
    $g = New-Object Windows.Controls.Grid
    foreach ($w in '24', '150', '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
    $action = "$($Entry.action)"
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 10; $dot.Height = 10; $dot.VerticalAlignment = 'Center'; $dot.HorizontalAlignment = 'Left'
    $dot.Fill = switch -Wildcard ($action) { 'locked*' { $Brush.Red } 'added*' { $Brush.Accent } 'removed*' { $Brush.Accent } 'unlocked*' { $Brush.Green } default { $Brush.Green } }
    $dot.Effect = if ($action -like 'locked*') { $Brush.GlowRed } elseif ($action -like 'added*' -or $action -like 'removed*') { $Brush.GlowBlue } else { $Brush.GlowGreen }
    $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = "$($Entry.at)"; $t1.Foreground = $Brush.Muted; $t1.FontSize = 13; $t1.VerticalAlignment = 'Center'
    $text = switch -Wildcard ($action) {
        'added'            { "Added $($Entry.minutes) min" }
        'removed extra'    { "Removed $($Entry.minutes) min" }
        'locked day'       { 'Locked day' }
        'unlocked'         { 'Unlocked day' }
        'settings saved'   { 'Settings saved' }
        'password changed' { 'Password changed' }
        'log cleared'      { 'Log cleared' }
        default            { $action }
    }
    $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = $text; $t2.Foreground = $Brush.Text; $t2.FontSize = 14; $t2.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($t1, 1); [Windows.Controls.Grid]::SetColumn($t2, 2)
    $g.Children.Add($dot) | Out-Null; $g.Children.Add($t1) | Out-Null; $g.Children.Add($t2) | Out-Null
    $b = New-Object Windows.Controls.Border; $b.Padding = '4,8'; $b.BorderThickness = '0,0,0,1'; $b.BorderBrush = $Brush.Line; $b.Child = $g
    return $b
}

function Update-Activity {
    $log = Read-Json $GrantLog
    $entries = @(); if ($log -and $log.entries) { $entries = @($log.entries) }
    [array]::Reverse($entries)
    foreach ($panel in @($ui.ActivityList, $ui.ActivityListFull)) {
        $panel.Children.Clear()
        if ($entries.Count -eq 0) {
            $t = New-Object Windows.Controls.TextBlock; $t.Text = 'No activity yet.'; $t.Foreground = $Brush.Muted; $t.FontSize = 14; $panel.Children.Add($t) | Out-Null
            continue
        }
        $take = if ($panel -eq $ui.ActivityList) { 12 } else { $entries.Count }
        foreach ($e in ($entries | Select-Object -First $take)) { $panel.Children.Add((New-ActivityRow $e)) | Out-Null }
    }
}


# --- gaming hours per day -----------------------------------------------------
$DayNames = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
$HourLabels = @(0..24 | ForEach-Object {
    if ($_ -eq 0) { '12:00 AM' } elseif ($_ -eq 24) { 'Midnight' } elseif ($_ -lt 12) { "${_}:00 AM" } elseif ($_ -eq 12) { '12:00 PM' } else { "$($_ - 12):00 PM" }
})
function Fill-HourBoxes {
    foreach ($d in $DayNames) {
        foreach ($box in @($ui["From$d"], $ui["To$d"])) { $box.Items.Clear(); foreach ($l in $HourLabels) { [void]$box.Items.Add($l) } }
        $ui["From$d"].Tag = $d; $ui["To$d"].Tag = $d; $ui["Chk$d"].Tag = $d; $ui["Bar$d"].Tag = $d
        $ui["Bar$d"].Add_MouseLeftButtonDown($BarDown); $ui["Bar$d"].Add_MouseMove($BarMove); $ui["Bar$d"].Add_MouseLeftButtonUp($BarUp)
        $ui["From$d"].Add_SelectionChanged({ Update-DayRow $this.Tag })
        $ui["To$d"].Add_SelectionChanged({ Update-DayRow $this.Tag })
        $ui["Chk$d"].Add_Click({ Update-DayRow $this.Tag })
    }
}
function Draw-BarHeader {
    $c = $ui.BarHeader; $c.Children.Clear()
    $W = $c.ActualWidth; if ($W -le 0) { return }
    foreach ($h in 0, 6, 12, 18, 24) {
        $x = $W * $h / 24
        $lbl = switch ($h) { 0 { '12 AM' } 6 { '6 AM' } 12 { '12 PM' } 18 { '6 PM' } 24 { '12 AM' } }
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $lbl; $t.FontSize = 11; $t.Foreground = $Brush.Muted; $t.Width = 44
        $t.TextAlignment = if ($h -eq 0) { 'Left' } elseif ($h -eq 24) { 'Right' } else { 'Center' }
        $left = if ($h -eq 0) { 0 } elseif ($h -eq 24) { $W - 44 } else { $x - 22 }
        [Windows.Controls.Canvas]::SetLeft($t, $left); [Windows.Controls.Canvas]::SetTop($t, 2); $c.Children.Add($t) | Out-Null
    }
}
function Update-DayRow([string]$Day) {
    $from = $ui["From$Day"].SelectedIndex; $to = $ui["To$Day"].SelectedIndex
    if ($from -lt 0 -or $to -lt 0) { return }
    $enabled = [bool]$ui["Chk$Day"].IsChecked
    $hours = if (-not $enabled) { 0 } elseif ($from -eq $to -or ($from -eq 0 -and $to -eq 24)) { 24 } elseif ($to -gt $from) { $to - $from } else { 24 - $from + $to }
    $ui["Dur$Day"].Text = if (-not $enabled) { 'off' } elseif ($hours -eq 24) { 'all day' } else { "${hours}h 0m" }
    foreach ($box in @($ui["From$Day"], $ui["To$Day"])) { $box.Opacity = if ($enabled) { 1 } else { 0.4 } }
    # timeline bar
    $c = $ui["Bar$Day"]; $c.Children.Clear()
    $W = $c.ActualWidth; if ($W -le 0) { return }
    $barH = 14; $top = 4
    $track = New-Object Windows.Shapes.Rectangle; $track.Width = $W; $track.Height = $barH; $track.RadiusX = 7; $track.RadiusY = 7
    $track.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#0D1A2E'); $track.Stroke = $Brush.Line
    [Windows.Controls.Canvas]::SetTop($track, $top); $c.Children.Add($track) | Out-Null
    foreach ($h in 6, 12, 18) { $tick = New-Object Windows.Shapes.Rectangle; $tick.Width = 1; $tick.Height = $barH; $tick.Fill = $Brush.Line; [Windows.Controls.Canvas]::SetLeft($tick, $W * $h / 24); [Windows.Controls.Canvas]::SetTop($tick, $top); $c.Children.Add($tick) | Out-Null }
    if (-not $enabled) {
        $r = New-Object Windows.Shapes.Rectangle; $r.Width = $W; $r.Height = $barH; $r.RadiusX = 7; $r.RadiusY = 7; $r.Fill = $Brush.BarRed; $r.Opacity = 0.7
        [Windows.Controls.Canvas]::SetTop($r, $top); $c.Children.Add($r) | Out-Null
        return
    }
    $segs = New-Object System.Collections.ArrayList
    if ($hours -eq 24) { [void]$segs.Add(@(0, 24)) } elseif ($to -gt $from) { [void]$segs.Add(@($from, $to)) } else { [void]$segs.Add(@($from, 24)); [void]$segs.Add(@(0, $to)) }
    foreach ($seg in $segs) {
        $x0 = $W * $seg[0] / 24; $x1 = $W * $seg[1] / 24
        $r = New-Object Windows.Shapes.Rectangle; $r.Width = [Math]::Max(4, $x1 - $x0); $r.Height = $barH; $r.RadiusX = 7; $r.RadiusY = 7; $r.Fill = $Brush.BarBlue; $r.Effect = $Brush.GlowBlue
        [Windows.Controls.Canvas]::SetLeft($r, $x0); [Windows.Controls.Canvas]::SetTop($r, $top); $c.Children.Add($r) | Out-Null
    }
    if ($hours -lt 24) {
        foreach ($h in $from, $to) {
            $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 18; $dot.Height = 18; $dot.Fill = [Windows.Media.Brushes]::White; $dot.Stroke = $Brush.Accent; $dot.StrokeThickness = 3; $dot.Effect = $Brush.GlowBlue
            [Windows.Controls.Canvas]::SetLeft($dot, ($W * $h / 24) - 9); [Windows.Controls.Canvas]::SetTop($dot, $top - 2); $c.Children.Add($dot) | Out-Null
        }
    }
}

# --- dragging the end markers -------------------------------------------------
$script:drag = $null
function Get-HourAtX($Canvas, [double]$X) {
    $W = $Canvas.ActualWidth; if ($W -le 0) { return 0 }
    return [int][Math]::Min(24, [Math]::Max(0, [Math]::Round($X / $W * 24)))
}
$BarDown = {
    $c = $this; $d = $c.Tag
    if (-not [bool]$ui["Chk$d"].IsChecked) { return }
    $x = $_.GetPosition($c).X; $W = $c.ActualWidth
    $from = $ui["From$d"].SelectedIndex; $to = $ui["To$d"].SelectedIndex
    $dF = [Math]::Abs($x - $W * $from / 24); $dT = [Math]::Abs($x - $W * $to / 24)
    if ($dF -gt 14 -and $dT -gt 14) { return }
    $which = if ($dF -le $dT) { 'From' } else { 'To' }
    $script:drag = @{ day = $d; which = $which }
    [void]$c.CaptureMouse(); $_.Handled = $true
}
$BarMove = {
    if (-not $script:drag -or $script:drag.day -ne $this.Tag) { return }
    $h = Get-HourAtX $this $_.GetPosition($this).X
    $box = $ui["$($script:drag.which)$($script:drag.day)"]
    if ($box.SelectedIndex -ne $h) { $box.SelectedIndex = $h }
}
$BarUp = {
    if ($script:drag -and $script:drag.day -eq $this.Tag) { $this.ReleaseMouseCapture(); $script:drag = $null; $_.Handled = $true }
}
function Set-DayRow([string]$Day, [bool]$Enabled, [int]$From, [int]$To) {
    $ui["Chk$Day"].IsChecked = $Enabled
    $ui["From$Day"].SelectedIndex = [Math]::Min(24, [Math]::Max(0, $From))
    $ui["To$Day"].SelectedIndex = [Math]::Min(24, [Math]::Max(0, $To))
    Update-DayRow $Day
}
function Load-DayHours($c) {
    foreach ($d in $DayNames) {
        $row = if ($c.days) { $c.days.$d } else { $null }
        if ($row) { Set-DayRow $d ($null -eq $row.enabled -or [bool]$row.enabled) ([int]$row.from) ([int]$row.until) }
        else {
            $weekend = $d -in 'Saturday','Sunday'
            $f = if ($weekend) { $c.weekendFrom } else { $c.weekdayFrom }; $t = if ($weekend) { $c.weekendUntil } else { $c.weekdayUntil }
            if ($null -eq $f -or $null -eq $t -or $f -eq $t) { $f = 0; $t = 24 }
            Set-DayRow $d $true ([int]$f) ([int]$t)
        }
    }
    Draw-BarHeader
}
function Get-DayHours {
    $o = [ordered]@{}
    foreach ($d in $DayNames) { $o[$d] = [ordered]@{ enabled = [bool]$ui["Chk$d"].IsChecked; from = [int]$ui["From$d"].SelectedIndex; until = [int]$ui["To$d"].SelectedIndex } }
    return $o
}
Fill-HourBoxes
$ui.BtnCopyWeek.Add_Click({ $e = [bool]$ui.ChkMonday.IsChecked; $f = $ui.FromMonday.SelectedIndex; $t = $ui.ToMonday.SelectedIndex; foreach ($d in $DayNames) { Set-DayRow $d $e $f $t } })
$ui.BtnResetHours.Add_Click({ foreach ($d in $DayNames) { Set-DayRow $d $true 0 24 } })

function Load-Settings {
    $c = Read-Json $ConfigFile; if (-not $c) { return }
    $wd = if ($null -ne $c.weekdayMinutes) { [int]$c.weekdayMinutes } else { [int]$c.limitMinutes }
    $we = if ($null -ne $c.weekendMinutes) { [int]$c.weekendMinutes } else { [int]$c.limitMinutes }
    Set-Spin 'Weekday' $wd; Set-Spin 'Weekend' $we
    Load-DayHours $c
    Set-Spin 'Reset'   ([int]$c.resetHourLocal)
    Set-Spin 'Grace'   $(if ($null -ne $c.graceSeconds) { [int]$c.graceSeconds } else { 60 })
    $ui.AboutData.Text = "Data folder: $DataDir`nReset hour: $(Format-Hour $c.resetHourLocal) in $(if ($c.timeZoneId) { $c.timeZoneId } else { 'a fixed UTC offset (re-save Settings to record the time zone)' })"
}

function Refresh-All { Update-Status; Update-History; Update-Activity }

function Set-Grant([int]$Minutes, [bool]$Lock) {
    $config = Read-Json $ConfigFile
    Write-Json $GrantFile ([ordered]@{ day = (Get-DayKey $config); extraMinutes = $Minutes; lockToday = $Lock; approvedAt = [DateTime]::Now.ToString('s') })
}
function Get-TodayGrant {
    $config = Read-Json $ConfigFile; $day = Get-DayKey $config; $g = Read-Json $GrantFile
    if ($g -and $g.day -eq $day) { return @{ extra = [int]$g.extraMinutes; lock = [bool]$g.lockToday } }
    return @{ extra = 0; lock = $false }
}

$ui.BtnAdd.Add_Click({ $g = Get-TodayGrant; $m = Get-Spin 'Extra'; Set-Grant ($g.extra + $m) $g.lock; Add-GrantLog 'added' $m; Refresh-All })
$ui.BtnRemove.Add_Click({ $g = Get-TodayGrant; Set-Grant 0 $g.lock; Add-GrantLog 'removed extra' $g.extra; Refresh-All })
$ui.BtnLock.Add_Click({ $g = Get-TodayGrant; Set-Grant $g.extra (-not $g.lock); Add-GrantLog $(if ($g.lock) { 'unlocked' } else { 'locked day' }) 0; Refresh-All })
$ui.BtnSave.Add_Click({
    $config = Read-Json $ConfigFile
    $offsetHours  = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalHours
    $resetLocal   = Get-Spin 'Reset'
    $new = [ordered]@{}
    foreach ($prop in $config.PSObject.Properties) { $new[$prop.Name] = $prop.Value }
    $new['weekdayMinutes'] = Get-Spin 'Weekday'; $new['weekendMinutes'] = Get-Spin 'Weekend'; $new['limitMinutes'] = Get-Spin 'Weekday'
    $new['days'] = Get-DayHours
    $new['resetHourLocal'] = $resetLocal; $new['resetHourUtc'] = (($resetLocal - $offsetHours) % 24 + 24) % 24
    $new['timeZoneId'] = [TimeZoneInfo]::Local.Id
    $new['graceSeconds'] = Get-Spin 'Grace'
    Write-Json $ConfigFile $new
    Add-GrantLog 'settings saved' 0
    Load-Settings; Refresh-All
    Show-Message 'Settings saved.'
})
$clearLog = { if ([Windows.MessageBox]::Show('Clear the activity log?', 'GameLock', 'YesNo', 'Question') -eq 'Yes') { Write-Json $GrantLog @{ entries = @() }; Add-GrantLog 'log cleared' 0; Update-Activity } }
$ui.BtnClearLog.Add_Click($clearLog); $ui.BtnClearLog2.Add_Click($clearLog)
$changePass = {
    $p1 = Read-PasswordDialog 'Change password' 'New admin password'
    if ($null -eq $p1) { return }
    if ($p1.Length -lt 4) { Show-Message 'Use at least 4 characters.'; return }
    $p2 = Read-PasswordDialog 'Change password' 'Repeat the new password'
    if ($p2 -ne $p1) { Show-Message 'Passwords do not match.'; return }
    Write-Json $SecretFile (New-SecretRecord $p1)
    Add-GrantLog 'password changed' 0
    Show-Message 'Password changed.'
}
$ui.BtnPass.Add_Click($changePass); $ui.BtnPass2.Add_Click($changePass)

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({ try { Update-Status } catch {} })
$win.Add_ContentRendered({ Load-Settings; Refresh-All })
$win.Add_SizeChanged({ try { if ($win.IsLoaded) { Update-Status; Update-History; Draw-BarHeader; foreach ($d in $DayNames) { Update-DayRow $d } } } catch {} })
$win.Add_Loaded({ $timer.Start() })
$win.Add_Closed({ $timer.Stop() })
[void]$win.ShowDialog()
