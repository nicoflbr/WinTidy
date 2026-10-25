#Requires -Version 5.1
<#
.SYNOPSIS
    WinTidy - evidenzbasierte Windows-Bereinigung und -Optimierung mit Vorher/Nachher-Statistik.

.DESCRIPTION
    WinTidy misst zuerst (Snapshot), zeigt dann, was es tun wuerde (Vorschau), fuehrt nur
    bestaetigte Aenderungen aus (Anwenden) und belegt das Ergebnis mit Zahlen (Vergleich, HTML-Bericht).

    Grundsaetze:
      * Nichts ohne Messung: jede Aenderung wird protokolliert (actions.jsonl) und vorher gesichert.
      * Keine Registry-"Cleaner", keine Tweaks ohne Wirkungsnachweis, keine Sicherheitsfunktionen abschalten.
      * Allgemeingueltig: keine festen Pfade, Benutzer oder Programme - nur Regeln.
      * Risikostufen: Niedrig (automatisierbar), Mittel (Einzelbestaetigung), Hoch (nur explizit, nie mit -Yes).

.PARAMETER Mode
    Menu     Interaktives Menue (Standard)
    Scan     Snapshot + alle Regeln pruefen + HTML-Bericht (aendert nichts)
    Preview  Zeigt, was Apply tun wuerde (aendert nichts)
    Apply    Fuehrt Regeln aus (Adminrechte, Wiederherstellungspunkt, Backup, Rueckfragen)
    Compare  Vergleicht zwei Snapshots (Standard: letzter "vorher" mit letztem Snapshot)
    Report   Erzeugt den HTML-Bericht aus allen gespeicherten Daten neu
    Restore  Stellt Registry/Tasks/Dienste eines Laufs wieder her
    Rules    Listet alle Regeln

.EXAMPLE
    .\WinTidy.ps1                          # Menue
    .\WinTidy.ps1 -Mode Scan -OpenReport
    .\WinTidy.ps1 -Mode Apply              # interaktiv
    .\WinTidy.ps1 -Mode Apply -Yes         # unbeaufsichtigt, nur Regeln mit Risiko "Niedrig"
    .\WinTidy.ps1 -Mode Apply -Rule STA-HEAVY,APP-BLOAT
    .\WinTidy.ps1 -Mode Compare
    .\WinTidy.ps1 -Mode Hardware                  # Kuehlung, Luefter, Temperaturen, Laufwerke (aendert nichts)
    .\WinTidy.ps1 -Mode Hardware -CoolingTest -Seconds 90   # zusaetzlich Kuehlungstest unter Last
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Scan', 'Preview', 'Apply', 'Compare', 'Report', 'Restore', 'Rules', 'Hardware')]
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
    [int]$Seconds = 0
)

Set-StrictMode -Off
# Ueber WinTidy.cmd (-File) kommt "-Rule A,B" als eine Zeichenkette an
if ($Rule) { $Rule = @($Rule | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($ExcludeRule) { $ExcludeRule = @($ExcludeRule | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Script:Version = '1.3.4'

# =============================================================================
#  Kontext, Konfiguration, Pfade
# =============================================================================
$Script:ToolRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Script:Me = [Security.Principal.WindowsIdentity]::GetCurrent()
# Mit Adminrechten nur Module aus Systemordnern laden (kein Unterschieben ueber Documents\WindowsPowerShell\Modules)
if ($Script:IsAdmin -and $env:windir) { $env:PSModulePath = (@("$env:ProgramFiles\WindowsPowerShell\Modules", "$env:windir\system32\WindowsPowerShell\v1.0\Modules") -join ';') }
# Datenordner: mit Adminrechten geschuetzt unter ProgramData (nur Administratoren/SYSTEM duerfen schreiben),
# ohne Adminrechte im eigenen Profil. Sicherungen, die "Wiederherstellen" mit Adminrechten einspielt, liegen so nie
# in einem Ordner, den Programme ohne Adminrechte veraendern koennen.
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
            # Besitzer laesst sich nicht immer setzen - dann nur die Rechte
            $acl2 = New-Object Security.AccessControl.DirectorySecurity; $acl2.SetAccessRuleProtection($true, $false)
            foreach ($r in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) { $acl2.AddAccessRule($r) }
            Set-Acl -LiteralPath $Path -AclObject $acl2 -ErrorAction Stop
        }
        return $true
    } catch { return $false }
}
# Prueft, dass der Ordner samt Inhalt nur SYSTEM/Administratoren gehoert und nur sie schreiben duerfen
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
        # Vorhandene Unterordner/Dateien auf die geerbten Rechte zuruecksetzen und Besitz uebernehmen
        if (Get-ChildItem -LiteralPath $wtRoot -Force -ErrorAction SilentlyContinue) {
            $null = & icacls.exe (Join-Path $wtRoot '*') /reset /T /C /Q 2>&1
            $null = & icacls.exe $wtRoot /setowner '*S-1-5-32-544' /T /C /Q 2>&1
        }
    }
    $Script:DataDirProtected = Test-WtDataRootSafe $wtRoot
    # Einmalige Uebernahme der Daten aus aelteren Versionen (Ordner WinTidy-Daten neben dem Skript)
    if (-not (Test-Path -LiteralPath (Join-Path $DataPath 'snapshots')) -and (Test-Path -LiteralPath (Join-Path $Script:LegacyDataDir 'snapshots'))) {
        try {
            New-Item -ItemType Directory -Force -Path $DataPath | Out-Null
            Get-ChildItem -LiteralPath $Script:LegacyDataDir -Force -ErrorAction Stop | Copy-Item -Destination $DataPath -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath (Join-Path $DataPath 'snapshots'))) { throw 'Uebernahme unvollstaendig' }
            Set-Content -LiteralPath (Join-Path $Script:LegacyDataDir 'UMGEZOGEN.txt') -Value ("Die WinTidy-Daten liegen seit Version 1.3 geschuetzt unter $DataPath. Dieser Ordner kann geloescht werden.") -Encoding UTF8 -ErrorAction SilentlyContinue
            $Script:DataMigrated = $true
        } catch { }
    }
}
$Script:DataDir = $DataPath
$Script:SnapDir = Join-Path $DataPath 'snapshots'
$Script:RunsDir = Join-Path $DataPath 'runs'
foreach ($d in $Script:DataDir, $Script:SnapDir, $Script:RunsDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
$Script:RestoreRunId = $RunId   # -RunId ist der Restore-Zielparameter; $Script:RunId wird gleich ueberschrieben
$Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
$Script:RunDir = $null
$Script:Cache = @{}
$Script:AllYes = $false

$Script:DefaultConfig = [ordered]@{
    TempAgeDays             = 2
    RecycleBinAgeDays       = 30
    CrashDumpAgeDays        = 7
    ShadowStorageMinPercent = 3
    ShadowStorageTarget     = '5%'
    BootDegradationHintMs   = 2000
    HeavyStartup            = @('Spotify', 'Steam', 'Discord', 'EADesktop', 'EALauncher', 'Battle.net', 'EpicGamesLauncher', 'Teams', 'Skype', 'Zoom', 'AdobeCollabSync', 'Creative Cloud', 'CCleaner', 'Luminar', 'Mobalytics', 'Overwolf', 'MicrosoftStartFeedProvider', 'LogiLDA', 'iTunesHelper', 'Opera', 'msedge')
    ProtectedStartup        = @('SecurityHealth', 'OneDrive', 'Windows Defender', 'RtkAudUService', 'KeePass', 'Bitwarden', '1Password', 'Malwarebytes', 'Bitdefender', 'Kaspersky', 'ESET', 'Avast', 'AVG', 'Norton', 'McAfee', 'Sophos', 'Trend Micro', 'G DATA', 'Avira', 'F-Secure', 'WireGuard', 'OpenVPN', 'NordVPN', 'FortiClient', 'GlobalProtect', 'Cisco', 'Synaptics', 'ELAN', 'Backblaze', 'Veeam', 'Acronis', 'Duet', 'Logitech Options', 'Dropbox', 'Nextcloud', 'Google Drive')
    BloatApps               = @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.ZuneVideo', 'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MixedReality.Portal', 'Microsoft.WindowsFeedbackHub', 'Microsoft.M365Companions', 'Clipchamp.Clipchamp', 'Microsoft.549981C3F5F10', 'Microsoft.Windows.DevHome', 'Microsoft.BingSearch', 'Microsoft.PowerAutomateDesktop', 'Microsoft.People', 'Microsoft.SkypeApp', 'Microsoft.Wallet', 'Microsoft.3DBuilder', 'Microsoft.Print3D', 'Microsoft.Microsoft3DViewer')
    GhostDeviceExclude      = @('WAN Miniport', 'Microsoft Kernel Debug', 'Hyper-V', 'Remote NDIS', 'Bluetooth', 'Microsoft Wi-Fi Direct', 'Teredo', '6to4', 'IP-HTTPS', 'ISATAP', 'VHD Loopback', 'Microsoft Virtual')
    GhostDeviceClasses      = @('System', 'HDC', 'SCSIAdapter', 'Display', 'Monitor', 'MEDIA', 'Net', 'DiskDrive', 'Volume', 'USB', 'USBDevice', 'HIDClass', 'Keyboard', 'Mouse', 'WPD', 'Image', 'Camera', 'Ports', 'Processor', 'SmartCardReader', 'Sensor', 'Biometric')
    SideBySideExclude       = @('Visual C\+\+', '\.NET', 'Windows SDK', 'Windows Software Development', 'Python', 'Java', 'WebView', 'Update for', 'Security Update', 'Hotfix', 'Runtime', 'Redistributable', 'Driver', 'Language', 'Sprachpaket', 'Microsoft 365', 'Office', 'Steam', 'SDK')
    WingetExclude           = @('rekordbox', 'DaVinci', 'Blackmagic', 'AlphaTheta')
    OrphanDirIgnore         = @('Microsoft', 'Windows', 'Packages', 'Temp', 'Package Cache', 'Common Files', 'NVIDIA', 'NVIDIA Corporation', 'Intel', 'AMD', 'Realtek', 'WindowsApps', 'ModifiableWindowsApps', 'Reference Assemblies', 'MSBuild', 'Internet Explorer', 'Windows Defender', 'Windows Mail', 'Windows Media Player', 'Windows NT', 'Windows Photo Viewer', 'Windows Sidebar', 'Uninstall Information', 'WindowsPowerShell', 'PackageManagement', 'dotnet', 'USOShared', 'USOPrivate', 'regid.1991-06.com.microsoft', 'SoftwareDistribution', 'ssh', 'Comms', 'ConnectedDevicesPlatform', 'D3DSCache', 'CrashDumps', 'Programs', 'PlaceholderTileLogoFolder', 'VirtualStore', 'Publishers', 'IsolatedStorage', 'speech', 'ElevatedDiagnostics', 'Adobe', 'Google', 'Mozilla', 'Apple', 'Apple Computer', 'Apple Inc', 'Claude', 'Code', 'Electron', 'NuGet', 'npm', 'npm-cache', 'pip')
    OrphanDirMinMB          = 50
    ExtraTempPaths          = @()      # weitere Temp-Ordner (z. B. 'C:\Temp'), nur wenn dort wirklich nur Wegwerfdateien liegen
    # Hardware/Kuehlung (Grad Celsius). Scan = PC hat kaum zu tun (Laptop +5 Grad)
    CpuTempIdleWarnC        = 80
    CpuTempIdleCritC        = 90
    # Temperaturgrenze (TjMax) je CPU-Familie (Regex auf den CPU-Namen, erster Treffer zaehlt; sonst 100)
    CpuTjMax                = [ordered]@{ 'Ryzen.*\d{4}X3D' = 89; 'Ryzen [3579] [79]\d{3}' = 95; 'Ryzen' = 90; 'Core\(TM\) Ultra|Core Ultra' = 105; 'Intel' = 100 }
    GpuTempWarnC            = 83
    GpuTempCritC            = 90
    DiskTempWarnC           = @{ NVMe = 70; SSD = 60; HDD = 50 }
    DiskTempCritC           = @{ NVMe = 80; SSD = 70; HDD = 60 }
    CoolingTestSeconds      = 60
    WinOldMinAgeDays        = 10
    # Ende der Sicherheitsupdates je Windows-Build (Home/Pro; Enterprise/Education: +12 Monate). Quelle: Microsoft Lifecycle
    WindowsSupportEnd       = [ordered]@{ '19045' = '2025-10-14'; '22621' = '2024-10-08'; '22631' = '2025-11-11'; '26100' = '2026-10-13'; '26200' = '2027-10-12' }
}
function Merge-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Script:DefaultConfig.Keys) { $cfg[$k] = $Script:DefaultConfig[$k] }
    $p = if ($ConfigPath) { $ConfigPath } else { Join-Path $Script:ToolRoot 'WinTidy.config.json' }
    if (Test-Path $p) {
        try {
            $user = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $user.PSObject.Properties) {
                if ($prop.Name -like '_*') { continue }
                $def = $Script:DefaultConfig[$prop.Name]
                if (($def -is [hashtable] -or $def -is [System.Collections.Specialized.OrderedDictionary]) -and $prop.Value -is [pscustomobject]) {
                    # Tabellen (z. B. DiskTempWarnC) pro Unterschluessel zusammenfuehren statt komplett zu ersetzen
                    $m = [ordered]@{}; foreach ($k in $def.Keys) { $m[$k] = $def[$k] }
                    foreach ($sp in $prop.Value.PSObject.Properties) { $m[$sp.Name] = $sp.Value }
                    $cfg[$prop.Name] = $m
                } else { $cfg[$prop.Name] = $prop.Value }
            }
        } catch { Write-Warning "Konfiguration $p konnte nicht gelesen werden: $($_.Exception.Message)" }
    }
    return $cfg
}
# Konfiguration auf gefaehrliche Werte pruefen (z. B. Altersgrenze 0 = alles loeschen)
function Test-Config($cfg) {
    $min = @{ TempAgeDays = 1; RecycleBinAgeDays = 7; CrashDumpAgeDays = 1; WinOldMinAgeDays = 10; OrphanDirMinMB = 10; CoolingTestSeconds = 20 }
    foreach ($k in @($min.Keys)) { $v = 0; if (-not [int]::TryParse([string]$cfg[$k], [ref]$v) -or $v -lt $min[$k]) { Write-Warning "Konfiguration: $k ungueltig ($($cfg[$k])) - Standardwert wird verwendet"; $cfg[$k] = $Script:DefaultConfig[$k] } }
    $never = 'Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.WindowsAppRuntime', 'Microsoft.VCLibs', 'Microsoft.UI.Xaml', 'Microsoft.NET'
    $cfg.BloatApps = @($cfg.BloatApps | Where-Object { $n = [string]$_; $n -match '^[\w\.\-]+$' -and -not ($never | Where-Object { $n -like "$_*" }) })
    if ([string]$cfg.ShadowStorageTarget -notmatch '^(\d{1,2})%$' -or [int]$Matches[1] -lt 3) { $cfg.ShadowStorageTarget = $Script:DefaultConfig.ShadowStorageTarget }
    $cfg.ExtraTempPaths = @($cfg.ExtraTempPaths | Where-Object { $_ -and ([string]$_) -match '^[A-Za-z]:\\.+' })
    return $cfg
}
$Script:Cfg = Test-Config (Merge-Config)

# =============================================================================
#  Ausgabe, Logging, Hilfsfunktionen
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
# Verknuepfungen (Junctions, Symlinks, OneDrive-Platzhalter) werden beim Aufraeumen nie betreten und nie geloescht.
# Sonst koennte z. B. eine Junction in einem Temp-Ordner das Loeschen auf beliebige andere Ordner umlenken.
function Test-Reparse($Item) { return [bool]($Item -and ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) }
function Test-SafeDeleteRoot([string]$Path) {
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full -match '^[A-Za-z]:$' -or $full -match '^\\\\[^\\]+\\[^\\]+$') { return $false }
    $bad = @($env:SystemDrive, $env:windir, "$env:windir\System32", $env:USERPROFILE, $(if ($env:USERPROFILE) { Split-Path $env:USERPROFILE }), $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop')) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') }
    return -not ($bad -contains $full)
}
function Get-OldFiles([string]$Path, [int]$Days) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    if (-not (Test-SafeDeleteRoot $Path)) { W "    Ordner $Path wird zur Sicherheit nicht bereinigt" 'DarkYellow'; return @() }
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
# Unmittelbar vor dem Loeschen: liegt die Datei noch unterhalb der Wurzel, ohne Verknuepfung dazwischen?
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
# Loescht einen Ordner samt Inhalt, folgt dabei aber keinen Verknuepfungen (die Verknuepfung selbst wird entfernt, ihr Ziel nicht)
function Remove-TreeNoFollow([string]$Path) {
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (Test-Reparse $it) { throw "Verknuepfung (Junction/Symlink) - zur Sicherheit nicht geloescht: $Path" }
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

# Ermittelt aus einer Befehlszeile die eigentliche Zieldatei (fuer Existenzpruefungen)
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
        return $null   # Interpreter ohne Dateiargument: nicht pruefbar
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
    # Netzwerkpfade nie als "verwaist" werten (NAS schlaeft, VPN getrennt) und mit Adminrechten nicht antasten
    if ($Target.StartsWith('\\')) { return 'unbekannt' }
    if ($Target -notmatch '^[A-Za-z]:\\') { return 'unbekannt' }
    if (-not (Test-DriveExists $Target)) { return 'LaufwerkFehlt' }
    if (Test-Path -LiteralPath $Target) { return 'ok' }
    return 'fehlt'
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
        W '[j]a / [n]ein / [a]lle dieser Regel / [s]Regel ueberspringen: ' 'DarkGray' -NoNewline
        $a = (Read-Host).Trim().ToLower()
        switch -Regex ($a) {
            '^(j|ja|y)$' { return $true }
            '^(n|nein|)$' { return $false }
            '^a$' { if ($Risk -eq 'Hoch') { W '    (bei Risiko "Hoch" wird jedes Objekt einzeln gefragt)' 'DarkYellow'; continue }; $Script:AllYes = $true; return $true }
            '^s$' { throw 'SKIPRULE' }
        }
    }
}

function Backup-RegKey([string]$Key, [string]$Name) {
    if (-not $Script:RunDir) { return }
    $f = Join-Path $Script:RunDir ("backup\" + ($Name -replace '[^\w\-]', '_') + '.reg')
    if (-not (Test-Path $f)) { & reg.exe export $Key $f /y 2>$null | Out-Null }
}
# Registry-Wert lesen, so dass er sich als JSON speichern und exakt zurueckschreiben laesst
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
# Nur diese Schluessel darf "Wiederherstellen" anfassen (Schutz vor manipulierten Sicherungen)
$Script:RestoreKeyAllow = '(?i)^HK(CU|LM)\\Software\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\(Run|Explorer\\StartupApproved\\(Run|Run32|StartupFolder))$|^HKCU\\System\\GameConfigStore$|^HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR$|^HKCU\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppModel\\SystemAppData\\[^\\]+\\[^\\]+$|^HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem$'
# Aenderung eines Registry-Werts mit Undo-Info ausfuehren (Vorher/Nachher; Restore setzt nur zurueck, wenn seitdem niemand den Wert geaendert hat)
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
    if (-not (Test-RegKeyAllowed $u.Key)) { throw 'Unerwarteter Registry-Pfad - nicht zurueckgesetzt' }
    $cur = Get-RegValueRaw $u.Key $u.Name
    $a = if ($null -eq $cur) { '' } else { $cur | ConvertTo-Json -Compress -Depth 3 }
    $b = if ($null -eq $u.Nachher) { '' } else { $u.Nachher | ConvertTo-Json -Compress -Depth 3 }
    if ($a -ne $b) { throw 'Seitdem geaendert - nicht ueberschrieben' }
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
#  Datenquellen
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
            $typ = switch ($e.Id) { 101 { 'App' } 102 { 'Treiber' } 103 { 'Dienst' } 106 { 'Hintergrund' } 109 { 'Geraet' } }
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
        @{ Ort = 'Autostart-Ordner (Benutzer)'; Path = [Environment]::GetFolderPath('Startup'); SA = "$Script:SA_HKCU\StartupFolder"; Reg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Ort = 'Autostart-Ordner (Alle)'; Path = [Environment]::GetFolderPath('CommonStartup'); SA = "$Script:SA_HKLM\StartupFolder"; Reg = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
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

# =============================================================================
#  Kontext (Server, Firmen-PC, Akku, anderes Konto) und Hardware-Datenquellen
# =============================================================================
function Test-RebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

# Geraeteart: Laptop (PCSystemType 2 bzw. mobiles Gehaeuse), Akku vorhanden (ohne USV), laeuft gerade auf Akku, VM
function Get-ChassisInfo {
    if ($Script:Cache.Chassis) { return $Script:Cache.Chassis }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1).ChassisTypes)
    $mobile = [bool]($types | Where-Object { $_ -in 8, 9, 10, 11, 14, 30, 31, 32 })
    $laptop = ($cs -and [int]$cs.PCSystemType -eq 2) -or $mobile
    # USV-Geraete melden sich ebenfalls als Batterie - nicht mitzaehlen
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
        # Fail-closed: laesst sich das Betriebssystem nicht abfragen, wird wie ein Server behandelt (nur pruefen)
        Server = ((-not $os) -or $os.ProductType -ne 1); Verwaltet = ($domain -or $mdm -or $aad -or $sccm); Domaene = $domain; Intune = $mdm; EntraJoin = $aad; ConfigMgr = $sccm
        AnderesKonto = [bool]($sess -and $proc -and $sess -ne $proc); ProzessBenutzer = $proc; SitzungsBenutzer = $sess
        NeustartAusstehend = [bool](Test-RebootPending); Akku = [bool]$ch.Akku; Laptop = [bool]$ch.Laptop; VM = [bool]$ch.VM; Admin = $Script:IsAdmin; Hinweise = @()
    }
}

# Andere aktive Sicherheitsprodukte (Security Center, nur Client-Windows). productState-Bit 0x1000 = aktiv
function Get-OtherSecurityProducts([string]$Class) {
    $k = "Sec_$Class"; if ($Script:Cache.ContainsKey($k)) { return $Script:Cache[$k] }
    $r = @(); try { $r = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName $Class -ErrorAction Stop | Where-Object { [string]$_.displayName -notmatch '(?i)defender|windows' -and ([int64]$_.productState -band 0x1000) } | ForEach-Object { [string]$_.displayName }) } catch { }
    $Script:Cache[$k] = $r
    return $r
}
# Supportende der Windows-Version und letzte Update-Installation
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

function ConvertTo-WtNumber($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if ($s -match '(?i)n/?a\b|not supported|unknown|^$') { return $null }
    $s = $s -replace '[^\d\.,\-]', ''
    if ($s -match '^-?\d{1,3}(\.\d{3})+$') { $s = $s -replace '\.', '' }          # Tausenderpunkte (1.234)
    elseif ($s -match '^-?\d{1,3}(,\d{3})+\.\d+$') { $s = $s -replace ',', '' }   # 1,234.5
    else { $s = $s -replace ',', '.' }                                           # Dezimalkomma
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

# winget sicher aufloesen: mit Adminrechten nur aus dem installierten App-Installer-Paket (nicht ueber PATH)
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

# Verstaendliche Namen fuer Store-Apps und Geraeteklassen
$Script:AppNames = @{
    'Microsoft.BingNews' = 'Microsoft News'; 'Microsoft.BingWeather' = 'Wetter (Microsoft)'; 'Microsoft.ZuneVideo' = 'Filme & TV'; 'Microsoft.Getstarted' = 'Tipps'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire-Spiele'; 'Microsoft.MixedReality.Portal' = 'Mixed-Reality-Portal'; 'Microsoft.WindowsFeedbackHub' = 'Feedback-Hub'
    'Microsoft.M365Companions' = 'Microsoft 365 Begleiter-Apps'; 'Clipchamp.Clipchamp' = 'Clipchamp (Videoschnitt)'; 'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.Windows.DevHome' = 'Dev Home (für Entwickler)'
    'Microsoft.BingSearch' = 'Bing-Suche'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'; 'Microsoft.People' = 'Kontakte (alt)'; 'Microsoft.SkypeApp' = 'Skype'
    'Microsoft.Wallet' = 'Wallet'; 'Microsoft.3DBuilder' = '3D Builder'; 'Microsoft.Print3D' = 'Print 3D'; 'Microsoft.Microsoft3DViewer' = '3D-Viewer'
}
function Get-AppDisplayName([string]$Id) { if ($Script:AppNames.ContainsKey($Id)) { return $Script:AppNames[$Id] }; return ($Id -replace '^[^\.]+\.', '') }
$Script:DeviceClassNames = @{
    'System' = 'Systemgeräte'; 'HDC' = 'Laufwerks-Controller'; 'SCSIAdapter' = 'Speicher-Controller'; 'Display' = 'Grafikkarten'; 'Monitor' = 'Bildschirme'; 'MEDIA' = 'Audiogeräte'
    'Net' = 'Netzwerkadapter'; 'DiskDrive' = 'Laufwerke'; 'Volume' = 'Laufwerksbereiche'; 'USB' = 'USB-Controller'; 'USBDevice' = 'USB-Geräte'; 'HIDClass' = 'Eingabegeräte'
    'Keyboard' = 'Tastaturen'; 'Mouse' = 'Mäuse'; 'WPD' = 'Handys und Kameras'; 'Image' = 'Scanner und Kameras'; 'Camera' = 'Kameras'; 'Ports' = 'Anschlüsse (COM)'; 'Processor' = 'Prozessoren'
    'SmartCardReader' = 'Kartenleser'; 'Sensor' = 'Sensoren'; 'Biometric' = 'Fingerabdruckleser'
}
function Get-DeviceClassName([string]$Class) { if ($Script:DeviceClassNames.ContainsKey($Class)) { return $Script:DeviceClassNames[$Class] }; return $Class }

# NVIDIA-Grafikkarten: nvidia-smi wird mit dem Treiber installiert (lokalisierungsfeste CSV-Ausgabe)
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
        # Drosselgruende sind Momentaufnahmen: nur werten, was in mindestens 2 von 3 Proben gesetzt ist
        if ($res | Where-Object { $_.Gruende -band 0xE8 }) {
            $proben = @(, @($res | ForEach-Object { $_.Gruende }))
            for ($i = 0; $i -lt 2; $i++) { Start-Sleep -Milliseconds 1000; $proben += , @(Invoke-NvidiaQuery $exe | ForEach-Object { $_.Gruende }) }
            for ($g = 0; $g -lt $res.Count; $g++) {
                $stabil = [int64]0
                foreach ($bit in 0x4, 0x8, 0x20, 0x40, 0x80) { $n = 0; foreach ($p in $proben) { if ($p.Count -gt $g -and ([int64]$p[$g] -band $bit)) { $n++ } }; if ($n -ge 2) { $stabil = $stabil -bor $bit } }
                $res[$g].GruendeStabil = $stabil
            }
        } else { foreach ($g in $res) { $g.GruendeStabil = $g.Gruende } }
        # Temperaturgrenzen der Karte (Ausgabe ist immer englisch)
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
    if ($m -band 0x40) { $t += 'Hitze (Hardware)' }
    if ($m -band 0x20) { $t += 'Temperaturgrenze' }
    if ($m -band 0x80) { $t += 'Stromversorgung (Power Brake)' }
    if ($m -band 0x8) { $t += 'Hardware-Signal (oft Stromversorgung oder Hitze)' }
    if ($m -band 0x4) { $t += 'Leistungsgrenze' }
    return $t
}

# Sensoren aus Hardware-Monitoren (optional): LibreHardwareMonitor / OpenHardwareMonitor (WMI, nur solange das
# Programm laeuft) oder HWiNFO (Werte mit "Report value in Gadget", nur solange HWiNFO laeuft). Ohne diese Programme
# meldet ein Desktop-Mainboard Luefterdrehzahlen und CPU-Temperatur meist gar nicht an Windows.
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
    # Bevorzugt: Tdie (ohne Offset), dann Package/Tctl, dann Core-Mittel/Max
    foreach ($muster in '(?i)tdie', '(?i)package|tctl', '(?i)core.*(average|mittel)', '(?i)core.*max') {
        $pref = $cpu | Where-Object { $_.Name -match $muster } | Sort-Object Wert -Descending | Select-Object -First 1
        if ($pref) { return [math]::Round([double]$pref.Wert, 1) }
    }
    $pref = $cpu | Sort-Object Wert -Descending | Select-Object -First 1
    if ($pref) { return [math]::Round([double]$pref.Wert, 1) }
    return $null
}
# CPU-Temperatur fuer den Scan: Median mehrerer Werte plus Auslastung (nur aussagekraeftig, wenn der PC ruht)
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
# Temperaturgrenze der CPU laut Konfiguration (Regex auf den CPU-Namen)
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
    # SMART-Vorhersage: InstanceName = PNPDeviceID + '_0'; Win32_DiskDrive.Index = PhysicalDisk.DeviceId
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

# Drosselung durch die Firmware (Kernel-Processor-Power 37). Windows schreibt das Ereignis je logischem Prozessor -
# gezaehlt werden deshalb Episoden (verschiedene Minuten), nicht Ereignisse.
function Get-ThrottleEventCount([int]$Days = 30, [datetime]$Since = [datetime]::MinValue) {
    $start = if ($Since -gt [datetime]::MinValue) { $Since } else { (Get-Date).AddDays(-$Days) }
    try { return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $start } -MaxEvents 5000 -ErrorAction Stop | ForEach-Object { $_.TimeCreated.ToString('yyyyMMddHHmm') } | Select-Object -Unique).Count } catch { return 0 }
}
function Get-EventCount([hashtable]$Filter) { try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 2000 -ErrorAction Stop).Count } catch { return 0 } }

# Warnsignale aus dem Ereignisprotokoll (fuer Regel EVT-HEALTH und den Snapshot - so bleibt der Score vergleichbar)
function Get-WarningSignals {
    if ($Script:Cache.ContainsKey('Warn')) { return $Script:Cache.Warn }
    $since = (Get-Date).AddDays(-30)
    $checks = @(
        @{ F = @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $since }; T = 'Plötzliches Ausschalten oder Neustart ohne Herunterfahren' },
        @{ F = @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since }; T = 'Bluescreen (Windows ist abgestürzt)' },
        @{ F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2, 3; StartTime = $since }; T = 'Von der Hardware gemeldete Fehler' },
        @{ F = @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci'; Level = 1, 2; StartTime = $since }; T = 'Fehler beim Lesen oder Schreiben eines Laufwerks' },
        @{ F = @{ LogName = 'System'; ProviderName = 'nvlddmkm', 'amdkmdag', 'igfx'; Level = 1, 2, 3; StartTime = $since }; T = 'Grafiktreiber ist abgestürzt oder wurde neu gestartet' },
        @{ F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-TPM-WMI', 'TPM'; Level = 1, 2; StartTime = $since }; T = 'Fehler des Sicherheitschips (TPM) – oft hilft ein BIOS-Update' },
        @{ F = @{ LogName = 'System'; ProviderName = 'Volsnap'; Level = 1, 2; StartTime = $since }; T = 'Wiederherstellungspunkte gingen verloren' }
    )
    $r = @(foreach ($c in $checks) { $n = Get-EventCount $c.F; if ($n) { [pscustomobject]@{ Text = $c.T; Anzahl = $n } } })
    $Script:Cache.Warn = $r
    return $r
}

# Energieeinstellung lesen (lokalisierungsfest ueber die Registry statt powercfg-Text)
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
$Script:CoolingTestMin = 20   # Tests setzen den Wert herunter

# Hardware-Zustand fuer Regel HW-COOLING, Snapshot und App: Punkte mit Stufe ok|warn|krit|'' (Info).
# Wertung 'moment' = Momentaufnahme (Temperatur, aktuelle Drosselung) - zaehlt nicht im Score.
function Get-HardwarePoints {
    if ($Script:Cache.ContainsKey('HwPoints')) { return $Script:Cache.HwPoints }
    $c = $Script:Cfg
    $pts = New-Object System.Collections.Generic.List[object]
    function P([string]$Stufe, [string]$Text, [string]$Bereich, [string]$Wertung = 'dauer') { $pts.Add([pscustomobject]@{ Stufe = $Stufe; Text = $Text; Bereich = $Bereich; Wertung = $Wertung }) }
    $ch = Get-ChassisInfo
    $sens = @(Get-HwMonitorSensors)
    $quelle = if ($sens.Count) { $sens[0].Quelle } else { $null }

    # ---- Prozessor: Temperatur (nur mit Hardware-Monitor), Drosselung, Thermalzonen
    $cpuT = $null
    if ($sens.Count) {
        $m = Get-CpuTempMedian
        if ($m) {
            $cpuT = $m.TempC
            $plus = if ($ch.Laptop) { 5 } else { 0 }
            if ($null -ne $m.Auslastung -and $m.Auslastung -gt 30) { P '' ("Prozessor: {0:N0} °C (gemessen, während der PC beschäftigt war – nicht bewertet)" -f $cpuT) 'CPU' 'moment' }
            elseif ($cpuT -ge $c.CpuTempIdleCritC + $plus) { P 'krit' ("Prozessor: {0:N0} °C, obwohl er kaum etwas zu tun hat – Kühler, Lüfter und Staub prüfen lassen" -f $cpuT) 'CPU' 'moment' }
            elseif ($cpuT -ge $c.CpuTempIdleWarnC + $plus) { P 'warn' ("Prozessor: {0:N0} °C bei wenig Last – etwas warm. Lüfter und Staubfilter prüfen" -f $cpuT) 'CPU' 'moment' }
            else { P 'ok' ("Prozessor: {0:N0} °C" -f $cpuT) 'CPU' 'moment' }
        }
    }
    $ep7 = Get-ThrottleEventCount 7; $ep30 = Get-ThrottleEventCount 30
    if (-not $ch.Laptop -and $ep7 -ge 3) { P 'warn' ("Die Firmware hat den Prozessor in den letzten 7 Tagen {0}-mal gebremst. Häufige Ursachen: Kühlung, verstaubte Lüfter oder Leistungsgrenzen im BIOS" -f $ep7) 'CPU' 'moment' }
    elseif ($ep30 -gt 0) { P '' ("Die Firmware hat den Prozessor in den letzten 30 Tagen {0}-mal kurz gebremst{1}" -f $ep30, $(if ($ch.Laptop) { ' – auf Laptops (z. B. im Akkubetrieb) normal' } else { ' – gelegentlich ist das normal' })) 'CPU' 'moment' }
    else { P 'ok' 'Prozessor: keine Drosselung in den letzten 30 Tagen' 'CPU' 'moment' }
    foreach ($z in (Get-ThermalZones)) {
        if ($z.PassivLimit -gt 0 -and $z.PassivLimit -lt 100) {
            $grund = if ($z.Gruende -band 1) { 'wegen Hitze' } elseif ($z.Gruende -band 2) { 'wegen einer Strombegrenzung' } else { '' }
            P $(if ($z.PassivLimit -le 80) { 'krit' } else { 'warn' }) ("Windows bremst den Prozessor gerade {0} ({1}: {2} % Leistung, {3:N0} °C)" -f $grund, $z.Name, $z.PassivLimit, $z.TempC).Replace('  ', ' ') 'CPU' 'moment'
        }
        elseif ($z.TempC -ge 90) { P 'warn' ("Temperaturfühler {0}: {1:N0} °C" -f $z.Name, $z.TempC) 'CPU' 'moment' }
    }

    # ---- Luefter (nur mit Hardware-Monitor)
    $fans = @($sens | Where-Object { $_.Typ -eq 'Fan' -and $_.GeraeteTyp -notmatch '(?i)gpu' -and $_.Name -notmatch '(?i)\bgpu\b' })
    $ctrl = @($sens | Where-Object { $_.Typ -eq 'Control' -and $_.GeraeteTyp -notmatch '(?i)gpu' -and $_.Name -notmatch '(?i)\bgpu\b|pump|aio' })
    if ($fans.Count) {
        $laufend = @($fans | Where-Object { $_.Wert -ge 100 })
        $pumpen = @($fans | Where-Object { $_.Name -match '(?i)pump|aio' })
        $cpuFan = @($fans | Where-Object { $_.Name -match '(?i)\bcpu\b' -and $_.Name -notmatch '(?i)pump|aio|opt' })
        $steht = $cpuFan.Count -and -not ($cpuFan | Where-Object { $_.Wert -ge 100 })
        if ($steht -and $null -ne $cpuT -and $cpuT -ge 60) { P 'krit' ("CPU-Lüfter meldet 0 U/min, obwohl der Prozessor {0:N0} °C warm ist – nicht angeschlossen oder defekt. Im BIOS prüfen" -f $cpuT) 'Lüfter' }
        elseif ($steht) { P '' 'CPU-Lüfter steht gerade – bei kühlem Prozessor ist das oft gewollt (Lüfterstopp im Leerlauf)' 'Lüfter' }
        elseif (-not $laufend.Count -and $null -ne $cpuT -and $cpuT -ge 60) { P 'krit' 'Kein Lüfter meldet eine Drehzahl, obwohl der Prozessor warm ist – Lüfteranschlüsse prüfen' 'Lüfter' }
        if ($pumpen.Count -and -not ($pumpen | Where-Object { $_.Wert -ge 100 })) { P 'warn' 'Die Pumpe der Wasserkühlung meldet 0 U/min – entweder ist ihr Drehzahlkabel nicht angeschlossen oder die Pumpe steht. Im BIOS bzw. in der Software der Kühlung prüfen' 'Lüfter' }
        if ($laufend.Count) { P 'ok' ('Lüfter: ' + (($laufend | Sort-Object Wert -Descending | Select-Object -First 6 | ForEach-Object { '{0} {1:N0} U/min' -f $_.Name, $_.Wert }) -join ', ')) 'Lüfter' }
        # Volllast bei kuehlem Prozessor: nur Steuerwerte, deren Luefter wirklich laeuft (gleiche Nummer #n)
        $voll = @($ctrl | Where-Object {
            $cv = $_; if ($cv.Wert -lt 95) { return $false }
            if ($cv.Name -match '#(\d+)') { $nr = $Matches[1]; return [bool]($fans | Where-Object { $_.Name -match "#$nr\b" -and $_.Wert -ge 100 }) }
            return [bool]$laufend.Count
        })
        if ($voll.Count -and $null -ne $cpuT -and $cpuT -lt 55) { P 'warn' ("Lüfter laufen auf Volllast, obwohl der Prozessor kühl ist ({0}) – die Lüfterkurve im BIOS ist vermutlich zu scharf eingestellt (unnötig laut). Hinweis: Das Programm nennt die Anschlüsse oft nur 'Fan #1' – im BIOS heißen sie z. B. CPU_FAN oder CHA_FAN" -f (($voll | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')) 'Lüfter' }
        P '' ("Sensordaten von {0}" -f $quelle) 'Lüfter'
    } else {
        P '' 'Lüfterdrehzahlen: Dieses Mainboard meldet sie nicht direkt an Windows. Läuft das kostenlose Programm LibreHardwareMonitor (ab Version 0.9.5), liest WinTidy Lüfter und Prozessor-Temperatur automatisch mit. Den Kühlungstest gibt es trotzdem.' 'Lüfter'
    }
    foreach ($p in (Get-FanToolPoints)) { $pts.Add($p) }

    # ---- Grafikkarte (NVIDIA). fan.speed ist die Soll-Drehzahl, kein Messwert.
    foreach ($g in (Get-NvidiaGpus)) {
        $txt = '{0}: {1}' -f $g.Name, $(if ($null -ne $g.TempC) { '{0:N0} °C' -f $g.TempC } else { 'Temperatur unbekannt' })
        if ($null -ne $g.LuefterProzent) { $txt += ', Lüfter {0:N0} %' -f $g.LuefterProzent }
        $m = [int64]$g.GruendeStabil
        $leerlauf = ($null -ne $g.Auslastung -and $g.Auslastung -lt 10)
        $slow = if ($g.SlowdownC) { $g.SlowdownC } else { $c.GpuTempCritC }
        $grenzeLast = if ($g.MaxOpC) { $g.MaxOpC - 5 } elseif ($g.ZielC) { $g.ZielC + 3 } else { $c.GpuTempWarnC }
        if (($m -band 0x40) -or ($null -ne $g.TempC -and $g.TempC -ge $slow)) { P 'krit' ($txt + ' – wird wegen Hitze gebremst. Gehäuselüfter und Staub prüfen') 'Grafikkarte' 'moment' }
        elseif ($null -ne $g.TempC -and $null -ne $g.LuefterProzent -and $g.LuefterProzent -eq 0 -and $g.TempC -ge 70) { P 'warn' ($txt + ' – die Lüfter laufen trotz hoher Temperatur nicht an. Lüfterkurve bzw. Grafikkarten-Software prüfen') 'Grafikkarte' 'moment' }
        elseif ($leerlauf -and $null -ne $g.TempC -and $g.TempC -ge 70) { P 'warn' ($txt + ' – im Leerlauf ungewöhnlich warm. Luftstrom im Gehäuse prüfen') 'Grafikkarte' 'moment' }
        elseif (-not $leerlauf -and $null -ne $g.TempC -and $g.TempC -ge $grenzeLast) { P 'warn' ($txt + ' – läuft an der Temperaturgrenze') 'Grafikkarte' 'moment' }
        elseif ($m -band 0x88) { P 'warn' ($txt + ' – wird gebremst: ' + ((Get-NvidiaReasonText ($m -band 0x88)) -join ', ')) 'Grafikkarte' 'moment' }
        elseif ($m -band 0x20) { P '' ($txt + ' – regelt den Takt, um ihre Temperaturgrenze zu halten (normal unter Last)') 'Grafikkarte' 'moment' }
        elseif ($null -ne $g.LuefterProzent -and $g.LuefterProzent -eq 0) { P 'ok' ($txt + ' (Lüfter stehen bei wenig Last – das ist so gewollt und leise)') 'Grafikkarte' 'moment' }
        else { P 'ok' $txt 'Grafikkarte' 'moment' }
        if ($g.PcieBreite -and $g.PcieBreiteMax -and $g.PcieBreite -lt $g.PcieBreiteMax) {
            if ($g.PcieBreite -le 4) { P 'warn' ("{0} ist nur mit x{1} statt x{2} angebunden – steckt sie im richtigen Steckplatz (meist der oberste lange)?" -f $g.Name, $g.PcieBreite, $g.PcieBreiteMax) 'Grafikkarte' }
            else { P '' ("{0} ist mit x{1} statt x{2} angebunden – bei manchen Mainboards normal, wenn weitere Steckplätze oder M.2-Plätze belegt sind" -f $g.Name, $g.PcieBreite, $g.PcieBreiteMax) 'Grafikkarte' }
        }
    }

    # ---- Laufwerke
    foreach ($d in (Get-DiskHealth)) {
        if ($d.Zustand -in 'Unhealthy', '2' -or $d.Betrieb -match 'Predictive Failure' -or $d.Ausfallwarnung) { P 'krit' ("Laufwerk {0}: meldet einen drohenden Defekt – wichtige Daten jetzt sichern und das Laufwerk tauschen lassen" -f $d.Name) 'Laufwerke'; continue }
        if ($d.Zustand -in 'Warning', '1') { P 'warn' ("Laufwerk {0}: meldet Auffälligkeiten – Daten sichern und das Laufwerk prüfen lassen" -f $d.Name) 'Laufwerke' }
        if ($null -ne $d.Verschleiss -and $d.Verschleiss -ge 100) { P 'krit' ("SSD {0}: Lebensdauer laut Hersteller verbraucht ({1} %) – Daten sichern, SSD tauschen" -f $d.Name, $d.Verschleiss) 'Laufwerke' }
        elseif ($null -ne $d.Verschleiss -and $d.Verschleiss -ge 80) { P 'warn' ("SSD {0}: {1} % der Lebensdauer verbraucht" -f $d.Name, $d.Verschleiss) 'Laufwerke' }
        if ($null -ne $d.TempC) {
            $art = if ($d.Art) { $d.Art } else { 'HDD' }
            $w = $c.DiskTempWarnC.$art; $k = $c.DiskTempCritC.$art
            if ($k -and $d.TempC -ge $k) { P 'krit' ("Laufwerk {0}: {1} °C – deutlich zu heiß. Luftstrom im Gehäuse verbessern (bei NVMe: Kühlkörper)" -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
            elseif ($w -and $d.TempC -ge $w) { P 'warn' ("Laufwerk {0}: {1} °C – warm. Luftstrom im Gehäuse prüfen" -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
            else { P 'ok' ("Laufwerk {0}: {1} °C" -f $d.Name, $d.TempC) 'Laufwerke' 'moment' }
        }
    }
    if ($Script:Cache.SmartUnmapped -gt 0) { P 'krit' 'Ein Laufwerk warnt über seine Selbstdiagnose (SMART) vor einem Ausfall – wichtige Daten jetzt sichern' 'Laufwerke' }

    # ---- Arbeitsspeicher und Prozessor-Fehler (Ereignisse)
    $since90 = (Get-Date).AddDays(-90); $since30 = (Get-Date).AddDays(-30)
    if ((Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; Id = 1202; StartTime = $since90 }) -gt 0) { P 'krit' 'Die Windows-Speicherdiagnose hat Fehler im Arbeitsspeicher gefunden – RAM prüfen lassen (Riegel, XMP/EXPO-Einstellung)' 'Speicher' }
    $w19 = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 19; StartTime = $since30 }
    if ($w19 -ge 5) { P 'warn' ("Der Prozessor hat {0}-mal korrigierte Fehler gemeldet – häufig bei Übertaktung (PBO, Curve Optimizer, XMP/EXPO). BIOS-Einstellungen auf Standard prüfen" -f $w19) 'CPU' }
    $w17 = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17; StartTime = $since30 }
    if ($w17 -ge 5) { P 'warn' ("Eine Steckverbindung (PCIe) hat {0}-mal korrigierte Fehler gemeldet – Sitz von Grafikkarte/SSD, Riser-Kabel oder die PCIe-Einstellung im BIOS prüfen" -f $w17) 'CPU' }

    # ---- Akku
    if ($ch.HatAkku) {
        $wear = Get-BatteryWear
        if ($null -ne $wear) {
            if ($wear -ge 50) { P 'krit' ("Akku: hat {0} % seiner ursprünglichen Kapazität verloren – ein Austausch lohnt sich" -f $wear) 'Akku' }
            elseif ($wear -ge 30) { P 'warn' ("Akku: hat {0} % seiner ursprünglichen Kapazität verloren" -f $wear) 'Akku' }
            else { P 'ok' ("Akku: {0} % Kapazitätsverlust (normal)" -f [math]::Max(0, $wear)) 'Akku' }
        }
    }
    $Script:Cache.HwPoints = $pts.ToArray()
    return $Script:Cache.HwPoints
}

# Mehrere Luefter-/Tuning-Programme gleichzeitig kaempfen um die Steuerung (schwankende Luefter, Fehlwerte)
function Get-FanToolPoints {
    $gruppen = [ordered]@{
        'Mainboard-Lüfter' = @{ 'ArmouryCrate' = 'Armoury Crate'; 'AsusFanControlService' = 'ASUS Fan Xpert'; 'MSI.CentralServer' = 'MSI Center'; 'GCC' = 'Gigabyte Control Center'; 'EasyTune' = 'Gigabyte EasyTune'; 'FanControl' = 'Fan Control'; 'ArgusMonitor' = 'Argus Monitor'; 'SpeedFan' = 'SpeedFan'; 'NZXT CAM' = 'NZXT CAM'; 'iCUE' = 'Corsair iCUE'; 'L-Connect' = 'Lian Li L-Connect'; 'G-Helper' = 'G-Helper'; 'LegionToolkit' = 'Legion Toolkit' }
        'Grafikkarten-Lüfter' = @{ 'MSIAfterburner' = 'MSI Afterburner'; 'GPUTweakII' = 'ASUS GPU Tweak'; 'GPUTweakIII' = 'ASUS GPU Tweak'; 'PrecisionX_x64' = 'EVGA Precision X1'; 'PrecisionX' = 'EVGA Precision X1' }
    }
    $proc = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $res = @()
    foreach ($g in $gruppen.Keys) {
        $tab = $gruppen[$g]
        $treffer = @($tab.Keys | Where-Object { $n = $_; $proc | Where-Object { $_ -like "$n*" } } | ForEach-Object { $tab[$_] } | Select-Object -Unique)
        if ($treffer.Count -ge 2) { $res += [pscustomobject]@{ Stufe = 'warn'; Text = ("Mehrere Programme steuern gleichzeitig die {0}: {1} – das kann zu schwankenden oder falschen Lüfterdrehzahlen führen. Am besten nur eines davon verwenden" -f $g, ($treffer -join ', ')); Bereich = 'Lüfter'; Wertung = 'dauer' } }
    }
    $tuning = @(@{ 'ThrottleStop' = 'ThrottleStop'; 'XtuService' = 'Intel XTU'; 'AMDRyzenMasterDriver' = 'Ryzen Master'; 'RyzenMaster' = 'Ryzen Master' }.GetEnumerator() | Where-Object { $n = $_.Key; $proc | Where-Object { $_ -like "$n*" } } | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($tuning.Count) { $res += [pscustomobject]@{ Stufe = ''; Text = ("Tuning-Programm aktiv ({0}) – Spannungen/Takt werden manuell beeinflusst; das wirkt sich auf Temperaturen und den Kühlungstest aus" -f ($tuning -join ', ')); Bereich = 'CPU'; Wertung = 'dauer' } }
    return $res
}

# Kompakte Hardware-Messwerte fuer den Snapshot (Vorher/Nachher und Verlauf)
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

# Kuehlungstest: belastet die Prozessorkerne fuer kurze Zeit und beobachtet Leistung, Drosselung und - falls ein
# Hardware-Monitor laeuft - Temperatur und Luefterdrehzahl. Aendert nichts am System.
# Status: OK | ABGEBROCHEN (vom Benutzer, wird nicht gespeichert) | GESTOPPT (Sicherheitsabbruch) | AKKU | GESPERRT
function Invoke-CoolingTest([int]$Seconds = 60, [scriptblock]$OnProgress = $null, $Control = $null) {
    $Seconds = [math]::Max($Script:CoolingTestMin, [math]::Min(600, $Seconds))
    $Script:Cache = @{}
    $ch = Get-ChassisInfo
    if ($ch.Akku) { return [pscustomobject]@{ Status = 'AKKU'; Meldung = 'Der Kühlungstest geht nur mit angeschlossenem Netzteil. Bitte das Netzteil anschließen und es dann noch einmal versuchen.'; Punkte = @() } }
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    if ($ch.VM -or ($ctx -and $ctx.Server)) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = 'Auf Servern und in virtuellen Maschinen ist der Kühlungstest nicht sinnvoll und deshalb gesperrt.'; Punkte = @() } }
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
    // Windows 11 drosselt Prozesse mit niedriger Prioritaet per EcoQoS - fuer die Messung ausdruecklich abschalten
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
        // Watchdog: endet spaetestens zur Deadline, auch wenn PowerShell haengt
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
    $threads = [Environment]::ProcessorCount; if ($threads -gt 4) { $threads-- }   # einen Kern fuer Windows und die Messung frei lassen
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
            # Sicherheitsabbruch
            if ($null -ne $s.CpuTempC -and $s.CpuTempC -ge $tj + 3) { $grund = ('Prozessor über {0} °C' -f [int]$s.CpuTempC); break }
            if ($s.ZonePassiv -and $s.ZonePassiv -lt 80) { $grund = 'Windows bremst den Prozessor wegen Hitze stark'; break }
            if ($ch.HatAkku -and @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -OperationTimeoutSec 3 -ErrorAction SilentlyContinue | Where-Object { $_.PowerOnline -eq $false }).Count) { $grund = 'Netzteil wurde getrennt'; break }
            if ($OnProgress) { try { & $OnProgress ([int]$el) $Seconds ("Kühlungstest läuft – noch {0} Sekunden. Die Lüfter werden dabei hörbar lauter." -f [int]([math]::Max(0, $Seconds - $el))) 'HW-COOLTEST' } catch { } }
        }
    } finally { [WtBurn2]::Stop() }
    if ($OnProgress) { try { & $OnProgress $Seconds $Seconds 'Fast fertig – der Prozessor kühlt ab …' 'HW-COOLTEST' } catch { } }
    for ($i = 0; $i -lt 3; $i++) { Start-Sleep -Milliseconds 2000; $verlauf.Add((Sample 'Danach' $sw.Elapsed.TotalSeconds)) }
    $pts = New-Object System.Collections.Generic.List[object]
    function P([string]$Stufe, [string]$Text) { $pts.Add([pscustomobject]@{ Stufe = $Stufe; Text = $Text }) }
    $ruhe = @($verlauf | Where-Object Phase -eq 'Ruhe'); $last = @($verlauf | Where-Object Phase -eq 'Last')
    $status = if ($abbruch) { 'ABGEBROCHEN' } elseif ($grund) { 'GESTOPPT' } else { 'OK' }
    if ($abbruch) { P '' 'Der Test wurde abgebrochen – das Ergebnis ist unvollständig.' }
    if ($grund) { P 'krit' ("Der Test wurde zur Sicherheit vorzeitig beendet: {0}. Die Kühlung sollte geprüft werden." -f $grund) }
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
        # 1) Leistung unter Dauerlast. Ein Abfall nach der Turbo-Phase ist oft gewollt (Leistungs-/Zeitlimit des Herstellers);
        #    als Kuehlungsproblem gilt er nur zusammen mit Erreichen der Temperaturgrenze oder Drosselsignalen.
        if ($mitLeistung.Count -ge 6) {
            $n = $mitLeistung.Count; $q = [math]::Max(2, [int][math]::Floor($n / 4))
            $anfang = ($mitLeistung | Select-Object -First $q | Measure-Object Leistung -Average).Average
            $ende = ($mitLeistung | Select-Object -Last $q | Measure-Object Leistung -Average).Average
            $drop = if ($anfang -gt 0) { [math]::Round(100 * ($anfang - $ende) / $anfang, 0) } else { 0 }
            if ($drop -ge 15 -and ($heiss -or $signal)) {
                $st = if ($drop -ge 30) { 'krit' } else { 'warn' }
                P $st ("Der Prozessor wird unter Dauerlast um {0} % langsamer und erreicht dabei seine Temperaturgrenze bzw. wird gebremst – typisch für zu schwache Kühlung, verstaubte Kühler oder zu langsam drehende Lüfter" -f $drop)
            } elseif ($drop -ge 30 -and $null -eq $tmax) {
                P 'warn' ("Der Prozessor wird unter Dauerlast um {0} % langsamer. Ohne Temperaturfühler ist unklar, ob das an der Kühlung oder an einer Leistungsgrenze liegt – LibreHardwareMonitor starten und den Test wiederholen" -f $drop)
            } elseif ($drop -ge 15) {
                P '' ("In den ersten Sekunden arbeitet der Prozessor kurz schneller als auf Dauer vorgesehen. Danach sinkt die Leistung um {0} % – {1}" -f $drop, $(if ($null -ne $tmax) { 'die Temperatur bleibt dabei unter der Grenze, das ist eine Leistungsgrenze des Herstellers und kein Kühlungsproblem.' } else { 'das ist bei vielen Prozessoren vom Hersteller so gewollt.' }))
            } else { P 'ok' ("Der Prozessor hält seine Leistung auch unter Dauerlast (am Ende noch {0:N0} % der Anfangsleistung)" -f $(if ($anfang -gt 0) { 100 * $ende / $anfang } else { 100 })) }
            if ($limitProben -ge 3) { P $(if ($heiss) { 'warn' } else { '' }) ("Die Firmware hat die Leistung während des Tests zeitweise begrenzt (Leistungs- oder Temperaturgrenze)") }
        } else { P '' 'Die Prozessorleistung ließ sich auf diesem PC nicht messen.' }
        if ($neu37 -gt 0) { P 'warn' ("Während des Tests hat Windows {0}-mal eine Drosselung durch die Firmware gemeldet" -f $neu37) }
        if ($zp -and $zp -lt 100) { P $(if ($zp -le 80) { 'krit' } else { 'warn' }) ("Windows hat den Prozessor während des Tests gebremst (bis auf {0} %)" -f $zp) }
        # 2) Temperatur und Luefterreaktion (nur mit Hardware-Monitor)
        if ($null -ne $tmax) {
            if ($heiss) { P '' ("Der Prozessor erreicht unter Last {0:N0} °C und damit seine Temperaturgrenze ({1} °C). Viele aktuelle Prozessoren regeln bewusst an dieser Grenze – entscheidend ist, ob die Leistung dabei einbricht (siehe oben)." -f $tmax, $tj) }
            else { P 'ok' ("Prozessor-Temperatur unter Last: höchstens {0:N0} °C (Grenze {1} °C)" -f $tmax, $tj) }
            $namen = @($ruhe + $last | ForEach-Object { @($_.Luefter.Keys) } | Select-Object -Unique)
            $reakt = @(); $kand = 0
            foreach ($fn in $namen) {
                $f0 = ($ruhe | ForEach-Object { $_.Luefter[$fn] } | Where-Object { $_ -gt 0 } | Measure-Object -Average).Average
                $fm = ($last | ForEach-Object { $_.Luefter[$fn] } | Where-Object { $_ -gt 0 } | Measure-Object -Maximum).Maximum
                if ($f0 -gt 0 -and $fm -gt 0) { $kand++; $reakt += [pscustomobject]@{ Name = $fn; Plus = [math]::Round(100 * ($fm - $f0) / $f0, 0) } }
            }
            if ($kand -and $null -ne $t0c) {
                $best = $reakt | Sort-Object Plus -Descending | Select-Object -First 1
                if ($best.Plus -ge 15) { P 'ok' ("Die Lüfter reagieren auf Wärme ({0}: +{1} % Drehzahl unter Last)" -f $best.Name, $best.Plus) }
                elseif ($best.Plus -lt 5 -and ($tmax - $t0c) -ge 20 -and $tmax -ge 85) { P 'warn' ("Die Lüfter drehen kaum hoch (höchstens +{0} %), obwohl der Prozessor {1:N0} °C wärmer wurde – vermutlich feste Drehzahl. Lüfterkurve im BIOS prüfen (bei Wasserkühlungen reagieren die Lüfter oft absichtlich träge)" -f $best.Plus, ($tmax - $t0c)) }
                else { P '' ("Die Lüfter drehen etwas hoch (höchstens +{0} %)" -f $best.Plus) }
            }
        } else { P '' 'Ohne Temperaturfühler (z. B. LibreHardwareMonitor) bewertet WinTidy nur, ob der Prozessor unter Last gebremst wird.' }
        P '' 'Hinweis: Ein Test von einer Minute zeigt grobe Fehler (Kühler sitzt nicht, Lüfter steht, keine Wärmeleitpaste). Wie sich der PC bei stundenlanger Last verhält, zeigt er nicht.'
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

# Gemeinsame Hilfe fuer Datentraegerbereinigung (cleanmgr /sagerun) mit ausgewaehlten Kategorien
function Invoke-CleanMgr([string[]]$Categories) {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    # Reste eines abgebrochenen Laufs entfernen, sonst raeumt cleanmgr ungewollt weitere Kategorien (z. B. Windows.old) mit ab
    foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) { Remove-ItemProperty -LiteralPath $k.PSPath -Name StateFlags4711 -ErrorAction SilentlyContinue }
    $set = @(); foreach ($c in $Categories) { if (Test-Path "$root\$c") { Set-ItemProperty "$root\$c" -Name StateFlags4711 -Value 2 -Type DWord; $set += $c } }
    if (-not $set.Count) { throw 'Keine passenden Bereinigungskategorien gefunden' }
    try {
        $p = Start-Process "$env:windir\System32\cleanmgr.exe" -ArgumentList '/sagerun:4711' -PassThru -WindowStyle Minimized
        if (-not $p.WaitForExit(3600000)) { throw 'Zeitueberschreitung (60 Min.)' }
    } finally { foreach ($c in $set) { Remove-ItemProperty "$root\$c" -Name StateFlags4711 -ErrorAction SilentlyContinue } }
    return $set.Count
}

# =============================================================================
#  Regeln
#  Jede Regel: Id, Kategorie, Titel, Warum, Risiko (Niedrig|Mittel|Hoch|Info), Wirkung,
#              Admin (bool), Standard (bool), Detect {-> Items}, Fix {param($item) -> Meldung}
#              optional: Dauer (Text), Endgueltig, Einzeln, Umkehrbar (bool) - fuer die App
#  Item.Data.Stufe (ok|warn|krit) steuert bei Info-Regeln das Symbol in der App
#  Item: [pscustomobject]@{ Label; Bytes; Data }
# =============================================================================
function New-Item2([string]$Label, [double]$Bytes = 0, $Data = $null, [string]$Technik = $null) { [pscustomobject]@{ Label = $Label; Bytes = [int64]$Bytes; Data = $Data; Technik = $Technik } }

$Script:Rules = @(

    # ---------------------------------------------------------------- Speicher
    [pscustomobject]@{ Id = 'CLN-TEMP'; Kategorie = 'Speicher'; Titel = 'Temporaere Dateien'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = 'Temp-Ordner wachsen unbegrenzt. Geloescht werden nur Dateien, die laenger als die Altersgrenze weder angelegt noch geaendert wurden (laufende Installer bleiben unberuehrt). Verknuepfungen werden nie verfolgt. Weitere Ordner nur ueber ExtraTempPaths in der Konfiguration.'
        Detect = {
            $paths = @($env:TEMP) + @($Script:Cfg.ExtraTempPaths); if ($Script:IsAdmin) { $paths += "$env:windir\Temp" }
            foreach ($p in ($paths | Where-Object { $_ } | Select-Object -Unique)) {
                $f = @(Get-OldFiles $p $Script:Cfg.TempAgeDays)
                if ($f.Count) { New-Item2 ("Temporäre Dateien in {0}: {1} Dateien, älter als {2} Tage" -f $p, $f.Count, $Script:Cfg.TempAgeDays) (($f | Measure-Object Length -Sum).Sum) $p }
            }
        }
        Fix = { param($it) $n = 0; foreach ($f in (Get-OldFiles $it.Data $Script:Cfg.TempAgeDays)) { try { if (Test-PathChainNoReparse $it.Data $f.FullName) { $f.Attributes = 'Normal'; $f.Delete(); $n++ } } catch { } }; Remove-EmptyDirs $it.Data $Script:Cfg.TempAgeDays; "$n Dateien geloescht" }
    }

    [pscustomobject]@{ Id = 'CLN-WINCLEAN'; Kategorie = 'Speicher'; Titel = 'Windows-Datentraegerbereinigung (Update-Reste, Fehlerberichte, Update-Cache)'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Dauer = '5–15 Minuten'; Endgueltig = $true
        Warum = 'Nutzt die Windows-eigene Bereinigung (cleanmgr /sagerun) fuer Update-Reste, Fehlerberichte, Speicherabbilder und den Delivery-Optimization-Cache. Die vorherige Windows-Version (Windows.old) behandelt die eigene Regel CLN-WINOLD.'
        Detect = {
            if (-not (Test-Path "$env:windir\System32\cleanmgr.exe")) { return }
            $t = @("$env:windir\SoftwareDistribution\Download", "$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache", "$env:ProgramData\Microsoft\Windows\WER", "$env:windir\MEMORY.DMP", "$env:windir\Minidump", "$env:windir\LiveKernelReports")
            $sum = 0; $found = @()
            foreach ($p in $t) { $s = Get-DirSize $p; if ($s -gt 10MB) { $sum += $s; $found += ('{0} ({1})' -f (Split-Path $p -Leaf), (Fmt-Bytes $s)) } }
            if ($sum -gt 50MB) { New-Item2 ('Reste von Windows-Updates und Fehlerberichte (' + ($found -join ', ') + ')') $sum $null }
        }
        Fix = { param($it)
            $n = Invoke-CleanMgr @('Update Cleanup', 'Windows Error Reporting Files', 'Delivery Optimization Files', 'System error memory dump files', 'System error minidump files', 'Windows Upgrade Log Files', 'Setup Log Files', 'Downloaded Program Files')
            # cleanmgr laesst den Delivery-Optimization-Cache und Treiber-Watchdog-Abbilder teils liegen
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { } }
            $lkr = "$env:windir\LiveKernelReports"
            if (Test-Path $lkr) { Get-ChildItem $lkr -Recurse -File -Filter '*.dmp' -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue }
            "Kategorien: $n"
        }
    }

    [pscustomobject]@{ Id = 'CLN-WINOLD'; Kategorie = 'Speicher'; Titel = 'Vorherige Windows-Version (Windows.old) und Upgrade-Reste entfernen'; Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Endgueltig = $true; Dauer = '5–20 Minuten'
        Warum = 'Nach einem grossen Windows-Update bleibt die vorherige Version als Windows.old liegen (oft 10-30 GB). Danach ist ein Zurueck zur alten Windows-Version nicht mehr moeglich. Liegen in Windows.old noch persoenliche Dateien (nach Neuinstallation/Zuruecksetzen), wird gewarnt und nichts vorausgewaehlt. Die Dateien fuer "Diesen PC zuruecksetzen" bleiben erhalten.'
        Detect = {
            if (-not (Test-Path "$env:windir\System32\cleanmgr.exe")) { return }
            $old = "$env:SystemDrive\Windows.old"; $sum = 0
            foreach ($d in @($old, "$env:SystemDrive\`$WINDOWS.~BT", "$env:SystemDrive\`$Windows.~WS")) { $s = Get-DirSize $d; if ($s -gt 10MB) { $sum += $s } }
            if ($sum -lt 500MB) { return }
            $alter = $null; if (Test-Path -LiteralPath $old) { try { $alter = [int]((Get-Date) - (Get-Item -LiteralPath $old -Force).CreationTime).TotalDays } catch { } }
            # Persoenliche Dateien in Windows.old\Users? (nach Neuinstallation ohne Formatieren oft die einzige Kopie)
            $userBytes = [int64]0
            if (Test-Path -LiteralPath "$old\Users") {
                foreach ($u in @(Get-ChildItem -LiteralPath "$old\Users" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' -and -not (Test-Reparse $_) })) {
                    foreach ($sub in 'Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads', 'OneDrive') { $userBytes += Get-DirSize (Join-Path $u.FullName $sub) }
                }
            }
            $lbl = 'Vorherige Windows-Version und Upgrade-Reste' + $(if ($null -ne $alter) { " (seit $alter Tagen)" } else { '' })
            if ($userBytes -gt 10MB) { $lbl += (' – ACHTUNG: enthält noch {0} persönliche Dateien (Windows.old\Users). Vorher sichern!' -f (Fmt-Bytes $userBytes)) }
            $it = New-Item2 $lbl $sum @{ AlterTage = $alter; PersoenlicheBytes = $userBytes; Stufe = $(if ($userBytes -gt 10MB) { 'warn' } else { '' }) }
            $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue ($null -ne $alter -and $alter -ge $Script:Cfg.WinOldMinAgeDays -and $userBytes -le 10MB)
            $it
        }
        Fix = { param($it) $n = Invoke-CleanMgr @('Previous Installations', 'Temporary Setup Files'); "Kategorien: $n" }
    }

    [pscustomobject]@{ Id = 'CLN-WINSXS'; Kategorie = 'Speicher'; Titel = 'Windows-Komponentenspeicher (WinSxS) bereinigen'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Dauer = '5–30 Minuten'
        Warum = 'Ersetzte Komponenten aus Updates bleiben im WinSxS liegen. DISM entfernt sie, wenn Windows selbst eine Bereinigung empfiehlt (ohne /ResetBase). Ersetzte Komponenten werden dabei sofort entfernt; das aktuelle Update bleibt deinstallierbar. Die Analyse laeuft hoechstens alle 7 Tage (mit -Deep immer).'
        Detect = {
            # Die DISM-Analyse dauert Minuten und heizt die CPU auf: nur alle 7 Tage (oder mit -Deep), nie bei ausstehendem Neustart
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
            # DISM meldet oft auch direkt nach einer Bereinigung weiter "empfohlen" - dann nicht staendig erneut vorschlagen
            $kuerzlich = $false
            foreach ($f in (Get-ChildItem $Script:RunsDir -Recurse -Filter 'actions.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })) {
                if (Select-String -LiteralPath $f.FullName -Pattern '"Regel":"CLN-WINSXS".*"Status":"OK"' -Quiet) { $kuerzlich = $true; break }
            }
            if ($w.Empfohlen -and -not $kuerzlich) { New-Item2 ('Komponentenbereinigung empfohlen (Sicherungen/deaktivierte Features: {0}; wie viel davon frei wird, entscheidet Windows)' -f (Fmt-Bytes $w.BackupsBytes)) 0 $null }
        }
        Fix = { param($it) $o = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /English 2>&1; if ($LASTEXITCODE -ne 0) { throw ("Windows konnte die Bereinigung gerade nicht ausführen – später noch einmal versuchen (DISM-Code {0})" -f $LASTEXITCODE) }; Remove-Item -LiteralPath (Join-Path $Script:DataDir 'winsxs-analyse.json') -ErrorAction SilentlyContinue; 'DISM erfolgreich' }
    }

    [pscustomobject]@{ Id = 'CLN-DUMPS'; Kategorie = 'Speicher'; Titel = 'Absturzabbilder von Programmen'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = 'Programm-Absturzabbilder (CrashDumps) sind nur fuer Entwickler nuetzlich und koennen mehrere GB gross werden.'
        Detect = { $p = Join-Path $env:LOCALAPPDATA 'CrashDumps'; $f = @(Get-OldFiles $p $Script:Cfg.CrashDumpAgeDays); if ($f.Count) { New-Item2 ("Absturzberichte von Programmen: {0} Dateien" -f $f.Count) (($f | Measure-Object Length -Sum).Sum) $p } }
        Fix = { param($it) $n = 0; foreach ($f in (Get-OldFiles $it.Data $Script:Cfg.CrashDumpAgeDays)) { try { if (Test-PathChainNoReparse $it.Data $f.FullName) { $f.Attributes = 'Normal'; $f.Delete(); $n++ } } catch { } }; "$n Dateien" }
    }

    [pscustomobject]@{ Id = 'CLN-HIBERFIL'; Kategorie = 'Speicher'; Titel = 'Ruhezustandsdatei auf Desktop-PCs verkleinern'; Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'hiberfil.sys ist auf Desktops oft 40 % des Arbeitsspeichers gross, obwohl der Ruhezustand kaum genutzt wird. "powercfg /h /type reduced" verkleinert sie auf die Groesse, die der Schnellstart braucht - der Schnellstart bleibt, nur der Ruhezustand entfaellt. Rueckgaengig ueber "Wiederherstellen". Vorausgewaehlt nur, wenn der Ruhezustand nicht im Startmenue angeboten wird.'
        Detect = {
            $ch = Get-ChassisInfo; if ($ch.Laptop) { return }
            $hf = Join-Path $env:SystemDrive 'hiberfil.sys'
            $f = Get-Item -LiteralPath $hf -Force -ErrorAction SilentlyContinue; if (-not $f) { return }
            $ram = [double](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory; if (-not $ram) { return }
            if ($f.Length -lt 2GB -or $f.Length -lt 0.3 * $ram) { return }
            $spar = [int64]([math]::Max(0, $f.Length - 0.2 * $ram))
            $zeigt = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' -ErrorAction SilentlyContinue).ShowHibernateOption
            # Hybrider Standby und Ein-/Ruhetaste auf "Ruhezustand" brauchen die volle Datei
            $hybrid = Get-PowerSettingIndex '238c9fa8-0aad-41ed-83f4-97be242c8f20' '94ac6d29-73ce-41a6-809f-6363ba21b47e'
            $pb = Get-PowerSettingIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '7648efa3-dd9c-4e3e-b566-50f929386280'
            $sb = Get-PowerSettingIndex '4f971e89-eebd-4455-a8de-9e59040e7347' '96996bc0-ad50-47ec-923b-6f41874dd9eb'
            $braucht = ($hybrid -and $hybrid.AC -eq 1) -or ($pb -and $pb.AC -eq 2) -or ($sb -and $sb.AC -eq 2)
            $txt = "Ruhezustandsdatei ({0}) – nach dem Verkleinern ca. {1} frei" -f (Fmt-Bytes $f.Length), (Fmt-Bytes $spar)
            if ($hybrid -and $hybrid.AC -eq 1) { $txt += '. Achtung: Der hybride Standby (schützt im Energiesparmodus bei Stromausfall) ist an und würde mit abgeschaltet' }
            $it = New-Item2 $txt $spar $null
            $it | Add-Member -NotePropertyName AutoOk -NotePropertyValue ($zeigt -ne 1 -and -not $braucht)
            $it
        }
        Fix = { param($it)
            $null = & powercfg.exe /h /type reduced 2>&1
            if ($LASTEXITCODE -ne 0) { throw "powercfg meldet Fehler $LASTEXITCODE" }
            Add-ActionRecord 'CLN-HIBERFIL' 'Ruhezustandsdatei' 'Undo-Info' 0 '' @{ Typ = 'Hiber'; Vorher = 'full' } | Out-Null
            'verkleinert'
        }
    }

    [pscustomobject]@{ Id = 'CLN-RECYCLE'; Kategorie = 'Speicher'; Titel = 'Alte Papierkorb-Eintraege'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
        Warum = 'Nur Eintraege, die vor mehr als der Altersgrenze geloescht wurden. Frisch Geloeschtes bleibt wiederherstellbar.'
        Detect = { $o = @(Get-RecycleBinOld $Script:Cfg.RecycleBinAgeDays); if ($o.Count) { New-Item2 ("{0} Dateien, die vor über {1} Tagen gelöscht wurden" -f $o.Count, $Script:Cfg.RecycleBinAgeDays) (($o | Measure-Object Size -Sum).Sum) $null } }
        Fix = { param($it)
            $n = 0
            foreach ($e in (Get-RecycleBinOld $Script:Cfg.RecycleBinAgeDays)) {
                $i = Join-Path (Split-Path $e.Path) ((Split-Path $e.Path -Leaf) -replace '^\$R', '$I')
                try { Remove-TreeNoFollow $e.Path } catch { }
                if (-not (Test-Path -LiteralPath $e.Path)) { Remove-Item -LiteralPath $i -Force -ErrorAction SilentlyContinue; $n++ }
            }
            "$n Eintraege entfernt"
        }
    }

    [pscustomobject]@{ Id = 'CLN-RECYCLE-ORPHAN'; Kategorie = 'Speicher'; Titel = 'Papierkoerbe nicht mehr existierender Benutzerkonten'; Risiko = 'Mittel'; Wirkung = 'Speicher'; Admin = $true; Standard = $true; Endgueltig = $true
        Warum = 'Nach Neuinstallationen oder Kontowechseln bleiben auf jedem Laufwerk Papierkoerbe alter Konten-SIDs liegen, die kein Benutzer mehr sieht. Angeboten wird nur, was zu keinem Profil und keinem existierenden Konto gehoert; ist die Profilliste nicht lesbar, wird nichts angeboten.'
        Detect = {
            $known = @(); try { $known = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Select-Object -ExpandProperty SID) } catch { return }
            if ($known.Count -lt 1) { return }
            $known += [string]$Script:Me.User.Value
            foreach ($v in (Get-VolumeInfo)) {
                $rb = "$($v.LW):\`$Recycle.Bin"
                if (-not (Test-Path -LiteralPath $rb)) { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $rb -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $known -notcontains $_.Name -and -not (Test-Reparse $_) })) {
                    # Konto existiert noch (z. B. Domaenenkonto ohne lokales Profil)? Dann nicht anbieten.
                    $lebt = $false; try { $null = (New-Object Security.Principal.SecurityIdentifier $d.Name).Translate([Security.Principal.NTAccount]); $lebt = $true } catch { }
                    if ($lebt) { continue }
                    $s = Get-DirSize $d.FullName
                    New-Item2 ("Papierkorb eines gelöschten Benutzerkontos auf {0}: ({1})" -f $v.LW, (Fmt-Bytes $s)) $s $d.FullName
                }
            }
        }
        Fix = { param($it) if ([string]$it.Data -notmatch '^[A-Za-z]:\\\$Recycle\.Bin\\S-1-5-21-[\d-]+$') { throw 'Unerwarteter Pfad' }; Remove-TreeNoFollow $it.Data; 'entfernt' }
    }

    [pscustomobject]@{ Id = 'CLN-DRIVERSTORE'; Kategorie = 'Speicher'; Titel = 'Alte Treiberpakete im Treiberspeicher'; Risiko = 'Mittel'; Wirkung = 'Speicher/Hygiene'; Admin = $true; Standard = $true
        Warum = 'Bei jedem Treiberupdate bleibt die alte Version im Treiberspeicher. Entfernt werden nur aeltere Duplikate (die neueste bleibt) und Chipsatztreiber des jeweils anderen CPU-Herstellers (Reste eines Vorgaenger-PCs). Treiber in Benutzung verweigert Windows (kein /force).'
        Detect = {
            $pk = Get-DriverPackages
            # INF-Dateien, die irgendein Geraet benutzt - auch ein gerade nicht angeschlossenes (Dock, Audio-Interface)
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
                    $grund = if ($fremdPlattform) { 'Chipsatz-Treiber anderer CPU-Plattform' } else { "aeltere Version, neueste $($s[0].VerText) bleibt" }
                    New-Item2 ("{0} {1} {2} {3} - {4}" -f $k.Pub, $k.Orig, $k.Prov, $k.VerText, $grund) 0 $k.Pub
                }
            }
        }
        Fix = { param($it) $o = & pnputil.exe /delete-driver $it.Data 2>&1; if ($LASTEXITCODE -ne 0) { throw 'SKIP:Wird noch benutzt – Windows behält diesen Treiber' }; 'entfernt' }
    }

    [pscustomobject]@{ Id = 'CLN-ORPHANDIR'; Kategorie = 'Speicher'; Titel = 'Ordner ohne zugehoeriges installiertes Programm'; Risiko = 'Hoch'; Wirkung = 'Speicher/Hygiene'; Admin = $false; Standard = $false
        Warum = 'Heuristik: Ordner in Programme/ProgramData/AppData, deren Name zu keinem installierten Programm passt. Kann Fehltreffer enthalten - darum nur auf ausdruecklichen Wunsch (-Rule CLN-ORPHANDIR) und mit Einzelbestaetigung.'
        Detect = {
            $apps = Get-InstalledApps
            $norm = { param($s) (([string]$s).ToLower() -replace '[^a-z0-9]', '') }
            $names = @(); foreach ($a in $apps) { $names += (& $norm $a.DisplayName); $names += (& $norm $a.Publisher); if ($a.InstallLocation) { $names += (& $norm (Split-Path ([string]$a.InstallLocation).Trim('"').TrimEnd('\') -Leaf)) } }
            foreach ($ax in (Get-AppxPackage -ErrorAction SilentlyContinue)) { $names += (& $norm $ax.Name) }
            $names = @($names | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
            $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ }
            foreach ($r in $roots) {
                foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
                    if ($Script:Cfg.OrphanDirIgnore -contains $d.Name -or (Test-Reparse $d)) { continue }
                    $n = & $norm $d.Name; if ($n.Length -lt 3) { continue }
                    $hit = $false; foreach ($x in $names) { if ($x.Contains($n) -or ($x.Length -ge 4 -and $n.Contains($x))) { $hit = $true; break } }
                    if ($hit) { continue }
                    $s = Get-DirSize $d.FullName
                    if ($s -ge ($Script:Cfg.OrphanDirMinMB * 1MB)) { New-Item2 ("{0} ({1})" -f $d.FullName, (Fmt-Bytes $s)) $s $d.FullName }
                }
            }
        }
        Fix = { param($it) if (-not (Test-SafeDeleteRoot $it.Data)) { throw 'Unsicherer Pfad' }; Remove-TreeNoFollow $it.Data; 'entfernt' }
    }

    # ---------------------------------------------------------------- Autostart
    [pscustomobject]@{ Id = 'STA-ORPHAN'; Kategorie = 'Autostart'; Titel = 'Autostart-Eintraege mit fehlender Programmdatei'; Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Verweist ein Autostart auf eine nicht mehr vorhandene Datei, ist das Programm deinstalliert. Eintraege auf derzeit fehlenden Laufwerken (USB) und im Netzwerk werden nicht angefasst. Alles wird vorher gesichert.'
        Detect = { Get-StartupItems | Where-Object { $_.Zustand -eq 'fehlt' } | ForEach-Object { New-Item2 ("{0} – das Programm dazu ist nicht mehr da" -f $_.Name) 0 $_ ("[{0}] {1} -> {2}" -f $_.Ort, $_.Name, $_.Ziel) } }
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
            'entfernt'
        }
    }

    [pscustomobject]@{ Id = 'STA-APPROVED-ORPHAN'; Kategorie = 'Autostart'; Titel = 'Verwaiste Autostart-Statuswerte'; Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Der Task-Manager merkt sich an/aus-Zustaende auch fuer laengst entfernte Programme.'
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
                    if ($exist -notcontains $n) { New-Item2 ("Überbleibsel von {0}" -f $n) 0 @{ Key = $p.SA; Name = $n } }
                }
            }
        }
        Fix = { param($it) Set-RegValueWithUndo 'STA-APPROVED-ORPHAN' $it.Data.Name $it.Data.Key $it.Data.Name $null '' -Remove; 'entfernt' }
    }

    [pscustomobject]@{ Id = 'STA-HEAVY'; Kategorie = 'Autostart'; Titel = 'Aktive Autostarts pruefen (gemessene Startbremsen zuerst)'; Risiko = 'Mittel'; Wirkung = 'Startzeit'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Jedes Programm im Autostart kostet Anmeldezeit und RAM. Deaktiviert wird wie im Task-Manager (umkehrbar, nichts wird deinstalliert). Vorausgewaehlt bzw. mit -Yes deaktiviert werden nur Eintraege aus HeavyStartup; Virenschutz, VPN, Backup, Cloud-Speicher und Eingabegeraete sind geschuetzt (ProtectedStartup).'
        Detect = {
            $prot = $Script:Cfg.ProtectedStartup; $heavy = $Script:Cfg.HeavyStartup
            Get-StartupItems | Where-Object { $_.Aktiv -and $_.Zustand -ne 'fehlt' } | Sort-Object DegradationMs -Descending | ForEach-Object {
                $s = $_; $vi = $null
                if ($s.Ziel -and ([string]$s.Ziel) -match '^[A-Za-z]:\\') { try { $vi = (Get-Item -LiteralPath $s.Ziel -ErrorAction Stop).VersionInfo } catch { } }
                $id = "$($s.Name) $($s.Ziel) $(if ($vi) { "$($vi.CompanyName) $($vi.FileDescription) $($vi.ProductName)" })"
                if ($prot | Where-Object { $id -like "*$_*" }) { return }
                $isHeavy = [bool]($heavy | Where-Object { $id -like "*$_*" })
                $nm = if ($vi -and $vi.FileDescription -and $s.Art -ne 'StoreApp') { "{0} ({1})" -f $s.Name, ([string]$vi.FileDescription).Trim() } else { $s.Name }
                $tag = @(); if ($s.DegradationMs -ge $Script:Cfg.BootDegradationHintMs) { $tag += ('verlängert den Start um etwa {0:N0} Sekunden' -f ($s.DegradationMs / 1000)) }; if ($isHeavy) { $tag += 'startet unnötig mit' }
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
            'deaktiviert'
        }
    }

    # ---------------------------------------------------------------- Aufgaben & Dienste
    [pscustomobject]@{ Id = 'TSK-ORPHAN'; Kategorie = 'Aufgaben'; Titel = 'Geplante Aufgaben mit fehlender Programmdatei'; Risiko = 'Niedrig'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Solche Aufgaben laufen bei jedem Trigger ins Leere und erzeugen Fehler. Sie werden deaktiviert (nicht geloescht) und vorher gesichert.'
        Detect = {
            foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' -and $_.State -ne 'Disabled' })) {
                foreach ($a in @($t.Actions)) {
                    if (-not $a.Execute) { continue }
                    $tg = Resolve-CommandTarget ("`"$(([string]$a.Execute).Trim('"'))`" $($a.Arguments)")
                    if ((Get-TargetState $tg) -eq 'fehlt') { New-Item2 ("Geplante Aufgabe {0} – das Programm dazu ist nicht mehr da" -f $t.TaskName) 0 $t ("{0}{1} -> {2}" -f $t.TaskPath, $t.TaskName, $tg); break }
                }
            }
        }
        Fix = { param($it) Backup-Task $it.Data; Disable-ScheduledTask -TaskName $it.Data.TaskName -TaskPath $it.Data.TaskPath -ErrorAction Stop | Out-Null; 'deaktiviert' }
    }

    [pscustomobject]@{ Id = 'TSK-ANTIPATTERN'; Kategorie = 'Aufgaben'; Titel = 'Eigene Wartungsskripte mit schaedlichen Mustern'; Risiko = 'Info'; Wirkung = 'Startzeit/Datensicherheit'; Admin = $false; Standard = $true
        Warum = 'Gut gemeinte Aufraeumskripte machen Windows oft langsamer oder gefaehrden Daten. Erkannt werden: Prefetch loeschen, Papierkorb komplett leeren, Downloads ohne Altersgrenze loeschen, winget --all/--force bei jeder Anmeldung.'
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
                        # Kommentare entfernen, damit erklaerende Hinweise ("Prefetch wird NICHT geloescht") nicht anschlagen
                        $code = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(#|rem\s|rem$|::|'')' } | ForEach-Object { $_ -replace '\s+#\s.*$', '' }) -join "`n"
                        $txt += "`n" + $code
                    }
                    $lines = $txt -split "`n"
                    $hits = @()
                    if ($lines | Where-Object { $_ -match '(?i)prefetch' -and $_ -match $del }) { $hits += 'loescht Prefetch -> Starts und Programmstarts werden langsamer' }
                    if (($txt -match '(?i)clear-recyclebin' -or ($lines | Where-Object { $_ -match '(?i)\$recycle\.bin' -and $_ -match $del })) -and $txt -notmatch '(?i)DateDeleted|AddDays|-lt\s*\$') { $hits += 'leert den Papierkorb komplett -> versehentlich Geloeschtes ist sofort weg' }
                    if (($lines | Where-Object { $_ -match '(?i)downloads' -and $_ -match $del }) -and $txt -notmatch '(?i)lastwritetime|adddays|creationtime|SendToRecycleBin') { $hits += 'loescht Downloads ohne Altersgrenze' }
                    if ($txt -match '(?i)winget(\.exe)?\s+upgrade\s+.*--all') { $hits += 'winget upgrade --all (installiert alles ungefragt, teils Versionen nebeneinander)' }
                    if ($txt -match '(?i)winget[^\n]*--force') { $hits += 'winget --force (uebergeht Sicherheitspruefungen)' }
                    foreach ($h in $hits) { New-Item2 ("{0}{1}: {2}{3}" -f $t.TaskPath, $t.TaskName, $h, $(if ($logon) { ' (bei jeder Anmeldung!)' } else { '' })) 0 $null }
                }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SVC-ORPHAN'; Kategorie = 'Dienste'; Titel = 'Dienste mit fehlender Programmdatei'; Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Reste deinstallierter Programme: Der Dienst startet nie erfolgreich und erzeugt Fehler im Ereignisprotokoll. Er wird auf "Deaktiviert" gesetzt (umkehrbar).'
        Detect = {
            foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -and $_.StartMode -ne 'Disabled' })) {
                $tg = Resolve-CommandTarget $s.PathName
                if ($tg -match '\\(svchost|lsass|services)\.exe$') { continue }
                if ((Get-TargetState $tg) -eq 'fehlt') { New-Item2 ("Hintergrunddienst {0} – das Programm dazu ist nicht mehr da" -f $s.DisplayName) 0 @{ Name = $s.Name; StartMode = $s.StartMode; Verzoegert = [bool]$s.DelayedAutoStart } ("{0} -> {1}" -f $s.Name, $tg) }
            }
        }
        Fix = { param($it) Set-Service -Name $it.Data.Name -StartupType Disabled -ErrorAction Stop; Add-ActionRecord 'SVC-ORPHAN' $it.Data.Name 'Undo-Info' 0 '' @{ Typ = 'Dienst'; Name = $it.Data.Name; StartMode = $it.Data.StartMode; Verzoegert = [bool]$it.Data.Verzoegert } | Out-Null; 'deaktiviert' }
    }

    # ---------------------------------------------------------------- Programme
    [pscustomobject]@{ Id = 'APP-SIDEBYSIDE'; Kategorie = 'Programme'; Titel = 'Mehrfach installierte Versionen desselben Programms'; Risiko = 'Mittel'; Wirkung = 'Speicher/Hygiene'; Admin = $true; Standard = $true
        Warum = 'Manche Installer legen Updates als zusaetzliche Version daneben. Angeboten wird die Deinstallation aller Versionen ausser der neuesten (Laufzeitumgebungen, SDKs usw. sind ausgenommen).'
        Detect = {
            $ex = ($Script:Cfg.SideBySideExclude -join '|')
            # Mit Adminrechten nur Eintraege aus HKLM: HKCU-Eintraege koennen von Programmen ohne Adminrechte stammen,
            # ihr Deinstallationsbefehl wuerde sonst mit Adminrechten laufen
            $apps = Get-InstalledApps | Where-Object { $_.DisplayName -notmatch $ex -and $_.UninstallString -and (-not $Script:IsAdmin -or [string]$_.PSPath -like '*HKEY_LOCAL_MACHINE*') }
            $grp = $apps | Group-Object { (($_.DisplayName -replace '\(?\b(x64|x86|64-?bit|32-?bit)\b\)?', '' -replace '\bv?\d+(\.\d+)+\b', '' -replace '\s+', ' ').Trim().ToLower()) + '|' + $_.Publisher }
            foreach ($g in ($grp | Where-Object { $_.Count -gt 1 })) {
                $withV = @($g.Group | ForEach-Object { $v = [version]'0.0'; $m = [regex]::Match(("$($_.DisplayVersion) $($_.DisplayName)"), '\d+(\.\d+)+'); if ($m.Success) { try { $v = [version]($m.Value -replace '^(\d+(\.\d+){0,3}).*$', '$1') } catch { } }; $_ | Add-Member -NotePropertyName V -NotePropertyValue $v -PassThru -Force })
                if (@($withV.V | Select-Object -Unique).Count -lt 2) { continue }
                $newest = ($withV | Sort-Object V -Descending)[0]
                foreach ($a in ($withV | Where-Object { $_ -ne $newest } | Sort-Object V)) { New-Item2 ("{0} {1} (neueste {2} bleibt)" -f $a.DisplayName, $a.DisplayVersion, $newest.DisplayVersion) ([int64]$a.EstimatedSize * 1KB) $a }
            }
        }
        Fix = { param($it)
            $a = $it.Data
            $s = if ($a.QuietUninstallString) { $a.QuietUninstallString } else { $a.UninstallString }
            if ($s -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] } elseif ($s -match '^\s*(.+?\.exe)\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] } else { $exe = $s; $arg = '' }
            if ($exe -match 'msiexec') { $arg = $arg -replace '/I\{', '/X{' }
            W '      (Deinstallationsprogramm oeffnet sich ggf. - bitte durchklicken)' 'DarkGray'
            $p = if ($arg.Trim()) { Start-Process -FilePath $exe -ArgumentList $arg -Wait -PassThru } else { Start-Process -FilePath $exe -Wait -PassThru }
            if ($p.ExitCode -in 1602, 1223) { throw 'SKIP:Deinstallation abgebrochen' }
            if ($p.ExitCode -notin 0, 3010, 1641) { throw "Deinstallation meldet Code $($p.ExitCode)" }
            'deinstalliert'
        }
    }

    [pscustomobject]@{ Id = 'APP-BLOAT'; Kategorie = 'Programme'; Titel = 'Vorinstallierte Store-Apps (Liste BloatApps)'; Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true
        Warum = 'Werbe- und Demo-Apps ohne Nutzen. Entfernt fuer den Benutzer und als Vorlage fuer neue Konten. Jederzeit aus dem Store neu installierbar.'
        Detect = {
            foreach ($n in $Script:Cfg.BloatApps) {
                $p = @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)
                if ($p.Count) { New-Item2 (Get-AppDisplayName $n) 0 $n ("{0} {1}" -f $n, $p[0].Version) }
            }
        }
        Fix = { param($it)
            Get-AppxPackage -Name $it.Data -ErrorAction SilentlyContinue | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Stop }
            if ($Script:IsAdmin) { try { Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -eq $it.Data | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null } } catch { } }
            'entfernt'
        }
    }

    [pscustomobject]@{ Id = 'APP-UPDATES'; Kategorie = 'Programme'; Titel = 'Veraltete Programme (winget)'; Risiko = 'Mittel'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true; Dauer = 'je Programm 1–5 Minuten'; Endgueltig = $true
        Warum = 'Veraltete Software ist das haeufigste Einfallstor. Aktualisiert wird einzeln ueber winget, Programme aus WingetExclude nie automatisch. Laufende Programme koennen dabei beendet werden.'
        Detect = {
            $ctx = $Script:LastContext; if ($ctx -and $ctx.AnderesKonto) { return }   # benutzerbezogene Installationen waeren unsichtbar
            $wg = Get-WingetPath; if (-not $wg) { return }
            $z = @(& $wg upgrade --source winget --disable-interactivity --accept-source-agreements 2>$null | ForEach-Object { ($_ -split "`r")[-1] })
            $kopf = $z | Where-Object { $_ -match '^\s*Name\s+I[dD]\s+' } | Select-Object -First 1
            if (-not $kopf) { return }
            $iId = $kopf.IndexOf(($kopf -split '\s+' | Where-Object { $_ -match '^I[dD]$' })[0]); $iVer = $kopf.IndexOf('Version')
            for ($k = [array]::IndexOf($z, $kopf) + 2; $k -lt $z.Count; $k++) {
                $l = $z[$k]; if ($l -notmatch '\S' -or $l.Length -le $iVer) { break }
                $id = $l.Substring($iId, $iVer - $iId).Trim(); if ($id -notmatch '^[^\s]+\.[^\s]+$') { break }
                if ($id -match '…|\.\.\.$') { continue }   # von winget gekuerzte ID - nicht eindeutig
                $name = $l.Substring(0, $iId).Trim()
                if ($Script:Cfg.WingetExclude | Where-Object { $name -like "*$_*" -or $id -like "*$_*" }) { continue }
                $ver = ($l.Substring($iVer).Trim() -split '\s+')
                New-Item2 ("{0}{1}" -f $name, $(if ($ver.Count -ge 2) { " ($($ver[0]) → $($ver[1]))" } else { '' })) 0 $id
            }
        }
        Fix = { param($it)
            $wg = Get-WingetPath; if (-not $wg) { throw 'winget nicht gefunden' }
            $o = & $wg upgrade --id $it.Data --exact --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1
            if ($LASTEXITCODE -ne 0) { throw ("Aktualisierung hat nicht geklappt – bitte später noch einmal versuchen oder das Programm selbst aktualisieren (winget-Code {0})" -f $LASTEXITCODE) }
            'aktualisiert'
        }
    }

    # ---------------------------------------------------------------- System
    [pscustomobject]@{ Id = 'SYS-GHOST'; Kategorie = 'System'; Titel = 'Geistergeraete (nicht mehr angeschlossene Hardware)'; Risiko = 'Mittel'; Wirkung = 'Hygiene'; Admin = $true; Standard = $true; Endgueltig = $true
        Warum = 'Alte Geraete bleiben im Geraete-Manager registriert (z. B. vom Vorgaenger-PC). Wird ein Geraet wieder angeschlossen, erkennt Windows es neu. Bluetooth, Audio-Endpunkte und Drucker sind ausgenommen.'
        Detect = {
            $cls = $Script:Cfg.GhostDeviceClasses
            $g = Get-GhostDevices
            foreach ($grp in ($g | Group-Object Class | Sort-Object Count -Descending)) {
                $bsp = ($grp.Group | Select-Object -ExpandProperty FriendlyName -Unique | Where-Object { $_ } | Select-Object -First 3) -join '; '
                New-Item2 ("{0} alte Einträge: {1} (z. B. {2})" -f $grp.Count, (Get-DeviceClassName $grp.Name), $bsp) 0 @($grp.Group | Select-Object -ExpandProperty InstanceId)
            }
        }
        Fix = { param($it) $ok = 0; $f = 0; foreach ($id in $it.Data) { & pnputil.exe /remove-device "$id" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ok++ } else { $f++ } }; "$ok entfernt, $f nicht" }
    }

    [pscustomobject]@{ Id = 'SYS-SHADOW'; Kategorie = 'System'; Titel = 'Zu wenig Speicher fuer Wiederherstellungspunkte'; Risiko = 'Niedrig'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true
        Warum = 'Ist der Schattenkopie-Speicher zu klein, verwirft Windows Wiederherstellungspunkte (Ereignis Volsnap 36). Ziel: ShadowStorageTarget der Laufwerksgroesse.'
        Detect = {
            $vols = @{}; Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $vols[$_.DeviceID] = $_ }
            foreach ($s in (Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue)) {
                $v = $vols[$s.Volume.DeviceID]; if (-not $v -or -not $v.Capacity) { continue }
                $pct = 100 * $s.MaxSpace / $v.Capacity
                if ($pct -lt $Script:Cfg.ShadowStorageMinPercent) { New-Item2 ("Laufwerk {0}: nur {1} ({2:N1} %) für Wiederherstellungspunkte" -f $v.DriveLetter, (Fmt-Bytes $s.MaxSpace), $pct) 0 $v.DriveLetter }
            }
        }
        Fix = { param($it) $o = & vssadmin.exe resize shadowstorage /for=$($it.Data) /on=$($it.Data) /maxsize=$($Script:Cfg.ShadowStorageTarget) 2>&1; if ($LASTEXITCODE -ne 0) { throw ($o | Out-String) }; "auf $($Script:Cfg.ShadowStorageTarget) gesetzt" }
    }

    [pscustomobject]@{ Id = 'SYS-TRIM'; Kategorie = 'System'; Titel = 'SSD-TRIM abgeschaltet oder lange nicht gelaufen'; Risiko = 'Niedrig'; Wirkung = 'Leistung'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'TRIM teilt der SSD freie Bloecke mit und haelt die Schreibleistung hoch. Windows macht das woechentlich ueber die Laufwerksoptimierung. Gemeldet wird nur, wenn TRIM abgeschaltet ist (oft durch "Tuning"-Tools) oder die Optimierung seit ueber 14 Tagen nicht lief.'
        Detect = {
            $fs = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
            $dd = (Get-ItemProperty $fs -ErrorAction SilentlyContinue).DisableDeleteNotification
            $ssd = @(Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' })
            if (-not $ssd.Count) { return }
            if ($dd -eq 1) { New-Item2 'TRIM ist in Windows abgeschaltet – die SSD wird mit der Zeit langsamer' 0 'an'; return }
            $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
            $i = if ($t) { $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue } else { $null }
            $alt = (-not $t) -or $t.State -eq 'Disabled' -or -not $i -or -not $i.LastRunTime -or $i.LastRunTime.Year -lt 2000 -or $i.LastRunTime -lt (Get-Date).AddDays(-14)
            if (-not $alt) { return }
            Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' } | ForEach-Object { New-Item2 ("SSD {0}: {1} – TRIM lief seit über 14 Tagen nicht" -f $_.LW, $_.Disk) 0 $_.LW }
        }
        Fix = { param($it)
            if ($it.Data -eq 'an') { Set-RegValueWithUndo 'SYS-TRIM' 'TRIM' 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification' 0 'DWord'; foreach ($v in @(Get-VolumeInfo | Where-Object { $_.Medium -eq 'SSD' -and $_.FS -eq 'NTFS' })) { try { Optimize-Volume -DriveLetter $v.LW -ReTrim -ErrorAction Stop } catch { } }; return 'TRIM eingeschaltet' }
            Optimize-Volume -DriveLetter $it.Data -ReTrim -ErrorAction Stop; 'TRIM ausgefuehrt'
        }
    }

    [pscustomobject]@{ Id = 'SYS-MAINT'; Kategorie = 'System'; Titel = 'Automatische Wartung laeuft nicht durch'; Risiko = 'Niedrig'; Wirkung = 'Leistung/Hygiene'; Admin = $true; Standard = $true
        Warum = 'Laufwerksoptimierung, Systemwiederherstellung u. a. haengen an der automatischen Wartung. Bricht sie dauerhaft ab, veraltet das System schleichend.'
        Detect = {
            $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
            if (-not $t) { return }
            $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            # Abbrueche (0x8007042B) sind normal, wenn man waehrend der Wartung arbeitet - relevant ist nur, wenn sie lange nicht lief
            if ($t.State -eq 'Disabled') { New-Item2 'Die Laufwerkspflege von Windows ist abgeschaltet (Aufgabe ScheduledDefrag deaktiviert)' 0 'aus'; return }
            if (-not $i.LastRunTime -or $i.LastRunTime.Year -lt 2000 -or $i.LastRunTime -lt (Get-Date).AddDays(-14)) { New-Item2 ("Die Laufwerkspflege von Windows lief seit über 14 Tagen nicht{0}" -f $(if ($i.LastRunTime -and $i.LastRunTime.Year -ge 2000) { " (zuletzt {0:dd.MM.yyyy})" -f $i.LastRunTime } else { '' })) 0 $null }
        }
        Fix = { param($it)
            if ($it.Data -eq 'aus') { Backup-Task (Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'); Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null; return 'Laufwerkspflege eingeschaltet' }
            Start-Process "$env:windir\System32\MSchedExe.exe" -ArgumentList 'Start'; 'Wartung gestartet (PC ca. 1 Stunde anlassen)'
        }
    }

    [pscustomobject]@{ Id = 'SYS-INTEGRITY'; Kategorie = 'System'; Titel = 'Systemdateien und Komponentenspeicher pruefen/reparieren'; Risiko = 'Niedrig'; Wirkung = 'Stabilitaet'; Admin = $true; Standard = $true; Dauer = '10–30 Minuten'
        Warum = 'DISM prueft den Komponentenspeicher, SFC die Systemdateien. Mit -Deep wird die Reparatur immer angeboten, sonst nur bei gemeldetem Schaden.'
        Detect = {
            $h = $null; try { $h = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState } catch { }
            if ($h -and "$h" -ne 'Healthy') { New-Item2 "Komponentenspeicher: $h" 0 'dism' }
            if ($Deep -or ($h -and "$h" -ne 'Healthy')) { New-Item2 'SFC /scannow (Systemdateien pruefen und reparieren, ca. 10 Min.)' 0 'sfc' }
        }
        Fix = { param($it)
            if ($it.Data -eq 'dism') { $r = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop; return "Zustand: $($r.ImageHealthState)" }
            $alt = [Console]::OutputEncoding
            try { [Console]::OutputEncoding = [Text.Encoding]::Unicode; $o = & sfc.exe /scannow 2>&1 } finally { [Console]::OutputEncoding = $alt }
            (($o | ForEach-Object { "$_" -replace "`0", '' } | Where-Object { $_ -match '\S' -and $_ -notmatch '%' }) | Select-Object -Last 2) -join ' '
        }
    }

    [pscustomobject]@{ Id = 'SYS-FSCHECK'; Kategorie = 'System'; Titel = 'Dateisystem-Pruefung (online, nur mit -Deep)'; Risiko = 'Info'; Wirkung = 'Stabilitaet'; Admin = $true; Standard = $true
        Warum = 'Prueft NTFS-Volumes im laufenden Betrieb auf Fehler. Bei Befund: chkdsk X: /spotfix bzw. /f beim naechsten Start.'
        Detect = { if (-not $Deep) { return }; foreach ($v in (Get-VolumeInfo | Where-Object FS -eq 'NTFS')) { $r = $null; try { $r = Repair-Volume -DriveLetter $v.LW -Scan -ErrorAction Stop } catch { $r = "Fehler: $($_.Exception.Message)" }; if ("$r" -ne 'NoErrorsFound') { New-Item2 ("{0}: {1}" -f $v.LW, $r) 0 $null } } }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-GAMEDVR'; Kategorie = 'System'; Titel = 'Hintergrundaufnahme (Xbox Game Bar) aktiv'; Risiko = 'Mittel'; Wirkung = 'Leistung'; Admin = $false; Standard = $true; Umkehrbar = $true
        Warum = 'Die Hintergrundaufnahme ("Aufzeichnen, was passiert ist") nimmt in Spielen staendig die letzten Minuten auf und kostet GPU-Leistung. Abgeschaltet wird nur sie; Clips manuell aufnehmen und der Spielmodus bleiben.'
        Detect = {
            $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -ErrorAction SilentlyContinue
            if ($k -and $k.HistoricalCaptureEnabled -eq 1 -and $k.AppCaptureEnabled -ne 0) { New-Item2 'Die Hintergrund-Aufnahme der Xbox Game Bar ist eingeschaltet' 0 $null }
        }
        Fix = { param($it) Set-RegValueWithUndo 'SYS-GAMEDVR' 'Hintergrund-Aufnahme' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0 'DWord'; 'deaktiviert' }
    }

    # ---------------------------------------------------------------- Sicherheit (meist Info)
    [pscustomobject]@{ Id = 'SEC-EXECPOLICY'; Kategorie = 'Sicherheit'; Titel = 'PowerShell-Ausfuehrungsrichtlinie zu offen'; Risiko = 'Mittel'; Wirkung = 'Sicherheit'; Admin = $false; Standard = $true; Umkehrbar = $true
        Warum = '"Unrestricted"/"Bypass" dauerhaft erlaubt jedes heruntergeladene Skript. RemoteSigned laesst lokale Skripte weiter laufen, blockiert aber unsignierte Downloads.'
        Detect = { foreach ($s in 'CurrentUser', 'LocalMachine') { $p = Get-ExecutionPolicy -Scope $s; if ("$p" -in 'Unrestricted', 'Bypass') { New-Item2 $(if ($s -eq 'CurrentUser') { 'Für dein Benutzerkonto ist diese Schutzeinstellung ausgeschaltet' } else { 'Für alle Benutzer ist diese Schutzeinstellung ausgeschaltet' }) 0 $s } } }
        Fix = { param($it) $alt = "$(Get-ExecutionPolicy -Scope $it.Data)"; try { Set-ExecutionPolicy RemoteSigned -Scope $it.Data -Force -ErrorAction Stop } catch { if ($_.Exception.Message -notmatch 'overridden|ueberschrieben|überschrieben') { throw } }; if ("$(Get-ExecutionPolicy -Scope $it.Data)" -ne $alt) { Add-ActionRecord 'SEC-EXECPOLICY' 'Schutzeinstellung fuer Skripte' 'Undo-Info' 0 '' @{ Typ = 'ExecPolicy'; Scope = $it.Data; Vorher = $alt } | Out-Null }; 'RemoteSigned' }
    }

    [pscustomobject]@{ Id = 'SEC-CHECKS'; Kategorie = 'Sicherheit'; Titel = 'Sicherheits-Grundlagen'; Risiko = 'Info'; Wirkung = 'Sicherheit'; Admin = $true; Standard = $true
        Warum = 'Windows-Support und Updates, Secure Boot, Virenschutz, Firewall, UAC, BIOS-Alter. Ein anderer aktiver Virenschutz bzw. eine andere Firewall wird beruecksichtigt.'
        Detect = {
            $wi = Get-WindowsSupportInfo
            if ($wi.Ende -and $wi.Ende -lt (Get-Date)) { New-Item2 ("Diese Windows-Version ({0}) bekommt seit {1:dd.MM.yyyy} keine Sicherheitsupdates mehr – bitte über Einstellungen > Windows Update auf die aktuelle Version aktualisieren" -f $wi.Version, $wi.Ende) 0 @{ Stufe = 'krit' } }
            elseif ($wi.Ende -and $wi.Ende -lt (Get-Date).AddDays(60)) { New-Item2 ("Diese Windows-Version ({0}) bekommt nur noch bis {1:dd.MM.yyyy} Sicherheitsupdates – bald auf die aktuelle Version aktualisieren" -f $wi.Version, $wi.Ende) 0 @{ Stufe = 'warn' } }
            if ($wi.WuDeaktiviert) { New-Item2 'Windows Update ist abgeschaltet – der PC bekommt keine Sicherheitsupdates' 0 @{ Stufe = 'krit' } }
            elseif ($null -ne $wi.TageSeitUpdate -and $wi.TageSeitUpdate -gt 40) { New-Item2 ("Seit {0} Tagen wurden keine Windows-Updates installiert – Einstellungen > Windows Update prüfen" -f $wi.TageSeitUpdate) 0 @{ Stufe = 'warn' } }
            $fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction SilentlyContinue).PEFirmwareType
            $sb = $null; try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
            if ($fw -eq 1) { New-Item2 'Windows startet im alten BIOS-Modus (Legacy) – Secure Boot (Startschutz) ist so nicht möglich. Eine Umstellung sollte nur jemand machen, der sich auskennt' 0 @{ Stufe = '' } }
            elseif ($sb -eq $false) { New-Item2 'Secure Boot (Startschutz) ist ausgeschaltet. Das ist kein akutes Problem. Einschalten sollte es nur jemand, der sich auskennt – falsch gemacht, startet Windows nicht mehr' 0 @{ Stufe = '' } }
            elseif ($sb -eq $true) {
                $ca = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue).UEFICA2023Status
                if ($ca -and [string]$ca -ne 'Updated') { New-Item2 'Die neuen Secure-Boot-Zertifikate (2023) sind noch nicht installiert. Windows erledigt das über Updates; manchmal ist dafür ein BIOS-Update nötig' 0 @{ Stufe = '' } }
            }
            $avFremd = @(Get-OtherSecurityProducts 'AntiVirusProduct')
            if (-not $avFremd.Count) {
                try {
                    $m = Get-MpComputerStatus -ErrorAction Stop
                    if (-not $m.RealTimeProtectionEnabled) { New-Item2 'Der Virenschutz (Microsoft Defender) ist ausgeschaltet und kein anderer Virenschutz ist aktiv' 0 @{ Stufe = 'krit' } }
                    elseif ($m.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-7)) { New-Item2 ("Die Virenschutz-Signaturen sind älter als 7 Tage (Stand {0:dd.MM.yyyy})" -f $m.AntivirusSignatureLastUpdated) 0 @{ Stufe = 'warn' } }
                } catch { }
            }
            if (-not @(Get-OtherSecurityProducts 'FirewallProduct').Count) {
                $pn = @{ 'Domain' = 'Firmennetzwerke'; 'Private' = 'private Netzwerke'; 'Public' = 'öffentliche Netzwerke' }
                try { Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { New-Item2 ("Die Windows-Firewall ist für {0} ausgeschaltet. Einschalten unter Einstellungen > Datenschutz und Sicherheit > Windows-Sicherheit > Firewall" -f $(if ($pn.ContainsKey([string]$_.Name)) { $pn[[string]$_.Name] } else { $_.Name })) 0 @{ Stufe = 'warn' } } } catch { }
            }
            if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA -eq 0) { New-Item2 'Die Benutzerkontensteuerung (Nachfrage bei Änderungen am System) ist ausgeschaltet' 0 @{ Stufe = 'warn' } }
            $b = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            if ($b.ReleaseDate -and $b.ReleaseDate -lt (Get-Date).AddYears(-2)) { New-Item2 ("Die Grundsoftware des Mainboards (BIOS) ist vom {0:dd.MM.yyyy}. Ein Update kann Fehler und Sicherheitslücken beheben – bitte nur von jemandem durchführen lassen, der sich auskennt" -f $b.ReleaseDate) 0 @{ Stufe = '' } }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'SYS-TWEAKS'; Kategorie = 'System'; Titel = 'Unguenstige Tuning-Einstellungen'; Risiko = 'Info'; Wirkung = 'Leistung/Sicherheit'; Admin = $true; Standard = $true
        Warum = 'Manche Tuning-Programme und -Anleitungen schalten Windows-Funktionen ab, die den PC eigentlich schneller oder sicherer machen: Auslagerungsdatei, Prefetch, SysMain, Defender per Richtlinie.'
        Detect = {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and -not $cs.AutomaticManagedPagefile -and -not @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue).Count) { New-Item2 'Die Auslagerungsdatei ist abgeschaltet – das führt bei vollem Arbeitsspeicher zu Abstürzen. Empfohlen: "Größe automatisch verwalten" (Systemeigenschaften > Erweitert > Leistung)' 0 @{ Stufe = 'warn' } }
            $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -ErrorAction SilentlyContinue).EnablePrefetcher
            if ($pf -eq 0) { New-Item2 'Prefetch ist abgeschaltet – Windows und Programme starten dadurch langsamer' 0 @{ Stufe = 'warn' } }
            $sm = Get-CimInstance Win32_Service -Filter "Name='SysMain'" -ErrorAction SilentlyContinue
            if ($sm -and $sm.StartMode -eq 'Disabled') { New-Item2 'Der Dienst SysMain (Programme schneller laden) ist abgeschaltet' 0 @{ Stufe = 'warn' } }
            $dp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -ErrorAction SilentlyContinue
            $rp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -ErrorAction SilentlyContinue
            if (($dp.DisableAntiSpyware -eq 1 -or $rp.DisableRealtimeMonitoring -eq 1) -and -not @(Get-OtherSecurityProducts 'AntiVirusProduct').Count) { New-Item2 'Der Virenschutz wurde per Richtlinie abgeschaltet (oft durch Tuning-Programme) und kein anderer Virenschutz ist aktiv' 0 @{ Stufe = 'krit' } }
        }
        Fix = $null
    }

    # ---------------------------------------------------------------- Hardware-Hinweise (Info)
    [pscustomobject]@{ Id = 'HW-HINTS'; Kategorie = 'Hardware'; Titel = 'Hardware- und Konfigurationshinweise'; Risiko = 'Info'; Wirkung = 'Leistung'; Admin = $false; Standard = $true
        Warum = 'Die groessten Hebel liegen oft in der Hardware-Konfiguration: Systemplatte, Arbeitsspeicher, Grafikkarte, Energieplan, Netzwerk und Geraetetreiber.'
        Detect = {
            $ch = Get-ChassisInfo
            $vols = Get-VolumeInfo; $sys = $vols | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) }
            if ($sys) {
                if ($sys.Medium -eq 'HDD') { New-Item2 'Windows liegt auf einer Festplatte (HDD) – eine SSD ist die größte einzelne Verbesserung' 0 @{ Stufe = 'warn' } }
                $nvme = $vols | Where-Object { $_.Bus -eq 'NVMe' -and $_.LW -ne $sys.LW -and $_.FreiProzent -gt 60 }
                if ($sys.Bus -ne 'NVMe' -and $nvme) { New-Item2 ("Windows liegt auf {0} ({1}), aber Laufwerk {2}: ist eine kaum genutzte, schnellere NVMe-SSD ({3} GB frei) – ein Umzug von Windows dorthin bringt deutlich schnellere Starts" -f $sys.Disk, $sys.Bus, $nvme[0].LW, $nvme[0].FreiGB) 0 @{ Stufe = '' } }
                elseif ($sys.Medium -eq 'SSD') {
                    $big = $vols | Where-Object { $_.Medium -eq 'SSD' -and $_.LW -ne $sys.LW -and $_.FreiProzent -gt 60 -and $_.GroesseGB -ge 2 * $sys.GroesseGB } | Select-Object -First 1
                    if ($big) { New-Item2 ("Windows liegt auf {0} ({1} GB), während Laufwerk {2}: ({3}, {4} GB) zu {5} % leer ist – prüfen, ob diese SSD schneller ist (z. B. NVMe), und Windows bzw. Spiele dorthin umziehen" -f $sys.Disk, $sys.GroesseGB, $big.LW, $big.Disk, $big.GroesseGB, $big.FreiProzent) 0 @{ Stufe = '' } }
                }
                if ($sys.FreiProzent -lt 15) { New-Item2 ("Auf dem Windows-Laufwerk sind nur {0} % frei – unter 15 % wird der PC langsamer" -f $sys.FreiProzent) 0 @{ Stufe = 'warn' } }
            }
            # Arbeitsspeicher
            $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Where-Object { $_.Capacity -gt 0 })
            if (-not $ch.Laptop -and -not $ch.VM -and $mem.Count -eq 1) { New-Item2 ('Nur ein Speicherriegel eingebaut ({0:N0} GB) – zwei gleiche Riegel arbeiten zusammen (Dual-Channel) und sind spürbar schneller, vor allem bei Spielen und mit Grafik im Prozessor' -f ($mem[0].Capacity / 1GB)) 0 @{ Stufe = 'warn' } }
            if (-not $ch.Laptop) { foreach ($m in $mem) { if ($m.ConfiguredClockSpeed -and $m.Speed -and $m.ConfiguredClockSpeed -lt $m.Speed) { New-Item2 ("Arbeitsspeicher läuft mit {0} statt {1} MT/s. Falls die Riegel ein XMP/EXPO-Profil haben, lässt es sich im BIOS einschalten (Herstellerangabe prüfen)" -f $m.ConfiguredClockSpeed, $m.Speed) 0 @{ Stufe = '' }; break } } }
            # Grafik: Treiber fehlt, Monitor am Mainboard
            $vc = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
            if (-not $ch.VM -and ($vc | Where-Object { $_.Name -match 'Basic Display|Standard-VGA|Microsoft Basic' -or $_.InfFilename -eq 'display.inf' })) { New-Item2 'Für die Grafik ist kein richtiger Treiber installiert (Microsoft-Standardtreiber) – Treiber vom Hersteller der Grafikkarte installieren' 0 @{ Stufe = 'krit' } }
            $dgpu = @($vc | Where-Object { $_.Name -match '(?i)NVIDIA|Radeon RX|Radeon Pro|Arc A|Arc B' })
            if (-not $ch.Laptop -and $dgpu.Count -and -not ($dgpu | Where-Object { $_.CurrentHorizontalResolution }) -and ($vc | Where-Object { $_.CurrentHorizontalResolution })) { New-Item2 ("Der Bildschirm hängt am Mainboard statt an der Grafikkarte ({0}) – das Kabel in einen Anschluss der Grafikkarte stecken, sonst bleibt ihre Leistung ungenutzt" -f $dgpu[0].Name) 0 @{ Stufe = 'warn' } }
            # Geraete mit Fehlercode (22 = vom Benutzer deaktiviert, 45 = nicht angeschlossen)
            $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -notin 22, 45 -and $_.Name })
            foreach ($d in ($bad | Select-Object -First 5)) { New-Item2 ("Gerät {0} funktioniert nicht richtig (Code {1}) – im Geräte-Manager prüfen, meist hilft der Treiber vom Hersteller" -f $d.Name, $d.ConfigManagerErrorCode) 0 @{ Stufe = 'warn' } }
            # Energieplan
            $pmax = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidProcMax
            $pmin = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidProcMin
            $boost = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidBoostMode
            if ($pmax -and $null -ne $pmax.AC -and $pmax.AC -lt 100) { New-Item2 ("Der Energieplan begrenzt den Prozessor im Netzbetrieb auf {0} % – er arbeitet dadurch nie mit voller Leistung (oft ein alter Tipp gegen Wärme). Systemsteuerung > Energieoptionen > Prozessorenergieverwaltung" -f $pmax.AC) 0 @{ Stufe = 'warn' } }
            if ($boost -and $boost.AC -eq 0) { New-Item2 'Der Turbo des Prozessors ist im Energieplan abgeschaltet – er arbeitet dadurch deutlich langsamer' 0 @{ Stufe = 'warn' } }
            if ($pmin -and $pmin.AC -eq 100 -and $pmin.Schema -eq '381b4222-f694-41f0-9685-ff5bb260df2e') { New-Item2 'Im Energieplan "Ausbalanciert" taktet der Prozessor nie herunter (Minimum 100 %) – wärmer und lauter ohne spürbaren Vorteil' 0 @{ Stufe = '' } }
            $plan = (& powercfg.exe /getactivescheme 2>$null) -join ' '
            if ($plan -and $plan -notmatch '381b4222-f694-41f0-9685-ff5bb260df2e|8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|a1841308-3541-4fab-bc81-f71556f20b4a|e9a42b02-d5df-448d-aa00-03f14749eb61') { New-Item2 ("Ein eigener Energieplan ist aktiv: {0}" -f ($plan -replace '^.*\(|\).*$', '')) 0 @{ Stufe = '' } }
            # Intel 13./14. Generation (Desktop): Microcode-Stand gegen Instabilitaet (Vmin Shift)
            if ($ch.CpuName -match '(?i)i[579]-1[34]\d{3}(K|KF|KS|F|T)?\b' -and $ch.CpuName -notmatch '(?i)\d{4,5}(H|HX|U|P)\b') {
                $rev = $null; try { $b = [byte[]](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'Update Revision'; if ($b.Count -ge 8) { $rev = [BitConverter]::ToUInt32($b, 4) } } catch { }
                if ($rev -and $rev -lt 0x1000 -and $rev -lt 0x12F) { New-Item2 ("Prozessor der Intel-Generation 13/14 mit altem Microcode (0x{0:X}) – Intel empfiehlt ein BIOS-Update (mindestens 0x12F) und das Profil 'Intel Default Settings', um bleibende Schäden zu vermeiden" -f $rev) 0 @{ Stufe = 'warn' } }
            }
            # Netzwerk
            try {
                $ad = @(Get-NetAdapter -ErrorAction Stop)
                $lan = @($ad | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|TAP|Loopback|WireGuard' })
                foreach ($l in $lan) { if ([int64]$l.Speed -gt 0 -and [int64]$l.Speed -le 100000000) { New-Item2 ("Die Netzwerkkabel-Verbindung ({0}) läuft nur mit 100 Mbit/s – meist liegt es an einem alten oder beschädigten Kabel oder Anschluss" -f $l.InterfaceDescription) 0 @{ Stufe = 'warn' } } }
                $wifi = $ad | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.11|Native 802' }
                $eth = $ad | Where-Object { $_.Status -ne 'Up' -and $_.PhysicalMediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|TAP|Loopback' }
                if ($wifi -and $eth -and -not $lan.Count -and -not $ch.Laptop) { New-Item2 ("Der PC ist per WLAN verbunden ({0}), hat aber einen Netzwerkkabel-Anschluss – falls ein Kabel möglich ist: schneller und stabiler" -f $wifi[0].LinkSpeed) 0 @{ Stufe = '' } }
            } catch { }
            $raidSvc = Get-CimInstance Win32_SystemDriver -Filter "Name='rcraid' OR Name='iaStorAVC' OR Name='iaStorAC'" -ErrorAction SilentlyContinue | Where-Object State -eq 'Running'
            if ($raidSvc -and -not (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'RAID|Array' })) { New-Item2 ("RAID-Treiber aktiv ({0}), aber kein RAID-Verbund erkennbar – im BIOS ist evtl. RAID statt AHCI/NVMe eingestellt. Umstellen nur mit Vorbereitung, sonst startet Windows nicht" -f ($raidSvc.Name -join ', ')) 0 @{ Stufe = '' } }
            # Schnellstart: "Herunterfahren" startet Windows nicht wirklich neu
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
            if ($os -and $hb -eq 1 -and $os.LastBootUpTime -lt (Get-Date).AddDays(-7)) { New-Item2 ("Windows wurde seit {0:N0} Tagen nicht neu gestartet (der Schnellstart macht aus 'Herunterfahren' keinen echten Neustart). Nach Updates und Treibern deshalb 'Neu starten' wählen" -f ((Get-Date) - $os.LastBootUpTime).TotalDays) 0 @{ Stufe = '' } }
        }
        Fix = $null
    }

    # ---------------------------------------------------------------- Kuehlung und Temperaturen (Info)
    [pscustomobject]@{ Id = 'HW-COOLING'; Kategorie = 'Hardware'; Titel = 'Kuehlung, Luefter und Temperaturen'; Risiko = 'Info'; Wirkung = 'Stabilitaet/Lebensdauer'; Admin = $false; Standard = $true
        Warum = 'Zu heisse Bauteile werden gebremst und altern schneller; stehende oder dauerhaft volle Luefter deuten auf einen Defekt oder eine unpassende Luefterkurve im BIOS hin. Windows kann Luefterkurven weder lesen noch einstellen - WinTidy misst deshalb die Auswirkungen (Temperaturen, Drosselung, Luefterdrehzahl) und bietet einen kurzen Kuehlungstest an.'
        Detect = {
            foreach ($p in (Get-HardwarePoints)) { New-Item2 $p.Text 0 @{ Stufe = $p.Stufe; Bereich = $p.Bereich; Wertung = $p.Wertung } }
            $lt = Get-LastCoolingTest
            if ($lt -and $lt.Zeit) {
                $z = [datetime]$lt.Zeit
                if ($z -gt (Get-Date).AddDays(-60)) {
                    $pt = @($lt.Punkte | Where-Object { $_.Stufe -eq 'krit' }) + @($lt.Punkte | Where-Object { $_.Stufe -eq 'warn' }) + @($lt.Punkte | Where-Object { $_.Stufe -eq 'ok' })
                    if ($pt.Count) { New-Item2 ('Letzter Kühlungstest ({0:dd.MM.yyyy}{1}): {2}' -f $z, $(if ($lt.Status -eq 'GESTOPPT') { ', vorzeitig beendet' } else { '' }), $pt[0].Text) 0 @{ Stufe = $pt[0].Stufe; Bereich = 'Test' } }
                }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'HW-COOLPOLICY'; Kategorie = 'Hardware'; Titel = 'Kuehlrichtlinie im Netzbetrieb auf "Aktiv" stellen'; Risiko = 'Mittel'; Wirkung = 'Leistung/Temperatur'; Admin = $true; Standard = $true; Umkehrbar = $true
        Warum = 'Mit der Richtlinie "Passiv" bremst Windows zuerst den Prozessor, bevor die Luefter hochdrehen. Im Netzbetrieb ist "Aktiv" (erst Luefter, dann bremsen) der Windows-Standard. Wirkt nur bei Geraeten, deren Firmware Windows an der Kuehlung beteiligt (ACPI-Thermalzonen). Rueckgaengig ueber "Wiederherstellen".'
        Detect = {
            # Nur sinnvoll, wenn die Firmware ACPI-Aktivkuehlung anbietet (Luefterstufen ueber Windows). Desktops und
            # die meisten aktuellen Laptops steuern Luefter selbst - dort haette die Einstellung keine Wirkung.
            $aktiv = @(); try { $aktiv = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Where-Object { $_.ActiveTripPointCount -gt 0 }) } catch { }
            if (-not $aktiv.Count) { return }
            $ps = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidSysCoolPol
            if (-not $ps -or $ps.AC -ne 0) { return }
            New-Item2 'Energieplan: Im Netzbetrieb bremst Windows den Prozessor, bevor die Lüfter hochdrehen (Kühlrichtlinie "Passiv")' 0 @{ Schema = $ps.Schema; AC = $ps.AC }
        }
        Fix = { param($it)
            $null = & powercfg.exe /setacvalueindex $it.Data.Schema $Script:GuidSubProcessor $Script:GuidSysCoolPol 1 2>&1
            if ($LASTEXITCODE -ne 0) { throw "powercfg meldet Fehler $LASTEXITCODE" }
            $akt = Get-PowerSettingIndex $Script:GuidSubProcessor $Script:GuidSysCoolPol
            if ($akt -and $akt.Schema -eq $it.Data.Schema) { $null = & powercfg.exe /setactive $it.Data.Schema 2>&1 }
            Add-ActionRecord 'HW-COOLPOLICY' 'Kuehlrichtlinie (Netzbetrieb)' 'Undo-Info' 0 '' @{ Typ = 'PowerSetting'; Schema = $it.Data.Schema; Sub = $Script:GuidSubProcessor; Setting = $Script:GuidSysCoolPol; AC = $it.Data.AC } | Out-Null
            'auf Aktiv gestellt'
        }
    }

    [pscustomobject]@{ Id = 'HW-DISPLAY'; Kategorie = 'Hardware'; Titel = 'Bildwiederholrate des Bildschirms'; Risiko = 'Info'; Wirkung = 'Bildqualitaet'; Admin = $false; Standard = $true
        Warum = 'Schnelle Monitore laufen nach dem Anschliessen oft nur mit 60 Hz, weil die hoehere Rate in Windows nie ausgewaehlt wurde. Verglichen wird mit dem, was der Monitor selbst meldet (EDID).'
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
                $txt = 'Bildschirm: {0} × {1} bei {2} Hz' -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $cur
                # Nur bei genau einem Monitor eindeutig zuordenbar
                if ($vc.Count -eq 1 -and $mons.Count -eq 1) {
                    $max = ($modes | Where-Object { $_.W -eq [int]$v.CurrentHorizontalResolution -and $_.H -eq [int]$v.CurrentVerticalResolution } | Measure-Object Hz -Maximum).Maximum
                    if ($max -and [math]::Floor($max) -ge $cur + 5) { New-Item2 ("{0} – der Monitor kann bis zu {1:N0} Hz. Einstellen unter Einstellungen > System > Anzeige > Erweiterte Anzeige > Aktualisierungsrate" -f $txt, [math]::Floor($max)) 0 @{ Stufe = $(if ((Get-ChassisInfo).Laptop) { '' } else { 'warn' }); Bereich = 'Bildschirm' }; continue }
                }
                New-Item2 $txt 0 @{ Stufe = 'ok'; Bereich = 'Bildschirm' }
            }
        }
        Fix = $null
    }

    [pscustomobject]@{ Id = 'EVT-HEALTH'; Kategorie = 'Stabilitaet'; Titel = 'Auffaelligkeiten im Ereignisprotokoll (30 Tage)'; Risiko = 'Info'; Wirkung = 'Stabilitaet'; Admin = $false; Standard = $true
        Warum = 'Unerwartete Abschaltungen, Bluescreens, Hardwarefehler (WHEA), Datentraegerfehler und GPU-Treiber-Resets sind Warnsignale.'
        Detect = {     foreach ($w in (Get-WarningSignals)) { New-Item2 ("{0}: {1}-mal" -f $w.Text, $w.Anzahl) 0 @{ Stufe = 'warn' } } }
        Fix = $null
    }
)

function Get-SelectedRules([switch]$ForApply) {
    $r = $Script:Rules
    if ($Rule) { $r = $r | Where-Object { $Rule -contains $_.Id } }
    else { $r = $r | Where-Object { $_.Standard } }
    if ($ExcludeRule) { $r = $r | Where-Object { $ExcludeRule -notcontains $_.Id } }
    # Firmen-PC: nur sichere Aufraeumregeln und Hinweise (wie in der App)
    if ($Script:CliContext) { $ctx = $Script:CliContext; $r = $r | Where-Object { Test-RuleAllowed $_ $ctx } }
    return @($r)
}

# =============================================================================
#  Snapshot (Messung) und Score
# =============================================================================
function Get-IdleSample {
    $cpu = @(); for ($i = 0; $i -lt 5; $i++) { try { $cpu += (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch { }; Start-Sleep -Milliseconds 800 }
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        CpuProzent = $(if ($cpu.Count) { [math]::Round(($cpu | Measure-Object -Average).Average, 1) } else { $null })
        RamBelegtProzent = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1)
        RamBelegtGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        Prozesse = (Get-Process).Count
        Threads = ((Get-Process | ForEach-Object { $_.Threads.Count }) | Measure-Object -Sum).Sum
        Handles = ((Get-Process | Measure-Object HandleCount -Sum).Sum)
    }
}

function New-Snapshot([string]$Label = 'scan', [object[]]$Findings) {
    W "  Messe System (Snapshot '$Label') ..." 'DarkGray'
    $os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
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
    $idle = Get-IdleSample
    $rbSize = 0; try { $rbSize = ((New-Object -ComObject Shell.Application).Namespace(10).Items() | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum } catch { }
    $secBoot = $null; try { $secBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
    $def = $null; try { $def = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { }
    # Anderer aktiver Virenschutz (Security Center, nur Client-Windows): dann ist ein abgeschalteter Defender normal
    $av = [bool](@(Get-OtherSecurityProducts 'AntiVirusProduct').Count)
    $wsi = $null; try { $wsi = Get-WindowsSupportInfo } catch { }
    $hw = $null; try { $hw = Get-HardwareSnapshot } catch { W "  Hardware-Messung fehlgeschlagen: $($_.Exception.Message)" 'DarkYellow' }
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
        Speicher = [ordered]@{ PapierkorbBytes = [int64]$rbSize; TempBytes = (Get-DirSize $env:TEMP); CrashDumpsBytes = (Get-DirSize (Join-Path $env:LOCALAPPDATA 'CrashDumps')) }
        Sicherheit = [ordered]@{ SecureBoot = $secBoot; DefenderEchtzeit = $def; AndererVirenschutz = $av; AusfuehrungsrichtlinieCU = "$(Get-ExecutionPolicy -Scope CurrentUser)"; WindowsSupportEnde = $(if ($wsi -and $wsi.Ende) { $wsi.Ende.ToString('yyyy-MM-dd') } else { $null }); TageSeitUpdate = $(if ($wsi) { $wsi.TageSeitUpdate } else { $null }); WindowsUpdateAus = $(if ($wsi) { $wsi.WuDeaktiviert } else { $null }) }
        Hardware = $hw
        Stabilitaet = [ordered]@{ Warnsignale = $warn }
        Befunde = @()
    }
    if ($Findings) { $snap.Befunde = @($Findings | ForEach-Object { [ordered]@{ Regel = $_.Regel; Kategorie = $_.Kategorie; Titel = $_.Titel; Risiko = $_.Risiko; Anzahl = $_.Anzahl; Bytes = $_.Bytes; Objekte = @($_.Objekte | Select-Object -First 50); Stufen = @($_.Stufen | Select-Object -First 50); Bereiche = @($_.Bereiche | Select-Object -First 50); Wertungen = @($_.Wertungen | Select-Object -First 50) } }) }
    $snap.Score = Get-HealthScore $snap
    $f = Join-Path $Script:SnapDir ("{0}_{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Label)
    $snap | ConvertTo-Json -Depth 7 | Out-File $f -Encoding utf8
    W "  Snapshot gespeichert: $f" 'DarkGray'
    return [pscustomobject]$snap
}

function Get-HealthScore($s) {
    $abz = New-Object System.Collections.Generic.List[object]
    function Abzug($p, $t) { $abz.Add([pscustomobject]@{ Punkte = $p; Grund = $t }) }
    $sys = $s.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    if ($sys) {
        # Prozent allein taugt nicht: auf 2 TB sind 15 % frei (300 GB) unkritisch
        $fg = [double]$sys.FreiGB; $fp = [double]$sys.FreiProzent
        if ($fg -lt 10 -or ($fp -lt 10 -and $fg -lt 20)) { Abzug 20 ("Auf dem Windows-Laufwerk sind nur {0:N0} GB frei" -f $fg) }
        elseif ($fp -lt 15 -and $fg -lt 50) { Abzug 8 ("Auf dem Windows-Laufwerk sind nur {0:N0} GB frei" -f $fg) }
    }
    $b = $s.Boot.Mittel5; if ($b) { $t = "Windows braucht im Schnitt {0:N0} Sekunden zum Starten" -f ($b / 1000); if ($b -gt 90000) { Abzug 15 $t } elseif ($b -gt 60000) { Abzug 10 $t } elseif ($b -gt 40000) { Abzug 5 $t } }
    $a = $s.Autostart.Aktiv; if ($a -gt 15) { Abzug 10 "$a Programme starten automatisch mit" } elseif ($a -gt 10) { Abzug 5 "$a Programme starten automatisch mit" }
    if ($s.Autostart.Verwaist -gt 0) { Abzug ([math]::Min(5, $s.Autostart.Verwaist)) "$($s.Autostart.Verwaist) kaputte Autostart-Einträge" }
    $e = $s.Ereignisse.FehlerSystem7T + $s.Ereignisse.FehlerAnwendung7T; if ($e -gt 200) { Abzug 5 "Viele Fehlermeldungen von Windows in den letzten 7 Tagen ($e)" } elseif ($e -gt 50) { Abzug 3 "Viele Fehlermeldungen von Windows in den letzten 7 Tagen ($e)" }
    if ($s.Treiber.Duplikate -gt 10) { Abzug 3 "$($s.Treiber.Duplikate) alte Treiber-Versionen" }
    if ($s.Treiber.Geistergeraete -gt 50) { Abzug 2 "$($s.Treiber.Geistergeraete) alte Geräte-Einträge" }
    if ($s.Sicherheit.SecureBoot -eq $false) { Abzug 8 'Secure Boot (Startschutz) ist aus' }
    if ($s.Sicherheit.DefenderEchtzeit -eq $false -and -not $s.Sicherheit.AndererVirenschutz) { Abzug 15 'Kein aktiver Virenschutz' }
    if ($s.Sicherheit.AusfuehrungsrichtlinieCU -in 'Unrestricted', 'Bypass') { Abzug 3 'Schutzeinstellung für Skripte ist ausgeschaltet' }
    if ($s.Sicherheit.WindowsSupportEnde) { try { if ([datetime]::ParseExact([string]$s.Sicherheit.WindowsSupportEnde, 'yyyy-MM-dd', $null) -lt [datetime]$s.Zeit) { Abzug 20 'Diese Windows-Version bekommt keine Sicherheitsupdates mehr' } } catch { } }
    if ($s.Sicherheit.WindowsUpdateAus) { Abzug 15 'Windows Update ist abgeschaltet' }
    elseif ($s.Sicherheit.TageSeitUpdate -gt 40) { Abzug 10 "Seit $($s.Sicherheit.TageSeitUpdate) Tagen keine Windows-Updates installiert" }
    if ($s.Speicher.PapierkorbBytes -gt 5GB) { Abzug 2 'Papierkorb größer als 5 GB' }
    # Warnsignale: neue Snapshots messen sie selbst (vergleichbar vorher/nachher), alte nur ueber die Befunde
    $nWarn = 0
    if ($null -ne $s.Stabilitaet) { $nWarn = @($s.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }
    else { foreach ($bf in @($s.Befunde)) { if ($bf.Regel -eq 'EVT-HEALTH') { $nWarn += [int]$bf.Anzahl } } }
    if ($nWarn -gt 0) { Abzug ([math]::Min(10, 2 * $nWarn)) 'Warnmeldungen von Windows (z. B. Abstürze) in den letzten 30 Tagen' }
    if ($s.Hardware) {
        # Nur Dauerzustaende (Laufwerk, Akku, Speicherfehler ...), keine Momentaufnahmen wie die aktuelle Temperatur
        $hp = @($s.Hardware.Punkte | Where-Object { $_ -and $_.Wertung -ne 'moment' })
        $nk = @($hp | Where-Object { $_.Stufe -eq 'krit' }).Count; $nw = @($hp | Where-Object { $_.Stufe -eq 'warn' }).Count
        if ($nk) { Abzug ([math]::Min(10, 5 * $nk)) 'Hardware: wichtige Warnungen (Laufwerke, Speicher, Kühlung, Akku)' }
        if ($nw) { Abzug ([math]::Min(3, $nw)) 'Hardware: Auffälligkeiten (Laufwerke, Lüfter, Grafikkarte)' }
    }
    $sum = ($abz | Measure-Object Punkte -Sum).Sum; if (-not $sum) { $sum = 0 }
    [ordered]@{ Wert = [int][math]::Max(0, 100 - $sum); Abzuege = $abz.ToArray() }
}

# =============================================================================
#  Regeln ausfuehren
# =============================================================================
function Invoke-Rules([bool]$Apply) {
    $Script:Preview = -not $Apply
    $rules = Get-SelectedRules -ForApply:$Apply
    # Hardware zuerst messen, solange der PC noch ruht (DISM, winget usw. heizen die CPU auf)
    try { $null = Get-HardwarePoints } catch { }
    $findings = New-Object System.Collections.Generic.List[object]
    $total = 0; $done = 0; $failed = 0; $skipped = 0; $bytes = 0
    $i = 0
    foreach ($r in $rules) {
        $i++
        Sub ("[{0}/{1}] {2}  {3}  (Risiko: {4})" -f $i, $rules.Count, $r.Id, $r.Titel, $r.Risiko)
        if ($r.Admin -and -not $Script:IsAdmin) { W '    uebersprungen: braucht Adminrechte' 'DarkYellow'; continue }
        $items = @()
        try { $items = @(& $r.Detect | Where-Object { $_ }) } catch { W "    Fehler bei der Pruefung: $($_.Exception.Message)" 'Red'; continue }
        if (-not $items.Count) { W '    ok - nichts gefunden' 'Green'; continue }
        $sum = ($items | Measure-Object Bytes -Sum).Sum
        $findings.Add([pscustomobject]@{ Regel = $r.Id; Kategorie = $r.Kategorie; Titel = $r.Titel; Risiko = $r.Risiko; Anzahl = $items.Count; Bytes = [int64]$sum; Objekte = @($items | ForEach-Object { $_.Label }); Stufen = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary] -and $_.Data.Stufe) { [string]$_.Data.Stufe } else { '' } }); Bereiche = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary]) { [string]$_.Data.Bereich } else { '' } }); Wertungen = @($items | ForEach-Object { if ($_.Data -is [System.Collections.IDictionary]) { [string]$_.Data.Wertung } else { '' } }) })
        W ("    {0} Befund(e){1}" -f $items.Count, $(if ($sum) { ', ca. ' + (Fmt-Bytes $sum) } else { '' })) 'Yellow'
        W "    Warum: $($r.Warum)" 'DarkGray'
        foreach ($it in $items) { W ("      - {0}{1}" -f $it.Label, $(if ($it.Bytes) { "  [$(Fmt-Bytes $it.Bytes)]" } else { '' })) 'Gray' }
        if (-not $Apply -or -not $r.Fix) { continue }
        # Unbeaufsichtigt nur, was die Regel selbst freigibt (AutoOk), z. B. Windows.old erst nach der Wartezeit
        if ($Yes) { $items = @($items | Where-Object { -not $_.PSObject.Properties['AutoOk'] -or $_.AutoOk }) }
        $Script:AllYes = $false
        try {
            if ($r.Risiko -eq 'Niedrig' -and -not $Yes) { if (-not (Confirm-Item ("Regel {0} fuer alle {1} Objekte ausfuehren?" -f $r.Id, $items.Count) 'Niedrig')) { $skipped += $items.Count; foreach ($it in $items) { Add-ActionRecord $r.Id $it.Label 'Uebersprungen' | Out-Null }; continue }; $Script:AllYes = $true }
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
                    if ($em -like 'SKIP:*') { $skipped++; W ("      uebersprungen  {0}: {1}" -f $it.Label, $em.Substring(5)) 'DarkYellow'; Add-ActionRecord $r.Id $it.Label 'Uebersprungen' 0 $em.Substring(5) | Out-Null; continue }
                    $failed++
                    W ("      FEHLER  {0}: {1}" -f $it.Label, $em) 'Red'
                    Add-ActionRecord $r.Id $it.Label 'Fehler' 0 $em | Out-Null
                }
            }
        } catch {
            if ($_.Exception.Message -eq 'SKIPRULE') { W '    Regel uebersprungen' 'DarkYellow'; Add-ActionRecord $r.Id '(Regel)' 'Uebersprungen' | Out-Null } else { throw }
        }
    }
    return [pscustomobject]@{ Befunde = $findings.ToArray(); Aktionen = $total; OK = $done; Fehler = $failed; Uebersprungen = $skipped; Bytes = $bytes }
}

# Legt einen Wiederherstellungspunkt an. Gibt $null (Erfolg) oder die Fehlermeldung zurueck.
# Enable-ComputerRestore nur im Notfall: es setzt das Speicherlimit fuer Schattenkopien auf den Standard zurueck.
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
    W '  Lege Wiederherstellungspunkt an ...' 'DarkGray'
    $err = Invoke-Checkpoint
    if (-not $err) { W '  Wiederherstellungspunkt angelegt.' 'Green'; Add-ActionRecord 'CORE' 'Wiederherstellungspunkt' 'OK' | Out-Null; return }
    W "  Wiederherstellungspunkt fehlgeschlagen: $err" 'Red'
    Add-ActionRecord 'CORE' 'Wiederherstellungspunkt' 'Fehler' 0 $err | Out-Null
    if (-not $Yes) { $a = Read-Host '  Trotzdem fortfahren? [j/N]'; if ($a -notmatch '^(j|ja|y)$') { throw 'Abbruch durch Benutzer' } } else { throw 'Kein Wiederherstellungspunkt - Abbruch (mit -NoRestorePoint erzwingbar)' }
}

# =============================================================================
#  Vergleich
# =============================================================================
function Get-Snapshots { @(Get-ChildItem $Script:SnapDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name) }
function Read-Snapshot($f) { Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-CompareMetrics($a, $b) {
    function M($name, $va, $vb, $unit, $better) {
        $d = $null; if ($null -ne $va -and $null -ne $vb) { $d = [math]::Round([double]$vb - [double]$va, 2) }
        $verdict = '='; if ($d) { if (($better -eq 'lower' -and $d -lt 0) -or ($better -eq 'higher' -and $d -gt 0)) { $verdict = 'besser' } else { $verdict = 'schlechter' } }
        [pscustomobject]@{ Kennzahl = $name; Vorher = $va; Nachher = $vb; Delta = $d; Einheit = $unit; Bewertung = $verdict }
    }
    $sysA = $a.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    $sysB = $b.Laufwerke | Where-Object { $_.LW -eq $env:SystemDrive.Substring(0, 1) } | Select-Object -First 1
    $freeA = ($a.Laufwerke | Measure-Object FreiGB -Sum).Sum; $freeB = ($b.Laufwerke | Measure-Object FreiGB -Sum).Sum
    @(
        (M 'Health-Score' $a.Score.Wert $b.Score.Wert 'Punkte' 'higher'),
        (M 'Start Ø letzte 5 Starts' $(if ($a.Boot.Mittel5) { [math]::Round($a.Boot.Mittel5 / 1000, 1) }) $(if ($b.Boot.Mittel5) { [math]::Round($b.Boot.Mittel5 / 1000, 1) }) 's' 'lower'),
        (M "Frei auf $($env:SystemDrive)" $sysA.FreiGB $sysB.FreiGB 'GB' 'higher'),
        (M 'Frei gesamt (feste Laufwerke)' ([math]::Round($freeA, 1)) ([math]::Round($freeB, 1)) 'GB' 'higher'),
        (M 'Aktive Autostarts' $a.Autostart.Aktiv $b.Autostart.Aktiv '' 'lower'),
        (M 'Verwaiste Autostarts' $a.Autostart.Verwaist $b.Autostart.Verwaist '' 'lower'),
        (M 'Laufende Dienste' $a.Dienste.Laufend $b.Dienste.Laufend '' 'lower'),
        (M 'Auto-Dienste von Drittanbietern' $a.Dienste.AutoDrittanbieter $b.Dienste.AutoDrittanbieter '' 'lower'),
        (M 'Prozesse im Leerlauf' $a.Leerlauf.Prozesse $b.Leerlauf.Prozesse '' 'lower'),
        (M 'Threads im Leerlauf' $a.Leerlauf.Threads $b.Leerlauf.Threads '' 'lower'),
        (M 'RAM belegt im Leerlauf' $a.Leerlauf.RamBelegtGB $b.Leerlauf.RamBelegtGB 'GB' 'lower'),
        (M 'CPU im Leerlauf' $a.Leerlauf.CpuProzent $b.Leerlauf.CpuProzent '%' 'lower'),
        (M 'Treiberpakete' $a.Treiber.Pakete $b.Treiber.Pakete '' 'lower'),
        (M 'Alte Treiber-Duplikate' $a.Treiber.Duplikate $b.Treiber.Duplikate '' 'lower'),
        (M 'Geistergeraete' $a.Treiber.Geistergeraete $b.Treiber.Geistergeraete '' 'lower'),
        (M 'Fehler System-Log (7 Tage)' $a.Ereignisse.FehlerSystem7T $b.Ereignisse.FehlerSystem7T '' 'lower'),
        (M 'Fehler Anwendungs-Log (7 Tage)' $a.Ereignisse.FehlerAnwendung7T $b.Ereignisse.FehlerAnwendung7T '' 'lower'),
        (M 'Installierte Programme' $a.Programme.Installiert $b.Programme.Installiert '' 'lower'),
        (M 'Store-Apps' $a.Programme.StoreApps $b.Programme.StoreApps '' 'lower'),
        (M 'Eigene geplante Aufgaben' $a.Aufgaben.Eigene $b.Aufgaben.Eigene '' 'lower'),
        (M 'Warnsignale (Ereignisprotokoll, 30 Tage)' $(if ($null -ne $a.Stabilitaet) { @($a.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }) $(if ($null -ne $b.Stabilitaet) { @($b.Stabilitaet.Warnsignale | Where-Object { $_ }).Count }) '' 'lower'),
        (M 'Hardware-Auffaelligkeiten' $(if ($a.Hardware) { @($a.Hardware.Punkte | Where-Object { $_ }).Count }) $(if ($b.Hardware) { @($b.Hardware.Punkte | Where-Object { $_ }).Count }) '' 'lower')
    )
}
function Show-Compare($a, $b) {
    Section ("Vergleich  {0} ({1})  ->  {2} ({3})" -f ([datetime]$a.Zeit).ToString('dd.MM. HH:mm'), $a.Label, ([datetime]$b.Zeit).ToString('dd.MM. HH:mm'), $b.Label)
    W ("  {0,-34} {1,12} {2,12} {3,12}" -f 'Kennzahl', 'Vorher', 'Nachher', 'Delta') 'White'
    foreach ($m in (Get-CompareMetrics $a $b)) {
        $c = switch ($m.Bewertung) { 'besser' { 'Green' } 'schlechter' { 'Red' } default { 'Gray' } }
        $d = if ($null -eq $m.Delta) { '' } elseif ($m.Delta -gt 0) { "+$($m.Delta)" } else { "$($m.Delta)" }
        W ("  {0,-34} {1,12} {2,12} {3,12} {4}" -f $m.Kennzahl, $m.Vorher, $m.Nachher, $d, $m.Einheit) $c
    }
    if ($a.Boot.Mittel5 -and $b.Boot.Mittel5 -and $a.Boot.Mittel5 -eq $b.Boot.Mittel5) { W '  Hinweis: Startzeiten sind erst nach 2-3 Neustarts aussagekraeftig (danach erneut "Scan").' 'DarkYellow' }
}

# =============================================================================
#  HTML-Bericht
# =============================================================================
function New-BootSvg($boots, $runs) {
    $pts = @($boots | Where-Object { $_.GesamtMs -gt 0 } | Sort-Object { [datetime]$_.Zeit })
    if ($pts.Count -lt 2) { return '<p class="muted">Noch zu wenige Startzeiten (Adminrechte noetig, mind. 2 Starts).</p>' }
    $W = 960; $H = 280; $pl = 50; $pr = 15; $pt = 15; $pb = 35
    $t0 = ([datetime]$pts[0].Zeit).Ticks; $t1 = ([datetime]$pts[-1].Zeit).Ticks; if ($t1 -eq $t0) { $t1 = $t0 + 1 }
    $max = [math]::Ceiling((($pts | Measure-Object GesamtMs -Maximum).Maximum) / 10000) * 10
    $sx = { param($t) $pl + ($W - $pl - $pr) * (($t - $t0) / ($t1 - $t0)) }
    $sy = { param($ms) $pt + ($H - $pt - $pb) * (1 - ($ms / 1000) / $max) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='chart' role='img' aria-label='Startzeiten'>")
    for ($y = 0; $y -le $max; $y += [math]::Max(10, [math]::Ceiling($max / 50) * 10)) { $yy = & $sy ($y * 1000); [void]$sb.Append("<line x1='$pl' x2='$($W-$pr)' y1='$yy' y2='$yy' class='grid'/><text x='$($pl-6)' y='$($yy+4)' class='ax' text-anchor='end'>$y s</text>") }
    foreach ($r in $runs) { $t = ([datetime]$r.Zeit).Ticks; if ($t -ge $t0 -and $t -le $t1) { $x = & $sx $t; [void]$sb.Append("<line x1='$x' x2='$x' y1='$pt' y2='$($H-$pb)' class='run'/><text x='$($x+4)' y='$($pt+10)' class='runlbl'>$(HtmlEnc $r.Name)</text>") } }
    foreach ($series in @(@{ P = 'HauptpfadMs'; C = 'main' }, @{ P = 'GesamtMs'; C = 'total' })) {
        [void]$sb.Append("<polyline points='$(($pts | ForEach-Object { ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0},{1:0.0}', (& $sx ([datetime]$_.Zeit).Ticks), (& $sy $_.($series.P)))) }) -join ' ')' class='$($series.C)'/>")
    }
    foreach ($p in $pts) { $x = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', (& $sx ([datetime]$p.Zeit).Ticks)); $y = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', (& $sy $p.GesamtMs)); [void]$sb.Append("<circle cx='$x' cy='$y' r='3.5' class='dot'><title>$(([datetime]$p.Zeit).ToString('dd.MM.yyyy HH:mm')): gesamt $([math]::Round($p.GesamtMs/1000,1)) s, bis Desktop $([math]::Round($p.HauptpfadMs/1000,1)) s, danach $([math]::Round($p.NachDesktopMs/1000,1)) s</title></circle>") }
    [void]$sb.Append("<text x='$pl' y='$($H-8)' class='ax'>$(([datetime]$pts[0].Zeit).ToString('dd.MM.yy'))</text><text x='$($W-$pr)' y='$($H-8)' class='ax' text-anchor='end'>$(([datetime]$pts[-1].Zeit).ToString('dd.MM.yy'))</text>")
    [void]$sb.Append('</svg><div class="legend"><span class="lg total"></span>Start gesamt <span class="lg main"></span>bis Desktop <span class="lg run"></span>WinTidy-Lauf</div>')
    return $sb.ToString()
}
function New-BarRows($rows, [string]$labelProp, [string]$valueProp, [scriptblock]$fmt) {
    $max = ($rows | Measure-Object $valueProp -Maximum).Maximum; if (-not $max) { return '<p class="muted">Keine Daten.</p>' }
    $sb = New-Object Text.StringBuilder
    foreach ($r in $rows) { $pct = [math]::Round(100 * $r.$valueProp / $max, 1); [void]$sb.Append("<div class='bar'><span class='bl'>$(HtmlEnc $r.$labelProp)</span><span class='bt'><span class='bf' style='width:$([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.0}',$pct))%'></span></span><span class='bv'>$(HtmlEnc (& $fmt $r.$valueProp))</span></div>") }
    $sb.ToString()
}

function New-Report {
    $snaps = Get-Snapshots
    if (-not $snaps.Count) { W 'Noch keine Snapshots - zuerst "Scan" ausfuehren.' 'Yellow'; return $null }
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
.chart .dot{fill:var(--acc)}.chart .run{stroke:var(--good);stroke-width:1.5;stroke-dasharray:6 4}.chart .runlbl{fill:var(--good);font-size:11px}
.legend{margin-top:6px;color:var(--muted);font-size:12px}.lg{display:inline-block;width:18px;height:3px;margin:0 6px 3px 14px;vertical-align:middle}.lg.total{background:var(--acc)}.lg.main{background:var(--main)}.lg.run{background:var(--good)}
.bar{display:grid;grid-template-columns:minmax(120px,240px) 1fr 90px;gap:10px;align-items:center;margin:5px 0}.bt{background:var(--line);height:10px;border-radius:5px;overflow:hidden}.bf{display:block;height:100%;background:var(--acc)}.bv{text-align:right;font-variant-numeric:tabular-nums}.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
details{margin:6px 0}summary{cursor:pointer}ul.items{margin:6px 0 0 18px;padding:0}
@media (max-width:640px){.bar{grid-template-columns:1fr 70px}.bt{grid-column:1/-1;order:3}.score{flex-direction:column;align-items:flex-start}table{display:block;overflow-x:auto}}
'@
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<!doctype html><html lang='de'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>WinTidy Bericht</title><style>$css</style></head><body><div class='wrap'>")
    [void]$sb.Append("<h1>WinTidy-Bericht &middot; $(HtmlEnc $last.Computer)</h1><div class='muted'>$(HtmlEnc $last.System.OS) $(HtmlEnc $last.System.Version) (Build $(HtmlEnc $last.System.Build)) &middot; $(HtmlEnc $last.System.CPU) &middot; $($last.System.RamGB) GB RAM &middot; $(HtmlEnc $last.System.Board) &middot; BIOS $(HtmlEnc $last.System.BIOS)<br>Letzter Snapshot: $(([datetime]$last.Zeit).ToString('dd.MM.yyyy HH:mm')) ($(HtmlEnc $last.Label)) &middot; $($all.Count) Snapshots &middot; WinTidy $Script:Version</div>")

    # Score + KPIs
    [void]$sb.Append("<h2>Zustand</h2><div class='grid4'><div class='card score' style='grid-column:span 2'><div class='ring $scoreClass'>$score</div><div><div class='kl'>Health-Score (0-100)</div>")
    if (@($last.Score.Abzuege).Count) { [void]$sb.Append('<ul class="items">'); foreach ($z in $last.Score.Abzuege) { [void]$sb.Append("<li>&minus;$([int]$z.Punkte) &nbsp;$(HtmlEnc $z.Grund)</li>") }; [void]$sb.Append('</ul>') } else { [void]$sb.Append('<p>Keine Abzuege.</p>') }
    [void]$sb.Append('</div></div>')
    $bootTxt = if ($last.Boot.Mittel5) { '{0:N1} s' -f ($last.Boot.Mittel5 / 1000) } else { 'n/a' }
    $kpis = @(
        @('Start (Ø 5)', $bootTxt), @("Frei auf $($sysLW):", $(if ($sysV) { "$($sysV.FreiGB) GB" } else { 'n/a' })), @('Aktive Autostarts', $last.Autostart.Aktiv),
        @('Fehler im Log (7 T.)', ($last.Ereignisse.FehlerSystem7T + $last.Ereignisse.FehlerAnwendung7T)), @('Aktionen gesamt', "$($okActs.Count) OK"), @('Freigegeben (geschaetzt)', (Fmt-Bytes $freed))
    )
    foreach ($k in $kpis) { [void]$sb.Append("<div class='card'><div class='kl'>$(HtmlEnc $k[0])</div><div class='kpi'>$(HtmlEnc $k[1])</div></div>") }
    [void]$sb.Append('</div>')

    [void]$sb.Append('<h2>Startzeiten</h2>'); [void]$sb.Append((New-BootSvg $boots $runs))

    if ($cmp.Count) {
        [void]$sb.Append("<h2>Vorher / Nachher</h2><p class='muted'>$(([datetime]$before.Zeit).ToString('dd.MM.yyyy HH:mm')) ($(HtmlEnc $before.Label)) &rarr; $(([datetime]$last.Zeit).ToString('dd.MM.yyyy HH:mm')) ($(HtmlEnc $last.Label)). Startzeiten aendern sich erst nach Neustarts.</p><table><tr><th>Kennzahl</th><th>Vorher</th><th>Nachher</th><th>Delta</th></tr>")
        foreach ($m in $cmp) { $d = if ($null -eq $m.Delta) { '' } elseif ($m.Delta -gt 0) { "+$($m.Delta)" } else { "$($m.Delta)" }; [void]$sb.Append("<tr><td>$(HtmlEnc $m.Kennzahl)</td><td class='n'>$(HtmlEnc $m.Vorher) $(HtmlEnc $m.Einheit)</td><td class='n'>$(HtmlEnc $m.Nachher) $(HtmlEnc $m.Einheit)</td><td class='n $($m.Bewertung)'>$(HtmlEnc $d)</td></tr>") }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append('<h2>Befunde (letzter Scan)</h2>')
    if (@($last.Befunde).Count) {
        [void]$sb.Append('<table><tr><th>Regel</th><th>Befund</th><th>Risiko</th><th>Anzahl</th><th>Umfang</th></tr>')
        foreach ($b in $last.Befunde) {
            $items = (@($b.Objekte) | ForEach-Object { "<li class='mono'>$(HtmlEnc $_)</li>" }) -join ''
            [void]$sb.Append("<tr><td class='mono'>$(HtmlEnc $b.Regel)</td><td><details><summary>$(HtmlEnc $b.Titel)</summary><ul class='items'>$items</ul></details></td><td><span class='tag $(if ([string]$b.Risiko -in 'Niedrig', 'Mittel', 'Hoch', 'Info') { [string]$b.Risiko } else { 'Info' })'>$(HtmlEnc $b.Risiko)</span></td><td class='n'>$([int]$b.Anzahl)</td><td class='n'>$(if ($b.Bytes) { Fmt-Bytes $b.Bytes })</td></tr>")
        }
        [void]$sb.Append('</table>')
    } else { [void]$sb.Append('<p class="muted">Keine Befunde gespeichert (Scan ausfuehren).</p>') }

    [void]$sb.Append('<h2>Startbremsen laut Windows (60 Tage)</h2>')
    $off = @($last.Boot.Bremser)
    if ($off.Count) { [void]$sb.Append((New-BarRows ($off | Select-Object -First 12 | ForEach-Object { [pscustomobject]@{ L = "$($_.Typ): $(if ($_.Name) { $_.Name } else { $_.Datei }) ($($_.Anzahl)x)"; V = $_.MittelMs } }) 'L' 'V' { param($v) '{0:N1} s' -f ($v / 1000) })) } else { [void]$sb.Append('<p class="muted">Keine Daten (Adminrechte noetig).</p>') }

    [void]$sb.Append('<h2>Autostart</h2><table><tr><th>Name</th><th>Ort</th><th>Aktiv</th><th>Ziel</th><th>Bremst</th></tr>')
    foreach ($s in (@($last.Autostart.Liste) | Sort-Object @{ Expression = { [bool]$_.Aktiv }; Descending = $true }, @{ Expression = { $_.DegradationMs }; Descending = $true })) {
        [void]$sb.Append("<tr><td>$(HtmlEnc $s.Name)</td><td>$(HtmlEnc $s.Ort)</td><td>$(if ($s.Aktiv) { '<span class=''OK''>an</span>' } else { '<span class=''muted''>aus</span>' })</td><td class='mono'>$(HtmlEnc $s.Ziel)$(if ($s.Zustand -eq 'fehlt') { ' <span class=''Fehler''>(fehlt)</span>' })</td><td class='n'>$(if ($s.DegradationMs) { '{0:N1} s' -f ($s.DegradationMs / 1000) })</td></tr>")
    }
    [void]$sb.Append('</table>')

    [void]$sb.Append('<h2>Laufwerke</h2>'); [void]$sb.Append((New-BarRows ($last.Laufwerke | ForEach-Object { [pscustomobject]@{ L = "$($_.LW): $($_.Label) $($_.Medium) $($_.Bus) - $($_.FreiGB) von $($_.GroesseGB) GB frei"; V = (100 - $_.FreiProzent) } }) 'L' 'V' { param($v) '{0:N0} % belegt' -f $v }))

    if ($last.Hardware) {
        $hw = $last.Hardware
        [void]$sb.Append("<h2>Hardware &amp; K&uuml;hlung</h2><table><tr><th>Messwert</th><th>Wert</th></tr>")
        $rows = New-Object System.Collections.Generic.List[object]
        $rows.Add(@('Prozessor-Temperatur', $(if ($null -ne $hw.CpuTempC) { '{0:N0} &deg;C (Quelle: {1})' -f $hw.CpuTempC, (HtmlEnc $hw.Sensorquelle) } else { 'nicht verf&uuml;gbar &ndash; Mainboard meldet sie nicht an Windows (LibreHardwareMonitor starten)' })))
        if ($hw.Gpu) { $rows.Add(@((HtmlEnc $hw.Gpu.Name), ('{0} &deg;C, L&uuml;fter {1} %' -f (HtmlEnc $hw.Gpu.TempC), (HtmlEnc $hw.Gpu.LuefterProzent)))) }
        $fl = @($hw.Luefter | Where-Object { $_ }); if ($fl.Count) { $rows.Add(@('L&uuml;fter', ((@($fl | ForEach-Object { '{0}: {1} U/min' -f (HtmlEnc $_.Name), $_.Upm })) -join '<br>'))) }
        $rows.Add(@('Drosselungen durch die Firmware (30 Tage)', [string][int]$hw.Drosselung30T))
        foreach ($d in @($hw.Laufwerke | Where-Object { $_ })) { $rows.Add(@(('Laufwerk ' + (HtmlEnc $d.Name)), ('{0}{1}{2}' -f $(if ($null -ne $d.TempC) { "$($d.TempC) &deg;C" } else { 'Temperatur unbekannt' }), $(if ($null -ne $d.Verschleiss) { ", $($d.Verschleiss) % verbraucht" } else { '' }), $(if ($d.Zustand) { ', ' + (HtmlEnc $d.Zustand) } else { '' })))) }
        if ($null -ne $hw.AkkuVerschleiss) { $rows.Add(@('Akku-Kapazit&auml;tsverlust', "$([int]$hw.AkkuVerschleiss) %")) }
        foreach ($r in $rows) { [void]$sb.Append("<tr><td>$($r[0])</td><td>$($r[1])</td></tr>") }
        [void]$sb.Append('</table>')
        $hp = @($hw.Punkte | Where-Object { $_ })
        if ($hp.Count) { [void]$sb.Append('<ul>'); foreach ($x in $hp) { [void]$sb.Append("<li class='$(if ($x.Stufe -eq 'krit') { 'bad' } else { 'mid' })'>$(HtmlEnc $x.Text)</li>") }; [void]$sb.Append('</ul>') } else { [void]$sb.Append("<p class='muted'>Keine Auff&auml;lligkeiten bei K&uuml;hlung, Laufwerken und Akku.</p>") }
        $lt = Get-LastCoolingTest
        if ($lt) { [void]$sb.Append("<p><b>Letzter K&uuml;hlungstest</b> ($(([datetime]$lt.Zeit).ToString('dd.MM.yyyy HH:mm')), $([int]$lt.Sekunden) s, $([int]$lt.Kerne) Threads):</p><ul>"); foreach ($x in @($lt.Punkte)) { [void]$sb.Append("<li class='$(switch ($x.Stufe) { 'krit' { 'bad' } 'warn' { 'mid' } 'ok' { 'good' } default { 'muted' } })'>$(HtmlEnc $x.Text)</li>") }; [void]$sb.Append('</ul>') }
    }
    if ($perRule.Count) { [void]$sb.Append('<h2>Aufgeraeumt pro Regel</h2>'); [void]$sb.Append((New-BarRows ($perRule | Where-Object Bytes) 'Regel' 'Bytes' { param($v) Fmt-Bytes $v })); [void]$sb.Append('<table><tr><th>Regel</th><th>Aktionen</th><th>Umfang</th></tr>'); foreach ($p in $perRule) { [void]$sb.Append("<tr><td class='mono'>$(HtmlEnc $p.Regel)</td><td class='n'>$($p.Anzahl)</td><td class='n'>$(Fmt-Bytes $p.Bytes)</td></tr>") }; [void]$sb.Append('</table>') }

    [void]$sb.Append('<h2>Aktionsprotokoll</h2>')
    if ($actions.Count) { [void]$sb.Append('<table><tr><th>Zeit</th><th>Regel</th><th>Objekt</th><th>Status</th><th>Umfang</th></tr>'); foreach ($a in ($actions | Sort-Object Zeit -Descending | Select-Object -First 400)) { [void]$sb.Append("<tr><td class='n'>$(([datetime]$a.Zeit).ToString('dd.MM. HH:mm'))</td><td class='mono'>$(HtmlEnc $a.Regel)</td><td>$(HtmlEnc $a.Objekt)$(if ($a.Meldung) { '<div class=''muted''>' + (HtmlEnc $a.Meldung) + '</div>' })</td><td class='$($a.Status)'>$(HtmlEnc $a.Status)</td><td class='n'>$(if ($a.Bytes) { Fmt-Bytes $a.Bytes })</td></tr>") }; [void]$sb.Append('</table>') } else { [void]$sb.Append('<p class="muted">Noch keine Aenderungen ausgefuehrt.</p>') }

    [void]$sb.Append('<h2>Snapshot-Verlauf</h2><table><tr><th>Zeit</th><th>Typ</th><th>Score</th><th>Start Ø</th><th>Frei System</th><th>Autostarts</th><th>Fehler 7 T.</th></tr>')
    foreach ($s in ($all | Sort-Object Zeit -Descending)) { $sv = $s.Laufwerke | Where-Object { $_.LW -eq $sysLW } | Select-Object -First 1; [void]$sb.Append("<tr><td class='n'>$(([datetime]$s.Zeit).ToString('dd.MM.yyyy HH:mm'))</td><td>$(HtmlEnc $s.Label)</td><td class='n'>$([int]$s.Score.Wert)</td><td class='n'>$(if ($s.Boot.Mittel5) { '{0:N1} s' -f ($s.Boot.Mittel5 / 1000) })</td><td class='n'>$(if ($sv) { "$($sv.FreiGB) GB" })</td><td class='n'>$($s.Autostart.Aktiv)</td><td class='n'>$($s.Ereignisse.FehlerSystem7T + $s.Ereignisse.FehlerAnwendung7T)</td></tr>") }
    [void]$sb.Append('</table>')
    [void]$sb.Append("<p class='muted' style='margin-top:30px'>Daten: <span class='mono'>$(HtmlEnc $Script:DataDir)</span> &middot; erzeugt $(Get-Date -Format 'dd.MM.yyyy HH:mm')</p></div></body></html>")
    $out = Join-Path $Script:DataDir 'WinTidy-Bericht.html'
    [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
    W "  Bericht: $out" 'Green'
    return $out
}

# =============================================================================
#  Wiederherstellen
# =============================================================================
function Resolve-RunDir([string]$Lauf) {
    if (-not $Lauf) { return $null }
    $runs = @(Get-ChildItem $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name -Descending)
    $exakt = $runs | Where-Object { $_.Name -eq "$($Lauf)_apply" } | Select-Object -First 1
    if ($exakt) { return $exakt }
    $treffer = @($runs | Where-Object { $_.Name -like "$Lauf*" })
    if ($treffer.Count -eq 1) { return $treffer[0] }
    return $null   # nicht eindeutig
}
function Read-UndoRecords($RunDir) {
    $acts = Join-Path $RunDir.FullName 'actions.jsonl'
    if (-not (Test-Path -LiteralPath $acts)) { return @() }
    @(Get-Content -LiteralPath $acts -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and $_.Undo })
}
# Verstaendlicher Name einer Undo-Info
function Get-UndoLabel($a) {
    $u = $a.Undo
    switch ([string]$u.Typ) {
        'RegValue' {
            $k = ConvertTo-RegKeyText $u.Key
            if ($k -match 'GameDVR|GameConfigStore') { return @('Einstellung', 'Spiele-Aufnahme (Xbox Game Bar)') }
            if ($k -match 'FileSystem$') { return @('Einstellung', 'TRIM für SSDs') }
            return @('Autostart', ('"{0}"' -f $a.Objekt))
        }
        'Dienst' { return @('Hintergrunddienst', ('"{0}"' -f $u.Name)) }
        'PowerSetting' { return @('Energieeinstellung', 'Kühlung im Netzbetrieb') }
        'ExecPolicy' { return @('Einstellung', 'Schutzeinstellung für Skripte') }
        'Hiber' { return @('Einstellung', 'Ruhezustandsdatei (volle Größe)') }
        'Datei' { return @('Autostart', ('Verknüpfung "{0}"' -f [IO.Path]::GetFileNameWithoutExtension([string]$u.Ziel))) }
    }
    return @('Einstellung', [string]$a.Objekt)
}
function Get-RegBackupLabel([string]$Name) {
    if ($Name -like 'appxkey_*') { return 'Autostart einer App' }
    if ($Name -like 'approved_*') { return 'Autostart-Einstellungen' }
    if ($Name -like 'run_*') { return 'Autostart-Einträge' }
    if ($Name -like 'gameconfigstore*') { return 'Spiele-Aufnahme (Xbox Game Bar)' }
    if ($Name -like 'appx_*') { return 'Autostart einer App' }
    return ($Name -replace '_', ' ')
}
# Registry-Sicherungen (.reg) werden nur noch fuer Laeufe ohne Einzelwert-Undo eingespielt (Laeufe vor 1.3) bzw. fuer
# komplett entfernte App-Autostart-Schluessel - und nur, wenn alle enthaltenen Schluessel erwartet sind.
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

# Was "Wiederherstellen" fuer einen Lauf zuruecksetzen wuerde (aendert nichts)
function Get-RestorePreview([string]$Lauf) {
    $sel = Resolve-RunDir $Lauf
    if (-not $sel) { return @() }
    $undos = Read-UndoRecords $sel
    $r = @()
    foreach ($f in (Get-RegBackupFiles $sel $undos)) { $r += [pscustomobject]@{ Art = 'Einstellung'; Objekt = (Get-RegBackupLabel $f.BaseName) } }
    $idx = Join-Path $sel.FullName 'backup\tasks\index.jsonl'
    if (Test-Path $idx) { foreach ($l in (Get-Content $idx -Encoding UTF8 | Where-Object { $_ })) { try { $t = $l | ConvertFrom-Json; $r += [pscustomobject]@{ Art = 'Geplante Aufgabe'; Objekt = ('"{0}"' -f $t.TaskName) } } catch { } } }
    foreach ($a in $undos) { $lb = Get-UndoLabel $a; $r += [pscustomobject]@{ Art = $lb[0]; Objekt = $lb[1] } }
    return @($r | Sort-Object Art, Objekt -Unique)
}

function Invoke-Restore {
    if ($Script:IsAdmin -and $Script:DataDirIsDefault -and -not $Script:DataDirProtected) {
        W 'Der Datenordner ist nicht ausreichend geschuetzt - Wiederherstellen ist zur Sicherheit gesperrt. Bitte die Systemwiederherstellung (rstrui.exe) nutzen.' 'Red'
        return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = 'Der Datenordner von WinTidy ist nicht ausreichend geschützt. Zur Sicherheit setzt WinTidy deshalb nichts zurück. Bitte die Windows-Systemwiederherstellung nutzen.'; Lauf = $null; Wiederhergestellt = 0; Fehler = 0; Details = @() }
    }
    $runs = @(Get-ChildItem $Script:RunsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*_apply' } | Sort-Object Name -Descending)
    if (-not $runs.Count) { W 'Keine Apply-Laeufe gefunden.' 'Yellow'; return [pscustomobject]@{ Status = 'NICHT-GEFUNDEN'; Lauf = $null; Wiederhergestellt = 0; Fehler = 0; Details = @() } }
    $sel = if ($Script:RestoreRunId) { Resolve-RunDir $Script:RestoreRunId } else {
        W 'Laeufe:'; for ($i = 0; $i -lt [math]::Min(10, $runs.Count); $i++) { W ("  [{0}] {1}" -f ($i + 1), $runs[$i].Name) }
        $n = Read-Host 'Nummer'; $k = 0; if ([int]::TryParse($n, [ref]$k) -and $k -ge 1 -and $k -le $runs.Count) { $runs[$k - 1] } else { $null }
    }
    if (-not $sel) { W 'Lauf nicht gefunden (oder nicht eindeutig).' 'Red'; return [pscustomobject]@{ Status = 'NICHT-GEFUNDEN'; Lauf = $Script:RestoreRunId; Wiederhergestellt = 0; Fehler = 0; Details = @() } }
    $det = New-Object System.Collections.Generic.List[object]
    function R([string]$Art, [string]$Obj, [bool]$Ok, [string]$Msg = '') {
        $det.Add([pscustomobject]@{ Art = $Art; Objekt = $Obj; Status = $(if ($Ok) { 'OK' } else { 'Fehler' }); Meldung = $Msg })
        Add-ActionRecord 'RESTORE' "$Art $Obj" $(if ($Ok) { 'OK' } else { 'Fehler' }) 0 $Msg | Out-Null
        W ("  {0} {1}: {2}{3}" -f $(if ($Ok) { 'OK    ' } else { 'FEHLER' }), $Art, $Obj, $(if ($Msg) { " ($Msg)" } else { '' })) $(if ($Ok) { 'Green' } else { 'Red' })
    }
    W "Stelle wieder her: $($sel.FullName)" 'Cyan'
    W 'Hinweis: Geloeschte Dateien, deinstallierte Programme und entfernte Store-Apps lassen sich hier nicht zurueckholen (dafuer: Wiederherstellungspunkt).' 'DarkYellow'
    $neuer = @($runs | Where-Object { $_.Name -gt $sel.Name })
    if ($neuer.Count) { W ("  Achtung: Danach gab es noch {0} weitere Optimierung(en). Werte, die seitdem geaendert wurden, werden nicht ueberschrieben." -f $neuer.Count) 'DarkYellow' }
    $undos = Read-UndoRecords $sel
    foreach ($f in (Get-RegBackupFiles $sel $undos)) {
        $lb = Get-RegBackupLabel $f.BaseName
        if (-not (Test-RegFileAllowed $f.FullName)) { R 'Einstellung' $lb $false 'Unerwarteter Registry-Pfad - nicht eingespielt'; continue }
        $null = & reg.exe import $f.FullName 2>&1
        R 'Einstellung' $lb ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -ne 0) { "reg import Fehler $LASTEXITCODE" } else { '' })
    }
    # Geplante Aufgaben wurden nur deaktiviert - wieder einschalten statt aus XML neu anzulegen
    $idx = Join-Path $sel.FullName 'backup\tasks\index.jsonl'
    if (Test-Path $idx) {
        foreach ($l in (Get-Content $idx -Encoding UTF8 | Where-Object { $_ })) {
            $t = $null; try { $t = $l | ConvertFrom-Json } catch { continue }
            try { Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null; R 'Geplante Aufgabe' $t.TaskName $true }
            catch { R 'Geplante Aufgabe' $t.TaskName $false $_.Exception.Message }
        }
    }
    # Einzelne Aenderungen in umgekehrter Reihenfolge zuruecknehmen
    $liste = @($undos); [array]::Reverse($liste)
    foreach ($a in $liste) {
        if ([string]$a.Undo.Typ -notin 'RegValue', 'Dienst', 'PowerSetting', 'ExecPolicy', 'Hiber', 'Datei') { continue }
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
                    if ($LASTEXITCODE -ne 0) { throw "powercfg Fehler $LASTEXITCODE" }
                    $null = & powercfg.exe /setactive $a.Undo.Schema 2>&1
                }
                'ExecPolicy' { if ([string]$a.Undo.Vorher -in 'Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass', 'Undefined') { try { Set-ExecutionPolicy ([string]$a.Undo.Vorher) -Scope ([string]$a.Undo.Scope) -Force -ErrorAction Stop } catch { if ($_.Exception.Message -notmatch 'overridden|ueberschrieben|überschrieben') { throw } } } }
                'Hiber' { $null = & powercfg.exe /h /type full 2>&1; if ($LASTEXITCODE -ne 0) { throw "powercfg Fehler $LASTEXITCODE" } }
                'Datei' {
                    $ziel = [IO.Path]::GetFullPath([string]$a.Undo.Ziel); $quelle = [IO.Path]::GetFullPath([string]$a.Undo.Quelle)
                    $erlaubt = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) | Where-Object { $_ -and ([IO.Path]::GetDirectoryName($ziel)) -ieq $_.TrimEnd('\') }
                    if (-not $erlaubt) { throw 'Unerwarteter Zielordner - nicht zurueckkopiert' }
                    if (-not $quelle.StartsWith($sel.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Sicherung liegt nicht im Laufordner' }
                    if (-not (Test-Path -LiteralPath $ziel)) { Copy-Item -LiteralPath $quelle -Destination $ziel -ErrorAction Stop }
                }
            }
            R $lb[0] $lb[1] $true
        } catch { R $lb[0] $lb[1] $false $_.Exception.Message }
    }
    W 'Fertig. Fuer alles Weitere: Systemwiederherstellung (rstrui.exe) mit dem Punkt "WinTidy <Lauf>".' 'Cyan'
    $okN = @($det | Where-Object Status -eq 'OK').Count
    try { [ordered]@{ Zeit = (Get-Date).ToString('o'); Wiederhergestellt = $okN; Fehler = ($det.Count - $okN) } | ConvertTo-Json | Out-File (Join-Path $sel.FullName 'rueckgaengig.json') -Encoding utf8 } catch { }
    return [pscustomobject]@{ Status = 'OK'; Lauf = $sel.Name; Wiederhergestellt = $okN; Fehler = ($det.Count - $okN); Details = $det.ToArray() }
}

# =============================================================================
#  API fuer die grafische Oberflaeche (WinTidy-App.ps1)
#  Die App laedt diese Datei per Dot-Sourcing in einen Hintergrund-Runspace.
# =============================================================================
$Script:Friendly = @{
    'CLN-TEMP'            = @('Temporäre Dateien entfernen', 'Programme legen beim Arbeiten Zwischendateien ab und vergessen sie. Gelöscht wird nur, was seit Tagen niemand mehr angelegt oder geändert hat.')
    'CLN-WINCLEAN'        = @('Windows-Altlasten aufräumen', 'Reste von Windows-Updates, Fehlerberichte und der Update-Zwischenspeicher. Nutzt die Windows-eigene Datenträgerbereinigung.')
    'CLN-WINOLD'          = @('Vorherige Windows-Version löschen', 'Nach einem großen Windows-Update bleibt die alte Version als Sicherung liegen – oft 10 bis 30 GB. Danach kannst du nicht mehr zur alten Windows-Version zurück. Die Dateien für "Diesen PC zurücksetzen" bleiben erhalten.')
    'CLN-WINSXS'          = @('Update-Speicher verkleinern', 'Windows behält ersetzte Teile alter Updates. Windows selbst empfiehlt hier eine Bereinigung.')
    'CLN-DUMPS'           = @('Absturzberichte von Programmen löschen', 'Programme hinterlassen nach Abstürzen große Diagnose-Dateien, die nur Entwickler brauchen.')
    'CLN-HIBERFIL'        = @('Ruhezustandsdatei verkleinern', 'Auf Desktop-PCs wird der Ruhezustand kaum genutzt, die Datei belegt aber oft viele Gigabyte. Sie wird auf die Größe verkleinert, die der Schnellstart braucht – der Schnellstart bleibt, der Ruhezustand und der hybride Standby entfallen. Lässt sich rückgängig machen.')
    'CLN-RECYCLE'         = @('Alte Dateien im Papierkorb endgültig löschen', 'Nur Dateien, die schon länger im Papierkorb liegen. Kürzlich Gelöschtes bleibt wiederherstellbar.')
    'CLN-RECYCLE-ORPHAN'  = @('Papierkörbe alter Benutzerkonten leeren', 'Nach einer Neuinstallation bleiben unsichtbare Papierkörbe früherer Konten auf den Laufwerken liegen.')
    'CLN-DRIVERSTORE'     = @('Alte Treiber-Versionen entfernen', 'Bei jedem Treiber-Update bleibt die alte Version liegen. Die aktuelle bleibt immer erhalten, benutzte Treiber schützt Windows.')
    'CLN-ORPHANDIR'       = @('Ordner ohne zugehöriges Programm (Profi)', 'Ordner, die zu keinem installierten Programm zu passen scheinen. Kann Fehltreffer enthalten – nur mit Bedacht auswählen.')
    'STA-ORPHAN'          = @('Kaputte Autostart-Einträge entfernen', 'Diese Einträge zeigen auf Programme, die es nicht mehr gibt.')
    'STA-APPROVED-ORPHAN' = @('Überbleibsel im Autostart aufräumen', 'Windows merkt sich Einstellungen für Programme, die längst entfernt wurden.')
    'STA-HEAVY'           = @('Programme beim Start nicht mehr automatisch öffnen', 'Jedes Programm, das beim Hochfahren mitstartet, verlängert den Start. Die Programme bleiben installiert und lassen sich normal öffnen. Virenschutz, VPN, Backup und Cloud-Speicher bleiben immer an.')
    'TSK-ORPHAN'          = @('Kaputte geplante Aufgaben abschalten', 'Diese Aufgaben versuchen regelmäßig Programme zu starten, die es nicht mehr gibt.')
    'TSK-ANTIPATTERN'     = @('Geplante Aufgaben mit unerwünschten Nebenwirkungen', 'Auf diesem PC wurden Aufgaben eingerichtet, die regelmäßig laufen und dabei den PC bremsen oder zu viel löschen. WinTidy ändert sie nicht – bitte von der Person anpassen lassen, die sie eingerichtet hat.')
    'SVC-ORPHAN'          = @('Kaputte Hintergrunddienste abschalten', 'Reste deinstallierter Programme, die bei jedem Start vergeblich versuchen zu laufen.')
    'APP-SIDEBYSIDE'      = @('Doppelt installierte Programme bereinigen', 'Von diesen Programmen sind mehrere Versionen installiert. Die neueste bleibt. Es öffnet sich jeweils das Deinstallationsprogramm.')
    'APP-BLOAT'           = @('Vorinstallierte Apps entfernen', 'Apps, die Windows ungefragt mitbringt (z. B. Spiele-Demos, News). Wenn du eine davon benutzt – etwa Wetter –, lass den Haken weg. Alles lässt sich im Store wieder installieren.')
    'APP-UPDATES'         = @('Programme aktualisieren', 'Veraltete Programme sind das häufigste Einfallstor für Schadsoftware. Bitte vorher alle Programme schließen – ein Update kann offene Programme beenden.')
    'SYS-GHOST'           = @('Alte Geräte-Einträge entfernen', 'Geräte, die nicht mehr angeschlossen sind (z. B. alte USB-Sticks, Mäuse, Monitore). Steckst du sie wieder ein, werden sie neu erkannt – eigene Einstellungen dafür (z. B. eine feste IP-Adresse) gehen aber verloren.')
    'SYS-SHADOW'          = @('Platz für Wiederherstellungspunkte vergrößern', 'Zu wenig Platz führt dazu, dass Windows Wiederherstellungspunkte stillschweigend löscht.')
    'SYS-TRIM'            = @('SSD auffrischen (TRIM)', 'Teilt der SSD mit, welcher Speicher frei ist, und hält sie schnell. Windows macht das normalerweise selbst – hier ist es abgeschaltet oder lange nicht gelaufen.')
    'SYS-MAINT'           = @('Windows-Wartung nachholen', 'Die automatische Wartung ist zuletzt nicht durchgelaufen. Danach den PC etwa eine Stunde eingeschaltet lassen.')
    'SYS-INTEGRITY'       = @('Windows-Systemdateien prüfen und reparieren', 'Prüft, ob Windows-Dateien beschädigt sind, und repariert sie. Dauert 10–30 Minuten.')
    'SYS-FSCHECK'         = @('Laufwerke auf Fehler prüfen', 'Ergebnis der Dateisystem-Prüfung.')
    'SYS-GAMEDVR'         = @('Hintergrund-Aufnahme für Spiele abschalten', 'Die Xbox Game Bar nimmt in Spielen ständig die letzten Minuten auf und kostet Leistung. Clips selbst aufnehmen kannst du weiterhin.')
    'SYS-TWEAKS'          = @('Ungünstige Tuning-Einstellungen', 'Manche Tuning-Programme schalten Windows-Funktionen ab, die den PC eigentlich schneller oder sicherer machen. WinTidy zeigt sie an; zurückstellen sollte es jemand, der sich auskennt.')
    'SEC-EXECPOLICY'      = @('Schutzeinstellung für Skripte zurücksetzen', 'Stellt eine Windows-Sicherheitseinstellung auf den von Microsoft empfohlenen Wert. Im Alltag merkst du davon nichts. Lässt sich rückgängig machen.')
    'SEC-CHECKS'          = @('Sicherheit', 'Updates und grundlegende Schutzfunktionen von Windows und des PCs.')
    'HW-HINTS'            = @('Hinweise zur Hardware', 'Einstellungen, die eine fachkundige Person prüfen kann. Bitte nichts im BIOS ändern, wenn du dir unsicher bist.')
    'HW-COOLING'          = @('Kühlung und Temperaturen', 'Ob Prozessor, Grafikkarte und Laufwerke zu warm werden, gebremst werden oder ob ein Lüfter steht. Lüfterkurven selbst liegen im BIOS – WinTidy misst ihre Wirkung.')
    'HW-COOLPOLICY'       = @('Bei Wärme zuerst die Lüfter hochdrehen', 'Im Netzbetrieb sollen zuerst die Lüfter schneller drehen, bevor Windows den Prozessor bremst. Die Einstellung steht hier auf "erst bremsen". Lässt sich rückgängig machen.')
    'HW-DISPLAY'          = @('Bildschirm', 'Ob dein Bildschirm mit der höchsten Bildwiederholrate läuft, die er kann.')
    'EVT-HEALTH'          = @('Warnmeldungen von Windows', 'Windows hat in den letzten 30 Tagen Probleme notiert, z. B. Abstürze oder plötzliches Ausschalten. Einzelne Einträge sind kein Grund zur Sorge. Treten sie häufig auf, lass den PC prüfen.')
}
# Mittel-Regeln, die die App vorauswaehlt. Endgueltiges (Loeschen, Deinstallieren, Geraete entfernen, Updates) bewusst nicht.
$Script:GuiPreselectMedium = @('SVC-ORPHAN', 'SEC-EXECPOLICY')
# Verstaendliche Bereichsnamen fuer den Fortschritt der Pruefung (keine Aktionsverben wie "loeschen")
$Script:AreaNames = @{ 'Speicher' = 'Speicherplatz'; 'Autostart' = 'Programme beim Start'; 'Aufgaben' = 'geplante Aufgaben'; 'Dienste' = 'Hintergrunddienste'; 'Programme' = 'installierte Programme'; 'System' = 'Windows-System'; 'Sicherheit' = 'Sicherheit'; 'Hardware' = 'Hardware und Kühlung'; 'Stabilitaet' = 'Warnmeldungen von Windows' }
$Script:LastFindings = @()

$Script:LastContext = $null

# Darf diese Regel im aktuellen Kontext angeboten werden? (Firmen-PC: nur sichere Aufraeumpunkte und Hinweise)
function Test-RuleAllowed($r, $ctx) {
    if (-not $ctx -or -not $ctx.Verwaltet) { return $true }
    return ($r.Risiko -eq 'Info' -or ($r.Kategorie -eq 'Speicher' -and $r.Risiko -eq 'Niedrig') -or $r.Id -eq 'SYS-TRIM')
}

function Get-AllFindings([bool]$Expert = $false, [scriptblock]$OnProgress = $null) {
    $Script:Cache = @{}
    $Script:Preview = $true
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    $Script:LastContext = $ctx
    $rules = @($Script:Rules | Where-Object { ($_.Standard -or $Expert) -and (Test-RuleAllowed $_ $ctx) })
    $res = New-Object System.Collections.Generic.List[object]
    # Hardware zuerst messen, solange der PC noch ruht
    if ($OnProgress) { try { & $OnProgress 0 $rules.Count 'Prüfe gerade: Hardware und Kühlung …' } catch { } }
    try { $null = Get-HardwarePoints } catch { }
    $i = 0
    foreach ($r in $rules) {
        $i++
        $fr = $Script:Friendly[$r.Id]; $titel = if ($fr) { $fr[0] } else { $r.Titel }; $text = if ($fr) { $fr[1] } else { $r.Warum }
        $bereich = if ($Script:AreaNames.ContainsKey([string]$r.Kategorie)) { $Script:AreaNames[[string]$r.Kategorie] } else { [string]$r.Kategorie }
        if ($OnProgress) { try { & $OnProgress $i $rules.Count ("Prüfe gerade: {0} …" -f $bereich) } catch { } }
        if ($r.Admin -and -not $Script:IsAdmin) { continue }
        $items = @()
        try { $items = @(& $r.Detect | Where-Object { $_ }) } catch { W "Pruefung $($r.Id) fehlgeschlagen: $($_.Exception.Message)" 'Red'; continue }
        W ("{0}: {1} Befund(e)" -f $r.Id, $items.Count) 'Gray'
        if (-not $items.Count) { continue }
        $k = 0
        $its = foreach ($it in $items) {
            $pre = $false
            if ($r.Risiko -eq 'Niedrig') { $pre = $true }
            elseif ($r.Risiko -eq 'Mittel') {
                $pre = ($Script:GuiPreselectMedium -contains $r.Id) -or [bool]$it.AutoOk
            }
            # Lange Schritte nicht vorauswaehlen, solange der PC auf Akku laeuft
            if ($r.Dauer -and $ctx -and $ctx.Akku) { $pre = $false }
            $stufe = ''
            if ($it.Data -and ($it.Data -is [System.Collections.IDictionary] -or $it.Data -is [pscustomobject]) -and $it.Data.Stufe) { $stufe = [string]$it.Data.Stufe }
            [pscustomobject]@{ Index = $k; Label = $it.Label; Bytes = [int64]$it.Bytes; Vorauswahl = $pre; Selected = $pre; Stufe = $stufe; Technik = $it.Technik; Raw = $it }
            $k++
        }
        $res.Add([pscustomobject]@{ Id = $r.Id; Kategorie = $r.Kategorie; Titel = $titel; Text = $text; Warum = $r.Warum; Risiko = $r.Risiko; Fixbar = [bool]$r.Fix; Bytes = [int64](($items | Measure-Object Bytes -Sum).Sum); Items = @($its)
                Dauer = $r.Dauer; Endgueltig = $r.Endgueltig; Einzeln = $r.Einzeln; Umkehrbar = $r.Umkehrbar })
    }
    $Script:LastFindings = $res.ToArray()
    return $Script:LastFindings
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
        if ($OnProgress) { try { & $OnProgress 1 1 'Fast fertig: Ich messe noch den Zustand deines PCs …' 'CORE' } catch { } }
        $snap = New-Snapshot 'scan' (ConvertTo-Befunde $f)
        $rep = New-Report
    } finally { Stop-RunLog }
    [pscustomobject]@{ Findings = $f; Snapshot = $snap; Report = $rep; Context = $Script:LastContext }
}

function New-RestorePointSilent {
    $err = Invoke-Checkpoint
    if (-not $err) { W 'Wiederherstellungspunkt angelegt.' 'Green'; return $true }
    W "Wiederherstellungspunkt fehlgeschlagen: $err" 'Red'; return $false
}

# Selection: Liste von @{ Id = 'REGEL'; Indexes = @(0,2,...) }
# Status: OK | ABGEBROCHEN | RP-FEHLT (nichts geaendert, App fragt nach und ruft mit OhneRP erneut auf) | GESPERRT
function Invoke-FixSelection([object[]]$Selection, [bool]$RestorePoint = $true, [scriptblock]$OnProgress = $null, $Control = $null, [bool]$OhneRP = $false) {
    function Prog($i, $n, $t, $id) { if ($OnProgress) { try { & $OnProgress $i $n $t $id } catch { } } }
    # Frisch messen: seit der Pruefung kann z. B. das Netzteil gezogen worden sein
    $Script:Cache = @{}
    $ctx = $null; try { $ctx = Get-WtContext } catch { }
    if (-not $ctx -or $ctx.Server) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = 'Auf Windows Server nimmt WinTidy keine Änderungen vor.' } }
    if (-not $Script:IsAdmin) { return [pscustomobject]@{ Status = 'GESPERRT'; Meldung = 'Für Änderungen braucht WinTidy Administratorrechte.' } }

    # Auftraege zusammenstellen (noch keine Aenderung)
    $jobs = @()
    foreach ($s in $Selection) {
        $f = $Script:LastFindings | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1
        $r = $Script:Rules | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1
        if (-not $f -or -not $r -or -not $r.Fix -or -not (Test-RuleAllowed $r $ctx)) { continue }
        foreach ($ix in @($s.Indexes)) { $it = $f.Items | Where-Object { $_.Index -eq [int]$ix } | Select-Object -First 1; if ($it) { $jobs += [pscustomobject]@{ Rule = $r; Titel = $f.Titel; Item = $it } } }
    }

    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $Script:Preview = $false
    if (-not $OhneRP) { $Script:ComputerschutzEingeschaltet = $false }   # bei OhneRP den Hinweis aus dem ersten Versuch behalten
    Start-RunLog 'apply'
    $rp = $null
    if ($RestorePoint -and -not $OhneRP) {
        Prog 0 1 'Lege einen Wiederherstellungspunkt an ...' 'CORE'
        $err = Invoke-Checkpoint
        if ($err) {
            W "Wiederherstellungspunkt fehlgeschlagen: $err" 'Red'
            # Nichts wurde geaendert: Laufordner wieder entfernen, damit kein leerer Lauf im Verlauf steht
            Stop-RunLog
            try { Remove-Item -LiteralPath $Script:RunDir -Recurse -Force -ErrorAction Stop } catch { }
            $Script:RunDir = $null
            return [pscustomobject]@{ Status = 'RP-FEHLT'; Meldung = [string]$err; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet }
        }
        $rp = $true
        W 'Wiederherstellungspunkt angelegt.' 'Green'
        Add-ActionRecord 'CORE' 'Wiederherstellungspunkt' 'OK' | Out-Null
    } elseif ($RestorePoint -and $OhneRP) {
        $rp = $false
        Add-ActionRecord 'CORE' 'Wiederherstellungspunkt' 'Uebersprungen' 0 'Vom Benutzer ohne Wiederherstellungspunkt bestaetigt' | Out-Null
    }

    # Schon waehrend des Wiederherstellungspunkts abgebrochen: nichts geaendert, keine Messungen mehr
    if ($Control -and $Control.Cancel) {
        $det0 = @($jobs | ForEach-Object { [pscustomobject]@{ Titel = $_.Titel; Objekt = [string]$_.Item.Label; Status = 'Abgebrochen'; Meldung = 'Nicht ausgeführt (abgebrochen)' } })
        [ordered]@{ Lauf = $Script:RunId; Aktionen = $jobs.Count; OK = 0; Fehler = 0; Abgebrochen = $true; BytesGeschaetzt = 0; Wiederherstellungspunkt = $rp; Umkehrbar = 0 } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
        Stop-RunLog
        return [pscustomobject]@{ Status = 'ABGEBROCHEN'; RunId = $Script:RunId; Aktionen = $jobs.Count; OK = 0; Fehler = 0; Bytes = 0; Vorher = $null; Nachher = $null; Vergleich = @(); Report = $null; Wiederherstellungspunkt = $rp; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet; Details = $det0; Umkehrbar = 0 }
    }
    W 'Messe Zustand vorher ...' 'Cyan'
    Prog 0 1 'Messe den Zustand vorher ...' 'CORE'
    $info = ConvertTo-Befunde $Script:LastFindings -NurInfo
    $pre = New-Snapshot 'vorher' $info

    $ok = 0; $fail = 0; $bytes = 0; $n = 0; $abbruch = $false
    $details = New-Object System.Collections.Generic.List[object]
    foreach ($j in $jobs) {
        $n++
        $lbl = [string]$j.Item.Label
        if ($abbruch -or ($Control -and $Control.Cancel)) {
            $abbruch = $true
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Abgebrochen'; Meldung = 'Nicht ausgeführt (abgebrochen)' })
            Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 'Abgebrochen' | Out-Null
            continue
        }
        if ($j.Rule.Dauer -and $ctx -and $ctx.Akku) {
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Uebersprungen'; Meldung = 'Läuft auf Akku – dieser lange Schritt wird nur mit Netzteil ausgeführt' })
            Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 'Akkubetrieb' | Out-Null
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
                # Erwartbar, kein Fehler (z. B. Treiber wird noch benutzt, Deinstallation abgebrochen)
                W ("--  [{0}] {1}: {2}" -f $j.Rule.Id, $lbl, $em.Substring(5)) 'DarkYellow'
                Add-ActionRecord $j.Rule.Id $lbl 'Uebersprungen' 0 $em.Substring(5) | Out-Null
                $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Uebersprungen'; Meldung = $em.Substring(5) })
                continue
            }
            $fail++
            W ("FEHLER  [{0}] {1}: {2}" -f $j.Rule.Id, $lbl, $em) 'Red'
            Add-ActionRecord $j.Rule.Id $lbl 'Fehler' 0 $em | Out-Null
            $details.Add([pscustomobject]@{ Titel = $j.Titel; Objekt = $lbl; Status = 'Fehler'; Meldung = $em })
        }
    }
    $Script:Cache = @{}
    Prog $jobs.Count $jobs.Count 'Messe den Zustand nachher ...' 'CORE'
    $post = New-Snapshot 'nachher' $info
    $cmp = @(Get-CompareMetrics $pre $post)
    $umk = @(Get-RestorePreview $Script:RunId).Count
    [ordered]@{ Lauf = $Script:RunId; Aktionen = $jobs.Count; OK = $ok; Fehler = $fail; Abgebrochen = $abbruch; BytesGeschaetzt = $bytes; ScoreVorher = $pre.Score.Wert; ScoreNachher = $post.Score.Wert; Wiederherstellungspunkt = $rp; Umkehrbar = $umk; ComputerschutzEingeschaltet = [bool]$Script:ComputerschutzEingeschaltet } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
    $rep = New-Report
    Stop-RunLog
    [pscustomobject]@{ Status = $(if ($abbruch) { 'ABGEBROCHEN' } else { 'OK' }); RunId = $Script:RunId; Aktionen = $jobs.Count; OK = $ok; Fehler = $fail; Bytes = $bytes; Vorher = $pre; Nachher = $post; Vergleich = $cmp; Report = $rep
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
    [pscustomobject]@{ Snapshots = $snaps; Boots = @($boots | Sort-Object { [datetime]$_.Zeit }); Laeufe = (Get-RunList); Report = (Join-Path $Script:DataDir 'WinTidy-Bericht.html'); DataDir = $Script:DataDir }
}

# Wie Get-HistoryData, aber ohne die kompletten Snapshots (kleiner Datentransfer zur App)
function Get-HistoryLight {
    $scores = @(); $boots = @(); $seen = @{}
    foreach ($f in (Get-Snapshots)) {
        $s = $null; try { $s = Read-Snapshot $f } catch { continue }
        $scores += [pscustomobject]@{ Zeit = $s.Zeit; Label = $s.Label; Wert = $s.Score.Wert }
        foreach ($b in @($s.Boot.Verlauf)) { if ($b -and -not $seen.ContainsKey($b.Zeit)) { $seen[$b.Zeit] = 1; $boots += $b } }
    }
    [pscustomobject]@{ Scores = $scores; Snapshots = @(); Boots = @($boots | Sort-Object { [datetime]$_.Zeit }); Laeufe = (Get-RunList); Report = (Join-Path $Script:DataDir 'WinTidy-Bericht.html'); DataDir = $Script:DataDir }
}

function Invoke-GuiRestore([string]$Lauf) {
    $Script:RestoreRunId = $Lauf
    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Start-RunLog 'restore'
    try { $r = Invoke-Restore } finally { Stop-RunLog }
    return $r
}

# Kuehlungstest fuer die App (eigener Laufordner fuer das Protokoll)
function Invoke-GuiCoolingTest([int]$Seconds = 0, [scriptblock]$OnProgress = $null, $Control = $null) {
    if ($Seconds -le 0) { $Seconds = [int]$Script:Cfg.CoolingTestSeconds }
    $Script:RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Start-RunLog 'kuehltest'
    try { $r = Invoke-CoolingTest $Seconds $OnProgress $Control } finally { Stop-RunLog }
    return $r
}

# =============================================================================
#  Modi
# =============================================================================
function Open-Report([string]$Path) { if (-not $Path) { return }; try { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList ('"{0}"' -f $Path) } catch { try { Start-Process $Path } catch { } } }

function Show-Header {
    W ''
    W ' __      __ _        _____  _      _       ' 'Cyan'
    W ' \ \    / /(_) _ _  |_   _|(_) __ | | _  _ ' 'Cyan'
    W '  \ \/\/ / | || '' \   | |  | |/ _`| || || |' 'Cyan'
    W '   \_/\_/  |_||_||_|  |_|  |_|\__,_|\_, |' 'Cyan'
    W ("                                    |__/   v{0}" -f $Script:Version) 'Cyan'
    W ("  {0}  |  Admin: {1}  |  Daten: {2}" -f $env:COMPUTERNAME, $Script:IsAdmin, $Script:DataDir) 'DarkGray'
}

function Invoke-Mode([string]$m) {
    $Script:Cache = @{}
    if ($m -in 'Scan', 'Preview', 'Apply') {
        $Script:CliContext = $null; try { $Script:CliContext = Get-WtContext } catch { }
        $Script:LastContext = $Script:CliContext
        if ($Script:CliContext -and $Script:CliContext.Verwaltet) { W '  Firmen-PC erkannt (Domaene/Intune/Entra/ConfigMgr): nur sichere Aufraeumregeln und Hinweise.' 'DarkYellow' }
        if ($Script:DataMigrated) { W "  Daten aus der Vorversion uebernommen nach $Script:DataDir" 'DarkGray' }
    }
    switch ($m) {
        'Rules' {
            Section 'Regeln'
            foreach ($r in $Script:Rules) { W ("{0,-20} {1,-8} {2,-12} {3}{4}" -f $r.Id, $r.Risiko, $r.Kategorie, $r.Titel, $(if (-not $r.Standard) { '  (nur mit -Rule)' } elseif (-not $r.Fix) { '  (nur Bericht)' } else { '' })) $(switch ($r.Risiko) { 'Niedrig' { 'Green' } 'Mittel' { 'Yellow' } 'Hoch' { 'Red' } default { 'Cyan' } }) }
        }
        'Scan' {
            Start-RunLog 'scan'
            Section 'Scan (aendert nichts)'
            if (-not $Script:IsAdmin) { W '  Ohne Adminrechte fehlen Startzeiten und einige Pruefungen. Fuer vollstaendige Ergebnisse als Administrator starten.' 'DarkYellow' }
            $res = Invoke-Rules $false
            $snap = New-Snapshot 'scan' $res.Befunde
            Section ("Health-Score: {0}/100" -f $snap.Score.Wert)
            foreach ($z in $snap.Score.Abzuege) { W ("  -{0,-3} {1}" -f $z.Punkte, $z.Grund) 'Yellow' }
            $prev = Get-Snapshots | Select-Object -SkipLast 1 | Select-Object -Last 1
            if ($prev) { Show-Compare (Read-Snapshot $prev) $snap }
            $rep = New-Report; Stop-RunLog
            if ($OpenReport -and $rep) { Open-Report $rep }
        }
        'Preview' {
            Start-RunLog 'preview'
            Section 'Vorschau (aendert nichts)'
            $res = Invoke-Rules $false
            Section 'Zusammenfassung Vorschau'
            W ("  {0} Regeln mit Befunden, {1} Objekte, geschaetzt {2}" -f $res.Befunde.Count, (($res.Befunde | Measure-Object Anzahl -Sum).Sum), (Fmt-Bytes (($res.Befunde | Measure-Object Bytes -Sum).Sum))) 'Cyan'
            Stop-RunLog
        }
        'Apply' {
            if (-not $Script:IsAdmin) { W 'Apply braucht Adminrechte. Bitte PowerShell als Administrator starten (oder WinTidy.cmd verwenden).' 'Red'; return }
            if (-not $Script:CliContext -or $Script:CliContext.Server) { W 'Windows Server (oder Systemabfrage fehlgeschlagen): WinTidy prueft hier nur, Aenderungen sind gesperrt.' 'Red'; return }
            Start-RunLog 'apply'
            Section 'Anwenden'
            W '  Ablauf: Messung vorher -> Wiederherstellungspunkt -> Regeln (mit Rueckfragen) -> Messung nachher -> Vergleich -> Bericht' 'DarkGray'
            if ($Yes) { W ("  Unbeaufsichtigt: nur Risiko Niedrig{0}" -f $(if ($IncludeMedium) { ' und Mittel' } else { '' })) 'DarkYellow' }
            $pre = New-Snapshot 'vorher'
            try { New-RestorePoint } catch { W "  $($_.Exception.Message)" 'Red'; Stop-RunLog; return }
            $res = Invoke-Rules $true
            $Script:Cache = @{}
            $post = New-Snapshot 'nachher' $res.Befunde
            Section 'Ergebnis'
            W ("  Aktionen: {0}  |  OK: {1}  |  Fehler: {2}  |  uebersprungen: {3}  |  geschaetzt freigegeben: {4}" -f $res.Aktionen, $res.OK, $res.Fehler, $res.Uebersprungen, (Fmt-Bytes $res.Bytes)) 'Cyan'
            Show-Compare $pre $post
            [ordered]@{ Lauf = $Script:RunId; Aktionen = $res.Aktionen; OK = $res.OK; Fehler = $res.Fehler; Uebersprungen = $res.Uebersprungen; BytesGeschaetzt = $res.Bytes; ScoreVorher = $pre.Score.Wert; ScoreNachher = $post.Score.Wert } | ConvertTo-Json | Out-File (Join-Path $Script:RunDir 'zusammenfassung.json') -Encoding utf8
            $rep = New-Report
            W '  Empfehlung: PC neu starten und nach 2-3 Starts erneut "Scan" ausfuehren - erst dann zeigen die Startzeiten die Wirkung.' 'Cyan'
            Stop-RunLog
            if ($OpenReport -and $rep) { Open-Report $rep }
        }
        'Compare' {
            $s = Get-Snapshots
            if ($s.Count -lt 2) { W 'Mindestens zwei Snapshots noetig.' 'Yellow'; return }
            $a = if ($From) { $s | Where-Object { $_.Name -like "*$From*" } | Select-Object -First 1 } else { ($s | Where-Object { $_.Name -like '*_vorher.json' } | Select-Object -Last 1) }
            if (-not $a) { $a = $s[0] }
            $b = if ($To) { $s | Where-Object { $_.Name -like "*$To*" } | Select-Object -First 1 } else { $s[-1] }
            Show-Compare (Read-Snapshot $a) (Read-Snapshot $b)
        }
        'Report' { $rep = New-Report; if ($rep) { Open-Report $rep } }
        'Restore' { Start-RunLog 'restore'; $null = Invoke-Restore; Stop-RunLog }
        'Hardware' {
            Start-RunLog 'hardware'
            Section 'Hardware und Kuehlung (aendert nichts)'
            W '  Hinweis: Luefterkurven liegen im BIOS bzw. in der Firmware und sind fuer Windows nicht lesbar. WinTidy misst deren Wirkung.' 'DarkGray'
            Show-HwPoints (Get-HardwarePoints)
            foreach ($rid in 'HW-COOLPOLICY', 'HW-DISPLAY') { $r = $Script:Rules | Where-Object Id -eq $rid; try { foreach ($it in @(& $r.Detect | Where-Object { $_ })) { Show-HwPoints @([pscustomobject]@{ Stufe = $(if ($it.Data -and $it.Data.Stufe) { $it.Data.Stufe } else { 'warn' }); Text = $it.Label }) } } catch { } }
            if ($CoolingTest) {
                $sec = if ($Seconds -gt 0) { $Seconds } else { [int]$Script:Cfg.CoolingTestSeconds }
                Section ("Kuehlungstest ({0} Sekunden)" -f $sec)
                W '  Alle Prozessorkerne werden voll belastet - die Luefter werden lauter. Abbrechen mit Strg+C.' 'DarkYellow'
                $null = Invoke-CoolingTest $sec { param($i, $n, $t) Write-Progress -Activity 'Kuehlungstest' -Status $t -PercentComplete ([math]::Min(100, 100 * $i / [math]::Max(1, $n))) }
                Write-Progress -Activity 'Kuehlungstest' -Completed
            } else { W '  Tipp: -CoolingTest prueft zusaetzlich unter Last, ob die Kuehlung mithaelt.' 'DarkGray' }
            Stop-RunLog
        }
    }
}

# Als Bibliothek geladen (Dot-Sourcing durch die App): hier aufhoeren
if ($MyInvocation.InvocationName -eq '.') { return }

Show-Header
if ($Mode -ne 'Menu') { Invoke-Mode $Mode; return }
while ($true) {
    W ''
    W '  [1] Scan        - messen und pruefen, Bericht erzeugen (aendert nichts)' 'White'
    W '  [2] Vorschau    - zeigen, was "Anwenden" tun wuerde' 'White'
    W '  [3] Anwenden    - interaktiv, mit Wiederherstellungspunkt' 'White'
    W '  [4] Vergleich   - letzter "vorher"-Snapshot gegen den neuesten' 'White'
    W '  [5] Bericht     - HTML-Bericht oeffnen' 'White'
    W '  [6] Regeln      - alle Regeln anzeigen' 'White'
    W '  [7] Wiederherstellen' 'White'
    W '  [8] Tiefen-Scan - inkl. Dateisystem-/Integritaetspruefung (langsam)' 'White'
    W '  [9] Hardware    - Kuehlung, Luefter, Temperaturen; optional Kuehlungstest' 'White'
    W '  [0] Beenden' 'White'
    $c = Read-Host '  Auswahl'
    switch ($c) {
        '1' { Invoke-Mode 'Scan' } '2' { Invoke-Mode 'Preview' } '3' { Invoke-Mode 'Apply' } '4' { Invoke-Mode 'Compare' }
        '5' { Invoke-Mode 'Report' } '6' { Invoke-Mode 'Rules' } '7' { Invoke-Mode 'Restore' }
        '8' { $Deep = $true; Invoke-Mode 'Scan'; $Deep = $false }
        '9' { $a = Read-Host '  Zusaetzlich Kuehlungstest (ca. 1 Minute Volllast, Luefter werden laut)? [j/N]'; $CoolingTest = ($a -match '^(j|ja|y)$'); Invoke-Mode 'Hardware'; $CoolingTest = $false }
        '0' { return }
    }
}
