# Test-Rules.ps1 - checks the rule changes of 1.9 without Windows: unattended mode (-Yes) fails closed, whole-word
# matching of heavy startup entries, blue screen dumps are kept, ghost devices only after the waiting time, parallel
# main versions are marked, quarantine instead of deleting, new checks (antivirus exclusions, hosts file, BitLocker paused,
# restart, profile folders), score deductions and configuration limits. Usage: pwsh ./tests/Test-Rules.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-rulestest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|QuarantineSuffix|AppNames|DeviceClassNames)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:Rules = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match "^\[pscustomobject\]@\{ Id = '[A-Z]+-[A-Z0-9-]+'; Kategorie" }, $true) | ForEach-Object { & ([scriptblock]::Create($_.Extent.Text)) })
$Script:Cfg = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $Script:Cfg[$k] = $Script:DefaultConfig[$k] }
$Script:DataDir = $TestData; $Script:RunsDir = Join-Path $TestData 'runs'; $Script:RunDir = $null
$Script:Cache = @{}; $Script:IsAdmin = $false; $Script:RunId = '20261028-120000'

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }
function Rule([string]$Id) { $Script:Rules | Where-Object Id -eq $Id }
function Item($AutoOk) { $i = [pscustomobject]@{ Label = 'x'; Bytes = 0; Data = $null }; if ($null -ne $AutoOk) { $i | Add-Member -NotePropertyName AutoOk -NotePropertyValue $AutoOk }; $i }
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
# robocopy only exists on Windows
function Get-DirSize([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }; $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($s) { [int64]$s } else { [int64]0 } }
$Script:Records = New-Object System.Collections.Generic.List[object]
function Add-ActionRecord { param($Regel, $Objekt, $Status, $Bytes, $Msg, $Undo) $Script:Records.Add([pscustomobject]@{ Regel = $Regel; Objekt = $Objekt; Status = $Status; Undo = $Undo }); $true }

# 1) Rule catalog
$ids = @($Script:Rules | ForEach-Object Id)
Check 'Rules loaded' ($ids.Count -ge 45) $ids.Count
Check 'Rule ids are unique' (@($ids | Select-Object -Unique).Count -eq $ids.Count)
Check 'APP-BLOAT is gone (now part of the Debloat page)' ($ids -notcontains 'APP-BLOAT')
$neu = 'CLN-QUARANTINE', 'CLN-DRIVERINSTALL', 'CLN-PROFILE-ORPHAN', 'SYS-REBOOT'
Check 'New rules exist' (@($neu | Where-Object { $ids -notcontains $_ }).Count -eq 0)
$ohne = @($Script:Rules | Where-Object { -not $_.Seite -and -not $Script:Friendly.ContainsKey($_.Id) } | ForEach-Object Id)
Check 'Every rule of the normal check has a plain-language text' ($ohne.Count -eq 0) ($ohne -join ', ')
Check 'Risk values are valid' (@($Script:Rules | Where-Object { $_.Risiko -notin 'Niedrig', 'Mittel', 'Hoch', 'Info' }).Count -eq 0)
Check 'Info rules have no fix' (@($Script:Rules | Where-Object { $_.Risiko -eq 'Info' -and $_.Fix }).Count -eq 0)

# 2) Unattended (-Yes) fails closed
$lo = [pscustomobject]@{ Risiko = 'Niedrig' }; $mi = [pscustomobject]@{ Risiko = 'Mittel' }; $hi = [pscustomobject]@{ Risiko = 'Hoch' }
Check 'Low without AutoOk: unattended' (Test-UnattendedItem $lo (Item $null))
Check 'Low with AutoOk = false: not unattended' (-not (Test-UnattendedItem $lo (Item $false)))
Check 'Medium without AutoOk: NOT unattended (fail closed)' (-not (Test-UnattendedItem $mi (Item $null)))
Check 'Medium with AutoOk = true: unattended' (Test-UnattendedItem $mi (Item $true))
Check 'High: never unattended' (-not (Test-UnattendedItem $hi (Item $true)))

# 3) Whole-word matching of heavy startup programs
Check 'Teams hits "Microsoft Teams"' (Test-WordMatch 'Microsoft Teams ms-teams.exe' 'Teams')
Check 'Teams does not hit TeamSpeak' (-not (Test-WordMatch 'TeamSpeak 3 Client' 'Teams'))
Check 'Zoom does not hit ZoomIt' (-not (Test-WordMatch 'ZoomIt64.exe Sysinternals' 'Zoom'))
Check 'msedge hits the path of msedge.exe' (Test-WordMatch 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' 'msedge')
$Script:Cfg.HeavyStartup = @('Teams', 'Spotify'); $Script:Cfg.ProtectedStartup = @('OneDrive')
function Get-StartupItems { @(
    [pscustomobject]@{ Name = 'TeamSpeak'; Ziel = ''; Aktiv = $true; Zustand = 'ok'; DegradationMs = 0; Art = 'Registry'; Ort = 'HKCU Run' },
    [pscustomobject]@{ Name = 'Teams'; Ziel = ''; Aktiv = $true; Zustand = 'ok'; DegradationMs = 0; Art = 'Registry'; Ort = 'HKCU Run' },
    [pscustomobject]@{ Name = 'OneDrive Teams'; Ziel = ''; Aktiv = $true; Zustand = 'ok'; DegradationMs = 0; Art = 'Registry'; Ort = 'HKCU Run' }) }
$st = @(& (Rule 'STA-HEAVY').Detect)
Check 'STA-HEAVY: Teams preselected, TeamSpeak not, protected entry hidden' ($st.Count -eq 2 -and ($st | Where-Object { $_.Data.Name -eq 'Teams' }).AutoOk -and -not ($st | Where-Object { $_.Data.Name -eq 'TeamSpeak' }).AutoOk) (($st | ForEach-Object { "$($_.Data.Name)=$($_.AutoOk)" }) -join ' ')

# 4) Blue screen dumps are kept (category choice at the time of the fix)
$Script:Kat = @()
function Invoke-CleanMgr([string[]]$Categories) { $Script:Kat = $Categories; $Categories.Count }
$Script:Recent = $true
function Test-RecentSystemDumps([int]$Days) { $Script:Recent }
$null = & (Rule 'CLN-WINCLEAN').Fix ([pscustomobject]@{ Data = @{ DumpsBehalten = $false } })
Check 'Recent blue screen: dump categories are not cleaned' (-not ($Script:Kat | Where-Object { $_ -match 'dump' }) -and $Script:Kat -contains 'Update Cleanup')
$Script:Recent = $false
$null = & (Rule 'CLN-WINCLEAN').Fix ([pscustomobject]@{ Data = @{ DumpsBehalten = $false } })
Check 'No recent blue screen: dumps are cleaned' (@($Script:Kat | Where-Object { $_ -match 'dump' }).Count -eq 2)
$null = & (Rule 'CLN-WINCLEAN').Fix ([pscustomobject]@{ Data = @{ DumpsBehalten = $true } })
Check 'Scan said "keep": kept even if the dumps aged since' (-not ($Script:Kat | Where-Object { $_ -match 'dump' }))

# 5) Ghost devices only after the waiting time, unknown age is not offered
function Get-GhostDevices { @(
    [pscustomobject]@{ InstanceId = 'USB\OLD'; Class = 'MEDIA'; FriendlyName = 'Old audio' },
    [pscustomobject]@{ InstanceId = 'USB\RECENT'; Class = 'MEDIA'; FriendlyName = 'Audio interface' },
    [pscustomobject]@{ InstanceId = 'USB\UNKNOWN'; Class = 'USB'; FriendlyName = 'Unknown' }) }
function Get-DeviceLastSeen([string[]]$InstanceIds) { @{ 'USB\OLD' = (Get-Date).AddDays(-200); 'USB\RECENT' = (Get-Date).AddDays(-10) } }
$gh = @(& (Rule 'SYS-GHOST').Detect)
Check 'SYS-GHOST: only the device unseen for 200 days' ($gh.Count -eq 1 -and @($gh[0].Data).Count -eq 1 -and @($gh[0].Data)[0] -eq 'USB\OLD') (($gh | ForEach-Object { $_.Data }) -join ',')

# 6) Parallel main versions are marked, nothing unattended
function Get-InstalledApps { @(
    [pscustomobject]@{ DisplayName = 'DaVinci Resolve'; DisplayVersion = '18.6.6'; Publisher = 'Blackmagic Design'; UninstallString = 'x.exe'; EstimatedSize = 1000; PSPath = 'HKEY_LOCAL_MACHINE' },
    [pscustomobject]@{ DisplayName = 'DaVinci Resolve'; DisplayVersion = '19.0.3'; Publisher = 'Blackmagic Design'; UninstallString = 'x.exe'; EstimatedSize = 1000; PSPath = 'HKEY_LOCAL_MACHINE' },
    [pscustomobject]@{ DisplayName = 'rekordbox 6.7.4'; DisplayVersion = '6.7.4'; Publisher = 'AlphaTheta'; UninstallString = 'y.exe'; EstimatedSize = 10; PSPath = 'HKEY_LOCAL_MACHINE' },
    [pscustomobject]@{ DisplayName = 'rekordbox 6.8.0'; DisplayVersion = '6.8.0'; Publisher = 'AlphaTheta'; UninstallString = 'y.exe'; EstimatedSize = 10; PSPath = 'HKEY_LOCAL_MACHINE' }) }
$sb = @(& (Rule 'APP-SIDEBYSIDE').Detect)
$dv = $sb | Where-Object { $_.Label -like 'DaVinci*' }; $rb = $sb | Where-Object { $_.Label -like 'rekordbox*' }
Check 'APP-SIDEBYSIDE: DaVinci 18 next to 19 is marked as a different main version' ($dv -and $dv.Label -match 'different main version') $dv.Label
Check 'APP-SIDEBYSIDE: rekordbox 6.7 next to 6.8 is not marked' ($rb -and $rb.Label -notmatch 'different main version') $rb.Label
Check 'APP-SIDEBYSIDE: never unattended' (@($sb | Where-Object { Test-UnattendedItem (Rule 'APP-SIDEBYSIDE') $_ }).Count -eq 0)

# 7) Quarantine instead of deleting (CLN-ORPHANDIR / CLN-QUARANTINE)
$env:LOCALAPPDATA = Join-Path $TestData 'Local'; $env:APPDATA = Join-Path $TestData 'Roaming'; $env:ProgramData = Join-Path $TestData 'PD'
$env:ProgramFiles = Join-Path $TestData 'PF'; ${env:ProgramFiles(x86)} = Join-Path $TestData 'PF86'
foreach ($d in $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:ProgramFiles) { New-Item -ItemType Directory -Force $d | Out-Null }
$orphan = Join-Path $env:LOCALAPPDATA 'OldTool'; New-Item -ItemType Directory -Force $orphan | Out-Null; Set-Content (Join-Path $orphan 'settings.ini') 'x'
$ziel = Move-ToQuarantine 'CLN-ORPHANDIR' $orphan
Check 'Folder is renamed in place, contents kept' (-not (Test-Path $orphan) -and (Test-Path (Join-Path $ziel 'settings.ini')) -and (Split-Path $ziel) -eq $env:LOCALAPPDATA) $ziel
Check 'Undo record: type folder with source and target' ($Script:Records[-1].Undo.Typ -eq 'Ordner' -and $Script:Records[-1].Undo.Ziel -eq $orphan -and $Script:Records[-1].Undo.Quelle -eq $ziel)
Check 'Quarantine path is recognised' (Test-QuarantinePath $ziel)
Check 'Foreign paths are not quarantine paths' (-not (Test-QuarantinePath $orphan) -and -not (Test-QuarantinePath (Join-Path $TestData ('x' + $Script:QuarantineSuffix + '20260101'))))
$tief = Join-Path $env:LOCALAPPDATA 'Sub\Deep'; New-Item -ItemType Directory -Force $tief | Out-Null
$err = $null; try { $null = Move-ToQuarantine 'CLN-ORPHANDIR' $tief } catch { $err = $_.Exception.Message }
Check 'Only folders directly in Program Files/ProgramData/AppData are set aside' ($err -and (Test-Path $tief))
$q = @(& (Rule 'CLN-QUARANTINE').Detect)
Check 'CLN-QUARANTINE: freshly set aside folder is not offered yet' ($q.Count -eq 0)
$alt = Join-Path $env:ProgramData ('Gone' + $Script:QuarantineSuffix + (Get-Date).AddDays(-40).ToString('yyyyMMdd')); New-Item -ItemType Directory -Force $alt | Out-Null
$q = @(& (Rule 'CLN-QUARANTINE').Detect)
Check 'CLN-QUARANTINE: folder older than QuarantineDays is offered' ($q.Count -eq 1 -and $q[0].Data -eq $alt -and $q[0].Label -like 'Gone*') (($q | ForEach-Object Label) -join ' | ')
function Test-SafeDeleteRoot([string]$Path) { $true }
function Remove-TreeNoFollow([string]$Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
$null = & (Rule 'CLN-QUARANTINE').Fix $q[0]
Check 'CLN-QUARANTINE: deletes it' (-not (Test-Path $alt))
$err = $null; try { $null = & (Rule 'CLN-QUARANTINE').Fix ([pscustomobject]@{ Data = $orphan }) } catch { $err = $_.Exception.Message }
Check 'CLN-QUARANTINE refuses other paths' ($err -and (Test-Path (Split-Path $orphan)))

# 8) Antivirus exclusions, hosts file
$env:SystemDrive = 'C:'; $env:windir = 'C:\Windows'; $env:USERPROFILE = 'C:\Users\nico'; $env:TEMP = 'C:\Users\nico\AppData\Local\Temp'
$ex = [pscustomobject]@{ Pfade = @('C:\', 'C:\Users\nico\Downloads\', '%TEMP%', 'C:\Program Files\SomeDaw'); Endungen = @('.exe', 'psd'); Prozesse = @('powershell.exe', 'Resolve.exe') }
$br = @(Get-BroadDefenderExclusions $ex)
Check 'Broad exclusions: drive, Downloads, TEMP, .exe, powershell.exe' ((@($br | Where-Object Art -eq 'Pfad').Count -eq 3) -and (@($br | Where-Object Art -eq 'Endung').Count -eq 1) -and (@($br | Where-Object Art -eq 'Prozess').Count -eq 1)) (($br | ForEach-Object { "$($_.Art):$($_.Wert)" }) -join ' ')
Check 'A single program folder is not reported' (-not ($br | Where-Object { $_.Wert -like '*SomeDaw*' }))
Check 'No exclusions readable: nothing reported' (@(Get-BroadDefenderExclusions $null).Count -eq 0)
$hosts = @('# 0.0.0.0 windowsupdate.com', '127.0.0.1 localhost', '0.0.0.0 download.windowsupdate.com', '0.0.0.0 fe3.delivery.mp.microsoft.com # blocked', '0.0.0.0 vortex.data.microsoft.com', '0.0.0.0 mywindowsupdate.com.example')
$hb = @(Select-HostsUpdateBlocks $hosts)
Check 'hosts: two update blocks, comments and telemetry hosts ignored' ($hb.Count -eq 2) ($hb -join ' | ')

# 9) BitLocker paused only until the next restart (e.g. BIOS update) is no warning
$Script:BL = 'Ausgesetzt'; $Script:BLN = 1
function Get-BitLockerState { $Script:BL }
function Get-BitLockerSuspendCount { $Script:BLN }
function Get-TpmState { $null }
function Get-MemoryIntegrityState { $null }
function Get-OtherSecurityProducts([string]$Class) { @() }
function Get-DefenderTamperState { $null }
$sh = @(& (Rule 'SEC-HEALTH').Detect)
Check 'BitLocker paused for one restart: hint, no warning' ($sh.Count -eq 1 -and $sh[0].Data.Stufe -eq '')
$Script:BLN = 0
Check 'BitLocker paused until someone resumes it: warning' ((@(& (Rule 'SEC-HEALTH').Detect))[0].Data.Stufe -eq 'warn')
$Script:BLN = $null
Check 'Restart count unknown: warning as before' ((@(& (Rule 'SEC-HEALTH').Detect))[0].Data.Stufe -eq 'warn')

# 10) Restart pending, profile folders of deleted accounts
$Script:Boot = (Get-Date).AddDays(-12); $Script:Pending = $true
function Get-CimInstance { param([string]$ClassName, $Filter, $ErrorAction) if ($ClassName -eq 'Win32_OperatingSystem') { [pscustomobject]@{ LastBootUpTime = $Script:Boot } } }
function Test-RebootPending { $Script:Pending }
$rb = @(& (Rule 'SYS-REBOOT').Detect)
Check 'Restart pending for 12 days: warning' ($rb.Count -eq 1 -and $rb[0].Data.Stufe -eq 'warn')
$Script:Boot = (Get-Date).AddDays(-2)
Check 'Restarted 2 days ago: nothing' (@(& (Rule 'SYS-REBOOT').Detect).Count -eq 0)
$Script:Prof = $null
function Get-OrphanProfileDirs { $Script:Prof }
function Get-DirSize([string]$Path) { [int64]5GB }
Check 'Profile list unreadable: nothing shown (fail closed)' (@(& (Rule 'CLN-PROFILE-ORPHAN').Detect).Count -eq 0)
$Script:Prof = @([pscustomobject]@{ FullName = 'C:\Users\olduser' })
$po = @(& (Rule 'CLN-PROFILE-ORPHAN').Detect)
Check 'Orphaned profile folder: only shown, no bytes counted as freed' ($po.Count -eq 1 -and $po[0].Bytes -eq 0 -and $null -eq (Rule 'CLN-PROFILE-ORPHAN').Fix)

# 11) Score and configuration
$snap = [pscustomobject]@{ Laufwerke = @(); Boot = [pscustomobject]@{ Mittel5 = $null }; Autostart = [pscustomobject]@{ Aktiv = 0; Verwaist = 0 }; Ereignisse = [pscustomobject]@{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = [pscustomobject]@{ Duplikate = 0; Geistergeraete = 0 }; Speicher = [pscustomobject]@{ PapierkorbBytes = 0 }; Stabilitaet = [pscustomobject]@{ Warnsignale = @() }; Zeit = (Get-Date).ToString('o')
    Sicherheit = [pscustomobject]@{ SecureBoot = $false; DefenderEchtzeit = $true; AndererVirenschutz = $false; AusfuehrungsrichtlinieCU = 'RemoteSigned'; UacAus = $true; FirewallProfileAus = 2 } }
$sc = Get-HealthScore $snap
Check 'Score: UAC off -8, firewall off -10, Secure Boot off -4' ($sc.Wert -eq 78) (($sc.Abzuege | ForEach-Object { "$($_.Punkte) $($_.Grund)" }) -join '; ')
$snap.Sicherheit = [pscustomobject]@{ SecureBoot = $true; DefenderEchtzeit = $true; AusfuehrungsrichtlinieCU = 'RemoteSigned' }
Check 'Old snapshots without the new fields: no deduction' ((Get-HealthScore $snap).Wert -eq 100)
$c = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $c[$k] = $Script:DefaultConfig[$k] }
$c.GhostDeviceMinDays = 5; $c.QuarantineDays = 1; $c.SystemDumpKeepDays = 0; $c.DriverInstallerDirs = @('C:\', '%SystemDrive%', 'relative\path', 'C:\AMD')
$c = Test-Config $c 3>$null
Check 'Test-Config: too small waiting times fall back to the default' ($c.GhostDeviceMinDays -eq 90 -and $c.QuarantineDays -eq 30 -and $c.SystemDumpKeepDays -eq 30)
Check 'Test-Config: drive roots and relative paths are no driver installer folders' (@($c.DriverInstallerDirs).Count -eq 1 -and @($c.DriverInstallerDirs)[0] -eq 'C:\AMD') (@($c.DriverInstallerDirs) -join ' | ')
Check 'No personal defaults: WingetExclude and BloatApps are empty' (@($Script:DefaultConfig.WingetExclude).Count -eq 0 -and @($Script:DefaultConfig.BloatApps).Count -eq 0)

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All rule tests passed' -ForegroundColor Green }
