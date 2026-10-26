#Requires -Version 5.1
<#
.SYNOPSIS
    WinTidy App - graphical interface for WinTidy (also for non-IT users).
.DESCRIPTION
    Opens a window (WPF). The actual work is done by WinTidy.ps1, which is loaded into a
    background runspace so that the interface never freezes.
    Start: double-click "WinTidy App.cmd" or the desktop shortcut (can be created in the settings).
    Language: German if Windows is German, otherwise English; can be changed in the settings.
#>
param([switch]$NoElevate, [switch]$Restarted)

$ErrorActionPreference = 'Stop'
$ErrLog = Join-Path $env:TEMP 'WinTidy-App-Fehler.log'
function Write-ErrLog([string]$t) { try { "$(Get-Date -Format s)  $t" | Out-File -LiteralPath $ErrLog -Append -Encoding utf8 } catch { } }

# Language: the code contains English texts, German comes from lang\de.psd1 (same mechanism as WinTidy.ps1).
# Setting in the app (Sprache = Auto | de | en); Auto = German if Windows is German, otherwise English.
$AppSettingsFile = Join-Path $env:APPDATA 'WinTidy\app-einstellungen.json'
$Script:Lang = 'en'; $Script:De = $null; $Script:LangMode = 'Auto'
function Read-WtLangFile([string]$Path) {
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$err)
    if ($err -and $err.Count) { throw "$Path`: $($err[0].Message)" }
    $h = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    if (-not $h) { throw "$Path`: no table found" }
    foreach ($kv in $h.KeyValuePairs) {
        $v = $kv.Item2
        if ($v -is [System.Management.Automation.Language.PipelineAst] -and $v.PipelineElements.Count -eq 1) { $v = $v.PipelineElements[0].Expression }
        if ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $v -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $dict[$kv.Item1.Value] = $v.Value }
    }
    return , $dict
}
function T([string]$Text) {
    $s = $Text
    if ($Script:Lang -eq 'de' -and $null -ne $Script:De) { $v = $null; if ($Script:De.TryGetValue($Text, [ref]$v)) { $s = $v } }
    if ($args.Count) { try { return ($s -f $args) } catch { return $s } }
    return $s
}
try { if (Test-Path -LiteralPath $AppSettingsFile) { $st0 = Get-Content -LiteralPath $AppSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$st0.Sprache -in 'Auto', 'de', 'en') { $Script:LangMode = [string]$st0.Sprache } } } catch { }
if ($Script:LangMode -in 'de', 'en') { $Script:Lang = $Script:LangMode }
else { try { if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de') { $Script:Lang = 'de' } } catch { } }
if ($Script:Lang -eq 'de') {
    try { $Script:De = Read-WtLangFile (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) 'lang\de.psd1') }
    catch { $Script:Lang = 'en'; $Script:De = $null; Write-ErrLog "Language file: $($_.Exception.Message)" }
}

# Make errors at startup visible (the console is hidden)
trap {
    Write-ErrLog ("FATAL " + ($_ | Out-String))
    try { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show((T "WinTidy could not start.`n`n{0}`n`nError log: {1}" ($_.Exception.Message) $ErrLog), 'WinTidy', 'OK', 'Error') | Out-Null } catch { }
    try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex() } } catch { }
    exit 1
}

$AppPath = $PSCommandPath
$AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Network drive (Z:\...): the process with admin rights usually does not see mapped drives -> use the UNC path
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
        [System.Windows.MessageBox]::Show((T "WinTidy is on a network drive. With administrator rights Windows often cannot find it there.`n`nPlease copy the WinTidy folder to this PC (e.g. into Documents) and start it from there.`n`nWinTidy now starts with limited functions (check only)."), 'WinTidy', 'OK', 'Information') | Out-Null
    } else {
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$AppPath`"", '-NoElevate') -ErrorAction Stop
            return
        } catch { }   # UAC declined -> continue without admin rights (limited)
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Only one instance (two simultaneous optimizations would be dangerous)
$Script:Mutex = $null
$gotMutex = $false
try {
    $Script:Mutex = New-Object System.Threading.Mutex($false, 'Global\WinTidyApp')
    try { $gotMutex = $Script:Mutex.WaitOne($(if ($Restarted) { 15000 } else { 0 })) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
} catch { $gotMutex = $false }
if (-not $gotMutex) {
    $Script:Mutex = $null
    [System.Windows.MessageBox]::Show((T 'WinTidy is already open. Please use the existing window (check the taskbar).'), 'WinTidy', 'OK', 'Information') | Out-Null
    return
}
if (-not (Test-Path -LiteralPath $EnginePath)) { [System.Windows.MessageBox]::Show((T "WinTidy.ps1 was not found:`n{0}`n`nPlease copy the complete WinTidy folder." $EnginePath), 'WinTidy', 'OK', 'Error') | Out-Null; $Script:Mutex.ReleaseMutex(); return }

# =============================================================================
#  Interface (XAML)
# =============================================================================
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinTidy – PC care" Width="1180" Height="780" MinWidth="860" MinHeight="520"
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
    <Grid.ColumnDefinitions><ColumnDefinition x:Name="NavCol" Width="252"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Navigation -->
    <Border Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,0">
      <DockPanel x:Name="NavDock" Margin="16,22,16,16">
        <StackPanel DockPanel.Dock="Top" Margin="6,0,0,26" Orientation="Horizontal">
          <Border Width="40" Height="40" CornerRadius="11" Background="{DynamicResource Accent}">
            <TextBlock Text="&#xE9F5;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource OnAccent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel x:Name="BrandText" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="WinTidy" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Ink}"/>
            <TextBlock Text="PC care with proof" FontSize="12" Foreground="{DynamicResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <TextBlock x:Name="VersionText" FontSize="12" Foreground="{DynamicResource Muted}" Margin="6,0" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavHome" AutomationProperties.Name="Overview" Style="{StaticResource Nav}" IsChecked="True" ToolTip="Overview"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT1" Text="Overview"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavRecs" AutomationProperties.Name="Recommendations" Style="{StaticResource Nav}" ToolTip="Recommendations"><DockPanel LastChildFill="True"><TextBlock DockPanel.Dock="Left" Text="&#xE82F;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><Border x:Name="RecsBadge" DockPanel.Dock="Right" Background="{DynamicResource Accent}" CornerRadius="9" Padding="7,0" Margin="6,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"><TextBlock x:Name="RecsBadgeText" Foreground="{DynamicResource OnAccent}" FontSize="12"/></Border><TextBlock x:Name="NavT2" Text="Recommendations" TextTrimming="CharacterEllipsis"/></DockPanel></RadioButton>
          <RadioButton x:Name="NavDebloat" AutomationProperties.Name="Debloat" Style="{StaticResource Nav}" ToolTip="Debloat"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT6" Text="Debloat"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavHistory" AutomationProperties.Name="History" Style="{StaticResource Nav}" ToolTip="History"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT3" Text="History"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavSettings" AutomationProperties.Name="Settings" Style="{StaticResource Nav}" ToolTip="Settings"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT4" Text="Settings"/></StackPanel></RadioButton>
          <RadioButton x:Name="NavHelp" AutomationProperties.Name="Help" Style="{StaticResource Nav}" ToolTip="Help"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE897;" FontFamily="Segoe MDL2 Assets" Width="30" VerticalAlignment="Center"/><TextBlock x:Name="NavT5" Text="Help"/></StackPanel></RadioButton>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Content -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel x:Name="BannerPanel" Grid.Row="0" Margin="36,16,36,0"/>

      <Grid Grid.Row="1">
      <!-- Overview -->
      <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Overview" Style="{StaticResource H1}"/>
          <TextBlock x:Name="HomeSub" Style="{StaticResource Sub}" Margin="0,4,0,22" Text="Let WinTidy check your PC. Nothing is changed in the process."/>
          <Border Style="{StaticResource Card}" Padding="26">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <Grid Width="170" Height="170">
                  <Ellipse Stroke="{DynamicResource Track}" StrokeThickness="14"/>
                  <Path x:Name="ScoreArc" StrokeThickness="14" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stroke="{DynamicResource Accent}"/>
                  <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock x:Name="ScoreText" Text="–" FontSize="46" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{DynamicResource Ink}"/>
                    <TextBlock Text="of 100" FontSize="12" HorizontalAlignment="Center" Foreground="{DynamicResource Muted}"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="30,6,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="ScoreHeadline" Text="Not checked yet" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" TextWrapping="Wrap"/>
                <TextBlock x:Name="ScoreDetail" Style="{StaticResource Sub}" Margin="0,6,0,6" Text="The check usually takes one to three minutes. Afterwards you see what can be improved – in plain words."/>
                <TextBlock x:Name="ScoreLimited" FontSize="12" Foreground="{DynamicResource Warn}" TextWrapping="Wrap" Margin="0,0,0,6" Visibility="Collapsed" Text="Limited check without administrator rights – the value is only partly meaningful."/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Button x:Name="BtnScan" Style="{StaticResource Primary}" Content="_Check now"/>
                  <Button x:Name="BtnToRecs" Style="{StaticResource Secondary}" Content="_View recommendations" Margin="12,0,0,0" Visibility="Collapsed"/>
                </StackPanel>
                <TextBlock x:Name="LastScanText" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,12,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
          </Border>
          <Expander x:Name="ScoreWhy" Header="Why not 100?" Margin="4,-4,0,14" Visibility="Collapsed">
            <Border Style="{StaticResource Card}" Margin="0,8,0,0">
              <StackPanel>
                <StackPanel x:Name="ScoreWhyList"/>
                <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,10,0,0" Text="The value describes the state of your PC, not how much WinTidy cleaned up. Some points WinTidy cannot fix itself (e.g. settings in the BIOS), others only improve after a few days (e.g. errors in the event log)."/>
              </StackPanel>
            </Border>
          </Expander>
          <UniformGrid x:Name="KpiGrid" Columns="4" Margin="-7,0,-7,0"/>
          <Border x:Name="HwCard" Style="{StaticResource Card}" Margin="0,14,0,0" Visibility="Collapsed">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Hardware" Style="{StaticResource H2}"/>
                <Border Background="{DynamicResource InfoBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock Text="For experts" FontSize="12" Foreground="{DynamicResource InfoFg}"/></Border>
              </StackPanel>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,12" Text="Cooling, drives, memory and monitor. WinTidy changes nothing here. If needed, have changes (e.g. in the BIOS) done by someone who knows what they are doing."/>
              <TextBlock Style="{StaticResource Sub}" FontSize="13" Margin="0,0,0,10" Text="✓ fine   ·   ! keep an eye on it   ·   ✗ take care of it soon"/>
              <StackPanel x:Name="HwPanel"/>
              <StackPanel x:Name="CoolTestPanel" Margin="0,4,0,0"/>
              <WrapPanel Margin="0,8,0,0">
                <Button x:Name="BtnCoolTest" Style="{StaticResource Secondary}" Content="Test cooling (about 1 minute)" AutomationProperties.Name="Test cooling, takes about one minute"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap" Text="The test briefly puts the processor under full load and checks whether the cooling keeps up. The fans get audibly louder. Fan curves themselves are set in the BIOS – WinTidy only measures their effect."/>
            </StackPanel>
          </Border>
          <Border x:Name="HintsCard" Style="{StaticResource Card}" Margin="0,14,0,0" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="Good to know" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,12" Text="WinTidy cannot take care of these points itself."/>
              <StackPanel x:Name="HintsPanel"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Recommendations -->
      <Grid x:Name="PageRecs" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="36,22,36,10">
          <TextBlock Text="Recommendations" Style="{StaticResource H1}"/>
          <TextBlock x:Name="RecsSub" Style="{StaticResource Sub}" Margin="0,4,0,10" Text="No check carried out yet."/>
          <WrapPanel x:Name="RecsLegend" Margin="0,0,0,8">
            <Border Background="{DynamicResource LowBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Safe" FontSize="12" Foreground="{DynamicResource LowFg}"/></Border>
            <TextBlock Text="Junk data, reversible or Windows' own maintenance" FontSize="13" Foreground="{DynamicResource Muted}" Margin="0,2,18,4"/>
            <Border Background="{DynamicResource MidBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Check briefly" FontSize="12" Foreground="{DynamicResource MidFg}"/></Border>
            <TextBlock Text="please check whether you still need it" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,2,18,4"/>
            <Border Background="{DynamicResource HighBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="8,2" Margin="0,0,6,4"><TextBlock Text="Experts only" FontSize="12" Foreground="{DynamicResource HighFg}"/></Border>
            <TextBlock Text="may contain false positives, select each entry individually" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,2,0,4"/>
          </WrapPanel>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnSelRecommended" Style="{StaticResource LinkBtn}" Content="Select recommended"/>
            <TextBlock Text="  ·  " Foreground="{DynamicResource Muted}"/>
            <Button x:Name="BtnSelNone" Style="{StaticResource LinkBtn}" Content="Select nothing"/>
          </StackPanel>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="RecsPanel" Margin="36,6,36,20" MaxWidth="980"/>
        </ScrollViewer>
        <Border Grid.Row="2" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="36,14">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnElevate2" Style="{StaticResource Secondary}" Content="Restart with _administrator rights" Margin="0,0,12,0" Visibility="Collapsed"/>
              <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="_Apply selected"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
              <TextBlock x:Name="SelSummary" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" TextWrapping="Wrap"/>
              <TextBlock x:Name="SelNote" FontSize="12" Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Text="A restore point is created first. Every change is logged."/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>

      <!-- Debloat: ads, suggestions, apps -->
      <Grid x:Name="PageDebloat" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Margin="36,22,36,10">
          <TextBlock Text="Debloat" Style="{StaticResource H1}"/>
          <TextBlock x:Name="DebloatSub" Style="{StaticResource Sub}" Margin="0,4,0,10" Text="Not checked yet." TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnDebloatScan" Style="{StaticResource LinkBtn}" Content="Check again"/>
            <TextBlock Text="  ·  " Foreground="{DynamicResource Muted}"/>
            <Button x:Name="BtnDebloatNone" Style="{StaticResource LinkBtn}" Content="Select nothing"/>
          </StackPanel>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="DebloatPanel" Margin="36,6,36,20" MaxWidth="980" HorizontalAlignment="Left"/>
        </ScrollViewer>
        <Border Grid.Row="2" Background="{DynamicResource CardBg}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="36,14">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnDebloatApply" Style="{StaticResource Primary}" Content="_Apply selected"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
              <TextBlock x:Name="DebloatSummary" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource Ink}" TextWrapping="Wrap"/>
              <TextBlock x:Name="DebloatNote" FontSize="12" Foreground="{DynamicResource Muted}" TextWrapping="Wrap"/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>

      <!-- Work in progress -->
      <ScrollViewer x:Name="PageBusy" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <Border Style="{StaticResource Card}" MaxWidth="660" Margin="36,30" VerticalAlignment="Center" Padding="30">
          <StackPanel>
            <TextBlock x:Name="BusyTitle" Text="Checking your PC …" Style="{StaticResource H2}" FontSize="22"/>
            <TextBlock x:Name="BusyStep" Style="{StaticResource Sub}" Margin="0,8,0,16" Text="One moment please."/>
            <ProgressBar x:Name="BusyBar" Height="10" Minimum="0" Maximum="100" Foreground="{DynamicResource Accent}" Background="{DynamicResource Track}" BorderThickness="0" IsIndeterminate="True"/>
            <DockPanel Margin="0,8,0,0">
              <TextBlock x:Name="BusyElapsed" DockPanel.Dock="Right" FontSize="12" Foreground="{DynamicResource Muted}"/>
              <TextBlock x:Name="BusyCount" FontSize="12" Foreground="{DynamicResource Muted}"/>
            </DockPanel>
            <TextBlock x:Name="BusyHint" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <Border x:Name="BusyUninstall" Background="{DynamicResource MidBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,14,0,0" Visibility="Collapsed">
              <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource MidFg}" FontWeight="SemiBold" Text="An uninstall window opens now. Please click through it – it may be behind this window (check the taskbar)."/>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
              <Button x:Name="BtnCancel" Style="{StaticResource Secondary}" Content="_Cancel" IsCancel="True"/>
              <TextBlock x:Name="CancelNote" FontSize="12" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <Expander Header="Show details" Margin="0,16,0,0">
              <TextBox x:Name="BusyLog" Height="220" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderThickness="0" Padding="8"/>
            </Expander>
          </StackPanel>
        </Border>
      </ScrollViewer>

      <!-- Result -->
      <ScrollViewer x:Name="PageResult" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <DockPanel>
            <Border x:Name="ResultIconBg" Width="44" Height="44" CornerRadius="22" Background="{DynamicResource LowBg}" DockPanel.Dock="Left" VerticalAlignment="Top"><TextBlock x:Name="ResultIcon" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="{DynamicResource Good}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <TextBlock x:Name="ResultTitle" Text="Done!" Style="{StaticResource H1}" Margin="14,0,0,0" VerticalAlignment="Center"/>
          </DockPanel>
          <TextBlock x:Name="ResultSub" Style="{StaticResource Sub}" Margin="0,8,0,20"/>
          <UniformGrid x:Name="ResultGrid" Columns="3" Margin="-7,0,-7,0"/>
          <Border x:Name="ResultNoteCard" Style="{StaticResource Card}" Background="{DynamicResource MidBg}" Visibility="Collapsed">
            <TextBlock x:Name="ResultNote" TextWrapping="Wrap" Foreground="{DynamicResource MidFg}"/>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What exactly happened" Style="{StaticResource H2}"/>
              <StackPanel x:Name="ResultDetails" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Background="{DynamicResource TipBg}" BorderBrush="{DynamicResource TipLine}">
            <TextBlock TextWrapping="Wrap" Foreground="{DynamicResource InfoFg}" Text="Tip: the effect on the boot time only shows after a few restarts. Start the PC normally over the next days and then check again. Under History you see the trend."/>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnRestartNow" Style="{StaticResource Primary}" Content="_Restart PC now" Margin="0,0,12,10"/>
            <Button x:Name="BtnResultReport" Style="{StaticResource Secondary}" Content="Open detailed _report" Margin="0,0,12,10"/>
            <Button x:Name="BtnResultHome" Style="{StaticResource Secondary}" Content="To the _overview" Margin="0,0,12,10"/>
          </WrapPanel>
          <Button x:Name="BtnResultUndo" Style="{StaticResource LinkBtn}" Content="Undo changes …" Margin="0,8,0,0" HorizontalAlignment="Left"/>
        </StackPanel>
      </ScrollViewer>

      <!-- Error -->
      <ScrollViewer x:Name="PageError" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <Border Style="{StaticResource Card}" MaxWidth="660" Margin="36,30" VerticalAlignment="Center" Padding="30">
          <StackPanel>
            <DockPanel>
              <Border Width="44" Height="44" CornerRadius="22" Background="{DynamicResource MidBg}" DockPanel.Dock="Left" VerticalAlignment="Top"><TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="{DynamicResource MidFg}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
              <TextBlock x:Name="ErrTitle" Style="{StaticResource H2}" FontSize="22" Margin="14,0,0,0" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="ErrText" Style="{StaticResource Body}" Margin="0,14,0,0"/>
            <WrapPanel Margin="0,20,0,0">
              <Button x:Name="BtnErrRetry" Style="{StaticResource Primary}" Content="_Try again" Margin="0,0,12,10"/>
              <Button x:Name="BtnErrCopy" Style="{StaticResource Secondary}" Content="_Copy error report" Margin="0,0,12,10"/>
              <Button x:Name="BtnErrHome" Style="{StaticResource Secondary}" Content="To the _overview" Margin="0,0,12,10"/>
            </WrapPanel>
            <TextBlock x:Name="ErrCopied" FontSize="12" Foreground="{DynamicResource Good}" Visibility="Collapsed" Text="The error report is on the clipboard. You can paste it into an e-mail, for example."/>
            <Expander Header="Technical details" Margin="0,12,0,0">
              <TextBox x:Name="ErrDetail" Height="140" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogFg}" BorderThickness="0" Padding="8"/>
            </Expander>
          </StackPanel>
        </Border>
      </ScrollViewer>

      <!-- History -->
      <ScrollViewer x:Name="PageHistory" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="History" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="This is how your PC has developed. Green lines mark optimizations."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Windows boot until ready" Style="{StaticResource H2}"/>
              <Canvas x:Name="BootCanvas" Height="240" Margin="0,14,0,0" ClipToBounds="True"/>
              <TextBlock x:Name="BootNote" FontSize="12" Foreground="{DynamicResource Muted}" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Checks and optimizations" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,4,0,0" Text="For optimizations you can reset settings (startup, scheduled tasks, services) per run."/>
              <StackPanel x:Name="HistoryList" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
          <WrapPanel>
            <Button x:Name="BtnHistReport" Style="{StaticResource Secondary}" Content="Open detailed _report" Margin="0,0,12,10"/>
            <Button x:Name="BtnHistFolder" Style="{StaticResource Secondary}" Content="Open _log folder" Margin="0,0,12,10"/>
            <Button x:Name="BtnHistRstrui" Style="{StaticResource Secondary}" Content="Open _System Restore" Margin="0,0,12,10"/>
          </WrapPanel>
        </StackPanel>
      </ScrollViewer>

      <!-- Settings -->
      <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Settings" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="The default settings suit almost everyone."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Appearance" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <WrapPanel>
                <RadioButton x:Name="OptThemeAuto" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Same as Windows" AutomationProperties.Name="Appearance same as Windows"/>
                <RadioButton x:Name="OptThemeLight" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Light" AutomationProperties.Name="Light appearance"/>
                <RadioButton x:Name="OptThemeDark" GroupName="Theme" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Dark" AutomationProperties.Name="Dark appearance"/>
              </WrapPanel>
              <TextBlock x:Name="ThemeNote" Style="{StaticResource Sub}" FontSize="13" Margin="0,6,0,0" Text="&quot;Same as Windows&quot; follows the setting under Settings › Personalization › Colors."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Language" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <WrapPanel>
                <RadioButton x:Name="OptLangAuto" GroupName="Lang" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Same as Windows" AutomationProperties.Name="Language same as Windows"/>
                <RadioButton x:Name="OptLangDe" GroupName="Lang" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="Deutsch"/>
                <RadioButton x:Name="OptLangEn" GroupName="Lang" Style="{StaticResource Choice}" Margin="0,4,10,4" Content="English"/>
              </WrapPanel>
              <TextBlock x:Name="LangNote" Style="{StaticResource Sub}" FontSize="13" Margin="0,6,0,0" TextWrapping="Wrap" Text="Takes effect after WinTidy restarts."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Safety" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <CheckBox x:Name="OptRestorePoint" IsChecked="True" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Create a restore point before changes <Run Foreground="{DynamicResource Muted}">(strongly recommended)</Run></TextBlock></CheckBox>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="24,2,0,0" Text="A restore point can reset settings, drivers and system files. It does not bring back deleted files and removed programs."/>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="BtnUndo" Style="{StaticResource Secondary}" Content="_Undo last optimization …" Margin="0,0,12,6"/>
                <Button x:Name="BtnRstrui" Style="{StaticResource Secondary}" Content="Open _System Restore" Margin="0,0,12,6"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" Text="WinTidy itself resets startup settings, scheduled tasks, services and some Windows settings. Deleted files do not come back – not even via System Restore. You find individual runs under History."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Check" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <CheckBox x:Name="OptDeep" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Thorough check <Run Foreground="{DynamicResource Muted}">(additionally checks drives and system files, takes up to 30 minutes)</Run></TextBlock></CheckBox>
              <CheckBox x:Name="OptExpert" Margin="0,4"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Expert mode <Run Foreground="{DynamicResource Muted}">(shows technical details and recommendations with a risk of false positives – takes effect from the next check)</Run></TextBlock></CheckBox>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Updates" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <CheckBox x:Name="OptAutoUpdate" Margin="0,4" IsEnabled="False"><TextBlock TextWrapping="Wrap" Foreground="{DynamicResource Ink}">Update WinTidy automatically <Run Foreground="{DynamicResource Muted}">(checks for a new version at most once a day and installs it; a copy of the old version is kept)</Run></TextBlock></CheckBox>
              <WrapPanel Margin="0,10,0,0">
                <Button x:Name="BtnUpdateCheck" Style="{StaticResource Secondary}" Content="Check for u_pdates now" Margin="0,0,12,6" IsEnabled="False"/>
              </WrapPanel>
              <TextBlock x:Name="UpdateStatus" Style="{StaticResource Sub}" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap"/>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap" Text="WinTidy only installs official releases from GitHub, and only after a checksum and a safety check."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Program" Style="{StaticResource H2}" Margin="0,0,0,10"/>
              <WrapPanel>
                <Button x:Name="BtnShortcut" Style="{StaticResource Secondary}" Content="Create _desktop shortcut" Margin="0,0,12,10"/>
                <Button x:Name="BtnDataFolder" Style="{StaticResource Secondary}" Content="Open _data folder" Margin="0,0,12,10"/>
                <Button x:Name="BtnConfig" Style="{StaticResource Secondary}" Content="Edit _configuration" Margin="0,0,12,10" Visibility="Collapsed"/>
              </WrapPanel>
              <TextBlock x:Name="AboutText" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Help -->
      <ScrollViewer x:Name="PageHelp" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="36,22,36,30" MaxWidth="980">
          <TextBlock Text="Help" Style="{StaticResource H1}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,20" Text="The most common questions in brief."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What does WinTidy do?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="WinTidy checks your PC (storage space, startup, leftovers, security, hardware) and suggests improvements. Nothing is changed while checking. Only what you select is applied – it is measured before and after so that you see the difference."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Is it safe?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="WinTidy only uses Windows' own tools, never turns off protection features and creates a restore point before changes. WinTidy can reset settings (startup, tasks, services) itself. On company PCs WinTidy only shows safe points – if in doubt, ask your IT department."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What happens to my files?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="WinTidy does not touch your documents, pictures and downloads. Only things like old temporary files, update leftovers and items that have been in the recycle bin for a long time are deleted. What is deleted does not come back – that is why you see exactly what is affected beforehand."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What do the colors mean?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Green (Safe): junk data, reversible or Windows' own maintenance – preselected. Yellow (Check briefly): please take a quick look whether you still need it. Red (Experts only): may contain false positives, only visible in expert mode and only selectable individually."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Why does the boot time only change later?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Windows measures the boot time itself at every startup. So the effect of an optimization only shows after a few normal restarts. Single slow starts (e.g. after updates) are normal – what matters is the average in the history."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Can WinTidy adjust the fans?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="No. Fan curves are set in the BIOS or in manufacturer programs. WinTidy reads what Windows reliably reports (e.g. temperatures of the graphics card and drives, throttling of the processor) and points out irregularities. Many motherboards do not pass fan data to Windows at all without an additional program."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What does the cooling test do?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="It runs the processor at full load for about a minute and watches whether it slows down due to heat, how warm it gets and whether the fans speed up. The fans get loud – this is intended. If it gets too hot or you unplug the laptop's power adapter, the test stops immediately. Nothing is changed on the PC."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="What to do about a red hardware warning?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="If a drive reports problems, first back up your photos and documents (USB stick, external hard drive or cloud). For cooling warnings, cleaning the dust out of the PC usually helps. In both cases: have the PC checked by someone who knows what they are doing. WinTidy itself changes nothing on the hardware."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Something does not work after the optimization – what to do?" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Body}" Margin="0,6,0,0" Text="Under History you find &quot;Undo …&quot; for every optimization. WinTidy uses it to reset startup, scheduled tasks, services and settings. If that is not enough, use &quot;Open System Restore&quot; under History and choose the point &quot;WinTidy …&quot; from the day of the optimization."/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

# Translate the XAML texts before loading (only when German is active)
function Convert-XamlLanguage([xml]$Doc) {
    if ($Script:Lang -ne 'de' -or $null -eq $Script:De) { return }
    foreach ($node in $Doc.SelectNodes('//*')) {
        foreach ($at in @($node.Attributes)) {
            if ($at.LocalName -in 'Text', 'Content', 'ToolTip', 'Header', 'Title' -or $at.Name -eq 'AutomationProperties.Name') {
                $v = $null; if ($at.Value -match '[A-Za-z]' -and $at.Value -notmatch '^\{' -and $Script:De.TryGetValue($at.Value, [ref]$v)) { $at.Value = $v }
            }
        }
        foreach ($tn in @($node.ChildNodes)) {
            $v = $null; if ($tn.NodeType -eq 'Text' -and $tn.Value.Trim() -match '[A-Za-z]' -and $Script:De.TryGetValue(($tn.Value -replace '\s+', ' ').Trim(), [ref]$v)) { $tn.Value = $v }
        }
    }
}
Convert-XamlLanguage $Xaml
$reader = New-Object System.Xml.XmlNodeReader $Xaml
$Win = [Windows.Markup.XamlReader]::Load($reader)
$UI = @{}
$Xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1; if ($n) { $UI[$n.Value] = $Win.FindName($n.Value) } }

# =============================================================================
#  Colors (incl. high contrast) and helper functions
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
# Set a color as a resource reference (not as a fixed color) so that the element follows a light/dark switch
function Set-Brush($el, [string]$prop, [string]$key) {
    $f = $el.GetType().GetField($prop + 'Property', [Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
    if ($f) { $el.SetResourceReference($f.GetValue($null), $key) } else { $el.$prop = $Win.Resources[$key] }
}

# =============================================================================
#  Light / dark
#  The colors are brushes in the window resources. Switching replaces them; XAML (DynamicResource) and
#  code (Set-Brush = SetResourceReference) only refer to the key and therefore adapt immediately.
# =============================================================================
$ThemeDark = @{
    Bg = '#0B1220'; CardBg = '#141C2B'; Accent = '#2563EB'; AccentDark = '#1D4ED8'; OnAccent = '#FFFFFF'; Link = '#7AAAFB'
    Ink = '#F1F5F9'; Text = '#CBD5E1'; Text2 = '#AAB6C8'; Muted = '#9AA8BC'; Line = '#263244'; BtnLine = '#6B7C96'
    Hover = '#1E293B'; NavSel = '#1E3A6E'; NavSelFg = '#DBEAFE'; Good = '#4ADE80'; Warn = '#FBBF24'; Bad = '#F87171'
    LowBg = '#0B3B22'; LowFg = '#86EFAC'; MidBg = '#3D2A06'; MidFg = '#FCD34D'; HighBg = '#4A1212'; HighFg = '#FCA5A5'
    InfoBg = '#172554'; InfoFg = '#BFDBFE'; TipBg = '#111F3A'; TipLine = '#1E3A8A'; LogBg = '#020617'; LogFg = '#CBD5E1'; Track = '#243042'
}
$ThemeLight = @{}
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
    // Title bar dark/light (Windows 10 20H1+: attribute 20, older builds: 19)
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
    # Replace brushes (WPF freezes brushes used by styles/templates - changing them would not work).
    # All references (DynamicResource in XAML, Set-Brush in code) pick up the new brush automatically.
    foreach ($k in @($pal.Keys)) {
        # .psobject.BaseObject: New-Object returns a PowerShell wrapper object - WPF needs the real brush
        try { $nb = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k])); $nb.Freeze(); $Win.Resources[$k] = $nb.psobject.BaseObject } catch { }
    }
    $Script:IsDark = $dark
    Set-TitleBarDark $dark
}
function Save-AppSettings {
    try {
        $d = Split-Path $AppSettingsFile; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        [ordered]@{ Darstellung = $Script:ThemeMode; Sprache = $Script:LangMode; AutoUpdate = [bool]$Script:AutoUpdate; UpdateGeprueft = $Script:UpdateChecked } | ConvertTo-Json | Out-File -LiteralPath $AppSettingsFile -Encoding utf8
    } catch { }
}
$Script:AutoUpdate = $false; $Script:UpdateChecked = $null
try { if (Test-Path -LiteralPath $AppSettingsFile) { $st = Get-Content -LiteralPath $AppSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$st.Darstellung -in 'Auto', 'Hell', 'Dunkel') { $Script:ThemeMode = [string]$st.Darstellung }; if ($st.AutoUpdate -eq $true) { $Script:AutoUpdate = $true }; if ($st.UpdateGeprueft) { $Script:UpdateChecked = [string]$st.UpdateGeprueft } } } catch { }
Apply-Theme
# Settings: show the selection and switch
if ($HighContrast) {
    foreach ($n in 'OptThemeAuto', 'OptThemeLight', 'OptThemeDark') { $UI[$n].IsEnabled = $false }
    $UI.ThemeNote.Text = (T 'Windows currently uses a contrast theme – WinTidy follows its colors.')
} else {
    $UI[$(switch ($Script:ThemeMode) { 'Hell' { 'OptThemeLight' } 'Dunkel' { 'OptThemeDark' } default { 'OptThemeAuto' } })].IsChecked = $true
}
foreach ($pair in @(@('OptThemeAuto', 'Auto'), @('OptThemeLight', 'Hell'), @('OptThemeDark', 'Dunkel'))) {
    $UI[$pair[0]].Tag = $pair[1]
    $UI[$pair[0]].Add_Checked({ param($s, $e) if ($Script:ThemeMode -ne [string]$s.Tag) { $Script:ThemeMode = [string]$s.Tag; Apply-Theme; Save-AppSettings } })
}
# Language: save the choice; it takes effect after a restart of the app
$UI[$(switch ($Script:LangMode) { 'de' { 'OptLangDe' } 'en' { 'OptLangEn' } default { 'OptLangAuto' } })].IsChecked = $true
foreach ($pair in @(@('OptLangAuto', 'Auto'), @('OptLangDe', 'de'), @('OptLangEn', 'en'))) {
    $UI[$pair[0]].Tag = $pair[1]
    $UI[$pair[0]].Add_Checked({ param($s, $e) if ($Script:LangMode -ne [string]$s.Tag) { $Script:LangMode = [string]$s.Tag; Save-AppSettings; Restart-ForLanguage } })
}
$Win.Add_SourceInitialized({ Set-TitleBarDark $Script:IsDark })
# "Same as Windows": also follow a change in Windows while the window is open
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
#  Background runspace with the WinTidy engine
# =============================================================================
$Sync = [hashtable]::Synchronized(@{ Log = New-Object System.Collections.Concurrent.ConcurrentQueue[string]; Progress = $null; Selection = $null; Expert = $false; Deep = $false; RestorePoint = $true; OhneRP = $false; Lauf = $null; Lang = $Script:Lang })
$Control = [hashtable]::Synchronized(@{ Cancel = $false })
$RS = [runspacefactory]::CreateRunspace()
$RS.ApartmentState = 'STA'; $RS.ThreadOptions = 'ReuseThread'; $RS.Open()
$RS.SessionStateProxy.SetVariable('Sync', $Sync)
$RS.SessionStateProxy.SetVariable('Control', $Control)
$RS.SessionStateProxy.SetVariable('EnginePath', $EnginePath)
$State = @{ CoolTest = $null; Op = $null; Findings = @(); InfoFindings = @(); Snapshot = $null; ScanTime = $null; History = $null; LastResult = $null; Busy = $false; Version = ''; DataDir = $null; Context = $null; Locked = ''; EngineOk = $false; ForceClose = $false; Narrow = $false; Retry = $null; ErrReport = ''; UpdateBlocker = ''; UpdateHours = 24; UpdateMsg = ''; UpdateMode = ''; UpdateRunning = $false; UpdatedTo = '' }
$Stopwatch = New-Object System.Diagnostics.Stopwatch

# Kind: init | scan | fix | undo | silent (background, without progress page)
function Start-Op([string]$Kind, [string]$Script, [scriptblock]$OnDone, [string]$Title = (T 'One moment …'), [string]$Hint = '', [switch]$Silent) {
    if ($State.Busy) { return $false }
    $State.Busy = $true
    $Control.Cancel = $false
    $Sync.Progress = $null
    if (-not $Silent) {
        Set-Nav $false
        $UI.BusyTitle.Text = $Title; $UI.BusyStep.Text = (T 'One moment please.'); $UI.BusyBar.IsIndeterminate = $true; $UI.BusyBar.Value = 0; $UI.BusyLog.Clear()
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
                if ($p.N -gt 0) { $UI.BusyBar.IsIndeterminate = $false; $UI.BusyBar.Value = [math]::Min(97, 100 * $p.I / $p.N); $UI.BusyCount.Text = $(if ($op.Kind -eq 'cooltest' -or $p.Id -eq 'CORE' -or $p.I -lt 1) { '' } else { (T 'Step {0} of {1}') -f $p.I, $p.N }) }
                if ($p.Text) { $UI.BusyStep.Text = [string]$p.Text }
                $uninst = ($p.Id -eq 'APP-SIDEBYSIDE') -or ($op.Kind -eq 'fix' -and [string]$p.Text -match '(?i)deinstall|doppelt installiert|uninstall|installed twice')
                $UI.BusyUninstall.Visibility = $(if ($uninst) { 'Visible' } else { 'Collapsed' })
            }
            $e = $Stopwatch.Elapsed
            $UI.BusyElapsed.Text = ((T 'Running for {0}:{1:00} min.') -f [int][math]::Floor($e.TotalMinutes), $e.Seconds)
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
        Show-ErrorPage (T 'The results could not be displayed') (T 'The work itself is finished. What happened is shown in the history and in the detailed report.') $_.Exception.Message $null
    }
    # Reload the history if it was requested during the operation
    if ($State.HistoryPending -and -not $State.Busy -and $UI.PageHistory.Visibility -eq 'Visible') { $State.HistoryPending = $false; try { Load-History } catch { } }
}

# =============================================================================
#  Navigation, pages, layout
# =============================================================================
$Pages = 'PageHome', 'PageRecs', 'PageDebloat', 'PageBusy', 'PageResult', 'PageError', 'PageHistory', 'PageSettings', 'PageHelp'
$NavItems = 'NavHome', 'NavRecs', 'NavDebloat', 'NavHistory', 'NavSettings', 'NavHelp'
# Is something running right now (also invisible, e.g. loading)? Then say so instead of silently doing nothing.
# Open files (report) via Explorer so that the browser does not start with admin rights
function Open-AsUser([string]$Path) { try { Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList ('"{0}"' -f $Path) } catch { try { Start-Process -FilePath $Path } catch { } } }
function Test-Busy { if ($State.Busy) { Show-Msg (T 'WinTidy is still busy. Please try again in a few seconds.') | Out-Null; return $true }; return $false }
function Show-Page([string]$name) { foreach ($p in $Pages) { $UI[$p].Visibility = $(if ($p -eq $name) { 'Visible' } else { 'Collapsed' }) } }
function Set-Nav([bool]$on) { foreach ($n in $NavItems) { $UI[$n].IsEnabled = $on } }
function Clear-NavSelection { foreach ($n in $NavItems) { $UI[$n].IsChecked = $false } }
$UI.NavHome.Add_Checked({ Show-Page 'PageHome' })
$UI.NavRecs.Add_Checked({ Show-Page 'PageRecs' })
$UI.NavDebloat.Add_Checked({ Show-Page 'PageDebloat'; if ((-not $State.DebloatScanned) -and -not $State.Busy) { Start-DebloatScan } })
$UI.NavHistory.Add_Checked({ Show-Page 'PageHistory'; Load-History })
$UI.NavSettings.Add_Checked({ Show-Page 'PageSettings' })
$UI.NavHelp.Add_Checked({ Show-Page 'PageHelp' })
function Go([string]$nav) { if ($UI[$nav].IsChecked) { $UI[$nav].RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent))) } else { $UI[$nav].IsChecked = $true } }

function Set-Narrow([bool]$narrow) {
    if ($State.Narrow -eq $narrow) { return }
    $State.Narrow = $narrow
    $vis = $(if ($narrow) { 'Collapsed' } else { 'Visible' })
    $UI.NavCol.Width = New-Object System.Windows.GridLength ($(if ($narrow) { 84 } else { 252 }))
    $UI.NavDock.Margin = $(if ($narrow) { '10,22,10,16' } else { '16,22,16,16' })
    foreach ($n in 'BrandText', 'NavT1', 'NavT2', 'NavT3', 'NavT4', 'NavT5', 'NavT6', 'VersionText') { $UI[$n].Visibility = $vis }
}
# Window never larger than the work area (laptops with scaling)
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
#  Notice banners (admin rights, company PC, battery, restart, other account)
# =============================================================================
function Restart-Elevated {
    if ($State.Busy) { return }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$AppPath`"", '-NoElevate', '-Restarted') -ErrorAction Stop
        $State.ForceClose = $true
        $Win.Close()
    } catch { Show-Msg (T 'Windows did not grant administrator rights. WinTidy keeps running with limited functions (check only).') | Out-Null }
}
function Restart-ForLanguage {
    if ($State.Busy -or $State.Op) { return }
    if ((Show-Msg (T 'Restart WinTidy now so that the new language takes effect?') 'YesNo' 'Question') -ne 'Yes') { return }
    Restart-App
}
function Restart-App {
    if ($State.Busy -or $State.Op) { return }
    try {
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$AppPath`"", '-NoElevate', '-Restarted') -ErrorAction Stop
        $State.ForceClose = $true
        $Win.Close()
    } catch { }
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
        $txt = (T 'WinTidy runs without administrator rights. Checking is only possible to a limited extent, changes are not possible.')
        if ($NetDriveProblem) { $txt += (T ' WinTidy is on a network drive – please copy it to this PC first.'); Add-Banner $txt }
        else { Add-Banner $txt 'warn' (T 'Restart with administrator rights') { Restart-Elevated } }
    }
    $c = $State.Context
    if ($c) {
        $hs = @($c.Hinweise | Where-Object { $_ })
        if ($hs.Count) { foreach ($h in $hs) { Add-Banner ([string]$h) } }
        else {
            if ($c.Server) { Add-Banner (T 'Windows Server detected: WinTidy only checks here, changes are blocked.') }
            if ($c.Verwaltet) { Add-Banner (T 'Company PC detected: WinTidy only shows safe cleanup points. If you have questions, please contact your IT department.') }
            if ($c.AnderesKonto) { Add-Banner ((T 'WinTidy runs under the account {0}, but {1} is signed in. Startup programs, temporary files and apps of {1} are therefore not checked.') -f $c.ProzessBenutzer, $c.SitzungsBenutzer) }
            if ($c.NeustartAusstehend) { Add-Banner (T 'Windows wants to restart after updates. Best restart the PC first and check afterwards – then the results are more accurate.') 'info' }
            if ($c.Akku) { Add-Banner (T 'The PC is currently running on battery. Please connect the power adapter – otherwise long steps are skipped.') 'info' }
        }
        $State.Locked = $(if ($c.Server) { (T 'On Windows Server WinTidy only checks. Changes are blocked.') } else { '' })
    }
    # An imminent data loss belongs at the very top, not in the card for experts
    $krit = @(@($State.Findings) + @($State.InfoFindings) | Where-Object { $_ -and "$($_.Id)" -eq 'HW-COOLING' } | ForEach-Object { @($_.Items) } | Where-Object { (Get-ItemLevel $_) -eq 'krit' -and (Get-ItemArea $_) -in 'Laufwerke', 'Speicher' -and (Get-ItemRating $_) -ne 'moment' })
    if ($krit.Count) { Add-Banner ((T 'Important: your PC reports a problem with a drive or the RAM. Back up your photos and documents to a USB stick or the cloud soon and have the PC checked. (') + [string]$krit[0].Label + ')') 'bad' }
    if ($State.Reminder) { Add-Banner ([string]$State.Reminder) 'info' (T 'Check now') { if (-not (Test-Busy)) { Start-Scan } } }
    if ($State.UpdatedTo) { Add-Banner ((T 'WinTidy was updated to version {0}. The new version is used after the next start.') -f $State.UpdatedTo) 'info' (T 'Restart now') { if (-not (Test-Busy)) { Restart-App } } }
    $UI.BannerPanel.Visibility = $(if ($UI.BannerPanel.Children.Count) { 'Visible' } else { 'Collapsed' })
}
$UI.BtnElevate2.Add_Click({ Restart-Elevated })

# =============================================================================
#  Overview
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
    if ($score -ge 85) { $UI.ScoreHeadline.Text = (T 'Your PC is in good shape') }
    elseif ($score -ge 65) { $UI.ScoreHeadline.Text = (T 'Your PC runs – but there is a lot to improve') }
    else { $UI.ScoreHeadline.Text = (T 'Your PC needs some care') }
    Set-A11y $UI.ScoreText ((T 'Health score {0} of 100') -f $score)
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
# Group names are internal keys (German, also used for sorting) - this is the display text
function Get-GroupText([string]$g) {
    switch ($g) { 'Aufräumen' { T 'Clean up' } 'Schneller starten' { T 'Start faster' } 'Programme' { T 'Programs' } 'Windows pflegen' { T 'Maintain Windows' } 'Sicherheit' { T 'Security' } 'Hardware' { T 'Hardware' } 'Hinweise' { T 'Notes' } default { $g } }
}
function Get-ItemLevel($it) {
    foreach ($v in @($it.Stufe, $it.Raw.Stufe, $it.Raw.Data.Stufe)) { if ($v) { return ([string]$v).ToLower() } }
    return ''
}
function Get-ItemArea($it) { foreach ($v in @($it.Bereich, $it.Raw.Data.Bereich)) { if ($v) { return [string]$v } }; return '' }
function Get-ItemRating($it) { foreach ($v in @($it.Wertung, $it.Raw.Data.Wertung)) { if ($v) { return [string]$v } }; return '' }
# Info findings from the last snapshot (if no check was run since the app started)
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
    elseif ((Get-Group $f) -eq 'Hardware') { $code = 0xE82F }   # light bulb = hint (E950 looked like an empty checkbox)
    $ic = New-Icon $code $col 16; $ic.Margin = '0,2,12,0'
    [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
    $tx = New-Object System.Windows.Controls.TextBlock; $tx.TextWrapping = 'Wrap'; Set-Brush $tx 'Foreground' 'Text'
    $vor = if ($lvl -match 'krit') { (T 'Important: ') } else { '' }
    if (-not $NoTitle) { $r1 = New-Object System.Windows.Documents.Run ([string]$f.Titel + ': '); $r1.FontWeight = 'SemiBold'; $tx.Inlines.Add($r1) }
    if ($vor) { $r0 = New-Object System.Windows.Documents.Run $vor; $r0.FontWeight = 'SemiBold'; $tx.Inlines.Add($r0) }
    $tx.Inlines.Add((New-Object System.Windows.Documents.Run ([string]$it.Label)))
    [void]$row.Children.Add($ic); [void]$row.Children.Add($tx)
    Set-A11y $row ("{0}{1}: {2}" -f $(if ($lvl -match 'krit') { (T 'Critical, ') } elseif ($lvl -match 'warn') { (T 'Warning, ') } elseif ($lvl -eq 'ok') { (T 'OK, ') } else { '' }), $f.Titel, $it.Label)
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
            $UI.ScoreDetail.Text = $(if ($cnt) { (T 'WinTidy found {0}. Take your time to look at them – nothing happens without your consent.' (Plural $cnt (T 'possible improvement') (T 'possible improvements'))) } elseif ([int]$s.Score.Wert -ge 85) { (T 'Everything is fine – there is nothing to clean up.') } else { (T 'WinTidy cannot improve anything automatically here. "Why not 100?" and "Good to know" show what else helps.') })
        }
        $UI.BtnScan.Content = (T '_Check again')
        $UI.BtnToRecs.Visibility = $(if ($cnt) { 'Visible' } else { 'Collapsed' })
        $UI.LastScanText.Text = (T 'Last checked: ') + ([datetime]$s.Zeit).ToString((T 'yyyy-MM-dd, HH:mm')) + ''
        $UI.ScoreLimited.Visibility = $(if ($s.Admin -eq $false) { 'Visible' } else { 'Collapsed' })
        # Why not 100?
        $UI.ScoreWhyList.Children.Clear()
        foreach ($z in @($s.Score.Abzuege)) {
            if (-not $z) { continue }
            $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,4'
            $p = New-Tb ('−{0}' -f $z.Punkte) 'Bad' 14 'SemiBold'; $p.Width = 44; [System.Windows.Controls.DockPanel]::SetDock($p, 'Left')
            [void]$row.Children.Add($p); [void]$row.Children.Add((New-Tb ([string]$z.Grund) 'Text' 14))
            [void]$UI.ScoreWhyList.Children.Add($row)
        }
        $UI.ScoreWhy.Visibility = $(if ($UI.ScoreWhyList.Children.Count) { 'Visible' } else { 'Collapsed' })
        # Key figures
        $sys = @($s.Laufwerke) | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
        $boot = if ($s.Boot.Mittel5) { '{0:N0} s' -f ($s.Boot.Mittel5 / 1000) } else { '–' }
        $bootNote = if ($s.Boot.Mittel5) { if ($s.Boot.Mittel5 -gt 60000) { (T 'rather slow') } elseif ($s.Boot.Mittel5 -gt 35000) { (T 'average') } else { (T 'fast') } } else { (T 'measured with admin rights') }
        [void]$UI.KpiGrid.Children.Add((New-Kpi (T 'Windows boot (average)') $boot $bootNote))
        [void]$UI.KpiGrid.Children.Add((New-Kpi (T 'Free on drive {0}' $env:SystemDrive) $(if ($sys) { '{0:N0} GB' -f [double]$sys.FreiGB } else { '–' }) $(if ($sys) { (T '{0:N0} % of {1:N0} GB') -f [double]$sys.FreiProzent, [double]$sys.GroesseGB } else { '' })))
        [void]$UI.KpiGrid.Children.Add((New-Kpi (T 'Startup programs') ('{0:N0}' -f [double]$s.Autostart.Aktiv) $(if ($s.Autostart.Aktiv -gt 10) { (T 'many – slows down the boot') } else { (T 'fine') })))
        $bytes = ($fix | Measure-Object Bytes -Sum).Sum
        [void]$UI.KpiGrid.Children.Add((New-Kpi (T 'Possible space gain') $(if ($bytes) { Fmt-Bytes $bytes } else { '–' }) $(if ($fix.Count) { (T 'estimated') } else { (T 'after the check') })))
        $UI.HomeSub.Text = (T 'See at a glance how your PC is doing.')
    }
    # Hints and hardware (cannot be fixed automatically)
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
    if ($schlimm.Count) { $wt = New-Tb (T 'What to do? For cooling warnings, cleaning the dust out of the PC and having the fans checked usually helps. WinTidy itself changes nothing on the hardware.') 'Muted' 13; $wt.Margin = '0,6,0,4'; $wt.TextWrapping = 'Wrap'; [void]$UI.HwPanel.Children.Add($wt) }
    $UI.HintsCard.Visibility = $(if ($UI.HintsPanel.Children.Count) { 'Visible' } else { 'Collapsed' })
    Show-CoolTest
    $UI.HwCard.Visibility = $(if ($UI.HwPanel.Children.Count -or $State.CoolTest) { 'Visible' } else { 'Collapsed' })
}

# Cooling test: show the result below the hardware points
function Show-CoolTest {
    $UI.CoolTestPanel.Children.Clear()
    $r = $State.CoolTest
    if (-not $r) { return }
    $zeit = ''; try { $zeit = ([datetime]$r.Zeit).ToString((T 'yyyy-MM-dd, HH:mm')) + '' } catch { }
    $f = [pscustomobject]@{ Id = 'HW-COOLTEST'; Kategorie = 'Hardware'; Titel = ((T 'Cooling test ') + $zeit).Trim() }
    foreach ($p in @($r.Punkte | Where-Object { $_ })) { Add-InfoRow $UI.CoolTestPanel $f ([pscustomobject]@{ Label = [string]$p.Text; Stufe = [string]$p.Stufe }) }
}
function Start-CoolTest {
    if (Test-Busy) { return }
    $c = $State.Context
    if ($c -and $c.Akku) { Show-Msg (T 'The cooling test only works with the power adapter connected. Please connect the power adapter and try again.') | Out-Null; return }
    if ($c -and ($c.Server -or $c.VM)) { Show-Msg (T 'On servers and in virtual machines the cooling test makes no sense and is therefore blocked.') | Out-Null; return }
    $q = (T "Start the cooling test?`n`nWinTidy fully loads all processor cores for about one minute and watches performance, temperature and – if a program such as LibreHardwareMonitor is running – the fans.`n`nThe fans get audibly louder. The PC stays usable but gets slower. Best close other programs beforehand. WinTidy changes nothing in the end.{0}`n`nStart now?" ($(if ($c -and $c.Laptop) { "`n`n" + (T 'For laptops: keep the vents clear – not on your lap, a bed or a sofa.') })))
    if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
    [void](Start-Op 'cooltest' @'
if (Get-Command Invoke-GuiCoolingTest -ErrorAction SilentlyContinue) { Invoke-GuiCoolingTest 0 { param($i, $n, $t, $id) $Sync.Progress = @{ I = $i; N = $n; Text = $t; Id = $id } } $Control }
else { [pscustomobject]@{ Status = 'FEHLT'; Meldung = 'This WinTidy version cannot run the cooling test yet.'; Punkte = @() } }
'@ {
        param($r, $err, $cancelled)
        Go 'NavHome'
        if (-not $r) { Show-ErrorPage (T 'The cooling test did not work') (T 'Nothing was changed on the PC. You can start the test again later.') $err $null; return }
        if ($r.Status -in 'AKKU', 'FEHLT', 'GESPERRT') { Show-Msg ([string]$r.Meldung) | Out-Null; return }
        $pts = @($r.Punkte | Where-Object { $_ })
        if ($r.Status -eq 'ABGEBROCHEN') { Show-Msg (T 'The cooling test was cancelled. Nothing was saved and nothing was changed.') | Out-Null; return }
        $State.CoolTest = $r
        Update-Home
        $kopf = if ($r.Status -eq 'GESTOPPT') { (T 'The test was stopped early for safety.') }
                elseif ($pts | Where-Object { $_.Stufe -eq 'krit' }) { (T 'The cooling is not sufficient under load. Have the PC cleaned and the fans checked.') }
                elseif ($pts | Where-Object { $_.Stufe -eq 'warn' }) { (T 'The cooling is reaching its limit. Have the PC cleaned and the fans checked when you get the chance.') }
                elseif (-not ($pts | Where-Object { $_.Stufe -eq 'ok' })) { (T 'The test ran through. But this PC did not report enough to judge the cooling reliably.') }
                else { (T 'The cooling keeps up under load.') }
        $lines = @($pts | ForEach-Object { $sym = switch ($_.Stufe) { 'ok' { '✓' } 'warn' { '!' } 'krit' { '✗' } default { '•' } }; '{0}  {1}' -f $sym, $_.Text })
        $icon = if ($pts | Where-Object { $_.Stufe -eq 'krit' }) { 'Warning' } else { 'Information' }
        Show-Msg ($kopf + "`n`n" + ($lines -join "`n") + (T "`n`nThe result is also shown on the overview under Hardware.")) 'OK' $icon | Out-Null
    } (T 'Cooling test running …') (T 'The fans get louder now – that is intended. The test takes about one minute.'))
}
$UI.BtnCoolTest.Add_Click({ Start-CoolTest })

# =============================================================================
#  Recommendations
# =============================================================================
$GroupOrder = @('Aufräumen', 'Schneller starten', 'Windows pflegen', 'Programme', 'Sicherheit', 'Hinweise', 'Hardware')
$RiskUi = @{
    'Niedrig' = @((T 'Safe'), 'LowBg', 'LowFg')
    'Mittel'  = @((T 'Check briefly'), 'MidBg', 'MidFg')
    'Hoch'    = @((T 'Experts only'), 'HighBg', 'HighFg')
}
$EndgueltigIds = 'CLN-TEMP', 'CLN-WINCLEAN', 'CLN-WINOLD', 'CLN-WINSXS', 'CLN-DUMPS', 'CLN-RECYCLE', 'CLN-RECYCLE-ORPHAN', 'CLN-DRIVERSTORE', 'CLN-ORPHANDIR', 'APP-SIDEBYSIDE', 'APP-BLOAT', 'APP-UPDATES', 'SYS-GHOST'
function Test-Endgueltig($f) { if ($null -ne $f.Endgueltig) { return [bool]$f.Endgueltig }; return ($EndgueltigIds -contains $f.Id) }
function Test-Umkehrbar($f) { if ($null -ne $f.Umkehrbar) { return [bool]$f.Umkehrbar }; return ("$($f.Id)" -match '^(STA|TSK|SVC)-|^SYS-GAMEDVR$') }
function Test-Einzeln($f) { return ([bool]$f.Einzeln -or $f.Risiko -eq 'Hoch') }
function Get-CleanWhy([string]$t) {
    # Command line hints (-Rule, -Yes, -Deep) do not belong in the app
    (($t -split '(?<=[\.\!\?])\s+') | Where-Object { $_ -notmatch '(^|\s|\()-(Rule|Yes|Deep|IncludeMedium|NoRestorePoint)\b' }) -join ' '
}

function Update-SelSummary {
    $n = 0; $b = 0
    foreach ($f in $State.Findings) { foreach ($it in @($f.Items)) { if ($it.Selected) { $n++; $b += $it.Bytes } } }
    $UI.SelSummary.Text = if ($n) { ((T '{0} selected') -f (Plural $n (T 'change') (T 'changes'))) + $(if ($b) { (T ' · approx. {0} of space' (Fmt-Bytes $b)) } else { '' }) } else { (T 'Nothing selected') }
    $UI.BtnApply.IsEnabled = ($n -gt 0 -and $IsAdmin -and -not $State.Locked)
    $UI.BtnElevate2.Visibility = $(if ($IsAdmin -or $NetDriveProblem) { 'Collapsed' } else { 'Visible' })
    $UI.SelNote.Text = if (-not $IsAdmin) { (T 'WinTidy needs administrator rights to apply changes.') } elseif ($State.Locked) { $State.Locked } elseif ($UI.OptRestorePoint.IsChecked) { (T 'A restore point is created first. Every change is logged.') } else { (T 'Caution: no restore point is created (see Settings).') }
    $total = [int](@($State.Findings | Where-Object Fixbar | ForEach-Object { @($_.Items).Count }) | Measure-Object -Sum).Sum
    if ($total) { $UI.RecsBadge.Visibility = 'Visible'; $UI.RecsBadgeText.Text = "$total" } else { $UI.RecsBadge.Visibility = 'Collapsed' }
    Set-A11y $UI.BtnApply ((T 'Apply selected: ') + $UI.SelSummary.Text)
    Update-DebloatSummary
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
        Set-A11y $cb ((T '{0} – {1} – select all entries') -f $f.Titel, $riskName) ([string]$f.Text)
        [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left'); [void]$head.Children.Add($cb)
    } else {
        $sp0 = New-Object System.Windows.Controls.Border; $sp0.Width = 28; [System.Windows.Controls.DockPanel]::SetDock($sp0, 'Left'); [void]$head.Children.Add($sp0)
    }
    $size = New-Tb (Fmt-Bytes $f.Bytes) 'Link' 14 'SemiBold'; $size.VerticalAlignment = 'Center'; $size.Margin = '12,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($size, 'Right'); [void]$head.Children.Add($size)
    $titleRow = New-Object System.Windows.Controls.WrapPanel
    $tt = New-Tb ([string]$f.Titel) 'Ink' 16 'SemiBold'; $tt.VerticalAlignment = 'Center'
    [void]$titleRow.Children.Add($tt); $bd = New-Badge $f.Risiko; if ($bd) { [void]$titleRow.Children.Add($bd) }
    if ($einzeln) { $en = New-Tb (T 'select each entry individually') 'Muted' 12; $en.Margin = '10,0,0,0'; $en.VerticalAlignment = 'Center'; [void]$titleRow.Children.Add($en) }
    [void]$head.Children.Add($titleRow)
    [void]$outer.Children.Add($head)
    $desc = New-Tb ([string]$f.Text) 'Text2' 14; $desc.Margin = '32,6,0,0'; [void]$outer.Children.Add($desc)
    # Affected: name up to three items directly
    $labels = @(@($f.Items) | ForEach-Object { $l = [string]$_.Label; if ($l.Length -gt 60) { $l.Substring(0, 57) + '…' } else { $l } })
    if ($labels.Count) {
        $more = $labels.Count - 3
        $nm = New-Tb ((T 'Affects: ') + (($labels | Select-Object -First 3) -join ', ') + $(if ($more -gt 0) { (T ' and {0} more' $more) } else { '' })) 'Muted' 12; $nm.Margin = '32,4,0,0'
        [void]$outer.Children.Add($nm)
    }
    if ($f.Dauer) { $du = New-Tb ((T 'Duration: ') + [string]$f.Dauer) 'Muted' 12; $du.Margin = '32,2,0,0'; [void]$outer.Children.Add($du) }
    if ($gesperrt) {
        $gp = New-Object System.Windows.Controls.DockPanel; $gp.Margin = '32,6,0,0'
        $gi = New-Icon 0xE72E 'Warn' 13; $gi.Margin = '0,1,8,0'; [System.Windows.Controls.DockPanel]::SetDock($gi, 'Left')
        [void]$gp.Children.Add($gi); [void]$gp.Children.Add((New-Tb ((T 'Not possible right now: ') + $gesperrt) 'Warn' 13))
        [void]$outer.Children.Add($gp)
    }
    $exp = New-Object System.Windows.Controls.Expander; $exp.Margin = '28,8,0,0'
    $exp.Header = $(if ($einzeln) { (T 'Select entries ({0})' (@($f.Items).Count)) } elseif (@($f.Items).Count -eq 1) { 'Details' } else { (T 'Details ({0} entries)' (@($f.Items).Count)) })
    $exp.IsExpanded = ($einzeln -or $f.Risiko -eq 'Mittel' -or $f.Seite -eq 'Debloat')
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
        if ($w) { $why = New-Tb (T 'Technical: {0}' $w) 'Muted' 12; $why.Margin = '0,8,0,0'; [void]$list.Children.Add($why) }
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
    $UI.RecsSub.Text = if ($cnt) { (T 'WinTidy found {0}. Recommended points are already selected. Points with a check mark are applied.' (Plural $cnt (T 'possible improvement') (T 'possible improvements'))) } elseif ($State.ScanTime) { (T 'No points found that can be fixed automatically.') } else { (T 'No check carried out yet. Start it on the overview.') }
    $UI.RecsLegend.Visibility = $(if ($cnt) { 'Visible' } else { 'Collapsed' })
    $groups = @($fix | Group-Object { Get-Group $_ } | Sort-Object @{ Expression = { $i = [array]::IndexOf($GroupOrder, $_.Name); if ($i -lt 0) { 99 } else { $i } } })
    foreach ($g in $groups) {
        $h = New-Tb (Get-GroupText $g.Name) 'Muted' 13 'SemiBold'; $h.Margin = '2,10,0,8'
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
#  Debloat page (own tab): same cards as the recommendations, but its own check and its own apply button
# =============================================================================
$State.DebloatFindings = @(); $State.DebloatHint = ''; $State.DebloatScanned = $false; $State.DebloatScanTime = $null; $State.LastFixPage = ''
$DebloatOrder = 'DBL-ADS', 'DBL-PRIVACY', 'DBL-SHELL', 'DBL-COMFORT', 'DBL-APPS-PROMO', 'DBL-APPS-MS', 'DBL-APPS-OEM'
function Update-DebloatSummary {
    $n = 0
    foreach ($f in @($State.DebloatFindings)) { foreach ($it in @($f.Items)) { if ($it.Selected) { $n++ } } }
    $UI.DebloatSummary.Text = if ($n) { (T '{0} selected') -f (Plural $n (T 'change') (T 'changes')) } else { (T 'Nothing selected') }
    $UI.BtnDebloatApply.IsEnabled = ($n -gt 0 -and $IsAdmin -and -not $State.Locked)
    $UI.DebloatNote.Text = if (-not $IsAdmin) { (T 'WinTidy needs administrator rights to apply changes.') } elseif ($State.Locked) { $State.Locked } elseif ($UI.OptRestorePoint.IsChecked) { (T 'A restore point is created first. Every change is logged.') } else { (T 'Caution: no restore point is created (see Settings).') }
    Set-A11y $UI.BtnDebloatApply ((T 'Apply selected: ') + $UI.DebloatSummary.Text)
}
function Build-Debloat {
    $UI.DebloatPanel.Children.Clear()
    $fix = @($State.DebloatFindings | Where-Object Fixbar)
    $cnt = [int](@($fix | ForEach-Object { @($_.Items).Count }) | Measure-Object -Sum).Sum
    $UI.DebloatSub.Text = if ($State.DebloatHint) { $State.DebloatHint } elseif ($cnt) { (T 'WinTidy found {0}. Only ads and suggestions are preselected - everything else is up to you. Settings can be undone under History; removed apps can be reinstalled from the Store.' (Plural $cnt (T 'possible change') (T 'possible changes'))) } elseif ($State.DebloatScanned) { (T 'Nothing to tidy up here - your PC is already clean.') } else { (T 'Not checked yet.') }
    $lastKind = ''
    foreach ($id in $DebloatOrder) {
        $f = $fix | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $f) { continue }
        $kind = $(if ($id -like 'DBL-APPS-*') { 'apps' } else { 'settings' })
        if ($kind -ne $lastKind) {
            $h = New-Tb $(if ($kind -eq 'apps') { T 'Apps' } else { T 'Settings' }) 'Muted' 13 'SemiBold'; $h.Margin = '2,10,0,8'
            [void]$UI.DebloatPanel.Children.Add($h); $lastKind = $kind
        }
        [void]$UI.DebloatPanel.Children.Add((New-RecCard $f))
    }
    Update-DebloatSummary
}
function Start-DebloatScan {
    if (Test-Busy) { return }
    [void](Start-Op 'scan' @'
$r = Invoke-GuiDebloatScan { param($i, $n, $t) $Sync.Progress = @{ I = $i; N = $n; Text = $t } }
$r
'@ {
        param($r, $err, $cancelled)
        if ($cancelled) { Go 'NavHome'; return }
        if (-not $r) {
            Write-ErrLog "Debloat: $err"
            Show-ErrorPage (T 'The check could not be completed') (T 'Nothing was changed on your PC. Please try again. If it happens again, copy the error report and send it to the person who gave you WinTidy.') $err { Start-DebloatScan }
            return
        }
        $State.DebloatFindings = @($r.Findings); $State.DebloatHint = [string]$r.Hinweis; $State.DebloatScanned = $true; $State.DebloatScanTime = Get-Date
        if ($r.Context) { $State.Context = $r.Context; Update-Banners }
        Build-Debloat; Go 'NavDebloat'
    } (T 'Looking for ads, suggestions and apps ...') (T 'Nothing is changed. This only takes a few seconds.'))
}
$UI.BtnDebloatScan.Add_Click({ Start-DebloatScan })
$UI.BtnDebloatNone.Add_Click({ foreach ($f in @($State.DebloatFindings)) { foreach ($it in @($f.Items)) { $it.Selected = $false } }; Build-Debloat })

# =============================================================================
#  Error page (friendly, with "Try again" and "Copy error report")
# =============================================================================
function Show-ErrorPage([string]$title, [string]$text, [string]$detail, [scriptblock]$retry) {
    $UI.ErrTitle.Text = $title; $UI.ErrText.Text = $text; $UI.ErrDetail.Text = [string]$detail; $UI.ErrCopied.Visibility = 'Collapsed'
    $State.Retry = $retry
    $UI.BtnErrRetry.Visibility = $(if ($retry) { 'Visible' } else { 'Collapsed' })
    $tail = ''
    try { if (Test-Path -LiteralPath $ErrLog) { $tail = (Get-Content -LiteralPath $ErrLog -Tail 40 -Encoding UTF8) -join "`r`n" } } catch { }
    $os = ''; try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | ForEach-Object { "$($_.Caption) $($_.Version)" }) } catch { }
    $State.ErrReport = "WinTidy error report`r`nVersion: $($State.Version)`r`nTime: $(Get-Date -Format 's')`r`nSystem: $os`r`nAdmin: $IsAdmin`r`n`r`n$title`r`n$detail`r`n`r`n--- Log ($ErrLog) ---`r`n$tail"
    Clear-NavSelection
    Show-Page 'PageError'
}
$UI.BtnErrRetry.Add_Click({ $r = $State.Retry; if ($r) { & $r } })
$UI.BtnErrCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText($State.ErrReport); $UI.ErrCopied.Visibility = 'Visible' } catch { Show-Msg (T "Copying is not possible. The error file is here:`n{0}" $ErrLog) | Out-Null } })
$UI.BtnErrHome.Add_Click({ Go 'NavHome' })

# =============================================================================
#  Check
# =============================================================================
function Start-Scan {
    if (Test-Busy) { return }
    $Sync.Expert = [bool]$UI.OptExpert.IsChecked; $Sync.Deep = [bool]$UI.OptDeep.IsChecked
    $hint = if ($Sync.Deep) { (T 'Nothing is changed. The thorough check can take up to 30 minutes.') } else { (T 'Nothing is changed. This usually takes one to three minutes. Best not to do much else in the meantime – otherwise the measurements get less accurate.') }
    [void](Start-Op 'scan' @'
$r = Invoke-GuiScan $Sync.Expert $Sync.Deep { param($i, $n, $t) $Sync.Progress = @{ I = $i; N = $n; Text = $t } }
$r
'@ {
        param($r, $err, $cancelled)
        if ($cancelled) { Go 'NavHome'; $UI.LastScanText.Text = (T 'Check cancelled. Nothing was changed on your PC.'); return }
        if (-not $r -or -not $r.Snapshot) {
            Write-ErrLog "Scan: $err"
            Show-ErrorPage (T 'The check could not be completed') (T 'Nothing was changed on your PC. Please try again. If it happens again, copy the error report and send it to the person who gave you WinTidy.') $err { Start-Scan }
            return
        }
        $State.Findings = @($r.Findings); $State.Snapshot = $r.Snapshot; $State.ScanTime = Get-Date; $State.InfoFindings = @(); $State.Reminder = ''
        if ($r.Context) { $State.Context = $r.Context }
        Update-Banners
        Update-Home; Build-Recs; Go 'NavHome'
    } (T 'Checking your PC …') $hint)
}
$UI.BtnScan.Add_Click({ Start-Scan })

# =============================================================================
#  Apply
# =============================================================================
function Get-SelectedJobs([string]$Page = '') {
    $jobs = @()
    foreach ($f in $(if ($Page) { @($State.DebloatFindings) } else { @($State.Findings) })) { foreach ($it in @($f.Items)) { if ($it.Selected) { $jobs += [pscustomobject]@{ F = $f; It = $it } } } }
    $jobs
}
function Start-Fix([bool]$ohneRP, [string]$Page = '') {
    $sel = @()
    $State.LastFixPage = $Page
    foreach ($f in $(if ($Page) { @($State.DebloatFindings) } else { @($State.Findings) })) { $ix = @(@($f.Items) | Where-Object Selected | ForEach-Object { $_.Index }); if ($ix.Count) { $sel += @{ Id = $f.Id; Indexes = $ix } } }
    if (-not $sel.Count) { return }
    $Sync.Selection = $sel; $Sync.RestorePoint = [bool]$UI.OptRestorePoint.IsChecked; $Sync.OhneRP = $ohneRP
    [void](Start-Op 'fix' @'
$r = Invoke-FixSelection $Sync.Selection $Sync.RestorePoint { param($i, $n, $t, $id) $Sync.Progress = @{ I = $i; N = $n; Text = $t; Id = $id } } $Control $Sync.OhneRP
$r
'@ {
        param($r, $err, $cancelled)
        if (-not $r) {
            Write-ErrLog "Fix: $err"
            Show-ErrorPage (T 'Something went wrong while applying') (T 'WinTidy stopped the work. What was done up to then is shown in the history and in the report. If something no longer works afterwards: undo the optimization under History or use Windows System Restore.') $err $null
            return
        }
        if ($r.Status -eq 'RP-FEHLT') {
            $q = (T "Windows could not create a restore point.`n") + $(if ($r.Meldung) { (T "(Reason: {0})`n" ($r.Meldung)) } else { '' }) + (T "`nNothing has been changed in your files and settings so far.") + $(if ($r.ComputerschutzEingeschaltet) { (T ' WinTidy only switched on Windows System Restore for drive {0} for this.' $env:SystemDrive) } else { '' }) + (T "`n`nWithout a restore point, changes to drivers and Windows are harder to undo. WinTidy can still reset startup, tasks and services itself.`n`nContinue anyway? (Recommended: No)")
            if ([System.Windows.MessageBox]::Show($Win, $q, 'WinTidy', 'YesNo', 'Warning', 'No') -eq 'Yes') { Start-Fix $true $State.LastFixPage } else { Go $(if ($State.LastFixPage) { 'NavDebloat' } else { 'NavRecs' }) }
            return
        }
        if ($r.Status -eq 'GESPERRT') { Show-Msg ((T "Changes are blocked on this PC.`n`n") + [string]$r.Meldung) | Out-Null; Go $(if ($State.LastFixPage) { 'NavDebloat' } else { 'NavRecs' }); return }
        $State.LastResult = $r; if ($r.Nachher) { $State.Snapshot = $r.Nachher }
        Show-Result $r
    } (T 'Optimizing your PC …') (T 'Please keep the PC switched on. You can cancel at any time – WinTidy then stops after the current step.'))
}
function Confirm-Apply([string]$Page = '') {
    if (Test-Busy) { return }
    $jobs = @(Get-SelectedJobs $Page)
    $n = $jobs.Count
    if (-not $n) { return }
    # Outdated check?
    $scanTime = $(if ($Page) { $State.DebloatScanTime } else { $State.ScanTime })
    if ($scanTime -and ((Get-Date) - $scanTime).TotalMinutes -gt 30) {
        $min = [int]((Get-Date) - $scanTime).TotalMinutes
        $a = Show-Msg ((T "The check is already {0} minutes old. Something may have changed since then.`n`nYes = check again first (recommended)`nNo = continue with the old check") -f $min) 'YesNoCancel' 'Question'
        if ($a -eq 'Yes') { if ($Page) { Start-DebloatScan } else { Start-Scan }; return }
        if ($a -ne 'No') { return }
    }
    $nEnd = @($jobs | Where-Object { Test-Endgueltig $_.F }).Count
    $nUm = @($jobs | Where-Object { -not (Test-Endgueltig $_.F) -and (Test-Umkehrbar $_.F) }).Count
    $einz = @($jobs | Where-Object { Test-Einzeln $_.F })
    $dauer = @($jobs | Where-Object { $_.F.Dauer } | ForEach-Object { [string]$_.F.Dauer } | Select-Object -Unique)
    $uninst = [bool]($jobs | Where-Object { $_.F.Id -eq 'APP-SIDEBYSIDE' })
    $msg = $(if ($n -eq 1) { (T "1 change will be applied.`n") } else { (T "{0} changes will be applied.`n" $n) })
    if ($nUm) { $msg += (T "  • WinTidy can undo {0} of them later.`n" $nUm) }
    if ($nEnd) { $msg += (T "  • {0} {1} permanent (deleting files, removing programs or apps).`n" $nEnd ($(if ($nEnd -eq 1) { T 'of them is' } else { T 'of them are' }))) }
    if ($einz.Count) { $msg += (T "`nSelected individually (Experts only):`n") + ((@($einz | Select-Object -First 10) | ForEach-Object { '  – ' + [string]$_.It.Label }) -join "`n") + $(if ($einz.Count -gt 10) { (T "`n  … and {0} more" ($einz.Count - 10)) } else { '' }) + "`n" }
    if ($dauer.Count) { $msg += (T "`nSome steps take longer ({0}). Please keep the PC switched on until then.`n" ($dauer -join ', ')) }
    if ($UI.OptRestorePoint.IsChecked) { $msg += (T "`nWinTidy creates a restore point first. It can reset settings, drivers and system files. Deleted files and removed programs do not come back with it.`n") }
    else { $msg += (T "`nCAUTION: NO restore point is created.`n") }
    if ($uninst) { $msg += (T "`nFor programs installed twice, the uninstaller opens for each one. It may be behind the WinTidy window.`n") }
    if ($jobs | Where-Object { $_.F.Id -eq 'APP-UPDATES' }) { $msg += (T "`nPlease save and close all programs beforehand – updates can close open programs.`n") }
    $msg += (T "`nStart now?")
    if ((Show-Msg $msg 'YesNo' 'Question') -ne 'Yes') { return }
    Start-Fix $false $Page
}
$UI.BtnApply.Add_Click({ Confirm-Apply '' })
$UI.BtnDebloatApply.Add_Click({ Confirm-Apply 'Debloat' })
$UI.BtnCancel.Add_Click({
    $op = $State.Op; if (-not $op) { return }
    if ($op.Kind -eq 'scan') { $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = (T 'Cancelling …'); try { [void]$op.PS.BeginStop($null, $null) } catch { } }
    elseif ($op.Kind -eq 'cooltest') { $Control.Cancel = $true; $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = (T 'Cancelling …') }
    elseif ($op.Kind -eq 'fix') { $Control.Cancel = $true; $op.Cancelled = $true; $UI.BtnCancel.IsEnabled = $false; $UI.CancelNote.Text = (T 'WinTidy stops after the current step. With long steps this can take a while.') }
})

function New-ResultTile([string]$label, $before, $after, [string]$unit, [string]$better, [int]$dec = 0) {
    $d = $null; if ($null -ne $before -and $null -ne $after) { $d = [math]::Round([double]$after - [double]$before, $dec) }
    $good = $d -and (($better -eq 'lower' -and $d -lt 0) -or ($better -eq 'higher' -and $d -gt 0))
    $bad = $d -and -not $good
    $b = New-Object System.Windows.Controls.Border; $b.Style = $Win.FindResource('Card'); $b.Margin = '7,0,7,14'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t2 = New-Tb ((Fmt-Num $after $dec) + ' ' + $unit).Trim() 'Ink' 24 'SemiBold'; $t2.Margin = '0,4,0,2'
    $t3txt = if ($null -eq $d -or $d -eq 0) { (T 'before {0} {1} · unchanged') -f (Fmt-Num $before $dec), $unit } else { (T 'before {0} {1} · {2}{3} {1}') -f (Fmt-Num $before $dec), $unit, $(if ($d -gt 0) { '+' } else { '' }), (Fmt-Num $d $dec) }
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
    if (@($rows).Count -gt 100) { [void]$UI.ResultDetails.Children.Add((New-Tb ((T '… and {0} more (see report)') -f (@($rows).Count - 100)) 'Muted' 12)) }
}
function Show-Result($r) {
    $fail = [int]$r.Fehler; $ok = [int]$r.OK; $tot = [int]$r.Aktionen
    $abgebrochen = ($r.Status -eq 'ABGEBROCHEN')
    if ($abgebrochen) {
        $UI.ResultTitle.Text = (T 'Cancelled')
        $UI.ResultSub.Text = ((T 'Cancelled after {0} of {1} steps. The rest was not carried out.') -f $ok, $tot)
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } elseif ($ok -eq 0 -and -not $fail) {
        $UI.ResultTitle.Text = (T 'Nothing applied')
        $UI.ResultSub.Text = (T 'All selected steps were skipped – the reasons are below.')
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } elseif ($fail) {
        $UI.ResultTitle.Text = (T 'Done – some points could not be applied')
        $UI.ResultSub.Text = ((T '{0} of {1} applied successfully, {2} not possible. The reasons are below.') -f $ok, (Plural $tot (T 'change') (T 'changes')), $fail)
        $UI.ResultIcon.Text = [string][char]0xE7BA; Set-Brush $UI.ResultIcon 'Foreground' 'MidFg'; Set-Brush $UI.ResultIconBg 'Background' 'MidBg'
    } else {
        $UI.ResultTitle.Text = (T 'Done!')
        $UI.ResultSub.Text = ((T '{0} applied successfully.') -f (Plural $ok (T 'change') (T 'changes')))
        $UI.ResultIcon.Text = [string][char]0xE73E; Set-Brush $UI.ResultIcon 'Foreground' 'Good'; Set-Brush $UI.ResultIconBg 'Background' 'LowBg'
    }
    $notes = @()
    if ($r.Wiederherstellungspunkt -eq $false) { $notes += (T 'No restore point was created.') }
    if ($r.ComputerschutzEingeschaltet) { $notes += (T 'Note: Windows System Restore was switched off. WinTidy switched it on for drive ') + $env:SystemDrive + (T ' so that a restore point could be created.') }
    $UI.ResultNote.Text = ($notes -join "`n"); $UI.ResultNoteCard.Visibility = $(if ($notes.Count) { 'Visible' } else { 'Collapsed' })
    # Tiles
    $UI.ResultGrid.Children.Clear()
    $m = @{}; foreach ($x in @($r.Vergleich)) { if ($x) { $m[$x.Kennzahl] = $x } }
    $pick = @(
        @('Health-Score', (T 'Health score'), '', 'higher', 0),
        @('Aktive Autostarts', (T 'Startup programs'), '', 'lower', 0),
        @('Treiberpakete', (T 'Driver packages'), '', 'lower', 0),
        @('Geistergeraete', (T 'Old device entries'), '', 'lower', 0),
        @('Store-Apps', (T 'Store apps'), '', 'lower', 0)
    )
    $fa = $null; $fb = $null
    if ($r.Vorher -and $r.Nachher) { $fa = (@($r.Vorher.Laufwerke) | Measure-Object FreiGB -Sum).Sum; $fb = (@($r.Nachher.Laufwerke) | Measure-Object FreiGB -Sum).Sum }
    if ($null -ne $fa -and $null -ne $fb) {
        $t = New-ResultTile (T 'Free space (measured, all drives)') ([math]::Round($fa, 1)) ([math]::Round($fb, 1)) 'GB' 'neutral' 1
        $t.Child.Children[1].Text = ('{0:+0.0;-0.0;0.0} GB' -f ($fb - $fa))
        $t.Child.Children[2].Text = $(if (($fb - $fa) -lt 0) { (T 'The restore point itself takes up some space. The gain often only shows after a restart.') } elseif ($r.Bytes) { (T 'estimate was {0} – Windows only releases some of it after a restart' (Fmt-Bytes $r.Bytes)) } else { (T 'Difference before/after') })
        Set-Brush $t.Child.Children[2] 'Foreground' 'Muted'
        [void]$UI.ResultGrid.Children.Add($t)
    }
    foreach ($p in $pick) { $x = $m[$p[0]]; if ($x) { [void]$UI.ResultGrid.Children.Add((New-ResultTile $p[1] $x.Vorher $x.Nachher $p[2] $p[3] $p[4])) } }
    # What exactly happened
    $UI.ResultDetails.Children.Clear()
    $det = @($r.Details | Where-Object { $_ })
    if ($det.Count) {
        Add-ResultGroup (T 'Done') 'Good' 0xE73E @($det | Where-Object { $_.Status -eq 'OK' })
        Add-ResultGroup (T 'Not possible') 'Bad' 0xE7BA @($det | Where-Object { $_.Status -eq 'Fehler' })
        Add-ResultGroup (T 'Skipped') 'Muted' 0xE711 @($det | Where-Object { $_.Status -eq 'Uebersprungen' })
        Add-ResultGroup (T 'Not carried out') 'Muted' 0xE711 @($det | Where-Object { $_.Status -notin 'OK', 'Fehler', 'Uebersprungen' })
    } else { [void]$UI.ResultDetails.Children.Add((New-Tb (T 'The details are in the detailed report.') 'Muted' 13)) }
    # Applied recommendations are done: keep only hints, check again for new recommendations
    if ($State.LastFixPage -eq 'Debloat') {
        $State.DebloatFindings = @(); $State.DebloatScanned = $false; $State.DebloatScanTime = $null; $State.DebloatHint = ''
        Build-Debloat
    } else {
        $State.Findings = @($State.Findings | Where-Object { -not $_.Fixbar }); $State.ScanTime = $null
        Update-Home; Build-Recs
        $UI.RecsSub.Text = (T 'The selected recommendations have been processed. Check again to see the current state.')
        $UI.ScoreDetail.Text = (T 'Optimization complete. Please check again for new recommendations.')
    }
    Clear-NavSelection; Show-Page 'PageResult'
}
$UI.BtnResultHome.Add_Click({ Go 'NavHome' })
$UI.BtnResultReport.Add_Click({ $p = if ($State.LastResult) { $State.LastResult.Report } else { $null }; if ($p -and (Test-Path -LiteralPath $p)) { Open-AsUser $p } else { Show-Msg (T 'The report was not found.') | Out-Null } })
$UI.BtnRestartNow.Add_Click({ if ((Show-Msg (T 'The PC will now restart. Please save everything first.') 'OKCancel' 'Information') -eq 'OK') { Start-Process shutdown.exe -ArgumentList '/r /t 5 /c "WinTidy: restart after optimization"' } })

# =============================================================================
#  Undo
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
        if (-not $r -or -not $r.Lauf) { Show-Msg (T 'There is no optimization yet that could be undone.') | Out-Null; return }
        $zeit = ''; try { $zeit = [datetime]::ParseExact($r.Lauf.Substring(0, 15), 'yyyyMMdd-HHmmss', $null).ToString((T 'yyyy-MM-dd, HH:mm')) + '' } catch { $zeit = $r.Lauf }
        $items = @($r.Items | Where-Object { $_ })
        if ($r.HatVorschau -and -not $items.Count) {
            if ((Show-Msg (T "There is nothing WinTidy can reset itself for the optimization of {0}.`n`nDeleted files and removed programs do not come back. Drivers and system changes can be reset with Windows System Restore.`n`nOpen System Restore now?" $zeit) 'YesNo' 'Information') -eq 'Yes') { Open-Rstrui }
            return
        }
        $liste = if ($items.Count) { "`n" + ((@($items | Select-Object -First 15) | ForEach-Object { '  – {0}: {1}' -f $_.Art, $_.Objekt }) -join "`n") + $(if ($items.Count -gt 15) { (T "`n  … and {0} more" ($items.Count - 15)) } else { '' }) + "`n" } else { (T "`nStartup settings, scheduled tasks and services of this run.`n") }
        $q = (T "Undo the optimization of {0}?`n`nWinTidy resets:{1}`nDeleted files and removed programs do not come back – not even via System Restore.`n`nContinue?" $zeit $liste)
        if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
        $Sync.Lauf = $r.Lauf
        [void](Start-Op 'undo' @'
$x = Invoke-GuiRestore $Sync.Lauf
if ($null -eq $x) { [pscustomobject]@{ Wiederhergestellt = $null; Fehler = 0; Details = @() } } else { $x }
'@ {
                param($x, $err2, $c2)
                if (-not $x) { Show-ErrorPage (T 'Undo did not work') (T 'WinTidy could not reset the settings. You can use Windows System Restore (History → Open System Restore).') $err2 $null; return }
                if ($x.Status -eq 'GESPERRT') { Show-Msg ([string]$x.Meldung) 'OK' 'Warning' | Out-Null; return }
                if ($x.Status -eq 'NICHT-GEFUNDEN') { Show-Msg (T 'This optimization was not found. Nothing was reset.') 'OK' 'Warning' | Out-Null; return }
                if ($null -eq $x.Wiederhergestellt) { $t = (T 'Done.') }
                else {
                    $t = ((T '{0} restored.') -f (Plural ([int]$x.Wiederhergestellt) (T 'entry') (T 'entries')))
                    if ([int]$x.Fehler) { $t += ((T "`n{0} could not be restored:`n") -f [int]$x.Fehler) + ((@($x.Details | Where-Object { $_.Status -ne 'OK' } | Select-Object -First 10) | ForEach-Object { '  – {0}: {1}' -f $_.Objekt, $_.Meldung }) -join "`n") }
                }
                Show-Msg ($t + (T "`n`nPlease restart the PC so that everything takes effect.")) 'OK' $(if ([int]$x.Fehler) { 'Warning' } else { 'Information' }) | Out-Null
                Go 'NavHistory'
            } (T 'Undoing changes …') (T 'This usually only takes a few seconds.'))
    } (T 'Loading the changes …') '' -Silent)
}
function Open-Rstrui { try { Start-Process -FilePath (Join-Path $env:windir 'System32\rstrui.exe') } catch { Show-Msg (T 'System Restore could not be opened.') | Out-Null } }
$UI.BtnResultUndo.Add_Click({ Start-Undo $(if ($State.LastResult) { [string]$State.LastResult.RunId } else { '' }) })
$UI.BtnUndo.Add_Click({ Start-Undo '' })
$UI.BtnRstrui.Add_Click({ Open-Rstrui })
$UI.BtnHistRstrui.Add_Click({ Open-Rstrui })

# =============================================================================
#  History (asynchronous)
# =============================================================================
function Load-History {
    $UI.HistoryList.Children.Clear()
    [void]$UI.HistoryList.Children.Add((New-Tb (T 'Loading the history …') 'Muted' 13))
    $started = Start-Op 'silent' @'
if (Get-Command Get-HistoryLight -ErrorAction SilentlyContinue) { Get-HistoryLight } else { Get-HistoryData }
'@ {
        param($h, $err, $c)
        if ($err) { Write-ErrLog "History: $err" }
        $State.History = $h
        Draw-Boot $h
        Show-HistoryList $h
    } -Silent
    if (-not $started) { $State.HistoryPending = $true; $UI.HistoryList.Children.Clear(); [void]$UI.HistoryList.Children.Add((New-Tb (T 'WinTidy is busy right now. The history is shown afterwards.') 'Muted' 13)) }
}
function Show-HistoryList($h) {
    $UI.HistoryList.Children.Clear()
    if (-not $h) { [void]$UI.HistoryList.Children.Add((New-Tb (T 'The history could not be loaded.') 'Muted' 13)); return }
    $entries = @()
    $scores = @(); if ($h.Scores) { $scores = @($h.Scores) } else { $scores = @($h.Snapshots | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Zeit = $_.Zeit; Label = $_.Label; Wert = $_.Score.Wert } }) }
    foreach ($s in $scores) { if ($s.Label -eq 'scan') { $entries += [pscustomobject]@{ Zeit = [datetime]$s.Zeit; Text = ((T 'Check – health score {0}') -f $s.Wert); Icon = 0xE721; Col = 'Accent'; Lauf = $null; Umk = 0 } } }
    foreach ($l in @($h.Laeufe | Where-Object { $_ })) {
        $z = $l.Zusammenfassung
        $txt = if ($z) { (T 'Optimization – {0}, score {1} → {2}') -f (Plural ([int]$z.OK) (T 'change') (T 'changes')), $z.ScoreVorher, $z.ScoreNachher } else { (T 'Optimization') }
        if ($l.RueckgaengigAm) { try { $txt += ((T ' · undone on {0:yyyy-MM-dd}') -f [datetime]$l.RueckgaengigAm) } catch { } }
        $umk = if ($null -ne $l.Umkehrbar) { [int]$l.Umkehrbar } else { -1 }
        $entries += [pscustomobject]@{ Zeit = [datetime]$l.Zeit; Text = $txt; Icon = 0xE73E; Col = 'Good'; Lauf = [string]$l.Lauf; Umk = $umk }
    }
    foreach ($e in ($entries | Sort-Object Zeit -Descending | Select-Object -First 40)) {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '0,0,0,10'
        $ic = New-Icon $e.Icon $e.Col 14; $ic.Margin = '0,2,12,0'; [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        $dt = New-Tb $e.Zeit.ToString((T 'yyyy-MM-dd HH:mm')) 'Muted' 14; $dt.Width = 140; $dt.TextWrapping = 'NoWrap'; [System.Windows.Controls.DockPanel]::SetDock($dt, 'Left')
        [void]$row.Children.Add($ic); [void]$row.Children.Add($dt)
        if ($e.Lauf -and $e.Umk -ne 0) {
            $btn = New-Object System.Windows.Controls.Button; $btn.Style = $Win.FindResource('LinkBtn'); $btn.Content = (T 'Undo …'); $btn.Tag = $e.Lauf; $btn.Margin = '12,0,0,0'; $btn.VerticalAlignment = 'Center'
            Set-A11y $btn ((T 'Undo the optimization of {0}') -f $e.Zeit.ToString((T 'yyyy-MM-dd HH:mm')))
            $btn.Add_Click({ param($s, $ev) Start-Undo ([string]$s.Tag) })
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right'); [void]$row.Children.Add($btn)
        }
        [void]$row.Children.Add((New-Tb $e.Text 'Ink' 14))
        [void]$UI.HistoryList.Children.Add($row)
    }
    if (-not $entries.Count) { [void]$UI.HistoryList.Children.Add((New-Tb (T 'No entries yet.') 'Muted' 13)) }
}
function Draw-Boot($h) {
    $c = $UI.BootCanvas; $c.Children.Clear()
    $pts = @(); if ($h) { $pts = @($h.Boots | Where-Object { $_ -and $_.GesamtMs -gt 0 } | Sort-Object { [datetime]$_.Zeit }) }
    if ($pts.Count -lt 2) { $UI.BootNote.Text = (T 'Not enough boot times measured yet. Windows records them at every startup (visible with administrator rights).'); return }
    $W = $c.ActualWidth; if ($W -lt 200) { return }   # Layout not finished yet -> SizeChanged redraws
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
        $e.ToolTip = ((T '{0:yyyy-MM-dd HH:mm}: {1:N1} s') -f [datetime]$p.Zeit, ($p.GesamtMs / 1000))
        [System.Windows.Controls.Canvas]::SetLeft($e, (& $X ([datetime]$p.Zeit).Ticks) - 4); [System.Windows.Controls.Canvas]::SetTop($e, (& $Y $p.GesamtMs) - 4); [void]$c.Children.Add($e)
    }
    $first = ($pts | Select-Object -First 5 | Measure-Object GesamtMs -Average).Average / 1000
    $last = ($pts | Select-Object -Last 3 | Measure-Object GesamtMs -Average).Average / 1000
    $UI.BootNote.Text = ((T 'Initially {0:N1} s on average, most recently {1:N1} s ({2} boots since {3:yyyy-MM-dd}). Single outliers are normal, e.g. after updates.') -f $first, $last, $pts.Count, [datetime]$pts[0].Zeit)
    Set-A11y $c $UI.BootNote.Text
}
$UI.BootCanvas.Add_SizeChanged({ if ($State.History) { Draw-Boot $State.History } })
$UI.BtnHistReport.Add_Click({ $p = $null; if ($State.History) { $p = [string]$State.History.Report }; if ($p -and (Test-Path -LiteralPath $p)) { Open-AsUser $p } else { Show-Msg (T 'No report yet – please run a check first.') | Out-Null } })
function Open-Folder([string]$d) { if ($d -and (Test-Path -LiteralPath $d)) { Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $d) } else { Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $AppRoot) } }
$UI.BtnHistFolder.Add_Click({ $d = $State.DataDir; if ($State.History -and $State.History.DataDir) { $d = [string]$State.History.DataDir }; Open-Folder $d })

# =============================================================================
#  Settings
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
        $s.WorkingDirectory = $AppRoot; $s.IconLocation = "$env:windir\System32\cleanmgr.exe,0"; $s.Description = (T 'WinTidy – PC care'); $s.WindowStyle = 7
        $s.Save()
        $bytes = [IO.File]::ReadAllBytes($lnk); $bytes[0x15] = $bytes[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnk, $bytes)   # "Run as administrator"
        Show-Msg (T 'The shortcut "WinTidy" is now on the desktop.') | Out-Null
    } catch { Show-Msg (T 'The shortcut could not be created: {0}' ($_.Exception.Message)) 'OK' 'Warning' | Out-Null }
})

# =============================================================================
#  Updates (settings card, automatic check at start)
#  Check (silent) -> download and verify (silent) -> replace files (silent, window cannot be closed meanwhile).
#  The running instance keeps using the old files it has already loaded; the new version starts after a restart.
# =============================================================================
function Get-UpdateCheckedTime {
    if (-not $Script:UpdateChecked) { return $null }
    try { return [datetime]::Parse([string]$Script:UpdateChecked, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}
function Test-UpdateDue {
    $t = Get-UpdateCheckedTime
    if (-not $t) { return $true }
    $h = ((Get-Date) - $t).TotalHours
    return ($h -lt 0 -or $h -ge [math]::Max(1, [int]$State.UpdateHours))
}
function Update-UpdateUi {
    $off = [bool]$State.UpdateBlocker
    $UI.OptAutoUpdate.IsChecked = [bool]$Script:AutoUpdate
    $UI.OptAutoUpdate.IsEnabled = (-not $off)
    $UI.BtnUpdateCheck.IsEnabled = ((-not $off) -and (-not $State.UpdateRunning))
    if ($off) { $UI.UpdateStatus.Text = [string]$State.UpdateBlocker; return }
    $parts = @()
    if ($State.UpdateMsg) { $parts += [string]$State.UpdateMsg }
    $t = Get-UpdateCheckedTime
    $parts += $(if ($t) { (T 'Last checked: {0}' ($t.ToString((T 'yyyy-MM-dd HH:mm')))) } else { (T 'Not checked yet.') })
    $UI.UpdateStatus.Text = ($parts -join '  ')
}
# Mode: 'auto' (at start, or right after switching it on; no message boxes) or 'manual' (button)
function Start-UpdateCheck([string]$Mode) {
    if ($State.UpdateBlocker) { if ($Mode -eq 'manual') { Show-Msg ([string]$State.UpdateBlocker) | Out-Null }; return }
    if ($State.UpdateRunning) { return }
    if ($Mode -eq 'manual' -and (Test-Busy)) { return }
    $State.UpdateMode = $Mode
    $State.UpdateMsg = (T 'Checking for updates …')
    $State.UpdateRunning = $true
    if (-not (Start-Op 'updatecheck' 'Invoke-GuiUpdateCheck' { param($r, $err, $c) Complete-UpdateCheck $r $err $c } -Silent)) { $State.UpdateRunning = $false; $State.UpdateMsg = '' }
    Update-UpdateUi
}
function Complete-UpdateCheck($r, $err, $cancelled) {
    $State.UpdateRunning = $false
    $State.UpdateMsg = ''
    $manual = ($State.UpdateMode -eq 'manual')
    if ($cancelled) { Update-UpdateUi; return }
    $Script:UpdateChecked = (Get-Date).ToString('o'); Save-AppSettings
    if ($err -or -not $r) {
        if ($err) { Write-ErrLog "Update check: $err" }
        $State.UpdateMsg = (T 'The update did not work. Details are in the error log.'); Update-UpdateUi
        if ($manual) { Show-Msg ([string]$State.UpdateMsg) 'OK' 'Warning' | Out-Null }
        return
    }
    switch ([string]$r.Status) {
        'AKTUELL' {
            $State.UpdateMsg = (T 'WinTidy is up to date (version {0}).' ([string]$r.Aktuell)); Update-UpdateUi
            if ($manual) { Show-Msg ([string]$State.UpdateMsg) | Out-Null }
        }
        'NEU' {
            if ($manual) {
                $State.UpdateMsg = (T 'A new version ({0}) is available.' ([string]$r.Neu)); Update-UpdateUi
                if ((Show-Msg (T "Version {0} is available (you have {1}).`n`nInstall it now?" ([string]$r.Neu) ([string]$r.Aktuell)) 'YesNo' 'Question') -ne 'Yes') { return }
            }
            Start-UpdateInstall
        }
        default {
            $State.UpdateMsg = [string]$r.Meldung; Update-UpdateUi
            if ($manual) { Show-Msg ([string]$r.Meldung) 'OK' 'Warning' | Out-Null }
        }
    }
}
function Start-UpdateInstall {
    $State.UpdateMsg = (T 'Downloading the update …'); $State.UpdateRunning = $true; Update-UpdateUi
    if (-not (Start-Op 'updatestage' 'Invoke-GuiUpdateStage' { param($r, $err, $c) Complete-UpdateStage $r $err $c } -Silent)) {
        $State.UpdateRunning = $false; $State.UpdateMsg = (T 'The update could not be installed right now. WinTidy tries again later.'); Update-UpdateUi
    }
}
function Complete-UpdateStage($r, $err, $cancelled) {
    if ($cancelled) { $State.UpdateRunning = $false; $State.UpdateMsg = ''; Update-UpdateUi; return }
    if ($err -or -not $r -or [string]$r.Status -ne 'BEREIT') {
        $State.UpdateRunning = $false
        if ($err) { Write-ErrLog "Update download: $err" }
        $State.UpdateMsg = $(if ($r -and $r.Meldung) { [string]$r.Meldung } else { (T 'The update did not work. Details are in the error log.') }); Update-UpdateUi
        if ($State.UpdateMode -eq 'manual') { Show-Msg ([string]$State.UpdateMsg) 'OK' 'Warning' | Out-Null }
        return
    }
    $State.UpdateMsg = (T 'Installing the update …'); Update-UpdateUi
    if (-not (Start-Op 'updateapply' 'Invoke-GuiUpdateApply' { param($r2, $err2, $c2) Complete-UpdateApply $r2 $err2 } -Silent)) {
        $State.UpdateRunning = $false; $State.UpdateMsg = (T 'The update could not be installed right now. WinTidy tries again later.'); Update-UpdateUi
    }
}
function Complete-UpdateApply($r, $err) {
    $State.UpdateRunning = $false
    if ($err) { Write-ErrLog "Update install: $err" }
    if (-not $err -and $r -and [string]$r.Status -eq 'OK') {
        $State.UpdatedTo = [string]$r.Version
        $State.UpdateMsg = (T 'Updated to version {0}. Restart WinTidy to use it.' $State.UpdatedTo)
        Update-Banners
    } else {
        $State.UpdateMsg = $(if ($r -and $r.Meldung) { [string]$r.Meldung } else { (T 'The update did not work. Details are in the error log.') })
        if ($State.UpdateMode -eq 'manual') { Show-Msg ([string]$State.UpdateMsg) 'OK' 'Warning' | Out-Null }
    }
    Update-UpdateUi
}
$UI.OptAutoUpdate.Add_Click({ $Script:AutoUpdate = [bool]$UI.OptAutoUpdate.IsChecked; Save-AppSettings; if ($Script:AutoUpdate) { Start-UpdateCheck 'auto' } })
$UI.BtnUpdateCheck.Add_Click({ Start-UpdateCheck 'manual' })

# =============================================================================
#  Start, exit, global error handling
# =============================================================================
$Win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-ErrLog ("UI: " + $e.Exception.ToString())
    $e.Handled = $true
    try { Show-Msg ((T "Something went wrong. Your PC was not changed by this.`n`n{0}`n`nError log: {1}" ($e.Exception.Message) $ErrLog)) 'OK' 'Warning' | Out-Null } catch { }
})

$Win.Add_Loaded({
    $UI.VersionText.Text = (T 'Loading …')
    $UI.BtnScan.IsEnabled = $false; $UI.BtnScan.Content = (T 'Preparing …')
    Update-Banners
    Update-SelSummary
    Build-Recs
    [void](Start-Op 'init' @'
. $EnginePath -Language $Sync.Lang
$Script:UiSink = { param($t, $c) $Sync.Log.Enqueue([string]$t) }
$last = Get-Snapshots | Select-Object -Last 1
$ctx = $null; if (Get-Command Get-WtContext -ErrorAction SilentlyContinue) { try { $ctx = Get-WtContext } catch { } }
$upd = $null; if (Get-Command Get-WtUpdateBlocker -ErrorAction SilentlyContinue) { try { $upd = [pscustomobject]@{ Blocker = [string](Get-WtUpdateBlocker); Stunden = [int]$Script:Cfg.UpdateIntervalHours } } catch { } }
$rem = $null; if (Get-Command Get-CheckReminder -ErrorAction SilentlyContinue) { try { $rem = Get-CheckReminder } catch { } }
[pscustomobject]@{ Version = $Script:Version; Last = $(if ($last) { Read-Snapshot $last } else { $null }); DataDir = $Script:DataDir; Context = $ctx; Friendly = $Script:Friendly; Migriert = [bool]$Script:DataMigrated; Update = $upd; Erinnerung = $(if ($rem) { [string]$rem.Text } else { '' }); Ok = [bool](Get-Command Invoke-GuiScan -ErrorAction SilentlyContinue) }
'@ {
        param($init, $err, $c)
        if (-not $init -or -not $init.Ok -or -not $init.Version) {
            Write-ErrLog "Init: $err"
            Show-Msg ((T "WinTidy.ps1 could not be loaded. Please copy the complete WinTidy folder again.`n`n{0}`n`nError log: {1}" $err $ErrLog)) 'OK' 'Error' | Out-Null
            $State.ForceClose = $true; $Win.Close(); return
        }
        $State.EngineOk = $true
        $State.Friendly = $init.Friendly
        $UI.BtnScan.IsEnabled = $true; $UI.BtnScan.Content = (T '_Check now')
        $State.Version = $init.Version; $State.DataDir = [string]$init.DataDir
        # Error log from now on in the data folder (easier to find than %TEMP%)
        if ($State.DataDir -and (Test-Path -LiteralPath $State.DataDir)) { $Script:ErrLog = Join-Path $State.DataDir 'WinTidy-App-Fehler.log' }
        $UI.VersionText.Text = (T 'Version {0}' ($init.Version))
        $UI.AboutText.Text = (T "WinTidy {0} · Data: {1}`nNo installation, no internet connection (except for program updates). Every change is logged.`nError log: {2}" ($init.Version) ($init.DataDir) $ErrLog)
        $State.Reminder = [string]$init.Erinnerung
        $State.Context = $init.Context; Update-Banners
        if ($init.Last) {
            $State.Snapshot = $init.Last
            $State.Findings = @()
            $State.InfoFindings = @(Get-InfoFromSnapshot $init.Last)
            Update-Home
            $UI.ScoreDetail.Text = (T 'Result of the last check. Please check again for current recommendations.')
            $UI.BtnToRecs.Visibility = 'Collapsed'
        }
        Update-SelSummary
        # Updates: only on request (setting), at most once per interval; failures stay silent
        $State.UpdateBlocker = $(if ($init.Update) { [string]$init.Update.Blocker } else { (T 'Updates are not available.') })
        if ($init.Update -and [int]$init.Update.Stunden -gt 0) { $State.UpdateHours = [int]$init.Update.Stunden }
        Update-UpdateUi
        if ($Script:AutoUpdate -and -not $State.UpdateBlocker -and (Test-UpdateDue)) { Start-UpdateCheck 'auto' }
    } -Silent)
})
$Win.Add_Closing({
    param($s, $e)
    if ($State.ForceClose) { return }
    $op = $State.Op
    if ($op -and $op.Kind -eq 'updateapply') { Show-Msg (T 'WinTidy is installing an update right now. Please wait a moment.') | Out-Null; $e.Cancel = $true; return }
    if ($op -and $op.Kind -eq 'fix') {
        Show-Msg (T 'WinTidy is applying changes right now. Please wait until it is done – or click Cancel. WinTidy then stops after the current step.') | Out-Null
        $e.Cancel = $true; return
    }
    if ($op -and $op.Kind -eq 'undo' -and -not $op.Silent) { Show-Msg (T 'WinTidy is undoing changes right now. Please wait a moment.') | Out-Null; $e.Cancel = $true; return }
    if ($op -and $op.Kind -eq 'cooltest') { if ((Show-Msg (T 'The cooling test is still running. Cancel it and quit WinTidy?') 'YesNo' 'Question') -ne 'Yes') { $e.Cancel = $true } else { $Control.Cancel = $true }; return }
    if ($op -and $op.Kind -eq 'undo' -and $op.Silent) { return }
    if ($op -and -not $op.Silent) { if ((Show-Msg (T 'Cancel the check and quit WinTidy?') 'YesNo' 'Question') -ne 'Yes') { $e.Cancel = $true } }
})
$Win.Add_Closed({
    try { $Timer.Stop() } catch { }
    try { $ThemeTimer.Stop() } catch { }
    try { if ($State.Op) { [void]$State.Op.PS.BeginStop($null, $null) } } catch { }
    try { $RS.CloseAsync() } catch { }
    try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex(); $Script:Mutex.Dispose(); $Script:Mutex = $null } } catch { }
})

try { [void]$Win.ShowDialog() }
catch { Write-ErrLog "ShowDialog: $($_.Exception.Message) $($_.ScriptStackTrace)"; [System.Windows.MessageBox]::Show((T "Unexpected error: {0}`n`nError log: {1}" ($_.Exception.Message) $ErrLog), 'WinTidy', 'OK', 'Error') | Out-Null }
finally { try { if ($Script:Mutex) { $Script:Mutex.ReleaseMutex() } } catch { } }
