#Requires -Version 5.1
<#
.SYNOPSIS
    WinTidy App - grafische Oberflaeche fuer WinTidy (auch fuer Nicht-ITler).
.DESCRIPTION
    Startet ein Fenster (WPF). Die eigentliche Arbeit macht WinTidy.ps1, das in einem
    Hintergrund-Runspace geladen wird, damit die Oberflaeche nie einfriert.
    Start: "WinTidy App.cmd" doppelklicken oder Desktop-Verknuepfung (in den Einstellungen anlegbar).
#>
param([switch]$NoElevate, [switch]$Restarted)

$ErrorActionPreference = 'Stop'
$ErrLog = Join-Path $env:TEMP 'WinTidy-App-Fehler.log'
function Write-ErrLog([string]$t) { try { "$(Get-Date -Format s)  $t" | Out-File -LiteralPath $ErrLog -Append -Encoding utf8 } catch { } }

# Fehler beim Start sichtbar machen (die Konsole ist versteckt)
trap {
    Write-ErrLog ("FATAL " + ($_ | Out-String))
    try { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show("WinTidy konnte nicht starten.`n`n$($_.Exception.Message)`n`nFehlerprotokoll: $ErrLog", 'WinTidy', 'OK', 'Error') | Out-Null } catch { }
    try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex() } } catch { }
    exit 1
}

$AppPath = $PSCommandPath
$AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Netzlaufwerk (Z:\...): Der Prozess mit Adminrechten sieht verbundene Laufwerke meist nicht -> UNC-Pfad verwenden
$NetDriveProblem = $false
try {
    if ($AppRoot -match '^([A-Za-z]):') {
        $dl = $Matches[1]
        $di = New-Object System.IO.DriveInfo ($dl)
        if ("$($di.DriveType)" -eq 'Network') {
            $unc = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($dl):'" -ErrorAction Stop).ProviderName
            if ($unc) { $AppPath = $AppPath -replace '^[A-Za-z]:', $unc; $AppRoot = $AppRoot -replace '^[A-Za-z]:', $unc } else { $NetDriveProblem = $true }
        }
    }
} catch { $NetDriveProblem = $true }
$EnginePath = Join-Path $AppRoot 'WinTidy.ps1'

if (-not $IsAdmin -and -not $NoElevate) {
    if ($NetDriveProblem) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show("WinTidy liegt auf einem Netzlaufwerk. Mit Administratorrechten kann Windows es dort oft nicht finden.`n`nBitte den WinTidy-Ordner auf diesen PC kopieren (z. B. in Dokumente) und von dort starten.`n`nWinTidy startet jetzt eingeschränkt (nur Prüfen).", 'WinTidy', 'OK', 'Information') | Out-Null
    } else {
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$AppPath`"", '-NoElevate') -ErrorAction Stop
            return
        } catch { }   # UAC abgelehnt -> ohne Adminrechte weiter (eingeschraenkt)
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Nur eine Instanz (zwei gleichzeitige Optimierungen waeren gefaehrlich)
$Script:Mutex = $null
$gotMutex = $false
try {
    $Script:Mutex = New-Object System.Threading.Mutex($false, 'Global\WinTidyApp')
    try { $gotMutex = $Script:Mutex.WaitOne($(if ($Restarted) { 15000 } else { 0 })) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
} catch { $gotMutex = $false }
if (-not $gotMutex) {
    $Script:Mutex = $null
    [System.Windows.MessageBox]::Show('WinTidy ist bereits geöffnet. Bitte das vorhandene Fenster verwenden (ggf. in der Taskleiste).', 'WinTidy', 'OK', 'Information') | Out-Null
    return
}
if (-not (Test-Path -LiteralPath $EnginePath)) { [System.Windows.MessageBox]::Show("WinTidy.ps1 wurde nicht gefunden:`n$EnginePath`n`nBitte den kompletten WinTidy-Ordner kopieren.", 'WinTidy', 'OK', 'Error') | Out-Null; $Script:Mutex.ReleaseMutex(); return }

# =============================================================================
#  Oberflaeche (XAML)
# =============================================================================
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinTidy – PC-Pflege" Width="1180" Height="780" MinWidth="860" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}" FontFamily="Segoe UI" FontSize="14"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#F4F6FA"/>
    <SolidColorBrush x:Key="CardBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>
    <SolidColorBrush x:Key="AccentDark" Color="#1D4ED8"/>
    <SolidColorBrush x:Key="OnAccent" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Ink" Color="#0F172A"/>
    <SolidColorBrush x:Key="Text" Color="#334155"/>
    <SolidColorBrush x:Key="Text2" Color="#475569"/>
    <SolidColorBrush x:Key="Muted" Color="#556274"/>
    <SolidColorBrush x:Key="Line" Color="#E2E8F0"/>
    <SolidColorBrush x:Key="BtnLine" Color="#94A3B8"/>
    <SolidColorBrush x:Key="Hover" Color="#F1F5F9"/>
    <SolidColorBrush x:Key="NavSel" Color="#E0E9FF"/>
    <SolidColorBrush x:Key="NavSelFg" Color="#1D4ED8"/>
    <SolidColorBrush x:Key="Good" Color="#15803D"/>
    <SolidColorBrush x:Key="Warn" Color="#B45309"/>
    <SolidColorBrush x:Key="Bad" Color="#B91C1C"/>
    <SolidColorBrush x:Key="LowBg" Color="#DCFCE7"/>
    <SolidColorBrush x:Key="LowFg" Color="#166534"/>
    <SolidColorBrush x:Key="MidBg" Color="#FEF3C7"/>
    <SolidColorBrush x:Key="MidFg" Color="#92400E"/>
    <SolidColorBrush x:Key="HighBg" Color="#FEE2E2"/>
    <SolidColorBrush x:Key="HighFg" Color="#991B1B"/>
    <SolidColorBrush x:Key="InfoBg" Color="#E0E9FF"/>
    <SolidColorBrush x:Key="InfoFg" Color="#1E3A8A"/>
    <SolidColorBrush x:Key="TipBg" Color="#EFF6FF"/>
    <SolidColorBrush x:Key="TipLine" Color="#BFDBFE"/>
    <SolidColorBrush x:Key="LogBg" Color="#0F172A"/>
    <SolidColorBrush x:Key="LogFg" Color="#CBD5E1"/>
    <SolidColorBrush x:Key="Track" Color="#E5E7EB"/>
    <SolidColorBrush x:Key="Link" Color="#1D4ED8"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardBg}"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="20"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="28"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="18"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource BtnLine}" VerticalAlignment="Top" Margin="0,1,9,0">
              <Grid>
                <TextBlock x:Name="mark" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="{DynamicResource OnAccent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                <TextBlock x:Name="part" Text="&#xE738;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="{DynamicResource OnAccent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ContentPresenter Grid.Column="1" VerticalAlignment="Center" RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="box" Property="Background" Value="{DynamicResource Accent}"/><Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="mark" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="box" Property="Background" Value="{DynamicResource Accent}"/><Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="part" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Ink}"/><Setter TargetName="box" Property="BorderThickness" Value="2"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Choice" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="pill" CornerRadius="10" BorderThickness="1.5" Padding="14,8" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource BtnLine}">
            <StackPanel Orientation="Horizontal">
              <Grid Width="18" Height="18" Margin="0,0,9,0" VerticalAlignment="Center">
                <Ellipse x:Name="ring" Stroke="{DynamicResource BtnLine}" StrokeThickness="1.5" Fill="{DynamicResource CardBg}"/>
                <Ellipse x:Name="dot" Width="8" Height="8" Fill="{DynamicResource OnAccent}" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="ring" Property="Fill" Value="{DynamicResource Accent}"/><Setter TargetName="ring" Property="Stroke" Value="{DynamicResource Accent}"/><Setter TargetName="dot" Property="Visibility" Value="Visible"/><Setter TargetName="pill" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="pill" Property="Background" Value="{DynamicResource NavSel}"/></Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="pill" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="pill" Property="BorderBrush" Value="{DynamicResource Ink}"/><Setter TargetName="pill" Property="BorderThickness" Value="2"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="WtThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border x:Name="t" CornerRadius="4" Background="{DynamicResource BtnLine}" Opacity="0.7"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Opacity" Value="1"/></Trigger><Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Opacity" Value="1"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="{TemplateBinding Background}">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
              <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource WtThumb}"/></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Grid Background="{TemplateBinding Background}">
                <Track x:Name="PART_Track" IsDirectionReversed="False" Margin="2">
                  <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb Style="{StaticResource WtThumb}"/></Track.Thumb>
                </Track>
              </Grid>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{DynamicResource CardBg}"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,12"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource AccentDark}" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource AccentDark}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Ink}"/><Setter TargetName="b" Property="BorderThickness" Value="2"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="18,10"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Background" Value="{DynamicResource CardBg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource BtnLine}" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Ink}"/><Setter TargetName="b" Property="BorderThickness" Value="2"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Link}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><TextBlock Text="{TemplateBinding Content}" TextDecorations="Underline" Foreground="{TemplateBinding Foreground}"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="FontSize" Value="15"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="10" Padding="14,11" Background="Transparent" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource NavSel}"/><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource NavSelFg}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Ink}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition x:Name="NavCol" Width="232"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Navigation -->
    <Border Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,0">
      <DockPanel x:Name="NavDock" Margin="16,22,16,16">
        <StackPanel DockPanel.Dock="Top" Margin="6,0,0,26" Orientation="Horizontal">
          <Border Width="40" Height="40" CornerRadius="11" Background="{DynamicResource Accent}">
            <TextBlock Text="&#xE9F5;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource OnAccent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel x:Name="BrandText" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="WinTidy" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
            <TextBlock Text="PC-Pflege mit Beleg" FontSize="12" Foreground="{DynamicResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <TextBlock x:Name="VersionText" FontSize="12" Foreground="{DynamicResource Muted}" Margin="6,0" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavHome" AutomationProperties.Name="Übersicht" Style="{StaticResource Nav}" IsChecked="True" ToolTip="Übersicht"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT1" Text="Übersicht"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavRecs" AutomationProperties.Name="Empfehlungen" Style="{StaticResource Nav}" ToolTip="Empfehlungen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE82F;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT2" Text="Empfehlungen"/><Border x:Name="RecsBadge" Background="{DynamicResource Accent}" CornerRadius="9" Padding="7,0" Margin="8,0,0,0" Visibility="Collapsed"><TextBlock x:Name="RecsBadgeText" Foreground="{DynamicResource OnAccent}" FontSize="12"/></Border></StackPanel></RadioButton>
          <RadioButton x:Name="NavHistory" AutomationProperties.Name="Verlauf" Style="{StaticResource Nav}" ToolTip="Verlauf"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT3" Text="Verlauf"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavSettings" AutomationProperties.Name="Einstellungen" Style="{StaticResource Nav}" ToolTip="Einstellungen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT4" Text="Einstellungen"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavHelp" AutomationProperties.Name="Hilfe" Style="{StaticResource Nav}" ToolTip="Hilfe"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE897;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT5" Text="Hilfe"/></StackPanel></RadioButton>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Inhalt -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel x:Name="BannerPanel" Grid.Row="0" Margin="36,16,36,0"/>

      <Grid Grid.Row="1">
      <!-- Übersicht -->
      <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Übersicht" Style="{StaticResource H1}"/>
          <TextBlock x:Name="HomeSub" Style="{StaticResource Sub}" Margin="0,4,0,22" Text="Lass WinTidy deinen PC prüfen. Dabei wird nichts verändert."/>
          <Border Style="{StaticResource Card}" Padding="26">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <Grid Width="170" Height="170">
                  <Ellipse Stroke="{DynamicResource Track}" StrokeThickness="14"/>
                  <Path x:Name="ScoreArc" StrokeThickness="14" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stroke="{DynamicResource Accent}"/>
                  <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock x:Name="ScoreText" Text="–" FontSize="46" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{DynamicResource Ink}"/>
                    <TextBlock Text="von 100" FontSize="12" HorizontalAlignment="Center" Foreground="{DynamicResource Muted}"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="30,6,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="ScoreHeadline" Text="Noch nicht geprüft" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" TextWrapping="Wrap"/>
                <TextBlock x:Name="ScoreDetail" Style="{StaticResource Sub}" Margin="0,6,0,6" Text="Die Prüfung dauert meist ein bis drei Minuten. Danach siehst du, was sich verbessern lässt – in verständlichen Worten."/>
                <TextBlock x:Name="ScoreLimited" FontSize="12" Foreground="{DynamicResource Warn}" TextWrapping="Wrap" Margin="0,0,0,6" Visibility="Collapsed" Text="Eingeschränkte Prüfung ohne Administratorrechte – der Wert ist nur bedingt aussagekräftig."/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Button x:Name="BtnScan" Style="{StaticResource Primary}" Content="_Jetzt prüfen"/>
                  <Button x:Name="BtnToRecs" Style="{StaticResource Secondary}" Content="Empfehlungen an_sehen" Margin="12,0,0,0" Visibility="Collapsed"/>
                </StackPanel>
                <TextBlock x:Name="LastScanText" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,12,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
          </Border>
          <Expander x:Name="ScoreWhy" Header="Warum nicht 100?" Margin="4,-4,0,14" Visibility="Collapsed">
            <Border Style="{StaticResource Card}" Margin="0,8,0,0">
              <StackPanel>
                <StackPanel x:Name="ScoreWhyList"/>
                <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,10,0,0" Text="Der Wert beschreibt den Zustand deines PCs, nicht wie viel WinTidy aufgeräumt hat. Manche Punkte kann WinTidy nicht selbst beheben (z. B. Einstellungen im BIOS), andere bessern sich erst nach einigen Tagen (z. B. Fehler im Ereignisprotokoll)."/>
              </StackPanel>
            </Border>
          </Expander>
          <UniformGrid x:Name="KpiGrid" Columns="4" Margin="-7,0,-7,0"/>
          <Border x:Name="HwCard" Style="{StaticResource Card}" Margin="0,14,0,0" Visibility="Collapsed">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Hardware" Style="{StaticResource H2}"/>
                <Border Background="{DynamicResource InfoBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="Für Fachleute" FontSize="12" Foreground="{DynamicResource InfoFg}"/></Border>
              </StackPanel>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,12" Text="Kühlung, Laufwerke, Arbeitsspeicher und Bildschirm. WinTidy ändert hier nichts. Lass Änderungen (z. B. im BIOS) bei Bedarf von jemandem erledigen, der sich auskennt."/>
              <TextBlock Style="{StaticResource Sub}" FontSize="13" Margin="0,0,0,10" Text="✓ in Ordnung   ·   ! im Auge behalten   ·   ✗ bald darum kümmern"/>
              <StackPanel x:Name="HwPanel"/>
              <StackPanel x:Name="CoolTestPanel" Margin="0,4,0,0"/>
              <WrapPanel Margin="0,8,0,0">
                <Button x:Name="BtnCoolTest" Style="{StaticResource Secondary}" Content="Kühlung testen (ca. 1 Minute)" AutomationProperties.Name="Kühlung testen, dauert etwa eine Minute"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap" Text="Der Test belastet den Prozessor kurz voll und prüft, ob die Kühlung mithält. Die Lüfter werden dabei hörbar lauter. Lüfterkurven selbst stehen im BIOS – WinTidy misst nur ihre Wirkung."/>
            </StackPanel>
          </Border>
          <Border x:Name="HintsCard" Style="{StaticResource Card}" Margin="0,14,0,0" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="Gut zu wissen" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,12" Text="Diese Punkte kann WinTidy nicht selbst erledigen."/>
              <StackPanel x:Name="HintsPanel"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Empfehlungen -->
      <Grid x:Name="PageRecs" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="36,22,36,10">
          <TextBlock Text="Empfehlungen" Style="{StaticResource H1}"/>
          <TextBlock x:Name="RecsSub" Style="{StaticResource Sub}" Margin="0,4,0,10" Text="Noch keine Prüfung durchgeführt."/>
          <WrapPanel x:Name="RecsLegend" Margin="0,0,0,8">
            <Border Background="{DynamicResource LowBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Sicher" FontSize="12" Foreground="{DynamicResource LowFg}"/></Border>
            <TextBlock Text="Datenmüll, umkehrbar oder Windows-eigene Pflege" FontSize="13" Foreground="{DynamicResource Muted}" Margin="0,2,18,4"/>
            <Border Background="{DynamicResource MidBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Kurz prüfen" FontSize="12" Foreground="{DynamicResource MidFg}"/></Border>
            <TextBlock Text="bitte ansehen, ob du das noch brauchst" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,2,18,4"/>
            <Border Background="{DynamicResource HighBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Nur für Profis" FontSize="12" Foreground="{DynamicResource HighFg}"/></Border>
            <TextBlock Text="kann Fehltreffer enthalten, jeden Eintrag einzeln wählen" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,2,0,4"/>
          </WrapPanel>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnSelRecommended" Style="{StaticResource LinkBtn}" Content="Empfohlene auswählen"/>
            <TextBlock Text="  ·  " Foreground="{DynamicResource Muted}"/>
            <Button x:Name="BtnSelNone" Style="{StaticResource LinkBtn}" Content="Nichts auswählen"/>
          </StackPanel>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="RecsPanel" Margin="36,6,36,20" MaxWidth="980"/>
        </ScrollViewer>
        <Border Grid.Row="2" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="36,14">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnElevate2" Style="{StaticResource Secondary}" Content="Mit _Administratorrechten neu starten" Margin="0,0,12,0" Visibility="Collapsed"/>
              <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Ausgewählte _umsetzen"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
              <TextBlock x:Name="SelSummary" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" TextWrapping="Wrap"/>
              <TextBlock x:Name="SelNote" FontSize="12" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Text="Vorher wird ein Wiederherstellungspunkt angelegt. Jede Änderung wird protokolliert."/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>

      <!-- Arbeit läuft -->
      <ScrollViewer x:Name="PageBusy" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <Border Style="{StaticResource Card}" MaxWidth="660" Margin="36,30" VerticalAlignment="Center" Padding="30">
          <StackPanel>
            <TextBlock x:Name="BusyTitle" Text="Prüfe deinen PC …" Style="{StaticResource H2}" FontSize="22"/>
            <TextBlock x:Name="BusyStep" Style="{StaticResource Sub}" Margin="0,8,0,16" Text="Einen Moment bitte."/>
            <ProgressBar x:Name="BusyBar" Height="10" Minimum="0" Maximum="100" Foreground="{DynamicResource Accent}" Background="{DynamicResource Track}" BorderThickness="0" IsIndeterminate="True"/>
            <DockPanel Margin="0,8,0,0">
              <TextBlock x:Name="BusyElapsed" DockPanel.Dock="Right" FontSize="12" Foreground="{DynamicResource Muted}"/>
              <TextBlock x:Name="BusyCount" FontSize="12" Foreground="{DynamicResource Muted}"/>
            </DockPanel>
            <TextBlock x:Name="BusyHint" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <Border x:Name="BusyUninstall" Background="{DynamicResource MidBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,14,0,0" Visibility="Collapsed">
              <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource MidFg}" FontWeight="SemiBold" Text="Jetzt öffnet sich ein Deinstallationsfenster. Bitte dort durchklicken – es kann hinter diesem Fenster liegen (Taskleiste prüfen)."/>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
              <Button x:Name="BtnCancel" Style="{StaticResource Secondary}" Content="Abbre_chen" IsCancel="True"/>
              <TextBlock x:Name="CancelNote" FontSize="12" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <Expander Header="Details anzeigen" Margin="0,16,0,0">
              <TextBox x:Name="BusyLog" Height="220" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderThickness="0" Padding="8"/>
            </Expander>
          </StackPanel>
        </Border>
      </ScrollViewer>

      <!-- Ergebnis -->
      <ScrollViewer x:Name="PageResult" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <DockPanel>
            <Border x:Name="ResultIconBg" Width="44" Height="44" CornerRadius="22" Background="{DynamicResource LowBg}" DockPanel.Dock="Left" VerticalAlignment="Top"><TextBlock x:Name="ResultIcon" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="{DynamicResource Good}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <TextBlock x:Name="ResultTitle" Text="Fertig!" Style="{StaticResource H1}" Margin="14,0,0,0" VerticalAlignment="Center"/>
          </DockPanel>
          <TextBlock x:Name="ResultSub" Style="{StaticResource Sub}" Margin="0,8,0,20"/>
          <UniformGrid x:Name="ResultGrid" Columns="3" Margin="-7,0,-7,0"/>
          <Border x:Name="ResultNoteCard" Style="{StaticResource Card}" Background="{DynamicResource MidBg}" Visibility="Collapsed">
            <TextBlock x:Name="ResultNote" TextWrapping="Wrap" Foreground="{DynamicResource MidFg}"/>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was genau passiert ist" Style="{StaticResource H2}"/>
              <StackPanel x:Name="ResultDetails" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Background="{DynamicResource TipBg}" BorderBrush="{DynamicResource TipLine}">
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource InfoFg}" Text="Tipp: Die Wirkung auf die Startzeit zeigt sich erst nach ein paar Neustarts. Starte den PC in den nächsten Tagen ganz normal und prüfe dann erneut. Unter Verlauf siehst du die Entwicklung."/>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnRestartNow" Style="{StaticResource Primary}" Content="PC jetzt _neu starten" Margin="0,0,12,10"/>
            <Button x:Name="BtnResultReport" Style="{StaticResource Secondary}" Content="Ausführlichen _Bericht öffnen" Margin="0,0,12,10"/>
            <Button x:Name="BtnResultHome" Style="{StaticResource Secondary}" Content="Zur _Übersicht" Margin="0,0,12,10"/>
          </WrapPanel>
          <Button x:Name="BtnResultUndo" Style="{StaticResource LinkBtn}" Content="Änderungen rückgängig machen …" Margin="0,8,0,0" HorizontalAlignment="Left"/>
        </StackPanel>
      </ScrollViewer>

      <!-- Fehler -->
      <ScrollViewer x:Name="PageError" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <Border Style="{StaticResource Card}" MaxWidth="660" Margin="36,30" VerticalAlignment="Center" Padding="30">
          <StackPanel>
            <DockPanel>
              <Border Width="44" Height="44" CornerRadius="22" Background="{DynamicResource MidBg}" DockPanel.Dock="Left" VerticalAlignment="Top"><TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="{DynamicResource MidFg}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
              <TextBlock x:Name="ErrTitle" Style="{StaticResource H2}" FontSize="22" Margin="14,0,0,0" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="ErrText" Style="{StaticResource Body}" Margin="0,14,0,0"/>
            <WrapPanel Margin="0,20,0,0">
              <Button x:Name="BtnErrRetry" Style="{StaticResource Primary}" Content="_Erneut versuchen" Margin="0,0,12,10"/>
              <Button x:Name="BtnErrCopy" Style="{StaticResource Secondary}" Content="Fehlerbericht _kopieren" Margin="0,0,12,10"/>
              <Button x:Name="BtnErrHome" Style="{StaticResource Secondary}" Content="Zur _Übersicht" Margin="0,0,12,10"/>
            </WrapPanel>
            <TextBlock x:Name="ErrCopied" FontSize="12" Foreground="{DynamicResource Good}" Visibility="Collapsed" Text="Fehlerbericht ist in der Zwischenablage. Du kannst ihn z. B. in eine E-Mail einfügen."/>
            <Expander Header="Technische Details" Margin="0,12,0,0">
              <TextBox x:Name="ErrDetail" Height="140" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderThickness="0" Padding="8"/>
            </Expander>
          </StackPanel>
        </Border>
      </ScrollViewer>

      <!-- Verlauf -->
      <ScrollViewer x:Name="PageHistory" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Verlauf" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="So hat sich dein PC entwickelt. Grüne Linien markieren Optimierungen."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Windows-Start bis bereit" Style="{StaticResource H2}"/>
              <Canvas x:Name="BootCanvas" Height="240" Margin="0,14,0,0" ClipToBounds="True"/>
              <TextBlock x:Name="BootNote" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Prüfungen und Optimierungen" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,4,0,0" Text="Bei Optimierungen kannst du Einstellungen (Autostart, geplante Aufgaben, Dienste) einzeln pro Lauf zurücksetzen."/>
              <StackPanel x:Name="HistoryList" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnHistReport" Style="{StaticResource Secondary}" Content="Ausführlichen _Bericht öffnen" Margin="0,0,12,10"/>
            <Button x:Name="BtnHistFolder" Style="{StaticResource Secondary}" Content="_Protokoll-Ordner öffnen" Margin="0,0,12,10"/>
            <Button x:Name="BtnHistRstrui" Style="{StaticResource Secondary}" Content="_Systemwiederherstellung öffnen" Margin="0,0,12,10"/>
          </WrapPanel>
        </StackPanel>
      </ScrollViewer>

      <!-- Einstellungen -->
      <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Einstellungen" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="Die Standardeinstellungen passen für fast alle."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Darstellung" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <WrapPanel>
                <RadioButton x:Name="OptThemeAuto" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Wie Windows" AutomationProperties.Name="Darstellung wie Windows"/>
                <RadioButton x:Name="OptThemeLight" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Hell" AutomationProperties.Name="Helle Darstellung"/>
                <RadioButton x:Name="OptThemeDark" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Dunkel" AutomationProperties.Name="Dunkle Darstellung"/>
              </WrapPanel>
              <TextBlock x:Name="ThemeNote" Style="{StaticResource Sub}" FontSize="13" Margin="0,6,0,0" Text="„Wie Windows“ folgt der Einstellung unter Einstellungen › Personalisierung › Farben."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Sicherheit" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <CheckBox x:Name="OptRestorePoint" IsChecked="True" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Vor Änderungen einen Wiederherstellungspunkt anlegen <Run Foreground="{DynamicResource Muted}">(dringend empfohlen)</Run></TextBlock></CheckBox>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="24,2,0,0" Text="Ein Wiederherstellungspunkt kann Einstellungen, Treiber und Systemdateien zurücksetzen. Gelöschte Dateien und entfernte Programme holt er nicht zurück."/>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="BtnUndo" Style="{StaticResource Secondary}" Content="Letzte Optimierung _rückgängig machen …" Margin="0,0,12,6"/>
                <Button x:Name="BtnRstrui" Style="{StaticResource Secondary}" Content="_Systemwiederherstellung öffnen" Margin="0,0,12,6"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" Text="WinTidy setzt Autostart-Einstellungen, geplante Aufgaben, Dienste und einige Windows-Einstellungen selbst zurück. Gelöschte Dateien kommen nicht zurück – auch nicht über die Systemwiederherstellung. Einzelne Läufe findest du unter Verlauf."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Prüfung" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <CheckBox x:Name="OptDeep" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Gründliche Prüfung <Run Foreground="{DynamicResource Muted}">(prüft zusätzlich Laufwerke und Systemdateien, dauert bis zu 30 Minuten)</Run></TextBlock></CheckBox>
              <CheckBox x:Name="OptExpert" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Expertenmodus <Run Foreground="{DynamicResource Muted}">(zeigt technische Details und Empfehlungen mit Fehltreffer-Risiko – wirkt ab der nächsten Prüfung)</Run></TextBlock></CheckBox>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Programm" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <WrapPanel>
                <Button x:Name="BtnShortcut" Style="{StaticResource Secondary}" Content="_Verknüpfung auf dem Desktop anlegen" Margin="0,0,12,10"/>
                <Button x:Name="BtnDataFolder" Style="{StaticResource Secondary}" Content="_Datenordner öffnen" Margin="0,0,12,10"/>
                <Button x:Name="BtnConfig" Style="{StaticResource Secondary}" Content="_Konfiguration bearbeiten" Margin="0,0,12,10" Visibility="Collapsed"/>
              </WrapPanel>
              <TextBlock x:Name="AboutText" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Hilfe -->
      <ScrollViewer x:Name="PageHelp" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Hilfe" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="Die häufigsten Fragen in Kürze."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was macht WinTidy?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="WinTidy prüft deinen PC (Speicherplatz, Autostart, Altlasten, Sicherheit, Hardware) und schlägt Verbesserungen vor. Beim Prüfen wird nichts verändert. Umgesetzt wird nur, was du auswählst – vorher und nachher wird gemessen, damit du den Unterschied siehst."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Ist das sicher?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="WinTidy nutzt nur Windows-eigene Werkzeuge, schaltet keine Schutzfunktionen ab und legt vor Änderungen einen Wiederherstellungspunkt an. Einstellungen (Autostart, Aufgaben, Dienste) kann WinTidy selbst zurücksetzen. Auf Firmen-PCs zeigt WinTidy nur sichere Punkte – frag im Zweifel deine IT."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was passiert mit meinen Dateien?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Deine Dokumente, Bilder und Downloads fasst WinTidy nicht an. Gelöscht werden nur Dinge wie alte temporäre Dateien, Update-Reste und Einträge, die schon lange im Papierkorb liegen. Was gelöscht ist, kommt nicht zurück – deshalb siehst du vorher genau, was betroffen ist."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was bedeuten die Farben?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Grün (Sicher): Datenmüll, umkehrbar oder Windows-eigene Pflege – ist vorausgewählt. Gelb (Kurz prüfen): bitte kurz ansehen, ob du das noch brauchst. Rot (Nur für Profis): kann Fehltreffer enthalten, nur im Expertenmodus sichtbar und nur einzeln auswählbar."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Warum ändert sich die Startzeit erst später?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Windows misst die Startzeit bei jedem Hochfahren selbst. Die Wirkung einer Optimierung sieht man deshalb erst nach einigen normalen Neustarts. Einzelne langsame Starts (z. B. nach Updates) sind normal – entscheidend ist der Durchschnitt im Verlauf."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Kann WinTidy die Lüfter einstellen?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Nein. Lüfterkurven stehen im BIOS oder in Hersteller-Programmen. WinTidy liest aus, was Windows zuverlässig meldet (z. B. Temperaturen von Grafikkarte und Laufwerken, Drosselung des Prozessors) und weist auf Auffälligkeiten hin. Viele Mainboards geben Lüfterdaten ohne Zusatzprogramm gar nicht an Windows weiter."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was macht der Kühlungstest?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Er lässt den Prozessor etwa eine Minute lang voll arbeiten und beobachtet, ob er dabei wegen Hitze langsamer wird, wie warm er wird und ob die Lüfter hochdrehen. Die Lüfter werden dabei laut – das ist gewollt. Wird es zu heiß oder ziehst du beim Laptop das Netzteil, hört der Test sofort auf. Am PC wird nichts verändert."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Was tun bei einer roten Hardware-Warnung?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Meldet ein Laufwerk Probleme, sichere zuerst deine Fotos und Dokumente (USB-Stick, externe Festplatte oder Cloud). Bei Warnungen zur Kühlung hilft meist, den PC von innen von Staub zu befreien. In beiden Fällen: lass den PC von jemandem prüfen, der sich auskennt. WinTidy selbst ändert an der Hardware nichts."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Nach der Optimierung funktioniert etwas nicht – was tun?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Unter Verlauf findest du bei jeder Optimierung „Rückgängig …“. Damit setzt WinTidy Autostart, geplante Aufgaben, Dienste und Einstellungen zurück. Reicht das nicht, nutze unter Verlauf „Systemwiederherstellung öffnen“ und wähle den Punkt „WinTidy …“ vom Tag der Optimierung."/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $Xaml
$Win = [Windows.Markup.XamlReader]::Load($reader)
$UI = @{}
$Xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1; if ($n) { $UI[$n.Value] = $Win.FindName($n.Value) } }

# =============================================================================
#  Farben (inkl. Kontrastdesign) und Hilfsfunktionen
# =============================================================================
$HighContrast = [System.Windows.SystemParameters]::HighContrast
if ($HighContrast) {
    $sc = [System.Windows.SystemColors]
    $map = @{
        Bg = $sc::WindowBrush; CardBg = $sc::WindowBrush; Hover = $sc::ControlBrush; NavSel = $sc::ControlBrush; NavSelFg = $sc::ControlTextBrush; Track = $sc::ControlBrush
        Accent = $sc::HighlightBrush; AccentDark = $sc::HighlightBrush; OnAccent = $sc::HighlightTextBrush
        Ink = $sc::WindowTextBrush; Text = $sc::WindowTextBrush; Text2 = $sc::WindowTextBrush; Muted = $sc::WindowTextBrush
        Line = $sc::WindowTextBrush; BtnLine = $sc::WindowTextBrush; Good = $sc::WindowTextBrush; Warn = $sc::WindowTextBrush; Bad = $sc::WindowTextBrush
        LowBg = $sc::WindowBrush; MidBg = $sc::WindowBrush; HighBg = $sc::WindowBrush; InfoBg = $sc::WindowBrush; TipBg = $sc::WindowBrush; TipLine = $sc::WindowTextBrush
        LowFg = $sc::WindowTextBrush; MidFg = $sc::WindowTextBrush; HighFg = $sc::WindowTextBrush; InfoFg = $sc::WindowTextBrush
        LogBg = $sc::WindowBrush; LogFg = $sc::WindowTextBrush; Link = $sc::HotTrackBrush
    }
    foreach ($k in $map.Keys) { $Win.Resources[$k] = $map[$k] }
}
function B([string]$key) { $Win.Resources[$key] }
# Farbe als Ressourcen-Verweis setzen (nicht als feste Farbe), damit sich das Element beim Umschalten Hell/Dunkel mitaendert
function Set-Brush($el, [string]$prop, [string]$key) {
    $f = $el.GetType().GetField($prop + 'Property', [Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
    if ($f) { $el.SetResourceReference($f.GetValue($null), $key) } else { $el.$prop = $Win.Resources[$key] }
}

# =============================================================================
#  Hell / Dunkel
#  Die Farben sind Pinsel in den Fenster-Ressourcen. Beim Umschalten werden sie ersetzt; XAML (DynamicResource) und
#  Code (Set-Brush = SetResourceReference) verweisen nur auf den Schluessel und passen sich dadurch sofort an.
# =============================================================================
$ThemeDark = @{
    Bg = '#0B1220'; CardBg = '#141C2B'; Accent = '#2563EB'; AccentDark = '#1D4ED8'; OnAccent = '#FFFFFF'; Link = '#7AAAFB'
    Ink = '#F1F5F9'; Text = '#CBD5E1'; Text2 = '#AAB6C8'; Muted = '#9AA8BC'; Line = '#263244'; BtnLine = '#6B7C96'
    Hover = '#1E293B'; NavSel = '#1E3A6E'; NavSelFg = '#DBEAFE'; Good = '#4ADE80'; Warn = '#FBBF24'; Bad = '#F87171'
    LowBg = '#0B3B22'; LowFg = '#86EFAC'; MidBg = '#3D2A06'; MidFg = '#FCD34D'; HighBg = '#4A1212'; HighFg = '#FCA5A5'
    InfoBg = '#172554'; InfoFg = '#BFDBFE'; TipBg = '#111F3A'; TipLine = '#1E3A8A'; LogBg = '#020617'; LogFg = '#CBD5E1'; Track = '#243042'
}
$ThemeLight = @{}
$AppSettingsFile = Join-Path $env:APPDATA 'WinTidy\app-einstellungen.json'
$Script:ThemeMode = 'Auto'; $Script:IsDark = $false
if (-not $HighContrast) {
    foreach ($k in @($ThemeDark.Keys)) {
        $br = $Win.Resources[$k]
        if ($br -is [System.Windows.Media.SolidColorBrush]) {
            $ThemeLight[$k] = $br.Color.ToString()
        }
    }
}
function Get-WindowsDarkMode {
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}
if (-not ('WtDwm' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WtDwm {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    // Titelleiste dunkel/hell (Windows 10 20H1+: Attribut 20, aeltere Builds: 19)
    public static void SetDark(IntPtr hwnd, bool dark) { int v = dark ? 1 : 0; if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) { DwmSetWindowAttribute(hwnd, 19, ref v, 4); } }
}
'@ -ErrorAction Stop
    } catch { }
}
function Set-TitleBarDark([bool]$dark) {
    try { $h = (New-Object System.Windows.Interop.WindowInteropHelper $Win).Handle; if ($h -ne [IntPtr]::Zero -and ('WtDwm' -as [type])) { [WtDwm]::SetDark($h, $dark) } } catch { }
}
function Apply-Theme {
    if ($HighContrast) { return }
    $dark = switch ($Script:ThemeMode) { 'Dunkel' { $true } 'Hell' { $false } default { Get-WindowsDarkMode } }
    $pal = if ($dark) { $ThemeDark } else { $ThemeLight }
    # Pinsel ersetzen (WPF friert Pinsel ein, die von Styles/Vorlagen benutzt werden - aendern ginge dann nicht).
    # Alle Verweise (DynamicResource im XAML, Set-Brush im Code) holen sich den neuen Pinsel automatisch.
    foreach ($k in @($pal.Keys)) {
        # .psobject.BaseObject: New-Object liefert ein PowerShell-Huellobjekt - WPF braucht den echten Brush
        try { $nb = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k])); $nb.Freeze(); $Win.Resources[$k] = $nb.psobject.BaseObject } catch { }
    }
    $Script:IsDark = $dark
    Set-TitleBarDark $dark
}
function Save-AppSettings {
    try {
        $d = Split-Path $AppSettingsFile; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        [ordered]@{ Darstellung = $Script:ThemeMode } | ConvertTo-Json | Out-File -LiteralPath $AppSettingsFile -Encoding utf8
    } catch { }
}
try { if (Test-Path -LiteralPath $AppSettingsFile) { $st = Get-Content -LiteralPath $AppSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$st.Darstellung -in 'Auto', 'Hell', 'Dunkel') { $Script:ThemeMode = [string]$st.Darstellung } } } catch { }
Apply-Theme
# Einstellungen: Auswahl anzeigen und umschalten
if ($HighContrast) {
    foreach ($n in 'OptThemeAuto', 'OptThemeLight', 'OptThemeDark') { $UI[$n].IsEnabled = $false }
    $UI.ThemeNote.Text = 'Windows nutzt gerade ein Kontrastdesign – WinTidy übernimmt dessen Farben.'
} else {
    $UI[$(switch ($Script:ThemeMode) { 'Hell' { 'OptThemeLight' } 'Dunkel' { 'OptThemeDark' } default { 'OptThemeAuto' } })].IsChecked = $true
}
foreach ($pair in @(@('OptThemeAuto', 'Auto'), @('OptThemeLight', 'Hell'), @('OptThemeDark', 'Dunkel'))) {
    $UI[$pair[0]].Tag = $pair[1]
    $UI[$pair[0]].Add_Checked({ param($s, $e) if ($Script:ThemeMode -ne [string]$s.Tag) { $Script:ThemeMode = [string]$s.Tag; Apply-Theme; Save-AppSettings } })
}
$Win.Add_SourceInitialized({ Set-TitleBarDark $Script:IsDark })
# "Wie Windows": Wechsel in Windows auch bei offenem Fenster uebernehmen
$ThemeTimer = New-Object System.Windows.Threading.DispatcherTimer
$ThemeTimer.Interval = [TimeSpan]::FromSeconds(5)
$ThemeTimer.Add_Tick({ try { if ($Script:ThemeMode -eq 'Auto' -and (Get-WindowsDarkMode) -ne $Script:IsDark) { Apply-Theme } } catch { } })
if (-not $HighContrast) { $ThemeTimer.Start() }
function Fmt-Bytes([double]$b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } elseif ($b -gt 0) { '{0:N0} KB' -f ($b / 1KB) } else { '' } }
function Fmt-Num($v, [int]$dec = 0) { if ($null -eq $v -or "$v" -eq '') { return '–' }; try { return ("{0:N$dec}" -f [double]$v) } catch { return "$v" } }
function Plural([int]$n, [string]$one, [string]$many) { if ($n -eq 1) { "1 $one" } else { "$n $many" } }
function New-Tb([string]$text, [string]$fg = 'Text', [double]$size = 14, [string]$weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $t.TextWrapping = 'Wrap'; Set-Brush $t 'Foreground' $fg; $t.FontSize = $size; $t.FontWeight = $weight; $t
}
function New-Icon([int]$code, [string]$fg = 'Accent', [double]$size = 16) {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string][char]$code; $t.FontFamily = 'Segoe MDL2 Assets'; $t.FontSize = $size; Set-Brush $t 'Foreground' $fg; $t.Focusable = $false; $t
}
function Set-A11y($el, [string]$name, [string]$help = '') {
    try { [System.Windows.Automation.AutomationProperties]::SetName($el, $name); if ($help) { [System.Windows.Automation.AutomationProperties]::SetHelpText($el, $help) } } catch { }
}
function Show-Msg([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') { [System.Windows.MessageBox]::Show($Win, $text, 'WinTidy', $buttons, $icon) }

# =============================================================================
#  Hintergrund-Runspace mit der WinTidy-Engine
# =============================================================================
$Sync = [hashtable]::Synchronized(@{ Log = New-Object System.Collections.Concurrent.ConcurrentQueue[string]; Progress = $null; Selection = $null; Expert = $false; Deep = $false; RestorePoint = $true; OhneRP = $false; Lauf = $null })
$Control = [hashtable]::Synchronized(@{ Cancel = $false })
$RS = [runspacefactory]::CreateRunspace()
$RS.ApartmentState = 'STA'; $RS.ThreadOptions = 'ReuseThread'; $RS.Open()
$RS.SessionStateProxy.SetVariable('Sync', $Sync)
$RS.SessionStateProxy.SetVariable('Control', $Control)
$RS.SessionStateProxy.SetVariable('EnginePath', $EnginePath)
$State = @{ CoolTest = $null; Op = $null; Findings = @(); InfoFindings = @(); Snapshot = $null; ScanTime = $null; History = $null; LastResult = $null; Busy = $false; Version = ''; DataDir = $null; Context = $null; Locked = ''; EngineOk = $false; ForceClose = $false; Narrow = $false; Retry = $null; ErrReport = '' }
$Stopwatch = New-Object System.Diagnostics.Stopwatch

# Kind: init | scan | fix | undo | silent (Hintergrund, ohne Fortschrittsseite)
function Start-Op([string]$Kind, [string]$Script, [scriptblock]$OnDone, [string]$Title = 'Einen Moment …', [string]$Hint = '', [switch]$Silent) {
    if ($State.Busy) { return $false }
    $State.Busy = $true
    $Control.Cancel = $false
    $Sync.Progress = $null
    if (-not $Silent) {
        Set-Nav $false
        $UI.BusyTitle.Text = $Title; $UI.BusyStep.Text = 'Einen Moment bitte.'; $UI.BusyBar.IsIndeterminate = $true; $UI.BusyBar.Value = 0; $UI.BusyLog.Clear()
        $UI.BusyHint.Text = $Hint
        $UI.BusyCount.Text = ''; $UI.BusyElapsed.Text = ''; $UI.BusyUninstall.Visibility = 'Collapsed'
        $UI.BtnCancel.IsEnabled = ($Kind -eq 'scan' -or $Kind -eq 'fix' -or $Kind -eq 'cooltest'); $UI.BtnCancel.Visibility = $(if ($UI.BtnCancel.IsEnabled) { 'Visible' } else { 'Collapsed' }); $UI.CancelNote.Text = ''
        Show-Page 'PageBusy'
        $Stopwatch.Restart()
    }
    $ps = [powershell]::Create(); $ps.Runspace = $RS
    [void]$ps.AddScript($Script, $false)
    $State.Op = @{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Kind = $Kind; Silent = [bool]$Silent; Cancelled = $false }
    $Timer.Start()
    return $true
}

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$Timer.Add_Tick({
    try {
        $line = $null; $added = $false
        while ($Sync.Log.TryDequeue([ref]$line)) { $UI.BusyLog.AppendText($line + "`r`n"); $added = $true }
        if ($added) { $UI.BusyLog.ScrollToEnd() }
        $op = $State.Op
        if ($op -and -not $op.Silent) {
            $p = $Sync.Progress
            if ($p) {
                if ($p.N -gt 0) { $UI.BusyBar.IsIndeterminate = $false; $UI.BusyBar.Value = [math]::Min(97, 100 * $p.I / $p.N); $UI.BusyCount.Text = $(if ($op.Kind -eq 'cooltest' -or $p.Id -eq 'CORE' -or $p.I -lt 1) { '' } else { 'Schritt {0} von {1}' -f $p.I, $p.N }) }
                if ($p.Text) { $UI.BusyStep.Text = [string]$p.Text }
                $uninst = ($p.Id -eq 'APP-SIDEBYSIDE') -or ($op.Kind -eq 'fix' -and [string]$p.Text -match '(?i)deinstall|doppelt installiert')
                $UI.BusyUninstall.Visibility = $(if ($uninst) { 'Visible' } else { 'Collapsed' })
            }
            $e = $Stopwatch.Elapsed
            $UI.BusyElapsed.Text = ('Läuft seit {0}:{1:00} Min.' -f [int][math]::Floor($e.TotalMinutes), $e.Seconds)
        }
        if ($op -and $op.Handle.IsCompleted) { Complete-Op $op }
        elseif (-not $op) { $Timer.Stop() }
    } catch { Write-ErrLog "Timer: $($_.Exception.Message) $($_.ScriptStackTrace)" }
})
function Complete-Op($op) {
    $State.Op = $null
    $res = $null; $err = $null
    try { $res = $op.PS.EndInvoke($op.Handle) } catch { $err = $_.Exception.Message }
    if ($op.PS.Streams.Error.Count) {
        $op.PS.Streams.Error | ForEach-Object { Write-ErrLog ("[$($op.Kind)] " + $_.ToString()) }
        if (-not $err -and -not $res) { $err = (($op.PS.Streams.Error | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join "`n") }
    }
    $cancelled = [bool]$op.Cancelled
    try { $op.PS.Dispose() } catch { }
    $Stopwatch.Stop()
    $State.Busy = $false
    if (-not $op.Silent) { Set-Nav $true }
    $r = @($res) | Select-Object -Last 1
    try { & $op.OnDone $r $err $cancelled }
    catch {
        Write-ErrLog "OnDone($($op.Kind)): $($_.Exception.Message) $($_.ScriptStackTrace)"
        Show-ErrorPage 'Die Ergebnisse konnten nicht angezeigt werden' 'Die Arbeit selbst ist abgeschlossen. Was passiert ist, steht im Verlauf und im ausführlichen Bericht.' $_.Exception.Message $null
    }
    # Verlauf nachladen, wenn er waehrend des Vorgangs angefordert wurde
    if ($State.HistoryPending -and -not $State.Busy -and $UI.PageHistory.Visibility -eq 'Visible') { $State.HistoryPending = $false; try { Load-History } catch { } }
}

# =============================================================================
#  Navigation, Seiten, Layout
# =============================================================================
$Pages = 'PageHome', 'PageRecs', 'PageBusy', 'PageResult', 'PageError', 'PageHistory', 'PageSettings', 'PageHelp'
$NavItems = 'NavHome', 'NavRecs', 'NavHistory', 'NavSettings', 'NavHelp'
# Laeuft gerade etwas (auch unsichtbar, z. B. Laden)? Dann Bescheid sagen statt still nichts zu tun.
# Dateien (Bericht) ueber den Explorer oeffnen, damit der Browser nicht mit Adminrechten startet
function Open-AsUser([string]$Path) { try { Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList ('"{0}"' -f $Path) } catch { try { Start-Process -FilePath $Path } catch { } } }
function Test-Busy { if ($State.Busy) { Show-Msg 'WinTidy ist gerade noch beschäftigt. Bitte versuch es in ein paar Sekunden noch einmal.' | Out-Null; return $true }; return $false }
function Show-Page([string]$name) { foreach ($p in $Pages) { $UI[$p].Visibility = $(if ($p -eq $name) { 'Visible' } else { 'Collapsed' }) } }
function Set-Nav([bool]$on) { foreach ($n in $NavItems) { $UI[$n].IsEnabled = $on } }
function Clear-NavSelection { foreach ($n in $NavItems) { $UI[$n].IsChecked = $false } }
$UI.NavHome.Add_Checked({ Show-Page 'PageHome' })
$UI.NavRecs.Add_Checked({ Show-Page 'PageRecs' })
$UI.NavHistory.Add_Checked({ Show-Page 'PageHistory'; Load-History })
$UI.NavSettings.Add_Checked({ Show-Page 'PageSettings' })
$UI.NavHelp.Add_Checked({ Show-Page 'PageHelp' })
function Go([string]$nav) { if ($UI[$nav].IsChecked) { $UI[$nav].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent))) } else { $UI[$nav].IsChecked = $true } }

function Set-Narrow([bool]$narrow) {
    if ($State.Narrow -eq $narrow) { return }
    $State.Narrow = $narrow
    $vis = $(if ($narrow) { 'Collapsed' } else { 'Visible' })
    $UI.NavCol.Width = New-Object System.Windows.GridLength ($(if ($narrow) { 84 } else { 232 }))
    $UI.NavDock.Margin = $(if ($narrow) { '10,22,10,16' } else { '16,22,16,16' })
    foreach ($n in 'BrandText', 'NavT1', 'NavT2', 'NavT3', 'NavT4', 'NavT5', 'VersionText') { $UI[$n].Visibility = $vis }
}
# Fenster nie groesser als die Arbeitsflaeche (Laptops mit Skalierung)
$Win.Add_SourceInitialized({
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        if ($Win.Height -gt $wa.Height) { $Win.Height = $wa.Height; $Win.Top = $wa.Top }
        if ($Win.Width -gt $wa.Width) { $Win.Width = $wa.Width; $Win.Left = $wa.Left }
        if ($Win.MinHeight -gt $wa.Height) { $Win.MinHeight = $wa.Height }
        if ($Win.MinWidth -gt $wa.Width) { $Win.MinWidth = $wa.Width }
    } catch { Write-ErrLog "WorkArea: $($_.Exception.Message)" }
})
$Win.Add_SizeChanged({ Set-Narrow ($Win.ActualWidth -lt 1000) })

# =============================================================================
#  Hinweis-Banner (Adminrechte, Firmen-PC, Akku, Neustart, anderes Konto)
# =============================================================================
function Restart-Elevated {
    if ($State.Busy) { return }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$AppPath`"", '-NoElevate', '-Restarted') -ErrorAction Stop
        $State.ForceClose = $true
        $Win.Close()
    } catch { Show-Msg 'Windows hat keine Administratorrechte erteilt. WinTidy läuft weiter eingeschränkt (nur Prüfen).' | Out-Null }
}
function Add-Banner([string]$text, [string]$kind = 'warn', [string]$button = '', [scriptblock]$action = $null) {
    $b = New-Object System.Windows.Controls.Border; $b.CornerRadius = 10; $b.Padding = '14,10'; $b.Margin = '0,0,0,8'; $b.BorderThickness = 1; Set-Brush $b 'BorderBrush' 'Line'
    Set-Brush $b 'Background' $(if ($kind -eq 'info') { 'InfoBg' } elseif ($kind -eq 'bad') { 'HighBg' } else { 'MidBg' })
    $dp = New-Object System.Windows.Controls.DockPanel
    if ($button) {
        $btn = New-Object System.Windows.Controls.Button; $btn.Style = $Win.FindResource('Secondary'); $btn.Content = $button; $btn.Padding = '12,6'; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
        if ($action) { $btn.Add_Click($action) }
        [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right'); [void]$dp.Children.Add($btn)
    }
    $fg = if ($kind -eq 'info') { 'InfoFg' } elseif ($kind -eq 'bad') { 'HighFg' } else { 'MidFg' }
    $ic = New-Icon $(if ($kind -eq 'info') { 0xE946 } elseif ($kind -eq 'bad') { 0xEA39 } else { 0xE7BA }) $fg 16; $ic.Margin = '0,1,10,0'; $ic.VerticalAlignment = 'Top'
    [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left'); [void]$dp.Children.Add($ic)
    $t = New-Tb $text $fg 13; $t.VerticalAlignment = 'Center'; [void]$dp.Children.Add($t)
    $b.Child = $dp; Set-A11y $b $text
    [void]$UI.BannerPanel.Children.Add($b)
}
function Update-Banners {
    $UI.BannerPanel.Children.Clear()
    if (-not $IsAdmin) {
        $txt = 'WinTidy läuft ohne Administratorrechte. Prüfen geht nur eingeschränkt, Änderungen sind nicht möglich.'
        if ($NetDriveProblem) { $txt += ' WinTidy liegt auf einem Netzlaufwerk – bitte zuerst auf diesen PC kopieren.'; Add-Banner $txt }
        else { Add-Banner $txt 'warn' 'Mit Administratorrechten neu starten' { Restart-Elevated } }
    }
    $c = $State.Context
    if ($c) {
        $hs = @($c.Hinweise | Where-Object { $_ })
        if ($hs.Count) { foreach ($h in $hs) { Add-Banner ([string]$h) } }
        else {
            if ($c.Server) { Add-Banner 'Windows Server erkannt: WinTidy prüft hier nur, Änderungen sind gesperrt.' }
            if ($c.Verwaltet) { Add-Banner 'Firmen-PC erkannt: WinTidy zeigt nur sichere Aufräum-Punkte. Bei Fragen wende dich bitte an deine IT-Abteilung.' }
            if ($c.AnderesKonto) { Add-Banner ("WinTidy läuft unter dem Konto {0}, angemeldet ist aber {1}. Programme im Autostart, temporäre Dateien und Apps von {1} werden deshalb nicht geprüft." -f $c.ProzessBenutzer, $c.SitzungsBenutzer) }
            if ($c.NeustartAusstehend) { Add-Banner 'Windows möchte nach Updates neu starten. Am besten startest du den PC zuerst neu und prüfst danach – dann sind die Ergebnisse genauer.' 'info' }
            if ($c.Akku) { Add-Banner 'Der PC läuft gerade auf Akku. Bitte das Netzteil anschließen – lange Schritte werden sonst übersprungen.' 'info' }
        }
        $State.Locked = $(if ($c.Server) { 'Auf Windows Server prüft WinTidy nur. Änderungen sind gesperrt.' } else { '' })
    }
    # Drohender Datenverlust gehoert ganz nach oben, nicht in die Karte fuer Fachleute
    $krit = @(@($State.Findings) + @($State.InfoFindings) | Where-Object { $_ -and "$($_.Id)" -eq 'HW-COOLING' } | ForEach-Object { @($_.Items) } | Where-Object { (Get-ItemLevel $_) -eq 'krit' -and (Get-ItemArea $_) -in 'Laufwerke', 'Speicher' -and (Get-ItemRating $_) -ne 'moment' })
    if ($krit.Count) { Add-Banner ('Wichtig: Dein PC meldet ein Problem mit einem Laufwerk oder dem Arbeitsspeicher. Sichere deine Fotos und Dokumente bald auf einen USB-Stick oder in die Cloud und lass den PC prüfen. (' + [string]$krit[0].Label + ')') 'bad' }
    $UI.BannerPanel.Visibility = $(if ($UI.BannerPanel.Children.Count) { 'Visible' } else { 'Collapsed' })
}
$UI.BtnElevate2.Add_Click({ Restart-Elevated })

# =============================================================================
#  Übersicht
# =============================================================================
function Set-Score([int]$score) {
    $UI.ScoreText.Text = "$score"
    Set-Brush $UI.ScoreArc 'Stroke' $(if ($score -ge 85) { 'Good' } elseif ($score -ge 65) { 'Warn' } else { 'Bad' })
    $r = 78; $cx = 85; $cy = 85
    $ang = [math]::Min(359.99, [math]::Max(0.5, 360 * $score / 100))
    $rad = ($ang - 90) * [math]::PI / 180
    $end = New-Object System.Windows.Point ($cx + $r * [math]::Cos($rad)), ($cy + $r * [math]::Sin($rad))
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = New-Object System.Windows.Point $cx, ($cy - $r)
    $arc = New-Object System.Windows.Media.ArcSegment
    $arc.Point = $end; $arc.Size = New-Object System.Windows.Size $r, $r; $arc.IsLargeArc = ($ang -gt 180); $arc.SweepDirection = 'Clockwise'
    [void]$fig.Segments.Add($arc)
    $geo = New-Object System.Windows.Media.PathGeometry; [void]$geo.Figures.Add($fig)
    $UI.ScoreArc.Data = $geo
    if ($score -ge 85) { $UI.ScoreHeadline.Text = 'Dein PC ist in gutem Zustand' }
    elseif ($score -ge 65) { $UI.ScoreHeadline.Text = 'Dein PC läuft – es gibt aber einiges zu verbessern' }
    else { $UI.ScoreHeadline.Text = 'Dein PC braucht etwas Pflege' }
    Set-A11y $UI.ScoreText ("Gesundheitswert {0} von 100" -f $score)
}
function New-Kpi([string]$label, [string]$value, [string]$note) {
    $b = New-Object System.Windows.Controls.Border; $b.Style = $Win.FindResource('Card'); $b.Margin = '7,0,7,0'; $b.Padding = '18,16'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t2 = New-Tb $value 'Ink' 26 'SemiBold'; $t2.Margin = '0,4,0,2'
    [void]$sp.Children.Add((New-Tb $label 'Muted' 12)); [void]$sp.Children.Add($t2); [void]$sp.Children.Add((New-Tb $note 'Muted' 12))
    $b.Child = $sp; Set-A11y $b "$label $value $note"; $b
}
function Get-Group($f) {
    if ($f.Gruppe) { return [string]$f.Gruppe }
    if ("$($f.Id)" -like 'HW-*') { return 'Hardware' }
    switch ("$($f.Kategorie)") { 'Speicher' { 'Aufräumen' } 'Autostart' { 'Schneller starten' } 'Aufgaben' { 'Aufräumen' } 'Dienste' { 'Aufräumen' } 'Programme' { 'Programme' } 'System' { 'Windows pflegen' } 'Sicherheit' { 'Sicherheit' } 'Hardware' { 'Hardware' } default { 'Hinweise' } }
}
function Get-ItemLevel($it) {
    foreach ($v in @($it.Stufe, $it.Raw.Stufe, $it.Raw.Data.Stufe)) { if ($v) { return ([string]$v).ToLower() } }
    return ''
}
function Get-ItemArea($it) { foreach ($v in @($it.Bereich, $it.Raw.Data.Bereich)) { if ($v) { return [string]$v } }; return '' }
function Get-ItemRating($it) { foreach ($v in @($it.Wertung, $it.Raw.Data.Wertung)) { if ($v) { return [string]$v } }; return '' }
# Info-Befunde aus dem letzten Snapshot (wenn seit dem App-Start noch nicht geprueft wurde)
function Get-InfoFromSnapshot($s) {
    @(foreach ($b in @($s.Befunde)) {
        if ($b -and $b.Risiko -eq 'Info') {
            $obj = @($b.Objekte); $st = @($b.Stufen); $be = @($b.Bereiche); $we = @($b.Wertungen)
            $titel = if ($State.Friendly -and $State.Friendly[[string]$b.Regel]) { [string]$State.Friendly[[string]$b.Regel][0] } else { [string]$b.Titel }
            $items = @(for ($i = 0; $i -lt $obj.Count; $i++) { [pscustomobject]@{ Label = [string]$obj[$i]; Stufe = $(if ($i -lt $st.Count) { [string]$st[$i] } else { '' }); Bereich = $(if ($i -lt $be.Count) { [string]$be[$i] } else { '' }); Wertung = $(if ($i -lt $we.Count) { [string]$we[$i] } else { '' }) } })
            [pscustomobject]@{ Id = $b.Regel; Kategorie = $b.Kategorie; Titel = $titel; Fixbar = $false; Gruppe = $null; Items = $items }
        }
    })
}
function Add-InfoRow($panel, $f, $it, [switch]$NoTitle) {
    $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,10'
    $lvl = Get-ItemLevel $it
    $code = 0xE946; $col = 'Accent'
    if ($lvl -eq 'ok') { $code = 0xE73E; $col = 'Good' }
    elseif ($lvl -match 'krit|fehler|bad') { $code = 0xEA39; $col = 'Bad' }
    elseif ($lvl -match 'warn') { $code = 0xE7BA; $col = 'Warn' }
    elseif ("$($f.Id)" -eq 'SEC-CHECKS') { $code = 0xE72E; $col = 'Warn' }
    elseif ("$($f.Id)" -eq 'EVT-HEALTH') { $code = 0xE7BA; $col = 'Warn' }
    elseif ((Get-Group $f) -eq 'Hardware') { $code = 0xE82F }   # Gluehbirne = Hinweis (E950 sah aus wie ein leeres Kaestchen)
    $ic = New-Icon $code $col 16; $ic.Margin = '0,2,12,0'
    [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
    $tx = New-Object System.Windows.Controls.TextBlock; $tx.TextWrapping = 'Wrap'; Set-Brush $tx 'Foreground' 'Text'
    $vor = if ($lvl -match 'krit') { 'Wichtig: ' } else { '' }
    if (-not $NoTitle) { $r1 = New-Object System.Windows.Documents.Run ([string]$f.Titel + ': '); $r1.FontWeight = 'SemiBold'; $tx.Inlines.Add($r1) }
    if ($vor) { $r0 = New-Object System.Windows.Documents.Run $vor; $r0.FontWeight = 'SemiBold'; $tx.Inlines.Add($r0) }
    $tx.Inlines.Add((New-Object System.Windows.Documents.Run ([string]$it.Label)))
    [void]$row.Children.Add($ic); [void]$row.Children.Add($tx)
    Set-A11y $row ("{0}{1}: {2}" -f $(if ($lvl -match 'krit') { 'Kritisch, ' } elseif ($lvl -match 'warn') { 'Warnung, ' } elseif ($lvl -eq 'ok') { 'In Ordnung, ' } else { '' }), $f.Titel, $it.Label)
    [void]$panel.Children.Add($row)
}
function Update-Home {
    $s = $State.Snapshot
    $UI.KpiGrid.Children.Clear()
    if ($s) {
        Set-Score ([int]$s.Score.Wert)
        $fix = @($State.Findings | Where-Object Fixbar)
        $cnt = [int](@($fix | ForEach-Object { @($_.Items).Count }) | Measure-Object -Sum).Sum
        if ($State.Findings.Count -or $State.ScanTime) {
            $UI.ScoreDetail.Text = $(if ($cnt) { "WinTidy hat $(Plural $cnt 'mögliche Verbesserung' 'mögliche Verbesserungen') gefunden. Sieh sie dir in Ruhe an – nichts passiert ohne deine Zustimmung." } elseif ([int]$s.Score.Wert -ge 85) { 'Alles in Ordnung – es gibt nichts aufzuräumen.' } else { 'WinTidy kann hier nichts automatisch verbessern. Unter "Warum nicht 100?" und "Gut zu wissen" steht, was sonst noch hilft.' })
        }
        $UI.BtnScan.Content = '_Erneut prüfen'
        $UI.BtnToRecs.Visibility = $(if ($cnt) { 'Visible' } else { 'Collapsed' })
        $UI.LastScanText.Text = 'Zuletzt geprüft: ' + ([datetime]$s.Zeit).ToString('dd.MM.yyyy, HH:mm') + ' Uhr'
        $UI.ScoreLimited.Visibility = $(if ($s.Admin -eq $false) { 'Visible' } else { 'Collapsed' })
        # Warum nicht 100?
        $UI.ScoreWhyList.Children.Clear()
        foreach ($z in @($s.Score.Abzuege)) {
            if (-not $z) { continue }
            $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,4'
            $p = New-Tb ('−{0}' -f $z.Punkte) 'Bad' 14 'SemiBold'; $p.Width = 44; [System.Windows.Controls.DockPanel]::SetDock($p, 'Left')
            [void]$row.Children.Add($p); [void]$row.Children.Add((New-Tb ([string]$z.Grund) 'Text' 14))
            [void]$UI.ScoreWhyList.Children.Add($row)
        }
        $UI.ScoreWhy.Visibility = $(if ($UI.ScoreWhyList.Children.Count) { 'Visible' } else { 'Collapsed' })
        # Kennzahlen
        $sys = @($s.Laufwerke) | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
        $boot = if ($s.Boot.Mittel5) { '{0:N0} s' -f ($s.Boot.Mittel5 / 1000) } else { '–' }
        $bootNote = if ($s.Boot.Mittel5) { if ($s.Boot.Mittel5 -gt 60000) { 'eher langsam' } elseif ($s.Boot.Mittel5 -gt 35000) { 'im Mittelfeld' } else { 'schnell' } } else { 'wird mit Adminrechten gemessen' }
        [void]$UI.KpiGrid.Children.Add((New-Kpi 'Windows-Start (Durchschnitt)' $boot $bootNote))
        [void]$UI.KpiGrid.Children.Add((New-Kpi "Frei auf Laufwerk $($env:SystemDrive)" $(if ($sys) { '{0:N0} GB' -f [double]$sys.FreiGB } else { '–' }) $(if ($sys) { '{0:N0} % von {1:N0} GB' -f [double]$sys.FreiProzent, [double]$sys.GroesseGB } else { '' })))
        [void]$UI.KpiGrid.Children.Add((New-Kpi 'Programme im Autostart' ('{0:N0}' -f [double]$s.Autostart.Aktiv) $(if ($s.Autostart.Aktiv -gt 10) { 'viele – bremst den Start' } else { 'in Ordnung' })))
        $bytes = ($fix | Measure-Object Bytes -Sum).Sum
        [void]$UI.KpiGrid.Children.Add((New-Kpi 'Möglicher Platzgewinn' $(if ($bytes) { Fmt-Bytes $bytes } else { '–' }) $(if ($fix.Count) { 'geschätzt' } else { 'nach der Prüfung' })))
        $UI.HomeSub.Text = 'Hier siehst du auf einen Blick, wie es deinem PC geht.'
    }
    # Hinweise und Hardware (nicht automatisch loesbar)
    $UI.HintsPanel.Children.Clear(); $UI.HwPanel.Children.Clear()
    $info = @($State.Findings | Where-Object { -not $_.Fixbar })
    if (-not $info.Count) { $info = @($State.InfoFindings) }
    foreach ($f in $info) {
        if ((Get-Group $f) -eq 'Hardware') {
            $h = New-Tb ([string]$f.Titel) 'Ink' 14 'SemiBold'; $h.Margin = '0,6,0,6'; [void]$UI.HwPanel.Children.Add($h)
            foreach ($it in @($f.Items)) { if ($it) { Add-InfoRow $UI.HwPanel $f $it -NoTitle } }
        } else { foreach ($it in @($f.Items)) { if ($it) { Add-InfoRow $UI.HintsPanel $f $it } } }
    }
    $schlimm = @($info | Where-Object { (Get-Group $_) -eq 'Hardware' } | ForEach-Object { @($_.Items) } | Where-Object { (Get-ItemLevel $_) -in 'warn', 'krit' })
    if ($schlimm.Count) { $wt = New-Tb 'Was tun? Bei Warnungen zur Kühlung hilft meist, den PC von innen von Staub zu befreien und die Lüfter prüfen zu lassen. WinTidy selbst ändert an der Hardware nichts.' 'Muted' 13; $wt.Margin = '0,6,0,4'; $wt.TextWrapping = 'Wrap'; [void]$UI.HwPanel.Children.Add($wt) }
    $UI.HintsCard.Visibility = $(if ($UI.HintsPanel.Children.Count) { 'Visible' } else { 'Collapsed' })
    Show-CoolTest
    $UI.HwCard.Visibility = $(if ($UI.HwPanel.Children.Count -or $State.CoolTest) { 'Visible' } else { 'Collapsed' })
}

# Kuehlungstest: Ergebnis unter den Hardware-Punkten anzeigen
function Show-CoolTest {
    $UI.CoolTestPanel.Children.Clear()
    $r = $State.CoolTest
    if (-not $r) { return }
    $zeit = ''; try { $zeit = ([datetime]$r.Zeit).ToString('dd.MM.yyyy, HH:mm') + ' Uhr' } catch { }
    $f = [pscustomobject]@{ Id = 'HW-COOLTEST'; Kategorie = 'Hardware'; Titel = ('Kühlungstest ' + $zeit).Trim() }
    foreach ($p in @($r.Punkte | Where-Object { $_ })) { Add-InfoRow $UI.CoolTestPanel $f ([pscustomobject]@{ Label = [string]$p.Text; Stufe = [string]$p.Stufe }) }
}
function Start-CoolTest {
    if (Test-Busy) { return }
    $c = $State.Context
    if ($c -and $c.Akku) { Show-Msg 'Der Kühlungstest geht nur mit angeschlossenem Netzteil. Bitte das Netzteil anschließen und es dann noch einmal versuchen.' | Out-Null; return }
    if ($c -and ($c.Server -or $c.VM)) { Show-Msg 'Auf Servern und in virtuellen Maschinen ist der Kühlungstest nicht sinnvoll und deshalb gesperrt.' | Out-Null; return }
    $q = "Kühlungstest starten?`n`nWinTidy belastet etwa eine Minute lang alle Prozessorkerne voll und beobachtet dabei Leistung, Temperatur und – falls ein Programm wie LibreHardwareMonitor läuft – die Lüfter.`n`nDie Lüfter werden hörbar lauter. Der PC bleibt bedienbar, wird aber langsamer. Am besten andere Programme vorher schließen. Am Ende ändert WinTidy nichts.$(if ($c -and $c.Laptop) { "`n`nBei Laptops: Lüftungsschlitze frei lassen – nicht auf Schoß, Bett oder Sofa." })`n`nJetzt starten?"
    if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
    [void](Start-Op 'cooltest' @'
if (Get-Command Invoke-GuiCoolingTest -ErrorAction SilentlyContinue) { Invoke-GuiCoolingTest 0 { param($i, $n, $t, $id) $Sync.Progress = @{ I = $i; N = $n; Text = $t; Id = $id } } $Control }
else { [pscustomobject]@{ Status = 'FEHLT'; Meldung = 'Diese WinTidy-Version kann den Kühlungstest noch nicht.'; Punkte = @() } }
'@ {
        param($r, $err, $cancelled)
        Go 'NavHome'
        if (-not $r) { Show-ErrorPage 'Der Kühlungstest hat nicht geklappt' 'Am PC wurde nichts verändert. Du kannst den Test später noch einmal starten.' $err $null; return }
        if ($r.Status -in 'AKKU', 'FEHLT', 'GESPERRT') { Show-Msg ([string]$r.Meldung) | Out-Null; return }
        $pts = @($r.Punkte | Where-Object { $_ })
        if ($r.Status -eq 'ABGEBROCHEN') { Show-Msg 'Der Kühlungstest wurde abgebrochen. Es wurde nichts gespeichert und nichts verändert.' | Out-Null; return }
        $State.CoolTest = $r
        Update-Home
        $kopf = if ($r.Status -eq 'GESTOPPT') { 'Der Test wurde zur Sicherheit vorzeitig beendet.' }
                elseif ($pts | Where-Object { $_.Stufe -eq 'krit' }) { 'Die Kühlung reicht unter Last nicht aus. Lass den PC reinigen und die Lüfter prüfen.' }
                elseif ($pts | Where-Object { $_.Stufe -eq 'warn' }) { 'Die Kühlung kommt an ihre Grenze. Lass den PC bei Gelegenheit reinigen und die Lüfter prüfen.' }
                elseif (-not ($pts | Where-Object { $_.Stufe -eq 'ok' })) { 'Der Test ist durchgelaufen. Auf diesem PC ließ sich aber nicht genug messen, um die Kühlung sicher zu bewerten.' }
                else { 'Die Kühlung hält unter Last mit.' }
        $lines = @($pts | ForEach-Object { $sym = switch ($_.Stufe) { 'ok' { '✓' } 'warn' { '!' } 'krit' { '✗' } default { '•' } }; '{0}  {1}' -f $sym, $_.Text })
        $icon = if ($pts | Where-Object { $_.Stufe -eq 'krit' }) { 'Warning' } else { 'Information' }
        Show-Msg ($kopf + "`n`n" + ($lines -join "`n") + "`n`nDas Ergebnis steht auch auf der Übersicht unter Hardware.") 'OK' $icon | Out-Null
    } 'Kühlungstest läuft …' 'Die Lüfter werden jetzt lauter – das ist gewollt. Der Test dauert etwa eine Minute.')
}
$UI.BtnCoolTest.Add_Click({ Start-CoolTest })

# =============================================================================
#  Empfehlungen
# =============================================================================
$GroupOrder = @('Aufräumen', 'Schneller starten', 'Windows pflegen', 'Programme', 'Sicherheit', 'Hinweise', 'Hardware')
$RiskUi = @{
    'Niedrig' = @('Sicher', 'LowBg', 'LowFg')
    'Mittel'  = @('Kurz prüfen', 'MidBg', 'MidFg')
    'Hoch'    = @('Nur für Profis', 'HighBg', 'HighFg')
}
$EndgueltigIds = 'CLN-TEMP', 'CLN-WINCLEAN', 'CLN-WINOLD', 'CLN-WINSXS', 'CLN-DUMPS', 'CLN-RECYCLE', 'CLN-RECYCLE-ORPHAN', 'CLN-DRIVERSTORE', 'CLN-ORPHANDIR', 'APP-SIDEBYSIDE', 'APP-BLOAT', 'APP-UPDATES', 'SYS-GHOST'
function Test-Endgueltig($f) { if ($null -ne $f.Endgueltig) { return [bool]$f.Endgueltig }; return ($EndgueltigIds -contains $f.Id) }
function Test-Umkehrbar($f) { if ($null -ne $f.Umkehrbar) { return [bool]$f.Umkehrbar }; return ("$($f.Id)" -match '^(STA|TSK|SVC)-|^SYS-GAMEDVR$') }
function Test-Einzeln($f) { return ([bool]$f.Einzeln -or $f.Risiko -eq 'Hoch') }
function Get-CleanWhy([string]$t) {
    # Kommandozeilen-Hinweise (-Rule, -Yes, -Deep) gehoeren nicht in die App
    (($t -split '(?<=[\.\!\?])\s+') | Where-Object { $_ -notmatch '(^|\s|\()-(Rule|Yes|Deep|IncludeMedium|NoRestorePoint)\b' }) -join ' '
}

function Update-SelSummary {
    $n = 0; $b = 0
    foreach ($f in $State.Findings) { foreach ($it in @($f.Items)) { if ($it.Selected) { $n++; $b += $it.Bytes } } }
    $UI.SelSummary.Text = if ($n) { ('{0} ausgewählt' -f (Plural $n 'Änderung' 'Änderungen')) + $(if ($b) { " · ca. $(Fmt-Bytes $b) Platz" } else { '' }) } else { 'Nichts ausgewählt' }
    $UI.BtnApply.IsEnabled = ($n -gt 0 -and $IsAdmin -and -not $State.Locked)
    $UI.BtnElevate2.Visibility = $(if ($IsAdmin -or $NetDriveProblem) { 'Collapsed' } else { 'Visible' })
    $UI.SelNote.Text = if (-not $IsAdmin) { 'Zum Umsetzen braucht WinTidy Administratorrechte.' } elseif ($State.Locked) { $State.Locked } elseif ($UI.OptRestorePoint.IsChecked) { 'Vorher wird ein Wiederherstellungspunkt angelegt. Jede Änderung wird protokolliert.' } else { 'Achtung: Es wird kein Wiederherstellungspunkt angelegt (siehe Einstellungen).' }
    $total = [int](@($State.Findings | Where-Object Fixbar | ForEach-Object { @($_.Items).Count }) | Measure-Object -Sum).Sum
    if ($total) { $UI.RecsBadge.Visibility = 'Visible'; $UI.RecsBadgeText.Text = "$total" } else { $UI.RecsBadge.Visibility = 'Collapsed' }
    Set-A11y $UI.BtnApply ('Ausgewählte umsetzen: ' + $UI.SelSummary.Text)
}
function New-Badge([string]$risk) {
    $m = $RiskUi[$risk]; if (-not $m) { return $null }
    $b = New-Object System.Windows.Controls.Border; $b.CornerRadius = 8; $b.Padding = '8,2'; Set-Brush $b 'Background' $m[1]; $b.Margin = '10,0,0,0'; $b.VerticalAlignment = 'Center'; $b.BorderThickness = 1; Set-Brush $b 'BorderBrush' 'Line'
    $b.Child = (New-Tb $m[0] $m[2] 12); $b
}
function New-RecCard($f) {
    $einzeln = Test-Einzeln $f
    $gesperrt = [string]$f.Gesperrt
    $expert = [bool]$UI.OptExpert.IsChecked
    $riskName = $(if ($RiskUi[$f.Risiko]) { $RiskUi[$f.Risiko][0] } else { '' })
    $card = New-Object System.Windows.Controls.Border; $card.Style = $Win.FindResource('Card'); $card.Padding = '20,16'
    $outer = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.DockPanel
    $cb = $null
    if (-not $einzeln) {
        $cb = New-Object System.Windows.Controls.CheckBox; $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,12,0'; $cb.IsThreeState = $false; $cb.IsEnabled = (-not $gesperrt)
        Set-A11y $cb ("{0} – {1} – alle Einträge auswählen" -f $f.Titel, $riskName) ([string]$f.Text)
        [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left'); [void]$head.Children.Add($cb)
    } else {
        $sp0 = New-Object System.Windows.Controls.Border; $sp0.Width = 28; [System.Windows.Controls.DockPanel]::SetDock($sp0, 'Left'); [void]$head.Children.Add($sp0)
    }
    $size = New-Tb (Fmt-Bytes $f.Bytes) 'Link' 14 'SemiBold'; $size.VerticalAlignment = 'Center'; $size.Margin = '12,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($size, 'Right'); [void]$head.Children.Add($size)
    $titleRow = New-Object System.Windows.Controls.WrapPanel
    $tt = New-Tb ([string]$f.Titel) 'Ink' 16 'SemiBold'; $tt.VerticalAlignment = 'Center'
    [void]$titleRow.Children.Add($tt); $bd = New-Badge $f.Risiko; if ($bd) { [void]$titleRow.Children.Add($bd) }
    if ($einzeln) { $en = New-Tb 'jeden Eintrag einzeln auswählen' 'Muted' 12; $en.Margin = '10,0,0,0'; $en.VerticalAlignment = 'Center'; [void]$titleRow.Children.Add($en) }
    [void]$head.Children.Add($titleRow)
    [void]$outer.Children.Add($head)
    $desc = New-Tb ([string]$f.Text) 'Text2' 14; $desc.Margin = '32,6,0,0'; [void]$outer.Children.Add($desc)
    # Betroffen: bis zu drei Namen direkt nennen
    $labels = @(@($f.Items) | ForEach-Object { $l = [string]$_.Label; if ($l.Length -gt 60) { $l.Substring(0, 57) + '…' } else { $l } })
    if ($labels.Count) {
        $more = $labels.Count - 3
        $nm = New-Tb ('Betrifft: ' + (($labels | Select-Object -First 3) -join ', ') + $(if ($more -gt 0) { " und $more weitere" } else { '' })) 'Muted' 12; $nm.Margin = '32,4,0,0'
        [void]$outer.Children.Add($nm)
    }
    if ($f.Dauer) { $du = New-Tb ('Dauer: ' + [string]$f.Dauer) 'Muted' 12; $du.Margin = '32,2,0,0'; [void]$outer.Children.Add($du) }
    if ($gesperrt) {
        $gp = New-Object System.Windows.Controls.DockPanel; $gp.Margin = '32,6,0,0'
        $gi = New-Icon 0xE72E 'Warn' 13; $gi.Margin = '0,1,8,0'; [System.Windows.Controls.DockPanel]::SetDock($gi, 'Left')
        [void]$gp.Children.Add($gi); [void]$gp.Children.Add((New-Tb ('Gerade nicht möglich: ' + $gesperrt) 'Warn' 13))
        [void]$outer.Children.Add($gp)
    }
    $exp = New-Object System.Windows.Controls.Expander; $exp.Margin = '28,8,0,0'
    $exp.Header = $(if ($einzeln) { "Einträge auswählen ($(@($f.Items).Count))" } elseif (@($f.Items).Count -eq 1) { 'Details' } else { "Details ($(@($f.Items).Count) Einträge)" })
    $exp.IsExpanded = ($einzeln -or $f.Risiko -eq 'Mittel')
    $list = New-Object System.Windows.Controls.StackPanel; $list.Margin = '4,8,0,0'
    $itemBoxes = New-Object System.Collections.ArrayList
    foreach ($it in @($f.Items)) {
        if ($gesperrt) { $it.Selected = $false }
        $ib = New-Object System.Windows.Controls.CheckBox; $ib.Margin = '0,3'; $ib.IsChecked = [bool]$it.Selected; $ib.Tag = $it; $ib.IsEnabled = (-not $gesperrt)
        $ct = New-Object System.Windows.Controls.StackPanel
        [void]$ct.Children.Add((New-Tb ([string]$it.Label + $(if ($it.Bytes) { "   ($(Fmt-Bytes $it.Bytes))" } else { '' })) 'Text' 13))
        if ($expert -and $it.Technik -and [string]$it.Technik -ne [string]$it.Label) { [void]$ct.Children.Add((New-Tb ([string]$it.Technik) 'Muted' 11.5)) }
        $ib.Content = $ct
        Set-A11y $ib ([string]$it.Label) ("{0} – {1}" -f $f.Titel, $riskName)
        $ib.Add_Click({ param($s, $e) $s.Tag.Selected = [bool]$s.IsChecked; Sync-RuleBox $s.Parent; Update-SelSummary })
        [void]$list.Children.Add($ib); [void]$itemBoxes.Add($ib)
    }
    if ($expert -and $f.Warum) {
        $w = Get-CleanWhy ([string]$f.Warum)
        if ($w) { $why = New-Tb "Technisch: $w" 'Muted' 12; $why.Margin = '0,8,0,0'; [void]$list.Children.Add($why) }
    }
    $exp.Content = $list
    $list.Tag = $cb
    if ($cb) {
        $cb.Tag = $itemBoxes
        $cb.Add_Click({ param($s, $e) $v = [bool]$s.IsChecked; foreach ($ib in $s.Tag) { if ($ib.IsEnabled) { $ib.IsChecked = $v; $ib.Tag.Selected = $v } }; Update-SelSummary })
    }
    [void]$outer.Children.Add($exp)
    $card.Child = $outer
    Sync-RuleBox $list
    $card
}
function Build-Recs {
    $UI.RecsPanel.Children.Clear()
    $fix = @($State.Findings | Where-Object Fixbar)
    $cnt = [int](@($fix | ForEach-Object { @($_.Items).Count }) | Measure-Object -Sum).Sum
    $UI.RecsSub.Text = if ($cnt) { "WinTidy hat $(Plural $cnt 'mögliche Verbesserung' 'mögliche Verbesserungen') gefunden. Empfohlene Punkte sind schon ausgewählt. Mit Häkchen markierte Punkte werden umgesetzt." } elseif ($State.ScanTime) { 'Keine automatisch lösbaren Punkte gefunden.' } else { 'Noch keine Prüfung durchgeführt. Starte sie in der Übersicht.' }
    $UI.RecsLegend.Visibility = $(if ($cnt) { 'Visible' } else { 'Collapsed' })
    $groups = @($fix | Group-Object { Get-Group $_ } | Sort-Object @{ Expression = { $i = [array]::IndexOf($GroupOrder, $_.Name); if ($i -lt 0) { 99 } else { $i } } })
    foreach ($g in $groups) {
        $h = New-Tb $g.Name 'Muted' 13 'SemiBold'; $h.Margin = '2,10,0,8'
        [void]$UI.RecsPanel.Children.Add($h)
        foreach ($f in ($g.Group | Sort-Object @{ Expression = { switch ($_.Risiko) { 'Niedrig' { 1 } 'Mittel' { 2 } default { 3 } } } }, @{ Expression = { $_.Bytes }; Descending = $true })) {
            [void]$UI.RecsPanel.Children.Add((New-RecCard $f))
        }
    }
    Update-SelSummary
}
function Sync-RuleBox($list) {
    if (-not $list) { return }
    $cb = $list.Tag; if (-not $cb) { return }
    $boxes = @($cb.Tag | Where-Object { $_.IsEnabled }); if (-not $boxes.Count) { $cb.IsChecked = $false; return }
    $on = @($boxes | Where-Object { $_.IsChecked }).Count
    if ($on -eq 0) { $cb.IsChecked = $false } elseif ($on -eq $boxes.Count) { $cb.IsChecked = $true } else { $cb.IsChecked = $null }
}
function Set-AllSelection([string]$mode) {
    foreach ($f in $State.Findings) { foreach ($it in @($f.Items)) { $it.Selected = $(if ($mode -eq 'rec' -and -not $f.Gesperrt) { [bool]$it.Vorauswahl } else { $false }) } }
    Build-Recs
}
$UI.BtnSelRecommended.Add_Click({ Set-AllSelection 'rec' })
$UI.BtnSelNone.Add_Click({ Set-AllSelection 'none' })
$UI.BtnToRecs.Add_Click({ Go 'NavRecs' })

# =============================================================================
#  Fehlerseite (freundlich, mit "Erneut versuchen" und "Fehlerbericht kopieren")
# =============================================================================
function Show-ErrorPage([string]$title, [string]$text, [string]$detail, [scriptblock]$retry) {
    $UI.ErrTitle.Text = $title; $UI.ErrText.Text = $text; $UI.ErrDetail.Text = [string]$detail; $UI.ErrCopied.Visibility = 'Collapsed'
    $State.Retry = $retry
    $UI.BtnErrRetry.Visibility = $(if ($retry) { 'Visible' } else { 'Collapsed' })
    $tail = ''
    try { if (Test-Path -LiteralPath $ErrLog) { $tail = (Get-Content -LiteralPath $ErrLog -Tail 40 -Encoding UTF8) -join "`r`n" } } catch { }
    $os = ''; try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | ForEach-Object { "$($_.Caption) $($_.Version)" }) } catch { }
    $State.ErrReport = "WinTidy-Fehlerbericht`r`nVersion: $($State.Version)`r`nZeit: $(Get-Date -Format 's')`r`nSystem: $os`r`nAdmin: $IsAdmin`r`n`r`n$title`r`n$detail`r`n`r`n--- Protokoll ($ErrLog) ---`r`n$tail"
    Clear-NavSelection
    Show-Page 'PageError'
}
$UI.BtnErrRetry.Add_Click({ $r = $State.Retry; if ($r) { & $r } })
$UI.BtnErrCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText($State.ErrReport); $UI.ErrCopied.Visibility = 'Visible' } catch { Show-Msg "Kopieren nicht möglich. Die Fehlerdatei liegt hier:`n$ErrLog" | Out-Null } })
$UI.BtnErrHome.Add_Click({ Go 'NavHome' })

# =============================================================================
#  Prüfen
# =============================================================================
function Start-Scan {
    if (Test-Busy) { return }
    $Sync.Expert = [bool]$UI.OptExpert.IsChecked; $Sync.Deep = [bool]$UI.OptDeep.IsChecked
    $hint = if ($Sync.Deep) { 'Es wird nichts verändert. Die gründliche Prüfung kann bis zu 30 Minuten dauern.' } else { 'Es wird nichts verändert. Das dauert meist ein bis drei Minuten. Am besten nebenbei nicht viel arbeiten – sonst werden die Messwerte ungenauer.' }
    [void](Start-Op 'scan' @'
$r = Invoke-GuiScan $Sync.Expert $Sync.Deep { param($i, $n, $t) $Sync.Progress = @{ I = $i; N = $n; Text = $t } }
$r
'@ {
        param($r, $err, $cancelled)
        if ($cancelled) { Go 'NavHome'; $UI.LastScanText.Text = 'Prüfung abgebrochen. An deinem PC wurde nichts verändert.'; return }
        if (-not $r -or -not $r.Snapshot) {
            Write-ErrLog "Scan: $err"
            Show-ErrorPage 'Die Prüfung konnte nicht abgeschlossen werden' 'An deinem PC wurde nichts verändert. Versuch es bitte noch einmal. Wenn es wieder passiert, kopiere den Fehlerbericht und schick ihn an die Person, die dir WinTidy gegeben hat.' $err { Start-Scan }
            return
        }
        $State.Findings = @($r.Findings); $State.Snapshot = $r.Snapshot; $State.ScanTime = Get-Date; $State.InfoFindings = @()
        if ($r.Context) { $State.Context = $r.Context; Update-Banners }
        Update-Home; Build-Recs; Go 'NavHome'
    } 'Prüfe deinen PC …' $hint)
}
$UI.BtnScan.Add_Click({ Start-Scan })

# =============================================================================
#  Umsetzen
# =============================================================================
function Get-SelectedJobs {
    $jobs = @()
    foreach ($f in $State.Findings) { foreach ($it in @($f.Items)) { if ($it.Selected) { $jobs += [pscustomobject]@{ F = $f; It = $it } } } }
    $jobs
}
function Start-Fix([bool]$ohneRP) {
    $sel = @()
    foreach ($f in $State.Findings) { $ix = @(@($f.Items) | Where-Object Selected | ForEach-Object { $_.Index }); if ($ix.Count) { $sel += @{ Id = $f.Id; Indexes = $ix } } }
    if (-not $sel.Count) { return }
    $Sync.Selection = $sel; $Sync.RestorePoint = [bool]$UI.OptRestorePoint.IsChecked; $Sync.OhneRP = $ohneRP
    [void](Start-Op 'fix' @'
$r = Invoke-FixSelection $Sync.Selection $Sync.RestorePoint { param($i, $n, $t, $id) $Sync.Progress = @{ I = $i; N = $n; Text = $t; Id = $id } } $Control $Sync.OhneRP
$r
'@ {
        param($r, $err, $cancelled)
        if (-not $r) {
            Write-ErrLog "Fix: $err"
            Show-ErrorPage 'Beim Umsetzen ist etwas schiefgelaufen' 'WinTidy hat die Arbeit abgebrochen. Was bis dahin erledigt wurde, steht im Verlauf und im Bericht. Falls danach etwas nicht mehr funktioniert: unter Verlauf die Optimierung rückgängig machen oder die Windows-Systemwiederherstellung nutzen.' $err $null
            return
        }
        if ($r.Status -eq 'RP-FEHLT') {
            $q = "Windows konnte keinen Wiederherstellungspunkt anlegen.`n" + $(if ($r.Meldung) { "(Grund: $($r.Meldung))`n" } else { '' }) + "`nAn deinen Dateien und Einstellungen wurde bisher nichts verändert." + $(if ($r.ComputerschutzEingeschaltet) { " Nur die Windows-Systemwiederherstellung für Laufwerk $env:SystemDrive hat WinTidy dafür eingeschaltet." } else { '' }) + "`n`nOhne Wiederherstellungspunkt lassen sich Änderungen an Treibern und Windows schwerer zurücknehmen. Autostart, Aufgaben und Dienste kann WinTidy trotzdem selbst zurücksetzen.`n`nTrotzdem fortfahren? (Empfohlen: Nein)"
            if ([System.Windows.MessageBox]::Show($Win, $q, 'WinTidy', 'YesNo', 'Warning', 'No') -eq 'Yes') { Start-Fix $true } else { Go 'NavRecs' }
            return
        }
        if ($r.Status -eq 'GESPERRT') { Show-Msg ("Änderungen sind auf diesem PC gesperrt.`n`n" + [string]$r.Meldung) | Out-Null; Go 'NavRecs'; return }
        $State.LastResult = $r; if ($r.Nachher) { $State.Snapshot = $r.Nachher }
        Show-Result $r
    } 'Optimiere deinen PC …' 'Bitte den PC eingeschaltet lassen. Abbrechen ist jederzeit möglich – WinTidy hört dann nach dem aktuellen Schritt auf.')
}
$UI.BtnApply.Add_Click({
    if (Test-Busy) { return }
    $jobs = @(Get-SelectedJobs)
    $n = $jobs.Count
    if (-not $n) { return }
    # Veraltete Pruefung?
    if ($State.ScanTime -and ((Get-Date) - $State.ScanTime).TotalMinutes -gt 30) {
        $min = [int]((Get-Date) - $State.ScanTime).TotalMinutes
        $a = Show-Msg ("Die Prüfung ist schon {0} Minuten alt. Seitdem kann sich etwas geändert haben.`n`nJa = erst neu prüfen (empfohlen)`nNein = mit der alten Prüfung fortfahren" -f $min) 'YesNoCancel' 'Question'
        if ($a -eq 'Yes') { Start-Scan; return }
        if ($a -ne 'No') { return }
    }
    $nEnd = @($jobs | Where-Object { Test-Endgueltig $_.F }).Count
    $nUm = @($jobs | Where-Object { -not (Test-Endgueltig $_.F) -and (Test-Umkehrbar $_.F) }).Count
    $einz = @($jobs | Where-Object { Test-Einzeln $_.F })
    $dauer = @($jobs | Where-Object { $_.F.Dauer } | ForEach-Object { [string]$_.F.Dauer } | Select-Object -Unique)
    $uninst = [bool]($jobs | Where-Object { $_.F.Id -eq 'APP-SIDEBYSIDE' })
    $msg = $(if ($n -eq 1) { "Es wird 1 Änderung umgesetzt.`n" } else { "Es werden $n Änderungen umgesetzt.`n" })
    if ($nUm) { $msg += "  • $nUm davon kann WinTidy später rückgängig machen.`n" }
    if ($nEnd) { $msg += "  • $nEnd $(if ($nEnd -eq 1) { 'davon ist' } else { 'davon sind' }) endgültig (Dateien löschen, Programme oder Apps entfernen).`n" }
    if ($einz.Count) { $msg += "`nEinzeln ausgewählt (Nur für Profis):`n" + ((@($einz | Select-Object -First 10) | ForEach-Object { '  – ' + [string]$_.It.Label }) -join "`n") + $(if ($einz.Count -gt 10) { "`n  … und $($einz.Count - 10) weitere" } else { '' }) + "`n" }
    if ($dauer.Count) { $msg += "`nEinige Schritte dauern länger ($($dauer -join ', ')). Bitte den PC so lange eingeschaltet lassen.`n" }
    if ($UI.OptRestorePoint.IsChecked) { $msg += "`nVorher legt WinTidy einen Wiederherstellungspunkt an. Damit lassen sich Einstellungen, Treiber und Systemdateien zurücksetzen. Gelöschte Dateien und entfernte Programme kommen damit nicht zurück.`n" }
    else { $msg += "`nACHTUNG: Es wird KEIN Wiederherstellungspunkt angelegt.`n" }
    if ($uninst) { $msg += "`nFür doppelt installierte Programme öffnet sich jeweils das Deinstallationsprogramm. Es kann hinter dem WinTidy-Fenster liegen.`n" }
    if ($jobs | Where-Object { $_.F.Id -eq 'APP-UPDATES' }) { $msg += "`nBitte vorher alle Programme schließen und speichern – Updates können offene Programme beenden.`n" }
    $msg += "`nJetzt starten?"
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return }
    Start-Fix $false
})
$UI.BtnCancel.Add_Click({
    $op = $State.Op; if (-not $op) { return }
    if ($op.Kind -eq 'scan') { $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = 'Wird abgebrochen …'; try { [void]$op.PS.BeginStop($null, $null) } catch { } }
    elseif ($op.Kind -eq 'cooltest') { $Control.Cancel = $true; $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = 'Wird abgebrochen …' }
    elseif ($op.Kind -eq 'fix') { $Control.Cancel = $true; $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = 'WinTidy hört nach dem aktuellen Schritt auf. Das kann bei langen Schritten etwas dauern.' }
})

function New-ResultTile([string]$label, $before, $after, [string]$unit, [string]$better, [int]$dec = 0) {
    $d = $null; if ($null -ne $before -and $null -ne $after) { $d = [math]::Round([double]$after - [double]$before, $dec) }
    $good = $d -and (($better -eq 'lower' -and $d -lt 0) -or ($better -eq 'higher' -and $d -gt 0))
    $bad = $d -and -not $good
    $b = New-Object System.Windows.Controls.Border; $b.Style = $Win.FindResource('Card'); $b.Margin = '7,0,7,14'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t2 = New-Tb ((Fmt-Num $after $dec) + ' ' + $unit).Trim() 'Ink' 24 'SemiBold'; $t2.Margin = '0,4,0,2'
    $t3txt = if ($null -eq $d -or $d -eq 0) { 'vorher {0} {1} · unverändert' -f (Fmt-Num $before $dec), $unit } else { 'vorher {0} {1} · {2}{3} {1}' -f (Fmt-Num $before $dec), $unit, $(if ($d -gt 0) { '+' } else { '' }), (Fmt-Num $d $dec) }
    $t3 = New-Tb $t3txt $(if ($good) { 'Good' } elseif ($bad) { 'Bad' } else { 'Muted' }) 13
    [void]$sp.Children.Add((New-Tb $label 'Muted' 12)); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($t3); $b.Child = $sp
    Set-A11y $b "$label $($t2.Text), $t3txt"; $b
}
function Add-ResultGroup([string]$title, [string]$fg, [int]$icon, $rows) {
    if (-not @($rows).Count) { return }
    $h = New-Object System.Windows.Controls.DockPanel; $h.Margin = '0,8,0,6'
    $ic = New-Icon $icon $fg 15; $ic.Margin = '0,1,8,0'; [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
    [void]$h.Children.Add($ic); [void]$h.Children.Add((New-Tb ('{0} ({1})' -f $title, @($rows).Count) 'Ink' 15 'SemiBold'))
    [void]$UI.ResultDetails.Children.Add($h)
    foreach ($d in (@($rows) | Select-Object -First 100)) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.TextWrapping = 'Wrap'; $t.Margin = '23,0,0,4'; Set-Brush $t 'Foreground' 'Text'
        $r1 = New-Object System.Windows.Documents.Run ([string]$d.Titel + ': '); $r1.FontWeight = 'SemiBold'; $t.Inlines.Add($r1)
        $t.Inlines.Add((New-Object System.Windows.Documents.Run ([string]$d.Objekt)))
        if ($d.Meldung -and $d.Status -ne 'OK') { $r3 = New-Object System.Windows.Documents.Run (' – ' + [string]$d.Meldung); Set-Brush $r3 'Foreground' 'Muted'; $t.Inlines.Add($r3) }
        [void]$UI.ResultDetails.Children.Add($t)
    }
    if (@($rows).Count -gt 100) { [void]$UI.ResultDetails.Children.Add((New-Tb ("… und {0} weitere (siehe Bericht)" -f (@($rows).Count - 100)) 'Muted' 12)) }
}
function Show-Result($r) {
    $fail = [int]$r.Fehler; $ok = [int]$r.OK; $tot = [int]$r.Aktionen
    $abgebrochen = ($r.Status -eq 'ABGEBROCHEN')
    if ($abgebrochen) {
        $UI.ResultTitle.Text = 'Abgebrochen'
        $UI.ResultSub.Text = ('Abgebrochen nach {0} von {1} Schritten. Der Rest wurde nicht ausgeführt.' -f $ok, $tot)
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } elseif ($ok -eq 0 -and -not $fail) {
        $UI.ResultTitle.Text = 'Nichts umgesetzt'
        $UI.ResultSub.Text = 'Alle ausgewählten Schritte wurden übersprungen – die Gründe stehen unten.'
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } elseif ($fail) {
        $UI.ResultTitle.Text = 'Fertig – einige Punkte konnten nicht umgesetzt werden'
        $UI.ResultSub.Text = ('{0} von {1} erfolgreich umgesetzt, {2} nicht möglich. Die Gründe stehen unten.' -f $ok, (Plural $tot 'Änderung' 'Änderungen'), $fail)
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } else {
        $UI.ResultTitle.Text = 'Fertig!'
        $UI.ResultSub.Text = ('{0} erfolgreich umgesetzt.' -f (Plural $ok 'Änderung' 'Änderungen'))
        $UI.ResultIcon.Text = [string][char]0xE73E; Set-Brush $UI.ResultIcon 'Foreground' 'Good'; Set-Brush $UI.ResultIconBg 'Background' 'LowBg'
    }
    $notes = @()
    if ($r.Wiederherstellungspunkt -eq $false) { $notes += 'Es wurde kein Wiederherstellungspunkt angelegt.' }
    if ($r.ComputerschutzEingeschaltet) { $notes += 'Hinweis: Die Windows-Systemwiederherstellung war ausgeschaltet. WinTidy hat sie für Laufwerk ' + $env:SystemDrive + ' eingeschaltet, damit ein Wiederherstellungspunkt angelegt werden konnte.' }
    $UI.ResultNote.Text = ($notes -join "`n"); $UI.ResultNoteCard.Visibility = $(if ($notes.Count) { 'Visible' } else { 'Collapsed' })
    # Kacheln
    $UI.ResultGrid.Children.Clear()
    $m = @{}; foreach ($x in @($r.Vergleich)) { if ($x) { $m[$x.Kennzahl] = $x } }
    $pick = @(
        @('Health-Score', 'Gesundheitswert', '', 'higher', 0),
        @('Aktive Autostarts', 'Programme im Autostart', '', 'lower', 0),
        @('Treiberpakete', 'Treiberpakete', '', 'lower', 0),
        @('Geistergeraete', 'Alte Geräte-Einträge', '', 'lower', 0),
        @('Store-Apps', 'Store-Apps', '', 'lower', 0)
    )
    $fa = $null; $fb = $null
    if ($r.Vorher -and $r.Nachher) { $fa = (@($r.Vorher.Laufwerke) | Measure-Object FreiGB -Sum).Sum; $fb = (@($r.Nachher.Laufwerke) | Measure-Object FreiGB -Sum).Sum }
    if ($null -ne $fa -and $null -ne $fb) {
        $t = New-ResultTile 'Freier Speicher (gemessen, alle Laufwerke)' ([math]::Round($fa, 1)) ([math]::Round($fb, 1)) 'GB' 'neutral' 1
        $t.Child.Children[1].Text = ('{0:+0.0;-0.0;0.0} GB' -f ($fb - $fa))
        $t.Child.Children[2].Text = $(if (($fb - $fa) -lt 0) { 'Der Wiederherstellungspunkt belegt selbst etwas Platz. Der Gewinn zeigt sich oft erst nach einem Neustart.' } elseif ($r.Bytes) { "geschätzt waren $(Fmt-Bytes $r.Bytes) – manches gibt Windows erst nach einem Neustart frei" } else { 'Differenz vorher/nachher' })
        Set-Brush $t.Child.Children[2] 'Foreground' 'Muted'
        [void]$UI.ResultGrid.Children.Add($t)
    }
    foreach ($p in $pick) { $x = $m[$p[0]]; if ($x) { [void]$UI.ResultGrid.Children.Add((New-ResultTile $p[1] $x.Vorher $x.Nachher $p[2] $p[3] $p[4])) } }
    # Was genau passiert ist
    $UI.ResultDetails.Children.Clear()
    $det = @($r.Details | Where-Object { $_ })
    if ($det.Count) {
        Add-ResultGroup 'Erledigt' 'Good' 0xE73E @($det | Where-Object { $_.Status -eq 'OK' })
        Add-ResultGroup 'Nicht möglich' 'Bad' 0xE7BA @($det | Where-Object { $_.Status -eq 'Fehler' })
        Add-ResultGroup 'Übersprungen' 'Muted' 0xE711 @($det | Where-Object { $_.Status -eq 'Uebersprungen' })
        Add-ResultGroup 'Nicht ausgeführt' 'Muted' 0xE711 @($det | Where-Object { $_.Status -notin 'OK', 'Fehler', 'Uebersprungen' })
    } else { [void]$UI.ResultDetails.Children.Add((New-Tb 'Die Einzelheiten stehen im ausführlichen Bericht.' 'Muted' 13)) }
    # Umgesetzte Empfehlungen sind erledigt: nur Hinweise behalten, fuer neue Empfehlungen erneut pruefen
    $State.Findings = @($State.Findings | Where-Object { -not $_.Fixbar }); $State.ScanTime = $null
    Update-Home; Build-Recs
    $UI.RecsSub.Text = 'Die ausgewählten Empfehlungen wurden bearbeitet. Prüfe erneut, um den aktuellen Stand zu sehen.'
    $UI.ScoreDetail.Text = 'Optimierung abgeschlossen. Für neue Empfehlungen bitte erneut prüfen.'
    Clear-NavSelection; Show-Page 'PageResult'
}
$UI.BtnResultHome.Add_Click({ Go 'NavHome' })
$UI.BtnResultReport.Add_Click({ $p = if ($State.LastResult) { $State.LastResult.Report } else { $null }; if ($p -and (Test-Path -LiteralPath $p)) { Open-AsUser $p } else { Show-Msg 'Der Bericht wurde nicht gefunden.' | Out-Null } })
$UI.BtnRestartNow.Add_Click({ if ((Show-Msg 'Der PC wird jetzt neu gestartet. Bitte vorher alles speichern.' 'OKCancel' 'Information') -eq 'OK') { Start-Process shutdown.exe -ArgumentList '/r /t 5 /c "WinTidy: Neustart nach Optimierung"' } })

# =============================================================================
#  Rückgängig machen
# =============================================================================
function Start-Undo([string]$lauf) {
    if (Test-Busy) { return }
    $Sync.Lauf = $lauf
    [void](Start-Op 'undo' @'
$l = $Sync.Lauf
if (-not $l) { $last = Get-ChildItem -LiteralPath $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name | Select-Object -Last 1; if ($last) { $l = $last.Name.Substring(0, 15) } }
$p = @(); if ($l -and (Get-Command Get-RestorePreview -ErrorAction SilentlyContinue)) { try { $p = @(Get-RestorePreview $l) } catch { } }
[pscustomobject]@{ Lauf = $l; Items = $p; HatVorschau = [bool](Get-Command Get-RestorePreview -ErrorAction SilentlyContinue) }
'@ {
        param($r, $err, $cancelled)
        if (-not $r -or -not $r.Lauf) { Show-Msg 'Es gibt noch keine Optimierung, die man rückgängig machen könnte.' | Out-Null; return }
        $zeit = ''; try { $zeit = [datetime]::ParseExact($r.Lauf.Substring(0, 15), 'yyyyMMdd-HHmmss', $null).ToString('dd.MM.yyyy, HH:mm') + ' Uhr' } catch { $zeit = $r.Lauf }
        $items = @($r.Items | Where-Object { $_ })
        if ($r.HatVorschau -and -not $items.Count) {
            if ((Show-Msg "Für die Optimierung vom $zeit gibt es nichts, was WinTidy selbst zurücksetzen kann.`n`nGelöschte Dateien und entfernte Programme kommen nicht zurück. Treiber und Systemänderungen lassen sich mit der Windows-Systemwiederherstellung zurücksetzen.`n`nSystemwiederherstellung jetzt öffnen?" 'YesNo' 'Information') -eq 'Yes') { Open-Rstrui }
            return
        }
        $liste = if ($items.Count) { "`n" + ((@($items | Select-Object -First 15) | ForEach-Object { '  – {0}: {1}' -f $_.Art, $_.Objekt }) -join "`n") + $(if ($items.Count -gt 15) { "`n  … und $($items.Count - 15) weitere" } else { '' }) + "`n" } else { "`nAutostart-Einstellungen, geplante Aufgaben und Dienste dieses Laufs.`n" }
        $q = "Optimierung vom $zeit rückgängig machen?`n`nWinTidy setzt zurück:$liste`nGelöschte Dateien und entfernte Programme kommen nicht zurück – auch nicht über die Systemwiederherstellung.`n`nFortfahren?"
        if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
        $Sync.Lauf = $r.Lauf
        [void](Start-Op 'undo' @'
$x = Invoke-GuiRestore $Sync.Lauf
if ($null -eq $x) { [pscustomobject]@{ Wiederhergestellt = $null; Fehler = 0; Details = @() } } else { $x }
'@ {
                param($x, $err2, $c2)
                if (-not $x) { Show-ErrorPage 'Rückgängig machen hat nicht geklappt' 'WinTidy konnte die Einstellungen nicht zurücksetzen. Du kannst die Windows-Systemwiederherstellung nutzen (Verlauf → Systemwiederherstellung öffnen).' $err2 $null; return }
                if ($x.Status -eq 'GESPERRT') { Show-Msg ([string]$x.Meldung) 'OK' 'Warning' | Out-Null; return }
                if ($x.Status -eq 'NICHT-GEFUNDEN') { Show-Msg 'Diese Optimierung wurde nicht gefunden. Es wurde nichts zurückgesetzt.' 'OK' 'Warning' | Out-Null; return }
                if ($null -eq $x.Wiederhergestellt) { $t = 'Erledigt.' }
                else {
                    $t = ('{0} wiederhergestellt.' -f (Plural ([int]$x.Wiederhergestellt) 'Einstellung' 'Einstellungen'))
                    if ([int]$x.Fehler) { $t += ("`n{0} konnten nicht wiederhergestellt werden:`n" -f [int]$x.Fehler) + ((@($x.Details | Where-Object { $_.Status -ne 'OK' } | Select-Object -First 10) | ForEach-Object { '  – {0}: {1}' -f $_.Objekt, $_.Meldung }) -join "`n") }
                }
                Show-Msg ($t + "`n`nBitte den PC neu starten, damit alles wirkt.") 'OK' $(if ([int]$x.Fehler) { 'Warning' } else { 'Information' }) | Out-Null
                Go 'NavHistory'
            } 'Mache Änderungen rückgängig …' 'Das dauert meist nur wenige Sekunden.')
    } 'Lade die Änderungen …' '' -Silent)
}
function Open-Rstrui { try { Start-Process -FilePath (Join-Path $env:windir 'System32\rstrui.exe') } catch { Show-Msg 'Die Systemwiederherstellung konnte nicht geöffnet werden.' | Out-Null } }
$UI.BtnResultUndo.Add_Click({ Start-Undo $(if ($State.LastResult) { [string]$State.LastResult.RunId } else { '' }) })
$UI.BtnUndo.Add_Click({ Start-Undo '' })
$UI.BtnRstrui.Add_Click({ Open-Rstrui })
$UI.BtnHistRstrui.Add_Click({ Open-Rstrui })

# =============================================================================
#  Verlauf (asynchron)
# =============================================================================
function Load-History {
    $UI.HistoryList.Children.Clear()
    [void]$UI.HistoryList.Children.Add((New-Tb 'Lade den Verlauf …' 'Muted' 13))
    $started = Start-Op 'silent' @'
if (Get-Command Get-HistoryLight -ErrorAction SilentlyContinue) { Get-HistoryLight } else { Get-HistoryData }
'@ {
        param($h, $err, $c)
        if ($err) { Write-ErrLog "History: $err" }
        $State.History = $h
        Draw-Boot $h
        Show-HistoryList $h
    } -Silent
    if (-not $started) { $State.HistoryPending = $true; $UI.HistoryList.Children.Clear(); [void]$UI.HistoryList.Children.Add((New-Tb 'WinTidy arbeitet gerade. Der Verlauf wird danach angezeigt.' 'Muted' 13)) }
}
function Show-HistoryList($h) {
    $UI.HistoryList.Children.Clear()
    if (-not $h) { [void]$UI.HistoryList.Children.Add((New-Tb 'Der Verlauf konnte nicht geladen werden.' 'Muted' 13)); return }
    $entries = @()
    $scores = @(); if ($h.Scores) { $scores = @($h.Scores) } else { $scores = @($h.Snapshots | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Zeit = $_.Zeit; Label = $_.Label; Wert = $_.Score.Wert } }) }
    foreach ($s in $scores) { if ($s.Label -eq 'scan') { $entries += [pscustomobject]@{ Zeit = [datetime]$s.Zeit; Text = ('Prüfung – Gesundheitswert {0}' -f $s.Wert); Icon = 0xE721; Col = 'Accent'; Lauf = $null; Umk = 0 } } }
    foreach ($l in @($h.Laeufe | Where-Object { $_ })) {
        $z = $l.Zusammenfassung
        $txt = if ($z) { 'Optimierung – {0}, Wert {1} → {2}' -f (Plural ([int]$z.OK) 'Änderung' 'Änderungen'), $z.ScoreVorher, $z.ScoreNachher } else { 'Optimierung' }
        if ($l.RueckgaengigAm) { try { $txt += (' · rückgängig gemacht am {0:dd.MM.yyyy}' -f [datetime]$l.RueckgaengigAm) } catch { } }
        $umk = if ($null -ne $l.Umkehrbar) { [int]$l.Umkehrbar } else { -1 }
        $entries += [pscustomobject]@{ Zeit = [datetime]$l.Zeit; Text = $txt; Icon = 0xE73E; Col = 'Good'; Lauf = [string]$l.Lauf; Umk = $umk }
    }
    foreach ($e in ($entries | Sort-Object Zeit -Descending | Select-Object -First 40)) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,10'
        $ic = New-Icon $e.Icon $e.Col 14; $ic.Margin = '0,2,12,0'; [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        $dt = New-Tb $e.Zeit.ToString('dd.MM.yyyy HH:mm') 'Muted' 14; $dt.Width = 140; $dt.TextWrapping = 'NoWrap'; [System.Windows.Controls.DockPanel]::SetDock($dt, 'Left')
        [void]$row.Children.Add($ic); [void]$row.Children.Add($dt)
        if ($e.Lauf -and $e.Umk -ne 0) {
            $btn = New-Object System.Windows.Controls.Button; $btn.Style = $Win.FindResource('LinkBtn'); $btn.Content = 'Rückgängig …'; $btn.Tag = $e.Lauf; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
            Set-A11y $btn ('Optimierung vom {0} rückgängig machen' -f $e.Zeit.ToString('dd.MM.yyyy HH:mm'))
            $btn.Add_Click({ param($s, $ev) Start-Undo ([string]$s.Tag) })
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right'); [void]$row.Children.Add($btn)
        }
        [void]$row.Children.Add((New-Tb $e.Text 'Ink' 14))
        [void]$UI.HistoryList.Children.Add($row)
    }
    if (-not $entries.Count) { [void]$UI.HistoryList.Children.Add((New-Tb 'Noch keine Einträge.' 'Muted' 13)) }
}
function Draw-Boot($h) {
    $c = $UI.BootCanvas; $c.Children.Clear()
    $pts = @(); if ($h) { $pts = @($h.Boots | Where-Object { $_ -and $_.GesamtMs -gt 0 } | Sort-Object { [datetime]$_.Zeit }) }
    if ($pts.Count -lt 2) { $UI.BootNote.Text = 'Noch zu wenige Startzeiten gemessen. Windows erfasst sie bei jedem Hochfahren (sichtbar mit Administratorrechten).'; return }
    $W = $c.ActualWidth; if ($W -lt 200) { return }   # Layout noch nicht fertig -> SizeChanged zeichnet neu
    $H = 240; $pl = 44; $pb = 24; $pt = 10
    $t0 = ([datetime]$pts[0].Zeit).Ticks; $t1 = ([datetime]$pts[-1].Zeit).Ticks; if ($t1 -eq $t0) { $t1 = $t0 + 1 }
    $max = [math]::Max(10, [math]::Ceiling((($pts | Measure-Object GesamtMs -Maximum).Maximum) / 10000) * 10)
    $X = { param($t) $pl + ($W - $pl - 10) * (($t - $t0) / ($t1 - $t0)) }
    $Y = { param($ms) $pt + ($H - $pt - $pb) * (1 - ($ms / 1000) / $max) }
    $step = [math]::Max(10, [math]::Ceiling($max / 40) * 10)
    for ($v = 0; $v -le $max; $v += $step) {
        $yy = & $Y ($v * 1000)
        $ln = New-Object System.Windows.Shapes.Line; $ln.X1 = $pl; $ln.X2 = $W - 10; $ln.Y1 = $yy; $ln.Y2 = $yy; Set-Brush $ln 'Stroke' 'Line'; [void]$c.Children.Add($ln)
        $lb = New-Tb "$v s" 'Muted' 11; $lb.TextWrapping = 'NoWrap'; [System.Windows.Controls.Canvas]::SetLeft($lb, 0); [System.Windows.Controls.Canvas]::SetTop($lb, $yy - 8); [void]$c.Children.Add($lb)
    }
    foreach ($l in @($h.Laeufe | Where-Object { $_ })) {
        $t = ([datetime]$l.Zeit).Ticks; if ($t -lt $t0 -or $t -gt $t1) { continue }
        $x = & $X $t
        $ln = New-Object System.Windows.Shapes.Line; $ln.X1 = $x; $ln.X2 = $x; $ln.Y1 = $pt; $ln.Y2 = $H - $pb; Set-Brush $ln 'Stroke' 'Good'; $ln.StrokeThickness = 1.5; $ln.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('4 3'); [void]$c.Children.Add($ln)
    }
    $poly = New-Object System.Windows.Shapes.Polyline; Set-Brush $poly 'Stroke' 'Accent'; $poly.StrokeThickness = 2.5; $poly.StrokeLineJoin = 'Round'
    foreach ($p in $pts) { [void]$poly.Points.Add((New-Object System.Windows.Point (& $X ([datetime]$p.Zeit).Ticks), (& $Y $p.GesamtMs))) }
    [void]$c.Children.Add($poly)
    foreach ($p in $pts) {
        $e = New-Object System.Windows.Shapes.Ellipse; $e.Width = 8; $e.Height = 8; Set-Brush $e 'Fill' 'Accent'
        $e.ToolTip = ('{0:dd.MM.yyyy HH:mm}: {1:N1} s' -f [datetime]$p.Zeit, ($p.GesamtMs / 1000))
        [System.Windows.Controls.Canvas]::SetLeft($e, (& $X ([datetime]$p.Zeit).Ticks) - 4); [System.Windows.Controls.Canvas]::SetTop($e, (& $Y $p.GesamtMs) - 4); [void]$c.Children.Add($e)
    }
    $first = ($pts | Select-Object -First 5 | Measure-Object GesamtMs -Average).Average / 1000
    $last = ($pts | Select-Object -Last 3 | Measure-Object GesamtMs -Average).Average / 1000
    $UI.BootNote.Text = ('Anfangs im Schnitt {0:N1} s, zuletzt {1:N1} s ({2} Starts seit {3:dd.MM.yyyy}). Einzelne Ausreißer sind normal, z. B. nach Updates.' -f $first, $last, $pts.Count, [datetime]$pts[0].Zeit)
    Set-A11y $c $UI.BootNote.Text
}
$UI.BootCanvas.Add_SizeChanged({ if ($State.History) { Draw-Boot $State.History } })
$UI.BtnHistReport.Add_Click({ $p = $null; if ($State.History) { $p = [string]$State.History.Report }; if ($p -and (Test-Path -LiteralPath $p)) { Open-AsUser $p } else { Show-Msg 'Noch kein Bericht vorhanden – bitte zuerst prüfen.' | Out-Null } })
function Open-Folder([string]$d) { if ($d -and (Test-Path -LiteralPath $d)) { Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $d) } else { Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $AppRoot) } }
$UI.BtnHistFolder.Add_Click({ $d = $State.DataDir; if ($State.History -and $State.History.DataDir) { $d = [string]$State.History.DataDir }; Open-Folder $d })

# =============================================================================
#  Einstellungen
# =============================================================================
$UI.BtnDataFolder.Add_Click({ $d = $State.DataDir; if (-not $d) { $d = Join-Path $AppRoot "WinTidy-Daten\$env:COMPUTERNAME" }; Open-Folder $d })
$UI.BtnConfig.Add_Click({ $p = Join-Path $AppRoot 'WinTidy.config.json'; Start-Process -FilePath notepad.exe -ArgumentList ('"{0}"' -f $p) })
$UI.OptExpert.Add_Click({ $UI.BtnConfig.Visibility = $(if ($UI.OptExpert.IsChecked) { 'Visible' } else { 'Collapsed' }); if ($State.Findings.Count) { Build-Recs } })
$UI.OptRestorePoint.Add_Click({ Update-SelSummary })
$UI.BtnShortcut.Add_Click({
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WinTidy.lnk'
        $sh = New-Object -ComObject WScript.Shell; $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppPath`""
        $s.WorkingDirectory = $AppRoot; $s.IconLocation = "$env:windir\System32\cleanmgr.exe,0"; $s.Description = 'WinTidy – PC-Pflege'; $s.WindowStyle = 7
        $s.Save()
        $bytes = [IO.File]::ReadAllBytes($lnk); $bytes[0x15] = $bytes[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnk, $bytes)   # "Als Administrator ausfuehren"
        Show-Msg 'Die Verknüpfung "WinTidy" liegt jetzt auf dem Desktop.' | Out-Null
    } catch { Show-Msg "Die Verknüpfung konnte nicht angelegt werden: $($_.Exception.Message)" 'OK' 'Warning' | Out-Null }
})

# =============================================================================
#  Start, Beenden, globale Fehlerbehandlung
# =============================================================================
$Win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-ErrLog ("UI: " + $e.Exception.ToString())
    $e.Handled = $true
    try { Show-Msg ("Da ist etwas schiefgelaufen. Dein PC wurde dadurch nicht verändert.`n`n$($e.Exception.Message)`n`nFehlerprotokoll: $ErrLog") 'OK' 'Warning' | Out-Null } catch { }
})

$Win.Add_Loaded({
    $UI.VersionText.Text = 'Lade …'
    $UI.BtnScan.IsEnabled = $false; $UI.BtnScan.Content = 'Wird vorbereitet …'
    Update-Banners
    Update-SelSummary
    Build-Recs
    [void](Start-Op 'init' @'
. $EnginePath
$Script:UiSink = { param($t, $c) $Sync.Log.Enqueue([string]$t) }
$last = Get-Snapshots | Select-Object -Last 1
$ctx = $null; if (Get-Command Get-WtContext -ErrorAction SilentlyContinue) { try { $ctx = Get-WtContext } catch { } }
[pscustomobject]@{ Version = $Script:Version; Last = $(if ($last) { Read-Snapshot $last } else { $null }); DataDir = $Script:DataDir; Context = $ctx; Friendly = $Script:Friendly; Migriert = [bool]$Script:DataMigrated; Ok = [bool](Get-Command Invoke-GuiScan -ErrorAction SilentlyContinue) }
'@ {
        param($init, $err, $c)
        if (-not $init -or -not $init.Ok -or -not $init.Version) {
            Write-ErrLog "Init: $err"
            Show-Msg ("WinTidy.ps1 konnte nicht geladen werden. Bitte den kompletten WinTidy-Ordner neu kopieren.`n`n$err`n`nFehlerprotokoll: $ErrLog") 'OK' 'Error' | Out-Null
            $State.ForceClose = $true; $Win.Close(); return
        }
        $State.EngineOk = $true
        $State.Friendly = $init.Friendly
        $UI.BtnScan.IsEnabled = $true; $UI.BtnScan.Content = '_Jetzt prüfen'
        $State.Version = $init.Version; $State.DataDir = [string]$init.DataDir
        # Fehlerprotokoll ab jetzt im Datenordner (leichter zu finden als %TEMP%)
        if ($State.DataDir -and (Test-Path -LiteralPath $State.DataDir)) { $Script:ErrLog = Join-Path $State.DataDir 'WinTidy-App-Fehler.log' }
        $UI.VersionText.Text = "Version $($init.Version)"
        $UI.AboutText.Text = "WinTidy $($init.Version) · Daten: $($init.DataDir)`nOhne Installation, ohne Internetverbindung (außer für Programm-Updates). Jede Änderung wird protokolliert.`nFehlerprotokoll: $ErrLog"
        $State.Context = $init.Context; Update-Banners
        if ($init.Last) {
            $State.Snapshot = $init.Last
            $State.Findings = @()
            $State.InfoFindings = @(Get-InfoFromSnapshot $init.Last)
            Update-Home
            $UI.ScoreDetail.Text = 'Ergebnis der letzten Prüfung. Für aktuelle Empfehlungen bitte erneut prüfen.'
            $UI.BtnToRecs.Visibility = 'Collapsed'
        }
        Update-SelSummary
    } -Silent)
})
$Win.Add_Closing({
    param($s, $e)
    if ($State.ForceClose) { return }
    $op = $State.Op
    if ($op -and $op.Kind -eq 'fix') {
        Show-Msg 'WinTidy setzt gerade Änderungen um. Bitte warte, bis es fertig ist – oder klicke auf Abbrechen. WinTidy hört dann nach dem aktuellen Schritt auf.' | Out-Null
        $e.Cancel = $true; return
    }
    if ($op -and $op.Kind -eq 'undo' -and -not $op.Silent) { Show-Msg 'WinTidy setzt gerade Änderungen zurück. Bitte einen Moment warten.' | Out-Null; $e.Cancel = $true; return }
    if ($op -and $op.Kind -eq 'cooltest') { if ((Show-Msg 'Der Kühlungstest läuft noch. Abbrechen und WinTidy beenden?' 'YesNo' 'Question') -ne 'Yes') { $e.Cancel = $true } else { $Control.Cancel = $true }; return }
    if ($op -and $op.Kind -eq 'undo' -and $op.Silent) { return }
    if ($op -and -not $op.Silent) { if ((Show-Msg 'Die Prüfung abbrechen und WinTidy beenden?' 'YesNo' 'Question') -ne 'Yes') { $e.Cancel = $true } }
})
$Win.Add_Closed({
    try { $Timer.Stop() } catch { }
    try { $ThemeTimer.Stop() } catch { }
    try { if ($State.Op) { [void]$State.Op.PS.BeginStop($null, $null) } } catch { }
    try { $RS.CloseAsync() } catch { }
    try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex(); $Script:Mutex.Dispose(); $Script:Mutex = $null } } catch { }
})

try { [void]$Win.ShowDialog() }
catch { Write-ErrLog "ShowDialog: $($_.Exception.Message) $($_.ScriptStackTrace)"; [System.Windows.MessageBox]::Show("Unerwarteter Fehler: $($_.Exception.Message)`n`nFehlerprotokoll: $ErrLog", 'WinTidy', 'OK', 'Error') | Out-Null }
finally { try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex() } } catch { } }
