# Test-Debloat.ps1 - checks the Debloat page (catalog, detection, fixing, app removal, safety checks) without Windows:
# the registry and the app list are replaced by memory. Usage: pwsh ./tests/Test-Debloat.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-debloattest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|GuiPreselectMedium|AreaNames|RestoreKeyAllow|Debloat\w+)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
# The Debloat rules only (the other rules are not needed here)
$Script:Rules = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match "Id = 'DBL-" }, $true) | ForEach-Object { & ([scriptblock]::Create($_.Extent.Text)) })
$Script:Cfg = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $Script:Cfg[$k] = $Script:DefaultConfig[$k] }
$Script:DataDir = $TestData; $Script:SnapDir = Join-Path $TestData 'snapshots'; $Script:RunsDir = Join-Path $TestData 'runs'
New-Item -ItemType Directory -Force $Script:SnapDir, $Script:RunsDir | Out-Null
$Script:Cache = @{}; $Script:IsAdmin = $true

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }

# --- Replace Windows parts ---
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
function Start-Transcript { } ; function Stop-Transcript { }
function New-Snapshot([string]$Label, $Findings) { [pscustomobject]@{ Label = $Label; Score = @{ Wert = 80 }; Befunde = $Findings } }
function New-Report { $null }
function Get-CompareMetrics($a, $b) { @() }
function Invoke-Checkpoint { $null }
function Get-HardwarePoints { @() }
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
function Get-WtContext { $Script:Ctx }
$Script:MockBuild = 26100
function Get-WtBuildNumber { $Script:MockBuild }
$Script:Reg = @{}; $Script:Writes = New-Object System.Collections.Generic.List[object]
function Get-DebloatValue([string]$Key, [string]$Name) { $k = "$Key|$Name"; if ($Script:Reg.ContainsKey($k)) { return $Script:Reg[$k] }; return $null }
function Set-RegValueWithUndo([string]$Rule, [string]$Objekt, [string]$Key, [string]$Name, $Value, [string]$Type, [switch]$Remove) {
    $Script:Writes.Add([pscustomobject]@{ Rule = $Rule; Key = $Key; Name = $Name; Value = $Value; Type = $Type })
    $Script:Reg["$Key|$Name"] = $Value
}
$Script:Apps = @()
$Script:RemovedFull = New-Object System.Collections.Generic.List[string]
$Script:RemovedProv = New-Object System.Collections.Generic.List[string]
function Get-AppxPackage { [CmdletBinding()] param() $Script:Apps }
function Remove-AppxPackage { [CmdletBinding()] param([string]$Package) $Script:RemovedFull.Add($Package); $Script:Apps = @($Script:Apps | Where-Object { $_.PackageFullName -ne $Package }) }
function Get-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online) @([pscustomobject]@{ DisplayName = 'King.com.CandyCrushSaga'; PackageName = 'King.com.CandyCrushSaga_prov' }, [pscustomobject]@{ DisplayName = 'Microsoft.Paint'; PackageName = 'Microsoft.Paint_prov' }) }
function Remove-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online, [string]$PackageName) $Script:RemovedProv.Add($PackageName) }
function New-App([string]$Name, [bool]$NonRemovable = $false, [bool]$Framework = $false) { [pscustomobject]@{ Name = $Name; Version = '1.0.0.0'; PackageFullName = "${Name}_1.0.0.0_x64__abc"; NonRemovable = $NonRemovable; IsFramework = $Framework } }

# 1) Catalog
$ids = @($Script:DebloatTweaks | ForEach-Object { $_.Id })
Check 'Tweak IDs are unique' (@($ids | Group-Object | Where-Object Count -gt 1).Count -eq 0)
Check 'Every tweak belongs to one of the 4 setting rules' (@($Script:DebloatTweaks | Where-Object { $_.Gruppe -notin 'DBL-ADS', 'DBL-PRIVACY', 'DBL-SHELL', 'DBL-COMFORT' }).Count -eq 0)
Check 'Every tweak has a title and values' (@($Script:DebloatTweaks | Where-Object { -not $_.Titel -or -not @($_.Werte).Count }).Count -eq 0)
$badKeys = @($Script:DebloatTweaks | ForEach-Object { $_.Werte } | Where-Object { -not (Test-RegKeyAllowed $_.Key) } | ForEach-Object { $_.Key } | Select-Object -Unique)
Check 'All registry keys are in the Restore allow-list (so every change can be undone)' ($badKeys.Count -eq 0) ($badKeys -join '; ')
Check 'Only HKCU is touched' (@($Script:DebloatTweaks | ForEach-Object { $_.Werte } | Where-Object { $_.Key -notmatch '^HKCU:\\' }).Count -eq 0)
Check 'Value types are valid' (@($Script:DebloatTweaks | ForEach-Object { $_.Werte } | Where-Object { $_.Typ -notin 'DWord', 'String' }).Count -eq 0)
$appIds = @($Script:DebloatApps | ForEach-Object { $_.Id })
Check 'App catalog has entries and all 3 groups' ($appIds.Count -gt 50 -and @($Script:DebloatApps | Group-Object Gruppe).Count -eq 3 -and @($Script:DebloatApps | Where-Object { $_.Gruppe -notin 'PROMO', 'MS', 'OEM' }).Count -eq 0)
Check 'App IDs are unique ignoring case' (@($appIds | ForEach-Object { $_.ToLower() } | Group-Object | Where-Object Count -gt 1).Count -eq 0) ((@($appIds | ForEach-Object { $_.ToLower() } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)) -join ', ')
Check 'App IDs and names are well-formed' (@($Script:DebloatApps | Where-Object { $_.Id -notmatch '^[\w\.\-]+$' -or -not $_.Name }).Count -eq 0)
$hit = @($appIds | Where-Object { $i = $_; @($Script:DebloatNever | Where-Object { $i -like ($_ + '*') -or $_ -like ($i + '*') }).Count })
Check 'No catalog app is on the never-remove list' ($hit.Count -eq 0) ($hit -join ', ')
Check 'Never-list protects Store, Defender UI, App Installer, Terminal' (@('Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsTerminal' | Where-Object { $n = $_; -not ($Script:DebloatNever | Where-Object { $n -like ($_ + '*') }) }).Count -eq 0)

# 2) Settings: detection
$Script:Build = 26100; $Script:MockBuild = 26100
$all = @(Get-DebloatTweakItems 'DBL-ADS') + @(Get-DebloatTweakItems 'DBL-PRIVACY') + @(Get-DebloatTweakItems 'DBL-SHELL') + @(Get-DebloatTweakItems 'DBL-COMFORT')
Check 'Empty registry: every setting is offered on a current Windows 11' ($all.Count -eq $ids.Count) "$($all.Count) of $($ids.Count)"
$Script:MockBuild = 19045; $Script:Cache = @{}
$w10 = @(Get-DebloatTweakItems 'DBL-SHELL' | ForEach-Object { $_.Data })
Check 'Windows 10: Copilot, Chat and End-task are not offered' (-not ($w10 -contains 'copilot-btn') -and -not ($w10 -contains 'chat') -and -not ($w10 -contains 'endtask') -and ($w10 -contains 'bing'))
$Script:MockBuild = 22000
$w11a = @(Get-DebloatTweakItems 'DBL-SHELL' | ForEach-Object { $_.Data })
Check 'Windows 11 21H2: Chat yes, Copilot and End-task no' (($w11a -contains 'chat') -and -not ($w11a -contains 'copilot-btn') -and -not ($w11a -contains 'endtask'))
$Script:MockBuild = 26100
Check 'Detect does not change anything' ($Script:Writes.Count -eq 0)

# 3) Settings: fix and re-check
$t = $Script:DebloatTweaks | Where-Object Id -eq 'sticky'
$item = New-Item2 $t.Titel 0 'sticky'
$res = Set-DebloatTweak 'DBL-COMFORT' $item
Check 'Set-DebloatTweak writes the values via Set-RegValueWithUndo' ($Script:Writes.Count -eq @($t.Werte).Count -and $Script:Writes[0].Rule -eq 'DBL-COMFORT' -and $res -eq 'changed')
Check 'Sticky Keys flags is a string value' (($Script:Writes | Where-Object Name -eq 'Flags').Type -eq 'String' -and ($Script:Writes | Where-Object Name -eq 'Flags').Value -eq '506')
Check 'Changed setting is no longer offered' (@(Get-DebloatTweakItems 'DBL-COMFORT' | Where-Object { $_.Data -eq 'sticky' }).Count -eq 0)
$thrown = $false; try { Set-DebloatTweak 'DBL-ADS' (New-Item2 'x' 0 'does-not-exist') | Out-Null } catch { $thrown = $true }
Check 'Unknown setting throws' $thrown
# A value of a different type/number counts as not set
$Script:Reg.Clear(); $first = $Script:DebloatTweaks[0]; $v0 = @($first.Werte)[0]
foreach ($v in @($first.Werte)) { $Script:Reg["$($v.Key)|$($v.Name)"] = $v.Wert }
Check 'Fully set tweak is not offered' (@(Get-DebloatTweakItems $first.Gruppe | Where-Object { $_.Data -eq $first.Id }).Count -eq 0)
$Script:Reg["$($v0.Key)|$($v0.Name)"] = 1
Check 'Partly set tweak is still offered' (@(Get-DebloatTweakItems $first.Gruppe | Where-Object { $_.Data -eq $first.Id }).Count -eq 1)
$Script:Reg.Clear(); $Script:Writes.Clear()

# 4) Apps: detection
$Script:Apps = @((New-App 'King.com.CandyCrushSaga'), (New-App 'Microsoft.BingFinance'), (New-App 'Microsoft.WindowsStore'), (New-App 'Microsoft.YourPhone' $true), (New-App 'Microsoft.NetworkSpeedTest' $false $true), (New-App 'Microsoft.Todos'))
$Script:Cache = @{}
$promo = @(Get-DebloatAppItems 'PROMO'); $ms = @(Get-DebloatAppItems 'MS'); $oem = @(Get-DebloatAppItems 'OEM')
Check 'PROMO: installed catalog app found' ($promo.Count -eq 1 -and $promo[0].Data -eq 'king.com.CandyCrushSaga')
Check 'MS: finds installed apps, skips NonRemovable and frameworks' (@($ms | ForEach-Object { $_.Data } | Sort-Object) -join ',' -eq 'Microsoft.BingFinance,Microsoft.Todos') (@($ms | ForEach-Object { $_.Data }) -join ',')
Check 'The Store is never offered' (-not (@($promo + $ms + $oem | ForEach-Object { $_.Data }) -contains 'Microsoft.WindowsStore'))
Check 'OEM: nothing installed, nothing offered' ($oem.Count -eq 0)
# Since 1.9 BloatApps only adds package names to the group MS (the former rule APP-BLOAT is part of the catalog)
Check 'Former APP-BLOAT apps are in the catalog (group MS)' (@($Script:DebloatApps | Where-Object { $_.Gruppe -eq 'MS' -and $_.Id -in 'Microsoft.BingNews', 'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection' }).Count -eq 3)
$Script:Cfg.BloatApps = @('Microsoft.Todos'); $Script:Cache = @{}
Check 'BloatApps entry already in the catalog is offered only once' (@(Get-DebloatAppItems 'MS' | Where-Object { $_.Data -eq 'Microsoft.Todos' }).Count -eq 1)
$Script:Apps += New-App 'Contoso.ExtraApp'
$Script:Cfg.BloatApps = @('Contoso.ExtraApp'); $Script:Cache = @{}
Check 'BloatApps entry outside the catalog is offered under Microsoft apps' (@(Get-DebloatAppItems 'MS' | Where-Object { $_.Data -eq 'Contoso.ExtraApp' }).Count -eq 1 -and @(Get-DebloatAppItems 'PROMO' | Where-Object { $_.Data -eq 'Contoso.ExtraApp' }).Count -eq 0)
$Script:Apps = @($Script:Apps | Where-Object { $_.Name -ne 'Contoso.ExtraApp' })
$Script:Cfg.BloatApps = @($Script:DefaultConfig.BloatApps); $Script:Cache = @{}

# 5) Apps: removal and safety
$r = Remove-DebloatApp 'King.com.CandyCrushSaga'
Check 'Remove-DebloatApp removes the package' ($Script:RemovedFull.Count -eq 1 -and $Script:RemovedFull[0] -like 'King.com.CandyCrushSaga_*' -and $r -eq 'removed')
Check 'As administrator also removed from the Windows image (only the matching one)' ($Script:RemovedProv.Count -eq 1 -and $Script:RemovedProv[0] -eq 'King.com.CandyCrushSaga_prov')
$Script:RemovedFull.Clear(); $Script:RemovedProv.Clear()
foreach ($bad in 'Foo;calc', 'a b', '', 'x*', '..\evil', 'Microsoft.WindowsStore', 'Microsoft.SecHealthUI', 'Microsoft', 'Microsoft.Paint', 'Microsoft.NET.Native.Framework.2.2') {
    $thrown = $false; try { Remove-DebloatApp $bad | Out-Null } catch { $thrown = $true }
    Check "Remove-DebloatApp refuses '$bad'" ($thrown -and $Script:RemovedFull.Count -eq 0 -and $Script:RemovedProv.Count -eq 0)
}

# 6) Rules and findings of the page
$Script:Cache = @{}; $Script:Reg.Clear()
$Script:Apps = @((New-App 'King.com.CandyCrushSaga'), (New-App 'Microsoft.BingFinance'))
Check '7 Debloat rules exist' ($Script:Rules.Count -eq 7)
Check 'All Debloat rules are on the page, not standard, and have a plain-language text' (@($Script:Rules | Where-Object { $_.Seite -ne 'Debloat' -or $_.Standard -or -not $Script:Friendly[$_.Id] }).Count -eq 0)
Check 'Settings are reversible, apps are permanent' (@($Script:Rules | Where-Object { $_.Id -notlike 'DBL-APPS-*' -and -not $_.Umkehrbar }).Count -eq 0 -and @($Script:Rules | Where-Object { $_.Id -like 'DBL-APPS-*' -and (-not $_.Endgueltig -or -not $_.Admin) }).Count -eq 0)
Check 'Vendor apps need an individual decision' (($Script:Rules | Where-Object Id -eq 'DBL-APPS-OEM').Einzeln -and ($Script:Rules | Where-Object Id -eq 'DBL-APPS-OEM').Risiko -eq 'Hoch')
$page = @(Get-AllFindings $false $null 'Debloat')
Check 'Page scan: 4 setting rules + 2 app rules with findings' ($page.Count -eq 6 -and @($page | Where-Object { $_.Seite -ne 'Debloat' }).Count -eq 0) ($page.Id -join ',')
$ads = $page | Where-Object Id -eq 'DBL-ADS'
Check 'Ads and suggestions are preselected' (@($ads.Items | Where-Object { -not $_.Selected }).Count -eq 0 -and $ads.Items.Count -gt 5)
Check 'Everything else is not preselected' (@($page | Where-Object Id -ne 'DBL-ADS' | ForEach-Object { $_.Items } | Where-Object Selected).Count -eq 0)
Check 'Findings use the plain-language text' ($ads.Titel -eq $Script:Friendly['DBL-ADS'][0])
# Another page's findings are kept and the normal check does not show Debloat rules
$Script:Rules += [pscustomobject]@{ Id = 'CLN-T'; Kategorie = 'Speicher'; Titel = 'T'; Warum = 't'; Risiko = 'Niedrig'; Admin = $false; Standard = $true; Detect = { New-Item2 't1' 10 }; Fix = { param($it) 'ok' } }
$norm = @(Get-AllFindings $false $null)
Check 'Normal check shows no Debloat rule' ($norm.Count -eq 1 -and $norm[0].Id -eq 'CLN-T')
Check 'Debloat findings stay available after a normal check' (@($Script:LastFindings | Where-Object Seite -eq 'Debloat').Count -eq 6 -and @($Script:LastFindings | Where-Object Id -eq 'CLN-T').Count -eq 1)
$page2 = @(Get-AllFindings $false $null 'Debloat')
Check 'Debloat check does not drop the normal findings' (@($Script:LastFindings | Where-Object Id -eq 'CLN-T').Count -eq 1 -and @($Script:LastFindings | Where-Object Seite -eq 'Debloat').Count -eq 6 -and $page2.Count -eq 6)

# 7) Apply through the engine
$sel = @(@{ Id = 'DBL-ADS'; Indexes = @($ads.Items | ForEach-Object { $_.Index }) }, @{ Id = 'DBL-APPS-PROMO'; Indexes = @(0) })
$run = Invoke-FixSelection $sel $false $null $null $true
Check 'Invoke-FixSelection applies settings and removes the app' ($run.Status -eq 'OK' -and $run.Fehler -eq 0 -and $run.OK -eq ($ads.Items.Count + 1)) ($run | Select-Object Status, OK, Fehler | ConvertTo-Json -Compress)
Check 'Registry values were written' ($Script:Writes.Count -gt 5 -and @($Script:Writes | Where-Object Rule -ne 'DBL-ADS').Count -eq 0)
Check 'The app was removed' ($Script:RemovedFull.Count -eq 1)
$Script:Cache = @{}
$after = @(Get-AllFindings $false $null 'Debloat')
Check 'After applying, ads and the removed app are gone, the other app remains' (-not ($after | Where-Object Id -eq 'DBL-ADS') -and -not ($after | Where-Object Id -eq 'DBL-APPS-PROMO') -and [bool]($after | Where-Object Id -eq 'DBL-APPS-MS')) (($after | ForEach-Object Id) -join ',')

# 8) Contexts
$Script:Reg.Clear(); $Script:Cache = @{}
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $true; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
$g = Invoke-GuiDebloatScan
Check 'Managed PC: nothing offered, hint shown' (@($g.Findings).Count -eq 0 -and $g.Hinweis)
$Script:Ctx = [pscustomobject]@{ Server = $true; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
$g = Invoke-GuiDebloatScan
Check 'Windows Server: nothing offered, hint shown' (@($g.Findings).Count -eq 0 -and $g.Hinweis)
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $true; NeustartAusstehend = $false; Hinweise = @() }
$g = Invoke-GuiDebloatScan
Check 'Other account signed in: nothing offered, hint shown' (@($g.Findings).Count -eq 0 -and $g.Hinweis)
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
$g = Invoke-GuiDebloatScan
Check 'Normal PC: findings, no hint' (@($g.Findings).Count -gt 0 -and -not $g.Hinweis)
$Script:IsAdmin = $false; $Script:Cache = @{}
$g = Invoke-GuiDebloatScan
Check 'Without administrator rights the app rules are skipped, settings remain' (@($g.Findings | Where-Object { $_.Id -like 'DBL-APPS-*' }).Count -eq 0 -and @($g.Findings | Where-Object Id -eq 'DBL-ADS').Count -eq 1)

exit $fail
