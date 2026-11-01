# Test-Policies.ps1 - checks the policy analysis of version 1.13 (CSV export since 1.14) (GPO/Intune, -Mode Policies, app page "Policies"):
# RSoP parser, duplicates and conflicts per GPO pair, GPOs without own effect, multiple links, processing times from the
# event log (startup, sign-in, background, per extension), slowdown patterns, Intune/MDM overlaps, report (EN/DE),
# GUI API and that the section never changes anything. gpresult, the event log and the registry are replaced.
# Usage: pwsh ./tests/Test-Policies.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-policytest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null
$src = Join-Path $root 'WinTidy.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:DataDir = $TestData; $Script:Cache = @{}; $Script:IsAdmin = $true; $Script:Version = '1.13.0'; $Script:Cfg = $null

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { $Script:Out += $Text }
function Section([string]$t) { $Script:Out += $t }
function Write-Progress { }
function Get-WtContext { $Script:Ctx }
$Script:Ctx = [pscustomobject]@{ Domaene = $true; Intune = $true; EntraJoin = $true; ConfigMgr = $false; AnderesKonto = $false; ProzessBenutzer = 'CONTOSO\admin'; SitzungsBenutzer = 'CONTOSO\admin' }

# --- fake registry (HKLM, keys case-insensitive like the real one) ---
$Script:Reg = @{}
function Reg([string]$Path, [hashtable]$Values) { $Script:Reg[$Path] = $Values }
function Get-PolicyRegValues([string]$Path) {
    foreach ($k in $Script:Reg.Keys) { if ($k -ieq $Path) { $h = [ordered]@{}; foreach ($n in $Script:Reg[$k].Keys) { $h[$n] = $Script:Reg[$k][$n] }; return $h } }
    foreach ($k in $Script:Reg.Keys) { if ($k.StartsWith($Path + '\', [StringComparison]::OrdinalIgnoreCase)) { return [ordered]@{} } }
    return $null
}
function Get-PolicyRegSubKeys([string]$Path) {
    $p = $Path + '\'
    @($Script:Reg.Keys | Where-Object { $_.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.Substring($p.Length).Split('\')[0] } | Sort-Object -Unique)
}

# --- synthetic gpresult XML ---
$T = 'http://www.microsoft.com/GroupPolicy/Types'
function GpoXml([string]$Name, [string]$Id, [string[]]$Soms, [string]$Allowed = 'true', [string]$Wmi = '') {
    $l = ''; $i = 1; foreach ($s in $Soms) { $l += "<Link><SOMPath>$s</SOMPath><SOMOrder>$i</SOMOrder><AppliedOrder>$i</AppliedOrder><LinkOrder>$i</LinkOrder><Enabled>true</Enabled><NoOverride>false</NoOverride></Link>"; $i++ }
    $w = if ($Wmi) { "<FilterName>$Wmi</FilterName>" } else { '' }
    "<GPO><Name>$([Security.SecurityElement]::Escape($Name))</Name><Path><Identifier xmlns='$T'>$Id</Identifier><Domain xmlns='$T'>contoso.com</Domain></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>$Allowed</FilterAllowed><AccessDenied>false</AccessDenied>$w$l<ExtensionName>Registry</ExtensionName></GPO>"
}
function Ref([string]$Id, [int]$Prec) { "<GPO xmlns='http://www.microsoft.com/GroupPolicy/Rsop'><Identifier xmlns='$T'>$Id</Identifier><Domain xmlns='$T'>contoso.com</Domain></GPO><Precedence xmlns='http://www.microsoft.com/GroupPolicy/Rsop'>$Prec</Precedence>" }
function Pol([string]$Id, [int]$Prec, [string]$Name, [string]$State, [string]$Cat = 'Windows Components/Test') { "<q1:Policy>$(Ref $Id $Prec)<q1:Name>$Name</q1:Name><q1:State>$State</q1:State><q1:Explain>Long text $Prec</q1:Explain><q1:Supported>Windows 10</q1:Supported><q1:Category>$Cat</q1:Category></q1:Policy>" }
function ExtStatus([string]$Name, [string]$Id, [double]$Sec) { "<ExtensionStatus><Name>$Name</Name><Identifier>$Id</Identifier><BeginTime>2026-11-01T08:00:00</BeginTime><EndTime>$(([datetime]'2026-11-01T08:00:00').AddSeconds($Sec).ToString('s'))</EndTime><LoggingStatus>Complete</LoggingStatus><Error>0</Error></ExtensionStatus>" }
$gA = '{AAAAAAAA-0000-0000-0000-000000000001}'; $gB = '{BBBBBBBB-0000-0000-0000-000000000002}'; $gC = '{CCCCCCCC-0000-0000-0000-000000000003}'; $gD = '{DDDDDDDD-0000-0000-0000-000000000004}'; $gFx = '{FFFFFFFF-0000-0000-0000-000000000005}'
$gREG = '{35378EAC-683F-11D2-A89A-00C04FBBCFA2}'; $gSI = '{C6DC5466-785A-11D2-84D0-00C04FB169F7}'; $gSCR = '{42B5FAAE-6536-11D2-AE5A-0000F87571E3}'; $gDRV = '{5794dafd-be60-433f-88a2-1a31939ac01f}'; $gSEC = '{827D319E-6EAC-11D2-A4EA-00C04F79F83A}'
$xmlText = @"
<?xml version="1.0" encoding="utf-16"?>
<Rsop xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://www.microsoft.com/GroupPolicy/Rsop">
<ComputerResults>
<Name>CONTOSO\PC01$</Name><SlowLink>false</SlowLink>
$(GpoXml 'Client Baseline' $gA @('contoso.com/Clients'))
$(GpoXml 'Old Baseline & Co' $gB @('contoso.com/Clients', 'contoso.com/Clients/Laptops'))
$(GpoXml 'Filtered GPO' $gFx @('contoso.com/Clients') 'false')
$(GpoXml 'Software' $gD @('contoso.com/Clients') 'true' 'Only laptops')
$(ExtStatus 'Registry' $gREG 2)
$(ExtStatus 'Software Installation' $gSI 30)
$(ExtStatus 'Scripts' $gSCR 1)
$(ExtStatus 'Security' $gSEC 1)
<ExtensionData><Extension xmlns:q1="http://www.microsoft.com/GroupPolicy/Settings/Registry" xsi:type="q1:RegistrySettings">
$(Pol $gA 1 'Turn off Windows Copilot' 'Enabled')
$(Pol $gB 2 'Turn off Windows Copilot' 'Enabled')
$(Pol $gB 3 'Turn off Windows Copilot' 'Enabled')
$(Pol $gA 1 'Configure Automatic Updates' 'Enabled' 'Windows Components/Windows Update')
$(Pol $gB 2 'Configure Automatic Updates' 'Disabled' 'Windows Components/Windows Update')
$(Pol $gA 1 'Only in client baseline' 'Enabled')
<q1:RegistrySetting>$(Ref $gA 1)<q1:KeyPath>Software\Contoso</q1:KeyPath><q1:Value><q1:Name>Alpha</q1:Name><q1:Number>1</q1:Number></q1:Value></q1:RegistrySetting>
<q1:RegistrySetting>$(Ref $gA 1)<q1:KeyPath>Software\Contoso</q1:KeyPath><q1:Value><q1:Name>Beta</q1:Name><q1:Number>2</q1:Number></q1:Value></q1:RegistrySetting>
</Extension><Name>Registry</Name></ExtensionData>
<ExtensionData><Extension xmlns:q2="http://www.microsoft.com/GroupPolicy/Settings/Scripts" xsi:type="q2:Scripts">
<q2:Script>$(Ref $gA 1)<q2:Command>\\contoso.com\netlogon\inventory.cmd</q2:Command><q2:Parameters /><q2:Type>Startup</q2:Type><q2:Order>0</q2:Order><q2:RunOrder>PSNotConfigured</q2:RunOrder></q2:Script>
</Extension><Name>Scripts</Name></ExtensionData>
<ExtensionData><Extension xmlns:q3="http://www.microsoft.com/GroupPolicy/Settings/SoftwareInstallation" xsi:type="q3:SoftwareInstallationSettings">
<q3:MsiApplication>$(Ref $gD 1)<q3:Name>7-Zip</q3:Name><q3:Path>\\contoso.com\apps\7z.msi</q3:Path><q3:DeploymentType>Assign</q3:DeploymentType></q3:MsiApplication>
</Extension><Name>Software Installation</Name></ExtensionData>
<ExtensionData><Extension xmlns:q4="http://www.microsoft.com/GroupPolicy/Settings/Security" xsi:type="q4:SecuritySettings">
<q4:Account>$(Ref $gA 1)<q4:Name>MinimumPasswordLength</q4:Name><q4:SettingNumber>12</q4:SettingNumber><q4:Type>Password</q4:Type></q4:Account>
<q4:Account>$(Ref $gB 2)<q4:Name>MinimumPasswordLength</q4:Name><q4:SettingNumber>8</q4:SettingNumber><q4:Type>Password</q4:Type></q4:Account>
</Extension><Name>Security</Name></ExtensionData>
</ComputerResults>
<UserResults>
<SlowLink>true</SlowLink>
$(GpoXml 'User Drives' $gC @('contoso.com/Users'))
$(ExtStatus 'Group Policy Drive Maps' $gDRV 4)
$(ExtStatus 'Scripts' $gSCR 1)
<ExtensionData><Extension xmlns:q5="http://www.microsoft.com/GroupPolicy/Settings/DriveMaps" xsi:type="q5:DriveMapSettings">
<q5:DriveMapSettings><q5:Drive name="H:" uid="{1}" changed="2026-01-01">$(Ref $gC 1)<q5:Properties action="R" letter="H" path="\\srv\home" /></q5:Drive></q5:DriveMapSettings>
</Extension><Name>Group Policy Drive Maps</Name></ExtensionData>
<ExtensionData><Extension xmlns:q2="http://www.microsoft.com/GroupPolicy/Settings/Scripts" xsi:type="q2:Scripts">
<q2:Script>$(Ref $gC 1)<q2:Command>logon1.cmd</q2:Command><q2:Type>Logon</q2:Type></q2:Script>
<q2:Script>$(Ref $gC 1)<q2:Command>logon2.cmd</q2:Command><q2:Type>Logon</q2:Type></q2:Script>
<q2:Script>$(Ref $gC 1)<q2:Command>logon3.cmd</q2:Command><q2:Type>Logon</q2:Type></q2:Script>
</Extension><Name>Scripts</Name></ExtensionData>
</UserResults>
</Rsop>
"@

# --- 1) parser ---
$parts = @(ConvertFrom-GpRsop $xmlText)
$cp = $parts | Where-Object Bereich -eq 'Computer'; $up = $parts | Where-Object Bereich -eq 'Benutzer'
Check 'Parser: computer and user part' ($parts.Count -eq 2 -and $cp -and $up)
Check 'Parser: 4 GPOs in the computer part, the filtered one not applied' (@($cp.Gpos).Count -eq 4 -and -not ($cp.Gpos | Where-Object Name -eq 'Filtered GPO').Wirksam -and ($cp.Gpos | Where-Object Name -eq 'Client Baseline').Wirksam)
Check 'Parser: GPO with two applied links has two places' (@(($cp.Gpos | Where-Object Name -eq 'Old Baseline & Co').Orte).Count -eq 2)
Check 'Parser: WMI filter is read' (($cp.Gpos | Where-Object Name -eq 'Software').WmiFilter -eq 'Only laptops')
Check 'Parser: extension status with duration' ((($cp.Erweiterungen | Where-Object Id -eq $gSI).Ms) -eq 30000)
Check 'Parser: GUIDs are normalized ({lowercase} -> {UPPERCASE})' (@($up.Erweiterungen | Where-Object { $_.Id -ceq $gDRV.ToUpper() }).Count -eq 1)
Check 'Parser: settings with GPO and precedence' (@($cp.Einstellungen).Count -eq 12) (@($cp.Einstellungen).Count)
$ra = @($cp.Einstellungen | Where-Object { $_.Art -eq 'RegistrySetting' })
Check 'Parser: two registry values under one key are two settings' ($ra.Count -eq 2 -and $ra[0].Schluessel -ne $ra[1].Schluessel)
Check 'Parser: explain texts do not count as value' ((@($cp.Einstellungen | Where-Object { $_.Anzeige -like '*Copilot' }) | Select-Object -ExpandProperty Wert | Select-Object -Unique).Count -eq 1)
Check 'Parser: label with category' (@($cp.Einstellungen | Where-Object { $_.Anzeige -eq 'Windows Components/Test / Turn off Windows Copilot' }).Count -ge 1)
Check 'Parser: drive map uid/changed do not count' ((@($up.Einstellungen | Where-Object Art -eq 'Drive')[0].Wert) -notmatch 'uid|changed')
$bad = $null; try { $null = ConvertFrom-GpRsop '<Rsop><broken' } catch { $bad = $_ }
Check 'Parser: broken XML throws (the analysis turns it into a hint)' ($null -ne $bad)
$dtd = $null; try { $dtd = ConvertFrom-GpRsop '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/hostname">]><Rsop><ComputerResults><GPO><Name>&x;</Name><Path><Identifier>{1}</Identifier></Path></GPO></ComputerResults></Rsop>' } catch { }
Check 'Parser: external entities are not resolved' (-not $dtd -or -not (@($dtd[0].Gpos)[0].Name))

# --- 2) duplicates and conflicts ---
$ov = @(Find-GpOverlaps $parts)
$dup = @($ov | Where-Object { $_.Art -eq 'Doppelt' -and $_.Schluessel -like 'dup:*' })
$con = @($ov | Where-Object { $_.Art -eq 'Konflikt' })
Check 'Duplicates: one finding per GPO pair' ($dup.Count -eq 1 -and $dup[0].Schluessel -eq "dup:$gA`:$gB" -and @($dup[0].Details).Count -eq 1)
Check 'Duplicates: a GPO linked twice does not count as its own duplicate' (@($dup[0].Details).Count -eq 1)
Check 'Conflicts: one finding per pair, with both values' ($con.Count -eq 1 -and @($con[0].Details).Count -eq 2 -and ($con[0].Details -join ' ') -match 'Disabled' -and ($con[0].Details -join ' ') -match '"12"')
Check 'Conflicts: winner first in the GPO list' ($con[0].Gpos[0] -eq 'Client Baseline' -and $con[0].Gpos[1] -eq 'Old Baseline & Co')
$noeff = @($ov | Where-Object Schluessel -eq "noeffect:$gB")
Check 'GPO without own effect is found' ($noeff.Count -eq 1 -and $noeff[0].Stufe -eq 'warn')
Check 'GPO with own settings is not "without effect"' (-not ($ov | Where-Object Schluessel -eq "noeffect:$gA"))
Check 'GPO linked twice is reported with both places' (@($ov | Where-Object { $_.Schluessel -eq "multilink:$gB" -and @($_.Details).Count -eq 2 }).Count -eq 1)
Check 'Counts per GPO' (($cp.Gpos | Where-Object Id -eq $gB).Doppelt -eq 1 -and ($cp.Gpos | Where-Object Id -eq $gB).Ueberstimmt -eq 2 -and ($cp.Gpos | Where-Object Id -eq $gA).Gewinnt -eq 7)

# --- 3) processing times ---
function Ev([int]$Id, [string]$Act, [hashtable]$gD) { [pscustomobject]@{ Id = $Id; Zeit = (Get-Date).AddMinutes(- $Script:EvN++).ToString('o'); Aktivitaet = $Act; Daten = $gD } }
$Script:EvN = 1
$events = @(
    (Ev 8000 'a1' @{ PolicyElaspedTimeInSeconds = '50' }), (Ev 5016 'a1' @{ CSEExtensionId = $gSI.ToLower(); CSEExtensionName = 'Software Installation'; CSEElaspedTimeInMilliSeconds = '30000' }), (Ev 5016 'a1' @{ CSEExtensionId = $gREG; CSEExtensionName = 'Registry'; CSEElaspedTimeInMilliSeconds = '800' })
    (Ev 8000 'a2' @{ PolicyElaspedTimeInSeconds = '40' }), (Ev 5016 'a2' @{ CSEExtensionId = $gSI; CSEExtensionName = 'Software Installation'; CSEElaspedTimeInMilliSeconds = '25000' })
    (Ev 8001 'a3' @{ PolicyElaspedTimeInSeconds = '8' }), (Ev 5016 'a3' @{ CSEExtensionId = $gSCR; CSEExtensionName = 'Scripts'; CSEElaspedTimeInMilliSeconds = '1200' })
    (Ev 8006 'b1' @{ PolicyElaspedTimeInSeconds = '3' }), (Ev 7016 'b1' @{ CSEExtensionId = $gREG; CSEExtensionName = 'Registry'; CSEElaspedTimeInMilliSeconds = '900'; ErrorCode = '1' })
)
$z = Measure-GpTimes $parts $events
Check 'Times: startup median and maximum' ($z.Start.Anzahl -eq 2 -and $z.Start.MedianSek -eq 45 -and $z.Start.MaxSek -eq 50)
Check 'Times: sign-in and background' ($z.Anmeldung.MedianSek -eq 8 -and $z.Hintergrund.MedianSek -eq 3)
$si = $z.Erweiterungen | Where-Object Id -eq $gSI
Check 'Times: extension median, phase and GPOs' ($si -and $si.MedianMs -eq 27500 -and $si.StartMedianMs -eq 27500 -and $null -eq $si.AnmeldungMedianMs -and @($si.Gpos) -contains 'Software') ($si | ConvertTo-Json -Compress)
Check 'Times: slowest extension first' ($z.Erweiterungen[0].Id -eq $gSI)
Check 'Times: errors (7016) are counted' (($z.Erweiterungen | Where-Object Id -eq $gREG).Fehler -eq 1)
$ti = @(Find-GpTimeIssues $z)
Check 'Startup 45 s with default limits = critical, names the slow GPO' (@($ti | Where-Object { $_.Schluessel -eq 'time-startup' -and $_.Stufe -eq 'krit' -and @($_.Gpos) -contains 'Software' }).Count -eq 1)
Check 'Sign-in 8 s = no finding' (-not ($ti | Where-Object Schluessel -eq 'time-logon'))
Check 'Slow extension = critical (27.5 s >= 15 s)' (@($ti | Where-Object { $_.Schluessel -eq "cse:$gSI" -and $_.Stufe -eq 'krit' -and $_.Text -match 'Only the GPO "Software"' }).Count -eq 1)
Check 'Fast extension = no finding' (-not ($ti | Where-Object Schluessel -eq "cse:$gREG"))
$Script:Cfg = @{ PolicyStartWarnSec = 5; PolicyStartCritSec = 60; PolicyCseWarnMs = 500; PolicyCseCritMs = 100000; PolicyEventDays = 30 }
$ti2 = @(Find-GpTimeIssues $z)
Check 'Limits from the configuration' (@($ti2 | Where-Object { $_.Schluessel -eq 'time-startup' -and $_.Stufe -eq 'warn' }).Count -eq 1 -and @($ti2 | Where-Object Schluessel -eq 'time-logon').Count -eq 1 -and @($ti2 | Where-Object Schluessel -eq "cse:$gREG").Count -eq 1)
$Script:Cfg = $null
$z0 = Measure-GpTimes $parts @()
Check 'No events: last run from gpresult' ($z0.Quelle -eq 'RSoP' -and ($z0.Erweiterungen | Where-Object Id -eq $gSI).MedianMs -eq 30000 -and $z0.Start.Anzahl -eq 0)
Check 'No events: finding says "last run"' (@(Find-GpTimeIssues $z0 | Where-Object { $_.Schluessel -eq "cse:$gSI" -and $_.Text -match 'last run' }).Count -eq 1)

# --- 4) slowdown patterns ---
Reg 'SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon' @{ SyncForegroundPolicy = 1 }
Reg 'SOFTWARE\Policies\Microsoft\Windows\System' @{ UserPolicyMode = 1; GroupPolicyRefreshTime = 10; GpNetworkStartTimeoutPolicyValue = 120 }
Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' @{ MaxGPOScriptWait = 0 }
Reg "SOFTWARE\Policies\Microsoft\Windows\Group Policy\$($gREG.ToLower())" @{ NoGPOListChanges = 0 }
Reg "SOFTWARE\Policies\Microsoft\Windows\Group Policy\$gSEC" @{ NoGPOListChanges = 1 }
$br = @(Find-GpBrakes $parts)
$keys = @($br | ForEach-Object Schluessel)
Check 'Always wait for the network' ($keys -contains 'sync-foreground')
Check 'Startup scripts (synchronous by default)' (@($br | Where-Object { $_.Schluessel -eq 'startup-scripts' -and @($_.Gpos) -contains 'Client Baseline' }).Count -eq 1)
Check 'Three logon scripts (asynchronous) = hint' (@($br | Where-Object { $_.Schluessel -eq 'logon-scripts' -and $_.Stufe -eq '' }).Count -eq 1)
Check 'Unlimited script wait time' ($keys -contains 'script-wait')
Check 'Software Installation forces synchronous processing' (@($br | Where-Object { $_.Schluessel -eq "cse-sync:$gSI" -and @($_.Gpos) -contains 'Software' }).Count -eq 1)
Check 'Drive maps with lowercase GUID' ($keys -contains ('cse-drive:' + $gDRV.ToUpper()))
Check 'Slow link only in the user part' ($keys -contains 'slowlink:Benutzer' -and $keys -notcontains 'slowlink:Computer')
Check 'Loopback merge = warning' (@($br | Where-Object { $_.Schluessel -eq 'loopback-merge' -and $_.Stufe -eq 'warn' }).Count -eq 1)
Check 'Short refresh interval' ($keys -contains 'refresh-short')
Check 'Long network wait at startup' ($keys -contains 'network-wait')
Check 'Processed even if unchanged: only the extension with 0, with its name' (@($br | Where-Object { $_.Schluessel -eq "always:$gREG" -and $_.Titel -match 'Registry' }).Count -eq 1 -and $keys -notcontains "always:$gSEC")
Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' @{ RunStartupScriptSync = 0; RunLogonScriptSync = 1 }
$br2 = @(Find-GpBrakes $parts); $k2 = @($br2 | ForEach-Object Schluessel)
Check 'Asynchronous startup scripts = no finding; synchronous logon scripts = warning' ($k2 -notcontains 'startup-scripts' -and @($br2 | Where-Object { $_.Schluessel -eq 'logon-scripts-sync' -and $_.Stufe -eq 'warn' }).Count -eq 1)
Check 'Only 4 GPOs and 1 WMI filter = no "many GPOs"/"WMI" hint' ($k2 -notcontains 'many-gpos:Computer' -and $k2 -notcontains 'wmi:Computer')
$Script:Reg = @{}
Check 'Clean registry: only the RSoP-based patterns remain' (@(Find-GpBrakes $parts | Where-Object { $_.Schluessel -in 'sync-foreground', 'loopback-merge', 'refresh-short', 'network-wait', 'script-wait' }).Count -eq 0)

# --- 5) Intune/MDM ---
$PI = '{11111111-AAAA-BBBB-CCCC-000000000001}'; $PC = '{22222222-AAAA-BBBB-CCCC-000000000002}'
function Set-MdmReg {
    $Script:Reg = @{}
    Reg "SOFTWARE\Microsoft\Enrollments\$PI" @{ ProviderID = 'MS DM Server'; EnrollmentState = 1 }
    Reg "SOFTWARE\Microsoft\Enrollments\$PC" @{ ProviderID = 'ConfigMgr' }
    Reg "SOFTWARE\Microsoft\PolicyManager\providers\$PI\default\Device\Update" @{ DeferFeatureUpdatesPeriodInDays = 30; DeferFeatureUpdatesPeriodInDays_ProviderSet = 1 }
    Reg "SOFTWARE\Microsoft\PolicyManager\providers\$PI\default\Device\Browser" @{ AllowCookies = 1 }
    Reg "SOFTWARE\Microsoft\PolicyManager\providers\$PC\default\Device\Browser" @{ AllowCookies = 2 }
    Reg "SOFTWARE\Microsoft\PolicyManager\providers\$PI\default\Device\Experience" @{ AllowCortana = 0 }
    Reg 'SOFTWARE\Microsoft\PolicyManager\current\device\Update' @{ DeferFeatureUpdatesPeriodInDays = 30 }
    Reg 'SOFTWARE\Microsoft\PolicyManager\current\device\Browser' @{ AllowCookies = 2; AllowCookies_WinningProvider = $PC }
    Reg 'SOFTWARE\Microsoft\PolicyManager\current\device\Experience' @{ AllowCortana = 0 }
    Reg 'SOFTWARE\Microsoft\PolicyManager\default\Experience\AllowCortana' @{ GPBlockingRegKeyPath = 'Software\Policies\Microsoft\Windows\Windows Search'; GPBlockingRegValueName = 'AllowCortana' }
    Reg 'SOFTWARE\Policies\Microsoft\Windows\Windows Search' @{ AllowCortana = 1 }
    Reg 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' @{ DeferFeatureUpdates = 1 }
    Reg 'SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' @{ DisableRealtimeMonitoring = 0 }
    Reg 'SOFTWARE\Policies\Microsoft\Windows Defender\Policy Manager' @{ AllowRealtimeMonitoring = 1 }
    Reg 'SOFTWARE\Policies\Microsoft\PassportForWork' @{ Enabled = 1 }
    Reg 'SOFTWARE\Microsoft\Policies\PassportForWork\tenant\Device\Policies' @{ UsePassportForWork = 1 }
}
Set-MdmReg
$mdm = @(Get-MdmPolicies)
Check 'MDM: policies from the providers, bookkeeping values skipped' ($mdm.Count -eq 3 -and -not ($mdm | Where-Object Name -like '*_ProviderSet'))
$ck = $mdm | Where-Object Name -eq 'AllowCookies'
Check 'MDM: effective value and both sources' ($ck.Wert -eq 2 -and @($ck.Anbieter) -contains 'Intune' -and @($ck.Anbieter) -contains 'ConfigMgr')
$mo = @(Find-MdmOverlaps $mdm); $mk = @($mo | ForEach-Object Schluessel)
Check 'Intune + GPO for the same policy, GPO wins = conflict with both values' (@($mo | Where-Object { $_.Schluessel -eq 'mdm-gp-conflict' -and ($_.Details -join ' ') -match 'Intune "0", Group Policy "1"' -and $_.Quelle -eq 'GPO+Intune' }).Count -eq 1)
Check 'Windows Update from both = conflict' ($mk -contains 'mdm-wu-conflict')
Check 'Defender from both = conflict' ($mk -contains 'mdm-defender')
Check 'Windows Hello from both = conflict' ($mk -contains 'mdm-hello')
Check 'Several management sources' (@($mo | Where-Object { $_.Schluessel -eq 'mdm-multi' -and ($_.Details -join ' ') -match 'Browser/AllowCookies' }).Count -eq 1)
Reg 'SOFTWARE\Microsoft\PolicyManager\current\device\ControlPolicyConflict' @{ MDMWinsOverGP = 1 }
Reg "SOFTWARE\Microsoft\PolicyManager\providers\$PI\default\Device\Update" @{ DeferFeatureUpdatesPeriodInDays = 30; IgnoreWindowsUpdateGroupPolicies = 1 }
Reg 'SOFTWARE\Microsoft\PolicyManager\current\device\Update' @{ DeferFeatureUpdatesPeriodInDays = 30; IgnoreWindowsUpdateGroupPolicies = 1 }
$mo2 = @(Find-MdmOverlaps @(Get-MdmPolicies)); $mk2 = @($mo2 | ForEach-Object Schluessel)
Check 'MDMWinsOverGP: GPO values blocked = cleanup hint instead of conflict' ($mk2 -contains 'mdm-gp-blocked' -and $mk2 -notcontains 'mdm-gp-conflict' -and ($mo2 | Where-Object Schluessel -eq 'mdm-gp-blocked').Stufe -eq '')
Check 'IgnoreWindowsUpdateGroupPolicies: GPO values ignored = cleanup hint' ($mk2 -contains 'mdm-wu-ignored' -and $mk2 -notcontains 'mdm-wu-conflict')
Check 'No MDM policies = no Intune findings' (@(Find-MdmOverlaps @()).Count -eq 0)

# --- 6) complete analysis, report, GUI API, CLI ---
function Get-GpRsopXml { [pscustomobject]@{ Xml = $Script:Rx; Fehler = $Script:RxErr } }
function Get-GpEvents([int]$Days = 30) { $Script:EvSeen = $Days; if ($Script:EvNull) { return $null }; return , @($events) }
$Script:Rx = $xmlText; $Script:RxErr = $null; $Script:EvNull = $false
Set-MdmReg
$an = Get-PolicyAnalysis
Check 'Analysis: all sources read' ($an.Quellen.Rsop -and $an.Quellen.Ereignisse -and $an.Quellen.Mdm -and $an.MdmAnzahl -eq 3)
Check 'Analysis: event days from the configuration' ($Script:EvSeen -eq 30)
Check 'Analysis: critical findings first' ($an.Befunde[0].Stufe -eq 'krit')
Check 'Analysis: counts per kind' ($an.Zaehler.Konflikt -ge 2 -and $an.Zaehler.Doppelt -ge 3 -and $an.Zaehler.Startzeit -eq 1 -and $an.Zaehler.Ladezeit -ge 1 -and $an.Zaehler.Bremse -ge 3 -and $an.Zaehler.Intune -ge 4)
Check 'Analysis: every finding has kind, level, title, text and a stable key' (@($an.Befunde | Where-Object { -not $_.Art -or $_.Stufe -notin 'krit', 'warn', '' -or -not $_.Titel -or -not $_.Text -or -not $_.Schluessel }).Count -eq 0)
Check 'Analysis: findings keys are unique' (@($an.Befunde | Group-Object Schluessel | Where-Object Count -gt 1).Count -eq 0) (@($an.Befunde | Group-Object Schluessel | Where-Object Count -gt 1 | ForEach-Object Name) -join ', ')
Check 'Analysis: JSON round trip' ($null -ne (($an | ConvertTo-Json -Depth 8) | ConvertFrom-Json))
$rep = New-PolicyReport $an
$html = Get-Content -LiteralPath $rep -Raw -Encoding UTF8
Check 'Report written to the data folder' ($rep -eq (Join-Path $TestData 'WinTidy-Richtlinien.html') -and $html -match '<html lang=''en''>')
Check 'Report: names are HTML-encoded' ($html -match 'Old Baseline &amp; Co' -and $html -notmatch 'Old Baseline & Co')
Check 'Report: findings, extension table and GPO table' ($html -match 'Software Installation' -and $html -match 'Applied GPOs' -and $html -match 'Filtered GPO' -and $html -match 'not applied')
# --- CSV export (since 1.14) ---
$csvPath = New-PolicyCsv $an
$raw = [IO.File]::ReadAllBytes($csvPath)
Check 'CSV written to the data folder, UTF-8 with BOM' ($csvPath -eq (Join-Path $TestData 'WinTidy-Richtlinien.csv') -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
$rows = @(Import-Csv -LiteralPath $csvPath -Delimiter ';' -Encoding UTF8)
$hdr = (Get-Content -LiteralPath $csvPath -Encoding UTF8 -TotalCount 1)
Check 'CSV: stable English header, separator ;' ($hdr -eq '"Computer";"Time";"Kind";"Severity";"Source";"Check";"Key";"GpoIds";"Gpos";"Title";"Text";"Details"') $hdr
Check 'CSV: one row per finding, same order' ($rows.Count -eq @($an.Befunde).Count -and $rows[0].Key -eq $an.Befunde[0].Schluessel) ("$($rows.Count) / $(@($an.Befunde).Count)")
Check 'CSV: internal, language-independent kind and severity' (@($rows | Where-Object { $_.Kind -notin 'Konflikt', 'Doppelt', 'Startzeit', 'Ladezeit', 'Bremse' -or $_.Severity -notin 'krit', 'warn', '' }).Count -eq 0)
$dupRow = @($rows | Where-Object { $_.Check -eq 'dup' })[0]
Check 'CSV: GPO ids of a duplicate, winner first' ($dupRow -and ($dupRow.GpoIds -split '; ').Count -eq 2 -and $dupRow.Key -eq ('dup:' + ($dupRow.GpoIds -replace '; ', ':'))) $(if ($dupRow) { $dupRow.Key + ' / ' + $dupRow.GpoIds })
Check 'CSV: no GPO ids for extension checks' (@($rows | Where-Object { $_.Check -like 'cse*' -and $_.GpoIds }).Count -eq 0)
$detRow = @($rows | Where-Object { @($an.Befunde | Where-Object Schluessel -eq $_.Key)[0].Details.Count -ge 2 })[0]
Check 'CSV: details survive as lines of one cell' ($detRow -and @($detRow.Details -split "`r?`n").Count -ge 2)
Check 'CSV: names with special characters intact' ((Get-Content -LiteralPath $csvPath -Raw -Encoding UTF8) -match 'Old Baseline & Co')
$evil = [pscustomobject]@{ Computer = 'PC'; Zeit = 'now'; Befunde = @([pscustomobject]@{ Art = 'Doppelt'; Stufe = ''; Quelle = 'GPO'; Titel = '=HYPERLINK("x")'; Text = '+1'; Gpos = @('@evil', 'a;b'); Details = @('-ok'); Schluessel = 'multilink:{AAAAAAAA-0000-0000-0000-000000000001}' }) }
$er = @(Get-PolicyCsvRows $evil)[0]
Check 'CSV: cells starting with = + @ are not formulas' ($er.Title -eq "'=HYPERLINK(""x"")" -and $er.Text -eq "'+1" -and $er.Gpos -eq "'@evil; a;b" -and $er.Details -eq '-ok' -and $er.GpoIds -eq '{AAAAAAAA-0000-0000-0000-000000000001}')
$emptyCsv = New-PolicyCsv ([pscustomobject]@{ Computer = 'PC'; Zeit = 'now'; Befunde = @() })
Check 'CSV without findings: header only' (@(Get-Content -LiteralPath $emptyCsv -Encoding UTF8).Count -eq 1)
$Script:Out = @()
Show-PolicyAnalysis $an
Check 'CLI output contains the findings' ((@($Script:Out) -join "`n") -match 'Software Installation' -and (@($Script:Out) -join "`n") -match 'Findings:')

# without anything readable
$Script:Rx = $null; $Script:RxErr = 'access denied'; $Script:EvNull = $true; $Script:Reg = @{}
$Script:Ctx = [pscustomobject]@{ Domaene = $false; Intune = $false; EntraJoin = $false; ConfigMgr = $false; AnderesKonto = $false; ProzessBenutzer = 'PC\u'; SitzungsBenutzer = 'PC\u' }
$Script:IsAdmin = $false
$e = Get-PolicyAnalysis
Check 'Nothing readable: no findings, but hints' (@($e.Befunde).Count -eq 0 -and @($e.Hinweise).Count -ge 4 -and -not $e.Quellen.Rsop -and -not $e.Quellen.Ereignisse) (@($e.Hinweise) -join ' | ')
Check 'Nothing readable: report still works' ((Test-Path -LiteralPath (New-PolicyReport $e)))
function Get-GpRsopXml { throw 'boom' }
$g = Invoke-GuiPolicyScan
Check 'GUI API never throws: failing source becomes a hint' ($g.Analyse -and -not $g.Fehler -and (@($g.Analyse.Hinweise) -join ' ') -match 'boom' -and $g.Report -and $g.Csv -and (Test-Path -LiteralPath $g.Csv))
function Get-PolicyAnalysis { throw 'kaputt' }
$g2 = Invoke-GuiPolicyScan
Check 'GUI API never throws: readable error' (-not $g2.Analyse -and $g2.Fehler -match 'kaputt')

# --- 7) German report ---
Set-WtLanguage 'de' $root
$Script:IsAdmin = $true
$repDe = New-PolicyReport $an
$htmlDe = Get-Content -LiteralPath $repDe -Raw -Encoding UTF8
Check 'German report' ($htmlDe -match "<html lang='de'>" -and $htmlDe -match 'Richtlinien')
Check 'German texts for kinds' ((Get-PolArtText 'Konflikt') -ne 'Conflicts' -and (Get-PolArtText 'Bremse') -ne 'Slowdown patterns')
Set-WtLanguage 'en' $root

# --- 8) read-only and configuration ---
$code = Get-Content -LiteralPath $src -Raw -Encoding UTF8
$i0 = $code.IndexOf('#  Policy analysis for IT admins'); $i1 = $code.IndexOf('#  Modes', $i0)
$sec = $code.Substring($i0, $i1 - $i0)
$writes = @([regex]::Matches($sec, '(?i)Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-RegValueWithUndo|\.SetValue\(|\.DeleteValue|\.DeleteSubKey|\.CreateSubKey|OpenSubKey\([^)]*\$true|Remove-Item(?! -LiteralPath \$out )|gpupdate|Invoke-GPUpdate|Set-GP|New-GP|Remove-GP') | ForEach-Object Value)
Check 'Policy section changes nothing (no registry writes, no gpupdate, only its own gpresult file)' ($writes.Count -eq 0) ($writes -join ', ')
Check 'gpresult is started by full path' ($sec -match "Join-Path \`$env:windir 'System32\\gpresult.exe'")
$c = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $c[$k] = $Script:DefaultConfig[$k] }
$c.PolicyStartWarnSec = 0; $c.PolicyCseWarnMs = 5000; $c.PolicyCseCritMs = 1000; $c.PolicyEventDays = 0
$c = Test-Config $c 3>$null
Check 'Test-Config: invalid limits fall back, critical never below warning' ($c.PolicyStartWarnSec -eq 15 -and $c.PolicyEventDays -eq 30 -and $c.PolicyCseCritMs -eq 5000)
$ex = Get-Content -LiteralPath (Join-Path $root 'WinTidy.config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'Example configuration lists the new keys' ($ex.PSObject.Properties['PolicyStartWarnSec'] -and $ex.PSObject.Properties['PolicyEventDays'] -and $ex.PSObject.Properties['PolicyCseCritMs'])
Check 'Mode Policies exists' ($code -match "'Exclusions', 'Policies'\)\]" -and $code -match "'Policies' \{ Start-RunLog 'policies'; Invoke-PolicyMode")

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit $fail }
Write-Host 'All policy tests passed' -ForegroundColor Green
