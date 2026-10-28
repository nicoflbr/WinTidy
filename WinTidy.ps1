#Requires -Version 5.1
<#
.SYNOPSIS
    WinTidy - evidence-based Windows cleanup and optimization with before/after statistics.

.DESCRIPTION
    WinTidy measures first (snapshot), then shows what it would do (preview), only carries out
    confirmed changes (apply) and backs the result with numbers (comparison, HTML report).

    Principles:
      * Nothing without measurement: every change is logged (actions.jsonl) and backed up first.
      * No registry "cleaners", no tweaks without proven effect, never disable security features.
      * Generic: no hard-coded paths, users or programs - only rules.
      * Risk levels: Low (can be automated), Medium (confirm each item), High (explicit only, never with -Yes).

.PARAMETER Mode
    Menu     Interactive menu (default)
    Scan     Snapshot + check all rules + HTML report (changes nothing)
    Preview  Shows what Apply would do (changes nothing)
    Apply    Runs rules (admin rights, restore point, backup, confirmations)
    Compare  Compares two snapshots (default: last "before" with the latest snapshot)
    Report   Rebuilds the HTML report from all stored data
    Restore  Restores registry/tasks/services of a run
    Rules    Lists all rules
    Update   Checks GitHub for a new WinTidy version and installs it (admin rights, asks first)

.PARAMETER Language
    auto (default: German if Windows is German, otherwise English), en or de

.EXAMPLE
    .\WinTidy.ps1                          # menu
    .\WinTidy.ps1 -Mode Scan -OpenReport
    .\WinTidy.ps1 -Mode Apply              # interactive
    .\WinTidy.ps1 -Mode Apply -Yes         # unattended, only rules with risk "Low"
    .\WinTidy.ps1 -Mode Apply -Rule STA-HEAVY,DBL-APPS-MS
    .\WinTidy.ps1 -Mode Compare
    .\WinTidy.ps1 -Mode Hardware                  # cooling, fans, temperatures, drives (changes nothing)
    .\WinTidy.ps1 -Mode Hardware -CoolingTest -Seconds 90   # additionally a cooling test under load
    .\WinTidy.ps1 -Mode Scan -Language de         # German output
    .\WinTidy.ps1 -Mode Update                   # install a newer WinTidy release
    .\WinTidy.ps1 -Mode Rules -Preset Safe -SavePreset mine.json   # save a rule selection as a profile
    .\WinTidy.ps1 -Mode Preview -Preset mine.json                  # use a saved profile (or Safe / Standard)
    .\WinTidy.ps1 -Mode Report -Share -Pdf       # report without PC name, user name and paths (optional PDF)
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Scan', 'Preview', 'Apply', 'Compare', 'Report', 'Restore', 'Rules', 'Hardware', 'Update')]
    [string]$Mode = 'Menu',
    [string[]]$Rule,
    [string[]]$ExcludeRule,
    [switch]$Yes,
    [switch]$IncludeMedium,
    [switch]$Deep,
    [string]$DataPath,
    [string]$ConfigPath,
    [string]$From,
    [string]$To,
    [string]$RunId,
    [switch]$NoRestorePoint,
    [switch]$OpenReport,
    [switch]$CoolingTest,
    [string]$Preset,
    [string]$SavePreset,
    [switch]$Share,
    [switch]$Pdf,
    [int]$Seconds = 0,
    [ValidateSet('auto', 'en', 'de')]
    [string]$Language = 'auto'
)

Set-StrictMode -Off
# Via WinTidy.cmd (-File), "-Rule A,B" arrives as a single string
if ($Rule) { $Rule = @($Rule | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($ExcludeRule) { $ExcludeRule = @($ExcludeRule | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Script:Version = '1.11.0'

# =============================================================================
#  Language (English is the source language, German comes from lang\de.psd1)
#  T 'English text' [args] returns the text in the current language; with arguments it is formatted like -f.
# =============================================================================
function Get-WtUiLanguage {
    try { if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de') { return 'de' } } catch { }
    return 'en'
}
# Reads lang\<lang>.psd1 without executing it: only plain 'key' = 'value' string pairs are accepted.
# (Import-PowerShellDataFile refuses files with several hundred entries.)
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
function Set-WtLanguage([string]$Lang, [string]$Root) {
    $Script:Lang = if ($Lang -in 'en', 'de') { $Lang } else { Get-WtUiLanguage }
    $Script:De = $null
    if ($Script:Lang -eq 'de') {
        $root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        try { $Script:De = Read-WtLangFile (Join-Path $root 'lang\de.psd1') } catch { $Script:Lang = 'en'; $Script:De = $null }
    }
}
function T([string]$Text) {
    $s = $Text
    if ($Script:Lang -eq 'de' -and $null -ne $Script:De) { $v = $null; if ($Script:De.TryGetValue($Text, [ref]$v)) { $s = $v } }
    if ($args.Count) { try { return ($s -f $args) } catch { return $s } }
    return $s
}
# Display names for internal values (risk levels and rule categories stay German in data files)
function Get-RiskText([string]$Risk) {
    switch ($Risk) { 'Niedrig' { return (T 'Low') } 'Mittel' { return (T 'Medium') } 'Hoch' { return (T 'High') } 'Info' { return (T 'Info') } }
    return $Risk
}
function Get-CategoryText([string]$Cat) {
    switch ($Cat) { 'Speicher' { return (T 'Storage') } 'Autostart' { return (T 'Startup') } 'Aufgaben' { return (T 'Tasks') } 'Dienste' { return (T 'Services') } 'Programme' { return (T 'Programs') } 'System' { return (T 'System') } 'Sicherheit' { return (T 'Security') } 'Hardware' { return (T 'Hardware') } 'Stabilitaet' { return (T 'Stability') } }
    return $Cat
}
Set-WtLanguage $Language

# =============================================================================
#  Context, configuration, paths
# =============================================================================
$Script:ToolRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Script:Me = [Security.Principal.WindowsIdentity]::GetCurrent()
# With admin rights, load modules only from system folders (no planting via Documents\WindowsPowerShell\Modules)
if ($Script:IsAdmin -and $env:windir) { $env:PSModulePath = (@("$env:ProgramFiles\WindowsPowerShell\Modules", "$env:windir\system32\WindowsPowerShell\v1.0\Modules") -join ';') }
# Data folder: with admin rights protected under ProgramData (only Administrators/SYSTEM may write),
# without admin rights in the user's own profile. Backups that "Restore" applies with admin rights therefore never
# live in a folder that programs without admin rights can modify.
$Script:LegacyDataDir = Join-Path $Script:ToolRoot ("WinTidy-Daten\" + $env:COMPUTERNAME)
$Script:DataDirIsDefault = -not $DataPath
if (-not $DataPath) { $DataPath = if ($Script:IsAdmin) { Join-Path $env:ProgramData ("WinTidy\" + $env:COMPUTERNAME) } else { Join-Path $env:LOCALAPPDATA ("WinTidy\" + $env:COMPUTERNAME) } }
function Protect-WtDataRoot([string]$Path) {
    try {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        foreach ($p in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $p[0]), [Security.AccessControl.FileSystemRights]$p[1], $inh, 'None', 'Allow')))
        }
        try { $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544')); Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop }
        catch {
            # Setting the owner does not always work - then only the permissions
            $acl2 = New-Object Security.AccessControl.DirectorySecurity; $acl2.SetAccessRuleProtection($true, $false)
            foreach ($r in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) { $acl2.AddAccessRule($r) }
            Set-Acl -LiteralPath $Path -AclObject $acl2 -ErrorAction Stop
        }
        return $true
    } catch { return $false }
}
# Checks that the folder and its contents belong only to SYSTEM/Administrators and only they may write
function Test-WtDataRootSafe([string]$Path) {
    try {
        $ok = 'S-1-5-18', 'S-1-5-32-544'
        $schreib = [Security.AccessControl.FileSystemRights]'Write, Delete, ChangePermissions, TakeOwnership'
        foreach ($i in @(@(Get-Item -LiteralPath $Path -Force -ErrorAction Stop) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue))) {
            if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            $acl = Get-Acl -LiteralPath $i.FullName -ErrorAction Stop
            if ($ok -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
            foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($r.AccessControlType -eq 'Allow' -and $ok -notcontains $r.IdentityReference.Value -and ($r.FileSystemRights -band $schreib)) { return $false }
            }
        }
        return $true
    } catch { return $false }
}
$Script:DataDirProtected = $false
if ($Script:IsAdmin -and $Script:DataDirIsDefault) {
    $wtRoot = Split-Path $DataPath
    if (-not (Test-Path -LiteralPath $wtRoot) -or -not (Test-WtDataRootSafe $wtRoot)) {
        $null = Protect-WtDataRoot $wtRoot
        # Reset existing subfolders/files to the inherited permissions and take ownership
        if (Get-ChildItem -LiteralPath $wtRoot -Force -ErrorAction SilentlyContinue) {
            $null = & icacls.exe (Join-Path $wtRoot '*') /reset /T /C /Q 2>&1
            $null = & icacls.exe $wtRoot /setowner '*S-1-5-32-544' /T /C /Q 2>&1
        }
    }
    $Script:DataDirProtected = Test-WtDataRootSafe $wtRoot
    # One-time migration of data from older versions (folder WinTidy-Daten next to the script)
    if (-not (Test-Path -LiteralPath (Join-Path $DataPath 'snapshots')) -and (Test-Path -LiteralPath (Join-Path $Script:LegacyDataDir 'snapshots'))) {
        try {
            New-Item -ItemType Directory -Force -Path $DataPath | Out-Null
            Get-ChildItem -LiteralPath $Script:LegacyDataDir -Force -ErrorAction Stop | Copy-Item -Destination $DataPath -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath (Join-Path $DataPath 'snapshots'))) { throw 'Uebernahme unvollstaendig' }
            Set-Content -LiteralPath (Join-Path $Script:LegacyDataDir 'UMGEZOGEN.txt') -Value ((T 'The WinTidy data has been stored protected under {0} since version 1.3. This folder can be deleted.' $DataPath)) -Encoding UTF8 -ErrorAction SilentlyContinue
            $Script:DataMigrated = $true
        } catch { }
    }
}
$Script:DataDir = $DataPath
$Script:SnapDir = Join-Path $DataPath 'snapshots'
$Script:RunsDir = Join-Path $DataPath 'runs'
foreach ($d in $Script:DataDir, $Script:SnapDir, $Script:RunsDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
$Script:RestoreRunId = $RunId   # -RunId is the restore target parameter; $Script:RunId is overwritten right below
$Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
$Script:RunDir = $null
$Script:Cache = @{}
$Script:AllYes = $false

$Script:DefaultConfig = [ordered]@{
    TempAgeDays             = 2
    RecycleBinAgeDays       = 30
    CrashDumpAgeDays        = 7
    SystemDumpKeepDays      = 30       # CLN-WINCLEAN: memory dumps of blue screens younger than this are kept
    ShadowStorageMinPercent = 3
    ShadowStorageTarget     = '5%'
    BootDegradationHintMs   = 2000
    HeavyStartup            = @('Spotify', 'Steam', 'Discord', 'EADesktop', 'EALauncher', 'Battle.net', 'EpicGamesLauncher', 'Teams', 'Skype', 'Zoom', 'AdobeCollabSync', 'Creative Cloud', 'CCleaner', 'Overwolf', 'MicrosoftStartFeedProvider', 'LogiLDA', 'iTunesHelper', 'Opera', 'msedge')
    ProtectedStartup        = @('SecurityHealth', 'OneDrive', 'Windows Defender', 'RtkAudUService', 'KeePass', 'Bitwarden', '1Password', 'Malwarebytes', 'Bitdefender', 'Kaspersky', 'ESET', 'Avast', 'AVG', 'Norton', 'McAfee', 'Sophos', 'Trend Micro', 'G DATA', 'Avira', 'F-Secure', 'WireGuard', 'OpenVPN', 'NordVPN', 'FortiClient', 'GlobalProtect', 'Cisco', 'Synaptics', 'ELAN', 'Backblaze', 'Veeam', 'Acronis', 'Duet', 'Logitech Options', 'Dropbox', 'Nextcloud', 'Google Drive')
    BloatApps               = @()      # additional Store apps (package names) offered on the Debloat page under "Microsoft apps"; the built-in list is in the code
    GhostDeviceExclude      = @('WAN Miniport', 'Microsoft Kernel Debug', 'Hyper-V', 'Remote NDIS', 'Bluetooth', 'Microsoft Wi-Fi Direct', 'Teredo', '6to4', 'IP-HTTPS', 'ISATAP', 'VHD Loopback', 'Microsoft Virtual')
    GhostDeviceClasses      = @('System', 'HDC', 'SCSIAdapter', 'Display', 'Monitor', 'MEDIA', 'Net', 'DiskDrive', 'Volume', 'USB', 'USBDevice', 'HIDClass', 'Keyboard', 'Mouse', 'WPD', 'Image', 'Camera', 'Ports', 'Processor', 'SmartCardReader', 'Sensor', 'Biometric')
    SideBySideExclude       = @('Visual C\+\+', '\.NET', 'Windows SDK', 'Windows Software Development', 'Python', 'Java', 'WebView', 'Update for', 'Security Update', 'Hotfix', 'Runtime', 'Redistributable', 'Driver', 'Language', 'Sprachpaket', 'Microsoft 365', 'Office', 'Steam', 'SDK')
    WingetExclude           = @()      # programs (name or winget id, part of it is enough) that WinTidy never updates; personal entries belong in WinTidy.config.local.json
    OrphanDirIgnore         = @('Microsoft', 'Windows', 'Packages', 'Temp', 'Package Cache', 'Common Files', 'NVIDIA', 'NVIDIA Corporation', 'Intel', 'AMD', 'Realtek', 'WindowsApps', 'ModifiableWindowsApps', 'Reference Assemblies', 'MSBuild', 'Internet Explorer', 'Windows Defender', 'Windows Mail', 'Windows Media Player', 'Windows NT', 'Windows Photo Viewer', 'Windows Sidebar', 'Uninstall Information', 'WindowsPowerShell', 'PackageManagement', 'dotnet', 'USOShared', 'USOPrivate', 'regid.1991-06.com.microsoft', 'SoftwareDistribution', 'ssh', 'Comms', 'ConnectedDevicesPlatform', 'D3DSCache', 'CrashDumps', 'Programs', 'PlaceholderTileLogoFolder', 'VirtualStore', 'Publishers', 'IsolatedStorage', 'speech', 'ElevatedDiagnostics', 'Adobe', 'Google', 'Mozilla', 'Apple', 'Apple Computer', 'Apple Inc', 'Claude', 'Code', 'Electron', 'NuGet', 'npm', 'npm-cache', 'pip')
    OrphanDirMinMB          = 50
    QuarantineDays          = 30       # CLN-QUARANTINE: folders set aside by CLN-ORPHANDIR are deleted after this many days
    GhostDeviceMinDays      = 90       # SYS-GHOST: only devices not connected for at least this many days
    DriverInstallerDirs     = @('%SystemDrive%\AMD', '%SystemDrive%\NVIDIA', '%ProgramData%\NVIDIA Corporation\Downloader')   # CLN-DRIVERINSTALL: folders where driver installers unpack themselves
    DriverInstallerMinMB    = 200      # CLN-DRIVERINSTALL: only offered from this size
    GpuDriverMaxAgeDays     = 365      # HW-HINTS: hint if the graphics driver is older than this
    ExtraTempPaths          = @()      # additional temp folders (e.g. 'C:\Temp'), only if they really contain nothing but disposable files
    BrowserCacheMinMB       = 500      # CLN-BROWSER: browser caches are only offered from this size per browser
    BigFileMinMB            = 1024     # CLN-BIGFILES (only shown, never deleted): minimum size of a file in the personal folders
    DownloadsOldDays        = 90       # CLN-BIGFILES: files in Downloads older than this count as "old"
    CheckReminderDays       = 30       # app/menu: remind to check again after this many days without a check (0 = never)
    # Hardware/cooling (degrees Celsius). Scan = PC is mostly idle (laptop +5 degrees)
    CpuTempIdleWarnC        = 80
    CpuTempIdleCritC        = 90
    # Temperature limit (TjMax) per CPU family (regex on the CPU name, first match wins; otherwise 100)
    CpuTjMax                = [ordered]@{ 'Ryzen.*\d{4}X3D' = 89; 'Ryzen [3579] [79]\d{3}' = 95; 'Ryzen' = 90; 'Core\(TM\) Ultra|Core Ultra' = 105; 'Intel' = 100 }
    GpuTempWarnC            = 83
    GpuTempCritC            = 90
    DiskTempWarnC           = @{ NVMe = 70; SSD = 60; HDD = 50 }
    DiskTempCritC           = @{ NVMe = 80; SSD = 70; HDD = 60 }
    CoolingTestSeconds      = 60
    WinOldMinAgeDays        = 10
    # End of security updates per Windows build (Home/Pro; Enterprise/Education: +12 months). Source: Microsoft Lifecycle
    WindowsSupportEnd       = [ordered]@{ '19045' = '2025-10-14'; '22621' = '2024-10-08'; '22631' = '2025-11-11'; '26100' = '2026-10-13'; '26200' = '2027-10-12' }
    # Updates: GitHub repository whose releases WinTidy installs, hours between automatic checks, master switch ($false = never update)
    UpdateRepo              = 'nicoflbr/WinTidy'
    UpdateIntervalHours     = 24
    UpdateEnabled           = $true
}
# Configuration = defaults + WinTidy.config.json + WinTidy.config.local.json (personal, not in Git).
# Only keys that differ from the defaults belong in the files; keys starting with _ are ignored.
function Merge-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Script:DefaultConfig.Keys) { $cfg[$k] = $Script:DefaultConfig[$k] }
    $files = if ($ConfigPath) { @($ConfigPath) } else { @((Join-Path $Script:ToolRoot 'WinTidy.config.json'), (Join-Path $Script:ToolRoot 'WinTidy.config.local.json')) }
    foreach ($p in $files) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $user = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $user.PSObject.Properties) {
                if ($prop.Name -like '_*') { continue }
                $def = $cfg[$prop.Name]
                if (($def -is [hashtable] -or $def -is [System.Collections.Specialized.OrderedDictionary]) -and $prop.Value -is [pscustomobject]) {
                    # Merge tables (e.g. DiskTempWarnC) per sub-key instead of replacing them completely
                    $m = [ordered]@{}; foreach ($k in $def.Keys) { $m[$k] = $def[$k] }
                    foreach ($sp in $prop.Value.PSObject.Properties) { $m[$sp.Name] = $sp.Value }
                    $cfg[$prop.Name] = $m
                } else { $cfg[$prop.Name] = $prop.Value }
            }
        } catch { Write-Warning (T 'Configuration {0} could not be read: {1}' $p ($_.Exception.Message)) }
    }
    return $cfg
}
# Check the configuration for dangerous values (e.g. age limit 0 = delete everything)
function Test-Config($cfg) {
    $min = @{ TempAgeDays = 1; RecycleBinAgeDays = 7; CrashDumpAgeDays = 1; SystemDumpKeepDays = 7; WinOldMinAgeDays = 10; OrphanDirMinMB = 10; QuarantineDays = 7; GhostDeviceMinDays = 30; DriverInstallerMinMB = 50; GpuDriverMaxAgeDays = 90; CoolingTestSeconds = 20; UpdateIntervalHours = 1; BrowserCacheMinMB = 50; BigFileMinMB = 100; DownloadsOldDays = 14; CheckReminderDays = 0 }
    foreach ($k in @($min.Keys)) { $v = 0; if (-not [int]::TryParse([string]$cfg[$k], [ref]$v) -or $v -lt $min[$k]) { Write-Warning (T 'Configuration: {0} invalid ({1}) - default value is used' $k ($cfg[$k])); $cfg[$k] = $Script:DefaultConfig[$k] } }
    $never = 'Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.WindowsAppRuntime', 'Microsoft.VCLibs', 'Microsoft.UI.Xaml', 'Microsoft.NET'
    # Driver installer folders: only absolute folders below a drive that are not system or profile folders
    $cfg.DriverInstallerDirs = @($cfg.DriverInstallerDirs | Where-Object { $p = ([Environment]::ExpandEnvironmentVariables([string]$_)).TrimEnd('\'); $p -match '^[A-Za-z]:\\[^\\]' -and (Test-SafeDeleteRoot $p) })
    $cfg.BloatApps = @($cfg.BloatApps | Where-Object { $n = [string]$_; $n -match '^[\w\.\-]+$' -and -not ($never | Where-Object { $n -like "$_*" }) })
    if ([string]$cfg.ShadowStorageTarget -notmatch '^(\d{1,2})%$' -or [int]$Matches[1] -lt 3) { $cfg.ShadowStorageTarget = $Script:DefaultConfig.ShadowStorageTarget }
    if ([string]$cfg.UpdateRepo -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') { Write-Warning (T 'Configuration: {0} invalid ({1}) - default value is used' 'UpdateRepo' ([string]$cfg.UpdateRepo)); $cfg.UpdateRepo = $Script:DefaultConfig.UpdateRepo }
    $cfg.UpdateEnabled = [bool]$cfg.UpdateEnabled
    $cfg.ExtraTempPaths = @($cfg.ExtraTempPaths | Where-Object { $_ -and ([string]$_) -match '^[A-Za-z]:\\.+' })
    return $cfg
}
$Script:Cfg = Test-Config (Merge-Config)

# =============================================================================
#  Output, logging, helper functions
# =============================================================================
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) {
    if ($Script:UiSink) {
        try { & $Script:UiSink $Text $Color } catch { }
        if ($Script:RunDir) { try { $Text | Out-File (Join-Path $Script:RunDir 'protokoll.txt') -Append -Encoding utf8 } catch { } }
        return
    }
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
}
function Section([string]$t) { W ''; W ('=' * 78) 'DarkCyan'; W "  $t" 'Cyan'; W ('=' * 78) 'DarkCyan' }
function Sub([string]$t) { W ''; W "--- $t" 'Cyan' }
function Fmt-Bytes([double]$b) {
    if ($b -ge 1TB) { return '{0:N2} TB' -f ($b / 1TB) }
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return '{0:N0} B' -f $b
}
function HtmlEnc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Iso($d) { if ($d) { try { ([datetime]$d).ToString('o') } catch { $null } } else { $null } }

function Start-RunLog([string]$Kind) {
    $Script:RunDir = Join-Path $Script:RunsDir ("{0}_{1}" -f $Script:RunId, $Kind)
    New-Item -ItemType Directory -Force -Path $Script:RunDir, (Join-Path $Script:RunDir 'backup') | Out-Null
    try { Start-Transcript -Path (Join-Path $Script:RunDir 'konsole.txt') -Force | Out-Null } catch { }
}
function Stop-RunLog { try { Stop-Transcript | Out-Null } catch { } }

function Add-ActionRecord([string]$RuleId, [string]$Item, [string]$Status, [double]$Bytes = 0, [string]$Message = '', $Undo = $null) {
    $rec = [ordered]@{ Zeit = (Get-Date).ToString('o'); Lauf = $Script:RunId; Regel = $RuleId; Objekt = $Item; Status = $Status; Bytes = [int64]$Bytes; Meldung = $Message; Undo = $Undo }
    if ($Script:RunDir) { ($rec | ConvertTo-Json -Compress -Depth 5) | Out-File (Join-Path $Script:RunDir 'actions.jsonl') -Append -Encoding utf8 }
    return [pscustomobject]$rec
}

function Get-DirSize([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $it) { return [int64]0 }
    if (-not $it.PSIsContainer) { return [int64]$it.Length }
    $o = & robocopy.exe $Path 'NULL' /L /S /NJH /BYTES /NFL /NDL /NC /XJ /R:0 /W:0 2>$null
    foreach ($l in $o) { if ($l -match '^\s*Bytes\s*:\s*(\d+)') { return [int64]$Matches[1] } }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($s) { return [int64]$s } else { return [int64]0 }
}
# Links (junctions, symlinks, OneDrive placeholders) are never entered and never deleted during cleanup.
# Otherwise e.g. a junction in a temp folder could redirect the deletion to arbitrary other folders.
function Test-Reparse($Item) { return [bool]($Item -and ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function Test-SafeDeleteRoot([string]$Path) {
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full -match '^[A-Za-z]:$' -or $full -match '^\\\\[^\\]+\\[^\\]+$') { return $false }
    $bad = @($env:SystemDrive, $env:windir, "$env:windir\System32", $env:USERPROFILE, $(if ($env:USERPROFILE) { Split-Path $env:USERPROFILE }), $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop')) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') }
    return -not ($bad -contains $full)
}
# Quarantine (since 1.9): CLN-ORPHANDIR does not delete a folder right away but renames it in place to
# "<name>.WinTidy-removed-<yyyyMMdd>". The program no longer finds it, "Restore" renames it back, and CLN-QUARANTINE
# deletes it permanently after QuarantineDays days. Renaming stays on the same drive, follows no links and leaves
# the permissions as they are.
$Script:QuarantineSuffix = '.WinTidy-removed-'
function Get-QuarantineRoots { @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') } | Select-Object -Unique) }
function Test-QuarantinePath([string]$Path) {
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Get-QuarantineRoots | Where-Object { $_ -ieq $parent })) { return $false }
    return ([IO.Path]::GetFileName($full) -match ('^.+' + [regex]::Escape($Script:QuarantineSuffix) + '\d{8}(-\d+)?$'))
}
function Get-QuarantineDirs {
    foreach ($r in (Get-QuarantineRoots)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $Script:QuarantineSuffix + '*') -and -not (Test-Reparse $_) })) {
            $m = [regex]::Match($d.Name, '^(.+)' + [regex]::Escape($Script:QuarantineSuffix) + '(\d{8})(-\d+)?$')
            if (-not $m.Success) { continue }
            $datum = $null; try { $datum = [datetime]::ParseExact($m.Groups[2].Value, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
            [pscustomobject]@{ Pfad = $d.FullName; Name = $m.Groups[1].Value; Datum = $datum }
        }
    }
}
function Move-ToQuarantine([string]$Rule, [string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Get-QuarantineRoots | Where-Object { $_ -ieq $parent })) { throw (T 'Unsafe path') }
    $d = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (Test-Reparse $d) { throw (T 'Unsafe path') }
    $basis = $full + $Script:QuarantineSuffix + (Get-Date -Format 'yyyyMMdd')
    $ziel = $basis; $k = 1
    while (Test-Path -LiteralPath $ziel) { $k++; $ziel = "$basis-$k" }
    try { [IO.Directory]::Move($full, $ziel) } catch { throw ('SKIP:' + (T 'The folder could not be moved (in use or no permission): {0}' ($_.Exception.Message))) }
    Add-ActionRecord $Rule (Split-Path $full -Leaf) 'Undo-Info' 0 '' @{ Typ = 'Ordner'; Quelle = $ziel; Ziel = $full } | Out-Null
    return $ziel
}
function Get-OldFiles([string]$Path, [int]$Days) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    if (-not (Test-SafeDeleteRoot $Path)) { W (T '    Folder {0} is not cleaned for safety reasons' $Path) 'DarkYellow'; return @() }
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $root -or (Test-Reparse $root)) { return @() }
    $limit = (Get-Date).AddDays(-$Days)
    $res = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($root.FullName)
    while ($stack.Count) {
        foreach ($e in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction SilentlyContinue)) {
            if (Test-Reparse $e) { continue }
            if ($e.PSIsContainer) { $stack.Push($e.FullName) }
            elseif ($e.LastWriteTime -lt $limit -and $e.CreationTime -lt $limit) { $res.Add($e) }
        }
    }
    return $res.ToArray()
}
# Newest change (written or created) of a file below $Path, without following links; $null if there are no files
function Get-NewestFileTime([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $root -or (Test-Reparse $root)) { return $null }
    $max = $null
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($root.FullName)
    while ($stack.Count) {
        foreach ($e in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction SilentlyContinue)) {
            if (Test-Reparse $e) { continue }
            if ($e.PSIsContainer) { $stack.Push($e.FullName); continue }
            foreach ($t in $e.LastWriteTime, $e.CreationTime) { if ($null -eq $max -or $t -gt $max) { $max = $t } }
        }
    }
    return $max
}
function Remove-EmptyDirs([string]$Path, [int]$Days = 0) {
    if (-not (Test-SafeDeleteRoot $Path)) { return }
    $ri = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; if (-not $ri -or (Test-Reparse $ri)) { return }
    $limit = (Get-Date).AddDays(-$Days)
    $dirs = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count) { foreach ($d in @(Get-ChildItem -LiteralPath $stack.Pop() -Directory -Force -ErrorAction SilentlyContinue)) { if (Test-Reparse $d) { continue }; $dirs.Add($d); $stack.Push($d.FullName) } }
    foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
        if ($d.LastWriteTime -lt $limit -and -not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue) -and (Test-PathChainNoReparse $Path $d.FullName) -and -not ([IO.File]::GetAttributes($d.FullName) -band [IO.FileAttributes]::ReparsePoint)) { try { [IO.Directory]::Delete($d.FullName, $false) } catch { } }
    }
}
# Right before deleting: is the file still below the root, without a link in between?
function Test-PathChainNoReparse([string]$Root, [string]$Full) {
    try {
        $sep = [string][IO.Path]::DirectorySeparatorChar
        $r = [IO.Path]::GetFullPath($Root).TrimEnd($sep); $p = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Full))
        if (-not ($p + $sep).StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        while ($p -and $p.Length -ge $r.Length) {
            if ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) { return $false }
            if ($p -ieq $r) { break }
            $p = [IO.Path]::GetDirectoryName($p)
        }
        return $true
    } catch { return $false }
}
# Deletes a folder including its contents, but never follows links (the link itself is removed, its target is not)
function Remove-TreeNoFollow([string]$Path) {
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (Test-Reparse $it) { throw (T 'Link (junction/symlink) - not deleted for safety reasons: {0}' $Path) }
    if (-not $it.PSIsContainer) { $it.Attributes = 'Normal'; $it.Delete(); return }
    foreach ($e in @(Get-ChildItem -LiteralPath $it.FullName -Force -ErrorAction Stop)) {
        if (Test-Reparse $e) { if ($e.PSIsContainer) { [IO.Directory]::Delete($e.FullName, $false) } else { [IO.File]::Delete($e.FullName) } }
        elseif ($e.PSIsContainer) { Remove-TreeNoFollow $e.FullName }
        else { $e.Attributes = 'Normal'; $e.Delete() }
    }
    try { $it.Attributes = 'Directory' } catch { }
    [IO.Directory]::Delete($it.FullName, $false)
}
function Test-DriveExists([string]$Path) {
    if ($Path -match '^([A-Za-z]):') { return (Test-Path "$($Matches[1]):\") }
    return $true
}

# Determines the actual target file of a command line (for existence checks)
function Resolve-CommandTarget([string]$Command) {
    if (-not $Command) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $exe = $null; $rest = ''
    if ($c -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
    elseif ($c -match '^(.+?\.(exe|com|bat|cmd|vbs|js|ps1|lnk|msc))(\s+(.*))?$') { $exe = $Matches[1]; $rest = $Matches[4] }
    else { $exe = ($c -split '\s+')[0] }
    $leaf = ''; try { $leaf = Split-Path $exe -Leaf } catch { return $null }
    $interpreters = 'rundll32.exe', 'wscript.exe', 'cscript.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'mshta.exe', 'regsvr32.exe', 'conhost.exe'
    if ($interpreters -contains $leaf.ToLower() -and $rest) {
        if ($rest -match '"?([A-Za-z]:\\[^"]+?\.(dll|vbs|js|ps1|bat|cmd|hta|exe))"?') { return $Matches[1] }
        return $null   # Interpreter without a file argument: cannot be checked
    }
    if ($exe -notmatch '\\') {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source } else { return $exe }
    }
    return $exe
}
function Get-TargetState([string]$Target) {
    if (-not $Target) { return 'unbekannt' }
    $Target = $Target -replace '^\\\?\?\\', '' -replace '^\\\\\?\\', ''
    # Never treat network paths as "orphaned" (NAS asleep, VPN disconnected) and never touch them with admin rights
    if ($Target.StartsWith('\\')) { return 'unbekannt' }
    if ($Target -notmatch '^[A-Za-z]:\\') { return 'unbekannt' }
    if (-not (Test-DriveExists $Target)) { return 'LaufwerkFehlt' }
    if (Test-Path -LiteralPath $Target) { return 'ok' }
    return 'fehlt'
}

# Does $Text contain $Word as a whole word (no letter directly before or after)? Case-insensitive.
function Test-WordMatch([string]$Text, [string]$Word) {
    if (-not $Text -or -not $Word) { return $false }
    return ($Text -match ('(?i)(?<![a-z])' + [regex]::Escape($Word) + '(?![a-z])'))
}

# Unattended (-Yes): risk Low unless the item forbids it (AutoOk = $false); risk Medium only if the item explicitly
# allows it (AutoOk = $true, fail closed); risk High never.
function Test-UnattendedItem($Rule, $Item) {
    $p = $Item.PSObject.Properties['AutoOk']
    if ($Rule.Risiko -eq 'Niedrig') { return (-not $p -or [bool]$Item.AutoOk) }
    if ($Rule.Risiko -eq 'Mittel') { return ($null -ne $p -and [bool]$Item.AutoOk) }
    return $false
}

function Confirm-Item([string]$Question, [string]$Risk) {
    if ($Script:Preview) { return $false }
    if ($Yes) {
        if ($Risk -eq 'Niedrig') { return $true }
        if ($Risk -eq 'Mittel' -and $IncludeMedium) { return $true }
        return $false
    }
    if ($Script:AllYes -and $Risk -ne 'Hoch') { return $true }
    while ($true) {
        W "    $Question " 'White' -NoNewline
        W (T '[y]es / [n]o / [a]ll of this rule / [s]kip rule: ') 'DarkGray' -NoNewline
        $a = (Read-Host).Trim().ToLower()
        switch -Regex ($a) {
            '^(j|ja|y|yes)$' { return $true }
            '^(n|nein|no|)$' { return $false }
            '^a$' { if ($Risk -eq 'Hoch') { W (T '    (with risk "High" every item is asked individually)') 'DarkYellow'; continue }; $Script:AllYes = $true; return $true }
            '^s$' { throw 'SKIPRULE' }
        }
    }
}

function Backup-RegKey([string]$Key, [string]$Name) {
    if (-not $Script:RunDir) { return }
    $f = Join-Path $Script:RunDir ("backup\" + ($Name -replace '[^\w\-]', '_') + '.reg')
    if (-not (Test-Path $f)) { & reg.exe export $Key $f /y 2>$null | Out-Null }
}
# Read a registry value so that it can be stored as JSON and written back exactly
function Get-RegValueRaw([string]$Key, [string]$Name) {
    try {
        $k = Get-Item -LiteralPath $Key -ErrorAction Stop
        if (@($k.GetValueNames()) -notcontains $Name) { return $null }
        $kind = [string]$k.GetValueKind($Name)
        $v = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        if ($kind -eq 'Binary') { $v = [Convert]::ToBase64String([byte[]]$v) } elseif ($kind -eq 'MultiString') { $v = @($v) }
        return [ordered]@{ Art = $kind; Wert = $v }
    } catch { return $null }
}
function ConvertTo-RegKeyText([string]$Key) {
    $k = $Key -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $k = $k -replace '^HKEY_CURRENT_USER', 'HKCU' -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^(HKCU|HKLM):', '$1'
    return $k.TrimEnd('\')
}
# Only these keys may be touched by "Restore" (protection against tampered backups)
$Script:RestoreKeyAllow = '(?i)^HK(CU|LM)\\Software\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\(Run|Explorer\\StartupApproved\\(Run|Run32|StartupFolder))$|^HKCU\\System\\GameConfigStore$|^HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR$|^HKCU\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppModel\\SystemAppData\\[^\\]+\\[^\\]+$|^HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem$'
# =============================================================================
#  Debloat catalog (page "Debloat" in the app, rules DBL-*)
#  Only per-user preferences that Windows itself offers (Settings, Explorer options) and removable apps. No policies for the
#  whole PC, no services, no security features, no telemetry policies. Selection of the settings and the app lists were
#  compiled with the help of the open-source project Win11Debloat (MIT, https://github.com/raphire/win11debloat),
#  see THIRD-PARTY-NOTICES.md.
# =============================================================================
$Script:RestoreKeyAllow += '|^HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\(ContentDeliveryManager|Explorer\\Advanced|Explorer\\Advanced\\TaskbarDeveloperSettings|SystemSettings\\AccountNotifications|UserProfileEngagement|Notifications\\Settings\\Windows\.SystemToast\.Suggested|Mobility|Search|AdvertisingInfo|Privacy)$|^HKCU\\Software\\Microsoft\\(Speech_OneCore\\Settings\\OnlineSpeechPrivacy|Input\\TIPC)$|^HKCU\\Software\\Policies\\Microsoft\\Windows\\Explorer$|^HKCU\\Control Panel\\Accessibility\\StickyKeys$'
# One registry value of a setting; 'CV:' stands for HKCU:\Software\Microsoft\Windows\CurrentVersion
function Dv([string]$Key, [string]$Name, $Value, [string]$Type = 'DWord') {
    [pscustomobject]@{ Key = ($Key -replace '^CV:', 'HKCU:\Software\Microsoft\Windows\CurrentVersion'); Name = $Name; Wert = $Value; Typ = $Type }
}
# Id = internal name, Gruppe = rule, Min = first Windows build that has the setting (0 = all), Werte = values that are set
$Script:DebloatTweaks = @(
    @{ Id = 'welcome'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off welcome screens and "finish setting up your PC" reminders')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0), (Dv 'CV:\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0)) }
    @{ Id = 'start-ads'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off suggested apps in the Start menu')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0), (Dv 'CV:\Explorer\Advanced' 'Start_IrisRecommendations' 0), (Dv 'CV:\Explorer\Advanced' 'Start_AccountNotifications' 0)) }
    @{ Id = 'tips'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off tips, tricks and suggestions while you work')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'SoftLandingEnabled' 0)) }
    @{ Id = 'settings-ads'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off suggested content in the Settings app')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-353698Enabled' 0), (Dv 'CV:\SystemSettings\AccountNotifications' 'EnableAccountNotifications' 0)) }
    @{ Id = 'lockscreen'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off tips and "fun facts" on the lock screen')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 0), (Dv 'CV:\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0)) }
    @{ Id = 'autoinstall'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Stop Windows from installing suggested apps by itself')
        Werte = @((Dv 'CV:\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0)) }
    @{ Id = 'sync-ads'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off cloud service ads in File Explorer')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'ShowSyncProviderNotifications' 0)) }
    @{ Id = 'phone-suggest'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off suggestions to connect your phone')
        Werte = @((Dv 'CV:\Mobility' 'OptedIn' 0)) }
    @{ Id = 'suggested-toast'; Gruppe = 'DBL-ADS'; Min = 0; Titel = (T 'Turn off notifications that advertise Microsoft services')
        Werte = @((Dv 'CV:\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0)) }
    @{ Id = 'adid'; Gruppe = 'DBL-PRIVACY'; Min = 0; Titel = (T 'Turn off the advertising ID for apps')
        Werte = @((Dv 'CV:\AdvertisingInfo' 'Enabled' 0)) }
    @{ Id = 'tailored'; Gruppe = 'DBL-PRIVACY'; Min = 0; Titel = (T 'Turn off tailored tips and ads based on diagnostic data')
        Werte = @((Dv 'CV:\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0)) }
    @{ Id = 'trackprogs'; Gruppe = 'DBL-PRIVACY'; Min = 0; Titel = (T 'Stop tracking app launches for Start and search results')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'Start_TrackProgs' 0)) }
    @{ Id = 'speech'; Gruppe = 'DBL-PRIVACY'; Min = 0; Titel = (T 'Turn off online speech recognition')
        Werte = @((Dv 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0)) }
    @{ Id = 'inking'; Gruppe = 'DBL-PRIVACY'; Min = 0; Titel = (T 'Turn off sending inking and typing samples')
        Werte = @((Dv 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0)) }
    @{ Id = 'bing'; Gruppe = 'DBL-SHELL'; Min = 0; Titel = (T 'Remove web results (Bing) from Start menu search')
        Werte = @((Dv 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1)) }
    @{ Id = 'copilot-btn'; Gruppe = 'DBL-SHELL'; Min = 22621; Titel = (T 'Hide the Copilot button in the taskbar')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'ShowCopilotButton' 0)) }
    @{ Id = 'chat'; Gruppe = 'DBL-SHELL'; Min = 22000; Titel = (T 'Hide the Chat (Teams) icon in the taskbar')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'TaskbarMn' 0)) }
    @{ Id = 'taskview'; Gruppe = 'DBL-SHELL'; Min = 0; Titel = (T 'Hide the Task view button in the taskbar')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'ShowTaskViewButton' 0)) }
    @{ Id = 'search-icon'; Gruppe = 'DBL-SHELL'; Min = 0; Titel = (T 'Show search as an icon instead of a search box')
        Werte = @((Dv 'CV:\Search' 'SearchboxTaskbarMode' 1)) }
    @{ Id = 'endtask'; Gruppe = 'DBL-SHELL'; Min = 22621; Titel = (T 'Add "End task" to the taskbar context menu')
        Werte = @((Dv 'CV:\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1)) }
    @{ Id = 'fileext'; Gruppe = 'DBL-COMFORT'; Min = 0; Titel = (T 'Always show file extensions (e.g. .pdf)')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'HideFileExt' 0)) }
    @{ Id = 'hidden'; Gruppe = 'DBL-COMFORT'; Min = 0; Titel = (T 'Show hidden files and folders')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'Hidden' 1)) }
    @{ Id = 'thispc'; Gruppe = 'DBL-COMFORT'; Min = 0; Titel = (T 'Open File Explorer at "This PC"')
        Werte = @((Dv 'CV:\Explorer\Advanced' 'LaunchTo' 1)) }
    @{ Id = 'sticky'; Gruppe = 'DBL-COMFORT'; Min = 0; Titel = (T 'Turn off the Sticky Keys shortcut (pressing Shift five times)')
        Werte = @((Dv 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String')) }
)
# Removable apps: Gruppe|package name (start of the name)|display name. PROMO = ad and trial apps of third parties,
# MS = Microsoft apps that many people never use, OEM = tools of PC makers. Never in here: Store, Edge, Terminal, Xbox identity, Get Help.
# Apps that are never removed (prefix match in both directions, so a too short name cannot hit them either)
$Script:DebloatNever = 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.WindowsAppRuntime', 'Microsoft.VCLibs', 'Microsoft.UI.Xaml', 'Microsoft.NET.', 'Microsoft.WindowsTerminal', 'MicrosoftWindows.Client', 'Microsoft.Windows.Search', 'Microsoft.LockApp', 'Microsoft.Win32WebViewHost', 'Microsoft.WebpImageExtension', 'Microsoft.HEIFImageExtension', 'Microsoft.VP9VideoExtensions', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.WindowsCamera', 'Microsoft.GamingServices', 'Microsoft.Xbox.TCUI', 'NVIDIACorp', 'RealtekSemiconductorCorp', 'AdvancedMicroDevicesInc', 'IntelCorporation'
$Script:DebloatApps = @(@'
PROMO|Clipchamp.Clipchamp|Clipchamp
PROMO|ACGMediaPlayer|ACG Media Player
PROMO|ActiproSoftwareLLC|Actipro Software
PROMO|AdobeSystemsIncorporated.AdobePhotoshopExpress|Adobe Photoshop Express
PROMO|Amazon.com.Amazon|Amazon
PROMO|AmazonVideo.PrimeVideo|Prime Video
PROMO|Asphalt8Airborne|Asphalt 8
PROMO|AutodeskSketchBook|Autodesk SketchBook
PROMO|CaesarsSlotsFreeCasino|Caesars Slots
PROMO|COOKINGFEVER|Cooking Fever
PROMO|CyberLinkMediaSuiteEssentials|CyberLink Media Suite
PROMO|DisneyMagicKingdoms|Disney Magic Kingdoms
PROMO|Disney.37853FC22B2CE|Disney+
PROMO|DrawboardPDF|Drawboard PDF
PROMO|Duolingo-LearnLanguagesforFree|Duolingo
PROMO|FACEBOOK.FACEBOOK|Facebook
PROMO|FarmVille2CountryEscape|FarmVille 2
PROMO|Flipboard|Flipboard
PROMO|HiddenCity|Hidden City
PROMO|HULULLC.HULUPLUS|Hulu
PROMO|iHeartRadio|iHeartRadio
PROMO|Facebook.Instagram|Instagram
PROMO|king.com.BubbleWitch3Saga|Bubble Witch 3
PROMO|king.com.CandyCrushSaga|Candy Crush Saga
PROMO|king.com.CandyCrushSodaSaga|Candy Crush Soda
PROMO|LinkedInforWindows|LinkedIn
PROMO|MarchofEmpires|March of Empires
PROMO|4DF9E0F8.Netflix|Netflix
PROMO|NYTCrossword|NYT Crossword
PROMO|OneCalendar|One Calendar
PROMO|PandoraMediaInc|Pandora
PROMO|PhototasticCollage|Phototastic Collage
PROMO|PicsArt-PhotoStudio|PicsArt
PROMO|PolarrPhotoEditorAcademicEdition|Polarr Photo Editor
PROMO|flaregamesGmbH.RoyalRevolt|Royal Revolt
PROMO|Sidia.LiveWallpaper|Live Wallpaper
PROMO|SlingTV|Sling TV
PROMO|SpotifyAB.SpotifyMusic|Spotify
PROMO|BytedancePte.Ltd.TikTok|TikTok
PROMO|TuneInRadio|TuneIn Radio
PROMO|WinZipUniversal|WinZip
MS|Microsoft.BingNews|Microsoft News
MS|Microsoft.BingWeather|Weather
MS|Microsoft.BingSearch|Bing Search
MS|Microsoft.ZuneVideo|Movies & TV
MS|Microsoft.Getstarted|Tips
MS|Microsoft.MicrosoftSolitaireCollection|Solitaire Collection
MS|Microsoft.MixedReality.Portal|Mixed Reality Portal
MS|Microsoft.WindowsFeedbackHub|Feedback Hub
MS|Microsoft.M365Companions|Microsoft 365 Companions
MS|Microsoft.549981C3F5F10|Cortana
MS|Microsoft.Windows.DevHome|Dev Home
MS|Microsoft.PowerAutomateDesktop|Power Automate
MS|Microsoft.People|People
MS|Microsoft.SkypeApp|Skype
MS|Microsoft.Wallet|Wallet
MS|Microsoft.3DBuilder|3D Builder
MS|Microsoft.Print3D|Print 3D
MS|Microsoft.Microsoft3DViewer|3D Viewer
MS|Microsoft.BingFinance|Bing Finance
MS|Microsoft.BingFoodAndDrink|Bing Food And Drink
MS|Microsoft.BingHealthAndFitness|Bing Health And Fitness
MS|Microsoft.BingSports|Bing Sports
MS|Microsoft.BingTranslator|Bing Translator
MS|Microsoft.BingTravel|Bing Travel
MS|Microsoft.Windows.AIHub|Copilot+ AI Hub
MS|Microsoft.PCManager|Microsoft PC Manager
MS|Microsoft.Messaging|Messaging
MS|Microsoft.MicrosoftJournal|Microsoft Journal
MS|Microsoft.MicrosoftPowerBIForWindows|Power BI
MS|Microsoft.NetworkSpeedTest|Network Speed Test
MS|Microsoft.Office.Sway|Sway
MS|Microsoft.OneConnect|One Connect
MS|Microsoft.XboxApp|Xbox Console Companion
MS|Microsoft.MicrosoftOfficeHub|Office Hub
MS|Microsoft.Todos|Microsoft To Do
MS|Microsoft.WindowsAlarms|Alarms & Clock
MS|Microsoft.WindowsMaps|Windows Maps
MS|Microsoft.WindowsSoundRecorder|Sound Recorder
MS|Microsoft.YourPhone|Phone Link
MS|MicrosoftWindows.CrossDevice|Cross Device Experience
MS|Microsoft.Whiteboard|Whiteboard
MS|Microsoft.windowscommunicationsapps|Mail & Calendar
OEM|AD2F1837.OMENCommandCenter|HP OMEN Gaming Hub
OEM|AcerIncorporated.AcerCareCenterS|Acer Care Center S
OEM|B9ECED6F.ASUSPCAssistant|MyASUS
OEM|B9ECED6F.Glidex|ASUS GlideX
OEM|SAMSUNGELECTRONICSCoLtd.SamsungQuickShare|Samsung Quick Share
OEM|9426MICRO-STARINTERNATION.MSICenter|MSI Center
OEM|SAMSUNGELECTRONICSCO.LTD.PCGallery|Samsung Gallery
OEM|SAMSUNGELECTRONICSCoLtd.SamsungFlux|Samsung Flow
OEM|SAMSUNGELECTRONICSCoLtd.SamsungNotes|Samsung Notes
OEM|B9ECED6F.ScreenPadMaster|ASUS ScreenXpert
OEM|SAMSUNGELECTRONICSCO.LTD.SamsungStudio|Samsung Studio
OEM|SAMSUNGELECTRONICSCO.LTD.SamsungScreenRecording|Samsung Screen Recorder
OEM|SAMSUNGELECTRONICSCO.LTD.Bixby|Samsung Bixby
OEM|SAMSUNGELECTRONICSCO.LTD.SamsungWelcome|Samsung Galaxy Book Experience
OEM|SAMSUNGELECTRONICSCO.LTD.SmartThingsWindows|Samsung SmartThings
OEM|SAMSUNGELECTRONICSCoLtd.MultiControl|Samsung Multi control
OEM|SAMSUNGELECTRONICSCoLtd.SecondScreen|Samsung Second Screen
OEM|SAMSUNGELECTRONICSCO.LTD.PENUP|Samsung PENUP
OEM|9426MICRO-STARINTERNATION.BusinessCenter|MSI Center Pro
OEM|AcerIncorporated.AcerRegistration|Acer Product Registration
OEM|E0469640.SmartAppearance|Lenovo Smart Appearance
OEM|LGElectronics.LGMonitorApp|LG Monitor App
OEM|AD2F1837.HPAIExperienceCenter|HP AI Experience Center
OEM|AD2F1837.HPConnectedMusic|HP Connected Music
OEM|AD2F1837.HPConnectedPhotopoweredbySnapfish|HP Connected Photo
OEM|AD2F1837.HPDesktopSupportUtilities|HP Desktop Support Utilities
OEM|AD2F1837.HPEasyClean|HP Easy Clean
OEM|AD2F1837.HPFileViewer|HP File Viewer
OEM|AD2F1837.HPJumpStarts|HP JumpStarts
OEM|AD2F1837.HPPCHardwareDiagnosticsWindows|HP PC Hardware Diagnostics
OEM|AD2F1837.HPPowerManager|HP Power Manager
OEM|AD2F1837.HPPrinterControl|HP Printer Control
OEM|AD2F1837.HPPrivacySettings|HP Privacy Settings
OEM|AD2F1837.HPQuickDrop|HP QuickDrop
OEM|AD2F1837.HPQuickTouch|HP QuickTouch
OEM|AD2F1837.HPRegistration|HP Registration
OEM|AD2F1837.HPSupportAssistant|HP Support Assistant
OEM|AD2F1837.HPSureShieldAI|HP Sure Shield AI
OEM|AD2F1837.HPSystemInformation|HP System Information
OEM|AD2F1837.HPWelcome|HP Welcome
OEM|AD2F1837.HPWorkWell|HP WorkWell
OEM|AD2F1837.myHP|myHP
OEM|E046963F.LenovoCompanion|Lenovo Vantage
OEM|LenovoCompanyLimited.LenovoVantageService|Lenovo Vantage Service
OEM|DellInc.DellSupportAssistforPCs|Dell SupportAssist
OEM|DellInc.DellDigitalDelivery|Dell Digital Delivery Services
OEM|DellInc.DellMobileConnect|Dell Mobile Connect
'@ -split "`r?`n" | Where-Object { $_ } | ConvertFrom-Csv -Delimiter '|' -Header Gruppe, Id, Name)

function Get-DebloatValue([string]$Key, [string]$Name) {
    try { $p = Get-ItemProperty -LiteralPath $Key -ErrorAction Stop; $pr = $p.PSObject.Properties[$Name]; if ($pr) { return $pr.Value } } catch { }
    return $null
}
# Are all values of the setting already as WinTidy would set them?
function Test-DebloatTweakSet($Tweak) {
    foreach ($v in @($Tweak.Werte)) {
        $cur = Get-DebloatValue $v.Key $v.Name
        if ($null -eq $cur -or [string]$cur -ne [string]$v.Wert) { return $false }
    }
    return $true
}
# HKCU and the app list belong to the account that runs WinTidy. If WinTidy runs under a different account than the one that is
# signed in, the settings would land in the wrong profile - then the Debloat rules offer nothing.
function Test-DebloatUserHive {
    $ctx = $Script:LastContext
    if (-not $ctx) { try { $ctx = Get-WtContext } catch { } }
    return (-not ($ctx -and $ctx.AnderesKonto))
}
function Get-WtBuildNumber {
    if (-not $Script:Cache.ContainsKey('Build')) {
        $b = 0; try { $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild } catch { }
        $Script:Cache['Build'] = $b
    }
    return $Script:Cache['Build']
}
function Get-DebloatTweakItems([string]$Group) {
    if (-not (Test-DebloatUserHive)) { return }
    $build = Get-WtBuildNumber
    foreach ($t in $Script:DebloatTweaks) {
        if ($t.Gruppe -ne $Group -or ($t.Min -and $build -gt 0 -and $build -lt $t.Min)) { continue }
        if (-not (Test-DebloatTweakSet $t)) { New-Item2 $t.Titel 0 $t.Id }
    }
}
function Set-DebloatTweak([string]$Rule, $Item) {
    $t = $Script:DebloatTweaks | Where-Object { $_.Id -eq $Item.Data } | Select-Object -First 1
    if (-not $t) { throw (T 'Unknown setting') }
    foreach ($v in @($t.Werte)) { Set-RegValueWithUndo $Rule $t.Titel $v.Key $v.Name $v.Wert $v.Typ }
    (T 'changed')
}
# Installed apps of the catalog group. Since 1.9 the former rule APP-BLOAT is part of the catalog (group MS); the
# configuration key BloatApps only adds further package names to the group MS (nothing preselected, as everywhere here).
function Get-DebloatAppItems([string]$Group) {
    if (-not (Test-DebloatUserHive)) { return }
    if (-not $Script:Cache.ContainsKey('Appx')) { $Script:Cache['Appx'] = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable -and -not $_.IsFramework }) }
    $liste = @($Script:DebloatApps)
    if ($Group -eq 'MS') {
        $bekannt = @($liste | ForEach-Object { [string]$_.Id })
        $liste += @($Script:Cfg.BloatApps | Where-Object { $_ -and $bekannt -notcontains [string]$_ } | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ Gruppe = 'MS'; Id = [string]$_; Name = (Get-AppDisplayName ([string]$_)) } })
    }
    foreach ($a in $liste) {
        if ($a.Gruppe -ne $Group) { continue }
        $p = @($Script:Cache['Appx'] | Where-Object { $_.Name -like ($a.Id + '*') })
        $nm = if ($Script:AppNames -and $Script:AppNames.ContainsKey([string]$a.Id)) { $Script:AppNames[[string]$a.Id] } else { $a.Name }
        if ($p.Count) { New-Item2 $nm 0 $a.Id ("{0} {1}" -f $p[0].Name, $p[0].Version) }
    }
}
function Remove-DebloatApp([string]$Id) {
    if ($Id -notmatch '^[\w\.\-]+$' -or @($Script:DebloatNever | Where-Object { $Id -like ($_ + '*') -or $_ -like ($Id + '*') }).Count) { throw (T 'Unexpected app name - not removed') }
    $found = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($Id + '*') -and -not $_.NonRemovable -and -not $_.IsFramework })
    foreach ($p in $found) { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
    # also from the Windows image, so that new accounts do not get the app again
    if ($Script:IsAdmin) { try { Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like ($Id + '*') } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null } } catch { } }
    (T 'removed')
}

# Change a registry value with undo info (before/after; Restore only resets if nobody has changed the value since)
function Set-RegValueWithUndo([string]$Rule, [string]$Objekt, [string]$Key, [string]$Name, $Value, [string]$Type, [switch]$Remove) {
    $vorher = Get-RegValueRaw $Key $Name
    if ($Remove) { Remove-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop }
    else {
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    }
    $nachher = Get-RegValueRaw $Key $Name
    Add-ActionRecord $Rule $Objekt 'Undo-Info' 0 '' @{ Typ = 'RegValue'; Key = $Key; Name = $Name; Vorher = $vorher; Nachher = $nachher } | Out-Null
}
function Test-RegKeyAllowed([string]$Key) { $kt = ConvertTo-RegKeyText $Key; return ($kt -notmatch '(^|\\)\.\.?(\\|$)' -and $kt -match $Script:RestoreKeyAllow) }
function Restore-RegValue($u) {
    if (-not (Test-RegKeyAllowed $u.Key)) { throw (T 'Unexpected registry path - not reset') }
    $cur = Get-RegValueRaw $u.Key $u.Name
    $a = if ($null -eq $cur) { '' } else { $cur | ConvertTo-Json -Compress -Depth 3 }
    $b = if ($null -eq $u.Nachher) { '' } else { $u.Nachher | ConvertTo-Json -Compress -Depth 3 }
    if ($a -ne $b) { throw (T 'Changed since - not overwritten') }
    if ($null -eq $u.Vorher) { if ($null -ne $cur) { Remove-ItemProperty -LiteralPath $u.Key -Name $u.Name -ErrorAction Stop }; return }
    $v = $u.Vorher.Wert
    switch ([string]$u.Vorher.Art) { 'Binary' { $v = [byte[]][Convert]::FromBase64String([string]$v) } 'DWord' { $v = [int]$v } 'QWord' { $v = [int64]$v } 'MultiString' { $v = [string[]]@($v) } }
    if (-not (Test-Path -LiteralPath $u.Key)) { New-Item -Path $u.Key -Force | Out-Null }
    Set-ItemProperty -LiteralPath $u.Key -Name $u.Name -Value $v -Type ([string]$u.Vorher.Art) -ErrorAction Stop
}
function Backup-Task($Task) {
    if (-not $Script:RunDir) { return }
    $dir = Join-Path $Script:RunDir 'backup\tasks'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safe = (($Task.TaskPath + $Task.TaskName) -replace '[^\w\-]', '_')
    try {
        Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath | Out-File (Join-Path $dir "$safe.xml") -Encoding unicode
        [ordered]@{ TaskName = $Task.TaskName; TaskPath = $Task.TaskPath; Datei = "$safe.xml" } | ConvertTo-Json -Compress | Out-File (Join-Path $dir 'index.jsonl') -Append -Encoding utf8
    } catch { }
}

# =============================================================================
#  Data sources
# =============================================================================
function Get-InstalledApps {
    if ($Script:Cache.Apps) { return $Script:Cache.Apps }
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $Script:Cache.Apps = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.ParentKeyName -and $_.SystemComponent -ne 1 } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, UninstallString, QuietUninstallString, EstimatedSize, PSChildName, PSPath)
    return $Script:Cache.Apps
}

function Get-BootEvents([int]$Max = 60) {
    if ($Script:Cache.Boots) { return $Script:Cache.Boots }
    $r = @()
    try {
        $r = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents $Max -ErrorAction Stop | ForEach-Object {
            $x = [xml]$_.ToXml(); $d = @{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
            [pscustomobject]@{ Zeit = $_.TimeCreated.ToString('o'); GesamtMs = [int]$d.BootTime; HauptpfadMs = [int]$d.MainPathBootTime; NachDesktopMs = [int]$d.BootPostBootTime }
        })
    } catch { }
    $Script:Cache.Boots = $r
    return $r
}
function Get-BootOffenders([int]$Days = 60) {
    if ($Script:Cache.Offenders) { return $Script:Cache.Offenders }
    $r = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101, 102, 103, 106, 109; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction Stop
        $rows = foreach ($e in $ev) {
            $x = [xml]$e.ToXml(); $d = @{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
            $typ = switch ($e.Id) { 101 { 'App' } 102 { (T 'Driver') } 103 { (T 'Service') } 106 { (T 'Background') } 109 { (T 'Device') } }
            [pscustomobject]@{ Typ = $typ; Datei = $d.Name; Name = $d.FriendlyName; DegradationMs = [int]$d.DegradationTime }
        }
        $r = @($rows | Where-Object Datei | Group-Object Typ, Datei | ForEach-Object {
            [pscustomobject]@{ Typ = $_.Group[0].Typ; Datei = $_.Group[0].Datei; Name = ($_.Group | Where-Object Name | Select-Object -First 1).Name; Anzahl = $_.Count; MittelMs = [int](($_.Group | Measure-Object DegradationMs -Average).Average); MaxMs = [int](($_.Group | Measure-Object DegradationMs -Maximum).Maximum) }
        } | Sort-Object MittelMs -Descending)
    } catch { }
    $Script:Cache.Offenders = $r
    return $r
}

$Script:SA_HKCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$Script:SA_HKLM = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$Script:AppxStartupRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
function Get-ApprovedEnabled([string]$Key, [string]$Name) {
    $p = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
    if (-not $p -or -not ($p.PSObject.Properties.Name -contains $Name)) { return $true }
    $v = $p.$Name
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] % 2) -eq 0) }
    return $true
}
function Get-StartupItems {
    if ($Script:Cache.Startup) { return $Script:Cache.Startup }
    $list = New-Object System.Collections.Generic.List[object]
    $off = Get-BootOffenders
    $runKeys = @(
        @{ Ort = 'HKCU Run'; Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Reg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; SA = "$Script:SA_HKCU\Run" },
        @{ Ort = 'HKLM Run'; Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Reg = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run'; SA = "$Script:SA_HKLM\Run" },
        @{ Ort = 'HKLM Run32'; Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Reg = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; SA = "$Script:SA_HKLM\Run32" }
    )
    foreach ($rk in $runKeys) {
        $p = Get-ItemProperty -Path $rk.Key -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in ($p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
            $t = Resolve-CommandTarget ([string]$prop.Value)
            $list.Add([pscustomobject]@{ Name = $prop.Name; Art = 'Registry'; Ort = $rk.Ort; Befehl = [string]$prop.Value; Ziel = $t; Zustand = (Get-TargetState $t); Aktiv = (Get-ApprovedEnabled $rk.SA $prop.Name); Key = $rk.Key; RegKey = $rk.Reg; SAKey = $rk.SA; DegradationMs = 0 })
        }
    }
    $sh = $null; try { $sh = New-Object -ComObject WScript.Shell } catch { }
    $folders = @(
        @{ Ort = (T 'Startup folder (user)'); Path = [Environment]::GetFolderPath('Startup'); SA = "$Script:SA_HKCU\StartupFolder"; Reg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Ort = (T 'Startup folder (all users)'); Path = [Environment]::GetFolderPath('CommonStartup'); SA = "$Script:SA_HKLM\StartupFolder"; Reg = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path $f.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $t = $file.FullName
            if ($file.Extension -eq '.lnk' -and $sh) { try { $tp = $sh.CreateShortcut($file.FullName).TargetPath; if ($tp) { $t = $tp } } catch { } }
            $list.Add([pscustomobject]@{ Name = $file.Name; Art = 'Ordner'; Ort = $f.Ort; Befehl = $file.FullName; Ziel = $t; Zustand = (Get-TargetState $t); Aktiv = (Get-ApprovedEnabled $f.SA $file.Name); Key = $f.Path; RegKey = $f.Reg; SAKey = $f.SA; DegradationMs = 0 })
        }
    }
    $installedPkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PackageFamilyName)
    foreach ($pkg in (Get-ChildItem $Script:AppxStartupRoot -ErrorAction SilentlyContinue)) {
        foreach ($task in (Get-ChildItem $pkg.PSPath -ErrorAction SilentlyContinue)) {
            $st = (Get-ItemProperty $task.PSPath -ErrorAction SilentlyContinue).State
            if ($null -eq $st) { continue }
            $fam = $pkg.PSChildName
            $zust = if (-not $installedPkgs.Count) { 'unbekannt' } elseif ($installedPkgs -contains $fam) { 'ok' } else { 'fehlt' }
            $list.Add([pscustomobject]@{ Name = $task.PSChildName; Art = 'StoreApp'; Ort = $fam; Befehl = $fam; Ziel = $fam; Zustand = $zust; Aktiv = ($st -eq 2 -or $st -eq 4); Key = $task.PSPath; RegKey = $null; SAKey = $null; DegradationMs = 0; State = $st })
        }
    }
    foreach ($i in $list) {
        $leaf = ''; if ($i.Ziel) { try { $leaf = [IO.Path]::GetFileName([string]$i.Ziel) } catch { } }
        $m = $off | Where-Object { $_.Typ -eq 'App' -and ($_.Datei -eq $leaf -or ($i.Art -eq 'StoreApp' -and $_.Datei -like "$($i.Name)*")) } | Select-Object -First 1
        if ($m) { $i.DegradationMs = $m.MittelMs }
    }
    $Script:Cache.Startup = $list.ToArray()
    return $Script:Cache.Startup
}

function Get-DriverPackages {
    if ($Script:Cache.Drivers) { return $Script:Cache.Drivers }
    $raw = & pnputil.exe /enum-drivers 2>$null
    $pk = New-Object System.Collections.Generic.List[object]; $cur = @{}
    foreach ($l in (@($raw) + '')) {
        if ($l -match '^\s*$') { if ($cur.Pub) { $pk.Add([pscustomobject]$cur) }; $cur = @{}; continue }
        if ($l -match '^(Published Name|Ver.ffentlichter Name)\s*:\s*(.+)$') { $cur.Pub = $Matches[2].Trim() }
        elseif ($l -match '^(Original Name|Urspr.nglicher Name|Originalname)\s*:\s*(.+)$') { $cur.Orig = $Matches[2].Trim().ToLower() }
        elseif ($l -match '^(Provider Name|Anbietername)\s*:\s*(.+)$') { $cur.Prov = $Matches[2].Trim() }
        elseif ($l -match '^(Class Name|Klassenname)\s*:\s*(.+)$') { $cur.Klasse = $Matches[2].Trim() }
        elseif ($l -match '^(Driver Version|Treiberversion)\s*:\s*(\S+)\s+(\S+)') {
            $cur.DatumText = $Matches[2]; $cur.VerText = $Matches[3]
            try { $cur.Ver = [version]$Matches[3] } catch { $cur.Ver = [version]'0.0' }
            try { $cur.Datum = [datetime]::ParseExact($Matches[2], 'MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { try { $cur.Datum = [datetime]$Matches[2] } catch { $cur.Datum = [datetime]'1900-01-01' } }
        }
    }
    $Script:Cache.Drivers = $pk.ToArray()
    return $Script:Cache.Drivers
}

function Get-VolumeInfo {
    $map = @{}
    try {
        foreach ($pd in Get-PhysicalDisk -ErrorAction Stop) {
            foreach ($part in (Get-Partition -DiskNumber $pd.DeviceId -ErrorAction SilentlyContinue | Where-Object DriveLetter)) {
                $map["$($part.DriveLetter)"] = [pscustomobject]@{ Medium = [string]$pd.MediaType; Bus = [string]$pd.BusType; Disk = $pd.FriendlyName }
            }
        }
    } catch { }
    @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 2GB } | Sort-Object DriveLetter | ForEach-Object {
        $m = $map["$($_.DriveLetter)"]
        [pscustomobject]@{ LW = "$($_.DriveLetter)"; Label = $_.FileSystemLabel; FS = $_.FileSystem; GroesseGB = [math]::Round($_.Size / 1GB, 1); FreiGB = [math]::Round($_.SizeRemaining / 1GB, 1); FreiProzent = [math]::Round(100 * $_.SizeRemaining / $_.Size, 1); Medium = $(if ($m) { $m.Medium } else { '' }); Bus = $(if ($m) { $m.Bus } else { '' }); Disk = $(if ($m) { $m.Disk } else { '' }) }
    })
}

function Get-GhostDevices {
    $cls = $Script:Cfg.GhostDeviceClasses; $ex = $Script:Cfg.GhostDeviceExclude
    @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $d = $_
        -not $d.Present -and $cls -contains $d.Class -and $d.InstanceId -notmatch '^(SWD|ROOT)\\' -and -not ($ex | Where-Object { $d.FriendlyName -like "*$_*" })
    })
}
# When was each device last seen (newest of last removal and last arrival)? Devices without a date are missing from
# the result - callers treat them as "unknown" and do not offer them (fail closed).
function Get-DeviceLastSeen([string[]]$InstanceIds) {
    $res = @{}
    if (-not $InstanceIds.Count) { return $res }
    $props = @(); try { $props = @(Get-PnpDeviceProperty -InstanceId $InstanceIds -KeyName 'DEVPKEY_Device_LastRemovalDate', 'DEVPKEY_Device_LastArrivalDate' -ErrorAction SilentlyContinue) } catch { }
    foreach ($p in $props) {
        if (-not $p.Data) { continue }
        $d = $null; try { $d = [datetime]$p.Data } catch { continue }
        $id = [string]$p.InstanceId
        if (-not $res.ContainsKey($id) -or $d -gt $res[$id]) { $res[$id] = $d }
    }
    return $res
}
function Get-RecycleBinOld([int]$Days) {
    $res = @()
    try {
        $limit = (Get-Date).AddDays(-$Days)
        $rb = (New-Object -ComObject Shell.Application).Namespace(10)
        foreach ($it in @($rb.Items())) {
            $d = $null; try { $d = [datetime]$it.ExtendedProperty('System.Recycle.DateDeleted') } catch { }
            if ($d -and $d -lt $limit) { $res += [pscustomobject]@{ Path = $it.Path; Size = [int64]$it.Size; Name = $it.Name } }
        }
    } catch { }
    return $res
}

# Joins a relative path written with \ to a base path with the separator of the platform (tests also run on Linux)
function Join-WtPath([string]$Base, [string]$Rel) { $p = $Base; foreach ($s in @($Rel -split '[\\/]' | Where-Object { $_ })) { $p = [IO.Path]::Combine($p, $s) }; return $p }

# Browser caches (rule CLN-BROWSER). Root = folder below %LOCALAPPDATA%. Art: Chromium = profiles are the subfolders of
# "User Data" that contain a Preferences file, Single = the root is the only profile, Firefox = every folder in Profiles.
# Only cache folders are ever touched - cookies, sign-ins, history, passwords, bookmarks and extensions live elsewhere.
$Script:BrowserCatalog = @(
    @{ Name = 'Microsoft Edge'; Prozess = 'msedge'; Root = 'Microsoft\Edge\User Data'; Art = 'Chromium' }
    @{ Name = 'Google Chrome'; Prozess = 'chrome'; Root = 'Google\Chrome\User Data'; Art = 'Chromium' }
    @{ Name = 'Brave'; Prozess = 'brave'; Root = 'BraveSoftware\Brave-Browser\User Data'; Art = 'Chromium' }
    @{ Name = 'Vivaldi'; Prozess = 'vivaldi'; Root = 'Vivaldi\User Data'; Art = 'Chromium' }
    @{ Name = 'Opera'; Prozess = 'opera'; Root = 'Opera Software\Opera Stable'; Art = 'Single' }
    @{ Name = 'Opera GX'; Prozess = 'opera'; Root = 'Opera Software\Opera GX Stable'; Art = 'Single' }
    @{ Name = 'Mozilla Firefox'; Prozess = 'firefox'; Root = 'Mozilla\Firefox\Profiles'; Art = 'Firefox' }
)
$Script:BrowserCacheProfileDirs = @('Cache', 'Code Cache', 'GPUCache')
$Script:BrowserCacheRootDirs = @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache')
$Script:BrowserCacheFirefoxDirs = @('cache2')
function Get-BrowserCacheDirs {
    if ($Script:Cache.ContainsKey('BrowserCaches')) { return $Script:Cache['BrowserCaches'] }
    $res = @()
    $base = $env:LOCALAPPDATA
    if ($base) {
        foreach ($b in $Script:BrowserCatalog) {
            $root = Join-WtPath $base $b.Root
            $ri = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
            if (-not $ri -or -not $ri.PSIsContainer -or (Test-Reparse $ri)) { continue }
            $profiles = @()
            if ($b.Art -eq 'Single') { $profiles = @($root) }
            else {
                $profiles = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-Reparse $_) -and ($b.Art -eq 'Firefox' -or (Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences'))) } | ForEach-Object { $_.FullName })
            }
            $dirs = @()
            $sub = if ($b.Art -eq 'Firefox') { $Script:BrowserCacheFirefoxDirs } else { $Script:BrowserCacheProfileDirs }
            foreach ($p in $profiles) { foreach ($s in $sub) { $dirs += [IO.Path]::Combine($p, $s) } }
            if ($b.Art -ne 'Firefox') { foreach ($s in $Script:BrowserCacheRootDirs) { $dirs += [IO.Path]::Combine($root, $s) } }
            $dirs = @($dirs | Select-Object -Unique | Where-Object { $i = Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue; $i -and $i.PSIsContainer -and -not (Test-Reparse $i) })
            if (-not $dirs.Count) { continue }
            $bytes = [int64]0; foreach ($d in $dirs) { $bytes += Get-DirSize $d }
            $res += [pscustomobject]@{ Name = $b.Name; Prozess = $b.Prozess; Root = $root; Dirs = $dirs; Profile = $profiles.Count; Bytes = $bytes }
        }
    }
    $Script:Cache['BrowserCaches'] = $res
    return $res
}
function Test-BrowserRunning([string]$Name) { return [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue) }
# Empties the cache folders of one browser. Checks everything again: known root below %LOCALAPPDATA%, only known cache
# folder names, no link on the way, browser closed. Files that are in use stay.
function Clear-BrowserCache($Data) {
    $base = $env:LOCALAPPDATA; $root = [string]$Data.Root
    $known = @($Script:BrowserCatalog | Where-Object { $base -and (Join-WtPath $base $_.Root) -eq $root -and $_.Prozess -eq [string]$Data.Prozess })
    if (-not $known.Count -or -not (Test-SafeDeleteRoot $root)) { throw (T 'Unexpected path') }
    if (Test-BrowserRunning ([string]$Data.Prozess)) { throw ('SKIP:' + (T '{0} is still open - close it completely (Edge and Chrome often keep running in the background) and apply again' ([string]$Data.Name))) }
    $names = @($Script:BrowserCacheProfileDirs) + @($Script:BrowserCacheRootDirs) + @($Script:BrowserCacheFirefoxDirs)
    $vor = [int64]0; $nach = [int64]0; $gesperrt = 0
    foreach ($dir in @($Data.Dirs)) {
        $dir = [string]$dir
        if ($names -notcontains [IO.Path]::GetFileName($dir) -or -not (Test-PathChainNoReparse $root $dir)) { throw (T 'Unexpected path') }
        $di = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if (-not $di -or -not $di.PSIsContainer -or (Test-Reparse $di)) { continue }
        $vor += Get-DirSize $dir
        foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) { if (Test-Reparse $e) { continue }; try { Remove-TreeNoFollow $e.FullName } catch { $gesperrt++ } }
        $nach += Get-DirSize $dir
    }
    $msg = (T '{0} freed' (Fmt-Bytes ([math]::Max(0, $vor - $nach))))
    if ($gesperrt) { $msg += (T ' ({0} entries in use were kept)' $gesperrt) }
    return $msg
}

# Personal folders for the large-file overview (CLN-BIGFILES). Art is an internal name, Pfad the real folder.
function Get-PersonalFolders {
    $r = @()
    $dl = $null
    try { $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'; if ($v) { $dl = [Environment]::ExpandEnvironmentVariables([string]$v) } } catch { }
    if (-not $dl -and $env:USERPROFILE) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
    if ($dl) { $r += [pscustomobject]@{ Art = 'Downloads'; Pfad = $dl } }
    foreach ($p in @(@('Desktop', 'Desktop'), @('Documents', 'MyDocuments'), @('Videos', 'MyVideos'))) { $x = [Environment]::GetFolderPath($p[1]); if ($x) { $r += [pscustomobject]@{ Art = $p[0]; Pfad = $x } } }
    $seen = @{}; $out = @()
    foreach ($x in $r) {
        $k = ([string]$x.Pfad).TrimEnd('\', '/').ToLower()
        if (-not $k -or $seen.ContainsKey($k) -or -not (Test-Path -LiteralPath $x.Pfad -PathType Container)) { continue }
        $seen[$k] = $true; $out += $x
    }
    return $out
}
# One pass through the personal folders: large files and old files in Downloads. Never follows links and skips files that
# are only in the cloud (OneDrive "online only" - they take up no space on this PC). Stops after MaxFiles files.
function Get-PersonalFileStats([int64]$MinBytes, [int]$OldDays, [int]$MaxFiles = 50000) {
    if ($Script:Cache.ContainsKey('PersonalFiles')) { return $Script:Cache['PersonalFiles'] }
    $big = New-Object System.Collections.Generic.List[object]
    $limit = (Get-Date).AddDays(-$OldDays)
    $cloud = 0x1000 -bor 0x40000 -bor 0x400000   # Offline, RecallOnOpen, RecallOnDataAccess
    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $n = 0; $alt = 0; $altBytes = [int64]0; $voll = $false
    foreach ($f in @(Get-PersonalFolders)) {
        $ri = New-Object IO.DirectoryInfo $f.Pfad
        if (-not $ri.Exists -or ($ri.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'; $stack.Push($ri)
        while ($stack.Count -and -not $voll) {
            $d = $stack.Pop()
            $entries = @(); try { $entries = $d.GetFileSystemInfos() } catch { continue }
            foreach ($e in $entries) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) { $stack.Push($e); continue }
                if (([int64]$e.Attributes) -band $cloud) { continue }
                if (-not $seenFiles.Add($e.FullName)) { continue }
                $n++; if ($n -gt $MaxFiles) { $voll = $true; break }
                $len = [int64]$e.Length
                $rel = (Get-PersonalFolderText $f.Art) + $e.FullName.Substring($ri.FullName.TrimEnd([IO.Path]::DirectorySeparatorChar).Length)
                if ($len -ge $MinBytes) { $big.Add([pscustomobject]@{ Art = $f.Art; Rel = $rel; Pfad = $e.FullName; Bytes = $len; Zeit = $e.LastWriteTime }) }
                if ($f.Art -eq 'Downloads' -and $e.LastWriteTime -lt $limit -and $e.CreationTime -lt $limit) { $alt++; $altBytes += $len }
            }
        }
    }
    $r = [pscustomobject]@{ Gross = @($big | Sort-Object Bytes -Descending); AltDownloads = $alt; AltDownloadsBytes = $altBytes; Dateien = [math]::Min($n, $MaxFiles); Abgebrochen = $voll }
    $Script:Cache['PersonalFiles'] = $r
    return $r
}
function Get-PersonalFolderText([string]$Art) { switch ($Art) { 'Downloads' { return (T 'Downloads') } 'Desktop' { return (T 'Desktop') } 'Documents' { return (T 'Documents') } 'Videos' { return (T 'Videos') } }; return $Art }

# Check reminder: $null if there is no check yet, the reminder is off (CheckReminderDays = 0) or the last check is recent
function Get-CheckReminder {
    $days = 0; [void][int]::TryParse([string]$Script:Cfg.CheckReminderDays, [ref]$days)
    if ($days -le 0) { return $null }
    $last = Get-Snapshots | Select-Object -Last 1
    if (-not $last -or $last.Name -notmatch '^(\d{8}-\d{6})_') { return $null }
    $t = $null; try { $t = [datetime]::ParseExact($Matches[1], 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
    $alt = [int][math]::Floor(((Get-Date) - $t).TotalDays)
    if ($alt -lt $days) { return $null }
    [pscustomobject]@{ Tage = $alt; Zuletzt = $t.ToString('o'); Text = (T 'The last check of this PC was {0} days ago. A new check shows what has changed since - it changes nothing.' $alt) }
}

# =============================================================================
#  Context (server, company PC, battery, other account) and hardware data sources
# =============================================================================
function Test-RebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

# Device type: laptop (PCSystemType 2 or mobile chassis), battery present (excluding UPS), currently on battery, VM
function Get-ChassisInfo {
    if ($Script:Cache.Chassis) { return $Script:Cache.Chassis }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1).ChassisTypes)
    $mobile = [bool]($types | Where-Object { $_ -in 8, 9, 10, 11, 14, 30, 31, 32 })
    $laptop = ($cs -and [int]$cs.PCSystemType -eq 2) -or $mobile
    # UPS devices also report as batteries - do not count them
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DeviceID) $($_.Caption)" -notmatch '(?i)\bUPS\b|\bUSV\b|APC|Eaton|CyberPower' })
    $akku = $false
    if ($laptop -and $bat.Count) {
        $st = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue)
        if ($st.Count) { $akku = [bool]($st | Where-Object { $_.PowerOnline -eq $false }) }
        else { $akku = [bool]($bat | Where-Object { $_.BatteryStatus -in 1, 4, 5 }) }
    }
    $vm = [bool]($cs -and ("$($cs.Model) $($cs.Manufacturer)" -match '(?i)virtual|vmware|kvm|qemu|virtualbox|innotek|xen|parallels'))
    $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1)
    $r = [pscustomobject]@{ Laptop = [bool]$laptop; Akku = [bool]$akku; HatAkku = ($bat.Count -gt 0 -and $laptop); Typen = $types; VM = $vm; CpuName = $(if ($cpu) { ([string]$cpu.Name).Trim() } else { '' }) }
    $Script:Cache.Chassis = $r
    return $r
}

function Get-WtContext {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $mdm = $false
    try {
        foreach ($k in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.ProviderID -eq 'MS DM Server' -and $p.EnrollmentState -eq 1) { $mdm = $true; break }
        }
    } catch { }
    $aad = [bool](Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction SilentlyContinue)
    $sccm = Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM'
    $domain = [bool]($cs -and $cs.PartOfDomain)
    $sess = if ($cs) { [string]$cs.UserName } else { '' }
    $proc = [string]$Script:Me.Name
    $ch = Get-ChassisInfo
    [pscustomobject]@{
        # Fail-closed: if the operating system cannot be queried, treat it like a server (check only)
        Server = ((-not $os) -or $os.ProductType -ne 1); Verwaltet = ($domain -or $mdm -or $aad -or $sccm); Domaene = $domain; Intune = $mdm; EntraJoin = $aad; ConfigMgr = $sccm
        AnderesKonto = [bool]($sess -and $proc -and $sess -ne $proc); ProzessBenutzer = $proc; SitzungsBenutzer = $sess
        NeustartAusstehend = [bool](Test-RebootPending); Akku = [bool]$ch.Akku; Laptop = [bool]$ch.Laptop; VM = [bool]$ch.VM; Admin = $Script:IsAdmin; Hinweise = @()
    }
}

# Other active security products (Security Center, client Windows only). productState bit 0x1000 = active
function Get-OtherSecurityProducts([string]$Class) {
    $k = "Sec_$Class"; if ($Script:Cache.ContainsKey($k)) { return $Script:Cache[$k] }
    $r = @(); try { $r = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName $Class -ErrorAction Stop | Where-Object { [string]$_.displayName -notmatch '(?i)defender|windows' -and ([int64]$_.productState -band 0x1000) } | ForEach-Object { [string]$_.displayName }) } catch { }
    $Script:Cache[$k] = $r
    return $r
}
# End of support of the Windows version and last update installation
function Get-WindowsSupportInfo {
    if ($Script:Cache.ContainsKey('WinSupport')) { return $Script:Cache.WinSupport }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [string]$cv.CurrentBuild; $ed = [string]$cv.EditionID
    $ende = $null
    $tab = $Script:Cfg.WindowsSupportEnd
    $wert = if ($tab -is [System.Collections.IDictionary]) { $tab[$build] } elseif ($tab) { $tab.$build } else { $null }
    if ($wert -and $ed -notmatch '(?i)LTSC|EnterpriseS|IoT|Server') {
        try { $ende = [datetime]::ParseExact([string]$wert, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); if ($ed -match '(?i)Enterprise|Education' -and [int]$build -ge 22000) { $ende = $ende.AddMonths(12) } } catch { }
    }
    $tage = $null
    try { $d = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate; if ($d -and ([datetime]$d).Year -ge 2010) { $tage = [int]((Get-Date) - [datetime]$d).TotalDays } } catch { }
    $wu = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
    $name = ("{0} {1}" -f $(if ([int]$build -ge 22000) { 'Windows 11' } else { 'Windows 10' }), $cv.DisplayVersion).Trim()
    $r = [pscustomobject]@{ Build = $build; Edition = $ed; Version = $name; Ende = $ende; TageSeitUpdate = $tage; WuDeaktiviert = [bool]($wu -and $wu.StartMode -eq 'Disabled') }
    $Script:Cache.WinSupport = $r
    return $r
}

# --- Read-only data sources of the security health check, Storage Sense and AI inventory (replaceable in tests)
# Status of the drive encryption of the system drive: Geschuetzt | Ausgesetzt | Aus | $null (unknown)
function Get-BitLockerState {
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop | Select-Object -First 1
        if (-not $v) { return $null }
        $prot = [string]$v.ProtectionStatus; $vs = [string]$v.VolumeStatus
        if ($prot -match '^(On|1)$') { return 'Geschuetzt' }
        if ($prot -match '^(Off|0)$') { if ($vs -match 'Encrypt') { return 'Ausgesetzt' } else { return 'Aus' } }
        return $null
    } catch { return $null }
}
# Memory integrity (core isolation, HVCI): $true | $false | $null (unknown)
function Get-MemoryIntegrityState {
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\State' -ErrorAction Stop).HVCIEnabled
        if ($null -eq $v) { return $null }
        return ([int]$v -eq 1)
    } catch { return $null }
}
# Security chip: @{ Vorhanden; Bereit } or $null
function Get-TpmState {
    try { $x = Get-Tpm -ErrorAction Stop; return [pscustomobject]@{ Vorhanden = [bool]$x.TpmPresent; Bereit = [bool]$x.TpmReady } } catch { return $null }
}
# Tamper protection of Microsoft Defender: $true | $false | $null
function Get-DefenderTamperState {
    try { $m = Get-MpComputerStatus -ErrorAction Stop; if ($null -eq $m.IsTamperProtected) { return $null }; return [bool]$m.IsTamperProtected } catch { return $null }
}
# Storage Sense (per user) and its policy: @{ Aktiv; DownloadsTage; PapierkorbTage; Richtlinie } or $null
function Get-StorageSenseState {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    $pol = $null; try { $pv = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -ErrorAction Stop).AllowStorageSenseGlobal; if ($null -ne $pv) { $pol = [int]$pv } } catch { }
    if (-not (Test-Path -LiteralPath $k)) { return [pscustomobject]@{ Aktiv = $false; DownloadsTage = 0; PapierkorbTage = 0; Richtlinie = $pol } }
    try {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        $dl = 0; if ($null -ne $p.'512') { $dl = [int]$p.'512' }
        $rb = 0; if ($null -ne $p.'256') { $rb = [int]$p.'256' }
        return [pscustomobject]@{ Aktiv = ($p.'01' -eq 1); DownloadsTage = $dl; PapierkorbTage = $rb; Richtlinie = $pol }
    } catch { return $null }
}
# AI features: Copilot app, Recall, policies. Only reads.
function Get-AiFeatureState {
    $r = [pscustomobject]@{ CopilotApp = $false; CopilotRichtlinieAus = $false; RecallAktiv = $null; RecallRichtlinie = $null; DatenanalyseAus = $false }
    try { $r.CopilotApp = [bool](Get-AppxPackage -Name 'Microsoft.Copilot' -ErrorAction Stop) } catch { }
    try { $r.CopilotRichtlinieAus = ((Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -ErrorAction Stop).TurnOffWindowsCopilot -eq 1) } catch { }
    try { $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -ErrorAction Stop).AllowRecallEnablement; if ($null -ne $v) { $r.RecallRichtlinie = [int]$v } } catch { }
    foreach ($h in 'HKLM', 'HKCU') { try { if ((Get-ItemProperty "${h}:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction Stop).DisableAIDataAnalysis -eq 1) { $r.DatenanalyseAus = $true } } catch { } }
    if ($Script:IsAdmin) { try { $f = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction Stop; $r.RecallAktiv = ([string]$f.State -eq 'Enabled') } catch { } }
    return $r
}

# --- Data sources of the checks added in 1.9 (each one replaceable in the tests) ---
# Defender exclusions (paths, file extensions, processes). Needs admin rights; $null if they cannot be read.
function Get-DefenderExclusions {
    try {
        $p = Get-MpPreference -ErrorAction Stop
        $f = { param($v) @(@($v) | Where-Object { $_ -and [string]$_ -notmatch '(?i)^N/A' } | ForEach-Object { [string]$_ }) }
        return [pscustomobject]@{ Pfade = (& $f $p.ExclusionPath); Endungen = (& $f $p.ExclusionExtension); Prozesse = (& $f $p.ExclusionProcess) }
    } catch { return $null }
}
# Exclusions that switch off the virus scan for large parts of the PC (a single program folder is normal)
function Get-BroadDefenderExclusions($Ex) {
    if (-not $Ex) { return @() }
    $breit = @($env:SystemDrive, $env:windir, "$env:windir\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $(if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\') -replace '\\[^\\]+$', '' }), $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, $(if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\') + '\Downloads' }), $(if ($env:USERPROFILE) { $env:USERPROFILE.TrimEnd('\') + '\Desktop' })) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\').ToLower() }
    $res = @()
    foreach ($p in @($Ex.Pfade)) {
        $n = ([Environment]::ExpandEnvironmentVariables([string]$p)).Trim().TrimEnd('\').TrimEnd('*').TrimEnd('\').ToLower()
        if ($n -eq '' -or $n -match '^[a-z]:$' -or $breit -contains $n) { $res += [pscustomobject]@{ Art = 'Pfad'; Wert = [string]$p } }
    }
    $endungen = 'exe', 'dll', 'ps1', 'bat', 'cmd', 'vbs', 'js', 'jse', 'wsf', 'hta', 'scr', 'msi', 'com', 'lnk', 'jar', 'zip', 'iso'
    foreach ($e in @($Ex.Endungen)) { if ($endungen -contains ([string]$e).Trim().TrimStart('*').TrimStart('.').ToLower()) { $res += [pscustomobject]@{ Art = 'Endung'; Wert = [string]$e } } }
    $prozesse = 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'explorer.exe', 'svchost.exe', 'msiexec.exe'
    foreach ($q in @($Ex.Prozesse)) { if ($prozesse -contains ([IO.Path]::GetFileName([string]$q)).ToLower()) { $res += [pscustomobject]@{ Art = 'Prozess'; Wert = [string]$q } } }
    return $res
}
# BitLocker of the system drive paused: for how many more restarts? 0 = until someone resumes it, >0 = resumes by
# itself (Windows pauses it for one restart e.g. for BIOS updates), $null = unknown
function Get-BitLockerSuspendCount {
    try {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop | Select-Object -First 1
        if (-not $v) { return $null }
        $n = (Invoke-CimMethod -InputObject $v -MethodName GetSuspendCount -ErrorAction Stop).SuspendCount
        if ($null -eq $n) { return $null }
        return [int]$n
    } catch { return $null }
}
# Lines of the hosts file that block Windows Update or Defender (typical for "anti-telemetry" tools)
function Get-HostsUpdateBlocks {
    $f = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $z = @(); try { $z = @(Get-Content -LiteralPath $f -ErrorAction Stop) } catch { return @() }
    return @(Select-HostsUpdateBlocks $z)
}
function Select-HostsUpdateBlocks([string[]]$Lines) {
    $z = @($Lines)
    $muster = '(?i)(^|[\s\.])(windowsupdate\.com|windowsupdate\.microsoft\.com|update\.microsoft\.com|delivery\.mp\.microsoft\.com|definitionupdates\.microsoft\.com|wdcp\.microsoft\.com|wdcpalt\.microsoft\.com)(\s|$)'
    return @($z | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ -match '^(0\.0\.0\.0|127\.0\.0\.1|::1?|0)\s+' -and $_ -match $muster })
}
# Feature updates held at a version by policy (TargetReleaseVersion); $null if not set
function Get-UpdatePolicyPin {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    if ($p -and $p.TargetReleaseVersion -eq 1 -and $p.TargetReleaseVersionInfo) { return [pscustomobject]@{ Version = [string]$p.TargetReleaseVersionInfo; Produkt = [string]$p.ProductVersion } }
    return $null
}
# Folders under C:\Users that belong to no profile of the profile list (leftovers of deleted accounts). $null if the
# profile list cannot be read (fail closed).
function Get-OrphanProfileDirs {
    if (-not $env:USERPROFILE) { return $null }
    $root = Split-Path $env:USERPROFILE
    $bekannt = @(); try { $bekannt = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | ForEach-Object { ([string]$_.LocalPath).TrimEnd('\').ToLower() }) } catch { return $null }
    if (-not $bekannt.Count) { return $null }
    $fest = 'public', 'default', 'default user', 'all users', 'defaultapppool'
    @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-Reparse $_) -and $fest -notcontains $_.Name.ToLower() -and $bekannt -notcontains $_.FullName.TrimEnd('\').ToLower() })
}
function ConvertTo-WtNumber($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if ($s -match '(?i)n/?a\b|not supported|unknown|^$') { return $null }
    $s = $s -replace '[^\d\.,\-]', ''
    if ($s -match '^-?\d{1,3}(\.\d{3})+$') { $s = $s -replace '\.', '' }          # Thousands separators (1.234)
    elseif ($s -match '^-?\d{1,3}(,\d{3})+\.\d+$') { $s = $s -replace ',', '' }   # 1,234.5
    else { $s = $s -replace ',', '.' }                                           # Decimal comma
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

# Resolve winget safely: with admin rights only from the installed App Installer package (not via PATH)
function Get-WingetPath {
    if ($Script:Cache.ContainsKey('Winget')) { return $Script:Cache.Winget }
    $p = $null
    try {
        $pkg = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation -and ([string]$pkg.InstallLocation) -like "$env:ProgramFiles\WindowsApps\*") { $c = Join-Path $pkg.InstallLocation 'winget.exe'; if (Test-Path -LiteralPath $c) { $p = $c } }
    } catch { }
    if (-not $p -and -not $Script:IsAdmin) { $c = Get-Command winget.exe -ErrorAction SilentlyContinue; if ($c) { $p = $c.Source } }
    $Script:Cache.Winget = $p
    return $p
}

# Friendly names for Store apps and device classes
$Script:AppNames = @{
    'Microsoft.BingNews' = 'Microsoft News'; 'Microsoft.BingWeather' = (T 'Weather (Microsoft)'); 'Microsoft.ZuneVideo' = (T 'Movies & TV'); 'Microsoft.Getstarted' = (T 'Tips')
    'Microsoft.MicrosoftSolitaireCollection' = (T 'Solitaire games'); 'Microsoft.MixedReality.Portal' = (T 'Mixed Reality Portal'); 'Microsoft.WindowsFeedbackHub' = (T 'Feedback Hub')
    'Microsoft.M365Companions' = (T 'Microsoft 365 companion apps'); 'Clipchamp.Clipchamp' = (T 'Clipchamp (video editing)'); 'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.Windows.DevHome' = (T 'Dev Home (for developers)')
    'Microsoft.BingSearch' = (T 'Bing Search'); 'Microsoft.PowerAutomateDesktop' = 'Power Automate'; 'Microsoft.People' = (T 'People (legacy)'); 'Microsoft.SkypeApp' = 'Skype'
    'Microsoft.Wallet' = 'Wallet'; 'Microsoft.3DBuilder' = '3D Builder'; 'Microsoft.Print3D' = 'Print 3D'; 'Microsoft.Microsoft3DViewer' = (T '3D Viewer')
}
function Get-AppDisplayName([string]$Id) { if ($Script:AppNames -and $Script:AppNames.ContainsKey($Id)) { return $Script:AppNames[$Id] }; return ($Id -replace '^[^\.]+\.', '') }
$Script:DeviceClassNames = @{
    'System' = (T 'System devices'); 'HDC' = (T 'Drive controllers'); 'SCSIAdapter' = (T 'Storage controllers'); 'Display' = (T 'Graphics cards'); 'Monitor' = (T 'Monitors'); 'MEDIA' = (T 'Audio devices')
    'Net' = (T 'Network adapters'); 'DiskDrive' = (T 'Drives'); 'Volume' = (T 'Volumes'); 'USB' = (T 'USB controllers'); 'USBDevice' = (T 'USB devices'); 'HIDClass' = (T 'Input devices')
    'Keyboard' = (T 'Keyboards'); 'Mouse' = (T 'Mice'); 'WPD' = (T 'Phones and cameras'); 'Image' = (T 'Scanners and cameras'); 'Camera' = (T 'Cameras'); 'Ports' = (T 'Ports (COM)'); 'Processor' = (T 'Processors')
    'SmartCardReader' = (T 'Card readers'); 'Sensor' = (T 'Sensors'); 'Biometric' = (T 'Fingerprint readers')
}
function Get-DeviceClassName([string]$Class) { if ($Script:DeviceClassNames.ContainsKey($Class)) { return $Script:DeviceClassNames[$Class] }; return $Class }

# NVIDIA graphics cards: nvidia-smi is installed with the driver (locale-independent CSV output)
function Find-NvidiaSmi { foreach ($p in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }; return $null }
function Invoke-NvidiaQuery([string]$Exe) {
    $q = 'name,temperature.gpu,fan.speed,power.draw,power.limit,clocks.sm,clocks.max.sm,utilization.gpu,pcie.link.width.current,pcie.link.width.max'
    foreach ($reason in 'clocks_event_reasons.active', 'clocks_throttle_reasons.active') {
        $o = @(& $Exe "--query-gpu=$q,$reason" '--format=csv,noheader,nounits' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $o.Count) { $r = @(ConvertFrom-NvidiaCsv $o); if ($r.Count) { return $r } }
    }
    return @()
}
function Get-NvidiaGpus {
    if ($Script:Cache.ContainsKey('Nvidia')) { return $Script:Cache.Nvidia }
    $res = @()
    $exe = Find-NvidiaSmi
    if ($exe) {
        $res = @(Invoke-NvidiaQuery $exe)
        # Throttle reasons are snapshots: only count what is set in at least 2 of 3 samples
        if ($res | Where-Object { $_.Gruende -band 0xE8 }) {
            $proben = @(, @($res | ForEach-Object { $_.Gruende }))
            for ($i = 0; $i -lt 2; $i++) { Start-Sleep -Milliseconds 1000; $proben += , @(Invoke-NvidiaQuery $exe | ForEach-Object { $_.Gruende }) }
            for ($g = 0; $g -lt $res.Count; $g++) {
                $stabil = [int64]0
                foreach ($bit in 0x4, 0x8, 0x20, 0x40, 0x80) { $n = 0; foreach ($p in $proben) { if ($p.Count -gt $g -and ([int64]$p[$g] -band $bit)) { $n++ } }; if ($n -ge 2) { $stabil = $stabil -bor $bit } }
                $res[$g].GruendeStabil = $stabil
            }
        } else { foreach ($g in $res) { $g.GruendeStabil = $g.Gruende } }
        # Temperature limits of the card (output is always English)
        $t = @(& $exe -q -d TEMPERATURE 2>$null)
        $gi = -1
        foreach ($l in $t) {
            if ($l -match '^GPU [0-9A-Fa-f]{4,}:') { $gi++; continue }
            if ($gi -lt 0 -or $gi -ge $res.Count) { continue }
            if ($l -match 'GPU Slowdown Temp\s*:\s*(\d+)') { $res[$gi].SlowdownC = [int]$Matches[1] }
            elseif ($l -match 'GPU Max Operating Temp\s*:\s*(\d+)') { $res[$gi].MaxOpC = [int]$Matches[1] }
            elseif ($l -match 'GPU Target Temperature\s*:\s*(\d+)') { $res[$gi].ZielC = [int]$Matches[1] }
        }
    }
    $Script:Cache.Nvidia = $res
    return $res
}
function ConvertFrom-NvidiaCsv([string[]]$Lines) {
    foreach ($l in $Lines) {
        $c = @($l -split ',\s*')
        if ($c.Count -lt 8) { continue }
        $neu = ($c.Count -ge 11)
        $mi = if ($neu) { 10 } else { 7 }
        $mask = [int64]0; try { $mask = [Convert]::ToInt64(($c[$mi].Trim() -replace '^0x', ''), 16) } catch { }
        [pscustomobject]@{
            Name = $c[0].Trim(); TempC = (ConvertTo-WtNumber $c[1]); LuefterProzent = (ConvertTo-WtNumber $c[2]); LeistungW = (ConvertTo-WtNumber $c[3]); LimitW = (ConvertTo-WtNumber $c[4])
            TaktMHz = (ConvertTo-WtNumber $c[5]); TaktMaxMHz = (ConvertTo-WtNumber $c[6])
            Auslastung = $(if ($neu) { ConvertTo-WtNumber $c[7] } else { $null }); PcieBreite = $(if ($neu) { ConvertTo-WtNumber $c[8] } else { $null }); PcieBreiteMax = $(if ($neu) { ConvertTo-WtNumber $c[9] } else { $null })
            Gruende = $mask; GruendeStabil = $mask; SlowdownC = $null; MaxOpC = $null; ZielC = $null
        }
    }
}
function Get-NvidiaReasonText([int64]$m) {
    $t = @()
    if ($m -band 0x40) { $t += (T 'Heat (hardware)') }
    if ($m -band 0x20) { $t += (T 'Temperature limit') }
    if ($m -band 0x80) { $t += (T 'Power supply (power brake)') }
    if ($m -band 0x8) { $t += (T 'Hardware signal (often power supply or heat)') }
    if ($m -band 0x4) { $t += (T 'Power limit') }
    return $t
}

# Sensors from hardware monitors (optional): LibreHardwareMonitor / OpenHardwareMonitor (WMI, only while the
# program runs) or HWiNFO (values with "Report value in Gadget", only while HWiNFO runs). Without these programs
# a desktop motherboard usually does not report fan speeds and CPU temperature to Windows at all.
function Get-HwMonitorSensors([switch]$NoCache) {
    if (-not $NoCache -and $Script:Cache.ContainsKey('HwMon')) { return $Script:Cache.HwMon }
    $res = @()
    foreach ($ns in 'root\LibreHardwareMonitor', 'root\OpenHardwareMonitor') {
        try {
            $s = @(Get-CimInstance -Namespace $ns -ClassName Sensor -OperationTimeoutSec 3 -ErrorAction Stop)
            if (-not $s.Count) { continue }
            $hw = @{}
            try { foreach ($h in (Get-CimInstance -Namespace $ns -ClassName Hardware -OperationTimeoutSec 3 -ErrorAction Stop)) { $hw[[string]$h.Identifier] = $h } } catch { }
            $res = @($s | Where-Object { $_.SensorType -in 'Temperature', 'Fan', 'Control' } | ForEach-Object {
                $p = $hw[[string]$_.Parent]
                [pscustomobject]@{ Quelle = ($ns -replace '^root\\', ''); Name = [string]$_.Name; Typ = [string]$_.SensorType; Wert = [double]$_.Value; Geraet = $(if ($p) { [string]$p.Name } else { [string]$_.Parent }); GeraeteTyp = $(if ($p) { [string]$p.HardwareType } else { '' }) }
            })
            if ($res.Count) { break }
        } catch { }
    }
    if (-not $res.Count -and (Get-Process -Name HWiNFO64, HWiNFO32, HWiNFO -ErrorAction SilentlyContinue)) {
        try {
            $k = Get-ItemProperty 'HKCU:\Software\HWiNFO64\VSB' -ErrorAction Stop
            $leer = 0
            for ($i = 0; $i -lt 1000 -and $leer -lt 5; $i++) {
                $lbl = $k."Label$i"
                if (-not $lbl) { $leer++; continue }
                $leer = 0
                $val = [string]$k."Value$i"
                $typ = if ($val -match '(?i)rpm') { 'Fan' } elseif ($val -match '°C') { 'Temperature' } else { $null }
                if (-not $typ) { continue }
                $raw = [string]$k."ValueRaw$i"; if (-not $raw) { $raw = $val }
                $num = ConvertTo-WtNumber $raw
                if ($null -eq $num) { continue }
                $res += [pscustomobject]@{ Quelle = 'HWiNFO'; Name = [string]$lbl; Typ = $typ; Wert = [double]$num; Geraet = [string]$k."Sensor$i"; GeraeteTyp = '' }
            }
        } catch { }
    }
    $Script:Cache.HwMon = $res
    return $res
}
function Get-CpuTempFromSensors($sensors) {
    $t = @($sensors | Where-Object { $_.Typ -eq 'Temperature' -and $_.Wert -gt 5 -and $_.Wert -lt 130 -and $_.Name -notmatch '(?i)distance|tjmax' })
    $cpu = @($t | Where-Object { $_.GeraeteTyp -eq 'Cpu' })
    if (-not $cpu.Count) { $cpu = @($t | Where-Object { $_.Name -match '(?i)\bcpu\b|tctl|tdie|package' -and $_.Name -notmatch '(?i)gpu|vrm|soc|chipset' -and $_.Geraet -notmatch '(?i)gpu|nvidia|radeon' }) }
    # Preferred: Tdie (without offset), then Package/Tctl, then core average/max
    foreach ($muster in '(?i)tdie', '(?i)package|tctl', '(?i)core.*(average|mittel)', '(?i)core.*max') {
        $pref = $cpu | Where-Object { $_.Name -match $muster } | Sort-Object Wert -Descending | Select-Object -First 1
        if ($pref) { return [math]::Round([double]$pref.Wert, 1) }
    }
    $pref = $cpu | Sort-Object Wert -Descending | Select-Object -First 1
    if ($pref) { return [math]::Round([double]$pref.Wert, 1) }
    return $null
}
# CPU temperature for the scan: median of several readings plus load (only meaningful while the PC is idle)
function Get-CpuTempMedian([int]$Count = 5, [int]$DelayMs = 600) {
    $temps = @(); $last = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $t = Get-CpuTempFromSensors (Get-HwMonitorSensors -NoCache)
        if ($null -eq $t) { if ($i -eq 0) { return $null }; continue }
        $temps += $t
        $p = Get-CpuPerfSample; if ($p -and $null -ne $p.Auslastung) { $last += [double]$p.Auslastung }
        if ($i -lt $Count - 1) { Start-Sleep -Milliseconds $DelayMs }
    }
    if (-not $temps.Count) { return $null }
    $s = @($temps | Sort-Object)
    [pscustomobject]@{ TempC = $s[[int][math]::Floor($s.Count / 2)]; Auslastung = $(if ($last.Count) { [math]::Round(($last | Measure-Object -Average).Average, 0) } else { $null }) }
}
# CPU temperature limit according to the configuration (regex on the CPU name)
function Get-CpuTjMax([string]$Name) {
    if (-not $Name) { $Name = (Get-ChassisInfo).CpuName }
    $tab = $Script:Cfg.CpuTjMax
    $pairs = if ($tab -is [System.Collections.IDictionary]) { @($tab.Keys | ForEach-Object { , @($_, $tab[$_]) }) } elseif ($tab) { @($tab.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) }) } else { @() }
    foreach ($p in $pairs) { try { if ($Name -match $p[0]) { return [int]$p[1] } } catch { } }
    return 100
}

function Get-ThermalZones {
    @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -OperationTimeoutSec 3 -ErrorAction SilentlyContinue | ForEach-Object {
        $k = if ($_.HighPrecisionTemperature) { $_.HighPrecisionTemperature / 10.0 } else { [double]$_.Temperature }
        [pscustomobject]@{ Name = ([string]$_.Name -replace '^\\_TZ\.', ''); TempC = [math]::Round($k - 273.15, 1); PassivLimit = [int]$_.PercentPassiveLimit; Gruende = [int]$_.ThrottleReasons }
    } | Where-Object { $_.TempC -gt 5 -and $_.TempC -lt 130 })
}

function Get-CpuPerfSample {
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -OperationTimeoutSec 3 -ErrorAction Stop
        [pscustomobject]@{ Leistung = [double]$p.PercentProcessorPerformance; Limit = [double]$p.PercentPerformanceLimit; MHz = [double]$p.ProcessorFrequency; Auslastung = [double]$p.PercentProcessorUtility }
    } catch { $null }
}

function Get-DiskHealth {
    if ($Script:Cache.ContainsKey('Disks')) { return $Script:Cache.Disks }
    # SMART prediction: InstanceName = PNPDeviceID + '_0'; Win32_DiskDrive.Index = PhysicalDisk.DeviceId
    $pf = @(); try { $pf = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure } | ForEach-Object { [string]$_.InstanceName }) } catch { }
    $dd = @{}; foreach ($x in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) { $dd[[string]$x.Index] = $x }
    $zugeordnet = 0
    $r = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { "$($_.BusType)" -notin 'Spaces', 'Virtual', 'File Backed Virtual' } | ForEach-Object {
        $d = $_; $c = $null
        try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $kind = if ("$($d.BusType)" -eq 'NVMe') { 'NVMe' } elseif ("$($d.MediaType)" -eq 'SSD') { 'SSD' } elseif ("$($d.MediaType)" -eq 'HDD') { 'HDD' } else { '' }
        $w = $dd[[string]$d.DeviceId]
        $smart = $false
        if ($w) {
            if ([string]$w.Status -eq 'Pred Fail') { $smart = $true }
            $pnp = [string]$w.PNPDeviceID
            if ($pnp -and ($pf | Where-Object { $_.StartsWith($pnp, [StringComparison]::OrdinalIgnoreCase) })) { $smart = $true; $zugeordnet++ }
        }
        [pscustomobject]@{
            Name = ([string]$d.FriendlyName).Trim(); Art = $kind; Bus = "$($d.BusType)"; Zustand = "$($d.HealthStatus)"; Betrieb = (@($d.OperationalStatus) -join ',')
            TempC = $(if ($c -and [int]$c.Temperature -gt 0) { [int]$c.Temperature } else { $null })
            Verschleiss = $(if ($c -and $null -ne $c.Wear -and "$($d.BusType)" -eq 'NVMe') { [int]$c.Wear } else { $null })
            Betriebsstunden = $(if ($c -and $c.PowerOnHours) { [int64]$c.PowerOnHours } else { $null })
            Ausfallwarnung = $smart
        }
    })
    $Script:Cache.SmartUnmapped = [math]::Max(0, $pf.Count - $zugeordnet)
    $Script:Cache.Disks = $r
    return $r
}

function Get-BatteryWear {
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        if ($design -gt 0 -and $full -gt 0) { return [math]::Round(100 * (1 - $full / $design), 0) }
    } catch { }
    return $null
}

# Throttling by the firmware (Kernel-Processor-Power 37). Windows writes the event per logical processor -
# so episodes (distinct minutes) are counted, not events.
function Get-ThrottleEventCount([int]$Days = 30, [datetime]$Since = [datetime]::MinValue) {
    $start = if ($Since -gt [datetime]::MinValue) { $Since } else { (Get-Date).AddDays(-$Days) }
    try { return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $start } -MaxEvents 5000 -ErrorAction Stop | ForEach-Object { $_.TimeCreated.ToString('yyyyMMddHHmm') } | Select-Object -Unique).Count } catch { return 0 }
}
function Get-EventCount([hashtable]$Filter) { try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 2000 -ErrorAction Stop).Count } catch { return 0 } }

# Warning signs from the event log (for rule EVT-HEALTH and the snapshot - keeps the score comparable)
function Get-WarningSignals {
    if ($Script:Cache.ContainsKey('Warn')) { return $Script:Cache.Warn }
    $since = (Get-Date).AddDays(-30)
    $checks = @(
        @{ F = @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $since }; T = (T 'Sudden power-off or restart without shutting down') },
        @{ F = @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since }; T = (T 'Blue screen (Windows crashed)') },
        @{ F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $since }; T = (T 'Errors reported by the hardware') },
        @{ F = @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci'; Level = 1, 2; StartTime = $since }; T = (T 'Errors reading or writing a drive') },
        @{ F = @{ LogName = 'System'; ProviderName = 'nvlddmkm', 'amdkmdag', 'igfx'; Level = 1, 2, 3; StartTime = $since }; T = (T 'Graphics driver crashed or was restarted') },
        @{ F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-TPM-WMI', 'TPM'; Level = 1, 2; StartTime = $since }; T = (T 'Security chip (TPM) errors – a BIOS update often helps') },
        @{ F = @{ LogName = 'System'; ProviderName = 'Volsnap'; Level = 1, 2; StartTime = $since }; T = (T 'Restore points were lost') }
    )
    $r = @(foreach ($c in $checks) { $n = Get-EventCount $c.F; if ($n) { [pscustomobject]@{ Text = $c.T; Anzahl = $n } } })
    $Script:Cache.Warn = $r
    return $r
}

# Read a power setting (locale-independent via the registry instead of powercfg text)
function Get-PowerSettingIndex([string]$SubGuid, [string]$SettingGuid) {
    $o = (& powercfg.exe /getactivescheme 2>$null) -join ' '
    if ($o -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $null }
    $scheme = $Matches[1].ToLower()
    $ac = $null; $dc = $null
    foreach ($k in @("HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$SubGuid\$SettingGuid", "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SubGuid\$SettingGuid\DefaultPowerSchemeValues\$scheme")) {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($null -eq $ac -and $null -ne $p.ACSettingIndex) { $ac = [int]$p.ACSettingIndex }
        if ($null -eq $dc -and $null -ne $p.DCSettingIndex) { $dc = [int]$p.DCSettingIndex }
    }
    [pscustomobject]@{ Schema = $scheme; AC = $ac; DC = $dc }
}
$Script:GuidSubProcessor = '54533251-82be-4824-96c1-47b60b740d00'
$Script:GuidSysCoolPol = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
$Script:GuidProcMax = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$Script:GuidProcMin = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$Script:GuidBoostMode = 'be337238-0d82-4146-a960-4f3749d470c7'
$Script:CoolingTestMin = 20   # Tests lower this value

# Hardware state for rule HW-COOLING, snapshot and app: points with level ok|warn|krit|'' (info).
# Rating 'moment' = snapshot (temperature, current throttling) - does not count in the score.
function Get-HardwarePoints {
    if ($Script:Cache.ContainsKey('HwPoints')) { return $Script:Cache.HwPoints }
    $c = $Script:Cfg
    $pts = New-Object System.Collections.Generic.List[object]
    function P([string]$Stufe, [string]$Text, [string]$Bereich, [string]$Wertung = 'dauer') { $pts.Add([pscustomobject]@{ Stufe = $Stufe; Text = $Text; Bereich = $Bereich; Wertung = $Wertung }) }
    $ch = Get-ChassisInfo
    $sens = @(Get-HwMonitorSensors)
    $quelle = if ($sens.Count) { $sens[0].Quelle } else { $null }

    # ---- Processor: temperature (only with a hardware monitor), throttling, thermal zones
    $cpuT = $null
    if ($sens.Count) {
        $m = Get-CpuTempMedian
        if ($m) {
            $cpuT = $m.TempC
            $plus = if ($ch.Laptop) { 5 } else { 0 }
            if ($null -ne $m.Auslastung -and $m.Auslastung -gt 30) { P '' ((T 'Processor: {0:N0} °C (measured while the PC was busy – not rated)') -f $cpuT) 'CPU' 'moment' }
            elseif ($cpuT -ge $c.CpuTempIdleCritC + $plus) { P 'krit' ((T 'Processor: {0:N0} °C although it has hardly anything to do – have the cooler, fans and dust checked') -f $cpuT) 'CPU' 'moment' }
            elseif ($cpuT -ge $c.CpuTempIdleWarnC + $plus) { P 'warn' ((T 'Processor: {0:N0} °C under light load – a bit warm. Check fans and dust filters') -f $cpuT) 'CPU' 'moment' }
            else { P 'ok' ((T 'Processor: {0:N0} °C') -f $cpuT) 'CPU' 'moment' }
        }
    }
    $ep7 = Get-ThrottleEventCount 7; $ep30 = Get-ThrottleEventCount 30
    if (-not $ch.Laptop -and $ep7 -ge 3) { P 'warn' ((T 'The firmware throttled the processor {0} times in the last 7 days. Common causes: cooling, dusty fans or power limits in the BIOS') -f $ep7) 'CPU' 'moment' }
    elseif ($ep30 -gt 0) { P '' ((T 'The firmware briefly throttled the processor {0} times in the last 30 days{1}') -f $ep30, $(if ($ch.Laptop) { (T ' – normal on laptops (e.g. on battery)') } else { (T ' – this is normal occasionally') })) 'CPU' 'moment' }
    else { P 'ok' (T 'Processor: no throttling in the last 30 days') 'CPU' 'moment' }
    foreach ($z in (Get-ThermalZones)) {
        if ($z.PassivLimit -gt 0 -and $z.PassivLimit -lt 100) {
            $grund = if ($z.Gruende -band 1) { (T 'due to heat') } elseif ($z.Gruende -band 2) { (T 'due to a current limit') } else { '' }
            P $(if ($z.PassivLimit -le 80) { 'krit' } else { 'warn' }) ((T 'Windows is currently throttling the processor {0} ({1}: {2} % performance, {3:N0} °C)') -f $grund, $z.Name, $z.PassivLimit, $z.TempC).Replace('  ', ' ') 'CPU' 'moment'
        }
        elseif ($z.TempC -ge 90) { P 'warn' ((T 'Temperature sensor {0}: {1:N0} °C') -f $z.Name, $z.TempC) 'CPU' 'moment' }
    }

    # ---- Fans (only with a hardware monitor)
    $fans = @($sens | Where-Object { $_.Typ -eq 'Fan' -and $_.GeraeteTyp -notmatch '(?i)gpu' -and $_.Name -notmatch '(?i)\bgpu\b' })
    $ctrl = @($sens | Where-Object { $_.Typ -eq 'Control' -and $_.GeraeteTyp -notmatch '(?i)gpu' -and $_.Name -notmatch '(?i)\bgpu\b|pump|aio' })
    if ($fans.Count) {
        $laufend = @($fans | Where-Object { $_.Wert -ge 100 })
        $pumpen = @($fans | Where-Object { $_.Name -match '(?i)pump|aio' })
        $cpuFan = @($fans | Where-Object { $_.Name -match '(?i)\bcpu\b' -and $_.Name -notmatch '(?i)pump|aio|opt' })
        $steht = $cpuFan.Count -and -not ($cpuFan | Where-Object { $_.Wert -ge 100 })
        if ($steht -and $null -ne $cpuT -and $cpuT -ge 60) { P 'krit' ((T 'CPU fan reports 0 RPM although the processor is at {0:N0} °C – not connected or defective. Check in the BIOS') -f $cpuT) 'Lüfter' }
        elseif ($steht) { P '' (T 'CPU fan is currently stopped – with a cool processor this is often intended (fan stop at idle)') 'Lüfter' }
        elseif (-not $laufend.Count -and $null -ne $cpuT -and $cpuT -ge 60) { P 'krit' (T 'No fan reports a speed although the processor is warm – check the fan connectors') 'Lüfter' }
        if ($pumpen.Count -and -not ($pumpen | Where-Object { $_.Wert -ge 100 })) { P 'warn' (T 'The water cooling pump reports 0 RPM – either its speed cable is not connected or the pump has stopped. Check in the BIOS or in the cooling software') 'Lüfter' }
        if ($laufend.Count) { P 'ok' ((T 'Fans: ') + (($laufend | Sort-Object Wert -Descending | Select-Object -First 6 | ForEach-Object { (T '{0} {1:N0} RPM') -f $_.Name, $_.Wert }) -join ', ')) 'Lüfter' }
        # Full speed with a cool processor: only control values whose fan is really spinning (same number #n)
        $voll = @($ctrl | Where-Object {
            $cv = $_; if ($cv.Wert -lt 95) { return $false }
            if ($cv.Name -match '#(\d+)') { $nr = $Matches[1]; return [bool]($fans | Where-Object { $_.Name -match "#$nr\b" -and $_.Wert -ge 100 }) }
            return [bool]$laufend.Count
        })
        if ($voll.Count -and $null -ne $cpuT -and $cpuT -lt 55) { P 'warn' ((T 'Fans run at full speed although the processor is cool ({0}) – the fan curve in the BIOS is probably too aggressive (unnecessarily loud). Note: the program often only names the connectors ''Fan #1'' – in the BIOS they are called e.g. CPU_FAN or CHA_FAN') -f (($voll | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')) 'Lüfter' }
        P '' ((T 'Sensor data from {0}') -f $quelle) 'Lüfter'
    } else {
        P '' (T 'Fan speeds: this motherboard does not report them directly to Windows. If the free program LibreHardwareMonitor (version 0.9.5 or later) is running, WinTidy reads fans and processor temperature automatically. The cooling test works anyway.') 'Lüfter'
    }
    foreach ($p in (Get-FanToolPoints)) { $pts.Add($p) }

    # ---- Graphics card (NVIDIA). fan.speed is the target speed, not a measurement.
    foreach ($g in (Get-NvidiaGpus)) {
        $txt = '{0}: {1}' -f $g.Name, $(if ($null -ne $g.TempC) { '{0:N0} °C' -f $g.TempC } else { (T 'temperature unknown') })
        if ($null -ne $g.LuefterProzent) { $txt += (T ', fans {0:N0} %') -f $g.LuefterProzent }
        $m = [int64]$g.GruendeStabil
        $leerlauf = ($null -ne $g.Auslastung -and $g.Auslastung -lt 10)
        $slow = if ($g.SlowdownC) { $g.SlowdownC } else { $c.GpuTempCritC }
        $grenzeLast = if ($g.MaxOpC) { $g.MaxOpC - 5 } elseif ($g.ZielC) { $g.ZielC + 3 } else { $c.GpuTempWarnC }
        if (($m -band 0x40) -or ($null -ne $g.TempC -and $g.TempC -ge $slow)) { P 'krit' ($txt + (T ' – throttled due to heat. Check case fans and dust')) 'Grafikkarte' 'moment' }
        elseif ($null -ne $g.TempC -and $null -ne $g.LuefterProzent -and $g.LuefterProzent -eq 0 -and $g.TempC -ge 70) { P 'warn' ($txt + (T ' – the fans do not start despite the high temperature. Check the fan curve or the graphics card software')) 'Grafikkarte' 'moment' }
        elseif ($leerlauf -and $null -ne $g.TempC -and $g.TempC -ge 70) { P 'warn' ($txt + (T ' – unusually warm at idle. Check the airflow in the case')) 'Grafikkarte' 'moment' }
        elseif (-not $leerlauf -and $null -ne $g.TempC -and $g.TempC -ge $grenzeLast) { P 'warn' ($txt + (T ' – running at the temperature limit')) 'Grafikkarte' 'moment' }
        elseif ($m -band 0x88) { P 'warn' ($txt + (T ' – throttled: ') + ((Get-NvidiaReasonText ($m -band 0x88)) -join ', ')) 'Grafikkarte' 'moment' }
        elseif ($m -band 0x20) { P '' ($txt + (T ' – lowers its clock to stay within its temperature limit (normal under load)')) 'Grafikkarte' 'moment' }
        elseif ($null -ne $g.LuefterProzent -and $g.LuefterProzent -eq 0) { P 'ok' ($txt + (T ' (fans stop at low load – this is intended and quiet)')) 'Grafikkarte' 'moment' }
        else { P 'ok' $txt 'Grafikkarte' 'moment' }
        if ($g.PcieBreite -and $g.PcieBreiteMax -and $g.PcieBreite -lt $g.PcieBreiteMax) {
            if ($g.PcieBreite -le 4) { P 'warn' ((T '{0} is only connected with x{1} instead of x{2} – is it in the right slot (usually the top long one)?') -f $g.Name, $g.PcieBreite, $g.PcieBreiteMax) 'Grafikkarte' }
            else { P '' ((T '{0} is connected with x{1} instead of x{2} – normal on some motherboards when other slots or M.2 slots are in use') -f $g.Name, $g.PcieBreite, $g.PcieBreiteMax) 'Grafikkarte' }
        }
    }

    # ---- Drives
    foreach ($d in (Get-DiskHealth)) {
        if ($d.Zustand -in 'Unhealthy', '2' -or $d.Betrieb -match 'Predictive Failure' -or $d.Ausfallwarnung) { P 'krit' ((T 'Drive {0}: reports an imminent failure – back up important data now and have the drive replaced') -f $d.Name) 'Laufwerke'; continue }
        if ($d.Zustand -in 'Warning', '1') { P 'warn' ((T 'Drive {0}: reports irregularities – back up data and have the drive checked') -f $d.Name) 'Laufwerke' }
        if ($null -ne $d.Verschleiss -and $d.Verschleiss -ge 100) { P 'krit' ((T 'SSD {0}: rated lifetime used up according to the manufacturer ({1} %) – back up data, replace the SSD') -f $d.Name, $d.Verschleiss) 'Laufwerke' }
        elseif ($null -ne $d.Verschleiss -and $d.Verschleiss -ge 80) { P 'warn' ((T 'SSD {0}: {1} % of its rated lifetime used') -f $d.Name, $d.Verschleiss) 'Laufwerke' }
        if ($null -ne $d.TempC) {
            $art = if ($d.Art) { $d.Art } else { 'HDD' }
            $w = $c.DiskTempWarnC.$art; $k = $c.DiskTempCritC.$art
            if ($k -and $d.TempC -ge $k) { P 'krit' ((T 'Drive {0}: {1} °C – much too hot. Improve the airflow in the case (NVMe: heatsink)') -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
            elseif ($w -and $d.TempC -ge $w) { P 'warn' ((T 'Drive {0}: {1} °C – warm. Check the airflow in the case') -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
            else { P 'ok' ((T 'Drive {0}: {1} °C') -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
        }
    }
    if ($Script:Cache.SmartUnmapped -gt 0) { P 'krit' (T 'A drive warns of failure via its self-diagnosis (SMART) – back up important data now') 'Laufwerke' }

    # ---- Memory and processor errors (events)
    $since90 = (Get-Date).AddDays(-90); $since30 = (Get-Date).AddDays(-30)
    if ((Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; Id = 1202; StartTime = $since90 }) -gt 0) { P 'krit' (T 'Windows Memory Diagnostic found errors in the RAM – have the RAM checked (modules, XMP/EXPO setting)') 'Speicher' }
    $w19 = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 19; StartTime = $since30 }
    if ($w19 -ge 5) { P 'warn' ((T 'The processor reported {0} corrected errors – common with overclocking (PBO, Curve Optimizer, XMP/EXPO). Check BIOS settings for defaults') -f $w19) 'CPU' }
    $w17 = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = $since30 }
    if ($w17 -ge 5) { P 'warn' ((T 'A connection (PCIe) reported {0} corrected errors – check the seating of graphics card/SSD, riser cables or the PCIe setting in the BIOS') -f $w17) 'CPU' }

    # ---- Battery
    if ($ch.HatAkku) {
        $wear = Get-BatteryWear
        if ($null -ne $wear) {
            if ($wear -ge 50) { P 'krit' ((T 'Battery: has lost {0} % of its original capacity – a replacement is worthwhile') -f $wear) 'Akku' }
            elseif ($wear -ge 30) { P 'warn' ((T 'Battery: has lost {0} % of its original capacity') -f $wear) 'Akku' }
            else { P 'ok' ((T 'Battery: {0} % capacity loss (normal)') -f [math]::Max(0, $wear)) 'Akku' }
        }
    }
    $Script:Cache.HwPoints = $pts.ToArray()
    return $Script:Cache.HwPoints
}

# Several fan/tuning programs at the same time fight over control (fluctuating fans, wrong readings)
function Get-FanToolPoints {
    $gruppen = [ordered]@{
        (T 'motherboard fans') = @{ 'ArmouryCrate' = 'Armoury Crate'; 'AsusFanControlService' = 'ASUS Fan Xpert'; 'MSI.CentralServer' = 'MSI Center'; 'GCC' = 'Gigabyte Control Center'; 'EasyTune' = 'Gigabyte EasyTune'; 'FanControl' = 'Fan Control'; 'ArgusMonitor' = 'Argus Monitor'; 'SpeedFan' = 'SpeedFan'; 'NZXT CAM' = 'NZXT CAM'; 'iCUE' = 'Corsair iCUE'; 'L-Connect' = 'Lian Li L-Connect'; 'G-Helper' = 'G-Helper'; 'LegionToolkit' = 'Legion Toolkit' }
        (T 'graphics card fans') = @{ 'MSIAfterburner' = 'MSI Afterburner'; 'GPUTweakII' = 'ASUS GPU Tweak'; 'GPUTweakIII' = 'ASUS GPU Tweak'; 'PrecisionX_x64' = 'EVGA Precision X1'; 'PrecisionX' = 'EVGA Precision X1' }
    }
    $proc = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $res = @()
    foreach ($g in $gruppen.Keys) {
        $tab = $gruppen[$g]
        $treffer = @($tab.Keys | Where-Object { $n = $_; $proc | Where-Object { $_ -like "$n*" } } | ForEach-Object { $tab[$_] } | Select-Object -Unique)
        if ($treffer.Count -ge 2) { $res += [pscustomobject]@{ Stufe = 'warn'; Text = ((T 'Several programs control the {0} at the same time: {1} – this can cause fluctuating or wrong fan speeds. Best use only one of them') -f $g, ($treffer -join ', ')); Bereich = 'Lüfter'; Wertung = 'dauer' } }
    }
    $tuning = @(@{ 'ThrottleStop' = 'ThrottleStop'; 'XtuService' = 'Intel XTU'; 'AMDRyzenMasterDriver' = 'Ryzen Master'; 'RyzenMaster' = 'Ryzen Master' }.GetEnumerator() | Where-Object { $n = $_.Key; $proc | Where-Object { $_ -like "$n*" } } | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($tuning.Count) { $res += [pscustomobject]@{ Stufe = ''; Text = ((T 'Tuning program active ({0}) – voltages/clocks are changed manually; this affects temperatures and the cooling test') -f ($tuning -join ', ')); Bereich = 'CPU'; Wertung = 'dauer' } }
    return $res
}

# Compact hardware readings for the snapshot (before/after and history)
function Get-HardwareSnapshot {
    $sens = @(Get-HwMonitorSensors)
    $g = @(Get-NvidiaGpus) | Select-Object -First 1
    $ch = Get-ChassisInfo
    $pts = @(Get-HardwarePoints)
    [ordered]@{
        Laptop = [bool]$ch.Laptop
        Sensorquelle = $(if ($sens.Count) { $sens[0].Quelle } else { $null })
        CpuTempC = (Get-CpuTempFromSensors $sens)
        Luefter = @($sens | Where-Object { $_.Typ -eq 'Fan' } | ForEach-Object { [ordered]@{ Name = $_.Name; Upm = [int]$_.Wert } })
        Gpu = $(if ($g) { [ordered]@{ Name = $g.Name; TempC = $g.TempC; LuefterProzent = $g.LuefterProzent; Gruende = $g.GruendeStabil; Auslastung = $g.Auslastung } } else { $null })
        Laufwerke = @(Get-DiskHealth | ForEach-Object { [ordered]@{ Name = $_.Name; Art = $_.Art; TempC = $_.TempC; Verschleiss = $_.Verschleiss; Zustand = $_.Zustand } })
        Drosselung30T = (Get-ThrottleEventCount 30)
        Thermalzonen = @(Get-ThermalZones)
        AkkuVerschleiss = $(if ($ch.HatAkku) { Get-BatteryWear } else { $null })
        Punkte = @($pts | Where-Object { $_.Stufe -in 'warn', 'krit' } | ForEach-Object { [ordered]@{ Stufe = $_.Stufe; Text = $_.Text; Wertung = $_.Wertung } })
    }
}

function Show-HwPoints($Punkte) {
    foreach ($p in @($Punkte)) {
        $tag = switch ($p.Stufe) { 'ok' { 'OK' } 'warn' { '! ' } 'krit' { '!!' } default { '  ' } }
        $col = switch ($p.Stufe) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'krit' { 'Red' } default { 'Gray' } }
        W ("  [{0}] {1}" -f $tag, $p.Text) $col
    }
}

# Cooling test: loads the processor cores for a short time and watches performance, throttling and - if a
# hardware monitor is running - temperature and fan speed. Changes nothing on the system.
# Status: OK | ABGEBROCHEN (cancelled by the user, not saved) | GESTOPPT (safety stop) | AKKU | GESPERRT
function Invoke-CoolingTest([int]$Seconds = 60, [scriptblock]$OnProgress = $null, $Control = $null) {
    $Seconds = [math]::Max($Script:CoolingTestMin, [math]::Min(600, $Seconds))
    $Script:Cache = @{}
    $ch = Get-ChassisInfo
    if ($ch.Akku) { return [pscustomobject]@{ Status = 'AKKU'; Meldung = (T 'The cooling test only works with the power adapter connected. Please connect the power adapter and try again.'); Punkte = @() } }
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    if ($ch.VM -or ($ctx -and $ctx.Server)) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = (T 'On servers and in virtual machines the cooling test makes no sense and is therefore blocked.'); Punkte = @() } }
    if (-not ('WtBurn2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class WtBurn2 {
    static volatile bool stop;
    static long deadline;
    static readonly Stopwatch sw = Stopwatch.StartNew();
    [StructLayout(LayoutKind.Sequential)]
    struct PPTS { public uint Version; public uint ControlMask; public uint StateMask; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref PPTS info, uint size);
    // Windows 11 throttles low-priority processes via EcoQoS - explicitly turn that off for the measurement
    static void SetEco(bool aus) {
        try {
            PPTS s = new PPTS(); s.Version = 1; s.ControlMask = aus ? 1u : 0u; s.StateMask = 0;
            SetProcessInformation(Process.GetCurrentProcess().Handle, 4, ref s, (uint)Marshal.SizeOf(typeof(PPTS)));
        } catch { }
    }
    public static void Start(int threads, int maxSeconds) {
        stop = false;
        Interlocked.Exchange(ref deadline, sw.ElapsedTicks + (long)maxSeconds * Stopwatch.Frequency);
        SetEco(true);
        for (int i = 0; i < threads; i++) { Thread t = new Thread(Work); t.IsBackground = true; t.Priority = ThreadPriority.Normal; t.Start(); }
    }
    public static void Stop() { stop = true; SetEco(false); }
    static void Work() {
        double a = 1.0001, b = 1.0002, c = 1.0003, d = 1.0004;
        // Watchdog: ends at the deadline at the latest, even if PowerShell hangs
        while (!stop && sw.ElapsedTicks < Interlocked.Read(ref deadline)) {
            for (int i = 1; i < 1000000; i++) { a = Math.Sqrt(a * 1.0001 + i); b = Math.Sin(b) + b * 0.5; c = c * 1.000001 + Math.Cos(i); d = Math.Sqrt(d + c); }
            if (a > 1e300 || b > 1e300 || c > 1e300 || d > 1e300) { a = b = c = d = 1.0; }
        }
    }
}
'@
    }
    $c = $Script:Cfg
    $tj = Get-CpuTjMax $ch.CpuName
    function Sample([string]$Phase, [double]$Sek) {
        $p = Get-CpuPerfSample
        $s = @(Get-HwMonitorSensors -NoCache)
        $tz = @(Get-ThermalZones)
        $fl = @{}; foreach ($f in @($s | Where-Object { $_.Typ -eq 'Fan' -and $_.Name -notmatch '(?i)gpu|pump|aio' -and $_.GeraeteTyp -notmatch '(?i)gpu' })) { $fl[$f.Name] = [double]$f.Wert }
        [pscustomobject]@{
            Phase = $Phase; Sek = [math]::Round($Sek, 1)
            Leistung = $(if ($p) { $p.Leistung } else { $null }); Limit = $(if ($p) { $p.Limit } else { $null }); Auslastung = $(if ($p) { $p.Auslastung } else { $null })
            CpuTempC = (Get-CpuTempFromSensors $s)
            Luefter = $fl
            ZoneMaxC = $(if ($tz.Count) { ($tz | Measure-Object TempC -Maximum).Maximum } else { $null })
            ZonePassiv = $(if ($tz.Count) { ($tz | Where-Object { $_.PassivLimit -gt 0 } | Measure-Object PassivLimit -Minimum).Minimum } else { $null })
        }
    }
    $verlauf = New-Object System.Collections.Generic.List[object]
    $start = Get-Date
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 3; $i++) { $verlauf.Add((Sample 'Ruhe' $sw.Elapsed.TotalSeconds)); Start-Sleep -Milliseconds 1500 }
    $threads = [Environment]::ProcessorCount; if ($threads -gt 4) { $threads-- }   # leave one core free for Windows and the measurement
    $abbruch = $false; $grund = $null
    $t0 = $sw.Elapsed.TotalSeconds
    [WtBurn2]::Start($threads, $Seconds + 15)
    try {
        while (($sw.Elapsed.TotalSeconds - $t0) -lt $Seconds) {
            if ($Control -and $Control.Cancel) { $abbruch = $true; break }
            Start-Sleep -Milliseconds 2000
            $el = $sw.Elapsed.TotalSeconds - $t0
            $s = Sample 'Last' $el
            $verlauf.Add($s)
            # Safety stop
            if ($null -ne $s.CpuTempC -and $s.CpuTempC -ge $tj + 3) { $grund = ((T 'Processor above {0} °C') -f [int]$s.CpuTempC); break }
            if ($s.ZonePassiv -and $s.ZonePassiv -lt 80) { $grund = (T 'Windows is heavily throttling the processor due to heat'); break }
            if ($ch.HatAkku -and @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -OperationTimeoutSec 3 -ErrorAction SilentlyContinue | Where-Object { $_.PowerOnline -eq $false }).Count) { $grund = (T 'Power adapter was disconnected'); break }
            if ($OnProgress) { try { & $OnProgress ([int]$el) $Seconds ((T 'Cooling test running – {0} seconds left. The fans will get audibly louder.') -f [int]([math]::Max(0, $Seconds - $el))) 'HW-COOLTEST' } catch { } }
        }
    } finally { [WtBurn2]::Stop() }
    if ($OnProgress) { try { & $OnProgress $Seconds $Seconds (T 'Almost done – the processor is cooling down …') 'HW-COOLTEST' } catch { } }
    for ($i = 0; $i -lt 3; $i++) { Start-Sleep -Milliseconds 2000; $verlauf.Add((Sample 'Danach' $sw.Elapsed.TotalSeconds)) }
    $pts = New-Object System.Collections.Generic.List[object]
    function P([string]$Stufe, [string]$Text) { $pts.Add([pscustomobject]@{ Stufe = $Stufe; Text = $Text }) }
    $ruhe = @($verlauf | Where-Object Phase -eq 'Ruhe'); $last = @($verlauf | Where-Object Phase -eq 'Last')
    $status = if ($abbruch) { 'ABGEBROCHEN' } elseif ($grund) { 'GESTOPPT' } else { 'OK' }
    if ($abbruch) { P '' (T 'The test was cancelled – the result is incomplete.') }
    if ($grund) { P 'krit' ((T 'The test was stopped early for safety reasons: {0}. The cooling should be checked.') -f $grund) }
    $mitLeistung = @($last | Where-Object { $_.Leistung -gt 0 })
    $mitT = @($verlauf | Where-Object { $null -ne $_.CpuTempC })
    $tmax = $null; $t0c = $null
    if ($mitT.Count -ge 4) {
        $t0c = ($ruhe | Where-Object { $null -ne $_.CpuTempC } | Measure-Object CpuTempC -Average).Average
        $tmax = ($last | Where-Object { $null -ne $_.CpuTempC } | Measure-Object CpuTempC -Maximum).Maximum
    }
    $heiss = ($null -ne $tmax -and $tmax -ge $tj - 1)
    $neu37 = Get-ThrottleEventCount -Since $start
    $zp = ($last | Where-Object { $null -ne $_.ZonePassiv -and $_.ZonePassiv -gt 0 } | Measure-Object ZonePassiv -Minimum).Minimum
    $signal = ($neu37 -gt 0 -or ($zp -and $zp -lt 100))
    $limitProben = @($last | Where-Object { $_.Limit -gt 0 -and $_.Limit -lt 95 }).Count
    if (-not $abbruch) {
        # 1) Performance under sustained load. A drop after the turbo phase is often intended (power/time limit of the manufacturer);
        #    it only counts as a cooling problem together with reaching the temperature limit or throttling signals.
        if ($mitLeistung.Count -ge 6) {
            $n = $mitLeistung.Count; $q = [math]::Max(2, [int][math]::Floor($n / 4))
            $anfang = ($mitLeistung | Select-Object -First $q | Measure-Object Leistung -Average).Average
            $ende = ($mitLeistung | Select-Object -Last $q | Measure-Object Leistung -Average).Average
            $drop = if ($anfang -gt 0) { [math]::Round(100 * ($anfang - $ende) / $anfang, 0) } else { 0 }
            if ($drop -ge 15 -and ($heiss -or $signal)) {
                $st = if ($drop -ge 30) { 'krit' } else { 'warn' }
                P $st ((T 'The processor gets {0} % slower under sustained load and reaches its temperature limit or is throttled – typical of weak cooling, dusty coolers or fans spinning too slowly') -f $drop)
            } elseif ($drop -ge 30 -and $null -eq $tmax) {
                P 'warn' ((T 'The processor gets {0} % slower under sustained load. Without a temperature sensor it is unclear whether this is due to cooling or a power limit – start LibreHardwareMonitor and repeat the test') -f $drop)
            } elseif ($drop -ge 15) {
                P '' ((T 'In the first seconds the processor briefly runs faster than intended for sustained load. After that, performance drops by {0} % – {1}') -f $drop, $(if ($null -ne $tmax) { (T 'the temperature stays below the limit, so this is a power limit of the manufacturer and not a cooling problem.') } else { (T 'many processors are designed this way by the manufacturer.') }))
            } else { P 'ok' ((T 'The processor keeps its performance under sustained load (still {0:N0} % of the initial performance at the end)') -f $(if ($anfang -gt 0) { 100 * $ende / $anfang } else { 100 })) }
            if ($limitProben -ge 3) { P $(if ($heiss) { 'warn' } else { '' }) ((T 'The firmware temporarily limited performance during the test (power or temperature limit)')) }
        } else { P '' (T 'The processor performance could not be measured on this PC.') }
        if ($neu37 -gt 0) { P 'warn' ((T 'During the test Windows reported throttling by the firmware {0} times') -f $neu37) }
        if ($zp -and $zp -lt 100) { P $(if ($zp -le 80) { 'krit' } else { 'warn' }) ((T 'Windows throttled the processor during the test (down to {0} %)') -f $zp) }
        # 2) Temperature and fan response (only with a hardware monitor)
        if ($null -ne $tmax) {
            if ($heiss) { P '' ((T 'Under load the processor reaches {0:N0} °C and thus its temperature limit ({1} °C). Many current processors deliberately regulate at this limit – what matters is whether performance drops (see above).') -f $tmax, $tj) }
            else { P 'ok' ((T 'Processor temperature under load: at most {0:N0} °C (limit {1} °C)') -f $tmax, $tj) }
            $namen = @($ruhe + $last | ForEach-Object { @($_.Luefter.Keys) } | Select-Object -Unique)
            $reakt = @(); $kand = 0
            foreach ($fn in $namen) {
                $f0 = ($ruhe | ForEach-Object { $_.Luefter[$fn] } | Where-Object { $_ -gt 0 } | Measure-Object -Average).Average
                $fm = ($last | ForEach-Object { $_.Luefter[$fn] } | Where-Object { $_ -gt 0 } | Measure-Object -Maximum).Maximum
                if ($f0 -gt 0 -and $fm -gt 0) { $kand++; $reakt += [pscustomobject]@{ Name = $fn; Plus = [math]::Round(100 * ($fm - $f0) / $f0, 0) } }
            }
            if ($kand -and $null -ne $t0c) {
                $best = $reakt | Sort-Object Plus -Descending | Select-Object -First 1
                if ($best.Plus -ge 15) { P 'ok' ((T 'The fans respond to heat ({0}: +{1} % speed under load)') -f $best.Name, $best.Plus) }
                elseif ($best.Plus -lt 5 -and ($tmax - $t0c) -ge 20 -and $tmax -ge 85) { P 'warn' ((T 'The fans hardly speed up (at most +{0} %), although the processor got {1:N0} °C warmer – probably a fixed speed. Check the fan curve in the BIOS (with water cooling the fans often react sluggishly on purpose)') -f $best.Plus, ($tmax - $t0c)) }
                else { P '' ((T 'The fans speed up a little (at most +{0} %)') -f $best.Plus) }
            }
        } else { P '' (T 'Without a temperature sensor (e.g. LibreHardwareMonitor) WinTidy only rates whether the processor is throttled under load.') }
        P '' (T 'Note: a one-minute test reveals gross faults (cooler not seated, fan stopped, no thermal paste). It does not show how the PC behaves under hours of load.')
    }
    $res = [pscustomobject]@{ Status = $status; Grund = $grund; Zeit = $start.ToString('o'); Sekunden = [int](($last | Measure-Object Sek -Maximum).Maximum); Kerne = $threads; TjMax = $tj; Sensorquelle = $(if ($null -ne $tmax) { (@(Get-HwMonitorSensors) | Select-Object -First 1).Quelle } else { $null }); Punkte = $pts.ToArray(); Verlauf = $verlauf.ToArray() }
    if (-not $abbruch) {
        try {
            $dir = Join-Path $Script:DataDir 'kuehltest'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $res | ConvertTo-Json -Depth 5 | Out-File (Join-Path $dir ("{0}.json" -f $start.ToString('yyyyMMdd-HHmmss'))) -Encoding utf8
        } catch { }
    }
    Show-HwPoints $res.Punkte
    return $res
}
function Get-LastCoolingTest {
    foreach ($f in @(Get-ChildItem (Join-Path $Script:DataDir 'kuehltest') -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        try { $t = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; if ($t.Status -in 'OK', 'GESTOPPT') { return $t } } catch { }
    }
    return $null
}

# Shared helper for Disk Cleanup (cleanmgr /sagerun) with selected categories
# Are there memory dumps of blue screens (MEMORY.DMP, Minidump) younger than $Days days? Then they are kept,
# because EVT-HEALTH reports the blue screens and the dumps are needed to find the cause.
function Test-RecentSystemDumps([int]$Days) {
    $limit = (Get-Date).AddDays(-$Days)
    $f = @()
    $mem = Get-Item -LiteralPath "$env:windir\MEMORY.DMP" -Force -ErrorAction SilentlyContinue; if ($mem) { $f += $mem }
    $f += @(Get-ChildItem -LiteralPath "$env:windir\Minidump" -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue)
    return [bool]($f | Where-Object { $_.LastWriteTime -gt $limit })
}
function Invoke-CleanMgr([string[]]$Categories) {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    # Remove leftovers of a cancelled run, otherwise cleanmgr unintentionally cleans further categories (e.g. Windows.old)
    foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) { Remove-ItemProperty -LiteralPath $k.PSPath -Name StateFlags4711 -ErrorAction SilentlyContinue }
    $set = @(); foreach ($c in $Categories) { if (Test-Path "$root\$c") { Set-ItemProperty "$root\$c" -Name StateFlags4711 -Value 2 -Type DWord; $set += $c } }
    if (-not $set.Count) { throw (T 'No matching cleanup categories found') }
    try {
        $p = Start-Process "$env:windir\System32\cleanmgr.exe" -ArgumentList '/sagerun:4711' -PassThru -WindowStyle Minimized
        if (-not $p.WaitForExit(3600000)) { throw (T 'Timeout (60 min.)') }
    } finally { foreach ($c in $set) { Remove-ItemProperty "$root\$c" -Name StateFlags4711 -ErrorAction SilentlyContinue } }
    return $set.Count
}

# =============================================================================
#  Rules
#  Each rule: Id, Kategorie, Titel, Warum, Risiko (Niedrig|Mittel|Hoch|Info), Wirkung,
#              Admin (bool), Standard (bool), Detect {-> items}, Fix {param($item) -> message}
#              optional: Dauer (text), Endgueltig, Einzeln, Umkehrbar (bool) - for the app
#  Item.Data.Stufe (ok|warn|krit) controls the icon of info rules in the app
#  Item: [pscustomobject]@{ Label; Bytes; Data }
# =============================================================================
function New-Item2([string]$Label, [double]$Bytes = 0, $Data = $null, [string]$Technik = $null) { [pscustomobject]@{ Label = $Label; Bytes = [int64]$Bytes; Data = $Data; Technik = $Technik } }

$Script:Rules = @(

    # ---------------------------------------------------------------- Storage
    [pscustomobject]@{ Id = 'CLN-TEMP'; Kategorie = 'Speicher'; Titel = (T 'Temporary files'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = (T 'Temp folders grow without limit. Only files that were neither created nor modified for longer than the age limit are deleted (running installers stay untouched). Links are never followed. Additional folders only via ExtraTempPaths in the configuration.')
        Detect = {
            $paths = @($env:TEMP) + @($Script:Cfg.ExtraTempPaths); if ($Script:IsAdmin) { $paths += "$env:windir\Temp" }
            foreach ($p in ($paths | Where-Object { $_ } | Select-Object -Unique)) {
                $f = @(Get-OldFiles $p $Script:Cfg.TempAgeDays)
                if ($f.Count) { New-Item2 ((T 'Temporary files in {0}: {1} files, older than {2} days') -f $p, $f.Count, $Script:Cfg.TempAgeDays) (($f | Measure-Object Length -Sum).Sum) $p }
            }
        }
        Fix = { param($it) $n = 0; foreach ($f in (Get-OldFiles $it.Data $Script:Cfg.TempAgeDays)) { try { if (Test-PathChainNoReparse $it.Data $f.FullName) { $f.Attributes = 'Normal'; $f.Delete(); $n++ } } catch { } }; Remove-EmptyDirs $it.Data $Script:Cfg.TempAgeDays; (T '{0} files deleted' $n) }
    }

    [pscustomobject]@{ Id = 'CLN-WINCLEAN'; Kategorie = 'Speicher'; Titel = (T 'Windows Disk Cleanup (update leftovers, error reports, update cache)'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Dauer = (T '5–15 minutes'); Endgueltig = $true
        Warum = (T 'Uses Windows'' own cleanup (cleanmgr /sagerun) for update leftovers, error reports, memory dumps and the Delivery Optimization cache. Memory dumps of blue screens from the last SystemDumpKeepDays days are kept - they are needed to find the cause. The previous Windows version (Windows.old) is handled by its own rule CLN-WINOLD.')
        Detect = {
            if (-not (Test-Path "$env:windir\System32\cleanmgr.exe")) { return }
            # Recent blue screens: keep all system dumps (cleanmgr can only delete all or none of them)
            $behalten = [bool](Test-RecentSystemDumps ([int]$Script:Cfg.SystemDumpKeepDays))
            $t = @("$env:windir\SoftwareDistribution\Download", "$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache", "$env:ProgramData\Microsoft\Windows\WER", "$env:windir\LiveKernelReports")
            if (-not $behalten) { $t += "$env:windir\MEMORY.DMP", "$env:windir\Minidump" }
            $sum = 0; $found = @()
            foreach ($p in $t) { $s = Get-DirSize $p; if ($s -gt 10MB) { $sum += $s; $found += ('{0} ({1})' -f (Split-Path $p -Leaf), (Fmt-Bytes $s)) } }
            if ($sum -gt 50MB) {
                $lbl = (T 'Leftovers of Windows updates and error reports (') + ($found -join ', ') + ')'
                if ($behalten) { $lbl += (T ' - memory dumps of recent blue screens are kept') }
                New-Item2 $lbl $sum @{ DumpsBehalten = $behalten }
            }
        }
        Fix = { param($it)
            $kat = @('Update Cleanup', 'Windows Error Reporting Files', 'Delivery Optimization Files', 'Windows Upgrade Log Files', 'Setup Log Files', 'Downloaded Program Files')
            # Decide again at the time of the fix: a blue screen may have happened since the scan
            if (-not ($it.Data -and $it.Data.DumpsBehalten) -and -not (Test-RecentSystemDumps ([int]$Script:Cfg.SystemDumpKeepDays))) { $kat += 'System error memory dump files', 'System error minidump files' }
            $n = Invoke-CleanMgr $kat
            # cleanmgr sometimes leaves the Delivery Optimization cache and driver watchdog dumps behind
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { } }
            $lkr = "$env:windir\LiveKernelReports"
            if (Test-Path $lkr) { Get-ChildItem $lkr -Recurse -File -Filter '*.dmp' -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue }
            (T 'Categories: {0}' $n)
        }
    }

    [pscustomobject]@{ Id = 'CLN-WINOLD'; Kategorie = 'Speicher'; Titel = (T 'Remove the previous Windows version (Windows.old) and upgrade leftovers'); Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Endgueltig = $true; Dauer = (T '5–20 minutes')
        Warum = (T 'After a major Windows update, the previous version stays behind as Windows.old (often 10-30 GB). Afterwards going back to the old Windows version is no longer possible. If Windows.old still contains personal files (after a reinstall/reset), WinTidy warns and preselects nothing. The files for "Reset this PC" are kept.')
        Detect = {
            if (-not (Test-Path "$env:windir\System32\cleanmgr.exe")) { return }
            $old = "$env:SystemDrive\Windows.old"; $sum = 0
            foreach ($d in @($old, "$env:SystemDrive\`$WINDOWS.~BT", "$env:SystemDrive\`$Windows.~WS")) { $s = Get-DirSize $d; if ($s -gt 10MB) { $sum += $s } }
            if ($sum -lt 500MB) { return }
            $alter = $null; if (Test-Path -LiteralPath $old) { try { $alter = [int]((Get-Date) - (Get-Item -LiteralPath $old -Force).CreationTime).TotalDays } catch { } }
            # Personal files in Windows.old\Users? (after a reinstall without formatting often the only copy)
            $userBytes = [int64]0
            if (Test-Path -LiteralPath "$old\Users") {
                foreach ($u in @(Get-ChildItem -LiteralPath "$old\Users" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' -and -not (Test-Reparse $_) })) {
                    foreach ($sub in 'Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads', 'OneDrive') { $userBytes += Get-DirSize (Join-Path $u.FullName $sub) }
                }
            }
            $lbl = (T 'Previous Windows version and upgrade leftovers') + $(if ($null -ne $alter) { (T ' (for {0} days)' $alter) } else { '' })
            if ($userBytes -gt 10MB) { $lbl += ((T ' – CAUTION: still contains {0} of personal files (Windows.old\Users). Back them up first!') -f (Fmt-Bytes $userBytes)) }
            $it = New-Item2 $lbl $sum @{ AlterTage = $alter; PersoenlicheBytes = $userBytes; Stufe = $(if ($userBytes -gt 10MB) { 'warn' } else { '' }) }
            $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue ($null -ne $alter -and $alter -ge $Script:Cfg.WinOldMinAgeDays -and $userBytes -le 10MB)
            $it
        }
        Fix = { param($it) $n = Invoke-CleanMgr @('Previous Installations', 'Temporary Setup Files'); (T 'Categories: {0}' $n) }
    }

    [pscustomobject]@{ Id = 'CLN-WINSXS'; Kategorie = 'Speicher'; Titel = (T 'Clean up the Windows component store (WinSxS)'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Dauer = (T '5–30 minutes')
        Warum = (T 'Superseded components from updates stay in WinSxS. DISM removes them when Windows itself recommends a cleanup (without /ResetBase). Superseded components are removed immediately; the current update remains uninstallable. The analysis runs at most every 7 days (always with -Deep).')
        Detect = {
            # The DISM analysis takes minutes and heats up the CPU: only every 7 days (or with -Deep), never with a pending restart
            if (Test-RebootPending) { return }
            $cacheFile = Join-Path $Script:DataDir 'winsxs-analyse.json'
            if (-not $Script:Cache.ContainsKey('WinSxS') -and -not $Deep -and (Test-Path -LiteralPath $cacheFile)) {
                try { $cw = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ([datetime]$cw.Zeit -gt (Get-Date).AddDays(-7)) { $Script:Cache.WinSxS = [pscustomobject]@{ Empfohlen = [bool]$cw.Empfohlen; BackupsBytes = [int64]$cw.BackupsBytes } } } catch { }
            }
            if (-not $Script:Cache.ContainsKey('WinSxS')) {
                $o = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore /English 2>$null
                $rec = ($o | Where-Object { $_ -match 'Cleanup Recommended\s*:\s*(\w+)' } | Select-Object -First 1) -match 'Yes'
                $bk = 0; $l = $o | Where-Object { $_ -match 'Backups and Disabled Features\s*:\s*([\d\.,]+)\s*(GB|MB|KB)' } | Select-Object -First 1
                if ($l -and $l -match ':\s*([\d\.,]+)\s*(GB|MB|KB)') { $v = [double]($Matches[1] -replace ',', '.'); $bk = switch ($Matches[2]) { 'GB' { $v * 1GB } 'MB' { $v * 1MB } default { $v * 1KB } } }
                $Script:Cache.WinSxS = [pscustomobject]@{ Empfohlen = [bool]$rec; BackupsBytes = [int64]$bk }
                try { [ordered]@{ Zeit = (Get-Date).ToString('o'); Empfohlen = [bool]$rec; BackupsBytes = [int64]$bk } | ConvertTo-Json | Out-File -LiteralPath $cacheFile -Encoding utf8 } catch { }
            }
            $w = $Script:Cache.WinSxS
            # DISM often keeps reporting "recommended" even right after a cleanup - then do not suggest it again all the time
            $kuerzlich = $false
            foreach ($f in (Get-ChildItem $Script:RunsDir -Recurse -Filter 'actions.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })) {
                if (Select-String -LiteralPath $f.FullName -Pattern '"Regel":"CLN-WINSXS".*"Status":"OK"' -Quiet) { $kuerzlich = $true; break }
            }
            if ($w.Empfohlen -and -not $kuerzlich) { New-Item2 ((T 'Component cleanup recommended (backups/disabled features: {0}; Windows decides how much of it is freed)') -f (Fmt-Bytes $w.BackupsBytes)) 0 $null }
        }
        Fix = { param($it) $o = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /English 2>&1; if ($LASTEXITCODE -ne 0) { throw ((T 'Windows could not run the cleanup right now – try again later (DISM code {0})') -f $LASTEXITCODE) }; Remove-Item -LiteralPath (Join-Path $Script:DataDir 'winsxs-analyse.json') -ErrorAction SilentlyContinue; (T 'DISM successful') }
    }

    [pscustomobject]@{ Id = 'CLN-DUMPS'; Kategorie = 'Speicher'; Titel = (T 'Crash dumps of programs'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = (T 'Program crash dumps (CrashDumps) are only useful for developers and can grow to several GB.')
        Detect = { $p = Join-Path $env:LOCALAPPDATA 'CrashDumps'; $f = @(Get-OldFiles $p $Script:Cfg.CrashDumpAgeDays); if ($f.Count) { New-Item2 ((T 'Crash reports of programs: {0} files') -f $f.Count) (($f | Measure-Object Length -Sum).Sum) $p } }
        Fix = { param($it) $n = 0; foreach ($f in (Get-OldFiles $it.Data $Script:Cfg.CrashDumpAgeDays)) { try { if (Test-PathChainNoReparse $it.Data $f.FullName) { $f.Attributes = 'Normal'; $f.Delete(); $n++ } } catch { } }; (T '{0} files' $n) }
    }

    [pscustomobject]@{ Id = 'CLN-BROWSER'; Kategorie = 'Speicher'; Titel = (T 'Large browser caches'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true; Endgueltig = $true; Vorwahl = $false
        Warum = (T 'Browsers keep copies of web pages, scripts and graphics shaders and rebuild them automatically. Only the cache folders (Cache, Code Cache, GPUCache, shader caches, Firefox cache2) are emptied - sign-ins, cookies, history, passwords, bookmarks and extensions stay untouched. Only offered from BrowserCacheMinMB per browser and only while the browser is closed. Pages load a little slower the first time afterwards, so nothing is preselected.')
        Detect = {
            # Browser data belongs to the signed-in user: not offered if WinTidy runs under a different account
            if (-not (Test-DebloatUserHive)) { return }
            foreach ($b in @(Get-BrowserCacheDirs)) {
                if ($b.Bytes -lt ([int64]$Script:Cfg.BrowserCacheMinMB * 1MB)) { continue }
                $offen = Test-BrowserRunning $b.Prozess
                $lbl = (T '{0}: cache {1}' $b.Name (Fmt-Bytes $b.Bytes)) + $(if ($b.Profile -gt 1) { (T ' ({0} profiles)' $b.Profile) } else { '' }) + $(if ($offen) { (T ' - please close the browser before applying') } else { '' })
                $it = New-Item2 $lbl $b.Bytes @{ Name = $b.Name; Prozess = $b.Prozess; Root = $b.Root; Dirs = @($b.Dirs) } ($b.Root)
                # Unattended (-Yes) only while the browser is closed (otherwise it would only be skipped)
                $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue (-not $offen)
                $it
            }
        }
        Fix = { param($it) Clear-BrowserCache $it.Data }
    }

    [pscustomobject]@{ Id = 'CLN-BIGFILES'; Kategorie = 'Speicher'; Titel = (T 'Large and old files in your personal folders (only shown)'); Risiko = 'Info'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = (T 'Personal files are never deleted by WinTidy. This overview shows which large files (BigFileMinMB and more) in Downloads, Desktop, Documents and Videos take up the most space and how much the old files in Downloads (older than DownloadsOldDays) take - so you can decide yourself. Files that are only stored in the cloud (OneDrive "online only") are not counted.')
        Detect = {
            if (-not (Test-DebloatUserHive)) { return }
            $st = Get-PersonalFileStats ([int64]$Script:Cfg.BigFileMinMB * 1MB) ([int]$Script:Cfg.DownloadsOldDays)
            $gross = @($st.Gross)
            if ($gross.Count) {
                $sum = [int64](($gross | Measure-Object Bytes -Sum).Sum)
                $top = @($gross | Select-Object -First 5 | ForEach-Object { '{0} ({1})' -f $_.Rel, (Fmt-Bytes $_.Bytes) })
                $lbl = (T '{0} large files take up {1} in total, the largest: {2}' $gross.Count (Fmt-Bytes $sum) ($top -join ', '))
                New-Item2 $lbl 0 @{ Stufe = ''; Anzahl = $gross.Count; Bytes = $sum } (($gross | Select-Object -First 20 | ForEach-Object { $_.Pfad }) -join '; ')
            }
            if ($st.AltDownloadsBytes -ge 500MB) {
                New-Item2 (T 'Downloads: {0} files older than {1} days take up {2}. If you no longer need them, delete them yourself - Windows Storage Sense (Settings > System > Storage) can also do this automatically.' $st.AltDownloads ([int]$Script:Cfg.DownloadsOldDays) (Fmt-Bytes $st.AltDownloadsBytes)) 0 @{ Stufe = ''; Anzahl = $st.AltDownloads; Bytes = [int64]$st.AltDownloadsBytes }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'CLN-HIBERFIL'; Kategorie = 'Speicher'; Titel = (T 'Shrink the hibernation file on desktop PCs'); Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'On desktops hiberfil.sys is often 40 % of the RAM size although hibernation is hardly used. "powercfg /h /type reduced" shrinks it to the size fast startup needs - fast startup stays, only hibernation is no longer available. Can be undone via "Restore". Only preselected if hibernation is not offered in the Start menu.')
        Detect = {
            $ch = Get-ChassisInfo; if ($ch.Laptop) { return }
            $hf = Join-Path $env:SystemDrive 'hiberfil.sys'
            $f = Get-Item -LiteralPath $hf -Force -ErrorAction SilentlyContinue; if (-not $f) { return }
            $ram = [double](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory; if (-not $ram) { return }
            if ($f.Length -lt 2GB -or $f.Length -lt 0.3 * $ram) { return }
            $spar = [int64]([math]::Max(0, $f.Length - 0.2 * $ram))
            $zeigt = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' -ErrorAction SilentlyContinue).ShowHibernateOption
            # Hybrid sleep and power/sleep button set to "Hibernate" need the full file
            $hybrid = Get-PowerSettingIndex '238c9fa8-0aad-41ed-83f4-97be242c8f20' '94ac6d29-73ce-41a6-809f-6363ba21b47e'
            $pb = Get-PowerSettingIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '7648efa3-dd9c-4e3e-b566-50f929386280'
            $sb = Get-PowerSettingIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '96996bc0-ad50-47ec-923b-6f41874dd9eb'
            $braucht = ($hybrid -and $hybrid.AC -eq 1) -or ($pb -and $pb.AC -eq 2) -or ($sb -and $sb.AC -eq 2)
            $txt = (T 'Hibernation file ({0}) – about {1} freed after shrinking') -f (Fmt-Bytes $f.Length), (Fmt-Bytes $spar)
            if ($hybrid -and $hybrid.AC -eq 1) { $txt += (T '. Caution: hybrid sleep (protects against power failure in sleep mode) is on and would be turned off as well') }
            $it = New-Item2 $txt $spar $null
            $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue ($zeigt -ne 1 -and -not $braucht)
            $it
        }
        Fix = { param($it)
            $null = & powercfg.exe /h /type reduced 2>&1
            if ($LASTEXITCODE -ne 0) { throw (T 'powercfg reports error {0}' $LASTEXITCODE) }
            Add-ActionRecord 'CLN-HIBERFIL' (T 'Hibernation file') 'Undo-Info' 0 '' @{ Typ = 'Hiber'; Vorher = 'full' } | Out-Null
            (T 'shrunk')
        }
    }

    [pscustomobject]@{ Id = 'CLN-RECYCLE'; Kategorie = 'Speicher'; Titel = (T 'Old recycle bin items'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = (T 'Only items deleted longer ago than the age limit. Recently deleted items stay recoverable.')
        Detect = { $o = @(Get-RecycleBinOld $Script:Cfg.RecycleBinAgeDays); if ($o.Count) { New-Item2 ((T '{0} files that were deleted more than {1} days ago') -f $o.Count, $Script:Cfg.RecycleBinAgeDays) (($o | Measure-Object Size -Sum).Sum) $null } }
        Fix = { param($it)
            $n = 0
            foreach ($e in (Get-RecycleBinOld $Script:Cfg.RecycleBinAgeDays)) {
                $i = Join-Path (Split-Path $e.Path) ((Split-Path $e.Path -Leaf) -replace '^\$R', '$I')
                try { Remove-TreeNoFollow $e.Path } catch { }
                if (-not (Test-Path -LiteralPath $e.Path)) { Remove-Item -LiteralPath $i -Force -ErrorAction SilentlyContinue; $n++ }
            }
            (T '{0} items removed' $n)
        }
    }

    [pscustomobject]@{ Id = 'CLN-RECYCLE-ORPHAN'; Kategorie = 'Speicher'; Titel = (T 'Recycle bins of user accounts that no longer exist'); Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Endgueltig = $true
        Warum = (T 'After reinstalls or account changes, recycle bins of old account SIDs remain on every drive that no user sees anymore. Only what belongs to no profile and no existing account is offered; if the profile list cannot be read, nothing is offered.')
        Detect = {
            $known = @(); try { $known = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Select-Object -ExpandProperty SID) } catch { return }
            if ($known.Count -lt 1) { return }
            $known += [string]$Script:Me.User.Value
            foreach ($v in (Get-VolumeInfo)) {
                $rb = "$($v.LW):\`$Recycle.Bin"
                if (-not (Test-Path -LiteralPath $rb)) { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $rb -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $known -notcontains $_.Name -and -not (Test-Reparse $_) })) {
                    # Does the account still exist (e.g. domain account without a local profile)? Then do not offer it.
                    $lebt = $false; try { $null = (New-Object Security.Principal.SecurityIdentifier $d.Name).Translate([Security.Principal.NTAccount]); $lebt = $true } catch { }
                    if ($lebt) { continue }
                    $s = Get-DirSize $d.FullName
                    New-Item2 ((T 'Recycle bin of a deleted user account on {0}: ({1})') -f $v.LW, (Fmt-Bytes $s)) $s $d.FullName
                }
            }
        }
        Fix = { param($it) if ([string]$it.Data -notmatch '^[A-Za-z]:\\\$Recycle\.Bin\\S-1-5-21-[\d-]+$') { throw (T 'Unexpected path') }; Remove-TreeNoFollow $it.Data; (T 'removed') }
    }

    [pscustomobject]@{ Id = 'CLN-DRIVERSTORE'; Kategorie = 'Speicher'; Titel = (T 'Old driver packages in the driver store'); Risiko = 'Mittel'; Wirkung = 'Speicher/Hygiene'; Admin = $true; Standard = $true
        Warum = (T 'With every driver update the old version stays in the driver store. Only older duplicates are removed (the newest stays) as well as chipset drivers of the other CPU vendor (leftovers of a previous PC). Windows refuses drivers in use (no /force).')
        Detect = {
            $pk = Get-DriverPackages
            # INF files used by any device - including one that is currently not connected (dock, audio interface)
            $inUse = @{}
            foreach ($c in @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class' -ErrorAction SilentlyContinue)) { foreach ($i in @(Get-ChildItem $c.PSPath -ErrorAction SilentlyContinue)) { $inf = (Get-ItemProperty $i.PSPath -Name InfPath -ErrorAction SilentlyContinue).InfPath; if ($inf) { $inUse[([string]$inf).ToLower()] = $true } } }
            $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Manufacturer
            $fremd = if ($cpu -match 'AMD') { 'Intel' } elseif ($cpu -match 'Intel') { 'Advanced Micro Devices|^AMD' } else { $null }
            foreach ($g in ($pk | Group-Object Orig)) {
                $s = @($g.Group | Sort-Object @{ Expression = { $_.Ver }; Descending = $true }, @{ Expression = { $_.Datum }; Descending = $true })
                $fremdPlattform = $fremd -and ($s | Where-Object { $_.Prov -match $fremd -and $_.Klasse -match '^(System|SCSIAdapter|HDC)$' })
                $kand = if ($fremdPlattform) { $s } elseif ($s.Count -gt 1) { $s | Select-Object -Skip 1 } else { @() }
                foreach ($k in $kand) {
                    if ($inUse.ContainsKey(([string]$k.Pub).ToLower())) { continue }
                    $grund = if ($fremdPlattform) { (T 'Chipset driver of another CPU platform') } else { (T 'older version, newest {0} stays' ($s[0].VerText)) }
                    New-Item2 ("{0} {1} {2} {3} - {4}" -f $k.Pub, $k.Orig, $k.Prov, $k.VerText, $grund) 0 $k.Pub
                }
            }
        }
        Fix = { param($it) $o = & pnputil.exe /delete-driver $it.Data 2>&1; if ($LASTEXITCODE -ne 0) { throw (T 'SKIP:Still in use – Windows keeps this driver') }; (T 'removed') }
    }

    [pscustomobject]@{ Id = 'CLN-ORPHANDIR'; Kategorie = 'Speicher'; Titel = (T 'Folders without a matching installed program'); Risiko = 'Hoch'; Wirkung = 'Speicher/Hygiene'; Admin = $false; Standard = $false; Umkehrbar = $true
        Warum = (T 'Heuristic: folders in Program Files/ProgramData/AppData whose name matches no installed program. May contain false positives - therefore only on explicit request (-Rule CLN-ORPHANDIR) and with confirmation for each item. The folder is not deleted right away but set aside (renamed); "Restore" brings it back, CLN-QUARANTINE deletes it after QuarantineDays days.')
        Detect = {
            $apps = Get-InstalledApps
            $norm = { param($s) (([string]$s).ToLower() -replace '[^a-z0-9]', '') }
            $names = @(); foreach ($a in $apps) { $names += (& $norm $a.DisplayName); $names += (& $norm $a.Publisher); if ($a.InstallLocation) { $names += (& $norm (Split-Path ([string]$a.InstallLocation).Trim('"').TrimEnd('\') -Leaf)) } }
            foreach ($ax in (Get-AppxPackage -ErrorAction SilentlyContinue)) { $names += (& $norm $ax.Name) }
            $names = @($names | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
            $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ }
            foreach ($r in $roots) {
                foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
                    if ($Script:Cfg.OrphanDirIgnore -contains $d.Name -or (Test-Reparse $d) -or $d.Name -like ('*' + $Script:QuarantineSuffix + '*')) { continue }
                    $n = & $norm $d.Name; if ($n.Length -lt 3) { continue }
                    $hit = $false; foreach ($x in $names) { if ($x.Contains($n) -or ($x.Length -ge 4 -and $n.Contains($x))) { $hit = $true; break } }
                    if ($hit) { continue }
                    $s = Get-DirSize $d.FullName
                    if ($s -ge ($Script:Cfg.OrphanDirMinMB * 1MB)) { New-Item2 ("{0} ({1})" -f $d.FullName, (Fmt-Bytes $s)) $s $d.FullName }
                }
            }
        }
        Fix = { param($it) if (-not (Test-SafeDeleteRoot $it.Data)) { throw (T 'Unsafe path') }; $null = Move-ToQuarantine 'CLN-ORPHANDIR' $it.Data; (T 'set aside (can be restored, deleted after {0} days)' ([int]$Script:Cfg.QuarantineDays)) }
    }

    [pscustomobject]@{ Id = 'CLN-QUARANTINE'; Kategorie = 'Speicher'; Titel = (T 'Folders set aside by WinTidy'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true; Endgueltig = $true
        Warum = (T 'Folders removed with CLN-ORPHANDIR are first only renamed (name ends with .WinTidy-removed-<date>), so that "Restore" can bring them back. After QuarantineDays days without anyone missing them, they are deleted permanently.')
        Detect = {
            $limit = (Get-Date).AddDays(-[int]$Script:Cfg.QuarantineDays)
            foreach ($q in @(Get-QuarantineDirs | Where-Object { $_.Datum -lt $limit })) {
                New-Item2 ((T '{0} (set aside on {1:yyyy-MM-dd})') -f $q.Name, $q.Datum) (Get-DirSize $q.Pfad) $q.Pfad
            }
        }
        Fix = { param($it) if (-not (Test-QuarantinePath $it.Data) -or -not (Test-SafeDeleteRoot $it.Data)) { throw (T 'Unexpected path') }; Remove-TreeNoFollow $it.Data; (T 'deleted') }
    }

    [pscustomobject]@{ Id = 'CLN-DRIVERINSTALL'; Kategorie = 'Speicher'; Titel = (T 'Unpacked driver installers'); Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Endgueltig = $true
        Warum = (T 'Graphics driver installers unpack themselves into folders such as C:\AMD or C:\NVIDIA and leave them there - often several GB. The installed driver does not need them (Windows keeps its own copy in the driver store). Only folders from DriverInstallerDirs, from DriverInstallerMinMB and only if nothing in them has changed for 14 days (no installation running).')
        Detect = {
            foreach ($raw in @($Script:Cfg.DriverInstallerDirs)) {
                $p = ([Environment]::ExpandEnvironmentVariables([string]$raw)).TrimEnd('\')
                if ($p -notmatch '^[A-Za-z]:\\.+' -or -not (Test-SafeDeleteRoot $p)) { continue }
                $d = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                if (-not $d -or -not $d.PSIsContainer -or (Test-Reparse $d)) { continue }
                $s = Get-DirSize $p
                if ($s -lt ([int64]$Script:Cfg.DriverInstallerMinMB * 1MB)) { continue }
                $neu = Get-NewestFileTime $p
                if ($neu -and $neu -gt (Get-Date).AddDays(-14)) { continue }
                New-Item2 ((T 'Unpacked driver installer {0} ({1})') -f $p, (Fmt-Bytes $s)) $s $p
            }
        }
        Fix = { param($it)
            $ok = @($Script:Cfg.DriverInstallerDirs | Where-Object { ([Environment]::ExpandEnvironmentVariables([string]$_)).TrimEnd('\') -ieq [string]$it.Data })
            if (-not $ok.Count -or -not (Test-SafeDeleteRoot $it.Data)) { throw (T 'Unexpected path') }
            Remove-TreeNoFollow $it.Data; (T 'deleted')
        }
    }

    [pscustomobject]@{ Id = 'CLN-PROFILE-ORPHAN'; Kategorie = 'Speicher'; Titel = (T 'Profile folders of deleted user accounts (only shown)'); Risiko = 'Info'; Wirkung = 'Speicher'; Admin = $true; Standard = $true
        Warum = (T 'If a user account is deleted or the PC was moved from an old installation, its folder under C:\Users often stays behind - with documents, pictures and program data nobody can see in the account list anymore. It may contain the only copy of personal files, so WinTidy only shows it. If the profile list cannot be read, nothing is shown.')
        Detect = {
            $dirs = Get-OrphanProfileDirs
            if ($null -eq $dirs) { return }
            foreach ($d in @($dirs)) {
                $s = Get-DirSize $d.FullName
                if ($s -lt 100MB) { continue }
                New-Item2 ((T 'The folder {0} ({1}) belongs to no user account on this PC. Check whether it still contains files you need, back them up and then delete the folder yourself') -f $d.FullName, (Fmt-Bytes $s)) 0 @{ Stufe = ''; Bytes = [int64]$s }
            }
        }
        Fix = $null
    }

    # ---------------------------------------------------------------- Startup
    [pscustomobject]@{ Id = 'STA-ORPHAN'; Kategorie = 'Autostart'; Titel = (T 'Startup entries with a missing program file'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'If a startup entry points to a file that no longer exists, the program has been uninstalled. Entries on currently missing drives (USB) and on the network are not touched. Everything is backed up first.')
        Detect = { Get-StartupItems | Where-Object { $_.Zustand -eq 'fehlt' } | ForEach-Object { New-Item2 ((T '{0} – the program for it is gone') -f $_.Name) 0 $_ ("[{0}] {1} -> {2}" -f $_.Ort, $_.Name, $_.Ziel) } }
        Fix = { param($it)
            $s = $it.Data
            switch ($s.Art) {
                'Registry' {
                    Set-RegValueWithUndo 'STA-ORPHAN' $s.Name $s.Key $s.Name $null '' -Remove
                    if (Get-RegValueRaw $s.SAKey $s.Name) { Set-RegValueWithUndo 'STA-ORPHAN' $s.Name $s.SAKey $s.Name $null '' -Remove }
                }
                'Ordner' {
                    $bdir = Join-Path $Script:RunDir 'backup\startup'; New-Item -ItemType Directory -Force -Path $bdir | Out-Null
                    $kopie = Join-Path $bdir ([IO.Path]::GetFileName($s.Befehl))
                    Copy-Item -LiteralPath $s.Befehl -Destination $kopie -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $s.Befehl -Force -ErrorAction Stop
                    Add-ActionRecord 'STA-ORPHAN' $s.Name 'Undo-Info' 0 '' @{ Typ = 'Datei'; Quelle = $kopie; Ziel = $s.Befehl } | Out-Null
                    if (Get-RegValueRaw $s.SAKey $s.Name) { Set-RegValueWithUndo 'STA-ORPHAN' $s.Name $s.SAKey $s.Name $null '' -Remove }
                }
                'StoreApp' { Backup-RegKey (ConvertTo-RegKeyText $s.Key) ('appxkey_' + $s.Ort + '_' + $s.Name); Remove-Item -Path $s.Key -Recurse -Force -ErrorAction Stop }
            }
            (T 'removed')
        }
    }

    [pscustomobject]@{ Id = 'STA-APPROVED-ORPHAN'; Kategorie = 'Autostart'; Titel = (T 'Orphaned startup state values'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'Task Manager remembers on/off states even for programs removed long ago.')
        Detect = {
            $pairs = @(
                @{ SA = "$Script:SA_HKCU\Run"; Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
                @{ SA = "$Script:SA_HKLM\Run"; Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
                @{ SA = "$Script:SA_HKLM\Run32"; Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
                @{ SA = "$Script:SA_HKCU\StartupFolder"; Dir = [Environment]::GetFolderPath('Startup') },
                @{ SA = "$Script:SA_HKLM\StartupFolder"; Dir = [Environment]::GetFolderPath('CommonStartup') }
            )
            foreach ($p in $pairs) {
                $exist = if ($p.Run) { @((Get-ItemProperty $p.Run -ErrorAction SilentlyContinue).PSObject.Properties.Name) } else { @(Get-ChildItem -LiteralPath $p.Dir -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) }
                $sa = Get-ItemProperty $p.SA -ErrorAction SilentlyContinue
                if (-not $sa) { continue }
                foreach ($n in ($sa.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Select-Object -ExpandProperty Name)) {
                    if ($exist -notcontains $n) { New-Item2 ((T 'Leftover of {0}') -f $n) 0 @{ Key = $p.SA; Name = $n } }
                }
            }
        }
        Fix = { param($it) Set-RegValueWithUndo 'STA-APPROVED-ORPHAN' $it.Data.Name $it.Data.Key $it.Data.Name $null '' -Remove; (T 'removed') }
    }

    [pscustomobject]@{ Id = 'STA-HEAVY'; Kategorie = 'Autostart'; Titel = (T 'Review active startup programs (measured startup delays first)'); Risiko = 'Mittel'; Wirkung = 'Startzeit'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'Every startup program costs sign-in time and RAM. Disabling works like in Task Manager (reversible, nothing is uninstalled). Only entries from HeavyStartup are preselected or disabled with -Yes; antivirus, VPN, backup, cloud storage and input devices are protected (ProtectedStartup).')
        Detect = {
            $prot = $Script:Cfg.ProtectedStartup; $heavy = $Script:Cfg.HeavyStartup
            Get-StartupItems | Where-Object { $_.Aktiv -and $_.Zustand -ne 'fehlt' } | Sort-Object DegradationMs -Descending | ForEach-Object {
                $s = $_; $vi = $null
                if ($s.Ziel -and ([string]$s.Ziel) -match '^[A-Za-z]:\\') { try { $vi = (Get-Item -LiteralPath $s.Ziel -ErrorAction Stop).VersionInfo } catch { } }
                $id = "$($s.Name) $($s.Ziel) $(if ($vi) { "$($vi.CompanyName) $($vi.FileDescription) $($vi.ProductName)" })"
                # Protected: plain substring (rather protect too much); heavy: only as a whole word, so that
                # 'Teams' does not hit TeamSpeak and 'Zoom' does not hit ZoomIt
                if ($prot | Where-Object { $id -like "*$_*" }) { return }
                $isHeavy = [bool]($heavy | Where-Object { Test-WordMatch $id $_ })
                $nm = if ($vi -and $vi.FileDescription -and $s.Art -ne 'StoreApp') { "{0} ({1})" -f $s.Name, ([string]$vi.FileDescription).Trim() } else { $s.Name }
                $tag = @(); if ($s.DegradationMs -ge $Script:Cfg.BootDegradationHintMs) { $tag += ((T 'delays startup by about {0:N0} seconds') -f ($s.DegradationMs / 1000)) }; if ($isHeavy) { $tag += (T 'starts unnecessarily') }
                $it = New-Item2 ("{0}{1}" -f $nm, $(if ($tag) { ' – ' + ($tag -join ', ') } else { '' })) 0 $s ("[{0}] {1} -> {2}" -f $s.Ort, $s.Name, $s.Ziel)
                $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $isHeavy
                $it
            }
        }
        Fix = { param($it)
            $s = $it.Data
            if ($s.Art -eq 'StoreApp') { Set-RegValueWithUndo 'STA-HEAVY' $s.Name $s.Key 'State' 1 'DWord' }
            else {
                [byte[]]$v = @(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())
                Set-RegValueWithUndo 'STA-HEAVY' $s.Name $s.SAKey $s.Name $v 'Binary'
            }
            (T 'disabled')
        }
    }

    # ---------------------------------------------------------------- Tasks & services
    [pscustomobject]@{ Id = 'TSK-ORPHAN'; Kategorie = 'Aufgaben'; Titel = (T 'Scheduled tasks with a missing program file'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'Such tasks run into nothing at every trigger and produce errors. They are disabled (not deleted) and backed up first.')
        Detect = {
            foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' -and $_.State -ne 'Disabled' })) {
                foreach ($a in @($t.Actions)) {
                    if (-not $a.Execute) { continue }
                    $tg = Resolve-CommandTarget ("`"$(([string]$a.Execute).Trim('"'))`" $($a.Arguments)")
                    if ((Get-TargetState $tg) -eq 'fehlt') { New-Item2 ((T 'Scheduled task {0} – the program for it is gone') -f $t.TaskName) 0 $t ("{0}{1} -> {2}" -f $t.TaskPath, $t.TaskName, $tg); break }
                }
            }
        }
        Fix = { param($it) Backup-Task $it.Data; Disable-ScheduledTask -TaskName $it.Data.TaskName -TaskPath $it.Data.TaskPath -ErrorAction Stop | Out-Null; (T 'disabled') }
    }

    [pscustomobject]@{ Id = 'TSK-ANTIPATTERN'; Kategorie = 'Aufgaben'; Titel = (T 'Own maintenance scripts with harmful patterns'); Risiko = 'Info'; Wirkung = 'Startzeit/Datensicherheit'; Admin = $false; Standard = $true
        Warum = (T 'Well-meant cleanup scripts often make Windows slower or endanger data. Detected: deleting Prefetch, emptying the recycle bin completely, deleting Downloads without an age limit, winget --all/--force at every sign-in.')
        Detect = {
            $del = '(?i)(remove-item|\bdel\b|\brd\b|rmdir|\berase\b|\[IO\.(File|Directory)\]::Delete)'
            foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.Author -notlike 'Microsoft*' -and $_.TaskPath -notlike '\Microsoft\Windows\*' })) {
                $logon = [bool]($t.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Boot' })
                foreach ($a in @($t.Actions)) {
                    $txt = "$($a.Execute) $($a.Arguments)"
                    $f = Resolve-CommandTarget ("`"$(([string]$a.Execute).Trim('"'))`" $($a.Arguments)")
                    if ($f -and (Test-Path -LiteralPath $f) -and $f -match '\.(ps1|psm1|bat|cmd|vbs)$' -and (Get-Item $f).Length -lt 500KB) {
                        $raw = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
                        if ($f -match '\.ps') { $raw = [regex]::Replace($raw, '(?s)<#.*?#>', '') }
                        # Remove comments so that explanatory notes ("Prefetch is NOT deleted") do not trigger
                        $code = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(#|rem\s|rem$|::|'')' } | ForEach-Object { $_ -replace '\s+#\s.*$', '' }) -join "`n"
                        $txt += "`n" + $code
                    }
                    $lines = $txt -split "`n"
                    $hits = @()
                    if ($lines | Where-Object { $_ -match '(?i)prefetch' -and $_ -match $del }) { $hits += (T 'deletes Prefetch -> Windows and program starts get slower') }
                    if (($txt -match '(?i)clear-recyclebin' -or ($lines | Where-Object { $_ -match '(?i)\$recycle\.bin' -and $_ -match $del })) -and $txt -notmatch '(?i)DateDeleted|AddDays|-lt\s*\$') { $hits += (T 'empties the recycle bin completely -> accidentally deleted files are gone immediately') }
                    if (($lines | Where-Object { $_ -match '(?i)downloads' -and $_ -match $del }) -and $txt -notmatch '(?i)lastwritetime|adddays|creationtime|SendToRecycleBin') { $hits += (T 'deletes Downloads without an age limit') }
                    if ($txt -match '(?i)winget(\.exe)?\s+upgrade\s+.*--all') { $hits += (T 'winget upgrade --all (installs everything without asking, sometimes versions side by side)') }
                    if ($txt -match '(?i)winget[^\n]*--force') { $hits += (T 'winget --force (skips security checks)') }
                    foreach ($h in $hits) { New-Item2 ("{0}{1}: {2}{3}" -f $t.TaskPath, $t.TaskName, $h, $(if ($logon) { (T ' (at every sign-in!)') } else { '' })) 0 $null }
                }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SVC-ORPHAN'; Kategorie = 'Dienste'; Titel = (T 'Services with a missing program file'); Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'Leftovers of uninstalled programs: the service never starts successfully and produces errors in the event log. It is set to "Disabled" (reversible).')
        Detect = {
            foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -and $_.StartMode -ne 'Disabled' })) {
                $tg = Resolve-CommandTarget $s.PathName
                if ($tg -match '\\(svchost|lsass|services)\.exe$') { continue }
                if ((Get-TargetState $tg) -eq 'fehlt') {
                    $it = New-Item2 ((T 'Background service {0} – the program for it is gone') -f $s.DisplayName) 0 @{ Name = $s.Name; StartMode = $s.StartMode; Verzoegert = [bool]$s.DelayedAutoStart } ("{0} -> {1}" -f $s.Name, $tg)
                    # Only switched to "Disabled" and can be undone: preselected and allowed unattended
                    $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $true
                    $it
                }
            }
        }
        Fix = { param($it) Set-Service -Name $it.Data.Name -StartupType Disabled -ErrorAction Stop; Add-ActionRecord 'SVC-ORPHAN' $it.Data.Name 'Undo-Info' 0 '' @{ Typ = 'Dienst'; Name = $it.Data.Name; StartMode = $it.Data.StartMode; Verzoegert = [bool]$it.Data.Verzoegert } | Out-Null; (T 'disabled') }
    }

    # ---------------------------------------------------------------- Programs
    [pscustomobject]@{ Id = 'APP-SIDEBYSIDE'; Kategorie = 'Programme'; Titel = (T 'Several installed versions of the same program'); Risiko = 'Mittel'; Wirkung = 'Speicher/Hygiene'; Admin = $true; Standard = $true
        Warum = (T 'Some installers put updates next to the old version as an additional version. Uninstalling all versions except the newest is offered (runtimes, SDKs etc. are excluded). Older main versions (e.g. version 18 next to 19) are marked, because they are often kept on purpose. Nothing is preselected.')
        Detect = {
            $ex = ($Script:Cfg.SideBySideExclude -join '|')
            # With admin rights only entries from HKLM: HKCU entries can come from programs without admin rights,
            # their uninstall command would otherwise run with admin rights
            $apps = Get-InstalledApps | Where-Object { $_.DisplayName -notmatch $ex -and $_.UninstallString -and (-not $Script:IsAdmin -or [string]$_.PSPath -like '*HKEY_LOCAL_MACHINE*') }
            $grp = $apps | Group-Object { (($_.DisplayName -replace '\(?\b(x64|x86|64-?bit|32-?bit)\b\)?', '' -replace '\bv?\d+(\.\d+)+\b', '' -replace '\s+', ' ').Trim().ToLower()) + '|' + $_.Publisher }
            foreach ($g in ($grp | Where-Object { $_.Count -gt 1 })) {
                $withV = @($g.Group | ForEach-Object { $v = [version]'0.0'; $m = [regex]::Match(("$($_.DisplayVersion) $($_.DisplayName)"), '\d+(\.\d+)+'); if ($m.Success) { try { $v = [version]($m.Value -replace '^(\d+(\.\d+){0,3}).*$', '$1') } catch { } }; $_ | Add-Member -NotePropertyName V -NotePropertyValue $v -PassThru -Force })
                if (@($withV.V | Select-Object -Unique).Count -lt 2) { continue }
                $newest = ($withV | Sort-Object V -Descending)[0]
                foreach ($a in ($withV | Where-Object { $_ -ne $newest } | Sort-Object V)) {
                    $lbl = (T '{0} {1} (newest {2} stays)') -f $a.DisplayName, $a.DisplayVersion, $newest.DisplayVersion
                    # Another main version (e.g. 18 next to 19) is often kept on purpose for old projects - say so
                    if ($a.V.Major -ne $newest.V.Major -and $a.V -ne [version]'0.0') { $lbl += (T ' - different main version, may be installed on purpose') }
                    $it = New-Item2 $lbl ([int64]$a.EstimatedSize * 1KB) $a
                    # Uninstallers are interactive and cannot be undone: never unattended, never preselected
                    $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $false
                    $it
                }
            }
        }
        Fix = { param($it)
            $a = $it.Data
            $s = if ($a.QuietUninstallString) { $a.QuietUninstallString } else { $a.UninstallString }
            if ($s -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] } elseif ($s -match '^\s*(.+?\.exe)\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] } else { $exe = $s; $arg = '' }
            if ($exe -match 'msiexec') { $arg = $arg -replace '/I\{', '/X{' }
            W (T '      (the uninstaller may open - please click through it)') 'DarkGray'
            $p = if ($arg.Trim()) { Start-Process -FilePath $exe -ArgumentList $arg -Wait -PassThru } else { Start-Process -FilePath $exe -Wait -PassThru }
            if ($p.ExitCode -in 1602, 1223) { throw (T 'SKIP:Uninstall cancelled') }
            if ($p.ExitCode -notin 0, 3010, 1641) { throw (T 'Uninstaller reports code {0}' ($p.ExitCode)) }
            (T 'uninstalled')
        }
    }

    [pscustomobject]@{ Id = 'APP-UPDATES'; Kategorie = 'Programme'; Titel = (T 'Outdated programs (winget)'); Risiko = 'Mittel'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true; Dauer = (T '1–5 minutes per program'); Endgueltig = $true
        Warum = (T 'Outdated software is the most common entry point for attacks. Updates are installed one by one via winget, programs from WingetExclude never automatically. Running programs may be closed in the process.')
        Detect = {
            $ctx = $Script:LastContext; if ($ctx -and $ctx.AnderesKonto) { return }   # per-user installations would be invisible
            $wg = Get-WingetPath; if (-not $wg) { return }
            $z = @(& $wg upgrade --source winget --disable-interactivity --accept-source-agreements 2>$null | ForEach-Object { ($_ -split "`r")[-1] })
            $kopf = $z | Where-Object { $_ -match '^\s*Name\s+I[dD]\s+' } | Select-Object -First 1
            if (-not $kopf) { return }
            $iId = $kopf.IndexOf(($kopf -split '\s+' | Where-Object { $_ -match '^I[dD]$' })[0]); $iVer = $kopf.IndexOf('Version')
            for ($k = [array]::IndexOf($z, $kopf) + 2; $k -lt $z.Count; $k++) {
                $l = $z[$k]; if ($l -notmatch '\S' -or $l.Length -le $iVer) { break }
                $id = $l.Substring($iId, $iVer - $iId).Trim(); if ($id -notmatch '^[^\s]+\.[^\s]+$') { break }
                if ($id -match '…|\.\.\.$') { continue }   # ID shortened by winget - not unique
                $name = $l.Substring(0, $iId).Trim()
                if ($Script:Cfg.WingetExclude | Where-Object { $name -like "*$_*" -or $id -like "*$_*" }) { continue }
                $ver = ($l.Substring($iVer).Trim() -split '\s+')
                New-Item2 ("{0}{1}" -f $name, $(if ($ver.Count -ge 2) { " ($($ver[0]) → $($ver[1]))" } else { '' })) 0 $id
            }
        }
        Fix = { param($it)
            $wg = Get-WingetPath; if (-not $wg) { throw (T 'winget not found') }
            $o = & $wg upgrade --id $it.Data --exact --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1
            if ($LASTEXITCODE -ne 0) { throw ((T 'The update did not work – please try again later or update the program yourself (winget code {0})') -f $LASTEXITCODE) }
            (T 'updated')
        }
    }

    # ---------------------------------------------------------------- System
    [pscustomobject]@{ Id = 'SYS-GHOST'; Kategorie = 'System'; Titel = (T 'Ghost devices (hardware that is no longer connected)'); Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Endgueltig = $true
        Warum = (T 'Old devices stay registered in Device Manager (e.g. from a previous PC). Only devices that have not been connected for at least GhostDeviceMinDays days are offered - a dock or audio interface that is only unplugged for a while keeps its settings. If a device is connected again, Windows detects it anew. Bluetooth, audio endpoints and printers are excluded.')
        Detect = {
            $cls = $Script:Cfg.GhostDeviceClasses
            $alle = @(Get-GhostDevices)
            if (-not $alle.Count) { return }
            # Only devices whose last appearance is known and old enough (unknown = not offered)
            $seen = Get-DeviceLastSeen @($alle | ForEach-Object { [string]$_.InstanceId })
            $limit = (Get-Date).AddDays(-[int]$Script:Cfg.GhostDeviceMinDays)
            $g = @($alle | Where-Object { $seen.ContainsKey([string]$_.InstanceId) -and $seen[[string]$_.InstanceId] -lt $limit })
            foreach ($grp in ($g | Group-Object Class | Sort-Object Count -Descending)) {
                $bsp = ($grp.Group | Select-Object -ExpandProperty FriendlyName -Unique | Where-Object { $_ } | Select-Object -First 3) -join '; '
                New-Item2 ((T '{0} old entries: {1} (e.g. {2})') -f $grp.Count, (Get-DeviceClassName $grp.Name), $bsp) 0 @($grp.Group | Select-Object -ExpandProperty InstanceId)
            }
        }
        Fix = { param($it) $ok = 0; $f = 0; foreach ($id in $it.Data) { & pnputil.exe /remove-device "$id" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ok++ } else { $f++ } }; (T '{0} removed, {1} not' $ok $f) }
    }

    [pscustomobject]@{ Id = 'SYS-SHADOW'; Kategorie = 'System'; Titel = (T 'Too little space for restore points'); Risiko = 'Niedrig'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true
        Warum = (T 'If the shadow copy storage is too small, Windows discards restore points (event Volsnap 36). Target: ShadowStorageTarget of the drive size.')
        Detect = {
            $vols = @{}; Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $vols[$_.DeviceID] = $_ }
            foreach ($s in (Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue)) {
                $v = $vols[$s.Volume.DeviceID]; if (-not $v -or -not $v.Capacity) { continue }
                $pct = 100 * $s.MaxSpace / $v.Capacity
                if ($pct -lt $Script:Cfg.ShadowStorageMinPercent) { New-Item2 ((T 'Drive {0}: only {1} ({2:N1} %) for restore points') -f $v.DriveLetter, (Fmt-Bytes $s.MaxSpace), $pct) 0 $v.DriveLetter }
            }
        }
        Fix = { param($it) $o = & vssadmin.exe resize shadowstorage /for=$($it.Data) /on=$($it.Data) /maxsize=$($Script:Cfg.ShadowStorageTarget) 2>&1; if ($LASTEXITCODE -ne 0) { throw ($o | Out-String) }; (T 'set to {0}' ($Script:Cfg.ShadowStorageTarget)) }
    }

    [pscustomobject]@{ Id = 'SYS-TRIM'; Kategorie = 'System'; Titel = (T 'SSD TRIM turned off'); Risiko = 'Niedrig'; Wirkung = 'Leistung'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'TRIM tells the SSD about free blocks and keeps write performance high. Only reported if TRIM is turned off in Windows (often by "tuning" tools). If the weekly drive optimization does not run, SYS-MAINT reports it - one cause, one finding.')
        Detect = {
            $fs = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
            $dd = (Get-ItemProperty $fs -ErrorAction SilentlyContinue).DisableDeleteNotification
            $ssd = @(Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' })
            if (-not $ssd.Count) { return }
            if ($dd -eq 1) { New-Item2 (T 'TRIM is turned off in Windows – the SSD gets slower over time') 0 'an' }
        }
        Fix = { param($it)
            if ($it.Data -eq 'an') { Set-RegValueWithUndo 'SYS-TRIM' 'TRIM' 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification' 0 'DWord'; foreach ($v in @(Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' })) { try { Optimize-Volume -DriveLetter $v.LW -ReTrim -ErrorAction Stop } catch { } }; return (T 'TRIM turned on') }
            Optimize-Volume -DriveLetter $it.Data -ReTrim -ErrorAction Stop; (T 'TRIM run')
        }
    }

    [pscustomobject]@{ Id = 'SYS-MAINT'; Kategorie = 'System'; Titel = (T 'Drive optimization does not run'); Risiko = 'Niedrig'; Wirkung = 'Leistung/Hygiene'; Admin = $true; Standard = $true
        Warum = (T 'Windows optimizes the drives weekly during automatic maintenance (TRIM for SSDs, defragmenting hard disks). Reported if this task is turned off or has not run for more than 14 days. The fix runs TRIM on the SSDs right away and starts the maintenance.')
        Detect = {
            $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
            if (-not $t) { return }
            $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            # Aborts (0x8007042B) are normal if you work during maintenance - it only matters if it has not run for a long time
            if ($t.State -eq 'Disabled') { New-Item2 (T 'Windows drive maintenance is turned off (task ScheduledDefrag disabled)') 0 'aus'; return }
            if (-not $i.LastRunTime -or $i.LastRunTime.Year -lt 2000 -or $i.LastRunTime -lt (Get-Date).AddDays(-14)) { New-Item2 ((T 'Windows drive maintenance has not run for more than 14 days{0}') -f $(if ($i.LastRunTime -and $i.LastRunTime.Year -ge 2000) { (T ' (last {0:yyyy-MM-dd})') -f $i.LastRunTime } else { '' })) 0 $null }
        }
        Fix = { param($it)
            if ($it.Data -eq 'aus') { Backup-Task (Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'); Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null; return (T 'Drive maintenance turned on') }
            # SSDs right away (takes seconds), the rest via the normal maintenance
            foreach ($v in @(Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' })) { try { Optimize-Volume -DriveLetter $v.LW -ReTrim -ErrorAction Stop } catch { } }
            Start-Process "$env:windir\System32\MSchedExe.exe" -ArgumentList 'Start'; (T 'Maintenance started (leave the PC on for about 1 hour)')
        }
    }

    [pscustomobject]@{ Id = 'SYS-REBOOT'; Kategorie = 'System'; Titel = (T 'Windows has not been restarted for a long time'); Risiko = 'Info'; Wirkung = 'Sicherheit/Stabilitaet'; Admin = $false; Standard = $true
        Warum = (T 'Updates and drivers often only take effect after a restart. With fast startup, "Shut down" is no real restart. Reported after 7 days without a restart - as a warning if Windows is waiting for a restart to finish updates.')
        Detect = {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if (-not $os -or -not $os.LastBootUpTime -or $os.LastBootUpTime -ge (Get-Date).AddDays(-7)) { return }
            $tage = ((Get-Date) - $os.LastBootUpTime).TotalDays
            if (Test-RebootPending) { New-Item2 ((T 'Windows is waiting for a restart to finish installing updates, but has not been restarted for {0:N0} days - until then the updates do not protect the PC. Choose Start > Power > Restart') -f $tage) 0 @{ Stufe = 'warn' }; return }
            $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
            if ($hb -eq 1) { New-Item2 ((T 'Windows has not been restarted for {0:N0} days (fast startup turns ''Shut down'' into no real restart). So choose ''Restart'' after updates and drivers') -f $tage) 0 @{ Stufe = '' } }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-INTEGRITY'; Kategorie = 'System'; Titel = (T 'Check/repair system files and the component store'); Risiko = 'Niedrig'; Wirkung = 'Stabilitaet'; Admin = $true; Standard = $true; Dauer = (T '10–30 minutes')
        Warum = (T 'DISM checks the component store, SFC the system files. With -Deep the repair is always offered, otherwise only when damage is reported.')
        Detect = {
            $h = $null; try { $h = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState } catch { }
            if ($h -and "$h" -ne 'Healthy') { New-Item2 (T 'Component store: {0}' $h) 0 'dism' }
            if ($Deep -or ($h -and "$h" -ne 'Healthy')) { New-Item2 (T 'SFC /scannow (check and repair system files, about 10 min.)') 0 'sfc' }
        }
        Fix = { param($it)
            if ($it.Data -eq 'dism') { $r = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop; return (T 'State: {0}' ($r.ImageHealthState)) }
            $alt = [Console]::OutputEncoding
            try { [Console]::OutputEncoding = [Text.Encoding]::Unicode; $o = & sfc.exe /scannow 2>&1 } finally { [Console]::OutputEncoding = $alt }
            (($o | ForEach-Object { "$_" -replace "`0", '' } | Where-Object { $_ -match '\S' -and $_ -notmatch '%' }) | Select-Object -Last 2) -join ' '
        }
    }

    [pscustomobject]@{ Id = 'SYS-FSCHECK'; Kategorie = 'System'; Titel = (T 'File system check (online, only with -Deep)'); Risiko = 'Info'; Wirkung = 'Stabilitaet'; Admin = $true; Standard = $true
        Warum = (T 'Checks NTFS volumes for errors while running. If something is found: chkdsk X: /spotfix or /f at the next start.')
        Detect = { if (-not $Deep) { return }; foreach ($v in (Get-VolumeInfo | Where-Object FS -eq 'NTFS')) { $r = $null; try { $r = Repair-Volume -DriveLetter $v.LW -Scan -ErrorAction Stop } catch { $r = (T 'Error: {0}' ($_.Exception.Message)) }; if ("$r" -ne 'NoErrorsFound') { New-Item2 ("{0}: {1}" -f $v.LW, $r) 0 $null } } }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-GAMEDVR'; Kategorie = 'System'; Titel = (T 'Background recording (Xbox Game Bar) active'); Risiko = 'Mittel'; Wirkung = 'Leistung'; Admin = $false; Standard = $true; Umkehrbar = $true
        Warum = (T 'Background recording ("Record what happened") constantly records the last minutes in games; Windows itself warns in its settings that this may affect game performance. It is off by default - if it is on, someone switched it on. If you use it on purpose, leave it. Only this is turned off; recording clips manually and Game Mode stay. Nothing is preselected.')
        Detect = {
            $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -ErrorAction SilentlyContinue
            if ($k -and $k.HistoricalCaptureEnabled -eq 1 -and $k.AppCaptureEnabled -ne 0) {
                $it = New-Item2 (T 'Background recording of the Xbox Game Bar is turned on') 0 $null
                # Switched on by someone on purpose: never preselected, never unattended
                $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $false
                $it
            }
        }
        Fix = { param($it) Set-RegValueWithUndo 'SYS-GAMEDVR' (T 'Background recording') 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0 'DWord'; (T 'disabled') }
    }

    # ---------------------------------------------------------------- Security (mostly info)
    [pscustomobject]@{ Id = 'SEC-EXECPOLICY'; Kategorie = 'Sicherheit'; Titel = (T 'PowerShell execution policy too permissive'); Risiko = 'Mittel'; Wirkung = 'Sicherheit'; Admin = $false; Standard = $true; Umkehrbar = $true
        Warum = (T '"Unrestricted"/"Bypass" permanently allows every downloaded script. RemoteSigned keeps local scripts running but blocks unsigned downloads. The execution policy is not a security boundary (Microsoft), only a protection against running a downloaded script by accident - developers often set it on purpose. Therefore nothing is preselected.')
        Detect = {
            foreach ($s in 'CurrentUser', 'LocalMachine') {
                $p = Get-ExecutionPolicy -Scope $s
                if ("$p" -in 'Unrestricted', 'Bypass') {
                    $it = New-Item2 $(if ($s -eq 'CurrentUser') { (T 'This protection setting is turned off for your user account') } else { (T 'This protection setting is turned off for all users') }) 0 $s
                    $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $false
                    $it
                }
            }
        }
        Fix = { param($it) $alt = "$(Get-ExecutionPolicy -Scope $it.Data)"; try { Set-ExecutionPolicy RemoteSigned -Scope $it.Data -Force -ErrorAction Stop } catch { if ($_.Exception.Message -notmatch 'overridden|ueberschrieben|überschrieben') { throw } }; if ("$(Get-ExecutionPolicy -Scope $it.Data)" -ne $alt) { Add-ActionRecord 'SEC-EXECPOLICY' (T 'Protection setting for scripts') 'Undo-Info' 0 '' @{ Typ = 'ExecPolicy'; Scope = $it.Data; Vorher = $alt } | Out-Null }; 'RemoteSigned' }
    }

    [pscustomobject]@{ Id = 'SEC-CHECKS'; Kategorie = 'Sicherheit'; Titel = (T 'Security basics'); Risiko = 'Info'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true
        Warum = (T 'Windows support and updates, Secure Boot, antivirus, firewall, UAC, BIOS age and too broad antivirus exclusions. Another active antivirus or firewall is taken into account.')
        Detect = {
            $wi = Get-WindowsSupportInfo
            if ($wi.Ende -and $wi.Ende -lt (Get-Date)) { New-Item2 ((T 'This Windows version ({0}) has not received security updates since {1:yyyy-MM-dd} – please update to the current version via Settings > Windows Update') -f $wi.Version, $wi.Ende) 0 @{ Stufe = 'krit' } }
            elseif ($wi.Ende -and $wi.Ende -lt (Get-Date).AddDays(60)) { New-Item2 ((T 'This Windows version ({0}) only receives security updates until {1:yyyy-MM-dd} – update to the current version soon') -f $wi.Version, $wi.Ende) 0 @{ Stufe = 'warn' } }
            if ($wi.WuDeaktiviert) { New-Item2 (T 'Windows Update is turned off – the PC receives no security updates') 0 @{ Stufe = 'krit' } }
            elseif ($null -ne $wi.TageSeitUpdate -and $wi.TageSeitUpdate -gt 40) { New-Item2 ((T 'No Windows updates have been installed for {0} days – check Settings > Windows Update') -f $wi.TageSeitUpdate) 0 @{ Stufe = 'warn' } }
            $fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction SilentlyContinue).PEFirmwareType
            $sb = $null; try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
            if ($fw -eq 1) { New-Item2 (T 'Windows starts in the old BIOS mode (legacy) – Secure Boot (boot protection) is not possible this way. Only someone who knows what they are doing should switch it') 0 @{ Stufe = '' } }
            elseif ($sb -eq $false) { New-Item2 (T 'Secure Boot (boot protection) is turned off. This is not an acute problem. Only someone who knows what they are doing should turn it on – done wrong, Windows no longer starts') 0 @{ Stufe = '' } }
            elseif ($sb -eq $true) {
                $ca = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue).UEFICA2023Status
                if ($ca -and [string]$ca -ne 'Updated') { New-Item2 (T 'The new Secure Boot certificates (2023) are not installed yet. Windows does this via updates; sometimes a BIOS update is needed for it') 0 @{ Stufe = '' } }
            }
            $avFremd = @(Get-OtherSecurityProducts 'AntiVirusProduct')
            if (-not $avFremd.Count) {
                try {
                    $m = Get-MpComputerStatus -ErrorAction Stop
                    if (-not $m.RealTimeProtectionEnabled) { New-Item2 (T 'The antivirus (Microsoft Defender) is turned off and no other antivirus is active') 0 @{ Stufe = 'krit' } }
                    elseif ($m.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-7)) { New-Item2 ((T 'The antivirus signatures are older than 7 days (as of {0:yyyy-MM-dd})') -f $m.AntivirusSignatureLastUpdated) 0 @{ Stufe = 'warn' } }
                } catch { }
            }
            if (-not @(Get-OtherSecurityProducts 'FirewallProduct').Count) {
                $pn = @{ 'Domain' = (T 'company networks'); 'Private' = (T 'private networks'); 'Public' = (T 'public networks') }
                try { Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { New-Item2 ((T 'The Windows Firewall is turned off for {0}. Turn it on under Settings > Privacy & security > Windows Security > Firewall') -f $(if ($pn.ContainsKey([string]$_.Name)) { $pn[[string]$_.Name] } else { $_.Name })) 0 @{ Stufe = 'warn' } } } catch { }
            }
            if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA -eq 0) { New-Item2 (T 'User Account Control (confirmation for changes to the system) is turned off') 0 @{ Stufe = 'warn' } }
            $b = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            if ($b.ReleaseDate -and $b.ReleaseDate -lt (Get-Date).AddYears(-2)) { New-Item2 ((T 'The basic software of the motherboard (BIOS) dates from {0:yyyy-MM-dd}. An update can fix bugs and security holes – please only have it done by someone who knows what they are doing') -f $b.ReleaseDate) 0 @{ Stufe = '' } }
            # Defender exclusions that switch off the scan for large parts of the PC (tuning tools, game cheats, old guides)
            if (-not $avFremd.Count) {
                foreach ($x in @(Get-BroadDefenderExclusions (Get-DefenderExclusions))) {
                    $txt = switch ($x.Art) { 'Pfad' { (T 'The antivirus skips the whole folder {0} - malware there is not found. Check the exclusion under Windows Security > Virus & threat protection > Exclusions') } 'Endung' { (T 'The antivirus skips all files of the type {0} - a typical trick of malware and tuning tools. Check the exclusion under Windows Security > Virus & threat protection > Exclusions') } default { (T 'The antivirus ignores everything the program {0} does - check the exclusion under Windows Security > Virus & threat protection > Exclusions') } }
                    New-Item2 ($txt -f $x.Wert) 0 @{ Stufe = 'warn' }
                }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SEC-HEALTH'; Kategorie = 'Sicherheit'; Titel = (T 'Security health check'); Risiko = 'Info'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true
        Warum = (T 'Shows whether drive encryption, the security chip (TPM), memory integrity and the tamper protection of Microsoft Defender are active. Only reads, changes nothing.')
        Detect = {
            $bl = Get-BitLockerState
            if ($bl -eq 'Geschuetzt') { New-Item2 (T 'The system drive is encrypted – the data stays unreadable if the PC is lost or stolen') 0 @{ Stufe = 'ok' } }
            elseif ($bl -eq 'Ausgesetzt') {
                # Paused only until the next restart (e.g. for a BIOS update): resumes by itself, no warning
                $n = Get-BitLockerSuspendCount
                if ($null -ne $n -and $n -gt 0) { New-Item2 (T 'The drive encryption of the system drive is paused until the next restart (Windows does this e.g. for BIOS updates) and then resumes by itself') 0 @{ Stufe = '' } }
                else { New-Item2 (T 'The drive encryption of the system drive is paused and protects nothing right now. Resume it under Settings > Privacy & security > Device encryption') 0 @{ Stufe = 'warn' } }
            }
            elseif ($bl -eq 'Aus') {
                $lap = $false; try { $lap = [bool](Get-ChassisInfo).Laptop } catch { }
                New-Item2 (T 'The system drive is not encrypted. If the PC is lost or stolen, others can read the data. Device encryption can be turned on under Settings > Privacy & security > Device encryption (depending on the Windows edition as BitLocker)') 0 @{ Stufe = $(if ($lap) { 'warn' } else { '' }) }
            }
            $tpm = Get-TpmState
            if ($tpm) {
                if ($tpm.Vorhanden -and $tpm.Bereit) { New-Item2 (T 'The security chip (TPM) is present and ready') 0 @{ Stufe = 'ok' } }
                elseif ($tpm.Vorhanden) { New-Item2 (T 'The security chip (TPM) is present but not ready. Please check it in the BIOS or with tpm.msc') 0 @{ Stufe = 'warn' } }
                else { New-Item2 (T 'No security chip (TPM) found. Windows 11 needs TPM 2.0; on a virtual machine or an old PC this is normal') 0 @{ Stufe = '' } }
            }
            $mi = Get-MemoryIntegrityState
            if ($mi -eq $true) { New-Item2 (T 'Memory integrity (core isolation) is on and protects the Windows kernel') 0 @{ Stufe = 'ok' } }
            elseif ($mi -eq $false) { New-Item2 (T 'Memory integrity (core isolation) is off. It protects the Windows kernel against attacks. It can be turned on under Settings > Privacy & security > Windows Security > Device security > Core isolation; old incompatible drivers can prevent it') 0 @{ Stufe = '' } }
            if (-not @(Get-OtherSecurityProducts 'AntiVirusProduct').Count) {
                $tp = Get-DefenderTamperState
                if ($tp -eq $true) { New-Item2 (T 'The tamper protection of Microsoft Defender is on – malware cannot simply turn the antivirus off') 0 @{ Stufe = 'ok' } }
                elseif ($tp -eq $false) { New-Item2 (T 'The tamper protection of Microsoft Defender is off. Malware could turn the antivirus off. Turn it on under Windows Security > Virus & threat protection > Settings') 0 @{ Stufe = 'warn' } }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-STORAGESENSE'; Kategorie = 'System'; Titel = (T 'Windows Storage Sense'); Risiko = 'Info'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = (T 'Storage Sense is the cleanup function built into Windows. WinTidy shows whether it is on and what it deletes automatically. Only reads, changes nothing.')
        Detect = {
            $ss = Get-StorageSenseState
            if (-not $ss) { return }
            if ($ss.Richtlinie -eq 0) { New-Item2 (T 'Storage Sense is turned off by a policy of the organization') 0 @{ Stufe = '' } }
            elseif (-not $ss.Aktiv) { New-Item2 (T 'Storage Sense (automatic cleanup by Windows) is off. That is fine, WinTidy cleans up on request. It can be turned on under Settings > System > Storage') 0 @{ Stufe = '' } }
            else {
                New-Item2 (T 'Storage Sense (automatic cleanup by Windows) is on') 0 @{ Stufe = 'ok' }
                if ($ss.DownloadsTage -gt 0) { New-Item2 ((T 'Storage Sense deletes files from your Downloads folder that are older than {0} days. Please check under Settings > System > Storage that this is what you want') -f $ss.DownloadsTage) 0 @{ Stufe = 'warn' } }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-AI'; Kategorie = 'System'; Titel = (T 'AI features (Copilot, Recall)'); Risiko = 'Info'; Wirkung = 'Sicherheit'; Admin = $false; Standard = $true
        Warum = (T 'Shows which AI features of Windows are present or active. WinTidy only informs, you decide in the Windows settings.')
        Detect = {
            $ai = Get-AiFeatureState
            if (-not $ai) { return }
            if ($ai.RecallAktiv -eq $true) { New-Item2 (T 'Recall is on: Windows regularly saves pictures of your screen on this PC so that your activity becomes searchable. If you do not want that, turn it off under Settings > Privacy & security > Recall & snapshots') 0 @{ Stufe = '' } }
            elseif ($ai.RecallAktiv -eq $false -or $ai.RecallRichtlinie -eq 0) { New-Item2 (T 'Recall (screen history with AI search) is not active on this PC') 0 @{ Stufe = 'ok' } }
            if ($ai.CopilotRichtlinieAus) { New-Item2 (T 'Copilot is turned off by a policy') 0 @{ Stufe = 'ok' } }
            elseif ($ai.CopilotApp) { New-Item2 (T 'The Copilot app is installed. If you do not use it, you can uninstall it like any other app under Settings > Apps > Installed apps') 0 @{ Stufe = '' } }
            if ($ai.DatenanalyseAus) { New-Item2 (T 'Windows may not analyze your activity with AI (policy)') 0 @{ Stufe = 'ok' } }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-TWEAKS'; Kategorie = 'System'; Titel = (T 'Unfavorable tuning settings'); Risiko = 'Info'; Wirkung = 'Leistung/Sicherheit'; Admin = $true; Standard = $true
        Warum = (T 'Some tuning programs and guides turn off Windows features that actually make the PC faster or safer: page file, Prefetch, SysMain, Windows Search, Defender via policy, update servers blocked in the hosts file, Windows held at an old version by policy.')
        Detect = {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and -not $cs.AutomaticManagedPagefile -and -not @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue).Count) { New-Item2 (T 'The page file is turned off – this leads to crashes when the RAM is full. Recommended: "Automatically manage paging file size" (System Properties > Advanced > Performance)') 0 @{ Stufe = 'warn' } }
            $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -ErrorAction SilentlyContinue).EnablePrefetcher
            if ($pf -eq 0) { New-Item2 (T 'Prefetch is turned off – Windows and programs start slower') 0 @{ Stufe = 'warn' } }
            $sm = Get-CimInstance Win32_Service -Filter "Name='SysMain'" -ErrorAction SilentlyContinue
            if ($sm -and $sm.StartMode -eq 'Disabled') { New-Item2 (T 'The SysMain service (loads programs faster) is turned off') 0 @{ Stufe = 'warn' } }
            $dp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -ErrorAction SilentlyContinue
            $rp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -ErrorAction SilentlyContinue
            if (($dp.DisableAntiSpyware -eq 1 -or $rp.DisableRealtimeMonitoring -eq 1) -and -not @(Get-OtherSecurityProducts 'AntiVirusProduct').Count) { New-Item2 (T 'The antivirus was turned off via policy (often by tuning programs) and no other antivirus is active') 0 @{ Stufe = 'krit' } }
            $ws = Get-CimInstance Win32_Service -Filter "Name='WSearch'" -ErrorAction SilentlyContinue
            if ($ws -and $ws.StartMode -eq 'Disabled') { New-Item2 (T 'The Windows Search service is turned off - searching in Start, File Explorer and Outlook becomes slow or finds nothing. It does not make the PC faster') 0 @{ Stufe = 'warn' } }
            $hb = @(Get-HostsUpdateBlocks)
            if ($hb.Count) { New-Item2 ((T 'The hosts file blocks {0} address(es) of Windows Update or the antivirus (e.g. {1}) - the PC then receives no or incomplete security updates. Often set by "anti-telemetry" tools') -f $hb.Count, ($hb[0] -split '\s+')[-1]) 0 @{ Stufe = 'krit' } }
            $pin = Get-UpdatePolicyPin
            if ($pin) {
                $wi = Get-WindowsSupportInfo
                $abgel = [bool]($wi.Ende -and $wi.Ende -lt (Get-Date))
                New-Item2 ((T 'A policy holds Windows at version {0} - newer Windows versions are not installed. On a company PC this is usually intended; otherwise a tuning program probably set it') -f (($pin.Produkt + ' ' + $pin.Version).Trim())) 0 @{ Stufe = $(if ($abgel) { 'krit' } else { '' }) }
            }
        }
        Fix = $null
    }

    # ---------------------------------------------------------------- Hardware hints (info)
    [pscustomobject]@{ Id = 'HW-HINTS'; Kategorie = 'Hardware'; Titel = (T 'Hardware and configuration hints'); Risiko = 'Info'; Wirkung = 'Leistung'; Admin = $false; Standard = $true
        Warum = (T 'The biggest levers are often in the hardware configuration: system drive, RAM, graphics card, power plan, network and device drivers.')
        Detect = {
            $ch = Get-ChassisInfo
            $vols = Get-VolumeInfo; $sys = $vols | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) }
            if ($sys) {
                if ($sys.Medium -eq 'HDD') { New-Item2 (T 'Windows is on a hard disk (HDD) – an SSD is the biggest single improvement') 0 @{ Stufe = 'warn' } }
                $nvme = $vols | Where-Object { $_.Bus -eq 'NVMe' -and $_.LW -ne $sys.LW -and $_.FreiProzent -gt 60 }
                if ($sys.Bus -ne 'NVMe' -and $nvme) { New-Item2 ((T 'Windows is on {0} ({1}), but drive {2}: is a barely used, faster NVMe SSD ({3} GB free) – moving Windows there gives much faster starts') -f $sys.Disk, $sys.Bus, $nvme[0].LW, $nvme[0].FreiGB) 0 @{ Stufe = '' } }
                elseif ($sys.Medium -eq 'SSD') {
                    $big = $vols | Where-Object { $_.Medium -eq 'SSD' -and $_.LW -ne $sys.LW -and $_.FreiProzent -gt 60 -and $_.GroesseGB -ge 2 * $sys.GroesseGB } | Select-Object -First 1
                    if ($big) { New-Item2 ((T 'Windows is on {0} ({1} GB), while drive {2}: ({3}, {4} GB) is {5} % empty – check whether this SSD is faster (e.g. NVMe) and move Windows or games there') -f $sys.Disk, $sys.GroesseGB, $big.LW, $big.Disk, $big.GroesseGB, $big.FreiProzent) 0 @{ Stufe = '' } }
                }
                if ($sys.FreiProzent -lt 15) { New-Item2 ((T 'Only {0} % is free on the Windows drive – below 15 % the PC gets slower') -f $sys.FreiProzent) 0 @{ Stufe = 'warn' } }
            }
            # RAM
            $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Where-Object { $_.Capacity -gt 0 })
            if (-not $ch.Laptop -and -not $ch.VM -and $mem.Count -eq 1) { New-Item2 ((T 'Only one memory module installed ({0:N0} GB) – two identical modules work together (dual channel) and are noticeably faster, especially in games and with graphics in the processor') -f ($mem[0].Capacity / 1GB)) 0 @{ Stufe = 'warn' } }
            if (-not $ch.Laptop) { foreach ($m in $mem) { if ($m.ConfiguredClockSpeed -and $m.Speed -and $m.ConfiguredClockSpeed -lt $m.Speed) { New-Item2 ((T 'RAM runs at {0} instead of {1} MT/s. If the modules have an XMP/EXPO profile, it can be turned on in the BIOS (check the manufacturer''s specification)') -f $m.ConfiguredClockSpeed, $m.Speed) 0 @{ Stufe = '' }; break } } }
            # Graphics: driver missing, monitor on the motherboard
            $vc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
            if (-not $ch.VM -and ($vc | Where-Object { $_.Name -match 'Basic Display|Standard-VGA|Microsoft Basic' -or $_.InfFilename -eq 'display.inf' })) { New-Item2 (T 'No proper driver is installed for the graphics (Microsoft standard driver) – install the driver from the graphics card manufacturer') 0 @{ Stufe = 'krit' } }
            $dgpu = @($vc | Where-Object { $_.Name -match '(?i)NVIDIA|Radeon RX|Radeon Pro|Arc A|Arc B' })
            if (-not $ch.Laptop -and $dgpu.Count -and -not ($dgpu | Where-Object { $_.CurrentHorizontalResolution }) -and ($vc | Where-Object { $_.CurrentHorizontalResolution })) { New-Item2 ((T 'The monitor is connected to the motherboard instead of the graphics card ({0}) – plug the cable into a port of the graphics card, otherwise its performance stays unused') -f $dgpu[0].Name) 0 @{ Stufe = 'warn' } }
            # Devices with an error code (22 = disabled by the user, 45 = not connected)
            $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 -and $_.Name })
            foreach ($d in ($bad | Select-Object -First 5)) { New-Item2 ((T 'Device {0} is not working properly (code {1}) – check in Device Manager, usually the manufacturer''s driver helps') -f $d.Name, $d.ConfigManagerErrorCode) 0 @{ Stufe = 'warn' } }
            # Power plan
            $pmax = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidProcMax
            $pmin = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidProcMin
            $boost = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidBoostMode
            if ($pmax -and $null -ne $pmax.AC -and $pmax.AC -lt 100) { New-Item2 ((T 'The power plan limits the processor to {0} % on mains power – it never works at full performance (often an old tip against heat). Control Panel > Power Options > Processor power management') -f $pmax.AC) 0 @{ Stufe = 'warn' } }
            if ($boost -and $boost.AC -eq 0) { New-Item2 (T 'The processor''s turbo is turned off in the power plan – it works much slower as a result') 0 @{ Stufe = 'warn' } }
            if ($pmin -and $pmin.AC -eq 100 -and $pmin.Schema -eq '381b4222-f694-41f0-9685-ff5bb260df2e') { New-Item2 (T 'In the "Balanced" power plan the processor never clocks down (minimum 100 %) – warmer and louder without a noticeable benefit') 0 @{ Stufe = '' } }
            $plan = (& powercfg.exe /getactivescheme 2>$null) -join ' '
            if ($plan -and $plan -notmatch '381b4222-f694-41f0-9685-ff5bb260df2e|8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|a1841308-3541-4fab-bc81-f71556f20b4a|e9a42b02-d5df-448d-aa00-03f14749eb61') { New-Item2 ((T 'A custom power plan is active: {0}') -f ($plan -replace '^.*\(|\).*$', '')) 0 @{ Stufe = '' } }
            # Intel 13th/14th generation (desktop): microcode level against instability (Vmin shift)
            if ($ch.CpuName -match '(?i)i[579]-1[34]\d{3}(K|KF|KS|F|T)?\b' -and $ch.CpuName -notmatch '(?i)\d{4,5}(H|HX|U|P)\b') {
                $rev = $null; try { $b = [byte[]](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'Update Revision'; if ($b.Count -ge 8) { $rev = [BitConverter]::ToUInt32($b, 4) } } catch { }
                if ($rev -and $rev -lt 0x1000 -and $rev -lt 0x12F) { New-Item2 ((T 'Intel 13th/14th generation processor with old microcode (0x{0:X}) – Intel recommends a BIOS update (at least 0x12F) and the ''Intel Default Settings'' profile to avoid permanent damage') -f $rev) 0 @{ Stufe = 'warn' } }
            }
            # Network
            try {
                $ad = @(Get-NetAdapter -ErrorAction Stop)
                $lan = @($ad | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|TAP|Loopback|WireGuard' })
                foreach ($l in $lan) { if ([int64]$l.Speed -gt 0 -and [int64]$l.Speed -le 100000000) { New-Item2 ((T 'The network cable connection ({0}) only runs at 100 Mbit/s – usually an old or damaged cable or port is to blame') -f $l.InterfaceDescription) 0 @{ Stufe = 'warn' } } }
                $wifi = $ad | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.11|Native 802' }
                $eth = $ad | Where-Object { $_.Status -ne 'Up' -and $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|TAP|Loopback' }
                if ($wifi -and $eth -and -not $lan.Count -and -not $ch.Laptop) { New-Item2 ((T 'The PC is connected via Wi-Fi ({0}) but has a network cable port – if a cable is possible: faster and more stable') -f $wifi[0].LinkSpeed) 0 @{ Stufe = '' } }
            } catch { }
            $raidSvc = Get-CimInstance Win32_SystemDriver -Filter "Name='rcraid' OR Name='iaStorAVC' OR Name='iaStorAC'" -ErrorAction SilentlyContinue | Where-Object State -eq 'Running'
            if ($raidSvc -and -not (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'RAID|Array' })) { New-Item2 ((T 'RAID driver active ({0}), but no RAID array detected – RAID instead of AHCI/NVMe may be set in the BIOS. Only switch with preparation, otherwise Windows no longer starts') -f ($raidSvc.Name -join ', ')) 0 @{ Stufe = '' } }
            # Graphics driver age (only real drivers; the standard driver is reported above)
            if (-not $ch.VM) {
                foreach ($g in @($vc | Where-Object { $_.DriverDate -and $_.Name -notmatch 'Basic Display|Standard-VGA|Microsoft Basic|Remote|Virtual|Parsec|Citrix' -and $_.InfFilename -ne 'display.inf' })) {
                    $dd = $null; try { $dd = [datetime]$g.DriverDate } catch { }
                    if ($dd -and $dd.Year -ge 2000 -and $dd -lt (Get-Date).AddDays(-[int]$Script:Cfg.GpuDriverMaxAgeDays)) { New-Item2 ((T 'The driver of {0} is from {1:yyyy-MM-dd}. Newer drivers from the graphics card maker (for laptops: the laptop maker) often fix bugs and bring more performance in games') -f $g.Name, $dd) 0 @{ Stufe = '' } }
                }
            }
        }
        Fix = $null
    }

    # ---------------------------------------------------------------- Cooling and temperatures (info)
    [pscustomobject]@{ Id = 'HW-COOLING'; Kategorie = 'Hardware'; Titel = (T 'Cooling, fans and temperatures'); Risiko = 'Info'; Wirkung = 'Stabilitaet/Lebensdauer'; Admin = $false; Standard = $true
        Warum = (T 'Components that are too hot get throttled and age faster; stopped or permanently full-speed fans indicate a defect or an unsuitable fan curve in the BIOS. Windows can neither read nor set fan curves - so WinTidy measures the effects (temperatures, throttling, fan speed) and offers a short cooling test.')
        Detect = {
            foreach ($p in (Get-HardwarePoints)) { New-Item2 $p.Text 0 @{ Stufe = $p.Stufe; Bereich = $p.Bereich; Wertung = $p.Wertung } }
            $lt = Get-LastCoolingTest
            if ($lt -and $lt.Zeit) {
                $z = [datetime]$lt.Zeit
                if ($z -gt (Get-Date).AddDays(-60)) {
                    $pt = @($lt.Punkte | Where-Object { $_.Stufe -eq 'krit' }) + @($lt.Punkte | Where-Object { $_.Stufe -eq 'warn' }) + @($lt.Punkte | Where-Object { $_.Stufe -eq 'ok' })
                    if ($pt.Count) { New-Item2 ((T 'Last cooling test ({0:yyyy-MM-dd}{1}): {2}') -f $z, $(if ($lt.Status -eq 'GESTOPPT') { (T ', stopped early') } else { '' }), $pt[0].Text) 0 @{ Stufe = $pt[0].Stufe; Bereich = 'Test' } }
                }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'HW-COOLPOLICY'; Kategorie = 'Hardware'; Titel = (T 'Set the cooling policy on mains power to "Active"'); Risiko = 'Mittel'; Wirkung = 'Leistung/Temperatur'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = (T 'With the "Passive" policy Windows throttles the processor first before the fans speed up. On mains power "Active" (fans first, then throttling) is the Windows default. Only has an effect on devices whose firmware lets Windows take part in cooling (ACPI thermal zones). Can be undone via "Restore".')
        Detect = {
            # Only useful if the firmware offers ACPI active cooling (fan levels via Windows). Desktops and
            # most current laptops control their fans themselves - there the setting would have no effect.
            $aktiv = @(); try { $aktiv = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Where-Object { $_.ActiveTripPointCount -gt 0 }) } catch { }
            if (-not $aktiv.Count) { return }
            $ps = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidSysCoolPol
            if (-not $ps -or $ps.AC -ne 0) { return }
            $it = New-Item2 (T 'Power plan: on mains power Windows throttles the processor before the fans speed up (cooling policy "Passive")') 0 @{ Schema = $ps.Schema; AC = $ps.AC }
            # Windows default on mains power and can be undone: preselected and allowed unattended
            $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue $true
            $it
        }
        Fix = { param($it)
            $null = & powercfg.exe /setacvalueindex $it.Data.Schema $Script:GuidSubProcessor $Script:GuidSysCoolPol 1 2>&1
            if ($LASTEXITCODE -ne 0) { throw (T 'powercfg reports error {0}' $LASTEXITCODE) }
            $akt = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidSysCoolPol
            if ($akt -and $akt.Schema -eq $it.Data.Schema) { $null = & powercfg.exe /setactive $it.Data.Schema 2>&1 }
            Add-ActionRecord 'HW-COOLPOLICY' (T 'Cooling policy (mains power)') 'Undo-Info' 0 '' @{ Typ = 'PowerSetting'; Schema = $it.Data.Schema; Sub = $Script:GuidSubProcessor; Setting = $Script:GuidSysCoolPol; AC = $it.Data.AC } | Out-Null
            (T 'set to Active')
        }
    }

    [pscustomobject]@{ Id = 'HW-DISPLAY'; Kategorie = 'Hardware'; Titel = (T 'Refresh rate of the monitor'); Risiko = 'Info'; Wirkung = 'Bildqualitaet'; Admin = $false; Standard = $true
        Warum = (T 'Fast monitors often run at only 60 Hz after being connected because the higher rate was never selected in Windows. It is compared with what the monitor itself reports (EDID).')
        Detect = {
            $vc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { [int]$_.CurrentRefreshRate -gt 1 -and $_.CurrentHorizontalResolution })
            $modes = @()
            try {
                $modes = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop | ForEach-Object {
                    $inst = $_.InstanceName
                    foreach ($m in @($_.MonitorSourceModes)) { if ($m.VerticalRefreshRateDenominator) { [pscustomobject]@{ Inst = $inst; W = [int]$m.HorizontalActivePixels; H = [int]$m.VerticalActivePixels; Hz = [double]$m.VerticalRefreshRateNumerator / $m.VerticalRefreshRateDenominator } } }
                })
            } catch { }
            $mons = @($modes | Select-Object -ExpandProperty Inst -Unique)
            foreach ($v in $vc) {
                $cur = [int]$v.CurrentRefreshRate
                $txt = (T 'Monitor: {0} × {1} at {2} Hz') -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $cur
                # Only clearly assignable with exactly one monitor
                if ($vc.Count -eq 1 -and $mons.Count -eq 1) {
                    $max = ($modes | Where-Object { $_.W -eq [int]$v.CurrentHorizontalResolution -and $_.H -eq [int]$v.CurrentVerticalResolution } | Measure-Object Hz -Maximum).Maximum
                    if ($max -and [math]::Floor($max) -ge $cur + 5) { New-Item2 ((T '{0} – the monitor supports up to {1:N0} Hz. Set it under Settings > System > Display > Advanced display > Refresh rate') -f $txt, [math]::Floor($max)) 0 @{ Stufe = $(if ((Get-ChassisInfo).Laptop) { '' } else { 'warn' }); Bereich = 'Bildschirm' }; continue }
                }
                New-Item2 $txt 0 @{ Stufe = 'ok'; Bereich = 'Bildschirm' }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'EVT-HEALTH'; Kategorie = 'Stabilitaet'; Titel = (T 'Irregularities in the event log (30 days)'); Risiko = 'Info'; Wirkung = 'Stabilitaet'; Admin = $false; Standard = $true
        Warum = (T 'Unexpected shutdowns, blue screens, hardware errors (WHEA), disk errors and GPU driver resets are warning signs.')
        Detect = {     foreach ($w in (Get-WarningSignals)) { New-Item2 ((T '{0}: {1} times') -f $w.Text, $w.Anzahl) 0 @{ Stufe = 'warn' } } }
        Fix = $null
    }

    # ---------------------------------------------------------------- Debloat (own page in the app; only with -Rule on the command line)
    [pscustomobject]@{ Id = 'DBL-ADS'; Kategorie = 'System'; Seite = 'Debloat'; Titel = (T 'Ads and suggestions in Windows'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $false; Standard = $false; Umkehrbar = $true; Vorwahl = $true
        Warum = (T 'Windows shows suggestions, tips and offers for Microsoft products in Start, Settings and on the lock screen, and installs suggested apps on its own. Only the settings you also find in Windows Settings are changed for your user account.')
        Detect = { Get-DebloatTweakItems 'DBL-ADS' }
        Fix = { param($it) Set-DebloatTweak 'DBL-ADS' $it }
    }

    [pscustomobject]@{ Id = 'DBL-PRIVACY'; Kategorie = 'System'; Seite = 'Debloat'; Titel = (T 'Tracking and personalisation'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $false; Standard = $false; Umkehrbar = $true; Vorwahl = $false
        Warum = (T 'Switches off personalisation and data sharing that Windows offers in Settings > Privacy (advertising ID, tailored ads, speech and typing samples). Not a hardening package: telemetry of Windows itself is not touched.')
        Detect = { Get-DebloatTweakItems 'DBL-PRIVACY' }
        Fix = { param($it) Set-DebloatTweak 'DBL-PRIVACY' $it }
    }

    [pscustomobject]@{ Id = 'DBL-SHELL'; Kategorie = 'System'; Seite = 'Debloat'; Titel = (T 'Start menu and taskbar'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $false; Standard = $false; Umkehrbar = $true; Vorwahl = $false
        Warum = (T 'Removes buttons and web results you may not need. A matter of taste, so nothing is preselected. The taskbar changes appear after signing out and in again (or restarting File Explorer).')
        Detect = { Get-DebloatTweakItems 'DBL-SHELL' }
        Fix = { param($it) Set-DebloatTweak 'DBL-SHELL' $it }
    }

    [pscustomobject]@{ Id = 'DBL-COMFORT'; Kategorie = 'System'; Seite = 'Debloat'; Titel = (T 'Everyday annoyances'); Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $false; Standard = $false; Umkehrbar = $true; Vorwahl = $false
        Warum = (T 'Small settings that many people change right after setting up Windows. A matter of taste, so nothing is preselected.')
        Detect = { Get-DebloatTweakItems 'DBL-COMFORT' }
        Fix = { param($it) Set-DebloatTweak 'DBL-COMFORT' $it }
    }

    [pscustomobject]@{ Id = 'DBL-APPS-PROMO'; Kategorie = 'Programme'; Seite = 'Debloat'; Titel = (T 'Advertising apps from third parties'); Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $false; Endgueltig = $true; Vorwahl = $false
        Warum = (T 'Trial, game and streaming apps that Windows or the PC maker installed. If you installed one yourself and use it, leave it unchecked. Everything can be reinstalled from the Store.')
        Detect = { Get-DebloatAppItems 'PROMO' }
        Fix = { param($it) Remove-DebloatApp $it.Data }
    }

    [pscustomobject]@{ Id = 'DBL-APPS-MS'; Kategorie = 'Programme'; Seite = 'Debloat'; Titel = (T 'Microsoft apps you may never use'); Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $false; Endgueltig = $true; Vorwahl = $false
        Warum = (T 'Preinstalled Microsoft apps such as Bing news and finance, Phone Link or Sticky Notes. Check each one: if you use it, leave it unchecked. Everything can be reinstalled from the Store.')
        Detect = { Get-DebloatAppItems 'MS' }
        Fix = { param($it) Remove-DebloatApp $it.Data }
    }

    [pscustomobject]@{ Id = 'DBL-APPS-OEM'; Kategorie = 'Programme'; Seite = 'Debloat'; Titel = (T 'Apps from the PC maker'); Risiko = 'Hoch'; Wirkung = 'Hygiene'; Admin = $true; Standard = $false; Endgueltig = $true; Einzeln = $true; Vorwahl = $false
        Warum = (T 'Support and "welcome" apps of HP, Dell, Lenovo, Acer, ASUS, MSI, Samsung and LG. Some of them deliver driver, BIOS or warranty functions - remove only what you know you do not need.')
        Detect = { Get-DebloatAppItems 'OEM' }
        Fix = { param($it) Remove-DebloatApp $it.Data }
    }
)

function Get-SelectedRules([switch]$ForApply) {
    $r = $Script:Rules
    if ($Rule) { $r = $r | Where-Object { $Rule -contains $_.Id } }
    else { $r = $r | Where-Object { $_.Standard } }
    if ($ExcludeRule) { $r = $r | Where-Object { $ExcludeRule -notcontains $_.Id } }
    # Company PC: only safe cleanup rules and hints (as in the app)
    if ($Script:CliContext) { $ctx = $Script:CliContext; $r = $r | Where-Object { Test-RuleAllowed $_ $ctx } }
    return @($r)
}

# =============================================================================
#  Snapshot (measurement) and score
# =============================================================================
function Get-Median([double[]]$Values) {
    $s = @($Values | Sort-Object)
    if (-not $s.Count) { return $null }
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2) { return [double]$s[$m] }
    return ([double]$s[$m - 1] + [double]$s[$m]) / 2
}

# Raw idle readings (processor and drive activity of the whole PC in percent). Own function so that tests can replace it.
function Get-IdleCounters {
    $r = [ordered]@{ Cpu = $null; Platte = $null; PlatteOps = $null }
    try { $r.Cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch { }
    try { $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop; $r.Platte = [math]::Min(100.0, [double]$d.PercentDiskTime); $r.PlatteOps = [double]$d.DiskTransfersPersec } catch { }
    [pscustomobject]$r
}

# Idle measurement for the before/after comparison. WinTidy itself (checks, DISM, event log queries) keeps the PC busy, so it first
# waits up to 8 seconds until the processor has calmed down, then takes 6 readings and uses the MEDIAN (single spikes do not count).
# Ruhig = $false if the PC was still busy: processor and drive values are then not reliable for a comparison.
function Get-IdleSample {
    $null = Get-IdleCounters   # warm-up: the first reading of a performance class is often 0
    for ($w = 0; $w -lt 8; $w++) { $c = Get-IdleCounters; if ($null -eq $c.Cpu -or $c.Cpu -le 15) { break }; Start-Sleep -Seconds 1 }
    $cpu = New-Object System.Collections.Generic.List[double]; $dsk = New-Object System.Collections.Generic.List[double]; $ops = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt 6; $i++) {
        $c = Get-IdleCounters
        if ($null -ne $c.Cpu) { $cpu.Add([double]$c.Cpu) }
        if ($null -ne $c.Platte) { $dsk.Add([double]$c.Platte); $ops.Add([double]$c.PlatteOps) }
        Start-Sleep -Milliseconds 700
    }
    $cpuMed = Get-Median $cpu.ToArray(); $dskMed = Get-Median $dsk.ToArray(); $opsMed = Get-Median $ops.ToArray()
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        CpuProzent = $(if ($null -ne $cpuMed) { [math]::Round($cpuMed, 1) } else { $null })
        RamBelegtProzent = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1)
        RamBelegtGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        Prozesse = (Get-Process).Count
        Threads = ((Get-Process | ForEach-Object { $_.Threads.Count }) | Measure-Object -Sum).Sum
        Handles = ((Get-Process | Measure-Object HandleCount -Sum).Sum)
        PlatteProzent = $(if ($null -ne $dskMed) { [math]::Round($dskMed, 1) } else { $null })
        PlatteOpsProSek = $(if ($null -ne $opsMed) { [math]::Round($opsMed, 0) } else { $null })
        Ruhig = [bool]($null -eq $cpuMed -or $cpuMed -le 25)
    }
}

function New-Snapshot([string]$Label = 'scan', [object[]]$Findings) {
    W (T '  Measuring the system (snapshot ''{0}'') ...' $Label) 'DarkGray'
    $os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    # Idle values first: the queries below (event log, scheduled tasks, drivers) keep the PC busy for a while
    $idle = Get-IdleSample
    $boots = @(Get-BootEvents)
    $startup = @(Get-StartupItems)
    $svc = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)
    $since7 = (Get-Date).AddDays(-7)
    $errSys = 0; $errApp = 0; $topErr = @()
    try { $e1 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since7 } -ErrorAction Stop); $errSys = $e1.Count } catch { $e1 = @() }
    try { $e2 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since7 } -ErrorAction Stop); $errApp = $e2.Count } catch { $e2 = @() }
    $topErr = @(($e1 + $e2) | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Quelle = $_.Name; Anzahl = $_.Count } })
    $drv = @(Get-DriverPackages)
    $ghost = 0; try { $ghost = @(Get-GhostDevices).Count } catch { }
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $rbSize = 0; try { $rbSize = ((New-Object -ComObject Shell.Application).Namespace(10).Items() | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum } catch { }
    $secBoot = $null; try { $secBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
    $def = $null; try { $def = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { }
    # Another active antivirus (Security Center, client Windows only): then a disabled Defender is normal
    $av = [bool](@(Get-OtherSecurityProducts 'AntiVirusProduct').Count)
    # UAC and firewall (since 1.9 in the score): a firewall of another product counts as on
    $uacAus = ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA -eq 0)
    $fwAus = $null
    if (@(Get-OtherSecurityProducts 'FirewallProduct').Count) { $fwAus = 0 } else { try { $fwAus = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled }).Count } catch { } }
    $wsi = $null; try { $wsi = Get-WindowsSupportInfo } catch { }
    $hw = $null; try { $hw = Get-HardwareSnapshot } catch { W (T '  Hardware measurement failed: {0}' ($_.Exception.Message)) 'DarkYellow' }
    $brw = $null; try { $brw = [int64]((@(Get-BrowserCacheDirs) | Measure-Object Bytes -Sum).Sum) } catch { }
    $warn = @(); try { $warn = @(Get-WarningSignals | ForEach-Object { [ordered]@{ Text = $_.Text; Anzahl = $_.Anzahl } }) } catch { }
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $snap = [ordered]@{
        Tool = $Script:Version; Label = $Label; Zeit = (Get-Date).ToString('o'); Admin = $Script:IsAdmin
        Computer = $env:COMPUTERNAME; Benutzer = $Script:Me.Name
        System = [ordered]@{ OS = $os.Caption; Build = "$($os.BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR)"; Version = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion; CPU = $cpu.Name.Trim(); Kerne = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors; RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); Board = "$($cs.Manufacturer) $($cs.Model)"; BIOS = "$($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') }))"; LetzterStart = Iso $os.LastBootUpTime; LaufzeitStd = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) }
        Laufwerke = @(Get-VolumeInfo)
        Boot = [ordered]@{ Verlauf = $boots; Mittel5 = $(if ($boots.Count) { [int](($boots | Select-Object -First 5 | Measure-Object GesamtMs -Average).Average) } else { $null }); Bremser = @(Get-BootOffenders | Select-Object -First 15) }
        Autostart = [ordered]@{ Gesamt = $startup.Count; Aktiv = @($startup | Where-Object Aktiv).Count; Verwaist = @($startup | Where-Object { $_.Zustand -eq 'fehlt' }).Count; Liste = @($startup | Select-Object Name, Art, Ort, Ziel, Zustand, Aktiv, DegradationMs) }
        Dienste = [ordered]@{ Gesamt = $svc.Count; Laufend = @($svc | Where-Object State -eq 'Running').Count; AutoDrittanbieter = @($svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -and $_.PathName -notmatch '(?i)\\windows\\' }).Count }
        Aufgaben = [ordered]@{ Gesamt = $tasks.Count; Eigene = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }).Count }
        Programme = [ordered]@{ Installiert = @(Get-InstalledApps).Count; StoreApps = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework }).Count }
        Treiber = [ordered]@{ Pakete = $drv.Count; Duplikate = @($drv | Group-Object Orig | Where-Object Count -gt 1 | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum; Geistergeraete = $ghost }
        Ereignisse = [ordered]@{ FehlerSystem7T = $errSys; FehlerAnwendung7T = $errApp; Top = $topErr }
        Leerlauf = $idle
        Speicher = [ordered]@{ PapierkorbBytes = [int64]$rbSize; TempBytes = (Get-DirSize $env:TEMP); CrashDumpsBytes = (Get-DirSize (Join-Path $env:LOCALAPPDATA 'CrashDumps')); BrowserCacheBytes = $brw }
        Sicherheit = [ordered]@{ UacAus = [bool]$uacAus; FirewallProfileAus = $fwAus; SecureBoot = $secBoot; DefenderEchtzeit = $def; AndererVirenschutz = $av; AusfuehrungsrichtlinieCU = "$(Get-ExecutionPolicy -Scope CurrentUser)"; WindowsSupportEnde = $(if ($wsi -and $wsi.Ende) { $wsi.Ende.ToString('yyyy-MM-dd') } else { $null }); TageSeitUpdate = $(if ($wsi) { $wsi.TageSeitUpdate } else { $null }); WindowsUpdateAus = $(if ($wsi) { $wsi.WuDeaktiviert } else { $null }) }
        Hardware = $hw
        Stabilitaet = [ordered]@{ Warnsignale = $warn }
        Befunde = @()
    }
    if ($Findings) { $snap.Befunde = @($Findings | ForEach-Object { [ordered]@{ Regel = $_.Regel; Kategorie = $_.Kategorie; Titel = $_.Titel; Risiko = $_.Risiko; Anzahl = $_.Anzahl; Bytes = $_.Bytes; Objekte = @($_.Objekte | Select-Object -First 50); Stufen = @($_.Stufen | Select-Object -First 50); Bereiche = @($_.Bereiche | Select-Object -First 50); Wertungen = @($_.Wertungen | Select-Object -First 50) } }) }
    $snap.Score = Get-HealthScore $snap
    $f = Join-Path $Script:SnapDir ("{0}_{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label)
    $snap | ConvertTo-Json -Depth 7 | Out-File $f -Encoding utf8
    W (T '  Snapshot saved: {0}' $f) 'DarkGray'
    return [pscustomobject]$snap
}

function Get-HealthScore($s) {
    $abz = New-Object System.Collections.Generic.List[object]
    function Abzug($p, $t) { $abz.Add([pscustomobject]@{ Punkte = $p; Grund = $t }) }
    $sys = $s.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    if ($sys) {
        # Percent alone is not enough: on 2 TB, 15 % free (300 GB) is not critical
        $fg = [double]$sys.FreiGB; $fp = [double]$sys.FreiProzent
        if ($fg -lt 10 -or ($fp -lt 10 -and $fg -lt 20)) { Abzug 20 ((T 'Only {0:N0} GB free on the Windows drive') -f $fg) }
        elseif ($fp -lt 15 -and $fg -lt 50) { Abzug 8 ((T 'Only {0:N0} GB free on the Windows drive') -f $fg) }
    }
    $b = $s.Boot.Mittel5; if ($b) { $t = (T 'Windows takes {0:N0} seconds to start on average') -f ($b / 1000); if ($b -gt 90000) { Abzug 15 $t } elseif ($b -gt 60000) { Abzug 10 $t } elseif ($b -gt 40000) { Abzug 5 $t } }
    $a = $s.Autostart.Aktiv; if ($a -gt 15) { Abzug 10 (T '{0} programs start automatically' $a) } elseif ($a -gt 10) { Abzug 5 (T '{0} programs start automatically' $a) }
    if ($s.Autostart.Verwaist -gt 0) { Abzug ([math]::Min(5, $s.Autostart.Verwaist)) (T '{0} broken startup entries' ($s.Autostart.Verwaist)) }
    $e = $s.Ereignisse.FehlerSystem7T + $s.Ereignisse.FehlerAnwendung7T; if ($e -gt 200) { Abzug 5 (T 'Many error messages from Windows in the last 7 days ({0})' $e) } elseif ($e -gt 50) { Abzug 3 (T 'Many error messages from Windows in the last 7 days ({0})' $e) }
    if ($s.Treiber.Duplikate -gt 10) { Abzug 3 (T '{0} old driver versions' ($s.Treiber.Duplikate)) }
    if ($s.Treiber.Geistergeraete -gt 50) { Abzug 2 (T '{0} old device entries' ($s.Treiber.Geistergeraete)) }
    # Secure Boot: only a small deduction - WinTidy itself advises non-experts not to switch it on themselves
    if ($s.Sicherheit.SecureBoot -eq $false) { Abzug 4 (T 'Secure Boot (boot protection) is off') }
    if ($s.Sicherheit.UacAus -eq $true) { Abzug 8 (T 'User Account Control is turned off') }
    if ($s.Sicherheit.FirewallProfileAus -gt 0) { Abzug 10 (T 'The firewall is turned off') }
    if ($s.Sicherheit.DefenderEchtzeit -eq $false -and -not $s.Sicherheit.AndererVirenschutz) { Abzug 15 (T 'No active antivirus') }
    if ($s.Sicherheit.AusfuehrungsrichtlinieCU -in 'Unrestricted', 'Bypass') { Abzug 3 (T 'Protection setting for scripts is turned off') }
    if ($s.Sicherheit.WindowsSupportEnde) { try { if ([datetime]::ParseExact([string]$s.Sicherheit.WindowsSupportEnde, 'yyyy-MM-dd', $null) -lt [datetime]$s.Zeit) { Abzug 20 (T 'This Windows version no longer receives security updates') } } catch { } }
    if ($s.Sicherheit.WindowsUpdateAus) { Abzug 15 (T 'Windows Update is turned off') }
    elseif ($s.Sicherheit.TageSeitUpdate -gt 40) { Abzug 10 (T 'No Windows updates installed for {0} days' ($s.Sicherheit.TageSeitUpdate)) }
    if ($s.Speicher.PapierkorbBytes -gt 5GB) { Abzug 2 (T 'Recycle bin larger than 5 GB') }
    # Warning signs: new snapshots measure them themselves (comparable before/after), old ones only via the findings
    $nWarn = 0
    if ($null -ne $s.Stabilitaet) { $nWarn = @($s.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }
    else { foreach ($bf in @($s.Befunde)) { if ($bf.Regel -eq 'EVT-HEALTH') { $nWarn += [int]$bf.Anzahl } } }
    if ($nWarn -gt 0) { Abzug ([math]::Min(10, 2 * $nWarn)) (T 'Warning messages from Windows (e.g. crashes) in the last 30 days') }
    if ($s.Hardware) {
        # Only permanent states (drive, battery, memory errors ...), no snapshots such as the current temperature
        $hp = @($s.Hardware.Punkte | Where-Object { $_ -and $_.Wertung -ne 'moment' })
        $nk = @($hp | Where-Object { $_.Stufe -eq 'krit' }).Count; $nw = @($hp | Where-Object { $_.Stufe -eq 'warn' }).Count
        if ($nk) { Abzug ([math]::Min(10, 5 * $nk)) (T 'Hardware: important warnings (drives, memory, cooling, battery)') }
        if ($nw) { Abzug ([math]::Min(3, $nw)) (T 'Hardware: irregularities (drives, fans, graphics card)') }
    }
    $sum = ($abz | Measure-Object Punkte -Sum).Sum; if (-not $sum) { $sum = 0 }
    [ordered]@{ Wert = [int][math]::Max(0, 100 - $sum); Abzuege = $abz.ToArray() }
}

# =============================================================================
#  Running rules
# =============================================================================
function Invoke-Rules([bool]$Apply) {
    $Script:Preview = -not $Apply
    $rules = Get-SelectedRules -ForApply:$Apply
    # Measure hardware first while the PC is still idle (DISM, winget etc. heat up the CPU)
    try { $null = Get-HardwarePoints } catch { }
    $findings = New-Object System.Collections.Generic.List[object]
    $total = 0; $done = 0; $failed = 0; $skipped = 0; $bytes = 0
    $i = 0
    foreach ($r in $rules) {
        $i++
        Sub ((T '[{0}/{1}] {2}  {3}  (risk: {4})') -f $i, $rules.Count, $r.Id, $r.Titel, (Get-RiskText $r.Risiko))
        if ($r.Admin -and -not $Script:IsAdmin) { W (T '    skipped: needs admin rights') 'DarkYellow'; continue }
        $items = @()
        try { $items = @(& $r.Detect | Where-Object { $_ }) } catch { W (T '    Error during the check: {0}' ($_.Exception.Message)) 'Red'; continue }
        if (-not $items.Count) { W (T '    ok - nothing found') 'Green'; continue }
        $sum = ($items | Measure-Object Bytes -Sum).Sum
        $findings.Add([pscustomobject]@{ Regel = $r.Id; Kategorie = $r.Kategorie; Titel = $r.Titel; Risiko = $r.Risiko; Anzahl = $items.Count; Bytes = [int64]$sum; Objekte = @($items | ForEach-Object { $_.Label }); Stufen = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary] -and $_.Data.Stufe) { [string]$_.Data.Stufe } else { '' } }); Bereiche = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary]) { [string]$_.Data.Bereich } else { '' } }); Wertungen = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary]) { [string]$_.Data.Wertung } else { '' } }) })
        W ((T '    {0} finding(s){1}') -f $items.Count, $(if ($sum) { (T ', approx. ') + (Fmt-Bytes $sum) } else { '' })) 'Yellow'
        W (T '    Why: {0}' ($r.Warum)) 'DarkGray'
        foreach ($it in $items) { W ("      - {0}{1}" -f $it.Label, $(if ($it.Bytes) { "  [$(Fmt-Bytes $it.Bytes)]" } else { '' })) 'Gray' }
        if (-not $Apply -or -not $r.Fix) { continue }
        # Unattended only what the rule itself allows (AutoOk), e.g. Windows.old only after the waiting period.
        # Medium needs an explicit AutoOk = $true (fail closed), otherwise -IncludeMedium would apply everything.
        if ($Yes) { $r0 = $r; $items = @($items | Where-Object { Test-UnattendedItem $r0 $_ }) }
        $Script:AllYes = $false
        try {
            if ($r.Risiko -eq 'Niedrig' -and -not $Yes) { if (-not (Confirm-Item ((T 'Run rule {0} for all {1} items?') -f $r.Id, $items.Count) 'Niedrig')) { $skipped += $items.Count; foreach ($it in $items) { Add-ActionRecord $r.Id $it.Label 'Uebersprungen' | Out-Null }; continue }; $Script:AllYes = $true }
            foreach ($it in $items) {
                $total++
                $ok = if ($r.Risiko -eq 'Niedrig' -and ($Script:AllYes -or $Yes)) { $true } else { Confirm-Item ("-> {0}" -f $it.Label) $r.Risiko }
                if (-not $ok) { $skipped++; Add-ActionRecord $r.Id $it.Label 'Uebersprungen' | Out-Null; continue }
                try {
                    $msg = & $r.Fix $it
                    $done++; $bytes += $it.Bytes
                    W ("      OK  {0}  {1}" -f $it.Label, $msg) 'Green'
                    Add-ActionRecord $r.Id $it.Label 'OK' $it.Bytes ([string]$msg) | Out-Null
                } catch {
                    $em = $_.Exception.Message
                    if ($em -like 'SKIP:*') { $skipped++; W ((T '      skipped  {0}: {1}') -f $it.Label, $em.Substring(5)) 'DarkYellow'; Add-ActionRecord $r.Id $it.Label 'Uebersprungen' 0 $em.Substring(5) | Out-Null; continue }
                    $failed++
                    W ((T '      ERROR  {0}: {1}') -f $it.Label, $em) 'Red'
                    Add-ActionRecord $r.Id $it.Label 'Fehler' 0 $em | Out-Null
                }
            }
        } catch {
            if ($_.Exception.Message -eq 'SKIPRULE') { W (T '    Rule skipped') 'DarkYellow'; Add-ActionRecord $r.Id (T '(rule)') 'Uebersprungen' | Out-Null } else { throw }
        }
    }
    return [pscustomobject]@{ Befunde = $findings.ToArray(); Aktionen = $total; OK = $done; Fehler = $failed; Uebersprungen = $skipped; Bytes = $bytes }
}

# Creates a restore point. Returns $null (success) or the error message.
# Enable-ComputerRestore only as a last resort: it resets the storage limit for shadow copies to the default.
function Invoke-Checkpoint {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $altFreq = (Get-ItemProperty $k -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord -ErrorAction SilentlyContinue
    try {
        try { Checkpoint-Computer -Description "WinTidy $Script:RunId" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
        catch { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; $Script:ComputerschutzEingeschaltet = $true; Checkpoint-Computer -Description "WinTidy $Script:RunId" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
        return $null
    } catch { return $_.Exception.Message }
    finally { if ($null -ne $altFreq) { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $altFreq -Type DWord -ErrorAction SilentlyContinue } else { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue } }
}

function New-RestorePoint {
    if ($NoRestorePoint) { return }
    W (T '  Creating restore point ...') 'DarkGray'
    $err = Invoke-Checkpoint
    if (-not $err) { W (T '  Restore point created.') 'Green'; Add-ActionRecord 'CORE' (T 'Restore point') 'OK' | Out-Null; return }
    W (T '  Restore point failed: {0}' $err) 'Red'
    Add-ActionRecord 'CORE' (T 'Restore point') 'Fehler' 0 $err | Out-Null
    if (-not $Yes) { $a = Read-Host (T '  Continue anyway? [y/N]'); if ($a -notmatch '^(j|ja|y|yes)$') { throw (T 'Cancelled by the user') } } else { throw (T 'No restore point - cancelled (can be forced with -NoRestorePoint)') }
}

# =============================================================================
#  Comparison
# =============================================================================
function Get-Snapshots { @(Get-ChildItem $Script:SnapDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name) }
function Read-Snapshot($f) { Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-CompareMetrics($a, $b) {
    # $tol = measurement noise: a change up to this size counts as "unchanged" (e.g. idle CPU 1.2 % -> 1.4 %)
    function M($id, $name, $va, $vb, $unit, $better, $tol = 0) {
        $d = $null; if ($null -ne $va -and $null -ne $vb) { $d = [math]::Round([double]$vb - [double]$va, 2) }
        $verdict = '='; if ($d -and [math]::Abs($d) -gt $tol) { if (($better -eq 'lower' -and $d -lt 0) -or ($better -eq 'higher' -and $d -gt 0)) { $verdict = 'besser' } else { $verdict = 'schlechter' } }
        [pscustomobject]@{ Id = $id; Kennzahl = $name; Vorher = $va; Nachher = $vb; Delta = $d; Einheit = $unit; Bewertung = $verdict }
    }
    $bootA = $null; if ($a.Boot.Mittel5) { $bootA = [math]::Round($a.Boot.Mittel5 / 1000, 1) }
    $bootB = $null; if ($b.Boot.Mittel5) { $bootB = [math]::Round($b.Boot.Mittel5 / 1000, 1) }
    $warnA = $null; if ($null -ne $a.Stabilitaet) { $warnA = @($a.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }
    $warnB = $null; if ($null -ne $b.Stabilitaet) { $warnB = @($b.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }
    $hwA = $null; if ($a.Hardware) { $hwA = @($a.Hardware.Punkte | Where-Object { $_ }).Count }
    $hwB = $null; if ($b.Hardware) { $hwB = @($b.Hardware.Punkte | Where-Object { $_ }).Count }
    $sysA = $a.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    $sysB = $b.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    $freeA = ($a.Laufwerke | Measure-Object FreiGB -Sum).Sum; $freeB = ($b.Laufwerke | Measure-Object FreiGB -Sum).Sum
    # Storage measured by the snapshot itself (MB; old snapshots without the field show no delta)
    $mb = { param($s, $n) if ($s -and $s.Speicher -and $null -ne $s.Speicher.$n) { [math]::Round([double]$s.Speicher.$n / 1MB, 0) } else { $null } }
    @(
        (M 'Score' (T 'Health score') $a.Score.Wert $b.Score.Wert 'Punkte' 'higher'),
        (M 'BootGesamt' (T 'Start Ø last 5 boots') $bootA $bootB 's' 'lower' 2),
        (M 'BootNach' (T 'Waiting time after the desktop appears') (Get-PerfValue $a 'BootNach') (Get-PerfValue $b 'BootNach') 's' 'lower' 1.5),
        (M 'Frei' (T 'Free on {0}' $env:SystemDrive) $sysA.FreiGB $sysB.FreiGB 'GB' 'higher'),
        (M 'FreiGesamt' (T 'Free total (fixed drives)') ([math]::Round($freeA, 1)) ([math]::Round($freeB, 1)) 'GB' 'higher'),
        (M 'Temp' (T 'Temporary files (own temp folder)') (& $mb $a 'TempBytes') (& $mb $b 'TempBytes') 'MB' 'lower'),
        (M 'Papierkorb' (T 'Recycle bin') (& $mb $a 'PapierkorbBytes') (& $mb $b 'PapierkorbBytes') 'MB' 'lower'),
        (M 'Absturzberichte' (T 'Crash reports of programs') (& $mb $a 'CrashDumpsBytes') (& $mb $b 'CrashDumpsBytes') 'MB' 'lower'),
        (M 'BrowserCache' (T 'Browser caches') (& $mb $a 'BrowserCacheBytes') (& $mb $b 'BrowserCacheBytes') 'MB' 'lower'),
        (M 'Autostart' (T 'Active startup programs') $a.Autostart.Aktiv $b.Autostart.Aktiv '' 'lower'),
        (M 'AutostartVerwaist' (T 'Orphaned startup entries') $a.Autostart.Verwaist $b.Autostart.Verwaist '' 'lower'),
        (M 'Dienste' (T 'Running services') $a.Dienste.Laufend $b.Dienste.Laufend '' 'lower'),
        (M 'DiensteDritt' (T 'Third-party auto-start services') $a.Dienste.AutoDrittanbieter $b.Dienste.AutoDrittanbieter '' 'lower'),
        (M 'Prozesse' (T 'Processes at idle') $a.Leerlauf.Prozesse $b.Leerlauf.Prozesse '' 'lower' 3),
        (M 'Threads' (T 'Threads at idle') $a.Leerlauf.Threads $b.Leerlauf.Threads '' 'lower' 150),
        (M 'Ram' (T 'RAM used at idle') $a.Leerlauf.RamBelegtGB $b.Leerlauf.RamBelegtGB 'GB' 'lower' 0.2),
        (M 'Cpu' (T 'CPU at idle') $a.Leerlauf.CpuProzent $b.Leerlauf.CpuProzent '%' 'lower' 1.5),
        (M 'Platte' (T 'Drive activity at idle') $a.Leerlauf.PlatteProzent $b.Leerlauf.PlatteProzent '%' 'lower' 3),
        (M 'Treiberpakete' (T 'Driver packages') $a.Treiber.Pakete $b.Treiber.Pakete '' 'lower'),
        (M 'TreiberDuplikate' (T 'Old driver duplicates') $a.Treiber.Duplikate $b.Treiber.Duplikate '' 'lower'),
        (M 'Geistergeraete' (T 'Ghost devices') $a.Treiber.Geistergeraete $b.Treiber.Geistergeraete '' 'lower'),
        (M 'FehlerSystem' (T 'Errors system log (7 days)') $a.Ereignisse.FehlerSystem7T $b.Ereignisse.FehlerSystem7T '' 'lower'),
        (M 'FehlerAnwendung' (T 'Errors application log (7 days)') $a.Ereignisse.FehlerAnwendung7T $b.Ereignisse.FehlerAnwendung7T '' 'lower'),
        (M 'Programme' (T 'Installed programs') $a.Programme.Installiert $b.Programme.Installiert '' 'lower'),
        (M 'StoreApps' (T 'Store apps') $a.Programme.StoreApps $b.Programme.StoreApps '' 'lower'),
        (M 'Aufgaben' (T 'Own scheduled tasks') $a.Aufgaben.Eigene $b.Aufgaben.Eigene '' 'lower'),
        (M 'Warnsignale' (T 'Warning signs (event log, 30 days)') $warnA $warnB '' 'lower'),
        (M 'Hardware' (T 'Hardware irregularities') $hwA $hwB '' 'lower')
    )
}
# =============================================================================
#  Performance key figures: did WinTidy bring something?
#  Eight figures that Windows or WinTidy measure themselves and that a cleanup can really influence. Each one has a noise
#  tolerance (a change inside it counts as "unchanged"). Start times are only compared with starts AFTER the optimization.
# =============================================================================
function Get-PerfDefs {
    # Id = internal, Abs/Rel = tolerance (absolute / share of the old value), Boot = comes from the boot events,
    # Ruhe = only reliable if the PC was idle during the measurement
    @(
        [pscustomobject]@{ Id = 'BootGesamt'; Titel = (T 'Windows start until ready'); Hinweis = (T 'Time from switching on until Windows is ready to use (average of the last 5 starts). Windows measures it at every start.'); Einheit = 's'; Stellen = 1; Besser = 'lower'; Abs = 2; Rel = 0.05; Boot = $true; Ruhe = $false }
        [pscustomobject]@{ Id = 'BootNach'; Titel = (T 'Waiting time after the desktop appears'); Hinweis = (T 'How long Windows keeps loading programs and services in the background after the desktop is visible. This is where startup programs cost time.'); Einheit = 's'; Stellen = 1; Besser = 'lower'; Abs = 1.5; Rel = 0.1; Boot = $true; Ruhe = $false }
        [pscustomobject]@{ Id = 'Autostart'; Titel = (T 'Programs starting with Windows'); Hinweis = (T 'Programs that start automatically with Windows and use memory and processor time right from the start.'); Einheit = ''; Stellen = 0; Besser = 'lower'; Abs = 0; Rel = 0; Boot = $false; Ruhe = $false }
        [pscustomobject]@{ Id = 'Prozesse'; Titel = (T 'Background processes at idle'); Hinweis = (T 'Programs and services running while you do nothing. Fewer means more room for the things you actually use.'); Einheit = ''; Stellen = 0; Besser = 'lower'; Abs = 3; Rel = 0; Boot = $false; Ruhe = $false }
        [pscustomobject]@{ Id = 'Ram'; Titel = (T 'Memory in use at idle'); Hinweis = (T 'Working memory (RAM) used while the PC is idle. Less leaves more for your programs.'); Einheit = 'GB'; Stellen = 1; Besser = 'lower'; Abs = 0.2; Rel = 0.03; Boot = $false; Ruhe = $false }
        [pscustomobject]@{ Id = 'Cpu'; Titel = (T 'Processor load at idle'); Hinweis = (T 'How busy the processor is while you do nothing. High values mean something keeps working in the background.'); Einheit = '%'; Stellen = 1; Besser = 'lower'; Abs = 1.5; Rel = 0; Boot = $false; Ruhe = $true }
        [pscustomobject]@{ Id = 'Platte'; Titel = (T 'Drive activity at idle'); Hinweis = (T 'How busy the drives are while you do nothing. Constant activity makes everything else feel slower.'); Einheit = '%'; Stellen = 1; Besser = 'lower'; Abs = 3; Rel = 0; Boot = $false; Ruhe = $true }
        [pscustomobject]@{ Id = 'Frei'; Titel = (T 'Free space on the Windows drive'); Hinweis = (T 'Windows needs free space for updates and temporary files. A nearly full drive slows Windows down.'); Einheit = 'GB'; Stellen = 1; Besser = 'higher'; Abs = 0.5; Rel = 0; Boot = $false; Ruhe = $false }
    )
}

function ConvertTo-PerfNum($Value, [int]$Digits = 1) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [math]::Round([double]$Value, $Digits) } catch { return $null }
}

# Average of one property over the newest N boots (boots in any order); Anzahl = how many boots were used
function Get-BootAvg($Boots, [string]$Prop, [int]$N = 5) {
    $v = @($Boots | Where-Object { $_ -and [double]$_.$Prop -gt 0 } | Sort-Object { [datetime]$_.Zeit } -Descending | Select-Object -First $N | ForEach-Object { [double]$_.$Prop })
    $avg = $null; if ($v.Count) { $avg = ($v | Measure-Object -Average).Average }
    [pscustomobject]@{ Anzahl = $v.Count; Mittel = $avg }
}

# Value of one key figure from a snapshot ($null if the snapshot does not have it, e.g. older versions)
function Get-PerfValue($s, [string]$Id) {
    if (-not $s) { return $null }
    $idle = $s.Leerlauf
    switch ($Id) {
        'BootGesamt' { if ($s.Boot -and $s.Boot.Mittel5) { return (ConvertTo-PerfNum ([double]$s.Boot.Mittel5 / 1000) 1) }; return $null }
        'BootNach' { if (-not $s.Boot) { return $null }; $a = Get-BootAvg @($s.Boot.Verlauf) 'NachDesktopMs' 5; if ($a.Anzahl) { return (ConvertTo-PerfNum ($a.Mittel / 1000) 1) }; return $null }
        'Autostart' { if ($s.Autostart) { return (ConvertTo-PerfNum $s.Autostart.Aktiv 0) }; return $null }
        'Prozesse' { if ($idle) { return (ConvertTo-PerfNum $idle.Prozesse 0) }; return $null }
        'Ram' { if ($idle) { return (ConvertTo-PerfNum $idle.RamBelegtGB 1) }; return $null }
        'Cpu' { if ($idle) { return (ConvertTo-PerfNum $idle.CpuProzent 1) }; return $null }
        'Platte' { if ($idle) { return (ConvertTo-PerfNum $idle.PlatteProzent 1) }; return $null }
        'Frei' { $sys = @($s.Laufwerke) | Where-Object { $_ -and $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1; if ($sys) { return (ConvertTo-PerfNum $sys.FreiGB 1) }; return $null }
    }
    return $null
}

# One point in time of the history: all key figures of a snapshot
function Get-PerfPoint($s) {
    $w = [ordered]@{}
    foreach ($d in (Get-PerfDefs)) { $w[$d.Id] = Get-PerfValue $s $d.Id }
    $calm = $true; if ($s.Leerlauf -and $s.Leerlauf.Ruhig -eq $false) { $calm = $false }
    [pscustomobject]@{ Zeit = ([datetime]$s.Zeit).ToString('o'); Label = [string]$s.Label; Ruhig = $calm; Werte = [pscustomobject]$w }
}

# Compares the state before the first optimization ($base) with the current state ($cur).
# $boots = all known boot events: start times are only taken from starts AFTER $base (at least 2), because a start right
# after the optimization still shows the old state. Without such starts the two start figures are 'offen' (open).
# Bewertung: 'besser' | 'schlechter' | '=' (inside the noise tolerance) | 'offen' (not measurable yet)
function Get-PerfEffect($base, $cur, $boots) {
    if (-not $base -or -not $cur) { return $null }
    $tBase = [datetime]$base.Zeit
    $after = @($boots | Where-Object { $_ -and [double]$_.GesamtMs -gt 0 -and [datetime]$_.Zeit -gt $tBase })
    $busy = [bool](($base.Leerlauf -and $base.Leerlauf.Ruhig -eq $false) -or ($cur.Leerlauf -and $cur.Leerlauf.Ruhig -eq $false))
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($d in (Get-PerfDefs)) {
        $vb = Get-PerfValue $base $d.Id
        $vc = $null
        if ($d.Boot) {
            $prop = 'GesamtMs'; if ($d.Id -eq 'BootNach') { $prop = 'NachDesktopMs' }
            $avg = Get-BootAvg $after $prop 5
            if ($avg.Anzahl -ge 2) { $vc = ConvertTo-PerfNum ($avg.Mittel / 1000) 1 }
        } else { $vc = Get-PerfValue $cur $d.Id }
        $delta = $null; $bew = 'offen'; $unsure = $false
        if ($null -ne $vb -and $null -ne $vc) {
            $delta = [math]::Round([double]$vc - [double]$vb, 2)
            $tol = [math]::Max([double]$d.Abs, [double]$d.Rel * [math]::Abs([double]$vb))
            if ([math]::Abs($delta) -le $tol) { $bew = '=' }
            elseif (($d.Besser -eq 'lower' -and $delta -lt 0) -or ($d.Besser -eq 'higher' -and $delta -gt 0)) { $bew = 'besser' }
            else { $bew = 'schlechter' }
            # Processor and drive values from a PC that was still busy are not a reliable basis for a verdict
            if ($d.Ruhe -and $busy -and $bew -ne '=') { $bew = '='; $unsure = $true }
        }
        $dtxt = ''; if ($null -ne $delta) { $dtxt = ('{0:+0.0;-0.0;0.0}' -f [double]$delta) + $(if ($d.Einheit) { ' ' + $d.Einheit } else { '' }) }
        $rows.Add([pscustomobject]@{ Id = $d.Id; Kennzahl = $d.Titel; Hinweis = $d.Hinweis; Einheit = $d.Einheit; Stellen = $d.Stellen; Vorher = $vb; Nachher = $vc; Delta = $delta; Bewertung = $bew; Unsicher = $unsure
            VorherText = (Format-PerfValue $vb $d.Stellen $d.Einheit); NachherText = (Format-PerfValue $vc $d.Stellen $d.Einheit); DeltaText = $dtxt; BewertungText = (Get-PerfRatingText $bew) })
    }
    $nb = @($rows | Where-Object { $_.Bewertung -eq 'besser' }).Count
    $ns = @($rows | Where-Object { $_.Bewertung -eq 'schlechter' }).Count
    $ng = @($rows | Where-Object { $_.Bewertung -eq '=' }).Count
    $no = @($rows | Where-Object { $_.Bewertung -eq 'offen' }).Count
    $urteil = 'offen'
    if ($nb + $ns + $ng) { if ($nb -and $ns) { $urteil = 'gemischt' } elseif ($nb) { $urteil = 'besser' } elseif ($ns) { $urteil = 'schlechter' } else { $urteil = 'gleich' } }
    $res = [pscustomobject]@{ Basis = ([datetime]$base.Zeit).ToString('o'); Jetzt = ([datetime]$cur.Zeit).ToString('o'); BootsDanach = $after.Count; Metriken = $rows.ToArray(); Besser = $nb; Schlechter = $ns; Gleich = $ng; Offen = $no; Gemessen = ($nb + $ns + $ng); Urteil = $urteil; Kopfzeile = ''; BootHinweis = '' }
    # Ready-made texts for the app and the report (the engine knows the language)
    $res.Kopfzeile = Get-PerfHeadline $res
    $res.BootHinweis = Get-PerfBootNote $res
    return $res
}

# The one-sentence answer to "did it bring something?" (translated)
function Get-PerfHeadline($e) {
    if (-not $e) { return (T 'Not enough data yet. After your first optimization WinTidy shows here whether it brought something.') }
    $date = ([datetime]$e.Basis).ToString((T 'yyyy-MM-dd'))
    switch ($e.Urteil) {
        'besser' { return (T 'WinTidy helped: {0} of {1} measured key figures improved since the optimization on {2}, none got worse.' $e.Besser $e.Gemessen $date) }
        'gemischt' { return (T 'Mixed result since the optimization on {2}: {0} key figures improved, {1} got worse.' $e.Besser $e.Schlechter $date) }
        'schlechter' { return (T 'No improvement since the optimization on {1}: {0} key figures got worse. Often this is only because more programs are running right now - check again after a restart.' $e.Schlechter $date) }
        'gleich' { return (T 'No measurable change since the optimization on {0}.' $date) }
    }
    return (T 'Not measurable yet. Restart the PC a few times and check again - Windows records the start time at every start.')
}

# Note on the two start-time figures (empty if there is nothing to say)
function Get-PerfBootNote($e) {
    if (-not $e) { return '' }
    if ($e.BootsDanach -lt 2) { return (T 'Start times need at least 2 starts after the optimization (so far: {0}). Use the PC normally and check again in a few days.' $e.BootsDanach) }
    return (T 'Start times are compared over the starts since the optimization ({0} so far).' $e.BootsDanach)
}

function Format-PerfValue($v, [int]$Digits, [string]$Unit) {
    if ($null -eq $v) { return '-' }
    return ((('{0:N' + $Digits + '}') -f [double]$v) + $(if ($Unit) { ' ' + $Unit } else { '' }))
}

# Display text of a rating in the report/CLI
function Get-PerfRatingText([string]$Rating) { switch ($Rating) { 'besser' { return (T 'better') } 'schlechter' { return (T 'worse') } '=' { return (T 'unchanged') } }; return (T 'not measurable yet') }

function Show-PerfEffect($e) {
    Section (T 'Did WinTidy help?')
    W ('  ' + (Get-PerfHeadline $e)) $(switch ($(if ($e) { $e.Urteil } else { '' })) { 'besser' { 'Green' } 'schlechter' { 'Red' } 'gemischt' { 'Yellow' } default { 'Gray' } })
    if (-not $e) { return }
    W ("  {0,-40} {1,12} {2,12}  {3}" -f (T 'Key figure'), (T 'Before'), (T 'Now'), (T 'Rating')) 'White'
    foreach ($m in $e.Metriken) {
        $c = switch ($m.Bewertung) { 'besser' { 'Green' } 'schlechter' { 'Red' } default { 'Gray' } }
        W ("  {0,-40} {1,12} {2,12}  {3}{4}" -f $m.Kennzahl, $m.VorherText, $m.NachherText, $m.BewertungText, $(if ($m.Unsicher) { ' ' + (T '(PC was busy while measuring)') } else { '' })) $c
    }
    $n = Get-PerfBootNote $e; if ($n) { W ('  ' + $n) 'DarkYellow' }
}

# Reads all snapshots once: scores, key figures per point in time, all boot events and the effect since the first optimization
function Read-SnapshotHistory {
    $scores = @(); $punkte = @(); $boots = @(); $seen = @{}; $first = $null; $last = $null
    foreach ($f in (Get-Snapshots)) {
        $s = $null; try { $s = Read-Snapshot $f } catch { continue }
        $scores += [pscustomobject]@{ Zeit = $s.Zeit; Label = $s.Label; Wert = $s.Score.Wert }
        $punkte += Get-PerfPoint $s
        foreach ($b in @($s.Boot.Verlauf)) { if ($b -and -not $seen.ContainsKey($b.Zeit)) { $seen[$b.Zeit] = 1; $boots += $b } }
        if (-not $first -and $s.Label -eq 'vorher') { $first = $s }
        $last = $s
    }
    $boots = @($boots | Sort-Object { [datetime]$_.Zeit })
    $effekt = $null
    if ($first -and $last -and $first.Zeit -ne $last.Zeit) { $effekt = Get-PerfEffect $first $last $boots }
    [pscustomobject]@{ Scores = $scores; Punkte = $punkte; Boots = $boots; Effekt = $effekt; Defs = @(Get-PerfDefs); Kopfzeile = (Get-PerfHeadline $effekt) }
}

function Show-Compare($a, $b) {
    Section ((T 'Comparison  {0} ({1})  ->  {2} ({3})') -f ([datetime]$a.Zeit).ToString((T 'MM-dd HH:mm')), $a.Label, ([datetime]$b.Zeit).ToString((T 'MM-dd HH:mm')), $b.Label)
    W ("  {0,-34} {1,12} {2,12} {3,12}" -f (T 'Metric'), (T 'Before'), (T 'After'), 'Delta') 'White'
    foreach ($m in (Get-CompareMetrics $a $b)) {
        $c = switch ($m.Bewertung) { 'besser' { 'Green' } 'schlechter' { 'Red' } default { 'Gray' } }
        $d = if ($null -eq $m.Delta) { '' } elseif ($m.Delta -gt 0) { "+$($m.Delta)" } else { "$($m.Delta)" }
        W ("  {0,-34} {1,12} {2,12} {3,12} {4}" -f $m.Kennzahl, $m.Vorher, $m.Nachher, $d, $m.Einheit) $c
    }
    if ($a.Boot.Mittel5 -and $b.Boot.Mittel5 -and $a.Boot.Mittel5 -eq $b.Boot.Mittel5) { W (T '  Note: boot times are only meaningful after 2-3 restarts (then run "Scan" again).') 'DarkYellow' }
}

# =============================================================================
#  HTML report
# =============================================================================
function New-BootSvg($boots, $runs) {
    $pts = @($boots | Where-Object { $_.GesamtMs -gt 0 } | Sort-Object { [datetime]$_.Zeit })
    if ($pts.Count -lt 2) { return (T '<p class="muted">Not enough boot times yet (admin rights needed, at least 2 boots).</p>') }
    $W = 960; $H = 280; $pl = 50; $pr = 15; $pt = 15; $pb = 35
    $t0 = ([datetime]$pts[0].Zeit).Ticks; $t1 = ([datetime]$pts[-1].Zeit).Ticks; if ($t1 -eq $t0) { $t1 = $t0 + 1 }
    $max = [math]::Ceiling((($pts | Measure-Object GesamtMs -Maximum).Maximum) / 10000) * 10
    $sx = { param($t) $pl + ($W - $pl - $pr) * (($t - $t0) / ($t1 - $t0)) }
    $sy = { param($ms) $pt + ($H - $pt - $pb) * (1 - ($ms / 1000) / $max) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='chart' role='img' aria-label='$(T 'Boot times')'>")
    for ($y = 0; $y -le $max; $y += [math]::Max(10, [math]::Ceiling($max / 50) * 10)) { $yy = & $sy ($y * 1000); [void]$sb.Append("<line x1='$pl' x2='$($W-$pr)' y1='$yy' y2='$yy' class='grid'/><text x='$($pl-6)' y='$($yy+4)' class='ax' text-anchor='end'>$y s</text>") }
    foreach ($r in $runs) { $t = ([datetime]$r.Zeit).Ticks; if ($t -ge $t0 -and $t -le $t1) { $x = & $sx $t; [void]$sb.Append("<line x1='$x' x2='$x' y1='$pt' y2='$($H-$pb)' class='run'/><text x='$($x+4)' y='$($pt+10)' class='runlbl'>$(HtmlEnc $r.Name)</text>") } }
    foreach ($series in @(@{ P = 'HauptpfadMs'; C = 'main' }, @{ P = 'GesamtMs'; C = 'total' })) {
        [void]$sb.Append("<polyline points='$(($pts | ForEach-Object { ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0},{1:0.0}', (& $sx ([datetime]$_.Zeit).Ticks), (& $sy $_.($series.P)))) }) -join ' ')' class='$($series.C)'/>")
    }
    $df = T 'yyyy-MM-dd HH:mm'
    foreach ($p in $pts) { $x = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', (& $sx ([datetime]$p.Zeit).Ticks)); $y = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', (& $sy $p.GesamtMs)); [void]$sb.Append("<circle cx='$x' cy='$y' r='3.5' class='dot'><title>$(HtmlEnc (T '{0}: total {1} s, to desktop {2} s, after that {3} s' ([datetime]$p.Zeit).ToString($df) ([math]::Round($p.GesamtMs / 1000, 1)) ([math]::Round($p.HauptpfadMs / 1000, 1)) ([math]::Round($p.NachDesktopMs / 1000, 1))))</title></circle>") }
    $dax = T 'yy-MM-dd'
    [void]$sb.Append("<text x='$pl' y='$($H-8)' class='ax'>$(([datetime]$pts[0].Zeit).ToString($dax))</text><text x='$($W-$pr)' y='$($H-8)' class='ax' text-anchor='end'>$(([datetime]$pts[-1].Zeit).ToString($dax))</text>")
    [void]$sb.Append("</svg><div class='legend'><span class='lg total'></span>$(HtmlEnc (T 'Total boot')) <span class='lg main'></span>$(HtmlEnc (T 'To desktop')) <span class='lg run'></span>$(HtmlEnc (T 'WinTidy run'))</div>")
    return $sb.ToString()
}
# Small trend chart of one key figure for the report: the line runs through the snapshots (start times: through the boot events),
# dashed green lines mark optimizations. Returns HTML.
function New-PerfSpark($Def, $Points, $Boots, $Runs) {
    $pts = @()
    if ($Def.Boot) {
        $prop = 'GesamtMs'; if ($Def.Id -eq 'BootNach') { $prop = 'NachDesktopMs' }
        $pts = @($Boots | Where-Object { $_ -and [double]$_.$prop -gt 0 } | ForEach-Object { [pscustomobject]@{ T = ([datetime]$_.Zeit).Ticks; V = [double]$_.$prop / 1000; Z = [datetime]$_.Zeit } } | Sort-Object T)
    } else {
        $pts = @($Points | Where-Object { $null -ne $_.Werte.($Def.Id) } | ForEach-Object { [pscustomobject]@{ T = ([datetime]$_.Zeit).Ticks; V = [double]$_.Werte.($Def.Id); Z = [datetime]$_.Zeit } } | Sort-Object T)
    }
    if ($pts.Count -lt 2) { return "<p class='muted'>$(HtmlEnc (T 'Not enough measurements yet.'))</p>" }
    $W = 320; $H = 96; $pl = 44; $pr = 8; $pt = 8; $pb = 8
    $t0 = $pts[0].T; $t1 = $pts[-1].T; if ($t1 -eq $t0) { $t1 = $t0 + 1 }
    $lo = ($pts | Measure-Object V -Minimum).Minimum; $hi = ($pts | Measure-Object V -Maximum).Maximum
    if ($hi -eq $lo) { $lo = [math]::Max(0, $lo - 1); $hi = $hi + 1 }
    $pad = ($hi - $lo) * 0.1; $hi = $hi + $pad; $lo = [math]::Max(0, $lo - $pad)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $sx = { param($t) $pl + ($W - $pl - $pr) * (($t - $t0) / ($t1 - $t0)) }
    $sy = { param($v) $pt + ($H - $pt - $pb) * (1 - ($v - $lo) / ($hi - $lo)) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='chart spark' role='img' aria-label='$(HtmlEnc $Def.Titel)'>")
    foreach ($v in @($hi, $lo)) { $yy = [string]::Format($inv, '{0:0.0}', (& $sy $v)); [void]$sb.Append("<line x1='$pl' x2='$($W-$pr)' y1='$yy' y2='$yy' class='grid'/><text x='$($pl-4)' y='$([string]::Format($inv, '{0:0.0}', ([double]$yy + 4)))' class='ax' text-anchor='end'>$(HtmlEnc (Format-PerfValue $v $Def.Stellen ''))</text>") }
    foreach ($r in $Runs) { $t = ([datetime]$r.Zeit).Ticks; if ($t -ge $t0 -and $t -le $t1) { $x = [string]::Format($inv, '{0:0.0}', (& $sx $t)); [void]$sb.Append("<line x1='$x' x2='$x' y1='$pt' y2='$($H-$pb)' class='run'/>") } }
    [void]$sb.Append("<polyline points='$(($pts | ForEach-Object { [string]::Format($inv, '{0:0.0},{1:0.0}', (& $sx $_.T), (& $sy $_.V)) }) -join ' ')' class='total'/>")
    $df = T 'yyyy-MM-dd HH:mm'
    foreach ($p in $pts) { [void]$sb.Append("<circle cx='$([string]::Format($inv, '{0:0.0}', (& $sx $p.T)))' cy='$([string]::Format($inv, '{0:0.0}', (& $sy $p.V)))' r='2.5' class='dot'><title>$(HtmlEnc ('{0}: {1}' -f $p.Z.ToString($df), (Format-PerfValue $p.V $Def.Stellen $Def.Einheit)))</title></circle>") }
    [void]$sb.Append('</svg>')
    $dax = T 'yy-MM-dd'
    [void]$sb.Append("<div class='muted sparkx'><span>$($pts[0].Z.ToString($dax))</span><span>$($pts[-1].Z.ToString($dax))</span></div>")
    return $sb.ToString()
}

# Trend of the health score for the report: fixed scale 0-100, dashed lines at the rating limits 85/65, one point per snapshot
# (colored by rating), dashed green lines mark optimizations. $Scores = @({ Zeit, Label, Wert }). Returns HTML.
function New-ScoreSvg($Scores, $Runs) {
    $pts = @($Scores | Where-Object { $_ -and $null -ne $_.Wert -and "$($_.Wert)" -ne '' } | ForEach-Object { [pscustomobject]@{ T = ([datetime]$_.Zeit).Ticks; V = [double]$_.Wert; Z = [datetime]$_.Zeit; L = [string]$_.Label } } | Sort-Object T)
    if ($pts.Count -lt 2) { return "<p class='muted'>$(HtmlEnc (T 'Not enough checks yet - the trend appears from the second check on.'))</p>" }
    $W = 960; $H = 220; $pl = 40; $pr = 15; $pt = 12; $pb = 30
    $t0 = $pts[0].T; $t1 = $pts[-1].T; if ($t1 -eq $t0) { $t1 = $t0 + 1 }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $sx = { param($t) $pl + ($W - $pl - $pr) * (($t - $t0) / ($t1 - $t0)) }
    $sy = { param($v) $pt + ($H - $pt - $pb) * (1 - $v / 100) }
    $f = { param($v) [string]::Format($inv, '{0:0.0}', $v) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='chart' role='img' aria-label='$(HtmlEnc (T 'Health score'))'>")
    foreach ($v in 0, 25, 50, 75, 100) { $yy = & $f (& $sy $v); [void]$sb.Append("<line x1='$pl' x2='$($W-$pr)' y1='$yy' y2='$yy' class='grid'/><text x='$($pl-6)' y='$(& $f ([double]$yy + 4))' class='ax' text-anchor='end'>$v</text>") }
    foreach ($lim in @(@{ V = 85; C = 'good' }, @{ V = 65; C = 'mid' })) { $yy = & $f (& $sy $lim.V); [void]$sb.Append("<line x1='$pl' x2='$($W-$pr)' y1='$yy' y2='$yy' class='lim $($lim.C)'/>") }
    foreach ($r in $Runs) { $t = ([datetime]$r.Zeit).Ticks; if ($t -ge $t0 -and $t -le $t1) { $x = & $f (& $sx $t); [void]$sb.Append("<line x1='$x' x2='$x' y1='$pt' y2='$($H-$pb)' class='run'/>") } }
    [void]$sb.Append("<polyline points='$(($pts | ForEach-Object { '{0},{1}' -f (& $f (& $sx $_.T)), (& $f (& $sy $_.V)) }) -join ' ')' class='total'/>")
    $df = T 'yyyy-MM-dd HH:mm'
    foreach ($p in $pts) {
        $cl = if ($p.V -ge 85) { 'good' } elseif ($p.V -ge 65) { 'mid' } else { 'bad' }
        [void]$sb.Append("<circle cx='$(& $f (& $sx $p.T))' cy='$(& $f (& $sy $p.V))' r='4' class='sdot $cl'><title>$(HtmlEnc ('{0} ({1}): {2}' -f $p.Z.ToString($df), (Get-SnapshotLabelText $p.L), [int]$p.V))</title></circle>")
    }
    $dax = T 'yy-MM-dd'
    [void]$sb.Append("<text x='$pl' y='$($H-8)' class='ax'>$($pts[0].Z.ToString($dax))</text><text x='$($W-$pr)' y='$($H-8)' class='ax' text-anchor='end'>$($pts[-1].Z.ToString($dax))</text></svg>")
    [void]$sb.Append("<div class='legend'><span class='lg total'></span>$(HtmlEnc (T 'Health score')) <span class='lg lim'></span>$(HtmlEnc (T 'Rating limits: from 85 good, below 65 needs care')) <span class='lg run'></span>$(HtmlEnc (T 'WinTidy run'))</div>")
    return $sb.ToString()
}

function New-BarRows($rows, [string]$labelProp, [string]$valueProp, [scriptblock]$fmt) {
    $max = ($rows | Measure-Object $valueProp -Maximum).Maximum; if (-not $max) { return "<p class='muted'>$(HtmlEnc (T 'No data.'))</p>" }
    $sb = New-Object Text.StringBuilder
    foreach ($r in $rows) { $pct = [math]::Round(100 * $r.$valueProp / $max, 1); [void]$sb.Append("<div class='bar'><span class='bl'>$(HtmlEnc $r.$labelProp)</span><span class='bt'><span class='bf' style='width:$([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.0}',$pct))%'></span></span><span class='bv'>$(HtmlEnc (& $fmt $r.$valueProp))</span></div>") }
    $sb.ToString()
}
# Display names for internal values in the report
function Get-SnapshotLabelText([string]$Label) { switch ($Label) { 'vorher' { return (T 'Before').ToLower() } 'nachher' { return (T 'After').ToLower() } 'scan' { return (T 'scan') } }; return $Label }
function Get-StatusText([string]$Status) { switch ($Status) { 'OK' { return 'OK' } 'Fehler' { return (T 'Error') } 'Uebersprungen' { return (T 'Skipped') } 'Abgebrochen' { return (T 'Cancelled') } }; return $Status }

function New-Report {
    $snaps = Get-Snapshots
    if (-not $snaps.Count) { W (T 'No snapshots yet - run "Scan" first.') 'Yellow'; return $null }
    function HT([string]$Text) { HtmlEnc (T $Text @args) }
    $df = T 'yyyy-MM-dd HH:mm'
    $all = @($snaps | ForEach-Object { Read-Snapshot $_ })
    $last = $all[-1]
    $before = ($all | Where-Object { $_.Label -eq 'vorher' } | Select-Object -Last 1); if (-not $before) { $before = $all[0] }
    $actions = @()
    foreach ($f in (Get-ChildItem $Script:RunsDir -Recurse -Filter 'actions.jsonl' -ErrorAction SilentlyContinue)) { $actions += @(Get-Content $f.FullName -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
    $actions = @($actions | Where-Object { $_.Status -ne 'Undo-Info' })
    $runs = @($all | Where-Object { $_.Label -eq 'vorher' } | ForEach-Object { [pscustomobject]@{ Zeit = $_.Zeit; Name = 'Apply' } })
    $boots = @(); $seen = @{}
    foreach ($s in $all) { foreach ($b in @($s.Boot.Verlauf)) { if (-not $seen.ContainsKey($b.Zeit)) { $seen[$b.Zeit] = 1; $boots += $b } } }
    $cmp = if ($before -and $before.Zeit -ne $last.Zeit) { Get-CompareMetrics $before $last } else { @() }
    $okActs = @($actions | Where-Object Status -eq 'OK')
    $freed = ($okActs | Measure-Object Bytes -Sum).Sum
    $perRule = @($okActs | Group-Object Regel | ForEach-Object { [pscustomobject]@{ Regel = $_.Name; Anzahl = $_.Count; Bytes = ($_.Group | Measure-Object Bytes -Sum).Sum } } | Sort-Object Bytes -Descending)
    $score = $last.Score.Wert
    $scoreClass = if ($score -ge 85) { 'good' } elseif ($score -ge 65) { 'mid' } else { 'bad' }
    $sysLW = $env:SystemDrive.Substring(0, 1); $sysV = $last.Laufwerke | Where-Object { $_.LW -eq $sysLW } | Select-Object -First 1

    $css = @'
:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--text:#e6edf3;--muted:#8b949e;--acc:#58a6ff;--good:#3fb950;--mid:#d29922;--bad:#f85149;--main:#a371f7}
li.bad{color:var(--bad)}li.mid{color:var(--mid)}li.good{color:var(--good)}li.muted{color:var(--muted)}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--bg:#f6f8fa;--panel:#ffffff;--line:#d0d7de;--text:#1f2328;--muted:#59636e;--acc:#0969da;--good:#1a7f37;--mid:#9a6700;--bad:#cf222e;--main:#8250df}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:24px 16px 60px}h1{font-size:26px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 10px;border-bottom:1px solid var(--line);padding-bottom:6px}
.muted{color:var(--muted)}.mono{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
.grid4{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.kpi{font-size:28px;font-weight:600;font-variant-numeric:tabular-nums}.kl{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.score{display:flex;align-items:center;gap:20px}.ring{width:110px;height:110px;border-radius:50%;display:grid;place-items:center;font-size:34px;font-weight:700;border:8px solid var(--line)}
.ring.good{border-color:var(--good)}.ring.mid{border-color:var(--mid)}.ring.bad{border-color:var(--bad)}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.03em}
td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.besser{color:var(--good)}.schlechter{color:var(--bad)}
.tag{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11.5px;border:1px solid var(--line)}.Niedrig{color:var(--good)}.Mittel{color:var(--mid)}.Hoch{color:var(--bad)}.Info{color:var(--acc)}
.OK{color:var(--good)}.Fehler{color:var(--bad)}.Uebersprungen{color:var(--muted)}
.chart{width:100%;height:auto;background:var(--panel);border:1px solid var(--line);border-radius:10px}
.chart .grid{stroke:var(--line);stroke-width:1}.chart .ax{fill:var(--muted);font-size:11px}.chart .total{fill:none;stroke:var(--acc);stroke-width:2}.chart .main{fill:none;stroke:var(--main);stroke-width:1.5;stroke-dasharray:4 3}
.chart .dot{fill:var(--acc)}.chart .sdot{stroke:var(--panel);stroke-width:1.5}.chart .sdot.good{fill:var(--good)}.chart .sdot.mid{fill:var(--mid)}.chart .sdot.bad{fill:var(--bad)}.chart .lim{stroke-width:1;stroke-dasharray:2 4}.chart .lim.good{stroke:var(--good)}.chart .lim.mid{stroke:var(--mid)}.chart .run{stroke:var(--good);stroke-width:1.5;stroke-dasharray:6 4}.chart .runlbl{fill:var(--good);font-size:11px}
.pgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}.pc .pv{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums}.pc .pd{font-size:13px;margin:2px 0 8px}.pc .kl[title]{cursor:help}
.verdict{font-size:16px;font-weight:600;margin:6px 0}.verdict.gemischt{color:var(--mid)}.sparkx{display:flex;justify-content:space-between;font-size:11px}.chart.spark{border:0;background:transparent}
.legend{margin-top:6px;color:var(--muted);font-size:12px}.lg{display:inline-block;width:18px;height:3px;margin:0 6px 3px 14px;vertical-align:middle}.lg.total{background:var(--acc)}.lg.main{background:var(--main)}.lg.run{background:var(--good)}.lg.lim{background:repeating-linear-gradient(90deg,var(--mid) 0 3px,transparent 3px 6px)}
.bar{display:grid;grid-template-columns:minmax(120px,240px) 1fr 90px;gap:10px;align-items:center;margin:5px 0}.bt{background:var(--line);height:10px;border-radius:5px;overflow:hidden}.bf{display:block;height:100%;background:var(--acc)}.bv{text-align:right;font-variant-numeric:tabular-nums}.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
details{margin:6px 0}summary{cursor:pointer}ul.items{margin:6px 0 0 18px;padding:0}
@media (max-width:640px){.bar{grid-template-columns:1fr 70px}.bt{grid-column:1/-1;order:3}.score{flex-direction:column;align-items:flex-start}table{display:block;overflow-x:auto}}
'@
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<!doctype html><html lang='$Script:Lang'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>$(HT 'WinTidy report')</title><style>$css</style></head><body><div class='wrap'>")
    [void]$sb.Append("<h1>$(HT 'WinTidy report') &middot; $(HtmlEnc $last.Computer)</h1><div class='muted'>$(HtmlEnc $last.System.OS) $(HtmlEnc $last.System.Version) (Build $(HtmlEnc $last.System.Build)) &middot; $(HtmlEnc $last.System.CPU) &middot; $($last.System.RamGB) GB RAM &middot; $(HtmlEnc $last.System.Board) &middot; BIOS $(HtmlEnc $last.System.BIOS)<br>$(HT 'Last snapshot: {0} ({1})' ([datetime]$last.Zeit).ToString($df) (Get-SnapshotLabelText $last.Label)) &middot; $(HT '{0} snapshots' $all.Count) &middot; WinTidy $Script:Version</div>")

    # Score + KPIs
    [void]$sb.Append("<h2>$(HT 'State')</h2><div class='grid4'><div class='card score' style='grid-column:span 2'><div class='ring $scoreClass'>$score</div><div><div class='kl'>$(HT 'Health score (0-100)')</div>")
    if (@($last.Score.Abzuege).Count) { [void]$sb.Append('<ul class="items">'); foreach ($z in $last.Score.Abzuege) { [void]$sb.Append("<li>&minus;$([int]$z.Punkte) &nbsp;$(HtmlEnc $z.Grund)</li>") }; [void]$sb.Append('</ul>') } else { [void]$sb.Append("<p>$(HT 'No deductions.')</p>") }
    [void]$sb.Append('</div></div>')
    $bootTxt = if ($last.Boot.Mittel5) { '{0:N1} s' -f ($last.Boot.Mittel5 / 1000) } else { 'n/a' }
    $kpis = @(
        @((T 'Boot (Ø 5)'), $bootTxt), @((T 'Free on {0}:' $sysLW), $(if ($sysV) { "$($sysV.FreiGB) GB" } else { 'n/a' })), @((T 'Active startup programs'), $last.Autostart.Aktiv),
        @((T 'Errors in the log (7 d)'), ($last.Ereignisse.FehlerSystem7T + $last.Ereignisse.FehlerAnwendung7T)), @((T 'Actions total'), "$($okActs.Count) OK"), @((T 'Freed (estimated)'), (Fmt-Bytes $freed))
    )
    foreach ($k in $kpis) { [void]$sb.Append("<div class='card'><div class='kl'>$(HtmlEnc $k[0])</div><div class='kpi'>$(HtmlEnc $k[1])</div></div>") }
    [void]$sb.Append('</div>')

    # Did WinTidy help? Key figures since the first optimization + trend per key figure
    $perfPts = @(); $eff = $null
    try {
        $perfPts = @($all | ForEach-Object { Get-PerfPoint $_ })
        $firstVor = ($all | Where-Object { $_.Label -eq 'vorher' } | Select-Object -First 1)
        if ($firstVor -and $firstVor.Zeit -ne $last.Zeit) { $eff = Get-PerfEffect $firstVor $last @($boots | Sort-Object { [datetime]$_.Zeit }) }
    } catch { W (T '  Key figures could not be compared: {0}' ($_.Exception.Message)) 'DarkYellow' }
    [void]$sb.Append("<h2>$(HT 'Did WinTidy help?')</h2>")
    $vcls = ''; if ($eff) { $vcls = switch ($eff.Urteil) { 'besser' { ' besser' } 'schlechter' { ' schlechter' } 'gemischt' { ' gemischt' } default { '' } } }
    [void]$sb.Append("<p class='verdict$vcls'>$(HtmlEnc (Get-PerfHeadline $eff))</p>")
    if ($eff) {
        $bn = Get-PerfBootNote $eff; if ($bn) { [void]$sb.Append("<p class='muted'>$(HtmlEnc $bn)</p>") }
        [void]$sb.Append("<table><tr><th>$(HT 'Key figure')</th><th>$(HT 'Before')</th><th>$(HT 'Now')</th><th>$(HT 'Difference')</th><th>$(HT 'Rating')</th></tr>")
        foreach ($m in $eff.Metriken) {
            $rt = HtmlEnc $m.BewertungText; if ($m.Unsicher) { $rt += ' <span class="muted">' + (HtmlEnc (T '(PC was busy while measuring)')) + '</span>' }
            $rcl = ''; if ($m.Bewertung -in 'besser', 'schlechter') { $rcl = $m.Bewertung }
            [void]$sb.Append("<tr><td><span title='$(HtmlEnc $m.Hinweis)'>$(HtmlEnc $m.Kennzahl)</span></td><td class='n'>$(HtmlEnc $m.VorherText)</td><td class='n'>$(HtmlEnc $m.NachherText)</td><td class='n $rcl'>$(HtmlEnc $m.DeltaText)</td><td class='$rcl'>$rt</td></tr>")
        }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append("<h2>$(HT 'Trend of the key figures')</h2><p class='muted'>$(HT 'One point per check, start times per start. Green dashed lines mark optimizations.')</p><div class='pgrid'>")
    foreach ($d in (Get-PerfDefs)) {
        $em = $null; if ($eff) { $em = $eff.Metriken | Where-Object { $_.Id -eq $d.Id } | Select-Object -First 1 }
        $cur = $null; $sub = ''
        if ($em -and $null -ne $em.Nachher) {
            $cur = $em.Nachher
            if ($null -ne $em.Vorher) { $sub = "<div class='pd $(if ($em.Bewertung -in 'besser', 'schlechter') { $em.Bewertung })'>$(HtmlEnc ((T 'before: {0}' $em.VorherText) + ', ' + $em.BewertungText))</div>" }
        } else {
            $lp = $perfPts | Where-Object { $null -ne $_.Werte.($d.Id) } | Select-Object -Last 1
            if ($lp) { $cur = $lp.Werte.($d.Id) }
            if ($d.Boot) { $bl = Get-BootAvg $boots $(if ($d.Id -eq 'BootNach') { 'NachDesktopMs' } else { 'GesamtMs' }) 5; if ($bl.Anzahl) { $cur = ConvertTo-PerfNum ($bl.Mittel / 1000) 1 } }
        }
        [void]$sb.Append("<div class='card pc'><div class='kl' title='$(HtmlEnc $d.Hinweis)'>$(HtmlEnc $d.Titel)</div><div class='pv'>$(HtmlEnc (Format-PerfValue $cur $d.Stellen $d.Einheit))</div>$sub$(New-PerfSpark $d $perfPts $boots $runs)</div>")
    }
    [void]$sb.Append('</div>')

    $scorePts = @($all | Where-Object { $_.Score } | ForEach-Object { [pscustomobject]@{ Zeit = $_.Zeit; Label = $_.Label; Wert = $_.Score.Wert } })
    [void]$sb.Append("<h2>$(HT 'Health score over time')</h2><p class='muted'>$(HT 'One point per check. Green dashed lines mark optimizations. Move the mouse over a point for details.')</p>"); [void]$sb.Append((New-ScoreSvg $scorePts $runs))

    [void]$sb.Append("<h2>$(HT 'Boot times')</h2>"); [void]$sb.Append((New-BootSvg $boots $runs))

    if ($cmp.Count) {
        [void]$sb.Append("<h2>$(HT 'Before / after')</h2><p class='muted'>$(([datetime]$before.Zeit).ToString($df)) ($(HtmlEnc (Get-SnapshotLabelText $before.Label))) &rarr; $(([datetime]$last.Zeit).ToString($df)) ($(HtmlEnc (Get-SnapshotLabelText $last.Label))). $(HT 'Boot times only change after restarts.')</p><table><tr><th>$(HT 'Metric')</th><th>$(HT 'Before')</th><th>$(HT 'After')</th><th>Delta</th></tr>")
        foreach ($m in $cmp) { $d = if ($null -eq $m.Delta) { '' } elseif ($m.Delta -gt 0) { "+$($m.Delta)" } else { "$($m.Delta)" }; [void]$sb.Append("<tr><td>$(HtmlEnc $m.Kennzahl)</td><td class='n'>$(HtmlEnc $m.Vorher) $(HtmlEnc $m.Einheit)</td><td class='n'>$(HtmlEnc $m.Nachher) $(HtmlEnc $m.Einheit)</td><td class='n $($m.Bewertung)'>$(HtmlEnc $d)</td></tr>") }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append("<h2>$(HT 'Findings (last scan)')</h2>")
    if (@($last.Befunde).Count) {
        [void]$sb.Append("<table><tr><th>$(HT 'Rule')</th><th>$(HT 'Finding')</th><th>$(HT 'Risk')</th><th>$(HT 'Count')</th><th>$(HT 'Size')</th></tr>")
        foreach ($b in $last.Befunde) {
            $items = (@($b.Objekte) | ForEach-Object { "<li class='mono'>$(HtmlEnc $_)</li>" }) -join ''
            [void]$sb.Append("<tr><td class='mono'>$(HtmlEnc $b.Regel)</td><td><details><summary>$(HtmlEnc $b.Titel)</summary><ul class='items'>$items</ul></details></td><td><span class='tag $(if ([string]$b.Risiko -in 'Niedrig', 'Mittel', 'Hoch', 'Info') { [string]$b.Risiko } else { 'Info' })'>$(HtmlEnc (Get-RiskText $b.Risiko))</span></td><td class='n'>$([int]$b.Anzahl)</td><td class='n'>$(if ($b.Bytes) { Fmt-Bytes $b.Bytes })</td></tr>")
        }
        [void]$sb.Append('</table>')
    } else { [void]$sb.Append("<p class='muted'>$(HT 'No findings saved (run a scan).')</p>") }

    [void]$sb.Append("<h2>$(HT 'Startup delays according to Windows (60 days)')</h2>")
    $off = @($last.Boot.Bremser)
    if ($off.Count) { [void]$sb.Append((New-BarRows ($off | Select-Object -First 12 | ForEach-Object { [pscustomobject]@{ L = "$($_.Typ): $(if ($_.Name) { $_.Name } else { $_.Datei }) ($($_.Anzahl)x)"; V = $_.MittelMs } }) 'L' 'V' { param($v) '{0:N1} s' -f ($v / 1000) })) } else { [void]$sb.Append("<p class='muted'>$(HT 'No data (admin rights needed).')</p>") }

    [void]$sb.Append("<h2>$(HT 'Startup')</h2><table><tr><th>Name</th><th>$(HT 'Location')</th><th>$(HT 'Active')</th><th>$(HT 'Target')</th><th>$(HT 'Delay')</th></tr>")
    foreach ($s in (@($last.Autostart.Liste) | Sort-Object @{ Expression = { [bool]$_.Aktiv }; Descending = $true }, @{ Expression = { $_.DegradationMs }; Descending = $true })) {
        [void]$sb.Append("<tr><td>$(HtmlEnc $s.Name)</td><td>$(HtmlEnc $s.Ort)</td><td>$(if ($s.Aktiv) { "<span class='OK'>$(HT 'on')</span>" } else { "<span class='muted'>$(HT 'off')</span>" })</td><td class='mono'>$(HtmlEnc $s.Ziel)$(if ($s.Zustand -eq 'fehlt') { " <span class='Fehler'>$(HT '(missing)')</span>" })</td><td class='n'>$(if ($s.DegradationMs) { '{0:N1} s' -f ($s.DegradationMs / 1000) })</td></tr>")
    }
    [void]$sb.Append('</table>')

    [void]$sb.Append("<h2>$(HT 'Drives')</h2>"); [void]$sb.Append((New-BarRows ($last.Laufwerke | ForEach-Object { [pscustomobject]@{ L = (T '{0}: {1} {2} {3} - {4} of {5} GB free' $_.LW $_.Label $_.Medium $_.Bus $_.FreiGB $_.GroesseGB); V = (100 - $_.FreiProzent) } }) 'L' 'V' { param($v) T '{0:N0} % used' $v }))

    if ($last.Hardware) {
        $hw = $last.Hardware
        [void]$sb.Append("<h2>$(HT 'Hardware & cooling')</h2><table><tr><th>$(HT 'Reading')</th><th>$(HT 'Value')</th></tr>")
        $rows = New-Object System.Collections.Generic.List[object]
        $rows.Add(@((HT 'Processor temperature'), $(if ($null -ne $hw.CpuTempC) { '{0:N0} &deg;C ({1})' -f $hw.CpuTempC, (HT 'source: {0}' $hw.Sensorquelle) } else { HT 'not available – the motherboard does not report it to Windows (start LibreHardwareMonitor)' })))
        if ($hw.Gpu) { $rows.Add(@((HtmlEnc $hw.Gpu.Name), ('{0} &deg;C, {1}' -f (HtmlEnc $hw.Gpu.TempC), (HT 'fans {0} %' $hw.Gpu.LuefterProzent)))) }
        $fl = @($hw.Luefter | Where-Object { $_ }); if ($fl.Count) { $rows.Add(@((HT 'Fans'), ((@($fl | ForEach-Object { HT '{0}: {1} RPM' $_.Name $_.Upm })) -join '<br>'))) }
        $rows.Add(@((HT 'Throttling by the firmware (30 days)'), [string][int]$hw.Drosselung30T))
        foreach ($d in @($hw.Laufwerke | Where-Object { $_ })) { $rows.Add(@((HT 'Drive {0}' $d.Name), ('{0}{1}{2}' -f $(if ($null -ne $d.TempC) { "$($d.TempC) &deg;C" } else { HT 'temperature unknown' }), $(if ($null -ne $d.Verschleiss) { ', ' + (HT '{0} % used up' $d.Verschleiss) } else { '' }), $(if ($d.Zustand) { ', ' + (HtmlEnc $d.Zustand) } else { '' })))) }
        if ($null -ne $hw.AkkuVerschleiss) { $rows.Add(@((HT 'Battery capacity loss'), "$([int]$hw.AkkuVerschleiss) %")) }
        foreach ($r in $rows) { [void]$sb.Append("<tr><td>$($r[0])</td><td>$($r[1])</td></tr>") }
        [void]$sb.Append('</table>')
        $hp = @($hw.Punkte | Where-Object { $_ })
        if ($hp.Count) { [void]$sb.Append('<ul>'); foreach ($x in $hp) { [void]$sb.Append("<li class='$(if ($x.Stufe -eq 'krit') { 'bad' } else { 'mid' })'>$(HtmlEnc $x.Text)</li>") }; [void]$sb.Append('</ul>') } else { [void]$sb.Append("<p class='muted'>$(HT 'No irregularities in cooling, drives and battery.')</p>") }
        $lt = Get-LastCoolingTest
        if ($lt) { [void]$sb.Append("<p><b>$(HT 'Last cooling test')</b> ($(([datetime]$lt.Zeit).ToString($df)), $([int]$lt.Sekunden) s, $([int]$lt.Kerne) Threads):</p><ul>"); foreach ($x in @($lt.Punkte)) { [void]$sb.Append("<li class='$(switch ($x.Stufe) { 'krit' { 'bad' } 'warn' { 'mid' } 'ok' { 'good' } default { 'muted' } })'>$(HtmlEnc $x.Text)</li>") }; [void]$sb.Append('</ul>') }
    }
    if ($perRule.Count) { [void]$sb.Append("<h2>$(HT 'Cleaned up per rule')</h2>"); [void]$sb.Append((New-BarRows ($perRule | Where-Object Bytes) 'Regel' 'Bytes' { param($v) Fmt-Bytes $v })); [void]$sb.Append("<table><tr><th>$(HT 'Rule')</th><th>$(HT 'Actions')</th><th>$(HT 'Size')</th></tr>"); foreach ($p in $perRule) { [void]$sb.Append("<tr><td class='mono'>$(HtmlEnc $p.Regel)</td><td class='n'>$($p.Anzahl)</td><td class='n'>$(Fmt-Bytes $p.Bytes)</td></tr>") }; [void]$sb.Append('</table>') }

    [void]$sb.Append("<h2>$(HT 'Action log')</h2>")
    $dfs = T 'MM-dd HH:mm'
    if ($actions.Count) { [void]$sb.Append("<table><tr><th>$(HT 'Time')</th><th>$(HT 'Rule')</th><th>$(HT 'Item')</th><th>Status</th><th>$(HT 'Size')</th></tr>"); foreach ($a in ($actions | Sort-Object Zeit -Descending | Select-Object -First 400)) { [void]$sb.Append("<tr><td class='n'>$(([datetime]$a.Zeit).ToString($dfs))</td><td class='mono'>$(HtmlEnc $a.Regel)</td><td>$(HtmlEnc $a.Objekt)$(if ($a.Meldung) { "<div class='muted'>$(HtmlEnc $a.Meldung)</div>" })</td><td class='$($a.Status)'>$(HtmlEnc (Get-StatusText $a.Status))</td><td class='n'>$(if ($a.Bytes) { Fmt-Bytes $a.Bytes })</td></tr>") }; [void]$sb.Append('</table>') } else { [void]$sb.Append("<p class='muted'>$(HT 'No changes made yet.')</p>") }

    [void]$sb.Append("<h2>$(HT 'Snapshot history')</h2><table><tr><th>$(HT 'Time')</th><th>$(HT 'Type')</th><th>Score</th><th>$(HT 'Boot Ø')</th><th>$(HT 'Free system')</th><th>$(HT 'Startup programs')</th><th>$(HT 'Errors 7 d')</th></tr>")
    foreach ($s in ($all | Sort-Object Zeit -Descending)) { $sv = $s.Laufwerke | Where-Object { $_.LW -eq $sysLW } | Select-Object -First 1; [void]$sb.Append("<tr><td class='n'>$(([datetime]$s.Zeit).ToString($df))</td><td>$(HtmlEnc (Get-SnapshotLabelText $s.Label))</td><td class='n'>$([int]$s.Score.Wert)</td><td class='n'>$(if ($s.Boot.Mittel5) { '{0:N1} s' -f ($s.Boot.Mittel5 / 1000) })</td><td class='n'>$(if ($sv) { "$($sv.FreiGB) GB" })</td><td class='n'>$($s.Autostart.Aktiv)</td><td class='n'>$($s.Ereignisse.FehlerSystem7T + $s.Ereignisse.FehlerAnwendung7T)</td></tr>") }
    [void]$sb.Append('</table>')
    [void]$sb.Append("<p class='muted' style='margin-top:30px'>$(HT 'Data:') <span class='mono'>$(HtmlEnc $Script:DataDir)</span> &middot; $(HT 'created {0}' (Get-Date).ToString($df))</p></div></body></html>")
    $out = Join-Path $Script:DataDir 'WinTidy-Bericht.html'
    [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    W (T '  Report: {0}' $out) 'Green'
    return $out
}

# =============================================================================
#  Restore
# =============================================================================
function Resolve-RunDir([string]$Lauf) {
    if (-not $Lauf) { return $null }
    $runs = @(Get-ChildItem $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name -Descending)
    $exakt = $runs | Where-Object { $_.Name -eq "$($Lauf)_apply" } | Select-Object -First 1
    if ($exakt) { return $exakt }
    $treffer = @($runs | Where-Object { $_.Name -like "$Lauf*" })
    if ($treffer.Count -eq 1) { return $treffer[0] }
    return $null   # not unique
}
function Read-UndoRecords($RunDir) {
    $acts = Join-Path $RunDir.FullName 'actions.jsonl'
    if (-not (Test-Path -LiteralPath $acts)) { return @() }
    @(Get-Content -LiteralPath $acts -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and $_.Undo })
}
# Readable name of an undo record
function Get-UndoLabel($a) {
    $u = $a.Undo
    switch ([string]$u.Typ) {
        'RegValue' {
            $k = ConvertTo-RegKeyText $u.Key
            if ($k -match 'GameDVR|GameConfigStore') { return @((T 'Setting'), (T 'Game recording (Xbox Game Bar)')) }
            if ($k -match 'FileSystem$') { return @((T 'Setting'), (T 'TRIM for SSDs')) }
            return @((T 'Startup'), ('"{0}"' -f $a.Objekt))
        }
        'Dienst' { return @((T 'Background service'), ('"{0}"' -f $u.Name)) }
        'PowerSetting' { return @((T 'Power setting'), (T 'Cooling on mains power')) }
        'ExecPolicy' { return @((T 'Setting'), (T 'Protection setting for scripts')) }
        'Hiber' { return @((T 'Setting'), (T 'Hibernation file (full size)')) }
        'Datei' { return @((T 'Startup'), ((T 'Shortcut "{0}"') -f [IO.Path]::GetFileNameWithoutExtension([string]$u.Ziel))) }
        'Ordner' { return @((T 'Folder'), ('"{0}"' -f [IO.Path]::GetFileName(([string]$u.Ziel).TrimEnd('')))) }
    }
    return @((T 'Setting'), [string]$a.Objekt)
}
function Get-RegBackupLabel([string]$Name) {
    if ($Name -like 'appxkey_*') { return (T 'Startup entry of an app') }
    if ($Name -like 'approved_*') { return (T 'Startup settings') }
    if ($Name -like 'run_*') { return (T 'Startup entries') }
    if ($Name -like 'gameconfigstore*') { return (T 'Game recording (Xbox Game Bar)') }
    if ($Name -like 'appx_*') { return (T 'Startup entry of an app') }
    return ($Name -replace '_', ' ')
}
# Registry backups (.reg) are only imported for runs without single-value undo (runs before 1.3) or for
# completely removed app startup keys - and only if all contained keys are expected.
function Get-RegBackupFiles($RunDir, $Undos) {
    $hatWerte = [bool]($Undos | Where-Object { $_.Undo.Typ -eq 'RegValue' })
    @(Get-ChildItem (Join-Path $RunDir.FullName 'backup') -Filter '*.reg' -ErrorAction SilentlyContinue | Where-Object { -not $hatWerte -or $_.BaseName -like 'appxkey_*' })
}
function Test-RegFileAllowed([string]$Path) {
    try {
        $keys = @(Get-Content -LiteralPath $Path -Encoding Unicode -ErrorAction Stop | Where-Object { $_ -match '^\s*\[' } | ForEach-Object { $_.Trim().TrimStart('[').TrimEnd(']').TrimStart('-') })
        if (-not $keys.Count) { return $false }
        foreach ($k in $keys) { if (-not (Test-RegKeyAllowed $k)) { return $false } }
        return $true
    } catch { return $false }
}

# What "Restore" would reset for a run (changes nothing)
function Get-RestorePreview([string]$Lauf) {
    $sel = Resolve-RunDir $Lauf
    if (-not $sel) { return @() }
    $undos = Read-UndoRecords $sel
    $r = @()
    foreach ($f in (Get-RegBackupFiles $sel $undos)) { $r += [pscustomobject]@{ Art = (T 'Setting'); Objekt = (Get-RegBackupLabel $f.BaseName) } }
    $idx = Join-Path $sel.FullName 'backup\tasks\index.jsonl'
    if (Test-Path $idx) { foreach ($l in (Get-Content $idx -Encoding UTF8 | Where-Object { $_ })) { try { $t = $l | ConvertFrom-Json; $r += [pscustomobject]@{ Art = (T 'Scheduled task'); Objekt = ('"{0}"' -f $t.TaskName) } } catch { } } }
    foreach ($a in $undos) { $lb = Get-UndoLabel $a; $r += [pscustomobject]@{ Art = $lb[0]; Objekt = $lb[1] } }
    return @($r | Sort-Object Art, Objekt -Unique)
}

function Invoke-Restore {
    # With admin rights, undo records are only applied from a folder that only admins can write (also with -DataPath)
    if ($Script:IsAdmin -and -not $Script:DataDirProtected -and ($Script:DataDirIsDefault -or -not (Test-WtDataRootSafe $Script:DataDir))) {
        W (T 'The data folder is not sufficiently protected - restore is blocked for safety reasons. Please use System Restore (rstrui.exe).') 'Red'
        return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = (T 'The WinTidy data folder is not sufficiently protected. For safety reasons WinTidy therefore resets nothing. Please use Windows System Restore.'); Lauf = $null; Wiederhergestellt = 0; Fehler = 0; Details = @() }
    }
    $runs = @(Get-ChildItem $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name -Descending)
    if (-not $runs.Count) { W (T 'No apply runs found.') 'Yellow'; return [pscustomobject]@{ Status = 'NICHT-GEFUNDEN'; Lauf = $null; Wiederhergestellt = 0; Fehler = 0; Details = @() } }
    $sel = if ($Script:RestoreRunId) { Resolve-RunDir $Script:RestoreRunId } else {
        W (T 'Runs:'); for ($i = 0; $i -lt [math]::Min(10, $runs.Count); $i++) { W ("  [{0}] {1}" -f ($i + 1), $runs[$i].Name) }
        $n = Read-Host (T 'Number'); $k = 0; if ([int]::TryParse($n, [ref]$k) -and $k -ge 1 -and $k -le $runs.Count) { $runs[$k - 1] } else { $null }
    }
    if (-not $sel) { W (T 'Run not found (or not unique).') 'Red'; return [pscustomobject]@{ Status = 'NICHT-GEFUNDEN'; Lauf = $Script:RestoreRunId; Wiederhergestellt = 0; Fehler = 0; Details = @() } }
    $det = New-Object System.Collections.Generic.List[object]
    function R([string]$Art, [string]$Obj, [bool]$Ok, [string]$Msg = '') {
        $det.Add([pscustomobject]@{ Art = $Art; Objekt = $Obj; Status = $(if ($Ok) { 'OK' } else { 'Fehler' }); Meldung = $Msg })
        Add-ActionRecord 'RESTORE' "$Art $Obj" $(if ($Ok) { 'OK' } else { 'Fehler' }) 0 $Msg | Out-Null
        W ("  {0} {1}: {2}{3}" -f $(if ($Ok) { 'OK    ' } else { (T 'ERROR ') }), $Art, $Obj, $(if ($Msg) { " ($Msg)" } else { '' })) $(if ($Ok) { 'Green' } else { 'Red' })
    }
    W (T 'Restoring: {0}' ($sel.FullName)) 'Cyan'
    W (T 'Note: deleted files, uninstalled programs and removed Store apps cannot be brought back here (for that: restore point).') 'DarkYellow'
    $neuer = @($runs | Where-Object { $_.Name -gt $sel.Name })
    if ($neuer.Count) { W ((T '  Caution: there were {0} more optimization(s) afterwards. Values changed since then are not overwritten.') -f $neuer.Count) 'DarkYellow' }
    $undos = Read-UndoRecords $sel
    foreach ($f in (Get-RegBackupFiles $sel $undos)) {
        $lb = Get-RegBackupLabel $f.BaseName
        if (-not (Test-RegFileAllowed $f.FullName)) { R (T 'Setting') $lb $false (T 'Unexpected registry path - not imported'); continue }
        $null = & reg.exe import $f.FullName 2>&1
        R (T 'Setting') $lb ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -ne 0) { (T 'reg import error {0}' $LASTEXITCODE) } else { '' })
    }
    # Scheduled tasks were only disabled - enable them again instead of recreating them from XML
    $idx = Join-Path $sel.FullName 'backup\tasks\index.jsonl'
    if (Test-Path $idx) {
        foreach ($l in (Get-Content $idx -Encoding UTF8 | Where-Object { $_ })) {
            $t = $null; try { $t = $l | ConvertFrom-Json } catch { continue }
            try { Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null; R (T 'Scheduled task') $t.TaskName $true }
            catch { R (T 'Scheduled task') $t.TaskName $false $_.Exception.Message }
        }
    }
    # Undo single changes in reverse order
    $liste = @($undos); [array]::Reverse($liste)
    foreach ($a in $liste) {
        if ([string]$a.Undo.Typ -notin 'RegValue', 'Dienst', 'PowerSetting', 'ExecPolicy', 'Hiber', 'Datei', 'Ordner') { continue }
        $lb = Get-UndoLabel $a
        try {
            switch ([string]$a.Undo.Typ) {
                'RegValue' { Restore-RegValue $a.Undo }
                'Dienst' {
                    $m = switch ($a.Undo.StartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } default { 'Manual' } }
                    Set-Service -Name $a.Undo.Name -StartupType $m -ErrorAction Stop
                    if ($a.Undo.Verzoegert -and $m -eq 'Automatic') { $null = & sc.exe config $a.Undo.Name start= delayed-auto 2>&1 }
                }
                'PowerSetting' {
                    $null = & powercfg.exe /setacvalueindex $a.Undo.Schema $a.Undo.Sub $a.Undo.Setting ([int]$a.Undo.AC) 2>&1
                    if ($LASTEXITCODE -ne 0) { throw (T 'powercfg error {0}' $LASTEXITCODE) }
                    $null = & powercfg.exe /setactive $a.Undo.Schema 2>&1
                }
                'ExecPolicy' { if ([string]$a.Undo.Vorher -in 'Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass', 'Undefined') { try { Set-ExecutionPolicy ([string]$a.Undo.Vorher) -Scope ([string]$a.Undo.Scope) -Force -ErrorAction Stop } catch { if ($_.Exception.Message -notmatch 'overridden|ueberschrieben|überschrieben') { throw } } } }
                'Hiber' { $null = & powercfg.exe /h /type full 2>&1; if ($LASTEXITCODE -ne 0) { throw (T 'powercfg error {0}' $LASTEXITCODE) } }
                'Datei' {
                    $ziel = [IO.Path]::GetFullPath([string]$a.Undo.Ziel); $quelle = [IO.Path]::GetFullPath([string]$a.Undo.Quelle)
                    $erlaubt = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) | Where-Object { $_ -and ([IO.Path]::GetDirectoryName($ziel)) -ieq $_.TrimEnd('\') }
                    if (-not $erlaubt) { throw (T 'Unexpected target folder - not copied back') }
                    if (-not $quelle.StartsWith($sel.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw (T 'Backup is not inside the run folder') }
                    if (-not (Test-Path -LiteralPath $ziel)) { Copy-Item -LiteralPath $quelle -Destination $ziel -ErrorAction Stop }
                }
                'Ordner' {
                    # Only rename back what WinTidy set aside: same parent folder, expected name, nothing in the way
                    $ziel = [IO.Path]::GetFullPath([string]$a.Undo.Ziel).TrimEnd(''); $quelle = [IO.Path]::GetFullPath([string]$a.Undo.Quelle).TrimEnd('')
                    if (-not (Test-QuarantinePath $quelle) -or [IO.Path]::GetDirectoryName($quelle) -ine [IO.Path]::GetDirectoryName($ziel) -or -not $quelle.StartsWith($ziel + $Script:QuarantineSuffix, [StringComparison]::OrdinalIgnoreCase)) { throw (T 'Unexpected path - not restored') }
                    if (-not (Test-Path -LiteralPath $quelle)) { throw (T 'Already deleted permanently') }
                    if (Test-Path -LiteralPath $ziel) { throw (T 'A folder with this name exists again - nothing overwritten') }
                    $q = Get-Item -LiteralPath $quelle -Force -ErrorAction Stop
                    if (Test-Reparse $q) { throw (T 'Unexpected path - not restored') }
                    [IO.Directory]::Move($quelle, $ziel)
                }
            }
            R $lb[0] $lb[1] $true
        } catch { R $lb[0] $lb[1] $false $_.Exception.Message }
    }
    W (T 'Done. For everything else: System Restore (rstrui.exe) with the point "WinTidy <run>".') 'Cyan'
    $okN = @($det | Where-Object Status -eq 'OK').Count
    try { [ordered]@{ Zeit = (Get-Date).ToString('o'); Wiederhergestellt = $okN; Fehler = ($det.Count - $okN) } | ConvertTo-Json | Out-File (Join-Path $sel.FullName 'rueckgaengig.json') -Encoding utf8 } catch { }
    return [pscustomobject]@{ Status = 'OK'; Lauf = $sel.Name; Wiederhergestellt = $okN; Fehler = ($det.Count - $okN); Details = $det.ToArray() }
}

# =============================================================================
#  API for the graphical interface (WinTidy-App.ps1)
#  The app loads this file via dot-sourcing into a background runspace.
# =============================================================================
$Script:Friendly = @{
    'CLN-TEMP'            = @((T 'Remove temporary files'), (T 'Programs leave temporary files behind while working and forget them. Only what nobody has created or changed for days is deleted.'))
    'CLN-WINCLEAN'        = @((T 'Clean up Windows leftovers'), (T 'Leftovers of Windows updates, error reports and the update cache. Uses Windows'' own Disk Cleanup.'))
    'CLN-WINOLD'          = @((T 'Delete the previous Windows version'), (T 'After a major Windows update the old version stays behind as a backup – often 10 to 30 GB. Afterwards you can no longer go back to the old Windows version. The files for "Reset this PC" are kept.'))
    'CLN-WINSXS'          = @((T 'Shrink the update storage'), (T 'Windows keeps replaced parts of old updates. Windows itself recommends a cleanup here.'))
    'CLN-DUMPS'           = @((T 'Delete crash reports of programs'), (T 'After crashes, programs leave large diagnostic files behind that only developers need.'))
    'CLN-BROWSER'         = @((T 'Empty large browser caches'), (T 'Browsers store copies of web pages and rebuild them by themselves. Only these copies are deleted - you stay signed in, and history, passwords and bookmarks are kept. Websites load a little slower the first time afterwards. Please close the browser first.'))
    'CLN-BIGFILES'        = @((T 'Large files in your folders'), (T 'WinTidy never deletes your own files. Here you see what takes up the most space in Downloads, Desktop, Documents and Videos - decide yourself what can go.'))
    'CLN-HIBERFIL'        = @((T 'Shrink the hibernation file'), (T 'On desktop PCs hibernation is hardly used, but the file often takes up many gigabytes. It is shrunk to the size fast startup needs – fast startup stays, hibernation and hybrid sleep are no longer available. Can be undone.'))
    'CLN-RECYCLE'         = @((T 'Permanently delete old files in the recycle bin'), (T 'Only files that have been in the recycle bin for a while. Recently deleted items stay recoverable.'))
    'CLN-RECYCLE-ORPHAN'  = @((T 'Empty recycle bins of old user accounts'), (T 'After a reinstall, invisible recycle bins of earlier accounts remain on the drives.'))
    'CLN-DRIVERSTORE'     = @((T 'Remove old driver versions'), (T 'With every driver update the old version stays behind. The current one is always kept, Windows protects drivers in use.'))
    'CLN-ORPHANDIR'       = @((T 'Folders without a matching program (expert)'), (T 'Folders that do not seem to belong to any installed program. May contain false positives – select carefully. They are only set aside first and can be brought back with "Restore" for some weeks.'))
    'CLN-QUARANTINE'      = @((T 'Delete folders set aside earlier'), (T 'Folders that WinTidy set aside a while ago and nobody has missed since. Now they are deleted for good.'))
    'CLN-DRIVERINSTALL'   = @((T 'Delete unpacked driver installers'), (T 'Graphics driver installers leave a copy of themselves on the drive, often several gigabytes. The installed driver keeps working without it.'))
    'CLN-PROFILE-ORPHAN'  = @((T 'Folders of old user accounts'), (T 'Folders of user accounts that no longer exist on this PC. They may still contain personal files - WinTidy does not delete them. Look inside and decide yourself.'))
    'STA-ORPHAN'          = @((T 'Remove broken startup entries'), (T 'These entries point to programs that no longer exist.'))
    'STA-APPROVED-ORPHAN' = @((T 'Clean up leftovers in startup'), (T 'Windows remembers settings for programs that were removed long ago.'))
    'STA-HEAVY'           = @((T 'Stop opening programs automatically at startup'), (T 'Every program that starts with Windows makes startup longer. The programs stay installed and can be opened normally. Antivirus, VPN, backup and cloud storage always stay on.'))
    'TSK-ORPHAN'          = @((T 'Turn off broken scheduled tasks'), (T 'These tasks regularly try to start programs that no longer exist.'))
    'TSK-ANTIPATTERN'     = @((T 'Scheduled tasks with unwanted side effects'), (T 'Tasks were set up on this PC that run regularly and slow the PC down or delete too much. WinTidy does not change them – please have the person who set them up adjust them.'))
    'SVC-ORPHAN'          = @((T 'Turn off broken background services'), (T 'Leftovers of uninstalled programs that try to run in vain at every startup.'))
    'APP-SIDEBYSIDE'      = @((T 'Clean up programs installed twice'), (T 'Several versions of these programs are installed. The newest stays. The uninstaller opens for each one.'))
    'APP-UPDATES'         = @((T 'Update programs'), (T 'Outdated programs are the most common entry point for malware. Please close all programs first – an update can close open programs.'))
    'SYS-GHOST'           = @((T 'Remove old device entries'), (T 'Devices that have not been connected for at least three months (e.g. old USB sticks, mice, monitors). If you plug them in again they are detected again – but their own settings (e.g. a fixed IP address) are lost.'))
    'SYS-SHADOW'          = @((T 'Increase the space for restore points'), (T 'Too little space means Windows silently deletes restore points.'))
    'SYS-TRIM'            = @((T 'Turn TRIM for the SSD back on'), (T 'Tells the SSD which storage is free and keeps it fast. Windows normally does this itself – here it was turned off, often by a tuning program.'))
    'SYS-MAINT'           = @((T 'Catch up on drive maintenance'), (T 'Windows normally keeps the drives fast once a week - here this has not happened for a while. Afterwards leave the PC on for about an hour.'))
    'SYS-REBOOT'          = @((T 'Restart Windows'), (T 'Updates and drivers often only take effect after a restart. "Shut down" is not enough because of fast startup - please choose "Restart".'))
    'SYS-INTEGRITY'       = @((T 'Check and repair Windows system files'), (T 'Checks whether Windows files are damaged and repairs them. Takes 10–30 minutes.'))
    'SYS-FSCHECK'         = @((T 'Check drives for errors'), (T 'Result of the file system check.'))
    'SYS-GAMEDVR'         = @((T 'Turn off background recording for games'), (T 'The Xbox Game Bar constantly records the last minutes in games, which can cost performance. It is off by default - if you switched it on to save game moments, leave it. You can still record clips yourself.'))
    'SYS-TWEAKS'          = @((T 'Unfavorable tuning settings'), (T 'Some tuning programs turn off Windows features that actually make the PC faster or safer. WinTidy shows them; someone who knows what they are doing should reset them.'))
    'SEC-HEALTH'          = @((T 'Security health check'), (T 'Shows in plain words whether the drive is encrypted, the security chip works, memory integrity is on and Defender is protected against tampering. WinTidy changes nothing here.'))
    'SYS-STORAGESENSE'    = @((T 'Windows Storage Sense'), (T 'Windows can clean up temporary files by itself. WinTidy only shows whether this is on and whether it also deletes old downloads. Nothing is changed.'))
    'SYS-AI'              = @((T 'AI features (Copilot, Recall)'), (T 'Shows whether Copilot is installed and whether Recall (screen history) is active. WinTidy only informs, you decide in the Windows settings.'))
    'SEC-EXECPOLICY'      = @((T 'Reset the protection setting for scripts'), (T 'Scripts downloaded from the internet then need a signature before they run; your own scripts keep working. If you write or run scripts yourself and set this on purpose, leave it. Can be undone.'))
    'SEC-CHECKS'          = @((T 'Security'), (T 'Updates and basic protection features of Windows and the PC.'))
    'HW-HINTS'            = @((T 'Hardware hints'), (T 'Settings that an expert can check. Please do not change anything in the BIOS if you are unsure.'))
    'HW-COOLING'          = @((T 'Cooling and temperatures'), (T 'Whether the processor, graphics card and drives get too warm, are throttled or whether a fan has stopped. Fan curves themselves live in the BIOS – WinTidy measures their effect.'))
    'HW-COOLPOLICY'       = @((T 'Spin up the fans first when it gets warm'), (T 'On mains power the fans should spin faster first before Windows throttles the processor. The setting here is "throttle first". Can be undone.'))
    'HW-DISPLAY'          = @((T 'Monitor'), (T 'Whether your monitor runs at the highest refresh rate it supports.'))
    'DBL-ADS'             = @((T 'Turn off ads and suggestions'), (T 'Windows suggests apps and Microsoft offers in Start, in Settings and on the lock screen and installs suggested apps by itself. This switches it off for you. Nothing else changes.'))
    'DBL-PRIVACY'         = @((T 'Limit tracking and personalisation'), (T 'Switches off personalisation that you can also turn off in Windows Settings under Privacy: advertising ID, tailored ads, online speech recognition and typing samples.'))
    'DBL-SHELL'           = @((T 'Tidy up Start menu and taskbar'), (T 'Takes away buttons and web results that many people do not use. A matter of taste – please tick only what bothers you. Changes appear after signing out and in again.'))
    'DBL-COMFORT'         = @((T 'Everyday annoyances'), (T 'Small settings that many people change after setting up Windows, for example always showing file extensions. A matter of taste.'))
    'DBL-APPS-PROMO'      = @((T 'Remove advertising apps'), (T 'Trial, game and streaming apps that came with the PC or were installed by Windows. If you use one of them yourself, leave it unchecked. Everything can be reinstalled from the Store.'))
    'DBL-APPS-MS'         = @((T 'Remove Microsoft apps you do not use'), (T 'Preinstalled Microsoft apps such as news, finance or Phone Link. Please look at each one: if you use it, leave it unchecked. Everything can be reinstalled from the Store.'))
    'DBL-APPS-OEM'        = @((T 'Remove apps from the PC maker (expert)'), (T 'Support and welcome apps of PC makers. Some of them also deliver drivers, BIOS updates or warranty functions – remove only what you are sure you do not need.'))
    'EVT-HEALTH'          = @((T 'Warning messages from Windows'), (T 'Windows noted problems in the last 30 days, e.g. crashes or sudden power-offs. Single entries are no reason to worry. If they occur often, have the PC checked.'))
}
# Medium rules that the app preselects as a whole. Since 1.9 the items say it themselves (AutoOk = $true), which also
# releases them for -Yes -IncludeMedium. Final actions (deleting, uninstalling, removing devices, updates) deliberately not.
$Script:GuiPreselectMedium = @()
# Readable area names for the progress of the check (no action verbs like "delete")
$Script:AreaNames = @{ 'Speicher' = (T 'storage space'); 'Autostart' = (T 'programs at startup'); 'Aufgaben' = (T 'scheduled tasks'); 'Dienste' = (T 'background services'); 'Programme' = (T 'installed software'); 'System' = (T 'Windows system'); 'Sicherheit' = (T 'security settings'); 'Hardware' = (T 'hardware and cooling'); 'Stabilitaet' = (T 'Windows warning messages') }
$Script:LastFindings = @()

$Script:LastContext = $null

# May this rule be offered in the current context? (company PC: only safe cleanup items and hints)
function Test-RuleAllowed($r, $ctx) {
    if (-not $ctx -or -not $ctx.Verwaltet) { return $true }
    return ($r.Risiko -eq 'Info' -or ($r.Kategorie -eq 'Speicher' -and $r.Risiko -eq 'Niedrig') -or $r.Id -eq 'SYS-TRIM')
}

# Page '' = the normal check (all standard rules); Page 'Debloat' = only the rules of that page (own tab in the app)
function Get-AllFindings([bool]$Expert = $false, [scriptblock]$OnProgress = $null, [string]$Page = '') {
    $Script:Cache = @{}
    $Script:Preview = $true
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    $Script:LastContext = $ctx
    $rules = @($Script:Rules | Where-Object { $(if ($Page) { $_.Seite -eq $Page } else { ($_.Standard -or $Expert) -and -not $_.Seite }) -and (Test-RuleAllowed $_ $ctx) })
    $res = New-Object System.Collections.Generic.List[object]
    # Measure hardware first while the PC is still idle
    if (-not $Page) {
        if ($OnProgress) { try { & $OnProgress 0 $rules.Count (T 'Checking: hardware and cooling …') } catch { } }
        try { $null = Get-HardwarePoints } catch { }
    }
    $i = 0
    foreach ($r in $rules) {
        $i++
        $fr = $Script:Friendly[$r.Id]; $titel = if ($fr) { $fr[0] } else { $r.Titel }; $text = if ($fr) { $fr[1] } else { $r.Warum }
        $bereich = if ($Script:AreaNames.ContainsKey([string]$r.Kategorie)) { $Script:AreaNames[[string]$r.Kategorie] } else { [string]$r.Kategorie }
        if ($OnProgress) { try { & $OnProgress $i $rules.Count ((T 'Checking: {0} …') -f $bereich) } catch { } }
        if ($r.Admin -and -not $Script:IsAdmin) { continue }
        $items = @()
        try { $items = @(& $r.Detect | Where-Object { $_ }) } catch { W (T 'Check {0} failed: {1}' ($r.Id) ($_.Exception.Message)) 'Red'; continue }
        W ((T '{0}: {1} finding(s)') -f $r.Id, $items.Count) 'Gray'
        if (-not $items.Count) { continue }
        $k = 0
        $its = foreach ($it in $items) {
            $pre = $false
            if ($r.Risiko -eq 'Niedrig') { $pre = ($r.Vorwahl -ne $false) }
            elseif ($r.Risiko -eq 'Mittel') {
                $pre = ($Script:GuiPreselectMedium -contains $r.Id) -or [bool]$it.AutoOk
            }
            # Do not preselect long steps while the PC runs on battery
            if ($r.Dauer -and $ctx -and $ctx.Akku) { $pre = $false }
            $stufe = ''
            if ($it.Data -and ($it.Data -is [System.Collections.IDictionary] -or $it.Data -is [pscustomobject]) -and $it.Data.Stufe) { $stufe = [string]$it.Data.Stufe }
            [pscustomobject]@{ Index = $k; Label = $it.Label; Bytes = [int64]$it.Bytes; Vorauswahl = $pre; Selected = $pre; Stufe = $stufe; Technik = $it.Technik; Raw = $it }
            $k++
        }
        $res.Add([pscustomobject]@{ Id = $r.Id; Kategorie = $r.Kategorie; Titel = $titel; Text = $text; Warum = $r.Warum; Risiko = $r.Risiko; Fixbar = [bool]$r.Fix; Bytes = [int64](($items | Measure-Object Bytes -Sum).Sum); Items = @($its)
                Dauer = $r.Dauer; Endgueltig = $r.Endgueltig; Einzeln = $r.Einzeln; Umkehrbar = $r.Umkehrbar; Seite = $r.Seite })
    }
    # The findings of the other page stay available for Invoke-FixSelection
    $keep = @($Script:LastFindings | Where-Object { $(if ($Page) { $_.Seite -ne $Page } else { $_.Seite }) })
    $Script:LastFindings = @($res.ToArray()) + $keep
    return $res.ToArray()
}

function ConvertTo-Befunde($findings, [switch]$NurInfo) {
    @($findings | Where-Object { -not $NurInfo -or -not $_.Fixbar } | ForEach-Object { [pscustomobject]@{ Regel = $_.Id; Kategorie = $_.Kategorie; Titel = $_.Titel; Risiko = $_.Risiko; Anzahl = $_.Items.Count; Bytes = $(if ($NurInfo) { 0 } else { $_.Bytes }); Objekte = @($_.Items | ForEach-Object { $_.Label }); Stufen = @($_.Items | ForEach-Object { [string]$_.Stufe }); Bereiche = @($_.Items | ForEach-Object { if ($_.Raw.Data -is [System.Collections.IDictionary]) { [string]$_.Raw.Data.Bereich } else { '' } }); Wertungen = @($_.Items | ForEach-Object { if ($_.Raw.Data -is [System.Collections.IDictionary]) { [string]$_.Raw.Data.Wertung } else { '' } }) } })
}

function Invoke-GuiScan([bool]$Expert = $false, [bool]$DeepScan = $false, [scriptblock]$OnProgress = $null) {
    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Set-Variable -Name Deep -Value ([bool]$DeepScan) -Scope Script
    Start-RunLog 'scan'
    try {
        $f = Get-AllFindings $Expert $OnProgress
        if ($OnProgress) { try { & $OnProgress 1 1 (T 'Almost done: measuring the state of your PC …') 'CORE' } catch { } }
        $snap = New-Snapshot 'scan' (ConvertTo-Befunde $f)
        $rep = New-Report
    } finally { Stop-RunLog }
    [pscustomobject]@{ Findings = $f; Snapshot = $snap; Report = $rep; Context = $Script:LastContext }
}

# "Debloat" page of the app: only the rules of that page (registry values and the app list, takes a few seconds).
# Hinweis = text for the page if nothing is offered because of the context.
function Invoke-GuiDebloatScan([scriptblock]$OnProgress = $null) {
    $f = @(Get-AllFindings $false $OnProgress 'Debloat')
    $ctx = $Script:LastContext
    $hint = ''
    if ($ctx -and $ctx.Server) { $f = @(); $hint = (T 'WinTidy makes no changes on Windows Server.') }
    elseif ($ctx -and $ctx.Verwaltet) { $hint = (T 'This PC is managed by an organization. Its settings are controlled by the organization, so WinTidy offers nothing on this page.') }
    elseif ($ctx -and $ctx.AnderesKonto) { $hint = (T 'WinTidy runs under a different account than the one that is signed in. Settings and apps would end up in the wrong profile, so nothing is offered. Start WinTidy while signed in with your own account.') }
    [pscustomobject]@{ Findings = $f; Hinweis = $hint; Context = $ctx }
}

function New-RestorePointSilent {
    $err = Invoke-Checkpoint
    if (-not $err) { W (T 'Restore point created.') 'Green'; return $true }
    W (T 'Restore point failed: {0}' $err) 'Red'; return $false
}

# Selection: list of @{ Id = 'RULE'; Indexes = @(0,2,...) }
# Status: OK | ABGEBROCHEN | RP-FEHLT (nothing changed, the app asks and calls again with OhneRP) | GESPERRT
function Invoke-FixSelection([object[]]$Selection, [bool]$RestorePoint = $true, [scriptblock]$OnProgress = $null, $Control = $null, [bool]$OhneRP = $false) {
    function Prog($i, $n, $t, $id) { if ($OnProgress) { try { & $OnProgress $i $n $t $id } catch { } } }
    # Measure fresh: the power adapter may have been unplugged since the check
    $Script:Cache = @{}
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    if (-not $ctx -or $ctx.Server) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = (T 'WinTidy makes no changes on Windows Server.') } }
    if (-not $Script:IsAdmin) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = (T 'WinTidy needs administrator rights for changes.') } }

    # Collect the jobs (no change yet)
    $jobs = @()
    foreach ($s in $Selection) {
        $f = $Script:LastFindings | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1
        $r = $Script:Rules | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1
        if (-not $f -or -not $r -or -not $r.Fix -or -not (Test-RuleAllowed $r $ctx)) { continue }
        foreach ($ix in @($s.Indexes)) { $it = $f.Items | Where-Object { $_.Index -eq [int]$ix } | Select-Object -First 1; if ($it) { $jobs += [pscustomobject]@{ Rule = $r; Titel = $f.Titel; Item = $it } } }
    }

    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $Script:Preview = $false
    if (-not $OhneRP) { $Script:ComputerschutzEingeschaltet = $false }   # with OhneRP keep the hint from the first attempt
    Start-RunLog 'apply'
    $rp = $null
    if ($RestorePoint -and -not $OhneRP) {
        Prog 0 1 (T 'Creating a restore point ...') 'CORE'
        $err = Invoke-Checkpoint
        if ($err) {
            W (T 'Restore point failed: {0}' $err) 'Red'
            # Nothing was changed: remove the run folder again so that no empty run appears in the history
            Stop-RunLog
            try { Remove-Item -LiteralPath $Script:RunDir -Recurse -Force -ErrorAction Stop } catch { }
            $Script:RunDir = $null
            return [pscustomobject]@{ Status = 'RP-FEHLT'; Meldung = [string]$err; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet }
        }
        $rp = $true
        W (T 'Restore point created.') 'Green'
        Add-ActionRecord 'CORE' (T 'Restore point') 'OK' | Out-Null
    } elseif ($RestorePoint -and $OhneRP) {
        $rp = $false
        Add-ActionRecord 'CORE' (T 'Restore point') 'Uebersprungen' 0 (T 'Confirmed by the user without a restore point') | Out-Null
    }

    # Cancelled while creating the restore point: nothing changed, no more measurements
    if ($Control -and $Control.Cancel) {
        $det0 = @($jobs | ForEach-Object { [pscustomobject]@{ Titel = $_.Titel; Objekt = [string]$_.Item.Label; Status = 'Abgebrochen'; Meldung = (T 'Not carried out (cancelled)') } })
        [ordered]@{ Lauf = $Script:RunId; Aktionen = $jobs.Count; OK = 0; Fehler = 0; Abgebrochen = $true; BytesGeschaetzt = 0; Wiederherstellungspunkt = $rp; Umkehrbar = 0 } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
        Stop-RunLog
        return [pscustomobject]@{ Status = 'ABGEBROCHEN'; RunId = $Script:RunId; Aktionen = $jobs.Count; OK = 0; Fehler = 0; Bytes = 0; Vorher = $null; Nachher = $null; Vergleich = @(); Report = $null; Wiederherstellungspunkt = $rp; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet; Details = $det0; Umkehrbar = 0 }
    }
    W (T 'Measuring state before ...') 'Cyan'
    Prog 0 1 (T 'Measuring the state before ...') 'CORE'
    $info = ConvertTo-Befunde $Script:LastFindings -NurInfo
    $pre = New-Snapshot 'vorher' $info

    $ok = 0; $fail = 0; $bytes = 0; $n = 0; $abbruch = $false
    $details = New-Object System.Collections.Generic.List[object]
    foreach ($j in $jobs) {
        $n++
        $lbl = [string]$j.Item.Label
        if ($abbruch -or ($Control -and $Control.Cancel)) {
            $abbruch = $true
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Abgebrochen'; Meldung = (T 'Not carried out (cancelled)') })
            Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 'Abgebrochen' | Out-Null
            continue
        }
        if ($j.Rule.Dauer -and $ctx -and $ctx.Akku) {
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Uebersprungen'; Meldung = (T 'Running on battery – this long step only runs with the power adapter connected') })
            Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 (T 'On battery') | Out-Null
            continue
        }
        Prog $n $jobs.Count ("{0}: {1}" -f $j.Titel, $lbl) $j.Rule.Id
        try {
            $msg = & $j.Rule.Fix $j.Item.Raw
            $ok++; $bytes += $j.Item.Bytes
            W ("OK  [{0}] {1}  {2}" -f $j.Rule.Id, $lbl, $msg) 'Green'
            Add-ActionRecord $j.Rule.Id $lbl 'OK' $j.Item.Bytes ([string]$msg) | Out-Null
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'OK'; Meldung = [string]$msg })
        } catch {
            $em = $_.Exception.Message
            if ($em -like 'SKIP:*') {
                # Expected, not an error (e.g. driver still in use, uninstall cancelled)
                W ("--  [{0}] {1}: {2}" -f $j.Rule.Id, $lbl, $em.Substring(5)) 'DarkYellow'
                Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 $em.Substring(5) | Out-Null
                $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Uebersprungen'; Meldung = $em.Substring(5) })
                continue
            }
            $fail++
            W ((T 'ERROR  [{0}] {1}: {2}') -f $j.Rule.Id, $lbl, $em) 'Red'
            Add-ActionRecord $j.Rule.Id $lbl 'Fehler' 0 $em | Out-Null
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Fehler'; Meldung = $em })
        }
    }
    $Script:Cache = @{}
    Prog $jobs.Count $jobs.Count (T 'Measuring the state after ...') 'CORE'
    $post = New-Snapshot 'nachher' $info
    $cmp = @(Get-CompareMetrics $pre $post)
    $wirkung = $null; try { $wirkung = Get-PerfEffect $pre $post @() } catch { W (T '  Key figures could not be compared: {0}' ($_.Exception.Message)) 'DarkYellow' }
    $umk = @(Get-RestorePreview $Script:RunId).Count
    [ordered]@{ Lauf = $Script:RunId; Aktionen = $jobs.Count; OK = $ok; Fehler = $fail; Abgebrochen = $abbruch; BytesGeschaetzt = $bytes; ScoreVorher = $pre.Score.Wert; ScoreNachher = $post.Score.Wert; Wiederherstellungspunkt = $rp; Umkehrbar = $umk; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
    $rep = New-Report
    Stop-RunLog
    [pscustomobject]@{ Status = $(if ($abbruch) { 'ABGEBROCHEN' } else { 'OK' }); RunId = $Script:RunId; Aktionen = $jobs.Count; OK = $ok; Fehler = $fail; Bytes = $bytes; Vorher = $pre; Nachher = $post; Vergleich = $cmp; Wirkung = $wirkung; Report = $rep
        Wiederherstellungspunkt = $rp; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet; Details = $details.ToArray(); Umkehrbar = $umk }
}

function Get-RunList {
    @(Get-ChildItem $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name | ForEach-Object {
        $z = Join-Path $_.FullName 'zusammenfassung.json'; $sum = $null; if (Test-Path $z) { try { $sum = Get-Content $z -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        $lauf = $_.Name -replace '_apply$', ''
        $umk = if ($sum -and $null -ne $sum.Umkehrbar) { [int]$sum.Umkehrbar } else { @(Get-RestorePreview $lauf).Count }
        $rg = $null; $rf = Join-Path $_.FullName 'rueckgaengig.json'; if (Test-Path -LiteralPath $rf) { try { $rg = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        [pscustomobject]@{ Lauf = $lauf; Zeit = [datetime]::ParseExact(($_.Name.Substring(0, 15)), 'yyyyMMdd-HHmmss', $null); Zusammenfassung = $sum; Umkehrbar = $umk; RueckgaengigAm = $(if ($rg) { $rg.Zeit } else { $null }) }
    })
}

function Get-HistoryData {
    $snaps = @(Get-Snapshots | ForEach-Object { Read-Snapshot $_ })
    $boots = @(); $seen = @{}
    foreach ($s in $snaps) { foreach ($b in @($s.Boot.Verlauf)) { if ($b -and -not $seen.ContainsKey($b.Zeit)) { $seen[$b.Zeit] = 1; $boots += $b } } }
    $ph = Read-SnapshotHistory
    [pscustomobject]@{ Snapshots = $snaps; Boots = @($boots | Sort-Object { [datetime]$_.Zeit }); Perf = $ph.Punkte; Effekt = $ph.Effekt; Defs = $ph.Defs; Kopfzeile = $ph.Kopfzeile; Laeufe = (Get-RunList); Report = (Join-Path $Script:DataDir 'WinTidy-Bericht.html'); DataDir = $Script:DataDir }
}

# Like Get-HistoryData, but without the full snapshots (small data transfer to the app)
function Get-HistoryLight {
    $h = Read-SnapshotHistory
    [pscustomobject]@{ Scores = $h.Scores; Snapshots = @(); Boots = $h.Boots; Perf = $h.Punkte; Effekt = $h.Effekt; Defs = $h.Defs; Kopfzeile = $h.Kopfzeile; Laeufe = (Get-RunList); Report = (Join-Path $Script:DataDir 'WinTidy-Bericht.html'); DataDir = $Script:DataDir }
}

function Invoke-GuiRestore([string]$Lauf) {
    $Script:RestoreRunId = $Lauf
    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Start-RunLog 'restore'
    try { $r = Invoke-Restore } finally { Stop-RunLog }
    return $r
}

# Cooling test for the app (own run folder for the log)
function Invoke-GuiCoolingTest([int]$Seconds = 0, [scriptblock]$OnProgress = $null, $Control = $null) {
    if ($Seconds -le 0) { $Seconds = [int]$Script:Cfg.CoolingTestSeconds }
    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Start-RunLog 'kuehltest'
    try { $r = Invoke-CoolingTest $Seconds $OnProgress $Control } finally { Stop-RunLog }
    return $r
}

# =============================================================================
#  Updates (releases on GitHub)
#  WinTidy only updates itself on request (app setting "Update WinTidy automatically" or -Mode Update). It downloads the
#  ZIP of the latest release, verifies it (checksum, allowed file types, syntax, version), keeps a copy of the old files
#  and then replaces the program files. This needs admin rights: the download is staged in the protected data folder,
#  so that programs without admin rights cannot swap it between the check and the installation.
# =============================================================================
$Script:UpdateHostPattern = '(^|\.)(github\.com|githubusercontent\.com)$'
$Script:UpdateMaxZipBytes = 20MB
$Script:UpdateMaxFileBytes = 10MB
$Script:UpdateMaxFiles = 100
$Script:PendingUpdate = $null

# 'v1.4.2' or '1.4.2' -> [version]; anything else (pre-release suffixes, text) -> $null
function ConvertTo-WtVersion([string]$Text) {
    if ($Text -match '^v?(\d{1,4})\.(\d{1,4})\.(\d{1,4})$') { return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
    return $null
}

# Reason why this copy of WinTidy cannot update itself (translated text), $null if it can
function Get-WtUpdateBlocker {
    if (-not [bool]$Script:Cfg.UpdateEnabled) { return (T 'Updates are switched off in the configuration (UpdateEnabled).') }
    if (-not $Script:IsAdmin) { return (T 'Updating needs administrator rights.') }
    if (-not $Script:DataDirProtected) { return (T 'Updating works only with the protected data folder (not with -DataPath).') }
    $root = [string]$Script:ToolRoot
    $net = ($root -like '\\*')
    try { if ($root -match '^([A-Za-z]):' -and ([string](New-Object IO.DriveInfo ($Matches[1])).DriveType) -eq 'Network') { $net = $true } } catch { }
    if ($net) { return (T 'WinTidy is on a network drive. Please copy it to this PC first.') }
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { return (T 'This copy of WinTidy is a git clone. Please update it with "git pull".') }
    try {
        $probe = Join-Path $root ('.wt-write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x'); [IO.File]::Delete($probe)
    } catch { return (T 'WinTidy is not allowed to change its own folder.') }
    return $null
}

function Add-WtUpdateLog([string]$Text) {
    try {
        $d = Join-Path $Script:DataDir 'update'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $f = Join-Path $d 'update.log'
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 200KB) { Remove-Item -LiteralPath $f -Force }
        ('{0}  {1}' -f (Get-Date -Format 's'), $Text) | Out-File -LiteralPath $f -Append -Encoding utf8
    } catch { }
}

# Opens an https address. Redirects are followed by hand and only to GitHub hosts. The caller closes the response.
function Open-WtHttp([string]$Url, [string]$Accept = '*/*', [int]$TimeoutSec = 20) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }   # TLS 1.2 (Windows PowerShell 5.1 may default to older protocols)
    for ($hop = 0; $hop -lt 6; $hop++) {
        $u = $null
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -ne 'https' -or $u.Host -notmatch $Script:UpdateHostPattern) { throw (T 'Blocked address: {0}' $Url) }
        $req = [Net.HttpWebRequest][Net.WebRequest]::Create($u)
        $req.UserAgent = 'WinTidy/' + $Script:Version
        $req.Accept = $Accept
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $false
        try { $req.Proxy = [Net.WebRequest]::GetSystemWebProxy(); $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials } catch { }
        $resp = $null
        try { $resp = [Net.HttpWebResponse]$req.GetResponse() }
        catch [Net.WebException] { if ($_.Exception.Response) { $resp = [Net.HttpWebResponse]$_.Exception.Response } else { throw } }
        $code = [int]$resp.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $loc = [string]$resp.Headers['Location']
            $resp.Close()
            if (-not $loc) { throw (T 'The server answered with status {0}.' $code) }
            $Url = (New-Object System.Uri -ArgumentList $u, $loc).AbsoluteUri
            continue
        }
        if ($code -ne 200) { $resp.Close(); throw (T 'The server answered with status {0}.' $code) }
        return $resp
    }
    throw (T 'Too many redirects.')
}

# Small text download (release information, checksum file)
function Get-WtHttpText([string]$Url, [string]$Accept = '*/*', [int]$MaxBytes = 1MB) {
    $resp = Open-WtHttp $Url $Accept 10   # short timeout: the app waits for this check
    try {
        $in = $resp.GetResponseStream()
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 16384
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt $MaxBytes) { throw (T 'The download is larger than expected.') }
        }
        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally { $resp.Close() }
}

# File download with a size limit
function Save-WtHttpFile([string]$Url, [string]$Path, [int64]$MaxBytes) {
    $resp = Open-WtHttp $Url 'application/octet-stream' 60
    try {
        if ($resp.ContentLength -gt $MaxBytes) { throw (T 'The download is larger than expected.') }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($Path)
        try {
            $buf = New-Object byte[] 65536
            $total = [int64]0
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $total += $n
                if ($total -gt $MaxBytes) { throw (T 'The download is larger than expected.') }
                $out.Write($buf, 0, $n)
            }
        } finally { $out.Dispose() }
    } finally { $resp.Close() }
}

# Latest published release of the configured repository (network access). The tests replace this function.
function Get-LatestRelease {
    $json = Get-WtHttpText ('https://api.github.com/repos/{0}/releases/latest' -f [string]$Script:Cfg.UpdateRepo) 'application/vnd.github+json'
    $j = $json | ConvertFrom-Json
    $ver = ConvertTo-WtVersion ([string]$j.tag_name)
    if (-not $ver -or $j.draft -or $j.prerelease) { return $null }
    $zipName = 'WinTidy-v{0}.zip' -f $ver
    $zip = @($j.assets | Where-Object { $_.name -eq $zipName }) | Select-Object -First 1
    if (-not $zip) { return $null }
    $sha = @($j.assets | Where-Object { $_.name -eq ($zipName + '.sha256') }) | Select-Object -First 1
    $dig = ''
    if ($zip.digest -and ([string]$zip.digest) -match '^sha256:([0-9a-fA-F]{64})$') { $dig = $Matches[1] }
    [pscustomobject]@{
        Tag = [string]$j.tag_name; Version = $ver; ZipUrl = [string]$zip.browser_download_url; ZipSize = [int64]$zip.size; Digest = $dig
        ShaUrl = $(if ($sha) { [string]$sha.browser_download_url } else { '' }); Notes = [string]$j.body; PageUrl = [string]$j.html_url
    }
}

# Which files may be part of an update package: a few text file types in the program folder or one subfolder (e.g. lang/)
function Test-WtUpdatePath([string]$Rel) {
    if (-not $Rel -or $Rel -match '\.\.') { return $false }
    if ($Rel -eq 'WinTidy.config.local.json') { return $false }   # personal settings of this PC: never part of an update
    if ($Rel -eq 'LICENSE') { return $true }
    if (-not ($Rel -match '^([A-Za-z0-9][A-Za-z0-9_\-]*/)?([A-Za-z0-9][A-Za-z0-9 _.\-]*)\.(ps1|psd1|cmd|json|md|txt)$')) { return $false }
    if ($Matches[2] -match '(^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\.|$))|[ .]$') { return $false }   # reserved device names, trailing space or dot
    return $true
}

# Unpacks the release ZIP into $Dest. Every entry name is checked first; returns the relative paths (with /).
function Expand-WtUpdateZip([string]$Zip, [string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction Stop
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($z.Entries | Where-Object { $_.FullName -and -not $_.FullName.EndsWith('/') -and -not $_.FullName.EndsWith('\') })
        if ($entries.Count -eq 0 -or $entries.Count -gt $Script:UpdateMaxFiles) { throw (T 'The package has an unexpected number of files.') }
        $names = @($entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        # the release ZIP has one top folder (WinTidy-vX.Y.Z); it is removed
        $top = ($names[0] -split '/')[0]
        $strip = $names[0].Contains('/') -and (@($names | Where-Object { -not $_.StartsWith($top + '/') }).Count -eq 0)
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\', '/') + [string][IO.Path]::DirectorySeparatorChar
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $list = New-Object System.Collections.Generic.List[string]
        $total = [int64]0
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $rel = $names[$i]
            if ($strip) { $rel = $rel.Substring($top.Length + 1) }
            if (-not (Test-WtUpdatePath $rel) -or -not $seen.Add($rel)) { throw (T 'The package contains an unexpected file: {0}' $rel) }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($Dest, $rel))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { throw (T 'The package contains an unexpected file: {0}' $rel) }
            if ($entries[$i].Length -gt $Script:UpdateMaxFileBytes) { throw (T 'The download is larger than expected.') }
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
            $in = $entries[$i].Open()
            $out = [IO.File]::Create($target)
            try {
                $buf = New-Object byte[] 65536
                $size = [int64]0
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $size += $n; $total += $n
                    if ($size -gt $Script:UpdateMaxFileBytes -or $total -gt $Script:UpdateMaxZipBytes) { throw (T 'The download is larger than expected.') }
                    $out.Write($buf, 0, $n)
                }
            } finally { $out.Dispose(); $in.Dispose() }
            $list.Add($rel)
        }
        return , $list.ToArray()
    } finally { $z.Dispose() }
}

# Checks the unpacked package; returns an error text, or $null if it is usable
function Test-WtUpdatePackage([string]$Dir, [string[]]$Files, $Version) {
    foreach ($req in 'WinTidy.ps1', 'WinTidy-App.ps1', 'lang/de.psd1') {
        if ($Files -notcontains $req) { return (T 'The package is incomplete: {0} is missing.' $req) }
    }
    foreach ($f in $Files) {
        if ($f -match '\.(ps1|psd1)$') {
            $err = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($Dir, $f), [ref]$null, [ref]$err)
            if ($err -and $err.Count) { return (T 'The package contains a file with a syntax error: {0}' $f) }
        }
    }
    $txt = [IO.File]::ReadAllText([IO.Path]::Combine($Dir, 'WinTidy.ps1'))
    $m = [regex]::Match($txt, "(?m)^\`$Script:Version = '([^']+)'")
    if (-not $m.Success -or (ConvertTo-WtVersion $m.Groups[1].Value) -ne $Version) { return (T 'The version in the package does not match the release.') }
    return $null
}

# Puts the old files back after a failed or interrupted installation (journal.json lists what the installation touched)
function Undo-WtUpdateFiles([string]$Upd) {
    $jf = Join-Path $Upd 'journal.json'
    if (-not (Test-Path -LiteralPath $jf)) { return $false }
    $ok = $true
    try {
        $j = Get-Content -LiteralPath $jf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.Fertig) { Remove-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue; return $false }   # installation was complete, only the cleanup is left
        $bk = Join-Path (Join-Path $Upd 'backup') ([string]$j.Von)
        foreach ($f in @($j.Dateien)) {
            $rel = [string]$f.Pfad
            if (-not (Test-WtUpdatePath $rel)) { continue }
            $dest = [IO.Path]::Combine([string]$Script:ToolRoot, $rel)
            try {
                if ([bool]$f.Vorhanden) { [IO.File]::Copy([IO.Path]::Combine($bk, $rel), $dest, $true) }
                elseif (Test-Path -LiteralPath $dest -PathType Leaf) { [IO.File]::Delete($dest) }
                foreach ($ext in '.wtnew', '.wtold') { if (Test-Path -LiteralPath ($dest + $ext)) { [IO.File]::Delete($dest + $ext) } }
            } catch { $ok = $false }
        }
    } catch { $ok = $false }
    if ($ok) { Remove-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue; Add-WtUpdateLog 'Rolled back an unfinished installation' }
    return $ok
}

# --- Interface for the app and the command line: check -> stage (download + verify) -> apply (replace files) ---

# Status: AKTUELL | NEU | GESPERRT | FEHLER (internal values stay German); Meldung is the text for the user
function Invoke-GuiUpdateCheck {
    $Script:PendingUpdate = $null
    $blocker = Get-WtUpdateBlocker
    if ($blocker) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = $blocker; Aktuell = [string]$Script:Version } }
    $rel = $null
    try {
        $null = Undo-WtUpdateFiles (Join-Path $Script:DataDir 'update')
        $rel = Get-LatestRelease
    } catch {
        Add-WtUpdateLog ('Check failed: ' + $_.Exception.Message)
        return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'The update check failed: {0}' ($_.Exception.Message)); Aktuell = [string]$Script:Version }
    }
    $cur = ConvertTo-WtVersion ([string]$Script:Version)
    if (-not $cur) { return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'The installed version number is not readable.'); Aktuell = [string]$Script:Version } }
    if (-not $rel) { return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'No installable release was found.'); Aktuell = [string]$Script:Version } }
    if ($rel.Version -le $cur) { return [pscustomobject]@{ Status = 'AKTUELL'; Meldung = ''; Aktuell = [string]$Script:Version } }
    $Script:PendingUpdate = $rel
    $notes = [string]$rel.Notes
    if ($notes.Length -gt 700) { $notes = $notes.Substring(0, 700) + ' …' }
    return [pscustomobject]@{ Status = 'NEU'; Meldung = ''; Aktuell = [string]$Script:Version; Neu = [string]$rel.Version; Notizen = $notes; Seite = [string]$rel.PageUrl }
}

# Downloads the release found by the last check, verifies it and unpacks it into the protected data folder.
# Status: BEREIT | GESPERRT | FEHLER. Nothing in the program folder is changed.
function Invoke-GuiUpdateStage {
    $blocker = Get-WtUpdateBlocker
    if ($blocker) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = $blocker } }
    $rel = $Script:PendingUpdate
    if (-not $rel) { return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'Please check for updates first.') } }
    $upd = Join-Path $Script:DataDir 'update'
    $stage = Join-Path $upd 'staged'
    $dl = Join-Path $upd 'download'
    try {
        $prefix = 'https://github.com/{0}/releases/download/' -f [string]$Script:Cfg.UpdateRepo
        if (-not ([string]$rel.ZipUrl).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or ($rel.ShaUrl -and -not ([string]$rel.ShaUrl).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) { throw (T 'The release points to an unexpected address.') }
        if ($rel.ZipSize -le 0 -or $rel.ZipSize -gt $Script:UpdateMaxZipBytes) { throw (T 'The download is larger than expected.') }
        # Expected checksum: GitHub's digest of the asset and/or the .sha256 file of the release. At least one is required;
        # if both exist they must agree.
        $expected = New-Object System.Collections.Generic.List[string]
        if ($rel.Digest) { $expected.Add(([string]$rel.Digest).ToLower()) }
        if ($rel.ShaUrl) {
            $txt = Get-WtHttpText ([string]$rel.ShaUrl) 'text/plain' 4096
            $m = [regex]::Match($txt, '(?i)\b([0-9a-f]{64})\b')
            if (-not $m.Success) { throw (T 'The checksum file of the release is not readable.') }
            $expected.Add($m.Groups[1].Value.ToLower())
        }
        if ($expected.Count -eq 0) { throw (T 'The release has no checksum and is not installed.') }
        if (@($expected | Select-Object -Unique).Count -gt 1) { throw (T 'The checksums of the release do not match each other.') }
        foreach ($p in $stage, $dl) { if (Test-Path -LiteralPath $p) { Remove-TreeNoFollow $p } }
        New-Item -ItemType Directory -Force -Path $dl, $stage | Out-Null
        $zip = Join-Path $dl ('WinTidy-v{0}.zip' -f $rel.Version)
        Save-WtHttpFile ([string]$rel.ZipUrl) $zip $Script:UpdateMaxZipBytes
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $expected[0]) { throw (T 'The checksum of the download is wrong. It is not installed.') }
        $files = [string[]](Expand-WtUpdateZip $zip (Join-Path $stage 'files'))   # (the function returns the array wrapped on purpose; @() would nest it)
        $err = Test-WtUpdatePackage (Join-Path $stage 'files') $files $rel.Version
        if ($err) { throw $err }
        $list = @($files | ForEach-Object { [ordered]@{ Pfad = $_; Sha256 = (Get-FileHash -LiteralPath ([IO.Path]::Combine($stage, 'files', $_)) -Algorithm SHA256).Hash.ToLower() } })
        [ordered]@{ Version = [string]$rel.Version; Tag = [string]$rel.Tag; Zeit = (Get-Date).ToString('o'); Dateien = $list } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $stage 'staged.json') -Encoding utf8
        Remove-TreeNoFollow $dl
        Add-WtUpdateLog ('Downloaded and verified version {0}' -f $rel.Version)
        return [pscustomobject]@{ Status = 'BEREIT'; Version = [string]$rel.Version; Meldung = '' }
    } catch {
        $msg = $_.Exception.Message
        foreach ($p in $stage, $dl) { try { if (Test-Path -LiteralPath $p) { Remove-TreeNoFollow $p } } catch { } }
        Add-WtUpdateLog ('Download failed: ' + $msg)
        return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'The update could not be downloaded: {0}' $msg) }
    }
}

# Replaces the program files with the staged version. Keeps a copy of the old files, never overwrites an existing
# WinTidy.config.json, and rolls everything back if a step fails. Status: OK | GESPERRT | FEHLER.
function Invoke-GuiUpdateApply {
    $blocker = Get-WtUpdateBlocker
    if ($blocker) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = $blocker } }
    $upd = Join-Path $Script:DataDir 'update'
    $stage = Join-Path $upd 'staged'
    $files = Join-Path $stage 'files'
    $journal = Join-Path $upd 'journal.json'
    $tmpFiles = New-Object System.Collections.Generic.List[string]
    $swapStarted = $false
    try {
        $mf = Join-Path $stage 'staged.json'
        if (-not (Test-Path -LiteralPath $mf)) { throw (T 'There is no downloaded update to install.') }
        if (-not (Test-WtDataRootSafe $stage)) { throw (T 'The data folder is not protected. The update is not installed.') }
        $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        $new = ConvertTo-WtVersion ([string]$m.Version)
        $cur = ConvertTo-WtVersion ([string]$Script:Version)
        if (-not $new -or -not $cur -or $new -le $cur) { throw (T 'The downloaded version is not newer than the installed one.') }
        # Check every staged file against the checksum recorded at download time and decide what has to be replaced
        $plan = New-Object System.Collections.Generic.List[object]
        foreach ($f in @($m.Dateien)) {
            $rel = [string]$f.Pfad
            if (-not (Test-WtUpdatePath $rel)) { throw (T 'The package contains an unexpected file: {0}' $rel) }
            $src = [IO.Path]::Combine($files, $rel)
            if (-not (Test-Path -LiteralPath $src -PathType Leaf) -or ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne [string]$f.Sha256)) { throw (T 'A downloaded file was changed. The update is not installed.') }
            $dest = [IO.Path]::Combine([string]$Script:ToolRoot, $rel)
            $exists = Test-Path -LiteralPath $dest -PathType Leaf
            # The shipped configuration may contain own settings: never overwritten. Unchanged files stay as they are.
            if ($rel -eq 'WinTidy.config.json' -and $exists) { continue }
            if ($exists -and ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq [string]$f.Sha256)) { continue }
            $plan.Add([pscustomobject]@{ Rel = $rel; Src = $src; Dest = $dest; Exists = $exists })
        }
        # Engine last: its version number marks the update as done. Other files first.
        $order = @($plan | Sort-Object @{ Expression = { if ($_.Rel -eq 'WinTidy.ps1') { 1 } else { 0 } } }, Rel)
        # Copy of the old files (only the last one is kept) and the new files next to their targets
        $bkRoot = Join-Path $upd 'backup'
        $bk = Join-Path $bkRoot ([string]$Script:Version)
        if (Test-Path -LiteralPath $bkRoot) { foreach ($d in @(Get-ChildItem -LiteralPath $bkRoot -Directory -Force)) { Remove-TreeNoFollow $d.FullName } }
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        foreach ($p in $order) {
            if ($p.Exists) {
                $b = [IO.Path]::Combine($bk, $p.Rel)
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($b)) | Out-Null
                [IO.File]::Copy($p.Dest, $b, $true)
            }
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($p.Dest)) | Out-Null
            $t = $p.Dest + '.wtnew'
            [IO.File]::Copy($p.Src, $t, $true)
            $tmpFiles.Add($t)
        }
        $jr = [ordered]@{ Von = [string]$Script:Version; Nach = [string]$m.Version; Fertig = $false; Dateien = @($order | ForEach-Object { [ordered]@{ Pfad = $_.Rel; Vorhanden = [bool]$_.Exists } }) }
        $jr | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $journal -Encoding utf8
        # The actual replacement: a rename per file, so the window in which the program folder is inconsistent is tiny
        $swapStarted = $true
        foreach ($p in $order) {
            $t = $p.Dest + '.wtnew'
            if ($p.Exists) {
                # Replace needs a backup name in Windows PowerShell 5.1 ($null becomes an empty string); the copy of the old file is in update\backup anyway
                $old = $p.Dest + '.wtold'
                [IO.File]::Replace($t, $p.Dest, $old)
                try { [IO.File]::Delete($old) } catch { }
            } else { [IO.File]::Move($t, $p.Dest) }
        }
        # Done. From here on nothing is rolled back any more, even if the cleanup fails.
        $swapStarted = $false
        $jr.Fertig = $true
        try { $jr | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $journal -Encoding utf8; Remove-Item -LiteralPath $journal -Force } catch { }
        try { Remove-TreeNoFollow $stage } catch { }
        Add-WtUpdateLog ('Installed version {0} (was {1}, {2} files replaced)' -f $m.Version, $Script:Version, $order.Count)
        return [pscustomobject]@{ Status = 'OK'; Version = [string]$m.Version; Geaendert = $order.Count; Sicherung = $bk; Meldung = ''; Zurueck = $false }
    } catch {
        $msg = $_.Exception.Message
        $rolled = $false
        foreach ($t in $tmpFiles) { try { if (Test-Path -LiteralPath $t) { [IO.File]::Delete($t) } } catch { } }
        if ($swapStarted) { try { $rolled = [bool](Undo-WtUpdateFiles $upd) } catch { } }
        else { try { Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue } catch { } }
        Add-WtUpdateLog ('Installation failed: {0} (rolled back: {1})' -f $msg, $rolled)
        return [pscustomobject]@{ Status = 'FEHLER'; Meldung = (T 'The update could not be installed: {0}' $msg); Zurueck = $rolled }
    }
}

# =============================================================================
#  Profiles: the rule selection as a small JSON file (export / import)
# =============================================================================
function Get-BuiltinPresetNames { return @('Safe', 'Standard') }
# Safe = default selection without anything that needs a confirmation; Standard = the default selection
function Get-PresetRuleIds([string]$Name) {
    if ($Name -eq 'Safe') { return @($Script:Rules | Where-Object { $_.Standard -and $_.Risiko -in 'Niedrig', 'Info' } | ForEach-Object { $_.Id }) }
    if ($Name -eq 'Standard') { return @($Script:Rules | Where-Object { $_.Standard } | ForEach-Object { $_.Id }) }
    return $null
}
# Name of a built-in profile or path of a profile file -> @{ Name; Ids; Unbekannt }. Throws with a readable message.
function Resolve-WtPreset([string]$NameOrPath) {
    $ids = $null; $label = $NameOrPath
    $b = Get-BuiltinPresetNames | Where-Object { $_ -eq $NameOrPath } | Select-Object -First 1
    if ($b) { $ids = @(Get-PresetRuleIds $b); $label = $b }
    elseif ($NameOrPath -and (Test-Path -LiteralPath $NameOrPath -PathType Leaf)) {
        $j = $null
        try { $j = Get-Content -LiteralPath $NameOrPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw ((T 'Profile could not be read: {0}') -f $_.Exception.Message) }
        if (-not $j -or -not $j.Regeln) { throw (T 'This file is not a WinTidy profile') }
        $ids = @($j.Regeln | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($j.Name) { $label = [string]$j.Name }
    }
    else { throw ((T 'Profile not found: {0} (built-in profiles: {1})') -f $NameOrPath, ((Get-BuiltinPresetNames) -join ', ')) }
    $known = @($Script:Rules | ForEach-Object { $_.Id })
    return [pscustomobject]@{ Name = $label; Ids = @($ids | Where-Object { $known -contains $_ } | Select-Object -Unique); Unbekannt = @($ids | Where-Object { $known -notcontains $_ } | Select-Object -Unique) }
}
function Save-WtPreset([string]$Path, [string[]]$Ids, [string]$Name) {
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Path) }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $o = [ordered]@{ Format = 'WinTidy-Profil'; Version = 1; WinTidy = $Script:Version; Name = $Name; Regeln = @($Ids) }
    [IO.File]::WriteAllText($full, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    return $full
}

# =============================================================================
#  Shareable report: no PC name, user name, paths; optional PDF
# =============================================================================
function Get-ShareReplacements {
    $l = New-Object System.Collections.Generic.List[object]
    function AddRep($von, $nach) { if ($von -and ([string]$von).Trim().Length -ge 3) { $l.Add([pscustomobject]@{ Von = [string]$von; Nach = [string]$nach }) } }
    AddRep $Script:DataDir (T '[data folder]')
    AddRep $env:USERPROFILE (T '[user profile]')
    AddRep $env:COMPUTERNAME (T '[PC name]')
    AddRep $env:USERNAME (T '[user]')
    if ($env:USERPROFILE) { AddRep ([IO.Path]::GetFileName(([string]$env:USERPROFILE).TrimEnd('\', '/'))) (T '[user]') }
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) { AddRep $env:USERDOMAIN (T '[domain]') }
    return @($l.ToArray())
}
function Invoke-ShareReplace([string]$Text, $Repl) {
    foreach ($r in $Repl) { $Text = [regex]::Replace($Text, [regex]::Escape((HtmlEnc $r.Von)), ([string](HtmlEnc $r.Nach)).Replace('$', '$$'), 'IgnoreCase') }
    return $Text
}
# Replaces the terms in text and in attribute values (not in the style block). Longest term first.
function ConvertTo-ShareableHtml([string]$Html, $Repl) {
    $Repl = @($Repl | Sort-Object { $_.Von.Length } -Descending)
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in [regex]::Split($Html, '(?s)(<style.*?</style>|<[^>]*>)')) {
        if ($p.StartsWith('<style')) { [void]$sb.Append($p) }
        elseif ($p.StartsWith('<')) { [void]$sb.Append([regex]::Replace($p, '"[^"]*"|''[^'']*''', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) Invoke-ShareReplace $m.Value $Repl })) }
        else { [void]$sb.Append((Invoke-ShareReplace $p $Repl)) }
    }
    $out = $sb.ToString()
    $note = "<p class='muted'>$(HtmlEnc (T 'Shareable version: PC name, user name and folder paths were replaced. Please still read the report before you pass it on.'))</p>"
    $i = $out.LastIndexOf('</div></body>')
    if ($i -ge 0) { $out = $out.Insert($i, $note) }
    return $out
}
function Get-PdfBrowserPath {
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $b) { continue }
        foreach ($rel in 'Microsoft\Edge\Application\msedge.exe', 'Google\Chrome\Application\chrome.exe') { $p = Join-Path $b $rel; if (Test-Path -LiteralPath $p) { return $p } }
    }
    return $null
}
# HTML -> PDF with the headless Edge/Chrome. Returns $null on success, otherwise a message.
function Convert-HtmlToPdf([string]$HtmlPath, [string]$PdfPath) {
    $exe = Get-PdfBrowserPath
    if (-not $exe) { return (T 'No Edge or Chrome found for the PDF export. Open the shareable report in the browser and print it as PDF (Ctrl+P).') }
    $prof = Join-Path ([IO.Path]::GetTempPath()) ('WinTidy-pdf-' + [guid]::NewGuid().ToString('N'))
    try {
        if (Test-Path -LiteralPath $PdfPath) { Remove-Item -LiteralPath $PdfPath -Force -ErrorAction SilentlyContinue }
        $uri = ([Uri]$HtmlPath).AbsoluteUri
        $arg = '--headless --disable-gpu --no-first-run --no-pdf-header-footer "--user-data-dir={0}" "--print-to-pdf={1}" "{2}"' -f $prof, $PdfPath, $uri
        $pr = Start-Process -FilePath $exe -ArgumentList $arg -PassThru -WindowStyle Hidden
        if (-not $pr.WaitForExit(90000)) { try { $pr.Kill() } catch { }; return (T 'The PDF export took too long and was cancelled.') }
        if (-not (Test-Path -LiteralPath $PdfPath)) { return (T 'The PDF could not be created. Open the shareable report in the browser and print it as PDF (Ctrl+P).') }
        return $null
    } catch { return ((T 'The PDF could not be created: {0}') -f $_.Exception.Message) }
    finally { if (Test-Path -LiteralPath $prof) { try { Remove-TreeNoFollow $prof } catch { } } }
}
# Creates the normal report, then the anonymized copy (and optionally the PDF). Returns @{ Html; Pdf; Hinweis } or $null.
function New-ShareableReport([bool]$AsPdf = $false) {
    $made = New-Report
    if (-not $made) { return $null }
    $html = [IO.File]::ReadAllText($made, [Text.Encoding]::UTF8)
    $out = Join-Path $Script:DataDir 'WinTidy-Bericht-teilbar.html'
    [IO.File]::WriteAllText($out, (ConvertTo-ShareableHtml $html (Get-ShareReplacements)), (New-Object Text.UTF8Encoding($true)))
    $pdf = $null; $hint = $null
    if ($AsPdf) {
        $pdf = [IO.Path]::ChangeExtension($out, '.pdf')
        $hint = Convert-HtmlToPdf $out $pdf
        if ($hint) { $pdf = $null }
    }
    return [pscustomobject]@{ Html = $out; Pdf = $pdf; Hinweis = $hint }
}

# =============================================================================
#  Modes
# =============================================================================
function Open-Report([string]$Path) { if (-not $Path) { return }; try { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('"{0}"' -f $Path) } catch { try { Start-Process $Path } catch { } } }

function Show-Header {
    W ''
    W ' __      __ _        _____  _      _       ' 'Cyan'
    W ' \ \    / /(_) _ _  |_   _|(_) __ | | _  _ ' 'Cyan'
    W '  \ \/\/ / | || '' \   | |  | |/ _`| || || |' 'Cyan'
    W '   \_/\_/  |_||_||_|  |_|  |_|\__,_|\_, |' 'Cyan'
    W ("                                    |__/   v{0}" -f $Script:Version) 'Cyan'
    W ((T '  {0}  |  Admin: {1}  |  Data: {2}') -f $env:COMPUTERNAME, $Script:IsAdmin, $Script:DataDir) 'DarkGray'
}

function Invoke-Mode([string]$m) {
    $Script:Cache = @{}
    if ($Preset -and -not $Rule -and $m -in 'Rules', 'Scan', 'Preview', 'Apply') {
        $pr = $null
        try { $pr = Resolve-WtPreset $Preset } catch { W $_.Exception.Message 'Red'; return }
        if ($pr.Unbekannt.Count) { W ((T '  Profile {0}: unknown rules are ignored: {1}') -f $pr.Name, ($pr.Unbekannt -join ', ')) 'DarkYellow' }
        if (-not $pr.Ids.Count) { W ((T '  Profile {0} contains no known rules.') -f $pr.Name) 'Red'; return }
        $Script:Rule = $pr.Ids
        W ((T '  Profile: {0} ({1} rules)') -f $pr.Name, $pr.Ids.Count) 'DarkGray'
    }
    if ($m -in 'Scan', 'Preview', 'Apply') {
        $Script:CliContext = $null; try { $Script:CliContext = Get-WtContext } catch { }
        $Script:LastContext = $Script:CliContext
        if ($Script:CliContext -and $Script:CliContext.Verwaltet) { W (T '  Company PC detected (domain/Intune/Entra/ConfigMgr): only safe cleanup rules and hints.') 'DarkYellow' }
        if ($Script:DataMigrated) { W (T '  Data from the previous version migrated to {0}' $Script:DataDir) 'DarkGray' }
    }
    switch ($m) {
        'Rules' {
            Section (T 'Rules')
            foreach ($r in $Script:Rules) { W ("{0,-20} {1,-8} {2,-12} {3}{4}" -f $r.Id, (Get-RiskText $r.Risiko), (Get-CategoryText $r.Kategorie), $r.Titel, $(if (-not $r.Standard) { (T '  (only with -Rule)') } elseif (-not $r.Fix) { (T '  (report only)') } else { '' })) $(switch ($r.Risiko) { 'Niedrig' { 'Green' } 'Mittel' { 'Yellow' } 'Hoch' { 'Red' } default { 'Cyan' } }) }
            if ($SavePreset) {
                try { $sel = @(Get-SelectedRules | ForEach-Object { $_.Id }); $pf = Save-WtPreset $SavePreset $sel; W ((T '  Profile saved: {0} ({1} rules)') -f $pf, $sel.Count) 'Green' }
                catch { W ((T '  Profile could not be saved: {0}') -f $_.Exception.Message) 'Red' }
            }
        }
        'Scan' {
            Start-RunLog 'scan'
            Section (T 'Scan (changes nothing)')
            if (-not $Script:IsAdmin) { W (T '  Without admin rights boot times and some checks are missing. Run as administrator for complete results.') 'DarkYellow' }
            $res = Invoke-Rules $false
            $snap = New-Snapshot 'scan' $res.Befunde
            Section ((T 'Health score: {0}/100') -f $snap.Score.Wert)
            foreach ($z in $snap.Score.Abzuege) { W ("  -{0,-3} {1}" -f $z.Punkte, $z.Grund) 'Yellow' }
            $prev = Get-Snapshots | Select-Object -SkipLast 1 | Select-Object -Last 1
            if ($prev) { Show-Compare (Read-Snapshot $prev) $snap }
            $hist = Read-SnapshotHistory; if ($hist.Effekt) { Show-PerfEffect $hist.Effekt }
            $rep = New-Report; Stop-RunLog
            if ($OpenReport -and $rep) { Open-Report $rep }
        }
        'Preview' {
            Start-RunLog 'preview'
            Section (T 'Preview (changes nothing)')
            $res = Invoke-Rules $false
            Section (T 'Preview summary')
            W ((T '  {0} rules with findings, {1} items, estimated {2}') -f $res.Befunde.Count, (($res.Befunde | Measure-Object Anzahl -Sum).Sum), (Fmt-Bytes (($res.Befunde | Measure-Object Bytes -Sum).Sum))) 'Cyan'
            Stop-RunLog
        }
        'Apply' {
            if (-not $Script:IsAdmin) { W (T 'Apply needs admin rights. Please start PowerShell as administrator (or use WinTidy.cmd).') 'Red'; return }
            if (-not $Script:CliContext -or $Script:CliContext.Server) { W (T 'Windows Server (or system query failed): WinTidy only checks here, changes are blocked.') 'Red'; return }
            Start-RunLog 'apply'
            Section (T 'Apply')
            W (T '  Sequence: measure before -> restore point -> rules (with confirmations) -> measure after -> comparison -> report') 'DarkGray'
            if ($Yes) { W ((T '  Unattended: only risk Low{0}') -f $(if ($IncludeMedium) { (T ' and Medium') } else { '' })) 'DarkYellow' }
            $pre = New-Snapshot 'vorher'
            try { New-RestorePoint } catch { W "  $($_.Exception.Message)" 'Red'; Stop-RunLog; return }
            $res = Invoke-Rules $true
            $Script:Cache = @{}
            $post = New-Snapshot 'nachher' $res.Befunde
            Section (T 'Result')
            W ((T '  Actions: {0}  |  OK: {1}  |  Errors: {2}  |  skipped: {3}  |  estimated freed: {4}') -f $res.Aktionen, $res.OK, $res.Fehler, $res.Uebersprungen, (Fmt-Bytes $res.Bytes)) 'Cyan'
            Show-Compare $pre $post
            try { Show-PerfEffect (Get-PerfEffect $pre $post @()) } catch { W (T '  Key figures could not be compared: {0}' ($_.Exception.Message)) 'DarkYellow' }
            [ordered]@{ Lauf = $Script:RunId; Aktionen = $res.Aktionen; OK = $res.OK; Fehler = $res.Fehler; Uebersprungen = $res.Uebersprungen; BytesGeschaetzt = $res.Bytes; ScoreVorher = $pre.Score.Wert; ScoreNachher = $post.Score.Wert } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
            $rep = New-Report
            W (T '  Recommendation: restart the PC and run "Scan" again after 2-3 boots - only then do the boot times show the effect.') 'Cyan'
            Stop-RunLog
            if ($OpenReport -and $rep) { Open-Report $rep }
        }
        'Compare' {
            $s = Get-Snapshots
            if ($s.Count -lt 2) { W (T 'At least two snapshots needed.') 'Yellow'; return }
            $a = if ($From) { $s | Where-Object { $_.Name -like "*$From*" } | Select-Object -First 1 } else { ($s | Where-Object { $_.Name -like '*_vorher.json' } | Select-Object -Last 1) }
            if (-not $a) { $a = $s[0] }
            $b = if ($To) { $s | Where-Object { $_.Name -like "*$To*" } | Select-Object -First 1 } else { $s[-1] }
            Show-Compare (Read-Snapshot $a) (Read-Snapshot $b)
            $hist = Read-SnapshotHistory; if ($hist.Effekt) { Show-PerfEffect $hist.Effekt }
        }
        'Report' {
            if ($Share -or $Pdf) {
                $sh = New-ShareableReport ([bool]$Pdf)
                if ($sh) {
                    W ((T '  Shareable report: {0}') -f $sh.Html) 'Green'
                    if ($sh.Pdf) { W ((T '  PDF: {0}') -f $sh.Pdf) 'Green' } elseif ($sh.Hinweis) { W ('  ' + $sh.Hinweis) 'DarkYellow' }
                    Open-Report $(if ($sh.Pdf) { $sh.Pdf } else { $sh.Html })
                }
            }
            else { $rep = New-Report; if ($rep) { Open-Report $rep } }
        }
        'Restore' { Start-RunLog 'restore'; $null = Invoke-Restore; Stop-RunLog }
        'Update' {
            Section (T 'Update')
            W (T '  Installed version: {0}' $Script:Version) 'Gray'
            $c = Invoke-GuiUpdateCheck
            if ($c.Status -eq 'AKTUELL') { W (T '  WinTidy is up to date.') 'Green'; return }
            if ($c.Status -ne 'NEU') { W ('  ' + $c.Meldung) 'Yellow'; return }
            W (T '  New version available: {0}' $c.Neu) 'Cyan'
            foreach ($l in @(($c.Notizen -split "`r?`n") | Select-Object -First 12)) { W ('    ' + $l) 'DarkGray' }
            W (T '  Source: {0}' $c.Seite) 'DarkGray'
            $a = if ($Yes) { 'y' } else { Read-Host (T '  Install it now? [y/N]') }
            if ($a -notmatch '^(j|ja|y|yes)$') { W (T '  Not installed.') 'Yellow'; return }
            $s = Invoke-GuiUpdateStage
            if ($s.Status -ne 'BEREIT') { W ('  ' + $s.Meldung) 'Red'; return }
            $r = Invoke-GuiUpdateApply
            if ($r.Status -ne 'OK') { W ('  ' + $r.Meldung) 'Red'; return }
            W (T '  Version {0} is installed. Please start WinTidy again to use it.' $r.Version) 'Green'
            W (T '  A copy of the previous version is in {0}' $r.Sicherung) 'DarkGray'
        }
        'Hardware' {
            Start-RunLog 'hardware'
            Section (T 'Hardware and cooling (changes nothing)')
            W (T '  Note: fan curves live in the BIOS or firmware and cannot be read by Windows. WinTidy measures their effect.') 'DarkGray'
            Show-HwPoints (Get-HardwarePoints)
            foreach ($rid in 'HW-COOLPOLICY', 'HW-DISPLAY') { $r = $Script:Rules | Where-Object Id -eq $rid; try { foreach ($it in @(& $r.Detect | Where-Object { $_ })) { Show-HwPoints @([pscustomobject]@{ Stufe = $(if ($it.Data -and $it.Data.Stufe) { $it.Data.Stufe } else { 'warn' }); Text = $it.Label }) } } catch { } }
            if ($CoolingTest) {
                $sec = if ($Seconds -gt 0) { $Seconds } else { [int]$Script:Cfg.CoolingTestSeconds }
                Section ((T 'Cooling test ({0} seconds)') -f $sec)
                W (T '  All processor cores are fully loaded - the fans get louder. Cancel with Ctrl+C.') 'DarkYellow'
                $null = Invoke-CoolingTest $sec { param($i, $n, $t) Write-Progress -Activity (T 'Cooling test') -Status $t -PercentComplete ([math]::Min(100, 100 * $i / [math]::Max(1, $n))) }
                Write-Progress -Activity (T 'Cooling test') -Completed
            } else { W (T '  Tip: -CoolingTest additionally checks under load whether the cooling keeps up.') 'DarkGray' }
            Stop-RunLog
        }
    }
}

# Loaded as a library (dot-sourcing by the app): stop here
if ($MyInvocation.InvocationName -eq '.') { return }

Show-Header
if ($Mode -ne 'Menu') { Invoke-Mode $Mode; return }
$rem = $null; try { $rem = Get-CheckReminder } catch { }
if ($rem) { W ''; W ('  ' + $rem.Text + (T ' Choose [1] Scan.')) 'Yellow' }
while ($true) {
    W ''
    W (T '  [1] Scan        - measure and check, create a report (changes nothing)') 'White'
    W (T '  [2] Preview     - show what "Apply" would do') 'White'
    W (T '  [3] Apply       - interactive, with restore point') 'White'
    W (T '  [4] Compare     - last "before" snapshot against the newest') 'White'
    W (T '  [5] Report      - open the HTML report') 'White'
    W (T '  [6] Rules       - show all rules') 'White'
    W (T '  [7] Restore') 'White'
    W (T '  [8] Deep scan   - incl. file system/integrity check (slow)') 'White'
    W (T '  [9] Hardware    - cooling, fans, temperatures; optional cooling test') 'White'
    W (T '  [U] Update      - check for a new WinTidy version and install it') 'White'
    W (T '  [0] Exit') 'White'
    $c = Read-Host (T '  Choice')
    switch ($c) {
        '1' { Invoke-Mode 'Scan' } '2' { Invoke-Mode 'Preview' } '3' { Invoke-Mode 'Apply' } '4' { Invoke-Mode 'Compare' }
        '5' { Invoke-Mode 'Report' } '6' { Invoke-Mode 'Rules' } '7' { Invoke-Mode 'Restore' }
        '8' { $Deep = $true; Invoke-Mode 'Scan'; $Deep = $false }
        '9' { $a = Read-Host (T '  Additionally run the cooling test (about 1 minute full load, fans get loud)? [y/N]'); $CoolingTest = ($a -match '^(j|ja|y|yes)$'); Invoke-Mode 'Hardware'; $CoolingTest = $false }
        'u' { Invoke-Mode 'Update' }
        '0' { return }
    }
}
